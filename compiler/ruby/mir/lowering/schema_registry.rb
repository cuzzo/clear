# typed: strict

require "sorbet-runtime"

require_relative "../../ast/schemas"

class MIRLoweringSchemas
  extend T::Sig

  EnumVariants = T.type_alias { T::Array[T.any(String, Symbol)] }
  SchemaName = T.type_alias { T.any(String, Symbol) }
  SchemaLookupResult = T.type_alias do
    T.nilable(
      T.any(
        Schemas::EnumSchema,
        Schemas::ResourceSchema,
        Schemas::StructSchema,
        Schemas::UnionSchema,
        EnumVariants,
      )
    )
  end
  SchemaLookup = T.type_alias { T.proc.params(name: SchemaName).returns(SchemaLookupResult) }

  sig { returns(T::Hash[Symbol, Schemas::StructSchema]) }
  attr_reader :struct_schemas

  sig { returns(T::Hash[Symbol, EnumVariants]) }
  attr_reader :enum_schemas

  sig { returns(T::Hash[Symbol, Schemas::UnionSchema]) }
  attr_reader :union_schemas

  sig do
    params(
      struct_schemas: T::Hash[Symbol, Schemas::StructSchema],
      enum_schemas: T::Hash[Symbol, EnumVariants],
      union_schemas: T::Hash[Symbol, Schemas::UnionSchema],
    ).void
  end
  def initialize(struct_schemas:, enum_schemas:, union_schemas:)
    @struct_schemas = T.let(struct_schemas.dup, T::Hash[Symbol, Schemas::StructSchema])
    @enum_schemas = T.let(enum_schemas.dup, T::Hash[Symbol, EnumVariants])
    @union_schemas = T.let(union_schemas.dup, T::Hash[Symbol, Schemas::UnionSchema])
    @lookup_proc = T.let(->(name) { lookup(name) }, SchemaLookup)
  end

  sig { returns(SchemaLookup) }
  def lookup_proc
    @lookup_proc
  end

  sig { params(name: SchemaName).returns(SchemaLookupResult) }
  def lookup(name)
    key = schema_key(name)
    @struct_schemas[key] || @union_schemas[key] || @enum_schemas[key]
  end

  sig { params(lookup_proc: SchemaLookup).void }
  def replace_lookup_proc!(lookup_proc)
    @lookup_proc = lookup_proc
  end

  sig { params(name: SchemaName, variants: EnumVariants).void }
  def register_enum(name, variants)
    @enum_schemas[name.to_sym] = variants
  end

  sig { params(name: SchemaName, schema: Schemas::StructSchema).void }
  def register_struct(name, schema)
    @struct_schemas[name.to_sym] = schema
  end

  sig { params(name: SchemaName, schema: Schemas::UnionSchema).void }
  def register_union(name, schema)
    @union_schemas[name.to_sym] = schema
  end

  sig do
    params(
      struct_schemas: T::Hash[Symbol, Schemas::StructSchema],
      enum_schemas: T::Hash[Symbol, EnumVariants],
      union_schemas: T::Hash[Symbol, Schemas::UnionSchema],
    ).void
  end
  def merge!(struct_schemas: {}, enum_schemas: {}, union_schemas: {})
    @struct_schemas.merge!(struct_schemas)
    @enum_schemas.merge!(enum_schemas)
    @union_schemas.merge!(union_schemas)
  end

  private

  sig { params(name: SchemaName).returns(Symbol) }
  def schema_key(name)
    name.is_a?(Symbol) ? name : name.to_sym
  end
end
