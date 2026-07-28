# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::Runtime::ScipEmitter do
  it "encodes observed calls as modeled-world SCIP with exact source ranges" do
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
        "arguments" => ["--fact-mine-index-authority=runtime-modeled-world"]
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
      # Modeled-world data conservatively assigns the observed target set to
      # every identical selector on the traced source line.
      expect(document.fetch("occurrences")).to include(
        a_hash_including("range" => [4, 11, 15], "symbolRoles" => 0),
        a_hash_including("range" => [4, 24, 28], "symbolRoles" => 0)
      )

      attestation = JSON.parse(File.read(result.fetch("attestation")))
      expect(attestation).to include("schema" => "fact-mine.semantic-environment.v1")
      expect(attestation.fetch("claims")).to include(
        "runtime_scip.authority" => "runtime-modeled-world",
        "runtime_scip.closure_assumption" =>
          "observed call targets exhaust the attested workload and runtime environment",
        "runtime_scip.inference" =>
          "language-owned source callsites joined to observed modeled dispatch domains",
        "runtime_scip.event_count" => "3",
        "runtime.version" => RUBY_VERSION
      )
    end
  end

  it "does not publish Ruby test-double definitions as production identities" do
    Dir.mktmpdir("nil-kill-runtime-scip-test-double", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "lib", "worker.rb")
      test_double = File.join(root, "test", "worker_test.rb")
      dependency = File.join(root, "vendor", "renderer.rb")
      mocking_framework = File.join(
        root, "vendor", "bundle", "ruby", RUBY_VERSION,
        "gems", "minitest-5.27.0", "lib", "minitest", "mock.rb"
      )
      FileUtils.mkdir_p(runtime_dir)
      FileUtils.mkdir_p(File.dirname(source))
      FileUtils.mkdir_p(File.dirname(test_double))
      FileUtils.mkdir_p(File.dirname(dependency))
      FileUtils.mkdir_p(File.dirname(mocking_framework))
      File.write(source, "def run(renderer)\n  renderer.render\nend\n")
      File.write(test_double, "def render\n  :fake\nend\n")
      File.write(dependency, "def render\n  :real\nend\n")
      File.write(mocking_framework, "def render\n  :mock\nend\n")
      event = lambda do |path, package|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "test-double",
          "caller" => {
            "class" => "Object", "method" => "run", "kind" => "instance",
            "path" => source, "line" => 1,
          },
          "callsite" => { "path" => source, "line" => 2 },
          "callee" => {
            "owner" => "Renderer", "name" => "render", "kind" => "instance",
            "path" => path, "line" => 1, "native" => false,
            "package_manager" => "rubygems", "package" => package, "version" => "1",
          },
          "count" => 1,
        }
      end
      File.write(
        File.join(runtime_dir, "runtime-calls-1.jsonl"),
        [
          event.call(test_double, "test-double"),
          event.call(mocking_framework, "minitest"),
          event.call(dependency, "renderer"),
        ].map { |row| JSON.generate(row) }.join("\n") + "\n"
      )

      result = described_class.emit(root: root, runtime_dir: runtime_dir)
      index = JSON.parse(File.read(result.fetch("index")))
      symbols = index.fetch("documents").flat_map do |document|
        document.fetch("occurrences").map { |occurrence| occurrence.fetch("symbol") }
      end

      expect(symbols).to include(
        "nil-kill-runtime rubygems renderer 1 Renderer#render()."
      )
      expect(symbols).not_to include(
        "nil-kill-runtime rubygems test-double 1 Renderer#render()."
      )
      expect(symbols).not_to include(
        "nil-kill-runtime rubygems minitest 1 Renderer#render()."
      )
      expect(result.fetch("excluded_events")).to eq(2)
    end
  end

  it "captures Ruby project and native calls and emits them without an Espalier adapter" do
    Dir.mktmpdir("nil-kill-runtime-scip-trace", NilKill::ROOT) do |root|
      source = File.join(root, "sample.rb")
      File.write(source, <<~RUBY)
        class Helper
          def value
            ["hello"].map do |item|
              item.upcase
            end.first
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
        "callsite" => a_hash_including("path" => source, "line" => 10),
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
      expect(calls).to include(a_hash_including(
        "caller" => a_hash_including("class" => "Helper", "method" => "value"),
        "callsite" => a_hash_including("path" => source, "line" => 3),
        "callee" => a_hash_including("owner" => "Array", "name" => "map")
      ))
      expect(calls).to include(a_hash_including(
        "caller" => a_hash_including("class" => "Helper", "method" => "value"),
        "callsite" => a_hash_including("path" => source, "line" => 4),
        "callee" => a_hash_including("owner" => "String", "name" => "upcase")
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

  it "does not spread ambiguous selector targets across unexecuted dynamic receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-ambiguous", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def first(factory)
            factory.build
          end

          def second(factory)
            factory.build
          end
        end
      RUBY
      event = lambda do |method, line, owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "ambiguous-targets",
          "caller" => {
            "class" => "Worker", "method" => method, "kind" => "instance",
            "path" => source, "line" => method == "first" ? 2 : 6,
          },
          "callsite" => { "path" => source, "line" => line },
          "callee" => {
            "owner" => owner, "name" => "build", "kind" => "instance",
            "native" => true, "package_manager" => "rubygems",
            "package" => owner.downcase, "version" => "1.0.0",
          },
          "count" => 1,
        }
      end
      events = [
        event.call("first", 3, "FirstBuilder"),
        event.call("second", 7, "SecondBuilder"),
      ]

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: events,
        root: root
      )

      expect(inferred).to be_empty
    end
  end

  it "does not mix class and instance targets that share an owner and selector" do
    Dir.mktmpdir("nil-kill-runtime-scip-dispatch-kind", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def run
            Builder.build
          end
        end
      RUBY
      event = lambda do |kind|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "dispatch-kind",
          "caller" => {
            "class" => "Worker", "method" => "run", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => "Builder", "name" => "build", "kind" => kind,
            "native" => false, "package_manager" => "workspace",
            "package" => "demo", "version" => "1",
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("class"), event.call("instance")],
        root: root
      )

      expect(inferred.map { |row| row.dig("callee", "kind") }.uniq).to eq(["class"])
      expect(inferred.first.dig("callsite", "range")).to eq([2, 12, 17])
    end
  end

  it "uses singleton runtime parameter types to infer unexecuted receiver identities" do
    Dir.mktmpdir("nil-kill-runtime-scip-parameter-types", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(items)
            items.map
          end

          def inferred(items)
            items.map
          end

          def block_inferred(items)
            items.each do |item|
              item.strip
            end
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        [
          {
            "class" => "Worker", "method" => "inferred", "kind" => "instance",
            "path" => source, "line" => 6, "calls" => 1, "ok_calls" => 1,
            "raised_calls" => 0, "params_by_name" => { "items" => ["Array"] },
            "params_ok" => { "items" => ["Array"] },
          },
          {
            "class" => "Worker", "method" => "block_inferred", "kind" => "instance",
            "path" => source, "line" => 10, "calls" => 1, "ok_calls" => 1,
            "raised_calls" => 0, "params_by_name" => { "items" => ["Array"] },
            "params_ok" => { "items" => ["Array"] },
            "param_elem" => { "items" => ["String"] },
          },
        ].map { |row| JSON.generate(row) }.join("\n") + "\n"
      )
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "parameter-types",
        "caller" => {
          "class" => "Worker", "method" => "observed", "kind" => "instance",
          "path" => source, "line" => 2,
        },
        "callsite" => { "path" => source, "line" => 3 },
        "callee" => {
          "owner" => "Enumerable", "name" => "map", "kind" => "instance",
          "native" => true, "receiver_type" => "Array",
          "package_manager" => "ruby", "package" => "ruby",
          "version" => RUBY_VERSION,
        },
        "count" => 1,
      }

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [
          event,
          event.merge(
            "callee" => event.fetch("callee").merge(
              "owner" => "String", "name" => "strip",
              "receiver_type" => "String"
            )
          ),
        ],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find { |row| row.dig("callsite", "line") == 7 }
      block_target = inferred.find do |row|
        row.dig("callsite", "line") == 12 && row.dig("callee", "name") == "strip"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("Enumerable")
      expect(target.dig("callsite", "range")).to eq([6, 10, 13])
      expect(block_target).not_to be_nil
      expect(block_target.dig("callee", "owner")).to eq("String")
      expect(block_target.dig("callsite", "range")).to eq([11, 11, 16])
    end
  end

  it "uses reviewed runtime selector aliases for typed unexecuted receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-selector-alias", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(values)
            values.add?(:item)
          end

          def inferred(seen)
            seen.add(:item)
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "inferred", "kind" => "instance",
          "path" => source, "line" => 6, "calls" => 1, "ok_calls" => 1,
          "raised_calls" => 0, "params_by_name" => { "seen" => ["Set"] },
          "params_ok" => { "seen" => ["Set"] }
        ) + "\n"
      )
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "selector-alias",
        "caller" => {
          "class" => "Worker", "method" => "observed", "kind" => "instance",
          "path" => source, "line" => 2,
        },
        "callsite" => { "path" => source, "line" => 3 },
        "callee" => {
          "owner" => "Set", "name" => "add?", "kind" => "instance",
          "path" => "/usr/lib/ruby/set.rb", "line" => 1,
          "native" => false, "receiver_type" => "Set",
          "package_manager" => "ruby", "package" => "ruby",
          "version" => RUBY_VERSION,
        },
        "count" => 1,
      }

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find { |row| row.dig("callsite", "line") == 7 }

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("Set")
      expect(target.dig("callee", "name")).to eq("add")
      expect(target.dig("callsite", "range")).to eq([6, 9, 12])
    end
  end

  it "keeps implicit Class#new identities without poisoning explicit constructors" do
    Dir.mktmpdir("nil-kill-runtime-scip-implicit-new", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def self.build
            new
          end

          def self.explicit
            Widget.new
          end
        end
      RUBY
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "implicit-new",
        "caller" => {
          "class" => "Worker", "method" => "build", "kind" => "class",
          "path" => source, "line" => 2,
        },
        "callsite" => { "path" => source, "line" => 3 },
        "callee" => {
          "owner" => "Class", "name" => "new", "kind" => "instance",
          "native" => true, "receiver_type" => "Class",
          "package_manager" => "ruby", "package" => "ruby",
          "version" => RUBY_VERSION,
        },
        "count" => 1,
      }
      provider = NilKill::Languages::Providers::Ruby.new

      locations = provider.runtime_scip_callsite_locations(event: event, root: root)
      inferred = provider.runtime_scip_inferred_events(events: [event], root: root)

      expect(locations.map { |location| location.fetch("range") }).to eq([[2, 4, 7]])
      expect(inferred).to include(a_hash_including(
        "callsite" => a_hash_including("line" => 3, "range" => [2, 4, 7]),
        "callee" => a_hash_including("owner" => "Class", "name" => "new")
      ))
      expect(inferred).not_to include(a_hash_including(
        "callsite" => a_hash_including("line" => 7)
      ))
    end
  end

  it "preserves every observed runtime receiver type as a closed candidate set" do
    Dir.mktmpdir("nil-kill-runtime-scip-union-types", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.to_s
          end

          def inferred(value)
            value.to_s
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "inferred", "kind" => "instance",
          "path" => source, "line" => 6, "calls" => 2, "ok_calls" => 2,
          "raised_calls" => 0,
          "params_by_name" => { "value" => ["String", "Symbol"] },
          "params_ok" => { "value" => ["String", "Symbol"] }
        ) + "\n"
      )
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "union-types",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "to_s", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("Symbol")],
        root: root,
        runtime_dir: runtime_dir
      )
      targets = inferred.select { |row| row.dig("callsite", "line") == 7 }

      expect(targets.map { |row| row.dig("callee", "owner") }.sort)
        .to eq(["String", "Symbol"])
      expect(targets.map { |row| row.dig("callsite", "range") }.uniq)
        .to eq([[6, 10, 14]])
    end
  end

  it "propagates union element types into block receiver candidate sets" do
    Dir.mktmpdir("nil-kill-runtime-scip-block-union", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.to_s
          end

          def inferred(values)
            values.each { |value| value.to_s }
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "inferred", "kind" => "instance",
          "path" => source, "line" => 6, "calls" => 2, "ok_calls" => 2,
          "raised_calls" => 0,
          "params_by_name" => { "values" => ["Array"] },
          "params_ok" => { "values" => ["Array"] },
          "param_elem" => { "values" => ["String", "Symbol"] }
        ) + "\n"
      )
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "block-union",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "to_s", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("Symbol")],
        root: root,
        runtime_dir: runtime_dir
      )
      targets = inferred.select { |row| row.dig("callsite", "line") == 7 }

      expect(targets.map { |row| row.dig("callee", "owner") }.sort)
        .to eq(["String", "Symbol"])
    end
  end

  it "propagates singleton observed return types through local assignments" do
    Dir.mktmpdir("nil-kill-runtime-scip-return-types", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def normalize(value)
            value.to_s
          end

          def run(value)
            text = normalize(value)
            text.strip
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "normalize", "kind" => "instance",
          "path" => source, "line" => 2, "calls" => 1, "ok_calls" => 1,
          "raised_calls" => 0, "params_by_name" => { "value" => ["Object"] },
          "params_ok" => { "value" => ["Object"] }, "returns" => ["String"]
        ) + "\n"
      )
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "return-types",
        "caller" => {
          "class" => "Other", "method" => "observed", "kind" => "instance",
          "path" => source, "line" => 1,
        },
        "callsite" => { "path" => source, "line" => 1 },
        "callee" => {
          "owner" => "String", "name" => "strip", "kind" => "instance",
          "native" => true, "receiver_type" => "String",
          "package_manager" => "ruby", "package" => "ruby",
          "version" => RUBY_VERSION,
        },
        "count" => 1,
      }
      # The event supplies the observed String#strip dispatch domain; only the
      # method-return observation supplies `run`'s local receiver type.
      event["caller"] = {
        "class" => "Worker", "method" => "normalize", "kind" => "instance",
        "path" => source, "line" => 2,
      }
      event["callsite"] = { "path" => source, "line" => 3 }

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [
          event,
          event.merge(
            "callee" => event.fetch("callee").merge(
              "owner" => "OtherRenderer", "receiver_type" => "OtherRenderer"
            )
          ),
        ],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find { |row| row.dig("callsite", "line") == 8 }

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
      expect(target.dig("callsite", "range")).to eq([7, 9, 14])
    end
  end

  it "propagates observed return element types through local block bindings" do
    Dir.mktmpdir("nil-kill-runtime-scip-return-elements", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def values
            ["one"]
          end

          def observed(value)
            value.to_s
          end

          def inferred
            values.first(1).each { |row| row.to_s }
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        [
          {
            "class" => "Worker", "method" => "values", "kind" => "instance",
            "path" => source, "line" => 2, "calls" => 1, "ok_calls" => 1,
            "raised_calls" => 0, "params_by_name" => {},
            "params_ok" => {}, "returns" => ["Array"],
            "return_elem" => ["String"]
          },
          {
            "class" => "Worker", "method" => "inferred", "kind" => "instance",
            "path" => source, "line" => 10, "calls" => 1, "ok_calls" => 1,
            "raised_calls" => 0, "params_by_name" => {}, "params_ok" => {}
          },
        ].map { |row| JSON.generate(row) }.join("\n") + "\n"
      )
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "return-elements",
        "caller" => {
          "class" => "Worker", "method" => "observed", "kind" => "instance",
          "path" => source, "line" => 6,
        },
        "callsite" => { "path" => source, "line" => 7 },
        "callee" => {
          "owner" => "String", "name" => "to_s", "kind" => "instance",
          "native" => true, "receiver_type" => "String",
          "package_manager" => "ruby", "package" => "ruby",
          "version" => RUBY_VERSION,
        },
        "count" => 1,
      }

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [
          event,
          event.merge(
            "callee" => event.fetch("callee").merge(
              "owner" => "Symbol", "receiver_type" => "Symbol"
            )
          ),
        ],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 11 && row.dig("callee", "name") == "to_s"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "propagates collection value types through nested call receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-nested-receivers", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.strip
          end

          def inferred(row)
            row[:name].strip
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "inferred", "kind" => "instance",
          "path" => source, "line" => 6, "calls" => 1, "ok_calls" => 1,
          "raised_calls" => 0,
          "params_by_name" => { "row" => ["Hash"] },
          "params_ok" => { "row" => ["Hash"] },
          "param_kv" => { "row" => [["Symbol"], ["String"]] }
        ) + "\n"
      )
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "nested-receivers",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "strip", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("OtherString")],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 7 && row.dig("callee", "name") == "strip"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "propagates observed hash shapes from collection elements into block receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-element-shapes", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.strip
          end

          def inferred(rows)
            rows.each { |row| row[:name].strip }
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "inferred", "kind" => "instance",
          "path" => source, "line" => 6, "calls" => 1, "ok_calls" => 1,
          "raised_calls" => 0,
          "params_by_name" => { "rows" => ["Array"] },
          "params_ok" => { "rows" => ["Array"] },
          "param_elem" => { "rows" => ["Hash"] },
          "param_elem_shapes" => {
            "rows" => [{
              "kind" => "hash",
              "keys" => [{ "kind" => "class", "name" => "Symbol" }],
              "values" => [{ "kind" => "class", "name" => "String" }],
            }]
          }
        ) + "\n"
      )
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "element-shapes",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "strip", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("OtherString")],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 7 && row.dig("callee", "name") == "strip"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "propagates literal hash and array shapes into block receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-literal-shapes", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.strip
          end

          def inferred
            rows = [{ name: "Ada" }]
            rows.each { |row| row[:name].strip }
          end
        end
      RUBY
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "literal-shapes",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "strip", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("OtherString")],
        root: root
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 8 && row.dig("callee", "name") == "strip"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "propagates map block result shapes into downstream block receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-map-shapes", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.strip
          end

          def inferred(rows)
            names = rows.map { |row| row[:name] }
            names.each { |name| name.strip }
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "inferred", "kind" => "instance",
          "path" => source, "line" => 6, "calls" => 1, "ok_calls" => 1,
          "raised_calls" => 0,
          "params_by_name" => { "rows" => ["Array"] },
          "params_ok" => { "rows" => ["Array"] },
          "param_elem" => { "rows" => ["Hash"] },
          "param_elem_shapes" => {
            "rows" => [{
              "kind" => "hash",
              "keys" => [{ "kind" => "class", "name" => "Symbol" }],
              "values" => [{ "kind" => "class", "name" => "String" }],
            }]
          }
        ) + "\n"
      )
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "map-shapes",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "strip", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("OtherString")],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 8 && row.dig("callee", "name") == "strip"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "propagates each_with_object argument shapes into accumulator receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-each-with-object", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def observed(out)
            out[:name] = "Ada"
          end

          def inferred(values)
            values.each_with_object({}) do |value, out|
              out[value] = "seen"
            end
          end
        end
      RUBY
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "each-with-object",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "[]=", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("Hash"), event.call("OtherHash")],
        root: root
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 8 && row.dig("callee", "name") == "[]="
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("Hash")
    end
  end

  it "propagates reduce initial-value shapes into accumulator receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-reduce", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value + "!"
          end

          def inferred(words)
            words.reduce("") { |memo, word| memo + word }
          end
        end
      RUBY
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "reduce",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "+", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("OtherString")],
        root: root
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 7 && row.dig("callee", "name") == "+"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "fails closed when destructuring exposes more block parameters than known domains" do
    Dir.mktmpdir("nil-kill-runtime-scip-destructuring", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.to_s
          end

          def inferred(pairs)
            pairs.each { |key, value| value.to_s }
          end
        end
      RUBY
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "destructuring",
        "caller" => {
          "class" => "Worker", "method" => "observed", "kind" => "instance",
          "path" => source, "line" => 2,
        },
        "callsite" => { "path" => source, "line" => 3 },
        "callee" => {
          "owner" => "String", "name" => "to_s", "kind" => "instance",
          "native" => true, "receiver_type" => "String",
          "package_manager" => "ruby", "package" => "ruby",
          "version" => RUBY_VERSION,
        },
        "count" => 1,
      }

      expect do
        NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
          events: [event],
          root: root
        )
      end.not_to raise_error
    end
  end

  it "propagates appended element shapes from initially empty collections" do
    Dir.mktmpdir("nil-kill-runtime-scip-appended-shapes", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.strip
          end

          def inferred
            rows = []
            rows << { name: "Ada" }
            rows.each { |row| row[:name].strip }
          end
        end
      RUBY
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "appended-shapes",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "strip", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("OtherString")],
        root: root
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 9 && row.dig("callee", "name") == "strip"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "propagates appended generated-record owners into block receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-appended-records", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        Node = Struct.new(:kind)
        OtherNode = Struct.new(:kind)

        class Worker
          def observed(node)
            node.kind
          end

          def inferred
            nodes = []
            nodes << Node.new(:root)
            nodes.each { |node| node.kind }
          end
        end
      RUBY
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "appended-records",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 5,
          },
          "callsite" => { "path" => source, "line" => 6 },
          "callee" => {
            "owner" => owner, "name" => "kind", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "workspace",
            "version" => "1",
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("Node"), event.call("OtherNode")],
        root: root
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 12 && row.dig("callee", "name") == "kind"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("Node")
    end
  end

  it "propagates indexed value shapes from initially empty hashes" do
    Dir.mktmpdir("nil-kill-runtime-scip-indexed-shapes", NilKill::ROOT) do |root|
      source = File.join(root, "worker.rb")
      File.write(source, <<~RUBY)
        class Worker
          def observed(value)
            value.strip
          end

          def inferred
            index = {}
            index[:name] = "Ada"
            index[:name].strip
          end
        end
      RUBY
      event = lambda do |owner|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "indexed-shapes",
          "caller" => {
            "class" => "Worker", "method" => "observed", "kind" => "instance",
            "path" => source, "line" => 2,
          },
          "callsite" => { "path" => source, "line" => 3 },
          "callee" => {
            "owner" => owner, "name" => "strip", "kind" => "instance",
            "native" => true, "receiver_type" => owner,
            "package_manager" => "ruby", "package" => "ruby",
            "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [event.call("String"), event.call("OtherString")],
        root: root
      )
      target = inferred.find do |row|
        row.dig("callsite", "line") == 9 && row.dig("callee", "name") == "strip"
      end

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("String")
    end
  end

  it "propagates constructor parameter observations into instance-field receivers" do
    Dir.mktmpdir("nil-kill-runtime-scip-ivar-types", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, <<~RUBY)
        class Worker
          def initialize(renderer)
            @renderer = renderer
          end

          def observed(renderer)
            renderer.render
          end

          def inferred
            @renderer.render
          end
        end
      RUBY
      File.write(
        File.join(runtime_dir, "methods-1.jsonl"),
        JSON.generate(
          "class" => "Worker", "method" => "initialize", "kind" => "instance",
          "path" => source, "line" => 2, "calls" => 1, "ok_calls" => 1,
          "raised_calls" => 0,
          "params_by_name" => { "renderer" => ["Renderer"] },
          "params_ok" => { "renderer" => ["Renderer"] }
        ) + "\n"
      )
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "ivar-types",
        "caller" => {
          "class" => "Worker", "method" => "observed", "kind" => "instance",
          "path" => source, "line" => 6,
        },
        "callsite" => { "path" => source, "line" => 7 },
        "callee" => {
          "owner" => "Renderer", "name" => "render", "kind" => "instance",
          "native" => false, "receiver_type" => "Renderer",
          "package_manager" => "workspace", "package" => "demo",
          "version" => "1",
        },
        "count" => 1,
      }

      inferred = NilKill::Languages::Providers::Ruby.new.runtime_scip_inferred_events(
        events: [
          event,
          event.merge(
            "callee" => event.fetch("callee").merge(
              "owner" => "OtherRenderer", "receiver_type" => "OtherRenderer"
            )
          ),
        ],
        root: root,
        runtime_dir: runtime_dir
      )
      target = inferred.find { |row| row.dig("callsite", "line") == 11 }

      expect(target).not_to be_nil
      expect(target.dig("callee", "owner")).to eq("Renderer")
    end
  end

  it "emits exact Ruby compound-write and nested-index selector locations" do
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
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "operators",
          "caller" => {
            "class" => "Object", "method" => "run", "kind" => "instance",
            "path" => source, "line" => 1,
          },
          "callsite" => { "path" => source, "line" => line },
          "callee" => {
            "owner" => owner, "name" => name, "kind" => "instance",
            "native" => true, "package_manager" => "ruby",
            "package" => "ruby", "version" => RUBY_VERSION,
          },
          "count" => 1,
        }
      end
      events = [
        event.call("+", "Integer", 2),
        event.call("-", "Integer", 3),
        event.call("[]", "Array", 4),
        event.call("min", "Array", 6),
      ]
      File.write(
        File.join(runtime_dir, "runtime-calls-1.jsonl"),
        events.map { |row| JSON.generate(row) }.join("\n") + "\n"
      )

      result = described_class.emit(root: root, runtime_dir: runtime_dir)
      index = JSON.parse(File.read(result.fetch("index")))
      occurrences = index.fetch("documents").first.fetch("occurrences")

      expect(occurrences).to include(
        a_hash_including("range" => [1, 8, 10], "symbol" => a_string_including("#`+`()")),
        a_hash_including("range" => [2, 8, 10], "symbol" => a_string_including("#`-`()")),
        a_hash_including("range" => [3, 8, 9], "symbol" => a_string_including("#`[]`()")),
        a_hash_including("range" => [4, 8, 9], "symbol" => a_string_including("#`[]`()")),
        a_hash_including("range" => [4, 15, 16], "symbol" => a_string_including("#`[]`()")),
        a_hash_including("range" => [5, 13, 16], "symbol" => a_string_including("#min()"))
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
