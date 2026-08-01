# gear — 並列ワーカー領分表 (territory map)

正本仕様は `spec-system/pins/domains/gear.spec`。**このファイルは領分だけを決める。**
振る舞いを決めるのは spec であって、この表ではない。

## 不変(全ワーカー共通)

- 中核は五点のみ: Clock / Admission / Executor / Journal / Receipt。中核を増やさない。
- 外界(shell/http/db/LLM/file)へは **port adapter 経由**。生の直接呼び出しを書かない。
- 副作用は **admission を通ってから** 実行し、**receipt を出す**。
- 状態の正本は **journal**。コンポーネント側に権威ある状態を持たない。
- program は **berylx Task**。gear 独自 DSL を作らない。
- effect substrate は **darkcore の単一 Effect 型**。語彙を分岐させない。
- 境界の値の形は **zeolite schema**。

## 領分 (touch してよいのは自分の列だけ)

| slot | 触ってよい path | 依存する slot | 成果の判定 |
| --- | --- | --- | --- |
| W1 clock | `lib/gear/clock.rb`, `lib/gear/clock/`, `test/gear/clock_test.rb` | なし | tick の全順序と seed 由来乱数が test で示せる |
| W2 journal | `lib/gear/journal.rb`, `lib/gear/journal/`, `test/gear/journal_test.rb` | W1 | append-only・fold で現在状態・同一 seed で replay 一致 |
| W3 admission | `lib/gear/admission.rb`, `lib/gear/admission/`, `test/gear/admission_test.rb` | なし | policy 差し替え可・拒否が値・bypass 不能 |
| W4 receipt | `lib/gear/receipt.rb`, `lib/gear/receipt/`, `test/gear/receipt_test.rb` | W3 | 根拠を持つ・先行 receipt を辿れる |
| W5 port | `lib/gear/port.rb`, `lib/gear/port/`, `test/gear/port_test.rb` | なし | adapter 契約 + shell/http の 2 枚が Effect を返す |
| W6 executor | `lib/gear/executor.rb`, `lib/gear/executor/`, `test/gear/executor_test.rb` | W1..W5 | berylx program を中断・再開できる |
| W7 routine | `lib/gear/routine.rb`, `lib/gear/routine/`, `test/gear/routine_test.rb` | W2 | journal から Task 列を復元し同じ経路で再実行できる |

`lib/gear.rb` / `Gemfile` / `gear.gemspec` / `AGENTS.md` は **統合担当(結衣)のみ**が触る。
require 行の追加が必要になったら、自分で書き足さず統合担当へ申告する。

## 規律

- 自分の slot 外のファイルを編集しない。必要になったら申告して待つ。
- test は minitest。`bundle exec rake test` が緑であること。
- 実測していない状態を完了と呼ばない。
