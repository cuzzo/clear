# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Decision-pressure: attribute every defensive type/nil guard to the
  # canonical ROOT CONTRACT its subject comes from, then rank contracts
  # by how many re-derived decisions they drive.
  #
  # Use-role discipline (Rapps & Weyuker 1985 c-use/p-use; McCabe /
  # Cognitive Complexity count DECISIONS, not reads): a single blended
  # "N defensive decisions" scalar is a category error -- it sums
  # populations with OPPOSITE actions. This detector therefore splits,
  # and the report NEVER presents one combined number:
  #
  #   * c-use (`emit(x.full_type)`, `y = x.full_type`, `return
  #     x.full_type`) -- pure consumption, NOT a decision. Excluded by
  #     construction (never recorded). Not complexity.
  #   * ELIMINABLE guard (`x.nil?`, `is_a?`, `kind_of?`,
  #     `instance_of?`, `respond_to?`, `x&.m`, `x.acc rescue nil`) --
  #     contract-eliminable: a stronger contract removes it. The
  #     actionable slop. -> tighten the contract / nil-kill (DELETE).
  #   * ESSENTIAL dispatch (`x.string?`, `.collection?`,
  #     `.heap_provenance?` -- a domain `?` query over a value that is
  #     legitimately a sum). NOT removable by typing; it IS the
  #     contract. Debt ONLY if the same dispatch is re-scattered, which
  #     is a DIFFERENT metric (Fat-Union / Missing-Abstractions). Shown
  #     as a per-contract context count, never summed into the headline.
  #
  # Pressure is decomplex-scoped: intra-procedural only (a local is
  # resolved to the accessor it was assigned from IN THE SAME METHOD).
  # Cross-procedure pressure is nil-kill's, by the recorded boundary.
  class DecisionPressure
    GUARD_MIDS = %i[is_a? kind_of? instance_of? nil? respond_to?].freeze
    Hit = Struct.new(:contract, :file, :defn, :line, :span,
                     keyword_init: true)

    def self.scan(files)
      guard = []
      dispatch = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f, lines)
        e.walk(root, [], {})
        guard.concat(e.guard_hits)
        dispatch.concat(e.dispatch_hits)
      end
      Report.new(guard, dispatch)
    end

    attr_reader :guard_hits, :dispatch_hits

    def initialize(file, lines)
      @file = file
      @lines = lines
      @guard_hits = []
      @dispatch_hits = []
    end

    def walk(node, defstack, asgmap)
      return unless Ast.node?(node)

      if %i[DEFN DEFS].include?(node.type)
        name = node.children[node.type == :DEFS ? 1 : 0].to_s
        defstack = defstack + [name]
        asgmap = build_asgmap(node)
      end

      record_decision(node, defstack, asgmap)
      record_rescue_nil(node, defstack, asgmap)
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

    def hit(contract, defstack, node)
      Hit.new(contract: contract, file: @file,
              defn: defstack.last || "(top-level)",
              line: node.first_lineno,
              span: [node.first_lineno, node.first_column,
                     node.last_lineno, node.last_column])
    end

    # At most ONE record per node. ELIMINABLE guard takes precedence
    # over ESSENTIAL dispatch (a `?` that is also a GUARD_MID, or a
    # safe-nav, is the eliminable kind).
    def record_decision(node, defstack, asgmap)
      return unless %i[CALL QCALL].include?(node.type)

      recv, mid, _args = node.children
      return unless recv

      guard =
        (node.type == :CALL && GUARD_MIDS.include?(mid)) ||
        node.type == :QCALL # safe-nav = implicit nil decision on recv
      if guard
        c = contract_of(recv, asgmap)
        @guard_hits << hit(c, defstack, node) if c
        return
      end

      # essential dispatch: a domain `?` query over a contract. NOT a
      # GUARD_MID (those are eliminable, handled above). Legitimate
      # polymorphism -- counted separately, never as pressure.
      return unless node.type == :CALL && mid.to_s.end_with?("?")

      c = contract_of(recv, asgmap)
      @dispatch_hits << hit(c, defstack, node) if c
    end

    # `x.accessor rescue nil` -- a defensive nil-swallow that exists
    # only because the receiver is loosely typed. Eliminable guard
    # (the exact idiom typed contracts remove). Conservative: bare
    # `rescue nil` wrapping a single contract-resolvable call.
    def record_rescue_nil(node, defstack, asgmap)
      return unless node.type == :RESCUE

      body, resb, = node.children
      return unless Ast.node?(resb) && resb.type == :RESBODY
      return unless resb.children[0].nil? # bare rescue (no class list)

      handler = resb.children[1]
      nil_handler = handler.nil? ||
                    (Ast.node?(handler) && handler.type == :NIL)
      return unless nil_handler
      return unless Ast.node?(body) && %i[CALL QCALL].include?(body.type)

      c = contract_of(body, asgmap)
      @guard_hits << hit(c, defstack, node) if c
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
      def initialize(guard_hits, dispatch_hits)
        @guard = guard_hits
        @dispatch = dispatch_hits
      end

      # Rows are keyed/driven by ELIMINABLE guards (the actionable
      # slop). A contract with only ESSENTIAL dispatch and zero
      # eliminable guards produces NO row -- legitimate polymorphism is
      # not pressure and must not be surfaced as actionable.
      #
      # `decisions` == eliminable guard count (the headline number,
      # back-compat). `essential` == count of essential dispatches on
      # the SAME contract (context only; NEVER summed into decisions,
      # and deliberately NOT added to sites/spans so downstream
      # consumers see the eliminable signal unchanged).
      #
      # [{ contract:, decisions:, essential:, methods:, sites:[...],
      #    spans:{} }] ; ranked by eliminable decisions; "~local" last.
      def ranked
        ess = Hash.new(0)
        @dispatch.each { |h| ess[h.contract] += 1 }

        rows = @guard.group_by(&:contract).map do |contract, hs|
          {
            contract: contract,
            decisions: hs.size,
            essential: ess[contract],
            methods: hs.map { |h| [h.file, h.defn] }.uniq.size,
            sites: hs.map { |h| "#{h.file}:#{h.defn}:#{h.line}" },
            spans: hs.to_h { |h| ["#{h.file}:#{h.defn}:#{h.line}", h.span] }
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
