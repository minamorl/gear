# frozen_string_literal: true

# ==================================================================
# Gear — 実行マシン。
#
# 既存 Ruby 資産の役割分担 (spec: gear.spec @meta derived_from):
#   darkcore = 動詞の共通語彙 (単一 Effect 型で全副作用をデータ化)
#   zeolite  = 名詞の共通形   (境界を通る値の型)
#   berylx   = 接続の文法     (Task : Lay -> Result[Lay] の合成則)
#   gear     = 時間を進める Executor (ここ)
#
# 中核は五点のみ (pin core.parts):
#   Clock / Admission / Executor / Journal / Receipt
#
# 主目的は「プログラムの境目を溶かす」こと。決定論リプレイと事後説明
# 可能性はその副産物であって主目的ではない。
# ==================================================================
require 'darkcore'

require_relative 'gear/version'
require_relative 'gear/clock'
require_relative 'gear/admission'
require_relative 'gear/receipt'
require_relative 'gear/journal'
require_relative 'gear/port'
require_relative 'gear/kit'
require_relative 'gear/program'
require_relative 'gear/executor'
require_relative 'gear/routine'
require_relative 'gear/view'
require_relative 'gear/machine'

module Gear
  class Error < StandardError; end
end
