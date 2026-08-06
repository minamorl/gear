# frozen_string_literal: true

require 'minitest/autorun'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# Gear::Machine — 投げ込まれた program を拾って走らせる実行機を実測で示す。
#
#   - 投げただけでは走らない (受付と走行が別)
#   - #step が 1 件拾って走らせ、走行ごとに独立した journal が残る
#   - 拾う 1 手そのものに receipt が出る (新しい門を作っていない)
#   - #drain が空になるまで拾う
#   - Kit が渡していない program は拾った時点で拒まれ、台帳に理由が残る
# ==================================================================
class GearMachineTest < Minitest::Test
  IN  = Zeolite.schema(n: :integer).named(:MachineIn)
  OUT = Zeolite.schema(n: :integer, doubled: :integer).named(:MachineOut)
  Ledger = Gear::Machine::Ledger

  def ports(calls)
    reg = Gear::Port::Registry.new
    reg.register(
      Gear::Port::Adapter.new(:probe).operation(:probe, payload: IN, result: OUT) do |payload|
        calls << payload['n']
        { 'n' => payload['n'], 'doubled' => payload['n'] * 2 }
      end
    )
    reg
  end

  def programs
    Gear::Program::Registry.new.register(
      name: :double,
      task: Berylx::Task[:double] { |lay, io| lay.put(:doubled, io.perform(:probe, { 'n' => lay[:n].fetch }).doubled) },
      input: IN, output: OUT
    )
  end

  def kit(depth: 1, allowed: %i[double])
    Gear::Kit.of(ports: %i[probe program_submit], programs: allowed, depth: depth)
  end

  def machine(calls = [])
    Gear::Machine.new(programs: programs, ports: ports(calls))
  end

  def test_submitting_does_not_run_anything
    m = machine(calls = [])
    ticket = m.submit(name: :double, focus: { 'n' => 2 }, kit: kit).ticket

    assert_empty calls, '投げただけでは外界を叩かない'
    assert_equal 1, m.pending
    assert_equal Ledger::ACCEPTED, m.state_of(ticket)
    assert_nil m.journal_for(ticket), 'まだ走行が無いので journal も無い'
  end

  def test_step_picks_one_up_and_runs_it
    m = machine(calls = [])
    ticket = m.submit(name: :double, focus: { 'n' => 2 }, kit: kit).ticket
    done = m.step

    assert_equal [2], calls, '拾ったら走る'
    assert_equal ticket, done.ticket
    assert_equal({ 'n' => 2, 'doubled' => 4 }, done.produced)
    assert_equal Ledger::COMPLETED, m.state_of(ticket)
    assert_equal 0, m.pending
  end

  def test_step_on_an_empty_intake_is_nil
    assert_nil machine.step
  end

  # 拾う 1 手そのものが admission を通り receipt を残す (門を増やしていない証拠)。
  def test_the_pickup_itself_leaves_a_receipt
    m = machine
    ticket = m.submit(name: :double, focus: { 'n' => 2 }, kit: kit).ticket
    outcome = m.step.outcome
    tags = outcome.receipts.map { |r| r.effect['tag'] }

    assert_includes tags, Gear::Program::SUBMIT_TAG.to_s, '拾った 1 手の receipt'
    assert_includes tags, 'probe', '子の効果の receipt'
    assert_equal outcome.journal, m.journal_for(ticket), '台帳は正本の journal を指す'
  end

  def test_each_run_gets_its_own_journal_and_seed
    m = machine
    first = m.submit(name: :double, focus: { 'n' => 2 }, kit: kit)
    second = m.submit(name: :double, focus: { 'n' => 3 }, kit: kit)
    m.drain

    refute_equal m.journal_for(first.ticket), m.journal_for(second.ticket)
    assert_equal 1, m.journal_for(first.ticket).port_results.size
    assert_equal 1, m.journal_for(second.ticket).port_results.size
    refute_equal first.seed, second.seed, '種は投入ごとに違う'
  end

  def test_drain_takes_everything_and_limit_stops_early
    m = machine(calls = [])
    3.times { |i| m.submit(name: :double, focus: { 'n' => i + 1 }, kit: kit) }

    assert_equal 2, m.drain(limit: 2).size
    assert_equal 1, m.pending
    assert_equal [1, 2], calls

    m.drain

    assert_equal 0, m.pending
    assert_equal [1, 2, 3], calls
  end

  def test_program_not_handed_down_is_refused_at_pickup
    m = machine(calls = [])
    ticket = m.submit(name: :double, focus: { 'n' => 2 }, kit: kit(allowed: %i[other])).ticket
    done = m.step

    assert_empty calls, '拒まれたら走らない'
    assert_predicate done, :denied?
    assert_equal Ledger::DENIED, m.state_of(ticket)
    assert_match(/program double は渡されていない/, m.ledger.for_ticket(ticket).last.payload['reason'])
  end

  def test_unregistered_program_does_not_ride_the_machine
    m = machine
    ticket = m.submit(name: :ghost, focus: { 'n' => 2 }, kit: kit(allowed: %i[ghost])).ticket
    done = m.step

    assert_instance_of Berylx::Err, done.outcome.result
    assert_equal Ledger::COMPLETED, m.state_of(ticket), '拒否ではなく走って Err で閉じた'
  end
end
