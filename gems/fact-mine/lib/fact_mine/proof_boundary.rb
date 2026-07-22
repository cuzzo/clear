# frozen_string_literal: true

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

    def build(input_completeness:, claim_status:, coverage_discharge:, authority:, scope:, blockers: [], claim_kind: nil)
      input = validate!(input_completeness, INPUT_COMPLETENESS, "input completeness")
      claim = validate!(claim_status, CLAIM_STATUS, "claim status")
      discharge = validate!(coverage_discharge, COVERAGE_DISCHARGE, "coverage discharge")
      normalized_authority = Array(authority).map(&:to_s).reject(&:empty?).uniq.sort
      normalized_claim_kind, normalized_scope = normalize_scope(claim_kind, scope)
      raise ArgumentError, "authority must not be empty" if normalized_authority.empty?
      raise ArgumentError, "claim kind must not be empty" if normalized_claim_kind.empty?

      {
        "schema" => SCHEMA,
        "input_completeness" => input,
        "claim_status" => claim,
        "coverage_discharge" => discharge,
        "authority" => normalized_authority,
        "claim_kind" => normalized_claim_kind,
        "scope" => normalized_scope,
        "blockers" => Array(blockers).map { |blocker| normalize_blocker(blocker) }.uniq.sort_by(&:to_s)
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

    def normalize_scope(claim_kind, scope)
      if scope.is_a?(Hash)
        kind = scope.fetch("kind", scope[:kind]).to_s
        closed = scope.fetch("closed", scope[:closed]) == true
        raise ArgumentError, "invalid scope kind: #{kind}" unless SCOPE_KINDS.include?(kind)
        [claim_kind.to_s.empty? ? "unspecified" : claim_kind.to_s, { "kind" => kind, "closed" => closed }]
      else
        legacy = scope.to_s
        if SCOPE_KINDS.include?(legacy)
          [claim_kind.to_s.empty? ? "unspecified" : claim_kind.to_s, { "kind" => legacy, "closed" => legacy == "closed_build_target" }]
        else
          [claim_kind.to_s.empty? ? legacy : claim_kind.to_s, { "kind" => "local", "closed" => false }]
        end
      end
    end
    private_class_method :normalize_scope

    def normalize_blocker(blocker)
      if blocker.is_a?(Hash)
        kind = blocker.fetch("kind", blocker[:kind]).to_s
        if BLOCKER_KINDS.include?(kind)
          normalized = { "kind" => kind }
          path = blocker.fetch("path", blocker[:path])
          span = blocker.fetch("span", blocker[:span])
          normalized["path"] = path.to_s unless path.nil? || path.to_s.empty?
          normalized["span"] = Array(span).map(&:to_i) if Array(span).size == 4
          return normalized
        end
      end

      text = blocker.to_s
      kind = if text.start_with?("parser_recovery")
        "parser_recovery"
      elsif text.start_with?("unresolved_call_resolution") || text.match?(/dispatch|call.*unresolved/i)
        "call_resolution"
      elsif text.start_with?("missing_")
        "missing_evidence"
      elsif text == "open_corpus" || text.match?(/closed corpus|incomplete corpus/i)
        "open_corpus"
      else
        "unknown"
      end
      { "kind" => kind }
    end
    private_class_method :normalize_blocker
  end
end
