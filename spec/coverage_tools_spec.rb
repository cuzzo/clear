require "tmpdir"
require "fileutils"

require_relative "../tools/loom_atomic_coverage"
require_relative "../tools/vopr_coverage"
require_relative "../tools/wait_loop_coverage"
require_relative "../tools/diff_bucket_summary"
require_relative "../tools/zig_coverage_support"

RSpec.describe "coverage gap tools" do
  around do |example|
    Dir.mktmpdir("coverage-tools") do |dir|
      @tmp = dir
      example.run
    end
  end

  it "does not count Loom atomics inside exclusion blocks or test files by default" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    File.write(File.join(@tmp, "zig/runtime/prod.zig"), <<~ZIG)
      pub fn covered(a: anytype) void {
          // LOOM-EXCLUDE-BEGIN
          _ = a.load(.acquire);
          // LOOM-EXCLUDE-END
          _ = a.store(1, .release);
      }
    ZIG
    File.write(File.join(@tmp, "zig/runtime/prod-test.zig"), <<~ZIG)
      test "ignored" {
          _ = a.load(.acquire);
      }
    ZIG

    sites = LoomAtomicCoverage.scan_atomic_sites(["zig/runtime"], @tmp)

    expect(sites.map { |s| [s[:file], s[:line]] }).to eq([["zig/runtime/prod.zig", 5]])
  end

  it "classifies Zig VOPR/Loom harness files as test code in diff buckets" do
    expect(bucket_for("zig/runtime/scheduler.zig")).to eq(:zig_src)
    expect(bucket_for("zig/runtime/scheduler-test.zig")).to eq(:zig_tests)
    expect(bucket_for("zig/runtime/scheduler-timeout-vopr.zig")).to eq(:zig_tests)
    expect(bucket_for("zig/runtime/parking-lot-loom.zig")).to eq(:zig_tests)
    expect(bucket_for("zig/vopr-loom-runner.zig")).to eq(:zig_tests)
    expect(bucket_for("zig/runtime/testing/loom-clock.zig")).to eq(:zig_tests)
  end

  it "sanitizes Zig coverage suite and run names for kcov directories" do
    expect(ZigCoverageSupport.sanitize_name("examples/benchmarks shard 1/5")).to eq("examples_benchmarks_shard_1_5")
    expect(ZigCoverageSupport.sanitize_name("///")).to eq("run")
  end

  it "excludes Zig test, VOPR, and Loom harness files from Codecov kcov reports" do
    pattern = ZigCoverageSupport::KCOV_CODECOV_EXCLUDE_PATTERN

    expect(pattern).to include("-test.zig")
    expect(pattern).to include("-vopr.zig")
    expect(pattern).to include("-loom.zig")
    expect(pattern).to include("/vopr-")
    expect(pattern).to include("/loom-")
  end

  it "resolves Zig coverage output roots from either env override or suite name" do
    old_dir = ENV.delete("ZIG_COVERAGE_DIR")
    old_suite = ENV.delete("ZIG_COVERAGE_SUITE")
    begin
      ENV["ZIG_COVERAGE_SUITE"] = "fuzz shard"
      expect(ZigCoverageSupport.output_root("default")).to end_with("/zig/zig-out/coverage-fuzz_shard")

      ENV["ZIG_COVERAGE_DIR"] = "tmp/custom-zig-coverage"
      expect(ZigCoverageSupport.output_root("default")).to eq(File.expand_path("../tmp/custom-zig-coverage", __dir__))
    ensure
      old_dir ? ENV["ZIG_COVERAGE_DIR"] = old_dir : ENV.delete("ZIG_COVERAGE_DIR")
      old_suite ? ENV["ZIG_COVERAGE_SUITE"] = old_suite : ENV.delete("ZIG_COVERAGE_SUITE")
    end
  end

  it "expands kcov Cobertura to track meaningful Zig source lines omitted from DWARF" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    File.write(File.join(@tmp, "zig/runtime/foo.zig"), <<~ZIG)
      // full-line comment is not coverage debt
      pub fn foo() void {
          const x = 1;
          _ = x;
      }
    ZIG
    xml = File.join(@tmp, "cobertura.xml")
    File.write(xml, <<~XML)
      <?xml version="1.0" ?>
      <coverage line-rate="1.0" lines-covered="1" lines-valid="1">
        <packages>
          <package name="" line-rate="1.0">
            <classes>
              <class name="foo" filename="runtime/foo.zig" line-rate="1.0">
                <lines>
                  <line number="2" hits="1"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML

    ZigCoverageSupport.expand_cobertura!(xml, zig_dir: File.join(@tmp, "zig"))

    doc = REXML::Document.new(File.read(xml))
    lines = REXML::XPath.match(doc, "//class/lines/line").map { |line| [line.attributes["number"].to_i, line.attributes["hits"].to_i] }
    expect(lines).to eq([[2, 1], [3, 0], [4, 0], [5, 0]])
    expect(REXML::XPath.first(doc, "/coverage").attributes["lines-valid"]).to eq("4")
    expect(REXML::XPath.first(doc, "/coverage").attributes["lines-covered"]).to eq("1")
  end

  it "excludes VOPR and Loom harness files from Loom and VOPR scanners" do
    loom_excluded = %w[
      foo-test.zig
      foo-vopr.zig
      foo-loom.zig
      vopr-clock.zig
      loom-clock.zig
    ]
    vopr_excluded = loom_excluded + ["foo-bench.zig"]

    expect(loom_excluded).to all(match(LoomAtomicCoverage::TEST_FILE_RE))
    expect(vopr_excluded).to all(match(VoprCoverage::TEST_FILE_RE))
    expect("scheduler.zig").not_to match(LoomAtomicCoverage::TEST_FILE_RE)
    expect("scheduler.zig").not_to match(VoprCoverage::TEST_FILE_RE)
  end

  it "does not classify control-flow atomic lines as kcov-elided false positives" do
    source = "if (entry.recommended.cmpxchgWeak(old, target, .release, .monotonic)) |_| {"
    file_hits = { 10 => 1, 11 => 0, 12 => 1 }

    expect(LoomAtomicCoverage.classify_artifact(file_hits, 11, source)).to be(false)
  end

  it "does classify simple inline atomic statement lines as kcov-elided when both neighbors ran" do
    source = "entry.downsized.store(true, .release);"
    file_hits = { 10 => 1, 11 => 0, 12 => 1 }

    expect(LoomAtomicCoverage.classify_artifact(file_hits, 11, source)).to be(true)
  end

  it "attributes VOPR retry markers on comments to the following executable line" do
    site = {
      file: "zig/runtime/foo.zig",
      line: 10,
      source: "// VOPR-START-RETRY: synthetic",
      category: :retry,
    }
    hits = { "zig/runtime/foo.zig" => { 11 => 3 } }

    correlated = VoprCoverage.correlate([site], hits)

    expect(correlated.fetch(0)[:hits]).to eq(3)
  end

  it "flags stale wait-loop hammer covers instead of silently passing them" do
    loop = WaitLoopCoverage::Loop.new(tag: "real.loop", file: "zig/runtime/x.zig", begin_line: 1, end_line: 3)
    cover = WaitLoopCoverage::Cover.new(tag: "stale.loop", file: "zig/foo-hammer-test.zig", line: 1)

    expect {
      @result = WaitLoopCoverage.report(
        WaitLoopCoverage.correlate([loop], [cover]),
        [cover],
        all: false,
        summary_only: true,
      )
    }.to output(/stale HAMMER-COVERS: 1/).to_stdout
    expect(@result).to eq([1, 1])
  end
end
