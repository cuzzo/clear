# frozen_string_literal: true

require_relative "spec_helper"

RSpec.describe NilKill::Runtime::ValueEvidenceEmitter do
  it "serializes observed values and calls without inferring source flow" do
    Dir.mktmpdir("nil-kill-runtime-values", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, "class Worker; def run(rows); rows; end; end\n")
      File.write(File.join(runtime_dir, "methods-1.jsonl"), JSON.generate({
        "class" => "Worker",
        "method" => "run",
        "kind" => "instance",
        "path" => source,
        "line" => 1,
        "calls" => 2,
        "ok_calls" => 2,
        "params_by_name" => { "rows" => ["Array"] },
        "param_singleton_types" => { "rows" => ["RowsProvider"] },
        "param_elem" => { "rows" => ["Row", "T.untyped"] },
        "param_value_shapes" => {
          "rows" => [{ "kind" => "record", "name" => "ObservedRows", "members" => {
            "kind" => { "kind" => "unknown" }
          } }]
        },
        # Raw `*_elem_shapes` are observations of values *inside* the
        # container.  The emitted value domain must retain that nesting so the
        # generic FactMine CFG/DFG overlay can project a block parameter back
        # to the record value.  Emitting this record at the top level instead
        # describes `rows` itself as a record, which is unsound.
        "param_elem_shapes" => {
          "rows" => [{ "kind" => "record", "name" => "ObservedRow", "members" => {
            "kind" => { "kind" => "unknown" }
          } }]
        },
        "param_kv" => {},
        "returns" => ["Array"],
        "return_singleton_types" => ["RowsResultProvider"],
        "return_elem" => ["Row", "T.untyped"],
        "return_kv" => [[], []],
        "return_elem_shapes" => [{ "kind" => "record", "name" => "ReturnedRow", "members" => {
          "kind" => { "kind" => "unknown" }
        } }],
      }) + "\n")
      event = {
        "schema_version" => 1,
        "event" => "runtime_call",
        "language" => "ruby",
        "run_id" => "run-1",
        "caller" => {
          "class" => "Worker", "method" => "run", "kind" => "instance",
          "path" => source, "line" => 1,
        },
        "callsite" => { "path" => source, "line" => 1 },
        "callee" => {
          "owner" => "Array", "name" => "each", "kind" => "instance",
          "native" => true, "receiver_type" => "Array",
          "package_manager" => "ruby", "package" => "ruby",
          "version" => RUBY_VERSION,
        },
        "receiver_domain" => {
          "types" => ["Array"],
          "elements" => ["Row", "T.untyped"],
          "shapes" => [{
            "kind" => "array",
            "elements" => [{ "kind" => "record", "name" => "ObservedCallRow" }]
          }],
        },
        "result_domain" => {
          "types" => ["Enumerator", "T.untyped"],
          "shapes" => [{ "kind" => "record", "name" => "ObservedResult" }],
        },
        "result_truths" => [true, false],
        "count" => 2,
      }

      result = described_class.emit(
        root: root,
        runtime_dir: runtime_dir,
        events: [event]
      )
      evidence = NilKill::Runtime::JsonIO.parse(result.fetch("path"))

      expect(evidence.fetch("schema")).to eq("fact-mine.runtime-value-evidence.v1")
      expect(evidence.fetch("runs")).to eq(["run-1"])
      parameter = evidence.fetch("observations").find do |row|
        row["kind"] == "parameter" && row["slot"] == "rows"
      end
      expect(parameter.dig("scope", "function")).to eq("run")
      expect(parameter.dig("domain", "types")).to eq(["Array"])
      expect(parameter.dig("domain", "singletons")).to eq(["RowsProvider"])
      expect(parameter.dig("domain", "elements")).to eq(["ObservedRow", "Row"])
      expect(parameter.dig("domain", "shapes")).to include(
        "kind" => "record", "name" => "ObservedRows",
        "members" => { "kind" => { "kind" => "unknown" } }
      )
      expect(parameter.dig("domain", "shapes")).to include(
        "kind" => "array",
        "elements" => [{
          "kind" => "record", "name" => "ObservedRow",
          "members" => { "kind" => { "kind" => "unknown" } }
        }]
      )
      returned = evidence.fetch("observations").find { |row| row["kind"] == "return" }
      expect(returned.dig("domain", "types")).to eq(["Array"])
      expect(returned.dig("domain", "singletons")).to eq(["RowsResultProvider"])
      expect(returned.dig("domain", "elements")).to eq(["ReturnedRow", "Row"])
      expect(returned.dig("domain", "shapes")).to include(
        "kind" => "array",
        "elements" => [{
          "kind" => "record", "name" => "ReturnedRow",
          "members" => { "kind" => { "kind" => "unknown" } }
        }]
      )
      expect(evidence.dig("calls", 0, "targets", 0, "symbol"))
        .to include("Array#each().")
      expect(evidence.dig("calls", 0, "receiver_domain")).to include(
        "types" => ["Array"],
        "elements" => ["ObservedCallRow", "Row"]
      )
      expect(evidence.dig("calls", 0, "result_domain", "types"))
        .to eq(["Enumerator", "ObservedResult"])
      expect(evidence.dig("calls", 0, "result_truths")).to eq([false, true])

      # The producer records only observed boundaries. It must not invent a
      # local assignment, block binding, return edge, or inferred callsite.
      expect(evidence.keys).to contain_exactly(
        "schema", "authority", "environment", "runs", "observations", "calls"
      )
      expect(evidence.fetch("calls").length).to eq(1)
    end
  end

  it "preserves receiver-type and Boolean-result correlation for runtime predicates" do
    Dir.mktmpdir("nil-kill-runtime-capability", NilKill::ROOT) do |root|
      runtime_dir = File.join(root, "runtime")
      source = File.join(root, "worker.rb")
      FileUtils.mkdir_p(runtime_dir)
      File.write(source, "class Worker; def label(arm); arm.respond_to?(:detail); end; end\n")
      event = lambda do |type, truth|
        {
          "schema_version" => 1,
          "event" => "runtime_call",
          "language" => "ruby",
          "run_id" => "run-1",
          "caller" => {
            "class" => "Worker", "method" => "label", "kind" => "instance",
            "path" => source, "line" => 1,
          },
          "callsite" => { "path" => source, "line" => 1 },
          "callee" => {
            "owner" => "Object", "name" => "respond_to?", "kind" => "instance",
            "native" => true, "receiver_type" => type,
            "package_manager" => "ruby", "package" => "ruby", "version" => RUBY_VERSION,
          },
          "receiver_domain" => { "types" => [type] },
          "result_domain" => { "types" => [truth ? "TrueClass" : "FalseClass"] },
          "result_truths" => [truth],
          "count" => 1,
        }
      end

      result = described_class.emit(
        root: root,
        runtime_dir: runtime_dir,
        events: [event.call("DetailArm", true), event.call("FallbackArm", false)]
      )
      calls = NilKill::Runtime::JsonIO.parse(result.fetch("path")).fetch("calls")

      expect(calls.map { |call| [call.dig("receiver_domain", "types"), call["result_truths"]] })
        .to contain_exactly([["DetailArm"], [true]], [["FallbackArm"], [false]])
    end
  end
