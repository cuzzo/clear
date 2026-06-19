# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe "nil-kill multi-language runtime pipeline" do
  def require_tree_sitter_language!(language)
    Decomplex::Syntax::TreeSitterAdapter.new.send(:parser_for, language)
  rescue LoadError => e
    skip e.message
  end

  it "publishes language provider capabilities for Ruby, Python, TypeScript, Lua, Go, Rust, Zig, C, C++, C#, Java, Kotlin, and Swift" do
    ruby = NilKill::Languages.capability_for("ruby")
    python = NilKill::Languages.capability_for("python")
    typescript = NilKill::Languages.capability_for("typescript")
    lua = NilKill::Languages.capability_for("lua")
    go = NilKill::Languages.capability_for("go")
    rust = NilKill::Languages.capability_for("rust")
    zig = NilKill::Languages.capability_for("zig")
    c = NilKill::Languages.capability_for("c")
    cpp = NilKill::Languages.capability_for("cpp")
    csharp = NilKill::Languages.capability_for("csharp")
    java = NilKill::Languages.capability_for("java")
    kotlin = NilKill::Languages.capability_for("kotlin")
    swift = NilKill::Languages.capability_for("swift")

    expect(ruby).to include("runtime_tracing" => true)
    expect(ruby["type_systems"]).to include("sorbet", "rbi")
    expect(python).to include("runtime_tracing" => true)
    expect(python).to include("type_indexing" => false)
    expect(python["annotation_systems"]).to include("python-typing")
    expect(python.dig("runtime_capabilities", "params")).to be(true)
    expect(python.dig("runtime_capabilities", "line_coverage")).to be(true)
    expect(typescript).to include("static_analysis" => true, "runtime_tracing" => false, "type_indexing" => false)
    expect(typescript["annotation_systems"]).to include("typescript")
    expect(lua).to include("static_analysis" => true, "runtime_tracing" => false, "type_indexing" => false)
    expect(go).to include("static_analysis" => true, "runtime_tracing" => false, "type_indexing" => false)
    expect(rust).to include("static_analysis" => true, "runtime_tracing" => false, "type_indexing" => false)
    expect(zig).to include("static_analysis" => true, "runtime_tracing" => false)
    expect(c).to include("static_analysis" => true, "runtime_tracing" => false, "display_name" => "C")
    expect(cpp).to include("static_analysis" => true, "runtime_tracing" => false, "display_name" => "C++")
    expect(csharp).to include("static_analysis" => true, "runtime_tracing" => false, "display_name" => "C#")
    expect(java).to include("static_analysis" => true, "runtime_tracing" => false, "display_name" => "Java")
    expect(kotlin).to include("static_analysis" => true, "runtime_tracing" => false, "display_name" => "Kotlin")
    expect(swift).to include("static_analysis" => true, "runtime_tracing" => false, "display_name" => "Swift")
    expect(zig["notes"].join).to include("runtime tracing is not implemented")
  end

  it "resolves language providers from file extensions for static diff dispatch" do
    expect(NilKill::Languages.provider_for_path("src/probe.rb").language).to eq("ruby")
    expect(NilKill::Languages.provider_for_path("src/probe.py").language).to eq("python")
    expect(NilKill::Languages.provider_for_path("src/probe.ts").language).to eq("typescript")
    expect(NilKill::Languages.provider_for_path("src/probe.lua").language).to eq("lua")
    expect(NilKill::Languages.provider_for_path("src/probe.go").language).to eq("go")
    expect(NilKill::Languages.provider_for_path("src/probe.rs").language).to eq("rust")
    expect(NilKill::Languages.provider_for_path("src/probe.zig").language).to eq("zig")
    expect(NilKill::Languages.provider_for_path("src/probe.c").language).to eq("c")
    expect(NilKill::Languages.provider_for_path("src/probe.h").language).to eq("c")
    expect(NilKill::Languages.provider_for_path("src/probe.cpp").language).to eq("cpp")
    expect(NilKill::Languages.provider_for_path("src/probe.hpp").language).to eq("cpp")
    expect(NilKill::Languages.provider_for_path("src/probe.cs").language).to eq("csharp")
    expect(NilKill::Languages.provider_for_path("src/probe.java").language).to eq("java")
    expect(NilKill::Languages.provider_for_path("src/probe.kt").language).to eq("kotlin")
    expect(NilKill::Languages.provider_for_path("src/probe.kts").language).to eq("kotlin")
    expect(NilKill::Languages.provider_for_path("src/probe.swift").language).to eq("swift")
    expect(NilKill::Languages.provider_for_path("src/probe.txt")).to be_nil
  end

  it "keeps Zig runtime collection explicitly unsupported behind the provider API" do
    provider = NilKill::Languages.provider_for("zig")

    expect {
      provider.collect_runtime(argv: ["--", "zig", "test", "sample.zig"], root: NilKill::ROOT,
        output: NilKill::RUNTIME_DIR, targets: ["zig"], append: false)
    }.to raise_error(NilKill::Languages::UnsupportedRuntimeTracer, /Zig/)
  end

  it "does not expose static field policy through the language provider" do
    %w[python typescript lua go rust zig c cpp csharp java kotlin swift].each do |language|
      provider = NilKill::Languages.provider_for(language)

      expect(provider).not_to respond_to(:canonical_state_field)
      expect(provider).not_to respond_to(:owned_state_origin?)
      expect(provider).not_to respond_to(:receiver_state_field)
    end
  end

  it "uses the Decomplex extension for Python Tree-sitter static evidence" do
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

  it "does not report Python None-only returns as nullable signatures" do
    report = NilKill::Report.allocate

    void_method = {
      "language" => "python",
      "path" => "src/worker.py",
      "owner" => "Worker",
      "name" => "call",
      "kind" => "method",
      "line" => 10,
      "signature" => "def call(self, value: str) -> None:",
    }
    maybe_method = void_method.merge(
      "name" => "fetch",
      "line" => 20,
      "signature" => "def fetch(self, value: str | None) -> str | None:",
    )

    void_findings = report.send(:static_method_findings, void_method)
    maybe_findings = report.send(:static_method_findings, maybe_method)

    expect(void_findings.map { |finding| finding["kind"] }).not_to include("nullable_signature")
    expect(maybe_findings.map { |finding| finding["kind"] }).to include("nullable_signature")
  end

  it "uses the Decomplex extension for TypeScript Tree-sitter static evidence" do
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
      expect(evidence.dig("language_capabilities", "typescript", "type_indexing")).to be(false)
      expect(evidence.dig("language_capabilities", "typescript", "annotation_systems")).to include("typescript")
    end
  end

  it "keeps Go name-type struct fields typed in static evidence" do
    grammar = ENV["DECOMPLEX_TS_GO_PATH"]
    skip "set DECOMPLEX_TS_GO_PATH to run Go Tree-sitter static evidence test" unless grammar && File.file?(grammar)

    Dir.mktmpdir("nil-kill-go-static", NilKill::ROOT) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "slab.go"), <<~GO)
        package util

        type Slab struct {
          I16 []int16
          Count int
        }
      GO

      evidence = NilKill::StaticEvidence.build([src], root: dir)
      fields = evidence.fetch("fields")
      report = NilKill::Report.allocate

      expect(evidence.dig("facts", "state_types", "Slab\u0000I16")).to eq("[]int16")
      expect(evidence.dig("facts", "state_types", "Slab\u0000Count")).to eq("int")
      expect(fields).to include(a_hash_including(
        "language" => "go",
        "name" => "I16",
        "declared_type" => "[]int16"
      ))
      expect(report.send(:static_field_finding, fields.find { |field| field["name"] == "I16" })).to be_nil
      expect(report.send(:static_field_finding, fields.find { |field| field["name"] == "Count" })).to be_nil
    end
  end

  it "uses Decomplex static facts for Go, Java, Kotlin, and Swift" do
    %i[go java kotlin swift].each { |language| require_tree_sitter_language!(language) }

    Dir.mktmpdir("nil-kill-go-jvm-swift-static", NilKill::ROOT) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "slab.go"), <<~GO)
        package util
        type Slab struct { I16 []int16; Count int }
        func (s *Slab) Push(value int16) { s.I16 = append(s.I16, value); s.Count = s.Count + 1 }
      GO
      File.write(File.join(src, "Parser.java"), <<~JAVA)
        public class Parser {
          private Node storage;
          public Node parse(Node node) { this.storage = node; return storage; }
        }
      JAVA
      File.write(File.join(src, "Parser.kt"), <<~KOTLIN)
        class Parser {
          private var storage: Node = nodeDefault()
          fun parse(node: Node): Node { this.storage = node; return storage }
        }
      KOTLIN
      File.write(File.join(src, "Parser.swift"), <<~SWIFT)
        final class Parser {
          private var storage: Node
          func parse(_ node: Node) -> Node { self.storage = node; return storage }
        }
      SWIFT

      evidence = NilKill::StaticEvidence.build([src], root: dir)

      expect(evidence.dig("language_capabilities").keys).to include("go", "java", "kotlin", "swift")
      expect(evidence["methods"]).to include(
        a_hash_including("language" => "go", "owner" => "Slab", "name" => "Push", "params" => ["value"]),
        a_hash_including("language" => "java", "owner" => "Parser", "name" => "parse", "params" => ["node"]),
        a_hash_including("language" => "kotlin", "owner" => "Parser", "name" => "parse", "params" => ["node"]),
        a_hash_including("language" => "swift", "owner" => "Parser", "name" => "parse", "params" => ["node"])
      )
      expect(evidence["fields"]).to include(
        a_hash_including("language" => "go", "owner" => "Slab", "name" => "I16", "declared_type" => "[]int16"),
        a_hash_including("language" => "java", "owner" => "Parser", "name" => "storage", "declared_type" => "Node"),
        a_hash_including("language" => "kotlin", "owner" => "Parser", "name" => "storage", "declared_type" => "Node"),
        a_hash_including("language" => "swift", "owner" => "Parser", "name" => "storage", "declared_type" => "Node")
      )
      expect(evidence.dig("facts", "state_type_records")).to include(
        a_hash_including("language" => "go", "owner" => "Slab", "field" => "I16", "declared_type" => "[]int16"),
        a_hash_including("language" => "java", "owner" => "Parser", "field" => "storage", "declared_type" => "Node"),
        a_hash_including("language" => "kotlin", "owner" => "Parser", "field" => "storage", "declared_type" => "Node"),
        a_hash_including("language" => "swift", "owner" => "Parser", "field" => "storage", "declared_type" => "Node")
      )
      expect(evidence.dig("facts", "state_param_origin_records")).to include(
        a_hash_including("language" => "go", "owner" => "Slab", "field" => "I16", "param" => "value"),
        a_hash_including("language" => "java", "owner" => "Parser", "field" => "storage", "param" => "node"),
        a_hash_including("language" => "kotlin", "owner" => "Parser", "field" => "storage", "param" => "node"),
        a_hash_including("language" => "swift", "owner" => "Parser", "field" => "storage", "param" => "node")
      )
    end
  end

  it "uses the Decomplex extension for Lua Tree-sitter static evidence" do
    require_tree_sitter_language!(:lua)

    Dir.mktmpdir("nil-kill-lua-static", NilKill::ROOT) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "worker.lua"), <<~LUA)
        local Worker = {}

        function Worker.new(items)
          local self = { items = items, count = 0 }
          return self
        end

        function Worker:push(value)
          self.items[#self.items + 1] = value
          self.client:fetch(value)
          return { value = value, ok = true }
        end
      LUA

      evidence = NilKill::StaticEvidence.build([src], root: dir)

      expect(evidence["methods"]).to include(a_hash_including(
        "language" => "lua",
        "owner" => "Worker",
        "name" => "push",
        "kind" => "method"
      ))
      expect(evidence["fields"]).to include(a_hash_including(
        "language" => "lua",
        "owner" => "Worker",
        "name" => "items",
        "static_origin" => "state_write"
      ))
      expect(evidence.dig("facts", "state_protocols", "Worker\u0000client")).to include("fetch")
      expect(evidence.dig("facts", "state_param_origins", "Worker\u0000items")).to eq(["value"])
      expect(evidence.dig("facts", "hash_shapes")).to include(a_hash_including(
        "keys" => include("items", "count"),
        "value_types" => include("number")
      ))
      expect(evidence.dig("language_capabilities", "lua")).to include(
        "static_analysis" => true,
        "runtime_tracing" => false,
        "type_indexing" => false
      )
    end
  end

  it "uses Decomplex static facts for Rust, Zig, C, C++, and C#" do
    %i[rust zig c cpp csharp].each { |language| require_tree_sitter_language!(language) }

    Dir.mktmpdir("nil-kill-systems-static", NilKill::ROOT) do |dir|
      src = File.join(dir, "src")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "worker.rs"), <<~RS)
        pub struct Worker { items: Vec<String>, count: usize }
        impl Worker {
          pub fn push(&mut self, value: String) { self.items.push(value); self.count = self.count + 1; }
        }
      RS
      File.write(File.join(src, "worker.zig"), <<~ZIG)
        const Worker = struct {
            items: []const u8,
            count: usize,
            pub fn push(self: *Worker, value: []const u8) void {
                self.items = value;
                self.count = self.count + 1;
            }
        };
      ZIG
      File.write(File.join(src, "worker.c"), <<~C)
        typedef struct Worker { int count; const char *name; } Worker;
        void worker_push(Worker *self, const char *name) { self->name = name; self->count = self->count + 1; }
      C
      File.write(File.join(src, "worker.hpp"), <<~CPP)
        #pragma once
        #include <string>
        class Worker {
        public:
          std::string name;
          int count;
          void push(const std::string& value) { name = value; count = count + 1; }
        };
      CPP
      File.write(File.join(src, "Worker.cs"), <<~CS)
        public class Worker {
          public string Name { get; set; }
          private int count;
          public void Push(string value) { Name = value; count = count + 1; }
        }
      CS

      evidence = NilKill::StaticEvidence.build([src], root: dir)

      expect(evidence.dig("language_capabilities").keys).to include("rust", "zig", "c", "cpp", "csharp")
      expect(evidence["methods"]).to include(
        a_hash_including("language" => "rust", "owner" => "Worker", "name" => "push"),
        a_hash_including("language" => "zig", "owner" => "Worker", "name" => "push"),
        a_hash_including("language" => "c", "owner" => "Worker", "name" => "worker_push"),
        a_hash_including("language" => "cpp", "owner" => "Worker", "name" => "push"),
        a_hash_including("language" => "csharp", "owner" => "Worker", "name" => "Push")
      )
      expect(evidence["fields"]).to include(
        a_hash_including("language" => "rust", "owner" => "Worker", "name" => "items", "declared_type" => "Vec<String>"),
        a_hash_including("language" => "zig", "owner" => "Worker", "name" => "items", "declared_type" => "[]const u8"),
        a_hash_including("language" => "c", "owner" => "Worker", "name" => "count", "declared_type" => "int"),
        a_hash_including("language" => "cpp", "owner" => "Worker", "name" => "name", "declared_type" => "std::string"),
        a_hash_including("language" => "csharp", "owner" => "Worker", "name" => "Name", "declared_type" => "string")
      )
      expect(evidence.dig("facts", "state_protocol_records")).to include(a_hash_including(
        "language" => "rust",
        "owner" => "Worker",
        "field" => "items",
        "protocol" => "push"
      ))
      expect(evidence.dig("facts", "state_param_origin_records")).to include(a_hash_including(
        "language" => "zig",
        "owner" => "Worker",
        "field" => "items",
        "param" => "value"
      ))
    end
  end

  it "honors static language overrides for ambiguous C++ headers" do
    require_tree_sitter_language!(:cpp)

    Dir.mktmpdir("nil-kill-cpp-header-static", NilKill::ROOT) do |dir|
      src = File.join(dir, "include")
      FileUtils.mkdir_p(src)
      File.write(File.join(src, "worker.h"), <<~CPP)
        #pragma once
        #include <string>
        class Worker {
        public:
          std::string name;
          void push(const std::string& value) { name = value; }
        };
      CPP

      evidence = NilKill::StaticEvidence.build([src], root: dir, language: :cpp)

      expect(evidence.fetch("files")).to include(a_hash_including("path" => "include/worker.h", "language" => "cpp"))
      expect(evidence["fields"]).to include(a_hash_including(
        "language" => "cpp",
        "owner" => "Worker",
        "name" => "name",
        "declared_type" => "std::string"
      ))
    end
  end

  it "exposes provider capabilities from trace-spec" do
    spec = NilKill::Commands::TraceSpecCommand.new([]).spec
    languages = spec.fetch("language_capabilities").to_h { |cap| [cap.fetch("language"), cap] }

    expect(languages.fetch("python")).to include("runtime_tracing" => true)
    expect(languages.fetch("typescript")).to include("type_indexing" => false)
    expect(languages.fetch("typescript")["annotation_systems"]).to include("typescript")
    expect(languages.fetch("lua")).to include("runtime_tracing" => false)
    expect(languages.fetch("go")).to include("runtime_tracing" => false)
    expect(languages.fetch("rust")).to include("runtime_tracing" => false)
    expect(languages.fetch("zig")).to include("runtime_tracing" => false)
    expect(languages.fetch("c")).to include("runtime_tracing" => false)
    expect(languages.fetch("cpp")).to include("runtime_tracing" => false)
    expect(languages.fetch("csharp")).to include("runtime_tracing" => false)
    expect(languages.fetch("java")).to include("runtime_tracing" => false)
    expect(languages.fetch("kotlin")).to include("runtime_tracing" => false)
    expect(languages.fetch("swift")).to include("runtime_tracing" => false)
  end

  it "preserves static language capabilities during v2 canonicalization" do
    canonical = NilKill::Schema::EvidenceBundle.canonical_static(
      "kind" => "espalier_static_evidence",
      "methods" => [],
      "facts" => {"alias_recommendations" => [{"alias" => "AST::RawBody"}]},
      "summary" => {},
      "language_capabilities" => {"zig" => NilKill::Languages.capability_for("zig")}
    )

    expect(canonical.dig("facts", "alias_recommendations")).to eq([{"alias" => "AST::RawBody"}])
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

  it "does not default non-Ruby static normalization to stale legacy runtime files" do
    Dir.mktmpdir("nil-kill-python-no-default-traces", NilKill::ROOT) do |dir|
      static_path = File.join(dir, "static.json")
      output_path = File.join(dir, "evidence.json")
      FileUtils.mkdir_p(NilKill::RUNTIME_DIR)
      File.write(File.join(NilKill::RUNTIME_DIR, "collections-stale.jsonl"),
        30.times.map { JSON.generate("legacy" => true) }.join("\n") + "\n")
      File.write(static_path, JSON.pretty_generate(
        "files" => [{"path" => "pkg/user.py", "language" => "python", "digest" => "sha256:test"}],
        "methods" => [],
        "fields" => [],
        "language_capabilities" => {"python" => NilKill::Languages.capability_for("python")}
      ))

      NilKill::Commands::NormalizeCommand.new(["--static", static_path, "--output", output_path, "--no-analyze"]).run
      evidence = JSON.parse(File.read(output_path))

      expect(evidence["languages"]).to eq(["python"])
      expect(evidence["diagnostics"]).to eq([])
      expect(evidence.dig("metadata", "trace_files")).to eq([])
    end
  end

  it "keeps Ruby-only normalization defaulting to the legacy runtime directory" do
    Dir.mktmpdir("nil-kill-ruby-default-traces", NilKill::ROOT) do |dir|
      static_path = File.join(dir, "static.json")
      output_path = File.join(dir, "evidence.json")
      FileUtils.mkdir_p(NilKill::RUNTIME_DIR)
      File.write(File.join(NilKill::RUNTIME_DIR, "events.jsonl"), JSON.generate(
        "schema_version" => 1,
        "event" => "process_start",
        "language" => "ruby",
        "run_id" => "run-1",
        "pid" => 1,
        "thread_id" => "main",
        "timestamp_ns" => 1,
        "path" => "src/demo.rb",
        "line" => 1,
        "payload" => {}
      ) + "\n")
      File.write(static_path, JSON.pretty_generate(
        "files" => [{"path" => "src/demo.rb", "language" => "ruby", "digest" => "sha256:test"}],
        "methods" => [],
        "fields" => []
      ))

      NilKill::Commands::NormalizeCommand.new(["--static", static_path, "--output", output_path, "--no-analyze"]).run
      evidence = JSON.parse(File.read(output_path))

      expect(evidence["languages"]).to eq(["ruby"])
      expect(evidence.dig("runtime", "runs")).to include(a_hash_including("run_id" => "run-1"))
      expect(evidence.dig("metadata", "trace_files")).not_to be_empty
    end
  end

  it "caps incompatible JSONL diagnostics per trace file" do
    Dir.mktmpdir("nil-kill-bad-traces", NilKill::ROOT) do |dir|
      trace_path = File.join(dir, "collections-stale.jsonl")
      File.write(trace_path, 40.times.map { JSON.generate("legacy" => true) }.join("\n") + "\n")

      diagnostics = []
      NilKill::Runtime::TraceLoader.new([trace_path]).each_event do |_event, diagnostic|
        diagnostics << diagnostic if diagnostic
      end

      expect(diagnostics.count { |diagnostic| diagnostic["code"] == "not_raw_trace_event" }).to eq(20)
      expect(diagnostics).to include(a_hash_including("code" => "not_raw_trace_event_suppressed"))
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

end
