# frozen_string_literal: true

module Gear
  # ==================================================================
  # Program — 実行機に乗る前の一段。
  #
  # 素の berylx Task を実行機へ直に乗せない。名前と境界 (入力 / 出力の zeolite
  # schema) を名乗ってから登録される。名乗った境界があるので、機械は走らせる前に
  # 「何を食べて何を出すか」を知れる — 自動で網に繋ぐための材料はこれ。
  #
  # 満たす pin (gear.spec):
  #   program.representation / no_private_dsl : 実行される form は berylx Task の
  #     まま。ここは Task を包む申告であって、program を書く別記法ではない。
  #   port.boundary_value : 境界の値の形は zeolite schema で表す (一段上へ適用)。
  #
  # 繋ぎ先の「判定基準」はここで決めない (quarantine goal.dissolve_boundaries)。
  # #candidates_for は候補を挙げるだけの問い合わせで、選ぶのは利用側。
  # ==================================================================
  module Program
    Declaration = Data.define(:name, :task, :input, :output) do
      # 走らせる前に、渡す予定の素データが入力の形を満たすか検査できる。
      def accepts?(data) = input.load(Port.normalize(data)).ok?
      def produces?(data) = output.load(Port.normalize(data)).ok?

      # 境界の名前 (zeolite の label)。網の接続はこの名前で照合する。
      def input_label = input.label
      def output_label = output.label
    end

    class Registry
      def initialize
        @by_name = {}
      end

      # 宣言が欠けた登録を受けない。素の Task が乗る経路をここで塞ぐ。
      def register(name:, task:, input:, output:)
        raise ArgumentError, 'program には name / task / input / output が要る' if
          name.nil? || task.nil? || input.nil? || output.nil?
        raise ArgumentError, "program #{name} は既に登録されている" if @by_name.key?(name.to_sym)

        @by_name[name.to_sym] = Declaration.new(name: name.to_sym, task: task, input: input, output: output)
        self
      end

      def fetch(name)
        @by_name.fetch(name.to_sym) do
          raise KeyError, "program #{name} は登録されていない (素の Task は実行機に乗らない)"
        end
      end

      def registered?(name) = @by_name.key?(name.to_sym)
      def names = @by_name.keys.sort
      def each(&) = @by_name.each_value(&)

      # name の出力を食べられる program を挙げる。選ぶ基準はここで発明しない。
      def candidates_for(name)
        produced = fetch(name).output_label
        @by_name.each_value.select { |d| d.name != name.to_sym && d.input_label == produced }.map(&:name).sort
      end
    end
  end
end
