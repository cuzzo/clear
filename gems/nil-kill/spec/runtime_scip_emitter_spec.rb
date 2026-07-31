# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::Runtime::ScipEmitter do
  it "uses the exact same FactMine executable as trace planning" do
    emitter = described_class.new(root: NilKill::ROOT, runtime_dir: NilKill::RUNTIME_DIR)

    expect(emitter.send(:fact_mine_binary))
      .to eq(Espalier::StaticEvidence::FACT_MINE_RUST_BINARY)
  end

  def runtime_event(source:, caller:, line:, owner:, name:, receiver_type: owner, **callee)
    {
      "schema_version" => 1,
      "event" => "runtime_call",
      "language" => "ruby",
      "run_id" => "runtime-scip-spec",
      "caller" => {
        "class" => caller.fetch(:owner),
        "method" => caller.fetch(:name),
        "kind" => "instance",
        "path" => source,
        "line" => caller.fetch(:line),
      },
      "callsite" => { "path" => source, "line" => line },
      "callee" => {
        "owner" => owner,
        "name" => name,
        "kind" => callee.fetch(:kind, "instance"),
        "path" => callee[:callee_path],
        "line" => callee[:callee_line],
        "native" => callee.fetch(:native, true),
        "receiver_type" => receiver_type,
        "package_manager" => callee.fetch(:package_manager, "ruby"),
        "package" => callee.fetch(:package, "ruby"),
        "version" => callee.fetch(:version, RUBY_VERSION),
      },
      "receiver_domain" => {
        "types" => [receiver_type],
        "singletons" => [],
        "elements" => [],
        "keys" => [],
        "values" => [],
        "shapes" => [],
      },
      "count" => 1,
    }
  end

  def write_runtime_calls(runtime_dir, events)
    File.write(
      File.join(runtime_dir, "runtime-calls-1.jsonl"),
      events.map { |event| JSON.generate(event) }.join("\n") + "\n"
    )
  end

  def occurrences(index)
    index.fetch("documents").flat_map { |document| document.fetch("occurrences") }
  end

  it "routes observed values through FactMine CFG/DFG and emits inferred SCIP" do
    Dir.mktmpdir("nil-kill-runtime-scip-fact-mine", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(row)
            row.kind
          end

          def inferred(rows)
            rows.each { |row| row.kind }
          end
        end
      RUBY
      File.write(File.join(runtime_dir, "methods-1.jsonl"), JSON.generate({
        "class" => "Worker",
        "method" => "inferred",
        "kind" => "instance",
        "path" => source,
        "line" => 6,
        "calls" => 1,
        "ok_calls" => 1,
        "params_by_name" => { "rows" => ["Array"] },
        "param_elem" => { "rows" => ["Row"] },
        "param_kv" => {},
        "returns" => ["Array"],
        "return_elem" => ["Row"],
        "return_kv" => [[], []],
      }) + "\n")
      write_runtime_calls(runtime_dir, [
        runtime_event(
          source: source,
          caller: { owner: "Worker", name: "observed", line: 2 },
          line: 3,
          owner: "Row",
          name: "kind",
          receiver_type: "Row",
          package_manager: "workspace",
          package: "demo",
          version: "workspace"
        ),
      ])

      result = described_class.emit(
        root: root,
        runtime_dir: runtime_dir,
        files: [source],
        environment: { "runtime.version" => RUBY_VERSION }
      )
      index = JSON.parse(File.read(result.fetch("index")))
      symbols_by_line = occurrences(index).group_by { |row| row.fetch("range").first }

      expect(index.dig("metadata", "toolInfo")).to include(
        "name" => "nil-kill-runtime",
        "version" => "2",
        "arguments" => ["--fact-mine-index-authority=runtime-modeled-world"]
      )
      expect(symbols_by_line.fetch(2).map { |row| row.fetch("symbol") })
        .to include("nil-kill-runtime workspace demo workspace Row#kind().")
      expect(symbols_by_line.fetch(6).map { |row| row.fetch("symbol") })
        .to include("nil-kill-runtime workspace demo workspace Row#kind().")
      expect(index.dig("_runtimeEvidence", "inferredCallSites")).to be >= 1
      expect(result.fetch("runtime_value_observations")).to be >= 1
      expect(
        NilKill::Runtime::JsonIO.parse(result.fetch("runtime_evidence"))
          .fetch("protocol_version")
      ).to eq(1)
      expect(NilKill::Runtime::JsonIO.parse(result.fetch("attestation")).fetch("claims")).to include(
        "runtime_scip.authority" => "runtime-modeled-world",
        "runtime.version" => RUBY_VERSION
      )
    end
  end

  it "uses observed project return domains for unexecuted downstream receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-return", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(row)
            row.kind
          end

          def rows
            []
          end

          def inferred
            rows.each { |row| row.kind }
          end
        end
      RUBY
      File.write(File.join(runtime_dir, "methods-1.jsonl"), JSON.generate({
        "class" => "Worker",
        "method" => "rows",
        "kind" => "instance",
        "path" => source,
        "line" => 6,
        "calls" => 1,
        "ok_calls" => 1,
        "params_by_name" => {},
        "param_elem" => {},
        "param_kv" => {},
        "returns" => ["Array"],
        "return_elem" => ["Row"],
        "return_kv" => [[], []],
      }) + "\n")
      write_runtime_calls(runtime_dir, [
        runtime_event(
          source: source,
          caller: { owner: "Worker", name: "observed", line: 2 },
          line: 3,
          owner: "Row",
          name: "kind",
          receiver_type: "Row",
          package_manager: "workspace",
          package: "demo",
          version: "workspace"
        ),
      ])

      result = described_class.emit(root: root, runtime_dir: runtime_dir, files: [source])
      index = JSON.parse(File.read(result.fetch("index")))
      inferred = occurrences(index).select { |row| row.fetch("range").first == 10 }

      expect(inferred.map { |row| row.fetch("symbol") })
        .to include("nil-kill-runtime workspace demo workspace Row#kind().")
    end
  end

  it "retains test-double evidence but does not publish it as production SCIP" do
    Dir.mktmpdir("nil-kill-runtime-scip-test-double", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "lib", "worker.rb")
      test_double = File.join(root, "test", "worker_test.rb")
      dependency = File.join(root, "vendor", "renderer.rb")
      mocking_framework = File.join(
        root, "vendor", "bundle", "ruby", RUBY_VERSION,
        "gems", "minitest-5.27.0", "lib", "minitest", "mock.rb"
      )
      [runtime_dir, File.dirname(source), File.dirname(test_double),
       File.dirname(dependency), File.dirname(mocking_framework)].each do |directory|
        FileUtils.mkdir_p(directory)
      end
      File.write(source, "def run(renderer)\n  renderer.render\nend\n")
      File.write(test_double, "def render\n  :fake\nend\n")
      File.write(dependency, "def render\n  :real\nend\n")
      File.write(mocking_framework, "def render\n  :mock\nend\n")
      event = lambda do |path, package|
        runtime_event(
          source: source,
          caller: { owner: "Object", name: "run", line: 1 },
          line: 2,
          owner: "Renderer",
          name: "render",
          receiver_type: "Renderer",
          native: false,
          callee_path: path,
          callee_line: 1,
          package_manager: "rubygems",
          package: package,
          version: "1"
        )
      end
      write_runtime_calls(runtime_dir, [
        event.call(test_double, "test-double"),
        event.call(mocking_framework, "minitest"),
        event.call(dependency, "renderer"),
      ])

      result = described_class.emit(root: root, runtime_dir: runtime_dir, files: [source])
      symbols = occurrences(JSON.parse(File.read(result.fetch("index"))))
        .map { |row| row.fetch("symbol") }

      expect(symbols).to include(
        "nil-kill-runtime rubygems renderer 1 Renderer#render()."
      )
      expect(symbols).not_to include(
        "nil-kill-runtime rubygems test-double 1 Renderer#render().",
        "nil-kill-runtime rubygems minitest 1 Renderer#render()."
      )
      expect(result.fetch("excluded_events")).to eq(0)
      evidence = NilKill::Runtime::JsonIO.parse(result.fetch("runtime_evidence"))
      expect(
        evidence.fetch("anchors").flat_map { |row| row.fetch("executions") }
          .map { |bucket| bucket.dig("target", "source_role") }
      ).to include("NON_PRODUCTION")
    end
  end

  it "emits exact compound-write and nested-index selector ranges" do
    Dir.mktmpdir("nil-kill-runtime-scip-operators", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        def run(index, values)
          index += 1
          index -= 1
          values[index]
          values[values[index]]
          [index, 1].min
        end
      RUBY
      event = lambda do |name, owner, line|
        runtime_event(
          source: source,
          caller: { owner: "Object", name: "run", line: 1 },
          line: line,
          owner: owner,
          name: name,
          receiver_type: owner
        )
      end
      write_runtime_calls(runtime_dir, [
        event.call("+", "Integer", 2),
        event.call("-", "Integer", 3),
        event.call("[]", "Array", 4),
        event.call("min", "Array", 6),
      ])

      result = described_class.emit(root: root, runtime_dir: runtime_dir, files: [source])
      rows = occurrences(JSON.parse(File.read(result.fetch("index"))))

      expect(rows).to include(
        # The selector for `+=`/`-=` is the dispatched `+`/`-` token, not
        # the assignment marker. SCIP must therefore annotate one byte.
        a_hash_including("range" => [1, 8, 9], "symbol" => a_string_including("Integer#+()")),
        a_hash_including("range" => [2, 8, 9], "symbol" => a_string_including("Integer#-()")),
        a_hash_including("range" => [3, 8, 9], "symbol" => a_string_including("#`[]`()")),
        a_hash_including("range" => [4, 8, 9], "symbol" => a_string_including("#`[]`()")),
        a_hash_including("range" => [4, 15, 16], "symbol" => a_string_including("#`[]`()")),
        a_hash_including("range" => [5, 13, 16], "symbol" => a_string_including("#min()"))
      )
    end
  end

  it "keeps source-flow inference out of the Ruby provider" do
    provider_source = File.read(
      File.join(
        NilKill::ROOT,
        "gems", "nil-kill", "lib", "nil_kill", "languages", "providers", "ruby.rb"
      )
    )

    expect(provider_source).not_to include(
      "ruby_runtime_scip_local_owners",
      "ruby_runtime_scip_value_domain",
      "runtime_scip_inferred_events",
      "Prism"
    )
    expect(provider_source).to include("runtime_value_observations")
  end
end
