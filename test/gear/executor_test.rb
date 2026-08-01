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
  def probe_task(name, key, n)
    Berylx::Task[name] do |lay, io|
      res = io.perform(:probe, { 'n' => n })
      lay.put(key, res.doubled)
    end
  end

  # 二つの効果を直列に踏む program (berylx の >> 合成)。
  def two_probes
    probe_task(:double_a, :a, 2) >> probe_task(:double_b, :b, 3)
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
    assert out.receipts.first.succeeded?
    refute out.suspended?
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
      assert r.grounded?, 'receipt は「何が許可したか」を持つ (receipt.carries_grounds)'
      assert r.succeeded?
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

    assert partial.suspended?, '予算到達で中断した'
    assert_equal [2], part_calls, '中断前に実走したのは 1 個だけ'
    assert_equal 1, partial.journal.port_results.size

    # 中断時の journal を渡して残りを再開する。
    reg_res = registry_with_probe(resume_calls = [])
    resumed = Executor.run(two_probes, policy: allow, seed: 3, registry: reg_res, journal: partial.journal)

    refute resumed.suspended?
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

    refute out.suspended?
    assert_equal [3], calls, '記録済み境界の内側は再実行しない、外側だけ叩く'
    assert_equal({ a: 4, b: 6 }, out.result.focus.to_h)
  end
end
