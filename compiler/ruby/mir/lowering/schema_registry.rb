# typed: strict

require "sorbet-runtime"

require_relative "../../ast/type"

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
    struct_schema = @struct_schemas[key]
    return struct_schema if struct_schema

    union_schema = @union_schemas[key]
    return union_schema if union_schema

    @enum_schemas[key]
  end

  sig { params(lookup_proc: SchemaLookup).void }
  def replace_lookup_proc!(lookup_proc)
    @lookup_proc = lookup_proc
  end

  sig { params(name: SchemaName, variants: EnumVariants).void }
  def register_enum(name, variants)
    @enum_schemas[schema_key(name)] = variants
  end

  sig { params(name: SchemaName, schema: Schemas::StructSchema).void }
  def register_struct(name, schema)
    @struct_schemas[schema_key(name)] = schema
  end

  sig { params(name: SchemaName, schema: Schemas::UnionSchema).void }
  def register_union(name, schema)
    @union_schemas[schema_key(name)] = schema
  end

  sig do
    params(
      struct_schemas: T::Hash[Symbol, Schemas::StructSchema],
      enum_schemas: T::Hash[Symbol, EnumVariants],
      union_schemas: T::Hash[Symbol, Schemas::UnionSchema],
    ).void
  end
  def merge!(struct_schemas: {}, enum_schemas: {}, union_schemas: {})
    struct_schemas.each { |name, schema| @struct_schemas[name] = schema }
    enum_schemas.each { |name, variants| @enum_schemas[name] = variants }
    union_schemas.each { |name, schema| @union_schemas[name] = schema }
  end

  private

  sig { params(name: SchemaName).returns(Symbol) }
  def schema_key(name)
    return name if name.is_a?(Symbol)

    name.to_sym
  end
end
