# typed: false

require "set"

require_relative "../src/compiler/module_importer" unless defined?(ModuleImporter)
require_relative "../src/mir/mir_lowering" unless defined?(MIRLowering::OwnershipSurfaceScan)

RSpec.describe "MIRLowering body finalization performance" do
  class CountingMIRLowering < MIRLowering
    attr_reader :normalize_body_calls, :normalize_nested_calls, :append_nested_calls, :finalize_node_calls

    def initialize(**opts)
      super(input: MIRLoweringInput.new(**opts))
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

  OwnedTargetExpr = Struct.new(:target_var) do
    include MIR::Expr

    def result_type
      Type.new(:String)
    end

    def ownership_effect
      MIR::OwnershipEffect.owned(alloc: :heap, target_var: target_var)
    end
  end

  OwnedWrapperExpr = Struct.new(:child, :target_var) do
    include MIR::Expr

    def result_type
      Type.new(:String)
    end

    def child_exprs
      [child]
    end

    def ownership_effect
      child.ownership_effect
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

  it "does not duplicate ownership facts when a finalized flat body is assembled again" do
    lowering = CountingMIRLowering.new
    cleanup = CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
    body = [
      MIR::AllocMark.new("items", :heap, Type.new(:"Int64[]", collection: :list), :heap),
      MIR::Let.new("items", MIR::ContainerInit.new("std.ArrayListUnmanaged(i64)", :array_list_empty, :heap, nil), true, Type.new("std.ArrayListUnmanaged(i64)")),
      MIR::Cleanup.new("items", cleanup),
    ]

    finalized = lowering.send(:append_ownership_transfers_for_mir_body, body, Set.new, Set.new)
    refinalized = lowering.send(:append_ownership_transfers_for_mir_body, finalized, Set.new, Set.new)

    owned_creates = refinalized.select { |node| node.is_a?(MIR::OwnedCreate) }
    owned_destroys = refinalized.select { |node| node.is_a?(MIR::OwnedDestroy) }

    expect(owned_creates.count { |node| node.name == "items" && node.source == "items" }).to eq(1)
    expect(owned_creates.count { |node| node.name == "items" && node.source == "MIR::ContainerInit" }).to eq(1)
    expect(owned_creates.count { |node| node.name == "MIR::ContainerInit" && node.source == "MIR::ContainerInit" }).to eq(1)
    expect(owned_destroys.count { |node| node.name == "items" && node.source == "items" }).to eq(1)
  end

  it "does not duplicate owned-result facts for target-var inline zig initializers" do
    lowering = CountingMIRLowering.new
    init = OwnedWrapperExpr.new(OwnedTargetExpr.new("tmp"), "tmp")
    let = MIR::Let.new("tmp", init, false, Type.new(:String), nil)
    owned_creates_after_let = lowering
      .send(:ownership_facts_for_mir_surface, let)
      .select { |node| node.is_a?(MIR::OwnedCreate) }

    expect(owned_creates_after_let.count { |node| node.name == "tmp" && node.source == "tmp" }).to eq(1)
  end
end
