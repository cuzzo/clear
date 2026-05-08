# typed: true
# Typed schemas for declared types stored in Scope.
#
# Replaces the hash-as-struct pattern where every type's schema was a
# Hash and dispatch was done by inspecting `schema[:kind]`. The kinds
# are heterogeneous enough that one Hash made the call sites repeat
# `schema.is_a?(Hash) && schema[:kind] == :X` ~60 times across the
# annotator and MIR pipeline.
#
# Migration is incremental — see TODO.md "Self-host preparation" task #2.
# Until all kinds (struct, union, resource) move out of Hash, callers
# may see EITHER a typed schema or a Hash, and must handle both.
require "sorbet-runtime"

module Schemas
    extend T::Sig

  # Plain classes (not Data.define) so Sorbet's 4010 doesn't fire on
  # the kwarg-only initialize signatures we need for default values.
  # Frozen at the end of initialize so callers still see immutable shapes.

  class EnumSchema
      extend T::Sig

    attr_reader :variants, :visibility
    sig { params(variants: Set, visibility: Symbol).void }
    def initialize(variants:, visibility: :package)
      @variants = variants
      @visibility = visibility
      freeze
    end
  end

  # Resource type schema — types with RAII cleanup (CLOSE method).
  #
  # Used for the 3 hand-written runtime types (File, TCPServer, TCPClient)
  # and EXTERN STRUCT ... CLOSE forms, which can carry generic type params,
  # an extern module name, and an AS alias.
  class ResourceSchema
    attr_reader :close_zig, :static_methods, :fields, :type_params, :extern_module, :as_type, :visibility
    def initialize(close_zig:, static_methods: {}, fields: {}, type_params: nil, extern_module: nil, as_type: nil, visibility: :package)
      @close_zig = close_zig
      @static_methods = static_methods
      @fields = fields
      @type_params = type_params
      @extern_module = extern_module
      @as_type = as_type
      @visibility = visibility
      freeze
    end
  end

  # Union (sum-type) schema. `variants` is a Hash[Symbol => Type|Hash]
  # where the value is `:nil` for payload-less variants, a Type for
  # typed variants, or a Hash with `:kind => :inline_struct` for inline
  # struct variants. The variant-level Hash (inline_struct shape) is
  # itself a hash-as-struct that hasn't been extracted yet — that's a
  # smaller, per-variant scope and can wait.
  class UnionSchema
      extend T::Sig

    attr_reader :variants, :type_params, :visibility
    sig { params(variants: Hash, type_params: T.nilable(T::Array[Symbol]), visibility: Symbol).void }
    def initialize(variants:, type_params: nil, visibility: :package)
      @variants = variants
      @type_params = type_params
      @visibility = visibility
      freeze
    end
  end

  # Struct/record schema. `fields` maps String field names to Type/Symbol/Hash
  # representations of field types — Hash form is `{type:, default:, borrowed:}`
  # produced by the parser, kept here unflattened for now. Metadata (defaults,
  # borrowed-set, generic type params, methods, EXTERN module, AS alias type,
  # visibility) live as named attrs rather than mixed Symbol keys in fields.
  class StructSchema
      extend T::Sig

    attr_reader :fields, :field_defaults, :borrowed_fields, :type_params, :methods, :visibility, :extern_module, :as_type
    sig { params(fields: Hash, field_defaults: T.nilable(T::Hash[String, T.untyped]), borrowed_fields: T.nilable(T::Set[String]), type_params: T.nilable(T::Array[Symbol]), methods: Hash, visibility: Symbol, extern_module: T.nilable(String), as_type: T.untyped).void }
    def initialize(fields: {}, field_defaults: nil, borrowed_fields: nil, type_params: nil, methods: {}, visibility: :package, extern_module: nil, as_type: nil)
      @fields = fields
      @field_defaults = field_defaults
      @borrowed_fields = borrowed_fields
      @type_params = type_params
      @methods = methods
      @visibility = visibility
      @extern_module = extern_module
      @as_type = as_type
      freeze
    end
  end

  # ── Coercion helpers ─────────────────────────────────────────────
  # The annotator stores schemas as raw Hashes in scope.declare_type;
  # the MIR side wraps in Schemas::* via lower_struct_def / lower_union_def.
  # Consumers (PromotionClassifier, CleanupClassifier, Type) see EITHER
  # form depending on which pipeline phase they're invoked from.
  #
  # These coercion helpers normalize to the typed form (returning nil
  # when the input isn't a struct / union schema), so a single call
  # site can use `.fields` / `.variants` regardless of source.

  sig { params(schema: T.untyped).returns(T.nilable(Schemas::StructSchema)) }
  def self.as_struct_schema(schema)
    return schema if schema.is_a?(StructSchema)
    return nil unless schema.is_a?(Hash) && !schema[:kind]
    StructSchema.new(
      fields: schema.reject { |k, _| k.is_a?(Symbol) },
      field_defaults: schema[:field_defaults],
      borrowed_fields: schema[:borrowed_fields],
      type_params: schema[:type_params],
      methods: schema[:methods] || {},
      visibility: schema[:visibility] || :package,
      extern_module: schema[:extern_module],
      as_type: schema[:as_type],
    )
  end

  sig { params(schema: T.nilable(Hash)).returns(T.nilable(Schemas::UnionSchema)) }
  def self.as_union_schema(schema)
    return schema if schema.is_a?(UnionSchema)
    return nil unless schema.is_a?(Hash) && schema[:kind] == :union
    UnionSchema.new(
      variants: schema[:variants] || {},
      type_params: schema[:type_params],
      visibility: schema[:visibility] || :package,
    )
  end

  sig { params(schema: T.nilable(Hash)).returns(T.untyped) }
  def self.as_resource_schema(schema)
    return schema if schema.is_a?(ResourceSchema)
    return nil unless schema.is_a?(Hash) && schema[:kind] == :resource
    ResourceSchema.new(
      close_zig: schema[:close_zig],
      static_methods: schema[:static_methods] || {},
      fields: schema[:fields] || {},
      type_params: schema[:type_params],
      extern_module: schema[:extern_module],
      as_type: schema[:as_type],
      visibility: schema[:visibility] || :package,
    )
  end
end
