# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# Gear::Executor — 五点セットを一本の走行に綴じる者を実測で示す。
#
#   - berylx の Task 合成をそのまま実行できる (gear 独自 DSL を書かない)
#   - admission を通らない副作用が発火しない (deny policy で外界が呼ばれない)
#   - 実行された副作用に必ず receipt が出る (silent effect が無い / 鎖になる)
#   - 途中で中断し journal から再開して同じ最終状態に至る
#   - 同じ journal + 同じ seed で 2 回走らせると同じ receipt 列になる (決定論)
#   - 記録済み外界結果が replay で再実行されない (外界呼び出し回数で実測)
#
# 外界は「呼ばれた回数」を数える probe adapter で観測する。実ネットワーク・
# 実ファイルは叩かない (shell の echo だけ berylx 合成の end-to-end に使う)。
# ==================================================================
class GearExecutorTest < Minitest::Test
  Executor = Gear::Executor

  def allow = Gear::Admission::Policy::AllowAll.new
  def deny  = Gear::Admission::Policy::DenyAll.new

  # 呼ばれた n を calls に積む probe adapter。replay では呼ばれないはず。
  PROBE_PAYLOAD = Zeolite.schema(n: :integer).named(:ProbePayload)
  PROBE_RESULT  = Zeolite.schema(n: :integer, doubled: :integer).named(:ProbeResult)

  def registry_with_probe(calls)
    adapter = Gear::Port::Adapter.new(:probe).operation(
      :probe, payload: PROBE_PAYLOAD, result: PROBE_RESULT
    ) do |payload|
      calls << payload['n'] # 外界を叩いた記録 (実走のときだけ増える)
      { 'n' => payload['n'], 'doubled' => payload['n'] * 2 }
    end
    reg = Gear::Port::Registry.new
    reg.register(adapter)
    reg
  end

  # n を渡すと doubled を focus に置く効果付き Task。
  def probe_task(name, key, number)
    Berylx::Task[name] do |lay, io|
      res = io.perform(:probe, { 'n' => number })
      lay.put(key, res.doubled)
    end
  end

  # 二つの効果を直列に踏む program (berylx の >> 合成)。
  def two_probes
    probe_task(:double_a, :a, 2) >> probe_task(:double_b, :b, 3)
  end

  def random_task(name, key, bound = 1_000_000)
    Berylx::Task[name] do |lay, io|
      res = io.perform(Gear::Clock::RANDOM_TAG, { 'bound' => bound })
      lay.put(key, res.value)
    end
  end

  def mixed_random_and_ports
    random_task(:random_a, :random_a) >> probe_task(:probe_a, :probe_a, 2) >>
      random_task(:random_b, :random_b) >> probe_task(:probe_b, :probe_b, 3)
  end

  # ---- berylx の Task 合成をそのまま実行できる (実 shell で end-to-end) ----
  def test_runs_berylx_task_composition_with_real_shell
    greet = Berylx::Task[:greet] do |lay, io|
      res = io.perform(:shell_run, { 'cmd' => 'echo gear' })
      lay.put(:greeting, res.stdout)
    end

    out = Executor.run(greet, policy: allow, seed: 1)

    assert_instance_of Berylx::Ok, out.result
    assert_equal "gear\n", out.result.focus.to_h[:greeting]
    assert_equal 1, out.receipts.size
    assert_predicate out.receipts.first, :succeeded?
    refute_predicate out, :suspended?
  end

  def test_runs_multi_step_composition
    calls = []
    out = Executor.run(two_probes, policy: allow, seed: 1, registry: registry_with_probe(calls))

    assert_instance_of Berylx::Ok, out.result
    assert_equal({ a: 4, b: 6 }, out.result.focus.to_h)
    assert_equal [2, 3], calls, '両方の効果が実走した'
  end

  # ---- admission を通らない副作用は発火しない ----
  def test_denied_effect_never_fires_and_is_recorded
    calls = []
    reg = registry_with_probe(calls)
    out = Executor.run(probe_task(:solo, :a, 2), policy: deny, seed: 5, registry: reg)

    assert_empty calls, 'admission を通らない副作用は外界を叩かない (admission.precedes_effect)'
    assert_instance_of Berylx::Err, out.result, '拒否は結果封筒 Err として program を閉じる'

    denials = out.journal.select { |e| e.kind == :admission_denied }

    assert_equal 1, denials.size, '拒否は journal に記録される'
    assert_equal 'deny_all', denials.first.payload['by']
    assert_empty out.receipts, '実行していないので receipt は無い (no receipt for non-effect)'
  end

  # ---- 実行された副作用には必ず receipt が出て、鎖になる ----
  def test_every_executed_effect_emits_a_chained_receipt
    calls = []
    out = Executor.run(two_probes, policy: allow, seed: 9, registry: registry_with_probe(calls))

    port_results = out.journal.port_results
    receipts_in_journal = out.journal.select { |e| e.kind == :receipt }

    # silent effect が無い: 外界結果の数だけ receipt が出ている。
    assert_equal port_results.size, receipts_in_journal.size
    assert_equal 2, out.receipts.size

    out.receipts.each do |r|
      assert_predicate r, :grounded?, 'receipt は「何が許可したか」を持つ (receipt.carries_grounds)'
      assert_predicate r, :succeeded?
      refute_nil r.effect['tag'], 'receipt は「何が起きたか」を持つ'
    end

    # 鎖: 先頭は根、次は先頭を指す (receipt.chainable)。
    assert_nil out.receipts[0].predecessor
    assert_equal out.receipts[0].id, out.receipts[1].predecessor
  end

  # ---- 途中で中断し、journal から再開して同じ最終状態に至る ----
  def test_interrupt_then_resume_reaches_same_final_state
    reg_full = registry_with_probe(full_calls = [])
    full = Executor.run(two_probes, policy: allow, seed: 3, registry: reg_full)

    assert_equal [2, 3], full_calls

    # 最初の効果の手前ではなく「1 個実行した後、2 個目の手前」で中断する。
    reg_part = registry_with_probe(part_calls = [])
    partial = Executor.run(two_probes, policy: allow, seed: 3, registry: reg_part, max_effects: 1)

    assert_predicate partial, :suspended?, '予算到達で中断した'
    assert_equal [2], part_calls, '中断前に実走したのは 1 個だけ'
    assert_equal 1, partial.journal.port_results.size

    # 中断時の journal を渡して残りを再開する。
    reg_res = registry_with_probe(resume_calls = [])
    resumed = Executor.run(two_probes, policy: allow, seed: 3, registry: reg_res, journal: partial.journal)

    refute_predicate resumed, :suspended?
    assert_equal [3], resume_calls, '再開時は未記録の効果だけ実走する (記録済みは読み戻す)'
    assert_equal full.result.focus.to_h, resumed.result.focus.to_h, '中断再開しても最終状態は同じ'
    assert_equal full.receipts, resumed.receipts, '中断再開しても receipt 列は同じ'
  end

  # ---- 同じ journal + 同じ seed で 2 回走らせると同じ receipt 列になる ----
  def test_same_journal_and_seed_replays_deterministically
    reg1 = registry_with_probe(record_calls = [])
    recorded = Executor.run(two_probes, policy: allow, seed: 7, registry: reg1)

    assert_equal [2, 3], record_calls

    reg2 = registry_with_probe(replay_calls = [])
    replayed = Executor.run(two_probes, policy: allow, seed: 7, registry: reg2, journal: recorded.journal)

    # 決定論: 同じ journal + 同じ seed → 同じ receipt 列 / 同じ journal。
    assert_equal recorded.receipts, replayed.receipts
    assert_equal Gear::Journal.dump(recorded.journal), Gear::Journal.dump(replayed.journal)
    # 記録済み外界結果は再実行されない (journal.records_external_results)。
    assert_empty replay_calls, 'replay は外界を一切叩かない'
  end

  # ---- 記録の外に出た効果だけが実走する (境界が宣言されている) ----
  def test_replay_reruns_only_beyond_recorded_boundary
    # 1 個だけ記録した journal を作る。
    reg_seed = registry_with_probe([])
    seed_run = Executor.run(two_probes, policy: allow, seed: 4, registry: reg_seed, max_effects: 1)

    assert_equal 1, seed_run.journal.port_results.size

    # その journal で通し実行 — 1 個目は読み戻し、2 個目だけ実走する。
    reg = registry_with_probe(calls = [])
    out = Executor.run(two_probes, policy: allow, seed: 4, registry: reg, journal: seed_run.journal)

    refute_predicate out, :suspended?
    assert_equal [3], calls, '記録済み境界の内側は再実行しない、外側だけ叩く'
    assert_equal({ a: 4, b: 6 }, out.result.focus.to_h)
  end

  # ---- seed 由来乱数は gate を通るが、外界結果としては記録しない ----
  def test_random_effect_repeats_from_same_seed_without_recorded_results
    program = random_task(:draw, :draw)

    first = Executor.run(program, policy: allow, seed: 12_345)
    second = Executor.run(program, policy: allow, seed: 12_345)

    assert_empty first.journal.port_results, '決定論的乱数は外界結果として記録しない'
    assert_empty second.journal.port_results
    assert_equal first.result.focus.to_h[:draw], second.result.focus.to_h[:draw],
                 '空の journal 同士でも一致は seed だけから生じる'
  end

  def test_random_effect_changes_with_seed_and_emits_receipt_with_value
    program = random_task(:draw, :draw)
    first = Executor.run(program, policy: allow, seed: 1)
    second = Executor.run(program, policy: allow, seed: 2)

    refute_equal first.result.focus.to_h[:draw], second.result.focus.to_h[:draw]
    assert_equal 1, first.receipts.size
    assert_equal first.result.focus.to_h[:draw], first.receipts.first.outcome['value']['value']
    assert_equal 'clock_random', first.receipts.first.effect['tag']
  end

  def test_denied_random_effect_draws_nothing_and_records_denial
    out = Executor.run(random_task(:draw, :draw), policy: deny, seed: 9)

    assert_instance_of Berylx::Err, out.result
    assert_empty out.receipts
    assert_empty out.journal.port_results
    denial = out.journal.find { |entry| entry.kind == :admission_denied }

    refute_nil denial
    assert_equal 'clock_random', denial.payload['tag']
  end

  def test_random_effect_does_not_shift_port_replay_cursor_when_resuming
    partial = Executor.run(
      mixed_random_and_ports, policy: allow, seed: 77,
                              registry: registry_with_probe(partial_calls = []),
                              max_effects: 3
    )

    assert_predicate partial, :suspended?
    assert_equal [2], partial_calls
    assert_equal 1, partial.journal.port_results.size

    resumed = Executor.run(
      mixed_random_and_ports, policy: allow, seed: 77,
                              registry: registry_with_probe(resume_calls = []),
                              journal: partial.journal
    )
    full = Executor.run(
      mixed_random_and_ports, policy: allow, seed: 77,
                              registry: registry_with_probe([])
    )

    assert_equal [3], resume_calls, '記録済み probe だけを読み戻し、次の probe は実走する'
    assert_equal full.result.focus.to_h, resumed.result.focus.to_h
    assert_equal full.receipts, resumed.receipts
  end

  # ---- 実時刻は外界 port として記録し、replay では読み戻す ----
  def test_time_port_records_and_replays_without_reading_clock_again
    program = Berylx::Task[:now] do |lay, io|
      res = io.perform(Gear::Port::TimeNow::TAG, {})
      lay.put(:now, res.epoch_seconds)
    end

    recorded = ::Time.stub(:now, ::Time.at(123.25)) do
      Executor.run(program, policy: allow, seed: 6)
    end
    replayed = ::Time.stub(:now, -> { flunk 'replay で Time.now を呼んではならない' }) do
      Executor.run(program, policy: allow, seed: 6, journal: recorded.journal)
    end

    entry = recorded.journal.port_results.fetch(0)

    assert_equal 'time_now', entry.payload['port']
    assert_in_delta 123.25, entry.payload['result']['epoch_seconds']
    assert_equal recorded.result.focus.to_h[:now], replayed.result.focus.to_h[:now]
    assert_equal 1, recorded.receipts.size
    assert_predicate recorded.receipts.first, :grounded?
    assert_in_delta 123.25, recorded.receipts.first.outcome['value']['epoch_seconds']
  end

  def test_denied_time_port_does_not_read_external_clock
    program = Berylx::Task[:now] do |lay, io|
      res = io.perform(Gear::Port::TimeNow::TAG, {})
      lay.put(:now, res.epoch_seconds)
    end

    out = ::Time.stub(:now, -> { flunk 'deny の前に Time.now を呼んではならない' }) do
      Executor.run(program, policy: deny, seed: 6)
    end

    assert_instance_of Berylx::Err, out.result
    assert_equal(1, out.journal.count { |entry| entry.kind == :admission_denied })
    assert_empty out.receipts
  end
  # ---- journal と program の効果順が食い違ったら黙って読み戻さない ----
  # 結果の「形」が同じ 2 枚の adapter を用意すると、位置だけで cursor を進める実装では
  # 逆順 program でも読み戻しが成功し、誤値が state に入り receipt に嘘の根拠が載る。
  # tag を照合して走行の外まで抜けることを実測で示す。
  SAME_SHAPE_PAYLOAD = Zeolite.schema(n: :integer).named(:SameShapePayload)
  SAME_SHAPE_RESULT  = Zeolite.schema(n: :integer, doubled: :integer).named(:SameShapeResult)

  def same_shape_registry
    reg = Gear::Port::Registry.new
    { alpha: 2, beta: 10 }.each do |name, factor|
      reg.register(
        Gear::Port::Adapter.new(name).operation(
          name, payload: SAME_SHAPE_PAYLOAD, result: SAME_SHAPE_RESULT
        ) { |payload| { 'n' => payload['n'], 'doubled' => payload['n'] * factor } }
      )
    end
    reg
  end

  def same_shape_task(tag, key)
    Berylx::Task[tag] { |lay, io| lay.put(key, io.perform(tag, { 'n' => 2 }).doubled) }
  end

  def test_replay_against_diverging_effect_order_raises_instead_of_restoring_wrong_value
    recorded = Executor.run(same_shape_task(:alpha, :a) >> same_shape_task(:beta, :b),
                            policy: allow, seed: 1, registry: same_shape_registry)

    assert_equal({ a: 4, b: 20 }, recorded.result.focus.to_h)

    error = assert_raises(Executor::ReplayMismatch) do
      Executor.run(same_shape_task(:beta, :b) >> same_shape_task(:alpha, :a),
                   policy: allow, seed: 1, registry: same_shape_registry,
                   journal: recorded.journal)
    end

    assert_equal 'alpha', error.recorded_port
    assert_equal :beta, error.requested_tag
    assert_match(/journal は alpha を記録している/, error.message)
  end

  def test_replay_against_same_effect_order_still_reads_back
    recorded = Executor.run(same_shape_task(:alpha, :a) >> same_shape_task(:beta, :b),
                            policy: allow, seed: 1, registry: same_shape_registry)
    replayed = Executor.run(same_shape_task(:alpha, :a) >> same_shape_task(:beta, :b),
                            policy: allow, seed: 1, registry: same_shape_registry,
                            journal: recorded.journal)

    assert_equal recorded.receipts, replayed.receipts
    assert_equal({ a: 4, b: 20 }, replayed.result.focus.to_h)
  end
end
