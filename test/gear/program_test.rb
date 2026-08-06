# frozen_string_literal: true

require 'minitest/autorun'
require 'gear'
require 'berylx'
require 'zeolite'

# ==================================================================
# Gear::Program — 実行機に乗る前の一段を実測で示す。
#
#   - 宣言 (name / task / 入力 / 出力) が欠けた登録を受けない
#   - 未登録の名前は引けない (素の Task が実行機へ回る経路が無い)
#   - 境界は zeolite schema なので走らせる前に検査できる
#   - 出力の名前で「食べられる相手」を挙げられる (網の材料。選ぶ基準は決めない)
# ==================================================================
class GearProgramTest < Minitest::Test
  RAW  = Zeolite.schema(url: :string).named(:RawInput)
  DOC  = Zeolite.schema(body: :string).named(:Document)
  WORD = Zeolite.schema(count: :integer).named(:WordCount)

  def task(name) = Berylx::Task[name] { |lay, _io| lay }

  def registry
    reg = Gear::Program::Registry.new
    reg.register(name: :fetch, task: task(:fetch), input: RAW, output: DOC)
    reg.register(name: :count, task: task(:count), input: DOC, output: WORD)
    reg.register(name: :index, task: task(:index), input: DOC, output: WORD)
    reg
  end

  def test_registers_and_fetches_with_declaration
    decl = registry.fetch(:fetch)

    assert_equal :fetch, decl.name
    assert_equal :RawInput, decl.input_label
    assert_equal :Document, decl.output_label
    assert_equal %i[count fetch index], registry.names
  end

  def test_registration_without_declaration_is_refused
    reg = Gear::Program::Registry.new

    assert_raises(ArgumentError) { reg.register(name: :bare, task: task(:bare), input: nil, output: DOC) }
    assert_raises(ArgumentError) { reg.register(name: :bare, task: task(:bare), input: RAW, output: nil) }
    assert_empty reg.names, '宣言が欠けた program は名簿に入らない'
  end

  def test_duplicate_registration_is_refused
    reg = registry

    assert_raises(ArgumentError) { reg.register(name: :fetch, task: task(:fetch), input: RAW, output: DOC) }
  end

  def test_unregistered_name_cannot_be_fetched
    error = assert_raises(KeyError) { registry.fetch(:nope) }

    assert_match(/素の Task は実行機に乗らない/, error.message)
  end

  def test_boundary_is_checkable_before_running
    decl = registry.fetch(:count)

    assert decl.accepts?({ 'body' => 'hello' })
    refute decl.accepts?({ 'url' => 'http://example.com' })
    assert decl.produces?({ 'count' => 1 })
    refute decl.produces?({ 'count' => 'many' })
  end

  def test_candidates_are_matched_by_boundary_name
    assert_equal %i[count index], registry.candidates_for(:fetch), '出力 Document を食べる相手'
    assert_empty registry.candidates_for(:count), 'WordCount を食べる相手は居ない'
  end
end
