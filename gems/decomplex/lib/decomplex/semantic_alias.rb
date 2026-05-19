# frozen_string_literal: true

require_relative "ast"

module Decomplex
  # Semantic predicate alias. The exact-text PredicateAlias misses the
  # real plague: `frame?` defined as `@provenance == :frame`, then the
  # body `@provenance == :frame` (or `provenance == :frame`, or
  # `node.provenance == :frame`) written inline at 30 sites instead of
  # calling `frame?`. This is invariant #16 violated -- a decision that
  # IS fixed state, re-derived.
  #
  # Method: build the predicate-definition map (one-line `def x?`),
  # then CANONICALISE both predicate bodies and inline conjunction
  # atoms by stripping receivers (`node.`, `self.`, `@`) and folding
  # polarity, so `@provenance == :frame` == `provenance == :frame` ==
  # `n.provenance == :frame`. Cluster by canonical form. Bounded,
  # zero points-to (per the design boundary): receiver stripping is a
  # syntactic canonicalisation, not alias analysis.
  class SemanticAlias
    Pred = Struct.new(:name, :canon, :file, :line, :span, keyword_init: true)
    Use  = Struct.new(:canon, :file, :defn, :line, :raw, :span,
                      keyword_init: true)

    def self.scan(files)
      preds = []
      uses = []
      files.each do |f|
        root, lines = Ast.parse(f)
        e = new(f, lines)
        e.walk(root, [])
        preds.concat(e.preds)
        uses.concat(e.uses)
      end
      Report.new(preds, uses)
    end

    attr_reader :preds, :uses

    def initialize(file, lines)
      @file = file
      @lines = lines
      @preds = []
      @uses = []
    end

    def walk(node, defstack)
      return unless Ast.node?(node)

      defstack = Ast.def_push(node, defstack)
      record_pred(node) if node.type == :DEFN
      if %i[CALL OPCALL].include?(node.type) && comparison?(node)
        c = canon(Ast.slice(node, @lines))
        @uses << Use.new(canon: c, file: @file,
                         defn: defstack.last || "(top-level)",
                         line: node.first_lineno,
                         raw: Ast.slice(node, @lines),
                         span: [node.first_lineno, node.first_column,
                                node.last_lineno, node.last_column])
      end
      node.children.each { |ch| walk(ch, defstack) }
    end

    # Canonical predicate form: drop a leading `!`, strip a leading
    # receiver chain (`a.b.`, `@`, `self.`) before the final
    # `name OP value`, collapse spaces. Pure syntactic folding.
    def self.canon(text)
      t, = Ast.canon_polarity(text)
      t = t.sub(/\Aself\./, "").sub(/\A@/, "")
      # strip a single receiver hop: `recv.attr == :v` -> `attr == :v`
      t = t.sub(/\A[A-Za-z_]\w*(?:\([^)]*\))?\.(?=[A-Za-z_]\w*\s*(==|!=|\.))/, "")
      t.gsub(/\s+/, " ").strip
    end

    private

    def canon(text) = self.class.canon(text)

    def comparison?(node)
      mid = node.children[node.type == :OPCALL ? 1 : 1]
      %i[== != nil?].include?(mid) ||
        (node.type == :CALL && node.children[1] == :nil?)
    end

    def record_pred(node)
      name = node.children[0].to_s
      return unless name.end_with?("?")

      stmts = Ast.body_stmts(node)
      return unless stmts.size == 1

      @preds << Pred.new(name: name, canon: canon(Ast.slice(stmts.first, @lines)),
                         file: @file, line: node.first_lineno,
                         span: [node.first_lineno, node.first_column,
                                node.last_lineno, node.last_column])
    end

    class Report
      def initialize(preds, uses)
        @preds = preds
        @uses = uses
      end

      # Predicates whose canonical body collides under >= 2 names, OR
      # collides with a different spelling. [{ canon:, names:[...] }]
      def alias_clusters
        @preds.group_by(&:canon).filter_map do |c, ps|
          names = ps.map(&:name).uniq
          next if names.size < 2

          { canon: c, names: names,
            sites: ps.map { |p| "#{p.file}:#{p.name}:#{p.line}" },
            spans: ps.to_h { |p| ["#{p.file}:#{p.name}:#{p.line}", p.span] } }
        end.sort_by { |h| -h[:names].size }
      end

      # An inline comparison whose canonical form equals a defined
      # predicate's canonical body, not made by calling the predicate.
      # The damning invariant-#16 form. [{ predicate:, canon:, at:, raw: }]
      def reification_misses
        bycanon = @preds.group_by(&:canon)
        @uses.filter_map do |u|
          ps = bycanon[u.canon]
          next unless ps && !ps.empty?
          next if u.defn.end_with?("?") && ps.any? { |p| p.name == u.defn }

          { predicate: ps.first.name, canon: u.canon,
            at: "#{u.file}:#{u.defn}:#{u.line}",
            spans: { "#{u.file}:#{u.defn}:#{u.line}" => u.span },
            raw: u.raw }
        end.sort_by { |h| h[:predicate] }
      end
    end
  end
end
