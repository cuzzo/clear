require "rspec"
require_relative "../src/ast/type" unless defined?(Type)

# Tests that Type#needs_promotion? and Type#needs_cleanup? mirror
# the Zig comptime needsPromotion and needsCleanup functions exactly.
#
# Zig needsPromotion: []const u8, ArrayList, StringMap, struct/union recurse
# Zig needsCleanup:   StringMap, NumericMap, Pool, ArrayList, has_deinit, struct/union recurse
#
# Raw slices ([]i64) are NOT promotable — only ArrayList (which knows its allocator).
# Struct fields typed as T[] are slices in Zig; ArrayList variables are promoted
# separately by mark_escaping_collections!.

RSpec.describe "Type promotion/cleanup analysis" do
  let(:schemas) do
    {
      Point: Schemas::StructSchema.new(fields: { "x" => :Float64, "y" => :Float64 }),
      User: Schemas::StructSchema.new(fields: { "name" => :String, "age" => :Int64 }),
      ListHolder: Schemas::StructSchema.new(fields: { "items" => Type.new(:"Int64[]"), "label" => :String }),
      MapHolder: Schemas::StructSchema.new(fields: { "data" => Type.new(:"HashMap<Int64>"), "label" => :String }),
      PureSliceHolder: Schemas::StructSchema.new(fields: { "items" => Type.new(:"Int64[]"), "count" => :Int64 }),
      JsonValue: Schemas::UnionSchema.new(variants: {
        "Null" => nil,
        "JBool" => Type.new(:Bool),
        "JNum" => Type.new(:Float64),
        "JStr" => Type.new(:String),
        "JArray" => Type.new(:"JsonValue[]"),
        "JObj" => Type.new(:"HashMap<JsonValue>"),
      }),
      Direction: Schemas::EnumSchema.new(variants: Set["North", "South"]),
      SimpleUnion: Schemas::UnionSchema.new(variants: {
        "A" => Type.new(:Float64),
        "B" => Type.new(:Int64),
      }),
    }
  end

  let(:lookup) { ->(name) { schemas[name] } }

  # =========================================================================
  # needs_promotion? — mirrors Zig needsPromotion
  # =========================================================================
  describe "#needs_promotion?" do
    # --- Primitives: false ---
    it("false for Float64") { expect(Type.new(:Float64).needs_promotion?).to be false }
    it("false for Int64")   { expect(Type.new(:Int64).needs_promotion?).to be false }
    it("false for Bool")    { expect(Type.new(:Bool).needs_promotion?).to be false }

    # --- String: true (Zig: []const u8) ---
    it("true for String") { expect(Type.new(:String).needs_promotion?).to be true }

    # --- ArrayList (@list): true (Zig: isArrayList) ---
    it "true for @list collection" do
      t = Type.new(:"Float64[]")
      t.collection = :list
      expect(t.needs_promotion?).to be true
    end

    # --- Raw slice (Int64[]): false — NOT an ArrayList, NOT a string ---
    # Struct fields typed as T[] are slices in Zig. ArrayList variables are
    # promoted per-variable by mark_escaping_collections!, not by type predicate.
    it "false for raw dynamic slice (not @list)" do
      expect(Type.new(:"Int64[]").needs_promotion?).to be false
    end

    # --- StringMap: true (Zig: isStringMap) ---
    it("true for HashMap (string map)") { expect(Type.new(:"HashMap<Int64>").needs_promotion?).to be true }

    # --- NumericMap: false (uses heapAlloc, no stored allocator to swap) ---
    it("false for numeric map") { expect(Type.new(:"HashMap<Int64,Float64>").needs_promotion?).to be false }

    # --- Enum: false ---
    it("false for enum") { expect(Type.new(:Direction).needs_promotion?(lookup)).to be false }

    # --- Struct recursion (requires schema_lookup) ---
    it("false for struct with only numeric fields") do
      expect(Type.new(:Point).needs_promotion?(lookup)).to be false
    end

    it "true for struct with String field" do
      expect(Type.new(:User).needs_promotion?(lookup)).to be true
    end

    it "true for struct with HashMap field" do
      expect(Type.new(:MapHolder).needs_promotion?(lookup)).to be true
    end

    # ListHolder has { items: Int64[], label: String } — String makes it true
    it "true for struct with String field (ListHolder)" do
      expect(Type.new(:ListHolder).needs_promotion?(lookup)).to be true
    end

    # PureSliceHolder has { items: Int64[], count: Int64 } — no promotable fields
    it "false for struct with only raw slice and numeric fields" do
      expect(Type.new(:PureSliceHolder).needs_promotion?(lookup)).to be false
    end

    # --- Union recursion ---
    it "true for union with String variant (JsonValue)" do
      expect(Type.new(:JsonValue).needs_promotion?(lookup)).to be true
    end

    it "false for union with only primitive variants" do
      expect(Type.new(:SimpleUnion).needs_promotion?(lookup)).to be false
    end

    # --- Schema lookup is required for struct/union ---
    it "false for struct type without schema lookup (can't recurse)" do
      expect(Type.new(:User).needs_promotion?).to be false
    end
  end

  # =========================================================================
  # needs_cleanup? — mirrors Zig needsCleanup
  # =========================================================================
  describe "#needs_cleanup?" do
    # --- Primitives: false ---
    it("false for Float64") { expect(Type.new(:Float64).needs_cleanup?).to be false }
    it("false for Int64")   { expect(Type.new(:Int64).needs_cleanup?).to be false }

    # --- String: false (not a standalone heap owner) ---
    it("false for String") { expect(Type.new(:String).needs_cleanup?).to be false }

    # --- Collections: true ---
    it "true for @list" do
      t = Type.new(:"Float64[]")
      t.collection = :list
      expect(t.needs_cleanup?).to be true
    end

    it("true for HashMap (StringMap)")  { expect(Type.new(:"HashMap<Int64>").needs_cleanup?).to be true }
    it("true for numeric map")          { expect(Type.new(:"HashMap<Int64,Float64>").needs_cleanup?).to be true }

    # --- Ownership types: true ---
    it("true for Rc")   { expect(Type.new(:Point).tap { |t| t.ownership = :multiowned }.needs_cleanup?).to be true }
    it("true for Arc")  { expect(Type.new(:Point).tap { |t| t.ownership = :shared }.needs_cleanup?).to be true }
    it("true for @link") { expect(Type.new(:Point).tap { |t| t.ownership = :link }.needs_cleanup?).to be true }

    # --- Struct recursion ---
    it("false for plain struct") { expect(Type.new(:Point).needs_cleanup?(lookup)).to be false }

    # --- Union recursion ---
    it "true for union with collection variants" do
      expect(Type.new(:JsonValue).needs_cleanup?(lookup)).to be true
    end

    it "false for union with only primitive variants" do
      expect(Type.new(:SimpleUnion).needs_cleanup?(lookup)).to be false
    end

    # --- Invariant: needs_promotion => needs_cleanup for non-strings ---
    it "needs_promotion implies needs_cleanup for non-string types" do
      types = [
        Type.new(:"Float64[]").tap { |t| t.collection = :list },
        Type.new(:"HashMap<Int64>"),
      ]
      types.each do |t|
        expect(t.needs_cleanup?).to be(true),
          "#{t.resolved} needs_promotion but NOT needs_cleanup"
      end
    end
  end
end
