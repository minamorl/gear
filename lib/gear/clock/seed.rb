# frozen_string_literal: true

module Gear
  class Clock
    # ==================================================================
    # Seed — (run seed, tick index) から per-tick seed を導出する純粋関数。
    #
    # pin tick.seeded         : 非決定の源はここで導出した seed からのみ取る。
    # pin tick.no_ambient_random: Kernel#rand / SecureRandom 等プロセス由来の
    #   暗黙乱数を一切呼ばない。derive は入力だけに依存する純関数なので、
    #   同じ (run seed, index) からは必ず同じ seed が出る (= 決定論の土台)。
    #
    # 混ぜ方は splitmix64。暗号強度は要らない (乱数の質ではなく再現性が要件)。
    # ==================================================================
    module Seed
      MASK64 = 0xFFFF_FFFF_FFFF_FFFF
      GOLDEN = 0x9E37_79B9_7F4A_7C15 # splitmix64 の黄金比定数

      # 1 語を撹拌する splitmix64 の finalizer。
      def self.mix(x)
        x = ((x ^ (x >> 30)) * 0xBF58_476D_1CE4_E5B9) & MASK64
        x = ((x ^ (x >> 27)) * 0x94D0_49BB_1331_11EB) & MASK64
        (x ^ (x >> 31)) & MASK64
      end

      # run seed と tick index を独立に撹拌してから合流させる。
      # index が隣り合っても導出 seed は無相関になる。
      def self.derive(run_seed, index)
        a = mix(((run_seed & MASK64) + GOLDEN) & MASK64)
        b = mix(((index & MASK64) + GOLDEN + a) & MASK64)
        mix(a ^ b)
      end
    end
  end
end
