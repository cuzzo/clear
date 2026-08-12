# frozen_string_literal: true

require "open3"
require "json"
require "rbconfig"
require "tmpdir"

RSpec.describe "ruby-to-clear CLI" do
  let(:exe) { File.expand_path("../exe/ruby-to-clear", __dir__) }

  it "prints usage for --help" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, exe, "--help")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("Usage: ruby-to-clear [--strict] [--helper-config path.json] [--cfg-facts path.json] [--typed-ir-report path.json] <file.rb>")
    expect(stderr).to eq("")
  end

  it "writes typed IR admission and consumption telemetry" do
    Dir.mktmpdir("ruby-to-clear-cli") do |dir|
      path = File.join(dir, "simple.rb")
      report_path = File.join(dir, "typed-ir.json")
      File.write(path, "def value\n  1\nend\n")

      _stdout, stderr, status = Open3.capture3(
        RbConfig.ruby, exe, "--typed-ir-report", report_path, path
      )

      expect(status).to be_success
      expect(stderr).to eq("")
      report = JSON.parse(File.read(report_path))
      expect(report.dig("aggregate", "functions")).to eq(1)
      expect(report.dig("aggregate", "admitted_functions")).to eq(0)
      expect(report.fetch("functions").first.fetch("reason")).to include("not supplied")
    end
  end

  it "emits CLEAR pattern strings for regex literals by default" do
    Dir.mktmpdir("ruby-to-clear-cli") do |dir|
      path = File.join(dir, "regex.rb")
      File.write(path, "pattern = /abc/\n")

      stdout, stderr, status = Open3.capture3(RbConfig.ruby, exe, path)

      expect(status).to be_success
      expect(stderr).to eq("")
      expect(stdout).to include('MUTABLE pattern = "abc";')
    end
  end

  it "preserves strict mode for callers that want unsupported syntax errors" do
    Dir.mktmpdir("ruby-to-clear-cli") do |dir|
      path = File.join(dir, "eval.rb")
      File.write(path, "eval('1 + 1')\n")

      _stdout, stderr, status = Open3.capture3(RbConfig.ruby, exe, "--strict", path)

      expect(status.exitstatus).to eq(1)
      expect(stderr).to include("dynamic evaluation")
    end
  end
end
