# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/nil_kill/native/command"
require_relative "../lib/nil_kill/native/co_update"
require_relative "../lib/nil_kill/native/flay_similarity"
require_relative "../lib/nil_kill/native/predicate_aliases"
require_relative "../lib/nil_kill/runtime_trace"

RSpec.describe "NilKill coverage hardening" do
  def capture_io
    old_stdout = $stdout
    old_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    [$stdout.string, $stderr.string]
  ensure
    $stdout = old_stdout
    $stderr = old_stderr
  end

  def status(success)
    instance_double(Process::Status, success?: success)
  end

  describe NilKill::CLI do
    before do
      allow(NilKill).to receive(:ensure_src_restored!)
    end

    it "dispatches supported subcommands to their command objects" do
      cases = [
        ["static", NilKill::Commands::StaticCommand],
        ["collect-runtime", NilKill::Commands::CollectRuntimeCommand],
        ["collect-python", NilKill::Commands::CollectPythonCommand],
        ["normalize", NilKill::Commands::NormalizeCommand],
        ["analyze", NilKill::Commands::AnalyzeCommand],
        ["trace-spec", NilKill::Commands::TraceSpecCommand],
        ["focus-hash-record", NilKill::FocusHashRecord],
        ["struct-rbi", NilKill::StructRBI],
      ]

      cases.each do |command, klass|
        runner = instance_double(klass, run: true)
        expect(klass).to receive(:new).with(["--flag"]).and_return(runner)
        described_class.new([command, "--flag"]).run
      end
    end

    it "runs infer only after the runtime freshness guard" do
      runner = instance_double(NilKill::Infer, run: true)
      cli = described_class.new(["infer", "--allow-stale-runtime"])

      expect(cli).to receive(:guard_fresh_runtime!).and_call_original
      expect(NilKill::Infer).to receive(:new).with([]).and_return(runner)

      cli.run
    end

    it "runs report with explicit evidence without invoking stale evidence guard" do
      runner = instance_double(NilKill::Report, run: true)
      cli = described_class.new(["report", "--evidence", "tmp/evidence.json"])

      expect(cli).not_to receive(:guard_fresh_evidence!)
      expect(NilKill::Report).to receive(:new).with(["--evidence", "tmp/evidence.json"]).and_return(runner)

      cli.run
    end

    it "prints help for help and exits on unknown commands" do
      out, = capture_io { described_class.new(["help"]).run }
      expect(out).to include("bundle exec tools/nil-kill collect")

      expect do
        capture_io { described_class.new(["unknown"]).run }
      end.to raise_error(SystemExit) { |error| expect(error.status).to eq(2) }
    end

    it "parses command files, command strings, globs, templates, and trailing commands" do
      Dir.mktmpdir do |dir|
        command_file = File.join(dir, "commands.txt")
        File.write(command_file, "# ignored\nruby -e 'puts 1'\n\nbundle exec rspec\n")
        a = File.join(dir, "a.rb")
        b = File.join(dir, "b.rb")
        File.write(a, "")
        File.write(b, "")

        cli = described_class.new([
          "collect",
          "--commands", command_file,
          "--cmd", "ruby -w",
          "--glob", File.join(dir, "*.rb"),
          "--template", "ruby {file}",
          "--", "bundle", "exec", "ruby", "script.rb",
        ])

        commands = cli.send(:collect_commands)
        expect(commands).to include(["ruby", "-e", "puts 1"])
        expect(commands).to include(["bundle", "exec", "rspec"])
        expect(commands).to include(["ruby", "-w"])
        expect(commands).to include(["ruby", a], ["ruby", b])
        expect(commands).to include(["bundle", "exec", "ruby", "script.rb"])
      end
    end

    it "writes and compares collect metadata by content, not mtime alone" do
      Dir.mktmpdir do |dir|
        cli = described_class.new([])
        meta = File.join(dir, "collect-meta.json")
        allow(cli).to receive(:collect_meta_path).and_return(meta)

        allow(cli).to receive(:git_capture) do |*args|
          case args
          when ["rev-parse", "HEAD"] then "abc123\n"
          when ["status", "--porcelain", "--", *NilKill.target_dirs] then ""
          else nil
          end
        end

        cli.send(:write_collect_meta!)
        expect(JSON.parse(File.read(meta))).to include("head" => "abc123", "dirty" => "")
        expect(cli.send(:targets_changed_since_collect)).to be(false)

        allow(cli).to receive(:git_capture) do |*args|
          case args
          when ["rev-parse", "HEAD"] then "def456"
          when ["status", "--porcelain", "--", *NilKill.target_dirs] then " M src/app.rb\n"
          when ["diff", "--name-only", "abc123..def456", "--", *NilKill.target_dirs] then "src/app.rb\n"
          else nil
          end
        end

        expect(cli.send(:targets_changed_since_collect)).to eq(["abc123", "def456", ["src/app.rb"]])
      end
    end

    it "uses conservative runtime/evidence guards and supports the stale override" do
      cli = described_class.new(["--allow-stale-runtime"])
      expect { cli.send(:guard_fresh_runtime!) }.not_to raise_error

      cli = described_class.new([])
      allow(Dir).to receive(:glob).with(File.join(NilKill::RUNTIME_DIR, "*.jsonl")).and_return([])
      expect { capture_io { cli.send(:guard_fresh_runtime!) } }.to raise_error(SystemExit)

      Dir.mktmpdir do |dir|
        evidence = File.join(dir, "evidence.json")
        File.write(evidence, "{}")
        stub_const("NilKill::EVIDENCE_PATH", evidence)
        cli = described_class.new([])
        allow(cli).to receive(:targets_changed_since_collect).and_return(["oldhead", "newhead", Array.new(10) { |i| "src/f#{i}.rb" }])

        expect { capture_io { cli.send(:guard_fresh_evidence!) } }.to raise_error(SystemExit)
      end
    end

    it "falls back to mtimes when git metadata is unknown" do
      Dir.mktmpdir do |dir|
        src = File.join(dir, "src.rb")
        File.write(src, "1")
        allow(NilKill).to receive(:target_files).and_return([src])

        old_runtime = Time.now - 60
        new_runtime = Time.now + 60
        expect(described_class.new([]).send(:mtime_stale?, old_runtime)).to be(true)
        expect(described_class.new([]).send(:mtime_stale?, new_runtime)).to be(false)
      end
    end

    it "runs collect with instrumentation, trace-plan setup, worker env, and cleanup" do
      cli = described_class.new(["collect", "--continue-on-error", "--", "ruby", "-e", "0"])
      allow(cli).to receive(:collect_commands).and_return([["ruby", "-e", "0"], ["ruby", "-e", "1"]])
      allow(cli).to receive(:write_collect_meta!)
      allow(cli).to receive(:acquire_inplace_lock!)
      allow(cli).to receive(:install_inplace_restore_traps!)
      allow(cli).to receive(:assert_collect_coverage_produced!)
      allow(NilKill::TracePlan).to receive(:write)
      allow(NilKill).to receive(:target_files).and_return(["src/app.rb"])
      allow(NilKill).to receive(:write_inplace_sentinel!)
      allow(NilKill).to receive(:restore_inplace_snapshot!)
      instrumenter = instance_double(NilKill::SourceInstrumenter, run_in_place: true)
      expect(NilKill::SourceInstrumenter).to receive(:new).and_return(instrumenter)
      seen_env = []
      allow(cli).to receive(:system) do |env, *cmd|
        seen_env << env
        expect(cmd).to eq(["ruby", "-e", seen_env.size == 1 ? "0" : "1"])
        seen_env.size == 1
      end

      capture_io { cli.run }

      expect(NilKill::TracePlan).to have_received(:write)
      expect(NilKill).to have_received(:restore_inplace_snapshot!)
      expect(seen_env.first).to include("NIL_KILL_TRACE" => "1")
      expect(seen_env.first["RUBYOPT"]).to include("runtime_trace.rb")
      expect(seen_env.first["NIL_KILL_TRACE_METHODS"]).to eq("0")
    end

    it "surfaces focused hash-record actions and doctor dependency probes" do
      Dir.mktmpdir("nil-kill-focus", NilKill::ROOT) do |dir|
        src = File.join(dir, "src", "record.rb")
        FileUtils.mkdir_p(File.dirname(src))
        File.write(src, "record = {name: 'Ada'}\n")
        action = {
          "kind" => "promote_hash_record_cluster_to_struct",
          "data" => {
            "struct_name" => "UserRecord",
            "pressure" => { "total" => 3 },
            "producers" => [{ "path" => src }],
            "consumers" => [{ "path" => src }],
            "signatures" => [{ "path" => src }],
            "blockers" => [],
          },
        }

        allow(NilKill::Store).to receive(:read).and_return("actions" => [action])
        store = instance_double(NilKill::Store, actions: [action])
        allow(NilKill::Store).to receive(:new).and_return(store)
        allow(NilKill::StaticAnalysis).to receive(:index_store)
        allow_any_instance_of(NilKill::Infer).to receive(:propose_hash_record_cluster_actions)

        out, = capture_io { NilKill::FocusHashRecord.new(["UserRecord"]).run }
        expect(out).to include("focused hash-record UserRecord", "pressure: 3")

        doctor = NilKill::Doctor.new
        allow(NilKill).to receive(:target_dirs).and_return([File.join(NilKill::ROOT, "src")])
        allow(NilKill).to receive(:target_exclude_dirs).and_return([File.join(NilKill::ROOT, "tmp")])
        allow(Open3).to receive(:capture3).and_return(["", "", status(false)])
        allow(doctor).to receive(:gem_ok?).and_return(nil)
        out, = capture_io { doctor.run }
        expect(out).to include("ruby:", "sorbet: missing/error", "excluded targets:")
      end
    end

    it "covers doctor dispatch, stale guards, collect failure exits, and evidence assertions" do
      doctor = instance_double(NilKill::Doctor, run: true)
      expect(NilKill::Doctor).to receive(:new).and_return(doctor)
      described_class.new(["doctor"]).run

      cli = described_class.new([])
      expect(cli.send(:explicit_evidence_path?, ["--evidence=tmp/evidence.json"])).to be(true)
      expect(cli.send(:explicit_evidence_path?, ["--flag"])).to be(false)

      allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT)
      expect(cli.send(:git_capture, "status")).to be_nil

      allow(cli).to receive(:collect_meta_path).and_return("/missing/meta.json")
      expect(cli.send(:targets_changed_since_collect)).to eq(:unknown)

      runtime_file = File.join(Dir.tmpdir, "nil-kill-runtime-guard.jsonl")
      File.write(runtime_file, "{}")
      stale_cli = described_class.new([])
      allow(Dir).to receive(:glob).and_call_original
      allow(Dir).to receive(:glob).with(File.join(NilKill::RUNTIME_DIR, "*.jsonl")).and_return([runtime_file])
      allow(stale_cli).to receive(:targets_changed_since_collect).and_return(["oldsha12345", "newsha67890", Array.new(10) { |i| "src/f#{i}.rb" }])
      expect { capture_io { stale_cli.send(:guard_fresh_runtime!) } }.to raise_error(SystemExit)

      evidence_cli = described_class.new([])
      stub_const("NilKill::TMP_DIR", Dir.mktmpdir("nil-kill-missing-evidence", NilKill::ROOT))
      expect { capture_io { evidence_cli.send(:guard_fresh_evidence!) } }.to raise_error(SystemExit)

      failing_collect = described_class.new(["collect", "--no-instrument-source", "--", "ruby", "-e", "exit 1"])
      allow(failing_collect).to receive(:collect_commands).and_return([["ruby", "-e", "exit 1"]])
      allow(failing_collect).to receive(:write_collect_meta!)
      allow(failing_collect).to receive(:system).and_return(false)
      allow(failing_collect).to receive(:assert_collect_coverage_produced!)
      allow(NilKill::TracePlan).to receive(:write)
      expect { capture_io { failing_collect.send(:collect) } }.to raise_error(SystemExit)

      lock_cli = described_class.new([])
      fake_file = instance_double(File, flock: false)
      allow(File).to receive(:open).and_return(fake_file)
      expect { capture_io { lock_cli.send(:acquire_inplace_lock!) } }.to raise_error(SystemExit)

      assert_cli = described_class.new([])
      allow(Dir).to receive(:glob).with(File.join(NilKill::RUNTIME_DIR, "coverage-*.jsonl")).and_return([runtime_file])
      allow(Dir).to receive(:glob).with(File.join(NilKill::RUNTIME_DIR, "methods-*.jsonl")).and_return([])
      expect { capture_io { assert_cli.send(:assert_collect_coverage_produced!) } }.to raise_error(SystemExit)
    ensure
      FileUtils.rm_f(runtime_file) if defined?(runtime_file)
    end
  end

  describe NilKill::Commands::CollectRuntimeCommand do
    it "parses options and delegates to the requested language provider" do
      provider = instance_double(NilKill::Languages::Provider)
      expect(NilKill::Languages).to receive(:provider_for).with("python").and_return(provider)
      expect(provider).to receive(:collect_runtime).with(
        argv: ["--", "pytest"],
        root: File.expand_path("."),
        output: File.expand_path("tmp/runtime", NilKill::ROOT),
        targets: ["app", "lib"],
        append: true
      )

      described_class.new([
        "--language=python",
        "--output", "tmp/runtime",
        "--target", "app",
        "--target=lib",
        "--append-runtime",
        "--", "pytest",
      ]).run
    end

    it "turns unsupported runtime tracers into a user-facing abort" do
      provider = instance_double(NilKill::Languages::Provider)
      allow(NilKill::Languages).to receive(:provider_for).and_return(provider)
      allow(provider).to receive(:collect_runtime).and_raise(NilKill::Languages::UnsupportedRuntimeTracer, "no tracer")

      expect { capture_io { described_class.new(["--language", "go", "--", "go", "test"]).run } }.to raise_error(SystemExit)
    end
  end

  describe NilKill::Commands::AnalyzeCommand do
    it "requires normalized v2 evidence and writes analyzed actions" do
      Dir.mktmpdir do |dir|
        evidence_path = File.join(dir, "evidence.json")
        output_path = File.join(dir, "out", "evidence.json")
        evidence = NilKill::Schema::EvidenceBundle.build(root: dir, static: {}, runtime: {})
        File.write(evidence_path, JSON.pretty_generate(evidence))

        analyzer = instance_double(NilKill::Analyzers::RuntimeEvidenceAnalyzer, analyze: [{"kind" => "fix_sig_return"}])
        expect(NilKill::Analyzers::RuntimeEvidenceAnalyzer).to receive(:new).and_return(analyzer)

        out, = capture_io do
          described_class.new(["--evidence=#{evidence_path}", "--output", output_path]).run
        end

        written = JSON.parse(File.read(output_path))
        expect(written["actions"]).to eq([{"kind" => "fix_sig_return"}])
        expect(out).to include("wrote analyzed evidence")
      end
    end
  end

  describe NilKill::Commands::CollectPythonCommand do
    it "is a python-specific wrapper around collect-runtime" do
      runner = instance_double(NilKill::Commands::CollectRuntimeCommand, run: true)
      expect(NilKill::Commands::CollectRuntimeCommand).to receive(:new).with(["--language", "python", "--", "pytest"]).and_return(runner)

      described_class.new(["--", "pytest"]).run
    end
  end

  describe NilKill::Commands::TraceSpecCommand do
    it "publishes the runtime event schema and current language capabilities" do
      spec = described_class.new([]).spec
      expect(spec["required_common_fields"]).to include("schema_version", "language", "payload")
      expect(spec["required_minimum_events"]).to include("method_call", "coverage")
      expect(spec["language_capabilities"].map { |capability| capability["language"] }).to include("python")
    end
  end

  describe NilKill::Languages::Providers::Python do
    it "builds a Python tracing environment and honors append mode" do
      provider = described_class.new

      Dir.mktmpdir do |dir|
        output = File.join(dir, "trace")
        FileUtils.mkdir_p(output)
        stale = File.join(output, "old.jsonl")
        File.write(stale, "old")

        expect(provider).to receive(:system) do |env, *cmd, chdir:|
          expect(env).to include(
            "NIL_KILL_PY_TRACE" => "1",
            "NIL_KILL_PY_TRACE_OUT" => output,
            "NIL_KILL_TRACE_ROOT" => dir,
          )
          expect(env["NIL_KILL_TARGETS"].split(File::PATH_SEPARATOR)).to eq([File.join(dir, "src")])
          expect(env["PYTHONPATH"]).to include("gems/nil-kill/lib")
          expect(cmd).to eq(["python", "-m", "pytest"])
          expect(chdir).to eq(dir)
          true
        end

        out, = capture_io do
          provider.collect_runtime(
            argv: ["--", "python", "-m", "pytest"],
            root: dir,
            output: output,
            targets: ["src"],
            append: false
          )
        end

        expect(File).not_to exist(stale)
        expect(out).to include("wrote Python trace events")
      end
    end
  end

  describe NilKill::HashShapeOps do
    it "deep-copies, merges, stringifies, and preserves poisoned shapes" do
      left = {
        "keys" => { :id => ["Integer"] },
        "value_hash_shapes" => { :meta => { "keys" => { :name => ["String"] }, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false } },
        "value_array_element_shapes" => {},
        "poisoned" => false,
      }
      right = {
        "keys" => { :id => ["Integer"], :active => ["TrueClass"] },
        "value_hash_shapes" => { :meta => { "keys" => { :name => ["String"], :age => ["Integer"] }, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false } },
        "value_array_element_shapes" => { :items => { "keys" => { :sku => ["String"] }, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false } },
        "poisoned" => false,
      }

      copy = described_class.dup_shape(left, stringify_keys: true)
      expect(copy["keys"]).to eq("id" => ["Integer"])
      copy["keys"]["id"] << "String"
      expect(left["keys"][:id]).to eq(["Integer"])

      merged = described_class.merge_shapes(left, right, stringify_keys: true)
      expect(merged["keys"]).to include("id" => ["Integer"], "active" => ["TrueClass"])
      expect(merged.dig("value_hash_shapes", "meta", "keys")).to include("name" => ["String"], "age" => ["Integer"])
      expect(merged.dig("value_array_element_shapes", "items", "keys")).to eq("sku" => ["String"])
      expect(described_class.merge_shapes(left, described_class.poisoned_shape)).to eq(described_class.poisoned_shape)
    end
  end

  describe NilKill::Languages::Providers::Ruby::Sorbet do
    it "extracts only real Sorbet signatures and RBI field types" do
      provider = described_class.new
      function = double("function", signature: "sig { returns(String) }")
      expect(provider.method_source(function)).to include("type_system" => "sorbet", "sig" => "sig { returns(String) }")
      expect(provider.method_source(double("function", signature: "returns(String)"))).to eq({})

      Dir.mktmpdir do |dir|
        rbi = File.join(dir, "sorbet", "rbi", "models.rbi")
        FileUtils.mkdir_p(File.dirname(rbi))
        File.write(rbi, <<~RBI)
          class User
            sig { returns(String) }
            def name; end
            def dynamic; end
          end
        RBI

        expect(provider.field_type_index(root: dir)).to include(["User", "name"] => "String", ["User", "dynamic"] => "T.untyped")
      end
    end
  end

  describe NilKill::StructRBI do
    let(:evidence) do
      {
        "facts" => {
          "struct_declarations" => [
            { "class" => "User", "line" => 1, "fields" => ["name", "age"] },
          ],
          "struct_field_runtime" => [
            { "class" => "User", "field" => "name", "types" => ["String"] },
          ],
          "struct_field_static" => [
            { "class" => "User", "field" => "age", "type" => "Integer" },
          ],
        },
      }
    end

    before do
      allow(NilKill::Store).to receive(:read).and_return(evidence)
    end

    it "generates complete RBI using candidates, existing RBI types, and validation blocklists" do
      report = instance_double(NilKill::Report, struct_field_candidates: [
        { "class" => "User", "field" => "name", "type" => "String" },
        { "class" => "User", "field" => "age", "type" => "Integer" },
      ])
      allow(NilKill::Report).to receive(:new).and_return(report)

      rbi = described_class.new(["--complete"]).tap do |generator|
        allow(generator).to receive(:existing_rbi_types).and_return(["User", "age"] => "Integer")
      end

      text = rbi.generate
      expect(text).to include("class User", "def name; end", "returns(String)", "def age; end", "returns(Integer)")

      rbi.instance_variable_set(:@blocklist, Set["age"])
      expect(rbi.generate).to include("def age; end", "returns(T.untyped)")
    end

    it "extracts offending methods from multiple Sorbet diagnostic shapes" do
      Dir.mktmpdir do |dir|
        out = File.join(dir, "structs.rbi")
        File.write(out, "class User\n  sig { returns(String) }\n  def name; end\nend\n")
        generator = described_class.new(["--output", out])
        text = <<~SRB
          Got `String` originating from:
              app/models/user.rb:1: user.name
          app.rb:2: Expected `String` but found `Integer` for argument `age` https://srb.help/7002
              2 | user.age
          #{out}:2: Method result type does not match https://srb.help/7005
        SRB

        expect(generator.extract_offending_methods(text)).to include("name", "age")
      end
    end

    it "runs print/output generation paths and honors existing RBI slots" do
      report = instance_double(NilKill::Report, struct_field_candidates: [
        { "class" => "User", "field" => "name", "type" => "String" },
        { "class" => "User", "field" => "age", "type" => "Integer" },
      ])
      allow(NilKill::Report).to receive(:new).and_return(report)

      printed, = capture_io do
        generator = described_class.new([])
        allow(generator).to receive(:existing_rbi_types).and_return(["User", "age"] => "Integer")
        generator.run
      end
      expect(printed).to include("def name; end")
      expect(printed).not_to include("def age; end")

      Dir.mktmpdir("nil-kill-struct-rbi", NilKill::ROOT) do |dir|
        out = File.join(dir, "out", "structs.rbi")
        generator = described_class.new(["--output", out, "--include-existing-rbi"])
        allow(generator).to receive(:existing_rbi_types).and_return(["User", "age"] => "Integer")

        output, = capture_io { generator.run }

        expect(output).to include("wrote")
        expect(File.read(out)).to include("def name; end", "def age; end")
        expect(generator.existing_rbi_slots).to include(["User", "age"])
      end
    end

    it "iteratively validates generated RBI and restores on non-convergence" do
      report = instance_double(NilKill::Report, struct_field_candidates: [
        { "class" => "User", "field" => "name", "type" => "String" },
      ])
      allow(NilKill::Report).to receive(:new).and_return(report)

      Dir.mktmpdir("nil-kill-struct-validate", NilKill::ROOT) do |dir|
        out = File.join(dir, "structs.rbi")
        generator = described_class.new(["--complete", "--validate", "--output", out, "--validate-max-iters", "3"])
        calls = 0
        allow(Open3).to receive(:capture3) do
          calls += 1
          if calls == 1
            ["app.rb:1: Expected `String` for argument `name`\n    1 | user.name\n", "", status(false)]
          else
            ["", "", status(true)]
          end
        end

        stdout, stderr = capture_io { generator.run }

        expect(stdout).to include("validated clean")
        expect(stderr).to include("dropping 1 offending method")
        expect(generator.instance_variable_get(:@blocklist)).to include("name")
      end

      Dir.mktmpdir("nil-kill-struct-validate-fail", NilKill::ROOT) do |dir|
        out = File.join(dir, "structs.rbi")
        File.write(out, "original")
        generator = described_class.new(["--complete", "--validate", "--output", out, "--validate-max-iters", "1"])
        allow(Open3).to receive(:capture3).and_return(["unparseable sorbet output\n", "", status(false)])

        expect { capture_io { generator.run } }.to raise_error(RuntimeError, /validate failed/)
        expect(File.read(out)).to eq("original")
      end
    end
  end

  describe NilKill::FlowGraph do
    it "queries reachability, labels hash-record origins, and imports runtime observations" do
      graph = described_class.new
      graph.add_node(:source, "a", types: ["String"])
      graph.add_edge(:unknown_edge_kind, "a", "b", "line" => 1, "code" => "a")
      graph.add_edge(:unknown_edge_kind, "a", "b", "line" => 1, "code" => "a")
      graph.add_edge(:call_argument, "b", "c")

      expect(graph.outgoing("a").size).to eq(1)
      expect(graph.incoming("b").size).to eq(1)
      expect(graph.reachable?("a", "c")).to be(true)
      expect(graph.reachable?("a", "c", edge_kinds: [:hash_read])).to be(false)
      expect(graph.to_h.fetch("edges").map { |edge| edge["kind"] }).to include("assignment", "call_argument")

      lookups = [
        { "origin" => { "kind" => "method parameter", "path" => "src/a.rb", "line" => 3, "name" => "record" }, "index" => ":name" },
        { "origin" => { "kind" => "method parameter", "name" => "record" }, "index" => ":name" },
        { "origin" => { "kind" => "array literal", "path" => "src/a.rb", "line" => 4, "name" => "records" }, "index" => "'id'" },
        { "origin" => { "kind" => "forwarded return", "path" => "src/a.rb", "line" => 5, "callee" => "load_record" }, "index" => ":id" },
        { "origin" => { "kind" => "instance variable", "name" => "@record" }, "index" => ":state" },
        { "path" => "src/a.rb", "line" => 8, "receiver" => "", "index" => "dynamic" },
        { "path" => "src/a.rb", "line" => 9, "receiver" => "local", "enclosing_scope" => "A#call", "index" => ":name" },
      ]

      labels = lookups.map { |lookup| graph.hash_record_label_for_lookup(lookup) }
      expect(labels).to include("method parameter hash record record", "unknown hash record")
      expect(graph.hash_record_identity_for_lookup(lookups.first)).to end_with("[:name]")
      expect(graph.hash_record_identity_for_lookup(lookups.first, include_field: false)).not_to end_with("[:name]")

      source = { "path" => "src/a.rb", "line" => 20, "class" => "A", "method" => "call", "kind" => "instance", "params" => [{ "name" => "items", "type" => "T::Array[T.untyped]" }], "sig" => "sig { params(items: T::Array[T.untyped]).returns(T.untyped) }" }
      evidence = {
        "facts" => {
          "existing_sigs" => [source],
          "unsigned_methods" => [],
          "return_origins" => [
            source.merge("return_syntax" => "explicit", "candidate_type" => "String", "sources" => [
              { "kind" => "static", "type" => "String", "line" => 21, "code" => '"ok"' },
              { "kind" => "call_untyped", "callee" => "helper", "line" => 22, "code" => "helper" },
            ]),
          ],
          "param_origins" => [
            { "path" => "src/a.rb", "line" => 30, "callee" => "call", "arg_kind" => "positional", "slot" => "0", "origin_kind" => "typed_return", "source_method" => "builder", "type" => "T::Array[String]", "code" => "call(builder)" },
          ],
          "collection_index_lookups" => lookups,
          "struct_field_static" => [
            { "path" => "src/a.rb", "line" => 40, "class" => "A::Record", "field" => "name", "type" => "String", "expression" => '"Ada"' },
          ],
          "collection_runtime" => [
            { "path" => "src/a.rb", "line" => 20, "owner_kind" => "method_param", "name" => "items", "kind" => "array", "elem_classes" => ["String"], "type" => "String" },
          ],
        },
        "methods" => [
          {
            "source" => source,
            "calls" => 2,
            "returns" => ["String"],
            "params_by_name" => { "items" => ["Array"] },
          },
        ],
      }

      imported = described_class.from_evidence(evidence)
      expect(imported.edges).to include(a_hash_including("kind" => "explicit_return"))
      expect(imported.edges).to include(a_hash_including("kind" => "call_result", "from" => "return:method_name:builder"))
      expect(imported.types_for("runtime_collection:method_param:src/a.rb:20:items:array")).to include("String")
    end
  end

  describe Decomplex::Native::Command do
    it "uses an explicit fresh native binary and returns stdout on success" do
      Dir.mktmpdir do |dir|
        bin = File.join(dir, "decomplex-rust")
        File.write(bin, "#!/bin/sh\n")
        File.chmod(0o755, bin)

        isolated_env("DECOMPLEX_RUST_BIN" => bin) do
          expect(Open3).to receive(:capture3).with(bin, "co-update").and_return(["ok", "", status(true)])
          expect(described_class.run("co-update")).to eq("ok")
        end
      end
    end

    it "falls back to cargo, validates jobs, and surfaces native failures" do
      isolated_env("DECOMPLEX_RUST_BIN" => nil) do
        expect(described_class.jobs_args(nil)).to eq([])
        expect(described_class.jobs_args("2")).to eq(["--jobs", "2"])
        expect { described_class.jobs_args("0") }.to raise_error(ArgumentError, /greater than zero/)

        expect(Open3).to receive(:capture3).and_return(["stdout failure", "", status(false)])
        expect { described_class.run("predicate-aliases") }.to raise_error(RuntimeError, /stdout failure/)

        expect(Open3).to receive(:capture3).and_raise(Errno::ENOENT.new("cargo"))
        expect { described_class.run("co-update") }.to raise_error(RuntimeError, /requires cargo/)
      end
    end
  end

  describe "Decomplex native wrapper normalization" do
    it "validates Ruby files and parses co-update and predicate-alias JSON" do
      expect(Decomplex::Native::Command).to receive(:run)
        .with("co-update", "--language", "ruby", "--jobs", "3", "a.rb")
        .and_return(JSON.dump("co_written_pairs" => []))
      expect(Decomplex::Native::CoUpdate.scan(["a.rb"], jobs: 3)).to eq("co_written_pairs" => [])

      expect(Decomplex::Native::Command).to receive(:run)
        .with("predicate-aliases", "--language", "ruby", "a.rb")
        .and_return(JSON.dump("alias_clusters" => []))
      expect(Decomplex::Native::PredicateAliases.scan(["a.rb"])).to eq("alias_clusters" => [])

      expect { Decomplex::Native::CoUpdate.scan(["a.py"]) }.to raise_error(ArgumentError, /Ruby files only/)
      expect { Decomplex::Native::PredicateAliases.scan(["a.py"]) }.to raise_error(ArgumentError, /Ruby files only/)
    end

    it "normalizes flay-similarity clone types and span coordinates" do
      expect(Decomplex::Native::Command).to receive(:run)
        .with("flay-similarity", "--language", "ruby", "--mass", "5", "--fuzzy", "2", "a.rb")
        .and_return(JSON.dump([
          {
            "clone_type" => "exact",
            "spans" => { "a.rb" => ["1", "4"] },
          },
        ]))

      findings = Decomplex::Native::FlaySimilarity.scan(["a.rb"], mass: "5", fuzzy: "2")
      expect(findings).to eq([{ clone_type: :exact, spans: { :"a.rb" => [1, 4] } }])
      expect { Decomplex::Native::FlaySimilarity.scan(["a.py"], mass: 5, fuzzy: 2) }.to raise_error(ArgumentError, /Ruby files only/)
    end
  end

  describe NilKillRuntimeTrace do
    def reset_runtime_trace_state!
      FileUtils.rm_f(described_class::TRACE_PLAN_PATH)
      {
        methods: {},
        tlets: {},
        structs: {},
        ivar_runtime: {},
        tuples: {},
        collections: {},
        method_edges: {},
        objects: {},
        object_tokens: {},
        frames: Hash.new { |h, k| h[k] = [] },
        shape_lookup: {},
        path_cache: {},
        target_cache: {},
        site_ctx: {},
        cshape: {},
        ctsk: {},
        cls_name: {},
        method_metadata: {},
        planned_methods_by_class: nil,
        targeted_tracepoints: [],
        targeted_tracepoint_keys: Set.new,
        trace_plan_loaded: false,
        trace_plan: nil,
        coverage_line_map: nil,
        pending_mut: nil,
        coalesce: true,
        coverage_owned: false,
      }.each do |name, value|
        described_class.instance_variable_set(:"@#{name}", value)
      end
    end

    FakeTracePoint = Struct.new(
      :path,
      :lineno,
      :defined_class,
      :method_id,
      :parameters,
      :return_value,
      :raised_exception,
      :trace_binding,
      keyword_init: true
    ) do
      def binding
        trace_binding
      end
    end

    def binding_for_forced_args(args)
      binding
    end

    before do
      reset_runtime_trace_state!
    end

    it "filters trace plans and respects sampling gates" do
      target = described_class::TARGETS.first
      file = File.join(target, "trace_plan_unit.rb")
      plan = {
        "target_dirs" => described_class::TARGETS,
        "methods" => {
          ["Worker", "skip", "instance", file, 10].join("\0") => { "sample" => false, "frame" => false },
          ["Worker", "perform", "instance", file, 20].join("\0") => {
            "sample" => true,
            "frame" => true,
            "return" => false,
            "params" => { "payload" => true, "ignored" => false },
          },
        },
        "tracepoint_methods" => {
          ["Worker", "targeted", "class", file, 30].join("\0") => {
            "sample" => true,
            "frame" => false,
            "return" => true,
            "params" => { "arg" => true },
          },
        },
        "tlets" => { [file, 40].join("\0") => true },
        "struct_fields" => { ["User", "name"].join("\0") => true },
      }
      FileUtils.mkdir_p(File.dirname(described_class::TRACE_PLAN_PATH))
      File.write(described_class::TRACE_PLAN_PATH, JSON.dump(plan))

      expect(described_class.trace_plan).to eq(plan)
      expect(described_class.method_plan("Worker", "perform", "instance", file, 20)).to include("return" => false)
      expect(described_class.sample_param?(plan["methods"].values.last, "payload")).to be(true)
      expect(described_class.sample_param?(plan["methods"].values.last, "ignored")).to be(false)
      expect(described_class.sample_return?(plan["methods"].values.last)).to be(false)
      expect(described_class.sample_tlet?(file, 40)).to be(true)
      expect(described_class.sample_struct_field?("Models::User", "name")).to be(true)
      expect(described_class.sample_struct_field?("Models::User", "missing")).to be(false)

      planned = described_class.planned_methods_by_class
      expect(planned["Worker"].map { |entry| entry[:method_id] }).to eq(["targeted"])
    end

    it "normalizes paths, target membership, class names, and collection shapes" do
      target_file = File.join(described_class::TARGETS.first, "shape_unit.rb")
      outside = File.join(Dir.tmpdir, "outside.rb")

      expect(described_class.abs_path(target_file)).to eq(File.expand_path(target_file, described_class::ROOT))
      expect(described_class.target_path?(target_file)).to be(true)
      expect(described_class.target_path?(outside)).to be(false)
      expect(described_class.class_name(nil)).to eq("NilClass")
      expect(described_class.class_name("x")).to eq("String")

      array_shape = described_class.container_shape([1, 2, 3])
      expect(array_shape.first).to eq(:array)
      expect(array_shape[1].to_a).to eq(["Integer"])
      expect(array_shape).to be_frozen

      hash_shape = described_class.container_shape({ "id" => 1 })
      expect(hash_shape.first).to eq(:hash)
      expect(hash_shape[1][0].to_a).to eq(["String"])
      expect(hash_shape[1][1].to_a).to eq(["Integer"])

      nested_key = described_class.collection_type_shape_key([{ "id" => 1 }])
      expect(described_class.shape_payload(nested_key)).to include("kind" => "array")
      expect(described_class.container_shape("scalar")).to be_nil
    end

    it "records source-wrapper calls, returns, raises, ivars, structs, and tuples" do
      target_file = File.join(described_class::TARGETS.first, "record_unit.rb")
      FileUtils.mkdir_p(File.dirname(target_file))
      File.write(target_file, "# trace target\n")

      described_class.record_source_method_call("Worker", "perform", "instance", target_file, 12, {
        "payload" => ["a", "b"],
        "meta" => { "id" => 1 },
      })
      returned = described_class.record_source_method_return("Worker", "perform", "instance", target_file, 12, ["ok", 1])
      expect(returned).to eq(["ok", 1])

      key = ["Worker", "perform", "instance", File.expand_path(target_file, described_class::ROOT), 12]
      bucket = described_class.methods.fetch(key)
      expect(bucket[:calls]).to eq(1)
      expect(bucket[:ok_calls]).to eq(1)
      expect(bucket[:params_by_name]["payload"].to_a).to eq(["Array"])
      expect(bucket[:return_elem].to_a).to contain_exactly("Integer", "String")

      described_class.record_source_method_call("Worker", "explode", "instance", target_file, 30, {})
      described_class.record_source_method_raise("Worker", "explode", "instance", target_file, 30, RuntimeError.new("boom"))
      error_key = ["Worker", "explode", "instance", File.expand_path(target_file, described_class::ROOT), 30]
      expect(described_class.methods.fetch(error_key)[:raised].to_a).to eq(["RuntimeError"])

      receiver = Class.new
      stub_const("TraceReceiver", receiver)
      described_class.record_ivar_assignment(receiver.new, "@items", [1, 2], target_file, 44)
      expect(described_class.instance_variable_get(:@ivar_runtime).keys.first).to eq(["TraceReceiver", "@items"])

      struct_class = Class.new
      struct_class.instance_variable_set(:@__nil_kill_struct_path, target_file)
      struct_class.instance_variable_set(:@__nil_kill_struct_line, 50)
      described_class.record_struct_field(struct_class, "TraceStruct", "values", [1, 2, 3])
      struct_key = ["TraceStruct", "values", File.expand_path(target_file, described_class::ROOT), 50]
      expect(described_class.structs.fetch(struct_key)[:array_calls]).to eq(1)
      expect(described_class.tuples).not_to be_empty
    ensure
      FileUtils.rm_f(target_file)
    end

    it "records forced tracepoint calls, returns, raises, and method edges" do
      target_file = File.join(described_class::TARGETS.first, "forced_trace_unit.rb")
      FileUtils.mkdir_p(File.dirname(target_file))
      File.write(target_file, "# trace target\n")
      entry = {
        owner: "TraceTarget",
        kind: "instance",
        method_id: "forced",
        path: target_file,
        line: 8,
        params: { "items" => true, "meta" => true },
        sample: true,
        frame: true,
        return: true,
      }

      call_tp = FakeTracePoint.new(
        path: target_file,
        lineno: 8,
        defined_class: Class.new,
        method_id: :forced,
        parameters: [[:req, :items], [:req, :meta]],
        trace_binding: binding_for_forced_args([["a", "b"], { "id" => 1 }])
      )
      described_class.record_call(call_tp, forced_entry: entry)

      return_tp = FakeTracePoint.new(path: target_file, lineno: 8, method_id: :forced, return_value: { "ok" => [1, 2] })
      described_class.record_return(return_tp, forced_entry: entry)

      key = ["TraceTarget", "forced", "instance", File.expand_path(target_file, described_class::ROOT), 8]
      bucket = described_class.methods.fetch(key)
      expect(bucket[:calls]).to eq(1)
      expect(bucket[:ok_calls]).to eq(1)
      expect(bucket[:param_elem]["items"].to_a).to eq(["String"])
      expect(bucket[:return_kv][0].to_a).to eq(["String"])
      expect(bucket[:return_kv_shapes][1].to_a.map { |shape| described_class.shape_payload(shape)["kind"] }).to include("array")

      described_class.record_call(call_tp, forced_entry: entry)
      raise_tp = FakeTracePoint.new(path: target_file, lineno: 8, method_id: :forced, raised_exception: ArgumentError.new("bad"))
      described_class.record_raise(raise_tp, forced_entry: entry)
      expect(bucket[:raised_calls]).to eq(1)
      expect(bucket[:raised].to_a).to eq(["ArgumentError"])

      stack = described_class.frames[Thread.current.object_id]
      caller_frame = { method_key: ["Caller", "outer", "instance", target_file, 2], edge_key: nil }
      callee_frame = { method_key: key, edge_key: nil }
      stack << caller_frame
      described_class.record_method_edge_entry(callee_frame, stack)
      described_class.record_method_edge_outcome(callee_frame, :ok)
      expect(described_class.method_edges.values.first[:ok_calls]).to eq(1)
    ensure
      FileUtils.rm_f(target_file)
    end

    it "records collection mutations through Array, Hash, and Set hooks without losing owners" do
      target_file = File.join(described_class::TARGETS.first, "collection_hook_unit.rb")
      FileUtils.mkdir_p(File.dirname(target_file))
      File.write(target_file, "# trace target\n")
      described_class.install_collection_hook

      array_bucket = described_class.method_bucket(["TraceTarget", "with_items", "instance", target_file, 10])
      array = []
      described_class.register_collection_owner(array, owner_kind: "method_param", name: "items", path: target_file, line: 10, bucket: array_bucket)
      eval("array.push('a'); array.append('b'); array.unshift(:sym); array[1] = 7; array.concat(['c'], ['d'])", binding, target_file, 20)

      hash_bucket = described_class.method_bucket(["TraceTarget", "with_hash", "instance", target_file, 12])
      hash = {}
      described_class.register_collection_owner(hash, owner_kind: "method_param", name: "meta", path: target_file, line: 12, bucket: hash_bucket)
      eval("hash['id'] = 1; hash.store(:name, 'Ada'); hash.merge!({'age' => 42}, active: true); hash.update({'score' => 10})", binding, target_file, 30)

      set_bucket = described_class.method_bucket(["TraceTarget", "with_set", "instance", target_file, 14])
      set = Set.new
      described_class.register_collection_owner(set, owner_kind: "method_param", name: "tags", path: target_file, line: 14, bucket: set_bucket)
      eval("set.add('one'); set << 'two'; set.merge(['three'])", binding, target_file, 40)

      described_class.flush_pending_mutations!

      array_key = ["method_param", "items", File.expand_path(target_file, described_class::ROOT), 10, "array"]
      hash_key = ["method_param", "meta", File.expand_path(target_file, described_class::ROOT), 12, "hash"]
      set_key = ["method_param", "tags", File.expand_path(target_file, described_class::ROOT), 14, "set"]
      expect(described_class.collections.fetch(array_key)[:elem_classes].to_a).to include("String", "Integer", "Symbol")
      expect(described_class.collections.fetch(hash_key)[:key_classes].to_a).to include("String", "Symbol")
      expect(described_class.collections.fetch(set_key)[:elem_classes].to_a).to include("String")

      described_class.instance_variable_set(:@coalesce, false)
      described_class.record_collection_mutation(array, elem: "direct")
      expect(described_class.collections.fetch(array_key)[:elem_classes].to_a).to include("String")

      frozen_array = [1, 2].freeze
      described_class.register_collection_owner(frozen_array, owner_kind: "method_return", name: "frozen_items", path: target_file, line: 16, bucket: array_bucket)
      frozen_key = ["method_return", "frozen_items", File.expand_path(target_file, described_class::ROOT), 16, "array"]
      expect(described_class.collections.fetch(frozen_key)[:elem_classes].to_a).to eq(["Integer"])
    ensure
      FileUtils.rm_f(target_file)
    end

    it "records T.let, OpenStruct, Struct, and Data field hooks at target callsites" do
      target_file = File.join(described_class::TARGETS.first, "hook_unit.rb")
      FileUtils.mkdir_p(File.dirname(target_file))
      File.write(target_file, "# trace target\n")

      t_module = Module.new do
        def self.let(value, _type, **_kw)
          value
        end
      end
      stub_const("T", t_module)
      described_class.install_tlet_hook
      eval("T.let('name', String)", binding, target_file, 7)
      expect(described_class.tlets.values.first[:classes].to_a).to eq(["String"])

      described_class.install_open_struct_hook
      eval("OpenStruct.new(name: 'Ada').tap { |obj| obj[:age] = 42 }", binding, target_file, 12)
      expect(described_class.structs.keys.map { |key| key[1] }).to include("name", "age")

      struct_class = Struct.new(:name, :tags)
      struct_class.instance_variable_set(:@__nil_kill_struct_path, target_file)
      struct_class.instance_variable_set(:@__nil_kill_struct_line, 20)
      described_class.attach_struct(struct_class)
      instance = struct_class.new("Ada", ["ruby"])
      instance.tags = ["coverage"]
      instance[:name] = "Grace"
      expect(described_class.structs.keys.map { |key| key[0] }).to include("AnonymousStruct")

      if defined?(Data)
        data_class = Data.define(:name, :meta)
        data_class.instance_variable_set(:@__nil_kill_struct_path, target_file)
        data_class.instance_variable_set(:@__nil_kill_struct_line, 30)
        described_class.attach_data(data_class)
        data_class.new("Ada", { "id" => 1 })
        expect(described_class.structs.keys.map { |key| key[0] }).to include("AnonymousData")
      end
    ensure
      FileUtils.rm_f(target_file)
    end

    it "handles invalid trace plans, set shapes, source locations, and coverage line maps" do
      target_file = File.join(described_class::TARGETS.first, "line_map_unit.rb")
      FileUtils.mkdir_p(File.dirname(target_file))
      File.write(target_file, "# trace target\n")
      FileUtils.mkdir_p(File.dirname(described_class::TRACE_PLAN_PATH))
      File.write(described_class::TRACE_PLAN_PATH, "{")
      expect(described_class.trace_plan).to be_nil

      set_key = described_class.collection_type_shape_key(Set["a", "b"])
      expect(described_class.shape_payload(set_key)).to include("kind" => "set")
      expect(described_class.collection_kind(Set.new)).to eq("set")
      expect(described_class.collection_key_for("set", owner_kind: "field", name: "tags", path: target_file, line: 4)).to include("set")

      klass = Class.new do
        def initialize; end
      end
      stub_const("LineMapRuntimeOwner", klass)
      expect(described_class.source_location_for_class(klass)).to be_an(Array)
      expect(described_class.method_owner(klass)).to include("instance")
      expect(described_class.method_owner(nil)).to be_nil

      FileUtils.mkdir_p(described_class::OUT_DIR)
      rel = Pathname.new(File.expand_path(target_file, described_class::ROOT)).relative_path_from(Pathname.new(described_class::ROOT)).to_s
      File.write(File.join(described_class::OUT_DIR, ".nk-linemap.json"), JSON.dump(rel => { "10" => 3, 10 => 3 }))
      described_class.instance_variable_set(:@coverage_line_map, nil)
      expect(described_class.src_line(target_file, 10)).to eq(3)
    ensure
      FileUtils.rm_f(target_file)
    end
  end

  describe NilKill::Runtime::Normalizer do
    it "normalizes raw runtime trace events into evidence without requiring legacy fixtures" do
      Dir.mktmpdir("nil-kill-normalizer", NilKill::ROOT) do |dir|
        trace_dir = File.join(dir, "trace")
        FileUtils.mkdir_p(trace_dir)
        trace_file = File.join(trace_dir, "events.jsonl")
        source = File.join(dir, "src", "worker.rb")
        FileUtils.mkdir_p(File.dirname(source))
        File.write(source, "class Worker\n  def call(input); input; end\nend\n")
        rel_source = Pathname.new(source).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
        method_id = "ruby\0#{rel_source}\0Worker\0instance\0call\02"
        static = {
          "methods" => [
            { "id" => method_id, "language" => "ruby", "path" => rel_source, "line" => 2, "owner" => "Worker", "name" => "call", "kind" => "instance", "params" => ["input"], "return" => "T.untyped" },
          ],
          "fields" => [
            { "language" => "ruby", "path" => rel_source, "owner" => "Worker", "name" => "name" },
          ],
        }
        events = [
          { "schema_version" => 2, "event" => "method_call", "language" => "ruby", "path" => source, "line" => 2 },
          { "schema_version" => 1, "event" => "process_start", "language" => "ruby", "path" => source, "line" => 1, "run_id" => "run-1", "pid" => 123, "thread_id" => "main", "timestamp_ns" => 10 },
          { "schema_version" => 1, "event" => "method_call", "language" => "ruby", "path" => source, "line" => 2, "method_id" => method_id, "run_id" => "run-1", "payload" => { "sample_count" => 2 } },
          { "schema_version" => 1, "event" => "param_observed", "language" => "ruby", "path" => source, "line" => 2, "method_id" => method_id, "run_id" => "run-1", "payload" => { "param" => "input", "type" => "String", "sample_count" => 2 } },
          { "schema_version" => 1, "event" => "method_return", "language" => "ruby", "path" => source, "line" => 2, "method_id" => method_id, "run_id" => "run-1", "payload" => { "type" => { "name" => "String", "kind" => "primitive" } } },
          { "schema_version" => 1, "event" => "method_raise", "language" => "ruby", "path" => source, "line" => 2, "method_id" => method_id, "run_id" => "run-1", "payload" => { "class" => "ArgumentError" } },
          { "schema_version" => 1, "event" => "field_observed", "language" => "ruby", "path" => source, "line" => 3, "run_id" => "run-1", "payload" => { "owner" => "Worker", "field" => "name", "type" => "String" } },
          { "schema_version" => 1, "event" => "collection_observed", "language" => "ruby", "path" => source, "line" => 4, "run_id" => "run-1", "payload" => { "owner" => "Worker", "name" => "items", "kind" => "array", "element_types" => ["String"] } },
          { "schema_version" => 1, "event" => "hash_shape_observed", "language" => "ruby", "path" => source, "line" => 5, "run_id" => "run-1", "payload" => { "owner" => "Worker", "name" => "meta", "shape" => { "keys" => { "id" => ["Integer"] } } } },
          { "schema_version" => 1, "event" => "call_edge", "language" => "ruby", "path" => source, "line" => 2, "run_id" => "run-1", "payload" => { "caller" => { "method_id" => method_id }, "callee" => { "language" => "ruby", "path" => source, "line" => 20, "owner" => "Worker", "name" => "missing", "kind" => "instance" } } },
          { "schema_version" => 1, "event" => "coverage", "language" => "ruby", "path" => source, "line" => 2, "run_id" => "run-1", "payload" => { "lines" => [1, 2, 3] } },
          { "schema_version" => 1, "event" => "mystery", "language" => "ruby", "path" => source, "line" => 9, "run_id" => "run-1" },
          { "schema_version" => 1, "event" => "process_end", "language" => "ruby", "path" => source, "line" => 1, "run_id" => "run-1", "pid" => 123, "thread_id" => "main", "timestamp_ns" => 99 },
        ]
        File.write(trace_file, events.map { |event| JSON.generate(event) }.join("\n") + "\nnot-json\n[]\n")

        evidence = described_class.new(root: NilKill::ROOT).normalize(static: static, trace_paths: [trace_dir], analyze: false)
        expect(evidence.dig("runtime", "method_hits", method_id, "calls")).to eq(2)
        expect(evidence.dig("runtime", "method_hits", method_id, "ok_calls")).to eq(1)
        expect(evidence.dig("runtime", "param_observations", method_id, "input", "types").first).to include("name" => "String")
        expect(evidence.dig("runtime", "return_observations", method_id, "types").first).to include("display" => "String")
        expect(evidence.dig("runtime", "exceptions", method_id, "exceptions")).to eq(["ArgumentError"])
        expect(evidence.dig("runtime", "coverage", rel_source)).to eq([1, 2, 3])
        expect(evidence["diagnostics"].map { |diagnostic| diagnostic["code"] }).to include("unsupported_trace_schema", "unknown_trace_event", "invalid_json", "not_raw_trace_event", "unresolved_method_locator")
      end
    end
  end

  describe NilKill::Infer do
    it "delegates inference to Rust and parses Sorbet diagnostics into structured evidence" do
      infer = described_class.new([])
      allow(infer).to receive(:rust_binary_path).and_return("nil-kill-infer-rust")
      expect(Open3).to receive(:capture3) do |bin, input_path, output_path|
        expect(bin).to eq("nil-kill-infer-rust")
        expect(JSON.parse(File.read(input_path))).to include("facts")
        File.write(output_path, JSON.dump(
          "actions" => [{ "kind" => "fix_sig_return" }],
          "diagnostics" => { "rust" => [{ "message" => "ok" }] }
        ))
        ["", "", status(true)]
      end
      infer.delegate_to_rust("facts" => {})
      expect(infer.store.actions).to eq([{ "kind" => "fix_sig_return" }])
      expect(infer.store.diagnostics["rust"]).to eq([{ "message" => "ok" }])

      sorbet = <<~ERR
        \e[31mapp/user.rb:10: Expected `String` but found `Integer` for argument `name` https://srb.help/7002\e[0m
            app/caller.rb:3:
        app/user.rb:11: Expected `String` but found `NilClass` for method result type https://srb.help/7005
            app/user.rb:11:
        app/user.rb:12: Method `foo` does not exist on `NilClass` component https://srb.help/7034
            app/user.rb:12:
        app/user.rb:13: Some other error https://srb.help/9999
        NilClass
            app/source.rb:7:
      ERR
      expect(Open3).to receive(:capture3).and_return(["", sorbet, status(false)])
      infer.load_sorbet
      expect(infer.store.diagnostics["sorbet_errors"].map { |error| error["code"] }).to include("7002", "7005", "7034", "9999")
      expect(infer.store.diagnostics["nil_origins"]).to include({ "origin" => "app/source.rb:7", "count" => 1 })
      expect(infer.store.diagnostics["sorbet_feedback"].map { |item| item["code"] }).to contain_exactly("7002", "7005", "7034")
    end

    it "indexes SourceIndex facts when the legacy index engine is requested" do
      infer = described_class.new(["--no-sorbet"])
      target = File.join(NilKill::ROOT, "src", "indexed.rb")
      usage = File.join(NilKill::ROOT, "tools", "usage.rb")
      fake_index = Struct.new(
        :rel,
        :summary,
        :methods,
        :tlet_sites,
        :dead_nil_checks,
        :deterministic_guards,
        :struct_declarations,
        :struct_field_static,
        :tuple_arrays,
        :hash_shapes,
        :collection_index_lookups,
        :hash_record_blockers,
        :hash_record_member_calls,
        :type_normalizers,
        :dispatcher_inferences,
        :return_origins,
        :param_origins,
        :hash_record_escape_sites,
        :hidden_enum_observations,
        :return_usage_sites,
        :return_direct_usage_sites,
        :rescue_handlers,
        :ivar_protocols,
        :ivar_param_origins,
        keyword_init: true
      ).new(
        rel: "src/indexed.rb",
        summary: { "methods" => 2 },
        methods: [
          { "path" => "src/indexed.rb", "line" => 1, "class" => "Indexed", "method" => "typed", "kind" => "instance", "has_sig" => true },
          { "path" => "src/indexed.rb", "line" => 2, "class" => "Indexed", "method" => "raw", "kind" => "instance", "has_sig" => false },
        ],
        tlet_sites: [{ "line" => 3 }],
        dead_nil_checks: [{ "line" => 4 }],
        deterministic_guards: [{ "line" => 5 }],
        struct_declarations: [{ "class" => "Structy" }],
        struct_field_static: [{ "field" => "name" }],
        tuple_arrays: [{ "line" => 6 }],
        hash_shapes: [{ "line" => 7 }],
        collection_index_lookups: [{ "line" => 8 }],
        hash_record_blockers: [{ "line" => 9 }],
        hash_record_member_calls: [{ "line" => 10 }],
        type_normalizers: [{ "line" => 11 }],
        dispatcher_inferences: [{ "line" => 12 }],
        return_origins: [{ "line" => 13 }],
        param_origins: [{ "line" => 14 }],
        hash_record_escape_sites: [{ "line" => 15 }],
        hidden_enum_observations: [{ "line" => 16 }],
        return_usage_sites: [{ "name" => "typed" }],
        return_direct_usage_sites: [{ "name" => "raw" }],
        rescue_handlers: [{ "line" => 17 }],
        ivar_protocols: { ["Indexed", "@state"] => Set["ready"] },
        ivar_param_origins: { ["Indexed", "@state"] => Set[{ "type" => "String" }] }
      )

      isolated_env("NIL_KILL_SOURCE_INDEX_ENGINE" => "source_index", "NIL_KILL_IDX_WARM_ONLY" => "0", "NIL_KILL_IDX_REUSE" => "0") do
        allow(NilKill).to receive(:target_files).and_return([target])
        allow(NilKill).to receive(:usage_scan_files).and_return([target, usage])
        allow(NilKill::SourceIndex).to receive(:reset_global_shape_indexes)
        allow(NilKill::SourceIndex).to receive(:noreturn_methods).and_return([])
        allow(NilKill::SourceIndex).to receive(:new).and_return(fake_index)
        infer.index_sources
      end

      facts = infer.store.facts
      expect(facts["files"]).to include("src/indexed.rb" => { "methods" => 2 })
      expect(facts["unsigned_methods"].map { |method| method["method"] }).to eq(["raw"])
      expect(facts["existing_sigs"].map { |method| method["method"] }).to eq(["typed"])
      expect(facts["ivar_protocols"]["Indexed\0@state"]).to eq(["ready"])
      expect(facts["return_usage_sites"].size).to be >= 1
      expect(facts["rescue_handlers"].size).to be >= 1
    end
  end

  describe NilKill::Report do
    def rich_report_evidence(tmp_dir)
      src = File.join(tmp_dir, "src")
      FileUtils.mkdir_p(src)
      worker_path = File.join(src, "worker.rb")
      File.write(worker_path, <<~RUBY)
        class Worker
          def consume(input); input.to_s; end
          def emit; helper; end
          def helper; "value"; end
        end
      RUBY
      rel_worker = Pathname.new(worker_path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s rescue worker_path

      consume = {
        "key" => ["Worker", "consume", "instance", worker_path, 2],
        "source" => { "path" => rel_worker, "line" => 2, "end_line" => 2, "class" => "Worker", "method" => "consume", "params" => [{ "name" => "input" }], "sig" => "sig { params(input: T.untyped).returns(String) }" },
        "calls" => 8,
        "ok_calls" => 8,
        "raised_calls" => 0,
        "params_by_name" => { "input" => %w[String User] },
        "params_ok" => { "input" => %w[String User] },
        "params_raised" => {},
        "param_sites" => { "input" => { "#{worker_path}:2:String" => 5, "#{worker_path}:2:User" => 3 } },
        "param_sites_ok" => { "input" => { "#{worker_path}:2:String" => 5, "#{worker_path}:2:User" => 3 } },
        "param_traces" => { "input" => { "#{worker_path}:1:String" => 5 } },
        "param_traces_ok" => { "input" => { "#{worker_path}:1:String" => 5 } },
        "param_elem" => {},
        "param_kv" => {},
        "param_elem_shapes" => {},
        "param_kv_shapes" => {},
        "returns" => ["String"],
        "return_elem" => [],
        "return_kv" => [[], []],
        "return_elem_shapes" => [],
        "return_kv_shapes" => [[], []],
        "raised" => [],
        "has_sig" => true,
      }
      emit = consume.merge(
        "key" => ["Worker", "emit", "instance", worker_path, 3],
        "source" => { "path" => rel_worker, "line" => 3, "end_line" => 3, "class" => "Worker", "method" => "emit", "params" => [], "sig" => "sig { returns(T.untyped) }" },
        "calls" => 0,
        "ok_calls" => 0,
        "params_by_name" => {},
        "params_ok" => {},
        "returns" => []
      )
      visitor = consume.merge(
        "key" => ["Visitor", "visit", "instance", worker_path, 4],
        "source" => { "path" => rel_worker, "line" => 4, "end_line" => 4, "class" => "Visitor", "method" => "visit", "params" => [{ "name" => "node" }], "sig" => "sig { params(node: T.untyped).returns(T.untyped) }" },
        "params_by_name" => { "node" => %w[AST::CallNode AST::SendNode AST::LiteralNode] },
        "params_ok" => { "node" => %w[AST::CallNode AST::SendNode AST::LiteralNode] },
        "returns" => ["NilClass"]
      )

      facts = NilKill::Store.new.facts
      facts["existing_sigs"] = [
        consume.dig("source").merge("sig" => "sig { params(input: T.untyped).returns(String) }"),
        emit.dig("source").merge("sig" => "sig { returns(T.untyped) }"),
        visitor.dig("source").merge("sig" => "sig { params(node: T.untyped).returns(T.untyped) }"),
      ]
      facts["unsigned_methods"] = [
        { "path" => rel_worker, "line" => 5, "end_line" => 5, "class" => "Worker", "method" => "unsigned", "params" => [{ "name" => "raw" }] },
      ]
      facts["collect_coverage"] = { rel_worker => [2, 3, 4, 5] }
      facts["type_normalizers"] = [
        { "path" => rel_worker, "line" => 8, "class" => "Worker", "method" => "consume", "code" => "input.is_a?(User) ? input : User.new(input)", "origin_kind" => "param", "origin_name" => "input" },
        { "path" => rel_worker, "line" => 9, "class" => "Worker", "method" => "consume", "code" => "@type_info.is_a?(Type) ? @type_info : Type.new(@type_info)", "origin_kind" => "ivar", "origin_name" => "@type_info" },
      ]
      facts["param_origins"] = [
        { "path" => rel_worker, "line" => 20, "callee" => "consume", "slot" => "input", "origin_kind" => "literal", "type" => "String", "code" => "consume('id')" },
        { "path" => rel_worker, "line" => 21, "callee" => "consume", "slot" => "input", "origin_kind" => "typed_return", "source_method" => "emit", "type" => "User", "code" => "consume(user)" },
      ]
      facts["return_origins"] = [
        { "path" => rel_worker, "line" => 3, "class" => "Worker", "method" => "emit", "candidate_type" => "String", "sources" => [{ "kind" => "call_untyped", "callee" => "helper", "line" => 3 }], "blockers" => ["untyped callee helper"] },
      ]
      facts["return_direct_usage_sites"] = [
        { "name" => "helper", "context" => "return" },
      ]
      facts["struct_declarations"] = [
        { "path" => rel_worker, "line" => 30, "class" => "User", "fields" => %w[name age], "field_types" => { "age" => "Integer" } },
      ]
      facts["struct_field_runtime"] = [
        { "path" => rel_worker, "line" => 30, "class" => "User", "field" => "name", "classes" => ["String"] },
      ]
      facts["struct_field_static"] = [
        { "path" => rel_worker, "line" => 30, "class" => "User", "field" => "age", "type" => "Integer" },
      ]
      facts["ivar_runtime"] = [
        { "path" => rel_worker, "line" => 9, "class" => "Worker", "name" => "@type_info", "classes" => ["Type"] },
      ]
      facts["hash_shapes"] = [
        { "path" => rel_worker, "line" => 40, "class" => "Worker", "method" => "record", "keys" => { "name" => ["String"], "age" => ["Integer"] }, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false },
      ]
      facts["collection_index_lookups"] = [
        { "path" => rel_worker, "line" => 41, "receiver" => "record", "key" => "name", "receiver_origin" => "local_record" },
      ]
      facts["hash_record_blockers"] = [
        { "path" => rel_worker, "line" => 42, "keys" => %w[name age], "reason" => "dynamic key" },
      ]
      facts["hash_record_member_calls"] = [
        { "path" => rel_worker, "line" => 43, "key" => "name", "method" => "upcase" },
      ]
      facts["tuple_arrays"] = [
        { "path" => rel_worker, "line" => 50, "types" => %w[String Integer], "complete" => true, "mixed" => true },
      ]
      facts["collection_runtime"] = [
        { "path" => rel_worker, "line" => 60, "owner_kind" => "method_return", "name" => "items", "kind" => "Array", "elem_classes" => ["String"], "classes" => ["Array"] },
      ]
      facts["hidden_enum_pressure"] = [
        { "path" => rel_worker, "line" => 70, "owner" => "Worker", "method" => "status", "slot" => "state", "kind" => "param", "values" => %w[draft sent], "decision_pressure" => 4, "score" => 12, "confidence" => "high", "suggestion" => "extract enum" },
      ]
      facts["fallibility_pressure"] = [
        { "path" => rel_worker, "line" => 80, "label" => "Worker#danger", "score" => 20, "handler_pressure" => 2, "direct_sources" => ["raise"], "fallible_callers" => ["Worker#call"], "runtime" => { "calls" => 10, "raised_calls" => 3, "raised_classes" => ["RuntimeError"], "raised_rate" => 30.0 } },
      ]
      facts["dead_nil_checks"] = [
        { "path" => rel_worker, "line" => 90, "code" => "return if input.nil?" },
      ]
      facts["deterministic_guards"] = [
        { "path" => rel_worker, "line" => 91, "predicate" => "input.nil?", "outcome" => false, "reason" => "non-nil param" },
      ]

      actions = [
        { "kind" => "nil_param_observed", "confidence" => "review", "path" => rel_worker, "line" => 2, "message" => "nil source", "data" => { "name" => "input", "candidate_type" => "String", "callsites" => { "#{rel_worker}:20:String" => 5 } } },
        { "kind" => "union_observed", "confidence" => "review", "path" => rel_worker, "line" => 2, "message" => "union source", "data" => { "name" => "input", "classes" => %w[String User], "callsites" => { "#{rel_worker}:20:String" => 5 } } },
        { "kind" => "fix_sig_return", "confidence" => "high", "path" => rel_worker, "line" => 3, "message" => "return can be String", "data" => { "type" => "String", "source" => "static_return_origin", "observed_calls" => 3 } },
        { "kind" => "replace_nil_with_default", "confidence" => "high", "path" => rel_worker, "line" => 2, "message" => "replace nil", "data" => { "default" => "\"\"", "target_method" => "consume", "name" => "input", "observed_calls" => 8 } },
        { "kind" => "coverage_gap", "confidence" => "gap", "path" => rel_worker, "line" => 5, "message" => "not exercised", "data" => {} },
        { "kind" => "experimental", "confidence" => "low", "path" => rel_worker, "line" => 6, "message" => "extra confidence", "data" => {} },
      ]

      {
        "version" => 1,
        "generated_at" => Time.now.utc.iso8601,
        "target_dirs" => [src],
        "target_exclude_dirs" => [],
        "methods" => [consume, emit, visitor],
        "tlets" => [],
        "facts" => facts,
        "diagnostics" => {
          "sorbet_errors" => [{ "path" => rel_worker, "line" => 2, "message" => "Expected String", "code" => "7002", "severity" => "warning" }],
          "nil_origins" => [{ "origin" => "#{rel_worker}:2", "count" => 2 }],
          "sorbet_feedback" => [],
        },
        "actions" => actions,
      }
    end

    def report_for(evidence)
      described_class.new([], evidence: evidence).tap do |report|
        report.instance_variable_set(:@evidence, evidence)
      end
    end

    def method_runtime_record(source, calls: 4, params_by_name: {}, params_ok: nil, returns: [], param_elem: {}, param_kv: {}, return_elem: [], return_kv: [[], []], return_elem_shapes: [], return_kv_shapes: [[], []])
      params_ok ||= params_by_name
      {
        "source" => source,
        "calls" => calls,
        "ok_calls" => calls,
        "raised_calls" => 0,
        "params_by_name" => params_by_name,
        "params_ok" => params_ok,
        "params_raised" => {},
        "param_sites" => params_by_name.transform_values { |classes| classes.to_h { |klass| ["#{source["path"]}:#{source["line"]}:#{klass}", 1] } },
        "param_sites_ok" => {},
        "param_traces" => {},
        "param_traces_ok" => {},
        "param_elem" => param_elem,
        "param_kv" => param_kv,
        "param_elem_shapes" => {},
        "param_kv_shapes" => {},
        "returns" => returns,
        "return_elem" => return_elem,
        "return_kv" => return_kv,
        "return_elem_shapes" => return_elem_shapes,
        "return_kv_shapes" => return_kv_shapes,
        "raised" => [],
      }
    end

    it "renders rich evidence across report sections and SARIF pressure outputs" do
      Dir.mktmpdir("nil-kill-rich-report", NilKill::ROOT) do |dir|
        evidence = rich_report_evidence(dir)
        report_path = File.join(dir, "report.md")

        out, = capture_io do
          described_class.new(["--output-path", report_path, "--with-links", "--full"], evidence: evidence).run
        end

        expect(out).to include("Project Prioritization")
        expect(out).to include("Foreign Scalar Inputs Into Object-Typed Params")
        expect(out).to include("Hidden Enum Pressure")
        expect(out).to include("Fallibility Pressure")
        expect(out).to include("Struct Shape Report")
        expect(out).to include("Collection Type Report")
        expect(out).to include("Tuple-Like Array Report")
        expect(File.read(report_path)).to include("Worker#emit")

        sarif = described_class.new(["--format", "sarif"], evidence: evidence).to_sarif_hash(evidence)
        rule_ids = sarif.dig("runs", 0, "tool", "driver", "rules").map { |rule| rule["id"] }
        expect(rule_ids).to include("nil-kill.pressure.hidden-enum", "nil-kill.pressure.fallibility")
        expect(sarif.dig("runs", 0, "results").map { |result| result["ruleId"] }).to include("nil-kill.action.fix-sig-return")
      end
    end

    it "renders SARIF, hygiene-only, and v2 evidence modes" do
      Dir.mktmpdir("nil-kill-report-modes", NilKill::ROOT) do |dir|
        evidence = rich_report_evidence(dir)
        sarif_path = File.join(dir, "out", "report.sarif")
        out, = capture_io { described_class.new(["--format", "json", "--output-path", sarif_path], evidence: evidence).run }
        expect(JSON.parse(out)).to include("version" => "2.1.0")
        expect(File).to exist(sarif_path)

        hygiene, = capture_io { described_class.new(["--hygiene"], evidence: evidence).run }
        expect(hygiene).to include("Hygiene Overview", "Action Plan Counts")

        v2 = NilKill::Schema::EvidenceBundle.build(root: dir, static: { "methods" => [] }, runtime: { "runs" => [] })
        v2_path = File.join(dir, "v2.md")
        v2_out, = capture_io { described_class.new(["--output-path", v2_path], evidence: v2).run }
        expect(v2_out).to include("Nil Kill Multi-Language Report")
        expect(File.read(v2_path)).to include("Multi-Language")
      end
    end

    it "classifies report pressure, evidence gaps, collection candidates, and hash-record struct shapes" do
      Dir.mktmpdir("nil-kill-report-pressure", NilKill::ROOT) do |dir|
        evidence = rich_report_evidence(dir)
        src = File.join(dir, "src")
        FileUtils.mkdir_p(src)
        pressure_path = File.join(src, "pressure.rb")
        File.write(pressure_path, <<~RUBY)
          class NodeConsumer
            def consume_a(node); node; end
            def consume_b(node); node; end
            def consume_c(node); node; end
            def collect(items, meta); [items, meta]; end
            def guarded(input); input; end
          end
        RUBY
        rel = Pathname.new(pressure_path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
        facts = evidence["facts"]
        facts["existing_sigs"] = []
        evidence["methods"] = []

        node_classes = %w[AST::SendNode AST::CallNode AST::LiteralNode AST::ConstNode]
        3.times do |idx|
          line = idx + 2
          source = {
            "path" => rel,
            "line" => line,
            "end_line" => line,
            "class" => "NodeConsumer",
            "method" => "consume_#{idx}",
            "kind" => "instance",
            "params" => [{ "name" => "node", "type" => "T.untyped" }],
            "sig" => "sig { params(node: T.untyped).returns(T.untyped) }",
            "return_origin" => {
              "candidate_type" => "T.untyped",
              "sources" => [{ "kind" => "unknown", "code" => "node", "unknown_reasons" => ["local variable node"] }],
              "blockers" => [],
            },
          }
          facts["existing_sigs"] << source
          evidence["methods"] << method_runtime_record(source, params_by_name: { "node" => node_classes }, returns: [])
        end

        collect_source = {
          "path" => rel,
          "line" => 5,
          "end_line" => 5,
          "class" => "NodeConsumer",
          "method" => "collect",
          "kind" => "instance",
          "params" => [
            { "name" => "items", "type" => "T::Array[T.untyped]" },
            { "name" => "meta", "type" => "T::Hash[T.untyped, T.untyped]" },
          ],
          "sig" => "sig { params(items: T::Array[T.untyped], meta: T::Hash[T.untyped, T.untyped]).returns(T::Array[T.untyped]) }",
        }
        facts["existing_sigs"] << collect_source
        evidence["methods"] << method_runtime_record(
          collect_source,
          param_elem: { "items" => ["String"] },
          param_kv: { "meta" => [["String"], ["Integer"]] },
          return_elem: ["String"]
        )

        no_candidate_source = {
          "path" => rel,
          "line" => 6,
          "end_line" => 6,
          "class" => "NodeConsumer",
          "method" => "empty_items",
          "kind" => "instance",
          "params" => [{ "name" => "items", "type" => "T::Array[T.untyped]" }],
          "sig" => "sig { params(items: T::Array[T.untyped]).returns(String) }",
        }
        facts["existing_sigs"] << no_candidate_source
        evidence["methods"] << method_runtime_record(no_candidate_source, calls: 1)

        guarded_source = {
          "path" => rel,
          "line" => 7,
          "end_line" => 7,
          "class" => "NodeConsumer",
          "method" => "guarded",
          "kind" => "instance",
          "params" => [{ "name" => "input", "type" => "T.untyped" }],
          "sig" => "sig { params(input: T.untyped).returns(String) }",
        }
        facts["existing_sigs"] << guarded_source
        evidence["methods"] << method_runtime_record(guarded_source, params_by_name: { "input" => ["String", "User"] }, returns: ["String"])

        facts["param_origins"] = [
          { "path" => rel, "line" => 20, "callee" => "guarded", "slot" => "input", "origin_kind" => "static", "type" => "User", "code" => "guarded(user)" },
          { "path" => rel, "line" => 21, "callee" => "guarded", "slot" => "input", "origin_kind" => "static", "type" => "String", "code" => "guarded('id')" },
          { "path" => rel, "line" => 30, "callee" => "collect", "slot" => "items", "origin_kind" => "unknown", "code" => "items", "unknown_reasons" => ["struct/array/collection value items"] },
        ]
        facts["return_origins"] = [
          { "path" => rel, "line" => 2, "class" => "NodeConsumer", "method" => "consume_0", "kind" => "instance", "confidence" => "blocked", "candidate_type" => "T.untyped", "sources" => [{ "kind" => "unknown", "code" => "node", "unknown_reasons" => ["local variable node"] }], "blockers" => [] },
          { "path" => rel, "line" => 5, "class" => "NodeConsumer", "method" => "collect", "kind" => "instance", "confidence" => "strong", "candidate_type" => "T::Array[String]", "sources" => [{ "kind" => "static", "type" => "T::Array[String]" }], "blockers" => [] },
        ]
        facts["return_usage_sites"] = [
          { "name" => "consume_0", "context" => "return", "current_method" => "collect" },
          { "name" => "collect", "context" => "value" },
        ]
        facts["return_direct_usage_sites"] = [
          { "name" => "consume_0", "context" => "return" },
          { "name" => "collect", "context" => "value" },
        ]
        facts["type_normalizers"] = [
          { "path" => rel, "line" => 40, "class" => "NodeConsumer", "method" => "guarded", "code" => "input.is_a?(Type) ? input : Type.new(input)", "origin_kind" => "param", "origin_name" => "input" },
          { "path" => rel, "line" => 41, "class" => "NodeConsumer", "method" => "guarded", "code" => "@type_info.is_a?(Type) ? @type_info : Type.new(@type_info)", "origin_kind" => "ivar", "origin_name" => "@type_info" },
          { "path" => rel, "line" => 42, "class" => "NodeConsumer", "method" => "guarded", "code" => "local.is_a?(Type) ? local : Type.new(local)" },
        ]
        facts["ivar_runtime"] = [
          { "path" => rel, "line" => 41, "class" => "NodeConsumer", "name" => "@type_info", "classes" => ["Type"] },
        ]
        facts["deterministic_guards"] = [
          { "path" => rel, "line" => 43, "class" => "NodeConsumer", "method" => "guarded", "code" => "input.is_a?(User)", "truth_value" => true, "branch_kind" => "if", "taken_branch" => "then", "reason" => "single producer" },
        ]
        facts["collect_coverage"] = { rel => [1, 3, 4, 5, 6] }
        facts["tlet_sites"] = [
          { "path" => rel, "line" => 50, "name" => "cache", "tlet" => true, "type" => "T::Array[T.untyped]" },
          { "path" => rel, "line" => 51, "name" => "raw", "candidate_type" => "String" },
        ]
        facts["struct_declarations"] = [
          { "path" => rel, "line" => 60, "class" => "User", "fields" => %w[name tags missing values], "field_types" => { "name" => "String" } },
        ]
        facts["struct_field_runtime"] = [
          { "path" => rel, "line" => 60, "class" => "User", "field" => "tags", "classes" => ["Array"], "elem_classes" => ["String"], "calls" => 3 },
          { "path" => rel, "line" => 60, "class" => "User", "field" => "values", "classes" => %w[String Integer Symbol Float], "calls" => 4 },
        ]
        facts["struct_field_static"] = [
          { "path" => rel, "line" => 60, "class" => "User", "field" => "name", "type" => "String" },
          { "path" => rel, "line" => 60, "class" => "User", "field" => "missing", "type" => "" },
        ]
        nested_shape = { "keys" => { "city" => ["String"] }, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false }
        facts["hash_shapes"] = [
          { "path" => rel, "line" => 70, "code" => "{name: 'Ada', age: 1, address: {city: 'Reno'}}", "keys" => %w[name age address], "value_types" => %w[String Integer Hash], "value_hash_shapes" => { "address" => nested_shape }, "value_array_element_shapes" => {}, "poisoned" => false },
          { "path" => rel, "line" => 71, "code" => "{name: 'Grace', age: 2, active: true}", "keys" => %w[name age active], "value_types" => %w[String Integer TrueClass], "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false },
        ]
        facts["collection_index_lookups"] = [
          { "path" => rel, "line" => 80, "code" => "record[:name]", "receiver" => "record", "index" => ":name", "lookup_type" => "T.untyped", "status" => "unknown receiver", "origin" => { "kind" => "hash literal", "path" => rel, "line" => 70, "code" => "{name: 'Ada', age: 1, address: {city: 'Reno'}}" } },
          { "path" => rel, "line" => 81, "code" => "meta['age']", "receiver" => "@meta", "index" => "'age'", "lookup_type" => "T.untyped", "status" => "typed collection receiver", "receiver_type" => "T::Hash[T.untyped, T.untyped]", "origin" => { "kind" => "instance variable", "name" => "@meta" } },
        ]
        facts["hash_record_blockers"] = [
          { "path" => rel, "line" => 82, "origin" => { "kind" => "hash literal", "path" => rel, "line" => 70, "code" => "{name: 'Ada', age: 1, address: {city: 'Reno'}}" }, "reason" => "dynamic key" },
        ]
        facts["hash_record_member_calls"] = [
          { "path" => rel, "line" => 83, "field" => "name", "member" => "upcase", "origin" => { "kind" => "hash literal", "path" => rel, "line" => 70, "code" => "{name: 'Ada', age: 1, address: {city: 'Reno'}}" }, "code" => "record[:name].upcase" },
        ]
        facts["collection_runtime"] = [
          { "path" => rel, "line" => 5, "owner_kind" => "method_param", "name" => "items", "kind" => "array", "elem_classes" => ["String"], "classes" => ["Array"], "calls" => 3, "mutation_sites" => { "#{rel}:90" => 2 } },
          { "path" => rel, "line" => 5, "owner_kind" => "method_param", "name" => "meta", "kind" => "hash", "key_classes" => ["String"], "value_classes" => ["Integer"], "classes" => ["Hash"], "calls" => 2, "mutation_sites" => {} },
          { "path" => rel, "line" => 52, "owner_kind" => "ivar", "name" => "cache", "kind" => "set", "elem_classes" => ["Symbol"], "classes" => ["Set"], "calls" => 1, "mutation_sites" => {} },
        ]
        facts["tuple_arrays"] = [
          { "path" => rel, "line" => 100, "types" => %w[String Integer], "confidence" => "high" },
        ]
        facts["tuple_runtime"] = [
          { "path" => File.join(NilKill::ROOT, rel), "line" => 101, "kind" => "return", "slot" => "collect", "types" => %w[String Integer], "size" => 2, "complete" => true, "mixed" => true, "calls" => 2 },
        ]
        evidence["actions"] = [
          { "kind" => "fix_sig_param", "confidence" => "high", "path" => rel, "line" => 7, "data" => { "name" => "input", "source" => "static_param_backflow", "type" => "User" } },
          { "kind" => "narrow_generic_return", "confidence" => "review", "path" => rel, "line" => 5, "data" => { "type" => "T::Array[String]" } },
          { "kind" => "add_struct_field_sig", "confidence" => "review", "data" => { "class" => "User", "field" => "tags" } },
        ]

        report = report_for(evidence)
        allow(report).to receive(:struct_rbi_types).and_return(
          ["User", "name"] => "String",
          ["User", "tags"] => "T.untyped",
          ["User", "values"] => "T.untyped"
        )

        lines = []
        report.send(:append_union_decomplexity, lines, evidence)
        report.send(:append_deterministic_guard_collapse, lines, evidence)
        report.send(:append_node_alias_candidates, lines, evidence)
        report.send(:append_untyped_evidence_gaps, lines, evidence)
        report.send(:append_signature_coverage, lines, evidence, accumulator: described_class::HygieneCountsAcc.new)
        report.send(:append_variable_assignment_coverage, lines, evidence, accumulator: described_class::HygieneCountsAcc.new)
        report.send(:append_signature_slot_evidence, lines, evidence)
        report.send(:append_untyped_cause_table, lines, evidence)
        report.send(:append_struct_report, lines, evidence)
        report.send(:append_collection_report, lines, evidence)
        report.send(:append_tuple_report, lines, evidence)

        text = lines.join("\n")
        expect(text).to include("Union Decomplexity", "AstNode", "Struct Field Type Candidates", "Hash Record Struct Candidates")
        expect(text).to include("Weak Collection Slots With Runtime Candidates", "Runtime Tuple-Like Array Slots")
        expect(report.send(:hash_record_struct_candidates, evidence).first).to include("struct_name")
        expect(report.send(:collection_blocker_pressure, evidence, report.send(:collection_signature_slots, evidence))).not_to be_empty
      end
    end

    it "covers report formatting, bucket, pressure, and type helper edge cases" do
      evidence = {
        "methods" => [],
        "facts" => {
          "existing_sigs" => [
            { "path" => "src/a.rb", "line" => 1, "class" => "A", "method" => "call", "kind" => "instance", "params" => [{ "name" => "value", "type" => "T.untyped" }], "sig" => "sig { params(value: T.untyped).returns(T.untyped) }" },
          ],
          "unsigned_methods" => [],
          "struct_declarations" => [],
          "param_origins" => [],
          "return_origins" => [],
        },
        "actions" => [
          { "kind" => "nil_param_observed", "path" => "src/a.rb", "line" => 1, "data" => { "name" => "value", "candidate_type" => "String", "callsites" => { "src/root.rb:2:String" => 5 } } },
          { "kind" => "union_observed", "path" => "src/a.rb", "line" => 1, "data" => { "name" => "value", "classes" => %w[String User Admin Guest Extra More], "callsites" => { "src/root.rb:2:String" => 5 } } },
          { "kind" => "bad_input_type_candidate", "path" => "src/a.rb", "line" => 1, "data" => { "name" => "value", "candidate_type" => "User", "raised_only_classes" => ["String"], "callsites" => { "src/raised.rb:4:String" => 1 } } },
        ],
      }
      report = report_for(evidence)
      lines = ["# Title", "", "- summary", "## Body"] + Array.new(12) { |i| "- item #{i}" }

      expect(report.send(:prepare_linked_report, lines, full: false).join("\n")).to include("Table of Contents", "more")
      expect(report.send(:prepare_linked_report, lines, full: true).join("\n")).to include("<details>")
      expect(report.send(:format_report_line, "#{NilKill::ROOT}/src/a.rb:1 A#call")).to include("src/a.rb")
      expect(report.send(:github_anchor, "`A#call` & More")).to eq("acall-more")
      expect(report.send(:default_for_type, "T::Hash[String, Integer]")).to eq("{}")
      expect(report.send(:proposed_action_text, { "kind" => "fix_sig_param", "data" => { "name" => "value", "type" => "String" } }, nil)).to include("value")
      expect(report.send(:action_evidence_text, evidence["actions"].first)).to include("top source")

      buckets = {}
      report.send(:record_bucket_example!, buckets, "a", "first")
      report.send(:record_bucket_example!, buckets, "a", "first")
      expect(report.send(:bucket_examples, buckets)).to eq(["2 slots: first"])
      expect(report.send(:unknown_expression_bucket, ["operation +", "local variable x"])).to include("local variable")
      expect(report.send(:unknown_expression_bucket, ["forwarded return foo", "instance variable @x"])).to include("multiple")
      expect(report.send(:protocol_strength, %w[to_s inspect custom])).to eq("medium")
      expect(report.send(:protocol_hint, { "protocols" => { "value" => { "methods" => %w[foo bar], "aliases" => ["v"], "gaps" => ["unknown alias"] } } }, "value", ["Known"], { "Candidate" => Set["foo", "bar"] })).to include("Candidate")

      pressure = report.send(:merge_pressure,
        report.send(:callsite_pressure, evidence["actions"], "nil_param_observed"),
        report.send(:callsite_pressure, evidence["actions"], "union_observed"),
        report.send(:callsite_pressure, evidence["actions"], "bad_input_type_candidate"))
      out = []
      isolated_env("NIL_KILL_PRESSURE_SORT" => "calls") do
        report.send(:append_pressure_list, out, pressure, "slots")
      end
      expect(out.join("\n")).to include("priority", "normal calls suggest")
    end

    it "covers compact report helper decisions from parsed source and synthetic evidence" do
      expect { capture_io { described_class.new(["--format", "xml"]) } }.to raise_error(SystemExit)
      expect { capture_io { described_class.new(["--sarif"]) } }.to raise_error(SystemExit)
      expect { capture_io { described_class.new(["--json"]) } }.to raise_error(SystemExit)
      expect { capture_io { described_class.new(["--evidence"]) } }.to raise_error(SystemExit)

      Dir.mktmpdir("nil-kill-report-helpers", NilKill::ROOT) do |dir|
        src = File.join(dir, "src")
        FileUtils.mkdir_p(src)
        source_path = File.join(src, "usage_probe.rb")
        File.write(source_path, <<~RUBY)
          class UsageProbe
            def leaf; "x"; end
            def voidish; puts "x"; end
            def wrapper(flag)
              if flag
                return leaf
              else
                helper(leaf)
              end
            end
            def helper(value); value; end
          end
        RUBY
        rel = Pathname.new(source_path).relative_path_from(Pathname.new(NilKill::ROOT)).to_s
        excluded = File.join(src, "excluded.rb")
        File.write(excluded, "def excluded; leaf; end\n")

        leaf = { "path" => rel, "line" => 2, "end_line" => 2, "class" => "UsageProbe", "method" => "leaf", "kind" => "instance", "params" => [], "sig" => "sig { returns(String) }" }
        voidish = { "path" => rel, "line" => 3, "end_line" => 3, "class" => "UsageProbe", "method" => "voidish", "kind" => "instance", "params" => [], "sig" => "sig { returns(T.untyped) }" }
        wrapper = { "path" => rel, "line" => 4, "end_line" => 10, "class" => "UsageProbe", "method" => "wrapper", "kind" => "instance", "params" => [{ "name" => "flag", "type" => "T.untyped", "nil_default" => true }], "uses_yield" => false, "sig" => "sig { params(flag: T.untyped).returns(T.untyped) }" }
        wrapper["return_origin"] = { "sources" => [{ "kind" => "unknown", "unknown_reasons" => ["struct/array/collection value items"], "code" => "items" }] }
        helper = { "path" => rel, "line" => 11, "end_line" => 11, "class" => "UsageProbe", "method" => "helper", "kind" => "instance", "params" => [{ "name" => "value", "type" => "T.untyped" }], "sig" => "sig { params(value: T.untyped).void }" }
        blocky = { "path" => rel, "line" => 12, "end_line" => 12, "class" => "UsageProbe", "method" => "with_block", "kind" => "instance", "params" => [{ "name" => "block", "type" => "T.untyped" }], "uses_yield" => true, "sig" => "sig { params(block: T.untyped).returns(T.untyped) }" }
        weak_array = { "path" => rel, "line" => 13, "end_line" => 13, "class" => "UsageProbe", "method" => "items", "kind" => "instance", "params" => [{ "name" => "items", "type" => "T::Array[T.untyped]" }], "sig" => "sig { params(items: T::Array[T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }" }
        empty_array = { "path" => rel, "line" => 14, "end_line" => 14, "class" => "UsageProbe", "method" => "empty_items", "kind" => "instance", "params" => [{ "name" => "items", "type" => "T::Array[T.untyped]" }], "sig" => "sig { params(items: T::Array[T.untyped]).returns(String) }" }

        evidence = {
          "target_dirs" => [src],
          "target_exclude_dirs" => [excluded],
          "methods" => [
            method_runtime_record(wrapper, calls: 3, params_by_name: { "flag" => [] }, returns: %w[TrueClass FalseClass]),
            method_runtime_record(helper, calls: 2, params_by_name: { "value" => %w[String User] }),
            method_runtime_record(weak_array, calls: 4, param_elem: { "items" => ["String"] }, return_kv: [%w[String], %w[Integer]], return_elem_shapes: [], return_kv_shapes: [[{ "kind" => "class", "name" => "String" }], [{ "kind" => "class", "name" => "Integer" }]]),
            method_runtime_record(empty_array, calls: 2),
            {
              "source" => helper,
              "calls" => 5,
              "ok_calls" => 5,
              "raised_calls" => 0,
              "params_by_name" => { "value" => %w[String User] },
              "params_ok" => { "value" => %w[String User] },
              "params_raised" => {},
              "param_sites" => { "value" => { "#{source_path}:6:String" => 2 } },
              "param_sites_ok" => { "value" => { "#{source_path}:6:String" => 2 } },
              "param_traces" => { "value" => { "#{File.join(src, "caller.rb")}:3|#{source_path}:11:String" => 2 } },
              "param_traces_ok" => { "value" => { "#{File.join(src, "caller.rb")}:3|#{source_path}:11:String" => 2 } },
              "param_elem" => {},
              "param_kv" => {},
              "param_elem_shapes" => {},
              "param_kv_shapes" => {},
              "returns" => [],
              "return_elem" => [],
              "return_kv" => [[], []],
              "return_elem_shapes" => [],
              "return_kv_shapes" => [[], []],
              "raised" => [],
            },
          ],
          "facts" => {
            "existing_sigs" => [leaf, voidish, wrapper, helper, blocky, weak_array, empty_array],
            "unsigned_methods" => [],
            "tlet_sites" => [
              { "path" => rel, "line" => 30, "name" => "cache", "tlet" => true, "type" => "T::Array[T.untyped]" },
            ],
            "return_origins" => [
              voidish.merge("candidate_type" => "T.noreturn", "return_syntax" => "implicit", "sources" => [{ "kind" => "call_untyped", "callee" => "raise", "line" => 3, "code" => "raise" }], "blockers" => ["untyped callee raise"]),
              wrapper.merge("candidate_type" => "String", "return_syntax" => "explicit", "sources" => [{ "kind" => "static", "type" => "String", "line" => 6, "code" => '"x"' }], "blockers" => []),
              helper.merge("candidate_type" => "T.untyped", "return_syntax" => "implicit", "sources" => [{ "kind" => "ivar_read", "line" => 11, "code" => "@value" }], "blockers" => []),
            ],
            "param_origins" => [
              { "path" => rel, "line" => 20, "callee" => "helper", "slot" => "value", "origin_kind" => "unknown", "unknown_reasons" => ["class variable @@state"], "code" => "helper(@@state)" },
              { "path" => rel, "line" => 21, "callee" => "helper", "slot" => "value", "origin_kind" => "typed_return", "source_method" => "leaf", "type" => "String", "code" => "helper(leaf)" },
              { "path" => rel, "line" => 22, "callee" => "items", "slot" => "items", "origin_kind" => "unknown", "unknown_reasons" => ["struct/array/collection value items"], "code" => "items" },
            ],
            "struct_declarations" => [
              { "path" => rel, "line" => 40, "class" => "UsageRecord", "fields" => %w[name tags weak missing nilable], "field_types" => {} },
            ],
            "struct_field_runtime" => [
              { "class" => "UsageRecord", "field" => "tags", "classes" => ["Array"], "elem_classes" => ["String"], "calls" => 2 },
              { "class" => "UsageRecord", "field" => "nilable", "classes" => %w[String NilClass], "calls" => 2 },
            ],
            "struct_field_static" => [
              { "class" => "UsageRecord", "field" => "name", "type" => "String" },
              { "class" => "UsageRecord", "field" => "weak", "type" => "T::Array[T.untyped]" },
              { "class" => "UsageRecord", "field" => "missing", "type" => "" },
            ],
            "collection_runtime" => [
              { "path" => rel, "line" => 13, "owner_kind" => "method_param", "name" => "items", "kind" => "array", "elem_classes" => ["String"], "classes" => ["Array"], "calls" => 4, "mutation_sites" => { "#{rel}:50" => 2 } },
              { "path" => rel, "line" => 13, "owner_kind" => "method_return", "name" => "items", "kind" => "hash", "key_classes" => ["String"], "value_classes" => ["Integer"], "classes" => ["Hash"], "calls" => 4, "mutation_sites" => {} },
              { "path" => rel, "line" => 14, "owner_kind" => "method_param", "name" => "items", "kind" => "array", "elem_classes" => [], "classes" => ["Array"], "calls" => 2, "mutation_sites" => { "#{rel}:51" => 1 } },
              { "path" => rel, "line" => 30, "owner_kind" => "tlet", "name" => "cache", "kind" => "array", "elem_classes" => [], "elem_shapes" => [{ "kind" => "class", "name" => "User" }], "classes" => ["Array"], "calls" => 1, "mutation_sites" => {} },
              { "path" => rel, "line" => 40, "owner_kind" => "struct_field", "name" => "UsageRecord.weak", "kind" => "array", "elem_classes" => %w[String Integer Symbol Float Object User Extra], "classes" => ["Array"], "calls" => 1, "mutation_sites" => {} },
            ],
            "collection_index_lookups" => [
              { "path" => rel, "line" => 60, "code" => "record[:name]", "receiver" => "record", "index" => ":name", "lookup_type" => "T.untyped", "status" => "unknown receiver", "origin" => { "kind" => "method parameter", "path" => rel, "line" => 11, "name" => "record", "type" => "T::Hash[T.untyped, T.untyped]" } },
              { "path" => rel, "line" => 61, "code" => "@record['id']", "receiver" => "@record", "index" => "'id'", "lookup_type" => "String", "status" => "typed collection receiver", "receiver_type" => "T::Hash[String, String]", "origin" => { "kind" => "instance variable", "name" => "@record" } },
              { "path" => rel, "line" => 62, "code" => "dynamic[key]", "receiver" => "dynamic[key]", "index" => "key", "lookup_type" => "T.untyped", "status" => "unknown receiver", "origin" => { "kind" => "forwarded return", "callee" => "load_record", "path" => rel, "line" => 2 } },
            ],
            "hash_shapes" => [
              { "path" => rel, "line" => 70, "code" => "{name: 'Ada', tags: [{id: 1}]}", "keys" => %w[name tags], "value_types" => %w[String Array], "value_hash_shapes" => {}, "value_array_element_shapes" => { "tags" => { "keys" => { "id" => ["Integer"] }, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false } }, "poisoned" => false },
              { "path" => rel, "line" => 71, "code" => "{name: 'Grace', meta: {active: true}}", "keys" => %w[name meta], "value_types" => %w[String Hash], "value_hash_shapes" => { "meta" => { "keys" => { "active" => ["TrueClass"] }, "value_hash_shapes" => {}, "value_array_element_shapes" => {}, "poisoned" => false } }, "value_array_element_shapes" => {}, "poisoned" => false },
            ],
            "hash_record_blockers" => [
              { "path" => rel, "line" => 72, "origin" => { "kind" => "local hash shape", "shape" => { "keys" => %w[name tags] } }, "reason" => "dynamic key" },
            ],
            "hash_record_member_calls" => [
              { "path" => rel, "line" => 73, "field" => "name", "member" => "full_type", "origin" => { "kind" => "hash literal", "path" => rel, "line" => 70, "code" => "{name: 'Ada', tags: [{id: 1}]}" } },
            ],
          },
          "diagnostics" => { "nil_origins" => [], "sorbet_errors" => [], "sorbet_feedback" => [] },
          "actions" => [
            { "kind" => "fix_sig_return", "confidence" => "review", "path" => rel, "line" => 4, "data" => { "type" => "String", "source" => "static_return_origin" } },
            { "kind" => "fix_sig_return", "confidence" => "high", "path" => rel, "line" => 4, "data" => { "type" => "String", "source" => "static_return_origin" } },
            { "kind" => "fix_sig_return", "confidence" => "low", "path" => rel, "line" => 3, "data" => { "type" => "T.noreturn" } },
            { "kind" => "narrow_generic_param", "confidence" => "review", "path" => rel, "line" => 13, "data" => { "name" => "items", "type" => "T::Array[String]" } },
            { "kind" => "narrow_generic_return", "confidence" => "high", "path" => rel, "line" => 13, "data" => { "type" => "T::Hash[String, Integer]" } },
          ],
        }

        report = report_for(evidence)
        allow(report).to receive(:struct_rbi_types).and_return(
          ["UsageRecord", "name"] => "String",
          ["UsageRecord", "tags"] => "T.untyped",
          ["UsageRecord", "weak"] => "T::Array[T.untyped]",
          ["UsageRecord", "nilable"] => "T.nilable(String)"
        )

        evidence_path = File.join(dir, "evidence.json")
        File.write(evidence_path, JSON.generate(evidence))
        expect(described_class.new(["--evidence=#{evidence_path}"]).send(:read_evidence)).to include("facts")
        expect(described_class.new(["--sarif=#{File.join(dir, "report.sarif")}"]).send(:report_filename)).to eq("report.sarif")
        expect(described_class.new(["--json", File.join(dir, "report.json")]).send(:sarif_format?)).to be(true)

        usage = report.send(:return_usage_by_name, evidence)
        graph = report.send(:return_usage_graph_summary, evidence)
        expect(usage["leaf"].values.sum + graph["used"].size).to be > 0
        expect(report.send(:evidence_target_files, evidence)).to include(source_path)
        expect(report.send(:return_hygiene_rows, evidence).map { |row| row["fixability"] }).to include(a_string_matching(/review action|missing action|needs collection|addressed/))
        expect(report.send(:hygiene_fixability_rank, "needs collection/field evidence")).to eq(3)
        expect(report.send(:return_fix_action_lookup, evidence)[[rel, 4]]["confidence"]).to eq("high")

        suggestions = %w[raise puts each any? join [] []= mystery].map do |callee|
          report.send(:root_return_suggestion, "untyped callee #{callee}", { "callee" => callee }, {})
        end
        expect(suggestions.compact.join("\n")).to include("void", "boolean", "String", "mutation")
        expect(report.send(:root_return_suggestion, "setter assignment name=", { "callee" => "name=" }, {})).to include("assignment")

        foreign_lines = []
        report.send(:append_foreign_class_pressure, foreign_lines, evidence)
        expect(foreign_lines.join("\n")).to include("Foreign Scalar", "UsageProbe#helper")

        unknown_lines = []
        report.send(:append_unknown_expression_breakdowns, unknown_lines, evidence["facts"]["existing_sigs"], evidence["facts"]["param_origins"])
        expect(unknown_lines.join("\n")).to include("class variable", "struct/array/collection")
        expect(report.send(:unknown_reason_label, "global variable $state")).to include("global variable")

        expect(report.send(:weak_signature_type_reason, "T.any(String, Integer)")).to include("union")
        expect(report.send(:weak_signature_type_reason, "T::Set[T.untyped]")).to include("collection")
        expect(report.send(:weak_signature_type_reason, "T.nilable(T.untyped)")).to include("nested")
        expect(report.send(:untyped_param_bucket, wrapper, "flag", [], { "calls" => 1 })).to include("defaultable")
        expect(report.send(:untyped_param_bucket, blocky, "block", [], { "calls" => 1 })).to include("block-like")
        expect(report.send(:untyped_return_bucket, wrapper, { "calls" => 1, "returns" => %w[TrueClass FalseClass] }, Set.new)).to include("Boolean")

        collection_slots = report.send(:collection_signature_slots, evidence)
        collection_lines = []
        report.send(:append_collection_slot_coverage, collection_lines, collection_slots)
        report.send(:append_collection_slot_candidates, collection_lines, evidence, collection_slots)
        report.send(:append_collection_blocker_pressure, collection_lines, evidence, collection_slots)
        report.send(:append_runtime_collection_observations, collection_lines, evidence.dig("facts", "collection_runtime"))
        report.send(:append_collection_index_lookup_report, collection_lines, evidence.dig("facts", "collection_index_lookups"))
        expect(collection_lines.join("\n")).to include("Weak Collection Slots", "mutation sites", "Runtime Collection", "forwarded return")
        expect(report.send(:collection_slot_missing_candidate_reason, collection_slots.find { |slot| slot.dig("method", "method") == "empty_items" })).to include("no element")
        expect(report.send(:collection_origin_label, { "kind" => "array literal", "name" => "records", "path" => rel, "line" => 1 })).to include("array literal")
        expect(report.send(:collection_origin_label, { "kind" => "instance variable", "name" => "@record" })).to include("instance")

        struct_lines = []
        report.send(:append_struct_field_coverage, struct_lines, evidence.dig("facts", "struct_declarations"), accumulator: described_class::HygieneCountsAcc.new)
        report.send(:append_struct_field_breakdown, struct_lines, evidence.dig("facts", "struct_declarations"), evidence.dig("facts", "struct_field_runtime"), evidence.dig("facts", "struct_field_static"))
        report.send(:append_struct_field_candidates, struct_lines, evidence.dig("facts", "struct_field_runtime"), evidence.dig("facts", "struct_field_static"))
        expect(struct_lines.join("\n")).to include("missing field type", "untyped with runtime candidate", "typed but nilable")

        hash_lines = []
        report.send(:append_hash_shape_candidates, hash_lines, evidence.dig("facts", "hash_shapes"))
        report.send(:append_hash_record_struct_candidates, hash_lines, evidence)
        report.send(:append_hash_record_struct_pressure, hash_lines, evidence)
        expect(hash_lines.join("\n")).to include("Hash Shapes", "High-Pressure HashMaps")
        candidates = report.send(:hash_record_struct_candidates, evidence)
        expect(report.send(:candidate_matches_pressure?, candidates, report.send(:hash_record_struct_pressure, evidence).first)).to be(true)
        expect(report.send(:hash_record_lookup?, evidence.dig("facts", "collection_index_lookups").last)).to be(false)
        expect(report.send(:hash_record_pressure_label, evidence.dig("facts", "collection_index_lookups").first)).to include("method parameter")
        expect(report.send(:hash_record_nested_structs, candidates.first["fields"])).not_to be_nil
        expect(report.send(:hash_record_protocol_type_for_members, %w[full_type token])).to eq("AST::Locatable")
        expect(report.send(:flow_graph, evidence)).to be_a(NilKill::FlowGraph)

        acc = described_class::HygieneCountsAcc.new
        acc.add("param", "weak_collection" => 2)
        primitive_lines = []
        report.send(:append_primitive_collection_summary, primitive_lines, acc)
        expect(primitive_lines.join("\n")).to include("Primitive Collection Slots")

        expect(report.send(:strip_nilable, "T.nilable(String)")).to eq("String")
      end
    end
  end
end
