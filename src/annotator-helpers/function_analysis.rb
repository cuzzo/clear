require_relative "../ast/ast"

module FunctionAnalysis
  # Converts an intrinsic definition from STD_LIB format to the standard
  # function signature format used by verify_function_signature!.
  #
  # Input format (STD_LIB):
  #   { args: [:Int64, :String], return: :Bool, zig: "..." }
  #
  # Output format (standard signature):
  #   {
  #     params: [
  #       { name: "arg0", type: :Int64, required: true, mutable: false, takes: false },
  #       { name: "arg1", type: :String, required: true, mutable: false, takes: false }
  #     ],
  #     return: { type: :Bool },
  #     zig: "..."
  #   }
  #
  # Supports extended param format for future use:
  #   args: [{ type: :Int64, mutable: true }, :String]
  #
  # Builds a standard function signature from lambda parameters and return type.
  # This allows lambdas to use the same verify_function_signature! validation.
  #
  # @param params [Array] Lambda parameters from AST (each with :name, :type, :mutable, :default, :takes)
  # @param return_type [Symbol] The inferred or declared return type
  # @return [Hash] Standard signature format with :lambda marker
  #
  # Example output:
  #   {
  #     params: [
  #       { name: "x", type: :Float64, required: true, mutable: false, takes: false }
  #     ],
  #     return: { type: :Bool },
  #     lambda: true
  #   }
  #
  # Analyze a function or lambda body: enter scope, declare params/captures,
  # visit all statements, finalize scope, and resolve the return type.
  def analyze_routine(node, body, declared_return, is_implicit)
    # 1. Routine Prologue (Before Scope)
    verify_captures!(node)
    # Save and reset returns on the current FunctionContext (supports nested lambdas).
    saved_returns = current_fn_ctx&.returns
    current_fn_ctx.returns = [] if current_fn_ctx

    # 2. Body Analysis (Inside Scope)
    with_new_scope do
      og_push_scope
      declare_and_verify_params(node)
      declare_captures(node)

      # PRE clauses run at function entry — visit them with parameters in
      # scope so each predicate type-checks and resolves identifiers
      # against the parameter set. Visited before the body so the body's
      # locals can't leak into the predicate's symbol scope.
      visit_pre_clauses!(node) if node.is_a?(AST::FunctionDef)

      if body.is_a?(Array)
        visit_stmts(body)
      else
        visit(body)
      end

      # DEBUG_POST clauses run AFTER the body is annotated (return type
      # is known and synthetic `result` can be typed against it). Still
      # inside the routine scope so parameters are visible.
      visit_post_clauses!(node) if node.is_a?(AST::FunctionDef)

      finalize_scope(node)
      og_pop_scope
    end

    # 3. Routine Epilogue (Process Returns)
    found_returns = (current_fn_ctx&.returns || []).uniq
    # Restore saved returns (for enclosing function/lambda).
    current_fn_ctx.returns = saved_returns if current_fn_ctx && saved_returns
    verify_returns(node, found_returns, is_implicit ? nil : declared_return)

    # Resolve return type (infer if implicit or :Any)
    return_type = if body.is_a?(Array)
      found_returns.any? ? found_returns.first[:type] : :Any
    else
      body.resolved_type
    end

    # Update return type if we can narrow it
    if (is_implicit || declared_return == :Any) && found_returns.any?
      inferred = found_returns.first[:type]
      if is_implicit || found_returns.size == 1
        return_type = inferred
      end
    end

    return_type
  end

  def build_lambda_signature(params, return_type)
    normalized_params = params.map do |param|
      {
        name: param[:name],
        type: param[:type],
        required: param[:default].nil?,
        default: param[:default],
        mutable: param[:mutable] || false,
        takes: param[:takes] || false
      }
    end

    # Return a Hash (not FunctionSignature) because this feeds into
    # Type.new({ params:, return:, fn_type: true }) which expects a Hash raw.
    # Converting this requires Type to support FunctionSignature as raw.
    {
      params: normalized_params,
      return: { type: return_type },
      lambda: true,
      fn_type: true
    }
  end

  # Resolve a function call: look up the function, dispatch based on type
  # (intrinsic, user-defined, fn-type variable, generic), validate args,
  # and set the call node's full_type. Also tags cross-module, extern,
  # heap_promoted_call flags.
  def resolve_call(node, args)
    func_name = node.name

    scope = lookup_scope_for(func_name)
    unless scope
      emit_typo_suggestion!(
        node.token, func_name, @fn_nodes.keys,
        "Undefined function '#{func_name}'",
        "closest declared function"
      )
      return
    end

    func_type = scope.resolve_type(func_name)

    if func_type == :Intrinsic
      visit_IntrinsicFunc(node, args)

    elsif func_type.is_a?(FunctionSignature) || func_type.is_a?(Hash)
      node.module_alias = func_type.module_alias if node.respond_to?(:module_alias=) && func_type.module_alias
      if node.respond_to?(:extern_call=) && func_type.extern
        node.extern_call = true
        node.extern_effects = func_type.extern_effects if func_type.extern_effects
        record_effect(EffectTracker::EXTERN)
        # EXTERN FN with EFFECTS :alloc needs rt for allocator injection.
        alloc_kind = func_type.extern_effects&.dig(:alloc)
        if alloc_kind && current_fn_ctx
          if alloc_kind == :heap
            current_fn_ctx.heap_count += 1
          else
            current_fn_ctx.frame_count += 1
          end
        end
      end

      if func_type.extern
        args.each do |arg|
          ti = arg.type_info rescue nil
          if ti&.respond_to?(:soa?) && ti.soa?
            error!(arg, :SOA_TO_EXTERN_FN)
          end
        end
        # Comptime params: extract type args from arguments in comptime positions.
        # The argument is a TYPE_ID Identifier (e.g., MyDoc) — set it as a generic_type_arg.
        comptime_type_args = []
        params = func_type.params || []
        params.each_with_index do |p, i|
          if p[:comptime] && args[i].is_a?(AST::Identifier)
            comptime_type_args << args[i].name.to_sym
            args[i].full_type = :Type  # Mark as type-value, not a variable
          end
        end
        if comptime_type_args.any?
          node.generic_type_args = comptime_type_args if node.respond_to?(:generic_type_args=)
        end
      end

      type_params = func_type.type_params
      if type_params&.any?
        # For EXTERN FN with comptime params, the type bindings come directly from
        # the comptime arguments (e.g. T=JsonRecord), not from inference on resolved_type.
        comptime_type_args ||= []
        if func_type.extern && comptime_type_args.any?
          subst = {}
          type_params.each_with_index { |tp, i| subst[tp] = comptime_type_args[i] if comptime_type_args[i] }
        else
          subst = infer_generic_type_args!(node, func_type, args, type_params)
        end
        node.generic_type_args = type_params.map { |tp| subst[tp] } if node.respond_to?(:generic_type_args=)
        substituted = substitute_type_params(func_type, subst)
        call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
        verify_function_signature!(call_node, substituted)
        node.full_type = substituted[:return][:type]
      else
        call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
        verify_function_signature!(call_node, func_type)
        # Copy the return type so per-call-site mutations (provenance, cleanup_alloc)
        # don't corrupt the function signature's shared Type object.
        rt = func_type.return_type
        node.full_type = rt.is_a?(Type) ? Type.new(rt) : rt
        # Auto-propagate (CLEAR's error-handling default): the call's
        # *expression-level* type is the SUCCESS branch -- a binding
        # `h = call()` sees `T`, not `!T`. The error union flows
        # implicitly through the enclosing fn's `!T` return signature
        # (the codegen's try-wrap performs the unwrap). Per
        # docs/agents/error-handling.md: "the compiler handles error
        # propagation for you by default."
        # The original `!T` is stashed on `error_union_type` so
        # OR-RESCUE handlers (which read the LHS's union to pick
        # `catch`/`orelse`) can still see the un-stripped form.
        if node.full_type.is_a?(Type) && node.full_type.respond_to?(:error_union?) &&
           node.full_type.error_union?
          node.error_union_type = node.full_type if node.respond_to?(:error_union_type=)
          outer = node.full_type
          inner = outer.payload_type
          # The parser stamps storage/ownership/sync/layout on the
          # OUTER error union (e.g. `!Node @multiowned` -> outer.ownership
          # = :multiowned, payload = bare `Node`). Carry those over so
          # the binding's type_info still classifies as multiowned/
          # shared/heap/etc -- otherwise field-access lowering for `n.id`
          # misses the `.ctrl.data` unwrap.
          if inner.is_a?(Type)
            inner = Type.new(inner)
            if outer.respond_to?(:ownership) && outer.ownership && outer.ownership != :affine &&
               inner.respond_to?(:ownership=) && (inner.ownership.nil? || inner.ownership == :affine)
              inner.ownership = outer.ownership
            end
            if outer.respond_to?(:provenance) && outer.provenance &&
               inner.respond_to?(:provenance) && inner.provenance.nil? &&
               inner.respond_to?(:provenance=)
              inner.provenance = outer.provenance
            end
            if outer.respond_to?(:sync) && outer.sync &&
               inner.respond_to?(:sync) && inner.sync.nil? &&
               inner.respond_to?(:sync=)
              inner.sync = outer.sync
            end
            if outer.respond_to?(:layout) && outer.layout &&
               inner.respond_to?(:layout) && inner.layout.nil? &&
               inner.respond_to?(:layout=)
              inner.layout = outer.layout
            end
          end
          node.full_type = inner
        end
      end


    elsif func_type.is_a?(Type) && func_type.fn_type?
      node.fn_var_call = true if node.respond_to?(:fn_var_call=)
      lookup_scope_for(func_name)&.mark_read(func_name)
      synthetic_sig = {
        params: func_type.raw[:params],
        return: { type: func_type.raw[:return][:type] }
      }
      call_node = Struct.new(:token, :name, :args).new(node.token, func_name, args)
      verify_function_signature!(call_node, synthetic_sig)
      node.full_type = func_type.raw[:return][:type]

    elsif func_type.is_a?(Symbol)
      node.full_type = func_type

    else
      error!(node, :NOT_A_FUNCTION, name: func_name)
    end

    # Tag calls that return collections (direct or via struct fields) so the
    # caller knows to use heapAlloc for cleanup of promoted data.
    # String returns only get heap_promoted_call from callee.returns_promoted
    # (not from type alone) because stdlib string functions like readFile use
    # frameAlloc internally — the caller shouldn't try to free those.
    if node.type_info.is_a?(Type)
      callee_node = @fn_nodes[func_name]
      if callee_node&.return_provenance == :heap
        node.type_info.provenance = :heap if node.type_info.is_a?(Type)
      elsif node.type_info&.needs_escape_promotion? && !node.type_info&.string?
        node.type_info.provenance = :heap if node.type_info.is_a?(Type)
      else
        # Union return types with heap variants need heap_promoted_call
        # when the callee allocates at all (frame, heap, or alloc).
        ret_type = node.type_info
        if ret_type
          ret_sym = ret_type.is_a?(Type) ? ret_type.resolved : ret_type
          schema = lookup_type_schema(ret_sym)
          if schema.is_a?(Hash) && schema[:kind] == :union
            has_heap = (schema[:variants] || {}).any? { |_, vt| Type.variant_has_heap?(vt) }
            callee_allocates = callee_node&.return_provenance == :heap || callee_node&.uses_frame || callee_node&.uses_heap || callee_node&.uses_alloc
            if has_heap && callee_allocates
              node.type_info.provenance = :heap if node.type_info.is_a?(Type)
            end
          end
        end
      end
    end
  end

  def normalize_intrinsic_signature(config)
    return nil if config[:args] == :Varargs

    params = config[:args].each_with_index.map do |arg_def, i|
      if arg_def.is_a?(Hash)
        # Extended format: { type: :Int64, mutable: true, takes: false }
        {
          name: arg_def[:name] || "arg#{i}",
          type: arg_def[:type],
          required: true,
          mutable: arg_def[:mutable] || false,
          takes: arg_def[:takes] || false
        }
      else
        # Simple format: just a type symbol
        {
          name: "arg#{i}",
          type: arg_def,
          required: true,
          mutable: false,
          takes: false
        }
      end
    end

    FunctionSignature.new(
      params: params,
      return_type: config[:return],
      intrinsic: true,
      zig_pattern: config[:zig]
    )
  end

  def verify_function_signature!(node, signature)
    params = signature[:params]
    min_args = params.count { |param| param[:required] }
    max_args = params.size
    given_args = node.args.size

    # A. Arity Check (Count)
    if given_args < min_args || given_args > max_args
      if min_args == max_args
        error!(node, :ARITY_MISMATCH, name: node.name, expected: min_args, got: given_args)
      else
        error!(node, :ARITY_MISMATCH_RANGE, name: node.name, min: min_args, max: max_args, got: given_args)
      end
    end

    # A2. Inject default args for omitted optional params.
    if given_args < max_args
      params[given_args...max_args].each do |param|
        next if param[:required]
        default = param[:default]
        injected = case default
        when AST::DefaultLit
          type_name = param[:type].is_a?(Symbol) ? param[:type].to_s : param[:type].to_s
          AST::StructLit.new(default.token, type_name, {}, nil)
        else
          default.dup
        end
        visit(injected)
        node.args << injected
      end
    end

    # For alias overlap
    encountered_args = []
    atomic_bare_value_args = []

    node.args.each_with_index do |arg_node, i|
      param = params[i]
      next if param[:comptime]  # comptime type params are not type-checked
      verify_param_lifetime!(arg_node, param, signature)

      # B. Check mutability
      if param[:mutable]
        # Rule 1: Must be a Variable (Identifier), not a literal/expression
        if !arg_node.is_a?(AST::Identifier)
          error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_EXPRESSION, index: i+1, param: param[:name])
        end

        # Rule 2: The Variable being passed must be MUTABLE
        # We check the scope to see if the user declared it with 'MUTABLE'
        if current_scope.is_immutable?(arg_node.name)
          emit_immutable_arg_error!(arg_node, current_scope, i + 1, param[:name])
        end

        # Rule 3: Mark the caller's binding as mutated-through-call on
        # the SymbolEntry. The callee receives a mutable reference
        # (CLEAR's MUTABLE-by-ref calling convention), so any mutation
        # inside the callee is observable at the caller's binding —
        # post-annotation passes like the GUARD MUTABLE-mutation check
        # (validate_with_guard_no_body_mutation!) need to see this.
        #
        # Critically, we mark ONLY entry.mutated, NOT
        # decl_node.var_mutated. The latter drives the var/const emit
        # decision for the Zig-level binding, and at the Zig level the
        # call site doesn't visibly mutate the local — Zig's
        # "var-never-mutated" safety check would fire if we promoted
        # the binding to `var` here. The "MUTABLE never reassigned"
        # lint also reads decl_node.var_mutated; keeping that path
        # untouched preserves existing lint behavior.
        if arg_node.is_a?(AST::Identifier)
          mark_var_mutated_via_call(arg_node.name)
        end
      end

      # C. Handle ownership (Affine / Linear):
      # TAKES (callee declares ownership) or GIVE (caller relinquishes ownership)
      # Both suppress caller-side cleanup. Unwrap MoveNode to get the identifier.
      is_give = arg_node.is_a?(AST::MoveNode)
      inner_node = is_give ? arg_node.value : arg_node
      if param[:takes] || is_give
        # Reject borrowed values passed to TAKES params.
        # Container index access (arr[i], map[key]) returns a borrow -
        # you cannot take ownership of data inside a container.
        # Use .remove(i) or COPY arr[i] instead.
        if inner_node.respond_to?(:container_borrow) && inner_node.container_borrow
          arg_ti = inner_node.type_info
          arg_ti = Type.new(arg_ti) if arg_ti && !arg_ti.is_a?(Type)
          is_copy = arg_ti&.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil } rescue true
          unless is_copy
            error!(inner_node, :TAKES_NEEDS_OWNED_INDEX)
          end
        end

        # Ensure @list args to TAKES params are heap-owned (implicit COPY).
        if inner_node.is_a?(AST::Identifier)
          owned = ensure_owned_value!(inner_node, param[:type])
          node.args[i] = owned if owned
        end

        # `is_give` already had visit_GiveNode set the :give action;
        # for plain TAKES (no GIVE wrapper) record :takes so the
        # USE_OF_MOVED_VALUE diagnostic can phrase "TOOK it away".
        move_if_not_copyable!(inner_node, action: is_give ? :give : :takes)
        inner_node.was_moved = true
        arg_node.was_moved = true
        # If ensure_owned_value! wrapped the arg in a fresh CopyNode (auto-COPY
        # for TAKES), the new wrapper at node.args[i] must also carry was_moved
        # so the lowering can see "callee TAKES this on success" without
        # re-deriving from CopyNode/MoveNode syntax. Single source of truth.
        node.args[i].was_moved = true if node.args[i].respond_to?(:was_moved=)
      end

      # D0. @link arguments cannot be passed to functions expecting a concrete type.
      # The caller must RESOLVE the weak ref first. Skip for :Any params (intrinsics).
      arg_ti = arg_node.respond_to?(:type_info) ? arg_node.type_info : nil
      expected_raw = param[:type]
      if arg_ti&.link? && expected_raw != :Any
        param_type_obj = expected_raw.is_a?(Type) ? expected_raw : nil
        unless param_type_obj&.link?
          arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
          error!(arg_node, :LINK_NEEDS_RESOLVE_FOR_CALL, name: arg_name, param: param[:name])
        end
      end

      # D. Type Check
      expected = param[:type]
      actual = arg_node.resolved_type

      match = false

      # Case 0: fn_type structural check.
      # resolved_type only returns the return-type symbol for fn_types, so we
      # must compare the full Type objects to validate signature compatibility.
      expected_type_obj = expected.is_a?(Type) ? expected : Type.new(expected || :Any)
      if expected_type_obj.fn_type? && arg_node.respond_to?(:full_type)
        actual_type_obj = arg_node.full_type
        if actual_type_obj.is_a?(Type) && expected_type_obj.accepts?(actual_type_obj)
          match = true
        elsif actual_type_obj.is_a?(Type) && actual_type_obj.fn_type? &&
              actual_type_obj.raw[:reentrant] && !expected_type_obj.raw[:reentrant]
          arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
          error!(arg_node, :REENTRANT_FN_TO_NON_REENTRANT_PARAM, name: arg_name, param: param[:name])
        end
      end

      # Case 0b: strict shared-handle boundary. Type#== intentionally
      # compares only the resolved base type for backward compatibility,
      # so `Point@shared` would otherwise accept bare `Point`. Keep this
      # check local to function calls: a `T@shared` parameter promises
      # that the callee can retain/cross execution boundaries, so callers
      # must pass a real shared handle or explicitly write SHARE x.
      actual_type_obj = arg_ti.is_a?(Type) ? arg_ti : Type.new(actual || :Any)
      if explicit_primitive_atomic_param?(expected_type_obj)
        unless atomic_cell_arg?(arg_node)
          arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
          error!(arg_node, :ARG_NEEDS_ATOMIC_CELL,
            index: i + 1, fn: node.name, expected: expected_type_obj.resolved,
            name: arg_name, actual: actual_type_obj.resolved)
        end
        arg_node.atomic_borrow = true if arg_node.respond_to?(:atomic_borrow=)
      end
      if atomic_cell_to_bare_value_param?(arg_node, expected_type_obj, param)
        atomic_bare_value_args << arg_node
      end
      if atomic_cell_to_atomic_param?(arg_node, param, signature)
        arg_node.atomic_borrow = true if arg_node.respond_to?(:atomic_borrow=)
      end
      if !match && expected_type_obj.shared?
        unless actual_type_obj.shared?
          hint = if arg_node.is_a?(AST::Identifier)
            " Use SHARE #{arg_node.name} to create a shared handle."
          else
            " Use SHARE <expr> to create a shared handle."
          end
          error!(arg_node, :ARG_NEEDS_SHARED,
            index: i + 1, fn: node.name, expected: expected_type_obj, actual: actual_type_obj, hint: hint)
        end
        match = true if expected_type_obj.resolved == actual_type_obj.resolved
      end

      # Case 1: Exact Match or Any
      if !match && (expected == :Any || actual == :Any || expected == actual)
        match = true

      elsif !match && (expected_type_obj.respond_to?(:auto?) && expected_type_obj.auto?)
        # Gradual-typing tolerance: param declared Auto. The
        # AutoUnifier (annotator's Pass C) resolves it from the
        # observed call-site arg types AFTER this body walk
        # completes; coercing the call-site arg here would commit
        # to a type the unifier hasn't picked yet. Treat as a
        # match for now; mismatch (if the resolution disagrees
        # with this arg's actual type) surfaces when the resolved
        # decl gets re-validated downstream.
        match = true

      elsif !match && is_safe_autocast?(actual, expected)
        arg_node.coerced_type = expected
        check_prefixed_int_range!(arg_node, expected)
        match = true
      end

      unless match
        arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
        error!(arg_node, :ARGUMENT_TYPE_ERROR, fn: arg_name, index: i+1, expected: expected, got: actual)
      end

      # E. Check for Alias overlap (i.e. swap(x, x) -> ERROR!)
      current_path = get_path_to_root(arg_node)

      next if current_path.nil?
      is_mutable = param[:mutable]

      encountered_args.each_with_index do |prev, prev_index|
        # Conflict Condition:
        # 1. At least one of them is MUTABLE (Mut/Mut OR Mut/Immut)
        # 2. The paths overlap (e.g. "x" overlaps "x.child", "x" overlaps "x")
        if (is_mutable || prev[:mutable]) && paths_overlap?(current_path, prev[:path])

          error!(arg_node, :ARG_ALIAS_CONFLICT,
            index: i+1, name: (arg_node.name rescue 'arg'), other_index: prev_index+1, path: current_path.first)
        end
      end

      # Register this argument for future checks
      encountered_args << {
        path: current_path,
        mutable: is_mutable,
        name: arg_node.respond_to?(:name) ? arg_node.name : "arg"
      }
    end

    warn_multi_atomic_bare_value_call!(node, atomic_bare_value_args)
  end

  def atomic_cell_to_bare_value_param?(arg_node, expected_type_obj, param)
    return false unless arg_node.is_a?(AST::Identifier)
    sym = arg_node.respond_to?(:symbol) ? arg_node.symbol : nil
    return false unless sym&.sync == :atomic
    return false if sym.respond_to?(:layout) && sym.layout == :indirect
    return false if param[:sync] == :atomic
    return false if param[:symbol]&.respond_to?(:sync) && param[:symbol].sync == :atomic
    return false if expected_type_obj.any? || expected_type_obj.fn_type?
    return false if expected_type_obj.shared? || expected_type_obj.any_sync?

    expected_type_obj.primitive?
  end

  def atomic_cell_to_atomic_param?(arg_node, param, signature)
    return false unless arg_node.is_a?(AST::Identifier)
    sym = arg_node.respond_to?(:symbol) ? arg_node.symbol : nil
    return false unless sym&.sync == :atomic
    ptype = param[:type]
    return true if ptype.is_a?(Type) && ptype.sync == :atomic
    return true if param[:sync] == :atomic
    return true if param[:symbol]&.respond_to?(:sync) && param[:symbol].sync == :atomic

    requires = signature.respond_to?(:requires) ? signature.requires : signature[:requires]
    families = requires && requires[param[:name].to_s]
    families.respond_to?(:include?) && families.include?(:ATOMIC)
  end

  def atomic_cell_arg?(arg_node)
    return false unless arg_node.is_a?(AST::Identifier)
    sym = arg_node.respond_to?(:symbol) ? arg_node.symbol : nil
    sym&.sync == :atomic && !(sym.respond_to?(:layout) && sym.layout == :indirect)
  end

  def explicit_primitive_atomic_param?(type)
    type.is_a?(Type) && type.sync == :atomic && type.primitive?
  end

  def warn_multi_atomic_bare_value_call!(node, atomic_args)
    unique_args = atomic_args.compact
    return if unique_args.length < 2

    names = unique_args.map { |arg| arg.respond_to?(:name) ? arg.name : "<expr>" }
    warning!(node,
      "Call to '#{node.name}' reads multiple atomic values independently " \
      "(#{names.join(', ')}). This is not a multi-object-consistent snapshot; " \
      "default mode allows it as ordinary atomic loads. STRICT/STRICT EXTREME " \
      "will require an explicit @inconsistent call-site annotation.")
  end

  # TODO: Needs updated once lifetimes are complex
  # TODO: At definition time, verify the full path is valid
  def verify_param_lifetime!(arg_node, param, signature)
    return true if !arg_node.is_a?(AST::Identifier)

    if param[:mutable] && !@og.can_write?(arg_node.name)
      error!(arg_node, :MUTABLE_ARG_RESTRICTED, name: arg_node.name)
    end

    # Atomics M2.4 / M2.5: signature[:return][:lifetime] is now an
    # Array of dotted-path strings (or [:wildcard]) instead of a
    # single string. Empty array = no lifetime annotation.
    lifetime_paths = signature.dig(:return, :lifetime) || []
    lifetime_paths = [lifetime_paths] unless lifetime_paths.is_a?(Array)
    return true if lifetime_paths.empty?

    borrow_type = param[:mutable] ? :mutable : :immutable
    return true if current_scope.is_immutable?(arg_node.name) || current_scope.is_restricted?(arg_node.name)

    # If `param` is named in the lifetime sources (any of the multi-
    # binding entries), the caller is borrowing through that param's
    # lifetime; reject if the borrow is mutable but not RESTRICTed.
    # Wildcard accepts every param implicitly.
    base_paths = lifetime_paths.flat_map do |p|
      next [:wildcard] if p == :wildcard
      [p.to_s.split(".").first]
    end
    return true unless base_paths.include?(:wildcard) || base_paths.include?(param[:name])

    error!(arg_node, :MUTABLE_PARAM_NEEDS_RESTRICT, name: param[:name])
  end

  # Atomics M2.4 / M2.5: validate `RETURNS <lifetime>:T`.
  #
  # `node.return_lifetime` shapes:
  #   nil                    -- no lifetime
  #   :wildcard              -- `RETURNS *:T` (lazy)
  #   Array<AST::Identifier|GetField>
  #                          -- `RETURNS foo:T` (one element) or
  #                             `RETURNS (a b c):T` (multi)
  def verify_lifetime!(node)
    rl = node.return_lifetime
    return true if rl.nil?

    # Wildcard: warn (linter will replace with explicit list); accept.
    if rl == :wildcard
      note!(node,
        "Function '#{node.name}' uses wildcard return lifetime " \
        "`RETURNS *:T`. Every parameter is conservatively folded into " \
        "the source set. Consider replacing with the explicit list of " \
        "parameters whose lifetimes the return value actually depends " \
        "on; `clear fix` (lint) will offer the rewrite once the audit " \
        "matrix lands.")
      return true
    end

    # Multi- (or single-) binding: every entry must resolve to a
    # parameter and (for nested field paths) a real field chain.
    sources = rl.is_a?(Array) ? rl : [rl]
    sources.each do |source|
      verify_lifetime_source!(node, source)
    end

    # Atomics M2.7: a `REQUIRES x: ATOMIC | <non-atomic>` with a
    # `RETURNS x:T` lifetime can't be safely emitted -- the runtime
    # layout differs per family (bare `*Atomic(T)` vs `Arc(Locked
    # (T))`), so a single returned future would have two different
    # lifetime stories at the call site. Reject the combination at
    # the declaration site so the user picks one family or splits
    # into two fns.
    verify_no_mixed_atomic_returned_lifetime!(node, sources)
    true
  end

  # Atomics M2.7: when the fn declares `RETURNS <param>:T` (the
  # returned value's lifetime is tied to <param>) AND the param's
  # REQUIRES disjunction mixes ATOMIC with a non-atomic family,
  # error. The returned value's runtime layout depends on which
  # family the caller passes, but the source-tracking (M2.3 +
  # M2.6) treats every concrete family the same way -- so the
  # mixed declaration is ambiguous in a way the lifetime checker
  # can't model. Force the user to split into separate fns or pick
  # one family.
  def verify_no_mixed_atomic_returned_lifetime!(node, sources)
    requires_map = node.respond_to?(:requires) ? (node.requires || {}) : {}
    return if requires_map.empty?

    sources.each do |source|
      path = get_path_to_root(source)
      next unless path
      root_name = path.first.to_s
      families = requires_map[root_name]
      next unless families.is_a?(Set) && families.size > 1
      next unless families.include?(:ATOMIC)
      others = families - Set[:ATOMIC]
      error!(node, :LIFETIME_RETURNS_REQUIRES_FAMILY_CONFLICT,
        fn: node.name, name: root_name,
        others: others.to_a.join(' | '), others_label: others.to_a.join(' / '))
    end
  end

  def verify_lifetime_source!(node, source_node)
    path = get_path_to_root(source_node)
    root_param_name = path.first.to_s
    param = node.params.find { |p| p[:name] == root_param_name }

    if param.nil?
      error!(node, :LIFETIME_ROOT_NOT_PARAM, name: root_param_name)
    end

    # Extract the resolved type name (Type objects from parse_type_annotation)
    param_type = param[:type]
    current_type_name = param_type.is_a?(Type) ? param_type.resolved : param_type.to_sym

    path.drop(1).each do |field_sym|
      field_name = field_sym.to_s

      # Stop if we hit an Array index wildcard (we can't verify types past a dynamic index easily yet)
      break if field_sym == :*
      schema = current_scope.resolve_type_definition(current_type_name)

      if schema.nil?
        error!(node, :LIFETIME_NOT_A_STRUCT, type: current_type_name, field: field_name)
      end

      # Check if the field exists in the schema
      next_type = schema[field_name] || schema[field_sym] # handle string/sym keys

      if next_type.nil?
        error!(node, :LIFETIME_NO_FIELD, type: current_type_name, field: field_name)
      end

      # Advance to the next type name (Type objects carry the resolved name)
      current_type_name = next_type.is_a?(Type) ? next_type.resolved : next_type.to_sym
    end
  end

  def declare_and_verify_params(node)
    node.params.each do |param|
      # Validate Defaults
      if param[:default]
        if param[:default].is_a?(AST::DefaultLit)
          # DEFAULT is only valid for struct-type params
          param_type_sym = param[:type].is_a?(Symbol) ? param[:type] : param[:type].to_sym rescue nil
          schema = lookup_type_schema(param_type_sym) if param_type_sym
          unless schema.is_a?(Hash) && !schema[:kind]
            error!(node, :DEFAULT_NEEDS_STRUCT_PARAM, type: param[:type])
          end
          # Validate all fields of the struct have defaults
          field_names = schema.keys.reject { |k| k.is_a?(Symbol) }
          unless field_names.empty?
            field_defaults = schema[:field_defaults] || {}
            missing = field_names.reject { |f| field_defaults.key?(f) }
            if missing.any?
              error!(node, :DEFAULT_STRUCT_MISSING_DEFAULTS, name: param[:name], type: param[:type], missing: missing.join(', '))
            end
          end
          param[:default].full_type = param[:type].to_sym rescue param[:type]
        else
          visit(param[:default])
          def_type = param[:default].resolved_type
          param_type = param[:type]
          unless is_safe_autocast?(def_type, param_type)
            error!(node, :DEFAULT_VALUE_TYPE_MISMATCH, name: param[:name], expected: param_type, got: def_type)
          end
        end
      end

      # Thread sync into the binding's SymbolEntry. Sources, in priority:
      #   1. Explicit :sync on the signature param (cross-module form).
      #   2. The param's declared type's sync (legacy direct-annotation).
      #   3. The function's REQUIRES clause — if the param is constrained
      #      to a sync family (LOCKED, etc.), seed a default sync that
      #      satisfies the deferred WITH validation. This unblocks the
      #      cross-module case where propagate_caller_sync! can't see
      #      callers (e.g., a helper in a REQUIRE'd file). The actual
      #      caller-supplied sync still flows in via P1.4 propagation
      #      when callers are visible; this seed just keeps the in-file
      #      annotation valid.
      param_sync = nil
      if param[:sync]
        param_sync = param[:sync]
      elsif param[:type].is_a?(Type) && param[:type].any_sync?
        param_sync = param[:type].sync
      elsif node.respond_to?(:requires) && node.requires
        families = node.requires[param[:name].to_s]
        if families
          # Polymorphic LOCKED | VERSIONED | ATOMIC falls through
          # to LOCKED's seed (the WITH MATCH x WHEN @versioned ...
          # WHEN @locked / WHEN @atomic arm-check overrides per-arm
          # anyway, so any pinned-default is informational only).
          # True-Sync-Polymorphism (#326): SNAPSHOTTED is the umbrella
          # family for {@versioned, @atomic}; seed :versioned so the
          # WITH SNAPSHOT body validation accepts a polymorphic param.
          # The actual caller-supplied sync overrides via P1.4
          # propagation when callers are visible.
          if families.include?(:LOCKED)
            param_sync = :locked
          elsif families.include?(:VERSIONED)
            param_sync = :versioned
          elsif families.include?(:ATOMIC)
            param_sync = :atomic
          elsif families.include?(:SNAPSHOTTED)
            param_sync = :versioned
          elsif families.include?(:LOCAL)
            # #336: LOCAL admits @local / @multiowned / plain T. Seed
            # `:local` so the deferred WITH POLYMORPHIC validation
            # accepts the param; the actual caller-supplied storage
            # axis flows in via P1.4 propagation.
            param_sync = :local
          end
        end
      end
      # AtomicPtr M3.11: when REQUIRES includes ATOMIC AND the param's
      # type is a struct (not a primitive), the implicit cap is
      # `@indirect:atomic` (the struct case). Seed `:layout = :indirect`
      # so WITH SNAPSHOT's cap_var_layout check accepts the cell --
      # parallel to the param_sync seed above. Primitives (Int64 /
      # Float64 / Bool) keep layout=nil because their @atomic surface
      # is the bare-cell @shared:atomic form, not AtomicPtr.
      param_layout = nil
      if param_sync == :atomic
        param_t = param[:type].is_a?(Type) ? param[:type] : Type.new(param[:type])
        param_layout = :indirect if param_t.respond_to?(:struct?) && param_t.struct?
      end
      current_scope.declare(
        param[:name], nil, param[:type], param[:mutable], false, nil, :stack,
        Set.new, [], sync: param_sync, layout: param_layout
      )
      # Stash the SymbolEntry on the param hash so the transitive sync
      # propagation pass (P1.4) and downstream code can find it without
      # walking the body for an Identifier reference.
      param[:symbol] = current_scope.locals[param[:name]]
      # Mark as a parameter so deferred WITH validation (P1.7) can
      # distinguish it from local bindings.
      param[:symbol].is_param = true
      param[:symbol].param_decl_token = param[:name_token]
      # Atomics M1.6.5: stamp sync_families from the REQUIRES disjunction so
      # call-site effect resolution can detect polymorphic bindings (size > 1).
      if node.respond_to?(:requires) && node.requires
        fams = node.requires[param[:name].to_s]
        param[:symbol].sync_families = fams if fams.is_a?(Set) && !fams.empty?
      end
      # TAKES parameters own the data — force :affine so cleanup is emitted.
      current_scope.locals[param[:name]].takes = true if param[:takes]
      classify_ownership!(current_scope.locals[param[:name]])
      og_declare(param[:name], nil, param[:type])
      # Non-TAKES parameters are implicit borrows. Mark in OG so the
      # annotator prevents storing borrowed data into owned containers.
      unless param[:takes]
        @og[param[:name]]&.kind = :borrowed
      end
      param[:type]
    end
  end

  # Cannot be part of declare, needs to happen in outer-scope
  def verify_captures!(node)
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      # cap is likely a hash: { name: "x" }
      cap_name = cap[:name]

      if cap[:default]
        error!(node, :CAPTURE_NO_DEFAULT, name: cap_name)
      end

      if !current_scope.locals.key?(cap_name)
        # Check if it's in a higher scope
        owner_scope = lookup_scope_for(cap_name)
        if owner_scope.nil?
           error!(node, :CAPTURE_UNDEFINED_VAR, name: cap_name)
        end
      else
        # Local capture
        owner_scope = current_scope
      end

      entry = owner_scope.locals[cap_name]

      if cap[:mutable] && !entry.mutable
        emit_capture_immutable_as_mutable_error!(node, cap_name, owner_scope)
      end

      # Mark the captured variable as used in its declaring scope.
      owner_scope.mark_read(cap_name)

      # Enrich the capture node with the resolved type
      cap[:type] = entry.type
      cap[:storage] = entry.storage
    end
  end

  def declare_captures(node)
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      current_scope.declare(
        cap[:name],
        nil,
        cap[:type],
        cap[:mutable],
        false,
        nil,
        cap[:storage]
      )
    end
  end

  def verify_returns(node, found_returns, declared_return)
    if found_returns.size > 1
      # Normalize: all string-like types (Byte[N], String) → String for comparison
      normalized = found_returns.map { |r|
        t = r[:type].to_s
        (t.start_with?("Byte[") || t == "String") ? :String : r[:type]
      }.uniq.size
      if declared_return != :Any && normalized > 1
        emit_ambiguous_return_error!(node, found_returns)
      end
    end
  end

  def get_return_strategy(return_type)
    type = Type.new(return_type)

    # 1. Small Objects & Pointers -> Return in Register (Fastest)
    if !type.requires_move? || type.heap?
      return :register
    elsif type.void?
      return :void
    else
      # Structs, Fixed Arrays, etc.
      return :destination_pass
    end
  end

  def verify_return(node)
    # A returned value is a borrow when it is a direct indexed/field access OR
    # a variable that the ownership graph marked as :borrowed.
    return true unless return_is_borrow?(node)

    # Union variant constructors (Value.Nil, Shape.Point) create new values, not borrows.
    if node.is_a?(AST::GetField) && node.target.is_a?(AST::Identifier)
      schema = lookup_type_schema(node.target.name.to_sym) rescue nil
      return true if schema.is_a?(Hash) && (schema[:kind] == :union || schema[:kind] == :enum)
    end

    # Atomics M2.5: lifetime is now an Array of dotted-path strings
    # (or [:wildcard] for `RETURNS *:T`). Empty array == no lifetime.
    lifetime_paths = current_fn_ctx&.lifetime || []
    type_info = node.type_object
    has_lifetime = !lifetime_paths.empty?
    is_wildcard = lifetime_paths == [:wildcard]
    schema_resolver = ->(t) { lookup_type_schema(t) rescue nil }
    is_copyable = (type_info&.copyable?(schema_resolver) || type_info&.implicitly_copyable?(schema_resolver))
    fn_type_params = current_fn_ctx&.type_params || []
    is_type_param = fn_type_params.include?(type_info&.resolved)

    unless has_lifetime || is_copyable || is_type_param
      emit_return_borrowed_no_copy_error!(node)
    end

    return true unless has_lifetime
    # Wildcard accepts any return-derivation path -- the diagnostic at
    # the declaration site already warned about it.
    return true if is_wildcard

    # Lifetime path validation applies to direct field/index access only.
    # Borrowed variables need source-tracing (future work).
    return true if node.is_a?(AST::Identifier)

    actual_path = get_path_to_root(node)
    if actual_path.nil?
      error!("Lifetime Error: Lifetime '#{lifetime_paths.join(', ')}' specified on return, but returned value is not associated.")
    end

    # Multi-source semantics: returned value derives from EXACTLY one
    # of the declared sources (it cannot simultaneously originate from
    # two distinct parameters). Accept iff `actual_path` has any
    # declared source as its prefix; reject with a clear "expected one
    # of: ..." diagnostic when none match.
    matched = lifetime_paths.any? do |p|
      lifetime_syms = p.split(".").map(&:to_sym)
      actual_path[0...lifetime_syms.size] == lifetime_syms
    end

    unless matched
      sources_msg = lifetime_paths.size == 1 ?
        "derived from: #{lifetime_paths.first}" :
        "derived from one of: #{lifetime_paths.join(' | ')}"
      error!(node, :RETURN_LIFETIME_MISMATCH,
        sources_msg: sources_msg, actual: actual_path.join('.'))
    end
  end

  def return_is_borrow?(node)
    if node.is_a?(AST::Identifier)
      return false unless @og[node.name]&.kind == :borrowed
      # Parameters (reg=nil) and MATCH bindings (reg=nil) are safe to return —
      # the caller controls their lifetime. Only flag variables explicitly assigned
      # from a collection index borrow (BindExpr with container_borrow=true).
      scope = lookup_scope_for(node.name)
      reg = scope&.locals&.[](node.name)&.reg
      return reg.respond_to?(:container_borrow) && reg.container_borrow == true
    end
    return true if node.is_a?(AST::GetIndex)
    return true if node.is_a?(AST::GetField)
    false
  end

  def paths_overlap?(path_a, path_b)
    # 1. Different Roots? (e.g. [:x, ...] vs [:y, ...]) -> No Overlap
    return false if path_a.first != path_b.first

    # 2. Same Root -> Check if one is a prefix of the other.
    # We only compare up to the length of the shorter path.
    # [:x, :a] vs [:x, :b] -> Compare [:x, :a] vs [:x, :b] -> mismatch at index 1 -> Safe.
    # [:x] vs [:x, :y]     -> Compare [:x] vs [:x]          -> match -> Unsafe.

    len = [path_a.size, path_b.size].min
    return path_a[0...len] == path_b[0...len]
  end

  # Finds the first intrinsic overload that matches the given arguments.
  # Returns nil if no overload matches.
  # Maps `:reject_when` symbol values to a predicate over a CLEAR Type.
  # Add new entries here when std_lib.rb introduces a new "this overload
  # doesn't make sense for type-shape X" guard. Each predicate receives
  # the receiver's resolved Type; returning true rejects the call.
  REJECT_TYPE_PREDICATES = {
    unsigned_integer: ->(t) { t.respond_to?(:unsigned_integer?) && t.unsigned_integer? },
  }.freeze

  def reject_arg_type_matches?(arg, kind)
    pred = REJECT_TYPE_PREDICATES[kind]
    return false unless pred
    type = arg.respond_to?(:full_type) ? arg.full_type : nil
    return false unless type.is_a?(Type)
    pred.call(type)
  end

  def find_matching_intrinsic(definitions, args)
    definitions.find do |config|
      next true if config[:args] == :Varargs  # Varargs accepts anything

      # Arity check
      next false if args.size != config[:args].size

      # Type check each argument, including capability constraints.
      # Hash args like { type: :String, sync: :raw } check both the base
      # type and the capability. This allows the registry to dispatch to
      # different Zig implementations based on the argument's capability.
      args.each_with_index.all? do |arg, i|
        spec = config[:args][i]
        if spec.is_a?(Hash)
          expected = spec[:type]
          next false unless is_safe_autocast?(arg.resolved_type, expected)
          # Check capability constraints (sync, ownership, etc.)
          arg_type = arg.type_info.is_a?(Type) ? arg.type_info : nil
          next false if spec[:sync] && arg_type&.sync != spec[:sync]
          next false if spec[:ownership] && arg_type&.ownership != spec[:ownership]
          true
        else
          is_safe_autocast?(arg.resolved_type, spec)
        end
      end
    end
  end

  # Formats intrinsic args for error messages
  def format_intrinsic_args(args)
    return "(varargs)" if args == :Varargs
    types = args.map { |a| a.is_a?(Hash) ? a[:type] : a }
    "(#{types.join(', ')})"
  end
end
