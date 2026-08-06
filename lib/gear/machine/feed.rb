# frozen_string_literal: true

require 'json'

module Gear
  class Machine
    # ==================================================================
    # Feed — 外から投げ込む口。IO から 1 行 1 件の JSON を読んで受付列へ入れる。
    #
    # free ui.protocol の裁定: 伝送は「NDJSON を任意の IO へ」。unix socket でも
    # pipe でも StringIO でも同じ口で受けられ、**核は in-process の Intake のまま**
    # なのでプロトコルを機械の核へ焼かない。SSE や WebSocket を足すときも、この
    # 口の前に置くだけで済む。
    #
    # 壊れた行は黙って落とさず rejected に残す (silent failure を作らない)。
    # ==================================================================
    class Feed
      Rejected = Data.define(:line, :reason)

      attr_reader :rejected

      def initialize(io:, intake:)
        @io = io
        @intake = intake
        @rejected = []
      end

      # 読めるだけ読んで受付列へ入れる。受け付けた投入を返す。
      def absorb(limit: nil)
        taken = []
        while (limit.nil? || taken.size < limit) && (line = read_line)
          submission = offer(line)
          taken << submission if submission
        end
        taken
      end

      private

      def read_line
        @io.gets
      rescue IOError # EOFError は IOError の子なので並べると shadow になる
        nil
      end

      def offer(line)
        text = line.to_s.strip
        return nil if text.empty?

        data = JSON.parse(text)
        name = data['name']
        return reject(text, 'name が無い') if name.nil? || name.to_s.empty?

        @intake.offer(name: name, focus: data['focus'] || {},
                      kit: data['kit'] && Kit.from_h(data['kit']), seed: data['seed'])
      rescue JSON::ParserError => e
        reject(text, "JSON として読めない: #{e.message}")
      rescue StandardError => e
        # JSON としては読めるが形が違う行 (top-level が Hash でない / kit の形が違う 等)。
        # ここで閉じ込めないと absorb ごと例外離脱し、同じバッファの後続行が rejected にも
        # 残らず消える。常駐ループなら 1 行で受付が止まる (監査で再現)。
        reject(text, "投入として受けられない: #{e.class}: #{e.message}")
      end

      def reject(line, reason)
        @rejected << Rejected.new(line: line, reason: reason)
        nil
      end
    end
  end
end
