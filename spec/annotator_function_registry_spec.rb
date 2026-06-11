require "rspec"
require "set"

require_relative "../src/annotator/function_registry"

RSpec.describe Annotator::FunctionRegistry do
  def token(value)
    Lexer::Token.new(:VAR_ID, value, 1, 1)
  end

  def function_def(name)
    AST::FunctionDef.new(token(name), name, [], [], Type.new(:Void), nil, [], [], nil, :pub, [], false)
  end

  def body_summary(name, callees: Set.new, propagating: callees, fnptr: false, raises: false)
    Annotator::Phases::FunctionBodySummary.new(
      name: name,
      callees: callees,
      propagating_callees: propagating,
      has_fnptr_call: fnptr,
      raises_directly: raises
    )
  end

  it "registers and looks up function nodes by name" do
    registry = described_class.new
    main = function_def("main")

    expect(registry.register!(main)).to eq(main)
    expect(registry.fetch("main")).to eq(main)
    expect(registry.fetch(nil)).to be_nil
    expect(registry.key?("main")).to be(true)
    expect(registry.names).to eq(["main"])

    seen = []
    registry.each_node { |fn| seen << fn.name }
    expect(seen).to eq(["main"])
  end

  it "rejects duplicate function nodes" do
    registry = described_class.new
    registry.register!(function_def("main"))

    expect {
      registry.register!(function_def("main"))
    }.to raise_error(RuntimeError, /duplicate function node 'main'/)
  end

  it "tracks synthetic definitions as a clearable queue" do
    registry = described_class.new
    generated = function_def("generated")

    expect(registry.add_synthetic_definition!(generated)).to eq(generated)
    expect(registry.synthetic_definitions).to eq([generated])

    registry.clear_synthetic_definitions!

    expect(registry.synthetic_definitions).to eq([])
  end

  it "records body summaries and exposes derived call graph facts" do
    registry = described_class.new
    summary = body_summary(
      "caller",
      callees: Set["callee"],
      propagating: Set["fallible"],
      fnptr: true,
      raises: true
    )

    expect(registry.record_body_summary!(summary)).to eq(summary)
    expect(registry.body_summary_for("caller")).to eq(summary)
    expect(registry.body_summary_for("missing")).to be_nil
    expect(registry.body_summaries).to eq("caller" => summary)
    expect(registry.call_graph).to eq("caller" => Set["callee"])
    expect(registry.propagating_callees).to eq("caller" => Set["fallible"])
    expect(registry.fnptr_call?("caller")).to be(true)
    expect(registry.fnptr_call?("missing")).to be(false)
    expect(registry.raises_directly?("caller")).to be(true)
    expect(registry.raises_directly?("missing")).to be(false)
  end
end
