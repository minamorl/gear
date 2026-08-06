# frozen_string_literal: true

module Gear
  # ==================================================================
  # Kit — program へおろす権限セット (御主人様の言葉で「便利セット」)。
  #
  # 権限を「policy が覗くフィールド」ではなく「渡す物」にする。渡していない物は
  # 呼べないので、迂回不能が policy の書き漏れではなく構造で担保される
  # (gated_effects が効果に対してやったことを、権限に対してもう一度当てる形)。
  #
  # 生きたオブジェクトではなく JSON-safe な宣言データにする。理由は
  # pin journal.state_is_fold — 現在状態は journal の畳み込みで得るので、
  # 畳み込めない生オブジェクトを状態に座らせない。
  #
  # 広げる操作は無い。narrow / descend で細めることしかできない (attenuation)。
  # ==================================================================
  Kit = Data.define(:ports, :programs, :depth) do
    class << self
      def of(ports: [], programs: [], depth: 0)
        depth = Integer(depth)
        raise ArgumentError, 'depth は 0 以上にする' if depth.negative?

        new(ports: names(ports), programs: names(programs), depth: depth)
      end

      # 何も許さないセット。既定を「全許可」にしない。
      def nothing = of

      def names(list) = list.map(&:to_sym).uniq.sort.freeze

      def from_h(hash)
        of(ports: hash['ports'] || [], programs: hash['programs'] || [], depth: hash['depth'] || 0)
      end
    end

    def port?(tag) = ports.include?(tag.to_sym)
    def program?(name) = programs.include?(name.to_sym)

    # 子を submit できるか。深さが尽きたら繋げない (無限入れ子を構造で止める)。
    def submit? = depth.positive? && !programs.empty?

    # 自分より狭いセットだけを作る。広げる要求は交差で落とす (黙って広げない)。
    def narrow(ports: nil, programs: nil, depth: nil)
      klass = self.class
      klass.of(
        ports: ports.nil? ? self.ports : klass.names(ports) & self.ports,
        programs: programs.nil? ? self.programs : klass.names(programs) & self.programs,
        depth: [depth.nil? ? self.depth : Integer(depth), self.depth].min
      )
    end

    # 子へおろすセット。深さが 1 段減る。
    def descend(ports: nil, programs: nil)
      narrow(ports: ports, programs: programs, depth: [depth - 1, 0].max)
    end

    # focus / journal に載せる形。String キー・String 値の素データ。
    def to_h
      { 'ports' => ports.map(&:to_s), 'programs' => programs.map(&:to_s), 'depth' => depth }
    end
  end
end
