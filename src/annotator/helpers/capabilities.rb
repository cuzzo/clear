# typed: strict
require "sorbet-runtime"
# capabilities.rb — Capability validation, audit, and helpers for CLEAR's type system.
#
# Three concerns, three modules:
#   Capabilities       — static validation of capability combinations on Type objects
#   CapabilityHelper   — runtime validation and inference for WITH blocks
#   CapabilityAudit    — "Architecture Consultant" that warns about over-engineered capabilities

require 'set'

# ============================================================================
# Capabilities — Static validation of capability combinations
# ============================================================================
module Capabilities
    extend T::Sig

  # Capabilities that are mutually exclusive with each other.
  Conflict = Struct.new(:set_a, :set_b, :message)
  CONFLICTS = T.let([
    Conflict.new([:soa],     [:shared, :multiowned], "SOA layout is incompatible with reference-counted ownership"),
  ].freeze, T::Array[T.untyped])

  sig { params(type: Type).returns(T::Array[String]) }
  def self.errors_for(type)
    return [] unless type.is_a?(Type)

    errors = []
    caps = active_capabilities(type)

    CONFLICTS.each do |conflict|
      has_a = conflict.set_a.any? { |c| caps.include?(c) }
      has_b = conflict.set_b.any? { |c| caps.include?(c) }
      errors << conflict.message if has_a && has_b
    end

    errors
  end

  sig { params(node: T.untyped, type: Type, error_handler: T.untyped).returns(NilClass) }
  def self.validate!(node, type, &error_handler)
    errs = errors_for(type)
    return if errs.empty?
    error_handler.call(node, errs.first) if error_handler
  end

  sig { params(type: Type).returns(T::Set[Symbol]) }
  def self.active_capabilities(type)
    caps = Set.new
    caps << type.ownership if type.ownership && type.ownership != :affine
    caps << type.sync if type.sync
    caps << :soa if type.respond_to?(:soa?) && type.soa?
    caps << :sharded if type.respond_to?(:sharded?) && type.sharded?
    caps << :pool if type.respond_to?(:pool?) && type.pool?
    caps << :list if type.respond_to?(:list_collection?) && type.list_collection?
    caps
  end
end

