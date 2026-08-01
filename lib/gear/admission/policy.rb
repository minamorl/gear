# frozen_string_literal: true

module Gear
  module Admission
    # ==================================================================
    # Policy — 判定基準の差し替え点 (spec: admission.policy_pluggable)。
    #
    # インターフェースは duck typing:  #judge(request) -> Verdict (Admitted/Denied)。
    # gear 本体には特定ドメインの判定基準を一切焼き込まない
    # (spec: admission.no_hardcoded_domain)。ゲーム / 知識 / 結衣 の差は、
    # ここに差し込む policy の差として表す。ドメイン固有ルールの実体は
    # 利用側 (乗客ドメイン) が持ち、lib には汎用のスタンスと合成器だけを置く。
    # ==================================================================
    module Policy
      # ----------------------------------------------------------------
      # 既定許可スタンス。どの request も同じに許可する汎用 policy。
      # tag / payload の中身を見ない = ドメイン固有ルールではない。
      # 「既定でどちらか」を gear 本体に焼かず policy 側の選択にするための駒
      # (これを合成に混ぜるかどうかは利用側が決める)。
      # ----------------------------------------------------------------
      class AllowAll
        def judge(request)
          Verdict.admit(request, grounds: [Grant.new(policy: :allow_all, detail: '既定許可スタンス')])
        end
      end

      # ----------------------------------------------------------------
      # 既定拒否スタンス。どの request も同じに拒否する汎用 policy。
      # AllowAll の対。安全側の既定を選びたい利用側が使う。
      # ----------------------------------------------------------------
      class DenyAll
        def judge(request)
          Verdict.deny(request, reason: '既定拒否スタンス', by: :deny_all)
        end
      end

      # ----------------------------------------------------------------
      # AND 合成。全 policy が許可したときのみ許可し、1 つでも拒否したら
      # 全体が拒否 (拒否した policy の Denied をそのまま返すので、根拠は
      # 実際に拒否した rule を指す)。許可時は各 policy の grounds を積む。
      #
      # 空合成は許さない (raise): 「policy 0 個なら既定でどうする」を発明せず、
      # 既定スタンス (AllowAll / DenyAll) を明示的に混ぜる選択を利用側へ返す。
      # ----------------------------------------------------------------
      class All
        def initialize(*policies)
          raise ArgumentError, 'All には最低 1 つの policy が要る (既定を発明しない)' if policies.empty?

          @policies = policies
        end

        def judge(request)
          grounds = []
          @policies.each do |policy|
            verdict = policy.judge(request)
            return verdict if verdict.denied? # 最初の拒否で全体拒否。

            grounds.concat(verdict.grounds)
          end
          Verdict.admit(request, grounds: grounds)
        end
      end
    end
  end
end