end

RSpec.describe NilKill::Runtime::EvidenceMerger do
  it "unions exact singleton identities across independently replaceable shards" do
    scope = {
      "language" => "ruby", "path" => "worker.rb",
      "owner" => "Worker", "function" => "run", "line" => 2,
    }
    bundle = lambda do |singleton|
      {
        "schema" => NilKill::Runtime::ValueEvidenceEmitter::SCHEMA,
        "authority" => NilKill::Runtime::ScipEmitter::AUTHORITY,
        "environment" => {},
        "runs" => [singleton],
        "observations" => [{
          "kind" => "parameter", "scope" => scope, "slot" => "provider",
          "slot_kind" => "",
          "domain" => {
            "types" => ["Module"], "singletons" => [singleton],
            "elements" => [], "keys" => [], "values" => [], "shapes" => [],
          },
          "count" => 1,
        }],
        "calls" => [{
          "language" => "ruby",
          "caller" => scope,
          "callsite" => {
            "path" => "worker.rb", "line" => 3, "selector" => "run"
          },
          "targets" => [],
          "receiver_domain" => {
            "types" => ["Module"], "singletons" => [singleton],
            "elements" => [], "keys" => [], "values" => [], "shapes" => [],
          },
          "count" => 1,
        }],
      }
    end

    Dir.mktmpdir("nil-kill-singleton-merge", NilKill::ROOT) do |dir|
      paths = %w[FirstProvider SecondProvider].map do |singleton|
        path = File.join(dir, "#{singleton}.json.gz")
        NilKill::Runtime::JsonIO.write(path, JSON.generate(bundle.call(singleton)))
        path
      end
      merged = described_class.merge(paths)

      expect(merged.dig("observations", 0, "domain", "singletons"))
        .to eq(%w[FirstProvider SecondProvider])
      expect(merged.fetch("calls").map { |call| call.dig("receiver_domain", "singletons") })
        .to contain_exactly(["FirstProvider"], ["SecondProvider"])
    end
  end
end
