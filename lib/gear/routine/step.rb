# frozen_string_literal: true

module Gear
  module Routine
    # ==================================================================
    # Step — ルーチン一歩分。journal から読み戻した「実行前のただのデータ」。
    #
    # Effect は実行前は tag/payload の純データなので (darkcore の tagged effect
    # /pin io.no_opaque_thunk)、journal に残った receipt からこの Step を復元
    # できる。Step を berylx の Task に載せ替えれば、そのまま program として
    # 走る (pin routine.from_journal / program.representation)。
    #
    #   tick    : この効果が起きた元の tick (全順序の index)。抽出範囲の指定や
    #             由来の保存に使う。復元後の実行では新しい tick が振り直される。
    #   tag     : darkcore effect のディスパッチキー (String)。journal には
    #             canonicalize 済みの文字列で残るので String で持ち、Task へ
    #             載せるときに Symbol へ戻す (registry の tag は Symbol)。
    #   payload : 効果への入力。素の JSON データ (String キーの Hash 等)。
    #             パラメータ化した箇所は「穴」(Routine::HOLE を含む Hash) に
    #             置き換わっており、to_task 時に実引数で埋める。
    #
    # 全フィールドが JSON プリミティブなので、そのままシリアライズできる
    # (名前を付けて残せる: pin routine.is_first_class を実務で支える)。
    # ==================================================================
    Step = Data.define(:tick, :tag, :payload) do
      def self.from_effect(tick, effect_summary)
        # receipt の effect 要約 ({ 'tag' => .., 'payload' => .. }) から起こす。
        # in-memory (Symbol キー) と NDJSON 復元後 (String キー) の両方を受ける。
        tag     = effect_summary['tag']     || effect_summary[:tag]
        payload = effect_summary['payload'] || effect_summary[:payload]
        new(tick: tick, tag: tag.to_s, payload: payload)
      end

      def to_h = { 'tick' => tick, 'tag' => tag, 'payload' => payload }

      def self.from_h(hash)
        new(
          tick: hash['tick'] || hash[:tick],
          tag: (hash['tag'] || hash[:tag]).to_s,
          payload: hash['payload'] || hash[:payload]
        )
      end
    end
  end
end
