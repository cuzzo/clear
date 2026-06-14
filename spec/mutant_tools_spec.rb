require_relative "../tools/mutants/support" unless defined?(MutationTesting)
require_relative "../tools/mutants/ruby_specs" unless defined?(RubySpecMutants)

RSpec.describe MutationTesting do
  describe ".parse_mutant_summary" do
    it "parses mutant's final summary block" do
      output = <<~OUT
        Mutant environment:
        Selected-Tests:  37
        Mutations:       2378
        Results:         2378
        Kills:           1814
        Alive:           564
        Timeouts:        59
        Coverage:        76.28%
      OUT

      summary = described_class.parse_mutant_summary(output)

      expect(summary.mutations).to eq(2378)
      expect(summary.kills).to eq(1814)
      expect(summary.alive).to eq(564)
      expect(summary.timeouts).to eq(59)
      expect(summary.selected_tests).to eq(37)
      expect(summary.coverage).to eq(76.28)
    end

    it "returns nil for unparsable output" do
      expect(described_class.parse_mutant_summary("boom")).to be_nil
    end
  end

  describe ".parse_fuzz_summary" do
    it "parses the fuzz runner summary line" do
      summary = described_class.parse_fuzz_summary(
        "Summary: 50 run, 46 ok, 1 fail, 2 leak, 3 mir-error, 4 unexpected-pass\n"
      )

      expect(summary).to include(
        run: 50,
        ok: 46,
        fail: 1,
        leak: 2,
        mir_error: 3,
        unexpected_pass: 4
      )
    end
  end

  describe ".parse_shard and .shard_items" do
    it "selects deterministic round-robin shards" do
      shard = described_class.parse_shard("1/3")

      expect(shard.index).to eq(1)
      expect(shard.count).to eq(3)
      expect(described_class.shard_items(%w[a b c d e f g], shard)).to eq(%w[b e])
    end

    it "rejects invalid shard bounds" do
      expect { described_class.parse_shard("3/3") }.to raise_error(RuntimeError, /shard index/)
      expect { described_class.parse_shard("0/0") }.to raise_error(RuntimeError, /shard count/)
      expect { described_class.parse_shard("x/y") }.to raise_error(RuntimeError, /invalid shard/)
    end
  end
end

RSpec.describe RubySpecMutants do
  def mutant_subject(hard_gate:)
    RubySpecMutants::Subject.new(
      name: "sample",
      expression: "Sample*",
      requires: ["sample", "dependency"],
      specs: ["spec/mutant_tools_spec.rb"],
      min_coverage: 90.0,
      max_timeouts: 0,
      hard_gate: hard_gate
    )
  end

  def mutant_summary(coverage:, mutations: 10, selected_tests: 1, timeouts: 0)
    MutationTesting::MutantSummary.new(
      mutations: mutations,
      kills: 0,
      alive: mutations,
      timeouts: timeouts,
      selected_tests: selected_tests,
      coverage: coverage
    )
  end

  it "loads the src subject matrix" do
    expect(described_class::SUBJECTS.length).to be > 100
    expect(described_class::SUBJECTS.map(&:name)).to include("lexer", "mirlowering-lower", "zigtranspiler")
  end

  it "runs mutant in zombie mode with each subject require" do
    argv = described_class.mutant_argv(mutant_subject(hard_gate: true), "origin/main")

    expect(argv).to include("mutant", "--zombie", "run")
    expect(argv.each_index.select { |index| argv[index] == "-r" }.length).to eq(2)
    expect(argv).to include("--since", "origin/main", "Sample*")
  end

  it "passes every mapped spec file to the rspec integration" do
    subject = RubySpecMutants::Subject.new(
      name: "multi",
      expression: "Multi*",
      requires: [],
      specs: ["spec/a_spec.rb", "spec/b_spec.rb"],
      min_coverage: 100.0,
      max_timeouts: 0,
      hard_gate: true
    )

    argv = described_class.mutant_argv(subject, nil)

    spec_args = argv.each_index.select { |index| argv[index] == "--integration-argument" }
    expect(spec_args.map { |index| argv.fetch(index + 1) }).to eq(["spec/a_spec.rb", "spec/b_spec.rb"])
  end

  it "parses multi-require subject entries" do
    expect(described_class.parse_requires("ast/lexer -r ast/ast -r ast/type")).to eq(
      ["ast/lexer", "ast/ast", "ast/type"]
    )
  end

  it "does not append wildcards to method subjects" do
    expect(described_class.subject_expression("MIRLowering#lower")).to eq("MIRLowering#lower")
    expect(described_class.subject_expression("Lexer")).to eq("Lexer*")
  end

  it "honors explicit subject matcher expressions from the registry" do
    subject = described_class.subject_from_entry(
      "subject" => "Emitter.render_step",
      "expression" => "Emitter.render_step",
      "require" => "backends/emitter",
      "spec" => "spec/mutant_tools_spec.rb",
      "baseline" => 100.0
    )

    expect(subject.name).to eq("emitter-render-step")
    expect(subject.expression).to eq("Emitter.render_step")
  end

  it "selects class subjects by raw source name as well as slug" do
    opts = RubySpecMutants::Options.new(
      subject: "Lexer",
      since: nil,
      shard: nil,
      out: "/tmp/unused",
      list: false
    )

    expect(described_class.selected_subjects(opts).map(&:expression)).to include("Lexer*")
  end

  it "shards selected subjects deterministically" do
    opts = RubySpecMutants::Options.new(
      subject: nil,
      since: nil,
      shard: MutationTesting.parse_shard("2/4"),
      out: "/tmp/unused",
      list: false
    )

    selected = described_class.selected_subjects(opts)

    expect(selected).not_to be_empty
    expect(selected).to eq(described_class::SUBJECTS.each_with_index.filter_map { |subject, index| subject if (index % 4) == 2 })
  end

  it "blocks failing hard-gate subjects" do
    result = described_class.evaluate_summary(mutant_subject(hard_gate: true), mutant_summary(coverage: 80.0))

    expect(result.ok).to be(false)
    expect(result.blocking).to be(true)
  end

  it "reports failing advisory subjects without blocking the runner" do
    result = described_class.evaluate_summary(mutant_subject(hard_gate: false), mutant_summary(coverage: 80.0))

    expect(result.ok).to be(false)
    expect(result.blocking).to be(false)
  end

  it "treats zero selected mutations as a clean skip" do
    result = described_class.evaluate_summary(mutant_subject(hard_gate: true), mutant_summary(coverage: 100.0, mutations: 0, selected_tests: 0))

    expect(result.ok).to be(true)
    expect(result.blocking).to be(false)
  end

  it "keeps subject specs present on disk" do
    missing = described_class::SUBJECTS.reject { |subject| subject.specs.all? { |spec| File.file?(spec) } }

    expect(missing).to be_empty
  end
end
