# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'gear'

# ==================================================================
# Gear::Receipt のテスト。
#
# receipt は「何が、何を根拠に許されて起きたか」を残す値。
# ここで示すこと:
#   - effect と grounds の両方を持つ (pin receipt.carries_grounds)
#   - 同じ入力から同じ id が導かれる (決定論 / tick.no_ambient_random 精神)
#   - predecessor を辿って鎖が遡れる (pin receipt.chainable)
#   - 壊れた鎖 (存在しない先行 / 循環) を検出できる
#   - シリアライズ round-trip で同値に戻る (journal に載る前提)
#   - grounds に admission の verdict を入れられる (接続点)
# ==================================================================
class GearReceiptTest < Minitest::Test
  # admission (W3) はまだ空なので、最小のダミー verdict をここに置く。
  # 「admission の verdict を根拠として受け取る」接続点だけは必ず用意する。
  # to_h を持つので、そのまま grounds に渡せば要約される。
  DummyVerdict = Data.define(:allowed, :policy, :reasons) do
    def to_h = { allowed: allowed, policy: policy, reasons: reasons }
  end

  def sample_effect
    # darkcore の単一 Effect 型に載る作用。tag/payload を持つ。
    Darkcore.op(:fs_write, { path: '/tmp/x', bytes: 3 })
  end

  def sample_verdict
    DummyVerdict.new(allowed: true, policy: 'fs.write.allow', reasons: ['within sandbox'])
  end

  def test_carries_effect_and_grounds
    r = Gear::Receipt.issue(
      effect: sample_effect,
      outcome: Gear::Receipt.ok('written'),
      grounds: sample_verdict,
      tick: 7
    )

    # 何が起きたか (effect の要約)
    assert_equal 'fs_write', r.effect['tag']
    assert_equal({ 'path' => '/tmp/x', 'bytes' => 3 }, r.effect['payload'])

    # 何が許可したか (grounds)
    assert_predicate r, :grounded?, 'grounds を持つべき'
    assert_equal 'fs.write.allow', r.grounds['policy']

    # 結果
    assert_predicate r, :succeeded?
    assert_equal 'written', r.outcome['value']
  end

  def test_effect_summary_drops_raw_continuation
    r = Gear::Receipt.issue(
      effect: sample_effect,
      outcome: Gear::Receipt.ok,
      grounds: sample_verdict,
      tick: 1
    )
    # receipt は tag/payload だけを保持し、生の継続 k (Proc) を持たない。
    refute r.effect.key?('k'), 'receipt に生の継続を持ち込まない'
    refute_includes r.effect.values, sample_effect.k
  end

  def test_deterministic_id
    args = {
      effect: sample_effect,
      outcome: Gear::Receipt.ok('written'),
      grounds: sample_verdict,
      tick: 7
    }
    a = Gear::Receipt.issue(**args)
    b = Gear::Receipt.issue(**args)

    assert_equal a.id, b.id, '同じ入力からは同じ id が導かれる'
    assert_equal a, b, '同値になる'
  end

  def test_id_changes_with_content
    base = {
      effect: sample_effect,
      outcome: Gear::Receipt.ok('written'),
      grounds: sample_verdict,
      tick: 7
    }
    a = Gear::Receipt.issue(**base)
    b = Gear::Receipt.issue(**base, tick: 8)

    refute_equal a.id, b.id, 'tick が違えば id も違う'
  end

  def test_chain_ancestors
    # root <- mid <- leaf の鎖を作る。
    root = Gear::Receipt.issue(effect: { tag: :boot }, outcome: Gear::Receipt.ok,
                               grounds: sample_verdict, tick: 0)
    mid  = Gear::Receipt.issue(effect: { tag: :step }, outcome: Gear::Receipt.ok,
                               grounds: sample_verdict, tick: 1, predecessor: root)
    leaf = Gear::Receipt.issue(effect: { tag: :done }, outcome: Gear::Receipt.ok,
                               grounds: sample_verdict, tick: 2, predecessor: mid)

    store = [root, mid, leaf]

    # 先行を辿って鎖が遡れる (近い順)。
    assert_equal [mid, root], leaf.ancestors(store)
    assert_equal [root], mid.ancestors(store)
    assert_empty root.ancestors(store)
    assert_predicate root, :root?
    refute_predicate leaf, :root?

    assert Gear::Receipt.chain_ok?(store), '健全な鎖'
  end

  def test_detects_dangling_predecessor
    orphan = Gear::Receipt.issue(
      effect: { tag: :step }, outcome: Gear::Receipt.ok,
      grounds: sample_verdict, tick: 1, predecessor: 'nonexistent-id'
    )
    store = [orphan]

    refute Gear::Receipt.chain_ok?(store)
    assert_includes Gear::Receipt.audit(store)[:dangling], orphan

    # 辿ろうとすると壊れた鎖として上がる。
    assert_raises(Gear::Receipt::BrokenChain) { orphan.ancestors(store) }
  end

  def test_detects_cycle
    # id を手で固定して循環を強制する (通常の issue では id が内容依存なので
    # 循環は作れない = 内容から鎖は前向きにしか伸びない)。
    a = Gear::Receipt.new(id: 'a', tick: 0, effect: { 'tag' => 'a' },
                          outcome: Gear::Receipt.ok, grounds: {}, predecessor: 'b')
    b = Gear::Receipt.new(id: 'b', tick: 1, effect: { 'tag' => 'b' },
                          outcome: Gear::Receipt.ok, grounds: {}, predecessor: 'a')
    store = [a, b]

    refute Gear::Receipt.chain_ok?(store)
    cyclic = Gear::Receipt.audit(store)[:cyclic]

    assert_includes cyclic, a
    assert_includes cyclic, b

    assert_raises(Gear::Receipt::BrokenChain) { a.ancestors(store) }
  end

  def test_serialization_round_trip
    r = Gear::Receipt.issue(
      effect: sample_effect,
      outcome: Gear::Receipt.ok('written'),
      grounds: sample_verdict,
      tick: 42,
      predecessor: 'prev-id'
    )

    # Hash 経由
    assert_equal r, Gear::Receipt.from_h(r.to_h)

    # JSON 経由 (journal に載る前提の serializable 性)
    restored = Gear::Receipt.from_json(r.to_json)

    assert_equal r, restored
    assert_equal r.id, restored.id
    assert_equal r.grounds, restored.grounds
  end

  def test_grounds_accepts_admission_verdict
    # admission の verdict を根拠として受け取れる (接続点)。
    verdict = sample_verdict
    r = Gear::Receipt.issue(
      effect: sample_effect,
      outcome: Gear::Receipt.ok,
      grounds: verdict,
      tick: 3
    )

    assert r.grounds['allowed']
    assert_equal 'fs.write.allow', r.grounds['policy']
    assert_equal ['within sandbox'], r.grounds['reasons']
  end
end
