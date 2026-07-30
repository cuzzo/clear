# frozen_string_literal: true

require "spec_helper"
require_relative "../lib/nil_kill"
require "tmpdir"

RSpec.describe "canonical runtime semantic evidence v1" do
  def conformance_fixture(name)
    path = File.join(
      NilKill::ROOT,
      "protocol/runtime-evidence/v1/conformance",
      name
    )
    JSON.parse(File.read(path))
  end

  def anchor(symbol:, kind:, name:, line: 3, enclosing: "fact-mine workspace fixture . Worker#run().")
    {
      "symbol" => symbol,
      "relative_path" => "lib/worker.rb",
      "range" => {
        "start_line" => line - 1,
        "start_character" => 4,
        "end_line" => line - 1,
        "end_character" => 8,
      },
      "kind" => kind,
      "enclosing_symbol" => enclosing,
      "semantic_digest" => "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=",
      "display_name" => name,
    }
  end

  def plan(*requests)
    value = {
      "protocol_version" => 1,
      "producer" => { "name" => "fact-mine-rust", "version" => "1" },
      "project_root" => "file:///fixture",
      "documents" => [],
      "requests" => requests,
    }
    message = Factmine::Runtime::V1::TracePlan.decode_json(
      JSON.generate(value),
      ignore_unknown_fields: false
    )
    message.plan_digest = Digest::SHA256.digest(
      Factmine::Runtime::V1::TracePlan.encode(message)
    )
    JSON.parse(
      Factmine::Runtime::V1::TracePlan.encode_json(
        message,
        preserve_proto_fieldnames: true,
        emit_defaults: true
      )
    )
  end

  def event(source_role: nil, receiver: "String", truth: nil)
    value = {
      "schema_version" => 1,
      "event" => "runtime_call",
      "language" => "ruby",
      "run_id" => "run-1",
      "caller" => {
        "class" => "Worker",
        "method" => "run",
        "kind" => "instance",
        "path" => File.join(NilKill::ROOT, "lib/worker.rb"),
        "line" => 2,
      },
      "callsite" => {
        "path" => File.join(NilKill::ROOT, "lib/worker.rb"),
        "line" => 3,
      },
      "callee" => {
        "owner" => receiver,
        "name" => "size",
        "kind" => "instance",
        "path" => nil,
        "line" => nil,
        "native" => true,
        "receiver_type" => receiver,
        "package_manager" => "ruby",
        "package" => "ruby",
        "version" => RUBY_VERSION,
        "source_role" => source_role,
      }.compact,
      "receiver_domain" => {
        "types" => [receiver],
        "singletons" => [],
        "elements" => [],
        "keys" => [],
        "values" => [],
        "shapes" => [],
      },
      "result_truths" => truth.nil? ? [] : [truth],
      "count" => 2,
    }
    value
  end

  def parse(path)
    JSON.parse(NilKill::Runtime::JsonIO.read(path))
  end

  it "emits one explicit row per exact plan anchor and correlated execution buckets" do
    request = {
      "anchor" => anchor(symbol: "local call-1", kind: "CALL_SELECTOR", name: "size"),
      "required" => %w[RECEIVER_VALUE CALL_TARGET],
    }
    Dir.mktmpdir do |directory|
      result = NilKill::Runtime::ValueEvidenceEmitter.emit(
        root: NilKill::ROOT,
        runtime_dir: directory,
        events: [event],
        plan: plan(request)
      )
      evidence = parse(result.fetch("path"))
      expect(File.binread(result.fetch("path"), 2).bytes).to eq([0x1f, 0x8b])
      expect(evidence.fetch("protocol_version")).to eq(1)
      expect(evidence.fetch("trace_plan_digest")).to eq(plan(request).fetch("plan_digest"))
      row = evidence.fetch("anchors").fetch(0)
      expect(row.fetch("anchor_symbol")).to eq("local call-1")
      expect(row.dig("capture", "status")).to eq("COMPLETE_FOR_RUNS")
      expect(row.dig("capture", "complete_kinds"))
        .to contain_exactly("RECEIVER_VALUE", "CALL_TARGET")
      bucket = row.fetch("executions").fetch(0)
      expect(bucket.fetch("count").to_i).to eq(2)
      expect(bucket.dig("receiver", "alternatives", 0, "value", "type_symbol"))
        .to end_with(" String#")
      expect(bucket.dig("target", "symbol")).to end_with(" String#size().")
      expect(bucket.dig("provenance", "run_id")).to eq("run-1")
    end
  end

  it "reports field-level completeness when result capture is partial" do
    request = {
      "anchor" => anchor(symbol: "local call-1", kind: "CALL_SELECTOR", name: "size"),
      "required" => %w[RECEIVER_VALUE CALL_TARGET RESULT_VALUE],
    }
    Dir.mktmpdir do |directory|
      evidence = parse(
        NilKill::Runtime::ValueEvidenceEmitter.emit(
          root: NilKill::ROOT,
          runtime_dir: directory,
          events: [event],
          plan: plan(request)
        ).fetch("path")
      )
      capture = evidence.dig("anchors", 0, "capture")
      expect(capture.fetch("status")).to eq("PARTIAL")
      expect(capture.fetch("complete_kinds"))
        .to contain_exactly("RECEIVER_VALUE", "CALL_TARGET")
    end
  end

  it "preserves anonymous nested collection shapes in canonical value evidence" do
    provider = NilKill::Languages.provider_for("ruby")
    values = NilKill::Runtime::EvidenceProtocol.value_set(
      {
        "types" => ["Array"],
        "elements" => ["Hash"],
        "shapes" => [{
          "kind" => "array",
          "elements" => [{
            "kind" => "hash",
            "keys" => [{ "kind" => "class", "name" => "String" }],
            "values" => [{
              "kind" => "array",
              "elements" => [{ "kind" => "class", "name" => "Integer" }],
            }],
          }],
        }],
      },
      count: 1,
      provider: provider
    )

    array_value = values.dig("alternatives", 0, "value")
    hash_value = array_value.dig("sequence", "elements", "alternatives", 0, "value")
    entry = hash_value.dig("mapping", "entries", 0)
    nested_array = entry.fetch("value")
    nested_element = nested_array.dig("sequence", "elements", "alternatives", 0, "value")

    expect(array_value.fetch("type_symbol")).to end_with(" Array#")
    expect(hash_value.fetch("type_symbol")).to end_with(" Hash#")
    expect(entry.dig("key", "type_symbol")).to end_with(" String#")
    expect(nested_array.fetch("type_symbol")).to end_with(" Array#")
    expect(nested_element.fetch("type_symbol")).to end_with(" Integer#")
  end

  it "emits one raw candidate correlation instead of guessing or duplicating same-line calls" do
    requests = %w[call-1 call-2].map do |id|
      {
        "anchor" => anchor(symbol: "local #{id}", kind: "CALL_SELECTOR", name: "size"),
        "required" => %w[RECEIVER_VALUE CALL_TARGET],
      }
    end
    Dir.mktmpdir do |directory|
      evidence = parse(
        NilKill::Runtime::ValueEvidenceEmitter.emit(
          root: NilKill::ROOT,
          runtime_dir: directory,
          events: [event],
          plan: plan(*requests)
        ).fetch("path")
      )
      expect(evidence.fetch("anchors").map { |row| row.dig("capture", "status") })
        .to eq(%w[PARTIAL PARTIAL])
      expect(evidence.fetch("anchors").map { |row| row.dig("capture", "complete_kinds") })
        .to eq([[], []])
      expect(evidence.fetch("anchors").flat_map { |row| row.fetch("executions") }).to be_empty
      correlation = evidence.fetch("correlations").fetch(0)
      expect(correlation.fetch("candidate_anchor_symbols"))
        .to eq(["local call-1", "local call-2"])
      expect(correlation.dig("capture", "status")).to eq("COMPLETE_FOR_RUNS")
      expect(correlation.dig("capture", "complete_kinds"))
        .to contain_exactly("RECEIVER_VALUE", "CALL_TARGET")
      expect(correlation.fetch("executions").length).to eq(1)
      expect(correlation.dig("executions", 0, "count").to_i).to eq(2)
    end
  end

  it "retains a test-double target with an explicit non-production source role" do
    request = {
      "anchor" => anchor(symbol: "local call-1", kind: "CALL_SELECTOR", name: "size"),
      "required" => %w[RECEIVER_VALUE CALL_TARGET],
    }
    Dir.mktmpdir do |directory|
      evidence = parse(
        NilKill::Runtime::ValueEvidenceEmitter.emit(
          root: NilKill::ROOT,
          runtime_dir: directory,
          events: [event(source_role: "nonproduction")],
          plan: plan(request)
        ).fetch("path")
      )
      expect(evidence.dig("anchors", 0, "executions", 0, "target", "source_role"))
        .to eq("NON_PRODUCTION")
    end
  end

  it "preserves an observed workspace declaration locator outside the trace plan" do
    request = {
      "anchor" => anchor(symbol: "local call-1", kind: "CALL_SELECTOR", name: "size"),
      "required" => %w[RECEIVER_VALUE CALL_TARGET],
    }
    Dir.mktmpdir("runtime-workspace-target", NilKill::ROOT) do |directory|
      callee_path = File.join(directory, "helper.rb")
      File.write(callee_path, "def size\n  1\nend\n")
      raw = event
      raw["callee"] = raw.fetch("callee").merge(
        "path" => callee_path,
        "line" => 1,
        "native" => false,
        "package_manager" => "workspace",
        "package" => "easy-vm",
        "version" => "workspace"
      )
      evidence = parse(
        NilKill::Runtime::ValueEvidenceEmitter.emit(
          root: NilKill::ROOT,
          runtime_dir: directory,
          events: [raw],
          plan: plan(request)
        ).fetch("path")
      )

      definition = evidence.dig("anchors", 0, "executions", 0, "target", "definition")
      expect(definition).to include(
        "symbol" => evidence.dig("anchors", 0, "executions", 0, "target", "symbol"),
        "anchor_symbol" => "",
        "relative_path" => Pathname.new(callee_path)
          .relative_path_from(Pathname.new(NilKill::ROOT)).to_s,
        "range" => include("start_line" => 0, "end_line" => 0)
      )
    end
  end

  it "merges replaceable shards by exact anchor and preserves per-run provenance" do
    request = {
      "anchor" => anchor(symbol: "local call-1", kind: "CALL_SELECTOR", name: "size"),
      "required" => %w[RECEIVER_VALUE CALL_TARGET],
    }
    Dir.mktmpdir do |directory|
      paths = %w[run-1 run-2].map do |run_id|
        raw = event.merge("run_id" => run_id, "count" => 1)
        NilKill::Runtime::ValueEvidenceEmitter.emit(
          root: NilKill::ROOT,
          runtime_dir: directory,
          output: File.join(directory, "#{run_id}.json.gz"),
          events: [raw],
          run_ids: [run_id],
          plan: plan(request)
        ).fetch("path")
      end
      merged = NilKill::Runtime::EvidenceMerger.merge(paths)
      expect(merged.fetch("runs").map { |run| run.fetch("id") }).to eq(%w[run-1 run-2])
      row = merged.fetch("anchors").fetch(0)
      expect(row.dig("capture", "status")).to eq("COMPLETE_FOR_RUNS")
      expect(row.dig("capture", "complete_kinds"))
        .to contain_exactly("RECEIVER_VALUE", "CALL_TARGET")
      expect(row.dig("capture", "observed_executions")).to eq(2)
      expect(row.fetch("executions").map { |bucket| bucket.dig("provenance", "run_id") })
        .to contain_exactly("run-1", "run-2")
    end
  end

  it "merges candidate correlations by stable candidate ownership and run provenance" do
    requests = %w[call-1 call-2].map do |id|
      {
        "anchor" => anchor(symbol: "local #{id}", kind: "CALL_SELECTOR", name: "size"),
        "required" => %w[RECEIVER_VALUE CALL_TARGET],
      }
    end
    Dir.mktmpdir do |directory|
      paths = %w[run-1 run-2].map do |run_id|
        NilKill::Runtime::ValueEvidenceEmitter.emit(
          root: NilKill::ROOT,
          runtime_dir: directory,
          output: File.join(directory, "#{run_id}.json.gz"),
          events: [event.merge("run_id" => run_id, "count" => 1)],
          run_ids: [run_id],
          plan: plan(*requests)
        ).fetch("path")
      end

      merged = NilKill::Runtime::EvidenceMerger.merge(paths)
      correlation = merged.fetch("correlations").fetch(0)
      expect(correlation.fetch("candidate_anchor_symbols"))
        .to eq(["local call-1", "local call-2"])
      expect(correlation.dig("capture", "status")).to eq("COMPLETE_FOR_RUNS")
      expect(correlation.dig("capture", "observed_executions")).to eq(2)
      expect(
        correlation.fetch("executions").map { |bucket| bucket.dig("provenance", "run_id") }
      ).to contain_exactly("run-1", "run-2")
    end
  end

  it "intersects field completeness across replaceable run shards" do
    request = {
      "anchor" => anchor(symbol: "local call-1", kind: "CALL_SELECTOR", name: "size"),
      "required" => %w[RECEIVER_VALUE CALL_TARGET RESULT_VALUE],
    }
    Dir.mktmpdir do |directory|
      empty = NilKill::Runtime::ValueEvidenceEmitter.emit(
        root: NilKill::ROOT,
        runtime_dir: directory,
        output: File.join(directory, "empty.json.gz"),
        events: [],
        run_ids: ["run-empty"],
        plan: plan(request)
      ).fetch("path")
      observed = NilKill::Runtime::ValueEvidenceEmitter.emit(
        root: NilKill::ROOT,
        runtime_dir: directory,
        output: File.join(directory, "observed.json.gz"),
        events: [event],
        run_ids: ["run-1"],
        plan: plan(request)
      ).fetch("path")

      capture = NilKill::Runtime::EvidenceMerger
        .merge([empty, observed]).dig("anchors", 0, "capture")

      expect(capture.fetch("status")).to eq("PARTIAL")
      expect(capture.fetch("complete_kinds"))
        .to contain_exactly("RECEIVER_VALUE", "CALL_TARGET")
      expect(capture.fetch("reason")).to eq(
        "provider did not capture every value requested at this anchor"
      )
    end
  end

  it "produces evidence accepted by FactMine's canonical validator" do
    binary = ENV.fetch(
      "FACT_MINE_RUST_BINARY",
      File.join(NilKill::ROOT, "gems/fact-mine/target/debug/fact-mine-rust")
    )
    skip "FactMine debug binary is unavailable" unless File.executable?(binary)

    Dir.mktmpdir do |directory|
      source = File.join(directory, "lib/worker.rb")
      FileUtils.mkdir_p(File.dirname(source))
      File.write(source, "class Worker\n  def run(value)\n    value.size\n  end\nend\n")
      plan_path = File.join(directory, "plan.json")
      expect(system(binary, "runtime-plan", "--root", directory, "--output", plan_path, source))
        .to be(true)
      generated_plan = JSON.parse(File.read(plan_path))
      raw = event
      raw["caller"]["path"] = source
      raw["callsite"]["path"] = source
      evidence_path = NilKill::Runtime::ValueEvidenceEmitter.emit(
        root: directory,
        runtime_dir: directory,
        events: [raw],
        plan: generated_plan
      ).fetch("path")
      expect(
        system(
          binary,
          "runtime-evidence", "validate",
          "--plan", plan_path,
          "--evidence", evidence_path
        )
      ).to be(true)
    end
  end

  it "uses the generated binding to enforce the shared conformance corpus" do
    canonical_plan = NilKill::Runtime::EvidenceProtocol.validate_plan!(
      conformance_fixture("trace-plan.valid.json")
    )
    expect(canonical_plan.fetch("requests").length).to eq(1)
    canonical_evidence = NilKill::Runtime::EvidenceProtocol.validate_evidence!(
      conformance_fixture("runtime-evidence.valid.json")
    )
    expect(canonical_evidence.fetch("anchors").length).to eq(1)
    correlation_plan = NilKill::Runtime::EvidenceProtocol.validate_plan!(
      conformance_fixture("trace-plan.valid-correlation.json")
    )
    expect(correlation_plan.fetch("requests").length).to eq(2)
    correlation_evidence = NilKill::Runtime::EvidenceProtocol.validate_evidence!(
      conformance_fixture("runtime-evidence.valid-correlation.json")
    )
    expect(correlation_evidence.fetch("correlations").length).to eq(1)
    expect {
      NilKill::Runtime::EvidenceProtocol.validate_evidence!(
        conformance_fixture("runtime-evidence.invalid-unknown-field.json")
      )
    }.to raise_error(ArgumentError, /No such field: misspelled_anchors/)
  end

  it "keeps language semantics out of shared runtime protocol code" do
    shared = %w[
      evidence_protocol.rb
      value_evidence_emitter.rb
      evidence_merger.rb
      scip_emitter.rb
    ].map do |name|
      File.read(File.join(NilKill::ROOT, "gems/nil-kill/lib/nil_kill/runtime", name))
    end.join("\n")
    expect(shared).not_to match(
      /\b(?:ruby|python|javascript|typescript|php|tracepoint|minitest|rspec)\b/i
    )
  end

  it "makes punctuation-heavy runtime method names canonical SCIP descriptors" do
    decoder = NilKill::Languages::Providers::Ruby::RuntimeValueEvidence
    callee = {
      "package_manager" => "ruby",
      "package" => "ruby",
      "version" => RUBY_VERSION,
      "owner" => "String",
      "kind" => "instance",
    }
    expect(decoder.runtime_symbol(callee, "start_with?"))
      .to end_with("String#`start_with?`().")
    expect(decoder.runtime_symbol(callee, "=="))
      .to end_with("String#`==`().")
    expect(decoder.runtime_symbol(callee, "+"))
      .to end_with("String#+().")
  end

  it "indexes provider rows once instead of rescanning them for every anchor" do
    requests = 20.times.map do |index|
      {
        "anchor" => anchor(
          symbol: "local call-#{index}",
          kind: "CALL_SELECTOR",
          name: "size",
          line: index + 3
        ),
        "required" => %w[RECEIVER_VALUE CALL_TARGET],
      }
    end
    events = 20.times.map do |index|
      event.tap { |row| row["callsite"] = row.fetch("callsite").merge("line" => index + 3) }
    end
    Dir.mktmpdir do |directory|
      emitter = NilKill::Runtime::ValueEvidenceEmitter.new(
        root: NilKill::ROOT,
        runtime_dir: directory,
        plan: plan(*requests)
      )
      path_normalizations = 0
      original = emitter.method(:canonical_path)
      emitter.define_singleton_method(:canonical_path) do |path|
        path_normalizations += 1
        original.call(path)
      end
      emitter.emit(events)
      expect(path_normalizations).to be <= events.length + 2
    end
  end
end
