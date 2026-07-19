require_relative '../../tools/fuzz/semantic_equivalence'

RSpec.describe SemanticEquivalence do
  let(:parser_path) { File.expand_path('../ruby/ast/parser.rb', __dir__) }
  let(:suite) { described_class::Suite.mvp(parser_path: parser_path, max_depth: 1) }

  it 'derives typed NIL OR_ELSE 1 from productions instead of a handwritten witness' do
    witness = suite.fragments.find do |fragment|
      fragment.goal == described_class::INT_ONE && fragment.productions.include?(:nil_or_else)
    end

    expect(witness).not_to be_nil
    expect(witness.productions).to include(:nil_or_else, :nil_literal, :int_literal)
    expect(witness.source).to include('NIL OR_ELSE 1_i64')
  end

  it 'places every derivation in every compatible consumer' do
    suite.fragments.each do |fragment|
      expected = suite.consumers.count { |consumer| consumer.accepts?(fragment.goal) }
      actual = suite.cases.count { |item| item.id.start_with?("#{fragment.goal.type}-#{fragment.fingerprint}-") }
      blocked = suite.blocked_obligations.count { |item| item.id.start_with?("#{fragment.goal.type}-#{fragment.fingerprint}-") }
      expect(actual + blocked).to eq(expected)
    end
  end

  it 'classifies every parser pipeline expression route' do
    expect(suite.audit).to eq(total: 26, generated: 10, manual: 16)
  end

  it 'exercises every declared production and consumer' do
    expect(suite.report.fetch(:productions_used)).to eq(suite.report.fetch(:productions))
    expect(suite.cases.map(&:consumer_id).uniq).to match_array(suite.consumers.map(&:id))
  end

  it 'activates every previously blocked obligation after its compiler fix' do
    active_pairs = suite.cases.map { |item| [item.production_id, item.consumer_id] }
    expect(active_pairs).to include([:singleton_sum, :pipeline_select], [:singleton_sum, :pipeline_sum])
    expect(active_pairs).to include([:map_literal, :list_element])
    expect(suite.blocked_obligations).to be_empty
  end


  it 'separates the original fixed gaps from newly discovered outstanding gaps' do
    expect(suite.report.fetch(:known_gaps)).to be_empty
    expect(described_class::FIXED_EXPANSION_GAPS.keys).to contain_exactly(
      :takes_direct_list_literal,
      :tuple_nil_or_else_transfer,
      :tuple_temporary_copy_leak,
      :list_or_else_loop_field_coercion,
      :nested_owned_sink_allocator_transport,
      :nested_list_contextual_shape,
      :owned_optional_fallback_copy_lifetime,
      :tuple_collection_constructor_context,
      :collection_literal_child_allocator_transport,
      :optional_owned_branch_allocator_convergence,
      :tuple_temporary_allocator_convergence
    )
    expect(suite.report.fetch(:fixed_language_gaps)).to contain_exactly(
      :contextual_nil_or_else,
      :direct_struct_literal_field,
      :unused_pipeline_capture,
      :int_min_max_projection,
      :nested_pipeline_expression,
      :nested_owned_map
    )
  end

  it 'is deterministic' do
    again = described_class::Suite.mvp(parser_path: parser_path, max_depth: 1)
    expect(again.cases.map(&:id)).to eq(suite.cases.map(&:id))
    expect(again.cases.map(&:source)).to eq(suite.cases.map(&:source))
  end

  it 'retains a typed derivation tree and edge coverage for every case' do
    suite.cases.each do |item|
      expected_goal = described_class::VALUES.values.find { |value| value.clear_type == item.expected_type }.goal
      expect(item.derivation.goal.key).to eq([expected_goal.type, item.expected_value])
      expect(item.derivation.to_h).to include(:production, :goal, :children, :depth, :cost)
    end
    expect(suite.report.fetch(:derivation_edges)).to be_positive
    expect(suite.report.fetch(:depth_histogram)).to include(0, 1)
  end

  it 'selects bounded campaigns reproducibly and shards by stable case hash' do
    first = described_class::Suite.mvp(parser_path: parser_path, max_depth: 2, seed: 41, limit: 160)
    again = described_class::Suite.mvp(parser_path: parser_path, max_depth: 2, seed: 41, limit: 160)
    other = described_class::Suite.mvp(parser_path: parser_path, max_depth: 2, seed: 42, limit: 160)

    expect(first.cases.map(&:id)).to eq(again.cases.map(&:id))
    expect(first.cases.length).to eq(160)
    expect(first.cases.map(&:id)).not_to eq(other.cases.map(&:id))

    shards = 3.times.map do |index|
      described_class::Suite.mvp(parser_path: parser_path, max_depth: 2, seed: 41, shard: "#{index}/3").cases.map(&:id)
    end
    expect(shards.flatten.uniq.sort).to eq(first.all_cases.map(&:id).sort)
    expect(shards.combination(2)).to all(satisfy { |left, right| (left & right).empty? })
  end

  it 'rejects a limit that would silently discard mandatory coverage representatives' do
    expect do
      described_class::Suite.mvp(parser_path: parser_path, max_depth: 2, seed: 41, limit: 10)
    end.to raise_error(/cannot retain .* mandatory coverage representatives/)
  end

  it 'shrinks only to cheaper derivations in the same semantic and attribute class' do
    complex = suite.fragments.max_by(&:cost)
    shrinker = described_class::Shrinker.new(suite.fragments)
    candidates = shrinker.candidates(complex)

    expect(candidates).not_to be_empty
    expect(candidates).to all(satisfy { |candidate| shrinker.preserves_class?(complex, candidate) })
    expect(candidates).to all(satisfy { |candidate| candidate.cost < complex.cost || candidate.depth < complex.depth })
  end

  it 'emits standalone deterministic failure context without consulting the compiler for its oracle' do
    item = suite.cases.first
    context = item.failure_context(seed: suite.seed)

    expect(context).to include(
      seed: 1,
      case_id: item.id,
      expected_type: item.expected_type,
      expected_value: item.expected_value,
      source: item.source
    )
    expect(context.fetch(:derivation)).to eq(item.derivation.to_h)
  end

  it 'closes the reviewed capability allowlist and keeps unsupported access protocols explicit' do
    capabilities = described_class::CapabilitySuite.new

    expect(capabilities.report).to include(
      capabilities: 9,
      cases: 17,
      value_capability_pairs: 17,
      access_modes: %i[direct exclusive snapshot]
    )
    expect(described_class::CAPABILITY_EXCLUSIONS).to be_empty
  end
end
