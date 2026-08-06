# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'stringio'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# 敵対的監査 (2026-08-07) で確定した 8 つの穴の回帰テスト。
# どれも監査側が実際に再現させたもので、読みだけの推測は含まない。
# ==================================================================
class GearAuditRegressionTest < Minitest::Test
  IN  = Zeolite.schema(n: :integer).named(:AuditIn)
  OUT = Zeolite.schema(n: :integer, doubled: :integer).named(:AuditOut)
  Ledger = Gear::Machine::Ledger

  def allow = Gear::Admission::Policy::AllowAll.new

  def ports(calls, factor: 2, &raiser)
    reg = Gear::Port::Registry.new
    %i[probe probe2].each do |tag|
      reg.register(
        Gear::Port::Adapter.new(tag).operation(tag, payload: IN, result: OUT) do |payload|
          calls << payload['n']
          raiser&.call(payload)
          { 'n' => payload['n'], 'doubled' => payload['n'] * factor }
        end
      )
    end
    reg
  end

  def effectful(tag, key = :doubled)
    Berylx::Task[tag] { |lay, io| lay.put(key, io.perform(tag, { 'n' => lay[:n].fetch }).doubled) }
  end

  # --- A: submit の子に並列分岐があってもデッドロックしない ---------------------
  def test_a_parallel_branch_inside_submit_does_not_deadlock
    programs = Gear::Program::Registry.new.register(
      name: :par, task: effectful(:probe, :a) & effectful(:probe2, :b), input: IN, output: PAR_OUT
    )
    parent = Berylx::Task[:parent] do |lay, io|
      lay.put(:out, io.perform(Gear::Program::SUBMIT_TAG, { 'name' => 'par', 'focus' => { 'n' => 2 } }))
    end
    kit = Gear::Kit.of(ports: %i[probe probe2 program_submit], programs: %i[par], depth: 1)

    outcome = nil
    worker = Thread.new do
      outcome = Gear::Executor.run(parent, policy: allow, seed: 1, registry: ports([]),
                                           programs: programs, kit: kit)
    end
    finished = worker.join(20)
    worker.kill if finished.nil?

    refute_nil finished, 'submit の子の並列分岐でデッドロックした'
    assert_equal 2, outcome.journal.port_results.size, '両方の枝が走った'
  end

  PAR_OUT = Zeolite.schema(n: :integer, a: :integer, b: :integer).named(:AuditParOut)

  # --- H: Kit 無しでも入れ子の上限で止まる (SystemStackError にしない) -----------
  def test_h_self_submit_without_a_kit_stops_at_the_depth_limit
    task = Berylx::Task[:loop_forever] do |lay, io|
      io.perform(Gear::Program::SUBMIT_TAG, { 'name' => 'loop_forever', 'focus' => { 'n' => 1 } })
      lay
    end
    programs = Gear::Program::Registry.new.register(name: :loop_forever, task: task, input: IN, output: IN)
    out = Gear::Executor.run(task, policy: allow, seed: 1, registry: ports([]), programs: programs)

    assert_instance_of Berylx::Err, out.result, '深さの上限は値として親へ返る'
    assert_operator out.receipts.size, :<=, Gear::Executor::Driver::MAX_SUBMIT_DEPTH + 1
  end

  # --- B1: 同じ tag でも payload が違えば古い記録を読み戻さない ------------------
  def test_b1_replay_refuses_a_record_whose_payload_differs
    program = effectful(:probe)
    recorded = Gear::Executor.run(program, policy: allow, seed: 1, registry: ports([]), focus: { n: 2 })

    assert_equal 1, recorded.journal.port_results.size

    assert_raises(Gear::Executor::ReplayMismatch) do
      Gear::Executor.run(program, policy: allow, seed: 1, registry: ports([]),
                                  focus: { n: 9 }, journal: recorded.journal)
    end
  end

  # --- B2: 読み戻せない記録は nil として渡さない --------------------------------
  def test_b2_unreadable_record_raises_instead_of_handing_over_nil
    broken = Gear::Journal::Log.new.append(
      Gear::Journal::Entry.at(1, Gear::Journal::PORT_RESULT,
                              'port' => 'probe', 'payload' => { 'n' => 2 },
                              'result' => { 'n' => 'not an integer' })
    )

    error = assert_raises(Gear::Executor::ReplayUnreadable) do
      Gear::Executor.run(effectful(:probe), policy: allow, seed: 1, registry: ports([]),
                                            focus: { n: 2 }, journal: broken)
    end

    assert_equal :probe, error.tag
    refute_empty error.violations
  end

  # --- E: handler が例外を投げても receipt と記録が残る -------------------------
  def test_e_a_failed_external_call_still_leaves_a_receipt
    out = Gear::Executor.run(
      effectful(:probe), policy: allow, seed: 1, focus: { n: 2 },
                         registry: ports(calls = []) { raise ' ポートの向こうで壊れた' }
    )

    assert_equal [2], calls, '外界は叩かれた'
    assert_instance_of Berylx::Err, out.result
    assert_equal 1, out.receipts.size, '叩いたのに receipt が無い状態を作らない'
    refute_predicate out.receipts.first, :succeeded?
    assert_includes out.journal.to_a.map(&:kind), :effect_failed
    assert_predicate out.receipts.first, :grounded?, '何が許可したかも残る'
  end

  # --- C: 短い journal で記録済みを上書きしない --------------------------------
  def test_c_ledger_does_not_shrink_a_remembered_journal
    ledger = Ledger.new
    long = Gear::Journal::Log.new
                             .append(Gear::Journal::Entry.at(1, Gear::Journal::PORT_RESULT, 'port' => 'probe'))
                             .append(Gear::Journal::Entry.at(2, Gear::Journal::PORT_RESULT, 'port' => 'probe'))
    short = Gear::Journal::Log.new
                              .append(Gear::Journal::Entry.at(1, Gear::Journal::PORT_RESULT, 'port' => 'probe'))

    ledger.remember(7, long)
    ledger.remember(7, short)

    assert_equal 2, ledger.journal_for(7).port_results.size, '記録済みの外界結果を捨てない'
  end

  # --- D: 台帳を引き継いだ機械は ticket を衝突させない -------------------------
  def test_d_a_rebuilt_machine_does_not_reissue_a_used_ticket
    programs = Gear::Program::Registry.new.register(name: :double, task: effectful(:probe), input: IN, output: OUT)
    kit = Gear::Kit.of(ports: %i[probe program_submit], programs: %i[double], depth: 1)
    ledger = Ledger.new
    first = Gear::Machine.new(programs: programs, ports: ports([]), ledger: ledger)
    used = first.submit(name: :double, focus: { 'n' => 2 }, kit: kit).ticket
    first.step

    second = Gear::Machine.new(programs: programs, ports: ports([]), ledger: ledger,
                               intake: Gear::Machine::Intake.new)
    fresh = second.submit(name: :double, focus: { 'n' => 9 }, kit: kit).ticket

    refute_equal used, fresh, '建て直しても使用済み ticket を再発行しない'
    assert_equal 2, fresh
  end

  # --- F: 壊れた行で受付が止まらない -------------------------------------------
  def test_f_feed_keeps_going_past_a_line_it_cannot_accept
    lines = [
      JSON.generate('name' => 'double', 'focus' => { 'n' => 1 }),
      JSON.generate('name' => 'double', 'kit' => 42),
      '["top level is an array"]',
      JSON.generate('name' => 'double', 'focus' => { 'n' => 2 })
    ].join("\n")
    feed = Gear::Machine::Feed.new(io: StringIO.new("#{lines}\n"), intake: Gear::Machine::Intake.new)
    taken = feed.absorb

    assert_equal 2, taken.size, '受けられる行は全部通る (途中で止まらない)'
    assert_equal 2, feed.rejected.size, '受けられない行は黙って消えず残る'
  end

  # --- G: 並列枝を置き去りにしない ---------------------------------------------
  def test_g_a_sibling_branch_is_joined_even_when_another_raises
    finished = []
    slow = Berylx::Task[:slow] do |lay, _io|
      sleep 0.05
      finished << :slow
      lay
    end
    thrower = Berylx::Task[:thrower] { |_lay, _io| raise Gear::Executor::Suspend }

    was = Thread.report_on_exception
    Thread.report_on_exception = false
    out = Gear::Executor.run(thrower & slow, policy: allow, seed: 1, registry: ports([]))
    Thread.report_on_exception = was

    # Suspend は走行の外まで抜けて Driver#run が中断として受ける。
    assert_predicate out, :suspended?
    assert_equal [:slow], finished, '兄弟の枝を置き去りにしない (走行後に副作用が起きない)'
  end
end
