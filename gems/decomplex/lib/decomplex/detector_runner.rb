# frozen_string_literal: true

require "json"
require_relative "co_update"
require_relative "flay_similarity"
require_relative "native/co_update"
require_relative "native/predicate_aliases"
require_relative "native/flay_similarity"
require_relative "predicate_alias"

module Decomplex
  # Runs one detector in isolation and emits deterministic machine output.
  #
  # This is intentionally narrower than Report: it gives parser/runtime
  # migration work an apples-to-apples target that excludes report wording,
  # timing, SARIF metadata, and other nondeterministic details.
  module DetectorRunner
    DETECTORS = {
      "co-update" => :co_update,
      "predicate-alias" => :predicate_alias,
      "predicate-aliases" => :predicate_alias,
      "flay-similarity" => :flay_similarity,
      "structural-similarity" => :flay_similarity
    }.freeze
    ENGINES = %w[ruby rust].freeze

    module_function

    def run(detector, files, engine: "ruby", mass: FlaySimilarity::DEFAULT_MASS, fuzzy: FlaySimilarity::DEFAULT_FUZZY)
      canonical = canonical_detector(detector)
      validate_engine!(engine)

      case canonical
      when :co_update
        co_update(files, engine: engine)
      when :predicate_alias
        predicate_alias(files, engine: engine)
      when :flay_similarity
        flay_similarity(files, engine: engine, mass: mass, fuzzy: fuzzy)
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

    private_class_method def self.co_update(files, engine:)
      return Native::CoUpdate.scan(files) if engine.to_s == "rust"

      report = CoUpdate.scan(files)

      {
        "co_written_pairs" => report.co_written_pairs,
        "neglected_updates" => report.neglected_updates
      }
    end

    private_class_method def self.predicate_alias(files, engine:)
      return Native::PredicateAliases.scan(files) if engine.to_s == "rust"

      report = PredicateAlias.scan(files)

      { "alias_clusters" => report.alias_clusters }
    end

    private_class_method def self.flay_similarity(files, engine:, mass:, fuzzy:)
      findings =
        if engine.to_s == "rust"
          Native::FlaySimilarity.scan(files, mass: mass, fuzzy: fuzzy)
        else
          FlaySimilarity.scan(files, mass: mass, fuzzy: fuzzy)
        end

      { "findings" => findings }
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
