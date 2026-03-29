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

  describe "Hash compatibility: []" do
    it "reads fields by symbol key" do
      expect(entry[:type]).to eq(:Int64)
      expect(entry[:mutable]).to eq(true)
      expect(entry[:storage]).to eq(:stack)
      expect(entry[:sync]).to eq(:locked)
    end

    it "returns nil for unknown keys" do
      expect(entry[:nonexistent]).to be_nil
    end
  end

  describe "Hash compatibility: []=" do
    it "writes fields by symbol key" do
      entry[:storage] = :heap
      expect(entry.storage).to eq(:heap)
      expect(entry[:storage]).to eq(:heap)
    end
  end

  describe "Hash compatibility: dig" do
    it "returns field value for single key" do
      expect(entry.dig(:type)).to eq(:Int64)
    end

    it "returns nil for missing key" do
      expect(entry.dig(:nonexistent)).to be_nil
    end
  end

  describe "Hash compatibility: key?" do
    it "returns true for known fields" do
      expect(entry.key?(:type)).to eq(true)
      expect(entry.key?(:storage)).to eq(true)
    end

    it "returns false for unknown fields" do
      expect(entry.key?(:nonexistent)).to eq(false)
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
    end
  end

  describe "integration with scope locals iteration" do
    it "works in each { |name, info| info[:type] } pattern" do
      locals = { "x" => entry }
      result = nil
      locals.each { |_name, info| result = info[:type] }
      expect(result).to eq(:Int64)
    end
  end
end
