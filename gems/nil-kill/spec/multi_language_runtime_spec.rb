# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill multi-language runtime pipeline" do
  it "collects Python raw trace events through sitecustomize" do
    Dir.mktmpdir("nil-kill-python-tracer", NilKill::ROOT) do |dir|
      src = File.join(dir, "src")
      trace_dir = File.join(dir, "runtime")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "demo.py"), <<~PY)
        class Worker:
            def __init__(self):
                self.items = []

            def call(self, value):
                self.items.append(value)
                return {"value": value}
      PY

      env = {
        "PYTHONPATH" => [File.join(NilKill::ROOT, "gems", "nil-kill", "lib"), src].join(File::PATH_SEPARATOR),
        "NIL_KILL_PY_TRACE" => "1",
        "NIL_KILL_PY_TRACE_OUT" => trace_dir,
        "NIL_KILL_TRACE_ROOT" => dir,
        "NIL_KILL_TARGETS" => src,
      }
      out, err, status = Open3.capture3(env, "python3", "-c", "from demo import Worker; Worker().call('x')", chdir: dir)

      expect(status).to be_success, "#{out}\n#{err}"
      events = Dir.glob(File.join(trace_dir, "python-events-*.jsonl")).flat_map do |path|
        File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      end
      expect(events).to include(a_hash_including("event" => "method_call", "locator" => a_hash_including("owner" => "Worker", "name" => "call")))
      expect(events).to include(a_hash_including("event" => "param_observed", "payload" => a_hash_including("param" => "value")))
      expect(events).to include(a_hash_including("event" => "method_return", "payload" => a_hash_including("type" => a_hash_including("kind" => "map"))))
      expect(events).to include(a_hash_including("event" => "field_observed", "payload" => a_hash_including("field" => "@items")))
      expect(events).to include(a_hash_including("event" => "coverage", "path" => "src/demo.py"))
    end
  end

  it "normalizes a minimal Python tracer JSONL stream into v2 evidence and report actions" do
    Dir.mktmpdir("nil-kill-python-trace", NilKill::ROOT) do |dir|
      static_path = File.join(dir, "static.json")
      trace_dir = File.join(dir, "traces")
      output_path = File.join(dir, "evidence.json")
      report_path = File.join(dir, "report.md")
      FileUtils.mkdir_p(trace_dir)

      static = {
        "static" => {
          "files" => [{"path" => "pkg/user.py", "language" => "python", "digest" => "sha256:test"}],
          "methods" => [{
            "id" => "python\u0000pkg/user.py\u0000User\u0000method\u0000name\u000012",
            "language" => "python",
            "path" => "pkg/user.py",
            "owner" => "User",
            "name" => "name",
            "kind" => "method",
            "line" => 12,
            "params" => [{"name" => "fallback", "declared_type" => "str", "nilable" => false}],
            "return" => {"declared_type" => "str", "nilable" => false},
          }],
          "fields" => [],
        },
      }
      File.write(static_path, JSON.pretty_generate(static))

      events = [
        {
          "schema_version" => 1, "event" => "process_start", "language" => "python",
          "run_id" => "run-1", "pid" => 1, "thread_id" => "main", "timestamp_ns" => 1,
          "path" => "pkg/user.py", "line" => 1, "payload" => {},
        },
        {
          "schema_version" => 1, "event" => "method_call", "language" => "python",
          "run_id" => "run-1", "pid" => 1, "thread_id" => "main", "timestamp_ns" => 2,
          "path" => "pkg/user.py", "line" => 12,
          "locator" => {"owner" => "User", "name" => "name", "kind" => "method"},
          "payload" => {"sample_count" => 1},
        },
        {
          "schema_version" => 1, "event" => "param_observed", "language" => "python",
          "run_id" => "run-1", "pid" => 1, "thread_id" => "main", "timestamp_ns" => 3,
          "path" => "pkg/user.py", "line" => 12,
          "locator" => {"owner" => "User", "name" => "name", "kind" => "method"},
          "payload" => {"param" => "fallback", "type" => {"name" => "None", "kind" => "null", "nullable" => true, "display" => "None"}},
        },
        {
          "schema_version" => 1, "event" => "method_return", "language" => "python",
          "run_id" => "run-1", "pid" => 1, "thread_id" => "main", "timestamp_ns" => 4,
          "path" => "pkg/user.py", "line" => 12,
          "locator" => {"owner" => "User", "name" => "name", "kind" => "method"},
          "payload" => {"type" => {"name" => "str", "kind" => "primitive", "nullable" => false, "display" => "str"}},
        },
        {
          "schema_version" => 1, "event" => "coverage", "language" => "python",
          "run_id" => "run-1", "pid" => 1, "thread_id" => "main", "timestamp_ns" => 5,
          "path" => "pkg/user.py", "line" => 12, "payload" => {"lines" => [12, 13]},
        },
      ]
      File.write(File.join(trace_dir, "events.jsonl"), events.map { |event| JSON.generate(event) }.join("\n") + "\n")

      NilKill::Commands::NormalizeCommand.new(["--static", static_path, "--traces", trace_dir, "--output", output_path]).run
      evidence = JSON.parse(File.read(output_path))

      expect(evidence["schema_version"]).to eq(2)
      expect(evidence["languages"]).to eq(["python"])
      method_id = "python\u0000pkg/user.py\u0000User\u0000method\u0000name\u000012"
      expect(evidence.dig("runtime", "method_hits", method_id)).to include("calls" => 1, "ok_calls" => 1)
      expect(evidence.dig("runtime", "coverage", "pkg/user.py")).to eq([12, 13])
      expect(evidence["actions"]).to include(a_hash_including(
        "kind" => "add_nullability",
        "language" => "python",
        "confidence" => "review",
        "message" => include("fallback")
      ))

      expect do
        NilKill::Report.new(["--evidence", output_path, "--output-path", report_path]).run
      end.to output(/Nil Kill Multi-Language Report/).to_stdout
      expect(File.read(report_path)).to include("pkg/user.py:12 add_nullability")
    end
  end

  it "keeps legacy Ruby runtime loading behind the normalizer boundary" do
    Dir.mktmpdir("nil-kill-legacy-runtime", NilKill::ROOT) do |dir|
      source = File.join(dir, "sample.rb")
      File.write(source, "class LegacyRuntime; def call(value); value; end; end\n")
      runtime_dir = File.join(dir, "runtime")
      FileUtils.mkdir_p(runtime_dir)
      File.write(File.join(runtime_dir, "methods-test.jsonl"), JSON.generate(
        "class" => "LegacyRuntime",
        "method" => "call",
        "kind" => "instance",
        "path" => source,
        "line" => 1,
        "calls" => 2,
        "ok_calls" => 2,
        "raised_calls" => 0,
        "params_by_name" => {"value" => ["String"]},
        "params_ok" => {"value" => ["String"]},
        "returns" => ["String"]
      ) + "\n")

      store = NilKill::Store.new
      isolated_env("NIL_KILL_TARGETS" => dir) do
        NilKill::Runtime::Normalizer.new.load_legacy_ruby!(store, runtime_dir: runtime_dir)
      end

      rec = store.methods.values.first
      expect(rec).to include("calls" => 2, "ok_calls" => 2)
      expect(rec.dig("params_by_name", "value")).to eq(["String"])
      expect(rec["returns"]).to eq(["String"])
    end
  end

  it "keeps unsupported non-Ruby auto-fixes report-only" do
    action = NilKill::Actions::Record.build(
      kind: "add_nullability",
      language: "python",
      confidence: "review",
      target: {"path" => "pkg/user.py", "line" => 12, "symbol_id" => "python\u0000pkg/user.py\u0000User\u0000method\u0000name\u000012"},
      message: "param fallback observed None",
      data: {"slot" => "param", "name" => "fallback"}
    )

    provider = NilKill::AutoFix.provider_for("python")
    plan = provider.plan(action)

    expect(provider.supports?(action)).to be(false)
    expect(plan["supported"]).to be(false)
    expect(plan.dig("diagnostics", 0, "code")).to eq("unsupported_autofix_provider")
  end
end
