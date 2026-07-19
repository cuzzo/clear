require_relative '../semantic_equivalence'

SEMANTIC_CAPABILITY_SUITE = SemanticEquivalence::CapabilitySuite.new
SEMANTIC_CAPABILITY_CASES = SEMANTIC_CAPABILITY_SUITE.cases.to_h { |item| [item.id, item] }.freeze
SEMANTIC_CAPABILITY_CELLS = SEMANTIC_CAPABILITY_CASES.values.map do |item|
  {
    case_id: item.id,
    value: item.expected_value.fetch(:value),
    capability: item.expected_value.fetch(:capability),
    access: item.consumer_id,
    derivation: item.derivation.fingerprint,
  }
end.freeze

FuzzGenerator.register(:semantic_capability_matrix, cells: SEMANTIC_CAPABILITY_CELLS) do |params|
  SEMANTIC_CAPABILITY_CASES.fetch(params.fetch(:case_id)).source
end
