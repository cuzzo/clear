require "rspec"
require_relative "../src/ast/ast" unless defined?(MIR::ReassignPlan)
require_relative "../src/ast/symbol_entry" unless defined?(SymbolEntry::BindingLifecycleFacts)
require_relative "../src/mir/fsm_lowering" unless defined?(FsmLowering::FsmLockErrorArmSplit)

RSpec.describe FsmLowering do
  let(:lowering) do
    Class.new do
      include FsmLowering
    end.new
  end

  def token
    Lexer::Token.new(:VAR_ID, "c", 1, 1)
  end

  it "uses Type sync predicates for polymorphic locked FSM captures" do
    var_node = AST::Identifier.new(token, "c")
    var_node.symbol = SymbolEntry.new(
      reg: nil,
      type: Type.new(:Counter, sync: :locked),
      mutable: true,
      storage: :stack,
      sync: :locked,
    )
    var_node.symbol.is_param = true
    cap = AST::Capability.new(
      capability: :EXCLUSIVE,
      var_node: var_node,
      alias: nil,
      alias_mutable: false,
      guard_expr: nil,
      snapshot_token: nil,
      view_token: nil,
      resolved_type: Type.new(:Counter, sync: :locked),
      old_scope: nil,
    )
    with_node = AST::WithBlock.new(token, [cap], [], nil)
    attach_capability_plan!(with_node)
    transition = CapabilityPlan.require_for(with_node).first_transition

    meta = lowering.fsm_cap_metadata(transition, with_node, 7, { "c" => Type.new(:Counter, sync: :locked) })

    expect(meta).not_to be_nil
    expect(meta[:lock_field_ref]).to include("comptime @hasField")
    expect(meta[:try_method]).to eq("tryLockForFsm")
  end

  it "uses Type write-lock predicates for polymorphic FSM captures" do
    var_node = AST::Identifier.new(token, "c")
    var_node.symbol = SymbolEntry.new(
      reg: nil,
      type: Type.new(:Counter, sync: :write_locked),
      mutable: true,
      storage: :stack,
      sync: :write_locked,
    )
    var_node.symbol.is_param = true
    cap = AST::Capability.new(
      capability: :EXCLUSIVE,
      var_node: var_node,
      alias: nil,
      alias_mutable: false,
      guard_expr: nil,
      snapshot_token: nil,
      view_token: nil,
      resolved_type: Type.new(:Counter, sync: :write_locked),
      old_scope: nil,
    )
    with_node = AST::WithBlock.new(token, [cap], [], nil)
    attach_capability_plan!(with_node)
    transition = CapabilityPlan.require_for(with_node).first_transition

    meta = lowering.fsm_cap_metadata(transition, with_node, 7, { "c" => Type.new(:Counter, sync: :write_locked) })

    expect(meta).not_to be_nil
    expect(meta[:lock_field_ref]).to include("comptime @hasField")
    expect(meta[:try_method]).to eq("tryWriteLockForFsm")
  end

  it "leaves non-polymorphic FSM captures on the direct field path" do
    var_node = AST::Identifier.new(token, "c")
    var_node.symbol = SymbolEntry.new(
      reg: nil,
      type: Type.new(:Counter),
      mutable: true,
      storage: :stack,
      sync: nil,
    )
    var_node.symbol.is_param = true
    cap = AST::Capability.new(
      capability: :EXCLUSIVE,
      var_node: var_node,
      alias: nil,
      alias_mutable: false,
      guard_expr: nil,
      snapshot_token: nil,
      view_token: nil,
      resolved_type: Type.new(:Counter),
      old_scope: nil,
    )
    with_node = AST::WithBlock.new(token, [cap], [], nil)
    attach_capability_plan!(with_node)
    transition = CapabilityPlan.require_for(with_node).first_transition

    meta = lowering.fsm_cap_metadata(transition, with_node, 7, { "c" => Type.new(:Counter) })

    expect(meta).not_to be_nil
    expect(meta[:lock_field_ref]).to eq("__ctx_7.c")
    expect(meta[:try_method]).to eq("tryLockForFsm")
  end
end
