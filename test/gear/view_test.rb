# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# Gear::View — journal を描く面を実測で示す。
#
#   - 投影は journal の畳み込み。view 側に状態が残らない (同じ journal なら同じ絵)
#   - 同じ journal に複数の renderer が同時に立つ
#   - journal が伸びれば絵も伸びる (view を作り直さなくてよい)
#   - view からの入力は状態を書き換えず program として機械へ入る
# ==================================================================
class GearViewTest < Minitest::Test
  IN  = Zeolite.schema(n: :integer).named(:ViewIn)
  OUT = Zeolite.schema(n: :integer, doubled: :integer).named(:ViewOut)

  def ports
    reg = Gear::Port::Registry.new
    reg.register(
      Gear::Port::Adapter.new(:probe).operation(:probe, payload: IN, result: OUT) do |payload|
        { 'n' => payload['n'], 'doubled' => payload['n'] * 2 }
      end
    )
    reg
  end

  def programs
    Gear::Program::Registry.new.register(
      name: :double, task: double_task, input: IN, output: OUT
    )
  end

  def double_task
    Berylx::Task[:double] { |lay, io| lay.put(:doubled, io.perform(:probe, { 'n' => lay[:n].fetch }).doubled) }
  end

  def kit(allowed: %i[double])
    Gear::Kit.of(ports: %i[probe program_submit], programs: allowed, depth: 1)
  end

  def machine = Gear::Machine.new(programs: programs, ports: ports)

  def ran_journal(allowed: %i[double])
    m = machine
    m.submit(name: :double, focus: { 'n' => 2 }, kit: kit(allowed: allowed))
    m.step.outcome.journal
  end

  def test_projection_is_a_fold_of_the_journal
    projection = Gear::View.project(ran_journal)

    assert_equal 2, projection.last_tick
    assert_equal [{ 'tick' => 2, 'port' => 'probe' }], projection.effects
    assert_empty projection.denials
    assert_equal 2, projection.receipts.size
    refute_predicate projection, :quiet?
  end

  def test_empty_journal_is_quiet
    assert_predicate Gear::View.project(Gear::Journal::Log.new), :quiet?
  end

  def test_view_holds_no_state_of_its_own
    journal = ran_journal
    renderer = Gear::View::Text.new

    assert_equal renderer.render(journal), renderer.render(journal), '同じ journal なら同じ絵'
  end

  def test_many_renderers_stand_on_the_same_journal
    journal = ran_journal
    text = Gear::View::Text.new.render(journal)
    summary = Gear::View::Summary.new.render(journal)

    assert_match(/効果 1/, text)
    assert_match(/2 probe/, text)
    assert_equal 2, summary['last_tick']
    assert_equal summary, JSON.parse(JSON.generate(summary)), '素データの面は JSON を往復する'
  end

  def test_the_picture_grows_with_the_journal
    renderer = Gear::View::Summary.new
    short = Gear::Journal::Log.new
    long = short.append(Gear::Journal::Entry.at(5, Gear::Journal::PORT_RESULT, 'port' => 'probe'))

    assert_equal 0, renderer.render(short)['last_tick']
    assert_equal 5, renderer.render(long)['last_tick']
  end

  def test_denials_are_drawn
    text = Gear::View::Text.new.render(ran_journal(allowed: %i[other]))

    assert_match(/拒否 1/, text)
    assert_match(/渡されていない/, text)
  end

  def test_input_enters_as_a_program_and_changes_nothing_in_the_view
    m = machine
    input = Gear::View::Input.new(m)
    submission = input.request(name: :double, focus: { 'n' => 2 }, kit: kit)

    assert_equal 1, m.pending, '入力は受付列へ入る (状態を直接書かない)'
    assert_equal Gear::Machine::Ledger::ACCEPTED, m.state_of(submission.ticket)
    assert_predicate Gear::View.project(Gear::Journal::Log.new), :quiet?, 'view 側には何も残らない'
  end
end
