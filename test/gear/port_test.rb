# frozen_string_literal: true

require 'minitest/autorun'
require 'json'
require 'socket'
require 'gear'

# ==================================================================
# port adapter の骨格を実測で示す。
#   - adapter が返すのは実行前の Darkcore::Effect (走らせず覗ける)
#   - handler を差し替えると同じ Effect が別の圏で解釈される
#   - shell adapter が実際に echo を走らせて期待通りの結果を返す
#   - 結果が zeolite schema で検証され型の付いた値として返る
#   - 結果がシリアライズ可能 (journal 記録の前提)
#   - registry に登録した adapter が tag から引ける
# 本物の外部ネットワークは叩かない。HTTP はローカル TCPServer か
# handler 差し替えで検査する。
# ==================================================================
class GearPortTest < Minitest::Test
  Port  = Gear::Port
  Shell = Gear::Port::Shell::ADAPTER
  Http  = Gear::Port::Http::ADAPTER

  # ---- Effect は実行前のデータ ----------------------------------
  def test_effect_is_unexecuted_and_inspectable
    eff = Shell.effect(:shell_run, cmd: 'echo hi')

    assert_instance_of Darkcore::Effect, eff
    refute eff.closed?, '外界 op はまだ閉じていない (継続を持つ)'

    # 走らせずに tag と payload を覗ける (pin port.effect_substrate)。
    state = Darkcore.step(eff)
    assert_instance_of Darkcore::Pending, state
    assert_equal :shell_run, state.tag
    assert_equal({ 'cmd' => 'echo hi' }, state.payload)
  end

  # payload の正規化: symbol key は string key に落ち、素データになる。
  def test_effect_payload_is_normalized_plain_data
    eff = Shell.effect(:shell_run, cmd: 'echo hi')
    payload = Darkcore.step(eff).payload
    # journal 記録可能な素の値であること。
    assert_equal payload, JSON.parse(JSON.generate(payload))
  end

  # ---- handler 差し替えで圏が変わる ------------------------------
  def test_same_effect_different_categories
    eff = Shell.effect(:shell_run, cmd: 'echo hi')

    # 圏R — 本物の外界。実際に echo が走る。
    real = Darkcore.run(eff, Shell.real_handlers)
    assert_equal 0, real.exit_status
    assert_equal "hi\n", real.stdout

    # 圏(記録用 fake) — 外界を叩かず、呼ばれた事実だけ記録して缶詰を返す。
    calls = []
    fake = Shell.handlers do |op, payload|
      calls << [op.tag, payload]
      { 'exit_status' => 0, 'stdout' => "FAKE\n", 'stderr' => '' }
    end
    faked = Darkcore.run(eff, fake)
    assert_equal "FAKE\n", faked.stdout
    assert_equal [[:shell_run, { 'cmd' => 'echo hi' }]], calls, 'fake は payload を記録した'

    # 圏(dry-run) — 何もせず型の付いたプレースホルダを返す。
    dry = Shell.handlers do |_op, _payload|
      { 'exit_status' => 0, 'stdout' => '', 'stderr' => '' }
    end
    dried = Darkcore.run(eff, dry)
    assert_equal '', dried.stdout

    # 同一 Effect が三通りに解釈された。
    assert_equal real.class, faked.class
    assert_equal real.class, dried.class
  end

  # ---- shell real handler が実際に走る ---------------------------
  def test_shell_real_handler_runs_echo
    eff = Shell.effect(:shell_run, cmd: 'echo gear')
    res = Darkcore.run(eff, Shell.real_handlers)
    assert_equal "gear\n", res.stdout
    assert_equal 0, res.exit_status
  end

  def test_shell_real_handler_captures_nonzero_exit_and_stderr
    # 破壊的でないコマンドだけ (false と、stderr へ 1 行)。
    eff = Shell.effect(:shell_run, cmd: 'echo boom 1>&2; false')
    res = Darkcore.run(eff, Shell.real_handlers)
    assert_equal 1, res.exit_status
    assert_equal "boom\n", res.stderr
    assert_equal '', res.stdout
  end

  # ---- 結果は型が付いた zeolite 値 -------------------------------
  def test_result_is_typed_value
    eff = Shell.effect(:shell_run, cmd: 'echo hi')
    res = Darkcore.run(eff, Shell.real_handlers)
    # result_schema の data_class の実体である。
    assert_instance_of Gear::Port::Shell::RESULT.data_class, res
    # 宣言したフィールドが reader として生えている。
    assert_respond_to res, :exit_status
    assert_respond_to res, :stdout
    assert_respond_to res, :stderr
  end

  # ---- 結果はシリアライズ可能 (journal 記録の前提) ---------------
  def test_result_is_serializable
    eff = Shell.effect(:shell_run, cmd: 'echo hi')
    res = Darkcore.run(eff, Shell.real_handlers)

    dumped = JSON.generate(res.to_h)
    round = JSON.parse(dumped)
    assert_equal({ 'exit_status' => 0, 'stdout' => "hi\n", 'stderr' => '' }, round)
  end

  # ---- schema 違反は検査可能な例外になる -------------------------
  def test_invalid_payload_is_rejected
    err = assert_raises(Gear::Port::InvalidPayload) do
      Shell.effect(:shell_run, cmd: 123) # cmd は string でなければならない
    end
    assert_match(/payload/, err.message)
  end

  def test_invalid_result_is_rejected
    eff = Shell.effect(:shell_run, cmd: 'echo hi')
    bad = Shell.handlers { |_op, _p| { 'exit_status' => 'oops' } }
    assert_raises(Gear::Port::InvalidResult) { Darkcore.run(eff, bad) }
  end

  # ---- registry: tag から引ける ----------------------------------
  def test_registry_lookup_by_tag_and_name
    assert_equal :shell, Port.for_tag(:shell_run).name
    assert_equal :http, Port.for_tag(:http_request).name
    assert_same Shell, Port.adapter(:shell)
    assert_includes Port.registry.tags, :shell_run
  end

  # registry から tag で発見して Effect を作れる (発見 → 生成)。
  def test_registry_builds_effect_from_tag
    eff = Port.effect(:shell_run, cmd: 'echo hi')
    assert_equal :shell_run, Darkcore.step(eff).tag
  end

  # 全 adapter の real handler が一枚に畳まれる (単一 Effect 型)。
  def test_registry_merges_real_handlers
    handlers = Port.real_handlers
    assert_includes handlers.keys, :shell_run
    assert_includes handlers.keys, :http_request
  end

  # 未登録 tag は検査可能な例外。
  def test_unknown_tag_raises
    assert_raises(Gear::Port::UnknownTag) { Port.for_tag(:no_such_tag) }
  end

  # tag は一系統だけが握れる (衝突は登録時に弾く)。
  def test_tag_conflict_is_rejected
    reg = Gear::Port::Registry.new
    reg.register(Shell)
    intruder = Gear::Port::Adapter.new(:intruder).operation(
      :shell_run,
      payload: Gear::Port::Shell::PAYLOAD,
      result: Gear::Port::Shell::RESULT
    ) { |_p| { 'exit_status' => 0, 'stdout' => '', 'stderr' => '' } }
    assert_raises(Gear::Port::TagConflict) { reg.register(intruder) }
  end

  # ---- HTTP: Effect 生成は純粋、handler 差し替えで検査 -----------
  def test_http_effect_is_pure_and_inspectable
    eff = Http.effect(:http_request, method: 'GET', url: 'http://example.test/')
    state = Darkcore.step(eff)
    assert_equal :http_request, state.tag
    assert_equal({ 'method' => 'GET', 'url' => 'http://example.test/' }, state.payload)
  end

  def test_http_fake_handler_returns_typed_result
    eff = Http.effect(:http_request, method: 'GET', url: 'http://example.test/')
    fake = Http.handlers do |_op, _payload|
      { 'status' => 200, 'headers' => { 'Content-Type' => 'text/plain' }, 'body' => 'ok' }
    end
    res = Darkcore.run(eff, fake)
    assert_instance_of Gear::Port::Http::RESULT.data_class, res
    assert_equal 200, res.status
    assert_equal 'ok', res.body
    # 結果はシリアライズ可能。
    assert_equal 'ok', JSON.parse(JSON.generate(res.to_h))['body']
  end

  # ---- HTTP: real handler をローカル TCPServer で end-to-end -----
  def test_http_real_handler_against_local_server
    server = TCPServer.new('127.0.0.1', 0)
    port = server.addr[1]
    body = 'hello from local'
    thread = Thread.new do
      sock = server.accept
      # リクエスト行 + ヘッダを空行まで読み捨てる。
      while (line = sock.gets) && line != "\r\n"; end
      sock.write("HTTP/1.1 200 OK\r\n" \
                 "Content-Type: text/plain\r\n" \
                 "Content-Length: #{body.bytesize}\r\n" \
                 "Connection: close\r\n\r\n#{body}")
      sock.close
    end

    eff = Http.effect(:http_request, method: 'GET', url: "http://127.0.0.1:#{port}/")
    res = Darkcore.run(eff, Http.real_handlers)

    assert_equal 200, res.status
    assert_equal body, res.body
    assert_equal 'text/plain', res.headers['content-type']
  ensure
    thread&.join
    server&.close
  end
end
