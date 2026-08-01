# frozen_string_literal: true

# test_helper.rb は統合担当の territory なので、ここでは直接必要物だけ require する。
# Rake の TestTask が 'lib' を $LOAD_PATH に足すので `require 'gear'` で足りる。
require 'minitest/autorun'
require 'gear'

# Gear::Journal — 状態の正本。spec の journal.* pin を「実測」で示す。
class GearJournalTest < Minitest::Test
  J = Gear::Journal

  # -- append-only ---------------------------------------------------------

  def test_append_returns_new_log_and_leaves_past_entries_untouched
    e0 = J::Entry.at(1, :step, 'n' => 1)
    e1 = J::Entry.at(2, :step, 'n' => 2)
    log0 = J::Log.new([e0])

    log1 = log0.append(e1)

    # 過去 (log0) は一切変わらない。
    assert_equal 1, log0.size
    assert_equal [e0], log0.to_a
    # 追記後 (log1) にだけ新 entry が居る。
    assert_equal 2, log1.size
    assert_equal [e0, e1], log1.to_a
    # 追記の前後で「過去 entry そのもの」が同一値のまま。
    assert_equal e0, log1.to_a.first
  end

  def test_no_rewrite_or_delete_api_exists
    log = J::Log.new([J::Entry.at(1, :step, 'n' => 1)])

    %i[delete delete_at rewrite update []= clear pop shift insert].each do |m|
      refute_respond_to log, m, "書き換え/削除 API (#{m}) を生やしてはいけない"
    end
    # entry は immutable な値。
    assert log.to_a.first.frozen?
    assert log.frozen?
  end

  # -- fold で現在状態を導く ----------------------------------------------

  def test_fold_derives_current_state
    log = J::Log.new([
                       J::Entry.at(1, :step, 'n' => 1),
                       J::Entry.at(2, :step, 'n' => 4),
                       J::Entry.at(3, :step, 'n' => 5)
                     ])

    sum = log.fold(0) { |acc, e| acc + e.payload['n'] }
    assert_equal 10, sum
  end

  def test_fold_is_deterministic_from_the_same_journal
    log = J::Log.new([
                       J::Entry.at(1, :step, 'n' => 3),
                       J::Entry.at(2, :step, 'n' => 7)
                     ])

    reducer = ->(acc, e) { acc + e.payload['n'] }
    # 何度畳み込んでも同じ状態が出る (正本が journal 一つに定まっている)。
    assert_equal log.fold(0, &reducer), log.fold(0, &reducer)
  end

  def test_fold_keeps_no_shadow_state_between_calls
    log = J::Log.new([J::Entry.at(1, :step, 'n' => 2)])

    # 別々の reducer を続けて畳み込んでも互いに漏れない
    # (= Log が畳み込み結果をキャッシュしていない)。
    count = log.fold(0) { |acc, _| acc + 1 }
    total = log.fold(0) { |acc, e| acc + e.payload['n'] }

    assert_equal 1, count
    assert_equal 2, total
  end

  # -- 外界 port の結果を記録し、replay で読み戻す ------------------------

  # 記録された境界を通す小さな「プログラム」。外界 (時刻・ネットワーク) は
  # boundary 経由、seed 由来の乱数は再現できるので boundary を通さない。
  def run_program(boundary, seed, outside:)
    rng = Random.new(seed)
    t    = boundary.call(1, :clock) { outside.call(:clock) }
    body = boundary.call(2, :http)  { outside.call(:http) }
    r    = rng.rand(1000) # seed から再現される決定論的乱数
    { t: t, body: body, r: r, log: boundary.log }
  end

  def test_records_external_results_and_replay_reproduces_the_run
    seed = 42

    # --- 記録走行: 実際に外界を叩き、結果を journal に記録する。
    live = ->(port) { port == :clock ? 1_722_000_000 : 'live-body' }
    rec = J::RecordedBoundary.recording
    first = run_program(rec, seed, outside: live)

    # 外界結果が PORT_RESULT として journal に載っている。
    assert_equal 2, first[:log].port_results.size
    assert_equal %w[clock http], first[:log].port_results.map { |e| e.payload['port'] }

    # --- 再生走行: 同じ journal + 同じ seed。外界は「触れたら失敗」にする。
    #     replay が block を呼ばない (= 外界を再実行しない) ことをこれで実測する。
    forbidden = ->(_port) { flunk('replay が外界を再実行した (境界の踏み越え)') }
    rep = J::RecordedBoundary.replaying(first[:log])
    second = run_program(rep, seed, outside: forbidden)

    # 記録された外界結果が読み戻り、同じ走行になる。
    assert_equal first[:t], second[:t]
    assert_equal first[:body], second[:body]
    # seed 由来の乱数も一致する (pin: determinism = journal_and_seed)。
    assert_equal first[:r], second[:r]
  end

  def test_determinism_depends_on_the_seed
    live = ->(_port) { 0 }
    rec = J::RecordedBoundary.recording
    a = run_program(rec, 1, outside: live)

    rep = J::RecordedBoundary.replaying(a[:log])
    # 同じ journal でも seed が違えば seed 由来の乱数は変わる
    # (= 決定論は journal “と” seed の両方に依る)。
    b = run_program(rep, 2, outside: ->(_p) { flunk('外界再実行') })

    refute_equal a[:r], b[:r]
  end

  def test_replay_scope_boundary_is_explicit_when_records_run_out
    # 記録が 1 件しかない journal を、2 件叩くプログラムで replay すると
    # 記録された境界を踏み越え、明示的な例外になる。
    log = J::Log.new([J::Entry.at(1, J::PORT_RESULT, 'port' => 'clock', 'result' => 7)])
    rep = J::RecordedBoundary.replaying(log)

    assert_equal 7, rep.call(1, :clock) { flunk('再実行') }
    assert_raises(J::CrossedBoundary) do
      rep.call(2, :http) { flunk('再実行') }
    end
  end

  # -- 物理形式 (NDJSON) の round-trip ------------------------------------

  def test_ndjson_round_trip_preserves_entries
    log = J::Log.new([
                       J::Entry.at(1, :step, 'n' => 1),
                       J::Entry.at(2, J::PORT_RESULT, 'port' => 'clock', 'result' => 1_722_000_000),
                       J::Entry.at(3, J::PORT_RESULT, 'port' => 'http', 'result' => 'live-body')
                     ])

    text = J.dump(log)
    reloaded = J.load(text)

    assert_equal log.to_a, reloaded.to_a
    # 読み戻した journal からも同じ状態が畳み込める (replay の土台)。
    ticks = ->(acc, e) { acc + e.tick }
    assert_equal log.fold(0, &ticks), reloaded.fold(0, &ticks)
  end

  def test_ndjson_is_one_json_object_per_line
    log = J::Log.new([J::Entry.at(1, :step, 'n' => 1), J::Entry.at(2, :step, 'n' => 2)])
    lines = J.dump(log).each_line.map(&:chomp).reject(&:empty?)

    assert_equal 2, lines.size
    lines.each { |line| assert_kind_of Hash, JSON.parse(line) }
  end
end
