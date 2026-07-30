# frozen_string_literal: true

require_relative "spec_helper"
require "rbconfig"

RSpec.describe NilKill::Runtime::Snapshot do
  def semantic_anchor_payload(rows)
    Marshal.load(Marshal.dump(rows)).each do |row|
      row.fetch("capture").delete("run_ids")
      row.fetch("executions").each { |bucket| bucket.fetch("provenance").delete("run_id") }
    end
  end

  def evidence(calls: [], observations: [], runs: ["run"])
    {
      "protocol_version" => 1,
      "producer" => { "name" => "nil-kill", "version" => "1" },
      "authority" => "MODELED_RUNS",
      "trace_plan_digest" => "fixture",
      "environment" => [{ "key" => "ruby.version", "value" => RUBY_VERSION }],
      "runs" => runs.map { |id| { "id" => id, "status" => "SUCCEEDED" } },
      "anchors" => observations + calls,
    }
  end

  it "reads plain and gzip JSONL transparently and compresses atomically" do
    Dir.mktmpdir("nil-kill-json-io") do |dir|
      plain = File.join(dir, "events.jsonl")
      File.write(plain, "{\"event\":1}\n{\"event\":2}\n")

      compressed = NilKill::Runtime::JsonIO.gzip_file(plain)

      expect(compressed).to end_with(".jsonl.gz")
      expect(File.exist?(plain)).to be(false)
      expect(File.binread(compressed, 2).bytes).to eq([0x1f, 0x8b])
      expect(described_class).not_to be_nil
      expect(NilKill::Runtime::JsonIO.foreach(compressed).to_a)
        .to eq(["{\"event\":1}\n", "{\"event\":2}\n"])
      expect(NilKill::Runtime::JsonIO.matching(dir, "events*.jsonl")).to eq([compressed])
    end
  end

  it "skips the workload entirely when a fast collection has no content changes" do
    Dir.mktmpdir("nil-kill-fast-noop", NilKill::ROOT) do |root|
      source = File.join(root, "app.rb")
      File.write(source, "def app = 1\n")
      runtime = File.join(root, "runtime")
      canonical = File.join(runtime, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      FileUtils.mkdir_p(runtime)
      NilKill::Runtime::JsonIO.write(canonical, JSON.generate(evidence))
      workload = NilKill::Runtime::WorkloadPlan.build(
        root: NilKill::ROOT,
        targets: [source],
        commands: []
      )
      inventory = NilKill::Runtime::FunctionInventory.build(
        root: NilKill::ROOT,
        files: [source],
        trace_plan: {}
      )
      described_class.new(root: NilKill::ROOT, runtime_dir: runtime)
        .write_full!(
          files: [source],
          evidence_path: canonical,
          workload_digest: workload.command_digest,
          function_inventory: inventory.to_h,
          workload: workload.to_h,
          trace_plan_digest: "fixture-plan"
        )
      reset_nil_kill_tmp_paths!(root)
      allow(NilKill).to receive(:target_files).and_return([source])
      allow(NilKill::TracePlan).to receive(:write) do
        File.write(
          NilKill::TRACE_PLAN_PATH,
          JSON.generate("runtime_evidence" => { "plan_digest" => "fixture-plan" })
        )
      end
      cli = NilKill::CLI.new(["collect", "--fast"])

      output = capture_stdout { cli.run }

      expect(output).to include("no semantic source/test changes, workload skipped")
      expect(NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST)))
        .to include("generation" => 0, "mode" => "full")
    end
  end

  it "invalidates a fast snapshot when FactMine changes the runtime trace plan" do
    Dir.mktmpdir("nil-kill-fast-plan-change", NilKill::ROOT) do |root|
      source = File.join(root, "app.rb")
      File.write(source, "def app = 1\n")
      runtime = File.join(root, "runtime")
      canonical = File.join(runtime, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      FileUtils.mkdir_p(runtime)
      NilKill::Runtime::JsonIO.write(canonical, JSON.generate(evidence))
      workload = NilKill::Runtime::WorkloadPlan.build(
        root: NilKill::ROOT,
        targets: [source],
        commands: [[RbConfig.ruby, "-e", "exit 0"]]
      )
      inventory = NilKill::Runtime::FunctionInventory.build(
        root: NilKill::ROOT,
        files: [source],
        trace_plan: {}
      )
      snapshot = described_class.new(root: NilKill::ROOT, runtime_dir: runtime)
      snapshot.write_full!(
        files: [source],
        evidence_path: canonical,
        workload_digest: workload.command_digest,
        function_inventory: inventory.to_h,
        workload: workload.to_h,
        trace_plan_digest: "old-plan"
      )

      selection = snapshot.select_increment(
        files: [source],
        function_inventory: inventory.to_h,
        workload_plan: workload,
        trace_plan_digest: "new-plan"
      )

      expect(selection).to include(
        "trace_plan_changed" => true,
        "fallback_full" => true,
        "rebuild" => true
      )
      expect(selection.fetch("selected_shards")).to eq(workload.shard_ids)
    end
  end

  it "does not turn a source-driven trace plan digest change into a full retrace" do
    Dir.mktmpdir("nil-kill-fast-source-plan-change", NilKill::ROOT) do |root|
      source = File.join(root, "app.rb")
      File.write(source, "def app = 1\n")
      runtime = File.join(root, "runtime")
      canonical = File.join(runtime, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      FileUtils.mkdir_p(runtime)
      NilKill::Runtime::JsonIO.write(canonical, JSON.generate(evidence))
      workload = NilKill::Runtime::WorkloadPlan.from_h(
        root: NilKill::ROOT,
        value: {
          "mode" => "test_files",
          "command_digest" => "fixture-workload",
          "tests" => {},
          "support_files" => {},
          "shards" => {
            "fixture-shard" => {
              "command" => [RbConfig.ruby, "-e", "exit 0"],
              "test_path" => "test/app_test.rb",
            },
          },
        }
      )
      original_inventory = NilKill::Runtime::FunctionInventory.build(
        root: NilKill::ROOT,
        files: [source],
        trace_plan: {}
      )
      snapshot = described_class.new(root: NilKill::ROOT, runtime_dir: runtime)
      snapshot.write_full!(
        files: [source],
        evidence_path: canonical,
        workload_digest: workload.command_digest,
        function_inventory: original_inventory.to_h,
        workload: workload.to_h,
        trace_plan_digest: "old-plan"
      )

      File.write(source, "def app = 2\n")
      changed_inventory = NilKill::Runtime::FunctionInventory.build(
        root: NilKill::ROOT,
        files: [source],
        trace_plan: {}
      )
      selection = snapshot.select_increment(
        files: [source],
        function_inventory: changed_inventory.to_h,
        workload_plan: workload,
        trace_plan_digest: "source-updated-plan"
      )

      expect(selection).to include(
        "trace_plan_changed" => true,
        "unexplained_trace_plan_changed" => false,
        "fallback_full" => false
      )
      expect(selection.fetch("changed_functions").length).to eq(1)
      expect(selection.fetch("selected_shards")).to be_empty
    end
  end

  it "keeps repeated method definitions distinct and resolves entries by definition line" do
    Dir.mktmpdir("nil-kill-function-identities", NilKill::ROOT) do |root|
      source = File.join(root, "redefined.rb")
      File.write(source, <<~RUBY)
        class Redefined
          def value
            1
          end

          def value
            2
          end
        end
      RUBY
      first = NilKill::Runtime::FunctionInventory.build(
        root: NilKill::ROOT,
        files: [source],
        trace_plan: {}
      )
      definitions = first.functions.values.select { |function| function["name"] == "value" }
      expect(definitions.length).to eq(2)
      expect(definitions.map { |function| function["key"] }.uniq.length).to eq(2)
      expect(definitions.map do |function|
        first.key_for_entry(
          path: source,
          owner: function["owner"],
          name: function["name"],
          kind: function["kind"],
          line: function["line"]
        )
      end).to contain_exactly(*definitions.map { |function| function["key"] })

      File.write(source, "# formatting-only shift\n#{File.read(source)}")
      shifted = NilKill::Runtime::FunctionInventory.build(
        root: NilKill::ROOT,
        files: [source],
        trace_plan: {}
      )
      expect(shifted.functions.transform_values { |function| function["fingerprint"] })
        .to eq(first.functions.transform_values { |function| function["fingerprint"] })
    end
  end

  it "rolls all canonical files back when incremental SCIP regeneration fails" do
    Dir.mktmpdir("nil-kill-snapshot-rollback", NilKill::ROOT) do |tmp|
      reset_nil_kill_tmp_paths!(tmp)
      paths = [
        File.join(NilKill::RUNTIME_DIR, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT),
        File.join(NilKill::RUNTIME_DIR, described_class::MANIFEST),
        File.join(NilKill::RUNTIME_DIR, "runtime.scip.json"),
        File.join(NilKill::RUNTIME_DIR, "runtime-attestation.json.gz"),
      ]
      paths.each_with_index { |path, index| NilKill::Runtime::JsonIO.write(path, "before-#{index}") }
      cli = NilKill::CLI.new([])

      expect do
        cli.send(:with_canonical_snapshot_transaction) do
          paths.each_with_index { |path, index| NilKill::Runtime::JsonIO.write(path, "after-#{index}") }
          raise "FactMine failed"
        end
      end.to raise_error("FactMine failed")

      expect(paths.map { |path| NilKill::Runtime::JsonIO.read(path) })
        .to eq(paths.each_index.map { |index| "before-#{index}" })
    end
  end

  it "runs full, no-op, progressive changed, and deletion-only collections on a real fixture" do
    Dir.mktmpdir("nil-kill-incremental-e2e") do |root|
      fixture = File.join(NilKill::ROOT, "gems/nil-kill/spec/fixtures/incremental_collect")
      FileUtils.cp_r("#{fixture}/.", root)
      runtime = File.join(root, ".nil-kill", "runtime")
      source = File.join(root, "lib", "calculator.rb")
      unchanged_source = File.join(root, "lib", "formatter.rb")
      deleted_source = File.join(root, "lib", "legacy.rb")
      env = {
        "NIL_KILL_ROOT" => root,
        "NIL_KILL_TARGETS" => File.join(root, "lib"),
        "NIL_KILL_TMP_DIR" => File.join(root, ".nil-kill"),
        "FACT_MINE_RUST_BINARY" =>
          File.join(NilKill::ROOT, "gems/fact-mine/target/release/fact-mine-rust"),
      }
      executable = File.join(NilKill::ROOT, "gems/nil-kill/lib/nil_kill.rb")
      workload = [RbConfig.ruby, File.join(root, "run.rb")]
      run_collect = lambda do |*args|
        Open3.capture3(env, RbConfig.ruby, executable, "collect", *args, "--", *workload)
      end

      stdout, stderr, status = run_collect.call
      expect([stdout, stderr, status.exitstatus]).to satisfy { |(_out, _err, code)| code.zero? },
        -> { "#{stdout}\n#{stderr}" }
      expect(Dir.glob(File.join(runtime, "*.jsonl"))).to be_empty
      expect(Dir.glob(File.join(runtime, "**", "*.jsonl.gz"))).not_to be_empty
      expect(NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST)))
        .to include("mode" => "full", "generation" => 0, "complete" => true)
      canonical_evidence = File.join(
        runtime,
        NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT
      )
      trace_plan_path = File.join(root, ".nil-kill", "trace-plan.json")
      full_plan = JSON.parse(File.read(trace_plan_path)).fetch("runtime_evidence")
      formatter_symbols = full_plan.fetch("requests").filter_map do |request|
        anchor = request.fetch("anchor")
        anchor.fetch("symbol") if anchor.fetch("relative_path") == "lib/formatter.rb"
      end
      full_formatter_observations = NilKill::Runtime::JsonIO.parse(canonical_evidence)
        .fetch("anchors")
        .select { |row| formatter_symbols.include?(row.fetch("anchor_symbol")) }
      expect(full_formatter_observations).not_to be_empty

      stdout, stderr, status = run_collect.call("--fast")
      expect(status).to be_success
      expect(stdout).to include("workload skipped")
      expect(stderr).not_to include("error")

      File.write(source, File.read(source) + "\nINCREMENTAL_VERSION = 1\n")
      stdout, stderr, status = run_collect.call("--fast")
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      first = NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST))
      expect(first).to include(
        "mode" => "fast",
        "generation" => 1,
        "complete" => true,
        "potentially_stale" => false,
        "changed_files" => ["lib/calculator.rb"]
      )
      increment_formatter_observations = NilKill::Runtime::JsonIO.parse(canonical_evidence)
        .fetch("anchors")
        .select { |row| formatter_symbols.include?(row.fetch("anchor_symbol")) }
      expect(semantic_anchor_payload(increment_formatter_observations))
        .to eq(semantic_anchor_payload(full_formatter_observations))

      File.write(source, File.read(source).sub("INCREMENTAL_VERSION = 1", "INCREMENTAL_VERSION = 2"))
      _stdout, stderr, status = run_collect.call("--fast")
      expect(status).to be_success, stderr
      expect(NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST)))
        .to include("generation" => 2)

      File.delete(deleted_source)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, executable, "collect", "--fast")
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      final = NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST))
      evidence = NilKill::Runtime::JsonIO.parse(
        File.join(runtime, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      )
      expect(final).to include("generation" => 3, "deleted_files" => ["lib/legacy.rb"])
      final_plan = JSON.parse(File.read(trace_plan_path)).fetch("runtime_evidence")
      expect(final_plan.fetch("documents").map { |row| row.fetch("relative_path") })
        .not_to include("lib/legacy.rb")
      expect(evidence.fetch("anchors").map { |row| row.fetch("anchor_symbol") }.sort)
        .to eq(
          final_plan.fetch("requests").map { |request| request.dig("anchor", "symbol") }.sort
        )
      expect(File.file?(unchanged_source)).to be(true)
    end
  end

  def capture_stdout
    old = $stdout
    io = StringIO.new
    $stdout = io
    yield
    io.string
  ensure
    $stdout = old
  end
end
