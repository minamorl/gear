# frozen_string_literal: true

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
      # replay_source : 記録済み外界結果の読み戻し元 (Journal::Log)。空なら全て実走。
      # max_effects   : 何個目の効果の手前で中断するか。nil なら中断しない。
      def initialize(clock:, policy:, registry:, replay_source:, max_effects:)
        @clock = clock
        @policy = policy
        @registry = registry
        @real = registry.real_handlers # tag => 型検証済みの実 handler
        @recorded = replay_source.port_results # 追記順の外界結果 (読み戻し元)
        @cursor = 0                            # @recorded の読み戻し位置
        @max_effects = max_effects

        @out = Journal::Log.new                # 出力 journal (走行の正本)
        @receipts = []                         # 発行順の receipt 列
        @last_receipt = nil                    # 鎖の直前 (predecessor)
        @processed = 0                         # 処理した効果数 (replay + 実走)
      end

      def run(program, focus)
        tree = Berylx::EffectTree.build(program, focus)
        handlers = Berylx::EffectTree.real_handlers(gated_effects)
        result = Darkcore.fold(tree, on_return: ->(x) { x }, handlers: handlers)
        Outcome.new(
          result: result, journal: @out, receipts: @receipts,
          suspended: false, last_tick: @clock.current.index
        )
      rescue Suspend
        # 予算に達したので、記録した分を持って中断する。program の結果は未確定。
        Outcome.new(
          result: nil, journal: @out, receipts: @receipts,
          suspended: true, last_tick: @clock.current.index
        )
      end

      private

      # 登録された全 tag を「gate を通す handler」に差し替える。Task 本体からの
      # perform はこの gate 済み handler にしか届かない (admission.no_bypass)。
      def gated_effects
        (@registry.tags + [Clock::RANDOM_TAG]).to_h do |tag|
          [tag, ->(payload) { gate(tag, payload) }]
        end
      end

      # 効果一つ分の綴じ目。judge → (Denied なら記録して閉じる / Admitted なら
      # 読み戻すか実走して receipt を出す) → 結果を Task へ返す。
      def gate(tag, payload)
        # 予算に達していたら、この効果の手前で中断する。tick も外界も触らない。
        raise Suspend if @max_effects && @processed >= @max_effects

        payload = Port.normalize(payload) # 素の string-key データに揃える (記録可能に)
        tick = @clock.advance             # 効果一つにつき 1 tick (tick.total_order)
        request = Admission::Request.new(tag: tag, payload: payload)
        verdict = Admission.judge(request, policy: @policy)

        return deny(tick, tag, payload, verdict) if verdict.denied?

        value, recorded, external = obtain(tick, tag, payload)
        record_effect(tick, tag, payload, recorded, verdict, external: external)
        @processed += 1
        value
      end

      # Admitted。記録済み境界の内側なら読み戻し (再実行しない)、外なら実走する。
      # 返り値は [Task へ渡す型付き値, journal に積む素データ]。
      def obtain(tick, tag, payload)
        return obtain_random(tick, payload) if tag == Clock::RANDOM_TAG

        if @cursor < @recorded.size
          entry = @recorded[@cursor]
          @cursor += 1
          recorded = entry.payload['result']
          [restore(tag, recorded), recorded, true] # 外界は叩かない (records_external_results)
        else
          value = @real.fetch(tag).call(payload) # ここが唯一の実外界呼び出し
          [value, Port.normalize(value.to_h), true]
        end
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

      # 実走の一歩を journal に綴じる: 外界結果 (port_result) と receipt を積む。
      def record_effect(tick, tag, payload, recorded, verdict, external:)
        if external
          @out = @out.append(
            Journal::Entry.at(tick.index, Journal::PORT_RESULT, 'port' => tag.to_s, 'result' => recorded)
          )
        end
        receipt = Receipt.issue(
          effect: { tag: tag, payload: payload },
          outcome: Receipt.ok(recorded),
          grounds: verdict,
          tick: tick.index,
          predecessor: @last_receipt
        )
        @out = @out.append(Journal::Entry.at(tick.index, :receipt, receipt.to_h))
        @receipts << receipt
        @last_receipt = receipt
      end

      # Denied。副作用を起こさず拒否を journal に記録し、program を Err で閉じる。
      # AdmissionDenied は StandardError なので Task#call の rescue が Err に翻訳する
      # (admission.denial_is_value: 判定は値、例外はその閉じ方の実装手段)。
      def deny(tick, tag, payload, verdict)
        @out = @out.append(
          Journal::Entry.at(
            tick.index, :admission_denied,
            'tag' => tag.to_s, 'payload' => payload,
            'reason' => verdict.reason.to_s, 'by' => verdict.by.to_s
          )
        )
        raise AdmissionDenied, verdict
      end

      # 記録済みの素データを、その tag の result schema で型付き値へ復元する。
      # replay 時に Task 本体が record 時と同じ型付き値 (r.stdout 等) を受け取れる。
      def restore(tag, recorded)
        schema = @registry.for_tag(tag).operation_for(tag).result_schema
        schema.load(Port.normalize(recorded)).value
      end
    end
  end
end
