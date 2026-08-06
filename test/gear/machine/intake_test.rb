# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'gear'

# ==================================================================
# Gear::Machine::Intake — 投げ込まれる先を実測で示す。
#
#   - ticket は連番で、実時刻も乱数も使わない (同じ順で投げれば同じ ticket)
#   - 先に投げたものから拾える (FIFO)
#   - 受け付けただけでは走らない
#   - Kit は値として同行し、宣言は JSON を往復する
# ==================================================================
class GearMachineIntakeTest < Minitest::Test
  Intake = Gear::Machine::Intake

  def kit = Gear::Kit.of(ports: %i[probe program_submit], programs: %i[double], depth: 1)

  def test_tickets_are_sequential_and_reproducible
    first = Intake.new
    second = Intake.new
    names = %i[a b c]

    issued_first = names.map { |n| first.offer(name: n).ticket }
    issued_second = names.map { |n| second.offer(name: n).ticket }

    assert_equal [1, 2, 3], issued_first
    assert_equal issued_first, issued_second, '同じ順で投げれば同じ ticket (実時刻も乱数も使わない)'
    assert_equal 3, first.issued
  end

  def test_takes_in_the_order_offered
    intake = Intake.new
    intake.offer(name: :first)
    intake.offer(name: :second)

    assert_equal :first, intake.take.name
    assert_equal :second, intake.take.name
    assert_nil intake.take, '空なら nil'
    assert_predicate intake, :empty?
  end

  def test_offering_does_not_run_anything
    intake = Intake.new
    submission = intake.offer(name: :double, focus: { 'n' => 2 }, kit: kit)

    assert_equal 1, intake.size, '受け付けただけで列に残る'
    assert_equal :double, submission.name
    assert_equal({ 'n' => 2 }, submission.focus)
    assert_equal kit, submission.kit
  end

  def test_seed_defaults_to_the_ticket_number
    intake = Intake.new

    assert_equal 1, intake.offer(name: :a).seed
    assert_equal 7, intake.offer(name: :b, seed: 7).seed, '明示した種はそのまま'
  end

  def test_submission_to_h_is_json_safe
    intake = Intake.new
    hash = intake.offer(name: :double, focus: { 'n' => 2 }, kit: kit).to_h

    assert_equal 1, hash['ticket']
    assert_equal 'double', hash['name']
    assert_equal({ 'ports' => %w[probe program_submit], 'programs' => %w[double], 'depth' => 1 },
                 hash['kit'])
    assert_equal hash, JSON.parse(JSON.generate(hash)), 'JSON を往復しても同じ'
  end

  def test_pending_is_a_view_not_the_queue
    intake = Intake.new
    intake.offer(name: :a)
    intake.pending.clear

    assert_equal 1, intake.size, '観測用の写しを触っても列は動かない'
  end
end
