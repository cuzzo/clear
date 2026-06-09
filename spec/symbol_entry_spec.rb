require_relative "../src/ast/symbol_entry"
require "set"

RSpec.describe SymbolEntry do
  let(:entry) do
    SymbolEntry.new(
      reg: :some_node,
      type: :Int64,
      mutable: true,
      storage: :stack,
      sync: :locked,
      size: 8,
      capabilities: Set[:RESTRICT]
    )
  end

  describe "attr_accessor" do
    it "provides typed field access" do
      expect(entry.type).to eq(:Int64)
      expect(entry.mutable).to eq(true)
      expect(entry.storage).to eq(:stack)
      expect(entry.sync).to eq(:locked)
      expect(entry.size).to eq(8)
      expect(entry.valid).to eq(true)
    end

    it "allows direct mutation" do
      entry.storage = :heap
      expect(entry.storage).to eq(:heap)
    end
  end

  describe "scope back-reference" do
    it "starts as nil (set by Scope#declare)" do
      expect(entry.scope).to be_nil
    end

    it "can be set and read" do
      entry.scope = :mock_scope
      expect(entry.scope).to eq(:mock_scope)
    end

    it "is preserved through dup" do
      entry.scope = :original_scope
      copy = entry.dup
      expect(copy.scope).to eq(:original_scope)
    end
  end

  describe "dup" do
    it "shares lifecycle facts and shallow-copies overlays" do
      copy = entry.dup
      expect(copy.type).to eq(:Int64)
      expect(copy.storage).to eq(:stack)
      expect(copy.lifecycle).to equal(entry.lifecycle)
      expect(copy.capabilities).to equal(entry.capabilities) # same object (shallow)
    end

    it "shares storage lifecycle changes across branch copies" do
      copy = entry.dup
      copy.storage = :heap

      expect(entry.storage).to eq(:heap)
    end

    it "forks binding flow facts when copied" do
      entry.mark_read!
      entry.mark_mutated!(touch_declaration: false)
      entry.mark_mutated_via_reference!
      entry.mark_poly_borrow_target!
      entry.mark_init_contents_heap!

      copy = entry.dup
      copy.mark_non_escaping!
      copy.invalidate!("branch-local invalidation")

      expect(copy.read).to eq(true)
      expect(copy.mutated).to eq(true)
      expect(copy.mutable_ref_target).to eq(true)
      expect(copy.poly_borrow_target).to eq(true)
      expect(copy.init_contents_heap).to eq(true)
      expect(copy.valid).to eq(false)
      expect(copy.invalid_reason).to eq("branch-local invalidation")

      expect(entry.non_escaping).to eq(false)
      expect(entry.valid).to eq(true)
      expect(entry.invalid_reason).to be_nil
    end

    it "preserves stable binding identity across branch copies" do
      copy = entry.dup
      other = SymbolEntry.new(reg: :other_node, type: :Int64, mutable: true, storage: :stack)

      expect(copy.binding_id).to eq(entry.binding_id)
      expect(other.binding_id).not_to eq(entry.binding_id)
    end
  end

  describe "defaults" do
    it "provides sensible defaults for optional fields" do
      minimal = SymbolEntry.new(reg: nil, type: :Bool, mutable: false, storage: :stack)
      expect(minimal.sync).to be_nil
      expect(minimal.rebindable).to eq(false)
      expect(minimal.size).to eq(0)
      expect(minimal.capabilities).to eq(Set.new)
      expect(minimal.valid).to eq(true)
      expect(minimal.invalid_reason).to be_nil
      expect(minimal.resource).to be_nil
      expect(minimal.close_plan).to be_nil
      expect(minimal.scope).to be_nil
    end
  end

  describe "integration with scope locals iteration" do
    it "works in each { |name, info| info.type } pattern" do
      locals = { "x" => entry }
      result = nil
      locals.each { |_name, info| result = info.type }
      expect(result).to eq(:Int64)
    end
  end
end
