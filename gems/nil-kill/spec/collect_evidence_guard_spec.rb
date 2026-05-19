# frozen_string_literal: true
#
# CORR-1/2/2b: a broken collect created empty/partial coverage-*.jsonl
# /methods-*.jsonl. The old guard only checked file existence, so
# zero-byte files (total collapse, CORR-2) and a per-stage collapse
# masked by other stages (CORR-2b) both passed and infer ran on bad
# evidence. The guard must check content AND per-PID consistency.

require_relative "spec_helper"

RSpec.describe "collect evidence guard" do
  let(:cli) { NilKill::CLI.allocate }

  # files: { "1" => [cov_bytes, meth_bytes], ... } keyed by fake pid
  def stub_evidence(files)
    cov = files.map { |pid, (c, _)| ["coverage-#{pid}.jsonl", c] }.to_h
    meth = files.map { |pid, (_, m)| ["methods-#{pid}.jsonl", m] }.to_h
    allow(Dir).to receive(:glob).with(/coverage-\*\.jsonl/).and_return(cov.keys)
    allow(Dir).to receive(:glob).with(/methods-\*\.jsonl/).and_return(meth.keys)
    allow(File).to receive(:size) { |f| cov.merge(meth).fetch(f) }
  end

  it "aborts when coverage and methods are all zero-byte (total collapse)" do
    stub_evidence("1" => [0, 0])
    expect { cli.send(:assert_collect_coverage_produced!) }.to raise_error(SystemExit)
  end

  it "aborts when methods evidence is empty though coverage has content" do
    stub_evidence("1" => [4096, 0])
    expect { cli.send(:assert_collect_coverage_produced!) }.to raise_error(SystemExit)
  end

  it "passes when the single process holds both coverage and methods" do
    stub_evidence("1" => [4096, 8192])
    expect { cli.send(:assert_collect_coverage_produced!) }.not_to raise_error
  end

  it "aborts when the MAJORITY of traced processes have coverage but zero methods (CORR-2b partial collapse)" do
    stub_evidence("1" => [4096, 0], "2" => [4096, 0], "3" => [4096, 8192])
    expect { cli.send(:assert_collect_coverage_produced!) }.to raise_error(SystemExit, /systemic instrumentation abort/)
  end

  it "tolerates a minority straggler (fault-tolerant by design)" do
    stub_evidence("1" => [4096, 8192], "2" => [4096, 8192], "3" => [4096, 0])
    expect { cli.send(:assert_collect_coverage_produced!) }.not_to raise_error
  end
end
