# frozen_string_literal: true
#
# Regression for CORR-1/CORR-2: a broken collect created empty
# coverage-*.jsonl/methods-*.jsonl files; the old guard only checked
# file existence (Dir.glob(...).empty?), so zero-byte files passed it
# and infer ran on no evidence. The guard must check content.

require_relative "spec_helper"

RSpec.describe "collect evidence guard" do
  let(:cli) { NilKill::CLI.allocate }

  def stub_evidence(coverage_bytes:, methods_bytes:)
    cov = { "coverage-1.jsonl" => coverage_bytes }
    meth = { "methods-1.jsonl" => methods_bytes }
    allow(Dir).to receive(:glob).with(/coverage-\*\.jsonl/).and_return(cov.keys)
    allow(Dir).to receive(:glob).with(/methods-\*\.jsonl/).and_return(meth.keys)
    allow(File).to receive(:size) { |f| cov.merge(meth).fetch(f) }
  end

  it "aborts when coverage and methods files exist but are zero-byte" do
    stub_evidence(coverage_bytes: 0, methods_bytes: 0)
    expect { cli.send(:assert_collect_coverage_produced!) }.to raise_error(SystemExit)
  end

  it "aborts when methods evidence is empty even though coverage has content" do
    stub_evidence(coverage_bytes: 4096, methods_bytes: 0)
    expect { cli.send(:assert_collect_coverage_produced!) }.to raise_error(SystemExit)
  end

  it "passes only when both coverage and methods hold content" do
    stub_evidence(coverage_bytes: 4096, methods_bytes: 8192)
    expect { cli.send(:assert_collect_coverage_produced!) }.not_to raise_error
  end
end
