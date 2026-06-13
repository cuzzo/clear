require "rspec"
require "set"

require_relative "../src/ast/lexer" unless defined?(Lexer)
require_relative "../src/ast/ast" unless defined?(AST::Node)
require_relative "../src/ast/type" unless defined?(Type)

RSpec.describe Type, "ownership and cleanup contracts" do
  def schema_lookup
    schemas = {
      Box: Schemas::StructSchema.new(fields: { "field" => Type.new(:String) }),
      Point: Schemas::StructSchema.new(fields: { "x" => Type.new(:Int64) }),
      Mode: Schemas::EnumSchema.new(variants: Set[:On, :Off]),
      Choice: Schemas::UnionSchema.new(variants: { Empty: nil, Count: Type.new(:Int64) }),
      OwnedChoice: Schemas::UnionSchema.new(variants: { Empty: nil, Name: Type.new(:String) }),
      InlineOwned: Schemas::UnionSchema.new(
        variants: {
          Pair: Schemas::InlineStructVariant.new(fields: { "name" => Type.new(:String) }),
        },
      ),
    }
    ->(name) { schemas[name] || schemas[name.to_sym] }
  end

  def heap_string
    Type.new(:String, location: :heap)
  end

  def rodata_string
    Type.new(:String, location: :rodata)
  end

  describe "heap pointer and escape promotion shape" do
    it "classifies pointer-backed values without treating primitives or fixed arrays as heap pointers" do
      expect(Type.new(:Int64).heap_ptr?).to eq(false)
      expect(Type.new(:String).heap_ptr?).to eq(true)
      expect(Type.optional_of(:String).heap_ptr?).to eq(true)
      expect(Type.optional_of(:Int64).heap_ptr?).to eq(false)
      expect(Type.array_of(:Int64, capacity: 4).heap_ptr?).to eq(false)
      expect(Type.array_of(:Int64).heap_ptr?).to eq(true)
      expect(Type.new(:"HashMap<String>").heap_ptr?).to eq(true)
      expect(Type.new(:"Int64[]", collection: :list).heap_ptr?).to eq(true)
      expect(Type.new(:"~Int64", observable: true).heap_ptr?).to eq(true)
      expect(Type.new(:Box, layout: :indirect).heap_ptr?).to eq(true)
    end

    it "promotes only managed slices, not sharded or rodata-backed values" do
      expect(Type.new(:String).needs_escape_promotion?).to eq(true)
      expect(rodata_string.needs_escape_promotion?).to eq(false)
      expect(Type.new(:"Int64[]", collection: :list).needs_escape_promotion?).to eq(true)
      expect(Type.new(:"Int64[]", collection: :list, shard_count: 4).needs_escape_promotion?).to eq(false)
      expect(Type.new(:Point).needs_escape_promotion?).to eq(false)
    end
  end

  describe "cleanup and ownership predicates" do
    it "distinguishes cleanup ownership from borrowed and copyable values" do
      expect(Type.new(:Int64).needs_cleanup?(schema_lookup)).to eq(false)
      expect(Type.new(:String).needs_cleanup?(schema_lookup)).to eq(false)
      expect(heap_string.needs_cleanup?(schema_lookup)).to eq(true)
      expect(Type.optional_of(:String).needs_cleanup?(schema_lookup)).to eq(true)
      expect(Type.new(:String, location: :borrow).needs_cleanup?(schema_lookup)).to eq(false)
      expect(Type.new(:"Int64[]", collection: :list).needs_cleanup?(schema_lookup)).to eq(true)
      expect(Type.new(:Box).needs_cleanup?(schema_lookup)).to eq(false)
      expect(Type.new(:Box).recursive_cleanup_shape?(schema_lookup)).to eq(true)
    end

    it "reports ownership-bearing values that cannot be treated as plain copy data" do
      expect(Type.new(:Int64).ownership_bearing?(schema_lookup)).to eq(false)
      expect(Type.new(:Void).ownership_bearing?(schema_lookup)).to eq(false)
      expect(Type.new(:String).ownership_bearing?(schema_lookup)).to eq(true)
      expect(Type.new(:Box).ownership_bearing?(schema_lookup)).to eq(true)
      expect(Type.new(:Point).ownership_bearing?(schema_lookup)).to eq(false)
      expect(Type.error_union_of(:String).ownership_bearing?(schema_lookup)).to eq(true)
    end

    it "requires explicit cleanup only when allocator and type shape demand it" do
      expect(Type.new(:String).needs_explicit_cleanup?(:frame, schema_lookup)).to eq(false)
      expect(Type.new(:String).needs_explicit_cleanup?(:heap, schema_lookup)).to eq(true)
      expect(Type.new(:File).needs_explicit_cleanup?(:frame, schema_lookup)).to eq(true)
      expect(Type.new(:Box, ownership: :multiowned).needs_explicit_cleanup?(:frame, schema_lookup)).to eq(true)
      expect(Type.new(:"Int64[]", collection: :list).needs_explicit_cleanup?(:frame, schema_lookup)).to eq(false)
      expect(Type.new(:Box).needs_explicit_cleanup?(:heap, schema_lookup)).to eq(true)
      expect(Type.new(:Point).needs_explicit_cleanup?(:frame, schema_lookup)).to eq(false)
    end

    it "chooses heap cleanup allocators only for heap-backed cleanup families" do
      expect(Type.new(:String).cleanup_allocator(schema_lookup)).to eq(:frame)
      expect(heap_string.cleanup_allocator(schema_lookup)).to eq(:heap)
      expect(Type.new(:File).cleanup_allocator(schema_lookup)).to eq(:heap)
      expect(Type.new(:Box, ownership: :multiowned).cleanup_allocator(schema_lookup)).to eq(:heap)
      expect(Type.new(:Box, sync: :locked).cleanup_allocator(schema_lookup)).to eq(:heap)
      expect(Type.new(:"Int64[]", collection: :list).cleanup_allocator(schema_lookup)).to eq(:frame)
      expect(Type.new(:Box).cleanup_allocator(schema_lookup)).to eq(:heap)
      expect(Type.new(:Point).cleanup_allocator(schema_lookup)).to eq(:frame)
    end
  end

  describe "copy and capture contracts" do
    it "keeps BG value-copy rules stricter than general implicit copy rules" do
      expect(Type.new(:Int64).bg_capture_is_value_copy?(schema_lookup)).to eq(true)
      expect(rodata_string.bg_capture_is_value_copy?(schema_lookup)).to eq(true)
      expect(Type.new(:String).bg_capture_is_value_copy?(schema_lookup)).to eq(false)
      expect(Type.new(:Mode).bg_capture_is_value_copy?(schema_lookup)).to eq(true)
      expect(Type.new(:Choice).bg_capture_is_value_copy?(schema_lookup)).to eq(true)
      expect(Type.new(:OwnedChoice).bg_capture_is_value_copy?(schema_lookup)).to eq(false)
      expect(Type.new(:Box).bg_capture_is_value_copy?(schema_lookup)).to eq(false)
    end

    it "allows implicit copies only for copy-safe scalar, enum, union, array, and all-copy struct shapes" do
      expect(Type.new(:Int64).implicitly_copyable?(schema_lookup)).to eq(true)
      expect(rodata_string.implicitly_copyable?(schema_lookup)).to eq(true)
      expect(Type.new(:String).implicitly_copyable?(schema_lookup)).to eq(false)
      expect(Type.array_of(:Int64, capacity: 4).implicitly_copyable?(schema_lookup)).to eq(true)
      expect(Type.new(:Mode).implicitly_copyable?(schema_lookup)).to eq(true)
      expect(Type.new(:Choice).implicitly_copyable?(schema_lookup)).to eq(true)
      expect(Type.new(:OwnedChoice).implicitly_copyable?(schema_lookup)).to eq(false)
      expect(Type.new(:Point).implicitly_copyable?(schema_lookup)).to eq(true)
      expect(Type.new(:Box).implicitly_copyable?(schema_lookup)).to eq(false)
    end
  end

  describe "payload and acceptance contracts" do
    it "unwraps success and payload types without losing ownership shape" do
      expect(Type.error_union_of(:String).success_type).to eq(Type.new(:String))
      expect(Type.optional_of(:String).value_payload_type).to eq(Type.new(:String))
      expect(Type.error_union_of(:String).value_payload_type).to eq(Type.new(:String))
      expect(Type.error_union_of(Type.optional_of(:String)).value_payload_type).to eq(Type.new(:String))
      expect(Type.new(:Int64).value_payload_type).to eq(Type.new(:Int64))
    end

    it "accepts only compatible optional, error-union, array, and map values" do
      expect(Type.optional_of(:String).accepts?(Type.new(:String))).to eq(true)
      expect(Type.optional_of(:String).accepts?(Type.new(:NIL))).to eq(true)
      expect(Type.error_union_of(:String).accepts?(Type.new(:String))).to eq(true)
      expect(Type.array_of(:Int64).accepts?(Type.array_of(:Byte))).to eq(true)
      expect(Type.new(:"HashMap<Any>").accepts?(Type.new(:"HashMap<String>"))).to eq(true)
      expect(Type.new(:String).accepts?(Type.new(:Bool))).to eq(false)
      expect(Type.array_of(:String, capacity: 2).accepts?(Type.array_of(:String, capacity: 3))).to eq(false)
    end
  end
end
