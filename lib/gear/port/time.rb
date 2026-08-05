# frozen_string_literal: true

require_relative '../port'

module Gear
  module Port
    # 実時刻を外界入力として扱う adapter。Clock の離散 tick とは別語彙にし、
    # JSON にそのまま載る epoch 秒だけを境界の内側へ返す。
    module TimeNow
      TAG = :time_now

      PAYLOAD = Zeolite.schema({}).named(:TimeNowPayload)
      RESULT = Zeolite.schema(epoch_seconds: :float).named(:TimeNowResult)

      def self.build
        Adapter.new(:time).operation(TAG, payload: PAYLOAD, result: RESULT) do |_payload|
          { 'epoch_seconds' => ::Time.now.to_f }
        end
      end

      ADAPTER = build
      Port.register(ADAPTER)
    end
  end
end
