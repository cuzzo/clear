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
      @pressure = DecisionPressure.scan(@files).ranked
    end

    # tier = signal quality (1 = highest signal / lowest false-positive,
    # 3 = high-recall but noisy). Sections are ordered by tier, NOT by
    # raw volume -- a noisy detector with thousands of low-value hits
    # must not outrank a precise one. Within a section, items are
    # frequency-ranked (support / scatter / confidence, descending).
    SECTIONS = [
      ["Decision Pressure",      :@pressure, 1, "loose contract -> N defensive type/nil decisions; fix the contract once, the cluster dies (intra-proc; cross-proc = nil-kill)"],
      ["Missing Abstractions",   :@miss,   1, "guard tuple recomputed across >=2 decision units"],
      ["Reification Misses",     :@reif,   1, "an existing predicate reinvented inline -- invariant #16"],
      ["Semantic Predicate Aliases", :@salias, 1, "one decision, multiple names (receiver/polarity folded)"],
      ["Exact Predicate Aliases", :@palias, 1, "identical one-line predicate body under >=2 names"],
      ["Type-3 Clones (missed rename)", :@clones, 2, "pasted block, one identifier inconsistently renamed -- *POSSIBLE* bug"],
      ["Neglected Updates",      :@negu,   2, "co-written state, one write missing -- *POSSIBLE* redundant-state desync"],
      ["Derived-State Staleness", :@derived, 2, "b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug"],
      ["Neglected Conditions",   :@negc,   2, "dispatch/conjunction minus one element -- *POSSIBLE* bug"],
      ["Neglected Path Conditions", :@pcneg, 3, "nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)"],
      ["Broken Protocols",       :@broken, 3, "co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)"]
    ].freeze

    def slug(t)
      t.downcase.gsub(/[^a-z0-9 ]/, "").tr(" ", "-")
    end

    # `file:method:line` is not a navigable link; editors want
    # `file:line`. Split from the right (line numeric, method has no
    # colon, file path may) and render `file:line (method)`.
    def nav(loc)
      parts = loc.to_s.split(":")
      return loc if parts.size < 3

      line = parts.pop
      meth = parts.pop
      file = parts.join(":")
      "`#{file}:#{line}` (#{meth})"
    end

    def to_markdown
      out = +"# Decomplex Report\n\n"
      out << "> Decision-level duplication and neglected-condition analysis.\n" \
              "> Every entry is a ranked **candidate** (Engler's discipline),\n" \
              "> never a verdict -- *POSSIBLE* findings, triaged by a human.\n" \
              "> Sections are ordered by SIGNAL TIER (1 = lowest false\n" \
              "> positive), not by volume. Items within a section are\n" \
              "> frequency-ranked. Triage tier 1, top-of-list, first.\n\n"

      out << "## Table of Contents\n"
      out << "- [Project Prioritization](#project-prioritization)\n"
      SECTIONS.each do |title, ivar, _tier, _|
        n = instance_variable_get(ivar).size
        out << "- [#{title} (#{n})](##{slug(title)}-#{n})\n"
      end
      out << "- [Run Summary](#run-summary)\n\n"

      out << "## Project Prioritization\n"
      out << "_Ordered by signal tier (1 = highest signal / lowest FP), " \
             "then by volume._\n\n"
      ranked = SECTIONS.map { |t, iv, tier, d| [t, instance_variable_get(iv), tier, d] }
                       .reject { |_, v, _, _| v.empty? }
                       .sort_by { |_, v, tier, _| [tier, -v.size] }
      ranked.each do |title, v, tier, desc|
        out << "- **[tier #{tier}]** [#{title} (#{v.size})]" \
               "(##{slug(title)}-#{v.size}): #{desc}\n"
      end
      out << "\nNothing flagged.\n" if ranked.empty?
      out << "\n"

      SECTIONS.each do |title, ivar, _tier, desc|
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
               when "Decision Pressure"
                 "- `#{h[:contract]}` drives **#{h[:decisions]}** defensive " \
                 "type/nil decisions across #{h[:methods]} method(s)\n" \
                 "  - #{h[:sites].first(4).map { |s| nav(s) }.join(' ; ')}\n"
               when "Missing Abstractions"
                 "- **[#{h[:kind]}]** support=#{h[:support]} scatter=#{h[:scatter]} " \
                 "rank=#{h[:rank]}\n  - tuple: `#{h[:members].join(' | ')}`\n" \
                 "  - #{h[:sites].first(6).map { |s| nav(s) }.join(' ; ')}\n"
               when "Neglected Conditions", "Neglected Path Conditions"
                 "- *POSSIBLE* (support=#{h[:support]}) #{nav(h[:at])} -- MISSING " \
                 "`#{h[:missing]}` from `#{(h[:pattern] || h[:guards]).join(' | ')}`\n"
               when "Neglected Updates"
                 "- *POSSIBLE* (support=#{h[:support]}) #{nav(h[:at])} writes `.#{h[:has]}` " \
                 "but NOT `.#{h[:missing]}` (recv `#{h[:recv]}`)\n"
               when "Semantic Predicate Aliases", "Exact Predicate Aliases"
                 "- `#{h[:names].join(' = ')}` == `#{h[:canon] || h[:body]}`\n" \
                 "  - #{h[:sites].map { |s| nav(s) }.join(' ; ')}\n"
               when "Reification Misses"
                 "- predicate `#{h[:predicate]}` reinvented inline at " \
                 "#{nav(h[:at])} (`#{h[:raw]}`)\n"
               when "Broken Protocols"
                 "- *POSSIBLE* conf=#{h[:confidence]} support=#{h[:support]} " \
                 "#{nav(h[:at])} does `#{h[:has]}` without `#{h[:missing]}`\n"
               when "Derived-State Staleness"
                 "- *POSSIBLE* #{nav(h[:at])}: `#{h[:derived]}` derived from " \
                 "`#{h[:source]}` (line #{h[:derived_at]}); `#{h[:source]}` " \
                 "reassigned line #{h[:source_reassigned_at]}, `#{h[:derived]}` " \
                 "not recomputed\n"
               when "Type-3 Clones (missed rename)"
                 "- *POSSIBLE* #{nav(h[:at])} clone of #{nav(h[:ref_at])}: ref var " \
                 "`#{h[:ref_name]}` spelled #{h[:divergent].inspect} here\n"
               end
      end
      out << "- ...(+#{v.size - 25} more)\n" if v.size > 25
    end
  end
end
