# frozen_string_literal: true

require 'berylx'

module Gear
  module Routine
    # ==================================================================
    # Definition — 名前の付いた Step 列。これが「ルーチン」の実体。
    #
    # 手で試した操作列 (journal) に名前を付けたものがこれ。第一級の値として
    # 持ち回せ、シリアライズして残せ、そのまま program として走る
    # (pin routine.is_first_class / routine.from_journal)。
    #
    # 満たす pin (gear.spec):
    #   routine.from_journal  : Step は journal の receipt から起こす (Routine.from_journal)。
    #   routine.is_first_class: Definition は普通の値。to_h/dump で名前ごと保存できる。
    #   routine.same_gate     : to_task が返すのは素の berylx Task 合成。復元された
    #                           ルーチンも通常 program と同じく Executor で走り、同じ
    #                           admission ゲートを通り、同じ receipt を出す。迂回路は無い。
    #   program.representation : 復元先は berylx Task。gear 独自 DSL を作らない。
    #
    # immutable: parameterize / slice は新しい Definition を返す (Data#with)。
    # ==================================================================
    Definition = Data.define(:name, :steps) do
      # ---- 実行対象へ: berylx Task 合成に載せ替える --------------------
      # 各 Step を「効果を一つ踏んで結果を focus に残す」Task にし、`>>` で
      # 直列に綴じる。返すのは素の berylx ノードなので、Executor.run にそのまま
      # 渡せば通常 program と同一の経路 (admission → 実行 → receipt) を通る。
      #
      #   params : 穴 (parameterize で開けた箇所) を埋める実引数。
      #            { name => value }。String/Symbol どちらのキーでも受ける。
      def to_task(params = {})
        bound = params.transform_keys(&:to_s)
        missing = self.params - bound.keys
        raise ArgumentError, "ルーチン #{name} の引数が足りない: #{missing.join(', ')}" unless missing.empty?

        tasks = steps.each_with_index.map { |step, i| step_task(step, i, bound) }
        compose(tasks)
      end

      # 復元したルーチンをそのまま走らせる薄い便宜口。to_task して Executor へ
      # 渡すだけ (同じゲートを通ることを API の形でも示す)。
      def run(policy:, seed:, params: {}, **opts)
        Executor.run(to_task(params), policy: policy, seed: seed, **opts)
      end

      # ---- パラメータ化: payload の一部を穴に持ち上げる ----------------
      # 一度きりの再生を「引数で振る舞いが変わるルーチン」にするための最小限の
      # 穴あけ。指定した payload キーを、名前付きの穴 (Routine::HOLE を持つ Hash)
      # に置き換える。to_task 時に実引数で埋める。
      #
      #   bindings : { param_name => locator }
      #   locator の形:
      #     'cmd'                     — payload キー 'cmd' を持つ全 Step を対象。
      #     { key:, step:, tag: }     — key を、step index / tag で絞って対象化。
      def parameterize(bindings)
        new_steps = steps.each_with_index.map do |step, i|
          payload = step.payload
          bindings.each do |param_name, locator|
            payload = apply_hole(payload, param_name.to_s, locator, i, step.tag)
          end
          step.with(payload: payload)
        end
        with(steps: new_steps)
      end

      # ---- 抽出範囲の絞り込み (from_journal 後の後付けでも切れる) -------
      #   ticks : 残す tick の Range/集合。
      #   tags  : 残す tag の集合 (Symbol/String どちらでも)。
      def slice(ticks: nil, tags: nil)
        tag_set = tags && Array(tags).map(&:to_s)
        kept = steps.select do |step|
          (ticks.nil? || ticks.include?(step.tick)) &&
            (tag_set.nil? || tag_set.include?(step.tag))
        end
        with(steps: kept)
      end

      # 必要な引数名 (穴に使われている名前) を昇順で。穴が無ければ空。
      def params
        steps.flat_map { |step| Routine.hole_names(step.payload) }.uniq.sort
      end

      def parameterized? = !params.empty?

      # ---- シリアライズ: 名前を付けて残す / 読み戻す ------------------
      def to_h
        { 'name' => name, 'steps' => steps.map(&:to_h) }
      end

      def dump = JSON.generate(to_h)

      private

      # Step 一つを効果 Task にする。tag は Symbol へ戻し (registry の tag に一致
      # させる)、穴は実引数で埋めてから perform する。結果は focus に残しておく
      # (走行の観測点)。効果の発火そのものは Executor のゲートが握るので、ここは
      # 「どの tag をどの payload で踏むか」だけを宣言する純データに近い。
      def step_task(step, index, params)
        tag = step.tag.to_sym
        payload = Routine.substitute(step.payload, params)
        slot = :"#{name}_#{index}"
        Berylx::Task[:"#{name}_#{index}"] do |lay, io|
          result = io.perform(tag, payload)
          lay.put(slot, result)
        end
      end

      # Task 列を berylx の直列合成へ。空ルーチンは「何もしない」Task に落とす
      # (抽出で 0 歩になっても壊れないように)。
      def compose(tasks)
        return Berylx::Task[:"#{name}_empty"] { |lay| lay } if tasks.empty?

        tasks.reduce { |acc, task| acc >> task }
      end

      # locator に一致する Step の payload キーを穴に置換して返す (不一致なら素通り)。
      def apply_hole(payload, param_name, locator, index, tag)
        loc = locator.is_a?(Hash) ? locator.transform_keys(&:to_sym) : { key: locator }
        return payload unless loc[:step].nil? || loc[:step] == index
        return payload unless loc[:tag].nil? || loc[:tag].to_s == tag

        key = loc.fetch(:key).to_s
        return payload unless payload.is_a?(Hash) && payload.key?(key)

        payload.merge(key => { Routine::HOLE => param_name })
      end
    end
  end
end
