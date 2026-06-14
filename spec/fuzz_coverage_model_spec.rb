require "tmpdir"

require_relative "../tools/fuzz/generator"
require_relative "../tools/fuzz/surface_registry"
require_relative "../tools/fuzz/coverage_model"

RSpec.describe FuzzCoverageModel do
  before(:all) do
    FuzzGenerator.new(seed: 1)
  end

  let(:templates) { FuzzGenerator::TEMPLATES }

  it "has complete P3 scope metadata for every registered template" do
    expect(described_class.metadata_gaps(templates)).to be_empty
  end

  it "keeps README template cell counts in sync with the generator" do
    readme = File.expand_path("../tools/fuzz/README.md", __dir__)
    counts = described_class.documented_counts(readme)

    expect(described_class.readme_gaps(templates, counts)).to be_empty
  end

  it "keeps current high-risk sink/value-shape cross-products covered" do
    expect(described_class.cross_product_gaps).to be_empty
  end

  it "reports stale README active-cell counts" do
    fake_template = Struct.new(:cells).new([{ expected: :pass }, { expected: :compile_error }])
    fake_templates = { escape_via_return: fake_template }

    gaps = described_class.readme_gaps(fake_templates, { escape_via_return: 1 })

    expect(gaps).to include("README active cell count for escape_via_return is 1, expected 2")
  end

  it "reports missing per-template P3 metadata" do
    fake_template = Struct.new(:cells).new([])

    gaps = described_class.metadata_gaps({ untracked_template: fake_template })

    expect(gaps).to include("template untracked_template is missing P3 scope metadata")
  end

  it "requires high-risk templates to use full matrix expansion" do
    fake_template = Struct.new(:cells).new([])
    high_risk_profile = described_class.profile(
      failure_proves: "important invariant",
      high_risk: true,
      matrix_strategy: :smoke
    )

    stub_const("#{described_class}::TEMPLATE_PROFILES", { dangerous_template: high_risk_profile })

    gaps = described_class.metadata_gaps({ dangerous_template: fake_template })

    expect(gaps).to include(
      "dangerous_template is high-risk but matrix_strategy=smoke; high-risk surfaces require full expansion"
    )
  end

  it "reports missing high-risk escape-sink by value-shape cross-products" do
    stub_const(
      "FuzzSurfaceRegistry::SINK_REQUIRES_SHAPES",
      { return_value: [:string, :shape_the_current_suite_does_not_cover] }
    )

    gaps = described_class.cross_product_gaps

    expect(gaps.join("\n")).to include("escape_sinks:return_value")
    expect(gaps.join("\n")).to include("shape_the_current_suite_does_not_cover")
  end
end
