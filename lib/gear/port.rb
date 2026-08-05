# frozen_string_literal: true

# WORKER SLOT: port
# 実装はこのファイルと lib/gear/port/ 配下に閉じること。
# 他ワーカーのファイルを触らない (並列分散の territory 境界)。

require 'json'
require 'darkcore'
require 'zeolite'

module Gear
  # ==================================================================
  # Port — 外界と gear の境界。ここが gear の心臓部。
  #
  # 目的は「プログラムの境目を溶かす」こと。外の世界のあらゆる系統
  # (shell / HTTP / DB / LLM / ファイル / 描画) を、一枚の adapter を
  # 書くだけで darkcore の Effect に載せる。これで n 個を繋ぐ接着剤が
  # n^2 から n に落ちる (spec: port.adapter_reusable / global_reuse)。
  #
  # 満たす pin:
  #   port.external_via_adapter — 外界は adapter を通して Effect になる。
  #   port.no_direct_call       — 生の外界呼び出しは handler の中だけ。
  #   port.effect_substrate     — 生む Effect は darkcore の単一 Effect 型。
  #   port.boundary_value       — payload/result の形は zeolite schema。
  #   port.adapter_reusable     — 1 枚登録すれば tag から全体で引ける。
  #   journal.records_external_results — result は必ずシリアライズ可能。
  #
  # free adapter.contract_shape の裁定(理由):
  #   登録・発見は「明示 registry + tag 所有」で行う。規約ベース autoload
  #   より、どの tag をどの系統が握るかが検査可能で衝突を早期に弾けるため。
  # ==================================================================
  module Port
    # gear.rb は require_relative 'gear/port' の後で Gear::Error を定義するため、
    # 読み込み順の都合でここでは Gear::Error にまだ触れない。自領分で完結させ、
    # StandardError を親にする (lib/gear.rb は編集しない territory 規律)。
    class Error < StandardError; end
    # payload が payload schema に合わない (呼び出し要求の形が不正)。
    class InvalidPayload < Error; end
    # 外界の生結果が result schema に合わない (境界の値の形が不正)。
    class InvalidResult < Error; end
    # 一つの effect tag を複数 adapter が握ろうとした。
    class TagConflict < Error; end
    class UnknownTag < Error; end
    class UnknownAdapter < Error; end

    module_function

    # 境界を跨ぐ値を「素の JSON スカラだけ」に正規化する。
    #   - symbol key を string key に落とす (zeolite Record は string key で読む)。
    #   - IO/Proc などシリアライズ不能物を JSON 経由で弾き落とす。
    # これを通した値は journal に記録可能 (pin journal.records_external_results)。
    def normalize(data)
      JSON.parse(JSON.generate(data))
    end

    # ================================================================
    # Operation — adapter が握る effect tag 一つ分の宣言。
    #
    #   tag            : darkcore effect のディスパッチキー。
    #   payload_schema : 呼び出し要求の形 (zeolite schema)。
    #   result_schema  : 結果の形 (zeolite schema)。シリアライズ可能な形に限る。
    #   run            : 実際に外界を叩く唯一のクロージャ。
    #                    ->(payload_hash) { raw_result_hash }
    #                    ここ以外で生の外界呼び出しをしない (pin port.no_direct_call)。
    # ================================================================
    Operation = Data.define(:tag, :payload_schema, :result_schema, :run)

    # ================================================================
    # Adapter — 「外界の一系統」を表す。扱う effect tag 群を宣言し、
    # 実行せず Effect を作る純粋側と、実際に外界を叩く handler 側の
    # 両方を提供する (darkcore の tagged effect + handler 差し替えの流儀)。
    # ================================================================
    class Adapter
      attr_reader :name, :operations

      def initialize(name)
        @name = name
        @operations = {} # tag => Operation
      end

      # tag を一つ宣言する。payload/result は zeolite schema。
      # &run が「実際に外界を叩く」唯一の場所。
      def operation(tag, payload:, result:, &run)
        raise Error, "run block required for #{tag}" unless run

        @operations[tag] = Operation.new(
          tag: tag, payload_schema: payload, result_schema: result, run: run
        )
        self
      end

      def tags = @operations.keys

      def operation_for(tag)
        @operations.fetch(tag) { raise UnknownTag, "#{name} は tag #{tag.inspect} を持たない" }
      end

      # ---- 純粋側: 実行せず Effect を作る ----------------------------
      # payload を schema で検証し、素の Hash に正規化してから
      # Darkcore.op(tag, payload) を返す。ここでは IO は一切起きない。
      # 返るのは走らせずに tag/payload を覗ける検査可能な Effect データ。
      def effect(tag, payload)
        op = operation_for(tag)
        normalized = Port.normalize(payload)
        checked = op.payload_schema.load(normalized)
        unless checked.ok?
          raise InvalidPayload,
                "#{name}##{tag} payload 不正: #{checked.violations.join('; ')}"
        end

        # Effect に載せるのは正規化済みの素データ (journal 記録可能)。
        Darkcore.op(tag, normalized)
      end

      # ---- 影側: handler map を作る ---------------------------------
      # interpret は ->(operation, payload_hash) { raw_result_hash }。
      # 生結果は必ず正規化 → result_schema.load を通し、型の付いた
      # zeolite 値にして返す。「どの圏で解釈するか」は interpret の
      # 差し替えだけで決まる (real / 記録用 fake / dry-run)。
      def handlers(&interpret)
        @operations.transform_values do |op|
          lambda do |payload|
            raw = interpret.call(op, payload)
            checked = op.result_schema.load(Port.normalize(raw))
            unless checked.ok?
              raise InvalidResult,
                    "#{name}##{op.tag} result 不正: #{checked.violations.join('; ')}"
            end

            checked.value
          end
        end
      end

      # 圏R — 本物の外界。run を呼ぶ唯一の入口。
      def real_handlers
        handlers { |op, payload| op.run.call(payload) }
      end
    end

    # ================================================================
    # Registry — adapter を登録し tag から引く。1 枚登録すれば全体で
    # 使い回せる形にすることで global_reuse (pin port.adapter_reusable)
    # を満たす。tag は一系統のみが握れる (衝突は登録時に弾く)。
    # ================================================================
    class Registry
      def initialize
        @by_name = {}
        @by_tag = {}
      end

      def register(adapter)
        adapter.tags.each do |tag|
          owner = @by_tag[tag]
          raise TagConflict, "tag #{tag.inspect} は既に #{owner.name} が所有" if owner && owner.name != adapter.name
        end
        @by_name[adapter.name] = adapter
        adapter.tags.each { |tag| @by_tag[tag] = adapter }
        adapter
      end

      def adapter(name)
        @by_name.fetch(name) { raise UnknownAdapter, "adapter #{name.inspect} は未登録" }
      end

      def for_tag(tag)
        @by_tag.fetch(tag) { raise UnknownTag, "tag #{tag.inspect} を握る adapter が無い" }
      end

      def tags = @by_tag.keys
      def names = @by_name.keys

      # tag から adapter を引いて Effect を作る (発見 → 生成を一手で)。
      def effect(tag, payload)
        for_tag(tag).effect(tag, payload)
      end

      # 全登録 adapter の real handler を一枚に畳む。Executor は
      # 単一 Effect 型の一枚の handler map として解釈できる
      # (pin port.effect_substrate: 語彙を分岐させない)。
      def real_handlers
        @by_name.values.reduce({}) { |acc, ad| acc.merge(ad.real_handlers) }
      end
    end

    # プロセス既定の registry。adapter は自分をここに register することで
    # 「1 枚書けば全体で使い回せる」を満たす。テストで隔離したい時は
    # Registry.new を各自で持てばよい。
    def registry
      @registry ||= Registry.new
    end

    def register(adapter) = registry.register(adapter)
    def for_tag(tag) = registry.for_tag(tag)
    def adapter(name) = registry.adapter(name)
    def effect(tag, payload) = registry.effect(tag, payload)
    def real_handlers = registry.real_handlers
  end
end

# 最初の 2 枚。読み込むだけで既定 registry に自分を登録する
# (require 行は lib/gear.rb を触らず自分の領分で完結させる)。
require_relative 'port/shell'
require_relative 'port/http'
require_relative 'port/time'
