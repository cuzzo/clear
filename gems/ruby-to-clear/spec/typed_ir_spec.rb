# frozen_string_literal: true

require "spec_helper"

RSpec.describe RubyToClear::TypedIR::TypeRef do
  describe ".parse" do
    it "separates only a top-level capability from a structural type" do
      nested = described_class.parse("HashMap<String@symbol, Variant@multiowned>")
      outer = described_class.parse("?HashMap<String@symbol, Variant@multiowned>@shared")

      expect(nested.name).to eq("HashMap<String@symbol, Variant@multiowned>")
      expect(nested.capability).to be_nil
      expect(nested.to_clear).to eq("HashMap<String@symbol, Variant@multiowned>")

      expect(outer.name).to eq("HashMap<String@symbol, Variant@multiowned>")
      expect(outer.capability).to eq("shared")
      expect(outer.to_clear).to eq("?HashMap<String@symbol, Variant@multiowned>@shared")
    end
  end
end
