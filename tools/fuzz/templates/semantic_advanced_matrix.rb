require_relative '../semantic_advanced'

# Load the reviewed surface renderers before constructing the registry.  Ruby
# require is idempotent, so generator.rb's normal alphabetical load remains
# safe; this merely makes the advanced matrix independently loadable in specs.
%w[
  semantic_capability_matrix capability_wrap_matrix execution_boundary
  bg_capture_transfer_matrix infallible_signature generic_map_protocol_matrix
  generic_shared_map_capability_matrix
].each { |name| require_relative name }

SEMANTIC_ADVANCED_REGISTRY = SemanticAdvanced.registry(
  depth_seeds: Integer(ENV.fetch('SEMANTIC_ADVANCED_DEPTH_SEEDS', '1'))
)
advanced_entries = SEMANTIC_ADVANCED_REGISTRY.entries
if (workstream = ENV['SEMANTIC_ADVANCED_WORKSTREAM'])
  advanced_entries = advanced_entries.select { |entry| entry.workstream.to_s == workstream }
end
if (excluded = ENV['SEMANTIC_ADVANCED_EXCLUDE_WORKSTREAM'])
  names = excluded.split(',').map(&:strip)
  advanced_entries = advanced_entries.reject { |entry| names.include?(entry.workstream.to_s) }
end
if (concurrency_kind = ENV['SEMANTIC_ADVANCED_CONCURRENCY_KIND'])
  advanced_entries = advanced_entries.select do |entry|
    entry.workstream != :concurrency || entry.provenance.to_s == concurrency_kind
  end
end
if (provenance = ENV['SEMANTIC_ADVANCED_PROVENANCE'])
  advanced_entries = advanced_entries.select { |entry| entry.provenance.to_s == provenance }
end

# Async runtime cases are intentionally isolated by the fuzz runner.  Keep the
# PR lane bounded but representative; a zero limit is the exhaustive nightly
# schedule/admission campaign.  Round-robin selection retains both boundary
# and transfer renderers instead of allowing a hash sample to hide a family.
concurrency_limit = Integer(ENV.fetch('SEMANTIC_ADVANCED_CONCURRENCY_LIMIT', '24'))
concurrency_entries = advanced_entries.select { |entry| entry.workstream == :concurrency }
if concurrency_limit.positive? && concurrency_entries.length > concurrency_limit
  groups = concurrency_entries.group_by(&:template).values
  selected_concurrency = (0...concurrency_limit).filter_map do |index|
    group = groups[index % groups.length]
    group[index / groups.length]
  end
  advanced_entries = advanced_entries.reject { |entry| entry.workstream == :concurrency } + selected_concurrency
end

SEMANTIC_ADVANCED_ENTRIES = advanced_entries.to_h { |entry| [entry.id, entry] }.freeze
SEMANTIC_ADVANCED_CELLS = SEMANTIC_ADVANCED_ENTRIES.values.map do |entry|
  { case_id: entry.id, expected: entry.expected, workstream: entry.workstream, provenance: entry.provenance }
end.freeze

FuzzGenerator.register(:semantic_advanced_matrix, cells: SEMANTIC_ADVANCED_CELLS) do |params|
  entry = SEMANTIC_ADVANCED_ENTRIES.fetch(params.fetch(:case_id))
  if entry.template == :semantic_advanced_inline
    { source: entry.params.fetch(:source) }
  else
    SemanticAdvanced.source_for(entry)
  end
end
