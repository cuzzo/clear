require "tmpdir"
require "fileutils"
require "pathname"

require_relative "../tools/loom_atomic_coverage"
require_relative "../tools/vopr_coverage"
require_relative "../tools/wait_loop_coverage"
require_relative "../tools/diff_bucket_summary"
require_relative "../tools/zig_coverage_support"
require_relative "../tools/zig_coverage_sanitize"
require_relative "../tools/zig_coverage_visibility"
require_relative "../tools/zig_dwarf_line_audit"

RSpec.describe "coverage gap tools" do
  around do |example|
    Dir.mktmpdir("coverage-tools") do |dir|
      @tmp = dir
      example.run
    end
  end

  def write_cobertura(path, filename, hits_by_line)
    File.write(path, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="zig">
            <classes>
              <class name="prod" filename="#{filename}">
                <lines>
                  #{hits_by_line.map { |line, hits| %(<line number="#{line}" hits="#{hits}"/>) }.join("\n")}
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML
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

  it "does not count non-executable Ruby additions in diff line coverage" do
    source_path = File.join(@tmp, "ruby_probe.rb")
    File.write(source_path, <<~RUBY)
      # documentation line

      end
      covered_call
      uncovered_call
    RUBY
    rel_path = Pathname.new(source_path).relative_path_from(Pathname.new(ROOT)).to_s
    coverage_path = File.join(@tmp, "ruby-resultset.json")
    File.write(coverage_path, JSON.generate(
      "coverage-tools" => {
        "coverage" => {
          File.join(ROOT, rel_path) => {
            "lines" => [0, 0, 0, 1, 0],
            "branches" => {},
          },
        },
      },
    ))
    old_paths = ENV["RUBY_COVERAGE_PATHS"]
    ENV["RUBY_COVERAGE_PATHS"] = coverage_path

    begin
      expect(ruby_added_coverage({ rel_path => Set[1, 2, 3, 4, 5] }, [rel_path])).to eq(["50.0%", "N/A"])
    ensure
      old_paths ? ENV["RUBY_COVERAGE_PATHS"] = old_paths : ENV.delete("RUBY_COVERAGE_PATHS")
    end
  end

  it "alerts when an added production Zig atomic site lacks merged coverage evidence" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/prod.zig")
    File.write(source_path, <<~ZIG)
      pub fn run(state: anytype) void {
          _ = state.load(.acquire);
      }
    ZIG
    coverage_xml = File.join(@tmp, "cobertura.xml")
    write_cobertura(coverage_xml, "zig/runtime/prod.zig", 2 => 0)

    alerts = special_coverage_alerts(
      { "zig/runtime/prod.zig" => Set[2] },
      root: @tmp,
      cov_paths: [coverage_xml],
    )

    expect(alerts.map { |alert| alert[:rule] }).to include("loom")
    expect(alerts.first[:finding]).to include("atomic")
  end

  it "does not alert on an added production Zig atomic site with merged coverage evidence" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/prod.zig")
    File.write(source_path, <<~ZIG)
      pub fn run(state: anytype) void {
          _ = state.store(1, .release);
      }
    ZIG
    coverage_xml = File.join(@tmp, "cobertura.xml")
    write_cobertura(coverage_xml, "zig/runtime/prod.zig", 2 => 1)

    alerts = special_coverage_alerts(
      { "zig/runtime/prod.zig" => Set[2] },
      root: @tmp,
      cov_paths: [coverage_xml],
    )

    expect(alerts).to be_empty
  end

  it "alerts when an added production Zig VOPR-relevant site lacks merged coverage evidence" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/prod.zig")
    File.write(source_path, <<~ZIG)
      pub fn run() i64 {
          return milliTimestamp();
      }
    ZIG
    coverage_xml = File.join(@tmp, "cobertura.xml")
    write_cobertura(coverage_xml, "zig/runtime/prod.zig", 2 => 0)

    alerts = special_coverage_alerts(
      { "zig/runtime/prod.zig" => Set[2] },
      root: @tmp,
      cov_paths: [coverage_xml],
    )

    expect(alerts.map { |alert| alert[:rule] }).to include("vopr")
    expect(alerts.first[:finding]).to include("Time")
  end

  it "requires added wait-loop markers to have a hammer cover" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    File.write(File.join(@tmp, "zig/runtime/prod.zig"), <<~ZIG)
      pub fn run() void {
          // HAMMER-WAIT-LOOP-BEGIN: tag=prod.wait
          while (true) {}
          // HAMMER-WAIT-LOOP-END: tag=prod.wait
      }
    ZIG

    alerts = special_coverage_alerts(
      { "zig/runtime/prod.zig" => Set[2] },
      root: @tmp,
      cov_paths: [],
    )

    expect(alerts.map { |alert| alert[:rule] }).to include("wait_loop")
    expect(alerts.first[:finding]).to include("prod.wait")
  end

  it "accepts added wait-loop markers with a matching hammer cover" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    File.write(File.join(@tmp, "zig/runtime/prod.zig"), <<~ZIG)
      pub fn run() void {
          // HAMMER-WAIT-LOOP-BEGIN: tag=prod.wait
          while (true) {}
          // HAMMER-WAIT-LOOP-END: tag=prod.wait
      }
    ZIG
    File.write(File.join(@tmp, "zig/runtime/prod-hammer-test.zig"), <<~ZIG)
      // HAMMER-COVERS: prod.wait
      test "covers wait" {}
    ZIG

    alerts = special_coverage_alerts(
      { "zig/runtime/prod.zig" => Set[2] },
      root: @tmp,
      cov_paths: [],
    )

    expect(alerts).to be_empty
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

  it "sanitizes Cobertura XML inside hidden kcov run directories" do
    source_path = File.join(ZigCoverageSanitizer::ROOT, ZigCoverageSanitizer::RUNTIME_HEADER_SOURCE)
    source_lines = File.readlines(source_path)
    start_index = source_lines.index { |line| line.include?("fn socketAccept") }
    hit_line = source_lines.each_with_index.drop(start_index).find { |line, _idx| line.include?("getCurrent") }.last + 1
    kcov_root = File.join(@tmp, "coverage-fuzz", "all-fuzz")
    hidden_run = File.join(kcov_root, ".zig-coverage-all-fuzz-123")
    merged_run = File.join(kcov_root, "merged", "kcov-merged")
    FileUtils.mkdir_p(hidden_run)
    FileUtils.mkdir_p(merged_run)
    hidden_xml = File.join(hidden_run, "cobertura.xml")
    merged_xml = File.join(merged_run, "cobertura.xml")
    orphan_xml = <<~XML
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="runtime-header" filename="runtime/runtime-header.zig">
                <lines>
                  <line number="#{hit_line}" hits="1"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML
    File.write(hidden_xml, orphan_xml)
    File.write(merged_xml, orphan_xml)

    expect(ZigCoverageSupport.coverage_xml_paths(kcov_root)).to eq([hidden_xml, merged_xml])
    allow(ZigCoverageSanitizer).to receive(:symbol_names_for).and_return([])

    ZigCoverageSupport.sanitize_coverage_run!(kcov_root, File.join(@tmp, "zig-test-bin"))

    sanitized = REXML::Document.new(File.read(hidden_xml))
    remaining = REXML::XPath.match(sanitized, "//class[@filename='runtime/runtime-header.zig']/lines/line")
    expect(remaining).to be_empty
    marker = File.join(kcov_root, ZigCoverageSupport::SANITIZER_REMOVALS_FILE)
    marker_rows = JSON.parse(File.read(marker))
    expect(marker_rows.map { |row| [row.fetch("file"), row.fetch("function"), row.fetch("line")] }).to eq([
      ["runtime/runtime-header.zig", "socketAccept", hit_line],
    ])
    expect(ZigCoverageSupport.proof_backed_removal_keys(File.dirname(kcov_root))).to eq(
      ZigCoverageSanitizer.removal_key("runtime/runtime-header.zig", "socketAccept", hit_line) => true,
    )
    merged = REXML::Document.new(File.read(merged_xml))
    merged_lines = REXML::XPath.match(merged, "//class[@filename='runtime/runtime-header.zig']/lines/line")
    expect(merged_lines).to be_empty
  end

  it "does not remove orphan runtime-header hits without binary provenance" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/runtime-header.zig")
    File.write(source_path, <<~ZIG)
      pub const CheatLib = struct {
          pub noinline fn socketAccept(server_fd: i32) !i32 {
              const sched = fp.active_scheduler;
              const task = sched.getCurrent();
              var waiter = fp.Scheduler.IoWaiter{ .task = task };
              try sched.submitAccept(&waiter, server_fd);
              task.base.yield();
              if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
              return waiter.result;
          }
      };
    ZIG
    hit_line = File.readlines(source_path).index { |line| line.include?("getCurrent") } + 1
    coverage_xml = File.join(@tmp, "cobertura.xml")
    File.write(coverage_xml, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="runtime-header" filename="runtime/runtime-header.zig">
                <lines>
                  <line number="#{hit_line}" hits="1"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML

    removals = ZigCoverageSanitizer.sanitize_file!(coverage_xml, root: @tmp)

    expect(removals).to be_empty
    sanitized = REXML::Document.new(File.read(coverage_xml))
    remaining = REXML::XPath.match(sanitized, "//class[@filename='runtime/runtime-header.zig']/lines/line")
    expect(remaining.map { |line| line.attributes["number"].to_i }).to eq([hit_line])
    expect {
      ZigCoverageSanitizer.assert_no_orphan_hits!(coverage_xml, root: @tmp)
    }.to raise_error(ZigCoverageSanitizer::Error, /socketAccept:#{hit_line}/)
  end

  it "removes proof-backed orphan runtime-header hits caused by bad Zig DWARF attribution" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/runtime-header.zig")
    File.write(source_path, <<~ZIG)
      pub const CheatLib = struct {
          pub noinline fn socketAccept(server_fd: i32) !i32 {
              const sched = fp.active_scheduler;
              const task = sched.getCurrent();
              var waiter = fp.Scheduler.IoWaiter{ .task = task };
              try sched.submitAccept(&waiter, server_fd);
              task.base.yield();
              if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
              return waiter.result;
          }
      };
    ZIG
    hit_line = File.readlines(source_path).index { |line| line.include?("getCurrent") } + 1
    coverage_xml = File.join(@tmp, "cobertura.xml")
    File.write(coverage_xml, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="runtime-header" filename="runtime/runtime-header.zig">
                <lines>
                  <line number="#{hit_line}" hits="1"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML

    removals = ZigCoverageSanitizer.sanitize_file!(coverage_xml, root: @tmp, symbols: [])

    expect(removals.map { |r| [r.function, r.line, r.hits] }).to eq([["socketAccept", hit_line, 1]])
    sanitized = REXML::Document.new(File.read(coverage_xml))
    remaining = REXML::XPath.match(sanitized, "//class[@filename='runtime/runtime-header.zig']/lines/line")
    expect(remaining).to be_empty
  end

  it "removes audit-only runtime-header hits when DWARF ownership proves the orphan" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/runtime-header.zig")
    File.write(source_path, <<~ZIG)
      pub const CheatLib = struct {
          pub fn intAdd(a: i64, b: i64) i64 {
              return a + b;
          }

          fn parseIpv4Addr(host: []const u8) !u32 {
              var parts: [4]u8 = .{0} ** 4;
              parts[0] = @intCast(host.len);
              return parts[0];
          }
      };
    ZIG
    hit_line = File.readlines(source_path).index { |line| line.include?("parts[0] =") } + 1
    coverage_xml = File.join(@tmp, "cobertura.xml")
    File.write(coverage_xml, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="runtime-header" filename="runtime/runtime-header.zig">
                <lines>
                  <line number="#{hit_line}" hits="1"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML
    binary = File.join(@tmp, "zig-test-bin")
    File.write(binary, "")
    allow(ZigCoverageSanitizer).to receive(:symbol_names_for).and_return(["runtime.runtime-header.CheatLib.intAdd"])
    allow(ZigCoverageSanitizer).to receive(:dwarf_orphan_removal_keys).and_return(
      ZigCoverageSanitizer.removal_key("runtime/runtime-header.zig", "parseIpv4Addr", hit_line) => true,
    )

    removals = ZigCoverageSanitizer.sanitize_file!(coverage_xml, root: @tmp, binary: binary)

    expect(removals.map { |r| [r.function, r.line, r.hits] }).to eq([["parseIpv4Addr", hit_line, 1]])
    sanitized = REXML::Document.new(File.read(coverage_xml))
    remaining = REXML::XPath.match(sanitized, "//class[@filename='runtime/runtime-header.zig']/lines/line")
    expect(remaining).to be_empty
  end

  it "keeps audit-only runtime-header hits without a matching DWARF ownership proof" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/runtime-header.zig")
    File.write(source_path, <<~ZIG)
      pub const CheatLib = struct {
          fn parseIpv4Addr(host: []const u8) !u32 {
              var parts: [4]u8 = .{0} ** 4;
              parts[0] = @intCast(host.len);
              return parts[0];
          }
      };
    ZIG
    hit_line = File.readlines(source_path).index { |line| line.include?("parts[0] =") } + 1
    coverage_xml = File.join(@tmp, "cobertura.xml")
    File.write(coverage_xml, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="runtime-header" filename="runtime/runtime-header.zig">
                <lines>
                  <line number="#{hit_line}" hits="1"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML
    binary = File.join(@tmp, "zig-test-bin")
    File.write(binary, "")
    allow(ZigCoverageSanitizer).to receive(:symbol_names_for).and_return(["runtime.runtime-header.CheatLib.intAdd"])
    allow(ZigCoverageSanitizer).to receive(:dwarf_orphan_removal_keys).and_return({})

    removals = ZigCoverageSanitizer.sanitize_file!(coverage_xml, root: @tmp, binary: binary)

    expect(removals).to be_empty
    expect {
      ZigCoverageSanitizer.assert_no_orphan_hits!(coverage_xml, root: @tmp)
    }.to raise_error(ZigCoverageSanitizer::Error, /parseIpv4Addr:#{hit_line}/)
  end

  it "builds sanitizer proof keys from cross-file DWARF ownership contradictions" do
    binary = File.join(@tmp, "zig-test-bin")
    File.write(binary, "")
    symbols = [ZigDwarfLineAudit::Symbol.new(addr: 1, size: 10, name: "all-fuzz.clearMain")]
    rows = [ZigDwarfLineAudit::LineRow.new(file: "zig/runtime/runtime-header.zig", line: 2290, pc: 5, flags: "x")]
    issue = ZigDwarfLineAudit::Issue.new(
      row: rows.fetch(0),
      symbol: symbols.fetch(0),
      owner_file: "zig/all-fuzz.zig",
      owner_function: "clearMain",
      source_function: ZigDwarfLineAudit::FunctionRange.new(
        name: "parseIpv4Addr",
        start_line: 2275,
        end_line: 2305,
        inline_fn: false,
      ),
    )
    allow(ZigDwarfLineAudit).to receive(:run_command!).and_return("stub")
    allow(ZigDwarfLineAudit).to receive(:parse_nm).and_return(symbols)
    allow(ZigDwarfLineAudit).to receive(:parse_decoded_line).and_return(rows)
    expect(ZigDwarfLineAudit).to receive(:audit_rows)
      .with(rows, symbols, root: @tmp, same_file_only: false)
      .and_return([[issue], { checked: 1 }])

    keys = ZigCoverageSanitizer.dwarf_orphan_removal_keys(binary, root: @tmp)

    expect(keys).to eq(
      ZigCoverageSanitizer.removal_key("zig/runtime/runtime-header.zig", "parseIpv4Addr", 2290) => true,
    )
  end

  it "builds sanitizer proof keys for runtime-header rows owned by generated symbols" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    File.write(File.join(@tmp, "zig/runtime/runtime-header.zig"), <<~ZIG)
      pub const CheatLib = struct {
          fn parseIpv4Addr(host: []const u8) !u32 {
              var parts: [4]u8 = .{0} ** 4;
              parts[0] = @intCast(host.len);
              return parts[0];
          }
      };
    ZIG
    hit_line = 4
    binary = File.join(@tmp, "zig-test-bin")
    File.write(binary, "")
    symbols = [
      ZigDwarfLineAudit::Symbol.new(
        addr: 0x100,
        size: 0x20,
        name: "all-fuzz.test.generated_case.cht.S.clearMain.__SgCtx0.run",
      ),
    ]
    rows = [ZigDwarfLineAudit::LineRow.new(file: "zig/runtime/runtime-header.zig", line: hit_line, pc: 0x110, flags: "x")]
    allow(ZigDwarfLineAudit).to receive(:run_command!).and_return("stub")
    allow(ZigDwarfLineAudit).to receive(:parse_nm).and_return(symbols)
    allow(ZigDwarfLineAudit).to receive(:parse_decoded_line).and_return(rows)
    allow(ZigDwarfLineAudit).to receive(:audit_rows).and_return([[], { checked: 0 }])

    keys = ZigCoverageSanitizer.dwarf_orphan_removal_keys(binary, root: @tmp)

    expect(keys).to eq(
      ZigCoverageSanitizer.removal_key("zig/runtime/runtime-header.zig", "parseIpv4Addr", hit_line) => true,
    )
  end

  it "removes merged orphan runtime-header hits only when an input run already proved them false" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/runtime-header.zig")
    File.write(source_path, <<~ZIG)
      pub const CheatLib = struct {
          pub noinline fn socketAccept(server_fd: i32) !i32 {
              const sched = fp.active_scheduler;
              const task = sched.getCurrent();
              var waiter = fp.Scheduler.IoWaiter{ .task = task };
              try sched.submitAccept(&waiter, server_fd);
              task.base.yield();
              if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
              return waiter.result;
          }
      };
    ZIG
    hit_line = File.readlines(source_path).index { |line| line.include?("getCurrent") } + 1
    coverage_xml = File.join(@tmp, "cobertura.xml")
    File.write(coverage_xml, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="runtime-header" filename="runtime/runtime-header.zig">
                <lines>
                  <line number="#{hit_line}" hits="1"/>
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML
    allowed = {
      ZigCoverageSanitizer.removal_key("runtime/runtime-header.zig", "socketAccept", hit_line) => true,
    }

    removals = ZigCoverageSanitizer.sanitize_file!(coverage_xml, root: @tmp, allowed_removals: allowed)

    expect(removals.map { |r| [r.function, r.line, r.hits] }).to eq([["socketAccept", hit_line, 1]])
    sanitized = REXML::Document.new(File.read(coverage_xml))
    remaining = REXML::XPath.match(sanitized, "//class[@filename='runtime/runtime-header.zig']/lines/line")
    expect(remaining).to be_empty
  end

  it "keeps real multi-line runtime-header coverage in suspicious helpers" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/runtime-header.zig")
    File.write(source_path, <<~ZIG)
      pub const CheatLib = struct {
          pub noinline fn socketAccept(server_fd: i32) !i32 {
              const sched = fp.active_scheduler;
              const task = sched.getCurrent();
              var waiter = fp.Scheduler.IoWaiter{ .task = task };
              try sched.submitAccept(&waiter, server_fd);
              task.base.yield();
              if (waiter.result < 0) return fp.Scheduler.ioError(waiter.result);
              return waiter.result;
          }
      };
    ZIG
    lines = File.readlines(source_path)
    hit_lines = [
      lines.index { |line| line.include?("active_scheduler") } + 1,
      lines.index { |line| line.include?("getCurrent") } + 1,
      lines.index { |line| line.include?("submitAccept") } + 1,
    ]
    coverage_xml = File.join(@tmp, "cobertura.xml")
    File.write(coverage_xml, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="runtime-header" filename="runtime/runtime-header.zig">
                <lines>
                  #{hit_lines.map { |line| %(<line number="#{line}" hits="1"/>) }.join("\n")}
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML

    removals = ZigCoverageSanitizer.sanitize_file!(coverage_xml, root: @tmp)

    expect(removals).to be_empty
    sanitized = REXML::Document.new(File.read(coverage_xml))
    remaining = REXML::XPath.match(sanitized, "//class[@filename='runtime/runtime-header.zig']/lines/line")
    expect(remaining.map { |line| line.attributes["number"].to_i }).to eq(hit_lines)
  end

  it "flags DWARF line-table rows whose PC owner and reported source function disagree" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    File.write(File.join(@tmp, "zig/runtime/runtime-header.zig"), <<~ZIG)
      pub const CheatLib = struct {
          pub fn concurrentListSelect() void {
              return;
          }

          pub noinline fn socketAccept() void {
              return;
          }
      };
    ZIG
    nm = <<~NM
      000000000130e490 00000000000000d2 t runtime.runtime-header.CheatLib.concurrentListSelect__anon_68940
    NM
    decoded_line = <<~LINES
      #{@tmp}/zig/runtime/runtime-header.zig:
      runtime-header.zig                      6           0x130e490               x
      runtime-header.zig                      3           0x130e4ed               x
    LINES

    rows = ZigDwarfLineAudit.parse_decoded_line(decoded_line, root: @tmp)
    symbols = ZigDwarfLineAudit.parse_nm(nm)
    issues, counters = ZigDwarfLineAudit.audit_rows(rows, symbols, root: @tmp)

    expect(counters[:checked]).to eq(2)
    expect(issues.length).to eq(1)
    expect(issues.first.row.line).to eq(6)
    expect(issues.first.owner_function).to eq("concurrentListSelect")
    expect(issues.first.source_function.name).to eq("socketAccept")
  end

  it "does not flag line-table rows for helpers reachable from the owning function" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    File.write(File.join(@tmp, "zig/runtime/runtime-header.zig"), <<~ZIG)
      pub fn caller() void {
          helper();
      }

      fn helper() void {
          return;
      }
    ZIG
    nm = <<~NM
      000000000130e490 00000000000000d2 t runtime.runtime-header.caller
    NM
    decoded_line = <<~LINES
      #{@tmp}/zig/runtime/runtime-header.zig:
      runtime-header.zig                      6           0x130e490               x
    LINES

    rows = ZigDwarfLineAudit.parse_decoded_line(decoded_line, root: @tmp)
    symbols = ZigDwarfLineAudit.parse_nm(nm)
    issues, counters = ZigDwarfLineAudit.audit_rows(rows, symbols, root: @tmp)

    expect(counters[:checked]).to eq(1)
    expect(counters[:callgraph_suppressed]).to eq(1)
    expect(issues).to be_empty
  end

  it "excludes Zig test, VOPR, Loom, generated, and benchmark files from visibility audits" do
    %w[
      zig/runtime
      zig/runtime/testing
      zig/lib
      zig/experimental
    ].each { |dir| FileUtils.mkdir_p(File.join(@tmp, dir)) }
    %w[
      zig/runtime/prod.zig
      zig/lib/atomic.zig
      zig/experimental/freeze.zig
      zig/runtime/prod-test.zig
      zig/runtime/foo-vopr.zig
      zig/runtime/foo-loom.zig
      zig/runtime/vopr-clock.zig
      zig/runtime/loom-clock.zig
      zig/runtime/foo-bench.zig
      zig/runtime/foo_bench.zig
      zig/runtime/foo-benchmark-test.zig
      zig/runtime/test_fixture.zig
      zig/runtime/testing/leak-tracker.zig
      zig/runtime/all-tests.zig
      zig/runtime/._clear_cov_x.zig
    ].each do |path|
      File.write(File.join(@tmp, path), "pub fn x() void {}\n")
    end

    expect(ZigCoverageVisibility::Analyzer.prod_files(root: @tmp)).to eq([
      "zig/experimental/freeze.zig",
      "zig/lib/atomic.zig",
      "zig/runtime/prod.zig",
    ])
  end

  it "reports executable-looking Zig functions with no kcov denominator" do
    FileUtils.mkdir_p(File.join(@tmp, "zig/runtime"))
    source_path = File.join(@tmp, "zig/runtime/prod.zig")
    File.write(source_path, <<~ZIG)
      const std = @import("std");

      pub const State = struct {
          value: i32 = 0,
      };

      pub fn visible() i32 {
          var x: i32 = 1;
          x += 1;
          return x;
      }

      pub fn invisible() i32 {
          var y: i32 = 2;
          y += 1;
          return y;
      }
    ZIG

    lines = File.readlines(source_path)
    visible_hit_lines = lines.each_with_index.filter_map do |line, idx|
      idx + 1 if line.include?("x += 1") || line.include?("return x")
    end
    coverage_xml = File.join(@tmp, "cobertura.xml")
    File.write(coverage_xml, <<~XML)
      <?xml version="1.0"?>
      <coverage>
        <packages>
          <package name="runtime">
            <classes>
              <class name="prod_zig" filename="runtime/prod.zig">
                <lines>
                  #{visible_hit_lines.map { |line| %(<line number="#{line}" hits="1"/>) }.join("\n")}
                </lines>
              </class>
            </classes>
          </package>
        </packages>
      </coverage>
    XML

    coverage = ZigCoverageVisibility::CoverageMap.new([coverage_xml])
    report = ZigCoverageVisibility::Analyzer.new(coverage).analyze_file("zig/runtime/prod.zig", root: @tmp)

    expect(report.tracked_lines).to eq(2)
    expect(report.covered_lines).to eq(2)
    expect(report.zero_tracked_functions.map(&:name)).to include("invisible")
    expect(report.zero_tracked_functions.map(&:name)).not_to include("visible")
    expect(report.expected_no_data_lines).to be > 0
    expect(report.executable_no_data_lines).to be > 0
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
