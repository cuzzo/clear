# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe AutoType::CLI do
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

    expect(ruby.supports?(ruby_action)).to be(true)
    expect(ruby.plan(ruby_action)).to include("supported" => true, "actions" => [ruby_action])
    expect(python.supports?(python_action)).to be(false)
    expect(python.plan(python_action).dig("diagnostics", 0, "code")).to eq("unsupported_auto_type_provider")
  end
end
