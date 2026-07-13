# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AutoType::CLI do
  it "runs when RubyGems loads the executable through its generated wrapper" do
    executable = File.expand_path("../exe/auto-type", __dir__)
    stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      "-e",
      "path = ARGV.fetch(0); $PROGRAM_NAME = 'rubygems-wrapper'; ARGV.replace(['help']); load path",
      executable,
    )

    expect(status).to be_success
    expect(stderr).to be_empty
    expect(stdout).to include("bundle exec auto-type apply")
  end

  it "prints Auto-type command help" do
    expect {
      described_class.new(["help"]).run
    }.to output(/bundle exec auto-type apply/).to_stdout
  end

  it "rejects unknown commands" do
    expect {
      described_class.new(["collect"]).run
    }.to raise_error(SystemExit).and output(/unknown command: collect/).to_stderr
  end
end

RSpec.describe AutoType::Providers do
  it "plans Ruby actions and rejects unsupported languages" do
    ruby_action = {
      "kind" => "fix_sig_return",
      "language" => "ruby",
      "confidence" => "high",
      "path" => "src/example.rb",
      "line" => 1,
      "data" => { "type" => "String" },
    }
    python_action = ruby_action.merge("language" => "python")

    ruby = described_class.provider_for("ruby")
    python = described_class.provider_for("python")
    ruby_plan = ruby.plan(ruby_action, workspace: AutoType::Workspace.new)
    python_plan = python.plan(python_action, workspace: AutoType::Workspace.new)

    expect(ruby.supports?(ruby_action)).to be(true)
    expect(ruby_plan).to be_supported
    expect(ruby_plan.legacy_actions).to eq([ruby_action])
    expect(ruby.capabilities["action_kinds"]).to include("fix_sig_return")
    expect(python.supports?(python_action)).to be(false)
    expect(python_plan).not_to be_supported
    expect(python_plan.diagnostics.first["code"]).to eq("unsupported_auto_type_provider")
  end

  it "uses schema-v2 target language for provider support checks" do
    action = {
      "schema_version" => 2,
      "kind" => "fix_sig_return",
      "confidence" => "high",
      "target" => { "language" => "python", "path" => "pkg/user.py", "line" => 1 },
      "data" => { "type" => "str" },
    }

    provider = described_class.provider_for(action.dig("target", "language"))
    plan = provider.plan(action, workspace: AutoType::Workspace.new)

    expect(plan).not_to be_supported
    expect(plan.diagnostics.first["language"]).to eq("python")
  end

  it "advertises the narrow Python add_nullability provider" do
    provider = described_class.provider_for("python")

    expect(described_class.registry.languages).to include("python")
    expect(provider.capabilities).to include(
      "language" => "python",
      "plan_kind" => "text_edits",
      "nilability_style" => "pep604",
    )
    expect(provider.capabilities["action_kinds"]).to eq(["add_nullability"])
  end
end
