# frozen_string_literal: true

# WORKER SLOT: routine
# 実装はこのファイルと lib/gear/routine/ 配下に閉じること。
# 他ワーカーのファイルを触らない (並列分散の territory 境界)。

require 'json'

module Gear
  # ==================================================================
  # Routine — 履歴からルーチンへの逆変換 (spec: routine.*)。
  #
  # gear が御主人様に返す一番効く形は「やったことが、そのままルーチンになる」
  # こと。Effect は実行前はただのデータなので、journal を読み戻すと Task 列が
  # 復元できる。手で試行錯誤した操作列に名前を付ければ、それがそのまま
  # プログラムになる。Unix の history をパイプに変換する行為が、型付きで自動に
  # なる、という感じ。
  #
  # 満たす pin (gear.spec):
  #   routine.from_journal   : journal の receipt を読み戻して berylx Task 列へ復元する
  #                            (require gear.routine.origin = journal_replay_to_task)。
  #   routine.is_first_class : ルーチンは第一級の値 (Definition)。名前を付けて
  #                            シリアライズし保存・再読込できる (後付けの便利機能で
  #                            はなく gear の主要機能として扱う)。
  #   routine.same_gate      : 復元されたルーチンも通常 program と同じ経路を通る。
  #                            to_task が返すのは素の berylx Task 合成で、Executor で
  #                            走ると admission を通り receipt を出す。ルーチン化した
  #                            からといって admission を迂回できてはならない —— ここは
  #                            「ゲートを持たない別経路」を一切作らないことで守る。
  #   program.representation : 復元先は berylx Task。gear 独自 DSL を作らない。
  #
  # なぜ receipt から起こすのか:
  #   実際に「起きた」効果 (= admission を通って実行された効果) だけが receipt を
  #   持つ。拒否された効果は実行されていないので routine に含めない —— routine は
  #   「実際にやったこと」の再構成だから。receipt の effect 要約は tag と payload の
  #   両方を持つので、perform を一つ復元するのにちょうど足りる。
  # ==================================================================
  module Routine
    # パラメータの「穴」を表す予約キー。payload の値が { HOLE => name } の形の
    # とき、それは名前 name の引数への差し込み口を意味する。実在の payload キーと
    # 衝突しないよう $ 始まりにする (JSON でそのまま持ち運べる)。
    HOLE = '$gear_param'

    module_function

    # journal (またはその一部区間) を読み、名前付きの Routine::Definition へ復元する。
    #
    #   journal : Journal::Log。走行で追記された正本。
    #   name    : ルーチンの名前 (String/Symbol)。
    #   ticks   : 残す tick の Range/集合。nil なら全区間。
    #   tags    : 残す tag の集合 (Symbol/String)。nil なら全 tag。
    #
    # ticks / tags で「試行錯誤の記録から使う部分だけ」を切り出せる
    # (抽出範囲を選べること)。
    def from_journal(journal, name:, ticks: nil, tags: nil)
      tag_set = tags && Array(tags).map(&:to_s)
      steps = journal.each_with_object([]) do |entry, acc|
        next unless entry.kind == :receipt
        next if ticks && !ticks.include?(entry.tick)

        effect = fetch_any(entry.payload, :effect)
        step = Step.from_effect(entry.tick, effect)
        next if tag_set && !tag_set.include?(step.tag)

        acc << step
      end
      Definition.new(name: name.to_s, steps: steps)
    end

    # シリアライズ済みルーチンを読み戻す (Hash / JSON 文字列どちらでも)。
    def load(source)
      from_h(source.is_a?(String) ? JSON.parse(source) : source)
    end

    def from_h(hash)
      name = hash['name'] || hash[:name]
      raw_steps = hash['steps'] || hash[:steps] || []
      Definition.new(name: name.to_s, steps: raw_steps.map { |s| Step.from_h(s) })
    end

    # ---- 穴あけ / 穴埋めの純関数 ------------------------------------

    # payload の中の穴 ({ HOLE => name }) を実引数 params[name] で埋めて返す。
    # 穴でない値はそのまま。ネストしていても再帰的に埋める。
    def substitute(value, params)
      case value
      when Hash
        return fetch_param(value[HOLE], params) if hole?(value)

        value.transform_values { |v| substitute(v, params) }
      when Array
        value.map { |v| substitute(v, params) }
      else
        value
      end
    end

    # payload に使われている穴の名前を列挙する (重複可・順序そのまま)。
    def hole_names(value)
      case value
      when Hash
        return [value[HOLE]] if hole?(value)

        value.values.flat_map { |v| hole_names(v) }
      when Array
        value.flat_map { |v| hole_names(v) }
      else
        []
      end
    end

    def hole?(value)
      value.is_a?(Hash) && value.size == 1 && value.key?(HOLE)
    end

    def fetch_param(name, params)
      params.fetch(name) do
        params.fetch(name.to_s) { raise ArgumentError, "ルーチン引数が渡されていない: #{name}" }
      end
    end

    # Symbol / String どちらのキーでも引ける (in-memory receipt.to_h は Symbol、
    # NDJSON 復元後は String)。
    def fetch_any(hash, key)
      hash.fetch(key) { hash.fetch(key.to_s) { hash.fetch(key.to_sym) } }
    end
  end
end

require_relative 'routine/step'
require_relative 'routine/definition'
