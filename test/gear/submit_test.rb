# frozen_string_literal: true

require 'minitest/autorun'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# program_submit — program から program へ繋ぐ一段を実測で示す。
#
#   - 親と子が 1 本の全順序に並び、receipt が親→子で鎖になる
#   - 子は親より狭い Kit で走る (depth が 1 段減り、更に submit できない)
#   - Kit に渡していない program は繋げない (拒否は値として親へ返る)
#   - 名簿に無い名前は繋げない (素の Task は実行機に乗らない)
#   - 宣言した境界を満たさない入出力は走らせない / 通さない
# ==================================================================
class GearSubmitTest < Minitest::Test
  Executor = Gear::Executor

  PROBE_IN  = Zeolite.schema(n: :integer).named(:ProbeIn)
  PROBE_OUT = Zeolite.schema(n: :integer, doubled: :integer).named(:ProbeOut)

  def allow = Gear::Admission::Policy::AllowAll.new

  def ports(calls)
    reg = Gear::Port::Registry.new
    reg.register(
      Gear::Port::Adapter.new(:probe).operation(:probe, payload: PROBE_IN, result: PROBE_OUT) do |payload|
        calls << payload['n']
        { 'n' => payload['n'], 'doubled' => payload['n'] * 2 }
      end
    )
    reg
  end

  # 子: probe を 1 回踏んで doubled を置く。宣言は ProbeIn -> ProbeOut。
  def child_task
    Berylx::Task[:double] do |lay, io|
      lay.put(:doubled, io.perform(:probe, { 'n' => lay[:n].fetch }).doubled)
    end
  end

  def programs
    Gear::Program::Registry.new.register(
      name: :double, task: child_task, input: PROBE_IN, output: PROBE_OUT
    )
  end

  # 親: 子を submit して、返ってきた素データから doubled を取る。
  def parent(name: :double, value: 2)
    Berylx::Task[:parent] do |lay, io|
      out = io.perform(Gear::Program::SUBMIT_TAG, { 'name' => name.to_s, 'focus' => { 'n' => value } })
      lay.put(:from_child, out['doubled'])
    end
  end

  # 渡された Kit の宣言を呼び出し側へ差し出しつつ走る子。
  def peek_task(&report)
    Berylx::Task[:peek] do |lay, _io|
      report.call(lay[Gear::Kit::FOCUS_KEY].fetch)
      lay.put(:doubled, 0)
    end
  end

  def kit(depth: 1) = Gear::Kit.of(ports: %i[probe program_submit], programs: %i[double], depth: depth)

  def run_parent(kit_arg: kit, calls: [], **opts)
    Executor.run(parent(**opts), policy: allow, seed: 1, registry: ports(calls),
                                 programs: programs, kit: kit_arg)
  end

  # ---- 親と子が 1 本の全順序に並び、receipt が鎖になる ----
  def test_child_runs_inline_on_the_parents_total_order
    out = run_parent(calls: calls = [])

    assert_equal [2], calls, '子の効果が実際に外界を叩いた'
    assert_equal 4, out.result.focus.to_h[:from_child]

    kinds = out.journal.to_a.map(&:kind)

    assert_equal 1, out.journal.port_results.size, 'submit 自身は外界結果を持たない'
    assert_equal 'probe', out.journal.port_results.first.payload['port']
    assert_equal 2, out.receipts.size, 'submit と子の効果でちょうど 2 通'
    assert_includes kinds, :receipt
  end

  # tick は「始まった順」、receipt 鎖は「閉じた順」。入れ子の親は子より後に閉じるので、
  # submit の receipt は子の receipt の後ろに繋がる (分散トレースの親 span と同じ形)。
  # 監査するときはこの向きを取り違えないこと。
  def test_receipts_are_chained_in_completion_order_across_the_submit_boundary
    child, submit = run_parent.receipts

    assert_equal 'probe', child.effect['tag']
    assert_equal Gear::Program::SUBMIT_TAG.to_s, submit.effect['tag']
    assert_equal 1, submit.tick, 'submit が先に始まる'
    assert_equal 2, child.tick, '子の効果は次の tick'
    assert_predicate child.predecessor.to_s, :empty?, '最初に閉じたものに先行は無い'
    assert_equal child.id, submit.predecessor, '鎖は閉じた順に繋がる'
  end

  # ---- 子は親より狭い Kit で走る ----
  def test_child_receives_a_narrowed_kit
    seen = nil
    reg = Gear::Program::Registry.new.register(
      name: :peek, task: peek_task { |kit_seen| seen = kit_seen }, input: PROBE_IN, output: PROBE_OUT
    )
    Executor.run(parent(name: :peek), policy: allow, seed: 1, registry: ports([]),
                                      programs: reg, kit: Gear::Kit.of(ports: %i[probe program_submit],
                                                                       programs: %i[peek], depth: 2))

    assert_equal 1, seen['depth'], '子の depth は 1 段減っている'
    assert_equal %w[probe program_submit], seen['ports']
  end

  def test_depth_zero_cannot_submit
    out = run_parent(kit_arg: kit(depth: 0), calls: calls = [])

    assert_empty calls, '繋げないなら子は走らない'
    assert_instance_of Berylx::Err, out.result
    denied = out.journal.to_a.select { |e| e.kind == :admission_denied }

    assert_equal 1, denied.size
    assert_match(/深さが尽きている/, denied.first.payload['reason'])
  end

  def test_program_not_handed_down_cannot_be_submitted
    narrow = Gear::Kit.of(ports: %i[probe program_submit], programs: %i[other], depth: 1)
    out = run_parent(kit_arg: narrow, calls: calls = [])

    assert_empty calls
    denied = out.journal.to_a.select { |e| e.kind == :admission_denied }

    assert_match(/program double は渡されていない/, denied.first.payload['reason'])
  end

  # ---- 名簿に無い名前は繋げない ----
  def test_unregistered_program_cannot_ride_the_machine
    ghost_kit = Gear::Kit.of(ports: %i[probe program_submit], programs: %i[ghost], depth: 1)
    out = Executor.run(parent(name: :ghost), policy: allow, seed: 1,
                                             registry: ports([]), programs: programs, kit: ghost_kit)

    assert_instance_of Berylx::Err, out.result, '未登録は結果封筒の Err で閉じる'
  end

  # ---- 宣言した境界を満たさない入力では走らせない ----
  def test_input_violating_the_declared_boundary_is_refused
    out = Executor.run(
      Berylx::Task[:bad_parent] do |_lay, io|
        io.perform(Gear::Program::SUBMIT_TAG, { 'name' => 'double', 'focus' => { 'n' => 'two' } })
      end,
      policy: allow, seed: 1, registry: ports(calls = []), programs: programs, kit: kit
    )

    assert_empty calls, '境界を満たさないなら子は走らない'
    assert_instance_of Berylx::Err, out.result
  end

  # ---- submit を含む走行も record -> replay で同じになる ----
  # 子の効果は子自身の port_result として記録されるので、replay では子を走らせ直し、
  # 子の効果が記録を順に読み戻す。submit 自身は外界結果を持たないので cursor は揺れない。
  def test_run_with_submit_replays_deterministically
    recorded = run_parent(calls: rec_calls = [])

    assert_equal [2], rec_calls, '記録時は子が実際に外界を叩く'

    replayed = Executor.run(parent, policy: allow, seed: 1, registry: ports(replay_calls = []),
                                    programs: programs, kit: kit, journal: recorded.journal)

    assert_empty replay_calls, 'replay は外界を叩かない (子の効果も読み戻す)'
    assert_equal recorded.receipts, replayed.receipts, 'receipt 列が一致する'
    assert_equal Gear::Journal.dump(recorded.journal), Gear::Journal.dump(replayed.journal)
    assert_equal 4, replayed.result.focus.to_h[:from_child]
  end

  # ---- 入れ子でも中断と再開が効く ----
  def test_submit_can_be_interrupted_and_resumed
    partial = Executor.run(parent, policy: allow, seed: 1, registry: ports(first = []),
                                   programs: programs, kit: kit, max_effects: 1)

    assert_predicate partial, :suspended?, 'submit の手前で止まる'
    assert_empty first, '止まった時点では子は走っていない'

    resumed = Executor.run(parent, policy: allow, seed: 1, registry: ports(second = []),
                                   programs: programs, kit: kit, journal: partial.journal)

    refute_predicate resumed, :suspended?
    assert_equal [2], second, '再開したぶんだけ外界を叩く'
    assert_equal 4, resumed.result.focus.to_h[:from_child]
  end

  # ---- 並列分岐から同時に submit しても壊れない ----
  # 効果 1 つを不可分にする前は、枝の submit が他の枝が細めた Kit を見て「深さが
  # 尽きている」と偽の拒否を受けていた (実測で約 2.5%)。確率的に壊れるので反復で見る。
  def test_parallel_submits_do_not_corrupt_each_others_kit
    par = submitter(:double, :a) & submitter(:triple, :b)
    broken = 200.times.count do
      out = Executor.run(par, policy: allow, seed: 1, registry: two_ports([]),
                              programs: two_programs, kit: two_kit)
      focus = out.result.respond_to?(:focus) ? out.result.focus.to_h : {}
      focus[:a] != 4 || focus[:b] != 6
    end

    assert_equal 0, broken, '並列 submit で偽の拒否や取り落ちが起きない'
  end

  def two_ports(calls)
    reg = Gear::Port::Registry.new
    { probe2: 2, probe3: 3 }.each do |name, factor|
      reg.register(
        Gear::Port::Adapter.new(name).operation(name, payload: PROBE_IN, result: PROBE_OUT) do |payload|
          calls << name
          { 'n' => payload['n'], 'doubled' => payload['n'] * factor }
        end
      )
    end
    reg
  end

  def two_programs
    Gear::Program::Registry.new
                           .register(name: :double, task: effectful_child(:probe2), input: PROBE_IN, output: PROBE_OUT)
                           .register(name: :triple, task: effectful_child(:probe3), input: PROBE_IN, output: PROBE_OUT)
  end

  def effectful_child(tag)
    Berylx::Task[tag] { |lay, io| lay.put(:doubled, io.perform(tag, { 'n' => lay[:n].fetch }).doubled) }
  end

  def submitter(name, key)
    Berylx::Task[:"submit_#{name}"] do |lay, io|
      out = io.perform(Gear::Program::SUBMIT_TAG, { 'name' => name.to_s, 'focus' => { 'n' => 2 } })
      lay.put(key, out['doubled'])
    end
  end

  def two_kit
    Gear::Kit.of(ports: %i[probe2 probe3 program_submit], programs: %i[double triple], depth: 1)
  end
end
