# frozen_string_literal: true

module Gear
  module Executor
    # ==================================================================
    # Authority — 「渡された範囲を天井として judge する」だけを持つ。
    #
    # かつては有効な Kit をスタックで持っていたが、並列分岐 (berylx の &) は Thread で
    # 走るので共有スタックは枝どうしで壊れ、実測で「事実でない拒否」が根拠として
    # journal に載った。スタックをロックで守ると、こんどは子の fold をロック内で
    # 回すことになり恒久デッドロックした (監査で再現)。
    #
    # なので Kit は**動的スコープを持たない**。走行ごと・入れ子ごとに handler へ
    # 閉じ込めて渡す (Driver#handlers_for)。ここは状態を持たない judge だけ。
    #
    # 満たす pin (gear.spec):
    #   admission.policy_pluggable : 判定基準は policy として差し替えられる。
    #   authority.is_ceiling       : Kit は policy の外側へ AND で当たる天井。
    # ==================================================================
    class Authority
      def initialize(policy:)
        @policy = policy
      end

      # kit を渡した範囲の天井として当て、その内側で policy が絞る。
      # kit が nil なら policy だけ (既定のスタンスを gear 本体へ焼かない)。
      def judge(request, kit:)
        Admission.judge(request, policy: kit.nil? ? @policy : capped(kit))
      end

      private

      def capped(kit)
        Admission::Policy::All.new(Admission::Policy::ByKit.new(kit), @policy)
      end
    end
  end
end
