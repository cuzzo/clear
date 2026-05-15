# frozen_string_literal: true

require_relative "../decomplex"

module Decomplex
  # Aggregates every detector over a file set and renders a single
  # markdown report (structured after gems/nil-kill/report.md: TOC,
  # prioritisation, per-detector sections, run summary). Every number
  # is a ranked CANDIDATE count, never a verdict.
  class Report
    def initialize(files)
      @files = files
      run
    end

    def run
      m = Miner.scan(@files)
      @miss   = m.missing_abstractions
      @negc   = m.neglected_conditions
      cu      = CoUpdate.scan(@files)
      @negu   = cu.neglected_updates
      @copair = cu.co_written_pairs
      pa      = PredicateAlias.scan(@files)
      @palias = pa.alias_clusters
      sa      = SemanticAlias.scan(@files)
      @salias = sa.alias_clusters
      @reif   = sa.reification_misses
      pc      = PathCondition.scan(@files)
      @pcneg  = pc.neglected
      @pcsc   = pc.scattered
      sm      = SequenceMine.scan(@files)
      @broken = sm.broken_protocol
      @derived = DerivedState.scan(@files)
      @clones  = Type3Clone.scan(@files)
    end

    SECTIONS = [
      ["Missing Abstractions",   :@miss,   "guard tuple recomputed across >=2 decision units"],
      ["Neglected Conditions",   :@negc,   "dispatch/conjunction minus one element -- likely bug"],
      ["Neglected Updates",      :@negu,   "co-written state, one write missing -- redundant-state desync"],
      ["Semantic Predicate Aliases", :@salias, "one decision, multiple names (receiver/polarity folded)"],
      ["Reification Misses",     :@reif,   "an existing predicate reinvented inline -- invariant #16"],
      ["Neglected Path Conditions", :@pcneg, "nested-if/&& guard set minus one atom"],
      ["Broken Protocols",       :@broken, "co-called pair, one site does A without B"],
      ["Derived-State Staleness", :@derived, "b = f(a); a later reassigned, b not recomputed"],
      ["Type-3 Clones (missed rename)", :@clones, "pasted block, one identifier inconsistently renamed"],
      ["Exact Predicate Aliases", :@palias, "identical one-line predicate body under >=2 names"]
    ].freeze

    def slug(t)
      t.downcase.gsub(/[^a-z0-9 ]/, "").tr(" ", "-")
    end

    def to_markdown
      out = +"# Decomplex Report\n\n"
      out << "> Decision-level duplication and neglected-condition analysis.\n" \
              "> Every count is a ranked **candidate** list (Engler's discipline),\n" \
              "> not a verdict. Triage top-of-list first.\n\n"

      out << "## Table of Contents\n"
      out << "- [Project Prioritization](#project-prioritization)\n"
      SECTIONS.each do |title, ivar, _|
        n = instance_variable_get(ivar).size
        out << "- [#{title} (#{n})](##{slug(title)}-#{n})\n"
      end
      out << "- [Run Summary](#run-summary)\n\n"

      out << "## Project Prioritization\n"
      ranked = SECTIONS.map { |t, iv, d| [t, instance_variable_get(iv), d] }
                       .reject { |_, v, _| v.empty? }
                       .sort_by { |_, v, _| -v.size }
      ranked.each do |title, v, desc|
        out << "- [#{title} (#{v.size})](##{slug(title)}-#{v.size}): #{desc}\n"
      end
      out << "\nNothing flagged.\n" if ranked.empty?
      out << "\n"

      SECTIONS.each do |title, ivar, desc|
        v = instance_variable_get(ivar)
        out << "## #{title} (#{v.size})\n"
        out << "_#{desc}_\n\n"
        if v.empty?
          out << "None.\n\n"
          next
        end
        render(out, title, v)
        out << "\n"
      end

      out << "## Run Summary\n"
      out << "- Files analyzed: #{@files.size}\n"
      out << "- Detectors: #{SECTIONS.size} (all shipped, self-tested)\n"
      total = SECTIONS.sum { |_, iv, _| instance_variable_get(iv).size }
      out << "- Total candidates: #{total}\n"
      out << "- Method: stdlib AST only, intra-procedural, zero deps, " \
             "no CFG / no points-to (see docs/agents/design.md)\n"
      out
    end

    private

    def render(out, title, v)
      v.first(25).each do |h|
        out << case title
               when "Missing Abstractions"
                 "- **[#{h[:kind]}]** support=#{h[:support]} scatter=#{h[:scatter]} " \
                 "rank=#{h[:rank]}\n  - tuple: `#{h[:members].join(' | ')}`\n" \
                 "  - #{h[:sites].first(6).join(' ; ')}\n"
               when "Neglected Conditions", "Neglected Path Conditions"
                 "- support=#{h[:support]} at `#{h[:at]}` -- MISSING " \
                 "`#{h[:missing]}` from `#{(h[:pattern] || h[:guards]).join(' | ')}`\n"
               when "Neglected Updates"
                 "- support=#{h[:support]} `#{h[:at]}` writes `.#{h[:has]}` " \
                 "but NOT `.#{h[:missing]}` (recv `#{h[:recv]}`)\n"
               when "Semantic Predicate Aliases", "Exact Predicate Aliases"
                 "- `#{h[:names].join(' = ')}` == `#{h[:canon] || h[:body]}`\n" \
                 "  - #{h[:sites].join(' ; ')}\n"
               when "Reification Misses"
                 "- predicate `#{h[:predicate]}` reinvented inline at " \
                 "`#{h[:at]}` (`#{h[:raw]}`)\n"
               when "Broken Protocols"
                 "- conf=#{h[:confidence]} support=#{h[:support]} `#{h[:at]}` " \
                 "does `#{h[:has]}` without `#{h[:missing]}`\n"
               when "Derived-State Staleness"
                 "- `#{h[:at]}`: `#{h[:derived]}` derived from `#{h[:source]}` " \
                 "(line #{h[:derived_at]}); `#{h[:source]}` reassigned line " \
                 "#{h[:source_reassigned_at]}, `#{h[:derived]}` not recomputed\n"
               when "Type-3 Clones (missed rename)"
                 "- `#{h[:at]}` clone of `#{h[:ref_at]}`: ref var " \
                 "`#{h[:ref_name]}` spelled #{h[:divergent].inspect} here\n"
               end
      end
      out << "- ...(+#{v.size - 25} more)\n" if v.size > 25
    end
  end
end
