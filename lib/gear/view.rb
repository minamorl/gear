# frozen_string_literal: true

module Gear
  # ==================================================================
  # View — journal を描く面。
  #
  # 満たす pin (gear.spec):
  #   ui.is_view          : view は journal を読んで描くだけ。
  #   ui.no_own_truth     : view 側に権威ある状態を持たない。投影は毎回 journal の
  #                         畳み込みから作るので、描く前と後で view は変わらない。
  #   ui.multiple_renderers : 同じ journal に複数の renderer が同時に立てる。
  #   ui.input_as_program : view からの操作は状態を書き換えず program として機械へ
  #                         入る (判定も記録も機械側で起きる)。
  #
  # journal.state_is_fold と同じ形をそのまま UI 層へ通している — 現在の絵は
  # journal の畳み込みであって、別立ての可変状態ではない。
  # ==================================================================
  module View
    # journal の畳み込みで得る投影。JSON-safe な素データだけを持つ。
    Projection = Data.define(:last_tick, :effects, :denials, :receipts) do
      def quiet? = effects.empty? && denials.empty? && receipts.empty?

      def to_h
        { 'last_tick' => last_tick, 'effects' => effects,
          'denials' => denials, 'receipts' => receipts }
      end
    end

    module_function

    # journal を投影へ畳む。view はこれ以外の状態を持たない。
    def project(journal)
      entries = journal.to_a
      Projection.new(
        last_tick: entries.map(&:tick).max || 0,
        effects: entries.select { |e| e.kind == Journal::PORT_RESULT }
                        .map { |e| { 'tick' => e.tick, 'port' => e.payload['port'] } },
        denials: entries.select { |e| e.kind == :admission_denied }
                        .map { |e| denial_of(e) },
        receipts: entries.select { |e| e.kind == :receipt }.map { |e| receipt_of(e) }
      )
    end

    def denial_of(entry)
      { 'tick' => entry.tick, 'tag' => at(entry.payload, 'tag'), 'reason' => at(entry.payload, 'reason') }
    end

    def receipt_of(entry)
      effect = at(entry.payload, 'effect') || {}
      { 'tick' => entry.tick, 'id' => at(entry.payload, 'id'),
        'tag' => at(effect, 'tag'), 'predecessor' => at(entry.payload, 'predecessor') }
    end

    # journal の payload は String キーと Symbol キーが混ざるので両方見る。
    def at(hash, key)
      return nil unless hash.respond_to?(:[])

      hash[key].nil? ? hash[key.to_sym] : hash[key]
    end

    # ------------------------------------------------------------------
    # 文字で描く renderer。
    # ------------------------------------------------------------------
    class Text
      def render(journal)
        projection = View.project(journal)
        lines = ["tick #{projection.last_tick} / 効果 #{projection.effects.size} / " \
                 "拒否 #{projection.denials.size} / receipt #{projection.receipts.size}"]
        projection.effects.each { |e| lines << "  #{e['tick']} #{e['port']}" }
        projection.denials.each { |d| lines << "  #{d['tick']} 拒否 #{d['tag']} — #{d['reason']}" }
        lines.join("\n")
      end
    end

    # ------------------------------------------------------------------
    # 素データで描く renderer (別の front へ渡す用)。
    # ------------------------------------------------------------------
    class Summary
      def render(journal) = View.project(journal).to_h
    end

    # ------------------------------------------------------------------
    # view からの入力。状態を書き換えず、program として機械へ入る。
    # ------------------------------------------------------------------
    class Input
      def initialize(machine)
        @machine = machine
      end

      def request(name:, focus: {}, kit: nil, seed: nil)
        @machine.submit(name: name, focus: focus, kit: kit, seed: seed)
      end
    end
  end
end
