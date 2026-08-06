# frozen_string_literal: true

module Gear
  module Executor
    # ==================================================================
    # Replay — 記録済み外界結果の読み戻し境界。
    #
    # Driver から切り出した。「時間を進める」責務と「記録の内側か外側かを判じて
    # 読み戻す」責務は別物なので、後者だけをここへ閉じる。
    #
    # 満たす pin (gear.spec):
    #   journal.records_external_results / journal.replay_deterministic :
    #     記録済みの結果は再実行せず読み戻し、record 時と同じ型付き値を返す。
    #   replay_scope_declared : 記録の内側と外側の境目 (#exhausted?) を隠さない。
    # ==================================================================
    class Replay
      def initialize(recorded:, registry:)
        @recorded = recorded # 追記順の port_result entry 列
        @registry = registry
        @cursor = 0
      end

      # 記録の外へ出たか。出たら実外界を叩く番。
      def exhausted? = @cursor >= @recorded.size

      # 次の記録を読み戻す。位置だけで進めず、記録された port **と payload** を要求と
      # 照合する。port だけ見ていたときは、同じ tag を別の引数で要求した効果へ古い
      # 記録がそのまま返り、receipt に「新しい payload と古い結果」という起きていない
      # 対応が根拠として残った (監査で再現)。
      # 返り値は [Task へ渡す型付き値, journal に積む素データ]。
      def read_back(tag, tick, payload = nil)
        entry = @recorded[@cursor]
        @cursor += 1
        raise ReplayMismatch.at(tick, entry, tag) if entry.payload['port'] != tag.to_s

        verify_payload!(entry, tag, tick, payload)
        recorded = entry.payload['result']
        [restore(tag, recorded, tick), recorded]
      end

      private

      # 記録に payload が残っていて、いまの要求と違うなら読み戻さない。
      # 古い journal には payload が無いので、その場合は port の一致だけで通す。
      def verify_payload!(entry, tag, tick, payload)
        recorded_payload = entry.payload['payload']
        return if payload.nil? || recorded_payload.nil?
        return if recorded_payload == payload

        raise ReplayMismatch.at(tick, entry, tag)
      end

      # 記録された素データを、その tag の result schema で型付き値へ復元する。
      # 検査に落ちたら黙って nil を返さない — zeolite の失敗 Result は value が nil
      # なので、そのまま返すと型付き値のふりをした nil が program へ渡る (監査で再現)。
      def restore(tag, recorded, tick)
        schema = @registry.for_tag(tag).operation_for(tag).result_schema
        checked = schema.load(Port.normalize(recorded))
        raise ReplayUnreadable.new(tick: tick, tag: tag, violations: checked.violations) unless checked.ok?

        checked.value
      end
    end
  end
end
