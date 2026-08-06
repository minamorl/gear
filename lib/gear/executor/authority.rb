# frozen_string_literal: true

module Gear
  module Executor
    # ==================================================================
    # Authority — 「いま誰の権限で判じるか」を握る。
    #
    # Driver から切り出した。走行は Kit を細めて子へおろすので、有効な権限は走行の
    # 途中で入れ替わる (入れ子の深さぶんのスタックになる)。時間を進める責務と
    # 権限を差し替える責務は別物なので、後者だけをここへ閉じる。
    #
    # 満たす pin (gear.spec):
    #   admission.policy_pluggable : 判定基準は policy として差し替えられる。
    #   admission.precedes_effect  : #judge が効果の手前で呼ばれる唯一の口。
    #   Kit は「渡した範囲」の天井として policy の外側へ AND で当たる。policy は
    #   その内側で更に絞れるが、緩めることはできない。Kit 無しなら policy だけ
    #   (既定のスタンスを gear 本体へ焼かない = no_hardcoded_domain)。
    # ==================================================================
    class Authority
      def initialize(policy:, kit: nil)
        @policy = policy
        @kits = [kit] # 有効な Kit のスタック。submit で細めて積む
      end

      # いま有効な Kit。子へおろす元になる。
      def current_kit = @kits.last

      # 一段細めた Kit の下で block を走らせる。抜けたら必ず元へ戻す。
      def descend
        @kits.push(current_kit&.descend)
        yield(current_kit)
      ensure
        @kits.pop
      end

      def judge(request)
        Admission.judge(request, policy: effective_policy)
      end

      private

      def effective_policy
        kit = current_kit
        return @policy if kit.nil?

        Admission::Policy::All.new(Admission::Policy::ByKit.new(kit), @policy)
      end
    end
  end
end
