# frozen_string_literal: true
#
# Unit matrix for the gap-classification primitives that have no other
# coverage: collect_coverage_index, collect_ran? (open-interval
# bounds), untraceable_arg_kind?, and never_run_reason's lo-nil
# short-circuit. The closed never_run_reason tree itself is covered in
# nil_kill_spec.rb.

require_relative "spec_helper"

RSpec.describe NilKill::Report, "evidence-gap primitives" do
  subject(:report) { described_class.new }

  describe "#collect_coverage_index" do
    it "converts the collect_coverage dict to per-path Sets of Integers" do
      ev = { "facts" => { "collect_coverage" => { "src/a.rb" => %w[3 5], "src/b.rb" => [7] } } }
      idx = report.send(:collect_coverage_index, ev)
      expect(idx["src/a.rb"]).to eq(Set[3, 5])
      expect(idx["src/b.rb"]).to eq(Set[7])
      expect(idx["src/a.rb"]).to all(be_a(Integer))
    end

    it "returns nil when collect_coverage is absent or empty" do
      expect(report.send(:collect_coverage_index, { "facts" => {} })).to be_nil
      expect(described_class.new.send(:collect_coverage_index, { "facts" => { "collect_coverage" => {} } })).to be_nil
    end

    it "memoizes per Report instance" do
      ev = { "facts" => { "collect_coverage" => { "src/a.rb" => [1] } } }
      first = report.send(:collect_coverage_index, ev)
      ev["facts"]["collect_coverage"]["src/a.rb"] = [9]
      expect(report.send(:collect_coverage_index, ev)).to equal(first)
    end
  end

  describe "#collect_ran? (open interval, def line and end excluded)" do
    let(:idx) { { "f" => Set[10, 12, 15] } }

    it "is false when idx is nil" do
      expect(report.send(:collect_ran?, nil, "f", 1, 9)).to be(false)
    end

    it "is false when the file has no coverage entry" do
      expect(report.send(:collect_ran?, idx, "other", 1, 99)).to be(false)
    end

    it "excludes the def line (lower bound)" do
      expect(report.send(:collect_ran?, { "f" => Set[10] }, "f", 10, 15)).to be(false)
    end

    it "excludes the trailing end line (upper bound)" do
      expect(report.send(:collect_ran?, { "f" => Set[15] }, "f", 10, 15)).to be(false)
    end

    it "is true for a strictly interior covered line" do
      expect(report.send(:collect_ran?, idx, "f", 9, 16)).to be(true)
    end

    it "matches absolute static-fact paths against root-relative coverage" do
      path = File.join(NilKill::ROOT, "f")
      expect(report.send(:collect_ran?, idx, path, 9, 16)).to be(true)
    end

    it "is false for a 1-2 line body (empty interior, hi == lo+1)" do
      expect(report.send(:collect_ran?, { "f" => Set[10, 11] }, "f", 10, 11)).to be(false)
    end

    it "defaults hi to lo when hi is nil (no interior -> false)" do
      expect(report.send(:collect_ran?, { "f" => Set[10] }, "f", 10, nil)).to be(false)
    end
  end

  describe "#untraceable_arg_kind?" do
    it "is true for block-ish names and Proc-ish types, false for a real slot" do
      expect(report.send(:untraceable_arg_kind?, "block", "T.untyped")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "blk", "T.untyped")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "*rest", "T.untyped")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "&b", "T.untyped")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "on_block", "T.untyped")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "cb_blk", "T.untyped")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "f", "T.proc.void")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "f", "Proc")).to be(true)
      expect(report.send(:untraceable_arg_kind?, "f", "T.nilable(Proc)")).to be(true)
      # the negative: a real typeable positional is NOT excused
      expect(report.send(:untraceable_arg_kind?, "value", "Integer")).to be(false)
    end
  end

  describe "#never_run_reason lo-nil short-circuit" do
    it "never returns collect_ran_untraced when lo is nil (struct-field caller)" do
      ev = { "facts" => { "collect_coverage" => { "src/m.rb" => [10, 11] } } }
      expect(report.send(:never_run_reason, ev, "src/m.rb")).to eq("unseen")
    end
  end
end
