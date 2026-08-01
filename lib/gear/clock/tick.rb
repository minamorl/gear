# frozen_string_literal: true

module Gear
  class Clock
    # ==================================================================
    # Tick — 「どの run の第何 tick か」を持つ検査可能な immutable 値。
    #
    # pin tick.discrete    : tick は連続時間ではなく index という離散した歩み。
    # pin tick.total_order : 同一 run (= 同一 run_seed) の tick は index で
    #   全順序を持つ。Comparable で <=> を提供する。
    # pin tick.no_backflow : Data.define は生成後 frozen。index を書き換える
    #   手段を持たないので、値としての巻き戻しが起きない。
    #
    # run を跨いだ順序は「未定義」であって「等しくない」ではない。異なる
    # run_seed 同士の <=> は nil を返し、Comparable が ArgumentError を上げる。
    # ==================================================================
    Tick = Data.define(:run_seed, :index) do
      include Comparable

      # この tick に紐づく決定論乱数源。同じ (run_seed, index) からは必ず
      # 同じ Random が出る (pin tick.seeded)。プロセス RNG は使わない。
      def rng
        Random.new(Seed.derive(run_seed, index))
      end

      # 同一 run 内でだけ index の全順序を与える。run が違えば比較不能 (nil)。
      def <=>(other)
        return nil unless other.is_a?(Tick)
        return nil unless run_seed == other.run_seed

        index <=> other.index
      end

      def to_s
        "tick(run=#{run_seed}, index=#{index})"
      end
    end
  end
end
