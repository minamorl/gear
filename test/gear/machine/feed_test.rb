# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'socket'
require 'stringio'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# Gear::Machine::Feed — 外から投げ込む口を実測で示す。
#
#   - NDJSON を任意の IO から読んで受付列へ入れる (StringIO でも socket でも同じ口)
#   - Kit も宣言データとして運べる
#   - 壊れた行は黙って落とさず rejected に残る
#   - **unix socket 越しに投げた program を機械が実際に拾って走らせる**
# ==================================================================
class GearMachineFeedTest < Minitest::Test
  IN  = Zeolite.schema(n: :integer).named(:FeedIn)
  OUT = Zeolite.schema(n: :integer, doubled: :integer).named(:FeedOut)

  def ports(calls)
    reg = Gear::Port::Registry.new
    reg.register(
      Gear::Port::Adapter.new(:probe).operation(:probe, payload: IN, result: OUT) do |payload|
        calls << payload['n']
        { 'n' => payload['n'], 'doubled' => payload['n'] * 2 }
      end
    )
    reg
  end

  def programs
    Gear::Program::Registry.new.register(name: :double, task: double_task, input: IN, output: OUT)
  end

  def double_task
    Berylx::Task[:double] { |lay, io| lay.put(:doubled, io.perform(:probe, { 'n' => lay[:n].fetch }).doubled) }
  end

  def kit_hash
    { 'ports' => %w[probe program_submit], 'programs' => %w[double], 'depth' => 1 }
  end

  def line(name, value, kit: nil)
    JSON.generate({ 'name' => name, 'focus' => { 'n' => value }, 'kit' => kit }.compact)
  end

  def feed_for(text, intake: Gear::Machine::Intake.new)
    Gear::Machine::Feed.new(io: StringIO.new(text), intake: intake)
  end

  def test_absorbs_ndjson_into_the_intake
    intake = Gear::Machine::Intake.new
    feed = feed_for("#{line('double', 1)}\n#{line('double', 2)}\n", intake: intake)
    taken = feed.absorb

    assert_equal 2, taken.size
    assert_equal %i[double double], taken.map(&:name)
    assert_equal [{ 'n' => 1 }, { 'n' => 2 }], taken.map(&:focus)
    assert_equal 2, intake.size
    assert_empty feed.rejected
  end

  def test_carries_the_kit_as_declaration_data
    taken = feed_for("#{line('double', 1, kit: kit_hash)}\n").absorb

    assert_equal Gear::Kit.from_h(kit_hash), taken.first.kit
  end

  def test_limit_stops_early_and_blank_lines_are_skipped
    feed = feed_for("#{line('double', 1)}\n\n#{line('double', 2)}\n")

    assert_equal 1, feed.absorb(limit: 1).size
    assert_equal 1, feed.absorb.size, '残りは次で読める'
  end

  def test_broken_lines_are_kept_not_dropped_silently
    feed = feed_for("not json\n#{line('double', 1)}\n{\"focus\":{}}\n")
    taken = feed.absorb

    assert_equal 1, taken.size, '読めた行だけ通る'
    assert_equal 2, feed.rejected.size, '壊れた行は黙って消えない'
    assert_match(/JSON として読めない/, feed.rejected.first.reason)
    assert_match(/name が無い/, feed.rejected.last.reason)
  end

  # ---- unix socket 越しに投げた program を機械が拾って走らせる ----
  def test_a_program_thrown_over_a_unix_socket_is_picked_up_and_run
    outside, inside = UNIXSocket.pair
    intake = Gear::Machine::Intake.new
    machine = Gear::Machine.new(programs: programs, ports: ports(calls = []), intake: intake)

    outside.write("#{line('double', 2, kit: kit_hash)}\n#{line('double', 5, kit: kit_hash)}\n")
    outside.close

    taken = Gear::Machine::Feed.new(io: inside, intake: intake).absorb

    assert_equal 2, taken.size, 'socket 越しに 2 件届いた'

    done = machine.drain

    assert_equal 2, done.size
    assert_equal [2, 5], calls, '外から投げた program が実際に走った'
    assert_equal({ 'n' => 2, 'doubled' => 4 }, done.first.produced)
    assert_equal({ 'n' => 5, 'doubled' => 10 }, done.last.produced)
  ensure
    inside&.close
  end
end
