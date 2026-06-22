# frozen_string_literal: true

require_relative "syntax"

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
        Syntax.parse(f, parser: "tree_sitter").predicate_defs.each do |predicate|
          preds << Pred.new(
            name: predicate.name,
            body: predicate.body,
            file: predicate.file,
            defn: predicate.name,
            line: predicate.line,
            span: predicate.span
          )
        end
      end
      Report.new(preds)
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
