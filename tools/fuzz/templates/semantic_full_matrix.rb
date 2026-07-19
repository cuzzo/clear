require_relative '../semantic_full'

parser_path = File.expand_path('../../../compiler/ruby/ast/parser.rb', __dir__)
SEMANTIC_FULL_SUITE = SemanticFull::Suite.new(
  parser_path: parser_path,
  depth: Integer(ENV.fetch('SEMANTIC_FULL_DEPTH', SemanticFull::DEFAULT_DEPTH.to_s)),
  seed: Integer(ENV.fetch('SEMANTIC_FULL_SEED', '1')),
  target_per_family: Integer(ENV.fetch('SEMANTIC_FULL_FAMILY_TARGET', SemanticFull::TARGET_PER_FAMILY.to_s))
)

semantic_full_cases = SEMANTIC_FULL_SUITE.cases
if (shard = ENV['SEMANTIC_FULL_SHARD'])
  match = /\A(\d+)\/(\d+)\z/.match(shard) or raise "invalid semantic full shard #{shard.inspect}"
  index = Integer(match[1])
  count = Integer(match[2])
  raise "invalid semantic full shard #{shard.inspect}" unless count.positive? && index < count
  semantic_full_cases = semantic_full_cases.select { |item| item.fingerprint.to_i(16) % count == index }
end

limit = Integer(ENV.fetch('SEMANTIC_FULL_LIMIT', '250'))
if limit.positive? && semantic_full_cases.length > limit
  by_family = semantic_full_cases.group_by(&:family).values
  semantic_full_cases = (0...limit).filter_map do |index|
    family = by_family[index % by_family.length]
    family[index / by_family.length]
  end
end
SEMANTIC_FULL_CASES = semantic_full_cases.to_h { |item| [item.id, item] }.freeze
SEMANTIC_FULL_CELLS = SEMANTIC_FULL_CASES.values.map do |item|
  {
    case_id: item.id,
    family: item.family,
    topology: item.topology.id,
    derivation: item.fragment.fingerprint,
    expected_type: SemanticEquivalence::VALUES.fetch(item.family).clear_type,
  }
end.freeze

FuzzGenerator.register(:semantic_full_matrix, cells: SEMANTIC_FULL_CELLS) do |params|
  SEMANTIC_FULL_CASES.fetch(params.fetch(:case_id)).source
end
