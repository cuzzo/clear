# typed: strict
require "sorbet-runtime"
require_relative "../../ast/ast"

module FunctionAnalysis
    extend T::Sig
    extend T::Helpers

  requires_ancestor { SemanticAnnotator }

  # Analyze a function or lambda body: enter scope, declare params/captures,
  # visit all statements, finalize scope, and resolve the return type.
  sig { params(node: T.untyped, body: T.untyped, declared_return: T.untyped, is_implicit: T::Boolean).returns(T.nilable(Symbol)) }
  def analyze_routine(node, body, declared_return, is_implicit)
    T.bind(self, SemanticAnnotator) rescue nil
    verify_captures!(node)
    # Save and reset returns on the current FunctionContext (supports nested lambdas).
    saved_returns = current_fn_ctx&.returns
    current_fn_ctx.returns = [] if current_fn_ctx

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
      og_pop_scope(archive: true)
    end

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

  sig { params(params: T::Array[AST::Param], return_type: Symbol).returns(FunctionSignature) }
  def build_lambda_signature(params, return_type)
    T.bind(self, SemanticAnnotator) rescue nil
    normalized_params = params.map do |param|
      AST::Param.new(
        name: param.name,
        type: param.type,
        required: param.default.nil?,
        default: param.default,
        mutable: param.mutable || false,
        takes: param.takes || false
      )
    end

    FunctionSignature.new(params: normalized_params, return_type: Type.new(return_type))
  end

  # Resolve a function call: look up the function, dispatch based on type
  # (intrinsic, user-defined, fn-type variable, generic), validate args,
  # and set the call node's full_type. Also tags cross-module, extern,
  # call result placement is decided later by escape analysis.
  sig { params(node: T.untyped, args: T::Array[T.untyped]).returns(T.nilable(Symbol)) }
  def resolve_call(node, args)
    T.bind(self, SemanticAnnotator) rescue nil
    func_name = node.name

    scope = lookup_scope_for(func_name)
    unless scope
      @fn_nodes = T.let(@fn_nodes, T.nilable(T::Hash[String, AST::FunctionDef]))
      fn_nodes = T.must(@fn_nodes)
      emit_typo_suggestion!(
        node.token, func_name, fn_nodes.keys,
        "Undefined function '#{func_name}'",
        "closest declared function"
      )
      return
    end

    func_type = scope.resolve_type(func_name)
    entry = scope.locals[func_name]
    fsig = FunctionSignature.unwrap(func_type)
    call_node = args.equal?(node.args) ? node : Struct.new(:token, :name, :args).new(node.token, func_name, args)

    if func_type == :Intrinsic
      visit_IntrinsicFunc(node, args)

    # Direct call to a defined/imported/extern function. The authoritative
    # fact is the binding's storage (:static for FN/IMPORT/EXTERN decls),
    # NOT the storage shape of the signature — a fn-typed param/local
    # holds the same Type-wrapped FunctionSignature but is :stack and
    # routes to the fn_var_call path below.
    elsif fsig && entry&.storage == :static
      signature = fsig
      node.module_alias = signature.module_alias if node.respond_to?(:module_alias=) && signature.module_alias
      if node.respond_to?(:extern_call=) && signature.extern
        node.extern_call = true
        node.extern_effects = signature.extern_effects
        record_effect(EffectTracker::EXTERN)
        # EXTERN FN with EFFECTS :alloc needs rt for allocator injection.
        alloc_kind = signature.extern_effects&.dig(:alloc)
        if alloc_kind && current_fn_ctx
          if alloc_kind == :heap
            current_fn_ctx.heap_count += 1
          else
            current_fn_ctx.frame_count += 1
          end
        end
      end

      if signature.extern
        args.each do |arg|
          if arg.full_type!(context: "extern argument").soa?
            error!(arg, :SOA_TO_EXTERN_FN)
          end
        end
        # Comptime params: extract type args from arguments in comptime positions.
        # The argument is a TYPE_ID Identifier (e.g., MyDoc) — set it as a generic_type_arg.
        comptime_type_args = []
        params = signature.params
        params.each_with_index do |p, i|
          if p.comptime && args[i].is_a?(AST::Identifier)
            comptime_type_args << args[i].name.to_sym
            stamp_type!(args[i], :Type) # Mark as type-value, not a variable
          end
        end
        if comptime_type_args.any?
          node.generic_type_args = comptime_type_args if node.respond_to?(:generic_type_args=)
        end
      end

      type_params = signature.type_params
      if type_params&.any?
        # For EXTERN FN with comptime params, the type bindings come directly from
        # the comptime arguments (e.g. T=JsonRecord), not from inference on resolved_type.
        comptime_type_args ||= []
        if signature.extern && comptime_type_args.any?
          subst = {}
          type_params.each_with_index { |tp, i| subst[tp] = comptime_type_args[i] if comptime_type_args[i] }
        else
          subst = infer_generic_type_args!(node, signature, args, type_params)
        end
        node.generic_type_args = type_params.map { |tp| T.must(subst)[tp] } if node.respond_to?(:generic_type_args=)
        substituted = substitute_type_params(signature, T.must(subst))
        verify_function_signature!(call_node, substituted)
        node.matched_signature = substituted if node.respond_to?(:matched_signature=)
        stamp_type!(node, substituted.return_type)
      else
        verify_function_signature!(call_node, signature)
        node.matched_signature = signature if node.respond_to?(:matched_signature=)
        # Copy the return type so per-call-site mutations (provenance, cleanup_alloc)
        # don't corrupt the function signature's shared Type object.
        stamp_type!(node, Type.new(signature.return_type))
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
        call_type = node.full_type!(context: "function call result")
        if call_type.respond_to?(:error_union?) &&
           call_type.error_union?
          node.error_union_type = call_type if node.respond_to?(:error_union_type=)
          stamp_type!(node, call_type.success_type)
        end
      end


    elsif fsig
      node.fn_var_call = true if node.respond_to?(:fn_var_call=)
      lookup_scope_for(func_name)&.mark_read(func_name)
      sig = fsig
      synthetic_sig = FunctionSignature.new(
        params: sig.params,
        return_type: sig.return_type
      )
      verify_function_signature!(call_node, synthetic_sig)
      node.matched_signature = synthetic_sig if node.respond_to?(:matched_signature=)
      stamp_type!(node, sig.return_type)

    elsif func_type.is_a?(Symbol)
      stamp_type!(node, func_type)

    else
      error!(node, :NOT_A_FUNCTION, name: func_name)
    end

    nil
  end

  sig { params(config: FunctionSignature).returns(T.nilable(FunctionSignature)) }
  def normalize_intrinsic_signature(config)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil if config.arg_spec == :Varargs

    params = config.arg_spec.each_with_index.map do |arg_def, i|
      if arg_def.is_a?(Hash)
        # Extended format: { type: :Int64, mutable: true, takes: false }
        AST::Param.new(
          name: arg_def[:name] || "arg#{i}",
          type: arg_def[:type],
          required: true,
          mutable: arg_def[:mutable] || false,
          takes: arg_def[:takes] || false
        )
      else
        # Simple format: just a type symbol
        AST::Param.new(
          name: "arg#{i}",
          type: arg_def,
          required: true,
          mutable: false,
          takes: false
        )
      end
    end

    FunctionSignature.new(
      params: params,
      return_type: config.return_type,
      intrinsic: true,
      zig_pattern: config.emit&.zig
    )
  end

  # Single point: what allocator does the receiver/container of this call use?
  # For MethodCall on a list/struct/etc, the receiver's binding storage tells
  # us the container allocator -- auto-COPY into this container must produce
  # values in this allocator (per "one collection = one allocator").
  # Returns nil when the call has no container context (plain function call,
  # or receiver storage not yet determined).
  sig { params(node: T.untyped).returns(T.nilable(Symbol)) }
  def receiver_container_alloc(node)
    return nil unless node.is_a?(AST::MethodCall)
    obj = node.object
    sym = obj.respond_to?(:symbol) ? obj.symbol : nil
    storage = sym&.storage
    return nil unless storage
    return :frame if storage == :frame
    return :heap if storage == :heap
    nil
  end

  sig { params(node: T.untyped, signature: FunctionSignature).returns(T.nilable(T::Array[String])) }
  def verify_function_signature!(node, signature)
    T.bind(self, SemanticAnnotator) rescue nil
    node.matched_signature = signature if node.respond_to?(:matched_signature=)
    params = signature.params
    min_args = params.count { |param| param.required }
    max_args = params.size
    given_args = node.args.size

    if given_args < min_args || given_args > max_args
      if min_args == max_args
        error!(node, :ARITY_MISMATCH, name: node.name, expected: min_args, got: given_args)
      else
        error!(node, :ARITY_MISMATCH_RANGE, name: node.name, min: min_args, max: max_args, got: given_args)
      end
    end

    if given_args < max_args
      (params[given_args...max_args] || []).each do |param|
        next if param.required
        default = param.default
        injected = case default
        when AST::DefaultLit
          type_name = param.type.to_s
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
      param = T.must(params[i])
      next if param.comptime  # comptime type params are not type-checked
      verify_param_lifetime!(arg_node, param, signature)

      if param.mutable
        if !arg_node.is_a?(AST::Identifier)
          error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_EXPRESSION, index: i+1, param: param.name)
        end

        if current_scope.is_immutable?(arg_node.name)
          emit_immutable_arg_error!(arg_node, current_scope, i + 1, param.name)
        end

        # Mark only the SymbolEntry as mutated-through-call. The callee receives a mutable reference
        # (CLEAR's MUTABLE-by-ref calling convention), so any mutation
        # inside the callee is observable at the caller's binding —
        # post-annotation passes like the GUARD MUTABLE-mutation check
        # (validate_with_guard_no_body_mutation!) need to see this.
        #
        # Critically, we mark only SymbolEntry state, not
        # decl_node.var_mutated. The declaration still should not count
        # as locally reassigned for lints, but lowering must emit Zig
        # `var` storage so the call site can pass `&binding` as `*T`.
        if arg_node.is_a?(AST::Identifier)
          mark_var_mutated_via_call(arg_node.name)
        end
      end

      is_give = arg_node.is_a?(AST::MoveNode)
      inner_node = is_give ? arg_node.value : arg_node
      if is_give && !param.takes
        error!(arg_node, :GIVE_TO_BORROW_PARAM, param: param.name)
      end
      if param.takes || is_give
        # Reject borrowed values passed to TAKES params.
        # Container index access (arr[i], map[key]) returns a borrow -
        # you cannot take ownership of data inside a container.
        # Use .remove(i) or COPY arr[i] instead.
        if borrowed_takes_argument?(inner_node)
          arg_ti = inner_node.full_type!(context: "TAKES index argument")
          arg_ti = Type.new(arg_ti) if arg_ti && !arg_ti.is_a?(Type)
          is_copy = arg_ti.is_a?(Type) ?
            (arg_ti.implicitly_copyable? { |t| lookup_type_schema(t) rescue nil } rescue true) :
            true
          unless is_copy
            if inner_node.is_a?(AST::GetIndex)
              error!(inner_node, :TAKES_NEEDS_OWNED_INDEX)
            else
              error!(inner_node, :TAKES_NEEDS_OWNED_BORROW)
            end
          end
        end

        # Ensure TAKES args are owned per the "one collection = one allocator"
        # policy. ensure_owned_value! handles each shape (list_collection
        # auto-COPY for @list/heap mismatch; rodata-string auto-COPY for
        # literal-at-use-site DEFAULT; named string Identifier raises
        # STORE_STRING_NEEDS_COPY when its source isn't heap-owned).
        # Pass the receiver's allocator so the auto-COPY uses the
        # container's allocator (frame list -> frame COPY, heap list ->
        # heap COPY).
        container_alloc = receiver_container_alloc(node) || :heap
        owned = ensure_owned_value!(inner_node, param.type, nil, container_alloc: container_alloc)
        node.args[i] = owned if owned
        # If the arg was an EXISTING CopyNode (user explicit COPY), inherit
        # the container's allocator -- a COPY into a frame list copies to
        # frame, not heap. Single source of truth: container decides.
        if node.args[i].is_a?(AST::CopyNode) && container_alloc != :heap
          node.args[i].alloc = container_alloc
        end

        # `is_give` already had visit_GiveNode set the :give action;
        # for plain TAKES (no GIVE wrapper) record :takes so the
        # USE_OF_MOVED_VALUE diagnostic can phrase "TOOK it away".
        # Stash the param's declared type on the OG node so the
        # use-after-move fix-dropdown can decide whether to offer an
        # `@shared` / `@multiowned` upgrade — irrelevant when the
        # consumer's parameter is plain affine and won't accept a
        # refcounted handle anyway.
        move_if_takes_ownership!(
          inner_node,
          action: is_give ? :give : :takes,
          consumer_param_type: param.type,
        )
        inner_node.was_moved = true
        arg_node.was_moved = true
        # If ensure_owned_value! wrapped the arg in a fresh CopyNode (auto-COPY
        # for TAKES), the new wrapper at node.args[i] must also carry was_moved
        # so the lowering can see "callee TAKES this on success" without
        # re-deriving from CopyNode/MoveNode syntax. Single source of truth.
        node.args[i].was_moved = true if node.args[i].respond_to?(:was_moved=)
      end

      # Weak refs must be RESOLVE'd before passing to concrete params.
      arg_ti = T.cast(arg_node, AST::Locatable).full_type!(context: "call argument")
      expected_raw = param.type
      if arg_ti&.link? && expected_raw != :Any
        param_type_obj = expected_raw.is_a?(Type) ? expected_raw : nil
        unless param_type_obj&.link?
          arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
          error!(arg_node, :LINK_NEEDS_RESOLVE_FOR_CALL, name: arg_name, param: param.name)
        end
      end

      expected = param.type
      actual = arg_node.resolved_type

      match = false

      # Case 0: fn_type structural check.
      # resolved_type only returns the return-type symbol for fn_types, so we
      # must compare the full Type objects to validate signature compatibility.
      expected_type_obj = expected.is_a?(Type) ? expected : Type.new(expected || :Any)
      if expected_type_obj.fn_type?
        actual_type_obj = T.cast(arg_node, AST::Locatable).full_type!(context: "fn-typed argument")
        if expected_type_obj.accepts?(actual_type_obj)
          match = true
        elsif actual_type_obj.fn_type? &&
              actual_type_obj.raw.reentrant && !expected_type_obj.raw.reentrant
          arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
          error!(arg_node, :REENTRANT_FN_TO_NON_REENTRANT_PARAM, name: arg_name, param: param.name)
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
      if !match && expected_type_obj.shared? && expected_type_obj.resolved == actual_type_obj.resolved
        unless actual_type_obj.shared?
          hint = if arg_node.is_a?(AST::Identifier)
            " Use SHARE #{arg_node.name} to create a shared handle."
          else
            " Use SHARE <expr> to create a shared handle."
          end
          error!(arg_node, :ARG_NEEDS_SHARED,
            index: i + 1, fn: node.name, expected: expected_type_obj, actual: actual_type_obj, hint: hint)
        end
        match = true
      end

      unless match
        if expected == :Any || actual == :Any || expected == actual
          match = true
        elsif any_element_collection_param?(expected_type_obj, actual_type_obj)
          match = true
        elsif expected_type_obj.respond_to?(:auto?) && expected_type_obj.auto?
          # Gradual-typing tolerance: param declared Auto. The
          # AutoUnifier (annotator's Pass C) resolves it from the
          # observed call-site arg types AFTER this body walk
          # completes; coercing the call-site arg here would commit
          # to a type the unifier hasn't picked yet. Treat as a
          # match for now; mismatch (if the resolution disagrees
          # with this arg's actual type) surfaces when the resolved
          # decl gets re-validated downstream.
          match = true
        elsif is_safe_autocast?(actual, expected)
          arg_node.coerced_type = expected
          check_prefixed_int_range!(arg_node, expected)
          match = true
        end
      end

      unless match
        arg_name = arg_node.respond_to?(:name) ? arg_node.name : "Expression"
        error!(arg_node, :ARGUMENT_TYPE_ERROR, fn: arg_name, index: i+1, expected: expected, got: actual)
      end

      current_path = get_path_to_root(arg_node)

      next if current_path.nil?
      is_mutable = param.mutable

      encountered_args.each_with_index do |prev, prev_index|
        # Mutable aliases conflict when their root paths overlap.
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

  sig { params(node: T.untyped).returns(T::Boolean) }
  def borrowed_takes_argument?(node)
    return true if node.respond_to?(:container_borrow) && node.container_borrow
    return true if node.is_a?(AST::GetIndex)
    return false unless node.is_a?(AST::GetField)

    root = AST.root_identifier(node)
    return false if root&.token&.type == :TYPE_ID
    sym = root&.symbol
    !!(sym && (sym.is_param || sym.reg))
  end

  sig { params(expected_type: Type, actual_type: Type).returns(T::Boolean) }
  def any_element_collection_param?(expected_type, actual_type)
    expected_elem = expected_type.element_type
    !!((expected_type.collection? || expected_type.dynamic?) && expected_elem&.any? && actual_type.collection?)
  end

  sig { params(arg_node: T.untyped, expected_type_obj: Type, param: AST::Param).returns(T::Boolean) }
  def atomic_cell_to_bare_value_param?(arg_node, expected_type_obj, param)
    T.bind(self, SemanticAnnotator) rescue nil
    return false unless arg_node.is_a?(AST::Identifier)
    sym = arg_node.symbol
    return false unless sym&.atomic?
    return false if sym.indirect?
    return false if param.atomic?
    return false if param.symbol&.atomic?
    return false if expected_type_obj.any? || expected_type_obj.fn_type?
    return false if expected_type_obj.shared? || expected_type_obj.any_sync?

    expected_type_obj.primitive?
  end

  sig { params(arg_node: T.untyped, param: AST::Param, signature: FunctionSignature).returns(T::Boolean) }
  def atomic_cell_to_atomic_param?(arg_node, param, signature)
    T.bind(self, SemanticAnnotator) rescue nil
    return false unless arg_node.is_a?(AST::Identifier)
    sym = arg_node.symbol
    return false unless sym&.atomic?
    ptype = param.type
    return true if ptype.is_a?(Type) && ptype.atomic?
    return true if param.atomic?
    return true if param.symbol&.atomic?

    requires = signature.requires
    families = requires && requires[param.name.to_s]
    families.respond_to?(:include?) && families.include?(:ATOMIC)
  end

  sig { params(arg_node: AST::Identifier).returns(T::Boolean) }
  def atomic_cell_arg?(arg_node)
    T.bind(self, SemanticAnnotator) rescue nil
    return false unless arg_node.is_a?(AST::Identifier)
    sym = arg_node.symbol
    sym&.atomic? && !sym.indirect?
  end

  sig { params(type: Type).returns(T.nilable(T::Boolean)) }
  def explicit_primitive_atomic_param?(type)
    T.bind(self, SemanticAnnotator) rescue nil
    type.atomic? && type.primitive?
  end

  sig { params(node: T.untyped, atomic_args: T::Array[T.untyped]).returns(T.nilable(T::Array[String])) }
  def warn_multi_atomic_bare_value_call!(node, atomic_args)
    T.bind(self, SemanticAnnotator) rescue nil
    unique_args = atomic_args.compact
    return if unique_args.length < 2

    names = unique_args.map { |arg| arg.respond_to?(:name) ? arg.name : "<expr>" }
    warning!(node,
      "Call to '#{node.name}' reads multiple atomic values independently " \
      "(#{names.join(', ')}). This is not a multi-object-consistent snapshot; " \
      "default mode allows it as ordinary atomic loads. STRICT/STRICT EXTREME " \
      "will require an explicit @inconsistent call-site annotation.")
  end

  sig { params(arg_node: T.untyped, param: AST::Param, signature: FunctionSignature).returns(T.nilable(T::Boolean)) }
  def verify_param_lifetime!(arg_node, param, signature)
    T.bind(self, SemanticAnnotator) rescue nil
    return true if !arg_node.is_a?(AST::Identifier)

    @og = T.let(@og, T.untyped)
    if param.mutable && !@og.can_write?(arg_node.name)
      error!(arg_node, :MUTABLE_ARG_RESTRICTED, name: arg_node.name)
    end

    lifetime_paths = signature.return_lifetime
    return true if lifetime_paths.empty?

    return true if current_scope.is_immutable?(arg_node.name) || current_scope.is_restricted?(arg_node.name)

    # If `param` is named in the lifetime sources (any of the multi-
    # binding entries), the caller is borrowing through that param's
    # lifetime; reject if the borrow is mutable but not RESTRICTed.
    # Wildcard accepts every param implicitly.
    base_paths = lifetime_paths.flat_map do |p|
      next [:wildcard] if p == :wildcard
      [p.to_s.split(".").first]
    end
    return true unless base_paths.include?(:wildcard) || base_paths.include?(param.name)

    error!(arg_node, :MUTABLE_PARAM_NEEDS_RESTRICT, name: param.name)
  end

  # `node.return_lifetime` shapes:
  #   nil                    -- no lifetime
  #   :wildcard              -- `RETURNS *:T` (lazy)
  #   Array<AST::Identifier|GetField>
  #                          -- `RETURNS foo:T` (one element) or
  #                             `RETURNS (a b c):T` (multi)
  sig { params(node: AST::FunctionDef).returns(T.nilable(T::Boolean)) }
  def verify_lifetime!(node)
    T.bind(self, SemanticAnnotator) rescue nil
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

    # A returned lifetime tied to a param cannot mix atomic and non-atomic
    # families because their runtime lifetime models differ.
    verify_no_mixed_atomic_returned_lifetime!(node, sources)
    true
  end

  # Mixed atomic/non-atomic returned lifetimes are ambiguous because the
  # returned value's runtime layout depends on the caller's family choice.
  sig { params(node: AST::FunctionDef, sources: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def verify_no_mixed_atomic_returned_lifetime!(node, sources)
    T.bind(self, SemanticAnnotator) rescue nil
    requires_map = node.respond_to?(:requires) ? (node.requires || {}) : {}
    return if requires_map.empty?

    sources.each do |source|
      path = T.must(get_path_to_root(source))
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

  sig { params(node: AST::FunctionDef, source_node: T.untyped).returns(T.nilable(T::Array[Symbol])) }
  def verify_lifetime_source!(node, source_node)
    T.bind(self, SemanticAnnotator) rescue nil
    path = get_path_to_root(source_node)
    root_param_name = T.must(path).first.to_s
    param = node.params.find { |p| p.name == root_param_name }

    if param.nil?
      error!(node, :LIFETIME_ROOT_NOT_PARAM, name: root_param_name)
    end

    # Extract the resolved type name (Type objects from parse_type_annotation)
    param_type = param.type
    current_type_name = param_type.is_a?(Type) ? param_type.resolved : param_type.to_sym

    T.must(path).drop(1).each do |field_sym|
      field_name = field_sym.to_s

      # Stop if we hit an Array index wildcard (we can't verify types past a dynamic index easily yet)
      break if field_sym == :*
      schema = current_scope.resolve_type_definition(current_type_name)

      if schema.nil?
        error!(node, :LIFETIME_NOT_A_STRUCT, type: current_type_name, field: field_name)
      end

      # Check if the field exists in the schema
      sf = schema.fields[field_name] || schema.fields[field_sym] # handle string/sym keys
      next_type = sf&.type

      if next_type.nil?
        error!(node, :LIFETIME_NO_FIELD, type: current_type_name, field: field_name)
      end

      # Advance to the next type name (Type objects carry the resolved name)
      current_type_name = next_type.is_a?(Type) ? next_type.resolved : next_type.to_sym
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Array[T::Hash[Symbol, T.untyped]])) }
  def declare_and_verify_params(node)
    T.bind(self, SemanticAnnotator) rescue nil
    node.params.each do |param|
      # Validate Defaults
      if param.default
        if param.default.is_a?(AST::DefaultLit)
          # DEFAULT is only valid for struct-type params
          param_type_sym = param.type&.resolved
          schema = lookup_type_schema(param_type_sym) if param_type_sym
          unless Schemas.struct?(schema)
            error!(node, :DEFAULT_NEEDS_STRUCT_PARAM, type: param.type)
          end
          # Validate all fields of the struct have defaults
          field_names = schema.fields.keys
          unless field_names.empty?
            field_defaults = schema.field_defaults || {}
            missing = field_names.reject { |f| field_defaults.key?(f) }
            if missing.any?
              error!(node, :DEFAULT_STRUCT_MISSING_DEFAULTS, name: param.name, type: param.type, missing: missing.join(', '))
            end
          end
          stamp_type!(param.default, param.type)
        else
          visit(param.default)
          def_type = param.default.resolved_type
          param_type = param.type
          unless is_safe_autocast?(def_type, param_type)
            error!(node, :DEFAULT_VALUE_TYPE_MISMATCH, name: param.name, expected: param_type, got: def_type)
          end
        end
      end

      # Seed sync for cross-module helpers where caller-sync propagation
      # cannot see call sites. Visible callers still override this later.
      param_sync = nil
      if param.sync
        param_sync = param.sync
      elsif param.type&.any_sync?
        param_sync = param.type.sync
      elsif node.respond_to?(:requires) && node.requires
        families = node.requires[param.name.to_s]
        if families
          # Polymorphic family seeds are only defaults; visible callers
          # override them during caller-sync propagation.
          sync_by_family = {
            LOCKED: :locked,
            VERSIONED: :versioned,
            ATOMIC: :atomic,
            SNAPSHOTTED: :versioned,
            LOCAL: :local,
          }
          family = sync_by_family.keys.find { |candidate| families.include?(candidate) }
          param_sync = sync_by_family[family] if family
        end
      end
      # Struct ATOMIC params are AtomicPtr cells; primitive ATOMIC params use
      # the bare-cell form.
      param_layout = nil
      if param_sync == :atomic
        param_t = param.type
        param_layout = :indirect if param_t.respond_to?(:struct?) && param_t.struct?
      end
      current_scope.declare(
        param.name, nil, param.type, param.mutable, false, nil, :stack,
        Set.new, [], sync: param_sync, layout: param_layout
      )
      # Stash the SymbolEntry on the Param so downstream passes don't
      # need to find an Identifier reference in the body.
      param.symbol = current_scope.locals[param.name]
      param.symbol.is_param = true
      param.symbol.param_decl_token = param.name_token
      # Preserve REQUIRES disjunctions for call-site effect resolution.
      if node.respond_to?(:requires) && node.requires
        fams = node.requires[param.name.to_s]
        param.symbol.sync_families = fams if fams.is_a?(Set) && !fams.empty?
      end
      # TAKES parameters own the data — force :affine so cleanup is emitted.
      current_scope.locals[param.name].takes = true if param.takes
      classify_ownership!(current_scope.locals[param.name])
      og_declare(param.name, nil, param.type)
      # Non-TAKES parameters are implicit borrows. Mark in OG so the
      # annotator prevents storing borrowed data into owned containers.
      unless param.takes
        @og[param.name]&.kind = :borrowed
      end
      param.type
    end
  end

  # Cannot be part of declare, needs to happen in outer-scope
  sig { params(node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def verify_captures!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      cap_name = cap.name

      if cap.default
        error!(node, :CAPTURE_NO_DEFAULT, name: cap_name)
      end

      if !current_scope.locals.key?(cap_name)
        # Check if it's in a higher scope
        owner_scope = lookup_scope_for(cap_name)
        if owner_scope.nil?
           error!(node, :CAPTURE_UNDEFINED_VAR, name: cap_name)
           next
        end
      else
        # Local capture
        owner_scope = current_scope
      end

      entry = owner_scope.locals[cap_name]

      if cap.mutable && !entry.mutable
        emit_capture_immutable_as_mutable_error!(node, cap_name, owner_scope)
      end

      # Mark the captured variable as used in its declaring scope.
      owner_scope.mark_read(cap_name)

      # Enrich the capture node with the resolved type
      cap.type = entry.type
      cap.storage = entry.storage
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def declare_captures(node)
    T.bind(self, SemanticAnnotator) rescue nil
    return if node.captures.nil? || node.captures.empty?

    node.captures.each do |cap|
      current_scope.declare(
        cap.name,
        nil,
        cap.type,
        cap.mutable,
        false,
        nil,
        cap.storage
      )
    end
  end

  sig { params(node: T.untyped, found_returns: T::Array[T::Hash[Symbol, T.nilable(Symbol)]], declared_return: T.nilable(Type)).void }
  def verify_returns(node, found_returns, declared_return)
    T.bind(self, SemanticAnnotator) rescue nil
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

  sig { params(return_type: T.untyped).returns(Symbol) }
  def get_return_strategy(return_type)
    T.bind(self, SemanticAnnotator) rescue nil
    type = Type.new(return_type)

    if !type.requires_move? || type.heap?
      return :register
    elsif type.void?
      return :void
    else
      # Structs, Fixed Arrays, etc.
      return :destination_pass
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Boolean)) }
  def verify_return(node)
    T.bind(self, SemanticAnnotator) rescue nil
    # A returned value is a borrow when it is a direct indexed/field access OR
    # a variable that the ownership graph marked as :borrowed.
    return true unless return_is_borrow?(node)

    # Union variant constructors (Value.Nil, Shape.Point) create new values, not borrows.
    if node.is_a?(AST::GetField) && node.target.is_a?(AST::Identifier)
      schema = lookup_type_schema(node.target.name.to_sym) rescue nil
      return true if (Schemas.union?(schema) || Schemas.enum?(schema))
    end

    lifetime_paths = current_fn_ctx.lifetime
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
      error!(node, :RETURN_LIFETIME_NOT_ASSOCIATED, sources: lifetime_paths.join(', '))
    end

    # Multi-source semantics: returned value derives from EXACTLY one
    # of the declared sources (it cannot simultaneously originate from
    # two distinct parameters). Accept iff `actual_path` has any
    # declared source as its prefix; reject with a clear "expected one
    # of: ..." diagnostic when none match.
    matched = lifetime_paths.any? do |p|
      lifetime_syms = p.split(".").map(&:to_sym)
      T.must(actual_path)[0...lifetime_syms.size] == lifetime_syms
    end

    unless matched
      sources_msg = lifetime_paths.size == 1 ?
        "derived from: #{lifetime_paths.first}" :
        "derived from one of: #{lifetime_paths.join(' | ')}"
      error!(node, :RETURN_LIFETIME_MISMATCH,
        sources_msg: sources_msg, actual: T.must(actual_path).join('.'))
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def return_is_borrow?(node)
    T.bind(self, SemanticAnnotator) rescue nil
    if node.is_a?(AST::Identifier)
      return false unless @og[node.name]&.kind == :borrowed
      # Parameters (reg=nil) and MATCH bindings (reg=nil) are safe to return —
      # the caller controls their lifetime. Only flag variables explicitly assigned
      # from a collection index borrow (BindExpr with container_borrow=true).
      scope = lookup_scope_for(node.name)
      reg = scope&.locals&.[](node.name)&.reg
      return reg&.container_borrow == true
    end
    return true if node.is_a?(AST::GetIndex)
    return true if node.is_a?(AST::GetField)
    false
  end

  sig { params(path_a: T::Array[Symbol], path_b: T::Array[Symbol]).returns(T::Boolean) }
  def paths_overlap?(path_a, path_b)
    T.bind(self, SemanticAnnotator) rescue nil
    return false if path_a.first != path_b.first

    len = [path_a.size, path_b.size].min
    return path_a[0...len] == path_b[0...len]
  end

  # Finds the first intrinsic overload that matches the given arguments.
  # Returns nil if no overload matches.
  # Maps `:reject_when` symbol values to a predicate over a CLEAR Type.
  # Add new entries here when std_lib.rb introduces a new "this overload
  # doesn't make sense for type-shape X" guard. Each predicate receives
  # the receiver's resolved Type; returning true rejects the call.
  REJECT_TYPE_PREDICATES = T.let({
    unsigned_integer: ->(t) { t.respond_to?(:unsigned_integer?) && t.unsigned_integer? },
  }.freeze, T::Hash[Symbol, Proc])

  sig { params(arg: T.untyped, kind: Symbol).returns(T::Boolean) }
  def reject_arg_type_matches?(arg, kind)
    T.bind(self, SemanticAnnotator) rescue nil
    pred = REJECT_TYPE_PREDICATES[kind]
    return false unless pred
    type = arg.full_type!(context: "intrinsic reject argument")
    return false unless type.is_a?(Type)
    pred.call(type)
  end

  sig { params(definitions: T::Array[T.untyped], args: T::Array[T.untyped]).returns(T.untyped) }
  def find_matching_intrinsic(definitions, args)
    T.bind(self, SemanticAnnotator) rescue nil
    matched = definitions.find do |config|
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
          arg_type = arg.full_type!(context: "intrinsic capability argument")
          next false if spec[:sync] && arg_type&.sync != spec[:sync]
          next false if spec[:ownership] && arg_type&.ownership != spec[:ownership]
          true
        else
          is_safe_autocast?(arg.resolved_type, spec)
        end
      end
    end
    matched && IntrinsicRegistry.fs(matched)
  end

  # Formats intrinsic args for error messages
  sig { params(args: T::Array[T.untyped]).returns(String) }
  def format_intrinsic_args(args)
    T.bind(self, SemanticAnnotator) rescue nil
    return "(varargs)" if args == :Varargs
    types = args.map { |a| a.is_a?(Hash) ? a[:type] : a }
    "(#{types.join(', ')})"
  end
end
