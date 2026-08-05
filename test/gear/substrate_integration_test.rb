# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'gear'
require 'berylx'
require 'darkcore'
require 'zeolite'

class GearSubstrateIntegrationTest < Minitest::Test
  PROBE_PAYLOAD = Zeolite.schema(n: :integer).named(:SubstrateProbePayload)
  PROBE_RESULT = Zeolite.schema(n: :integer, stdout: :string).named(:SubstrateProbeResult)

  def allow = Gear::Admission::Policy::AllowAll.new

  def probe_adapter(calls, invalid_result: false)
    Gear::Port::Adapter.new(:substrate_probe).operation(
      :substrate_probe, payload: PROBE_PAYLOAD, result: PROBE_RESULT
    ) do |payload|
      calls << payload['n']
      next({ 'n' => 'not-an-integer', 'stdout' => 12 }) if invalid_result

      { 'n' => payload['n'], 'stdout' => "probe-#{payload['n']}" }
    end
  end

  def registry_with(adapter)
    Gear::Port::Registry.new.tap { |registry| registry.register(adapter) }
  end

  def probe_task(name, key, number)
    Berylx::Task[name] do |lay, io|
      result = io.perform(:substrate_probe, { 'n' => number })
      lay.put(key, result.stdout)
    end
  end

  def two_probes
    probe_task(:first_probe, :first, 1) >> probe_task(:second_probe, :second, 2)
  end

  def test_berylx_task_builds_a_darkcore_effect_tree
    program = probe_task(:inspect_tree, :value, 1)

    tree = Berylx::EffectTree.build(program, {})

    assert_instance_of Darkcore::Effect, tree
    assert_equal Berylx::EffectTree::TASK, tree.tag
    refute_kind_of Hash, tree, 'gear 独自の木ではなく darkcore の単一 Effect 型である'
  end

  def test_step_exposes_pending_data_without_running_the_adapter
    calls = []
    adapter = probe_adapter(calls)
    program = probe_task(:pending_probe, :value, 7)
    tree = Berylx::EffectTree.build(program, {})

    pending = Darkcore.step(tree)

    assert_instance_of Darkcore::Pending, pending
    assert_equal Berylx::EffectTree::TASK, pending.tag
    assert_equal Berylx::EffectTree::TASK, tree.tag
    assert_empty calls, 'handler を渡さない step は probe adapter を実行しない'
    assert_includes adapter.tags, :substrate_probe
  end

  def test_port_effect_uses_the_single_darkcore_effect_and_plain_json_payload
    effect = probe_adapter([]).effect(:substrate_probe, n: 3)

    assert_instance_of Darkcore::Effect, effect
    assert_equal :substrate_probe, effect.tag
    assert_equal({ 'n' => 3 }, effect.payload)
    assert_equal effect.payload, JSON.parse(JSON.generate(effect.payload))
    refute contains_runtime_object?(effect.payload), 'payload に Proc / IO を混ぜない'
  end

  def test_zeolite_schemas_guard_both_sides_and_deliver_a_typed_value
    adapter = probe_adapter(calls = [])

    assert_raises(Gear::Port::InvalidPayload) do
      adapter.effect(:substrate_probe, { 'n' => 'three' })
    end

    invalid = probe_adapter([], invalid_result: true)
    assert_raises(Gear::Port::InvalidResult) do
      invalid.real_handlers.fetch(:substrate_probe).call('n' => 3)
    end

    out = Gear::Executor.run(
      probe_task(:typed_result, :value, 3), policy: allow, seed: 11,
                                            registry: registry_with(adapter)
    )

    assert_instance_of Berylx::Ok, out.result
    assert_equal 'probe-3', out.result.focus.to_h[:value]
    assert_equal [3], calls
  end

  def test_darkcore_berylx_and_gear_run_end_to_end_and_replay_identically
    recorded = Gear::Executor.run(
      two_probes, policy: allow, seed: 42,
                  registry: registry_with(probe_adapter(record_calls = []))
    )
    replayed = Gear::Executor.run(
      two_probes, policy: allow, seed: 42,
                  registry: registry_with(probe_adapter(replay_calls = [])),
                  journal: recorded.journal
    )

    assert_instance_of Berylx::Ok, recorded.result
    assert_instance_of Berylx::Ok, replayed.result
    assert_equal [1, 2], record_calls
    assert_empty replay_calls, '記録済み port_result は外界を再実行しない'
    assert_equal 2, recorded.journal.port_results.size
    assert_equal(2, recorded.journal.count { |entry| entry.kind == :receipt })
    assert_equal recorded.receipts, replayed.receipts
    assert_equal Gear::Journal.dump(recorded.journal), Gear::Journal.dump(replayed.journal)
  end

  def test_all_substrate_versions_are_available
    [Darkcore::VERSION, Berylx::VERSION, Zeolite::VERSION, Gear::VERSION].each do |version|
      assert_kind_of String, version
      refute_empty version
    end
  end

  private

  def contains_runtime_object?(value)
    return true if value.is_a?(Proc) || value.is_a?(IO)
    if value.is_a?(Hash)
      return value.any? do |key, item|
        contains_runtime_object?(key) || contains_runtime_object?(item)
      end
    end
    return value.any? { |item| contains_runtime_object?(item) } if value.is_a?(Array)

    false
  end
end
