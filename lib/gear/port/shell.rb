# frozen_string_literal: true

require 'open3'
require_relative '../port'

module Gear
  module Port
    # ==================================================================
    # Shell — コマンド実行の port adapter。
    #
    # effect tag :shell_run。
    #   payload : { cmd: string }         実行するコマンド行。
    #   result  : { exit_status, stdout, stderr }
    #             すべてシリアライズ可能なスカラ (pin journal.records_external_results)。
    #
    # 生の外界呼び出し (Open3) は run の中だけ。Effect 生成側は純粋に保つ
    # (pin port.no_direct_call)。
    # ==================================================================
    module Shell
      TAG = :shell_run

      PAYLOAD = Zeolite.schema(cmd: :string).named(:ShellRunPayload)

      RESULT = Zeolite.schema(
        exit_status: :integer,
        stdout: :string,
        stderr: :string
      ).named(:ShellRunResult)

      def self.build
        Adapter.new(:shell).operation(
          TAG, payload: PAYLOAD, result: RESULT
        ) do |payload|
          # ここが外界を叩く唯一の場所。capture3 は shell 経由で cmd を走らせ、
          # stdout / stderr / 終了ステータスを返す。
          stdout, stderr, status = Open3.capture3(payload['cmd'])
          { 'exit_status' => status.exitstatus, 'stdout' => stdout, 'stderr' => stderr }
        end
      end

      # 読み込み時に既定 registry へ登録 (global_reuse)。
      ADAPTER = build
      Port.register(ADAPTER)
    end
  end
end
