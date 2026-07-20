require_relative '../../tools/fuzz/generator'
require_relative '../../tools/fuzz/semantic_advanced'
require_relative '../ruby/backends/transpiler' unless defined?(CompilerFrontend)

RSpec.describe SemanticAdvanced do
  let(:generator) { FuzzGenerator.new(seed: 1) }
  let(:registry) { described_class.registry(depth_seeds: 1) }

  before { generator }

  it 'has an executable legality and trace contract for every advanced workstream' do
    expect(registry.validate!).to equal(registry)
    expect(registry.report.fetch(:workstreams).keys).to match_array(described_class::WORKSTREAMS)
    expect(registry.report.fetch(:rejected)).to be_positive
    expect(registry.report.fetch(:depth_cases)).to eq(18)
    expect(registry.report.fetch(:gaps)).to eq(discovered: 13, fixed: 13, expected: 0, outstanding: 0)
  end

  it 'renders every registry entry through its declared requirement owner' do
    registry.entries.each do |entry|
      meta = if entry.template == :semantic_advanced_inline
               { source: entry.params.fetch(:source) }
             else
               described_class.source_for(entry)
             end
      expect(meta.fetch(:source)).not_to be_empty, entry.id
      if entry.workstream == :diagnostics && entry.rejected?
        expect(meta).to include(diagnostic_code_required: true, error_code: entry.error_code)
      end
    end
  end

  it 'exposes each admitted tuple as a stable fuzz cell' do
    cells = generator.full_matrix.select { |cell| cell[:template] == :semantic_advanced_matrix }
    expected = registry.entries.reject { |entry| entry.workstream == :concurrency }.length + 24
    expect(cells.length).to eq(expected)
    expect(cells.map { |cell| cell[:params].fetch(:case_id) } - registry.entries.map(&:id)).to be_empty
    expect(cells.map { |cell| cell[:params].fetch(:workstream) }.count(:concurrency)).to eq(24)
  end

  it 'verifies generated diagnostics against structured code and primary span' do
    diagnostics = registry.entries.select { |entry| entry.workstream == :diagnostics }
    results = diagnostics.map { |entry| described_class.verify_diagnostic!(entry) }
    expect(results.map(&:code)).to match_array(diagnostics.map(&:error_code))
    expect(results).to all(satisfy { |result| result.line.positive? && result.column.positive? })
  end
end
