# frozen_string_literal: true

# WORKER SLOT: clock
# 実装はこのファイルと lib/gear/clock/ 配下に閉じること。
# 他ワーカーのファイルを触らない (並列分散の territory 境界)。
# require は lib/gear.rb を触らず自 slot 内で完結させる。
require_relative 'clock/seed'
require_relative 'clock/tick'
require 'zeolite'

module Gear
  # ==================================================================
  # Clock — gear の「時間を進める者」。run を開始し tick を単調に刻む。
  #
  # 満たす pin (gear.spec):
  #   tick.discrete         : #advance が離散した歩み (Tick) を返す。実時間で進めない。
  #   tick.total_order      : 同一 run の tick は index で全順序 (Tick#<=>)。
  #   tick.no_backflow      : advance は index を増やすだけ。過去 tick へ戻す API を
  #                           一切生やさない。返す Tick は frozen で書き戻せない。
  #   tick.seeded           : 乱数は (run seed, tick) 由来の seed からのみ導出する。
  #   tick.no_ambient_random: Kernel#rand / SecureRandom を Clock 内で呼ばない。
  #
  # 実時刻について:
  #   Clock は Time.now を直接呼ばない。実時刻が要る処理は「外界 port の結果」
  #   として W5(port)/W2(journal) が供給する前提であり (pin journal.records_
  #   external_results)、Clock 自身は外部入力を持たない純粋な時計として決定論を保つ。
  # ==================================================================
  class Clock
    ORIGIN_INDEX = 0 # まだ advance していない run の起点。最初の advance で 1 を返す。
    RANDOM_TAG = :clock_random
    RANDOM_PAYLOAD = Zeolite.schema(bound: :integer).named(:ClockRandomPayload)
    RANDOM_RESULT = Zeolite.schema(value: :integer).named(:ClockRandomResult)

    attr_reader :seed

    def initialize(seed:)
      # seed は明示必須。既定値を暗黙生成すると ambient RNG に依存してしまうため、
      # Integer 以外は受け付けない (pin tick.no_ambient_random)。
      raise ArgumentError, "seed は Integer で明示する (暗黙乱数を混ぜないため): #{seed.inspect}" unless seed.is_a?(Integer)

      @seed = seed
      @index = ORIGIN_INDEX
    end

    # まだ進んでいない現在の tick (起点は index 0)。副作用なし。
    def current
      Tick.new(run_seed: @seed, index: @index)
    end

    # tick を 1 つ進めて新しい Tick を返す。単調増加し、飛ばず、戻らない。
    def advance
      @index += 1
      current
    end
    alias tick advance # 名詞で呼びたい呼び出し側向けの別名。

    # 任意の Tick に対応する決定論乱数源。この Clock の run に属する tick だけ許す。
    def rng_for(tick)
      unless tick.is_a?(Tick) && tick.run_seed == @seed
        raise ArgumentError, "この run (seed=#{@seed}) に属さない tick からは乱数を導出しない: #{tick.inspect}"
      end

      tick.rng
    end
  end
end
