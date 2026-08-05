# frozen_string_literal: true

require 'minitest/autorun'
# Clock は darkcore/berylx や他 slot に依存しない純粋な時計。
# 予約乱数効果の境界形だけは zeolite schema で宣言する。
# それを担保するため 'gear' 全体ではなく clock だけを読み込む。
require 'gear/clock'

module Gear
  class ClockTest < Minitest::Test
    # --- pin tick.discrete / tick.total_order --------------------------------
    # tick は index という離散した歩みで、単調増加し・飛ばず・戻らない。
    def test_advance_is_monotonic_and_gapless
      clock = Clock.new(seed: 42)

      indices = Array.new(5) { clock.advance.index }

      assert_equal [1, 2, 3, 4, 5], indices
    end

    def test_current_starts_at_origin_and_does_not_advance
      clock = Clock.new(seed: 1)

      assert_equal 0, clock.current.index
      assert_equal 0, clock.current.index # current は副作用を持たない
      assert_equal 1, clock.advance.index
    end

    # 同一 run の tick は index で全順序を持つ (Comparable)。
    def test_ticks_have_total_order_within_a_run
      clock = Clock.new(seed: 7)
      t1 = clock.advance
      t2 = clock.advance
      t3 = clock.advance

      assert_operator t1, :<, t2
      assert_operator t2, :<, t3
      assert_equal [t1, t2, t3], [t3, t1, t2].sort
    end

    # run を跨いだ順序は「未定義」であって比較すると失敗する (等しくない、ではない)。
    def test_cross_run_ticks_are_not_ordered
      a = Clock.new(seed: 1).advance
      b = Clock.new(seed: 2).advance

      assert_raises(ArgumentError) { a < b }
    end

    # --- pin tick.seeded -----------------------------------------------------
    # 同一 seed の 2 つの Clock は同一の tick 列と同一の乱数列を生む。
    def test_same_seed_reproduces_ticks_and_randomness
      a = Clock.new(seed: 12_345)
      b = Clock.new(seed: 12_345)

      10.times do
        ta = a.advance
        tb = b.advance

        assert_equal ta, tb # Tick は値等価 (Data)
        assert_equal draw(ta.rng), draw(tb.rng)
      end
    end

    # 同じ (run seed, tick) からは何度導出しても同じ乱数列が出る。
    def test_rng_is_a_deterministic_function_of_run_seed_and_tick
      clock = Clock.new(seed: 999)
      tick = clock.advance

      assert_equal draw(tick.rng), draw(tick.rng)
      assert_equal draw(tick.rng), draw(clock.rng_for(tick))
    end

    # 異なる seed では乱数列が変わる。
    def test_different_seed_changes_randomness
      a = Clock.new(seed: 1).advance
      b = Clock.new(seed: 2).advance

      refute_equal draw(a.rng), draw(b.rng)
    end

    # 同一 run 内でも tick が違えば乱数列が変わる (per-tick seed であること)。
    def test_randomness_differs_across_ticks
      clock = Clock.new(seed: 555)
      t1 = clock.advance
      t2 = clock.advance

      refute_equal draw(t1.rng), draw(t2.rng)
    end

    # --- pin tick.no_ambient_random ------------------------------------------
    # seed は明示必須。暗黙の既定 seed (プロセス由来乱数) を作らない。
    def test_seed_must_be_an_explicit_integer
      assert_raises(ArgumentError) { Clock.new(seed: 'x') }
      assert_raises(ArgumentError) { Clock.new(seed: nil) }
      assert_raises(ArgumentError) { Clock.new(seed: 1.5) }
    end

    def test_foreign_tick_is_rejected_by_rng_for
      clock = Clock.new(seed: 1)
      foreign = Clock.new(seed: 2).advance

      assert_raises(ArgumentError) { clock.rng_for(foreign) }
    end

    # --- pin tick.no_backflow ------------------------------------------------
    # 過去 tick へ戻す API が存在しない。Tick 値も frozen で書き戻せない。
    def test_no_rewind_api_exists
      clock = Clock.new(seed: 1)

      refute_respond_to clock, :rewind
      refute_respond_to clock, :reset
      refute_respond_to clock, :index=
      refute_respond_to clock, :advance_to
    end

    def test_tick_values_are_frozen
      tick = Clock.new(seed: 1).advance

      assert_predicate tick, :frozen?
    end

    private

    # rng から決定論的に数列を引く小道具 (列で比べれば偶然一致を排除できる)。
    def draw(rng, count = 8)
      Array.new(count) { rng.rand(1_000_000) }
    end
  end
end
