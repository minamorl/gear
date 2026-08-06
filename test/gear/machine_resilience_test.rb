# frozen_string_literal: true

require 'minitest/autorun'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# Machine の縦の実測 — 御主人様の像に届いたかどうかの 2 本。
#
#   1. ずっと回っているループへ投げっぱなしにすると、勝手に拾って走る
#      (「ヘリコプターで拾う」が機能していること)
#   2. 機械を捨てて作り直しても、台帳の journal から続けて同じ receipt 列へ至る
#      (常駐にしても正本は journal のままで、機械はただの殻であること)
# ==================================================================
class GearMachineResilienceTest < Minitest::Test
  IN  = Zeolite.schema(n: :integer).named(:ResIn)
  OUT = Zeolite.schema(n: :integer, doubled: :integer).named(:ResOut)
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

  def once_task
    Berylx::Task[:double] do |lay, io|
      lay.put(:doubled, io.perform(:probe, { 'n' => lay[:n].fetch }).doubled)
    end
  end

  def twice_task
    Berylx::Task[:twice] do |lay, io|
      once = io.perform(:probe, { 'n' => lay[:n].fetch }).doubled
      lay.put(:doubled, io.perform(:probe, { 'n' => once }).doubled)
    end
  end

  def programs
    Gear::Program::Registry.new
                           .register(name: :double, task: once_task, input: IN, output: OUT)
                           .register(name: :twice, task: twice_task, input: IN, output: OUT)
  end

  def kit(name)
    Gear::Kit.of(ports: %i[probe program_submit], programs: [name], depth: 1)
  end

  def machine(calls, ledger: Ledger.new, intake: Gear::Machine::Intake.new)
    Gear::Machine.new(programs: programs, ports: ports(calls), ledger: ledger, intake: intake)
  end

  # ---- 1. 回っているループへ投げっぱなしにすると勝手に拾って走る ----
  def test_a_running_loop_picks_up_whatever_is_thrown_at_it
    m = machine(calls = [])
    wanted = 5
    driver = Thread.new do
      got = []
      spins = 0
      while got.size < wanted && (spins += 1) < 1_000_000
        completion = m.step
        completion ? got << completion : Thread.pass
      end
      got
    end

    wanted.times { |i| m.submit(name: :double, focus: { 'n' => i + 1 }, kit: kit(:double)) }
    picked = driver.value

    assert_equal wanted, picked.size, '回っているループが投げられたものを全部拾った'
    assert_equal [1, 2, 3, 4, 5], calls.sort, '全件が実際に外界を叩いた'
    assert_equal (1..wanted).to_a, picked.map(&:ticket), '投げた順に拾った'
    assert(picked.none?(&:suspended?), '中断せず走り切った')
    assert_equal 0, m.pending
  end

  # ---- 2. 機械を捨てて作り直しても同じ receipt 列へ至る ----
  def test_a_rebuilt_machine_resumes_to_the_same_receipts
    ledger = Ledger.new
    intake = Gear::Machine::Intake.new

    # 走らせきった基準線を別の機械で採る。
    baseline_machine = machine(baseline_calls = [])
    baseline_machine.submit(name: :twice, focus: { 'n' => 2 }, kit: kit(:twice))
    baseline = baseline_machine.step

    assert_equal [2, 4], baseline_calls

    # 1 台目: 拾って途中で止める。
    first = machine(first_calls = [], ledger: ledger, intake: intake)
    ticket = first.submit(name: :twice, focus: { 'n' => 2 }, kit: kit(:twice)).ticket

    assert_predicate first.step(max_effects: 2), :suspended?
    assert_equal [2], first_calls
    assert_equal Ledger::SUSPENDED, ledger.state_of(ticket)

    # 1 台目を捨て、台帳だけ渡して 2 台目を建てる (受付列は空のまま)。
    second = machine(second_calls = [], ledger: ledger, intake: Gear::Machine::Intake.new)
    resumed = second.resume(ticket)

    assert_equal [4], second_calls, '記録済みの 1 回は叩き直さず、残りだけ叩いた'
    refute_predicate resumed, :suspended?
    assert_equal Ledger::COMPLETED, ledger.state_of(ticket)
    assert_equal baseline.produced, resumed.produced, '同じ成果に至る'
    assert_equal baseline.outcome.receipts, resumed.outcome.receipts, '同じ receipt 列に至る'
    assert_equal Gear::Journal.dump(baseline.outcome.journal),
                 Gear::Journal.dump(resumed.outcome.journal), '同じ journal に至る'
  end

  # ---- 台帳だけで投入を組み直せる (機械に状態を残していない) ----
  def test_the_ledger_alone_carries_what_is_needed_to_resume
    ledger = Ledger.new
    first = machine([], ledger: ledger)
    ticket = first.submit(name: :twice, focus: { 'n' => 2 }, kit: kit(:twice)).ticket
    first.step(max_effects: 2)

    accepted = ledger.for_ticket(ticket).find { |r| r.kind == Ledger::ACCEPTED }

    assert_equal 'twice', accepted.payload['name']
    assert_equal({ 'n' => 2 }, accepted.payload['focus'])
    assert_equal 1, accepted.payload['kit']['depth'], 'Kit は宣言データとして台帳に残る'
    assert_equal ticket, accepted.payload['seed'], '種も残るので同じ走行が再現できる'
  end
end
