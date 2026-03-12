require_relative "./ast"

# ==========================================
# GENERIC ANALYSIS
# ==========================================
# Shared helpers for generic type validation, type-param substitution,
# and call-site inference. Included into SemanticAnnotator alongside
# FunctionAnalysis, OwnershipTracker, and PipeAnalysis.
#
# Requires host class to provide:
#   error!(node, msg, *args)       — raise CompilerError
#   lookup_type_schema(name)       — resolve a type name to its schema Hash
#   @current_fn_type_params        — Array<Symbol> of active fn type params
#
module GenericAnalysis
  BUILTIN_TYPES = %i[Number Bool Byte Int64 Float64 String Any Void Range].freeze

  # ----------------------------------------
  # Type param list validation
  # ----------------------------------------
  # Validate a list of type parameter names for struct/union/function definitions.
  # Raises on duplicates and on names that shadow built-in types.
  #
  # @param node   AST node (for location in error messages)
  # @param type_params Array<String> e.g. ["T", "K"]
  # @param kind   String — "struct", "union", or "function"
  def validate_type_param_list!(node, type_params, kind)
    seen = {}
    type_params.each do |param|
      param_sym = param.to_sym
      if seen[param_sym]
        error!(node, "Type Error: Duplicate type parameter '#{param}' in generic #{kind} '#{node.name}'.")
      end
      if BUILTIN_TYPES.include?(param_sym)
        error!(node, "Type Error: Type parameter '#{param}' shadows built-in type '#{param}'.")
      end
      seen[param_sym] = true
    end
  end

  # ----------------------------------------
  # Type annotation validation
  # ----------------------------------------
  # Validates a user-written type annotation wherever generics are involved.
  # Covers four cases:
  #   1. Generic type used correctly: Pair<Number>   — validate arg count + arg types
  #   2. Non-generic type with args:  User<Number>   — error: not generic
  #   3. Generic type without args:   Pair           — error: args required
  #   4. Non-generic type without args: User         — nothing to validate (normal path)
  #
  # Respects @current_fn_type_params so that Cache<T> in a generic function
  # does not raise "unknown type argument T".
  def validate_type_annotation!(node, type_obj)
    return unless type_obj.is_a?(Type)
    # FN types are structurally typed; their nested param/return types are validated
    # when they are parsed. No named-type schema lookup is needed here.
    return if type_obj.fn_type?

    # Unwrap error-union and optional wrappers to get the inner type
    inner = if type_obj.error_union?
      type_obj.payload_type
    elsif type_obj.optional?
      type_obj.wrapped_type
    else
      type_obj
    end
    return unless inner.is_a?(Type)

    if inner.generic_instance?
      base_name = inner.generic_base

      # Id<T> is a compiler intrinsic — no schema needed
      return if base_name == :Id

      schema = lookup_type_schema(base_name)

      if schema.nil?
        error!(node, "Type Error: Unknown type '#{base_name}'.")
      end

      unless schema.is_a?(Hash) && schema[:type_params]
        error!(node, :GENERIC_NOT_GENERIC, base_name)
      end

      expected = schema[:type_params].length
      actual   = inner.generic_args.length
      if actual != expected
        error!(node, :GENERIC_WRONG_ARG_COUNT, base_name, expected, actual)
      end

      fn_tps = @current_fn_type_params || []
      inner.generic_args.each do |arg|
        next if BUILTIN_TYPES.include?(arg.resolved)
        next if fn_tps.include?(arg.resolved)  # Cache<T> in a generic fn — T is valid
        arg_schema = lookup_type_schema(arg.resolved)
        if arg_schema.nil?
          error!(node, :GENERIC_UNKNOWN_TYPE_ARG, arg.resolved)
        end
        if arg_schema.is_a?(Hash) && arg_schema[:type_params]&.any?
          params_hint = arg_schema[:type_params].map(&:to_s).join(', ')
          error!(node, :GENERIC_MISSING_TYPE_ARGS, arg.resolved, arg.resolved, params_hint)
        end
      end

    else
      # Plain type name — check if it's a generic struct/union missing args
      base_name = inner.resolved
      return if (@current_fn_type_params || []).include?(base_name)  # T itself is valid
      schema = lookup_type_schema(base_name)
      if schema.is_a?(Hash) && schema[:type_params]&.any?
        params_hint = schema[:type_params].map(&:to_s).join(', ')
        error!(node, :GENERIC_MISSING_TYPE_ARGS, base_name, base_name, params_hint)
      end
    end
  end

  # ----------------------------------------
  # Call-site type-argument inference
  # ----------------------------------------
  # Infer a substitution map { :T => :Number, ... } from actual argument types.
  # Errors on conflicts (two args disagree on T) and missing bindings (T unused).
  #
  # @param node         AST::FuncCall (for error reporting)
  # @param signature    Hash — the function's type signature
  # @param actual_args  Array<AST node> — visited argument nodes
  # @param type_params  Array<Symbol>  — e.g. [:T, :K]
  # @return Hash — e.g. { T: :Number, K: :String }
  def infer_generic_type_args!(node, signature, actual_args, type_params)
    subst = {}
    signature[:params].each_with_index do |param, i|
      arg = actual_args[i]
      next unless arg
      param_type = param[:type].is_a?(Type) ? param[:type] : Type.new(param[:type] || :Any)
      actual_type = Type.new(arg.resolved_type || :Any)
      extract_type_bindings!(node, param_type, actual_type, type_params, subst)
    end
    type_params.each do |tp|
      unless subst.key?(tp)
        error!(node, :GENERIC_FN_CANNOT_INFER, tp, node.name, tp)
      end
    end
    subst
  end

  # Recursively match param_type against actual_type to bind type params.
  # Handles both direct uses (T) and nested generic uses (Cache<T>).
  def extract_type_bindings!(node, param_type, actual_type, type_params, subst)
    p_res = param_type.resolved
    a_res = actual_type.resolved
    if type_params.include?(p_res)
      existing = subst[p_res]
      if existing && existing != a_res
        error!(node, :GENERIC_FN_CONFLICT, p_res, node.name, existing, a_res)
      end
      subst[p_res] = a_res
    elsif param_type.generic_instance? && actual_type.generic_instance? &&
          param_type.generic_base == actual_type.generic_base
      param_type.generic_args.zip(actual_type.generic_args).each do |p_arg, a_arg|
        next unless p_arg && a_arg
        extract_type_bindings!(node, p_arg, a_arg, type_params, subst)
      end
    end
  end

  # ----------------------------------------
  # Type param substitution
  # ----------------------------------------
  # Apply a substitution map to a type object.
  # e.g. apply_type_subst(Type(:T), { T: :Number }) → Type(:Number)
  #      apply_type_subst(Type(:"Cache<T>"), { T: :Number }) → Type(:"Cache<Number>")
  def apply_type_subst(type_obj, subst)
    return Type.new(:Any) if type_obj.nil?
    t = type_obj.is_a?(Type) ? type_obj : Type.new(type_obj)
    resolved = t.resolved
    if subst.key?(resolved)
      Type.new(subst[resolved])
    elsif t.generic_instance?
      new_args = t.generic_args.map { |arg| apply_type_subst(arg, subst).resolved }
      Type.new(:"#{t.generic_base}<#{new_args.join(',')}>")
    else
      t
    end
  end

  # Build a concrete copy of a generic function signature with all type params
  # replaced by their inferred concrete types.
  def substitute_type_params(signature, subst)
    {
      params: signature[:params].map { |p| p.merge(type: apply_type_subst(p[:type], subst)) },
      return: { type:     apply_type_subst(signature[:return][:type], subst),
                lifetime: signature[:return][:lifetime] },
      visibility: signature[:visibility]
    }
  end
end
