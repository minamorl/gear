# frozen_string_literal: true

module Gear
  module Executor
    # ==================================================================
    # Submission — program から program へ繋ぐ一段。
    #
    # 素の Task は乗らない。名前で名簿を引き、宣言した境界 (入力 / 出力の zeolite
    # schema) を実際に検査してから走らせ、出た focus も宣言と照合する。
    # 「自動で網に繋ぐ」の材料はこの照合で、繋ぎ先を選ぶ基準はここで決めない
    # (quarantine goal.dissolve_boundaries)。
    #
    # 満たす pin (gear.spec):
    #   ui.input_as_program : 操作は program として入る。submit は効果なので gate を
    #     通り admission に judge され receipt が出る (迂回経路が無い)。
    #   port.boundary_value : 境界の値の形は zeolite schema。
    #
    # 実際の fold は Driver が持つので block で受ける — 子は親と同じ clock /
    # journal / receipt 鎖の上を走る (tick.total_order を跨いで割らない)。
    # ==================================================================
    class Submission
      def initialize(programs:)
        @programs = programs
      end

      # payload の name で名簿を引き、境界を検査して子を走らせ、出力も照合する。
      # 実際の fold は block で受ける (子は親と同じ clock / journal / receipt 鎖の上)。
      def run(payload, &fold)
        name = payload['name']
        focus = Port.normalize(payload['focus'] || {})
        decl = @programs.fetch(name) # 未登録なら KeyError (素の Task は乗らない)
        check!(decl.accepts?(focus), "program #{name} の入力が宣言 #{decl.input_label} を満たさない")

        produced = child_result(decl.task, focus, &fold)
        check!(decl.produces?(produced), "program #{name} の出力が宣言 #{decl.output_label} を満たさない")
        produced
      end

      private

      # 境界の宣言は JSON-safe な String キーだが berylx の focus は symbol キーで扱う
      # 慣習なので、子へ渡す手前で寄せる。Kit の宣言は機械の配管なので出力から外す。
      def child_result(task, focus)
        seed = focus.transform_keys(&:to_sym)
        result = yield(task, seed)
        raise Program::ChildFailed, "子 program が Err で閉じた: #{result.inspect}" if result.is_a?(Berylx::Err)

        Port.normalize(result.focus.to_h).except(Kit::FOCUS_KEY.to_s)
      end

      def check!(satisfied, message)
        raise Program::BoundaryError, message unless satisfied
      end
    end
  end
end
