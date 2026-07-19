require_relative '../semantic_gaps'

SEMANTIC_GAP_CASES = (SemanticGaps::FIXED + SemanticGaps::FIXED_CAPABILITIES + SemanticGaps::FIXED_EXPANSION)
  .to_h { |gap| [gap.id, gap] }
  .freeze
SEMANTIC_GAP_CELLS = SEMANTIC_GAP_CASES.values.map do |gap|
  { gap_id: gap.id, phase: gap.phase }
end.freeze

FuzzGenerator.register(:semantic_gap_matrix, cells: SEMANTIC_GAP_CELLS) do |params|
  SEMANTIC_GAP_CASES.fetch(params.fetch(:gap_id)).witness
end
