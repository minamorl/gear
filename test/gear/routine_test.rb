# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# Gear::Routine — 「やったことが、そのままルーチンになる」を実測で示す。
#
#   - 実際に Executor で走らせた journal から Routine を復元できる
#   - 復元した Routine を再実行すると、元と同じ effect 列が起きる
#   - 復元した Routine の実行が admission を通る (deny policy で止まる)
#   - 復元した Routine が receipt を出す
#   - tick 範囲やタグで部分抽出できる
#   - パラメータ化した Routine に別の引数を渡すと、その値で実行される
#   - Routine をシリアライズ→復元しても同じものになる (round-trip)
#
# 外界は「呼ばれた n」を積む probe adapter で観測する (executor_test と同じ流儀)。
# ==================================================================
class GearRoutineTest < Minitest::Test
  Routine  = Gear::Routine
  Executor = Gear::Executor

  def allow = Gear::Admission::Policy::AllowAll.new
  def deny  = Gear::Admission::Policy::DenyAll.new

  PROBE_PAYLOAD = Zeolite.schema(n: :integer).named(:RoutineProbePayload)
  PROBE_RESULT  = Zeolite.schema(n: :integer, doubled: :integer).named(:RoutineProbeResult)

  # 実走したときだけ calls に n を積む probe adapter。
  def probe_adapter(calls)
    Gear::Port::Adapter.new(:probe).operation(
      :probe, payload: PROBE_PAYLOAD, result: PROBE_RESULT
    ) do |payload|
      calls << payload['n']
      { 'n' => payload['n'], 'doubled' => payload['n'] * 2 }
    end
  end

  # probe だけの registry。
  def registry_with_probe(calls)
    reg = Gear::Port::Registry.new
    reg.register(probe_adapter(calls))
    reg
  end

  # probe + shell の registry (タグ抽出の実測用)。
  def registry_mixed(calls)
    reg = Gear::Port::Registry.new
    reg.register(probe_adapter(calls))
    reg.register(Gear::Port::Shell::ADAPTER)
    reg
  end

  def probe_task(name, key, number)
    Berylx::Task[name] do |lay, io|
      res = io.perform(:probe, { 'n' => number })
      lay.put(key, res.doubled)
    end
  end

  def shell_task(name, key, cmd)
    Berylx::Task[name] do |lay, io|
      res = io.perform(:shell_run, { 'cmd' => cmd })
      lay.put(key, res.stdout)
    end
  end

  def two_probes
    probe_task(:double_a, :a, 2) >> probe_task(:double_b, :b, 3)
  end

  # journal から (tag, payload) の効果列を取り出す (元と復元の比較用)。
  def effect_seq(journal)
    journal.select { |e| e.kind == :receipt }.map do |e|
      eff = e.payload[:effect] || e.payload['effect']
      [eff['tag'], eff['payload']]
    end
  end

  # 実走して正本 journal を作る小道具。
  def record(program, registry:, seed: 1)
    Executor.run(program, policy: allow, seed: seed, registry: registry)
  end

  # ---- 実際に走らせた journal から Routine を復元できる ----
  def test_restores_routine_from_a_real_run
    out = record(two_probes, registry: registry_with_probe([]))

    routine = Routine.from_journal(out.journal, name: :double_pair)

    assert_equal 'double_pair', routine.name
    assert_equal 2, routine.steps.size
    assert_equal %w[probe probe], routine.steps.map(&:tag)
    assert_equal [{ 'n' => 2 }, { 'n' => 3 }], routine.steps.map(&:payload)
  end

  # ---- 復元した Routine を再実行すると、元と同じ effect 列が起きる ----
  def test_replaying_a_restored_routine_reproduces_the_effect_sequence
    original = record(two_probes, registry: registry_with_probe(orig_calls = []))

    assert_equal [2, 3], orig_calls

    routine = Routine.from_journal(original.journal, name: :double_pair)

    # まっさらな registry + 空 journal で「実走」させる (replay ではなく再実行)。
    replay_calls = []
    replay = Executor.run(routine.to_task, policy: allow, seed: 99,
                                           registry: registry_with_probe(replay_calls))

    assert_equal [2, 3], replay_calls, '復元したルーチンが元と同じ順・同じ値で効果を踏む'
    assert_equal effect_seq(original.journal), effect_seq(replay.journal),
                 '元 journal と復元実行の effect 列が一致する'
  end

  # ---- 復元した Routine の実行も admission を通る (deny で止まる) ----
  def test_restored_routine_still_passes_through_admission
    out = record(probe_task(:solo, :a, 7), registry: registry_with_probe([]))
    routine = Routine.from_journal(out.journal, name: :solo)

    calls = []
    denied = Executor.run(routine.to_task, policy: deny, seed: 1,
                                           registry: registry_with_probe(calls))

    assert_empty calls, 'ルーチン化しても admission を迂回できない (routine.same_gate)'
    assert_instance_of Berylx::Err, denied.result, '拒否は結果封筒 Err として返る'
    denials = denied.journal.select { |e| e.kind == :admission_denied }

    assert_equal 1, denials.size, '拒否は journal に記録される'
    assert_empty denied.receipts, '実行していないので receipt は出ない'
  end

  # ---- 復元した Routine が receipt を出す ----
  def test_restored_routine_emits_receipts
    out = record(two_probes, registry: registry_with_probe([]))
    routine = Routine.from_journal(out.journal, name: :double_pair)

    run = Executor.run(routine.to_task, policy: allow, seed: 1,
                                        registry: registry_with_probe([]))

    assert_equal 2, run.receipts.size, '実行された効果の数だけ receipt が出る'
    run.receipts.each do |r|
      assert_predicate r, :succeeded?
      assert_predicate r, :grounded?, 'receipt は「何が許可したか」を持つ'
    end
    # 鎖になっている (receipt.chainable)。
    assert_nil run.receipts[0].predecessor
    assert_equal run.receipts[0].id, run.receipts[1].predecessor
  end

  # ---- tick 範囲で部分抽出できる ----
  def test_extracts_a_tick_range
    out = record(two_probes, registry: registry_with_probe([]))

    # 効果は tick 1, 2 に乗る。2 個目だけを切り出す。
    second = Routine.from_journal(out.journal, name: :only_second, ticks: 2..2)

    assert_equal 1, second.steps.size
    assert_equal({ 'n' => 3 }, second.steps.first.payload)

    calls = []
    Executor.run(second.to_task, policy: allow, seed: 1, registry: registry_with_probe(calls))

    assert_equal [3], calls, '切り出した部分だけが走る'
  end

  # ---- タグで部分抽出できる ----
  def test_extracts_by_tag
    program = probe_task(:p, :a, 4) >> shell_task(:s, :b, 'echo gear')
    out = record(program, registry: registry_mixed([]))

    only_shell = Routine.from_journal(out.journal, name: :only_shell, tags: [:shell_run])
    only_probe = Routine.from_journal(out.journal, name: :only_probe, tags: [:probe])

    assert_equal %w[shell_run], only_shell.steps.map(&:tag)
    assert_equal %w[probe], only_probe.steps.map(&:tag)
    assert_equal({ 'cmd' => 'echo gear' }, only_shell.steps.first.payload)
  end

  # ---- パラメータ化した Routine に別の引数を渡すと、その値で実行される ----
  def test_parameterized_routine_runs_with_a_different_argument
    out = record(probe_task(:solo, :a, 2), registry: registry_with_probe([]))
    routine = Routine.from_journal(out.journal, name: :doubler)

    # payload の 'n' を引数 :num に持ち上げる。
    param = routine.parameterize(num: { key: 'n' })

    assert_equal %w[num], param.params, '穴の名前が必要引数として見える'

    # 別の値を渡すと、その値で外界を叩く。
    calls = []
    param.run(policy: allow, seed: 1, params: { num: 42 }, registry: registry_with_probe(calls))

    assert_equal [42], calls, '記録時の 2 ではなく渡した 42 で走る'

    # 引数を渡さなければ「穴が埋まっていない」と弾く (一度きり再生との違い)。
    assert_raises(ArgumentError) { param.to_task }
  end

  # ---- Routine をシリアライズ→復元しても同じものになる (round-trip) ----
  def test_serialization_round_trip
    out = record(two_probes, registry: registry_with_probe([]))
    routine = Routine.from_journal(out.journal, name: :double_pair)

    reloaded = Routine.load(routine.dump)

    assert_equal routine, reloaded, 'dump → load で同値に戻る'

    # 穴あきルーチンも round-trip する (穴は JSON でそのまま運べる)。
    param = routine.parameterize(num: { key: 'n', step: 0 })
    param_reloaded = Routine.load(param.dump)

    assert_equal param, param_reloaded
    assert_equal %w[num], param_reloaded.params, '復元後も引数が保たれる'
  end
end
