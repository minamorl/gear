# frozen_string_literal: true

# WORKER SLOT: executor
# 実装はこのファイルと lib/gear/executor/ 配下に閉じること。
# 他ワーカーのファイルを触らない (並列分散の territory 境界)。
require 'darkcore'
require 'berylx'

module Gear
  # ==================================================================
  # Executor — 五点セットを一本の走行に綴じる者。gear の心臓。
  #
  # berylx の Task 合成 (= program) を Berylx::EffectTree で darkcore の単一
  # Effect 木へ compile し、Darkcore.fold のトランポリンで走らせる。木を
  # 一歩ずつ進めながら、外界に触れる効果の手前で必ず Admission に judge させ、
  # 通ったものだけ port adapter の handler で実行し、Receipt を出して Journal
  # に append する。どの一歩でも中断でき、journal から再開できる。
  #
  # ---- scheduler / runtime の裁定 (free scheduler.shape / free runtime.form) ----
  #
  #   runtime.form  : 言語内 runtime。別プロセス daemon にはしない (今回の指定)。
  #
  #   scheduler.shape: 「単一ループ (darkcore トランポリン) + journal リプレイに
  #     よる中断・再開」を選ぶ。協調 fiber や thread pool を継続の担い手にせず、
  #     継続の正本を journal 一本に寄せる。
  #     理由: pin journal.is_source_of_truth と journal.replay_deterministic が
  #     「状態の正本は journal / 同じ journal と seed から同じ走行が出る」と縛る。
  #     生きた fiber スタックを継続の担い手にすると、journal と競合する第二の正本
  #     (途中まで進んだプロセス状態) が生まれてしまう。よって中断は「journal に
  #     記録済みの外界結果」だけを継続の種とし、再開は program をもう一度 compile
  #     して走らせ直しつつ、記録済みの効果を読み戻す (再実行しない) 形にする。
  #     これで「決定論リプレイ」と「中断再開」が同じ一つの機構になる。
  #
  # 中断は Suspend を投げてトランポリンを抜ける。Suspend は StandardError では
  # ないので、Berylx::Task#call の `rescue StandardError` に捕まらず走行の外まで
  # 抜ける (効果を Err に化けさせない)。
  # ==================================================================
  module Executor
    # 走行成果。journal が正本、result は berylx の結果封筒 (Ok/Err)、receipts は
    # 発行順の根拠鎖、suspended は予算到達で中断したか。
    Outcome = Data.define(:result, :journal, :receipts, :suspended, :last_tick) do
      def suspended? = suspended
      def done? = !suspended
    end

    # 中断の合図。StandardError を継承しない — Task#call の rescue を素通りして
    # トランポリンの外 (Driver#run) まで抜けるため。
    class Suspend < Exception; end # rubocop:disable Lint/InheritException

    # journal が記録している効果順と program が要求する効果順が食い違った合図。
    # Suspend と同じく StandardError を継承しない — これは program の失敗ではなく
    # 「journal と program の対応が壊れている」という走行の前提破りなので、Err へ
    # 翻訳して結果封筒に混ぜず、走行の外まで抜けさせる (黙って誤値を返さない)。
    class ReplayMismatch < Exception # rubocop:disable Lint/InheritException
      attr_reader :tick, :recorded_port, :requested_tag

      # journal の entry と、いま program が要求した tag から起こす。
      def self.at(tick, entry, tag)
        new(tick: tick.index, recorded_port: entry.payload['port'], requested_tag: tag)
      end

      def initialize(tick:, recorded_port:, requested_tag:)
        @tick = tick
        @recorded_port = recorded_port
        @requested_tag = requested_tag
        super("tick #{tick}: journal は #{recorded_port} を記録しているが " \
              "program は #{requested_tag} を要求した")
      end
    end

    # admission が拒否した効果を実行しようとしたときの合図。こちらは
    # StandardError なので Task#call が捕まえ、berylx の Err へ翻訳される
    # (拒否は検査可能な結果値として program を閉じる)。
    class AdmissionDenied < StandardError
      attr_reader :verdict

      def initialize(verdict)
        @verdict = verdict
        super("admission denied: #{verdict.reason}")
      end
    end

    module_function

    # program を一本走らせる。
    #
    #   program     : berylx の Task / Sequence (gear 独自 DSL は取らない)。
    #   focus       : berylx の初期 focus (Hash か Berylx::Focus)。
    #   policy      : admission の判定基準 (#judge(request) -> Verdict)。必須。
    #   seed        : Clock の run seed (Integer)。同じ seed で同じ tick 列が出る。
    #   registry    : 効果 tag を握る Port::Registry。既定はプロセス既定 registry。
    #   journal     : 再開元 / リプレイ元の journal。記録済み外界結果は読み戻す。
    #   max_effects : 何個目の効果の手前で中断するか。nil なら中断しない。
    def run(program, policy:, seed:, focus: {}, registry: Port.registry,
            journal: Journal::Log.new, max_effects: nil)
      Driver.new(
        clock: Clock.new(seed: seed),
        policy: policy,
        registry: registry,
        replay_source: journal,
        max_effects: max_effects
      ).run(program, focus)
    end
  end
end

require_relative 'executor/replay'
require_relative 'executor/driver'
