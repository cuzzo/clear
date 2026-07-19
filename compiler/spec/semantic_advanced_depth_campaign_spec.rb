require_relative '../../tools/fuzz/semantic_full'

RSpec.describe SemanticFull::AdvancedCampaign do
  let(:parser_path) { File.expand_path('../ruby/ast/parser.rb', __dir__) }

  it 'declares one depth-4 run and ten deterministic seeds at each deep level' do
    expect(described_class.report).to include(deep_campaigns: 20, deep_seeds: (1..10).to_a, target_per_family: 1_000)
    expect(described_class::ALL.map(&:depth)).to include(4, 5, 6)
  end

  it 'builds bounded typed derivations at depth 4, 5, and 6 without Cartesian explosion' do
    [4, 5, 6].each do |depth|
      suite = SemanticFull::Suite.new(parser_path: parser_path, depth: depth, seed: 31, target_per_family: 25)
      expect(suite.report.fetch(:family_cases).values).to all(eq(25))
      expect(suite.report.fetch(:copy_cases)).to be_positive
      expect(suite.report.fetch(:give_takes_cases)).to be_positive
    end
  end
end
