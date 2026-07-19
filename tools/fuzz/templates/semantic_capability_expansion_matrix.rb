require_relative '../semantic_capability_expansion'

# Opt-in because the full 1,700-case lane is a campaign, not ordinary template
# load work.  A PR can select a bounded target; the full command sets target
# 100 and a deterministic shard.
if ENV['SEMANTIC_CAPABILITY_EXPANSION'] == '1'
  parser_path = File.expand_path('../../../compiler/ruby/ast/parser.rb', __dir__)
  suite = SemanticCapabilityExpansion::Suite.new(
    parser_path: parser_path,
    depth: Integer(ENV.fetch('SEMANTIC_CAPABILITY_EXPANSION_DEPTH', SemanticCapabilityExpansion::DEFAULT_DEPTH.to_s)),
    seed: Integer(ENV.fetch('SEMANTIC_CAPABILITY_EXPANSION_SEED', '1')),
    target_per_pair: Integer(ENV.fetch('SEMANTIC_CAPABILITY_EXPANSION_TARGET', SemanticCapabilityExpansion::TARGET_PER_PAIR.to_s))
  )
  cases = suite.cases
  if (shard = ENV['SEMANTIC_CAPABILITY_EXPANSION_SHARD'])
    index, count = shard.split('/').map { |part| Integer(part) }
    raise "invalid capability expansion shard #{shard.inspect}" unless count.positive? && index.between?(0, count - 1)
    cases = cases.select { |item| item.fingerprint.to_i(16) % count == index }
  end
  SEMANTIC_CAPABILITY_EXPANSION_CASES = cases.to_h { |item| [item.id, item] }.freeze
  SEMANTIC_CAPABILITY_EXPANSION_CELLS = SEMANTIC_CAPABILITY_EXPANSION_CASES.values.map do |item|
    { case_id: item.id, value: item.value_id, capability: item.capability_id, derivation: item.fragment.fingerprint }
  end.freeze
else
  SEMANTIC_CAPABILITY_EXPANSION_CASES = {}.freeze
  SEMANTIC_CAPABILITY_EXPANSION_CELLS = [].freeze
end

FuzzGenerator.register(:semantic_capability_expansion_matrix, cells: SEMANTIC_CAPABILITY_EXPANSION_CELLS) do |params|
  SEMANTIC_CAPABILITY_EXPANSION_CASES.fetch(params.fetch(:case_id)).source
end
