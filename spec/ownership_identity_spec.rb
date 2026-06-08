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
      expect(child.parent).to eq(place)
    end

    it "can be reused as a stable hash key while comparing to legacy names" do
      place = described_class.from_path("slot")
      same = described_class.from_path(place)
      table = { place => :owned }

      expect(same).to equal(place)
      expect(place).to eq("slot")
      expect(place).to eq(:slot)
      expect(place).not_to eq(Object.new)
      expect(table[described_class.from_path("slot")]).to eq(:owned)
    end
  end
end
