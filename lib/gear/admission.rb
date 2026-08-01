# frozen_string_literal: true

# WORKER SLOT: admission
# 実装はこのファイルと lib/gear/admission/ 配下に閉じること。
# 他ワーカーのファイルを触らない (並列分散の territory 境界)。

require_relative 'admission/request'
require_relative 'admission/verdict'
require_relative 'admission/policy'

module Gear
  # ==================================================================
  # Admission — 全ての副作用の前に立つゲート (spec: admission.*)。
  #
  # 実行前に必ずここを通す (admission.precedes_effect)。通らない副作用の
  # 抜け道は作らない (admission.no_bypass): judge は policy を必須で取り、
  # policy 抜きに Admitted を返す経路は存在しない。判定は policy に委ね
  # (admission.policy_pluggable)、gear 本体は特定ドメインの基準を持たない
  # (admission.no_hardcoded_domain)。結果は Admitted / Denied の値であって
  # 例外ではない (admission.denial_is_value)。
  #
  # judge が返す Verdict (特に Admitted#grounds) が、後段で実行された副作用の
  # receipt が参照する「何が許可したか」の根拠になる (receipt.carries_grounds)。
  # ==================================================================
  module Admission
    module_function

    # request を policy に判定させ、Verdict (Admitted / Denied) を返す。
    # policy はキーワード必須 —— 既定 policy を持たないことが、gear 本体が
    # ドメイン判断を焼き込まない (no_hardcoded_domain) ことの実装上の担保。
    def judge(request, policy:)
      policy.judge(request)
    end

    # darkcore の Effect ノードを直接判定するショートカット。
    # 実行前の Effect (tag / payload) から request を起こしてゲートに通す。
    def judge_effect(effect, policy:)
      judge(Request.from_effect(effect), policy: policy)
    end
  end
end
