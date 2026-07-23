# frozen_string_literal: true

require "json"

# The versioned proof-boundary contract shared by Ruby SARIF producers.
# Rust producers conform through gems/hazard-contract/proof-boundary.v3.schema.json.
module FactMine
  module ProofBoundary
    PROOF_BOUNDARY_PROPERTY = "fact_mine.proof_boundary"
    PROOF_BOUNDARY_SUMMARY_PROPERTY = "fact_mine.proof_boundary_summary"
    SCHEMA = "fact-mine.proof-boundary.v3"
    INPUT_COMPLETENESS = %w[complete partial unknown].freeze
    CLAIM_STATUS = %w[proven observed review].freeze
    COVERAGE_DISCHARGE = %w[satisfiable unsatisfiable not_applicable unknown].freeze

    module_function

    SCOPE_KINDS = %w[reported_span function owner file project closed_build_target local].freeze
    BLOCKER_KINDS = %w[parser_recovery call_resolution missing_evidence open_corpus unsupported_language unknown].freeze

    def build(input_completeness:, claim_status:, coverage_discharge:, authority:, scope:, blockers: [], claim_kind:)
      parse_validate_normalize(
        "schema" => SCHEMA,
        "input_completeness" => input_completeness,
        "claim_status" => claim_status,
        "coverage_discharge" => coverage_discharge,
        "authority" => authority,
        "claim_kind" => claim_kind,
        "scope" => scope,
        "blockers" => blockers
      )
    end

    # Strictly parses an incoming v3 payload, validates its semantic
    # constraints, and emits its one canonical representation. Consumers must
    # call this before preserving a boundary received from another producer.
    def parse_validate_normalize(boundary)
      raise ArgumentError, "proof boundary must be a hash" unless boundary.is_a?(Hash)

      normalized = boundary.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      required = %w[schema input_completeness claim_status coverage_discharge authority claim_kind scope blockers]
      raise ArgumentError, "proof boundary has unknown fields" unless (normalized.keys - required).empty?
      raise ArgumentError, "proof boundary is missing required fields" unless (required - normalized.keys).empty?
      raise ArgumentError, "invalid proof boundary schema" unless normalized["schema"] == SCHEMA

      input = validate!(normalized["input_completeness"], INPUT_COMPLETENESS, "input completeness")
      claim = validate!(normalized["claim_status"], CLAIM_STATUS, "claim status")
      discharge = validate!(normalized["coverage_discharge"], COVERAGE_DISCHARGE, "coverage discharge")
      authority = normalize_authority(normalized["authority"])
      claim_kind = normalized["claim_kind"]
      raise ArgumentError, "claim kind must not be empty" unless claim_kind.is_a?(String) && !claim_kind.empty?
      scope = normalize_scope(normalized["scope"])
      blockers = normalize_blockers(normalized["blockers"])

      raise ArgumentError, "complete input cannot carry proof blockers" if input == "complete" && !blockers.empty?
      if blockers.any? { |blocker| blocker["kind"] == "open_corpus" } && input != "unknown"
        raise ArgumentError, "open corpus blocker requires unknown input completeness"
      end

      {
        "schema" => SCHEMA,
        "input_completeness" => input,
        "claim_status" => claim,
        "coverage_discharge" => discharge,
        "authority" => authority,
        "claim_kind" => claim_kind,
        "scope" => scope,
        "blockers" => blockers
      }
    end

    # Explicit migration adapter for callers that still hold a v2 scalar
    # scope. It deliberately rejects arbitrary strings instead of deriving a
    # claim or blocker policy from display text.
    def legacy_scope(scope)
      kind = validate!(scope, SCOPE_KINDS, "scope kind")
      { "kind" => kind, "closed" => kind == "closed_build_target" }
    end

    def summary(results)
      input = INPUT_COMPLETENESS.to_h { |value| [value, 0] }
      claims = CLAIM_STATUS.to_h { |value| [value, 0] }
      coverage = COVERAGE_DISCHARGE.to_h { |value| [value, 0] }
      boundaries = Array(results).filter_map do |result|
        boundary = result.dig("properties", PROOF_BOUNDARY_PROPERTY)
        parse_validate_normalize(boundary) if boundary.is_a?(Hash)
      rescue ArgumentError
        nil
      end
      boundaries.each do |boundary|
        input[boundary.fetch("input_completeness")] += 1
        claims[boundary.fetch("claim_status")] += 1
        coverage[boundary.fetch("coverage_discharge")] += 1
      end
      {
        "schema" => SCHEMA,
        "result_count" => Array(results).size,
        "results_with_boundary" => boundaries.size,
        "input_completeness" => input,
        "claim_status" => claims,
        "coverage_discharge" => coverage
      }
    end

    def validate!(value, allowed, label)
      normalized = value.to_s
      return normalized if allowed.include?(normalized)

      raise ArgumentError, "invalid #{label}: #{value}"
    end
    private_class_method :validate!

    def normalize_authority(authority)
      raise ArgumentError, "authority must be an array" unless authority.is_a?(Array)
      raise ArgumentError, "authority entries must be nonempty strings" unless authority.all? { |entry| entry.is_a?(String) && !entry.empty? }

      normalized = authority.uniq.sort
      raise ArgumentError, "authority must not be empty" if normalized.empty?

      normalized
    end

    def normalize_scope(scope)
      raise ArgumentError, "proof boundary scope must be a hash" unless scope.is_a?(Hash)

      normalized = scope.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      raise ArgumentError, "scope has unknown fields" unless (normalized.keys - %w[kind closed]).empty?
      raise ArgumentError, "scope is missing required fields" unless (normalized.keys & %w[kind closed]).size == 2

      kind = validate!(normalized["kind"], SCOPE_KINDS, "scope kind")
      closed = normalized["closed"]
      raise ArgumentError, "scope closed must be boolean" unless closed == true || closed == false

      { "kind" => kind, "closed" => closed }
    end

    def normalize_blockers(blockers)
      raise ArgumentError, "blockers must be an array" unless blockers.is_a?(Array)

      blockers.map { |blocker| normalize_blocker(blocker) }.uniq.sort_by { |blocker| JSON.generate(blocker) }
    end

    def normalize_blocker(blocker)
      raise ArgumentError, "proof blocker must be a hash" unless blocker.is_a?(Hash)

      normalized = blocker.each_with_object({}) { |(key, value), out| out[key.to_s] = value }
      raise ArgumentError, "proof blocker has unknown fields" unless (normalized.keys - %w[kind path span]).empty?
      kind = validate!(normalized["kind"], BLOCKER_KINDS, "proof blocker kind")
      out = { "kind" => kind }
      if normalized.key?("path")
        path = normalized["path"]
        raise ArgumentError, "proof blocker path must be a nonempty string" unless path.is_a?(String) && !path.empty?

        out["path"] = path
      end
      if normalized.key?("span")
        span = normalized["span"]
        unless span.is_a?(Array) && span.size == 4 && span.all? { |value| value.is_a?(Integer) }
          raise ArgumentError, "proof blocker span must contain four integers"
        end
        start_line, start_column, end_line, end_column = span
        if start_line < 1 || start_column < 0 || end_line < start_line || end_column < 0 ||
           (end_line == start_line && end_column < start_column)
          raise ArgumentError, "proof blocker span is invalid"
        end
        out["span"] = span
      end
      out
    end
    private_class_method :normalize_authority, :normalize_scope, :normalize_blockers, :normalize_blocker
  end
end
