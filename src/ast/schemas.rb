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

  class ResourceCloseCallKind < T::Enum
    enums do
      Method = new("method")
      Function = new("function")
    end
  end

  class ResourceCloseAction < T::Struct
    extend T::Sig

    const :call_kind, ResourceCloseCallKind
    const :name, String
    const :field_path, T::Array[String], default: []
    const :runtime_heap_alloc_args, Integer, default: 0

    sig { params(field: String).returns(ResourceCloseAction) }
    def for_field(field)
      ResourceCloseAction.new(
        call_kind: call_kind,
        name: name,
        field_path: [field] + field_path,
        runtime_heap_alloc_args: runtime_heap_alloc_args,
      )
    end
  end

  class ResourceClosePlan < T::Struct
    extend T::Sig

    const :actions, T::Array[ResourceCloseAction]

    sig { params(name: String, runtime_heap_alloc_args: Integer).returns(ResourceClosePlan) }
    def self.method(name, runtime_heap_alloc_args: 0)
      new(actions: [
        ResourceCloseAction.new(
          call_kind: ResourceCloseCallKind::Method,
          name: name,
          runtime_heap_alloc_args: runtime_heap_alloc_args,
        ),
      ])
    end

    sig { params(name: String, runtime_heap_alloc_args: Integer).returns(ResourceClosePlan) }
    def self.function(name, runtime_heap_alloc_args: 0)
      new(actions: [
        ResourceCloseAction.new(
          call_kind: ResourceCloseCallKind::Function,
          name: name,
          runtime_heap_alloc_args: runtime_heap_alloc_args,
        ),
      ])
    end

    sig { params(actions: T::Array[ResourceCloseAction]).returns(ResourceClosePlan) }
    def self.composite(actions)
      new(actions: actions)
    end

    sig { params(field: String).returns(ResourceClosePlan) }
    def for_field(field)
      ResourceClosePlan.new(actions: actions.map { |action| action.for_field(field) })
    end

    sig { returns(T::Boolean) }
    def empty?
      actions.empty?
    end
  end

  # Resource type schema — types with RAII cleanup (CLOSE method).
  #
  # Used for the 3 hand-written runtime types (File, TCPServer, TCPClient)
  # and EXTERN STRUCT ... CLOSE forms, which can carry generic type params,
  # an extern module name, and an AS alias.
  class ResourceSchema
    extend T::Sig

    FieldMetadataValue = T.type_alias { T.nilable(T.any(Type::TypeInput, AST::Locatable, T::Boolean)) }
    FieldMetadata = T.type_alias { T::Hash[T.any(Symbol, String), FieldMetadataValue] }
    FieldInput = T.type_alias { T.any(Type::TypeInput, AST::StructField, FieldMetadata) }
    FieldInputMap = T.type_alias { T::Hash[T.any(Symbol, String), FieldInput] }
    StaticMethodValue = T.type_alias { T.any(T::Array[Symbol], Symbol, String, T::Boolean) }
    StaticMethodSpec = T.type_alias { T::Hash[Symbol, StaticMethodValue] }
    StaticMethodsMap = T.type_alias { T::Hash[String, StaticMethodSpec] }
    MethodsMap = T.type_alias { T::Hash[T.any(Symbol, String), FunctionSignature] }

    attr_reader :close_plan, :static_methods, :fields, :type_params, :extern_module, :as_type, :visibility, :methods
    sig { params(close_plan: Schemas::ResourceClosePlan, static_methods: Schemas::ResourceSchema::StaticMethodsMap, fields: FieldInputMap, type_params: T.nilable(T::Array[Symbol]), extern_module: T.nilable(String), as_type: T.nilable(String), visibility: Symbol, methods: Schemas::ResourceSchema::MethodsMap).void }
    def initialize(close_plan:, static_methods: {}, fields: {}, type_params: nil, extern_module: nil, as_type: nil, visibility: :package, methods: {})
      @close_plan      = T.let(close_plan, Schemas::ResourceClosePlan)
      @static_methods  = T.let(static_methods, Schemas::ResourceSchema::StaticMethodsMap)
      @fields          = T.let(normalize_fields(fields), T::Hash[String, AST::StructField])
      @type_params     = T.let(type_params, T.nilable(T::Array[Symbol]))
      @extern_module   = T.let(extern_module, T.nilable(String))
      @as_type         = T.let(as_type, T.nilable(String))
      @visibility      = T.let(visibility, Symbol)
      @methods         = T.let(methods, Schemas::ResourceSchema::MethodsMap)
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

    sig { params(fields: FieldInputMap).returns(T::Hash[String, AST::StructField]) }
    def normalize_fields(fields)
      fields.each_with_object({}) do |(name, field), out|
        out[name.to_s] = normalize_field(field)
      end
    end
    private :normalize_fields

    sig { params(field: FieldInput).returns(AST::StructField) }
    def normalize_field(field)
      return field if field.is_a?(AST::StructField)
      if field.is_a?(Hash)
        return AST::StructField.new(
          type: field[:type] || field["type"],
          default: field[:default] || field["default"],
          borrowed: field[:borrowed] || field["borrowed"]
        )
      end

      AST::StructField.new(type: field)
    end
    private :normalize_field
  end

  class InlineStructDeinitEntry < T::Struct
      extend T::Sig

    const :field, String
    const :kind, Symbol
    const :zig_type, T.nilable(String)
    const :elem_zig_type, T.nilable(String)

    sig { params(field: String, zig_type: String).returns(Schemas::InlineStructDeinitEntry) }
    def self.indirect(field:, zig_type:)
      new(field: field, kind: :indirect, zig_type: zig_type, elem_zig_type: nil)
    end

    sig { params(field: String, zig_type: String).returns(Schemas::InlineStructDeinitEntry) }
    def self.uniform(field:, zig_type:)
      new(field: field, kind: :uniform, zig_type: zig_type, elem_zig_type: nil)
    end

    sig { params(field: String, elem_zig_type: String).returns(Schemas::InlineStructDeinitEntry) }
    def self.array(field:, elem_zig_type:)
      new(field: field, kind: :array, zig_type: nil, elem_zig_type: elem_zig_type)
    end
  end

  # One union variant whose payload is an anonymous inline struct
  # (`UNION Shape { Circle { radius: Float64 } }`). `fields` maps field
  # name (String) to its declared Type. `deinit_entries` is filled in by
  # the annotator after parse (which fields need @indirect / array
  # cleanup) and is intentionally mutable in place, like
  # StructSchema#methods.
  class InlineStructVariant
      extend T::Sig

    FieldMap = T.type_alias { T::Hash[T.any(String, Symbol), Type] }
    FieldInputMap = T.type_alias { T::Hash[T.any(String, Symbol), Type::TypeInput] }

    attr_reader :fields
    attr_accessor :deinit_entries
    sig { params(fields: FieldInputMap, deinit_entries: T.nilable(T::Array[Schemas::InlineStructDeinitEntry])).void }
    def initialize(fields:, deinit_entries: nil)
      @fields = T.let(fields.transform_values { |field_type|
        Type.new(field_type)
      }, Schemas::InlineStructVariant::FieldMap)
      @deinit_entries = T.let(deinit_entries, T.nilable(T::Array[Schemas::InlineStructDeinitEntry]))
    end

    sig { returns(T::Hash[String, Type]) }
    def typed_fields
      @fields.transform_keys(&:to_s)
    end

    # Value equality on the field shape (not deinit_entries, which is
    # derived). The multi-arm shared-destructure check compares two
    # variants' payloads structurally — this used to be Hash `==`.
    sig { params(other: T.untyped).returns(T::Boolean) }
    def ==(other)
      !!(other.is_a?(Schemas::InlineStructVariant) && other.fields == @fields)
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

    VariantValue = T.type_alias { T.nilable(T.any(Type, Schemas::InlineStructVariant)) }
    VariantMap = T.type_alias { T::Hash[T.any(String, Symbol), VariantValue] }
    VariantInput = T.type_alias { T.nilable(T.any(Type::TypeInput, Schemas::InlineStructVariant)) }
    VariantInputMap = T.type_alias { T::Hash[T.any(String, Symbol), VariantInput] }

    attr_reader :variants, :type_params, :visibility
    sig { params(variants: VariantInputMap, type_params: T.nilable(T::Array[Symbol]), visibility: Symbol).void }
    def initialize(variants:, type_params: nil, visibility: :package)
      @variants = T.let(
        variants.transform_values do |variant|
          if variant.nil? || variant.is_a?(Schemas::InlineStructVariant)
            variant
          else
            Type.new(variant)
          end
        end,
        Schemas::UnionSchema::VariantMap
      )
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
    FieldMetadataValue = T.type_alias { T.nilable(T.any(Type::TypeInput, AST::Locatable, T::Boolean)) }
    FieldMetadata = T.type_alias { T::Hash[T.any(Symbol, String), FieldMetadataValue] }
    FieldInput = T.type_alias { T.any(Type::TypeInput, AST::StructField, FieldMetadata) }
    FieldInputMap = T.type_alias { T::Hash[T.any(Symbol, String), FieldInput] }
    MethodsMap = T.type_alias { T::Hash[T.any(Symbol, String), FunctionSignature] }

    attr_reader :fields, :type_params, :methods, :visibility, :extern_module, :as_type
    sig { params(fields: FieldInputMap, type_params: T.nilable(T::Array[Symbol]), methods: MethodsMap, visibility: Symbol, extern_module: T.nilable(String), as_type: T.nilable(String)).void }
    def initialize(fields: {}, type_params: nil, methods: {}, visibility: :package, extern_module: nil, as_type: nil)
      @fields = T.let(normalize_fields(fields), T::Hash[String, AST::StructField])
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

    sig { params(fields: FieldInputMap).returns(T::Hash[String, AST::StructField]) }
    def normalize_fields(fields)
      fields.each_with_object({}) do |(name, field), out|
        out[name.to_s] = normalize_field(field)
      end
    end
    private :normalize_fields

    sig { params(field: FieldInput).returns(AST::StructField) }
    def normalize_field(field)
      return field if field.is_a?(AST::StructField)
      if field.is_a?(Hash)
        return AST::StructField.new(
          type: field[:type] || field["type"],
          default: field[:default] || field["default"],
          borrowed: field[:borrowed] || field["borrowed"]
        )
      end

      AST::StructField.new(type: field)
    end
    private :normalize_field
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
