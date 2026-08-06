# frozen_string_literal: true

require 'minitest/autorun'
require 'gear'

# ==================================================================
# Gear::Machine::Ledger — 受付の台帳を実測で示す。
#
#   - 追記しかできず、順序が残る
#   - ticket で引ける / kind で引ける / いまの状態が読める
#   - 走行の journal を正本への索引として覚える
# ==================================================================
class GearMachineLedgerTest < Minitest::Test
  Ledger = Gear::Machine::Ledger

  def test_appends_in_order_and_keeps_them
    ledger = Ledger.new
    ledger.append(ticket: 1, kind: Ledger::ACCEPTED)
    ledger.append(ticket: 2, kind: Ledger::DENIED, payload: { 'reason' => '渡されていない' })
    ledger.append(ticket: 1, kind: Ledger::COMPLETED, payload: { 'receipts' => 2 })

    assert_equal 3, ledger.size
    assert_equal %i[accepted denied completed], ledger.to_a.map(&:kind)
  end

  def test_queried_by_ticket_and_by_kind
    ledger = Ledger.new
    ledger.append(ticket: 1, kind: Ledger::ACCEPTED)
    ledger.append(ticket: 2, kind: Ledger::ACCEPTED)
    ledger.append(ticket: 1, kind: Ledger::COMPLETED)

    assert_equal %i[accepted completed], ledger.for_ticket(1).map(&:kind)
    assert_equal [1, 2], ledger.of_kind(Ledger::ACCEPTED).map(&:ticket)
  end

  def test_state_of_is_the_latest_kind
    ledger = Ledger.new
    ledger.append(ticket: 1, kind: Ledger::ACCEPTED)

    assert_equal Ledger::ACCEPTED, ledger.state_of(1)
    ledger.append(ticket: 1, kind: Ledger::SUSPENDED)

    assert_equal Ledger::SUSPENDED, ledger.state_of(1)
    assert_nil ledger.state_of(99), '知らない ticket は nil'
  end

  def test_remembers_the_run_journal_as_an_index_to_the_truth
    ledger = Ledger.new
    journal = Gear::Journal::Log.new.append(Gear::Journal::Entry.at(1, :receipt, {}))
    ledger.remember(3, journal)

    assert_equal journal, ledger.journal_for(3)
    assert_nil ledger.journal_for(4)
    assert_equal [3], ledger.journals.keys
  end

  def test_denied_payload_survives
    ledger = Ledger.new
    ledger.append(ticket: 5, kind: Ledger::DENIED, payload: { 'reason' => '深さが尽きている' })

    assert_equal '深さが尽きている', ledger.for_ticket(5).first.payload['reason']
  end
end
