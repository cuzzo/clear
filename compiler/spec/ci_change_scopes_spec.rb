# frozen_string_literal: true

require "tmpdir"

require_relative "../../tools/ci_change_scopes"

RSpec.describe CIChangeScopes do
  def classify(paths)
    described_class.classify(paths).to_h
  end

  it "runs only gem scope for non-markdown gem changes" do
    expect(classify(["gems/nil-kill/lib/nil_kill.rb"])).to eq(
      "run_gems" => true,
      "run_src" => false,
      "run_zig" => false
    )
  end

  it "runs only src scope for non-markdown compiler/ruby changes" do
    expect(classify(["compiler/ruby/annotator/annotator.rb"])).to eq(
      "run_gems" => false,
      "run_src" => true,
      "run_zig" => false
    )
  end

  it "runs src and zig scopes for Zig changes" do
    expect(classify(["zig/runtime/scheduler.zig"])).to eq(
      "run_gems" => false,
      "run_src" => true,
      "run_zig" => true
    )
  end

  it "ignores markdown-only changes under scoped directories" do
    expect(classify([
      "compiler/ruby/README.md",
      "gems/nil-kill/docs/agents/plan.md",
      "zig/runtime/README.md",
    ])).to eq(
      "run_gems" => false,
      "run_src" => false,
      "run_zig" => false
    )
  end

  it "runs Ruby scopes for dependency and type config changes" do
    expect(classify(["Gemfile.lock", "sorbet/rbi/custom.rbi"])).to eq(
      "run_gems" => true,
      "run_src" => true,
      "run_zig" => false
    )
  end

  it "runs full scope for workflow or unknown non-markdown changes" do
    expect(classify([".github/workflows/ci.yml"])).to eq(
      "run_gems" => true,
      "run_src" => true,
      "run_zig" => true
    )
    expect(classify(["package.json"])).to eq(
      "run_gems" => true,
      "run_src" => true,
      "run_zig" => true
    )
  end

  it "writes GitHub Actions boolean outputs" do
    Dir.mktmpdir("ci-change-scopes") do |dir|
      output = File.join(dir, "github-output")
      described_class.write_github_outputs(
        CIChangeScopes::Scope.new(run_gems: true, run_src: false, run_zig: true),
        output
      )

      expect(File.read(output).lines.map(&:chomp)).to eq([
        "run_gems=true",
        "run_src=false",
        "run_zig=true",
      ])
    end
  end
end
