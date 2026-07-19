require_relative '../../tools/fuzz/generator'
require_relative '../../tools/fuzz/semantic_completion'
require_relative '../../tools/fuzz/semantic_gaps'

RSpec.describe SemanticCompletion do
  it 'keeps the original migration and gap scope closed and executable' do
    FuzzGenerator.new(seed: 1)

    expect(described_class::FULL_MIGRATIONS.length).to eq(11)
    expect(described_class::UNIQUE_HYBRID_REFACTORS.length).to eq(43)
    expect(described_class::KEEP_EXPLICIT.length).to eq(27)
    expect(described_class::LANGUAGE_GAPS.length).to eq(6)
    expect(SemanticGaps.report).to include(discovered: 21, fixed: 21, outstanding: 0)
    expect(
      described_class::FULL_MIGRATIONS & described_class::UNIQUE_HYBRID_REFACTORS
    ).to be_empty
    expect(
      described_class::FULL_MIGRATIONS & described_class::KEEP_EXPLICIT
    ).to be_empty
    expect(
      described_class::UNIQUE_HYBRID_REFACTORS & described_class::KEEP_EXPLICIT
    ).to be_empty
    expect(
      described_class::FULL_MIGRATIONS.length +
        described_class::UNIQUE_HYBRID_REFACTORS.length +
        described_class::KEEP_EXPLICIT.length
    ).to eq(81)
    expect do
      described_class.validate!(registered_templates: FuzzGenerator::TEMPLATES.keys)
    end.not_to raise_error
  end
end
