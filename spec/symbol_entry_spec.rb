require_relative "../src/symbol_entry"
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
    it "shallow copies all fields" do
      copy = entry.dup
      expect(copy.type).to eq(:Int64)
      expect(copy.storage).to eq(:stack)
      expect(copy.capabilities).to equal(entry.capabilities) # same object (shallow)
    end

    it "does not affect original when copy is modified" do
      copy = entry.dup
      copy.storage = :heap
      expect(entry.storage).to eq(:stack)
    end
  end

  describe "defaults" do
    it "provides sensible defaults for optional fields" do
      minimal = SymbolEntry.new(reg: nil, type: :Bool, mutable: false, storage: :stack)
      expect(minimal.sync).to be_nil
      expect(minimal.rebindable).to eq(false)
      expect(minimal.size).to eq(0)
      expect(minimal.capabilities).to eq(Set.new)
      expect(minimal.borrowed_paths).to eq([])
      expect(minimal.valid).to eq(true)
      expect(minimal.invalid_reason).to be_nil
      expect(minimal.resource).to be_nil
      expect(minimal.close_zig).to be_nil
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
