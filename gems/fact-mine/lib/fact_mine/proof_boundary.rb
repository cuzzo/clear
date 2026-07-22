# frozen_string_literal: true

# The versioned proof-boundary contract shared by Ruby SARIF producers.
# Rust producers conform through gems/hazard-contract/proof-boundary.v2.schema.json.
module FactMine
  module ProofBoundary
    PROOF_BOUNDARY_PROPERTY = "fact_mine.proof_boundary"
    PROOF_BOUNDARY_SUMMARY_PROPERTY = "fact_mine.proof_boundary_summary"
    SCHEMA = "fact-mine.proof-boundary.v2"
    INPUT_COMPLETENESS = %w[complete partial unknown].freeze
    CLAIM_STATUS = %w[proven observed review].freeze
    COVERAGE_DISCHARGE = %w[satisfiable unsatisfiable not_applicable unknown].freeze

    module_function

    def build(input_completeness:, claim_status:, coverage_discharge:, authority:, scope:, blockers: [])
      input = validate!(input_completeness, INPUT_COMPLETENESS, "input completeness")
      claim = validate!(claim_status, CLAIM_STATUS, "claim status")
      discharge = validate!(coverage_discharge, COVERAGE_DISCHARGE, "coverage discharge")
      normalized_authority = Array(authority).map(&:to_s).reject(&:empty?).uniq.sort
      normalized_scope = scope.to_s
      raise ArgumentError, "authority must not be empty" if normalized_authority.empty?
      raise ArgumentError, "scope must not be empty" if normalized_scope.empty?

      {
        "schema" => SCHEMA,
        "input_completeness" => input,
        "claim_status" => claim,
        "coverage_discharge" => discharge,
        "authority" => normalized_authority,
        "scope" => normalized_scope,
        "blockers" => Array(blockers).map(&:to_s).uniq.sort
      }
    end

    def summary(results)
      input = INPUT_COMPLETENESS.to_h { |value| [value, 0] }
      claims = CLAIM_STATUS.to_h { |value| [value, 0] }
      coverage = COVERAGE_DISCHARGE.to_h { |value| [value, 0] }
      boundaries = Array(results).filter_map do |result|
        boundary = result.dig("properties", PROOF_BOUNDARY_PROPERTY)
        boundary if boundary.is_a?(Hash)
      end
      boundaries.each do |boundary|
        input[INPUT_COMPLETENESS.include?(boundary["input_completeness"]) ? boundary["input_completeness"] : "unknown"] += 1
        claims[CLAIM_STATUS.include?(boundary["claim_status"]) ? boundary["claim_status"] : "review"] += 1
        coverage[COVERAGE_DISCHARGE.include?(boundary["coverage_discharge"]) ? boundary["coverage_discharge"] : "unknown"] += 1
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
  end
end
