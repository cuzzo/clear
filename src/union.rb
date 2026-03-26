# union.rb — Union type validation helpers for CLEAR.
#
# Provides validation for union method requirements (UNION ... REQUIRES)
# and union variant literal type-checking. Mixed into SemanticAnnotator.
module UnionAnalysis
  # Validate that all required methods for a union type exist and have
  # compatible signatures. Synthesizes default functions for stubs with
  # default bodies that have no concrete override.
  def validate_union_methods!(node)
    union_name = node.name

    # Detect duplicate method stub declarations.
    seen_names = {}
    node.methods.each do |req|
      if seen_names.key?(req[:name])
        error!(req[:token], :UNION_METHOD_DUPLICATE, union_name, req[:name])
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
          @synthetic_fns << fn_node
          next
        else
          error!(req_tok, :UNION_METHOD_MISSING, union_name, fn_name, fn_name)
        end
      end

      sig = local[:type]
      unless sig.is_a?(Hash) && sig.key?(:params)
        error!(req_tok, :UNION_METHOD_MISSING, union_name, fn_name, fn_name)
      end

      # Visibility check
      if req_vis != :package
        actual_vis = sig[:visibility] || :package
        unless actual_vis == req_vis
          vis_label = { pub: "PUB", private: "PRIVATE", package: "package" }
          error!(req_tok, :UNION_METHOD_WRONG_VISIBILITY,
                 union_name, fn_name, vis_label[req_vis], fn_name, vis_label[actual_vis])
        end
      end

      # Arity check
      if req[:params].length != sig[:params].length
        error!(req_tok, :UNION_METHOD_WRONG_ARITY,
               union_name, fn_name, req[:params].length, fn_name, sig[:params].length)
      end

      # Parameter type checks
      req[:params].each_with_index do |rp, i|
        req_t  = to_type(rp[:type]).resolved.to_s
        sig_t  = to_type(sig[:params][i][:type]).resolved.to_s
        unless req_t == sig_t || req_t == 'Any' || sig_t == 'Any'
          error!(req_tok, :UNION_METHOD_PARAM_TYPE,
                 union_name, fn_name, i + 1, req_t, fn_name, sig_t)
        end
      end

      # Return type check
      if req[:return_type]
        req_ret = to_type(req[:return_type]).resolved.to_s
        sig_ret = to_type(sig[:return][:type]).resolved.to_s
        unless req_ret == sig_ret || req_ret == 'Any' || sig_ret == 'Any'
          error!(req_tok, :UNION_METHOD_RETURN_TYPE,
                 union_name, fn_name, req_ret, fn_name, sig_ret)
        end
      end
    end
  end

  # Resolve enum or union variant access on a GetField node (TypeName.Variant).
  # Returns true if handled, false if the target is not an enum/union.
  def resolve_variant_access(node)
    return false unless node.target.is_a?(AST::Identifier)

    type_name = node.target.name.to_sym
    schema = lookup_type_schema(type_name)
    return false unless schema.is_a?(Hash)

    if schema[:kind] == :enum
      unless schema[:variants].include?(node.field)
        error!(node, :ENUM_UNKNOWN_VARIANT, type_name, node.field)
      end
      node.target.full_type = type_name
      node.full_type = type_name
      return true
    end

    if schema[:kind] == :union
      unless schema[:variants].key?(node.field)
        error!(node, :UNION_UNKNOWN_VARIANT, type_name, node.field)
      end
      var_data = schema[:variants][node.field]
      if var_data.is_a?(Hash) && var_data[:kind] == :inline_struct && !@match_pattern_context
        error!(node, :UNION_INLINE_VARIANT_NEEDS_BRACES, type_name, node.field, type_name, node.field)
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
  def validate_union_schema!(node, schema)
    if schema.nil?
      error!(node, "Unknown union type: '#{node.union_name}'")
    end
    unless schema.is_a?(Hash) && schema[:kind] == :union
      error!(node, "Type Error: '#{node.union_name}' is not a union type.")
    end
    unless schema[:variants].key?(node.variant_name)
      error!(node, :UNION_UNKNOWN_VARIANT, node.union_name, node.variant_name)
    end

    var_data = schema[:variants][node.variant_name]
    unless var_data.is_a?(Hash) && var_data[:kind] == :inline_struct
      if var_data.nil?
        error!(node, "Union variant '#{node.variant_name}' is a unit variant — use '#{node.union_name}.#{node.variant_name}' (no fields).")
      else
        error!(node, "Union variant '#{node.variant_name}' takes a single typed payload — use '#{node.union_name}{ #{node.variant_name}: value }' instead.")
      end
    end

    var_data
  end

  # Validate fields of an inline struct union variant: check for unknown fields,
  # missing required fields, and type-check each field value.
  def validate_union_fields!(node, expected_fields)
    node.fields.each_key do |fname|
      unless expected_fields.key?(fname)
        error!(node, :UNION_INLINE_VARIANT_UNKNOWN_FIELD, node.union_name, node.variant_name, fname)
      end
    end

    expected_fields.each_key do |fname|
      unless node.fields.key?(fname)
        error!(node, :UNION_INLINE_VARIANT_MISSING_FIELD, node.union_name, node.variant_name, fname)
      end
    end

    node.fields.each do |fname, val_node|
      visit(val_node)
      expected_type = expected_fields[fname]
      actual = val_node.type_info
      unless expected_type.accepts?(actual)
        error!(node, :UNION_INLINE_VARIANT_TYPE_MISMATCH,
               node.union_name, node.variant_name, fname,
               expected_type.resolved, actual&.resolved)
      end
    end
  end
end
