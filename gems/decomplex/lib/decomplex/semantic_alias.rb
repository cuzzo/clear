# frozen_string_literal: true

require_relative "syntax"

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
        document = Syntax.parse(f, parser: "tree_sitter")
        document.predicate_defs.each do |predicate|
          next unless semantic_predicate_definition?(predicate)

          preds << Pred.new(
            name: predicate.name,
            canon: canon(predicate.body),
            file: predicate.file,
            line: predicate.line,
            span: predicate.span
          )
        end
        document.comparison_sites.each do |comparison|
          uses << Use.new(
            canon: canon(comparison.source),
            file: comparison.file,
            defn: comparison.function,
            line: comparison.line,
            raw: comparison.source,
            span: comparison.span
          )
        end
        document.branch_arms.each do |arm|
          next unless arm.predicate.to_s.match?(/(?:==|!=)/)

          uses << Use.new(
            canon: canon(arm.predicate),
            file: arm.file,
            defn: arm.function,
            line: arm.decision_line,
            raw: arm.predicate,
            span: arm.decision_span
          )
        end
      end
      uses.uniq! { |use| [use.file, use.defn, use.line, use.canon, use.raw] }
      Report.new(preds, uses)
    end

    def self.semantic_predicate_definition?(predicate)
      predicate.name.to_s.end_with?("?") ||
        predicate.body.to_s.match?(/(?:==|!=|&&|\|\||\band\b|\bor\b)/)
    end

    # Canonical predicate form: drop a leading `!`, strip a leading
    # receiver chain (`a.b.`, `@`, `self.`) before the final
    # `name OP value`, collapse spaces. Pure syntactic folding.
    def self.canon(text)
      t, = canon_polarity(text)
      t = t.sub(/\Aself\./, "").sub(/\A@/, "")
      # strip a single receiver hop: `recv.attr == :v` -> `attr == :v`
      t = t.sub(/\A[A-Za-z_]\w*(?:\([^)]*\))?\.(?=[A-Za-z_]\w*\s*(==|!=|\.))/, "")
      t.gsub(/\s+/, " ").strip
    end

    def self.canon_polarity(text)
      source = text.to_s.strip
      return [source[1..].to_s.strip, true] if source.start_with?("!")

      [source, false]
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
          next if ps.any? { |p| p.name == u.defn }

          { predicate: ps.first.name, canon: u.canon,
            at: "#{u.file}:#{u.defn}:#{u.line}",
            spans: { "#{u.file}:#{u.defn}:#{u.line}" => u.span },
            raw: u.raw }
        end.sort_by { |h| h[:predicate] }
      end
    end
  end
end
