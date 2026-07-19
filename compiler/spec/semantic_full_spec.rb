require_relative '../../tools/fuzz/semantic_full'
require_relative '../../tools/fuzz/semantic_gaps'

RSpec.describe SemanticFull do
  let(:parser_path) { File.expand_path('../ruby/ast/parser.rb', __dir__) }
  let(:suite) { described_class::Suite.new(parser_path: parser_path, depth: 3, seed: 7) }

  it 'meets the 1,000-case gate independently for every enabled value family' do
    expect(suite.report.fetch(:family_cases).values).to all(eq(1_000))
    expect(suite.report.fetch(:cases)).to eq(7_000)
  end

  it 'crosses five carriers with five whole-program scopes' do
    expect(described_class::TOPOLOGIES.map(&:id).uniq.length).to eq(25)
    expect(suite.report).to include(topologies: 25, scopes: 5, carriers: 5)
  end

  it 'generates COPY and GIVE-to-TAKES cases for managed families' do
    expect(suite.report.fetch(:copy_cases)).to be >= 1_000
    expect(suite.report.fetch(:give_takes_cases)).to be >= 900
    expect(suite.cases.map { |item| item.topology.carrier }).to include(:mutable_or_copy, :give_to_takes)
  end

  it 'is byte-identical for a repeated seed' do
    again = described_class::Suite.new(parser_path: parser_path, depth: 3, seed: 7)
    expect(again.cases.map { |item| [item.id, item.source] }).to eq(suite.cases.map { |item| [item.id, item.source] })
  end

  it 'maintains an exact executable gap ledger' do
    expect(SemanticGaps.validate!).to eq(true)
    expect(SemanticGaps.report).to include(discovered: 21, fixed: 21, outstanding: 0)
    expect(SemanticGaps::ALL).to all(satisfy { |gap| !gap.witness.to_s.strip.empty? })
  end

  it 'closes all reviewed capability pairs without exclusions' do
    capabilities = SemanticEquivalence::CapabilitySuite.new
    expect(capabilities.report).to include(cases: 17, value_capability_pairs: 17)
    expect(SemanticEquivalence::CAPABILITY_EXCLUSIONS).to be_empty
  end
end
