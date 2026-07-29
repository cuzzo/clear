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
        "param_elem" => { "rows" => ["Row"] },
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
        "return_elem" => ["Row"],
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
          "elements" => ["Row"],
        },
        "result_domain" => {
          "types" => ["Enumerator"],
        },
        "result_truths" => [true, false],
        "count" => 2,
      }

      result = described_class.emit(
        root: root,
        runtime_dir: runtime_dir,
        events: [event]
      )
      evidence = JSON.parse(File.read(result.fetch("path")))

      expect(evidence.fetch("schema")).to eq("fact-mine.runtime-value-evidence.v1")
      expect(evidence.fetch("runs")).to eq(["run-1"])
      parameter = evidence.fetch("observations").find do |row|
        row["kind"] == "parameter" && row["slot"] == "rows"
      end
      expect(parameter.dig("scope", "function")).to eq("run")
      expect(parameter.dig("domain", "types")).to eq(["Array"])
      expect(parameter.dig("domain", "elements")).to eq(["Row"])
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
        "elements" => ["Row"]
      )
      expect(evidence.dig("calls", 0, "result_domain", "types")).to eq(["Enumerator"])
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
      calls = JSON.parse(File.read(result.fetch("path"))).fetch("calls")

      expect(calls.map { |call| [call.dig("receiver_domain", "types"), call["result_truths"]] })
        .to contain_exactly([["DetailArm"], [true]], [["FallbackArm"], [false]])
    end
  end
end
