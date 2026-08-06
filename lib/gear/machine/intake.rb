# frozen_string_literal: true

require 'monitor'

module Gear
  class Machine
    # ==================================================================
    # Submission — 投入 1 件の値。
    #
    # 「何を走らせたいか」を走らせる前に検査できる素のデータで持つ。Kit だけは
    # 権限そのものなので値として同行する (渡していない物は呼べないという担保は、
    # 判定用のフィールドではなく渡す物として運ぶことで成り立つ)。
    #
    # focus は境界の宣言と同じ JSON-safe な String キー。内側の symbol キーへ寄せる
    # のは走らせる段の仕事 (Executor::Submission が既に持っている)。
    # ==================================================================
    Submission = Data.define(:ticket, :name, :focus, :kit, :seed) do
      # 台帳と admission へ渡す形。Kit は宣言データへ落とす。
      def to_h
        { 'ticket' => ticket, 'name' => name.to_s, 'focus' => focus,
          'kit' => kit&.to_h, 'seed' => seed }
      end
    end

    # ==================================================================
    # Intake — 受付列。
    #
    # 「ずっとループしている実行機が、投げ込まれた program を拾う」の投げ込まれる先。
    # in-process の FIFO から始める (free ui.protocol の最も弱い commitment — socket や
    # SSE の前置きは後からこの上に被せられる)。
    #
    # ticket は連番。実時刻も乱数も使わないので、同じ順で投げれば同じ ticket が出る
    # (pin tick.no_ambient_random の精神を受付側にも通す)。
    #
    # 走行の可変状態をスレッドで壊した実測があるので、受付も最初からロックする。
    # ==================================================================
    class Intake
      def initialize
        @queue = []
        @issued = 0
        @lock = Monitor.new
      end

      # 受け付けて ticket を発行する。走らせはしない (拾うのは機械の仕事)。
      # seed 既定は ticket 番号 — 値を発明せず、決定論に必要な種を必ず持たせる。
      def offer(name:, focus: {}, kit: nil, seed: nil)
        @lock.synchronize do
          @issued += 1
          submission = Submission.new(ticket: @issued, name: name.to_sym, focus: focus,
                                      kit: kit, seed: seed || @issued)
          @queue.push(submission)
          submission
        end
      end

      # 先に投げられたものから 1 件。無ければ nil。
      def take = @lock.synchronize { @queue.shift }

      def size = @lock.synchronize { @queue.size }
      def empty? = @lock.synchronize { @queue.empty? }

      # まだ拾われていない投入 (観測用。ここを書き換えても列は動かない)。
      def pending = @lock.synchronize { @queue.dup }

      # これまでに発行した ticket の数。
      def issued = @lock.synchronize { @issued }

      # 発行済みの番号を引き継ぐ。台帳を渡して機械を建て直すとき、受付列が 1 から
      # やり直すと ticket が衝突し、resume が別の走行の journal を続けてしまう
      # (監査で再現)。既に使われた最大値まで進めておく。
      def advance_to(ticket)
        @lock.synchronize { @issued = [@issued, ticket.to_i].max }
      end
    end
  end
end
