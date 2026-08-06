# frozen_string_literal: true

require 'monitor'

module Gear
  class Machine
    # ==================================================================
    # Ledger — 受付の台帳。
    #
    # 「何が投げられ、何が拒まれ、何が終わったか」を追記する。走行そのものの正本は
    # 各 run の journal であって、台帳はその索引と受付の記録。scope が違う二本目の
    # 追記記録であり、run の状態を写した影ではない (journal.no_shadow_state を破らない)。
    #
    # 記録は JSON-safe な素データ。journal だけは正本への参照としてそのまま持つ
    # (畳み込みの対象は journal 自身で、台帳が状態を持つのではない)。
    # ==================================================================
    class Ledger
      Record = Data.define(:ticket, :kind, :payload)

      ACCEPTED  = :accepted  # 受け付けて列へ入れた
      DENIED    = :denied    # 投入が admission に拒まれた (走らせていない)
      COMPLETED = :completed # 拾って走り切った
      SUSPENDED = :suspended # 拾ったが予算で中断した (journal から続けられる)

      def initialize
        @records = []
        @journals = {}
        @lock = Monitor.new
      end

      def append(ticket:, kind:, payload: {})
        @lock.synchronize do
          record = Record.new(ticket: ticket, kind: kind, payload: payload)
          @records.push(record)
          record
        end
      end

      # 走行の journal を ticket に結び付けて覚える (正本への索引)。
      #
      # **縮めない。** resume が前回より手前で止まった (予算切れ / 拒否 / Err) ときに
      # 短い journal で差し替えると、記録済みの外界結果が消えて次の resume が同じ
      # 副作用を叩き直す (監査で再現)。記録が減る差し替えは受けない。
      def remember(ticket, journal)
        @lock.synchronize do
          current = @journals[ticket]
          @journals[ticket] = journal if current.nil? || !shrinks?(current, journal)
          @journals[ticket]
        end
      end

      # これまでに使われた最大の ticket。機械を建て直すとき受付列へ引き継ぐ。
      def max_ticket = @lock.synchronize { @records.map(&:ticket).max || 0 }

      def journal_for(ticket) = @lock.synchronize { @journals[ticket] }
      def journals = @lock.synchronize { @journals.dup }

      def for_ticket(ticket) = @lock.synchronize { @records.select { |r| r.ticket == ticket } }
      def of_kind(kind) = @lock.synchronize { @records.select { |r| r.kind == kind } }
      def to_a = @lock.synchronize { @records.dup }
      def size = @lock.synchronize { @records.size }

      # ticket ごとの最後の kind。いま何が起きている状態かの読み出し。
      def state_of(ticket) = for_ticket(ticket).last&.kind

      private

      def shrinks?(current, candidate)
        candidate.port_results.size < current.port_results.size
      end
    end
  end
end
