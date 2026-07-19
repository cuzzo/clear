require_relative '../semantic_equivalence'

parser_path = File.expand_path('../../../compiler/ruby/ast/parser.rb', __dir__)
SEMANTIC_EQUIVALENCE_SUITE = SemanticEquivalence::Suite.mvp(
  parser_path: parser_path,
  max_depth: Integer(ENV.fetch('SEMANTIC_FUZZ_DEPTH', '1')),
  seed: Integer(ENV.fetch('SEMANTIC_FUZZ_SEED', '1')),
  limit: ENV['SEMANTIC_FUZZ_LIMIT'],
  shard: ENV['SEMANTIC_FUZZ_SHARD']
)
semantic_production_filter = ENV['SEMANTIC_FUZZ_PRODUCTION']&.split(',')&.map(&:to_sym)
semantic_consumer_filter = ENV['SEMANTIC_FUZZ_CONSUMER']&.split(',')&.map(&:to_sym)
semantic_case_filter = ENV['SEMANTIC_FUZZ_CASE']&.split(',')
semantic_filtered_cases = SEMANTIC_EQUIVALENCE_SUITE.cases.select do |item|
  (!semantic_production_filter || semantic_production_filter.include?(item.production_id)) &&
    (!semantic_consumer_filter || semantic_consumer_filter.include?(item.consumer_id)) &&
    (!semantic_case_filter || semantic_case_filter.include?(item.id))
end
SEMANTIC_EQUIVALENCE_CASES = semantic_filtered_cases.to_h { |item| [item.id, item] }.freeze
SEMANTIC_EQUIVALENCE_CELLS = SEMANTIC_EQUIVALENCE_CASES.values.map do |item|
  {
    case_id: item.id,
    production: item.production_id,
    consumer: item.consumer_id,
    derivation: item.derivation.fingerprint,
    depth: item.derivation.depth,
    cost: item.derivation.cost,
    semantic_seed: SEMANTIC_EQUIVALENCE_SUITE.seed,
    expected_type: item.expected_type,
    expected_value: item.expected_value,
  }
end.freeze

FuzzGenerator.register(:semantic_equivalence_matrix, cells: SEMANTIC_EQUIVALENCE_CELLS) do |params|
  SEMANTIC_EQUIVALENCE_CASES.fetch(params.fetch(:case_id)).source
end
