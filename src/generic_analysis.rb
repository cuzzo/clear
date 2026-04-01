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
#   current_fn_ctx&.type_params        — Array<Symbol> of active fn type params
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
  # Validates a type annotation where generics are involved.
  # Called whenever a user-written type annotation is resolved (variable decls, params, returns).
  # Covers four cases:
  #   1. Generic type used correctly: Pair<Number> — validate arg count + arg types
  #   2. Generic type missing args: Pair — error
  #   3. Non-generic type with args: Int64<Number> — error
  #   4. Type param used as arg: Cache<T> — skip validation (resolved at monomorphization)
  #
  # Respects current_fn_ctx&.type_params so that Cache<T> in a generic function
  # does not raise "unknown type argument T".
  def validate_type_annotation!(node, type_obj)
    return unless type_obj.is_a?(Type)
    # FN types are structurally typed; their nested param/return types are validated
    # when they are parsed. No named-type schema lookup is needed here.
    return if type_obj.fn_type?

    # Pools require a fixed capacity: Entity[1000]@pool, not Entity[]@pool.
    if type_obj.pool? && !type_obj.fixed?
      error!(node, "Pool requires a fixed capacity — use #{type_obj.element_type&.resolved}[N]@pool instead of []@pool")
    end

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

      fn_tps = current_fn_ctx&.type_params || []
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
      return if (current_fn_ctx&.type_params || []).include?(base_name)  # T itself is valid
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
      # Handle prefixed types: !T, ?T, ~T — substitute the inner type.
      str = resolved.to_s
      prefix = str.match(/\A([!?~]+)/)&.[](1)
      if prefix
        inner = str[prefix.length..].to_sym
        if subst.key?(inner)
          Type.new(:"#{prefix}#{subst[inner]}")
        else
          t
        end
      else
        t
      end
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

  # ==========================================
  # Declaration helpers (shared by VarDecl + BindExpr)
  # ==========================================

  # Validate stream type annotations on variable declarations.
  def validate_stream_type!(node)
    return unless node.type.is_a?(Type) && node.type.tense?
    if node.type.multiowned?
      error!(node, "~T@multiOwned is not valid. Promises span fiber boundaries, so the ref-count must be atomic. Use ~T@shared instead.")
    end
    if node.type.tense_type.array? && node.type.tense_type.dynamic? && !node.type.list_collection?
      error!(node, "~T[] is not a valid stream type. Use ~T[N] for a bounded stream of N concurrent tasks, ~T[INF] for an infinite rendezvous stream, ~T[?] for an open/closeable stream, or ~T[]@list for a dynamic promise list.")
    end
  end

  # After coerce! validates type compatibility, propagate declared-type metadata
  # into the value node so the transpiler sees the correct runtime type.
  # Handles: BgStreamBlock ~T[INF] retyping, shard_count, @shared promise ownership.
  def propagate_declared_type_to_value!(node, final_type)
    return unless node.type.is_a?(Type)

    # BgStreamBlock infers ~T[?]; declared ~T[INF] picks the runtime wrapper.
    if node.value.is_a?(AST::BgStreamBlock) && node.type.inf_stream?
      node.value.full_type = final_type
    end

    # Propagate shard_count from declared type into final_type (lost during coerce!).
    if node.type.shard_count
      if final_type.is_a?(Type)
        final_type.shard_count = node.type.shard_count
      end
    end

    # Propagate @shared ownership into BgBlock for SharedPromise.spawn().
    if node.value.is_a?(AST::BgBlock) && node.type.shared_promise?
      node.value.full_type = Type.new(node.value.full_type, ownership: :shared)
    end
  end

  # Propagate collection, shard_count, soa, and sync metadata from the declared
  # type annotation (or inferred value type) into node.type_info and node.full_type.
  # These fields are lost during finalize_storage! and coerce!.
  def propagate_collection_metadata!(node, final_type)
    coll_src = if (decl_t = node.type).is_a?(Type) && decl_t.collection
      decl_t
    elsif node.value.type_info&.collection
      node.value.type_info
    end
    if coll_src
      node.type_info.collection  = coll_src.collection
      node.type_info.location    = :heap if coll_src.collection == :pool || coll_src.collection == :set
      node.type_info.shard_count = coll_src.shard_count if coll_src.shard_count
      node.type_info.soa         = coll_src.soa if coll_src.respond_to?(:soa) && coll_src.soa
      if node.full_type.is_a?(Type)
        node.full_type.collection  = coll_src.collection unless node.full_type.collection
        node.full_type.soa         = coll_src.soa if coll_src.respond_to?(:soa) && coll_src.soa
        node.full_type.shard_count = coll_src.shard_count if coll_src.shard_count && !node.full_type.shard_count
      end
    end

    # Map-specific propagation: maps don't use :collection, so the above doesn't cover them.
    if (decl_t = node.type).is_a?(Type)
      if decl_t.shard_count && !node.type_info&.shard_count
        node.type_info.shard_count = decl_t.shard_count if node.type_info
        node.full_type.instance_variable_set(:@shard_count, decl_t.shard_count) if node.full_type.is_a?(Type)
      end
      if decl_t.sync && node.type_info && !node.type_info.sync
        node.type_info.sync = decl_t.sync
        node.full_type.sync = decl_t.sync if node.full_type.is_a?(Type)
      end
      if decl_t.ownership != :affine && node.type_info
        node.type_info.instance_variable_set(:@ownership, decl_t.ownership)
        node.full_type.instance_variable_set(:@ownership, decl_t.ownership) if node.full_type.is_a?(Type)
      end
    end
  end

  # Propagate heap_promoted flag from function call return values.
  # Looks through OR expressions (BinaryOp :OR) to find the underlying
  # call — `x = failableFunc() OR default` should still propagate
  # heap_promoted from failableFunc's returns_promoted flag.
  def propagate_call_flags!(node)
    if has_heap_promoted_call?(node.value)
      node.type_info.heap_promoted = true
    end
  end

  # Check if an expression carries heap_promoted_call, looking through
  # OR/OR_RESCUE wrappers. Used by propagate_call_flags! and visit_BgBlock.
  # Both OR (orelse) and OR_RESCUE (catch) propagate because the transpiler
  # ensures fallback struct values also have their string fields duped to heap.
  def has_heap_promoted_call?(expr)
    return false unless expr
    # Direct call with heap_promoted_call flag
    return true if expr.respond_to?(:heap_promoted_call) && expr.heap_promoted_call
    # OR/OR_RESCUE expression: check the left side
    if expr.is_a?(AST::BinaryOp) && (expr.op == :OR || expr.op == :OR_RESCUE)
      return has_heap_promoted_call?(expr.left)
    end
    false
  end
end
