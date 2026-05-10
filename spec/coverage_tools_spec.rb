require "tmpdir"
require "fileutils"

require_relative "../tools/loom_atomic_coverage"
require_relative "../tools/vopr_coverage"
require_relative "../tools/wait_loop_coverage"

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
