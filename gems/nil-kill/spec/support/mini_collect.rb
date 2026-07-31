# frozen_string_literal: true
#
# Shared, production-faithful mini-collect harness for the tracer
# matrix and the zero-gap guarantee/invariant specs.
#
# B1 reality: there is no parallel instrumented tree and no
# require-redirect any more. A collect instruments the target source
# IN PLACE (one copy, at the real path, always wrapped). The harness
# does exactly that against a throwaway tmp corpus dir, runs a driver
# under the tracer, and returns the runtime records + Coverage. A red
# case is a genuine tracer/architecture gap.

require "tmpdir"

module MiniCollect
  TRACER = NilKill::COLLECTOR_EXTENSION
  SUBPROCESS_COVERAGE = File.join(__dir__, "subprocess_coverage.rb")

  def in_tmp(&blk)
    Dir.mktmpdir("nk-cap", NilKill::ROOT, &blk)
  end

  def lib(dir, body, name = "lib.rb")
    p = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(p))
    File.write(p, body)
    p
  end

  # Run `driver_src` under the tracer with NIL_KILL_TARGETS=dir. The child's
  # NIL_KILL_TMP_DIR is the spec's per-example TMP_DIR so the trace plan is the
  # same file the child reads. Returns runtime records + Coverage. Source is
  # executed exactly as written; the collector observes the running program.
  # collector: false is the NEGATIVE CONTROL -- run the workload with Ruby
  # Coverage marking bodies executed but the observer never installed, so no
  # record is produced for anything. The guarantee MUST then fail loudly,
  # proving it has teeth rather than being vacuously green.
  def mini_collect(dir, lib_rel, driver_src, extra_files: {}, runtime_scip: false, collector: true, trace_plan_patch: nil, targets: dir)
    FileUtils.mkdir_p(NilKill::RUNTIME_DIR)
    isolated_env("NIL_KILL_TARGETS" => targets) do
      NilKill::TracePlan.write(NilKill::TRACE_PLAN_PATH)
      if trace_plan_patch
        plan = JSON.parse(File.read(NilKill::TRACE_PLAN_PATH))
        trace_plan_patch.call(plan)
        File.write(NilKill::TRACE_PLAN_PATH, JSON.generate(plan))
      end
    end
    extra_files.each do |rel, body|
      p = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(p))
      File.write(p, body)
    end
    driver = File.join(dir, "driver.rb")
    File.write(driver, driver_src)
    env = {
      "NIL_KILL_TRACE" => "1",
      # The native collector is the only tier, so it is always installed; the
      # keyword now only selects whether the SCIP artifacts are also read back.
      "NIL_KILL_RUNTIME_SCIP" => collector ? "1" : nil,
      "NIL_KILL_TMP_DIR" => NilKill::TMP_DIR,
      "NIL_KILL_ROOT" => NilKill::ROOT,
      "NIL_KILL_TARGETS" => targets,
      "RUBYOPT" => ENV["NIL_KILL_SUBPROCESS_COVERAGE"] == "1" ? "-r#{SUBPROCESS_COVERAGE} -r#{TRACER}" : "-r#{TRACER}",
      "NIL_KILL_SUBPROCESS_COVERAGE_CHILD" => ENV["NIL_KILL_SUBPROCESS_COVERAGE"] == "1" ? "1" : nil,
      "NIL_KILL_SHARED_COVERAGE" => ENV["NIL_KILL_SUBPROCESS_COVERAGE"] == "1" ? "1" : nil,
    }
    out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", driver, chdir: NilKill::ROOT)
    unless status.success?
      raise <<~MESSAGE
        mini collect driver failed with status #{status.exitstatus}
        stdout:
        #{out}
        stderr:
        #{err}
      MESSAGE
    end
    rd = NilKill::RUNTIME_DIR
    # The traced program writes what the collector saw; shaping it into rows is
    # the collector process's job, which this helper is standing in for.
    NilKill::Runtime::CollectorExport.write(
      runtime_dir: rd,
      plan: (JSON.parse(File.read(NilKill::TRACE_PLAN_PATH)) if File.file?(NilKill::TRACE_PLAN_PATH)),
      root: NilKill::ROOT
    )
    glob = lambda do |k|
      Dir.glob(File.join(rd, "#{k}-*.jsonl")).flat_map do |p|
        File.readlines(p, chomp: true).map { |l| JSON.parse(l) }
      end
    end
    # In-place: the wrapped source IS the file at its real path (the
    # corpus dir is throwaway tmp, so it is left wrapped -- no restore
    # needed). instr_lib is that wrapped content for assertions.
    instr_lib_path = File.join(dir, lib_rel.to_s)
    {
      status: status, out: out, err: err, dir: dir,
      methods: glob.call("methods"), method_edges: glob.call("method-edges"), structs: glob.call("structs"),
      ivars: glob.call("ivars"), collections: glob.call("collections"),
      runtime_calls: glob.call("runtime-calls"),
      tlets: glob.call("tlets"), loops: glob.call("loops"), coverage: glob.call("coverage"),
      instr_lib: (File.file?(instr_lib_path) ? File.read(instr_lib_path) : ""),
    }
  end

  # mini_collect + the real in-process Infer/Report tail (no Sorbet:
  # fast + offline). Returns the collect result plus :evidence (parsed
  # evidence.json), :report (a NilKill::Report) and :report_md.
  def full_collect(dir, driver_src, extra_files: {}, collector: true)
    r = mini_collect(dir, "lib.rb", driver_src, extra_files: extra_files, collector: collector)
    isolated_env("NIL_KILL_TARGETS" => dir, "NIL_KILL_INSTRUMENTED_ROOT" => nil) do
      capture_stdout { NilKill::Infer.new(["--no-sorbet"]).run }
    end
    evidence = JSON.parse(File.read(NilKill::EVIDENCE_PATH))
    r.merge(
      evidence: evidence,
      report: NilKill::Report.new,
      report_md: (File.read(NilKill::REPORT_PATH) if File.file?(NilKill::REPORT_PATH)),
    )
  end

  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  # The exact predicate report.rb uses for collect_ran_untraced, run
  # over the collect's OWN evidence: rel-path -> Set(covered src lines).
  def collect_coverage_index(evidence)
    cc = evidence.dig("facts", "collect_coverage")
    return {} unless cc.is_a?(Hash)
    cc.each_with_object({}) { |(p, lines), h| h[p.to_s] = Array(lines).map(&:to_i).to_set }
  end
end

RSpec.configure { |c| c.include MiniCollect }
