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
        "param_kv" => {},
        "returns" => ["Array"],
        "return_elem" => ["Row"],
        "return_kv" => [[], []],
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
      expect(evidence.dig("calls", 0, "targets", 0, "symbol"))
        .to include("Array#each().")
      expect(evidence.dig("calls", 0, "receiver_domain")).to include(
        "types" => ["Array"],
        "elements" => ["Row"]
      )
      expect(evidence.dig("calls", 0, "result_domain", "types")).to eq(["Enumerator"])

      # The producer records only observed boundaries. It must not invent a
      # local assignment, block binding, return edge, or inferred callsite.
      expect(evidence.keys).to contain_exactly(
        "schema", "authority", "environment", "runs", "observations", "calls"
      )
      expect(evidence.fetch("calls").length).to eq(1)
    end
  end
end
