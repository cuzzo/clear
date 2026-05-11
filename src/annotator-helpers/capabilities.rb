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

  # Capability groups — at most one from each group is allowed.
  GROUPS = T.let({
    ownership: %i[multiowned shared],
    sync:      %i[locked write_locked local],
    layout:    %i[soa],
  }.freeze, T::Hash[Symbol, T::Array[Symbol]])

  # Capabilities that are mutually exclusive with each other.
  Conflict = Struct.new(:set_a, :set_b, :message)
  CONFLICTS = T.let([
    Conflict.new([:soa],     [:shared, :multiowned], "SOA layout is incompatible with reference-counted ownership"),
    Conflict.new([:arena],   [:parallel],            "@arena cannot be combined with @parallel — arena memory is thread-local"),
    Conflict.new([:local],   [:parallel],            "@local requires single-scheduler affinity, incompatible with @parallel"),
  ].freeze, T::Array[T.untyped])

  sig { params(type: Type).returns(T::Array[T.untyped]) }
  def self.errors_for(type)
    return [] unless type.is_a?(Type)

    errors = []
    caps = active_capabilities(type)

    GROUPS.each do |group_name, members|
      active = members.select { |c| caps.include?(c) }
      if active.size > 1
        errors << "Conflicting #{group_name} capabilities: #{active.map { |c| "@#{c}" }.join(' and ')}. Only one #{group_name} capability is allowed."
      end
    end

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

  # WITH can be applied to an Identifier or a GetField (`obj.field`).
  # For an Identifier, sync/ownership lives on the SymbolEntry. For a
  # GetField, it lives on the field's declared type (recorded on the
  # struct schema and projected onto the GetField node's full_type
  # during annotation). These helpers paper over the difference so the
  # rest of the WITH logic doesn't have to.
  sig { params(var_node: T.untyped).returns(T.nilable(Symbol)) }
  def cap_var_sync(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    sym_sync = var_node.symbol&.sync
    return sym_sync if sym_sync
    return var_node.full_type.sync if var_node.full_type.is_a?(Type)
    nil
  end

  sig { params(var_node: AST::Identifier).returns(T.nilable(Symbol)) }
  def cap_var_storage(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    sym = var_node.symbol
    return sym.storage if sym
    if var_node.full_type.is_a?(Type)
      case T.must(var_node.full_type).ownership
      when :shared     then return :shared
      when :multiowned then return :multiowned
      end
    end
    nil
  end

  # Read layout from the SymbolEntry when available, or from full_type before
  # symbol binding has completed. Mirrors cap_var_sync / cap_var_storage.
  sig { params(var_node: AST::Identifier).returns(T.nilable(Symbol)) }
  def cap_var_layout(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    sym_layout = var_node.symbol&.layout
    return sym_layout if sym_layout
    return T.must(var_node.full_type).layout if var_node.full_type.is_a?(Type)
    nil
  end

  # Validate that a capability type is legal for the given variable.
  sig { params(node: AST::WithBlock, capability_type: Symbol, var_node: T.untyped).returns(T.nilable(T::Array[T::Hash[T.untyped, T.untyped]])) }
  def validate_capability(node, capability_type, var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    @deferred_with_validations = T.let(@deferred_with_validations, T.untyped)
    var_type = var_node.full_type
    allowed = T.let([AST::Identifier, AST::GetField], T::Array[T::Class[T.untyped]])
    allowed << AST::GetIndex if capability_type == :BORROWED
    unless allowed.any? { |t| var_node.is_a?(t) }
      error!(var_node, :WITH_CAP_BAD_TARGET, capability: capability_type, got: var_node.class)
    end

    case capability_type
    when :EXCLUSIVE
      syn = cap_var_sync(var_node)
      unless syn
        # Function parameters may not have propagated sync yet; locals error
        # eagerly because no later propagation can fix them.
        if var_node.symbol&.is_param
          @deferred_with_validations << {
            node: node, var_node: var_node, capability: :EXCLUSIVE
          }
        else
          storage = cap_var_storage(var_node)
          name = var_node.respond_to?(:name) ? var_node.name : var_node.field
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
          @deferred_with_validations << {
            node: node, var_node: var_node, capability: :write_locked_read
          }
        else
          name = var_node.respond_to?(:name) ? var_node.name : var_node.field
          emit_with_read_needs_write_lock!(node, name, var_node)
        end
      end

    when :RESTRICT
      if var_node.symbol && !var_node.symbol.mutable
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
        emit_view_not_observable_finding!(node, var_node, t)
      end

    when :MATERIALIZED_VIEW
      # Any tense aggregate is allowed; non-tense sources are rejected.
      t = var_type.is_a?(Type) ? var_type : Type.new(var_type)
      unless t.future?
        name = var_node.respond_to?(:name) ? var_node.name : var_node.field
        emit_with_materialized_needs_tense!(node, name, t.resolved)
      end

    when :SNAPSHOT
      # Versioned cells and indirect atomic cells share the WITH SNAPSHOT
      # surface; lowering chooses the Guard or update/CAS path per capability.
      syn = cap_var_sync(var_node)
      lay = cap_var_layout(var_node)
      atomic_ptr_ok = syn == :atomic && lay == :indirect
      unless syn == :versioned || atomic_ptr_ok
        name = var_node.respond_to?(:name) ? var_node.name : var_node.field
        actual = if syn && lay == :indirect
          "@#{lay}:#{syn}"
        elsif syn
          "@#{syn}"
        elsif cap_var_storage(var_node)
          "@#{cap_var_storage(var_node)}"
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
        name = var_node.respond_to?(:name) ? var_node.name : var_node.field
        emit_with_cap_mismatch!(node, name, :WITH_NEEDS_MULTIOWNED,
          [{ sigil: '@multiowned',
             description: "Add `@multiowned` to '#{name}' (Rc — single-scheduler refcount; cheap clones via WITH)." }],
          confidence: :auto,
          name: name)
      end

    when :shared
      unless cap_var_storage(var_node) == :shared
        name = var_node.respond_to?(:name) ? var_node.name : var_node.field
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
          @deferred_with_validations << {
            node: node, var_node: var_node, capability: :ATOMIC
          }
        else
          name = var_node.respond_to?(:name) ? var_node.name : var_node.field
          actual = syn ? "@#{syn}" : (cap_var_storage(var_node) ? "@#{cap_var_storage(var_node)}" : "plain")
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
    @current_predicate_context = T.let(@current_predicate_context, T.untyped)
    ctx = @current_predicate_context
    return unless ctx
    return if %w[TRUE FALSE].include?(node.name)

    case ctx[:kind]
    when :guard
      own_alias = ctx[:alias]
      return if node.name == own_alias

      sibling_aliases = ctx[:sibling_aliases] || []
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
      params = ctx[:param_names] || []
      return if params.include?(node.name)
      emit_typo_suggestion!(
        node.token, node.name, params,
        "PRE clauses may only reference function parameters. " \
        "Found '#{node.name}', which is not a parameter of '#{ctx[:fn_name]}'.",
        "a parameter of '#{ctx[:fn_name]}'",
        category: :type, cascade: true)
    when :post
      allowed = ctx[:allowed_names] || []
      rejected = ctx[:rejected_param_names] || Set.new
      unless allowed.include?(node.name)
        return emit_typo_suggestion!(
          node.token, node.name, allowed,
          "DEBUG_POST clauses may only reference function parameters or 'result'. " \
          "Found '#{node.name}', which is not in scope for '#{ctx[:fn_name]}'.",
          "a parameter of '#{ctx[:fn_name]}' or 'result'",
          category: :type, cascade: true)
      end
      if rejected.include?(node.name)
        error!(node, :DEBUG_POST_NEEDS_UNSYNC_PARAM, name: node.name)
      end
    end
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Array[T::Hash[T.untyped, T.untyped]])) }
  def record_predicate_call_site!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.untyped)
    @predicate_call_sites = T.let(@predicate_call_sites, T.untyped)
    ctx = @current_predicate_context
    return unless ctx
    @predicate_call_sites << {
      kind:       ctx[:kind],
      with_node:  ctx[:with_node],
      fn_node:    ctx[:fn_node],
      pred_expr:  ctx[:pred_expr],
      call:       node,
      callee:     node.name,
    }
  end

  sig { returns(T.nilable(T::Array[T.untyped])) }
  def validate_predicate_purity!
    T.bind(self, SemanticAnnotator) rescue nil
    @predicate_call_sites = T.let(@predicate_call_sites, T.untyped)
    (@predicate_call_sites || []).each do |site|
      call = site[:call]
      callee = site[:callee]
      reason = predicate_impurity_reason(call, callee)
      next unless reason

      surface, hint = case site[:kind]
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

  sig { params(call: T.untyped, callee: String).returns(T.nilable(String)) }
  def predicate_impurity_reason(call, callee)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    return "is an extern call" if call.respond_to?(:extern_call) && call.extern_call
    return "has extern effects" if call.respond_to?(:extern_effects) && call.extern_effects && !call.extern_effects.empty?
    return "can fail" if call.respond_to?(:can_fail) && call.can_fail
    if call.matched_stdlib_def
      md = call.matched_stdlib_def
      return "allocates" if md[:allocates]
      return "can fail" if md[:can_fail]
      return "suspends" if md[:suspends]
      return "mutates its receiver" if md[:mutates_receiver]
      return nil
    end

    fn = @fn_nodes[callee] if callee.is_a?(String)
    return nil unless fn
    return "can fail" if fn.can_fail
    effects = fn.effects || Set.new
    return nil if effects.empty?
    "has effects #{effects.map { |e| EffectTracker.display(e) }.sort.join(', ')}"
  end

  sig { params(node: AST::WithBlock).returns(T.nilable(T::Array[T::Hash[T.untyped, T.untyped]])) }
  def validate_and_visit_with_guards!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.untyped)
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
        @current_predicate_context = {
          kind: :guard, with_node: node, pred_expr: gcap[:guard_expr],
          alias: own, sibling_aliases: siblings,
        }
        visit(gcap[:guard_expr])

        guard_type = gcap[:guard_expr].type_info
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
  sig { params(fn_node: AST::FunctionDef).returns(T.nilable(T::Array[T::Hash[T.untyped, T.untyped]])) }
  def visit_pre_clauses!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    @current_predicate_context = T.let(@current_predicate_context, T.untyped)
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

    param_names = (fn_node.params || []).map { |p| p[:name].to_s }
    prev_ctx = @current_predicate_context
    begin
      pre_clauses.each do |entry|
        expr = entry[:expr]
        @current_predicate_context = {
          kind: :pre, fn_node: fn_node, pred_expr: expr,
          param_names: param_names, fn_name: fn_node.name,
        }
        visit(expr)

        pred_type = expr.type_info
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
    @current_predicate_context = T.let(@current_predicate_context, T.untyped)
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

    param_names = (fn_node.params || []).map { |p| p[:name].to_s }
    rejected = (fn_node.params || []).filter_map do |p|
      sym = current_scope.locals[p[:name].to_s]
      next unless sym && %i[locked write_locked versioned atomic].include?(sym.sync)
      p[:name].to_s
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
          @current_predicate_context = {
            kind: :post, fn_node: fn_node, pred_expr: expr,
            allowed_names: allowed_names, rejected_param_names: rejected,
            fn_name: fn_node.name,
          }
          visit(expr)

          pred_type = expr.type_info
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
  sig { params(node: AST::WithBlock, cap: T::Hash[Symbol, T.untyped], expanded: T::Array[T::Hash[T.untyped, T.untyped]]).returns(T.untyped) }
  def acquire_capability!(node, cap, expanded)
    T.bind(self, SemanticAnnotator) rescue nil
    var_node = cap[:var_node]
    visit(var_node)
    cap[:resolved_type] = var_node.full_type

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
                           name = var_node.respond_to?(:name) ? var_node.name : var_node.field
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

      fields = schema.is_a?(Schemas::StructSchema) ? schema.fields : schema
      fields.each do |field_name, _|
        field_node = AST::GetField.new(var_node.token, var_node.target, field_name)
        expanded << {
          capability: cap[:capability],
          var_node: field_node,
          old_scope: cap[:old_scope]
        }
      end
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
    case var_node
    when AST::Identifier then var_node.name
    when AST::GetField   then var_node.name
    when AST::GetIndex   then var_node.target.is_a?(AST::Identifier) ? var_node.target.name : "__idx"
    else "__unknown"
    end
  end

  sig { params(cap: T::Hash[Symbol, T.untyped]).returns(T.nilable(String)) }
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
      inner_type = cap[:var_node].full_type
      if inner_type.is_a?(Type) && (inner_type.any_sync? || inner_type.ownership != :affine)
        inner_type = inner_type.bare_data_type
      end
      alias_name = cap[:alias] || var_name
      current_scope.declare(alias_name, nil, inner_type, true, false, nil, :stack)
      current_scope.locals[alias_name].non_escaping = true
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
      current_scope.locals[alias_name].non_escaping = true
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
        resolved_type = capability_alias_type(cap[:resolved_type] || cap[:old_scope]&.resolve_type(var_name) || :Any)
        current_scope.declare(alias_name, nil, resolved_type, is_mutable, false, nil, :stack)
        sym = current_scope.locals[alias_name]
        sym.non_escaping  = true
        sym.borrowed_alias = true  # RESTRICT alias: fiber capture is stack-UAF
        og_declare(alias_name, nil, resolved_type)
      end
    elsif cap[:capability] == :VIEW || cap[:capability] == :MATERIALIZED_VIEW
      # Observables Phase 2.3 / 2.4. Bind alias to `?T` where T is the
      # inner element type of the tense source. VIEW is immutable +
      # non_escaping (borrow); MATERIALIZED_VIEW is owned and may escape.
      source_type = cap[:resolved_type] || cap[:old_scope]&.resolve_type(var_name)
      st = source_type.is_a?(Type) ? source_type : Type.new(source_type)
      inner = st.future? && st.tense_type ? st.tense_type : st
      # Wrap as ?T so the binding is null until the first item lands.
      # If `inner` is already optional (FIND yields `~?T@observable`,
      # whose tense_type is `?T`), don't double-wrap into `??T`.
      bind_type_sym = inner.optional? ? inner.resolved : :"?#{inner.resolved}"
      alias_name = cap[:alias] || var_name
      current_scope.declare(alias_name, nil, bind_type_sym, false, false, nil, :stack)
      sym = current_scope.locals[alias_name]
      if cap[:capability] == :VIEW
        sym.non_escaping  = true
        sym.borrowed_alias = true
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
      source_type = cap[:resolved_type] || cap[:old_scope]&.resolve_type(var_name)
      st = source_type.is_a?(Type) ? source_type : Type.new(source_type)
      # Strip Group-1 sigils so the alias's `.type` is the bare inner T.
      # The alias's SymbolEntry already keeps sync/layout=nil (declare
      # call below passes neither), but type-side downstream paths
      # (resolve_type / full_type readers) shouldn't see leftover
      # @versioned / @indirect:atomic flags on the alias's Type.
      strip = st.versioned? ||
              (st.respond_to?(:atomic?) && st.atomic? &&
               st.respond_to?(:indirect?) && st.indirect?)
      inner_type = strip ? st.bare_data_type : st
      alias_name = cap[:alias] || var_name
      is_mutable = !!cap[:alias_mutable]
      current_scope.declare(alias_name, nil, inner_type, is_mutable, false, nil, :stack)
      sym = current_scope.locals[alias_name]
      sym.non_escaping  = true
      sym.borrowed_alias = true
      og_declare(alias_name, nil, inner_type)
    elsif cap[:capability] == :BORROWED
      # BORROWED guarantees the aliased data is stable for the borrow duration.
      # @shared/@locked/@multiowned types can be concurrently written — the
      # stability guarantee cannot be upheld. Reject them at the borrow site.
      source_sym = cap[:old_scope]&.locals&.[](var_name)
      if source_sym
        bad_storage = source_sym.storage == :shared || source_sym.storage == :multiowned
        bad_sync    = source_sym.sync == :locked || source_sym.sync == :write_locked
        if bad_storage || bad_sync
          qualifier = if source_sym.storage == :shared then "@shared"
                      elsif source_sym.storage == :multiowned then "@multiowned"
                      elsif source_sym.sync == :locked then "@locked"
                      else "@writeLocked"
                      end
          remediation = "BORROWED guarantees the data is stable, but #{qualifier} data can be " \
                        "modified concurrently. Use WITH #{var_name} { } to access it safely instead."
          error!(cap[:var_node], :WITH_BORROWED_ON_QUALIFIED_VAR, qualifier: qualifier, name: var_name, remediation: remediation)
        end
      end
      alias_name = cap[:alias] || var_name
      resolved_type = capability_alias_type(cap[:resolved_type] || cap[:old_scope]&.resolve_type(var_name) || :Any)
      current_scope.declare(alias_name, nil, resolved_type, false, false, nil, :stack)
      sym = current_scope.locals[alias_name]
      sym.non_escaping  = true
      sym.borrowed_alias = true  # BORROWED alias: fiber capture is stack-UAF
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

  # --- Fiber capture analysis (shared by BG and DO blocks) ---

  # Result of analyzing a fiber body's captured variables.
  # Computed once per body by analyze_fiber_captures, queried by multiple consumers.
  CaptureAnalysis = Struct.new(
    :has_local,        # captures @local var (sync == :local)
    :has_rc,           # captures @multiowned (Rc) var
    :has_shared,       # captures any shared/locked/write_locked/local/multiowned/sharded var
    :has_sharded,      # specifically captures @sharded (for auto-pin reason)
    :has_affine_locked, # captures affine @locked (not @shared) -- needs spawnPinned
    :has_outer_ref,    # references any outer-scope variable
    :has_non_escaping_capture, # captures a non_escaping (BORROWED/RESTRICT) binding -- UAF risk
    :captures,         # Hash<name => type_obj> for code generation
    :capture_symbols,  # Hash<name => SymbolEntry> -- live entry for late re-resolution
                       # of sync/storage stamps that propagate_caller_sync! adds AFTER
                       # the BG body was visited (params receiving @shared:locked from
                       # callers). mir_lowering reads the entry's CURRENT sync/storage
                       # to overlay onto the cached type, which fixes the BG ctx field
                       # type-mismatch repro'd by transpile-tests/253_bg_capture_locked_param.cht.
    :close_patterns,   # Hash<name => close_zig_string> for resource cleanup
    :pointer_captures, # Set<name> - captures needing *T pointer passing
    :string_captures,  # Set<name> - string captures needing defer free in fiber
    :resource_captures, # Set<name> - resource captures needing move suppression
    # ── Phase 2: site_info collected during the same single walk.
    # Names the user wrapped in GIVE/MOVE (moved) and COPY/CLONE (copied)
    # at the BG capture site. Replaces the separate Pass-4 walk in
    # mir_lowering.collect_bg_capture_site_info. Authority: this walk.
    :site_moved,       # Set<name> -- user wrote GIVE x at BG site
    :site_copied,      # Set<name> -- user wrote COPY/CLONE x at BG site
    # ── Phase 3: derived facts produced by BgCaptureClassifier (after
    # propagate_caller_sync! has finalized SymbolEntry stamps).
    # Authority: BgCaptureClassifier.classify_one!. Every downstream
    # consumer reads these instead of re-walking the BG body.
    :strategies,        # Hash<name => CaptureStrategy::*>
    :heap_promote_names,# Set<name> -- needs heap promotion at decl
    :move_mark_names,   # Set<name> -- needs MIR::SuppressCleanup at outer scope
    :alloc_mark_entries,# Hash<name => alloc_sym> -- FreshHeapCopy markers
    keyword_init: true
  ) do
    extend T::Sig
    sig { returns(Symbol) }
    def pin_reason; has_sharded ? :sharded : :shared; end
  end

  # Single walk over a fiber body that computes ALL capture properties at once.
  # Replaces 6 separate walks (_captures_with_storage?, _captures_with_sync?,
  # _captures_shared?, _auto_pin_reason, _has_outer_ref?, _audit_walk_captures).
  sig { params(body_exprs: T::Array[T.untyped], is_parallel: T.nilable(T::Boolean)).returns(CapabilityHelper::CaptureAnalysis) }
  def analyze_fiber_captures(body_exprs, is_parallel: false)
    T.bind(self, SemanticAnnotator) rescue nil
    result = CaptureAnalysis.new(
      has_local: false, has_rc: false, has_shared: false,
      has_sharded: false, has_affine_locked: false, has_outer_ref: false,
      has_non_escaping_capture: false,
      captures: {}, capture_symbols: {}, close_patterns: {},
      pointer_captures: Set.new, string_captures: Set.new, resource_captures: Set.new,
      site_moved: Set.new, site_copied: Set.new,
      strategies: nil, heap_promote_names: nil, move_mark_names: nil, alloc_mark_entries: nil
    )
    _unified_capture_walk(body_exprs, Set.new, result, is_parallel)
    result
  end

  # Validate capture safety using pre-computed analysis.
  sig { params(node: AST::ConcurrentOp, body: T::Array[T.untyped], is_parallel: T::Boolean, is_pinned: T::Boolean).returns(T.nilable(CapabilityHelper::CaptureAnalysis)) }
  def validate_fiber_captures!(node, body, is_parallel, is_pinned)
    T.bind(self, SemanticAnnotator) rescue nil
    analysis = analyze_fiber_captures(body, is_parallel: is_parallel)

    if is_parallel
      if analysis.has_local
        error!(node, :LOCAL_VAR_NOT_IN_PARALLEL)
      end
      if analysis.has_rc
        error!(node, :MULTIOWNED_NOT_IN_PARALLEL)
      end
    end

    if !is_pinned && !is_parallel && analysis.has_shared
      return analysis  # caller should set pinned = true; return analysis for pin_reason
    end
    nil
  end

  # Walk a BG block's body AST and mark any outer-scope resource, affine, or
  # frame-allocated variables as :moved. Stops at nested BgBlock boundaries.
  sig { params(stmts: T::Array[T.untyped], scope: Scope, locally_bound: T::Set[String]).returns(T::Array[T.untyped]) }
  def walk_bg_capture_moves(stmts, scope, locally_bound)
    T.bind(self, SemanticAnnotator) rescue nil
    stmts.each { |expr| _bg_walk(expr, scope, locally_bound) }
  end

  # Returns true if body references any outer-scope variable not in locally_bound.
  sig { params(body: T.untyped, locally_bound: T::Set[String]).returns(T::Boolean) }
  def captures_outer_variables?(body, locally_bound)
    T.bind(self, SemanticAnnotator) rescue nil
    result = CaptureAnalysis.new(
      has_local: false, has_rc: false, has_shared: false,
      has_sharded: false, has_affine_locked: false, has_outer_ref: false,
      has_non_escaping_capture: false,
      captures: {}, capture_symbols: {}, close_patterns: {},
      pointer_captures: Set.new, string_captures: Set.new, resource_captures: Set.new,
      site_moved: Set.new, site_copied: Set.new,
      strategies: nil, heap_promote_names: nil, move_mark_names: nil, alloc_mark_entries: nil
    )
    _unified_capture_walk(body, locally_bound, result, false)
    result.has_outer_ref
  end

  private

  # One recursive walk that checks each outer-scope identifier for ALL properties.
  sig { params(nodes: T::Array[T.untyped], locally_bound: T::Set[String], result: CapabilityHelper::CaptureAnalysis, is_parallel: T.nilable(T::Boolean)).returns(T::Array[T.untyped]) }
  def _unified_capture_walk(nodes, locally_bound, result, is_parallel)
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let(@capability_audit, T.untyped)
    name = T.let(nil, T.untyped)
    info = T.let(nil, T.untyped)
    key  = T.let(nil, T.untyped)
    nodes.each do |node|
      next unless node.is_a?(AST::Locatable)

      # Track locally-declared names so we don't treat them as outer captures.
      if (node.is_a?(AST::BindExpr) || node.is_a?(AST::VarDecl)) && node.name.is_a?(String)
        locally_bound = locally_bound | Set[node.name]
      end
      if (node.is_a?(AST::ForRange) || node.is_a?(AST::ForEach)) && node.var_name.is_a?(String)
        locally_bound = locally_bound | Set[node.var_name]
      end

      # Site-info collection (Phase 2): every MoveNode/CopyNode/CloneNode
      # wrapping a captured outer-scope Identifier is the user's GIVE/COPY/
      # CLONE intent at the BG site. Recorded ONCE here so downstream
      # passes don't re-walk the body. The capture tracker (lines below)
      # uses `result.captures.key?(name)` — but at first-encounter time
      # the capture might not be registered yet. We don't gate on that;
      # we record every wrapped outer-scope Identifier and let the
      # classifier filter against the eventual captures dict.
      if node.is_a?(AST::MoveNode) && node.value.is_a?(AST::Identifier)
        nm = node.value.name.to_s
        result.site_moved << nm unless locally_bound.include?(nm)
      end
      if (node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode)) && node.value.is_a?(AST::Identifier)
        nm = node.value.name.to_s
        result.site_copied << nm unless locally_bound.include?(nm)
      end
      # Phase 3 (was_moved CopyNode wrapper produced by ensure_owned_value!):
      # function_analysis.rb stamps was_moved=true on a CopyNode wrapper that
      # encodes the user's GIVE intent for type adaptation. Treat as moved.
      if node.is_a?(AST::CopyNode) && node.was_moved &&
         node.value.is_a?(AST::Identifier)
        nm = node.value.name.to_s
        result.site_moved << nm unless locally_bound.include?(nm)
      end

      if node.is_a?(AST::Identifier)
        name = node.name
        next if locally_bound.include?(name)
        next if %w[TRUE FALSE VOID _].include?(name)

        info = current_scope.locals[name]
        # Fallback: the symbol was resolved during visit_Identifier and stored on the node.
        # Use it when current_scope lookup misses (e.g. inside DO branches with deep nesting).
        resolved_sym = info || node.symbol
        result.has_non_escaping_capture = true if resolved_sym&.borrowed_alias
        if info
          result.has_outer_ref = true

          # Collect capture for code generation (type_info + close pattern).
          # Use the AST node's type_info (matches transpiler's walk_do_identifiers).
          # Atomic reads narrow type_info to the bare inner T, but BG captures
          # need the full cell shape so the captured ref keeps identity across
          # fibers.
          unless result.captures.key?(name)
            cap_type = info.sync == :atomic ? info.type : node.type_info
            result.captures[name] = cap_type
            # Record the live SymbolEntry so mir_lowering can re-resolve the
            # capture's actual type after EscapeAnalysis.propagate_caller_sync!
            # has stamped sync/storage on params (which happens AFTER this walk).
            result.capture_symbols[name] = info

            # Pre-compute per-capture metadata for transpiler.
            t = cap_type.is_a?(Type) ? cap_type : Type.new(cap_type || :Any)
            result.pointer_captures << name if t.needs_pointer_passing?
            result.string_captures << name if t.string?
            result.resource_captures << name if t.resource? || info.close_zig
            # Plain string-keyed HashMap captures (no @sharded / @shared /
            # @locked / @multiowned wrappers): same MoveInto pattern as
            # @set / @pool. CheatLib.StringMap stores its own allocator
            # internally; the 2-arg deinit signature is `(self, key_alloc,
            # bucket_alloc)` — both args are ignored, self.alloc drives
            # the actual frees. Wrapped variants take the RcClone /
            # safe-shared path in the classifier and don't need this.
            if t.map? && !t.numeric_map? && !info.close_zig &&
               !t.sharded? && !(t.respond_to?(:striped?) && t.striped?) &&
               !t.shared? && !t.multiowned? &&
               !(t.respond_to?(:any_sync?) && t.any_sync?)
              result.resource_captures << name
              result.close_patterns[name] ||= "{0}.deinit(rt.heapAlloc(), rt.heapAlloc())"
            end
          end
          if info.close_zig
            result.close_patterns[name] ||= info.close_zig
          end

          result.has_local   = true if info.sync == :local
          result.has_rc      = true if info.storage == :multiowned
          ti = info.type
          # shared+striped maps (DashMap) are self-synchronizing — per-shard locking
          # means any thread can access any shard without pinning. Skip has_shared
          # so BG blocks are NOT auto-pinned, enabling work stealing.
          # Non-shared striped maps (@sharded(N):locked without @shared) MUST be pinned
          # because the map is affine-owned and concurrent access without Arc is unsafe.
          is_dashmap = ti.is_a?(Type) && ti.striped? && (ti.shared? || ti.multiowned?)
          # @shared:atomic is self-synchronizing; pinning would defeat the
          # cross-thread parallelism that atomic storage is meant to allow.
          is_atomic = info.sync == :atomic
          unless is_dashmap || is_atomic
            result.has_shared  = true if info.sync == :locked || info.sync == :write_locked || info.sync == :local
            result.has_shared  = true if info.storage == :shared || info.storage == :multiowned
            # Affine @locked: not backed by Arc, needs spawnPinned for scheduler affinity
            if (info.sync == :locked || info.sync == :write_locked) && info.storage != :shared && info.storage != :multiowned
              result.has_affine_locked = true
            end
            if ti.is_a?(Type) && ti.sharded?
              result.has_sharded = true
              result.has_shared  = true
            end
          end

          # Audit: mark capability usage for over-engineering warnings
          if current_fn_ctx&.name
            key = "#{current_fn_ctx.name}:#{name}"
            if @capability_audit&.dig(key)
              @capability_audit[key][:captured_bg] = true
              @capability_audit[key][:captured_parallel] = true if is_parallel
            end
          end
        elsif lookup_scope_for(name)
          result.has_outer_ref = true
        end
        next
      end

      # WithBlock: check var_nodes for sync/shared captures
      if node.is_a?(AST::WithBlock) && node.capabilities.is_a?(Array)
        node.capabilities.each do |cap|
          var_node = cap[:var_node]
          next unless var_node.is_a?(AST::Identifier)
          name = var_node.name
          next if locally_bound.include?(name)
          info = current_scope.locals[name]
          next unless info
          result.has_outer_ref = true
          result.captures[name] ||= var_node.type_info
          # Also record the live SymbolEntry so mir_lowering can re-resolve
          # types after EscapeAnalysis.propagate_caller_sync! stamps params.
          result.capture_symbols[name] ||= info
          if info.close_zig
            result.close_patterns[name] ||= info.close_zig
          end
          result.has_local  = true if info.sync == :local
          result.has_shared = true if info.sync == :locked || info.sync == :write_locked || info.sync == :local
          result.has_shared = true if info.storage == :shared
          if (info.sync == :locked || info.sync == :write_locked) && info.storage != :shared && info.storage != :multiowned
            result.has_affine_locked = true
          end

          if current_fn_ctx&.name
            key = "#{current_fn_ctx.name}:#{name}"
            if @capability_audit&.dig(key)
              @capability_audit[key][:captured_bg] = true
              @capability_audit[key][:captured_parallel] = true if is_parallel
            end
          end
        end

        # lock_error_clause is an attr_accessor (not a Struct member), so
        # the generic walk below misses it. Descend explicitly so any
        # outer-scope vars used in the action's message/body are
        # captured by the enclosing BG/DO/fiber.
        if (clause = node.lock_error_clause)
          _unified_capture_walk([clause[:message]], locally_bound, result, is_parallel) if clause[:message]
          _unified_capture_walk(clause[:body], locally_bound, result, is_parallel) if clause[:body].is_a?(Array)
        end

        # WITH-block aliases (the AS-bound names) are declared inside the
        # WITH scope -- references to them in the body are NOT outer
        # captures, even though their underlying SymbolEntry has
        # borrowed_alias=true. Without this, capturing an
        # @shared:versioned cell into a `BG { WITH SNAPSHOT c AS view
        # ... }` is wrongly rejected: the walker sees `view` in the body,
        # resolves it through node.symbol to the borrowed_alias=true
        # SymbolEntry, and flags the BG as capturing a WITH-scoped
        # binding. Add alias names + per-arm aliases to locally_bound for
        # the recursive walk into body / arms below.
        with_locally_bound = locally_bound
        node.capabilities.each do |cap|
          a = cap[:alias]
          with_locally_bound = with_locally_bound | Set[a] if a.is_a?(String)
        end
        if node.body.is_a?(Array)
          _unified_capture_walk(node.body, with_locally_bound, result, is_parallel)
        end
        node.arms&.each do |arm|
          _unified_capture_walk(arm[:body], with_locally_bound, result, is_parallel) if arm[:body].is_a?(Array)
        end
        # Skip the generic-member descent below -- we just walked the
        # body / arms with the augmented locally_bound set.
        next
      end

      # Don't recurse into nested BG/DO blocks — they have their own capture scope.
      next if node.is_a?(AST::BgBlock) || node.is_a?(AST::DoBlock)

      # ThenChain.steps is an Array of Hashes (`{ expr:, binding: }`), not
      # AST::Locatable nodes — the generic Struct-member walk below would
      # skip them because the `next unless Locatable` filter rejects each
      # Hash. Recurse explicitly so the chain's expressions contribute to
      # the BG block's capture set.
      if node.is_a?(AST::ThenChain)
        bound_in_chain = locally_bound.dup
        (node.steps || []).each do |step|
          if step.is_a?(Hash)
            _unified_capture_walk([step[:expr]], bound_in_chain, result, is_parallel) if step[:expr]
            bound_in_chain = bound_in_chain | Set[step[:binding].to_s] if step[:binding]
          end
        end
        next
      end

      node.class.members.each do |member|
        val = node[member]
        if val.is_a?(Array)
          _unified_capture_walk(val, locally_bound, result, is_parallel)
        elsif val.is_a?(AST::Locatable)
          _unified_capture_walk([val], locally_bound, result, is_parallel)
        end
      end
    end
  end

  sig { params(node: T.untyped, scope: Scope, locally_bound: T::Set[String]).returns(T.nilable(T::Array[Symbol])) }
  def _bg_walk(node, scope, locally_bound)
    T.bind(self, SemanticAnnotator) rescue nil
    @og = T.let(@og, T.untyped)
    return unless node.is_a?(AST::Locatable)
    return if node.is_a?(AST::BgBlock)

    # COPY x / CLONE x at a BG capture site does NOT move x. COPY deep-
    # copies into the fiber; CLONE retains an Rc/Arc. The outer binding
    # remains live. Only MoveNode (GIVE) and bare captures of resource/
    # affine values trigger the move below.
    return if node.is_a?(AST::CopyNode) || node.is_a?(AST::CloneNode) || node.is_a?(AST::FreezeNode)

    if node.is_a?(AST::Identifier)
      name = node.name
      return if locally_bound.include?(name)
      info = scope.locals[name]
      return unless info && scope.owned_names.include?(name)
      classify_ownership!(info) unless info.ownership_kind
      kind = info.ownership_kind
      ti = info.type
      if @og.live?(name)
        if kind == :resource || kind == :affine
          og_set_moved(name, at_token: node.token, action: :capture)
        elsif ti.is_a?(Type) && ti.needs_escape_promotion?
          og_set_moved(name, at_token: node.token, action: :capture)
        end
      end
      return
    end

    lb = locally_bound
    if node.is_a?(AST::BindExpr) || node.is_a?(AST::VarDecl)
      lb = lb | Set[node.name.to_s] if node.name.is_a?(String)
    end
    if node.is_a?(AST::ForRange) || node.is_a?(AST::ForEach)
      lb = lb | Set[node.var_name.to_s] if node.var_name.is_a?(String)
    end

    node.class.members.each do |member|
      val = node[member]
      if val.is_a?(Array)
        val.each { |v| _bg_walk(v, scope, lb) }
      elsif val.is_a?(AST::Locatable)
        _bg_walk(val, scope, lb)
      end
    end
  end
