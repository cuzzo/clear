# typed: strict
require "sorbet-runtime"

# Compatibility shared by expression, assignment, tuple, and return typing.
# Keeping this calculation independent from any annotation domain prevents one
# domain from relying on another domain's private methods.
module UnionPayloadCompatibility
  extend T::Sig

  sig do
    params(
      expected_type: Type,
      actual_type: Type,
      schema: Schemas::SchemaValue
    ).returns(T.nilable(T.any(String, Symbol)))
  end
  def self.unique_variant(expected_type, actual_type, schema)
    return nil unless schema.is_a?(Schemas::UnionSchema)

    compared_actual = if expected_type.optional? && actual_type.optional?
      T.must(actual_type.wrapped_type)
    else
      actual_type
    end

    matches = schema.variants.filter_map do |variant_name, payload|
      next unless payload.is_a?(Type)
      payload_matches?(payload, compared_actual) ? variant_name : nil
    end
    matches.one? ? matches.first : nil
  end

  sig { params(payload_type: Type, actual_type: Type).returns(T::Boolean) }
  def self.payload_matches?(payload_type, actual_type)
    payload_surface = Type.coercion_surface_name(payload_type)
    actual_surface = Type.coercion_surface_name(actual_type)
    return true if payload_surface == actual_surface
    return false if payload_type.string? || actual_type.string?

    payload_type.accepts?(actual_type)
  end
  private_class_method :payload_matches?
end

# union.rb — Union type validation helpers for CLEAR.
#
# Provides validation for union method requirements (UNION ... REQUIRES)
# and union variant literal type-checking. Mixed into SemanticAnnotator.
module UnionAnalysis
    extend T::Sig

  # Resolve enum or union variant access on a GetField node (TypeName.Variant).
  # Returns true if handled, false if the target is not an enum/union.
  sig { params(node: AST::GetField).returns(T.nilable(T::Boolean)) }
  def resolve_variant_access(node)
    T.bind(self, Annotator::Phases::TypeAnalysisSession) rescue nil
    return false unless node.target.is_a?(AST::Identifier)

    type_name = node.target.name.to_sym
    schema = lookup_type_schema(type_name)
    return false unless Schemas.union?(schema) || Schemas.enum?(schema)

    if schema.kind == :enum
      unless schema.variants.include?(node.field)
        emit_variant_typo!(
          T.must(variant_anchor_from_getfield(node)), node.field, schema.variants,
          "Type Error: Enum '#{type_name}' has no variant '#{node.field}'.",
          "variant of enum #{type_name}",
          cascade: true
        )
      end
      stamp_type!(node.target, type_name)
      stamp_type!(node, type_name)
      return true
    end

    if schema.kind == :union
      unless schema.variants.key?(node.field)
        emit_variant_typo!(
          T.must(variant_anchor_from_getfield(node)), node.field, schema.variants.keys,
          "Type Error: Union '#{type_name}' has no variant '#{node.field}'.",
          "variant of union #{type_name}",
          cascade: true
        )
      end
      var_data = schema.variants[node.field]
      if Schemas.inline_struct?(var_data) && !inside_match_pattern_context?
        error!(node, :UNION_INLINE_VARIANT_NEEDS_BRACES, union: type_name, variant: node.field, union2: type_name, variant2: node.field)
      end
      stamp_type!(node.target, type_name)
      stamp_type!(node, type_name)
      return true
    end
  end

  sig { params(node: AST::UnionVariantLit).returns(T.nilable(Symbol)) }
  def visit_UnionVariantLit(node)
    T.bind(self, Annotator::Phases::TypeAnalysisSession) rescue nil
    schema = lookup_type_schema(node.union_name.to_sym)
    var_data = validate_union_schema!(node, schema)
    validate_union_fields!(node, T.must(var_data).typed_fields)
    stamp_type!(node, node.union_name.to_sym)
  end

  # Validate that a union type and variant exist, and that the variant
  # supports inline struct construction (not a unit or single-payload variant).
  # Returns the variant data hash on success.
  sig { params(node: AST::UnionVariantLit, schema: Schemas::SchemaValue).returns(T.nilable(Schemas::InlineStructVariant)) }
  def validate_union_schema!(node, schema)
    T.bind(self, Annotator::Phases::TypeAnalysisSession) rescue {}
    if schema.nil?
      error!(node, :UNION_TYPE_UNKNOWN, name: node.union_name)
    end
    unless schema.is_a?(Schemas::UnionSchema)
      error!(node, :NOT_A_UNION_TYPE, name: node.union_name)
      return nil
    end
    unless schema.variants.key?(node.variant_name)
      emit_variant_typo!(
        T.must(variant_anchor_from_unionlit(node, node.variant_name)),
        node.variant_name, schema.variants.keys,
        "Type Error: Union '#{node.union_name}' has no variant '#{node.variant_name}'.",
        "variant of union #{node.union_name}",
        cascade: true
      )
    end

    var_data = schema.variants[node.variant_name]
    unless var_data.is_a?(Schemas::InlineStructVariant)
      if var_data.nil?
        error!(node, :UNION_VARIANT_IS_UNIT_NO_FIELDS, variant: node.variant_name, union: node.union_name)
      else
        error!(node, :UNION_VARIANT_NEEDS_PAYLOAD_OBJECT, variant: node.variant_name, union: node.union_name)
      end
      return nil
    end

    var_data
  end

  # Validate fields of an inline struct union variant: check for unknown fields,
  # missing required fields, and type-check each field value.
  sig { params(node: AST::UnionVariantLit, expected_fields: T::Hash[String, Type]).void }
  def validate_union_fields!(node, expected_fields)
    T.bind(self, Annotator::Phases::TypeAnalysisSession) rescue nil
    node.fields.each_key do |fname|
      unless expected_fields.key?(fname)
        error!(node, :UNION_INLINE_VARIANT_UNKNOWN_FIELD, union: node.union_name, variant: node.variant_name, field: fname)
      end
    end

    expected_fields.each_key do |fname|
      unless node.fields.key?(fname)
        error!(node, :UNION_INLINE_VARIANT_MISSING_FIELD, union: node.union_name, variant: node.variant_name, field: fname)
      end
    end

    node.fields.each do |fname, val_node|
      visit(val_node)
      reject_borrowed_value!(val_node, "#{node.union_name}.#{node.variant_name}.#{fname}")
      # Ensure value is owned data (implicit COPY for @list/rodata strings).
      owned = ensure_owned_value!(val_node, expected_fields[fname], "#{node.union_name}.#{node.variant_name}.#{fname}")
      if owned
        node.fields[fname] = owned
        val_node = owned
      end
      ef = expected_fields[fname]
      if ef.is_a?(Type) && ef.indirect?
        val_node.needs_heap_create = true
        current_fn_ctx&.record_heap_use!
        record_effect(EffectTracker::HEAP)
      end

      expected_type = expected_fields[fname]
      actual = val_node.full_type!(context: "union variant field")
      unless T.must(expected_type).accepts?(actual)
        error!(node, :UNION_INLINE_VARIANT_TYPE_MISMATCH, union: node.union_name, variant: node.variant_name, field: fname, expected: T.must(expected_type).resolved, got: actual&.resolved)
      end
      move_if_not_copyable!(val_node)
    end
  end
  private :validate_union_fields!
  private :validate_union_schema!

end
