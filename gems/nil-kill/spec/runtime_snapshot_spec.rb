# frozen_string_literal: true

require_relative "spec_helper"
require "rbconfig"

RSpec.describe NilKill::Runtime::Snapshot do
  def evidence(calls: [], observations: [], runs: ["run"])
    {
      "schema" => NilKill::Runtime::ValueEvidenceEmitter::SCHEMA,
      "authority" => NilKill::Runtime::ScipEmitter::AUTHORITY,
      "environment" => { "ruby.version" => RUBY_VERSION },
      "runs" => runs,
      "observations" => observations,
      "calls" => calls,
    }
  end

  def call(path, selector, count = 1)
    {
      "language" => "ruby",
      "caller" => { "path" => path, "owner" => "Worker", "name" => "run", "line" => 1 },
      "callsite" => { "path" => path, "line" => 2, "selector" => selector },
      "targets" => [{ "symbol" => "runtime #{selector}" }],
      "count" => count,
    }
  end

  def observation(path, name)
    {
      "kind" => "parameter",
      "scope" => { "language" => "ruby", "path" => path, "function" => "run", "line" => 1 },
      "name" => name,
      "domain" => { "types" => ["String"] },
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

  it "content-hashes changes and progressively replaces changed, observed, and deleted slices" do
    Dir.mktmpdir("nil-kill-incremental") do |root|
      runtime = File.join(root, "runtime")
      lib = File.join(root, "lib")
      one = File.join(lib, "one.rb")
      two = File.join(lib, "two.rb")
      FileUtils.mkdir_p(runtime)
      FileUtils.mkdir_p(lib)
      File.write(one, "ONE = 1\n")
      File.write(two, "TWO = 2\n")
      canonical = File.join(runtime, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      NilKill::Runtime::JsonIO.write(
        canonical,
        JSON.generate(evidence(
          calls: [call("lib/one.rb", "old_one"), call("lib/two.rb", "old_two")],
          observations: [observation("lib/one.rb", "old_one"), observation("lib/two.rb", "old_two")]
        ))
      )
      snapshot = described_class.new(root: root, runtime_dir: runtime)
      full = snapshot.write_full!(files: [one, two], evidence_path: canonical)

      expect(full).to include("mode" => "full", "complete" => true, "potentially_stale" => false)
      expect(File.binread(File.join(runtime, described_class::MANIFEST), 2).bytes).to eq([0x1f, 0x8b])
      expect(described_class.load(root: root, runtime_dir: runtime).changes([one, two]))
        .to include("changed_paths" => [], "deleted_paths" => [])

      File.write(one, "# representation-only edit\nONE = 1\n")
      expect(described_class.load(root: root, runtime_dir: runtime).changes([one, two]))
        .to include("changed_paths" => [], "deleted_paths" => [])

      File.write(one, "ONE = 10\n")
      loaded = described_class.load(root: root, runtime_dir: runtime)
      changes = loaded.changes([one, two])
      delta = File.join(runtime, "delta-one.json.gz")
      NilKill::Runtime::JsonIO.write(
        delta,
        JSON.generate(evidence(
          calls: [call("lib/one.rb", "new_one")],
          observations: [observation("lib/one.rb", "new_one")],
          runs: ["delta-1"]
        ))
      )
      loaded.merge_delta!(
        delta_evidence_path: delta,
        changed_paths: changes.fetch("changed_paths"),
        deleted_paths: changes.fetch("deleted_paths"),
        current_hashes: changes.fetch("current_hashes"),
        environment: changes.fetch("environment"),
        workload_digest: nil
      )
      first = NilKill::Runtime::JsonIO.parse(canonical)
      expect(first.fetch("calls").map { |row| row.dig("callsite", "selector") })
        .to contain_exactly("new_one", "old_two")
      expect(first.dig("freshness", "potentially_stale")).to be(true)

      File.delete(two)
      loaded = described_class.load(root: root, runtime_dir: runtime)
      changes = loaded.changes([one])
      empty_delta = File.join(runtime, "delta-delete.json.gz")
      NilKill::Runtime::JsonIO.write(empty_delta, JSON.generate(evidence(runs: ["delta-2"])))
      loaded.merge_delta!(
        delta_evidence_path: empty_delta,
        changed_paths: changes.fetch("changed_paths"),
        deleted_paths: changes.fetch("deleted_paths"),
        current_hashes: changes.fetch("current_hashes"),
        environment: changes.fetch("environment"),
        workload_digest: nil
      )
      second = NilKill::Runtime::JsonIO.parse(canonical)
      manifest = NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST))
      expect(second.fetch("calls").map { |row| row.dig("callsite", "selector") }).to eq(["new_one"])
      expect(second.fetch("observations").map { |row| row["name"] }).to eq(["new_one"])
      expect(manifest).to include(
        "generation" => 2,
        "mode" => "fast",
        "complete" => false,
        "deleted_paths" => ["lib/two.rb"]
      )
      expect(manifest.fetch("base_full_snapshot_id")).to eq(full.fetch("base_full_snapshot_id"))
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
      empty_workload = Digest::SHA256.hexdigest(JSON.generate([]))
      described_class.new(root: NilKill::ROOT, runtime_dir: runtime)
        .write_full!(
          files: [source],
          evidence_path: canonical,
          workload_digest: empty_workload
        )
      reset_nil_kill_tmp_paths!(root)
      allow(NilKill).to receive(:target_files).and_return([source])
      cli = NilKill::CLI.new(["collect", "--fast"])

      output = capture_stdout { cli.run }

      expect(output).to include("0 changed sources, workload skipped")
      expect(NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST)))
        .to include("generation" => 0, "mode" => "full")
    end
  end

  it "invalidates unchanged sources when the workload or runtime dependency environment changes" do
    Dir.mktmpdir("nil-kill-snapshot-context") do |root|
      runtime = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      canonical = File.join(runtime, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      FileUtils.mkdir_p(runtime)
      File.write(source, "def work = 1\n")
      NilKill::Runtime::JsonIO.write(canonical, JSON.generate(evidence))
      original_workload = Digest::SHA256.hexdigest(JSON.generate([["ruby", "test.rb"]]))
      described_class.new(root: root, runtime_dir: runtime).write_full!(
        files: [source],
        evidence_path: canonical,
        workload_digest: original_workload
      )
      loaded = described_class.load(root: root, runtime_dir: runtime)

      expect(loaded.changes([source], workload_digest: original_workload))
        .to include("changed_paths" => [], "workload_changed" => false)
      changed_workload = loaded.changes(
        [source],
        workload_digest: Digest::SHA256.hexdigest(JSON.generate([["ruby", "other_test.rb"]]))
      )
      expect(changed_workload)
        .to include("changed_paths" => ["worker.rb"], "workload_changed" => true)

      File.write(File.join(root, "Gemfile.lock"), "GEM\n")
      changed_environment = loaded.changes([source], workload_digest: original_workload)
      expect(changed_environment)
        .to include("changed_paths" => ["worker.rb"], "environment_changed" => true)
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
      env = {
        "NIL_KILL_ROOT" => root,
        "NIL_KILL_TARGETS" => File.join(root, "lib"),
        "NIL_KILL_TMP_DIR" => File.join(root, ".nil-kill"),
        "FACT_MINE_RUST_BINARY" =>
          File.join(NilKill::ROOT, "gems/fact-mine/target/debug/fact-mine-rust"),
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
      expect(Dir.glob(File.join(runtime, "*.jsonl.gz"))).not_to be_empty
      expect(NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST)))
        .to include("mode" => "full", "generation" => 0, "complete" => true)
      canonical_evidence = File.join(
        runtime,
        NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT
      )
      full_formatter_observations = NilKill::Runtime::JsonIO.parse(canonical_evidence)
        .fetch("observations")
        .select { |row| row.dig("scope", "path") == "lib/formatter.rb" }
      expect(full_formatter_observations).not_to be_empty

      stdout, stderr, status = run_collect.call("--fast")
      expect(status).to be_success
      expect(stdout).to include("workload skipped")
      expect(stderr).to be_empty

      File.write(source, File.read(source) + "\nINCREMENTAL_VERSION = 1\n")
      stdout, stderr, status = run_collect.call("--fast")
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      first = NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST))
      expect(first).to include(
        "mode" => "fast",
        "generation" => 1,
        "complete" => false,
        "potentially_stale" => true,
        "changed_paths" => ["lib/calculator.rb"]
      )
      increment_formatter_observations = NilKill::Runtime::JsonIO.parse(canonical_evidence)
        .fetch("observations")
        .select { |row| row.dig("scope", "path") == "lib/formatter.rb" }
      expect(increment_formatter_observations).to eq(full_formatter_observations)

      File.write(source, File.read(source).sub("INCREMENTAL_VERSION = 1", "INCREMENTAL_VERSION = 2"))
      _stdout, stderr, status = run_collect.call("--fast")
      expect(status).to be_success, stderr
      expect(NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST)))
        .to include("generation" => 2)

      File.delete(source)
      stdout, stderr, status = Open3.capture3(env, RbConfig.ruby, executable, "collect", "--fast")
      expect(status).to be_success, "#{stdout}\n#{stderr}"
      final = NilKill::Runtime::JsonIO.parse(File.join(runtime, described_class::MANIFEST))
      evidence = NilKill::Runtime::JsonIO.parse(
        File.join(runtime, NilKill::Runtime::ValueEvidenceEmitter::DEFAULT_OUTPUT)
      )
      expect(final).to include("generation" => 3, "deleted_paths" => ["lib/calculator.rb"])
      expect(evidence.fetch("observations").map { |row| row.dig("scope", "path") }.uniq)
        .to eq(["lib/formatter.rb"])
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