# ============================================================================
# CapabilityHelper — WITH block validation and capability acquisition
# ============================================================================
# Mixed into SemanticAnnotator. Provides validate_capability and
# acquire_capability! used by visit_WithBlock.
module CapabilityHelper
    extend T::Sig
    extend T::Helpers

  requires_ancestor { SemanticAnnotator }

  class PredicateContext < T::Struct
    const :kind, Symbol
    const :with_node, T.nilable(AST::WithBlock)
    const :fn_node, T.nilable(AST::FunctionDef)
    const :pred_expr, AST::Locatable
    const :guard_alias, T.nilable(String)
    const :sibling_aliases, T::Array[String]
    const :param_names, T::Array[String]
    const :allowed_names, T::Array[String]
    const :rejected_param_names, T::Set[String]
    const :fn_name, T.nilable(String)
  end

  class PredicateCallSite < T::Struct
    const :kind, Symbol
    const :with_node, T.nilable(AST::WithBlock)
    const :fn_node, T.nilable(AST::FunctionDef)
    const :pred_expr, AST::Locatable
    const :call, T.any(AST::FuncCall, AST::MethodCall)
    const :callee, String
  end

  # WITH can be applied to an Identifier or a GetField (`obj.field`).
  # For an Identifier, sync/ownership lives on the SymbolEntry. For a
  # GetField, it lives on the field's declared type (recorded on the
  # struct schema and projected onto the GetField node's full_type
  # during annotation). These helpers paper over the difference so the
  # rest of the WITH logic doesn't have to.
  sig { params(var_node: AST::Locatable).returns(T.nilable(Symbol)) }
  def cap_var_sync(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    sym_sync = var_node.symbol&.sync
    return sym_sync if sym_sync
    var_node.full_type!(context: "WITH capability sync target").sync
  end

  sig { params(var_node: AST::Locatable).returns(T.nilable(Symbol)) }
  def cap_var_storage(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    sym = var_node.symbol
    return sym.storage if sym
    var_node.full_type!(context: "WITH capability storage target").ownership_storage
  end

  # Read layout from the SymbolEntry when available, or from full_type before
  # symbol binding has completed. Mirrors cap_var_sync / cap_var_storage.
  sig { params(var_node: AST::Locatable).returns(T.nilable(Symbol)) }
  def cap_var_layout(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    sym_layout = var_node.symbol&.layout
    return sym_layout if sym_layout
    var_node.full_type!(context: "WITH capability layout target").layout
  end

  sig { params(var_node: AST::Locatable).returns(String) }
  def cap_var_label(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    case var_node
    when AST::Identifier then var_node.name
    when AST::GetField then var_node.field.to_s
    when AST::GetIndex then cap_var_name(var_node)
    else "__unknown"
    end
  end

  # Validate that a capability type is legal for the given variable.
  sig { params(node: AST::WithBlock, capability_type: Symbol, var_node: AST::Locatable).void }
  def validate_capability(node, capability_type, var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    var_type = var_node.full_type!(context: "WITH capability target")
    unless valid_capability_target?(capability_type, var_node)
      error!(var_node, :WITH_CAP_BAD_TARGET, capability: capability_type, got: var_node.class)
    end

    case capability_type
    when :EXCLUSIVE
      syn = cap_var_sync(var_node)
      unless syn
        # Function parameters may not have propagated sync yet; locals error
        # eagerly because no later propagation can fix them.
        if var_node.symbol&.is_param
          record_deferred_with_validation!(node, var_node, :EXCLUSIVE)
        else
          storage = cap_var_storage(var_node)
          name = cap_var_label(var_node)
          emit_with_cap_mismatch!(node, name, :WITH_EXCLUSIVE_NEEDS_LOCK,
            [
              { sigil: '@locked',
                description: "Add `@locked` to '#{name}' (Mutex — single-writer EXCLUSIVE access)." },
              { sigil: '@writeLocked',
                description: "Add `@writeLocked` to '#{name}' (RwLock — readers can coexist via WITH READ; writers via WITH EXCLUSIVE)." },
            ],
            confidence: :interactive,
            got: storage || 'unknown')
        end
      end

    when :write_locked_read
      syn = cap_var_sync(var_node)
      unless syn == :write_locked
        if var_node.symbol&.is_param && syn.nil?
          record_deferred_with_validation!(node, var_node, :write_locked_read)
        else
          name = cap_var_label(var_node)
          emit_with_read_needs_write_lock!(node, name, var_node)
        end
      end

    when :RESTRICT
      if var_node.is_a?(AST::Identifier) && var_node.symbol && !var_node.symbol.mutable
        emit_with_restrict_immutable_error!(node, var_node)
      end

    when :BORROWED
      # BORROWED is an immutable borrow — any variable can be borrowed.
      # No special validation needed beyond the identity check above.

    when :VIEW
      # VIEW requires a tense observable source; MATERIALIZED VIEW is the
      # always-correct fallback for non-observable tense aggregates.
      t = var_type.is_a?(Type) ? var_type : Type.new(var_type)
      unless t.future? && t.observable?
        if var_node.is_a?(AST::Identifier)
          emit_view_not_observable_finding!(node, var_node, t)
        else
          name = cap_var_label(var_node)
          error!(node, :CAPABILITY_VIOLATION_FIXABLE,
            message: "WITH VIEW requires an `@observable` source, but '#{name}' has type #{t.resolved}.")
        end
      end

    when :MATERIALIZED_VIEW
      # Any tense aggregate is allowed; non-tense sources are rejected.
      t = var_type.is_a?(Type) ? var_type : Type.new(var_type)
      unless t.future?
        name = cap_var_label(var_node)
        emit_with_materialized_needs_tense!(node, name, t.resolved)
      end

    when :SNAPSHOT
      # Versioned cells and indirect atomic cells share the WITH SNAPSHOT
      # surface; lowering chooses the Guard or update/CAS path per capability.
      syn = cap_var_sync(var_node)
      lay = cap_var_layout(var_node)
      atomic_ptr_ok = syn == :atomic && lay == :indirect
      unless syn == :versioned || atomic_ptr_ok
        name = cap_var_label(var_node)
        storage = cap_var_storage(var_node)
        actual = if syn && lay == :indirect
          "@#{lay}:#{syn}"
        elsif syn
          "@#{syn}"
        elsif storage
          "@#{storage}"
        else
          "plain"
        end
        emit_with_cap_mismatch!(node, name, :WITH_SNAPSHOT_NEEDS_VERSIONED_OR_ATOMIC,
          [
            { sigil: '@versioned',
              description: "Add `@versioned` to '#{name}' (MVCC cell — readers see a stable snapshot; writers retry on conflict)." },
            { sigil: '@indirect:atomic',
              description: "Add `@indirect:atomic` to '#{name}' (lock-free atomic-pointer cell — readers snapshot, writers CAS-publish)." },
          ],
          confidence: :interactive,
          name: name, actual: actual)
      end

    when :multiowned
      unless cap_var_storage(var_node) == :multiowned
        name = cap_var_label(var_node)
        emit_with_cap_mismatch!(node, name, :WITH_NEEDS_MULTIOWNED,
          [{ sigil: '@multiowned',
             description: "Add `@multiowned` to '#{name}' (Rc — single-scheduler refcount; cheap clones via WITH)." }],
          confidence: :auto,
          name: name)
      end

    when :shared
      unless cap_var_storage(var_node) == :shared
        name = cap_var_label(var_node)
        emit_with_cap_mismatch!(node, name, :WITH_NEEDS_SHARED,
          [{ sigil: '@shared',
             description: "Add `@shared` to '#{name}' (Arc — atomic refcount; safe to clone across fibers)." }],
          confidence: :auto,
          name: name)
      end

    when :ATOMIC
      # Polymorphic params may not have sync propagated yet; defer those checks.
      syn = cap_var_sync(var_node)
      unless syn == :atomic
        if var_node.symbol&.is_param && syn.nil?
          record_deferred_with_validation!(node, var_node, :ATOMIC)
        else
          name = cap_var_label(var_node)
          storage = cap_var_storage(var_node)
          actual = syn ? "@#{syn}" : (storage ? "@#{storage}" : "plain")
          emit_with_cap_mismatch!(node, name, :WITH_ATOMIC_NEEDS_SHARED_ATOMIC,
            [{ sigil: '@shared:atomic',
               description: "Add `@shared:atomic` to '#{name}' (lock-free atomic primitive — `c.load()`, `c.fetchAdd(n)`, etc. via WITH ATOMIC)." }],
            confidence: :auto,
            name: name, actual: actual)
        end
      end

    else
      error!(node, :UNKNOWN_WITH_CAP_TYPE, type: capability_type)
    end
  end

  sig { params(capability_type: Symbol, var_node: AST::Locatable).returns(T::Boolean) }
  def valid_capability_target?(capability_type, var_node)
    return true if var_node.is_a?(AST::Identifier) || var_node.is_a?(AST::GetField)
    capability_type == :BORROWED && var_node.is_a?(AST::GetIndex)
  end
  private :valid_capability_target?

  # Observables Phase 2.8: emit a fixable error for `WITH VIEW v AS s`
  # where v is not `@observable`. The :auto fix replaces `VIEW` with
  # `MATERIALIZED VIEW` (always-correct, owned O(N) snapshot). The
  # :interactive fix proposes adding `@observable` at the source's
  # declaration -- skipped here because the declaration may be in
  # another module / file; `clear fix` will surface only the :auto fix.
  sig { params(node: AST::WithBlock, var_node: AST::Identifier, var_type: Type).returns(NilClass) }
  def emit_view_not_observable_finding!(node, var_node, var_type)
    T.bind(self, SemanticAnnotator) rescue nil
    name = var_node.respond_to?(:name) ? var_node.name : var_node.find
    msg = "WITH VIEW requires an `@observable` source, but '#{name}' has type #{var_type.resolved}. " \
          "Use `WITH MATERIALIZED VIEW` for non-observable aggregates, or annotate the binding as `~T@observable`."

    cap_entry = node.capabilities.find { |c| c[:capability] == :VIEW && c[:var_node].equal?(var_node) }
    view_tok = cap_entry && cap_entry[:view_token]

    fixes = []
    if view_tok
      fixes << Fix.new(
        description: "Replace `VIEW` with `MATERIALIZED VIEW` (owned O(N) snapshot, works on any `~T` aggregate).",
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: view_tok.line, col: view_tok.column, length: 'VIEW'.length),
          replacement: 'MATERIALIZED VIEW',
        )],
      )
    end

    return error!(node, :CAPABILITY_VIOLATION_FIXABLE, message: msg) if fixes.empty?
    fixable!(node, message: msg, category: :capability, level: :error,
             fixes: fixes, raise_in_collector: false)
  end

  # Predicate identifier scope check. Used by both WITH GUARD (where the
  # predicate may reference only its own alias) and FN PRE (where the
  # predicate may reference only function parameters). Branches on the
  # active context's :kind so each surface gets its own diagnostic.
  sig { params(node: AST::Identifier).returns(NilClass) }
  def predicate_identifier_allowed!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.nilable(PredicateContext))
    ctx = @current_predicate_context
    return unless ctx
    return if %w[TRUE FALSE].include?(node.name)

    case ctx.kind
    when :guard
      own_alias = ctx.guard_alias
      return unless own_alias
      return if node.name == own_alias

      sibling_aliases = ctx.sibling_aliases
      if sibling_aliases.include?(node.name)
        error!(node, :WITH_GUARD_REFS_SIBLING_ALIAS, own_alias: own_alias, name: node.name, remediation: # Trailing helper text follows the main message. Kept as
          # a separate arg so the registered template stays
          # parameterised — different surfaces can suggest different
          # remediations.
          "Use an `IF` guard clause inside the WITH body for cross-alias checks.")
      else
        emit_typo_suggestion!(
          node.token, node.name, [own_alias],
          "WITH GUARD can only reference the guarded alias '#{own_alias}'. Found '#{node.name}'.",
          "the guarded alias",
          category: :capability, cascade: true)
      end
    when :pre
      params = ctx.param_names
      return if params.include?(node.name)
      emit_typo_suggestion!(
        node.token, node.name, params,
        "PRE clauses may only reference function parameters. " \
        "Found '#{node.name}', which is not a parameter of '#{ctx.fn_name}'.",
        "a parameter of '#{ctx.fn_name}'",
        category: :type, cascade: true)
    when :post
      allowed = ctx.allowed_names
      rejected = ctx.rejected_param_names
      unless allowed.include?(node.name)
        return emit_typo_suggestion!(
          node.token, node.name, allowed,
          "DEBUG_POST clauses may only reference function parameters or 'result'. " \
          "Found '#{node.name}', which is not in scope for '#{ctx.fn_name}'.",
          "a parameter of '#{ctx.fn_name}' or 'result'",
          category: :type, cascade: true)
      end
      if rejected.include?(node.name)
        error!(node, :DEBUG_POST_NEEDS_UNSYNC_PARAM, name: node.name)
      end
    end
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).void }
  def record_predicate_call_site!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.nilable(PredicateContext))
    @predicate_call_sites = T.let(@predicate_call_sites, T.nilable(T::Array[PredicateCallSite]))
    ctx = @current_predicate_context
    return unless ctx
    T.must(@predicate_call_sites) << PredicateCallSite.new(
      kind: ctx.kind,
      with_node: ctx.with_node,
      fn_node: ctx.fn_node,
      pred_expr: ctx.pred_expr,
      call: node,
      callee: node.name,
    )
  end

  sig { void }
  def validate_predicate_purity!
    T.bind(self, SemanticAnnotator) rescue nil
    @predicate_call_sites = T.let(@predicate_call_sites, T.nilable(T::Array[PredicateCallSite]))
    T.must(@predicate_call_sites).each do |site|
      call = site.call
      callee = site.callee
      reason = predicate_impurity_reason(call, callee)
      next unless reason

      surface, hint = case site.kind
                      when :pre
                        ["PRE clauses",
                         "Move the impure work into the function body and validate the captured value there."]
                      when :post
                        ["DEBUG_POST clauses",
                         "Move the impure work into the function body and assert against an unsynchronized snapshot value instead."]
                      else
                        ["WITH GUARD clauses",
                         "Move the impure work before the WITH block and guard on the captured value."]
                      end
      error!(call, :PURE_FN_CANNOT_CALL_IMPURE, surface: surface, callee: callee, reason: reason, hint: hint)
    end
  end

  sig { params(call: T.any(AST::FuncCall, AST::MethodCall), callee: String).returns(T.nilable(String)) }
  def predicate_impurity_reason(call, callee)
    T.bind(self, SemanticAnnotator) rescue nil
    return "is an extern call" if call.respond_to?(:extern_call) && call.extern_call
    return "has extern effects" if call.respond_to?(:extern_effects) && call.extern_effects && !call.extern_effects.empty?
    return "can fail" if call.respond_to?(:can_fail) && call.can_fail
    if call.matched_stdlib_def
      md = call.matched_stdlib_def
      return "allocates" if md.emit&.allocates
      return "can fail" if md.can_fail
      return "suspends" if md.emit&.suspends
      return "mutates its receiver" if md.emit&.mutates_receiver
      return nil
    end

    @fn_nodes = T.let(@fn_nodes, T.nilable(T::Hash[String, AST::FunctionDef]))
    fn_nodes = T.must(@fn_nodes)
    fn = fn_nodes[callee] if callee.is_a?(String)
    return nil unless fn
    return "can fail" if fn.can_fail
    effects = fn.effects || Set.new
    return nil if effects.empty?
    "has effects #{effects.map { |e| EffectTracker.display(e) }.sort.join(', ')}"
  end

  sig { params(node: AST::WithBlock).void }
  def validate_and_visit_with_guards!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.nilable(PredicateContext))
    caps = node.capabilities || []
    guarded = caps.select { |cap| cap[:guard_expr] }
    return if guarded.empty?

    error!(node, :WITH_GUARD_NOT_WITH_MATCH) if node.arms
    if node.snapshot_mode == :transaction
      error!(node, :WITH_GUARD_NOT_ON_SNAPSHOT)
    end

    # Every participating capability must bind an alias so the guard can
    # name it, and every alias must be immutable. MUTABLE aliases could
    # change inside the body and silently invalidate the predicate.
    missing_alias = caps.reject { |c| c[:alias] }
    unless missing_alias.empty?
      emit_with_guard_all_bindings_need_as!(node, missing_alias)
    end

    aliases = caps.map { |c| c[:alias] }.compact
    prev_guard = @current_predicate_context
    begin
      guarded.each do |gcap|
        own = gcap[:alias]
        siblings = aliases - [own]
        @current_predicate_context = T.let(PredicateContext.new(
          kind: :guard,
          with_node: node,
          fn_node: nil,
          pred_expr: T.cast(gcap[:guard_expr], AST::Locatable),
          guard_alias: own,
          sibling_aliases: siblings,
          param_names: [],
          allowed_names: [],
          rejected_param_names: Set.new,
          fn_name: nil,
        ), T.nilable(PredicateContext))
        visit(gcap[:guard_expr])

        guard_type = gcap[:guard_expr].full_type!(context: "WITH guard expression")
        unless guard_type && guard_type.resolved == :Bool
          error!(gcap[:guard_expr], :WITH_GUARD_EXPR_MUST_BE_BOOL, got: guard_type || 'Unknown')
        end
      end
    ensure
      @current_predicate_context = prev_guard
    end
  end

  # Visit PRE clauses on a function definition. Runs after parameters
  # have been declared into the routine scope (so the predicate can
  # reference them and resolve their types) and before the body is
  # visited. Each predicate must be Bool, may reference only parameters
  # / TRUE / FALSE, and is held to the same purity rules as WITH GUARD.
  #
  # PRE failures emit `rt.setError(...PreconditionFail); return error.CheatError;`,
  # which means a PRE-having function MUST declare an error-union return
  # (`RETURNS !T`). The function-level `enforce_fallible_returns!` pass
  # catches the explicit-T case (since pre_clauses now flag the fn as
  # raising); the implicit-RETURNS case is caught here.
  sig { params(fn_node: AST::FunctionDef).void }
  def visit_pre_clauses!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.nilable(PredicateContext))
    pre_clauses = fn_node.respond_to?(:pre_clauses) ? (fn_node.pre_clauses || []) : []
    return if pre_clauses.empty?

    unless fn_node.respond_to?(:explicit_return_type) && fn_node.explicit_return_type
      message = "Function '#{fn_node.name}' has PRE clauses but no explicit return type. " \
                "PRE clauses can fail at runtime, so the function must declare an error-union " \
                "return. Add `RETURNS !Void` (or `RETURNS !T` for a value-returning function) " \
                "to the signature."

      arrow_tok = fn_node.arrow_token
      if arrow_tok
        # Auto-fix: insert `RETURNS !Void ` immediately before the
        # `->` arrow. The body is implicit-Void (no RETURNS clause
        # was given), so !Void is the correct error-union widening.
        fixes = [Fix.new(
          description: "Insert `RETURNS !Void` so PRE-failure errors can propagate.",
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: arrow_tok.line, col: arrow_tok.column, length: 0),
            replacement: 'RETURNS !Void ',
          )],
        )]
        fixable!(fn_node, message: message, category: :type, level: :error, fixes: fixes)
      else
        error!(fn_node, :PURITY_VIOLATION, message: message)
      end
    end

    param_names = fn_node.params.map { |p| p.name.to_s }
    prev_ctx = @current_predicate_context
    begin
      pre_clauses.each do |entry|
        expr = entry[:expr]
        @current_predicate_context = T.let(PredicateContext.new(
          kind: :pre,
          with_node: nil,
          fn_node: fn_node,
          pred_expr: T.cast(expr, AST::Locatable),
          guard_alias: nil,
          sibling_aliases: [],
          param_names: param_names,
          allowed_names: [],
          rejected_param_names: Set.new,
          fn_name: fn_node.name,
        ), T.nilable(PredicateContext))
        visit(expr)

        pred_type = expr.full_type!(context: "PRE expression")
        unless pred_type && pred_type.resolved == :Bool
          error!(expr, :PRE_EXPR_MUST_BE_BOOL, got: pred_type || 'Unknown')
        end
      end
    ensure
      @current_predicate_context = prev_ctx
    end
  end

  # Visit DEBUG_POST clauses on a function definition. Runs AFTER the
  # body has been annotated, while still inside the routine scope so
  # parameters resolve normally. Each predicate may reference parameters
  # plus the synthetic `result` (typed as the function's return payload).
  # Predicates referring to synchronized parameters are rejected because
  # POST runs after locks are released — reading a sync'd field outside
  # the lock is racy. POST predicates are debug-only assertions and do
  # NOT require the function to return an error union.
  sig { params(fn_node: AST::FunctionDef).returns(T.nilable(Scope)) }
  def visit_post_clauses!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.nilable(PredicateContext))
    post_clauses = fn_node.respond_to?(:post_clauses) ? (fn_node.post_clauses || []) : []
    return if post_clauses.empty?

    # POST + CATCH on the same function is not yet supported. Reject at
    # annotation time with a clean CLEAR diagnostic rather than letting
    # MIR lowering hit an internal raise.
    has_catch = fn_node.respond_to?(:catch_clauses) && fn_node.catch_clauses.is_a?(Array) && fn_node.catch_clauses.any?
    has_default_catch = fn_node.respond_to?(:default_catch) && fn_node.default_catch.is_a?(Array) && fn_node.default_catch.any?
    if has_catch || has_default_catch
      error!(fn_node, :DEBUG_POST_NOT_WITH_CATCH)
    end

    param_names = fn_node.params.map { |p| p.name.to_s }
    rejected = fn_node.params.filter_map do |p|
      sym = current_scope.locals[p.name.to_s]
      next unless sym && %i[locked write_locked versioned atomic].include?(sym.sync)
      p.name.to_s
    end.to_set

    rt = fn_node.return_type
    rt_obj = rt.is_a?(Type) ? rt : (rt ? Type.new(rt) : nil)
    payload = if rt_obj && rt_obj.error_union?
                rt_obj.payload_type
              else
                rt_obj
              end

    with_new_scope(current_scope) do
      if payload
        current_scope.declare("result", nil, payload, false, false, nil, :stack)
      end

      allowed_names = param_names + ["result"]
      prev_ctx = @current_predicate_context
      begin
        post_clauses.each do |entry|
          expr = entry[:expr]
          @current_predicate_context = T.let(PredicateContext.new(
            kind: :post,
            with_node: nil,
            fn_node: fn_node,
            pred_expr: T.cast(expr, AST::Locatable),
            guard_alias: nil,
            sibling_aliases: [],
            param_names: [],
            allowed_names: allowed_names,
            rejected_param_names: rejected,
            fn_name: fn_node.name,
          ), T.nilable(PredicateContext))
          visit(expr)

          pred_type = expr.full_type!(context: "DEBUG_POST expression")
          unless pred_type && pred_type.resolved == :Bool
            error!(expr, :DEBUG_POST_EXPR_MUST_BE_BOOL, got: pred_type || 'Unknown')
          end
        end
      ensure
        @current_predicate_context = prev_ctx
      end
    end
  end

  # Post-body check: a MUTABLE GUARD alias is fine as long as the body
  # never mutates it. Mutation inside the body could silently invalidate
  # the predicate evaluated at WITH entry, so reject only the cases that
  # actually exhibit mutation. Must run AFTER `visit_stmts(node.body)` so
  # the annotator's existing `mark_var_mutated` calls (assignment, field/
  # index store, mutating method dispatch, RESTRICT borrow) have stamped
  # the alias's SymbolEntry. Lookup-only — no AST re-walking.
  sig { params(node: AST::WithBlock).returns(NilClass) }
  def validate_with_guard_no_body_mutation!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    caps = node.capabilities || []
    return if caps.none? { |cap| cap[:guard_expr] }

    mutable_caps = caps.select { |c| c[:alias_mutable] && c[:alias] }
    return if mutable_caps.empty?

    mutated = mutable_caps.map { |c| c[:alias] }.select { |a| alias_mutated?(a) }
    return if mutated.empty?

    is_or_are = mutated.length == 1 ? 'is' : 'are'
    emit_with_guard_mutable_mutated!(node, mutated, is_or_are)
  end

  sig { params(alias_name: String).returns(T::Boolean) }
  def alias_mutated?(alias_name)
    T.bind(self, SemanticAnnotator) rescue nil
    scope = lookup_scope_for(alias_name)
    return false unless scope
    !!scope.locals[alias_name]&.mutated
  end

  # Resolve and validate a single capability entry from a WITH block.
  # Visits the var_node, infers capability if needed, validates it,
  # records effects/audit, and handles wildcard expansion.
  #
  # @param node [AST::WithBlock] the WITH block (for error reporting)
  # @param cap [Hash] the capability entry { :capability, :var_node, :alias }
  # @param expanded [Array] accumulator for resolved capabilities
  sig { params(node: AST::WithBlock, cap: AST::Capability, expanded: T::Array[AST::Capability]).void }
  def acquire_capability!(node, cap, expanded)
    T.bind(self, SemanticAnnotator) rescue nil
    var_node = cap[:var_node]
    visit(var_node)
    cap[:resolved_type] = var_node.full_type!(context: "WITH resolved capability target")

    cap[:old_scope] = lookup_scope_for(cap_var_name(var_node))

    # Infer capability from the variable's storage when not stated explicitly
    if cap[:capability] == :infer
      storage = cap_var_storage(var_node)
      syn     = cap_var_sync(var_node)
      cap[:capability] = case
                         when syn == :locked            then :EXCLUSIVE
                         when syn == :write_locked      then :write_locked_read
                         when syn == :versioned         then :SNAPSHOT
                         # Atomic bindings get a non-blocking ATOMIC capability. The
                         # WITH body (or per-arm prelude) binds the alias to
                         # the cell ref directly so atomic ops can be invoked.
                         when syn == :atomic            then :ATOMIC
                         # WITH POLYMORPHIC on a non-sync binding becomes a
                         # no-op alias so the body can read, and when mutable
                         # write, through `*T` without a Guard/Arc/snapshot.
                         when (node.respond_to?(:polymorphic) && node.polymorphic) &&
                              (syn.nil? || syn == :local) &&
                              (storage.nil? || storage == :local ||
                               storage == :multiowned || storage == :stack ||
                               storage == :heap)
                           is_mut = var_node.respond_to?(:symbol) &&
                                    var_node.symbol&.mutable
                           if is_mut
                             cap[:alias_mutable] = true
                             :RESTRICT
                           else
                             :BORROWED
                           end
                         when storage == :multiowned    then :multiowned
                         when storage == :shared        then :shared
                         else
                           name = cap_var_label(var_node)
                           emit_with_cannot_infer_cap!(node, name)
                           :unknown
                         end
    end

    validate_capability(node, cap[:capability], var_node)

    # Effect tracking: lock-based caps may block the fiber AND contend on
    # the lock's cache line. Lock-free SNAPSHOT (MVCC read) just contends
    # on the version pointer — no parking. Atomic ops are stamped at
    # their use sites (visit_Identifier read, visit_BindExpr atomic store /
    # fetchAdd) since atomic primitives don't go through WITH.
    #
    # WITH MATCH defers effect recording to per-arm tracking so family-specific
    # prelude effects collapse correctly; the actual runtime path depends on
    # which arm fires.
    if node.respond_to?(:arms) && node.arms
      # WITH MATCH form: per-arm recording in visit_WithBlock handles it.
    else
      case cap[:capability]
      when :EXCLUSIVE, :write_locked_read
        record_effect(EffectTracker::BLOCKING)
        record_effect(EffectTracker::CONTENTION)
      when :SNAPSHOT
        record_effect(EffectTracker::CONTENTION)
      end
    end

    # Capability audit: mark variable as mutated if EXCLUSIVE access is used.
    if cap[:capability] == :EXCLUSIVE && var_node.is_a?(AST::Identifier)
      audit_mark_mutated(var_node.name)
    end

    # Handle Wildcard Borrow: WITH RESTRICT node.* { ... }
    if var_node.is_a?(AST::GetField) && var_node.wildcard?
      target_type = var_node.target.resolved_type
      schema = lookup_type_schema(target_type)

      unless schema
        error!(node, :BORROW_WILDCARD_NEEDS_STRUCT, name: var_node.target.name, type: target_type)
      end

      fields = schema.fields
      fields.each do |field_name, _|
        field_node = AST::GetField.new(var_node.token, var_node.target, field_name)
        # Eager producer: resolve the field's type now (same mechanism
        # as the input cap, line 644) so every expanded cap carries a
        # real resolved_type -- the cap.resolved_type || old_scope
        # fallback chain becomes dead.
        visit(field_node) rescue nil
        expanded << AST::Capability.new(
          capability: cap[:capability],
          var_node: field_node,
          old_scope: cap[:old_scope],
          resolved_type: field_node.full_type!(context: "WITH wildcard field")
        )
      end
      # The per-field caps above each alias the base variable name; the
      # base binding must remain the struct type (a field cap declaring
      # `p` as a field's type would break `p.field` inside the block).
      # Re-assert the whole-struct cap last so the base keeps its type.
      base_t = var_node.target.full_type!(context: "WITH wildcard base")
      base_t = Type.new(base_t) unless base_t.is_a?(Type)
      expanded << AST::Capability.new(
        capability: cap[:capability],
        var_node: var_node.target,
        old_scope: cap[:old_scope],
        resolved_type: base_t
      )
    else
      expanded << cap
    end
  end

  # Declare a resolved capability into the current scope.
  # For locked/write_locked vars, declares the alias as the plain inner type
  # (mutable, stack-allocated) and re-declares the locked var for accessibility.
  # For all others, delegates to scope.declare_with_new_capability.
  sig { params(var_node: T.untyped).returns(String) }
  def cap_var_name(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    AST.root_identifier(var_node)&.name || "__unknown"
  end

  sig { params(cap: AST::Capability).returns(T.nilable(String)) }
  def declare_capability_scope!(cap)
    T.bind(self, SemanticAnnotator) rescue nil
    @og = T.let(@og, T.untyped)
    var_name = cap_var_name(cap[:var_node])
    source_entry = cap[:old_scope]&.locals&.[](var_name)
    # Sync may live on the binding (Identifier path) or on the field's
    # declared type (GetField path) — cap_var_sync covers both.
    syn = cap_var_sync(cap[:var_node])
    # Parameters without propagated sync still declare their inner aliases; the
    # deferred validation emits the real error later if sync stays nil.
    deferred_param = source_entry&.is_param && syn.nil? &&
      (cap[:capability] == :EXCLUSIVE || cap[:capability] == :write_locked_read)
    is_field = cap[:var_node].is_a?(AST::GetField)

    if syn && is_field
      # WITH on a sync-wrapped struct field. The alias holds the unwrapped
      # inner value (post-`.acquire().get()`). Resolve the bare inner type
      # from the field's declared type and declare the alias.
      inner_type = cap[:var_node].full_type!(context: "WITH capability field alias")
      if inner_type.is_a?(Type) && (inner_type.any_sync? || inner_type.ownership != :affine)
        inner_type = inner_type.bare_data_type
      end
      alias_name = cap[:alias] || var_name
      current_scope.declare(alias_name, nil, inner_type, true, false, nil, :stack)
      record_capture_local!(alias_name) if cap[:alias]
      current_scope.locals[alias_name].mark_non_escaping!
      og_declare(alias_name, nil, inner_type)
      unless current_scope.declare_with_new_capability(cap)
        error!(cap[:var_node], :WITH_CAP_BINDING_LOST,
               capability: cap[:capability], name: cap[:var_node].name)
      end
    elsif (syn || deferred_param) && !is_field
      # The WITH alias represents the unwrapped inner value for the
      # lifetime of the lock. Its type must be the bare data shape — no
      # sync/ownership wrappers — so downstream lowerings (method calls,
      # field access) don't re-emit Arc / Locked indirection on top of
      # the already-unwrapped guard pointer.
      inner_type = cap[:old_scope].resolve_type(var_name)
      if inner_type.is_a?(Type) && (inner_type.any_sync? || inner_type.ownership != :affine)
        inner_type = inner_type.bare_data_type
      end
      alias_name = cap[:alias] || var_name
      current_scope.declare(alias_name, nil, inner_type, true, false, nil, :stack)
      record_capture_local!(alias_name) if cap[:alias]
      current_scope.locals[alias_name].mark_non_escaping!
      og_declare(alias_name, nil, inner_type)
      unless current_scope.declare_with_new_capability(cap)
        error!(cap[:var_node], :WITH_CAP_BINDING_LOST,
               capability: cap[:capability], name: cap[:var_node].name)
      end
    else
      unless current_scope.declare_with_new_capability(cap)
        error!(cap[:var_node], :WITH_CAP_BINDING_LOST,
               capability: cap[:capability], name: cap[:var_node].name)
      end
    end
    # Register borrows and create alias bindings for RESTRICT and BORROWED.
    if cap[:capability] == :RESTRICT
      @og.borrow("__restrict_#{var_name}", var_name, mutable: true)
      # Mark source as mutated so transpiler emits `var` (not `const`)
      # when a mutable borrow exists — needed for &p to yield a mutable pointer.
      if cap[:alias_mutable]
        mark_var_mutated(var_name)
      end
      # Create alias binding if AS was used (for plain locals without sync)
      if cap[:alias] && !syn
        alias_name = cap[:alias]
        is_mutable = !!cap[:alias_mutable]
        resolved_type = capability_alias_type(cap.resolved_type.untyped? ? (cap.old_scope&.resolve_type(var_name) || :Any) : cap.resolved_type)
        current_scope.declare(alias_name, nil, resolved_type, is_mutable, false, nil, :stack)
        record_capture_local!(alias_name)
        sym = current_scope.locals[alias_name]
        sym.mark_non_escaping!
        sym.mark_borrowed_alias!  # RESTRICT alias: fiber capture is stack-UAF
        og_declare(alias_name, nil, resolved_type)
      end
    elsif cap[:capability] == :VIEW || cap[:capability] == :MATERIALIZED_VIEW
      # Observables Phase 2.3 / 2.4. Bind alias to `?T` where T is the
      # inner element type of the tense source. VIEW is immutable +
      # non_escaping (borrow); MATERIALIZED_VIEW is owned and may escape.
      st = Type.new(cap.resolved_type)
      inner = st.tense_type
      # Wrap as ?T so the binding is null until the first item lands.
      # If `inner` is already optional (FIND yields `~?T@observable`,
      # whose tense_type is `?T`), don't double-wrap into `??T`.
      bind_type_sym = inner.optional? ? inner.resolved : :"?#{inner.resolved}"
      alias_name = cap[:alias] || var_name
      current_scope.declare(alias_name, nil, bind_type_sym, false, false, nil, :stack)
      record_capture_local!(alias_name)
      sym = current_scope.locals[alias_name]
      if cap[:capability] == :VIEW
        sym.mark_non_escaping!
        sym.mark_borrowed_alias!
      end
      og_declare(alias_name, nil, bind_type_sym)
    elsif cap[:capability] == :SNAPSHOT
      # MVCC L5. The alias holds the inner T of a `T@versioned` cell --
      # for a read-only SNAPSHOT, this is a borrow into the
      # currently-published version (kept alive by EBR for the duration
      # of the WITH); for a MUTABLE SNAPSHOT it is a fresh copy that
      # `Shared.update[Multi]` will publish on commit.
      #
      # Either way, the alias is `non_escaping` + `borrowed_alias` --
      # escape would either pin EBR unboundedly (read) or detach a
      # half-committed value from the txn boundary (mutable). Every
      # escape vector (RETURN, struct/union/collection store, BG/DO
      # capture, GIVE, COPY-to-non-temp, pipeline-binding crossing the
      # WITH) is rejected by the existing non_escaping checks at the
      # use site.
      st = Type.new(cap.resolved_type)
      # Strip Group-1 sigils so the alias's `.type` is the bare inner T.
      # The alias's SymbolEntry already keeps sync/layout=nil (declare
      # call below passes neither), but type-side downstream paths
      # (resolve_type / full_type readers) shouldn't see leftover
      # @versioned / @indirect:atomic flags on the alias's Type.
      inner_type = st.bare_data_type
      alias_name = cap[:alias] || var_name
      is_mutable = !!cap[:alias_mutable]
      current_scope.declare(alias_name, nil, inner_type, is_mutable, false, nil, :stack)
      record_capture_local!(alias_name)
      sym = current_scope.locals[alias_name]
      sym.mark_non_escaping!
      sym.mark_borrowed_alias!
      og_declare(alias_name, nil, inner_type)
    elsif cap[:capability] == :BORROWED
      # BORROWED guarantees the aliased data is stable for the borrow duration.
      # @shared/@locked/@multiowned types can be concurrently written — the
      # stability guarantee cannot be upheld. Reject them at the borrow site.
      source_sym = cap[:old_scope]&.locals&.[](var_name)
      if source_sym
        bad_storage = source_sym.rc_stored?
        bad_sync    = source_sym.locked? || source_sym.write_locked?
        if bad_storage || bad_sync
          qualifier = if source_sym.storage == :shared then "@shared"
                      elsif source_sym.storage == :multiowned then "@multiowned"
                      elsif source_sym.locked? then "@locked"
                      else "@writeLocked"
                      end
          remediation = "BORROWED guarantees the data is stable, but #{qualifier} data can be " \
                        "modified concurrently. Use WITH #{var_name} { } to access it safely instead."
          error!(cap[:var_node], :WITH_BORROWED_ON_QUALIFIED_VAR, qualifier: qualifier, name: var_name, remediation: remediation)
        end
      end
      alias_name = cap[:alias] || var_name
      resolved_type = capability_alias_type(cap.resolved_type.untyped? ? (cap.old_scope&.resolve_type(var_name) || :Any) : cap.resolved_type)
      current_scope.declare(alias_name, nil, resolved_type, false, false, nil, :stack)
      record_capture_local!(alias_name) if cap[:alias]
      sym = current_scope.locals[alias_name]
      sym.mark_non_escaping!
      sym.mark_borrowed_alias!  # BORROWED alias: fiber capture is stack-UAF
      og_declare(alias_name, nil, resolved_type)
      @og.borrow("__borrowed_#{var_name}", var_name, mutable: false)
    end
  end

  sig { params(type: T.untyped).returns(Type) }
  def capability_alias_type(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = type.is_a?(Type) ? Type.new(type) : Type.new(type)
    if t.any_sync? || t.ownership != :affine
      t.bare_data_type
    else
      t
    end
  end

  CaptureAnalysis = Struct.new(
    :has_local,
    :has_rc,
    :has_shared,
    :has_sharded,
    :has_affine_locked,
    :has_outer_ref,
    :has_non_escaping_capture,
    :captures,
    :capture_symbols,
    :close_patterns,
    :pointer_captures,
    :string_captures,
    :resource_captures,
    :site_moved,
    :site_copied,
    :strategies,
    :move_mark_names,
    :alloc_mark_entries,
    keyword_init: true
  ) do
    extend T::Sig
    sig { returns(Symbol) }
    def pin_reason; has_sharded ? :sharded : :shared; end
  end

  CaptureContext = Struct.new(:analysis, :outer_scope, :locals, :is_parallel, :mark_moves, keyword_init: true)

  sig { returns(CapabilityHelper::CaptureAnalysis) }
  def new_capture_analysis
    CaptureAnalysis.new(
      has_local: false, has_rc: false, has_shared: false,
      has_sharded: false, has_affine_locked: false, has_outer_ref: false,
      has_non_escaping_capture: false,
      captures: {}, capture_symbols: {}, close_patterns: {},
      pointer_captures: Set.new, string_captures: Set.new, resource_captures: Set.new,
      site_moved: Set.new, site_copied: Set.new,
      strategies: nil, move_mark_names: nil, alloc_mark_entries: nil
    )
  end

  sig { params(is_parallel: T.nilable(T::Boolean), mark_moves: T::Boolean, blk: T.untyped).returns(CapabilityHelper::CaptureAnalysis) }
  def with_fiber_capture_analysis(is_parallel: false, mark_moves: false, &blk)
    T.bind(self, SemanticAnnotator) rescue nil
    @capture_stack = T.let(@capture_stack, T.untyped)
    ctx = CaptureContext.new(
      analysis: new_capture_analysis,
      outer_scope: current_scope,
      locals: Set.new,
      is_parallel: is_parallel,
      mark_moves: mark_moves
    )
    (@capture_stack ||= []) << ctx
    blk.call
    ctx.analysis
  ensure
    @capture_stack.pop if @capture_stack
  end

  sig { returns(T.nilable(CapabilityHelper::CaptureContext)) }
  def current_capture_context
    @capture_stack = T.let(@capture_stack, T.untyped)
    @capture_stack&.last
  end

  sig { params(name: T.nilable(String)).void }
  def record_capture_local!(name)
    current_capture_context&.locals&.add(name) if name
  end

  sig { params(node: T.untyped, copied: T::Boolean).void }
  def record_capture_site!(node, copied:)
    ctx = current_capture_context
    return unless ctx
    root = AST.root_identifier(node.value) rescue nil
    name = root&.name&.to_s
    return if !name || ctx.locals.include?(name)
    copied ? ctx.analysis.site_copied << name : ctx.analysis.site_moved << name
  end

  sig { params(node: AST::Identifier).void }
  def record_capture_identifier!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    ctx = current_capture_context
    return unless ctx
    name = node.name
    return if ctx.locals.include?(name) || %w[TRUE FALSE VOID _].include?(name)
    info = ctx.outer_scope.locals[name]
    resolved_sym = info || node.symbol
    ctx.analysis.has_non_escaping_capture = true if non_escaping_fiber_capture?(resolved_sym)
    if info
      record_capture_info!(ctx, name, info, node)
      record_capture_move!(ctx, name, info, node)
    elsif lookup_scope_for(name)
      ctx.analysis.has_outer_ref = true
    end
  end

  sig { params(symbol: T.nilable(SymbolEntry)).returns(T::Boolean) }
  def non_escaping_fiber_capture?(symbol)
    return false unless symbol&.borrowed_alias && symbol.non_escaping

    # WITH aliases unwrap a synchronized cell into a stack borrow and have no
    # sync on the alias itself. Capturing those is a UAF. Capturing the
    # synchronized cell handle is different: the fiber owns a safe handle to
    # reacquire inside its own lifetime.
    !symbol.locked? && !symbol.write_locked? && !symbol.local? && !symbol.atomic?
  end

  sig { params(ctx: CapabilityHelper::CaptureContext, name: String, info: SymbolEntry, node: AST::Identifier).void }
  def record_capture_info!(ctx, name, info, node)
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let(@capability_audit, T.untyped)
    result = ctx.analysis
    result.has_outer_ref = true
    unless result.captures.key?(name)
      cap_type = info.atomic? ? info.type : node.full_type!(context: "fiber capture identifier")
      result.captures[name] = cap_type
      result.capture_symbols[name] = info
      t = cap_type.is_a?(Type) ? cap_type : Type.new(cap_type || :Any)
      result.pointer_captures << name if t.needs_pointer_passing?
      result.string_captures << name if t.string?
      result.resource_captures << name if t.resource? || info.close_zig
      if t.captured_plain_string_map_needs_deinit? && !info.close_zig
        result.resource_captures << name
        result.close_patterns[name] ||= "{0}.deinit(rt.heapAlloc(), rt.heapAlloc())"
      end
    end
    result.close_patterns[name] ||= info.close_zig if info.close_zig
    result.has_local = true if info.local?
    result.has_rc = true if info.storage == :multiowned
    ti = info.type
    is_dashmap = ti.is_a?(Type) && ti.striped? && (ti.shared? || ti.multiowned?)
    unless is_dashmap || info.atomic?
      result.has_shared = true if info.locked? || info.write_locked? || info.local?
      result.has_shared = true if info.rc_stored?
      result.has_affine_locked = true if info.affine_locked_capture?
      if ti.is_a?(Type) && ti.sharded?
        result.has_sharded = true
        result.has_shared = true
      end
    end
    if current_fn_ctx&.name
      key = "#{current_fn_ctx.name}:#{name}"
      if @capability_audit&.dig(key)
        @capability_audit[key][:captured_bg] = true
        @capability_audit[key][:captured_parallel] = true if ctx.is_parallel
      end
    end
  end

  sig { params(ctx: CapabilityHelper::CaptureContext, name: String, info: SymbolEntry, node: AST::Identifier).void }
  def record_capture_move!(ctx, name, info, node)
    T.bind(self, SemanticAnnotator) rescue nil
    @capture_move_suppressed = T.let(@capture_move_suppressed, T.nilable(Integer))
    return unless ctx.mark_moves && (@capture_move_suppressed || 0).zero?
    return unless ctx.outer_scope.owned_names.include?(name)
    classify_ownership!(info) unless info.ownership_kind
    if info.capture_move_required?(@og.live?(name))
      og_set_moved(name, at_token: node.token, action: :capture)
    end
  end

  sig { params(blk: T.untyped).returns(T.untyped) }
  def without_capture_moves(&blk)
    @capture_move_suppressed = T.let(@capture_move_suppressed, T.nilable(Integer))
    @capture_move_suppressed = (@capture_move_suppressed || 0) + 1
    blk.call
  ensure
    @capture_move_suppressed = T.must(@capture_move_suppressed) - 1
  end

  sig { params(node: AST::ConcurrentOp, analysis: CapabilityHelper::CaptureAnalysis, is_parallel: T::Boolean, is_pinned: T::Boolean).returns(T.nilable(CapabilityHelper::CaptureAnalysis)) }
  def validate_capture_analysis!(node, analysis, is_parallel, is_pinned)
    T.bind(self, SemanticAnnotator) rescue nil

    if is_parallel
      if analysis.has_local
        error!(node, :LOCAL_VAR_NOT_IN_PARALLEL)
      end
      if analysis.has_rc
        error!(node, :MULTIOWNED_NOT_IN_PARALLEL)
      end
    end

    if !is_pinned && !is_parallel && analysis.has_shared
      return analysis
    end
    nil
  end
end

# ============================================================================
# CapabilityAudit — "Architecture Consultant"
# ============================================================================
# Mixed into SemanticAnnotator. Tracks capability usage patterns and
# warns about over-engineered capabilities (ghost locks, isolated shares, etc.)
module CapabilityAudit
    extend T::Sig

  sig { returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
  def capability_audit_init!
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let({}, T.untyped)
  end

  # Record a capability binding for later audit.
  sig { params(var_name: String, node: T.untyped, final_type: T.untyped, storage: Symbol).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def record_capability_binding(var_name, node, final_type, storage)
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let(@capability_audit, T.untyped)
    return unless var_name.is_a?(String) && current_fn_ctx&.name

    info = current_scope.locals[var_name]
    sync = info&.sync
    own  = storage if storage == :multiowned || storage == :shared
    return unless sync || own

    # Skip PUB functions — libraries can't know how consumers will use exports.
    fn_name = current_fn_ctx&.name
    @fn_nodes = T.let(@fn_nodes, T.nilable(T::Hash[String, AST::FunctionDef]))
    fn_nodes = T.must(@fn_nodes)
    fn_node = fn_name ? fn_nodes[fn_name] : nil
    return if fn_node&.visibility == :pub

    key = "#{current_fn_ctx&.name}:#{var_name}"
    line   = node.token&.line
    column = node.token&.column
    ft = final_type.is_a?(Type) ? final_type : nil
    is_sharded = ft&.respond_to?(:sharded?) && ft.sharded?
    @capability_audit[key] = {
      fn: current_fn_ctx&.name, var: var_name, line: line, column: column,
      sync: sync, ownership: own, storage: storage, sharded: is_sharded,
      mutated: false, captured_bg: false, captured_parallel: false
    }
  end

  sig { params(var_name: String).returns(T.nilable(T::Boolean)) }
  def audit_mark_mutated(var_name)
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let(@capability_audit, T.untyped)
    return unless current_fn_ctx&.name
    key = "#{current_fn_ctx&.name}:#{var_name}"
    @capability_audit[key][:mutated] = true if @capability_audit[key]
  end

  sig { returns(T::Hash[String, T::Hash[Symbol, T.untyped]]) }
  def finalize_capability_audit!
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let(@capability_audit, T.untyped)
    @capability_audit.each do |_key, info|
      loc = info[:line] ? " (line #{info[:line]})" : ""
      sync = info[:sync]
      own  = info[:ownership]

      if SymbolEntry.locked_family_sync?(sync) && !info[:mutated] && !info[:sharded]
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info[:var]}' is @#{sync} but never mutated via WITH EXCLUSIVE. " \
                     "You are paying for lock acquire/release on every access. Consider @local or removing the lock.#{loc}"
      end

      if own == :shared && !info[:captured_parallel]
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info[:var]}' is @shared (Arc) but never leaves the local scheduler. " \
                     "You are paying for atomic ref-counting but never crossing cores. Consider @multiowned or @local.#{loc}"
      end

      if SymbolEntry.local_sync?(sync) && !info[:captured_bg]
        emit_local_never_shared_finding!(info)
      end
    end
  end

end
