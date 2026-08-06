# frozen_string_literal: true

module Gear
  module Admission
    # ==================================================================
    # Request — admission の判定対象。
    #
    # darkcore の Effect ノード (tag / payload) から起こす、実行前に検査可能な
    # ただのデータ。作用を走らせる前にゲートで覗くための形なので、不透明な
    # サンクではなく tag と payload を素で持つ (spec: io.no_opaque_thunk の精神)。
    # ==================================================================
    Request = Data.define(:tag, :payload) do
      # effect-like (tag / payload に応答する) ノードから request を起こす。
      # darkcore の Effect / Pending いずれからでも作れるよう、型ではなく
      # duck typing で受ける (語彙を分岐させない)。
      def self.from_effect(effect)
        new(tag: effect.tag, payload: effect.payload)
      end

      # 機械可読な素データ。payload は既に素の形に揃っている。
      def to_h = { 'tag' => tag.to_s, 'payload' => payload }
    end
  end
end
