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
      icf     = ImplicitControlFlow.scan(@files)
      @implicit_control_flow = icf.ordered_protocols(
        min_support: Integer(ENV.fetch("DECOMPLEX_ICF_MIN_SUPPORT", "1"))
      )
      @derived = DerivedState.scan(@files)
      @rename_clones = InconsistentRenameClone.scan(@files)
      @similarity = FlaySimilarity.scan(
        @files,
        mass: Integer(ENV.fetch("DECOMPLEX_SIMILARITY_MASS",
                                ENV.fetch("DECOMPLEX_FLAY_MASS", FlaySimilarity::DEFAULT_MASS))),
        fuzzy: Integer(ENV.fetch("DECOMPLEX_SIMILARITY_FUZZY",
                                 ENV.fetch("DECOMPLEX_FLAY_FUZZY", FlaySimilarity::DEFAULT_FUZZY)))
      )
      @pressure = DecisionPressure.scan(@files).ranked
      @redundant_nil = RedundantNilGuard.scan(@files)
      @fsimple = FalseSimplicity.scan(@files).findings
      @oversized_predicates = OversizedPredicate.scan(@files).findings
      @fatu = FatUnion.scan(@files).fat_unions
      state_mesh = StateMesh.scan(@files, min_writes: 1)
      state_mesh.run
      @state_heat = state_mesh.findings
      @state_branch = StateBranchDensity.scan(@files).findings
      @temporal_ordering = TemporalOrderingPressure.scan(@files)
      @weighted_inlined_complexity = WeightedInlinedCognitiveComplexity.scan(
        @files,
        min_score: Float(ENV.fetch(
          "DECOMPLEX_WICC_MIN_SCORE",
          WeightedInlinedCognitiveComplexity::DEFAULT_MIN_SCORE
        )),
        min_hidden: Float(ENV.fetch(
          "DECOMPLEX_WICC_MIN_HIDDEN",
          WeightedInlinedCognitiveComplexity::DEFAULT_MIN_HIDDEN
        )),
        max_depth: Integer(ENV.fetch(
          "DECOMPLEX_WICC_MAX_DEPTH",
          WeightedInlinedCognitiveComplexity::DEFAULT_MAX_DEPTH
        ))
      )
      @locality_drag = LocalityDrag.scan(
        @files,
        min_unrelated_statements: Integer(ENV.fetch(
          "DECOMPLEX_LOCALITY_DRAG_MIN_UNRELATED_STATEMENTS",
          LocalityDrag::DEFAULT_MIN_UNRELATED_STATEMENTS
        )),
        min_gap_lines: Integer(ENV.fetch(
          "DECOMPLEX_LOCALITY_DRAG_MIN_GAP_LINES",
          LocalityDrag::DEFAULT_MIN_GAP_LINES
        )),
        min_local_complexity: Float(ENV.fetch(
          "DECOMPLEX_LOCALITY_DRAG_MIN_LOCAL_COMPLEXITY",
          LocalityDrag::DEFAULT_MIN_LOCAL_COMPLEXITY
        )),
        min_score: Integer(ENV.fetch(
          "DECOMPLEX_LOCALITY_DRAG_MIN_SCORE",
          LocalityDrag::DEFAULT_MIN_SCORE
        )),
        max_findings_per_method: Integer(ENV.fetch(
          "DECOMPLEX_LOCALITY_DRAG_MAX_FINDINGS_PER_METHOD",
          LocalityDrag::DEFAULT_MAX_FINDINGS_PER_METHOD
        ))
      )
      @function_lcom = FunctionLCOM.scan(
        @files,
        min_components: Integer(ENV.fetch(
          "DECOMPLEX_FUNCTION_LCOM_MIN_COMPONENTS",
          FunctionLCOM::DEFAULT_MIN_COMPONENTS
        )),
        min_locals: Integer(ENV.fetch(
          "DECOMPLEX_FUNCTION_LCOM_MIN_LOCALS",
          FunctionLCOM::DEFAULT_MIN_LOCALS
        )),
        min_statements: Integer(ENV.fetch(
          "DECOMPLEX_FUNCTION_LCOM_MIN_STATEMENTS",
          FunctionLCOM::DEFAULT_MIN_STATEMENTS
        )),
        min_score: Integer(ENV.fetch(
          "DECOMPLEX_FUNCTION_LCOM_MIN_SCORE",
          FunctionLCOM::DEFAULT_MIN_SCORE
        ))
      )
      operational_discontinuity = OperationalDiscontinuity.scan(
        @files,
        min_dead: Integer(ENV.fetch(
          "DECOMPLEX_OPERATIONAL_DISCONTINUITY_MIN_DEAD",
          OperationalDiscontinuity::DEFAULT_MIN_DEAD
        )),
        min_new: Integer(ENV.fetch(
          "DECOMPLEX_OPERATIONAL_DISCONTINUITY_MIN_NEW",
          OperationalDiscontinuity::DEFAULT_MIN_NEW
        )),
        max_continuing: Integer(ENV.fetch(
          "DECOMPLEX_OPERATIONAL_DISCONTINUITY_MAX_CONTINUING",
          OperationalDiscontinuity::DEFAULT_MAX_CONTINUING
        )),
        min_score: Integer(ENV.fetch(
          "DECOMPLEX_OPERATIONAL_DISCONTINUITY_MIN_SCORE",
          OperationalDiscontinuity::DEFAULT_MIN_SCORE
        ))
      )
      @operational_discontinuity_high_confidence, @operational_discontinuity =
        operational_discontinuity.partition { |finding| OperationalDiscontinuity.high_confidence?(finding) }
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
      ["Redundant Nil Guards",   :@redundant_nil, 1, "nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type"],
      ["State Heatmap",          :@state_heat, 1, "state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner"],
      ["State-Based Branch Density", :@state_branch, 1, "branch decisions over mutable/object state -- state + control-flow pressure"],
      ["Temporal Ordering Pressure", :@temporal_ordering, 1, "public mutable lifecycle surfaces that create implicit state-machine ordering"],
      ["Missing Abstractions",   :@miss,   1, "guard tuple recomputed across >=2 decision units"],
      ["Reification Misses",     :@reif,   1, "an existing predicate reinvented inline -- invariant #16"],
      ["Semantic Predicate Aliases", :@salias, 1, "one decision, multiple names (receiver/polarity folded)"],
      ["Exact Predicate Aliases", :@palias, 1, "identical one-line predicate body under >=2 names"],
      ["Inconsistent Rename Clones", :@rename_clones, 2, "pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug"],
      ["Structural Similarity (Type-2/3)", :@similarity, 2, "Tree-sitter structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict"],
      ["Neglected Updates",      :@negu,   2, "co-written state, one write missing -- *POSSIBLE* redundant-state desync"],
      ["Derived-State Staleness", :@derived, 2, "b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug"],
      ["Neglected Conditions",   :@negc,   2, "dispatch/conjunction minus one element -- *POSSIBLE* bug"],
      ["Neglected Path Conditions", :@pcneg, 3, "nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)"],
      ["Oversized Predicates", :@oversized_predicates, 3, "predicate with >3 condition atoms -- use an existing helper or extract a named predicate"],
      ["Broken Protocols",       :@broken, 3, "co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)"],
      ["Implicit Control Flow", :@implicit_control_flow, 2, "state-dependent internal call order exists -- hidden lifecycle/control-flow pressure"],
      ["Weighted Inlined Cognitive Complexity", :@weighted_inlined_complexity, 2, "same-owner helper chain hides cognitive load behind a low-looking orchestration method"],
      ["Locality Drag", :@locality_drag, 2, "local initialized far before first use while unrelated work runs -- move setup closer or extract a private phase"],
      ["Operational Discontinuity (High Confidence)", :@operational_discontinuity_high_confidence, 2, "strong blank/comment phase boundary where local variable lifetimes reset -- likely implicit sub-function boundary"],
      ["Function LCOM", :@function_lcom, 3, "independent local data-flow components inside one method -- *POSSIBLE* mixed concerns"],
      ["Operational Discontinuity", :@operational_discontinuity, 3, "blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary"],
      ["False Simplicity",       :@fsimple, 3, "looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/reflection/reopen -- *POSSIBLE* (noisy)"],
      ["Fat Unions",             :@fatu,   3, "case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*"]
    ].freeze

    CONVERGENCE_EXCLUDED_SECTIONS = ["State Heatmap"].freeze

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
      data = SECTIONS.reject { |t, *_| CONVERGENCE_EXCLUDED_SECTIONS.include?(t) }
                     .map { |t, iv, tier, _| [t, tier, instance_variable_get(iv)] }
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
             "no CFG / no points-to; Type-2/3 similarity uses " \
             "Tree-sitter structural fingerprints (see docs/agents/design.md)\n"
      out
    end

    def to_sarif_hash(include_snapshot: true, include_finding_payload: true, max_results: nil)
      snapshot = Delta.snapshot(sections_data, root_clusters)
      results = sarif_results(include_finding_payload: include_finding_payload)
      results = ranked_sarif_results(results).first(max_results) if max_results
      properties = {
        "format" => "decomplex.report.sarif.v1",
        "files" => @files
      }
      properties["decomplex.snapshot"] = snapshot if include_snapshot
      Decomplex::Sarif.document(
        tool_name: "Decomplex",
        information_uri: "https://github.com/cuzzo/clear",
        rules: sarif_rules,
        results: results,
        properties: properties
      )
    end

    def to_sarif(**kwargs)
      JSON.pretty_generate(to_sarif_hash(**kwargs))
    end

    def to_json(*_args)
      to_sarif
    end

    private

    def sarif_rules
      sarif_sections_data(include_findings: false).map do |title, tier, _findings, desc|
        Decomplex::Sarif.rule(
          id: sarif_rule_id(title),
          name: title,
          short_description: desc,
          default_level: tier.to_i <= 1 ? "warning" : "note",
          properties: { "tier" => tier }
        )
      end
    end

    def ranked_sarif_results(results)
      Array(results).sort_by do |result|
        location = result.dig("locations", 0, "physicalLocation")
        [
          result.dig("properties", "tier").to_i,
          result.fetch("ruleId", ""),
          result.dig("message", "text").to_s,
          location&.dig("artifactLocation", "uri").to_s,
          location&.dig("region", "startLine").to_i
        ]
      end
    end

    def sarif_results(include_finding_payload: true)
      sarif_sections_data.flat_map do |title, tier, findings, _desc|
        Array(findings).flat_map do |finding|
          sarif_locations_for_finding(finding).map do |location|
            properties = {
              "detector" => title,
              "tier" => tier,
              "method" => location[:method]
            }
            if include_finding_payload
              properties["decomplex_finding"] = Delta.json_safe_finding(title, finding)
            end
            Decomplex::Sarif.result(
              rule_id: sarif_rule_id(title),
              level: tier.to_i <= 1 ? "warning" : "note",
              message: sarif_message(title, finding, location),
              path: location[:path],
              line: location[:line],
              start_column: location[:start_column],
              end_line: location[:end_line],
              end_column: location[:end_column],
              partial_fingerprints: {
                "decomplexFinding" => Delta.fingerprint(title, finding)
              },
              properties: properties
            )
          end
        end
      end
    end

    def sarif_rule_id(title)
      "decomplex.#{Decomplex::Sarif.slug(title)}"
    end

    def sarif_message(title, finding, location)
      detail = sarif_message_detail(title, finding)
      return "#{title}: #{detail}" unless detail.to_s.empty?

      subject = location[:method] || finding[:method] || finding[:name] ||
                finding[:field] || finding[:contract] || finding[:owner] ||
                finding[:token] || finding[:kind]
      [title, subject].compact.join(": ")
    end

    def sarif_message_detail(title, finding)
      case title
      when "Decision Pressure"
        "`#{finding[:contract]}` creates #{finding[:decisions]} eliminable guard decision(s) across " \
          "#{finding[:methods]} method(s)"
      when "Redundant Nil Guards"
        "`#{finding[:local]}` is nil-guarded by `#{finding[:guard]}` after proof `#{finding[:proof]}`"
      when "State Heatmap"
        writers = Array(finding[:top_writers]).first(3).join(" | ")
        readers = Array(finding[:top_readers]).first(3).join(" | ")
        "state `#{finding[:field]}` has pressure=#{finding[:pressure]}, messiness=#{finding[:messiness]} " \
          "(writes=#{finding[:writes]}, reads=#{finding[:reads]}, re-derived=#{finding[:re_derivations]}, " \
          "scatter=#{finding[:scatter]}); writers #{writers}; readers #{readers}"
      when "Missing Abstractions"
        "guard tuple `#{Array(finding[:members]).join(' | ')}` repeats in #{finding[:support]} site(s) " \
          "with scatter=#{finding[:scatter]}"
      when "State-Based Branch Density"
        refs = Array(finding[:state_refs]).first(8).join(" | ")
        "#{finding[:decisions]} state-based branch decision(s) over `#{refs}`; " \
          "example predicate `#{finding[:predicate]}`"
      when "Temporal Ordering Pressure"
        "`#{finding[:owner]}` exposes mutable lifecycle pressure score=#{finding[:score]} " \
          "(public=#{finding[:public_methods]}, state_methods=#{finding[:state_methods]}, " \
          "writers=#{finding[:writers]})"
      when "Neglected Conditions", "Neglected Path Conditions"
        "missing condition `#{finding[:missing]}` from `#{Array(finding[:pattern] || finding[:guards]).join(' | ')}` " \
          "(support=#{finding[:support]})"
      when "Oversized Predicates"
        "#{finding[:count]} condition atoms in predicate `#{finding[:predicate]}`"
      when "Neglected Updates"
        "writes `.#{finding[:has]}` but not co-written `.#{finding[:missing]}` on receiver `#{finding[:recv]}` " \
          "(support=#{finding[:support]})"
      when "Semantic Predicate Aliases", "Exact Predicate Aliases"
        "predicate aliases `#{Array(finding[:names]).join(' = ')}` for `#{finding[:canon] || finding[:body]}`"
      when "Reification Misses"
        "predicate `#{finding[:predicate]}` is reinvented inline as `#{finding[:raw]}`"
      when "Broken Protocols"
        "does `#{finding[:has]}` without co-called `#{finding[:missing]}` " \
          "(support=#{finding[:support]}, confidence=#{finding[:confidence]})"
      when "Implicit Control Flow"
        sarif_implicit_control_flow_detail(finding)
      when "Weighted Inlined Cognitive Complexity"
        "inlined=#{finding[:inlined]} (local=#{finding[:local]}, hidden=#{finding[:hidden]}, " \
          "depth=#{finding[:depth]}); chain `#{Array(finding[:call_chain]).join(' -> ')}`"
      when "Locality Drag"
        "`#{finding[:variable]}` is initialized at line #{finding[:defined_at]} but first used at line " \
          "#{finding[:used_at]} after #{finding[:unrelated_statements]} unrelated statement(s)"
      when "Function LCOM"
        mode = finding[:mode] == :late_join ? "late_join" : "disjoint"
        "#{mode} local data-flow: score=#{finding[:score]}, components=#{finding[:components]}, " \
          "locals=#{finding[:locals]}, statements=#{finding[:statements]}"
      when "Operational Discontinuity", "Operational Discontinuity (High Confidence)"
        "score=#{finding[:score]}, reset_boundaries=#{finding[:resets]}, dead=#{finding[:dead_total]}, " \
          "new=#{finding[:new_total]}, confidence=#{finding[:confidence] || :review}"
      when "False Simplicity"
        "[#{finding[:kind]}] `#{finding[:detail]}` support=#{finding[:support]}, scatter=#{finding[:scatter]}"
      when "Fat Unions"
        "union `#{Array(finding[:variant_set]).join(' | ')}` has #{Array(finding[:common]).size} common and " \
          "#{Array(finding[:variant]).size} variant member(s), scatter=#{finding[:scatter]}"
      when "Derived-State Staleness"
        "`#{finding[:derived]}` derived from `#{finding[:source]}` at line #{finding[:derived_at]}; " \
          "`#{finding[:source]}` reassigned at line #{finding[:source_reassigned_at]} but " \
          "`#{finding[:derived]}` is not recomputed"
      when "Inconsistent Rename Clones"
        "clone of #{finding[:ref_at]}: reference variable `#{finding[:ref_name]}` diverges as " \
          "#{Array(finding[:divergent]).inspect}"
      when "Structural Similarity (Type-2/3)"
        "[#{finding[:clone_type]}] mass=#{finding[:mass]} node=`#{finding[:node]}` across " \
          "#{Array(finding[:sites]).size} site(s)"
      else
        nil
      end
    end

    def sarif_implicit_control_flow_detail(finding)
      protocol = Array(finding[:protocol]).join(" -> ")
      dependency = Array(finding[:dependency]).join("|")
      states = Array(finding[:states]).join(" | ")
      if finding[:kind] == :order_drift
        observed = Array(finding[:observed]).join(" -> ")
        return "[order_drift] observed `#{observed}` against protocol `#{protocol}` " \
               "(#{dependency} state=`#{states}`)"
      end

      "[protocol_pressure] protocol `#{protocol}` (#{dependency} state=`#{states}`), support=#{finding[:support]}"
    end

    def sarif_locations_for_finding(finding)
      spans = finding[:spans]
      if spans.is_a?(Hash) && !spans.empty?
        return spans.filter_map do |loc, span|
          parsed = parse_sarif_loc(loc)
          next unless parsed[:path]

          span = Array(span)
          parsed.merge(
            line: span[0].to_i.positive? ? span[0].to_i : parsed[:line],
            start_column: zero_based_column_to_sarif(span[1]),
            end_line: span[2].to_i.positive? ? span[2].to_i : nil,
            end_column: zero_based_column_to_sarif(span[3])
          )
        end
      end

      locs = []
      locs << finding[:at]
      locs.concat(Array(finding[:sites]))
      locs << finding[:ref_at]
      locs.compact!
      locs.uniq!
      locs.map { |loc| parse_sarif_loc(loc) }.select { |loc| loc[:path] }
    end

    def parse_sarif_loc(loc)
      parts = loc.to_s.split(":")
      line = nil
      line = parts.pop.to_i if parts.last.to_s.match?(/\A\d+\z/)
      method = parts.pop if parts.size >= 2
      path = parts.join(":")
      {
        path: path.empty? ? nil : path,
        method: method,
        line: line&.positive? ? line : 1
      }
    end

    def sarif_sections_data(include_findings: true)
      SECTIONS.map do |title, ivar, tier, desc|
        findings = include_findings ? instance_variable_get(ivar) : nil
        [title, tier, findings, desc]
      end
    end

    def zero_based_column_to_sarif(value)
      return nil if value.nil?

      value.to_i + 1
    end

    def render_state_heatmap_item(item)
      out = "- `#{item[:field]}` -- messiness **#{item[:messiness]}** " \
            "(writes=#{item[:writes]}, reads=#{item[:reads]}, re-derived=#{item[:re_derivations]}, " \
            "scatter=#{item[:scatter]}, receiver patterns=#{item[:receiver_types]})\n"
      writers = item[:top_writers].map { |site| nav(site) }
      readers = item[:top_readers].map { |site| nav(site) }
      out << "  - writers: #{writers.join(' ; ')}\n" unless writers.empty?
      out << "  - readers: #{readers.join(' ; ')}\n" unless readers.empty?
      out
    end

    def render_implicit_control_flow_item(item)
      if item[:kind] == :order_drift
        return "- *POSSIBLE* [order_drift] conf=#{item[:confidence]} support=#{item[:support]} " \
               "#{nav(item[:at])} observed `#{item[:observed].join(' -> ')}` " \
               "against protocol `#{item[:protocol].join(' -> ')}` " \
               "(#{item[:dependency].join('|')} state=`#{item[:states].join(' | ')}`)\n"
      end

      sites = item[:sites].first(4).map { |site| nav(site) }.join(" ; ")
      more = item[:sites].size > 4 ? " (+#{item[:sites].size - 4} more)" : ""
      "- *POSSIBLE* [protocol_pressure] support=#{item[:support]} " \
        "`#{item[:protocol].join(' -> ')}` " \
        "(#{item[:dependency].join('|')} state=`#{item[:states].join(' | ')}`) -- " \
        "#{nav(item[:at])}\n" \
        "  - sites: #{sites}#{more}\n"
    end

    def render_weighted_inlined_complexity_item(item)
      "- *POSSIBLE* #{nav(item[:at])} -- inlined=#{item[:inlined]} " \
        "(local=#{item[:local]}, hidden=#{item[:hidden]}, depth=#{item[:depth]})\n" \
        "  - chain: `#{item[:call_chain].join(' -> ')}`\n" \
        "  - single-caller helpers: `#{item[:single_caller_callees].first(8).join(' | ')}`\n" \
        "  - reason: #{item[:reason]}\n"
    end

    def render_locality_drag_item(item)
      out = "- *POSSIBLE* #{nav(item[:at])} -- `#{item[:variable]}` dormant until line " \
            "#{item[:used_at]} score=#{item[:score]} " \
            "(gap=#{item[:gap_lines]} lines, unrelated=#{item[:unrelated_statements]}, " \
            "boundaries=#{item[:boundary_crossings]}, local=#{item[:local_complexity]})\n" \
            "  - reason: #{item[:reason]}\n"
      out << "  - ignored setup initializers: #{item[:setup_statements]}\n" if item[:setup_statements].positive?
      unless item[:definition_deps].empty?
        out << "  - definition deps: `#{item[:definition_deps].first(6).join(' | ')}`\n"
      end
      unless item[:use_reads].empty?
        out << "  - first-use reads: `#{item[:use_reads].first(8).join(' | ')}`\n"
      end
      item[:boundaries].first(2).each do |boundary|
        out << "  - crosses line #{boundary[:line]} #{boundary[:marker]}\n"
      end
      item[:examples].first(2).each do |example|
        out << "  - unrelated line #{example[:line]}: `#{example[:source]}`\n"
      end
      out
    end

    def render_function_lcom_item(item)
      mode = item[:mode] == :late_join ? "late_join" : "disjoint"
      out = "- *POSSIBLE* [#{mode}] #{nav(item[:at])} -- score=#{item[:score]} " \
            "components=#{item[:components]}, locals=#{item[:locals]}, statements=#{item[:statements]}\n"
      item[:component_vars].first(4).each_with_index do |vars, index|
        lines = item[:component_lines][index]
        out << "  - component #{index + 1}: `#{vars.first(8).join(' | ')}`"
        out << " (lines #{lines.first}-#{lines.last})" if lines && !lines.empty?
        out << "\n"
      end
      out
    end

    def render_operational_discontinuity_item(item)
      reasons = Array(item[:confidence_reasons]).join(", ")
      confidence = item[:confidence] || :review
      out = "- *POSSIBLE* #{nav(item[:at])} -- score=#{item[:score]} " \
            "reset_boundaries=#{item[:resets]}, dead=#{item[:dead_total]}, new=#{item[:new_total]}, " \
            "confidence=#{confidence}"
      out << " (#{reasons})" unless reasons.empty?
      out << "\n"
      item[:reset_points].first(3).each do |reset|
        marker = reset[:text].to_s.empty? ? reset[:kind].to_s : reset[:text]
        out << "  - line #{reset[:line]} #{marker}: dead `#{reset[:dead].first(6).join(' | ')}` " \
               "-> new `#{reset[:new].first(6).join(' | ')}`"
        out << " (continuing `#{reset[:continuing].join(' | ')}`)" unless reset[:continuing].empty?
        out << "\n"
      end
      out
    end

    def render(out, title, v)
      v.first(25).each do |h|
        out << case title
               when "Decision Pressure"
                 "- `#{h[:contract]}` -- ELIMINABLE guard-pressure " \
                 "**#{h[:decisions]}** across #{h[:methods]} method(s) " \
                 "-> tighten contract / nil-kill: DELETE" \
                 "#{h[:essential].positive? ? "  (+#{h[:essential]} essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)" : ''}\n" \
                 "  - #{h[:sites].first(4).map { |s| nav(s) }.join(' ; ')}\n"
               when "Redundant Nil Guards"
                 "- #{nav(h[:at])} -- redundant nil guard on `#{h[:local]}`: " \
                 "`#{h[:guard]}`\n" \
                 "  - proof: #{h[:proof]}\n"
               when "Missing Abstractions"
                 "- **[#{h[:kind]}]** support=#{h[:support]} scatter=#{h[:scatter]} " \
                 "rank=#{h[:rank]}\n  - tuple: `#{h[:members].join(' | ')}`\n" \
                 "  - #{h[:sites].first(6).map { |s| nav(s) }.join(' ; ')}\n"
               when "State Heatmap"
                 render_state_heatmap_item(h)
               when "State-Based Branch Density"
                 "- #{nav(h[:at])} -- **#{h[:decisions]}** state-based branch decision(s), " \
                 "refs=`#{h[:state_refs].first(8).join(' | ')}` score=#{h[:score]}\n" \
                 "  - example predicate: `#{h[:predicate]}`\n"
               when "Temporal Ordering Pressure"
                 "- `#{h[:owner]}` (#{nav(h[:at])}) -- implicit lifecycle score **#{h[:score]}** " \
                 "(public=#{h[:public_methods]}, state methods=#{h[:state_methods]}, writers=#{h[:writers]}, " \
                 "fields=#{h[:state_fields].size}, shared=#{h[:shared_fields].size}, flows=#{h[:orderings]}, states=#{h[:state_space]})\n" \
                 "  - shared fields: `#{h[:shared_fields].first(8).join(' | ')}`\n" \
                 "  - surface: #{h[:sites].first(6).map { |s| nav(s) }.join(' ; ')}\n"
               when "Neglected Conditions", "Neglected Path Conditions"
                 "- *POSSIBLE* (support=#{h[:support]}) #{nav(h[:at])} -- MISSING " \
                 "`#{h[:missing]}` from `#{(h[:pattern] || h[:guards]).join(' | ')}`\n"
               when "Oversized Predicates"
                 "- *POSSIBLE* #{nav(h[:at])} -- #{h[:count]} condition atoms in " \
                 "`#{h[:predicate]}`\n" \
                 "  - atoms: `#{h[:atoms].first(8).join(' | ')}`\n"
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
               when "Implicit Control Flow"
                 render_implicit_control_flow_item(h)
               when "Weighted Inlined Cognitive Complexity"
                 render_weighted_inlined_complexity_item(h)
               when "Locality Drag"
                 render_locality_drag_item(h)
               when "Function LCOM"
                 render_function_lcom_item(h)
               when "Operational Discontinuity", "Operational Discontinuity (High Confidence)"
                 render_operational_discontinuity_item(h)
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
               when "Structural Similarity (Type-2/3)"
                 "- *POSSIBLE* [#{h[:clone_type]}] mass=#{h[:mass]} node=`#{h[:node]}` " \
                 "#{h[:sites].first(4).map { |s| nav(s) }.join(' ; ')}" \
                 "#{h[:sites].size > 4 ? " (+#{h[:sites].size - 4} more)" : ''}\n"
               end
      end
      out << "- ...(+#{v.size - 25} more)\n" if v.size > 25
    end
  end
end
