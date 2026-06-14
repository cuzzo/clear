# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AutoType::Workspace do
  it "applies non-overlapping byte-span edits and supports snapshot restore" do
    Dir.mktmpdir("auto-type-workspace", NilKill::ROOT) do |dir|
      rel = Pathname.new(File.join(dir, "sample.rb")).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
      File.write(File.join(NilKill::ROOT, rel), "alpha beta gamma\n")
      workspace = described_class.new
      snapshot = workspace.snapshot([rel])

      changed = workspace.apply_text_edits(rel, [
        AutoType::TextEdit.new(path: rel, start_offset: 0, end_offset: 5, replacement: "one"),
        AutoType::TextEdit.new(path: rel, start_offset: 6, end_offset: 10, replacement: "two"),
      ])

      expect(changed).to be(true)
      expect(workspace.read(rel)).to eq("one two gamma\n")
      workspace.restore(snapshot)
      expect(workspace.read(rel)).to eq("alpha beta gamma\n")
    end
  end

  it "rejects paths outside the workspace and overlapping text edits" do
    workspace = described_class.new
    expect { workspace.absolute_path("/tmp/outside.rb") }.to raise_error(ArgumentError, /escapes workspace root/)
    edits = [
      AutoType::TextEdit.new(path: "src/x.rb", start_offset: 0, end_offset: 5, replacement: "a"),
      AutoType::TextEdit.new(path: "src/x.rb", start_offset: 3, end_offset: 8, replacement: "b"),
    ]
    expect { workspace.non_overlapping_edits(edits) }.to raise_error(ArgumentError, /overlapping/)
  end
end

RSpec.describe AutoType::RewritePlan do
  it "records support, diagnostics, edits, legacy actions, and verifier risk" do
    edit = AutoType::TextEdit.new(path: "src/x.rb", start_offset: 0, end_offset: 1, replacement: "y")
    plan = described_class.new(
      provider: "TestProvider",
      language: "ruby",
      supported: true,
      diagnostics: [{ "message" => "ok" }],
      text_edits: [edit],
      legacy_actions: [{ "kind" => "fix_sig_return" }],
      risk: "review",
      requires_verifier: true,
    )

    expect(plan).to be_supported
    expect(plan).to be_edit
    expect(plan).to be_legacy
    expect(plan).to be_requires_verifier
    expect(plan.to_h).to include("risk" => "review", "language" => "ruby")
  end
end

RSpec.describe AutoType::Apply do
  it "skips unsupported language actions instead of applying Ruby rewrites" do
    _path, rel = repo_tmp_file("unsupported_provider.rb", <<~RUBY)
      class Example
        sig { returns(T.untyped) }
        def label
          "hello"
        end
      end
    RUBY
    action = {
      "kind" => "fix_sig_return",
      "language" => "python",
      "confidence" => "high",
      "path" => rel,
      "line" => 2,
      "data" => { "type" => "String" },
    }

    expect {
      changed = described_class.new([]).apply_actions([action])
      expect(changed).to eq(0)
    }.to output(/unsupported_auto_type_provider|no Auto-type provider supports fix_sig_return for python/).to_stderr
    expect(File.read(File.join(NilKill::ROOT, rel))).to include("returns(T.untyped)")
  end

  it "applies multiple Python add_nullability edits from original source offsets" do
    _path, rel = repo_tmp_file("python_nullability.py", <<~PYTHON)
      class User:
          def name(self, fallback: str) -> str:
              return fallback
    PYTHON

    changed = described_class.new(["--all"]).apply_actions([
      {
        "schema_version" => 2,
        "kind" => "add_nullability",
        "language" => "python",
        "confidence" => "review",
        "target" => { "language" => "python", "path" => rel, "line" => 2 },
        "data" => { "slot" => "param", "name" => "fallback", "declared_type" => "str" },
      },
      {
        "schema_version" => 2,
        "kind" => "add_nullability",
        "language" => "python",
        "confidence" => "review",
        "target" => { "language" => "python", "path" => rel, "line" => 2 },
        "data" => { "slot" => "return", "declared_type" => "str" },
      },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(changed).to eq(2)
    expect(source).to include("def name(self, fallback: str | None) -> str | None:")
  end

  it "applies Python add_nullability to annotated fields and stubs" do
    _path, rel = repo_tmp_file("python_model.pyi", <<~PYTHON)
      class User:
          label: str
          def fallback(self, value: str) -> str: ...
    PYTHON

    changed = described_class.new(["--all"]).apply_actions([
      {
        "schema_version" => 2,
        "kind" => "add_nullability",
        "language" => "python",
        "confidence" => "review",
        "target" => { "language" => "python", "path" => rel, "line" => 2 },
        "data" => { "slot" => "field", "name" => "@label", "declared_type" => "str" },
      },
      {
        "schema_version" => 2,
        "kind" => "add_nullability",
        "language" => "python",
        "confidence" => "review",
        "target" => { "language" => "python", "path" => rel, "line" => 3 },
        "data" => { "slot" => "param", "name" => "value", "declared_type" => "str" },
      },
    ])

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(changed).to eq(2)
    expect(source).to include("label: str | None")
    expect(source).to include("fallback(self, value: str | None) -> str")
  end

  it "skips unsafe Python nullability rewrites with diagnostics" do
    _path, rel = repo_tmp_file("python_skip_nullability.py", <<~PYTHON)
      def already(value: str | None) -> str:
          return value or ""

      def forward_ref(value: "User") -> "User":
          return value
    PYTHON
    applier = described_class.new(["--all"])

    expect {
      changed = applier.apply_actions([
        {
          "schema_version" => 2,
          "kind" => "add_nullability",
          "language" => "python",
          "confidence" => "review",
          "target" => { "language" => "python", "path" => rel, "line" => 1 },
          "data" => { "slot" => "param", "name" => "value", "declared_type" => "str | None" },
        },
        {
          "schema_version" => 2,
          "kind" => "add_nullability",
          "language" => "python",
          "confidence" => "review",
          "target" => { "language" => "python", "path" => rel, "line" => 4 },
          "data" => { "slot" => "param", "name" => "value", "declared_type" => "\"User\"" },
        },
        {
          "schema_version" => 2,
          "kind" => "add_nullability",
          "language" => "python",
          "confidence" => "review",
          "target" => { "language" => "python", "path" => rel, "line" => 4 },
          "data" => { "slot" => "return", "declared_type" => "RenamedUser" },
        },
      ])
      expect(changed).to eq(0)
    }.to output(/python_annotation_already_nullable|python_string_annotation|python_annotation_type_mismatch/).to_stderr

    source = File.read(File.join(NilKill::ROOT, rel))
    expect(source).to include("value: str | None")
    expect(source).to include("value: \"User\"")
    expect(source).to include("-> \"User\"")
  end
end
