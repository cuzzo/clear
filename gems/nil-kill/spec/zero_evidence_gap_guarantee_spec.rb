# frozen_string_literal: true
#
# THE GATE. A hermetic end-to-end collect over a fixture corpus that
# exercises every load path (plain require, require_relative,
# Kernel#load, autoload, absolute require, a spawned-ruby subprocess,
# the recursive-from-.each collect_bg_blocks shape, an ensure-punt, an
# endless def, splat/kwsplat/block slots, a Struct field, a T.let, a
# collection). It asserts the report's "Untyped Evidence Gaps" table
# has EXACTLY ZERO `collect_ran_untraced` and `untraced_covered`, and
# that every traceable sampled method produced a runtime record. A red
# here means the architecture regressed.

require_relative "spec_helper"

RSpec.describe "zero-gap end-to-end guarantee", :zero_gap_guarantee do
  corpus = File.join(__dir__, "fixtures", "zero_gap_corpus")

  # Class#method for every sampled (T.untyped-slot) method the workload
  # calls. arg-only-untraceable slots (handle's *rest/**kw/&blk) still
  # produce a `handle` record via its real `opts` slot.
  EXPECTED = [
    %w[PlainReq transform], %w[RelReq calc], %w[KernelLoad handle],
    %w[AutoLib one_line], %w[AbsReq walk], %w[AbsReq run],
    %w[SubProc in_child], %w[EnsurePunt guarded], %w[StructColl build],
  ].freeze

  around do |example|
    Dir.mktmpdir("nk-zero-gap", NilKill::ROOT) do |dir|
      Dir.glob(File.join(corpus, "*_lib.rb")).each { |f| FileUtils.cp(f, dir) }
      @r = full_collect(dir, File.read(File.join(corpus, "workload.rb")))
      example.run
    end
  end

  # Lazily classify: untyped_evidence_gaps RAISES if a collect_ran_untraced
  # or never_run ever appears (they are hard failures, not columns), so
  # calling it here is itself the zero-tracer-bug / real-collect assertion.
  def gaps
    @gaps ||= @r[:report].send(:untyped_evidence_gaps, @r[:evidence])
  end

  it "the collect child completes under the tracer for every load path" do
    expect(@r[:status]).to be_success, @r[:err]
  end

  it "produces collect_coverage facts (Coverage + linemap wired through)" do
    cc = @r[:evidence].dig("facts", "collect_coverage")
    expect(cc).to be_a(Hash)
    expect(cc).not_to be_empty
  end

  it "records EVERY traceable method, whatever load path reached it" do
    by = @r[:methods].group_by { |m| [m["class"], m["method"]] }
    missing = EXPECTED.reject do |cls, meth|
      recs = by[[cls, meth]]
      recs && recs.sum { |m| m["calls"].to_i }.positive?
    end
    expect(missing).to be_empty,
      "no runtime record for: #{missing.map { |c, m| "#{c}##{m}" }.join(", ")} " \
      "(a load path bypassed in-place recording). methods seen: " \
      "#{by.keys.map { |c, m| "#{c}##{m}" }.sort.join(", ")}"
  end

  it "GUARANTEE: no collect_ran_untraced / never_run -- classification does not raise on the real corpus" do
    # The in-place tracer recorded everything that ran and the collect
    # produced Coverage; if either were false, untyped_evidence_gaps
    # would RAISE here (hard failure, not a silently-zero column).
    expect { gaps }.not_to raise_error
    expect(gaps.keys & %w[collect_ran_untraced never_run untraced_covered]).to eq([])
  end

  it "GUARANTEE: the forbidden states are NOT columns -- they are hard failures" do
    expect(NilKill::Report::EVIDENCE_GAP_REASONS.keys)
      .not_to include("collect_ran_untraced", "never_run", "untraced_covered")
    expect(NilKill::Report::EVIDENCE_GAP_HARD.keys)
      .to contain_exactly("collect_ran_untraced", "never_run")
    lines = []
    @r[:report].send(:append_untyped_evidence_gaps, lines, @r[:evidence])
    header = lines.find { |l| l.start_with?("|  |") }
    expect(header).not_to include("collect ran untraced") if header
    expect(header).not_to include("untraced covered") if header
    expect(header).not_to include("never run") if header
    expect(gaps.keys - NilKill::Report::EVIDENCE_GAP_REASONS.keys).to eq([])
  end

  it "block/splat/kwsplat slots are arg_untraced, never a forbidden state" do
    expect(gaps["arg_untraced"].map { |g| g["text"] }).to include(a_string_matching(/`(rest|kw|blk)`/))
    expect(gaps.fetch("collect_ran_untraced", [])).to eq([])
    expect(gaps.fetch("never_run", [])).to eq([])
  end
end
