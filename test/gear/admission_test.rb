# frozen_string_literal: true

require 'minitest/autorun'
require 'gear'

class GearAdmissionTest < Minitest::Test
  include Gear

  # ----------------------------------------------------------------
  # テスト専用のドメイン固有 policy。
  # こういう「tag を見て可否を決める」ルールは lib には置かず、乗客ドメインが
  # 持つ (spec: admission.no_hardcoded_domain)。ここでは test の中だけに置く。
  # ----------------------------------------------------------------
  class TagAllowlist
    def initialize(*allowed)
      @allowed = allowed
    end

    def judge(request)
      if @allowed.include?(request.tag)
        Gear::Admission::Verdict.admit(
          request,
          grounds: [Gear::Admission::Grant.new(policy: :tag_allowlist, detail: "#{request.tag} は許可リストにある")]
        )
      else
        Gear::Admission::Verdict.deny(request, reason: "#{request.tag} は許可リストに無い", by: :tag_allowlist)
      end
    end
  end

  def shell_request
    # darkcore の Effect (実行前のただのデータ) から request を起こす。
    Admission::Request.from_effect(Darkcore.op(:shell, { cmd: 'ls' }))
  end

  # request は実行前の Effect ノードから作れ、走らせずに tag/payload を覗ける。
  def test_request_is_built_from_effect_node_and_inspectable
    request = shell_request

    assert_equal :shell, request.tag
    assert_equal({ cmd: 'ls' }, request.payload)
  end

  # pluggable の実測: policy を差し替えると同じ request の判定が変わる。
  def test_policy_is_pluggable_same_request_different_verdict
    request = shell_request

    admitted = Admission.judge(request, policy: Admission::Policy::AllowAll.new)
    denied   = Admission.judge(request, policy: Admission::Policy::DenyAll.new)

    assert_predicate admitted, :admitted?
    assert_predicate denied, :denied?
    assert_equal request, admitted.request
  end

  # 拒否は例外ではなく値として返る (assert_raises ではなく戻り値の検査)。
  def test_denial_is_a_value_not_an_exception
    verdict = Admission.judge(shell_request, policy: Admission::Policy::DenyAll.new)

    assert_instance_of Admission::Denied, verdict
    assert_predicate verdict, :denied?
    refute_predicate verdict, :admitted?
    assert_equal '既定拒否スタンス', verdict.reason
    assert_equal :deny_all, verdict.by
  end

  # Admitted / Denied のどちらも根拠を持つ。
  def test_both_verdicts_carry_grounds
    admitted = Admission.judge(shell_request, policy: TagAllowlist.new(:shell))
    denied   = Admission.judge(shell_request, policy: TagAllowlist.new(:http))

    # 許可の grounds: 何が許可したかを辿れる (receipt の根拠鎖の起点)。
    refute_empty admitted.grounds
    assert_equal :tag_allowlist, admitted.grounds.first.policy

    # 拒否の根拠: 理由と、どの rule が拒否したか。
    assert_equal :tag_allowlist, denied.by
    refute_empty denied.reason
    assert_equal :tag_allowlist, denied.grounds.first.policy
  end

  # policy 合成: 1 つでも拒否したら全体が拒否。
  def test_composition_denies_if_any_policy_denies
    request = shell_request

    both_admit = Admission::Policy::All.new(
      Admission::Policy::AllowAll.new,
      TagAllowlist.new(:shell)
    )
    one_denies = Admission::Policy::All.new(
      Admission::Policy::AllowAll.new,
      TagAllowlist.new(:http) # shell は許可リストに無い → 拒否
    )

    admitted = Admission.judge(request, policy: both_admit)
    denied   = Admission.judge(request, policy: one_denies)

    assert_predicate admitted, :admitted?
    # 両 policy の grounds が積まれている。
    assert_equal 2, admitted.grounds.length

    assert_predicate denied, :denied?
    # 根拠は実際に拒否した rule を指す (AllowAll ではなく TagAllowlist)。
    assert_equal :tag_allowlist, denied.by
  end

  # 空合成は既定を発明せず raise する ("policy 0 個ならどうするか" を焼かない)。
  def test_empty_composition_refuses_to_invent_a_default
    assert_raises(ArgumentError) { Admission::Policy::All.new }
  end

  # lib 側にドメイン固有ルールが無い:
  #  (1) policy は必須。未指定では gear 本体が判断せず ArgumentError になる。
  #  (2) lib の汎用スタンスは tag/payload を見ない (どの tag でも一様)。
  def test_no_hardcoded_domain_rules_in_lib
    # (1) policy 未指定 → gear 本体は判断を持たない。
    assert_raises(ArgumentError) { Admission.judge(shell_request) }

    # (2) AllowAll / DenyAll は request の中身に依らず一様に判定する。
    #     tag を変えても結果が変わらない = ドメイン判断が焼かれていない。
    http_request = Admission::Request.from_effect(Darkcore.op(:http, { url: 'x' }))

    assert_predicate Admission.judge(shell_request, policy: Admission::Policy::AllowAll.new), :admitted?
    assert_predicate Admission.judge(http_request,  policy: Admission::Policy::AllowAll.new), :admitted?
    assert_predicate Admission.judge(shell_request, policy: Admission::Policy::DenyAll.new), :denied?
    assert_predicate Admission.judge(http_request,  policy: Admission::Policy::DenyAll.new), :denied?
  end

  # judge_effect: Effect ノードを直接ゲートに通せる (実行前検査)。
  def test_judge_effect_gates_a_darkcore_effect_node
    effect = Darkcore.op(:shell, { cmd: 'ls' })

    verdict = Admission.judge_effect(effect, policy: TagAllowlist.new(:shell))

    assert_predicate verdict, :admitted?
    assert_equal :shell, verdict.request.tag
  end
end