end

# ============================================================================
# CapabilityAudit — "Architecture Consultant"
# ============================================================================
# Mixed into SemanticAnnotator. Tracks capability usage patterns and
# warns about over-engineered capabilities (ghost locks, isolated shares, etc.)
module CapabilityAudit
    extend T::Sig

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def capability_audit_init!
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let({}, T.untyped)
  end

  # Record a capability binding for later audit.
  sig { params(var_name: String, node: T.untyped, final_type: T.untyped, storage: Symbol).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def record_capability_binding(var_name, node, final_type, storage)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @capability_audit = T.let(@capability_audit, T.untyped)
    return unless var_name.is_a?(String) && current_fn_ctx&.name

    info = current_scope.locals[var_name]
    sync = info&.sync
    own  = storage if storage == :multiowned || storage == :shared
    return unless sync || own

    # Skip PUB functions — libraries can't know how consumers will use exports.
    fn_node = @fn_nodes[current_fn_ctx&.name]
    return if fn_node.respond_to?(:visibility) && fn_node.visibility == :pub

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

  # No longer needed — audit marking is handled by _unified_capture_walk.
  # Kept as a no-op for call-site compatibility.
  sig { params(body_exprs: T.untyped, is_parallel: T.untyped).returns(T.untyped) }
  def audit_mark_bg_captures(body_exprs, is_parallel)
    T.bind(self, SemanticAnnotator) rescue nil
  end

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def finalize_capability_audit!
    T.bind(self, SemanticAnnotator) rescue nil
    @capability_audit = T.let(@capability_audit, T.untyped)
    @capability_audit.each do |_key, info|
      loc = info[:line] ? " (line #{info[:line]})" : ""
      sync = info[:sync]
      own  = info[:ownership]

      if (sync == :locked || sync == :write_locked) && !info[:mutated] && !info[:sharded]
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info[:var]}' is @#{sync} but never mutated via WITH EXCLUSIVE. " \
                     "You are paying for lock acquire/release on every access. Consider @local or removing the lock.#{loc}"
      end

      if own == :shared && !info[:captured_parallel]
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info[:var]}' is @shared (Arc) but never leaves the local scheduler. " \
                     "You are paying for atomic ref-counting but never crossing cores. Consider @multiowned or @local.#{loc}"
      end

      if sync == :local && !info[:captured_bg]
        emit_local_never_shared_finding!(info)
      end
    end
  end

end
