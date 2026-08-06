# frozen_string_literal: true

require 'monitor'
require 'darkcore'
require 'berylx'

module Gear
  module Executor
    # ==================================================================
    # Driver — 五点セット (Clock / Admission / Executor / Journal / Receipt)
    # を一本の走行に綴じる本体。berylx program を darkcore Effect 木として
    # 走らせ、外界に触れる一歩ごとに admission ゲートを通し、receipt を発行し、
    # journal へ追記する。
    #
    # 満たす pin (gear.spec):
    #   program.representation   : 実行対象は berylx の Task 合成。gear 独自 DSL を
    #                              作らない。Berylx::EffectTree で darkcore Effect 木へ
    #                              compile し、Darkcore.fold のトランポリンで走らせる。
    #   program.no_private_dsl   : 走行の入口は berylx ノードのみ。効果は Task 本体が
    #                              Berylx::Perform 経由で発行する tag/payload だけ。
    #   program.interruptible    : max_effects で任意の一歩手前まで走らせて中断でき、
    #                              その journal を渡して残りを再開できる (suspendable_
    #                              resumable)。中断は StandardError でない Suspend で
    #                              トランポリンを抜けるので Task#call の rescue に
    #                              捕まらない。
    #   admission.precedes_effect: gate は必ず judge を先に行い、Admitted のときしか
    #                              外界を叩かない。ここが唯一の外界経路。
    #   admission.no_bypass      : 効果 tag は全て gate 済み handler に差し替えて
    #                              Perform へ渡す。生の real handler を直接渡す経路は無い。
    #   admission.denial_is_value: judge は Denied 値を返す。gate はそれを journal に
    #                              記録し、berylx の結果封筒 Err として program を閉じる
    #                              (例外は Err への翻訳手段であって判定そのものではない)。
    #   receipt.required         : 実行された効果には必ず Receipt.issue で receipt を出す。
    #   receipt.no_silent_effect : port_result を journal に積む一歩と receipt を出す一歩は
    #                              同じ gate の中。silent な効果 (receipt 無しの実行) は無い。
    #   receipt.chainable        : receipt は predecessor で直前の receipt を指し鎖になる。
    #   tick.total_order         : 効果一つにつき Clock を 1 tick 進める。全順序の index を
    #                              receipt/journal に刻む。
    #   journal.is_source_of_truth / state_is_fold : 走行の正本は出力 journal。現在状態は
    #                              その畳み込みとして berylx の focus に現れる。
    #   journal.records_external_results : 外界結果は port_result entry として記録する。
    #   journal.replay_deterministic / records_external_results :
    #                              入力 journal に記録済みの外界結果は「再実行せず読み戻す」。
    #                              記録の外に出た効果だけ実際に叩く。同じ journal と同じ
    #                              seed からは同じ receipt 列・同じ journal が再生される。
    # ==================================================================
    class Driver
      # submit の入れ子の上限。Kit を渡していない走行でも無限入れ子を構造で止める。
      MAX_SUBMIT_DEPTH = 32

      # replay_source : 記録済み外界結果の読み戻し元 (Journal::Log)。空なら全て実走。
      # max_effects   : 何個目の効果の手前で中断するか。nil なら中断しない。
      def initialize(clock:, policy:, registry:, replay_source:, max_effects:, kit: nil,
                     programs: Program::Registry.new)
        @clock = clock
        @lock = Monitor.new # 走行の可変状態を触る区間だけを不可分にする
        @kit = kit # 走行に渡された範囲。入れ子では handler へ閉じ込めて渡す
        @authority = Authority.new(policy: policy)
        @submission = Submission.new(programs: programs)
        @registry = registry
        @real = registry.real_handlers # tag => 型検証済みの実 handler
        @replay = Replay.new(recorded: replay_source.port_results, registry: registry)
        @max_effects = max_effects

        @recorder = Recorder.new # 記録は別責務 (追記と receipt 鎖)
        @processed = 0 # 処理した効果数 (replay + 実走)
      end

      def run(program, focus)
        result = fold(program, focus, @kit, 0)
        outcome(result, suspended: false)
      rescue Suspend
        # 予算に達したので、記録した分を持って中断する。program の結果は未確定。
        outcome(nil, suspended: true)
      end

      private

      # 登録された全 tag を「gate を通す handler」に差し替える。Task 本体からの
      # perform はこの gate 済み handler にしか届かない (admission.no_bypass)。
      #
      # Kit と入れ子の深さは**この handler に閉じ込める**。共有スタックで持つと並列
      # 分岐 (Thread) の枝どうしで壊れ、ロックで守ると子の fold をロック内で回して
      # 恒久デッドロックする (どちらも実測)。fold ごとに handler を作れば、枝が何本
      # 走っても各枝は自分の範囲だけを見る。
      def handlers_for(kit, depth)
        Berylx::EffectTree.real_handlers(
          (@registry.tags + [Clock::RANDOM_TAG, Program::SUBMIT_TAG]).to_h do |tag|
            [tag, ->(payload) { gate(tag, payload, kit, depth) }]
          end
        )
      end

      # 効果一つ分の綴じ目。judge → (Denied なら記録して閉じる / Admitted なら
      # 読み戻すか実走して receipt を出す) → 結果を Task へ返す。
      #
      # ロックは**走行の可変状態を触る区間だけ**にかける。実外界呼び出しと子 program の
      # fold をロックの内側で回すと、子や兄弟の枝が同じロックを待ち、こちらは枝の join を
      # 待って永久に噛み合う (監査で恒久デッドロックを再現)。記録は不可分、実行は並行。
      def gate(tag, payload, kit, depth)
        payload = Port.normalize(payload) # 素の string-key データに揃える (記録可能に)
        tick, verdict = admit(tag, payload, kit)
        return deny(tick, tag, payload, verdict) if verdict.denied?

        value, recorded, external = obtain(tick, tag, payload, kit, depth, verdict)
        commit(tick, tag, payload, recorded, verdict, external: external)
        value
      end

      # 予算・tick・judge を不可分に済ませる。予算は「始めた時点」で数える
      # (完了時に数えると入れ子の深さぶん超える)。
      def admit(tag, payload, kit)
        @lock.synchronize do
          raise Suspend if @max_effects && @processed >= @max_effects

          tick = @clock.advance # 効果一つにつき 1 tick (tick.total_order)
          request = Admission::Request.new(tag: tag, payload: payload)
          verdict = @authority.judge(request, kit: kit)
          @processed += 1 unless verdict.denied?
          [tick, verdict]
        end
      end

      def outcome(result, suspended:)
        Outcome.new(result: result, journal: @recorder.journal, receipts: @recorder.receipts,
                    suspended: suspended, last_tick: @clock.current.index)
      end

      def commit(tick, tag, payload, recorded, verdict, external:)
        @recorder.effect(tick: tick.index, tag: tag, payload: payload,
                         recorded: recorded, verdict: verdict, external: external)
      end

      # Admitted。記録済み境界の内側なら読み戻し (再実行しない)、外なら実走する。
      # 返り値は [Task へ渡す型付き値, journal に積む素データ]。
      def obtain(tick, tag, payload, kit, depth, verdict)
        return obtain_random(tick, payload) if tag == Clock::RANDOM_TAG
        return obtain_submit(payload, kit, depth) if tag == Program::SUBMIT_TAG

        # 記録済み境界の内側は Replay が読み戻す (外界を叩かない)。cursor の消費は
        # 不可分にする (並列の枝が同時に読み戻すと取り違える)。
        recorded = @lock.synchronize { @replay.exhausted? ? nil : @replay.read_back(tag, tick, payload) }
        return [*recorded, true] if recorded

        [*call_external(tick, tag, payload, verdict), true]
      end

      # 唯一の実外界呼び出し。ロックの外なので並列の枝は本当に並列に走る。
      # 叩いた後に失敗しても「叩いた」ことは残す — 副作用が起きたのに receipt が
      # 無い状態を作らない (pin receipt.no_silent_effect)。記録してから raise し直す。
      def call_external(tick, tag, payload, verdict)
        value = @real.fetch(tag).call(payload)
        [value, Port.normalize(value.to_h)]
      rescue StandardError => e
        @recorder.failure(tick: tick.index, tag: tag, payload: payload, verdict: verdict, error: e)
        raise
      end

      # 子 program を親と同じ clock / journal / receipt 鎖の上で inline に走らせる。
      # 子の効果は子自身の port_result として journal に載るので、submit 自体は外界
      # 結果を持たない (external: false)。replay では子を走らせ直し、子の効果が
      # 記録を順に読み戻すので cursor が揺れない。
      # 子は一段細めた Kit と 1 つ深い深さで走る。Kit が nil のときは細める先が無く
      # 深さも減らないので、機械側の上限で無限入れ子を止める (実測: 自己 submit が
      # SystemStackError になり journal も台帳も残らなかった)。
      def obtain_submit(payload, kit, depth)
        raise Program::TooDeep, "submit の入れ子が上限 #{MAX_SUBMIT_DEPTH} を超えた" if depth >= MAX_SUBMIT_DEPTH

        child_kit = kit&.descend
        produced = @submission.run(payload) do |task, focus|
          fold(task, child_kit ? Executor.focus_with_kit(focus, child_kit) : focus, child_kit, depth + 1)
        end
        [produced, produced, false]
      end

      # berylx program を darkcore Effect 木へ compile して 1 本走らせる。
      # handler は fold ごとに作る (Kit と深さをそこへ閉じ込めるため)。
      def fold(task, focus, kit, depth)
        Darkcore.fold(Berylx::EffectTree.build(task, focus),
                      on_return: ->(x) { x }, handlers: handlers_for(kit, depth))
      end

      # seed と tick だけから導き、replay cursor と port_result には触れない。
      def obtain_random(tick, payload)
        checked = Clock::RANDOM_PAYLOAD.load(payload)
        unless checked.ok?
          raise Port::InvalidPayload,
                "clock##{Clock::RANDOM_TAG} payload 不正: #{checked.violations.join('; ')}"
        end

        bound = checked.value.bound
        raise Port::InvalidPayload, 'clock_random bound は正の Integer にする' unless bound.positive?

        raw = { 'value' => @clock.rng_for(tick).rand(bound) }
        [Clock::RANDOM_RESULT.load(raw).value, raw, false]
      end

      # Denied。副作用を起こさず拒否を記録し、program を Err で閉じる。
      # AdmissionDenied は StandardError なので Task#call の rescue が Err に翻訳する
      # (admission.denial_is_value: 判定は値、例外はその閉じ方の実装手段)。
      def deny(tick, tag, payload, verdict)
        @recorder.denial(tick: tick.index, tag: tag, payload: payload, verdict: verdict)
        raise AdmissionDenied, verdict
      end
    end
  end
end
