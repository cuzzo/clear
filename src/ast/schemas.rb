# typed: strict
# Typed schemas for declared types stored in Scope.
#
# A declared type's schema is ALWAYS one of the typed classes below —
# never a raw Hash. Producers (the annotator's visit_*Def) construct
# these directly; consumers use the typed accessors (`.fields`,
# `.variants`, `.kind`, `.struct?`, ...). There is exactly one
# representation.
require "sorbet-runtime"
require "set"

module Schemas
    extend T::Sig

  # Plain classes (not Data.define) so Sorbet's 4010 doesn't fire on
  # the kwarg-only initialize signatures we need for default values.
  # Frozen at the end of initialize so callers see immutable shapes
  # (the methods table is mutable in place — see StructSchema#methods).

  class EnumSchema
      extend T::Sig

    attr_reader :variants, :visibility
    sig { params(variants: T.untyped, visibility: Symbol).void }
    def initialize(variants:, visibility: :package)
      @variants = variants
      @visibility = visibility
      freeze
    end

    sig { returns(T.nilable(Symbol)) }
    def kind = :enum
    sig { returns(T::Boolean) }
    def enum? = true
    sig { returns(T::Boolean) }
    def union? = false
    sig { returns(T::Boolean) }
    def struct? = false
    sig { returns(T::Boolean) }
    def resource? = false
  end

  # Resource type schema — types with RAII cleanup (CLOSE method).
  #
  # Used for the 3 hand-written runtime types (File, TCPServer, TCPClient)
  # and EXTERN STRUCT ... CLOSE forms, which can carry generic type params,
  # an extern module name, and an AS alias.
  class ResourceSchema
    extend T::Sig
    attr_reader :close_zig, :static_methods, :fields, :type_params, :extern_module, :as_type, :visibility, :methods
    sig { params(close_zig: T.untyped, static_methods: T.untyped, fields: T.untyped, type_params: T.untyped, extern_module: T.untyped, as_type: T.untyped, visibility: Symbol, methods: T.untyped).void }
    def initialize(close_zig:, static_methods: {}, fields: {}, type_params: nil, extern_module: nil, as_type: nil, visibility: :package, methods: {})
      @close_zig       = T.let(close_zig, String)
      @static_methods  = T.let(static_methods, T.untyped)
      @fields          = T.let(fields, T.untyped)
      @type_params     = T.let(type_params, T.untyped)
      @extern_module   = T.let(extern_module, T.nilable(String))
      @as_type         = T.let(as_type, T.nilable(String))
      @visibility      = T.let(visibility, Symbol)
      @methods         = T.let(methods, T.untyped)
      freeze
    end

    sig { returns(T.nilable(Symbol)) }
    def kind = :resource
    sig { returns(T::Boolean) }
    def resource? = true
    sig { returns(T::Boolean) }
    def union? = false
    sig { returns(T::Boolean) }
    def enum? = false
    sig { returns(T::Boolean) }
    def struct? = false
  end

  # One union variant whose payload is an anonymous inline struct
  # (`UNION Shape { Circle { radius: Float64 } }`). `fields` maps field
  # name (String) to its declared Type. `deinit_entries` is filled in by
  # the annotator after parse (which fields need @indirect / array
  # cleanup) and is intentionally mutable in place, like
  # StructSchema#methods.
  class InlineStructVariant
      extend T::Sig

    attr_reader :fields
    attr_accessor :deinit_entries
    sig { params(fields: T.untyped, deinit_entries: T.untyped).void }
    def initialize(fields:, deinit_entries: nil)
      @fields = fields
      @deinit_entries = deinit_entries
    end

    # Value equality on the field shape (not deinit_entries, which is
    # derived). The multi-arm shared-destructure check compares two
    # variants' payloads structurally — this used to be Hash `==`.
    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      other.is_a?(InlineStructVariant) && other.fields == @fields
    end
    alias eql? ==
    sig { returns(Integer) }
    def hash = @fields.hash
  end

  # Union (sum-type) schema. `variants` is a Hash[Symbol => value] where
  # the value is `nil` for payload-less variants, a Type for single-type
  # payloads, or an InlineStructVariant for inline struct variants.
  class UnionSchema
      extend T::Sig

    attr_reader :variants, :type_params, :visibility
    sig { params(variants: T.untyped, type_params: T.nilable(T::Array[Symbol]), visibility: Symbol).void }
    def initialize(variants:, type_params: nil, visibility: :package)
      @variants = variants
      @type_params = type_params
      @visibility = visibility
      freeze
    end

    sig { returns(T.nilable(Symbol)) }
    def kind = :union
    sig { returns(T::Boolean) }
    def union? = true
    sig { returns(T::Boolean) }
    def enum? = false
    sig { returns(T::Boolean) }
    def struct? = false
    sig { returns(T::Boolean) }
    def resource? = false
  end

  # Struct/record schema. `fields` maps String field names to Type/Symbol
  # representations of field types. Metadata (defaults, borrowed-set,
  # generic type params, methods, EXTERN module, AS alias type,
  # visibility) live as named attrs. `methods` is intentionally mutable
  # in place: method signatures are registered after the struct is
  # declared (when the method's FunctionDef is visited).
  class StructSchema
      extend T::Sig

    # `fields` is ALWAYS Hash[String => AST::StructField]. Per-field
    # default value and borrowed-ness live on the StructField, so
    # `field_defaults` / `borrowed_fields` are derived, not stored.
    attr_reader :fields, :type_params, :methods, :visibility, :extern_module, :as_type
    sig { params(fields: T.untyped, type_params: T.nilable(T::Array[Symbol]), methods: T.untyped, visibility: Symbol, extern_module: T.nilable(String), as_type: T.nilable(String)).void }
    def initialize(fields: {}, type_params: nil, methods: {}, visibility: :package, extern_module: nil, as_type: nil)
      @fields = fields
      @type_params = type_params
      @methods = methods
      @visibility = visibility
      @extern_module = extern_module
      @as_type = as_type
      freeze
    end

    sig { returns(T::Hash[String, T.untyped]) }
    def field_defaults
      @fields.each_with_object({}) { |(k, f), h| h[k] = f.default if f.default }
    end

    sig { returns(T::Set[String]) }
    def borrowed_fields
      @fields.each_with_object(Set.new) { |(k, f), s| s << k if f.borrowed }
    end

    sig { returns(T.nilable(Symbol)) }
    def kind = nil
    sig { returns(T::Boolean) }
    def struct? = true
    sig { returns(T::Boolean) }
    def union? = false
    sig { returns(T::Boolean) }
    def enum? = false
    sig { returns(T::Boolean) }
    def resource? = false
  end

  # Nil-safe kind predicates. Single representation: a schema is always
  # one of the typed classes above (or nil for an unknown type name).
  sig { params(s: T.untyped).returns(T::Boolean) }
  def self.struct?(s) = s.is_a?(StructSchema)

  sig { params(s: T.untyped).returns(T::Boolean) }
  def self.union?(s) = s.is_a?(UnionSchema)

  sig { params(s: T.untyped).returns(T::Boolean) }
  def self.enum?(s) = s.is_a?(EnumSchema)

  sig { params(s: T.untyped).returns(T::Boolean) }
  def self.resource?(s) = s.is_a?(ResourceSchema)

  sig { params(v: T.untyped).returns(T::Boolean) }
  def self.inline_struct?(v) = v.is_a?(InlineStructVariant)

  # Field-bearing schema: StructSchema or ResourceSchema (EXTERN STRUCT
  # ... CLOSE carries fields too), so `.fields` is safe to read.
  sig { params(s: T.untyped).returns(T::Boolean) }
  def self.field_bearing?(s) = s.is_a?(StructSchema) || s.is_a?(ResourceSchema)
end
