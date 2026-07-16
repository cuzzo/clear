# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "tmpdir"

RSpec.describe "generalized SARIF generator tool selection" do
  let(:root) { File.expand_path("../..", __dir__) }
  let(:script) { File.join(root, "tools", "generate_generalized_gem_sarif.rb") }

  %w[decomplex boobytrap slopcop espalier nil-kill].each do |tool|
    it "generates only #{tool} artifacts when selected" do
      Dir.mktmpdir("#{tool}-sarif") do |out_dir|
        _stdout, stderr, status = Open3.capture3(
          RbConfig.ruby,
          script,
          "--repo=#{root}",
          "--base=HEAD",
          "--head=HEAD",
          "--out-dir=#{out_dir}",
          "--only=#{tool}"
        )

        expect(status).to be_success, stderr
        expect(Dir.children(out_dir).sort).to eq(["#{tool}.md", "#{tool}.sarif"])
        sarif = JSON.parse(File.read(File.join(out_dir, "#{tool}.sarif")))
        expect(sarif.fetch("version")).to eq("2.1.0")
        expect(sarif.fetch("runs")).to contain_exactly(include("results" => []))
      end
    end
  end

  it "rejects unknown producers instead of silently running every analyzer" do
    _stdout, stderr, status = Open3.capture3(
      RbConfig.ruby,
      script,
      "--repo=#{root}",
      "--base=HEAD",
      "--head=HEAD",
      "--only=unknown"
    )

    expect(status).not_to be_success
    expect(stderr).to include("invalid argument")
  end
end
