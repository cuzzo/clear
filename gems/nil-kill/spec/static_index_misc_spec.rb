# frozen_string_literal: true

require_relative "spec_helper"
require_relative "../lib/nil_kill/runtime/static_index"

RSpec.describe NilKill::Runtime::StaticIndex do
  let(:root) { Dir.pwd }
  let(:index) { described_class.new({}, root: root) }
  
  describe "#normalize_field" do
    it "handles missing ids and stringifies keys" do
      field = index.send(:normalize_field, { "language" => "ruby", "path" => "foo.rb", "class" => "Foo", "field" => "bar" })
      expect(field["id"]).to eq("ruby\0foo.rb\0Foo\0field\0bar")
      expect(field["owner"]).to eq("Foo")
      expect(field["name"]).to eq("bar")
    end
  end
  
  describe "#normalize_return" do
    it "handles non-hash returns" do
      expect(index.send(:normalize_return, "String")).to eq({ "declared_type" => "String" })
      expect(index.send(:normalize_return, nil)).to eq({})
    end
  end
  
  describe "#synthetic_method_id" do
    it "handles empty kind" do
      expect(index.send(:synthetic_method_id, "ruby", "foo.rb", "Foo", "", "bar", 42)).to eq("ruby\0foo.rb\0Foo\0function\0bar\0#{42}")
    end
  end

  describe "#synthetic_method" do
    it "uses synthetic_method_id when id is nil" do
      method = index.send(:synthetic_method, "ruby", "foo.rb", "Foo", "method", "bar", 42)
      expect(method["id"]).to eq("ruby\0foo.rb\0Foo\0method\0bar\0#{42}")
      expect(method["synthetic"]).to be(true)
    end
  end

  describe "#rel_path" do
    it "rescues standard error and returns string path" do
      # Simulate a path that causes Pathname to raise ArgumentError or similar
      expect(index.send(:rel_path, "\0invalid")).to eq("\0invalid")
    end
  end

  describe "#nearby_path_name_candidates" do
    it "returns nearby candidates sorted by distance" do
      index.instance_variable_set(:@method_lookup, {
        ["path_name", "ruby", "foo.rb", "bar"] => [
          { "line" => "10", "owner" => "A" },
          { "line" => "12", "owner" => "B" },
          { "line" => "17", "owner" => "C" } # Too far from 11 (distance > 5)
        ]
      })
      
      candidates = index.send(:nearby_path_name_candidates, "ruby", "foo.rb", "bar", 11)
      expect(candidates.map { |c| c["owner"] }).to eq(["A", "B"])
    end
  end

  describe "public API fallbacks and lookups" do
    let(:populated_index) do
      described_class.new({
        "methods" => [{ "id" => "M1", "name" => "m1" }],
        "fields" => [{ "id" => "F1", "name" => "f1" }]
      }, root: root)
    end

    it "looks up methods and fields by id" do
      expect(populated_index.method("M1")["name"]).to eq("m1")
      expect(populated_index.field("F1")["name"]).to eq("f1")
    end
    
    it "locates method and normalizes falling back to synthetic" do
      id, method, found = index.resolve_method({ "method_id" => "", "locator" => {} })
      expect(found).to be(false)
      expect(method["synthetic"]).to be(true)
      expect(id).to eq(method["id"])
    end
  end
end
