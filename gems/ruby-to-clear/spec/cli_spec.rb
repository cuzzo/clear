# frozen_string_literal: true

require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "ruby-to-clear CLI" do
  let(:exe) { File.expand_path("../exe/ruby-to-clear", __dir__) }

  it "prints usage for --help" do
    stdout, stderr, status = Open3.capture3(RbConfig.ruby, exe, "--help")

    expect(status.exitstatus).to eq(1)
    expect(stdout).to include("Usage: ruby-to-clear [--strict] [--helper-config path.json] <file.rb>")
    expect(stderr).to eq("")
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
