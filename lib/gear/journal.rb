# frozen_string_literal: true

# WORKER SLOT: journal
# 実装はこのファイルと lib/gear/journal/ 配下に閉じること。
# 他ワーカーのファイルを触らない (並列分散の territory 境界)。
#
# ------------------------------------------------------------------
# Gear::Journal — 状態の正本 (source of truth)。
#
# gear の中で最も重い pin 群を背負う場所。走行中に起きたことはここへ
# 追記され、現在状態は「追記列の畳み込み」として導かれる。別立ての
# 可変状態 (shadow state) は持たない。
#
# 満たす pin (gear.spec):
#   journal.append_only          追記のみ。既存 entry を書き換えも削除もしない。
#   journal.is_source_of_truth   正本は journal。他所 (UI/cache) に正本を置かない。
#   journal.no_shadow_state      component 側に権威ある可変状態を持たない。
#   journal.state_is_fold        現在状態は #fold による畳み込みで得る。
#   journal.replay_deterministic 同じ journal と同じ seed から同じ走行が出る。
#   journal.records_external_results 非決定入力は外界 port の結果として記録する。
#   journal.replay_scope_declared 決定論は「記録された境界より内側」でのみ成立し、
#                                 その境界を RecordedBoundary として明示する。
#
# 物理形式 (free journal.physical の決定): NDJSON を採る。
#   理由: entry は 1 件 1 行の JSON object にちょうど載り、zeolite が NDJSON を
#   1 record ずつ遅延で読み戻せる (zeolite/README)。SQLite/Postgres は索引や
#   並行書き込みが要るときの将来拡張であって、正本ログの最小形は追記専用の
#   行指向テキストで足りる。
#
# sodalite 流用の判断: 流用しない。sodalite の store/journal.rb は saga 補償
#   (書き込みの逆操作を溜めて巻き戻す) 用であり、append-only の状態正本ログとは
#   目的が真逆 (あちらは undo を持つ) なので、ここでは共有語彙を持たせない。
# ------------------------------------------------------------------
require 'json'
require 'zeolite'

module Gear
  module Journal
    # 記録された境界を踏み越えた (= replay で外界に頼ろうとした) しるし。
    # gear.rb の Gear::Error はこのファイルの require 時点ではまだ未定義なので、
    # 依存を作らず StandardError を直接継承する。
    class CrossedBoundary < StandardError; end

    # 外界 port の結果を保持する entry の kind。
    PORT_RESULT = :port_result

    # 一件の出来事。immutable な値 (Data)。
    #   tick    : Clock の離散歩。全順序を持つ整数 (pin tick.total_order を尊重)。
    #   kind    : 出来事の種類 (Symbol)。
    #   payload : JSON 安全な Hash。
    Entry = Data.define(:tick, :kind, :payload) do
      # 生成の入口を一つにする。payload は凍結して後からの書き換えを防ぎ、
      # append-only を値レベルでも担保する。
      def self.at(tick, kind, payload = {})
        new(tick: tick, kind: kind.to_sym, payload: payload.freeze)
      end
    end

    # 境界を通る entry の名詞形を zeolite schema で宣言する
    # (pin port.boundary_value: 境界の名詞を共通化する精神)。
    # payload の内部形は domain 次第なので map_of(:any) で中身は縛らない。
    SCHEMA = Zeolite.schema(
      tick: :integer,
      kind: :string,
      payload: Zeolite.map_of(:any)
    ).named(:JournalEntry)

    # 追記専用のログ。これ自体が「状態の正本」であり、現在状態を別に抱えない。
    #
    # immutable にしてある: #append は既存 Log を一切変えず、entry を一つ足した
    # *新しい* Log を返す。書き換え/削除 API はそもそも生やさない。これにより
    # append-only (pin journal.append_only) と no_shadow_state を構造で担保する。
    class Log
      include Enumerable

      def initialize(entries = [])
        @entries = entries.to_a.dup.freeze
        freeze
      end

      # 追記のみ。既存 entry も既存 Log も変えず、新しい Log を返す。
      def append(entry)
        Log.new(@entries + [entry])
      end

      def each(&) = @entries.each(&)
      def to_a = @entries
      def size = @entries.size
      def empty? = @entries.empty?

      # 現在状態は畳み込みで導く (pin journal.state_is_fold)。Log 自身は
      # 畳み込んだ結果をキャッシュ (= shadow state) しない。同じ Log と同じ
      # 初期値・同じ reducer からは常に同じ状態が出る。
      def fold(initial)
        @entries.reduce(initial) { |state, entry| yield(state, entry) }
      end

      # 記録された外界結果だけを追記順に。
      def port_results
        @entries.select { |entry| entry.kind == PORT_RESULT }
      end
    end

    # 記録された境界 (recorded boundary)。決定論の“外周”をここで明示する
    # (pin journal.records_external_results / journal.replay_scope_declared)。
    #
    #   record モード: block を実行して外界に触れ、その結果を journal に
    #                  PORT_RESULT として記録し、結果を返す。
    #   replay モード: block を *実行しない*。journal に記録済みの結果を
    #                  追記順に読み戻す。
    #
    # ゆえに決定論は「記録済みの境界より内側」でのみ成立する。記録が尽きた
    # replay で block に頼ろうとしたら、それは境界の踏み越えなので例外にする。
    # 時刻・ネットワーク応答・ネイティブ乱数のような非決定入力はここを通す。
    # (seed から再現できる決定論的乱数は外界ではないので、ここでは記録しない。)
    class RecordedBoundary
      # 記録用。空 (または途中) の Log から始め、外界を記録しながら追記する。
      def self.recording(log = Log.new) = new(log, mode: :record)

      # 再生用。記録済みの Log を追記順に読み戻す。
      def self.replaying(log) = new(log, mode: :replay)

      attr_reader :log

      def initialize(log, mode:)
        @log = log
        @mode = mode
        @recorded = log.port_results
        @cursor = 0
      end

      def recording? = @mode == :record
      def replaying? = @mode == :replay

      # tick : 現在の tick (Clock 由来)。
      # port : 論理 port 名 (Symbol/String)。
      # block: 外界を実際に叩く手続き。replay 時は絶対に呼ばれない。
      def call(tick, port)
        return replay_next if replaying?

        result = yield
        @log = @log.append(
          Entry.at(tick, PORT_RESULT, 'port' => port.to_s, 'result' => result)
        )
        result
      end

      private

      def replay_next
        entry = @recorded[@cursor]
        if entry.nil?
          raise CrossedBoundary,
                '記録された境界を踏み越えた: replay に読み戻せる外界結果が尽きた'
        end
        @cursor += 1
        entry.payload['result']
      end
    end

    module_function

    # entry 列を NDJSON テキストへ書き出す (1 entry = 1 行)。
    def dump(log)
      log.to_a.map do |entry|
        JSON.generate('tick' => entry.tick, 'kind' => entry.kind.to_s, 'payload' => entry.payload)
      end.join("\n") + "\n"
    end

    # NDJSON テキストを読み戻して Log を復元する。zeolite で 1 record ずつ
    # 検証しながら Entry に写す (境界の名詞を SCHEMA で共通化する)。
    def load(text)
      entries = Zeolite.stream(text, SCHEMA).map do |result|
        row = result.unwrap
        Entry.at(row.tick, row.kind.to_sym, row.payload)
      end
      Log.new(entries)
    end
  end
end
