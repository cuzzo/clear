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
      "state-heatmap" => :state_mesh
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
