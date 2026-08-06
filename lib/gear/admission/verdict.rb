# frozen_string_literal: true

module Gear
  module Admission
    # ==================================================================
    # Grant — 根拠 1 単位。「どの policy / rule が、どういう理由で効いたか」。
    #
    # Admitted の grounds はこの列。後段の receipt はこの列を根拠鎖の起点に
    # できる (spec: receipt.carries_grounds — receipt は「何が許可したか」を持つ)。
    # ==================================================================
    Grant = Data.define(:policy, :detail) do
      # 機械可読な素データ。receipt の grounds はこの形で journal に載るので、
      # inspect 文字列 (#<data ...>) を根拠として記録しない。
      def to_h = { 'policy' => policy.to_s, 'detail' => detail.to_s }
    end

    # ==================================================================
    # 許可。何が許可したか (grounds) を必ず持つ。空の許可は作らない
    # ——根拠の無い許可は receipt の根拠鎖を切ってしまうため。
    # ==================================================================
    Admitted = Data.define(:request, :grounds) do
      def admitted? = true
      def denied? = false

      # 根拠を機械が辿れる形で出す (receipt.carries_grounds)。
      def to_h
        { 'verdict' => 'admitted', 'request' => request.to_h, 'grounds' => grounds.map(&:to_h) }
      end
    end

    # ==================================================================
    # 拒否。例外ではなく検査可能な結果値として返る
    # (spec: admission.denial_is_value — raise しない)。
    #
    #   reason : なぜ拒否したか。
    #   by     : どの policy / rule が拒否したか (根拠)。
    # ==================================================================
    Denied = Data.define(:request, :reason, :by) do
      def admitted? = false
      def denied? = true

      # 拒否も grounds として一様に読めるようにしておく (監査・記録用)。
      def grounds = [Grant.new(policy: by, detail: reason)]

      def to_h
        { 'verdict' => 'denied', 'request' => request.to_h, 'reason' => reason.to_s,
          'by' => by.to_s, 'grounds' => grounds.map(&:to_h) }
      end
    end

    # ==================================================================
    # Verdict — Admitted / Denied を起こす smart constructor 群。
    # policy 実装は自分の同一性を知っているので、判定の中でこれを呼んで
    # 根拠付きの結果値を組み立てる。
    # ==================================================================
    module Verdict
      module_function

      def admit(request, grounds:)
        Admitted.new(request: request, grounds: Array(grounds))
      end

      def deny(request, reason:, by:)
        Denied.new(request: request, reason: reason, by: by)
      end
    end
  end
end
