# typed: strict
require "sorbet-runtime"
# union.rb — Union type validation helpers for CLEAR.
#
# Provides validation for union method requirements (UNION ... REQUIRES)
# and union variant literal type-checking. Mixed into SemanticAnnotator.
module UnionAnalysis
    extend T::Sig

  # Validate that all required methods for a union type exist and have
  # compatible signatures. Synthesizes default functions for stubs with
  # default bodies that have no concrete override.
  sig { params(node: AST::UnionDef).returns(T.nilable(T::Array[T.untyped])) }
  def validate_union_methods!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    union_name = node.name

    # Detect duplicate method stub declarations.
    seen_names = {}
    node.methods.each do |req|
      if seen_names.key?(req[:name])
        error!(req[:token], :UNION_METHOD_DUPLICATE, union: union_name, method: req[:name])
      end
      seen_names[req[:name]] = true
    end

    node.methods.each do |req|
      fn_name = req[:name]
      req_tok = req[:token]
      req_vis = req[:visibility] || :package

      scope = lookup_scope_for(fn_name)
      local = scope&.locals&.[](fn_name)

      if local.nil?
        if req[:body]
          # No concrete override — synthesize a top-level function from the default body.
          fn_params = req[:params].map { |rp|
            { name: rp[:name], type: rp[:type], default: nil, mutable: false, takes: false }
          }
          fn_node = AST::FunctionDef.new(
            req[:token], req[:name], fn_params, [], req[:return_type],
            nil, req[:body], nil, nil, req_vis, nil, nil
          )
          @synthetic_fns = T.let(@synthetic_fns, T.untyped)
          @synthetic_fns << fn_node
          next
        else
          error!(req_tok, :UNION_METHOD_MISSING, union: union_name, method: fn_name, fn: fn_name)
        end
      end

      sig = local.type
      unless sig.is_a?(FunctionSignature)
        error!(req_tok, :UNION_METHOD_MISSING, union: union_name, method: fn_name, fn: fn_name)
      end

      # Visibility check
      if req_vis != :package
        actual_vis = sig.visibility || :package
        unless actual_vis == req_vis
          vis_label = { pub: "PUB", private: "PRIVATE", package: "package" }
          error!(req_tok, :UNION_METHOD_WRONG_VISIBILITY, union: union_name, method: fn_name, declared_vis: vis_label[req_vis], fn: fn_name, fn_vis: vis_label[actual_vis])
        end
      end

      # Arity check
      if req[:params].length != sig.params.length
        error!(req_tok, :UNION_METHOD_WRONG_ARITY, union: union_name, method: fn_name, expected_arity: req[:params].length, fn: fn_name, got_arity: sig.params.length)
      end

      # Parameter type checks
      req[:params].each_with_index do |rp, i|
        req_t  = to_type(rp[:type]).resolved
        sig_t  = to_type(sig.params[i][:type]).resolved
        unless req_t == sig_t || req_t == :Any || sig_t == :Any
          error!(req_tok, :UNION_METHOD_PARAM_TYPE, union: union_name, method: fn_name, index: i + 1, expected: req_t, fn: fn_name, got: sig_t)
        end
      end

      # Return type check
      if req[:return_type]
        req_ret = to_type(req[:return_type]).resolved
        sig_ret = sig.return_type.resolved
        unless req_ret == sig_ret || req_ret == :Any || sig_ret == :Any
          error!(req_tok, :UNION_METHOD_RETURN_TYPE, union: union_name, method: fn_name, expected: req_ret, fn: fn_name, got: sig_ret)
        end
      end
    end
  end

  # Resolve enum or union variant access on a GetField node (TypeName.Variant).
  # Returns true if handled, false if the target is not an enum/union.
  sig { params(node: AST::GetField).returns(T.nilable(T::Boolean)) }
  def resolve_variant_access(node)
    T.bind(self, SemanticAnnotator) rescue nil
    return false unless node.target.is_a?(AST::Identifier)

    type_name = node.target.name.to_sym
    schema = lookup_type_schema(type_name)
    return false unless schema.is_a?(Hash)

    if schema[:kind] == :enum
      unless schema[:variants].include?(node.field)
        emit_variant_typo!(
          T.must(variant_anchor_from_getfield(node)), node.field, schema[:variants],
          "Type Error: Enum '#{type_name}' has no variant '#{node.field}'.",
          "variant of enum #{type_name}",
          cascade: true
        )
      end
      node.target.full_type = type_name
      node.full_type = type_name
      return true
    end

    if schema[:kind] == :union
      unless schema[:variants].key?(node.field)
        emit_variant_typo!(
          T.must(variant_anchor_from_getfield(node)), node.field, schema[:variants].keys,
          "Type Error: Union '#{type_name}' has no variant '#{node.field}'.",
          "variant of union #{type_name}",
          cascade: true
        )
      end
      var_data = schema[:variants][node.field]
      @match_pattern_context = T.let(@match_pattern_context, T.untyped)
      if var_data.is_a?(Hash) && var_data[:kind] == :inline_struct && !@match_pattern_context
        error!(node, :UNION_INLINE_VARIANT_NEEDS_BRACES, union: type_name, variant: node.field, union2: type_name, variant2: node.field)
      end
      node.target.full_type = type_name
      node.full_type = type_name
      return true
    end

    false
  end

  # Validate that a union type and variant exist, and that the variant
  # supports inline struct construction (not a unit or single-payload variant).
  # Returns the variant data hash on success.
  sig { params(node: AST::UnionVariantLit, schema: T.nilable(T::Hash[T.untyped, T.untyped])).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def validate_union_schema!(node, schema)
    T.bind(self, SemanticAnnotator) rescue {}
    if schema.nil?
      error!(node, :UNION_TYPE_UNKNOWN, name: node.union_name)
    end
    unless schema.is_a?(Hash) && schema[:kind] == :union
      error!(node, :NOT_A_UNION_TYPE, name: node.union_name)
    end
    unless T.must(schema)[:variants].key?(node.variant_name)
      emit_variant_typo!(
        T.must(variant_anchor_from_unionlit(node, node.variant_name)),
        node.variant_name, T.must(schema)[:variants].keys,
        "Type Error: Union '#{node.union_name}' has no variant '#{node.variant_name}'.",
        "variant of union #{node.union_name}",
        cascade: true
      )
    end

    var_data = T.must(schema)[:variants][node.variant_name]
    unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
      if var_data.nil?
        error!(node, :UNION_VARIANT_IS_UNIT_NO_FIELDS, variant: node.variant_name, union: node.union_name)
      else
        error!(node, :UNION_VARIANT_NEEDS_PAYLOAD_OBJECT, variant: node.variant_name, union: node.union_name)
      end
    end

    var_data
  end

  # Validate fields of an inline struct union variant: check for unknown fields,
  # missing required fields, and type-check each field value.
  sig { params(node: AST::UnionVariantLit, expected_fields: T::Hash[String, Type]).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def validate_union_fields!(node, expected_fields)
    T.bind(self, SemanticAnnotator) rescue nil
    schema = lookup_type_schema(node.union_name.to_sym)
    variant_data = schema&.dig(:variants)&.[](node.variant_name)
    indirect_fields = if variant_data.is_a?(Hash)
      variant_data[:indirect_fields] || Set.new
    else
      Set.new
    end

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
      if indirect_fields.include?(fname)
        val_node.needs_heap_create = true
        current_fn_ctx.heap_count += 1 if current_fn_ctx
        record_effect(EffectTracker::HEAP)
      end
      reject_borrowed_value!(val_node, "#{node.union_name}.#{node.variant_name}.#{fname}")
      # Ensure value is owned data (implicit COPY for @list/rodata strings).
      owned = ensure_owned_value!(val_node, expected_fields[fname], "#{node.union_name}.#{node.variant_name}.#{fname}")
      if owned
        node.fields[fname] = owned
        val_node = owned
      end

      expected_type = expected_fields[fname]
      actual = val_node.type_info
      unless T.must(expected_type).accepts?(actual)
        error!(node, :UNION_INLINE_VARIANT_TYPE_MISMATCH, union: node.union_name, variant: node.variant_name, field: fname, expected: T.must(expected_type).resolved, got: actual&.resolved)
      end
      move_if_not_copyable!(val_node)
    end
  end
end
