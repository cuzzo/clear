# frozen_string_literal: true

module Decomplex
  # Predicate-alias clustering (cf. predicate abstraction in SLAM/BLAST,
  # and pre-mining canonicalization in spec miners).
  #
  # Plague targeted: "re-derived decisions that should be fixed state."
  # A one-line boolean method IS a named decision. Two such methods
  # with the same body are the SAME decision under two names (drift
  # risk). And an inline expression equal to a known predicate's body,
  # written without calling that predicate, is a reification miss --
  # the function already exists and was reinvented in place. That is
  # the most damning form of plague B and the literal invariant-#16
  # violation pattern (frame? vs provenance == :frame, etc.).
  class PredicateAlias
    Pred = Struct.new(:name, :body, :file, :defn, :line, :span,
                      keyword_init: true)

    def self.scan(files)
      preds = []
      files.each do |f|
        src = File.read(f)
        root = RubyVM::AbstractSyntaxTree.parse(src, keep_script_lines: true)
        new(f, src.lines).tap { |p| p.walk(root) }.preds.each { |p| preds << p }
      end
      Report.new(preds)
    end

    attr_reader :preds

    def initialize(file, lines)
      @file = file
      @lines = lines
      @preds = []
    end

    def walk(node)
      return unless node.is_a?(RubyVM::AbstractSyntaxTree::Node)

      record_def(node) if node.type == :DEFN
      node.children.each { |c| walk(c) }
    end

    private

    # Single-expression boolean-ish method: `def x?(...) <expr> end`.
    # The scope node's body is one statement (not a BLOCK of many).
    def record_def(node)
      name = node.children[0].to_s
      scope = node.children[1]
      return unless scope.is_a?(RubyVM::AbstractSyntaxTree::Node) && scope.type == :SCOPE

      body = scope.children[2]
      return unless body.is_a?(RubyVM::AbstractSyntaxTree::Node)
      return if body.type == :BLOCK # multi-statement => not a pure predicate

      txt = slice(body)
      return if txt.empty? || txt.length > 200

      @preds << Pred.new(name: name, body: txt, file: @file,
                         defn: name, line: node.first_lineno,
                         span: [node.first_lineno, node.first_column,
                                node.last_lineno, node.last_column])
    end

    def slice(node)
      sl = node.first_lineno
      el = node.last_lineno
      t =
        if sl == el
          @lines[sl - 1][node.first_column...node.last_column]
        else
          ([@lines[sl - 1][node.first_column..]] +
            @lines[sl...(el - 1)] +
            [@lines[el - 1][0...node.last_column]]).join
        end
      t.to_s.strip.gsub(/\s+/, " ")
    end

    class Report
      def initialize(preds)
        @preds = preds
      end

      # Same body, >=2 names = the same decision under aliases.
      # [{ body:, names:[...], sites:[...] }, ...]
      def alias_clusters
        @preds.group_by(&:body).filter_map do |body, ps|
          names = ps.map(&:name).uniq
          next if names.size < 2

          { body: body, names: names,
            sites: ps.map { |p| "#{p.file}:#{p.name}:#{p.line}" },
            spans: ps.to_h { |p| ["#{p.file}:#{p.name}:#{p.line}", p.span] } }
        end.sort_by { |h| -h[:names].size }
      end

      # A known predicate body that appears as an inline conjunction
      # member elsewhere, NOT calling the predicate -- reification miss.
      # `sites` are Decomplex::Site (kind :conjunction) from the miner.
      # [{ predicate:, body:, inline_at:[...] }, ...]
      def reification_misses(conjunction_sites)
        index = @preds.group_by(&:body)
        conjunction_sites.filter_map do |s|
          joined = s.members.join(" && ")
          hit = index.keys.find { |b| b == joined }
          next unless hit

          pred = index[hit].first
          # The predicate's own one-line body is itself a conjunction
          # site -- that is the definition, not a reinvention.
          next if s.defn == pred.name

          { predicate: pred.name, body: hit,
            inline_at: "#{s.file}:#{s.defn}:#{s.line}",
            spans: { "#{s.file}:#{s.defn}:#{s.line}" => s.span } }
        end
      end
    end
  end
end
