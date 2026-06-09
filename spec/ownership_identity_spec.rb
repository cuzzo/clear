require "rspec"
require_relative "../src/semantic/ownership_identity"

RSpec.describe OwnershipIdentity do
  describe OwnershipIdentity::BindingId do
    it "builds a stable binding identity from a symbol entry" do
      symbol = SymbolEntry.new(reg: :node, type: :String, mutable: false, storage: :heap)
      binding = described_class.from_symbol("name", symbol)

      expect(binding.name).to eq("name")
      expect(binding.binding_id).to eq(symbol.binding_id)
      expect(binding.to_s).to eq("name##{symbol.binding_id}")
    end
  end

  describe OwnershipIdentity::PlaceId do
    it "normalizes paths and exposes parent place identity" do
      place = described_class.from_path(:root)
      child = described_class.from_path("root.child")

      expect(place.path).to eq("root")
      expect(place.child?).to be(false)
      expect(place.parent).to be_nil
      expect(child.child?).to be(true)
      expect(child.parent).to be_a(described_class)
      expect(T.must(child.parent).path).to eq(place.path)
      expect(T.must(child.parent)).to eql(place)
    end

    it "can be reused as a stable hash key" do
      place = described_class.from_path("slot")
      same = described_class.from_path(place)
      table = { place => :owned }

      expect(same).to equal(place)
      expect(place.path).to eq("slot")
      expect(place).not_to eql(Object.new)
      expect(table[described_class.from_path("slot")]).to eq(:owned)
    end

    it "distinguishes shadowed bindings with the same display path" do
      outer = SymbolEntry.new(reg: :outer, type: :String, mutable: false, storage: :heap)
      inner = SymbolEntry.new(reg: :inner, type: :String, mutable: false, storage: :heap)
      outer_place = described_class.from_symbol("slot", outer)
      inner_place = described_class.from_symbol("slot", inner)
      table = { outer_place => :outer, inner_place => :inner }

      expect(outer_place.path).to eq("slot")
      expect(outer_place.binding_identity).not_to be_nil
      expect(inner_place.binding_identity).not_to be_nil
      expect(outer_place).not_to eql(inner_place)
      expect(table[outer_place]).to eq(:outer)
      expect(table[inner_place]).to eq(:inner)
    end
  end
end
