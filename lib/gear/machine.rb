# frozen_string_literal: true

require 'berylx'
require_relative 'machine/intake'
require_relative 'machine/ledger'

module Gear
  # ==================================================================
  # Machine — 常駐する実行機。投げ込まれた program を拾って走らせる。
  #
  # 御主人様の像: 「プログラム自体はループする機関で、実行機」「それが小プログラム
  # 全体を自動でネットワークに繋ぐ」。その最初の形。
  #
  # ---- 中核を増やさない ----
  # Machine は五点セット (Clock / Admission / Executor / Journal / Receipt) の 6 つ目では
  # なく、その上に乗る受付と繰り返しの殻 (pin core.parts を破らない)。拾う操作は
  # **新しい門を作らずに program_submit 効果として表す** ので、拾った瞬間が admission を
  # 通り receipt が出る (admission.no_bypass / receipt.required / ui.input_as_program)。
  # 受付では judge しない — そこで判定すると tick も receipt も無い決定が生まれる。
  #
  # ---- 実時間で進めない ----
  # #step / #drain は「呼ばれたら 1 件 / 空になるまで」進める。実時刻を待つ loop を
  # 内側に持たないので、暗黙の実時間が走行へ混ざらない (pin tick.discrete)。実時間で
  # 起こすのは埋め込む側の仕事で、機械は歩数で進む。
  #
  # ---- 走行 1 件 = 1 run ----
  # 拾うたびに自分の clock (種は投入が持つ) と自分の journal を持つ。tick の全順序は
  # run の中で閉じる (pin tick.total_order / tick.seeded)。
  #
  # ---- 範囲外 ----
  # 分散キューにはしない (pin scope.not_distributed_scheduler)。受付は in-process から
  # 始める (free ui.protocol の最も弱い commitment)。
  # ==================================================================
  class Machine
    # 拾って走らせた 1 件の結果。
    Completion = Data.define(:ticket, :outcome) do
      def suspended? = outcome.suspended?
      def denied? = Machine.denied?(outcome)

      # 子 program が出した素データ。拒否や中断なら nil。
      def produced
        return nil if suspended? || outcome.result.is_a?(Berylx::Err)

        outcome.result.focus.to_h[:produced]
      end
    end

    def self.denied?(outcome)
      outcome.result.is_a?(Berylx::Err) &&
        outcome.journal.to_a.any? { |entry| entry.kind == :admission_denied }
    end

    attr_reader :intake, :ledger

    def initialize(programs:, ports: Port.registry, policy: Admission::Policy::AllowAll.new,
                   intake: Intake.new, ledger: Ledger.new)
      @programs = programs
      @ports = ports
      @policy = policy
      @intake = intake
      @ledger = ledger
    end

    # 投げ込む。走らせない (拾うのは #step)。判定は拾う段でまとめて通る。
    def submit(name:, focus: {}, kit: nil, seed: nil)
      submission = @intake.offer(name: name, focus: focus, kit: kit, seed: seed)
      @ledger.append(ticket: submission.ticket, kind: Ledger::ACCEPTED, payload: submission.to_h)
      submission
    end

    # 1 件拾って走らせる。列が空なら nil。
    def step(max_effects: nil)
      submission = @intake.take
      return nil if submission.nil?

      launch(submission, max_effects: max_effects)
    end

    # 列が空になるまで拾う。limit を渡せばその件数で止める。
    def drain(limit: nil, max_effects: nil)
      done = []
      done << step(max_effects: max_effects) while keep_draining?(done, limit)
      done.compact
    end

    # 中断した走行を、台帳が指す journal を種に続ける。記録済みの外界は叩き直さない。
    # 投入は台帳の受付記録から組み直すので、機械を捨てて作り直しても続けられる
    # (台帳が JSON-safe な素データであることがそのまま可搬性になっている)。
    def resume(ticket, max_effects: nil)
      journal = @ledger.journal_for(ticket)
      raise KeyError, "ticket #{ticket} には続ける走行が無い" if journal.nil?

      launch(submission_of(ticket), journal: journal, max_effects: max_effects)
    end

    def pending = @intake.size
    def journal_for(ticket) = @ledger.journal_for(ticket)
    def state_of(ticket) = @ledger.state_of(ticket)

    private

    # 台帳の受付記録から投入を組み直す。Kit は宣言データから戻す。
    def submission_of(ticket)
      record = @ledger.for_ticket(ticket).find { |r| r.kind == Ledger::ACCEPTED }
      raise KeyError, "ticket #{ticket} の受付記録が無い" if record.nil?

      payload = record.payload
      Submission.new(ticket: ticket, name: payload['name'].to_sym, focus: payload['focus'],
                     kit: payload['kit'] && Kit.from_h(payload['kit']), seed: payload['seed'])
    end

    def keep_draining?(done, limit)
      return false if @intake.empty?

      limit.nil? || done.size < limit
    end

    def launch(submission, journal: Journal::Log.new, max_effects: nil)
      outcome = Executor.run(
        entry_program(submission), policy: @policy, seed: submission.seed,
                                   registry: @ports, programs: @programs, kit: submission.kit,
                                   journal: journal, max_effects: max_effects
      )
      record(submission.ticket, outcome)
      Completion.new(ticket: submission.ticket, outcome: outcome)
    end

    # 拾う操作そのものを program として表す。これが「新しい門を作らない」の実体で、
    # 拾った 1 手が admission を通り receipt を残す。
    def entry_program(submission)
      payload = { 'name' => submission.name.to_s, 'focus' => submission.focus }
      Berylx::Task[:"pickup_#{submission.ticket}"] do |lay, io|
        lay.put(:produced, io.perform(Program::SUBMIT_TAG, payload))
      end
    end

    def record(ticket, outcome)
      @ledger.remember(ticket, outcome.journal) # 正本は journal、台帳は索引
      @ledger.append(ticket: ticket, kind: kind_of(outcome), payload: summary(outcome))
    end

    def kind_of(outcome)
      return Ledger::SUSPENDED if outcome.suspended?
      return Ledger::DENIED if Machine.denied?(outcome)

      Ledger::COMPLETED
    end

    def summary(outcome)
      denials = outcome.journal.to_a.select { |entry| entry.kind == :admission_denied }
      { 'receipts' => outcome.receipts.size, 'last_tick' => outcome.last_tick,
        'suspended' => outcome.suspended?,
        'reason' => denials.last&.payload&.fetch('reason', nil) }.compact
    end
  end
end
