# frozen_string_literal: true
#
# THE PERMANENT CONTRACT. Property-level (survives corpus changes):
# over the collect's OWN Coverage, every interior-covered sampled
# method has a record or is excused (arg-untraceable / pruned) -- the
# exact contrapositive of collect_ran_untraced. Plus: the foreign
# SimpleCov baseline is gone and stays gone, and a deliberately
# mis-wired (uninstrumented) collect MUST violate the invariant
# (negative control -- proves it is not vacuously green).

require_relative "spec_helper"

RSpec.describe "evidence-gap invariant" do
  corpus = File.join(__dir__, "fixtures", "zero_gap_corpus")

  before(:context) do
    @positive_dir = Dir.mktmpdir("nk-inv", NilKill::ROOT)
    Dir.glob(File.join(corpus, "*_lib.rb")).each { |f| FileUtils.cp(f, @positive_dir) }
    @positive_corpus = full_collect(@positive_dir, File.read(File.join(corpus, "workload.rb")), instrument: true)
  end

  after(:context) do
    FileUtils.remove_entry(@positive_dir) if @positive_dir && File.directory?(@positive_dir)
  end

  it "INVARIANT: interior-covered sampled methods all have a record (0 exceptions)" do
    r = @positive_corpus
    # The report's own predicate: untyped_evidence_gaps RAISES if any
    # method ran-without-a-record (collect_ran_untraced) or there is
    # no collect coverage (never_run). On the in-place corpus it must
    # NOT raise, and the hard reasons must be absent from gaps.
    gaps = nil
    expect { gaps = r[:report].send(:untyped_evidence_gaps, r[:evidence]) }.not_to raise_error
    expect(gaps.keys & %w[collect_ran_untraced never_run]).to eq([])
    # Independent contrapositive cross-check, computed from raw
    # evidence (not the report): every method the workload called has
    # a runtime record. If a load path bypassed in-place recording
    # this fails even if the report classifier were buggy.
    recorded = r[:methods].select { |m| m["calls"].to_i.positive? }
                          .map { |m| [m["class"], m["method"]] }.to_set
    %w[PlainReq:transform AbsReq:walk AbsReq:run SubProc:in_child
       EnsurePunt:guarded StructColl:build KernelLoad:handle].each do |sig|
      cls, meth = sig.split(":")
      expect(recorded).to include([cls, meth]), "missing record for #{cls}##{meth}"
    end
  end

  it "INVARIANT: foreign baseline gone AND forbidden states are hard failures, not columns" do
    expect(NilKill::Report::EVIDENCE_GAP_REASONS.keys)
      .not_to include("untraced_covered", "collect_ran_untraced", "never_run")
    expect(NilKill::Report::EVIDENCE_GAP_HARD.keys)
      .to contain_exactly("collect_ran_untraced", "never_run")
    expect(NilKill::Report.const_defined?(:SIMPLECOV_RESULTSET)).to be(false)
    expect(NilKill::Report.new.respond_to?(:simplecov_covered_files, true)).to be(false)
  end

  it "INVARIANT: the rendered table has no forbidden column on the real corpus" do
    r = @positive_corpus
    lines = []
    r[:report].send(:append_untyped_evidence_gaps, lines, r[:evidence])
    header = lines.find { |l| l.start_with?("|  |") }
    next unless header
    expect(header).not_to include("collect ran untraced")
    expect(header).not_to include("untraced covered")
    expect(header).not_to include("never run")
  end

  it "NEGATIVE CONTROL: an uninstrumented collect makes infer/report RAISE (not silently zero)" do
    # skip "infer pipeline pending in Rust FactMine (Phase 3)"
    # Coverage marked bodies executed but the source-wrap recorder never
    # fired -> ran-without-a-record == collect_ran_untraced. The hard
    # guard fires inside Infer's own report generation, so the WHOLE
    # pipeline raises loudly -- a recording bypass cannot be silent. If
    # this didn't raise, the guarantee would be toothless.
    expect do
      Dir.mktmpdir("nk-inv-neg", NilKill::ROOT) do |dir|
        Dir.glob(File.join(corpus, "*_lib.rb")).each { |f| FileUtils.cp(f, dir) }
        full_collect(dir, File.read(File.join(corpus, "workload.rb")), instrument: false)
      end
    end.to raise_error(/collect_ran_untraced .* tracer\/trace-plan regression/)
  end
end
