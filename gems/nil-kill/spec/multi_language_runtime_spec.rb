# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill multi-language runtime pipeline" do
  it "publishes language provider capabilities for Ruby, Python, TypeScript, and Zig" do
    ruby = NilKill::Languages.capability_for("ruby")
    python = NilKill::Languages.capability_for("python")
    typescript = NilKill::Languages.capability_for("typescript")
    zig = NilKill::Languages.capability_for("zig")

    expect(ruby).to include("runtime_tracing" => true, "autofix" => true)
    expect(ruby["type_systems"]).to include("sorbet", "rbi")
    expect(python).to include("runtime_tracing" => true, "autofix" => false)
    expect(python).to include("type_indexing" => true)
    expect(python["type_systems"]).to include("python-typing")
    expect(python.dig("runtime_capabilities", "params")).to be(true)
    expect(python.dig("runtime_capabilities", "line_coverage")).to be(true)
    expect(typescript).to include("static_analysis" => true, "runtime_tracing" => false, "type_indexing" => true)
    expect(typescript["type_systems"]).to include("typescript")
    expect(zig).to include("static_analysis" => true, "runtime_tracing" => false)
    expect(zig["notes"].join).to include("runtime tracing is not implemented")
  end

  it "keeps Zig runtime collection explicitly unsupported behind the provider API" do
    provider = NilKill::Languages.provider_for("zig")

    expect {
      provider.collect_runtime(argv: ["--", "zig", "test", "sample.zig"], root: NilKill::ROOT,
        output: NilKill::RUNTIME_DIR, targets: ["zig"], append: false)
    }.to raise_error(NilKill::Languages::UnsupportedRuntimeTracer, /Zig/)
  end

  it "canonicalizes Python instance fields through the language provider" do
    provider = NilKill::Languages.provider_for("python")
    origin = Decomplex::Syntax::StateParamOrigin.new(
      field: "items",
      receiver: "self",
      owner: "Worker",
      param: "items",
      file: "src/demo.py",
      function: "__init__",
      line: 2,
      span: nil
    )

    expect(provider.owned_state_origin?(origin, Set.new)).to be(true)
    expect(provider.canonical_state_field("items", receiver: "self")).to eq("@items")
    expect(provider.receiver_state_field("self.items", Set.new)).to eq("@items")
  end

  it "uses Python provider field policy when building Tree-sitter static evidence" do
    grammar = ENV["DECOMPLEX_TS_PYTHON_PATH"]
    skip "set DECOMPLEX_TS_PYTHON_PATH to run Python Tree-sitter static evidence test" unless grammar && File.file?(grammar)

    Dir.mktmpdir("nil-kill-python-static", NilKill::ROOT) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "worker.py"), <<~PY)
        class Worker:
            def __init__(self, items: list[str]):
                self.items: list[str] = items

            def call(self, value: str | None) -> None:
                self.items.append("x")
      PY
      File.write(File.join(src, "client.pyi"), <<~PYI)
        class Client:
            name: str | None
            def fetch(self, value: str | None) -> str | None: ...
      PYI

      evidence = NilKill::StaticEvidence.build([src], root: dir)

      type_definitions = evidence.dig("facts", "type_definitions")
      expect(evidence.dig("facts", "state_param_origins", "Worker\u0000@items")).to eq(["items"])
      expect(evidence.dig("facts", "state_protocols", "Worker\u0000@items")).to include("append")
      expect(evidence.dig("facts", "state_types", "Worker\u0000@items")).to eq("list[str]")
      expect(type_definitions).to include(a_hash_including(
        "language" => "python",
        "type_system" => "python-typing",
        "kind" => "method_signature",
        "name" => "call",
        "return_type" => "None"
      ))
      expect(type_definitions).to include(a_hash_including(
        "language" => "python",
        "type_system" => "python-typing",
        "kind" => "state_field",
        "name" => "@items",
        "declared_type" => "list[str]"
      ))
      expect(type_definitions).to include(a_hash_including(
        "language" => "python",
        "type_system" => "python-typing",
        "kind" => "method_signature",
        "owner" => "Client",
        "name" => "fetch",
        "return_type" => "str | None"
      ))
      expect(type_definitions).to include(a_hash_including(
        "language" => "python",
        "type_system" => "python-typing",
        "kind" => "state_field",
        "owner" => "Client",
        "name" => "name",
        "declared_type" => "str | None"
      ))
      expect(evidence.dig("language_capabilities", "python", "runtime_tracing")).to be(true)
      expect(evidence.dig("summary", "signatures")).to eq(3)
    end
  end

  it "uses TypeScript provider annotations when building Tree-sitter static evidence" do
    grammar = ENV["DECOMPLEX_TS_TYPESCRIPT_PATH"]
    skip "set DECOMPLEX_TS_TYPESCRIPT_PATH to run TypeScript Tree-sitter static evidence test" unless grammar && File.file?(grammar)

    Dir.mktmpdir("nil-kill-typescript-static", NilKill::ROOT) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "worker.ts"), <<~TS)
        interface Client {
          name?: string | null;
          fetch(value: string | null): string | null;
        }

        class Worker {
          private client: Client | null;

          constructor(client: Client | null) {
            this.client = client;
          }

          call(value: string | null): string | null {
            return this.client?.fetch(value) ?? null;
          }
        }
      TS

      evidence = NilKill::StaticEvidence.build([src], root: dir)
      type_definitions = evidence.dig("facts", "type_definitions")

      expect(evidence.dig("facts", "state_types", "Worker\u0000@client")).to eq("Client | null")
      expect(evidence.dig("facts", "state_param_origins", "Worker\u0000@client")).to eq(["client"])
      expect(evidence.dig("facts", "state_protocols", "Worker\u0000@client")).to include("fetch")
      expect(type_definitions).to include(a_hash_including(
        "language" => "typescript",
        "type_system" => "typescript",
        "kind" => "method_signature",
        "name" => "call",
        "return_type" => "string | null"
      ))
      expect(type_definitions).to include(a_hash_including(
        "language" => "typescript",
        "type_system" => "typescript",
        "kind" => "method_signature",
        "owner" => "Client",
        "name" => "fetch",
        "return_type" => "string | null"
      ))
      expect(type_definitions).to include(a_hash_including(
        "language" => "typescript",
        "type_system" => "typescript",
        "kind" => "state_field",
        "name" => "@client",
        "declared_type" => "Client | null"
      ))
      expect(type_definitions).to include(a_hash_including(
        "language" => "typescript",
        "type_system" => "typescript",
        "kind" => "state_field",
        "owner" => "Client",
        "name" => "name",
        "declared_type" => "string | null"
      ))
      expect(evidence.dig("language_capabilities", "typescript", "type_indexing")).to be(true)
    end
  end

  it "exposes provider capabilities from trace-spec" do
    spec = NilKill::Commands::TraceSpecCommand.new([]).spec
    languages = spec.fetch("language_capabilities").to_h { |cap| [cap.fetch("language"), cap] }

    expect(languages.fetch("python")).to include("runtime_tracing" => true)
    expect(languages.fetch("typescript")).to include("type_indexing" => true)
    expect(languages.fetch("zig")).to include("runtime_tracing" => false)
  end

  it "preserves static language capabilities during v2 canonicalization" do
    canonical = NilKill::Schema::EvidenceBundle.canonical_static(
      "kind" => "espalier_static_evidence",
      "methods" => [],
      "facts" => {},
      "summary" => {},
      "language_capabilities" => {"zig" => NilKill::Languages.capability_for("zig")}
    )

    expect(canonical.dig("language_capabilities", "zig", "runtime_tracing")).to be(false)
    expect(canonical.dig("language_extensions", "nil_kill_static_evidence", "language_capabilities", "zig", "runtime_tracing")).to be(false)
  end

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
