# frozen_string_literal: true

require "json"
require_relative "co_update"
require_relative "flay_similarity"
require_relative "native/co_update"
require_relative "native/decision_pressure"
require_relative "native/predicate_aliases"
require_relative "native/flay_similarity"
require_relative "native/miner"
require_relative "native/semantic_aliases"
require_relative "miner"
require_relative "decision_pressure"
require_relative "predicate_alias"
require_relative "semantic_alias"
require_relative "state_mesh"
require_relative "state_branch_density"
require_relative "temporal_ordering_pressure"
require_relative "redundant_nil_guard"
require_relative "inconsistent_rename_clone"
require_relative "derived_state"
require_relative "ordered_protocol_mine"
require_relative "weighted_inlined_cognitive_complexity"
require_relative "locality_drag"
require_relative "operational_discontinuity"
require_relative "oversized_predicate"
require_relative "path_condition"
require_relative "sequence_mine"
require_relative "function_lcom"
require_relative "false_simplicity"
require_relative "fat_union"

module Decomplex
  # Runs one detector in isolation and emits deterministic machine output.
  #
  # This is intentionally narrower than Report: it gives parser/runtime
  # migration work an apples-to-apples target that excludes report wording,
  # timing, SARIF metadata, and other nondeterministic details.
  module DetectorRunner
    DETECTORS = {
      "co-update" => :co_update,
      "decision-pressure" => :decision_pressure,
      "predicate-alias" => :predicate_alias,
      "predicate-aliases" => :predicate_alias,
      "miner" => :miner,
      "decision-miner" => :miner,
      "missing-abstractions" => :miner,
      "neglected-conditions" => :miner,
      "semantic-alias" => :semantic_alias,
      "semantic-aliases" => :semantic_alias,
      "semantic-predicate-aliases" => :semantic_alias,
      "reification-misses" => :semantic_alias,
      "flay-similarity" => :flay_similarity,
      "structural-similarity" => :flay_similarity,
      "temporal-ordering-pressure" => :temporal_ordering_pressure,
      "state-branch-density" => :state_branch_density,
      "redundant-nil-guard" => :redundant_nil_guard,
      "state-mesh" => :state_mesh,
      "state-heatmap" => :state_mesh,
      "inconsistent-rename-clone" => :inconsistent_rename_clone,
      "derived-state" => :derived_state,
      "implicit-control-flow" => :implicit_control_flow,
      "weighted-inlined-complexity" => :weighted_inlined_complexity,
      "locality-drag" => :locality_drag,
      "operational-discontinuity" => :operational_discontinuity,
      "oversized-predicate" => :oversized_predicate,
      "path-condition" => :path_condition,
      "broken-protocol" => :sequence_mine,
      "sequence-mine" => :sequence_mine,
      "function-lcom" => :function_lcom,
      "false-simplicity" => :false_simplicity,
      "fat-union" => :fat_union
    }.freeze
    ENGINES = %w[ruby rust].freeze

    module_function

    def run(detector, files, engine: "ruby", mass: FlaySimilarity::DEFAULT_MASS, fuzzy: FlaySimilarity::DEFAULT_FUZZY, jobs: nil)
      canonical = canonical_detector(detector)
      validate_engine!(engine)

      case canonical
      when :co_update
        co_update(files, engine: engine, jobs: jobs)
      when :decision_pressure
        decision_pressure(files, engine: engine, jobs: jobs)
      when :predicate_alias
        predicate_alias(files, engine: engine, jobs: jobs)
      when :miner
        miner(files, engine: engine, jobs: jobs)
      when :semantic_alias
        semantic_alias(files, engine: engine, jobs: jobs)
      when :flay_similarity
        flay_similarity(files, engine: engine, mass: mass, fuzzy: fuzzy, jobs: jobs)
      when :temporal_ordering_pressure
        temporal_ordering_pressure(files, engine: engine, jobs: jobs)
      when :state_branch_density
        state_branch_density(files, engine: engine, jobs: jobs)
      when :redundant_nil_guard
        redundant_nil_guard(files, engine: engine, jobs: jobs)
      when :state_mesh
        state_mesh(files, engine: engine, jobs: jobs)
      when :inconsistent_rename_clone
        inconsistent_rename_clone(files, engine: engine, jobs: jobs)
      when :derived_state
        derived_state(files, engine: engine, jobs: jobs)
      when :implicit_control_flow
        implicit_control_flow(files, engine: engine, jobs: jobs)
      when :weighted_inlined_complexity
        weighted_inlined_complexity(files, engine: engine, jobs: jobs)
      when :locality_drag
        locality_drag(files, engine: engine, jobs: jobs)
      when :operational_discontinuity
        operational_discontinuity(files, engine: engine, jobs: jobs)
      when :oversized_predicate
        oversized_predicate(files, engine: engine, jobs: jobs)
      when :path_condition
        path_condition(files, engine: engine, jobs: jobs)
      when :sequence_mine
        sequence_mine(files, engine: engine, jobs: jobs)
      when :function_lcom
        function_lcom(files, engine: engine, jobs: jobs)
      when :false_simplicity
        false_simplicity(files, engine: engine, jobs: jobs)
      when :fat_union
        fat_union(files, engine: engine, jobs: jobs)
      else
        raise ArgumentError, "unsupported decomplex detector: #{detector}"
      end
    end

    def canonical_json(detector, files, engine: "ruby", **options)
      JSON.generate(canonicalize(run(detector, files, engine: engine, **options))) << "\n"
    end

    def compare(detector, files, **options)
      ruby_json = canonical_json(detector, files, engine: "ruby", **options)
      rust_json = canonical_json(detector, files, engine: "rust", **options)
      [ruby_json == rust_json, ruby_json, rust_json]
    end

    def detector_names
      DETECTORS.keys
    end

    private_class_method def self.canonical_detector(detector)
      DETECTORS.fetch(detector.to_s) do
        raise ArgumentError, "unsupported decomplex detector: #{detector}"
      end
    end

    private_class_method def self.validate_engine!(engine)
      return if ENGINES.include?(engine.to_s)

      raise ArgumentError, "unsupported decomplex detector engine: #{engine}"
    end

    private_class_method def self.co_update(files, engine:, jobs:)
      return Native::CoUpdate.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = CoUpdate.scan(files)

      {
        "co_written_pairs" => report.co_written_pairs,
        "neglected_updates" => report.neglected_updates
      }
    end

    private_class_method def self.decision_pressure(files, engine:, jobs:)
      return Native::DecisionPressure.scan(files, jobs: jobs) if engine.to_s == "rust"

      DecisionPressure.scan(files).ranked
    end

    private_class_method def self.predicate_alias(files, engine:, jobs:)
      return Native::PredicateAliases.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = PredicateAlias.scan(files)

      { "alias_clusters" => report.alias_clusters }
    end

    private_class_method def self.miner(files, engine:, jobs:)
      return Native::Miner.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = Miner.scan(files)

      {
        "missing_abstractions" => report.missing_abstractions,
        "neglected_conditions" => report.neglected_conditions
      }
    end

    private_class_method def self.semantic_alias(files, engine:, jobs:)
      return Native::SemanticAliases.scan(files, jobs: jobs) if engine.to_s == "rust"

      report = SemanticAlias.scan(files)

      {
        "alias_clusters" => report.alias_clusters,
        "reification_misses" => report.reification_misses
      }
    end

    private_class_method def self.flay_similarity(files, engine:, mass:, fuzzy:, jobs:)
      findings =
        if engine.to_s == "rust"
          Native::FlaySimilarity.scan(files, mass: mass, fuzzy: fuzzy, jobs: jobs)
        else
          FlaySimilarity.scan(files, mass: mass, fuzzy: fuzzy)
        end

      { "findings" => findings }
    end

    private_class_method def self.temporal_ordering_pressure(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/temporal_ordering_pressure"
        return Native::TemporalOrderingPressure.scan(files, jobs: jobs)
      end

      TemporalOrderingPressure.scan(files)
    end

    private_class_method def self.state_branch_density(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/state_branch_density"
        return Native::StateBranchDensity.scan(files, jobs: jobs)
      end

      StateBranchDensity.scan(files).findings
    end

    private_class_method def self.redundant_nil_guard(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/redundant_nil_guard"
        return Native::RedundantNilGuard.scan(files, jobs: jobs)
      end

      RedundantNilGuard.scan(files)
    end

    private_class_method def self.state_mesh(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/state_mesh"
        return Native::StateMesh.scan(files, jobs: jobs)
      end

      StateMesh.scan(files).tap(&:run).to_json_graph
    end

    private_class_method def self.inconsistent_rename_clone(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/inconsistent_rename_clone"
        return Native::InconsistentRenameClone.scan(files, jobs: jobs)
      end

      InconsistentRenameClone.scan(files)
    end

    private_class_method def self.derived_state(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/derived_state"
        return Native::DerivedState.scan(files, jobs: jobs)
      end

      DerivedState.scan(files)
    end

    private_class_method def self.implicit_control_flow(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/implicit_control_flow"
        return Native::ImplicitControlFlow.scan(files, jobs: jobs)
      end

      report = ImplicitControlFlow.scan(files)
      {
        "ordered_protocols" => report.ordered_protocols,
        "order_drift" => report.drift
      }
    end

    private_class_method def self.weighted_inlined_complexity(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/weighted_inlined_complexity"
        return Native::WeightedInlinedComplexity.scan(files, jobs: jobs)
      end

      WeightedInlinedCognitiveComplexity.scan(files)
    end

    private_class_method def self.locality_drag(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/locality_drag"
        return Native::LocalityDrag.scan(files, jobs: jobs)
      end

      LocalityDrag.scan(files)
    end

    private_class_method def self.operational_discontinuity(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/operational_discontinuity"
        return Native::OperationalDiscontinuity.scan(files, jobs: jobs)
      end

      OperationalDiscontinuity.scan(files)
    end

    private_class_method def self.oversized_predicate(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/oversized_predicate"
        return Native::OversizedPredicate.scan(files, jobs: jobs)
      end

      { "findings" => OversizedPredicate.scan(files).findings }
    end

    private_class_method def self.path_condition(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/path_condition"
        return Native::PathCondition.scan(files, jobs: jobs)
      end

      report = PathCondition.scan(files)
      { "neglected" => report.neglected }
    end

    private_class_method def self.sequence_mine(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/sequence_mine"
        return Native::SequenceMine.scan(files, jobs: jobs)
      end

      report = SequenceMine.scan(files)
      { "broken" => report.broken_protocol }
    end

    private_class_method def self.function_lcom(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/function_lcom"
        return Native::FunctionLcom.scan(files, jobs: jobs)
      end

      FunctionLCOM.scan(files)
    end

    private_class_method def self.false_simplicity(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/false_simplicity"
        return Native::FalseSimplicity.scan(files, jobs: jobs)
      end

      FalseSimplicity.scan(files).findings
    end

    private_class_method def self.fat_union(files, engine:, jobs:)
      if engine.to_s == "rust"
        require_relative "native/fat_union"
        return Native::FatUnion.scan(files, jobs: jobs)
      end

      { "fat_unions" => FatUnion.scan(files).fat_unions }
    end

    private_class_method def self.canonicalize(value)
      case value
      when Hash
        value.keys.map(&:to_s).sort.each_with_object({}) do |key, out|
          original = value.key?(key) ? key : value.keys.find { |candidate| candidate.to_s == key }
          out[key] = canonicalize(value.fetch(original))
        end
      when Array
        value.map { |item| canonicalize(item) }
      when Symbol
        value.to_s
      else
        value
      end
    end
  end
end
