require_relative '../../tools/fuzz/semantic_capability_expansion'

RSpec.describe SemanticCapabilityExpansion::Suite do
  let(:parser_path) { File.expand_path('../ruby/ast/parser.rb', __dir__) }

  it 'covers every reviewed capability/value pair with independent typed payload derivations' do
    suite = described_class.new(parser_path: parser_path, depth: 3, seed: 17, target_per_pair: 5)
    expect(suite.report.fetch(:pairs).values).to all(eq(5))
    expect(suite.report.fetch(:families).fetch(:struct)).to eq(40)
  end

  it 'is deterministic for a seed and changes selected derivations with another seed' do
    first = described_class.new(parser_path: parser_path, depth: 3, seed: 17, target_per_pair: 5)
    again = described_class.new(parser_path: parser_path, depth: 3, seed: 17, target_per_pair: 5)
    other = described_class.new(parser_path: parser_path, depth: 3, seed: 18, target_per_pair: 5)
    expect(first.cases.map(&:id)).to eq(again.cases.map(&:id))
    expect(first.cases.map(&:id)).not_to eq(other.cases.map(&:id))
  end
end

RSpec.describe SemanticCapabilityExpansion::TransportSuite do
  it 'models both legal COPY/GIVE/TAKES carriers for every direct managed pair' do
    expect(subject.report).to include(cases: 20, carriers: %i[direct nested_field])
    expect(subject.report.fetch(:pairs).values).to all(eq(2))
  end
end
