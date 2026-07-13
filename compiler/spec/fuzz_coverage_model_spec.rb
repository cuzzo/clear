require "tmpdir"
require "yaml"

require_relative "../../tools/fuzz/generator"
require_relative "../../tools/fuzz/surface_registry"
require_relative "../../tools/fuzz/coverage_model"
require_relative "../../tools/fuzz/mutants/registry"

RSpec.describe FuzzCoverageModel do
  before(:all) do
    FuzzGenerator.new(seed: 1)
  end

  let(:templates) { FuzzGenerator::TEMPLATES }

  it "has complete P3 scope metadata for every registered template" do
    expect(described_class.metadata_gaps(templates)).to be_empty
  end

  it "keeps README template cell counts in sync with the generator" do
    readme = File.expand_path("../../tools/fuzz/README.md", __dir__)
    counts = described_class.documented_counts(readme)

    expect(described_class.readme_gaps(templates, counts)).to be_empty
  end

  it "keeps current high-risk sink/value-shape cross-products covered" do
    expect(described_class.cross_product_gaps).to be_empty
  end

  it "has direct mutant coverage for every high-risk template" do
    high_risk = described_class.snapshots(templates).filter_map do |snapshot|
      snapshot.name if snapshot.profile.high_risk
    end
    mutant_covered = FuzzMutants::REGISTRY.flat_map(&:templates).uniq

    expect(high_risk - mutant_covered).to be_empty
  end

  it "keeps fuzz mutant registry entries wired to real templates and patches" do
    template_names = templates.keys
    mutant_templates = FuzzMutants::REGISTRY.flat_map(&:templates).uniq
    missing_patches = FuzzMutants::REGISTRY.filter_map do |mutant|
      mutant.patch unless File.file?(mutant.patch)
    end

    expect(mutant_templates - template_names).to be_empty
    expect(missing_patches).to be_empty
  end

  it "has no quarantine file, runner flags, or non-blocking CI lane" do
    root = File.expand_path("../..", __dir__)
    runner = File.read(File.join(root, "tools/fuzz/run.rb"))
    workflow = File.read(File.join(root, ".github/workflows/ci.yml"))
    guidance = ["CLAUDE.md", "tools/fuzz/README.md", "docs/agents/annotator-genuine-gaps-burndown.md"].map do |path|
      File.read(File.join(root, path))
    end.join("\n")

    expect(File).not_to exist(File.join(root, "tools/fuzz/quarantine.txt"))
    expect(runner).not_to include("skip-quarantined", "only-quarantined", "o.on('--exclude")
    expect(workflow).not_to include("skip-quarantined", "only-quarantined", "tools-fuzz-quarantined")
    expect(guidance).not_to include("skip-quarantined", "only-quarantined")
    expectations = FuzzGenerator::TEMPLATES.values.flat_map(&:cells).map { |cell| cell.fetch(:expected, :pass) }.uniq
    expect(expectations).to all(satisfy { |value| %i[pass compile_error].include?(value) })

    jobs = YAML.safe_load(workflow, aliases: true).fetch("jobs")
    expect(jobs).not_to have_key("tools-fuzz-isolated-shard")
    expect(workflow).not_to include("--bisect-positives")
    %w[tools-fuzz-shard].each do |name|
      job = jobs.fetch(name)
      expect(job["continue-on-error"]).not_to eq(true)
      command = job.fetch("steps").filter_map { |step| step["run"] }.find { |run| run.include?("tools/fuzz/run.rb") }
      expect(command).to include("--matrix")
      expect(command).not_to include("--templates", "--exclude", "quarant")
    end
  end

  it "rejects every inactive expectation at registration" do
    expect do
      FuzzGenerator.register(:invalid_inactive_cell, cells: [{ expected: :disabled }]) { "" }
    end.to raise_error(/invalid fuzz expectation/)
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
