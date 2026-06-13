require "rspec"
require_relative "../src/semantic/pass_work_profiler"

module AST
  PassWorkProfilerSpecNode = Struct.new(:children, :metadata, keyword_init: true)
end

module MIR
  PassWorkProfilerSpecNode = Struct.new(:children, :metadata, keyword_init: true)
end

RSpec.describe PassWorkProfiler do
  def ast_node(children: [], metadata: nil)
    AST::PassWorkProfilerSpecNode.new(children: children, metadata: metadata)
  end

  def mir_node(children: [], metadata: nil)
    MIR::PassWorkProfilerSpecNode.new(children: children, metadata: metadata)
  end

  it "counts AST nodes through arrays and hashes without following non-AST metadata" do
    child = ast_node
    root = ast_node(children: [child], metadata: { ignored: Object.new })

    expect(described_class.count_ast_nodes(root)).to eq(2)
    expect(described_class.count_ast_nodes([root, { again: child }])).to eq(2)
  end

  it "counts MIR nodes independently of AST nodes" do
    root = mir_node(children: [mir_node, ast_node])

    expect(described_class.count_mir_nodes(root)).to eq(2)
    expect(described_class.count_ast_nodes(root)).to eq(0)
  end

  it "guards cycles while counting structural nodes" do
    root = ast_node(children: [])
    root.children << root

    expect(described_class.count_ast_nodes(root)).to eq(1)
  end

  it "formats compact counts" do
    expect(described_class.format_count(999)).to eq("999")
    expect(described_class.format_count(12_500)).to eq("12.5k")
    expect(described_class.format_count(2_400_000)).to eq("2.4m")
  end

  it "records stage work and reports walker ratios" do
    profiler = described_class::Profiler.new
    root = ast_node(children: [ast_node])

    result = profiler.measure("annotator.body_analysis", ast_root: root, token_count: 7) do
      profiler.record_walk("AST.walk_body", 6, 0.125)
      :done
    end

    record = profiler.records.fetch(0)
    expect(result).to eq(:done)
    expect(record.calls).to eq(1)
    expect(record.input_tokens).to eq(7)
    expect(record.input_ast_nodes).to eq(2)
    expect(record.ast_walk_calls).to eq(1)
    expect(record.ast_walk_yields).to eq(6)
    expect(record.ast_yields_per_input_node).to eq(3.0)
    expect(record.top_walkers).to eq("AST.walk_body:6")
    expect(record.top_walk_times).to eq("AST.walk_body:0.125s")
  end

  it "records exact work counters separately from raw walker counters" do
    profiler = described_class::Profiler.new

    profiler.record_work("MIRLowering.match.switch", 4, 0.5, 0.125)
    record = profiler.records.fetch(0)

    expect(record.label).to eq("(outside)")
    expect(record.total_work_calls).to eq(1)
    expect(record.total_work_units).to eq(4)
    expect(record.top_work).to eq("MIRLowering.match.switch:4")
    expect(record.top_work_times).to eq("MIRLowering.match.switch:0.500s")
    expect(record.top_work_exclusive_times).to eq("MIRLowering.match.switch:0.125s")
    expect(profiler.work_summaries.fetch(0).kind).to eq("MIRLowering.match.switch")
    expect(profiler.work_details_to_csv).to include("MIRLowering.match.switch,1,4,0.500000,0.125000")
    expect(profiler.work_details_to_table).to include("MIRLowering.match.switch")
  end

  it "measures nested work with exclusive child time removed" do
    profiler = described_class::Profiler.new

    result = profiler.measure("mir.lower") do
      profiler.measure_work("outer", units: 10) do
        profiler.measure_work("inner", units: 3) { :inner }
        :done
      end
    end

    record = profiler.records.fetch(0)
    outer_total = record.work_seconds.fetch("outer")
    outer_exclusive = record.work_exclusive_seconds.fetch("outer")

    expect(result).to eq(:done)
    expect(record.total_work_calls).to eq(2)
    expect(record.total_work_units).to eq(13)
    expect(record.work_calls.fetch("outer")).to eq(1)
    expect(record.work_calls.fetch("inner")).to eq(1)
    expect(outer_exclusive).to be <= outer_total
    expect(record.work_exclusive_seconds.fetch("inner")).to be > 0.0
  end

  it "records work outside an explicit stage and keeps zero-input ratios finite" do
    profiler = described_class::Profiler.new

    profiler.record_walk("MIR.each_node", 4, 0.1)
    record = profiler.records.fetch(0)

    expect(record.label).to eq("(outside)")
    expect(record.mir_walk_calls).to eq(1)
    expect(record.mir_walk_yields).to eq(4)
    expect(record.mir_yields_per_input_node).to eq(0.0)
  end

  it "renders table and CSV summaries" do
    profiler = described_class::Profiler.new
    profiler.measure("mir.lower", mir_root: mir_node(children: [mir_node])) do
      profiler.record_walk("MIR.each_surface_node", 5, 0.2)
    end

    expect(profiler.to_table).to include("mir.lower")
    expect(profiler.to_table).to include("MIR.each_surface_node:5")
    expect(profiler.to_csv).to include("stage,calls,input_tokens")
    expect(profiler.to_csv).to include("top_work_exclusive_times")
    expect(profiler.to_csv).to include("mir.lower")
  end

  it "uses token count as the work-ratio denominator when no node input exists" do
    profiler = described_class::Profiler.new
    profiler.measure("parser.parse", token_count: 10) do
      profiler.record_walk("ClearParser.step", 5, 0.01)
    end

    expect(profiler.records.fetch(0).walk_yields_per_input).to eq(0.5)
  end

  it "ignores anonymous structural objects while counting nodes" do
    anonymous = Class.new(Struct.new(:child, keyword_init: true)).new(child: ast_node)

    expect(described_class.count_ast_nodes(anonymous)).to eq(0)
  end

  it "stores the current profiler in thread-local state" do
    profiler = described_class::Profiler.new

    described_class.current = profiler
    expect(described_class.current).to equal(profiler)
  ensure
    described_class.current = nil
  end
end
