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
  TRACER = File.join(NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb")

  def in_tmp(&blk)
    Dir.mktmpdir("nk-cap", NilKill::ROOT, &blk)
  end

  def lib(dir, body, name = "lib.rb")
    p = File.join(dir, name)
    FileUtils.mkdir_p(File.dirname(p))
    File.write(p, body)
    p
  end

  # Instrument `dir` IN PLACE, run `driver_src` under the tracer with
  # NIL_KILL_TARGETS=dir and NO instrumented-root redirect. The child's
  # NIL_KILL_TMP_DIR is the spec's per-example TMP_DIR so the linemap
  # (written by run_in_place to RUNTIME_DIR) and the trace plan are the
  # same files the child reads. Returns runtime records + Coverage.
  # instrument: false is the NEGATIVE CONTROL -- skip in-place wrapping
  # so the tracer's source-wrap recorder never fires while Ruby
  # Coverage still marks bodies executed. The invariant MUST then fail
  # (proving it has teeth, not vacuously green).
  def mini_collect(dir, lib_rel, driver_src, extra_files: {}, instrument: true)
    FileUtils.mkdir_p(NilKill::RUNTIME_DIR)
    snapshot = File.join(NilKill::TMP_DIR, "src-snapshot")
    isolated_env("NIL_KILL_TARGETS" => dir, "NIL_KILL_INSTRUMENTED_ROOT" => nil) do
      NilKill::TracePlan.write(NilKill::TRACE_PLAN_PATH)
      NilKill::SourceInstrumenter.new.run_in_place(snapshot) if instrument
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
      "NIL_KILL_TRACE_METHODS" => "0",
      "NIL_KILL_TMP_DIR" => NilKill::TMP_DIR,
      "NIL_KILL_TARGETS" => dir,
      "RUBYOPT" => "-r#{TRACER}",
    }
    out, err, status = Open3.capture3(env, "bundle", "exec", "ruby", driver, chdir: NilKill::ROOT)
    rd = NilKill::RUNTIME_DIR
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
      methods: glob.call("methods"), structs: glob.call("structs"),
      ivars: glob.call("ivars"), collections: glob.call("collections"),
      tlets: glob.call("tlets"), coverage: glob.call("coverage"),
      instr_lib: (File.file?(instr_lib_path) ? File.read(instr_lib_path) : ""),
    }
  end

  # mini_collect + the real in-process Infer/Report tail (no Sorbet:
  # fast + offline). Returns the collect result plus :evidence (parsed
  # evidence.json), :report (a NilKill::Report) and :report_md.
  def full_collect(dir, driver_src, extra_files: {}, instrument: true)
    r = mini_collect(dir, "lib.rb", driver_src, extra_files: extra_files, instrument: instrument)
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
