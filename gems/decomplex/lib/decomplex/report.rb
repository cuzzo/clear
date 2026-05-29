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
      @rename_clones = InconsistentRenameClone.scan(@files)
      @similarity = FlaySimilarity.scan(
        @files,
        mass: Integer(ENV.fetch("DECOMPLEX_FLAY_MASS", FlaySimilarity::DEFAULT_MASS)),
        fuzzy: Integer(ENV.fetch("DECOMPLEX_FLAY_FUZZY", FlaySimilarity::DEFAULT_FUZZY))
      )
      @pressure = DecisionPressure.scan(@files).ranked
      @fsimple = FalseSimplicity.scan(@files).findings
      @fatu = FatUnion.scan(@files).fat_unions
      # sections_data also asserts the span contract -- running it on
      # the normal report path keeps that tripwire live.
      sd = sections_data
      @convergence = Convergence.rollup(sd)
      @root = RootCause.cluster(sd)
    end

    # tier = signal quality (1 = highest signal / lowest false-positive,
    # 3 = high-recall but noisy). Sections are ordered by tier, NOT by
    # raw volume -- a noisy detector with thousands of low-value hits
    # must not outrank a precise one. Within a section, items are
    # frequency-ranked (support / scatter / confidence, descending).
    SECTIONS = [
      ["Decision Pressure",      :@pressure, 1, "ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)"],
      ["Missing Abstractions",   :@miss,   1, "guard tuple recomputed across >=2 decision units"],
      ["Reification Misses",     :@reif,   1, "an existing predicate reinvented inline -- invariant #16"],
      ["Semantic Predicate Aliases", :@salias, 1, "one decision, multiple names (receiver/polarity folded)"],
      ["Exact Predicate Aliases", :@palias, 1, "identical one-line predicate body under >=2 names"],
      ["Inconsistent Rename Clones", :@rename_clones, 2, "pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug"],
      ["Flay Similarity (Type-2/3)", :@similarity, 2, "Flay structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict"],
      ["Neglected Updates",      :@negu,   2, "co-written state, one write missing -- *POSSIBLE* redundant-state desync"],
      ["Derived-State Staleness", :@derived, 2, "b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug"],
      ["Neglected Conditions",   :@negc,   2, "dispatch/conjunction minus one element -- *POSSIBLE* bug"],
      ["Neglected Path Conditions", :@pcneg, 3, "nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)"],
      ["Broken Protocols",       :@broken, 3, "co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)"],
      ["False Simplicity",       :@fsimple, 3, "looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/metaprogramming/monkeypatch -- *POSSIBLE* (noisy)"],
      ["Fat Unions",             :@fatu,   3, "case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*"]
    ].freeze

    # Read-only structured verdict for sibling consumers (slopcop):
    # the exact [title, tier, findings] triples to_markdown renders and
    # Convergence already consumes. Single source of truth -- consumers
    # read this and never re-derive a detector.
    #
    # Span invariant is asserted HERE, at the published contract
    # boundary (the owner enforces its own contract): every finding
    # :spans value is nil or a [fl,fc,ll,lc] integer tuple with
    # fl<=ll. A violation means a detector is emitting a bad span --
    # fail loud, in decomplex's own run, naming the detector, instead
    # of as a cryptic `nil <= line` three gems downstream. Structurally
    # unreachable today (spans are raw AST node line/col); this is the
    # tripwire that catches a future detector regression at the source.
    def sections_data
      data = SECTIONS.map { |t, iv, tier, _| [t, tier, instance_variable_get(iv)] }
      data.each do |title, _tier, findings|
        next unless findings

        findings.each do |f|
          spans = f[:spans]
          next unless spans

          spans.each do |loc, s|
            next if s.nil?

            ok = s.is_a?(Array) && s.size == 4 &&
                 s[0].is_a?(Integer) && s[2].is_a?(Integer) && s[0] <= s[2]
            next if ok

            raise ArgumentError,
                  "decomplex: #{title} emitted malformed span " \
                  "#{s.inspect} for #{loc}"
          end
        end
      end
      data
    end

    # Read-only accessor for sibling consumers / Delta (parallel to
    # sections_data). The RootCause clusters this run produced.
    def root_clusters = @root

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
      out << "- [Cross-Detector Convergence (#{@convergence.size})]" \
             "(#cross-detector-convergence-#{@convergence.size})\n"
      out << "- [Root-Cause Clusters (#{@root.size})]" \
             "(#root-cause-clusters-#{@root.size})\n"
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

      out << "## Cross-Detector Convergence (#{@convergence.size})\n"
      out << "_(file, method) units flagged by >=2 INDEPENDENT detectors " \
             "-- the strongest triage signal: agreement outranks any " \
             "single detector's volume. Tier-weighted (1=3, 2=2, 3=1). " \
             "**Start here.**_\n\n"
      if @convergence.empty?
        out << "None (no unit flagged by >=2 detectors).\n\n"
      else
        @convergence.first(25).each do |h|
          out << "- #{nav(h[:at])} -- **#{h[:n_detectors]} detectors** " \
                 "[score #{h[:score]}, #{h[:findings]} findings]: " \
                 "#{h[:detectors].join(', ')}\n"
        end
        if @convergence.size > 25
          out << "- ...(+#{@convergence.size - 25} more)\n"
        end
        bf = Convergence.by_file(@convergence)
        unless bf.empty?
          out << "\n### By file\n"
          bf.first(15).each do |h|
            out << "- `#{h[:file]}` -- #{h[:n_detectors]} detectors across " \
                   "#{h[:methods]} method(s): #{h[:detectors].join(', ')}\n"
          end
        end
        out << "\n"
      end

      out << "## Root-Cause Clusters (#{@root.size})\n"
      out << "_Findings across >=2 INDEPENDENT detectors that name the " \
             "SAME entity -- 'N findings are really one invariant'. " \
             "Convergence says where to look; this says **what one fix " \
             "collapses the cluster**. Ranked candidate, not a verdict._\n\n"
      if @root.empty?
        out << "None (no entity named by >=2 detectors).\n\n"
      else
        @root.first(20).each do |h|
          tag = h[:fat_union] ? "[#{h[:kind]} | FAT-UNION]" : "[#{h[:kind]}]"
          out << "- **#{tag}** `#{h[:token]}` -- " \
                 "**#{h[:n_detectors]} detectors** [score #{h[:score]}] " \
                 "across #{h[:scatter]} unit(s), #{h[:support]} findings: " \
                 "#{h[:detectors].join(', ')}\n" \
                 "  - FIX: #{h[:fix]}\n" \
                 "  - #{h[:sites].first(4).map { |s| nav(s) }.join(' ; ')}\n"
        end
        out << "- ...(+#{@root.size - 20} more)\n" if @root.size > 20
        out << "\n"
      end

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
      out << "- Convergence: #{@convergence.size} unit(s) flagged by " \
             ">=2 independent detectors\n"
      out << "- Root-cause clusters: #{@root.size} (one fix collapses " \
             "each)\n"
      total = SECTIONS.sum { |_, iv, _| instance_variable_get(iv).size }
      out << "- Total candidates: #{total}\n"
      out << "- Method: stdlib AST only, intra-procedural, zero deps, " \
             "no CFG / no points-to; Flay similarity is an optional " \
             "external signal consumed read-only (see docs/agents/design.md)\n"
      out
    end

    private

    def render(out, title, v)
      v.first(25).each do |h|
        out << case title
               when "Decision Pressure"
                 "- `#{h[:contract]}` -- ELIMINABLE guard-pressure " \
                 "**#{h[:decisions]}** across #{h[:methods]} method(s) " \
                 "-> tighten contract / nil-kill: DELETE" \
                 "#{h[:essential].positive? ? "  (+#{h[:essential]} essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)" : ''}\n" \
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
               when "False Simplicity"
                 "- *POSSIBLE* [#{h[:kind]}] scatter=#{h[:scatter]} " \
                 "support=#{h[:support]} `#{h[:detail]}` -- #{nav(h[:at])}" \
                 "#{h[:sites].size > 1 ? " (+#{h[:sites].size - 1} more)" : ''}\n"
               when "Fat Unions"
                 "- *POSSIBLE*#{h[:degenerate] ? ' [DEGENERATE: no variance]' : ''} " \
                 "union `#{h[:variant_set].join(' | ')}` -- " \
                 "**#{h[:common].size} common** vs #{h[:variant].size} variant " \
                 "member(s), scatter=#{h[:scatter]} -- #{nav(h[:at])}\n" \
                 "  - common: `#{h[:common].first(8).join(', ')}` -> hoist to a struct, " \
                 "keep a SMALL union for `#{h[:variant].first(6).join(', ')}` (-> nil-kill)\n"
               when "Derived-State Staleness"
                 "- *POSSIBLE* #{nav(h[:at])}: `#{h[:derived]}` derived from " \
                 "`#{h[:source]}` (line #{h[:derived_at]}); `#{h[:source]}` " \
                 "reassigned line #{h[:source_reassigned_at]}, `#{h[:derived]}` " \
                 "not recomputed\n"
               when "Inconsistent Rename Clones"
                 "- *POSSIBLE* #{nav(h[:at])} clone of #{nav(h[:ref_at])}: ref var " \
                 "`#{h[:ref_name]}` spelled #{h[:divergent].inspect} here\n"
               when "Flay Similarity (Type-2/3)"
                 "- *POSSIBLE* [#{h[:clone_type]}] mass=#{h[:mass]} node=`#{h[:node]}` " \
                 "#{h[:sites].first(4).map { |s| nav(s) }.join(' ; ')}" \
                 "#{h[:sites].size > 4 ? " (+#{h[:sites].size - 4} more)" : ''}\n"
               end
      end
      out << "- ...(+#{v.size - 25} more)\n" if v.size > 25
    end
  end
end
