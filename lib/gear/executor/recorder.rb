# frozen_string_literal: true

require 'monitor'

module Gear
  module Executor
    # ==================================================================
    # Recorder — 走行の記録。journal への追記と receipt 鎖の発行を握る。
    #
    # Driver から切り出した。「時間を進めて判じる」責務と「起きたことを残す」責務は
    # 別物で、後者だけがここに閉じる。追記は不可分だが、**効果の実行はロックの外**
    # (内側で回すと子や兄弟の枝が同じロックを待って恒久デッドロックする)。
    #
    # 満たす pin (gear.spec):
    #   journal.append_only / is_source_of_truth : 追記のみ。走行の正本はこの log。
    #   receipt.required / no_silent_effect : 実行された効果は必ず receipt を残す。
    #     外界を叩いた後に例外が出た場合も #failure で残す — 副作用が起きたのに
    #     記録が無い状態を作らない。
    #   receipt.chainable : predecessor で直前の receipt を指す。
    #   effect.bookkeeping : 1 効果ぶんの追記は不可分。
    # ==================================================================
    class Recorder
      def initialize
        @log = Journal::Log.new
        @receipts = []
        @last = nil
        @lock = Monitor.new
      end

      def journal = @lock.synchronize { @log }
      def receipts = @lock.synchronize { @receipts.dup }

      # 実行された効果を残す。外界結果を持つものは port_result も積む。
      def effect(tick:, tag:, payload:, recorded:, verdict:, external:)
        @lock.synchronize do
          if external
            append(tick, Journal::PORT_RESULT,
                   'port' => tag.to_s, 'payload' => payload, 'result' => recorded)
          end
          issue(tick, tag, payload, Receipt.ok(recorded), verdict)
        end
      end

      # 外界を叩いた後に失敗した効果を残す。receipt 無しの実行を作らない。
      def failure(tick:, tag:, payload:, verdict:, error:)
        @lock.synchronize do
          append(tick, :effect_failed,
                 'port' => tag.to_s, 'payload' => payload,
                 'error' => error.class.name, 'message' => error.message.to_s)
          issue(tick, tag, payload, Receipt.err("#{error.class}: #{error.message}"), verdict)
        end
      end

      # 拒否を残す。副作用は起きていないので receipt は出さない。
      def denial(tick:, tag:, payload:, verdict:)
        @lock.synchronize do
          append(tick, :admission_denied,
                 'tag' => tag.to_s, 'payload' => payload,
                 'reason' => verdict.reason.to_s, 'by' => verdict.by.to_s)
        end
      end

      private

      def append(tick, kind, payload)
        @log = @log.append(Journal::Entry.at(tick, kind, payload))
      end

      def issue(tick, tag, payload, outcome, verdict)
        receipt = Receipt.issue(effect: { tag: tag, payload: payload }, outcome: outcome,
                                grounds: verdict, tick: tick, predecessor: @last)
        append(tick, :receipt, receipt.to_h)
        @receipts << receipt
        @last = receipt
        receipt
      end
    end
  end
end
