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

  class WithCapabilityFact < T::Struct
    extend T::Sig

    const :source, AST::Capability
    const :capability, Symbol
    const :var_node, AST::Locatable
    const :var_name, String
    const :alias_name, String
    const :alias_explicit, T::Boolean
    const :alias_mutable, T::Boolean
    const :resolved_type, Type
    const :old_scope, T.nilable(Scope)
    const :source_entry, T.nilable(SymbolEntry)
    const :field_target, T::Boolean
    const :sync, T.nilable(Symbol)
    const :storage, T.nilable(Symbol)
    const :layout, T.nilable(Symbol)
    const :source_type, Type
    const :lock_identity_value, T.nilable(Symbol)
    const :lock_capability, T::Boolean
    const :restrict_capability, T::Boolean
    const :borrowed_capability, T::Boolean
    const :snapshot_capability, T::Boolean
    const :view_capability, T::Boolean
    const :deferred_lock_param, T::Boolean
    const :sync_alias_unwrapped, T::Boolean
    const :plain_restrict_alias, T::Boolean
    const :borrowed_qualifier, T.nilable(String)

    sig { returns(T::Boolean) }
    def lock_capability?
      lock_capability
    end

    sig { returns(T::Boolean) }
    def restrict?
      restrict_capability
    end

    sig { returns(T::Boolean) }
    def borrowed?
      borrowed_capability
    end

    sig { returns(T::Boolean) }
    def snapshot?
      snapshot_capability
    end

    sig { returns(T::Boolean) }
    def view?
      view_capability
    end

    sig { returns(T::Boolean) }
    def deferred_lock_param?
      deferred_lock_param
    end

    sig { returns(T::Boolean) }
    def unwraps_sync_alias?
      sync_alias_unwrapped
    end

    sig { returns(T::Boolean) }
    def declares_plain_restrict_alias?
      plain_restrict_alias
    end

    sig { returns(Type) }
    def declared_source_type
      source_type
    end

    sig { returns(T.nilable(String)) }
    def borrowed_rejection_qualifier
      borrowed_qualifier
    end

    sig { returns(T.nilable(Symbol)) }
    def lock_identity
      lock_identity_value
    end
  end

  WithCapabilityFacts = T.type_alias { T::Array[WithCapabilityFact] }

  class WithCapabilityExpansion < T::Struct
    extend T::Sig

    prop :all, WithCapabilityFacts, factory: -> { [] }
    prop :locks, WithCapabilityFacts, factory: -> { [] }

    sig { params(fact: WithCapabilityFact).void }
    def add(fact)
      all << fact
      locks << fact if fact.lock_capability?
    end
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
    ctx = @current_predicate_context
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
    T.cast(instance_variable_get(:@predicate_call_sites), T::Array[PredicateCallSite])
  end
  private :predicate_call_sites_store

  sig { params(call: T.any(AST::FuncCall, AST::MethodCall), callee: String).returns(T.nilable(String)) }
  def predicate_impurity_reason(call, callee)
    T.bind(self, SemanticAnnotator) rescue nil
    return "is an extern call" if call.respond_to?(:extern_call) && call.extern_call
    return "has extern effects" if call.respond_to?(:extern_effects) && call.extern_effects && !call.extern_effects.empty?
    return "can fail" if call.respond_to?(:can_fail) && call.can_fail
    if call.matched_stdlib_def
      md = T.must(call.matched_stdlib_def)
      return "allocates" if md.emit&.allocates
      return "can fail" if md.can_fail
      return "suspends" if md.emit&.suspends
      return "mutates its receiver" if md.emit&.mutates_receiver
      return nil
    end
    fn_nodes = function_node_map
    fn = fn_nodes[callee]
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
      expanded.add(with_capability_fact(cap))
    end
  end

  sig { params(cap: AST::Capability).returns(WithCapabilityFact) }
  def with_capability_fact(cap)
    T.bind(self, SemanticAnnotator) rescue nil
    var_node = T.cast(cap[:var_node], AST::Locatable)
    var_name = cap_var_name(var_node)
    alias_value = cap[:alias]
    alias_explicit = T.let(!alias_value.nil?, T::Boolean)
    resolved = cap.resolved_type
    old_scope = T.cast(cap[:old_scope], T.nilable(Scope))
    source_entry = old_scope&.resolve_entry(var_name)
    source_type = source_entry ? Type.new(source_entry.type) : Type.new(resolved)
    capability = T.cast(cap[:capability], Symbol)
    lock_capability = LOCK_CAPABILITIES.include?(capability)
    restrict_capability = capability == :RESTRICT
    borrowed_capability = capability == :BORROWED
    snapshot_capability = capability == :SNAPSHOT
    view_capability = VIEW_CAPABILITIES.include?(capability)
    field_target = var_node.is_a?(AST::GetField)
    sync = cap_var_sync(var_node)
    deferred_lock_param = source_entry&.is_param == true && sync.nil? && lock_capability
    sync_alias_unwrapped = (field_target && !sync.nil?) ||
      (!field_target && (!sync.nil? || deferred_lock_param))
    WithCapabilityFact.new(
      source: cap,
      capability: capability,
      var_node: var_node,
      var_name: var_name,
      alias_name: (alias_value || var_name).to_s,
      alias_explicit: alias_explicit,
      alias_mutable: cap[:alias_mutable] == true,
      resolved_type: Type.new(resolved),
      old_scope: old_scope,
      source_entry: source_entry,
      field_target: field_target,
      sync: sync,
      storage: cap_var_storage(var_node),
      layout: cap_var_layout(var_node),
      source_type: source_type,
      lock_identity_value: Type.new(resolved).base_type,
      lock_capability: lock_capability,
      restrict_capability: restrict_capability,
      borrowed_capability: borrowed_capability,
      snapshot_capability: snapshot_capability,
      view_capability: view_capability,
      deferred_lock_param: deferred_lock_param,
      sync_alias_unwrapped: sync_alias_unwrapped,
      plain_restrict_alias: restrict_capability && alias_explicit && sync.nil?,
      borrowed_qualifier: borrowed_capability ? borrowed_source_qualifier(source_entry) : nil,
    )
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
  sig { params(var_node: T.untyped).returns(String) }
  def cap_var_name(var_node)
    T.bind(self, SemanticAnnotator) rescue nil
    AST.root_identifier(var_node)&.name || "__unknown"
  end

  sig { params(fact: WithCapabilityFact).returns(T.nilable(String)) }
  def declare_capability_scope!(fact)
    T.bind(self, SemanticAnnotator) rescue nil
    @og = T.let(@og, T.any(OwnershipGraph, T.untyped))
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
    @og.borrow("__restrict_#{fact.var_name}", fact.var_name, mutable: true)
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
    inner = Type.new(fact.resolved_type).tense_type
    bind_type_sym = inner.optional? ? inner.resolved : :"?#{inner.resolved}"
    alias_name = fact.alias_name
    current_scope.declare(alias_name, nil, bind_type_sym, false, false, nil, :stack)
    record_capture_local!(alias_name)
    declare_view_borrow_constraints!(alias_name) if fact.capability == :VIEW
    og_declare(alias_name, nil, bind_type_sym)
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
    @og.borrow("__borrowed_#{fact.var_name}", fact.var_name, mutable: false)
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
    prop :close_patterns, T::Hash[String, String], factory: -> { {} }
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
      close_patterns.merge!(nested.close_patterns) { |_name, old, _new| old }
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
    T.bind(self, SemanticAnnotator) rescue nil
    @capture_stack = T.let(@capture_stack, T.untyped)
    ctx = CaptureContext.new(
      analysis: new_capture_analysis,
      outer_scope: current_scope,
      locals: Set.new,
      is_parallel: !!is_parallel,
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
      close_pattern = info.close_zig
      add_capture_name_when(result.pointer_captures, name, t.needs_pointer_passing?)
      add_capture_name_when(result.string_captures, name, t.string?)
      add_capture_name_when(result.resource_captures, name, t.resource? || !close_pattern.nil?)
      string_map_cleanup = t.captured_plain_string_map_needs_deinit? && close_pattern.nil?
      add_capture_name_when(result.resource_captures, name, string_map_cleanup)
      set_capture_close_pattern_when(
        result.close_patterns,
        name,
        "{0}.deinit({rt}.heapAlloc(), {rt}.heapAlloc())",
        string_map_cleanup
      )
    end
    close_pattern = info.close_zig
    set_capture_close_pattern_when(result.close_patterns, name, close_pattern || "", !close_pattern.nil?)
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

  sig { params(patterns: T::Hash[String, String], name: String, pattern: String, active: T::Boolean).void }
  def set_capture_close_pattern_when(patterns, name, pattern, active)
    return unless active

    patterns[name] ||= pattern
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
    return unless current_fn_ctx&.name

    info = current_scope.resolve_entry(var_name)
    sync = info&.sync
    own  = storage if storage == :multiowned || storage == :shared
    return unless sync || own

    # Skip PUB functions — libraries can't know how consumers will use exports.
    fn_name = T.cast(current_fn_ctx&.name, T.nilable(String))
    fn_nodes = function_node_map
    fn_node = fn_name ? fn_nodes[fn_name] : nil
    return if fn_node&.visibility == :pub

    fn_name = T.must(fn_name)
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
    fn_name = T.cast(current_fn_ctx&.name, T.nilable(String))
    return unless fn_name
    record = capability_audit_store[capability_audit_key(fn_name, var_name)]
    record&.mark_mutated!
  end

  sig { params(var_name: String, parallel: T::Boolean).void }
  def audit_mark_captured(var_name, parallel:)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_name = T.cast(current_fn_ctx&.name, T.nilable(String))
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
    T.cast(instance_variable_get(:@capability_audit), BindingAuditStore)
  end
  private :capability_audit_store

  sig { params(fn_name: String, var_name: String).returns(String) }
  def capability_audit_key(fn_name, var_name)
    "#{fn_name}:#{var_name}"
  end
  private :capability_audit_key

end
