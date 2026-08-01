# frozen_string_literal: true

# WORKER SLOT: receipt
# 実装はこのファイルと lib/gear/receipt/ 配下に閉じること。
# 他ワーカーのファイルを触らない (並列分散の territory 境界)。

require 'digest'
require 'json'
require 'set'

# ==================================================================
# Gear::Receipt — 根拠の鎖。
#
# 「何が起きたか」ではなく「何が、何を根拠に許されて起きたか」を残す値。
# admission を通って実行された副作用に対して発行される、immutable な記録。
#
# 満たす pin (gear.spec):
#   receipt.required        — 実行に対して発行される値そのもの (execute 側は W5)
#   receipt.no_silent_effect— 沈黙した副作用を作らないための「痕跡」。receipt は
#                             effect の要約を必ず持つので、無内容にはならない。
#   receipt.carries_grounds — effect と grounds の両方を持つ (require
#                             gear.receipt.contents = effect_and_grounds)
#   receipt.chainable       — predecessor で先行 receipt を参照し鎖を遡れる
#                             (require gear.receipt.linkage = predecessor_reference)
#
# 呼応する精神:
#   tick.no_ambient_random  — id はプロセス由来乱数を使わず、内容と tick から
#                             決定論的に導出する (SHA256)。
#   journal.no_shadow_state — Receipt は可変グローバルストアを抱え込まない。
#                             鎖を遡る API は外から receipt 集合 (store) を受け取る。
#   free receipt.storage    — 保存先 (journal と同一ストアか分離か) は決めない。
#                             ここは値の設計と鎖の性質だけに集中し、シリアライズ
#                             可能性 (journal に載る前提) だけを保証する。
#
# フィールド:
#   id          : 内容 + tick から導かれる決定論的な識別子 (String)
#   tick        : いつ (W1 Clock の tick 値。ここでは整数として扱う)
#   effect      : 何が実行されたか。darkcore Effect の tag / payload の要約。
#                 継続 k (生 Proc) は載せない — シリアライズ可能性のため。
#   outcome     : 結果。{ "status" => "ok"|"err", ... } の要約。
#   grounds     : 何が許可したか。admission verdict / policy / rule の要約。
#   predecessor : 先行 receipt の id (String) または nil (鎖の根)。
#
# 全フィールドは JSON プリミティブ (String / 数値 / bool / nil / Array /
# String キーの Hash) に正規化して保持する。生の Proc / IO を持たないので、
# そのまま journal に記録・復元できる。
# ==================================================================
module Gear
  Receipt = Data.define(:id, :tick, :effect, :outcome, :grounds, :predecessor) do
    # ----------------------------------------------------------------
    # 発行 — 内容から決定論的に id を導いて receipt を作る smart constructor。
    #
    #   effect      : darkcore Effect (tag/payload を持つ) / Hash / タグ値。
    #   outcome     : 結果の要約。Receipt.ok / Receipt.err で作れる。
    #   grounds     : admission の verdict など。to_h を持てばそれを使う。
    #   tick        : W1 Clock の tick 値。
    #   predecessor : 先行 receipt (Receipt / id 文字列) または nil。
    # ----------------------------------------------------------------
    def self.issue(effect:, outcome:, grounds:, tick:, predecessor: nil)
      eff  = summarize_effect(effect)
      out  = canonicalize(outcome)
      grd  = canonicalize(normalize_grounds(grounds))
      pred = predecessor_id(predecessor)
      id   = derive_id(tick: tick, effect: eff, outcome: out, grounds: grd, predecessor: pred)

      new(id: id, tick: tick, effect: eff, outcome: out, grounds: grd, predecessor: pred)
    end

    # 結果要約の組み立て子。outcome: に渡す用。
    def self.ok(value = nil)  = { 'status' => 'ok',  'value'  => canonicalize(value) }
    def self.err(reason = nil) = { 'status' => 'err', 'reason' => canonicalize(reason) }

    # ----------------------------------------------------------------
    # 鎖を遡る — store (receipt 集合) を渡すと祖先列が近い順に返る。
    # Receipt 自身は store を抱えない (no_shadow_state の精神)。
    # 存在しない先行や循環を見つけたら BrokenChain を上げる。
    # ----------------------------------------------------------------
    def ancestors(store)
      idx  = self.class.index(store)
      out  = []
      seen = Set[id]
      cur  = predecessor
      while cur
        raise self.class::BrokenChain, "missing predecessor: #{cur}" unless idx.key?(cur)
        raise self.class::BrokenChain, "cycle detected at: #{cur}"    if seen.include?(cur)

        seen << cur
        rec = idx[cur]
        out << rec
        cur = rec.predecessor
      end
      out
    end

    def root?      = predecessor.nil?
    def succeeded? = outcome['status'] == 'ok'

    # grounds に admission verdict が入っているか (接続点)。
    def grounded? = !grounds.nil? && !(grounds.respond_to?(:empty?) && grounds.empty?)

    # ----------------------------------------------------------------
    # 鎖の健全性検査 — store 全体を走査し、壊れた receipt を洗い出す。
    #   dangling : 存在しない predecessor を指す receipt
    #   cyclic   : 祖先を辿ると循環に入る receipt
    # ----------------------------------------------------------------
    def self.audit(store)
      idx      = index(store)
      dangling = []
      cyclic   = []
      idx.each_value do |r|
        seen = Set[r.id]
        cur  = r.predecessor
        while cur
          unless idx.key?(cur)
            dangling << r
            break
          end
          if seen.include?(cur)
            cyclic << r
            break
          end
          seen << cur
          cur = idx[cur].predecessor
        end
      end
      { dangling: dangling.uniq, cyclic: cyclic.uniq }
    end

    # 鎖が健全か (dangling も cyclic も無いか)。
    def self.chain_ok?(store)
      a = audit(store)
      a[:dangling].empty? && a[:cyclic].empty?
    end

    # ----------------------------------------------------------------
    # シリアライズ — journal に載せるため JSON へ / から。
    # 全フィールドが JSON プリミティブなので round-trip で同値に戻る。
    # ----------------------------------------------------------------
    def to_json(*)
      JSON.generate(to_h)
    end

    def self.from_json(str)
      from_h(JSON.parse(str))
    end

    # String キー / Symbol キーどちらの Hash でも復元できる。
    def self.from_h(hash)
      h = hash.transform_keys(&:to_sym)
      new(
        id:          h[:id],
        tick:        h[:tick],
        effect:      h[:effect],
        outcome:     h[:outcome],
        grounds:     h[:grounds],
        predecessor: h[:predecessor]
      )
    end

    # ---- 内部ヘルパ ------------------------------------------------

    # store (Array<Receipt> か id=>Receipt の Hash) を id 索引へ正規化。
    def self.index(store)
      return store if store.is_a?(Hash)

      store.each_with_object({}) { |r, h| h[r.id] = r }
    end

    # darkcore Effect / Hash / タグ値 を serializable な要約へ。
    # 継続 k (生 Proc) は読まない — receipt は走らせずに覗ける純データに保つ。
    def self.summarize_effect(effect)
      case effect
      when Hash
        canonicalize(effect)
      else
        if effect.respond_to?(:tag) && effect.respond_to?(:payload)
          canonicalize(tag: effect.tag, payload: effect.payload)
        else
          canonicalize(tag: effect, payload: nil)
        end
      end
    end

    # grounds を Hash/Array の serializable な形へ寄せる。
    # admission verdict のように to_h を持つ値はそれを使う (接続点)。
    def self.normalize_grounds(grounds)
      return grounds if grounds.is_a?(Hash) || grounds.is_a?(Array)
      return grounds.to_h if grounds.respond_to?(:to_h)

      { value: grounds }
    end

    def self.predecessor_id(predecessor)
      case predecessor
      when nil     then nil
      when Receipt then predecessor.id
      else predecessor.to_s
      end
    end

    # 内容 + tick から決定論的に id を導く。プロセス由来乱数は使わない
    # (tick.no_ambient_random の精神)。キー順に依存しないよう安定化する。
    def self.derive_id(tick:, effect:, outcome:, grounds:, predecessor:)
      material = sort_keys(
        'tick'        => tick,
        'effect'      => effect,
        'outcome'     => outcome,
        'grounds'     => grounds,
        'predecessor' => predecessor
      )
      Digest::SHA256.hexdigest(JSON.generate(material))[0, 16]
    end

    # 任意データを JSON プリミティブへ深く正規化する。
    # Symbol は String に、Hash キーは String に落とす。未知のオブジェクトは
    # to_s に潰す — 生の Proc / IO を receipt に持ち込まないための堰。
    def self.canonicalize(obj)
      case obj
      when Hash
        obj.each_with_object({}) { |(k, v), h| h[k.to_s] = canonicalize(v) }
      when Array
        obj.map { |e| canonicalize(e) }
      when Symbol
        obj.to_s
      when String, Integer, Float, true, false, nil
        obj
      else
        obj.to_s
      end
    end

    # id 導出用: Hash のキーを再帰的にソートして順序非依存にする。
    def self.sort_keys(obj)
      case obj
      when Hash
        obj.keys.sort.each_with_object({}) { |k, h| h[k] = sort_keys(obj[k]) }
      when Array
        obj.map { |e| sort_keys(e) }
      else
        obj
      end
    end
  end

  class Receipt
    # 壊れた鎖 (存在しない先行 / 循環) を辿ろうとしたときに上がる。
    # Data.define のブロック内で定義するとレキシカルスコープの都合で
    # Gear:: 直下に落ちてしまうため、クラスを開き直してここに固定する。
    BrokenChain = Class.new(StandardError)
  end
end
