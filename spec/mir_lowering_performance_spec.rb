# typed: false

require "set"

require_relative "../src/backends/importer"
require_relative "../src/mir/mir_lowering"

RSpec.describe "MIRLowering body finalization performance" do
  class CountingMIRLowering < MIRLowering
    attr_reader :normalize_body_calls, :normalize_nested_calls, :append_nested_calls, :finalize_node_calls

    def initialize(**opts)
      super(**opts)
      @normalize_body_calls = 0
      @normalize_nested_calls = 0
      @append_nested_calls = 0
      @finalize_node_calls = 0
    end

    def normalize_allocating_mir_body(body)
      @normalize_body_calls += 1
      super
    end

    def normalize_nested_mir_bodies!(node)
      @normalize_nested_calls += 1
      super
    end

    def append_nested_ownership_transfers_for_mir_body(body, inherited_alloc_names, inherited_guarded_names, parent)
      @append_nested_calls += 1
      super
    end

    def finalize_ownership_for_mir_node!(node, body, state)
      @finalize_node_calls += 1
      super
    end
  end

  def balanced_if_body(depth)
    return [MIR::ExprStmt.new(MIR::Lit.new("0"), false)] if depth.zero?

    [
      MIR::IfStmt.new(
        MIR::Lit.new("true"),
        balanced_if_body(depth - 1),
        balanced_if_body(depth - 1),
      ),
    ]
  end

  it "normalizes nested MIR bodies proportionally instead of reprocessing them recursively" do
    lowering = CountingMIRLowering.new

    lowering.send(:append_ownership_transfers_for_mir_body, balanced_if_body(8), Set.new, Set.new)

    expect(lowering.append_nested_calls).to be <= 520
    expect(lowering.normalize_body_calls).to be <= 550
    expect(lowering.normalize_nested_calls).to be <= 800
  end

  it "does not finalize a child body again after lower_body has already finalized it" do
    lowering = CountingMIRLowering.new
    finalized_child = lowering.send(:append_ownership_transfers_for_mir_body, balanced_if_body(6), Set.new, Set.new)
    before = lowering.finalize_node_calls

    outer = [MIR::IfStmt.new(MIR::Lit.new("true"), finalized_child, nil)]
    lowering.send(:append_ownership_transfers_for_mir_body, outer, Set.new, Set.new)

    expect(lowering.finalize_node_calls - before).to be <= 2
  end
end
