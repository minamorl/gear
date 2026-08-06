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

      # 次の記録を読み戻す。位置だけで進めず、記録された port と要求 tag を照合する
      # (形の似た schema だと誤値の読み戻しが成功し receipt に嘘が載るため)。
      # 返り値は [Task へ渡す型付き値, journal に積む素データ]。
      def read_back(tag, tick)
        entry = @recorded[@cursor]
        @cursor += 1
        raise ReplayMismatch.at(tick, entry, tag) if entry.payload['port'] != tag.to_s

        recorded = entry.payload['result']
        [restore(tag, recorded), recorded]
      end

      private

      # 記録された素データを、その tag の result schema で型付き値へ復元する。
      def restore(tag, recorded)
        schema = @registry.for_tag(tag).operation_for(tag).result_schema
        schema.load(Port.normalize(recorded)).value
      end
    end
  end
end
