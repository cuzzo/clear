# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Decision-pressure: attribute every defensive type/nil guard to the
  # canonical ROOT CONTRACT its subject comes from, then rank contracts
  # by how many re-derived decisions they drive.
  #
  # This is the project's primary goal made concrete: not "this decision
  # is duplicated N times" (scatter) but "THIS loosely-typed contract
  # (`.full_type`, `[:type]`, `@schema`) is the SOURCE of N conditionals
  # -- fix the contract once, the cluster dies." Pressure, decomplex-
  # scoped: intra-procedural only (a local is resolved to the accessor
  # it was assigned from IN THE SAME METHOD). Cross-procedure pressure
  # is nil-kill's, by the recorded boundary -- not re-implemented here.
  #
  # A "decision" = a guard whose subject is type/nil-tested:
  #   x.is_a?(T) / kind_of? / instance_of? / x.nil? / x.respond_to? /
  #   x&.m  (safe-nav: an implicit nil decision on x).
  class DecisionPressure
    GUARD_MIDS = %i[is_a? kind_of? instance_of? nil? respond_to?].freeze
    Hit = Struct.new(:contract, :file, :defn, :line, keyword_init: true)

    def self.scan(files)
      hits = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f, lines)
        e.walk(root, [], {})
        hits.concat(e.hits)
      end
      Report.new(hits)
    end

    attr_reader :hits

    def initialize(file, lines)
      @file = file
      @lines = lines
      @hits = []
    end

    def walk(node, defstack, asgmap)
      return unless Ast.node?(node)

      if %i[DEFN DEFS].include?(node.type)
        name = node.children[node.type == :DEFS ? 1 : 0].to_s
        defstack = defstack + [name]
        asgmap = build_asgmap(node)
      end

      record_guard(node, defstack, asgmap)
      node.children.each { |c| walk(c, defstack, asgmap) }
    end

    private

    # name => rhs-source-node, for `name = <simple source>` LASGNs in
    # this method (intra-procedural only). First simple assignment wins.
    def build_asgmap(defn_node)
      map = {}
      stack = Ast.body_stmts(defn_node).dup
      until stack.empty?
        n = stack.pop
        next unless Ast.node?(n)

        if n.type == :LASGN
          nm = n.children[0].to_s
          src = n.children[1]
          map[nm] ||= src if !map.key?(nm) && simple_source?(src)
        end
        n.children.each { |c| stack << c }
      end
      map
    end

    def simple_source?(n)
      return false unless Ast.node?(n)

      case n.type
      when :IVAR then true
      when :CALL, :QCALL
        recv, mid, args = n.children
        recv && (args.nil? || mid == :[])
      else false
      end
    end

    def record_guard(node, defstack, asgmap)
      return unless %i[CALL QCALL].include?(node.type)

      recv, mid, _args = node.children
      is_guard =
        (node.type == :CALL && GUARD_MIDS.include?(mid)) ||
        node.type == :QCALL # safe-nav = implicit nil decision on recv
      return unless is_guard && recv

      c = contract_of(recv, asgmap)
      return unless c

      @hits << Hit.new(contract: c, file: @file,
                       defn: defstack.last || "(top-level)",
                       line: node.first_lineno)
    end

    # Canonical root contract of a subject node, resolving locals
    # through the intra-method assignment map.
    def contract_of(n, asgmap, depth = 0)
      return nil unless Ast.node?(n) && depth < 8

      case n.type
      when :LVAR, :DVAR
        nm = n.children[0].to_s
        src = asgmap[nm]
        src ? contract_of(src, asgmap, depth + 1) : "~local"
      when :IVAR
        n.children[0].to_s   # already includes the leading @
      when :CALL, :QCALL
        recv, mid, args = n.children
        if mid == :[]
          key = args && Ast.node?(args) ? args.children.compact.first : nil
          kt = (Ast.node?(key) ? Ast.slice(key, @lines) : key.inspect)
          "[#{kt}]"
        elsif args.nil? && recv
          ".#{mid}"            # no-arg accessor: the contract
        end
      when :VCALL
        ".#{n.children[0]}"
      end
    end

    class Report
      def initialize(hits)
        @hits = hits
      end

      # [{ contract:, decisions:, methods:, sites:[...] }, ...]
      # ranked by decisions; the low-signal "~local" (unresolved
      # proximate local -- needs cross-proc pressure = nil-kill) is
      # reported last regardless of count.
      def ranked
        by = @hits.group_by(&:contract)
        rows = by.map do |contract, hs|
          {
            contract: contract,
            decisions: hs.size,
            methods: hs.map { |h| [h.file, h.defn] }.uniq.size,
            sites: hs.map { |h| "#{h.file}:#{h.defn}:#{h.line}" }
          }
        end
        named = rows.reject { |r| r[:contract] == "~local" }
                    .sort_by { |r| [-r[:decisions], -r[:methods]] }
        local = rows.select { |r| r[:contract] == "~local" }
        named + local
      end
    end
  end
end
