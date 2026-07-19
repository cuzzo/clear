require_relative '../../tools/fuzz/generator'

RSpec.describe 'semantic template migration' do
  before(:all) do
    FuzzGenerator.new(seed: 1)
  end

  it 'adopts every one of the 54 addressable templates' do
    expect(SemanticMigration.report).to include(
      templates: 54,
      full_migrations: 11,
      hybrid_refactors: 43,
      parity: true,
      full_active_renderers_removed: 11,
      hybrid_outer_matrices_retained: 43,
      shared_value_families: 7
    )
  end

  it 'preserves every stable cell expectation and rendered source digest' do
    expect(SemanticMigration.validate!).to eq(true)
    expect(SemanticMigration.specs.values).to all(satisfy(&:parity?))
  end

  it 'makes the shared semantic ValueRegistry available to every migrated context' do
    expect(SemanticMigration.specs.values).to all(satisfy do |spec|
      spec.values.equal?(SemanticEquivalence::VALUES)
    end)
  end

  it 'makes ContextSpec the sole active renderer for all full migrations' do
    full = SemanticMigration.specs.values.select { |spec| spec.disposition == :full }

    expect(full).to all(satisfy(&:full_renderer_removed?))
    expect(full.sum { |spec| spec.materialized_cells.length }).to eq(393)
  end

  it 'keeps the 27 specialized templates explicit' do
    explicit = SemanticCompletion::KEEP_EXPLICIT
    expect(explicit & SemanticMigration.specs.keys).to be_empty
    expect(explicit - FuzzGenerator::TEMPLATES.keys).to be_empty
  end
end
