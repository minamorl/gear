# frozen_string_literal: true

require 'minitest/autorun'
require 'gear'

# ==================================================================
# Gear::Kit — program へおろす権限セットを実測で示す。
#
#   - 宣言データであって生オブジェクトではない (JSON-safe / 往復する)
#   - 細めることしかできない (広げる要求は交差で落ちる)
#   - descend で深さが 1 段減り、0 で止まる (無限入れ子を構造で止める)
# ==================================================================
class GearKitTest < Minitest::Test
  Kit = Gear::Kit

  def full = Kit.of(ports: %i[shell http], programs: %i[fetch parse], depth: 2)

  def test_of_normalizes_names_and_dedupes
    grant = Kit.of(ports: ['http', :shell, 'http'])

    assert_equal %i[http shell], grant.ports
    assert_equal [], grant.programs
    assert_equal 0, grant.depth
  end

  def test_nothing_grants_nothing
    assert_equal [], Kit.nothing.ports
    refute_predicate Kit.nothing, :submit?
    refute Kit.nothing.port?(:shell)
  end

  def test_negative_depth_is_refused
    assert_raises(ArgumentError) { Kit.of(depth: -1) }
  end

  def test_membership_queries
    assert full.port?(:shell)
    assert full.port?('shell'), 'String でも引ける'
    refute full.port?(:db)
    assert full.program?(:fetch)
    assert_predicate full, :submit?
  end

  def test_submit_requires_both_depth_and_programs
    refute_predicate Kit.of(programs: %i[fetch], depth: 0), :submit?, '深さが尽きたら繋げない'
    refute_predicate Kit.of(ports: %i[shell], depth: 3), :submit?, '相手が居なければ繋げない'
  end

  def test_narrow_can_only_intersect
    narrowed = full.narrow(ports: %i[shell db], programs: %i[fetch other], depth: 9)

    assert_equal %i[shell], narrowed.ports, '持っていない db は増えない'
    assert_equal %i[fetch], narrowed.programs
    assert_equal 2, narrowed.depth, '深さも広がらない'
  end

  def test_narrow_without_arguments_keeps_the_set
    assert_equal full, full.narrow
  end

  def test_descend_spends_one_level_and_floors_at_zero
    child = full.descend

    assert_equal 1, child.depth
    assert_equal 0, child.descend.depth
    assert_equal 0, child.descend.descend.depth, '0 より下へ行かない'
  end

  def test_descend_can_narrow_at_the_same_time
    child = full.descend(ports: %i[shell])

    assert_equal %i[shell], child.ports
    assert_equal 1, child.depth
  end

  def test_to_h_is_json_safe_and_round_trips
    hash = full.to_h

    assert_equal({ 'ports' => %w[http shell], 'programs' => %w[fetch parse], 'depth' => 2 }, hash)
    assert_equal full, Kit.from_h(hash)
    assert_equal full, Kit.from_h(JSON.parse(JSON.generate(hash))), 'JSON を往復しても同じ'
  end

  # ---- Kit の執行側: 渡した port だけを許す ----
  def by_kit(kit) = Gear::Admission::Policy::ByKit.new(kit)
  def request(tag) = Gear::Admission::Request.new(tag: tag, payload: {})

  def test_by_kit_admits_a_handed_down_port
    verdict = by_kit(full).judge(request(:shell))

    assert_predicate verdict, :admitted?
    assert_equal [:by_kit], verdict.grounds.map(&:policy)
  end

  def test_by_kit_denies_a_port_that_was_not_handed_down
    verdict = by_kit(full).judge(request(:db))

    assert_predicate verdict, :denied?
    assert_equal :by_kit, verdict.by
    assert_match(/渡されていない/, verdict.reason)
  end

  def test_by_kit_on_nothing_denies_everything
    assert_predicate by_kit(Kit.nothing).judge(request(:shell)), :denied?
  end

  def test_by_kit_composes_with_and
    both = Gear::Admission::Policy::All.new(by_kit(full), Gear::Admission::Policy::AllowAll.new)

    assert_predicate both.judge(request(:shell)), :admitted?
    assert_predicate both.judge(request(:db)), :denied?, 'AND なので Kit の外は通らない'
  end
end
