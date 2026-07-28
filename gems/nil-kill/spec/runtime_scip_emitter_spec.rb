# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::Runtime::ScipEmitter do
  it "encodes observed calls as open-authority SCIP with exact source ranges" do
    Dir.mktmpdir("nil-kill-runtime-scip", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def run(helper)
            helper.call
            "hello".upcase
            helper.call; helper.call
          end

          def call
            1
          end
        end
      RUBY
      events = [
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "run-1",
          "caller" => {
            "class" => "Worker", "method" => "run", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => "Worker", "name" => "call", "kind" => "instance",
            "path" => source, "line" => 8, "native" => false,
            "package_manager" => "workspace", "package" => "demo", "version" => "abc123",
          },
          "count" => 1,
        },
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "run-1",
          "caller" => {
            "class" => "Worker", "method" => "run", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 4 },
          "callee" => {
            "owner" => "String", "name" => "upcase", "kind" => "instance",
            "native" => true, "package_manager" => "ruby",
            "package" => "ruby", "version" => RUBY_VERSION,
          },
          "count" => 1,
        },
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "run-1",
          "caller" => {
            "class" => "Worker", "method" => "run", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 5 },
          "callee" => {
            "owner" => "Worker", "name" => "call", "kind" => "instance",
            "path" => source, "line" => 8, "native" => false,
            "package_manager" => "workspace", "package" => "demo", "version" => "abc123",
          },
          "count" => 2,
        },
      ]
      File.write(
        File.join(runtime_dir, "runtime-calls-1.jsonl"),
        events.map { |event| JSON.generate(event) }.join("\n") + "\n"
      )

      result = described_class.emit(
        root: root,
        runtime_dir: runtime_dir,
        environment: { "runtime.version" => RUBY_VERSION }
      )

      index = JSON.parse(File.read(result.fetch("index")))
      expect(index.dig("metadata", "toolInfo")).to include(
        "name" => "nil-kill-runtime",
        "version" => "1",
        "arguments" => ["--fact-mine-index-authority=observed-open"]
      )
      expect(index.dig("metadata", "projectRoot")).to eq(
        URI::Generic.build(
          scheme: "file",
          path: URI::DEFAULT_PARSER.escape(File.expand_path(root))
        ).to_s
      )
      document = index.fetch("documents").find { |row| row.fetch("relativePath") == "worker.rb" }
      symbols = document.fetch("occurrences").map { |row| row.fetch("symbol") }
      expect(symbols).to include(
        "nil-kill-runtime workspace demo abc123 Worker#call().",
        "nil-kill-runtime ruby ruby #{RUBY_VERSION} String#upcase()."
      )
      expect(document.fetch("occurrences")).to include(
        a_hash_including("range" => [2, 11, 15], "symbolRoles" => 0),
        a_hash_including("range" => [7, 6, 10], "symbolRoles" => 1)
      )
      # Two identical selector spellings on one line cannot be assigned to an
      # exact invocation from line-only runtime data, so the encoder fails shut.
      expect(document.fetch("occurrences").none? { |row| row.fetch("range").first == 4 }).to be(true)

      attestation = JSON.parse(File.read(result.fetch("attestation")))
      expect(attestation).to include("schema" => "fact-mine.semantic-environment.v1")
      expect(attestation.fetch("claims")).to include(
        "runtime_scip.authority" => "observed-open",
        "runtime_scip.event_count" => "3",
        "runtime.version" => RUBY_VERSION
      )
    end
  end

  it "captures Ruby project and native calls and emits them without an Espalier adapter" do
    Dir.mktmpdir("nil-kill-runtime-scip-trace", NilKill::ROOT) do |root|
      source = File.join(root, "sample.rb")
      File.write(source, <<~RUBY)
        class Helper
          def value
            "hello"
          end
        end
        class Worker
          def run(helper)
            helper.value.upcase
          end
        end
        Worker.new.run(Helper.new)
      RUBY
      trace_tmp = File.join(root, "trace")
      runtime_dir = File.join(trace_tmp, "runtime")
      tracer = File.join(
        NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace.rb"
      )
      env = {
        "NIL_KILL_TRACE" => "1",
        "NIL_KILL_TRACE_METHODS" => "1",
        "NIL_KILL_RUNTIME_SCIP" => "1",
        "NIL_KILL_RUN_ID" => "ruby-runtime-scip-test",
        "NIL_KILL_TMP_DIR" => trace_tmp,
        "NIL_KILL_TARGETS" => root,
        "NIL_KILL_PROJECT_NAME" => "runtime-demo",
        "NIL_KILL_PROJECT_VERSION" => "test-version",
        "RUBYOPT" => "-r#{tracer}",
      }

      _stdout, stderr, status = Open3.capture3(
        env, "bundle", "exec", "ruby", source, chdir: NilKill::ROOT
      )

      expect(status).to be_success, stderr
      calls = Dir.glob(File.join(runtime_dir, "runtime-calls-*.jsonl")).flat_map do |path|
        File.readlines(path, chomp: true).map { |line| JSON.parse(line) }
      end
      expect(calls).to include(a_hash_including(
        "event" => "runtime_call",
        "run_id" => "ruby-runtime-scip-test",
        "caller" => a_hash_including("class" => "Worker", "method" => "run"),
        "callsite" => a_hash_including("path" => source, "line" => 8),
        "callee" => a_hash_including(
          "owner" => "Helper",
          "name" => "value",
          "package_manager" => "workspace",
          "package" => "runtime-demo",
          "version" => "test-version"
        )
      ))
      expect(calls).to include(a_hash_including(
        "caller" => a_hash_including("class" => "Worker", "method" => "run"),
        "callee" => a_hash_including(
          "owner" => "String", "name" => "upcase", "native" => true
        )
      ))

      result = described_class.emit(root: root, runtime_dir: runtime_dir)
      index = JSON.parse(File.read(result.fetch("index")))
      symbols = index.fetch("documents").flat_map do |document|
        document.fetch("occurrences").map { |occurrence| occurrence.fetch("symbol") }
      end
      expect(symbols).to include(
        "nil-kill-runtime workspace runtime-demo test-version Helper#value().",
        "nil-kill-runtime ruby ruby #{RUBY_VERSION} String#upcase()."
      )
    end
  end

  it "never re-enters NilKill's collection lock or leaks tracing failures" do
    require File.join(
      NilKill::ROOT, "gems", "nil-kill", "lib", "nil_kill", "runtime_trace"
    )
    lock = NilKillRuntimeTrace.lock
    expect do
      lock.synchronize do
        trace = Object.new
        trace.define_singleton_method(:event) { raise "must not run" }
        NilKillRuntimeTrace.record_runtime_scip_call(trace)
      end
    end.not_to raise_error

    broken_trace = Object.new
    broken_trace.define_singleton_method(:defined_class) { raise "metadata unavailable" }
    expect { NilKillRuntimeTrace.record_runtime_scip_call(broken_trace) }.not_to raise_error
  end
end
