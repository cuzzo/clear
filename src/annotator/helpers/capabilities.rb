# typed: strict
require "sorbet-runtime"
# capabilities.rb — Capability validation, audit, and helpers for CLEAR's type system.
#
# Three concerns, three modules:
#   Capabilities       — static validation of capability combinations on Type objects
#   CapabilityHelper   — runtime validation and inference for WITH blocks
#   CapabilityAudit    — "Architecture Consultant" that warns about over-engineered capabilities

require 'set'
require_relative "../../semantic/capture_strategy"
require_relative "../../semantic/capability_plan"

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
    nil
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

  LOCK_CAPABILITIES = T.let(Set[:EXCLUSIVE, :write_locked_read].freeze, T::Set[Symbol])
  VIEW_CAPABILITIES = T.let(Set[:VIEW, :MATERIALIZED_VIEW].freeze, T::Set[Symbol])
  BORROWED_STORAGE_QUALIFIERS = T.let({
    shared: "@shared",
    multiowned: "@multiowned",
  }.freeze, T::Hash[Symbol, String])

  WithCapabilityFact = CapabilityPlan::CapabilityTransition
  WithCapabilityFacts = T.type_alias { T::Array[WithCapabilityFact] }
  WithCapabilityExpansion = CapabilityPlan::WithCapabilityPlan

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
	    when AST::GetIndex then CapabilityPlan.var_name_for(var_node)
	    else "__unknown"
	    end
	  end

  # Validate that a typed capability transition is legal for its target.
  sig { params(node: AST::WithBlock, fact: WithCapabilityFact).void }
  def validate_capability_transition!(node, fact)
    T.bind(self, SemanticAnnotator) rescue nil
    var_node = fact.var_node
    var_type = fact.resolved_type
    unless valid_capability_target?(fact.capability, var_node)
      error!(var_node, :WITH_CAP_BAD_TARGET, capability: fact.capability, got: var_node.class)
    end

    case fact.capability
    when :EXCLUSIVE
      case fact.exclusive_validation_action
      when :valid, :declared_contract
        # REQUIRES-family parameters are checked after the body walk, once
        # the whole function's polymorphic contract is available.
      when :defer
        record_deferred_with_validation!(node, fact)
      else
        storage = fact.storage
        name = fact.target_label
        emit_with_cap_mismatch!(node, name, :WITH_EXCLUSIVE_NEEDS_LOCK,
          [
            FixableHelper::CapabilityFixCandidate.new(
              sigil: "@locked",
              description_code: :WITH_ADD_LOCKED
            ),
            FixableHelper::CapabilityFixCandidate.new(
              sigil: "@writeLocked",
              description_code: :WITH_ADD_WRITE_LOCKED,
              description_params: { reader: "can coexist via WITH READ" }
            ),
          ],
          confidence: :interactive,
          got: storage || fact.sync || 'unknown')
      end

    when :write_locked_read
      unless fact.write_locked_sync?
        if fact.deferred_sync_param?
          record_deferred_with_validation!(node, fact)
        else
          name = fact.target_label
          emit_with_read_needs_write_lock!(node, name, var_node)
        end
      end

    when :RESTRICT
      if var_node.is_a?(AST::Identifier) && var_node.symbol && !T.must(var_node.symbol).mutable
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
          emit_view_not_observable_finding!(node, fact, t)
        else
          name = fact.target_label
          error!(node, :WITH_VIEW_NEEDS_OBSERVABLE, name: name, got: t.resolved)
        end
      end

    when :MATERIALIZED_VIEW
      # Any tense aggregate is allowed; non-tense sources are rejected.
      t = var_type.is_a?(Type) ? var_type : Type.new(var_type)
      unless t.future?
        name = fact.target_label
        emit_with_materialized_needs_tense!(node, name, t.resolved)
      end

	    when :SNAPSHOT
	      # Versioned cells and indirect atomic cells share the WITH SNAPSHOT
	      # surface; lowering chooses the Guard or update/CAS path per capability.
	      snapshot_sync = fact.sync
	      snapshot_layout = fact.layout
	      atomic_ptr_ok = snapshot_sync == :atomic && snapshot_layout == :indirect
	      unless snapshot_sync == :versioned || atomic_ptr_ok
	        name = fact.target_label
	        storage = fact.storage
	        actual = if snapshot_sync && snapshot_layout == :indirect
	          "@#{snapshot_layout}:#{snapshot_sync}"
	        elsif snapshot_sync
	          "@#{snapshot_sync}"
	        elsif storage
	          "@#{storage}"
	        else
          "plain"
        end
        emit_with_cap_mismatch!(node, name, :WITH_SNAPSHOT_NEEDS_VERSIONED_OR_ATOMIC,
          [
            FixableHelper::CapabilityFixCandidate.new(
              sigil: "@versioned",
              description_code: :WITH_ADD_VERSIONED
            ),
            FixableHelper::CapabilityFixCandidate.new(
              sigil: "@indirect:atomic",
              description_code: :WITH_ADD_INDIRECT_ATOMIC
            ),
          ],
          confidence: :interactive,
          name: name, actual: actual)
      end

    when :multiowned
      unless fact.storage == :multiowned
        name = fact.target_label
        emit_with_cap_mismatch!(node, name, :WITH_NEEDS_MULTIOWNED,
          [
            FixableHelper::CapabilityFixCandidate.new(
              sigil: "@multiowned",
              description_code: :WITH_ADD_MULTIOWNED,
              description_params: { suffix: " via WITH" }
            ),
          ],
          confidence: :auto,
          name: name)
      end

    when :shared
      unless fact.storage == :shared
        name = fact.target_label
        emit_with_cap_mismatch!(node, name, :WITH_NEEDS_SHARED,
          [
            FixableHelper::CapabilityFixCandidate.new(
              sigil: "@shared",
              description_code: :WITH_ADD_SHARED,
              description_params: { suffix: "to clone across fibers" }
            ),
          ],
          confidence: :auto,
          name: name)
      end

    when :ATOMIC
      # Polymorphic params may not have sync propagated yet; defer those checks.
      syn = fact.sync
      unless syn == :atomic
        if fact.deferred_sync_param?
          record_deferred_with_validation!(node, fact)
        else
          name = fact.target_label
          storage = fact.storage
          actual = syn ? "@#{syn}" : (storage ? "@#{storage}" : "plain")
          emit_with_cap_mismatch!(node, name, :WITH_ATOMIC_NEEDS_SHARED_ATOMIC,
            [
              FixableHelper::CapabilityFixCandidate.new(
                sigil: "@shared:atomic",
                description_code: :WITH_ADD_SHARED_ATOMIC
              ),
            ],
            confidence: :auto,
            name: name, actual: actual)
        end
      end

    else
      error!(node, :UNKNOWN_WITH_CAP_TYPE, type: fact.capability)
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
  sig { params(node: AST::WithBlock, fact: WithCapabilityFact, var_type: Type).returns(NilClass) }
  def emit_view_not_observable_finding!(node, fact, var_type)
    T.bind(self, SemanticAnnotator) rescue nil
    name = fact.target_label
    msg = "WITH VIEW requires an `@observable` source, but '#{name}' has type #{var_type.resolved}. " \
          "Use `WITH MATERIALIZED VIEW` for non-observable aggregates, or annotate the binding as `~T@observable`."

    view_tok = fact.source[:view_token]

    fixes = []
    if view_tok
      fixes << Fix.new(
        description: fix_description(:WITH_VIEW_TO_MATERIALIZED),
        confidence: :auto,
        edits: [Edit.new(
          span: Span.new(file: nil, line: view_tok.line, col: view_tok.column, length: 'VIEW'.length),
          replacement: 'MATERIALIZED VIEW',
        )],
      )
    end

    return error!(node, :WITH_VIEW_NEEDS_OBSERVABLE, name: name, got: var_type.resolved) if fixes.empty?
    fixable!(node, code: :WITH_VIEW_NEEDS_OBSERVABLE, name: name, got: var_type.resolved,
             category: :capability, level: :error,
             fixes: fixes, raise_in_collector: false)
  end

  # Predicate identifier scope check. Used by both WITH GUARD (where the
  # predicate may reference only its own alias) and FN PRE (where the
  # predicate may reference only function parameters). Branches on the
  # active context's :kind so each surface gets its own diagnostic.
  sig { params(node: AST::Identifier).returns(NilClass) }
  def predicate_identifier_allowed!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    ctx = current_predicate_context
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
    nil
  end

  sig { params(node: T.any(AST::FuncCall, AST::MethodCall)).void }
  def record_predicate_call_site!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    ctx = current_predicate_context
    return unless ctx
    predicate_call_sites_store << PredicateCallSite.new(
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
    predicate_call_sites_store.each do |site|
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

  sig { returns(T::Array[PredicateCallSite]) }
  def predicate_call_sites_store
    T.bind(self, SemanticAnnotator) rescue nil
    predicate_call_sites
  end
  private :predicate_call_sites_store

  sig { params(call: T.any(AST::FuncCall, AST::MethodCall), callee: String).returns(T.nilable(String)) }
  def predicate_impurity_reason(call, callee)
    T.bind(self, SemanticAnnotator) rescue nil
    call_declared_impurity_reason(call) ||
      matched_stdlib_impurity_reason(call) ||
      semantic_function_impurity_reason(callee)
  end

  sig { params(call: T.any(AST::FuncCall, AST::MethodCall)).returns(T.nilable(String)) }
  def call_declared_impurity_reason(call)
    T.bind(self, SemanticAnnotator) rescue nil

    return "is an extern call" if call.extern_call
    extern_effects = call.extern_effects
    return "has extern effects" if extern_effects && !extern_effects.empty?
    return "can fail" if call.can_fail

    nil
  end
  private :call_declared_impurity_reason

  sig { params(call: T.any(AST::FuncCall, AST::MethodCall)).returns(T.nilable(String)) }
  def matched_stdlib_impurity_reason(call)
    T.bind(self, SemanticAnnotator) rescue nil

    return nil unless call.matched_stdlib_def

    md = T.must(call.matched_stdlib_def)
    return "allocates" if md.emits_allocating?
    return "can fail" if md.can_fail
    return "suspends" if md.intrinsic_suspends?
    return "mutates its receiver" if md.mutates_receiver?

    nil
  end
  private :matched_stdlib_impurity_reason

  sig { params(callee: String).returns(T.nilable(String)) }
  def semantic_function_impurity_reason(callee)
    T.bind(self, SemanticAnnotator) rescue nil

    fn_nodes = function_node_map
    fn = fn_nodes[callee]
    return nil unless fn
    return "can fail" if fn.can_fail
    effects = fn.effects || Set.new
    return nil if effects.empty?
    "has effects #{effects.map { |e| EffectTracker.display(e) }.sort.join(', ')}"
  end
  private :semantic_function_impurity_reason

  sig { params(node: AST::WithBlock).void }
  def validate_and_visit_with_guards!(node)
    T.bind(self, SemanticAnnotator) rescue nil
    capability_plan = CapabilityPlan.require_for(node)
    caps = capability_plan.all
    guarded = capability_plan.guarded
    return if guarded.empty?

    error!(node, :WITH_GUARD_NOT_WITH_MATCH) if node.arms
    if node.snapshot_mode == :transaction
      error!(node, :WITH_GUARD_NOT_ON_SNAPSHOT)
    end

    # Every participating capability must bind an alias so the guard can
    # name it, and every alias must be immutable. MUTABLE aliases could
    # change inside the body and silently invalidate the predicate.
    missing_alias = caps.reject(&:alias_explicit)
    unless missing_alias.empty?
      emit_with_guard_all_bindings_need_as!(node, missing_alias)
    end

    aliases = caps.map(&:alias_name)
    guarded.each do |gcap|
      own = gcap.alias_name
      siblings = aliases - [own]
      guard_expr = T.must(gcap.guard_expr)
      with_predicate_context(
        PredicateContext.new(
          kind: :guard,
          with_node: node,
          fn_node: nil,
          pred_expr: guard_expr,
          guard_alias: own,
          sibling_aliases: siblings,
          param_names: [],
          allowed_names: [],
          rejected_param_names: Set.new,
          fn_name: nil,
        )
      ) do
        visit(guard_expr)

        guard_type = guard_expr.full_type!(context: "WITH guard expression")
        unless guard_type && guard_type.resolved == :Bool
          error!(guard_expr, :WITH_GUARD_EXPR_MUST_BE_BOOL, got: guard_type || 'Unknown')
        end
      end
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
    pre_clauses = fn_node.pre_clauses || []
    return if pre_clauses.empty?

    unless fn_node.explicit_return_type
      arrow_tok = fn_node.arrow_token
      if arrow_tok
        # Auto-fix: insert `RETURNS !Void ` immediately before the
        # `->` arrow. The body is implicit-Void (no RETURNS clause
        # was given), so !Void is the correct error-union widening.
        fixes = [Fix.new(
          description: fix_description(:INSERT_RETURNS_FALLIBLE_VOID),
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: arrow_tok.line, col: arrow_tok.column, length: 0),
            replacement: 'RETURNS !Void ',
          )],
        )]
        fixable!(fn_node, code: :PRE_CLAUSES_NEED_EXPLICIT_FALLIBLE_RETURN,
                 fn: fn_node.name, category: :type, level: :error, fixes: fixes)
      else
        error!(fn_node, :PRE_CLAUSES_NEED_EXPLICIT_FALLIBLE_RETURN, fn: fn_node.name)
      end
    end

    param_names = fn_node.params.map { |p| p.name.to_s }
    pre_clauses.each do |entry|
      expr = entry[:expr]
      with_predicate_context(
        PredicateContext.new(
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
        )
      ) do
        visit(expr)

        pred_type = expr.full_type!(context: "PRE expression")
        unless pred_type && pred_type.resolved == :Bool
          error!(expr, :PRE_EXPR_MUST_BE_BOOL, got: pred_type || 'Unknown')
        end
      end
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
    post_clauses = fn_node.respond_to?(:post_clauses) ? (fn_node.post_clauses || []) : []
    return if post_clauses.empty?

    # POST + CATCH on the same function is not yet supported. Reject at
    # annotation time with a clean CLEAR diagnostic rather than letting
    # MIR lowering hit an internal raise.
    has_catch = function_has_catch_clauses?(fn_node)
    has_default_catch = function_has_default_catch?(fn_node)
    if has_catch || has_default_catch
      error!(fn_node, :DEBUG_POST_NOT_WITH_CATCH)
    end

    param_names = fn_node.params.map { |p| p.name.to_s }
    rejected = fn_node.params.filter_map do |p|
      sym = current_scope.resolve_entry(p.name.to_s)
      next unless sym && %i[locked write_locked versioned atomic].include?(sym.sync)
      p.name.to_s
    end.to_set

    rt = fn_node.return_type
    payload = if rt && rt.error_union?
                rt.payload_type
              else
                rt
              end

    with_new_scope(current_scope) do
      if payload
        current_scope.declare("result", nil, payload, false, false, nil, :stack)
      end

      allowed_names = param_names + ["result"]
      post_clauses.each do |entry|
        expr = entry[:expr]
        with_predicate_context(
          PredicateContext.new(
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
          )
        ) do
          visit(expr)

          pred_type = expr.full_type!(context: "DEBUG_POST expression")
          unless pred_type && pred_type.resolved == :Bool
            error!(expr, :DEBUG_POST_EXPR_MUST_BE_BOOL, got: pred_type || 'Unknown')
          end
        end
      end
    end
    nil
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
    capability_plan = CapabilityPlan.require_for(node)
    return if capability_plan.guarded.empty?

    mutable_caps = capability_plan.all.select { |cap| cap.alias_mutable && cap.alias_explicit }
    return if mutable_caps.empty?

    mutated = mutable_caps.map(&:alias_name).select { |alias_name| alias_mutated?(alias_name) }
    return if mutated.empty?

    is_or_are = mutated.length == 1 ? 'is' : 'are'
    emit_with_guard_mutable_mutated!(node, mutated, is_or_are)
  end

  sig { params(alias_name: String).returns(T::Boolean) }
  def alias_mutated?(alias_name)
    T.bind(self, SemanticAnnotator) rescue nil
    scope = lookup_scope_for(alias_name)
    return false unless scope
    !!scope.resolve_entry(alias_name)&.mutated
  end

  # Resolve and validate a single capability entry from a WITH block.
  # Visits the var_node, infers capability if needed, validates it,
  # records effects/audit, and handles wildcard expansion.
  #
  # @param node [AST::WithBlock] the WITH block (for error reporting)
  # @param cap [Hash] the capability entry { :capability, :var_node, :alias }
  # @param expanded [Array] accumulator for resolved capabilities
  sig { params(node: AST::WithBlock, cap: AST::Capability, expanded: WithCapabilityExpansion).void }
  def acquire_capability!(node, cap, expanded)
    T.bind(self, SemanticAnnotator) rescue nil
    var_node = cap[:var_node]
    visit(var_node)
    cap[:resolved_type] = var_node.full_type!(context: "WITH resolved capability target")

	    cap[:old_scope] = lookup_scope_for(CapabilityPlan.var_name_for(var_node))

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

    fact = with_capability_fact(cap)
    validate_capability_transition!(node, fact)

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
      case fact.capability
      when :EXCLUSIVE, :write_locked_read
        record_effect(EffectTracker::BLOCKING)
        record_effect(EffectTracker::CONTENTION)
      when :SNAPSHOT
        record_effect(EffectTracker::CONTENTION)
      end
    end

    # Capability audit: mark variable as mutated if EXCLUSIVE access is used.
    if fact.capability == :EXCLUSIVE && var_node.is_a?(AST::Identifier)
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
        expanded_cap = AST::Capability.new(
          capability: cap[:capability],
          var_node: field_node,
          old_scope: cap[:old_scope],
          resolved_type: field_node.full_type!(context: "WITH wildcard field")
        )
        expanded.add(with_capability_fact(expanded_cap))
      end
      # The per-field caps above each alias the base variable name; the
      # base binding must remain the struct type (a field cap declaring
      # `p` as a field's type would break `p.field` inside the block).
      # Re-assert the whole-struct cap last so the base keeps its type.
      base_t = var_node.target.full_type!(context: "WITH wildcard base")
      base_t = Type.new(base_t) unless base_t.is_a?(Type)
      expanded_cap = AST::Capability.new(
        capability: cap[:capability],
        var_node: var_node.target,
        old_scope: cap[:old_scope],
        resolved_type: base_t
      )
      expanded.add(with_capability_fact(expanded_cap))
    else
      expanded.add(fact)
    end
  end

  sig { params(cap: AST::Capability).returns(WithCapabilityFact) }
  def with_capability_fact(cap)
    T.bind(self, SemanticAnnotator) rescue nil
    request = CapabilityPlan::CapabilityRequest.from_ast(cap)
    var_node = T.cast(cap[:var_node], AST::Locatable)
	    var_name = CapabilityPlan.var_name_for(var_node)
    resolved = cap.resolved_type
    old_scope = T.cast(cap[:old_scope], T.nilable(Scope))
    source_entry = old_scope&.resolve_entry(var_name)
    source_type = source_entry ? Type.new(source_entry.type) : Type.new(resolved)
    sync = cap_var_sync(var_node)
    target = CapabilityPlan::CapabilityTargetFact.new(
      var_node: var_node,
      var_name: var_name,
      target_label: cap_var_label(var_node),
      field_target: var_node.is_a?(AST::GetField),
      index_target: var_node.is_a?(AST::GetIndex),
      resolved_type: Type.new(resolved),
      old_scope: old_scope,
      source_entry: source_entry,
      sync: sync,
      storage: cap_var_storage(var_node),
      layout: cap_var_layout(var_node),
      source_type: source_type,
      live_symbol_refreshed: false,
    )
    CapabilityPlan.transition_from(request, target, borrowed_source_qualifier(source_entry))
  end

  sig { params(entry: T.nilable(SymbolEntry)).returns(T.nilable(String)) }
  def borrowed_source_qualifier(entry)
    return nil unless entry
    storage_qualifier = BORROWED_STORAGE_QUALIFIERS[entry.storage]
    return storage_qualifier if storage_qualifier
    return "@locked" if entry.locked?
    return "@writeLocked" if entry.write_locked?
    nil
  end

  # Declare a resolved capability into the current scope.
  # For locked/write_locked vars, declares the alias as the plain inner type
  # (mutable, stack-allocated) and re-declares the locked var for accessibility.
  # For all others, delegates to scope.declare_with_new_capability.
	  sig { params(fact: WithCapabilityFact).returns(T.nilable(String)) }
	  def declare_capability_scope!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    declare_unwrapped_capability_alias!(fact) if fact.unwraps_sync_alias?
    declare_capability_binding_or_error!(fact)
    declare_capability_projection!(fact)
    nil
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_capability_binding_or_error!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    return if current_scope.declare_with_new_capability(fact.source)

    error!(fact.var_node, :WITH_CAP_BINDING_LOST,
      capability: fact.capability, name: fact.var_name)
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_capability_projection!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    case fact.capability
    when :RESTRICT
      declare_restrict_capability!(fact)
    when :VIEW, :MATERIALIZED_VIEW
      declare_view_capability!(fact)
    when :SNAPSHOT
      declare_snapshot_capability!(fact)
    when :BORROWED
      declare_borrowed_capability!(fact)
    end
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_unwrapped_capability_alias!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    alias_name = fact.alias_name
    inner_type = unwrapped_capability_alias_type(fact)
    current_scope.declare(alias_name, nil, inner_type, true, false, nil, :stack)
    record_capture_local!(alias_name) if fact.alias_explicit
    current_scope.local_entry!(alias_name).mark_non_escaping!
    og_declare(alias_name, nil, inner_type)
  end

  sig { params(fact: WithCapabilityFact).returns(Type) }
  def unwrapped_capability_alias_type(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    source_type = fact.field_target ?
      fact.var_node.full_type!(context: "WITH capability field alias") :
      fact.declared_source_type
    capability_alias_type(source_type)
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_restrict_capability!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    ownership_graph.borrow("__restrict_#{fact.var_name}", fact.var_name, mutable: true)
    mark_var_mutated(fact.var_name) if fact.alias_mutable
    declare_restrict_alias!(fact) if fact.declares_plain_restrict_alias?
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_restrict_alias!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    alias_name = fact.alias_name
    resolved_type = capability_alias_type(capability_source_type(fact))
    current_scope.declare(alias_name, nil, resolved_type, fact.alias_mutable, false, nil, :stack)
    record_capture_local!(alias_name)
    sym = current_scope.local_entry!(alias_name)
    sym.mark_non_escaping!
    sym.mark_borrowed_alias!
    og_declare(alias_name, nil, resolved_type)
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_view_capability!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    bind_type = view_capability_alias_type(fact)
    alias_name = fact.alias_name
    current_scope.declare(alias_name, nil, bind_type, false, false, nil, :stack)
    record_capture_local!(alias_name)
    declare_view_borrow_constraints!(alias_name) if fact.capability == :VIEW
    og_declare(alias_name, nil, bind_type)
  end

  sig { params(fact: WithCapabilityFact).returns(Type) }
  def view_capability_alias_type(fact)
    Type.new(fact.resolved_type).tense_type
  end

  sig { params(alias_name: String).void }
  def declare_view_borrow_constraints!(alias_name)
    T.bind(self, SemanticAnnotator) rescue nil
    sym = current_scope.local_entry!(alias_name)
    sym.mark_non_escaping!
    sym.mark_borrowed_alias!
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_snapshot_capability!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    alias_name = fact.alias_name
    inner_type = Type.new(fact.resolved_type).bare_data_type
    current_scope.declare(alias_name, nil, inner_type, fact.alias_mutable, false, nil, :stack)
    record_capture_local!(alias_name)
    sym = current_scope.local_entry!(alias_name)
    sym.mark_non_escaping!
    sym.mark_borrowed_alias!
    og_declare(alias_name, nil, inner_type)
  end

  sig { params(fact: WithCapabilityFact).void }
  def declare_borrowed_capability!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    qualifier = fact.borrowed_rejection_qualifier
    emit_borrowed_rejection!(fact, qualifier) if qualifier
    alias_name = fact.alias_name
    resolved_type = capability_alias_type(capability_source_type(fact))
    current_scope.declare(alias_name, nil, resolved_type, false, false, nil, :stack)
    record_capture_local!(alias_name) if fact.alias_explicit
    sym = current_scope.local_entry!(alias_name)
    sym.mark_non_escaping!
    sym.mark_borrowed_alias!
    og_declare(alias_name, nil, resolved_type)
    ownership_graph.borrow("__borrowed_#{fact.var_name}", fact.var_name, mutable: false)
  end

  sig { params(fact: WithCapabilityFact, qualifier: String).void }
  def emit_borrowed_rejection!(fact, qualifier)
    T.bind(self, SemanticAnnotator) rescue nil
    remediation = "BORROWED guarantees the data is stable, but #{qualifier} data can be " \
                  "modified concurrently. Use WITH #{fact.var_name} { } to access it safely instead."
    error!(fact.var_node, :WITH_BORROWED_ON_QUALIFIED_VAR,
      qualifier: qualifier, name: fact.var_name, remediation: remediation)
  end

  sig { params(fact: WithCapabilityFact).returns(Type) }
  def capability_source_type(fact)
    fact.resolved_type.untyped? ? fact.declared_source_type : fact.resolved_type
  end

  sig { params(type: T.untyped).returns(Type) }
  def capability_alias_type(type)
    T.bind(self, SemanticAnnotator) rescue nil
    t = Type.new(type)
    if t.any_sync? || t.ownership != :affine
      t.bare_data_type
    else
      t
    end
  end

  class CaptureAnalysis < T::Struct
    extend T::Sig

    prop :has_local, T::Boolean, default: false
    prop :has_rc, T::Boolean, default: false
    prop :has_shared, T::Boolean, default: false
    prop :has_sharded, T::Boolean, default: false
    prop :has_affine_locked, T::Boolean, default: false
    prop :has_outer_ref, T::Boolean, default: false
    prop :has_non_escaping_capture, T::Boolean, default: false
    prop :captures, T::Hash[String, Type], factory: -> { {} }
    prop :capture_symbols, T::Hash[String, SymbolEntry], factory: -> { {} }
    prop :close_plans, T::Hash[String, Schemas::ResourceClosePlan], factory: -> { {} }
    prop :pointer_captures, T::Set[String], factory: -> { Set.new }
    prop :string_captures, T::Set[String], factory: -> { Set.new }
    prop :resource_captures, T::Set[String], factory: -> { Set.new }
    prop :site_moved, T::Set[String], factory: -> { Set.new }
    prop :site_copied, T::Set[String], factory: -> { Set.new }
    prop :strategies, T::Hash[String, CaptureStrategy::Strategy], factory: -> { {} }
    prop :move_mark_names, T::Set[String], factory: -> { Set.new }
    prop :alloc_mark_entries, T::Hash[String, Symbol], factory: -> { {} }

    sig { returns(Symbol) }
    def pin_reason; has_sharded ? :sharded : :shared; end

    sig { params(nested: CaptureAnalysis).void }
    def merge_nested!(nested)
      captures.merge!(nested.captures) { |_name, old, _new| old }
      capture_symbols.merge!(nested.capture_symbols) { |_name, old, _new| old }
      close_plans.merge!(nested.close_plans) { |_name, old, _new| old }
      pointer_captures.merge(nested.pointer_captures)
      string_captures.merge(nested.string_captures)
      resource_captures.merge(nested.resource_captures)
      site_moved.merge(nested.site_moved)
      site_copied.merge(nested.site_copied)
      strategies.merge!(nested.strategies) { |_name, old, _new| old }
      move_mark_names.merge(nested.move_mark_names)
      alloc_mark_entries.merge!(nested.alloc_mark_entries) { |_name, old, _new| old }
    end
  end

  class CaptureContext < T::Struct
    const :analysis, CaptureAnalysis
    const :outer_scope, Scope
    const :locals, T::Set[String]
    const :is_parallel, T::Boolean
    const :mark_moves, T::Boolean
  end

  sig { returns(CapabilityHelper::CaptureAnalysis) }
  def new_capture_analysis
    CaptureAnalysis.new
  end

  sig { params(is_parallel: T.nilable(T::Boolean), mark_moves: T::Boolean, blk: T.untyped).returns(CapabilityHelper::CaptureAnalysis) }
  def with_fiber_capture_analysis(is_parallel: false, mark_moves: false, &blk)
    T.bind(self, SemanticAnnotator)
    ctx = T.let(nil, T.nilable(CaptureContext))
    state = T.let(phase_receiver_state, SemanticAnnotator::ReceiverState)
    ctx = CaptureContext.new(
      analysis: new_capture_analysis,
      outer_scope: current_scope,
      locals: Set.new,
      is_parallel: !!is_parallel,
      mark_moves: mark_moves
    )
    state.capture_stack << ctx
    blk.call
    ctx.analysis
  ensure
    popped = T.must(state).capture_stack.pop
    Kernel.raise "BUG: capture context mismatch" if popped && !popped.equal?(ctx)
  end

  sig { returns(T.nilable(CapabilityHelper::CaptureContext)) }
  def current_capture_context
    T.bind(self, SemanticAnnotator)
    phase_receiver_state.capture_stack.last
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
    info = ctx.outer_scope.resolve_entry(name)
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
    result = ctx.analysis
    result.has_outer_ref = true
    unless result.captures.key?(name)
      cap_type = info.atomic? ? info.type : node.full_type!(context: "fiber capture identifier")
      result.captures[name] = cap_type
      result.capture_symbols[name] = info
      t = cap_type
      close_plan = info.close_plan
      add_capture_name_when(result.pointer_captures, name, t.needs_pointer_passing?)
      add_capture_name_when(result.string_captures, name, t.string?)
      add_capture_name_when(result.resource_captures, name, t.resource? || !close_plan.nil?)
      string_map_cleanup = t.captured_plain_string_map_needs_deinit? && close_plan.nil?
      add_capture_name_when(result.resource_captures, name, string_map_cleanup)
      set_capture_close_plan_when(
        result.close_plans,
        name,
        Schemas::ResourceClosePlan.method("deinit", runtime_heap_alloc_args: 2),
        string_map_cleanup
      )
    end
    close_plan = info.close_plan
    set_capture_close_plan_when(result.close_plans, name, close_plan, !close_plan.nil?)
    result.has_local ||= info.local?
    result.has_rc ||= info.storage == :multiowned
    ti = info.type
    sync_capture = !(ti.striped? && (ti.shared? || ti.multiowned?)) && !info.atomic?
    sharded_capture = sync_capture && ti.sharded?
    result.has_shared ||= sharded_capture ||
                           (sync_capture && (info.locked? || info.write_locked? || info.local? || info.rc_stored?))
    result.has_affine_locked ||= sync_capture && info.affine_locked_capture?
    result.has_sharded ||= sharded_capture
    audit_mark_captured(name, parallel: ctx.is_parallel)
  end

  sig { params(names: T::Set[String], name: String, active: T::Boolean).void }
  def add_capture_name_when(names, name, active)
    return unless active

    names << name
  end

  sig { params(plans: T::Hash[String, Schemas::ResourceClosePlan], name: String, plan: T.nilable(Schemas::ResourceClosePlan), active: T::Boolean).void }
  def set_capture_close_plan_when(plans, name, plan, active)
    return unless active

    plans[name] ||= T.must(plan)
  end

  sig { params(ctx: CapabilityHelper::CaptureContext, name: String, info: SymbolEntry, node: AST::Identifier).void }
  def record_capture_move!(ctx, name, info, node)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless ctx.mark_moves && phase_receiver_state.capture_move_suppression_depth.zero?
    return unless ctx.outer_scope.owned_names.include?(name)
    classify_ownership!(info) unless info.ownership_kind
    if info.capture_move_required?(ownership_graph.live?(name))
      og_set_moved(name, at_token: node.token, action: :capture)
    end
  end

  sig { params(blk: T.untyped).returns(T.untyped) }
  def without_capture_moves(&blk)
    T.bind(self, SemanticAnnotator)
    phase_receiver_state.capture_move_suppression_depth += 1
    blk.call
  ensure
    phase_receiver_state.capture_move_suppression_depth -= 1
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

  private :declare_borrowed_capability!,
    :declare_capability_projection!,
    :declare_restrict_capability!,
    :declare_restrict_alias!,
    :declare_snapshot_capability!,
    :declare_unwrapped_capability_alias!,
    :declare_view_capability!,
    :record_capture_local!,
    :record_capture_info!,
    :validate_capability_transition!,
    :with_capability_fact
  private :add_capture_name_when
  private :alias_mutated?
  private :borrowed_source_qualifier
  private :cap_var_layout
  private :declare_capability_binding_or_error!
  private :declare_view_borrow_constraints!
  private :emit_borrowed_rejection!
  private :emit_view_not_observable_finding!
  private :new_capture_analysis
  private :non_escaping_fiber_capture?
  private :predicate_impurity_reason
  private :record_capture_move!
  private :set_capture_close_plan_when
  private :unwrapped_capability_alias_type
  private :view_capability_alias_type

end

# ============================================================================
# CapabilityAudit — "Architecture Consultant"
# ============================================================================
# Mixed into SemanticAnnotator. Tracks capability usage patterns and
# warns about over-engineered capabilities (ghost locks, isolated shares, etc.)
module CapabilityAudit
    extend T::Sig

  class BindingAuditRecord < T::Struct
    extend T::Sig

    const :fn, String
    const :var, String
    const :line, T.nilable(Integer)
    const :column, T.nilable(Integer)
    const :sync, T.nilable(Symbol)
    const :ownership, T.nilable(Symbol)
    const :storage, Symbol
    const :sharded, T::Boolean
    prop :mutated, T::Boolean
    prop :captured_bg, T::Boolean
    prop :captured_parallel, T::Boolean

    sig { void }
    def mark_mutated!
      self.mutated = true
    end

    sig { params(parallel: T::Boolean).void }
    def mark_captured!(parallel:)
      self.captured_bg = true
      self.captured_parallel = true if parallel
    end
  end

  BindingAuditStore = T.type_alias { T::Hash[String, BindingAuditRecord] }

  sig { returns(BindingAuditStore) }
  def capability_audit_init!
    T.bind(self, SemanticAnnotator) rescue nil
    store = capability_audit_store
    store.clear
    store
  end

  # Record a capability binding for later audit.
  sig { params(var_name: String, node: AST::Locatable, final_type: T.any(Type, Symbol), storage: Symbol).returns(T.nilable(BindingAuditRecord)) }
  def record_capability_binding(var_name, node, final_type, storage)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_ctx = current_fn_ctx
    return unless fn_ctx
    fn_name = fn_ctx.name
    return unless fn_name

    info = current_scope.resolve_entry(var_name)
    sync = info&.sync
    own  = storage if storage == :multiowned || storage == :shared
    return unless sync || own

    # Skip PUB functions — libraries can't know how consumers will use exports.
    fn_nodes = function_node_map
    fn_node = fn_nodes[fn_name]
    return if fn_node&.visibility == :pub

    key = capability_audit_key(fn_name, var_name)
    line   = node.token&.line
    column = node.token&.column
    final_type_info = final_type.is_a?(Type) ? final_type : Type.new(final_type)
    record = BindingAuditRecord.new(
      fn: fn_name,
      var: var_name,
      line: line,
      column: column,
      sync: sync,
      ownership: own,
      storage: storage,
      sharded: final_type_info.sharded?,
      mutated: false,
      captured_bg: false,
      captured_parallel: false
    )
    capability_audit_store[key] = record
    record
  end

  sig { params(var_name: String).void }
  def audit_mark_mutated(var_name)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_name = current_fn_ctx&.name
    return unless fn_name
    record = capability_audit_store[capability_audit_key(fn_name, var_name)]
    record&.mark_mutated!
  end

  sig { params(var_name: String, parallel: T::Boolean).void }
  def audit_mark_captured(var_name, parallel:)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_name = current_fn_ctx&.name
    return unless fn_name
    record = capability_audit_store[capability_audit_key(fn_name, var_name)]
    record&.mark_captured!(parallel: parallel)
  end

  sig { returns(BindingAuditStore) }
  def finalize_capability_audit!
    T.bind(self, SemanticAnnotator) rescue nil
    capability_audit_store.each_value do |info|
      loc = info.line ? " (line #{info.line})" : ""
      sync = info.sync
      own  = info.ownership

      if SymbolEntry.locked_family_sync?(sync) && !info.mutated && !info.sharded
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info.var}' is @#{sync} but never mutated via WITH EXCLUSIVE. " \
                     "You are paying for lock acquire/release on every access. Consider @local or removing the lock.#{loc}"
      end

      if own == :shared && !info.captured_parallel
        $stderr.puts "\e[36m[Note]\e[0m Variable '#{info.var}' is @shared (Arc) but never leaves the local scheduler. " \
                     "You are paying for atomic ref-counting but never crossing cores. Consider @multiowned or @local.#{loc}"
      end

      if SymbolEntry.local_sync?(sync) && !info.captured_bg
        emit_local_never_shared_finding!(info)
      end
    end
  end

  sig { returns(BindingAuditStore) }
  def capability_audit_store
    T.bind(self, SemanticAnnotator) rescue nil
    capability_audit
  end
  private :capability_audit_store

  sig { params(fn_name: String, var_name: String).returns(String) }
  def capability_audit_key(fn_name, var_name)
    "#{fn_name}:#{var_name}"
  end
  private :capability_audit_key
end
