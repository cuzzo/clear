require_relative '../semantic_capability_expansion'

SEMANTIC_CAPABILITY_TRANSPORT_SUITE = SemanticCapabilityExpansion::TransportSuite.new
SEMANTIC_CAPABILITY_TRANSPORT_CASES = SEMANTIC_CAPABILITY_TRANSPORT_SUITE.cases.to_h { |item| [item.id, item] }.freeze
SEMANTIC_CAPABILITY_TRANSPORT_CELLS = SEMANTIC_CAPABILITY_TRANSPORT_CASES.values.map do |item|
  { case_id: item.id, value: item.value_id, capability: item.capability_id, carrier: item.carrier }
end.freeze

FuzzGenerator.register(:semantic_capability_transport_matrix, cells: SEMANTIC_CAPABILITY_TRANSPORT_CELLS) do |params|
  SEMANTIC_CAPABILITY_TRANSPORT_CASES.fetch(params.fetch(:case_id)).source
end
