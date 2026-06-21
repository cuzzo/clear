# frozen_string_literal: true

require "json"
require_relative "miner"
require_relative "co_update"
require_relative "predicate_alias"
require_relative "semantic_alias"
require_relative "path_condition"
require_relative "sequence_mine"
require_relative "ordered_protocol_mine"
require_relative "derived_state"
require_relative "inconsistent_rename_clone"
require_relative "flay_similarity"
require_relative "decision_pressure"
require_relative "redundant_nil_guard"
require_relative "false_simplicity"
require_relative "oversized_predicate"
require_relative "fat_union"
require_relative "state_mesh"
require_relative "state_branch_density"
require_relative "temporal_ordering_pressure"
require_relative "weighted_inlined_cognitive_complexity"
require_relative "locality_drag"
require_relative "function_lcom"
require_relative "operational_discontinuity"
require_relative "native/report_facts"

module Decomplex
  # Stable boundary between analysis and reporting.
  #
  # ReportFacts contains the report-ready detector outputs before
  # Convergence, RootCause, Markdown, or SARIF post-processing runs.
  module ReportFacts
    FORMAT = "decomplex.report-facts.v1"
    ENUM_KEYS = %i[kind mode confidence clone_type].freeze

    module_function

    def from_files(files, engine: "ruby", jobs: nil)
      paths = Array(files).map(&:to_s)
      case engine.to_s
      when "ruby"
        {
          "format" => FORMAT,
          "files" => paths,
          "detectors" => json_safe(ruby_detector_facts(paths))
        }
      when "rust"
        Native::ReportFacts.collect(paths, jobs: jobs)
      else
        raise ArgumentError, "unsupported decomplex facts engine: #{engine}"
      end
    end

    def to_json(facts, pretty: true)
      pretty ? JSON.pretty_generate(json_safe(facts)) : JSON.generate(json_safe(facts))
    end

    def normalize(payload)
      raw = payload.is_a?(String) ? JSON.parse(payload) : payload
      deep_hydrate(raw)
    end

    def json_safe(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          out[key] = json_safe(value.fetch(original))
        end
      when Array
        value.map { |child| json_safe(child) }
      when Symbol
        value.to_s
      else
        value
      end
    end

    def state_heatmap_findings_from_graph(graph, limit_sites: 12)
      fields = graph.fetch("fields", {})
      fields.map do |field, row|
        writers = Array(row["writers"])
        readers = Array(row["readers"])
        re_derivations = Array(row["re_derivations"])
        metrics = row.fetch("metrics", {})
        sites = site_locations(writers + readers) +
                re_derivations.map { |site| site_location(site) }
        spans = (writers + readers).each_with_object({}) do |site, out|
          out[site_location(site)] ||= site["span"]
        end

        {
          "at" => sites.first,
          "field" => field,
          "writes" => metrics.fetch("writes", 0),
          "reads" => metrics.fetch("reads", 0),
          "re_derivations" => metrics.fetch("re_derivations", 0),
          "scatter" => metrics.fetch("scatter", 0),
          "write_scatter" => metrics.fetch("write_scatter", 0),
          "read_scatter" => metrics.fetch("read_scatter", 0),
          "receiver_types" => metrics.fetch("receiver_types", 0),
          "messiness" => row.fetch("messiness", 0),
          "pressure" => metrics.fetch("pressure", 0),
          "top_writers" => site_locations(writers.first(4)),
          "top_readers" => site_locations(readers.first(4)),
          "sites" => sites.first(limit_sites),
          "spans" => spans
        }
      end
    end

    def ruby_detector_facts(files)
      m = Miner.scan(files)
      cu = CoUpdate.scan(files)
      pa = PredicateAlias.scan(files)
      sa = SemanticAlias.scan(files)
      pc = PathCondition.scan(files)
      sm = SequenceMine.scan(files)
      icf = ImplicitControlFlow.scan(files)
      state_mesh = StateMesh.scan(files, min_writes: 1)
      state_mesh.run
      operational_discontinuity = OperationalDiscontinuity.scan(
        files,
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

      {
        miner: {
          missing_abstractions: m.missing_abstractions,
          neglected_conditions: m.neglected_conditions
        },
        co_update: {
          co_written_pairs: cu.co_written_pairs,
          neglected_updates: cu.neglected_updates
        },
        predicate_alias: { alias_clusters: pa.alias_clusters },
        semantic_alias: {
          alias_clusters: sa.alias_clusters,
          reification_misses: sa.reification_misses
        },
        path_condition: {
          neglected: pc.neglected,
          scattered: pc.scattered
        },
        sequence_mine: { broken_protocol: sm.broken_protocol },
        implicit_control_flow: {
          ordered_protocols: icf.ordered_protocols(
            min_support: Integer(ENV.fetch("DECOMPLEX_ICF_MIN_SUPPORT", "1"))
          )
        },
        derived_state: DerivedState.scan(files),
        inconsistent_rename_clone: InconsistentRenameClone.scan(files),
        flay_similarity: FlaySimilarity.scan(
          files,
          mass: Integer(ENV.fetch(
            "DECOMPLEX_SIMILARITY_MASS",
            ENV.fetch("DECOMPLEX_FLAY_MASS", FlaySimilarity::DEFAULT_MASS)
          )),
          fuzzy: Integer(ENV.fetch(
            "DECOMPLEX_SIMILARITY_FUZZY",
            ENV.fetch("DECOMPLEX_FLAY_FUZZY", FlaySimilarity::DEFAULT_FUZZY)
          ))
        ),
        decision_pressure: DecisionPressure.scan(files).ranked,
        redundant_nil_guard: RedundantNilGuard.scan(files),
        false_simplicity: FalseSimplicity.scan(files).findings,
        oversized_predicate: OversizedPredicate.scan(files).findings,
        fat_union: { fat_unions: FatUnion.scan(files).fat_unions },
        state_heatmap: state_mesh.findings,
        state_branch_density: StateBranchDensity.scan(files).findings,
        temporal_ordering_pressure: TemporalOrderingPressure.scan(files),
        weighted_inlined_complexity: WeightedInlinedCognitiveComplexity.scan(
          files,
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
        ),
        locality_drag: LocalityDrag.scan(
          files,
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
        ),
        function_lcom: FunctionLCOM.scan(
          files,
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
        ),
        operational_discontinuity: operational_discontinuity
      }
    end

    def deep_hydrate(value, key: nil)
      case value
      when Hash
        value.each_with_object({}) do |(child_key, child), out|
          hydrated_key = key == :spans ? child_key.to_s : child_key.to_s.to_sym
          out[hydrated_key] = deep_hydrate(child, key: hydrated_key)
        end
      when Array
        value.map { |child| deep_hydrate(child, key: key) }
      when String
        ENUM_KEYS.include?(key) ? value.to_sym : value
      else
        value
      end
    end

    def site_locations(sites)
      Array(sites).map { |site| site_location(site) }
    end

    def site_location(site)
      "#{site.fetch('file')}:#{site.fetch('defn')}:#{site.fetch('line')}"
    end
  end
end
