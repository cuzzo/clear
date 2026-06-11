# typed: strict
require "sorbet-runtime"
require_relative "../../ast/ast"

module FunctionAnalysis
    extend T::Sig
    extend T::Helpers

  requires_ancestor { SemanticAnnotator }

  RoutineNode = T.type_alias { T.any(AST::FunctionDef, AST::LambdaLit) }

  class CallSignatureSite < T::Struct
    extend T::Sig

    const :node, Object
    const :name, String
    prop :args, T::Array[AST::Locatable]

    sig { params(signature: FunctionSignature).void }
    def assign_signature!(signature)
      T.unsafe(node).matched_signature = signature if node.respond_to?(:matched_signature=)
    end

    sig { params(arg: AST::Locatable).void }
    def append_arg!(arg)
      args << arg
    end

    sig { params(index: Integer, arg: AST::Locatable).void }
    def replace_arg!(index, arg)
      args[index] = arg
    end
  end

  class CallArityPlan < T::Struct
    extend T::Sig

    const :site, CallSignatureSite
    const :params, T::Array[AST::Param]
    const :min_args, Integer
    const :max_args, Integer
    const :given_args, Integer

    sig { returns(T::Boolean) }
    def mismatch?
      given_args < min_args || given_args > max_args
    end

    sig { returns(T::Boolean) }
    def exact?
      min_args == max_args
    end

    sig { returns(T::Array[AST::Param]) }
    def injectable_defaults
      return [] unless given_args < max_args

      slice = params[given_args...max_args]
      return [] unless slice

      slice.reject(&:required)
    end
  end

  class CallArgumentFacts < T::Struct
    const :site, CallSignatureSite
    const :index, Integer
    const :param, AST::Param
    const :arg_node, AST::Locatable
    const :is_give, T::Boolean
    const :inner_node, AST::Locatable
    const :arg_type, Type
    const :expected_type, Type
    const :actual_type, Type
    const :actual, T.nilable(Symbol)
    const :path, T.nilable(T::Array[Symbol])
  end

  class EncounteredCallArgument < T::Struct
    const :path, T::Array[Symbol]
    const :mutable, T::Boolean
    const :name, String
  end

  # Analyze a function or lambda body: enter scope, declare params/captures,
  # visit all statements, finalize scope, and resolve the return type.
  sig { params(node: RoutineNode, body: T.untyped, declared_return: T.untyped, is_implicit: T::Boolean).returns(T.nilable(Symbol)) }
  def analyze_routine(node, body, declared_return, is_implicit)
    T.bind(self, SemanticAnnotator) rescue nil
    verify_captures!(node)

    found_returns = collect_routine_returns do
      with_routine_analysis_scope(node) do
        declare_and_verify_params(node)
        declare_captures(node)

        # PRE clauses run at function entry -- visit them with parameters in
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
      end
    end

    verify_returns(node, found_returns, is_implicit ? nil : declared_return)

    # Resolve return type (infer if implicit or :Any)
    return_type = if body.is_a?(Array)
      found_returns.any? ? T.must(found_returns.first).type : :Any
    else
      body.resolved_type
    end

    # Update return type if we can narrow it
    if (is_implicit || declared_return == :Any) && found_returns.any?
      inferred = T.must(found_returns.first).type
      if is_implicit || found_returns.size == 1
        return_type = inferred
      end
    end

    return_type
  end

  sig { params(node: RoutineNode, blk: T.proc.void).void }
  def with_routine_analysis_scope(node, &blk)
    T.bind(self, SemanticAnnotator) rescue nil

    with_new_scope do
      og_push_scope
      begin
        blk.call
        finalize_scope(node)
      ensure
        og_pop_scope(archive: true)
      end
    end
  end
  private :with_routine_analysis_scope

  sig { params(blk: T.proc.void).returns(T::Array[AST::ReturnFact]) }
  def collect_routine_returns(&blk)
    T.bind(self, SemanticAnnotator) rescue nil

    # Save and reset returns on the current FunctionContext (supports nested lambdas).
    fn_ctx = current_fn_ctx
    saved_returns = fn_ctx&.returns
    fn_ctx.returns = [] if fn_ctx

    blk.call
    found_returns = T.let((current_fn_ctx&.returns || []).uniq, T::Array[AST::ReturnFact])

    # Restore saved returns (for enclosing function/lambda).
    restore_ctx = current_fn_ctx
    restore_ctx.returns = saved_returns if restore_ctx && saved_returns
    found_returns
  end
  private :collect_routine_returns

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

  sig { params(node: AST::LambdaLit).returns(T.nilable(FunctionSignature)) }
  def visit_LambdaLit(node)
    T.bind(self, SemanticAnnotator) rescue nil
    return_type = with_body_fact_nested_body do
      analyze_routine(node, node.body, :Any, true)
    end

    stamp_type!(node, build_lambda_signature(node.params, T.cast(return_type, Symbol)))
  end

  sig { params(node: AST::FunctionDef).returns(T.nilable(FunctionContext)) }
  def visit_FunctionDef(node)
    T.bind(self, SemanticAnnotator) rescue nil
    effects_begin_function(node.name)

    is_implicit_return = node.implicit_return_type?
    node.type_params = infer_implicit_type_params(node) if node.respond_to?(:type_params=)
    declared_return = node.annotation_return_type
    lifetime_paths = get_lifetime_paths(node)
    fn_type_params = (node.type_params || []).map(&:to_sym)
    fn_ctx = FunctionContext.new(
      name: node.name, return_type: node.annotation_return_type,
      lifetime: lifetime_paths, type_params: fn_type_params
    )
    push_function_context!(fn_ctx)
    begin
      has_mutable_param = node.params.any? { |p| p.mutable }
      if has_mutable_param && !node.name.end_with?("!")
        emit_style_mutable_param_needs_bang!(node)
      end
      verify_lifetime!(node)

      validate_type_param_list!(node, node.type_params, "function") if fn_type_params.any?

      node.params.each { |p| validate_type_annotation!(node, p.type, is_param: true) if p.type }
      validate_type_annotation!(node, node.return_type) if node.return_type

      signature = FunctionSignature.new(
        params: node.params.map { |p| AST::Param.new(
          name: p.name, type: p.type, required: p.default.nil?,
          default: p.default, mutable: p.mutable, takes: p.takes,
          sync: p.type.any_sync? ? p.type.sync : nil
        )},
        return_type: node.annotation_return_type, return_lifetime: lifetime_paths,
        visibility: node.visibility,
        type_params: fn_type_params.any? ? fn_type_params : nil,
        reentrant: node.reentrant == :reentrant
      )
      signature.requires = node.requires
      current_scope.declare(node.name, nil, signature, false, false, nil, :static)

      register_function_node!(node)
      body_identity = body_identity_for_function(node.name)
      node.semantic_with_blocks = []

      final_return_type = T.let(nil, T.nilable(Symbol))
      body_scan = with_body_fact_frame(body_identity) do
        final_return_type = analyze_routine(node, node.body, declared_return, is_implicit_return)
      end
      called_names = body_scan.callees
      has_fnptr = body_scan.has_fnptr_call
      unabsorbed_calls = body_scan.propagating_callees
      raises_in_body = body_scan.raises_directly
      directly_recursive = called_names.include?(node.name)
      fn_ctx.mark_runtime_used! if has_fnptr
      offer_plain_reentrant_variant_fix!(node, body_scan)
      route_thunk_to_tail_call_compat!(node, body_scan)

      if directly_recursive
        record_effect(EffectTracker::REENTRANT)
        case node.reentrant
        when :non_reentrant
          unless [:reentrant_not_logical, :reentrant_max_depth].include?(node.reentrance_kind)
            emit_reentrant_error!(node, :REENTRANCE_DIRECT_RECURSIVE)
          end
        when nil
          emit_reentrant_error!(node, :REENTRANCE_INDIRECT_RECURSIVE)
        end

        validate_tail_call!(node, body_scan) if node.tail_call

        if node.reentrance_kind == :reentrant_thunk && !node.tail_call
          plan = ThunkTransform::RecursiveSplitter.split(node.body, node.name, self)
          if plan
            node.thunk_plan = plan
          else
            error!(node, :REENTRANCE_THUNK_NON_TAIL,
              name: node.name)
          end
        end
      elsif node.tail_call
        error!(node, :REENTRANCE_TAIL_CALL_NOT_RECURSIVE,
          name: node.name)
      elsif node.reentrance_kind == :reentrant_thunk
        # Mutual :THUNK validation runs after the complete call graph exists.
      end

      resolved_return_type = T.must(final_return_type)
      if (is_implicit_return || declared_return == :Any)
        node.return_type = resolved_return_type
        signature.return_type = resolved_return_type
      end

      signature.return_strategy = get_return_strategy(signature.return_type)
      stamp_type!(node, signature)
      ctx = fn_ctx
      node.uses_frame = (ctx.frame_count > 0)
      node.uses_heap  = (ctx.heap_count > 0)
      node.uses_alloc = (ctx.alloc_count > 0)
      node.uses_rt    = ctx.uses_rt
      node.stack_vars_bytes = ctx.stack_vars_bytes
      raises_directly =
        has_fnptr ||
        (node.reentrant == :non_reentrant) ||
        function_has_pre_clauses?(node) ||
        raises_in_body == true
      record_function_body_summary!(Annotator::Phases::FunctionBodySummary.new(
        name: node.name,
        definition_id: body_identity.definition_id,
        body_id: body_identity.body_id,
        callees: called_names - [node.name],
        propagating_callees: (unabsorbed_calls || called_names) - [node.name],
        has_fnptr_call: has_fnptr,
        raises_directly: raises_directly,
        call_site_facts: body_scan.call_site_facts,
        local_facts: body_scan.local_facts,
        return_nodes: body_scan.return_nodes,
        binding_nodes: body_scan.binding_nodes,
        assignment_nodes: body_scan.assignment_nodes,
        escape_nodes: body_scan.escape_nodes,
        with_scope_nodes: body_scan.with_scope_nodes,
        with_blocks: body_scan.with_blocks,
        suspend_points: body_scan.suspend_points
      ))
      fn_ctx.mark_runtime_used! if runtime_error_clause?(node)

      if function_has_catch_clauses?(node)
        candidate_snap_types = body_scan.pipe_input_types
        snap_types = T.let(Set.new, T::Set[String])
        all_catch_bodies = node.catch_clauses.map { |c| c.body }
        all_catch_bodies << node.default_catch if function_has_default_catch?(node)
        catch_body_scan = with_body_fact_frame(Semantic::BodyIdentity.unassigned) do
          all_catch_bodies.compact.each do |clause_body|
            with_new_scope do
              current_scope.declare("__error", nil, :ErrorContext, false, false, nil, :stack)
              if candidate_snap_types.size == 1
                current_scope.declare("snapshot", nil, T.must(candidate_snap_types.first).to_sym, false, false, nil, :stack)
              end
              visit_stmts(clause_body)
            end
          end
        end
        snap_types.merge(candidate_snap_types) if catch_body_scan.references_snapshot
        node.snapshot_types = snap_types
      end
      nil
    ensure
      pop_function_context!
    end
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
    fn_nodes = function_node_map
      emit_typo_suggestion!(
        node.token, func_name, fn_nodes.keys,
        "Undefined function '#{func_name}'",
        "closest declared function"
      )
      return
    end

    func_type = scope.resolve_type(func_name)
    entry = scope.resolve_entry(func_name)
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
        fn_ctx = current_fn_ctx
        if alloc_kind && fn_ctx
          if alloc_kind == :heap
            fn_ctx.record_heap_use!
          else
            fn_ctx.record_frame_use!
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
      zig_pattern: config.intrinsic_pattern
    )
  end

  # Single point: what allocator does the receiver/container of this call use?
  # For MethodCall on a list/struct/etc, the receiver's binding storage tells
  # us the container allocator -- auto-COPY into this container must produce
  # values in this allocator (per "one collection = one allocator").
  # Returns nil when the call has no container context (plain function call,
  # or receiver storage not yet determined).
  sig { params(node: Object).returns(T.nilable(Symbol)) }
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

  sig { params(node: Object, signature: FunctionSignature).returns(NilClass) }
  def verify_function_signature!(node, signature)
    T.bind(self, SemanticAnnotator) rescue nil
    site = call_signature_site(node)
    site.assign_signature!(signature)
    plan = call_arity_plan(site, signature)
    verify_call_arity!(plan)
    inject_default_arguments!(plan)

    encountered_args = T.let([], T::Array[EncounteredCallArgument])
    atomic_bare_value_args = T.let([], T::Array[AST::Locatable])

    site.args.each_with_index do |arg_node, i|
      param = T.must(signature.params[i])
      next if param.comptime

      facts = call_argument_facts(site, param, arg_node, i)
      verify_param_lifetime!(facts.arg_node, facts.param, signature)
      verify_mutable_argument!(facts)
      verify_takes_argument!(facts)
      verify_link_argument!(facts)
      verify_argument_type!(facts, signature, atomic_bare_value_args)
      verify_argument_aliases!(facts, encountered_args)
    end

    warn_multi_atomic_bare_value_call!(site.node, atomic_bare_value_args)
    nil
  end

  sig { params(node: Object).returns(CallSignatureSite) }
  def call_signature_site(node)
    CallSignatureSite.new(
      node: node,
      name: T.unsafe(node).name.to_s,
      args: T.cast(T.unsafe(node).args, T::Array[AST::Locatable]),
    )
  end

  sig { params(site: CallSignatureSite, signature: FunctionSignature).returns(CallArityPlan) }
  def call_arity_plan(site, signature)
    params = signature.params
    CallArityPlan.new(
      site: site,
      params: params,
      min_args: params.count(&:required),
      max_args: params.size,
      given_args: site.args.size,
    )
  end

  sig { params(plan: CallArityPlan).void }
  def verify_call_arity!(plan)
    T.bind(self, SemanticAnnotator)
    return unless plan.mismatch?

    if plan.exact?
      error!(plan.site.node, :ARITY_MISMATCH,
        name: plan.site.name, expected: plan.min_args, got: plan.given_args)
    else
      error!(plan.site.node, :ARITY_MISMATCH_RANGE,
        name: plan.site.name, min: plan.min_args, max: plan.max_args, got: plan.given_args)
    end
  end

  sig { params(plan: CallArityPlan).void }
  def inject_default_arguments!(plan)
    T.bind(self, SemanticAnnotator)
    plan.injectable_defaults.each do |param|
      injected = default_argument_for(param)
      visit(injected)
      plan.site.append_arg!(injected)
    end
  end

  sig { params(param: AST::Param).returns(AST::Locatable) }
  def default_argument_for(param)
    default = param.default
    if default.is_a?(AST::DefaultLit)
      return AST::StructLit.new(default.token, param.type.to_s, {}, nil)
    end

    T.cast(default.dup, AST::Locatable)
  end

  sig do
    params(
      site: CallSignatureSite,
      param: AST::Param,
      arg_node: AST::Locatable,
      index: Integer,
    ).returns(CallArgumentFacts)
  end
  def call_argument_facts(site, param, arg_node, index)
    T.bind(self, SemanticAnnotator)
    is_give = arg_node.is_a?(AST::MoveNode)
    inner_node = is_give ? T.cast(T.unsafe(arg_node).value, AST::Locatable) : arg_node
    arg_type = arg_node.full_type!(context: "call argument")
    actual = arg_node.resolved_type
    CallArgumentFacts.new(
      site: site,
      index: index,
      param: param,
      arg_node: arg_node,
      is_give: is_give,
      inner_node: inner_node,
      arg_type: arg_type,
      expected_type: param.type,
      actual_type: arg_type,
      actual: actual,
      path: get_path_to_root(arg_node),
    )
  end

  sig { params(facts: CallArgumentFacts).void }
  def verify_mutable_argument!(facts)
    T.bind(self, SemanticAnnotator)
    return unless param_mutable?(facts.param)

    arg_node = facts.arg_node
    unless arg_node.is_a?(AST::Identifier)
      error!(arg_node, :IMMUTABLE_ARG_PASSED_AS_EXPRESSION,
        index: facts.index + 1, param: facts.param.name)
      return
    end

    if current_scope.is_immutable?(arg_node.name)
      emit_immutable_arg_error!(arg_node, current_scope, facts.index + 1, facts.param.name)
    end

    mark_var_mutated_via_call(arg_node.name)
  end

  sig { params(facts: CallArgumentFacts).void }
  def verify_takes_argument!(facts)
    T.bind(self, SemanticAnnotator)
    if facts.is_give && !facts.param.takes
      error!(facts.arg_node, :GIVE_TO_BORROW_PARAM, param: facts.param.name)
    end
    return unless facts.param.takes || facts.is_give

    verify_owned_takes_argument!(facts)
    container_alloc = receiver_container_alloc(facts.site.node) || :heap
    owned = ensure_owned_value!(facts.inner_node, facts.param.type, nil, container_alloc: container_alloc)
    facts.site.replace_arg!(facts.index, owned) if owned
    current_arg = facts.site.args[facts.index]
    current_arg.alloc = container_alloc if current_arg.is_a?(AST::CopyNode) && container_alloc != :heap
    move_if_takes_ownership!(
      facts.inner_node,
      action: facts.is_give ? :give : :takes,
      consumer_param_type: facts.param.type,
    )
    facts.inner_node.was_moved = true
    facts.arg_node.was_moved = true
    T.unsafe(current_arg).was_moved = true if current_arg.respond_to?(:was_moved=)
  end

  sig { params(facts: CallArgumentFacts).void }
  def verify_owned_takes_argument!(facts)
    T.bind(self, SemanticAnnotator)
    return unless borrowed_takes_argument?(facts.inner_node)

    arg_ti = facts.inner_node.full_type!(context: "TAKES index argument")
    return if arg_ti.implicitly_copyable? { |type| lookup_type_schema(type) }

    if facts.inner_node.is_a?(AST::GetIndex)
      error!(facts.inner_node, :TAKES_NEEDS_OWNED_INDEX)
    else
      error!(facts.inner_node, :TAKES_NEEDS_OWNED_BORROW)
    end
  end

  sig { params(facts: CallArgumentFacts).void }
  def verify_link_argument!(facts)
    T.bind(self, SemanticAnnotator)
    return unless facts.arg_type.link?
    return if facts.expected_type.any? || facts.expected_type.link?

    error!(facts.arg_node, :LINK_NEEDS_RESOLVE_FOR_CALL,
      name: argument_name(facts.arg_node, fallback: "Expression"), param: facts.param.name)
  end

  sig { params(facts: CallArgumentFacts, signature: FunctionSignature, atomic_bare_value_args: T::Array[AST::Locatable]).void }
  def verify_argument_type!(facts, signature, atomic_bare_value_args)
    T.bind(self, SemanticAnnotator)
    match = fn_type_argument_match?(facts)
    verify_atomic_argument!(facts, signature, atomic_bare_value_args)
    match = true if shared_argument_match?(facts, matched: match)
    match = true if basic_argument_match?(facts)
    return if match

    error!(facts.arg_node, :ARGUMENT_TYPE_ERROR,
      fn: argument_name(facts.arg_node, fallback: "Expression"),
      index: facts.index + 1, expected: facts.expected_type, got: facts.actual)
  end

  sig { params(facts: CallArgumentFacts).returns(T::Boolean) }
  def fn_type_argument_match?(facts)
    T.bind(self, SemanticAnnotator)
    return false unless facts.expected_type.fn_type?

    actual_type = facts.arg_node.full_type!(context: "fn-typed argument")
    return true if facts.expected_type.accepts?(actual_type)
    return false unless reentrant_fn_argument_rejected?(facts.expected_type, actual_type)

    error!(facts.arg_node, :REENTRANT_FN_TO_NON_REENTRANT_PARAM,
      name: argument_name(facts.arg_node, fallback: "Expression"), param: facts.param.name)
  end

  sig { params(expected_type: Type, actual_type: Type).returns(T::Boolean) }
  def reentrant_fn_argument_rejected?(expected_type, actual_type)
    return false unless actual_type.fn_type?

    actual_sig = actual_type.function_signature
    expected_sig = expected_type.function_signature
    !!(actual_sig&.reentrant && expected_sig && !expected_sig.reentrant)
  end

  sig { params(facts: CallArgumentFacts, signature: FunctionSignature, atomic_bare_value_args: T::Array[AST::Locatable]).void }
  def verify_atomic_argument!(facts, signature, atomic_bare_value_args)
    T.bind(self, SemanticAnnotator)
    arg_node = facts.arg_node
    if explicit_primitive_atomic_param?(facts.expected_type)
      unless arg_node.is_a?(AST::Identifier) && atomic_cell_arg?(arg_node)
        error!(arg_node, :ARG_NEEDS_ATOMIC_CELL,
          index: facts.index + 1, fn: facts.site.name, expected: facts.expected_type.resolved,
          name: argument_name(arg_node, fallback: "Expression"), actual: facts.actual_type.resolved)
      end
      T.unsafe(arg_node).atomic_borrow = true if arg_node.respond_to?(:atomic_borrow=)
    end
    atomic_bare_value_args << arg_node if atomic_cell_to_bare_value_param?(arg_node, facts.expected_type, facts.param)
    if atomic_cell_to_atomic_param?(arg_node, facts.param, signature)
      T.unsafe(arg_node).atomic_borrow = true if arg_node.respond_to?(:atomic_borrow=)
    end
  end

  sig { params(facts: CallArgumentFacts, matched: T::Boolean).returns(T::Boolean) }
  def shared_argument_match?(facts, matched:)
    T.bind(self, SemanticAnnotator)
    return false if matched
    return false unless facts.expected_type.shared? && facts.expected_type.resolved == facts.actual_type.resolved

    arg_node = facts.arg_node
    unless facts.actual_type.shared?
      hint = arg_node.is_a?(AST::Identifier) ? " Use SHARE #{arg_node.name} to create a shared handle." : " Use SHARE <expr> to create a shared handle."
      error!(arg_node, :ARG_NEEDS_SHARED,
        index: facts.index + 1, fn: facts.site.name,
        expected: facts.expected_type, actual: facts.actual_type, hint: hint)
    end
    true
  end

  sig { params(facts: CallArgumentFacts).returns(T::Boolean) }
  def basic_argument_match?(facts)
    T.bind(self, SemanticAnnotator)
    return true if facts.expected_type.any? || facts.actual == :Any || facts.expected_type == facts.actual
    return true if any_element_collection_param?(facts.expected_type, facts.actual_type)
    return true if facts.expected_type.auto?
    return false unless is_safe_autocast?(facts.actual, facts.expected_type)

    facts.arg_node.coerced_type = facts.expected_type
    check_prefixed_int_range!(facts.arg_node, facts.expected_type)
    true
  end

  sig { params(facts: CallArgumentFacts, encountered_args: T::Array[EncounteredCallArgument]).void }
  def verify_argument_aliases!(facts, encountered_args)
    T.bind(self, SemanticAnnotator)
    current_path = facts.path
    return if current_path.nil?

    encountered_args.each_with_index do |prev, prev_index|
      next unless (param_mutable?(facts.param) || prev.mutable) && paths_overlap?(current_path, prev.path)

      error!(facts.arg_node, :ARG_ALIAS_CONFLICT,
        index: facts.index + 1,
        name: argument_name(facts.arg_node, fallback: "arg"),
        other_index: prev_index + 1,
        path: T.must(current_path.first))
    end

    encountered_args << EncounteredCallArgument.new(
      path: current_path,
      mutable: param_mutable?(facts.param),
      name: argument_name(facts.arg_node, fallback: "arg"),
    )
  end

  sig { params(node: AST::Locatable, fallback: String).returns(String) }
  def argument_name(node, fallback:)
    node.respond_to?(:name) ? T.unsafe(node).name.to_s : fallback
  end

  sig { params(param: AST::Param).returns(T::Boolean) }
  def param_mutable?(param)
    !!param.mutable
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def borrowed_takes_argument?(node)
    AST.borrowed_ownership_view?(node)
  end

  sig { params(expected_type: Type, actual_type: Type).returns(T::Boolean) }
  def any_element_collection_param?(expected_type, actual_type)
    expected_elem = expected_type.element_type
    expected_accepts_any_element = (expected_type.collection_value? || expected_type.dynamic?) && expected_elem&.any?
    actual_is_collection_like = actual_type.collection_value? || actual_type.runtime_stream?
    !!(expected_accepts_any_element && actual_is_collection_like)
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

    signature.requires.fetch(param.name.to_s, Set.new).include?(:ATOMIC)
  end

  sig { params(arg_node: AST::Identifier).returns(T::Boolean) }
  def atomic_cell_arg?(arg_node)
    T.bind(self, SemanticAnnotator) rescue nil
    sym = arg_node.symbol
    !!(sym&.atomic? && !sym.indirect?)
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

    if param.mutable && !ownership_graph.can_write?(arg_node.name)
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
      if sf.nil?
        error!(node, :LIFETIME_NO_FIELD, type: current_type_name, field: field_name)
      end

      # Advance to the next type name (Type objects carry the resolved name)
      current_type_name = sf.type.resolved
    end
  end

  sig { params(node: RoutineNode).void }
  def declare_and_verify_params(node)
    T.bind(self, SemanticAnnotator) rescue nil
    requires_map = T.let(node.is_a?(AST::FunctionDef) ? node.requires : nil, T.nilable(T::Hash[String, T::Set[Symbol]]))
    node.params.each do |param|
      # Validate Defaults
      if param.default
        if param.default.is_a?(AST::DefaultLit)
          # DEFAULT is only valid for struct-type params
          param_type_sym = param.type.resolved
          schema = lookup_type_schema(param_type_sym)
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
      elsif param.type.any_sync?
        param_sync = param.type.sync
      elsif requires_map
        families = requires_map[param.name.to_s]
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
      param.symbol = current_scope.local_entry!(param.name)
      param.symbol.is_param = true
      param.symbol.param_decl_token = param.name_token
      # Preserve REQUIRES disjunctions for call-site effect resolution.
      if requires_map
        fams = requires_map[param.name.to_s]
        param.symbol.sync_families = fams if fams.is_a?(Set) && !fams.empty?
      end
      # TAKES parameters own the data — force :affine so cleanup is emitted.
      current_scope.local_entry!(param.name).takes = true if param.takes
      classify_ownership!(current_scope.local_entry!(param.name))
      og_declare(param.name, nil, param.type)
      # Non-TAKES parameters are implicit borrows. Mark in OG so the
      # annotator prevents storing borrowed data into owned containers.
      unless param.takes
        ownership_graph[param.name]&.kind = :borrowed
      end
      param.type
    end
    nil
  end

  # Cannot be part of declare, needs to happen in outer-scope
  sig { params(node: RoutineNode).void }
  def verify_captures!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    captures = node.captures
    return if captures.nil? || captures.empty?

    captures.each do |cap|
      cap_name = cap.name

      if cap.default
        error!(node, :CAPTURE_NO_DEFAULT, name: cap_name)
      end

      if !current_scope.entry?(cap_name)
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

      entry = owner_scope.entry_for_write!(cap_name)

      if cap.mutable && !entry.mutable && node.is_a?(AST::FunctionDef)
        emit_capture_immutable_as_mutable_error!(node, cap_name, owner_scope)
      end

      # Mark the captured variable as used in its declaring scope.
      owner_scope.mark_read(cap_name)

      # Enrich the capture node with the resolved type
      cap.type = entry.type
      cap.storage = entry.storage
    end
    nil
  end

  sig { params(node: RoutineNode).void }
  def declare_captures(node)
    T.bind(self, SemanticAnnotator) rescue nil
    captures = node.captures
    return if captures.nil? || captures.empty?

    captures.each do |cap|
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
    nil
  end

  sig { params(node: RoutineNode, found_returns: T::Array[AST::ReturnFact], declared_return: T.nilable(Type)).void }
  def verify_returns(node, found_returns, declared_return)
    T.bind(self, SemanticAnnotator) rescue nil
    if found_returns.size > 1
      return if declared_return&.any?

      if declared_return
        return if found_returns.all? { |r| declared_return.accepts?(Type.new(r.type)) }
      end

      # Normalize: all string-like types (Byte[N], String) → String for comparison
      normalized = found_returns.map { |r|
        t = r.type.to_s
        (t.start_with?("Byte[") || t == "String") ? :String : r.type
      }.uniq.size
      if normalized > 1
        emit_ambiguous_return_error!(node, found_returns) if node.is_a?(AST::FunctionDef)
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
      schema = lookup_type_schema(node.target.name.to_sym)
      return true if (Schemas.union?(schema) || Schemas.enum?(schema))
    end

    lifetime_paths = current_fn_ctx!.lifetime
    type_info = node.type_object
    has_lifetime = !lifetime_paths.empty?
    is_wildcard = lifetime_paths == [:wildcard]
    schema_resolver = ->(t) { lookup_type_schema(t) }
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
    unless actual_path
      error!(node, :RETURN_LIFETIME_NOT_ASSOCIATED, sources: lifetime_paths.join(', '))
      return
    end

    # Multi-source semantics: returned value derives from EXACTLY one
    # of the declared sources (it cannot simultaneously originate from
    # two distinct parameters). Accept iff `actual_path` has any
    # declared source as its prefix; reject with a clear "expected one
    # of: ..." diagnostic when none match.
    matched = lifetime_paths.any? do |p|
      lifetime_syms = p.to_s.split(".").map(&:to_sym)
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

  sig { params(node: T.untyped).returns(T::Boolean) }
  def return_is_borrow?(node)
    T.bind(self, SemanticAnnotator) rescue nil
    if node.is_a?(AST::Identifier)
      return false unless ownership_graph[node.name]&.kind == :borrowed
      # Parameters (reg=nil) and MATCH bindings (reg=nil) are safe to return —
      # the caller controls their lifetime. Only flag variables explicitly assigned
      # from a collection index borrow (BindExpr with container_borrow=true).
      scope = lookup_scope_for(node.name)
      reg = scope&.resolve_entry(node.name)&.reg
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
          next true if expected == :Any && !spec[:sync] && !spec[:ownership]
          next false unless expected == :Any || is_safe_autocast?(arg.resolved_type, expected)
          # Check capability constraints (sync, ownership, etc.)
          arg_type = arg.full_type!(context: "intrinsic capability argument")
          next false if spec[:sync] && arg_type&.sync != spec[:sync]
          next false if spec[:ownership] && arg_type&.ownership != spec[:ownership]
          true
        else
          next true if spec == :Any
          next true if spec.is_a?(Symbol) && any_array_intrinsic_arg?(spec, arg)
          is_safe_autocast?(arg.resolved_type, spec)
        end
      end
    end
    matched && IntrinsicRegistry.fs(matched)
  end

  sig { params(spec: Symbol, arg: Object).returns(T::Boolean) }
  def any_array_intrinsic_arg?(spec, arg)
    T.bind(self, SemanticAnnotator) rescue nil
    return false unless spec == :"Any[]"
    return false unless arg.respond_to?(:full_type!)

    type = arg.send(:full_type!, context: "intrinsic Any[] argument")
    return false unless type.is_a?(Type)
    return true if type.array?
    return false unless type.future?

    type.dynamic_stream? || type.promise_list? || type.bounded_stream? ||
      type.open_stream? || type.inf_stream?
  end

  # Formats intrinsic args for error messages
  sig { params(args: T::Array[T.untyped]).returns(String) }
  def format_intrinsic_args(args)
    T.bind(self, SemanticAnnotator) rescue nil
    return "(varargs)" if args == :Varargs
    types = args.map { |a| a.is_a?(Hash) ? a[:type] : a }
    "(#{types.join(', ')})"
  end

  private :verify_argument_type!,
    :verify_argument_aliases!,
    :verify_atomic_argument!,
    :verify_function_signature!,
    :verify_lifetime!,
    :verify_takes_argument!,
    :fn_type_argument_match?
  private :analyze_routine
  private :any_array_intrinsic_arg?
  private :any_element_collection_param?
  private :argument_name
  private :atomic_cell_arg?
  private :atomic_cell_to_atomic_param?
  private :atomic_cell_to_bare_value_param?
  private :basic_argument_match?
  private :borrowed_takes_argument?
  private :build_lambda_signature
  private :call_argument_facts
  private :call_arity_plan
  private :call_signature_site
  private :declare_and_verify_params
  private :declare_captures
  private :default_argument_for
  private :explicit_primitive_atomic_param?
  private :get_return_strategy
  private :inject_default_arguments!
  private :param_mutable?
  private :paths_overlap?
  private :receiver_container_alloc
  private :reentrant_fn_argument_rejected?
  private :return_is_borrow?
  private :shared_argument_match?
  private :verify_call_arity!
  private :verify_captures!
  private :verify_lifetime_source!
  private :verify_link_argument!
  private :verify_mutable_argument!
  private :verify_no_mixed_atomic_returned_lifetime!
  private :verify_owned_takes_argument!
  private :verify_param_lifetime!
  private :verify_returns
  private :warn_multi_atomic_bare_value_call!

end
