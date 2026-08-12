# frozen_string_literal: true

require "spec_helper"
require "digest"
require "json"
require "tmpdir"

RSpec.describe RubyToClear::TypedIR::CfgFacts do
  let(:source) { "def choose(x)\n  return 0 unless x\n  x\nend\n" }
  let(:function) { Prism.parse(source).value.statements.body.first }
  let(:digest) { "sha256:#{Digest::SHA256.hexdigest(source)}" }

  def payload(source_digest: digest, schema: described_class::SCHEMA, file: "fixture.rb")
    nodes = [
      { "id" => "entry", "function" => "choose", "owner" => "(top-level)", "kind" => "entry", "span" => [1, 0, 4, 3] },
      { "id" => "branch", "function" => "choose", "owner" => "(top-level)", "kind" => "branch", "span" => [2, 2, 2, 19] },
      { "id" => "return", "function" => "choose", "owner" => "(top-level)", "kind" => "jump", "span" => [2, 2, 2, 10] },
      { "id" => "read", "function" => "choose", "owner" => "(top-level)", "kind" => "statement", "span" => [3, 2, 3, 3] },
      { "id" => "exit", "function" => "choose", "owner" => "(top-level)", "kind" => "exit", "span" => [1, 0, 4, 3] }
    ]
    {
      "cfg_schema" => schema,
      "documents" => [{
        "file" => file,
        "source_digest" => source_digest,
        "functions" => [{ "name" => "choose", "owner" => "fixture", "span" => [1, 0, 4, 3] }],
        "control_flow_nodes" => nodes,
        "control_flow_edges" => [],
        "places" => [{
          "id" => "a", "function" => "take", "owner" => "(top-level)",
          "kind" => "local", "name" => "a"
        }],
        "node_effects" => nodes.map do |node|
          { "function" => "choose", "owner" => "(top-level)", "node_id" => node["id"], "complete" => true }
        end,
        "liveness" => nodes.map do |node|
          {
            "function" => "choose", "owner" => "(top-level)", "node_id" => node["id"],
            "live_out" => node["id"] == "branch" ? [{ "name" => "x" }] : []
          }
        end
      }]
    }
  end

  def write_payload(dir, value)
    path = File.join(dir, "facts.json")
    File.write(path, JSON.generate(value))
    path
  end

  it "admits exact source and span identities, including Prism wrapper spans" do
    Dir.mktmpdir do |dir|
      path = write_payload(dir, payload)
      bundle = described_class::Bundle.load(source: source, source_path: "fixture.rb", facts_path: path)
      admission = bundle.admit_function(function, owner: "Object")

      expect(admission.complete).to be(true)
      expect(admission.nodes.length).to eq(5)
      expect(admission.cfg_node_for(function.body.body.first)["id"]).to eq("branch")
      expect(admission).to be_live_out("branch", "x")
      expect(admission).not_to be_live_out("read", "x")
    end
  end

  it "admits expanded methods from their source document under a new emitted owner" do
    root_source = "class Receiver; end\n"
    imported = payload
    imported_document = imported.fetch("documents").first
    root_document = imported_document.merge(
      "file" => "receiver.rb",
      "source_digest" => "sha256:#{Digest::SHA256.hexdigest(root_source)}",
      "functions" => [],
      "control_flow_nodes" => [],
      "control_flow_edges" => [],
      "node_effects" => [],
      "liveness" => []
    )
    imported["documents"] = [root_document, imported_document]

    bundle = described_class::Bundle.new(payload: imported, source: root_source)
    admission = bundle.admit_function(function, owner: "Receiver")

    expect(admission.complete).to be(true)
    expect(admission.function.fetch("owner")).to eq("fixture")
    expect(admission.nodes.map { |node| node.fetch("owner") }.uniq).to eq(["(top-level)"])
  end

  it "rejects stale, malformed, missing, and unsupported fact bundles" do
    Dir.mktmpdir do |dir|
      stale = described_class::Bundle.load(
        source: source, facts_path: write_payload(dir, payload(source_digest: "sha256:stale"))
      )
      expect(stale.admit_function(function, owner: "Object").reason).to include("current source digest")

      unsupported = described_class::Bundle.new(payload: payload(schema: "future"), source: source)
      expect(unsupported).not_to be_available
      expect(unsupported.reason).to include("unsupported CFG schema")

      missing = described_class::Bundle.load(source: source, facts_path: File.join(dir, "missing.json"))
      expect(missing.reason).to include("does not exist")

      malformed_path = File.join(dir, "malformed.json")
      File.write(malformed_path, "{")
      malformed = described_class::Bundle.load(source: source, facts_path: malformed_path)
      expect(malformed.reason).to include("invalid CFG facts JSON")
    end
  end

  it "rejects missing function and node mappings instead of using partial facts" do
    other_source = "def other; end\n"
    other = Prism.parse(other_source).value.statements.body.first
    missing_function_payload = payload(
      source_digest: "sha256:#{Digest::SHA256.hexdigest(other_source)}"
    )
    no_function = described_class::Bundle.new(payload: missing_function_payload, source: other_source)
    expect(no_function.admit_function(other, owner: "Object").reason).to include("no CFG function")

    broken = payload
    broken["documents"][0]["control_flow_nodes"][1]["span"] = [99, 0, 99, 1]
    admission = described_class::Bundle.new(payload: broken, source: source).admit_function(function, owner: "Object")
    expect(admission.complete).to be(false)
    expect(admission.reason).to include("unmapped CFG nodes")

    incomplete = payload
    incomplete["documents"][0]["node_effects"].find { |effect| effect["node_id"] == "branch" }["complete"] = false
    admission = described_class::Bundle.new(payload: incomplete, source: source).admit_function(function, owner: "Object")
    expect(admission.complete).to be(false)
    expect(admission.reason).to include("incomplete dataflow")
  end

  it "lets typed IR ignore an unreachable textual read when choosing move ownership" do
    ownership_source = "def take\n  a = [1]\n  b = a\n  return b\n  a\nend\n"
    root = Prism.parse(ownership_source).value
    write = root.statements.body.first.body.body[1]
    nodes = [
      { "id" => "entry", "function" => "take", "owner" => "(top-level)", "kind" => "entry", "span" => [1, 0, 6, 3] },
      { "id" => "assign-a", "function" => "take", "owner" => "(top-level)", "kind" => "statement", "span" => [2, 2, 2, 9] },
      { "id" => "assign-b", "function" => "take", "owner" => "(top-level)", "kind" => "statement", "span" => [3, 2, 3, 7] },
      { "id" => "return", "function" => "take", "owner" => "(top-level)", "kind" => "jump", "span" => [4, 2, 4, 10] },
      { "id" => "unreachable", "function" => "take", "owner" => "(top-level)", "kind" => "statement", "span" => [5, 2, 5, 3] },
      { "id" => "exit", "function" => "take", "owner" => "(top-level)", "kind" => "exit", "span" => [1, 0, 6, 3] }
    ]
    cfg = {
      "cfg_schema" => described_class::SCHEMA,
      "documents" => [{
        "file" => "ownership.rb",
        "source_digest" => "sha256:#{Digest::SHA256.hexdigest(ownership_source)}",
        "functions" => [{ "name" => "take", "owner" => "ownership", "span" => [1, 0, 6, 3] }],
        "places" => [{
          "id" => "a", "function" => "take", "owner" => "(top-level)",
          "kind" => "local", "name" => "a"
        }],
        "control_flow_nodes" => nodes,
        "control_flow_edges" => [],
        "node_effects" => nodes.map do |node|
          { "function" => "take", "owner" => "(top-level)", "node_id" => node["id"], "complete" => true }
        end,
        "liveness" => nodes.map do |node|
          { "function" => "take", "owner" => "(top-level)", "node_id" => node["id"], "live_out" => [] }
        end,
        "reaching_definitions" => [{
          "function" => "take", "owner" => "(top-level)", "node_id" => "assign-b",
          "place_id" => "a", "definitions" => ["assign-a"]
        }],
        "dominators" => nodes.each_with_index.map do |node, index|
          {
            "function" => "take", "owner" => "(top-level)", "node_id" => node["id"],
            "immediate_dominator" => index.zero? ? nil : nodes[index - 1]["id"]
          }
        end,
        "flow_types" => []
      }]
    }

    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "ownership.rb")
      File.write(source_path, ownership_source)
      facts_path = write_payload(dir, cfg)
      with_cfg = RubyToClear::Transpiler.new(
        ownership_source, source_path: source_path, cfg_facts_path: facts_path
      )
      with_cfg.transpile(root)
      without_cfg = RubyToClear::Transpiler.new(ownership_source)
      without_cfg.transpile(Prism.parse(ownership_source).value)

      expect(with_cfg.typed_ir.storage_ownership_for(write).mode).to eq(:move)
      expect(with_cfg.typed_ir.analysis_report.dig("aggregate", "cfg_consumption"))
        .to include("reaching_definition_ownership" => 1)
      # The legacy offset heuristic sees the unreachable line-five read.
      expect(without_cfg.typed_ir.storage_ownership.values.first.mode).to eq(:copy)
    end
  end

  it "uses complete DFG flow types when syntax-local typing is unresolved" do
    flow_source = "def pick(value)\n  value\nend\n"
    root = Prism.parse(flow_source).value
    function_node = root.statements.body.first
    read = function_node.body.body.first
    nodes = [
      { "id" => "entry", "function" => "pick", "owner" => "(top-level)", "kind" => "entry", "span" => [1, 0, 3, 3] },
      { "id" => "read", "function" => "pick", "owner" => "(top-level)", "kind" => "statement", "span" => [2, 2, 2, 7] },
      { "id" => "exit", "function" => "pick", "owner" => "(top-level)", "kind" => "exit", "span" => [1, 0, 3, 3] }
    ]
    facts = {
      "cfg_schema" => described_class::SCHEMA,
      "documents" => [{
        "file" => "flow.rb",
        "source_digest" => "sha256:#{Digest::SHA256.hexdigest(flow_source)}",
        "functions" => [{ "name" => "pick", "owner" => "flow", "span" => [1, 0, 3, 3] }],
        "places" => [{
          "id" => "value", "function" => "pick", "owner" => "(top-level)",
          "kind" => "local", "name" => "value"
        }],
        "control_flow_nodes" => nodes,
        "control_flow_edges" => [],
        "node_effects" => nodes.map do |node|
          { "function" => "pick", "owner" => "(top-level)", "node_id" => node["id"], "complete" => true }
        end,
        "liveness" => nodes.map do |node|
          { "function" => "pick", "owner" => "(top-level)", "node_id" => node["id"], "live_out" => [] }
        end,
        "reaching_definitions" => [],
        "dominators" => [
          { "function" => "pick", "owner" => "(top-level)", "node_id" => "entry", "immediate_dominator" => nil },
          { "function" => "pick", "owner" => "(top-level)", "node_id" => "read", "immediate_dominator" => "entry" },
          { "function" => "pick", "owner" => "(top-level)", "node_id" => "exit", "immediate_dominator" => "read" }
        ],
        "flow_types" => [{
          "function" => "pick", "owner" => "(top-level)", "node_id" => "read",
          "place_id" => "value", "complete" => true, "types" => ["string"]
        }]
      }]
    }

    Dir.mktmpdir do |dir|
      source_path = File.join(dir, "flow.rb")
      File.write(source_path, flow_source)
      transpiler = RubyToClear::Transpiler.new(
        flow_source, source_path: source_path, cfg_facts_path: write_payload(dir, facts)
      )
      transpiler.transpile(root)

      expect(transpiler.typed_ir.value_for(read).type.to_clear).to eq("String")
      expect(transpiler.typed_ir.analysis_report.dig("aggregate", "cfg_consumption"))
        .to include("flow_type" => 1)
    end
  end
end
