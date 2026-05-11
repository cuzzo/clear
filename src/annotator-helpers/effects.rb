# typed: strict
require "sorbet-runtime"
require 'set'

# EffectTracker — Silent effect tracking for CLEAR functions.
#
# Tracks which side-effects each function can produce, both directly
# and transitively through the call graph.  This is infrastructure for
# the future STRICT mode / #HOT annotation system.
#
# Effects are computed in two phases:
#   1. Direct collection (during visit_* methods in pass 3)
#   2. Transitive propagation (fixed-point over @call_graph, after pass 5b)
#
# The result is stored on each FunctionDef node as `node.effects` (a frozen Set).
#
# Also includes reentrancy analysis helpers (scan_for_calls,
# check_indirect_reentrancy!, scan_for_raises) since reentrancy is
# both an effect and a call-graph property.
module EffectTracker
    extend T::Sig

  # Core effect constants.
  HEAP         = :HEAP
  BLOCKING     = :BLOCKING
  REENTRANT    = :REENTRANT
  LOOP_UNBOUND = :LOOP_UNBOUND
  EXTERN       = :EXTERN
  # Phase 3 closed-lattice effects. Recorded directly at visit_BgBlock /
  # visit_NextExpr (and FFI sites for IO). Propagated transitively by
  # compute_effects! over the existing call graph. Read by EffectSet
  # projection (src/mir/effect_inference.rb) and ConcurrencyChecks.
  YIELD        = :YIELD
  IO           = :IO

  # Contention / blocking axis for sync capabilities.
  # CONTENTION fires on any use of an @shared:atomic / @shared:versioned /
  # @shared:locked binding (cache-coherence pressure or CAS retry).
  # BLOCKING fires only when the caller's binding is lock-based (mutex
  # acquire can park the fiber). MAYBE variants fire when a polymorphic
  # REQUIRES disjunction crosses the lock-free / lock-based line:
  # the call site must check the arg's family to know which concrete
  # effect actually applies.
  CONTENTION       = :CONTENTION
  CONTENTION_MAYBE = :CONTENTION_MAYBE
  BLOCKING_MAYBE   = :BLOCKING_MAYBE

  # SUSPENDS family — fiber may suspend (IO, NEXT, YIELD, lock wait).
  # The three variants form an orthogonal set: a function may hold any
  # subset. Display form uses colon syntax (SUSPENDS:LOOP).
  #
  #   SUSPENDS             — function may suspend at a linear call site
  #   SUSPENDS_CONDITIONAL — function has a suspension point inside an IF/MATCH branch
  #   SUSPENDS_LOOP        — function has a suspension point inside a loop
  #
  # Propagation is context-sensitive: a caller that invokes a SUSPENDS-tagged
  # function inside a loop inherits SUSPENDS_LOOP (not plain SUSPENDS).
  #
  # Note: master added the simpler YIELD/IO pair independently while this
  # branch was developing SUSPENDS_*. They overlap in intent (both classify
  # fiber suspension points); kept side by side for now -- a follow-up
  # commit can unify them once both call sites are audited together.
  SUSPENDS             = :SUSPENDS
  SUSPENDS_CONDITIONAL = :SUSPENDS_CONDITIONAL
  SUSPENDS_LOOP        = :SUSPENDS_LOOP
  SUSPENDS_FAMILY      = T.let([SUSPENDS, SUSPENDS_CONDITIONAL, SUSPENDS_LOOP].freeze, T::Array[Symbol])

  ALL_EFFECTS = T.let([
    HEAP, BLOCKING, REENTRANT, LOOP_UNBOUND, EXTERN,
    YIELD, IO,
    SUSPENDS, SUSPENDS_CONDITIONAL, SUSPENDS_LOOP,
    CONTENTION, CONTENTION_MAYBE, BLOCKING_MAYBE,
  ].freeze, T::Array[Symbol])

  # Display format: :SUSPENDS_LOOP -> "SUSPENDS:LOOP".
  sig { params(effect: Symbol).returns(String) }
  def self.display(effect)
    case effect
    when SUSPENDS             then "SUSPENDS"
    when SUSPENDS_CONDITIONAL then "SUSPENDS:CONDITIONAL"
    when SUSPENDS_LOOP        then "SUSPENDS:LOOP"
    else effect.to_s
    end
  end

  # --- Phase 1: Direct collection ---

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def effects_init!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_direct_effects = T.let({}, T.untyped)   # fn_name => Set of direct effect symbols
    # Per-caller map of callee => worst-case call-site context
    # {loop: bool, cond: bool}. Populated by record_call_site during body
    # scanning. Used by compute_effects! to promote SUSPENDS → SUSPENDS_LOOP
    # or SUSPENDS_CONDITIONAL when the call site sits in that context.
    @call_site_context = T.let(Hash.new { |h, k| h[k] = {} }, T.untyped)
    # Per-(caller, callee) arg-family sets, one entry per call site. Used to
    # resolve callee ?-form effects based on what families the caller passes.
    @call_site_arg_families = T.let(Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }, T.untyped)
  end

  # Called at the start of visit_FunctionDef to prepare a fresh effect set.
  sig { params(fn_name: String).returns(T::Set[T.untyped]) }
  def effects_begin_function(fn_name)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_direct_effects = T.let(@fn_direct_effects, T.untyped)
    @fn_direct_effects[fn_name] = Set.new
  end

  # Record a direct effect for the function currently being analyzed.
  # For SUSPENDS specifically, promote based on current loop/conditional
  # context so the recorded effect reflects where the suspension occurs.
  sig { params(effect: Symbol).returns(NilClass) }
  def record_effect(effect)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_direct_effects = T.let(@fn_direct_effects, T.untyped)
    @inside_snapshot_txn = T.let(@inside_snapshot_txn, T.untyped)
    @snapshot_txn_violations = T.let(@snapshot_txn_violations, T.untyped)
    return unless current_fn_ctx&.name
    effect = promote_suspends_for_current_context(effect)
    @fn_direct_effects[current_fn_ctx.name]&.add(effect)
    # MVCC L5-followup (D1): a SNAPSHOT-transaction body must be pure
    # for atomicity -- yielding the fiber breaks EBR pin guarantees,
    # and IO can't be rolled back if the transaction aborts. Track
    # SUSPENDS effects recorded while @inside_snapshot_txn is set so
    # the WITH-block visitor can raise once the body is complete.
    if @inside_snapshot_txn && @inside_snapshot_txn > 0 && SUSPENDS_FAMILY.include?(effect)
      @snapshot_txn_violations ||= []
      @snapshot_txn_violations << { effect: effect, fn: current_fn_ctx.name }
    end
  end

  # Promote a bare SUSPENDS to SUSPENDS_LOOP / SUSPENDS_CONDITIONAL based
  # on the current visit context. Non-SUSPENDS effects pass through.
  sig { params(effect: Symbol).returns(Symbol) }
  def promote_suspends_for_current_context(effect)
    T.bind(self, SemanticAnnotator) rescue nil
    return effect unless effect == SUSPENDS
    if current_loop_depth > 0
      SUSPENDS_LOOP
    elsif current_conditional_depth > 0
      SUSPENDS_CONDITIONAL
    else
      SUSPENDS
    end
  end

  sig { returns(Integer) }
  def current_loop_depth
    T.bind(self, SemanticAnnotator) rescue nil
    @loop_depth = T.let(@loop_depth, T.untyped)
    current_fn_ctx&.loop_depth || @loop_depth || 0
  end

  sig { returns(Integer) }
  def current_conditional_depth
    T.bind(self, SemanticAnnotator) rescue nil
    @conditional_depth = T.let(@conditional_depth, T.untyped)
    current_fn_ctx&.conditional_depth || @conditional_depth || 0
  end

  # Record a call site's context so transitive propagation can promote the
  # callee's SUSPENDS effects. Worst-case merge across multiple call sites.
  sig { params(callee_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def record_call_site(callee_name)
    T.bind(self, SemanticAnnotator) rescue nil
    @call_site_context = T.let(@call_site_context, T.untyped)
    return unless current_fn_ctx&.name
    caller_name = current_fn_ctx.name
    in_loop = current_loop_depth > 0
    in_cond = current_conditional_depth > 0
    return unless in_loop || in_cond
    existing = @call_site_context[caller_name][callee_name] || { loop: false, cond: false }
    @call_site_context[caller_name][callee_name] = {
      loop: existing[:loop] || in_loop,
      cond: existing[:cond] || in_cond,
    }
  end

  # Record the per-arg family Sets at this call site.
  # `arg_family_sets` is an Array of Set<Symbol> in positional order (same
  # length as node.args). compute_effects! reads this to resolve callee
  # CONTENTION_MAYBE / BLOCKING_MAYBE into concrete effects when the
  # families are concrete, or keeps them MAYBE when polymorphism propagates.
  sig { params(callee_name: String, arg_family_sets: T::Array[T::Set[T.untyped]]).returns(T.nilable(T::Array[T.untyped])) }
  def record_call_arg_families(callee_name, arg_family_sets)
    T.bind(self, SemanticAnnotator) rescue nil
    @call_site_arg_families = T.let(@call_site_arg_families, T.untyped)
    return unless current_fn_ctx&.name
    @call_site_arg_families[current_fn_ctx.name][callee_name] << arg_family_sets
  end

  # --- Phase 2: Transitive propagation ---

  # Fixed-point propagation through @call_graph.
  # Follows the same pattern as compute_needs_rt! and compute_can_fail!.
  #
  # SUSPENDS-family effects promote based on call-site context: if foo
  # calls bar inside a loop, foo inherits SUSPENDS_LOOP regardless of
  # bar's own variant. Non-SUSPENDS effects inherit verbatim.
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def compute_effects!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_direct_effects = T.let(@fn_direct_effects, T.untyped)
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @call_graph = T.let(@call_graph, T.untyped)
    @call_site_context = T.let(@call_site_context, T.untyped)
    # Seed from direct effects.
    resolved = {}
    @fn_direct_effects.each { |name, effs| resolved[name] = effs.dup }

    # Recursive functions that emit `rt.checkYield()` yield to the scheduler.
    # Seed YIELD so hold-lock-across-yield sees calls inside WITH lock bodies.
    # TIGHT skips the yield emission, so TIGHT fns aren't seeded.
    # NOT_LOGICAL never yields (the StackGuard doesn't suspend).
    @fn_nodes.each do |name, fn_node|
      next if fn_node.tight_reentrance
      kind = fn_node.reentrance_kind
      next unless [:reentrant, :reentrant_tail_call, :reentrant_thunk, :reentrant_max_depth].include?(kind)
      (resolved[name] ||= Set.new).add(YIELD)
    end

    # Propagate: if foo calls bar, foo inherits bar's effects with context
    # promotion and ?-form resolution from per-call-site arg families.
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        current = resolved[fn_name] ||= Set.new
        callees.each do |callee|
          callee_effs = resolved[callee]
          next unless callee_effs
          before = current.size
          site_ctx = @call_site_context[fn_name][callee]
          resolved_callee = resolve_maybe_effects(
            callee_effs, fn_name, callee
          )
          inherit_effects_from_callee(current, resolved_callee, site_ctx)
          changed = true if current.size > before
        end
      end
    end

    # Store frozen effect sets on FunctionDef nodes.
    @fn_nodes.each do |name, fn_node|
      fn_node.effects = (resolved[name] || Set.new).freeze
    end
  end

  # Resolve callee ?-form effects into concrete effects when the caller's call
  # sites pin the family. Returns a new Set or the original if none apply.
  #
  # Resolution rules, aggregated across ALL call sites of `callee` from `caller`:
  #   - any concrete LOCKED arg          -> BLOCKING_MAYBE upgrades to BLOCKING
  #                                           (and CONTENTION_MAYBE upgrades to CONTENTION)
  #   - any concrete sync arg (LOCKED,
  #     ATOMIC, or VERSIONED)              -> CONTENTION_MAYBE upgrades to CONTENTION
  #   - all call sites pass concrete       -> ?-form is fully resolved (drop MAYBE)
  #     non-LOCKED args                     for BLOCKING_MAYBE; CONTENTION_MAYBE
  #                                           also resolves (to CONTENTION if any
  #                                           sync arg, else dropped if all nil)
  #   - any call site has a polymorphic    -> keep MAYBE form (caller still
  #     arg (sync_families.size > 1)          depends on caller's caller)
  #   - no concrete call-site info         -> conservatively keep MAYBE
  #
  # Effects orthogonal to the contention axis pass through unchanged.
  sig { params(callee_set: T::Set[Symbol], caller_name: String, callee_name: String).returns(T::Set[Symbol]) }
  def resolve_maybe_effects(callee_set, caller_name, callee_name)
    T.bind(self, SemanticAnnotator) rescue nil
    @call_site_arg_families = T.let(@call_site_arg_families, T.untyped)
    has_block_maybe = callee_set.include?(BLOCKING_MAYBE)
    has_cont_maybe  = callee_set.include?(CONTENTION_MAYBE)
    return callee_set unless has_block_maybe || has_cont_maybe

    call_sites = @call_site_arg_families[caller_name][callee_name]
    return callee_set if call_sites.empty?

    any_concrete_lockable = T.let(false, T::Boolean)
    any_concrete_sync     = T.let(false, T::Boolean)
    any_polymorphic_arg   = T.let(false, T::Boolean)

    call_sites.each do |arg_family_sets|
      arg_family_sets.each do |fam_set|
        next if fam_set.nil? || fam_set.empty?
        if fam_set.size > 1
          any_polymorphic_arg = true
          any_concrete_lockable = true if fam_set.include?(:LOCKED)
          any_concrete_sync     = true
        else
          fam = fam_set.first
          any_concrete_lockable = true if fam == :LOCKED
          any_concrete_sync     = true if [:LOCKED, :ATOMIC, :VERSIONED].include?(fam)
        end
      end
    end

    result = callee_set.dup

    if has_block_maybe
      if any_concrete_lockable && !any_polymorphic_arg
        result.add(BLOCKING)
        result.delete(BLOCKING_MAYBE)
      elsif !any_concrete_lockable && !any_polymorphic_arg && any_concrete_sync
        # All call sites pin to concrete lock-free families: BLOCKING is impossible.
        result.delete(BLOCKING_MAYBE)
      elsif any_polymorphic_arg
        # Caller's own param is polymorphic; ?-form propagates upward.
        # No-op (keep BLOCKING_MAYBE).
      end
    end

    if has_cont_maybe
      if any_concrete_sync && !any_polymorphic_arg
        result.add(CONTENTION)
        result.delete(CONTENTION_MAYBE)
      elsif any_polymorphic_arg
        # No-op (keep CONTENTION_MAYBE).
      else
        # No concrete sync at any call site (all args nil family) -> drop.
        result.delete(CONTENTION_MAYBE)
      end
    end

    result
  end

  # Merge callee's effects into caller, applying context-sensitive
  # SUSPENDS promotion based on the call site's loop/cond bits.
  sig { params(caller_set: T::Set[Symbol], callee_set: T::Set[Symbol], site_ctx: T.nilable(T::Hash[Symbol, T.untyped])).returns(T::Set[Symbol]) }
  def inherit_effects_from_callee(caller_set, callee_set, site_ctx)
    T.bind(self, SemanticAnnotator) rescue {}
    in_loop = site_ctx && site_ctx[:loop]
    in_cond = site_ctx && site_ctx[:cond]
    callee_set.each do |eff|
      if SUSPENDS_FAMILY.include?(eff)
        has_loop = (eff == SUSPENDS_LOOP) || in_loop
        has_cond = (eff == SUSPENDS_CONDITIONAL) || in_cond
        # Inherit base SUSPENDS so callers can still see linear suspend paths.
        caller_set.add(SUSPENDS)
        caller_set.add(SUSPENDS_LOOP)        if has_loop
        caller_set.add(SUSPENDS_CONDITIONAL) if has_cond
      else
        caller_set.add(eff)
      end
    end
  end

  # --- Call-graph fixed-point passes ---

  # Post-pass: compute needs_rt for every function.
  # A function needs rt if it uses the frame arena, calls a fn pointer, or any
  # transitive callee needs rt. main always needs rt (entry point).
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def compute_needs_rt!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @fn_raises_directly = T.let(@fn_raises_directly, T.untyped)
    @fn_has_fnptr = T.let(@fn_has_fnptr, T.untyped)
    @call_graph = T.let(@call_graph, T.untyped)
    needs_rt = {}
    @fn_nodes.each do |name, fn_node|
      raw = fn_node.full_type.is_a?(Type) ? fn_node.full_type.raw : fn_node.full_type
      ret_type = raw.is_a?(FunctionSignature) ? raw.return_type : nil
      heap_return = ret_type.is_a?(Type) && (ret_type.heap? || ret_type.dynamic?)
      has_takes_heap = fn_node.params&.any? { |p|
        next unless p[:takes]
        ti = Type.new(p[:type] || :Any)
        ti.string? || ti.array? || ti.list_collection? || ti.map?
      }
      has_catch = fn_node.catch_clauses.is_a?(Array) && fn_node.catch_clauses.any?
      has_raise = @fn_raises_directly[name]
      # Thunk Phase 4d: :reentrant_thunk fns whose body the splitter
      # recognized get a synthesized trampoline that allocates child
      # frames via rt.heapAlloc(). Force needs_rt=true so callers
      # pass rt when calling them.
      thunk_uses_rt = !fn_node.thunk_plan.nil? || !fn_node.mutual_thunk_plan.nil?
      # Phase: recursion co-op yield. Non-TIGHT recursive fns get
      # `rt.checkYield()` injected at entry by mir_lowering, so they
      # need rt threaded.
      yield_uses_rt = recursion_yield_needed?(fn_node)
      needs_rt[name] = fn_node.uses_frame || fn_node.uses_heap || fn_node.uses_alloc || fn_node.uses_rt || heap_return || (@fn_has_fnptr[name] == true) || has_takes_heap || has_catch || has_raise || thunk_uses_rt || yield_uses_rt || name == "main"
    end

    # Seed imported (cross-module) functions: if a callee is not a local function
    # but is imported with needs_rt=true, include it so propagation works.
    @call_graph.each do |_, callees|
      callees.each do |c|
        next if needs_rt.key?(c)
        scope = lookup_scope_for(c)
        next unless scope
        sig = scope.locals[c]&.type
        sig = sig.is_a?(FunctionSignature) ? sig : nil
        needs_rt[c] = true if sig&.needs_rt
      end
    end

    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        next if needs_rt[fn_name]
        if callees.any? { |c| needs_rt[c] }
          needs_rt[fn_name] = true
          changed = T.let(true, T::Boolean)
        end
      end
    end

    @fn_nodes.each do |name, fn_node|
      fn_node.needs_rt = (needs_rt[name] == true)
    end
  end

  # Post-pass: compute can_fail for every function.
  # A function can fail if it has direct failure sources (Raise/OrRaise, frame alloc,
  # fn pointer call, @nonReentrant StackGuard try) or any transitive callee can fail.
  # main always can_fail (entry point). Callees not in @fn_nodes (stdlib/extern)
  # are excluded from propagation — they don't use CLEAR's error union convention.
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def compute_can_fail!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @fn_raises_directly = T.let(@fn_raises_directly, T.untyped)
    @call_graph = T.let(@call_graph, T.untyped)
    can_fail = {}
    @fn_nodes.each do |name, _|
      can_fail[name] = @fn_raises_directly[name] == true || name == "main"
    end

    # Seed imported (cross-module) functions that can fail.
    @call_graph.each do |_, callees|
      callees.each do |c|
        next if can_fail.key?(c)
        scope = lookup_scope_for(c)
        next unless scope
        sig = scope.locals[c]&.type
        sig = sig.is_a?(FunctionSignature) ? sig : nil
        can_fail[c] = true if sig&.can_fail
      end
    end

    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        next if can_fail[fn_name]
        if callees.any? { |c| can_fail[c] }
          can_fail[fn_name] = true
          changed = T.let(true, T::Boolean)
        end
      end
    end

    @fn_nodes.each do |name, fn_node|
      fn_node.can_fail = (can_fail[name] == true)
    end
  end

  # Enforce Zig-style fallible-signature discipline.
  # Every fn whose can_fail is true MUST declare its return type as an
  # error union (`RETURNS !T`). The user authored the body that raises
  # or that calls a fallible callee; the signature must reflect that.
  #
  # The exempt list:
  #   - main: always can_fail (entry point) per compute_can_fail!, but
  #     CLEAR allows `FN main() RETURNS Void -> ...` without `!Void`.
  #   - extern functions: their fallibility comes from the FFI signature,
  #     not the body; the !T discipline doesn't apply.
  #   - constructor / destructor / methods auto-synthesized for unions:
  #     their signatures are stamped by the annotator; user code can't
  #     change them.
  sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def enforce_fallible_returns!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    # Enforcement is gated because migrating every fallible `RETURNS T` to
    # `RETURNS !T` is a tree-wide source change. Keep the scaffolding in place
    # so the flag can flip once call sites have been migrated.
    return unless T.unsafe(FALLIBLE_RETURNS_ENFORCE)

    @fn_nodes.each do |name, fn_node|
      next unless fn_node.can_fail
      next if name == "main"
      next if fn_node.respond_to?(:extern) && fn_node.extern
      next if fn_node.respond_to?(:synthesized) && fn_node.synthesized

      # A fn that absorbs its errors locally via CATCH (or a
      # DEFAULT catch-all) doesn't propagate, so the surface
      # signature doesn't need `!T`. compute_can_fail! treats every
      # body-level RAISE / frame alloc as `can_fail = true` regardless
      # of whether a CATCH downstream consumes it; we don't want to
      # force `!T` for a fn whose contract is "I handle my own errors."
      # The codegen will reject any propagation that escapes an
      # incomplete CATCH, so an over-permissive skip here only loses
      # the early diagnostic, not a safety guarantee.
      has_catch = fn_node.respond_to?(:catch_clauses) &&
                  fn_node.catch_clauses.is_a?(Array) &&
                  fn_node.catch_clauses.any?
      has_default = fn_node.respond_to?(:default_catch) && fn_node.default_catch
      next if has_catch || has_default

      # Only explicit RETURNS clauses are enforced; omitted RETURNS did not
      # author a non-error surface type.
      next unless fn_node.respond_to?(:explicit_return_type) && fn_node.explicit_return_type

      ret = fn_node.return_type
      next unless ret

      ret_t = ret.is_a?(Type) ? ret : Type.new(ret)
      next if ret_t.error_union?
      # Promise/tense returns (`~T`, `counter:~T`) carry errors through
      # the BG fiber's join boundary, not through the surface signature.
      # `!~T` is a parse error (parser reads `~` first, then `!`), and
      # the `!` would belong AFTER the `~` if anywhere. Skip — the
      # promise itself is the fallibility surface.
      next if ret_t.respond_to?(:tense?) && ret_t.tense?

      # Find at least one source of fallibility for the diagnostic.
      hint = fallibility_hint_for(name)
      message = "Function '#{name}' can fail (#{hint}) but its return type " \
                "doesn't declare it. Change `RETURNS #{ret_t.resolved}` to " \
                "`RETURNS !#{ret_t.resolved}` so callers can see the error " \
                "union and handle it (Zig-style discipline). Add a CATCH at " \
                "the call site, propagate via `try`, or mark the call's result " \
                "with `OR <action>`."

      # Auto-fix: insert `!` immediately before the return-type token.
      # The token's column points at the start of the type identifier;
      # a zero-length `!` insert at that column produces `RETURNS !T`.
      tok = fn_node.respond_to?(:return_type_token) ? fn_node.return_type_token : nil
      if tok
        fixes = [Fix.new(
          description: "Add `!` to the return type to declare the error union " \
                       "(Zig-style fallible signature).",
          confidence: :auto,
          edits: [Edit.new(
            span: Span.new(file: nil, line: tok.line, col: tok.column, length: 0),
            replacement: '!',
          )],
        )]
        fixable!(fn_node, message: message, category: :type, level: :error, fixes: fixes)
      else
        error!(fn_node, :PURITY_VIOLATION, message: message)
      end
    end
  end

  # Set to true to flip the fallible-signature check from a NO-OP into
  # a hard compile error. See `enforce_fallible_returns!` for the
  # migration scope.
  FALLIBLE_RETURNS_ENFORCE = true

  # Best-effort source-of-fallibility hint for the enforce_fallible_returns!
  # diagnostic. Reports either a direct RAISE (if the fn raises directly)
  # or names a fallible callee (transitive fallibility).
  sig { params(name: String).returns(String) }
  def fallibility_hint_for(name)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_raises_directly = T.let(@fn_raises_directly, T.untyped)
    @call_graph = T.let(@call_graph, T.untyped)
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    return "raises directly via RAISE" if @fn_raises_directly[name]
    callees = @call_graph[name] || []
    fallible_callee = callees.find { |c| @fn_nodes[c]&.can_fail }
    return "calls fallible '#{fallible_callee}'" if fallible_callee
    "transitively"
  end

  # PASS 5b: scan all AST nodes for Identifiers used as fn-type arguments.
  # Any named function referenced as a value must adopt the rt-bearing calling
  # convention (*Runtime, params) !return — mark it needs_rt=true and can_fail=true.
  sig { params(program_node: AST::Program).returns(T::Array[T.untyped]) }
  def mark_fn_value_references!(program_node)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FuncCall, AST::MethodCall
        n.args.each do |arg|
          arg_ft = arg.full_type
          if arg.is_a?(AST::Identifier) && arg_ft.is_a?(Type) && arg_ft.fn_type?
            fn = @fn_nodes[arg.name]
            if fn
              fn.needs_rt = true
              fn.can_fail  = true
            end
          end
          traverse.call(arg)
        end
        traverse.call(n.is_a?(AST::MethodCall) ? n.object : nil)
      when AST::VarDecl, AST::BindExpr
        traverse.call(n.value)
      when AST::ReturnNode
        traverse.call(n.value)
      when AST::FunctionDef
        traverse.call(n.body)
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(program_node.statements)
  end

  # --- FSM viability classifier (Phase A) ---
  #
  # Decides per-function whether the body can be compiled to an FsmTask
  # resume fn (stackless state machine) or must remain a stackful fiber.
  #
  # Eligibility rules (Phase A conservative set):
  #   - body has at least one SUSPENDS-family effect (otherwise nothing to
  #     translate, and a one-shot task is cheaper than an FSM state struct);
  #   - body does NOT have REENTRANT (recursion needs a stack);
  #   - body does NOT have EXTERN (opaque to the scheduler);
  #   - function is not annotated @reentrant.
  #
  # BLOCKING (lock wait) is no longer disqualifying: ParkingMutex and
  # ParkingRwLock both support FSM waiters in the runtime.
  # LOOP_UNBOUND is not disqualifying: SUSPENDS_LOOP is designed for it.
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def compute_fsm_eligibility!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @fn_nodes.each do |_name, fn_node|
      effs = fn_node.effects || Set.new

      reason = nil
      if effs.include?(REENTRANT) || fn_node.reentrant == :reentrant
        reason = :reentrant
      elsif effs.include?(EXTERN)
        reason = :extern
      elsif !effs.any? { |e| SUSPENDS_FAMILY.include?(e) }
        reason = :no_suspends
      end

      fn_node.fsm_eligible = reason.nil?
      fn_node.fsm_ineligible_reason = reason
    end
  end

  # --- FSM suspend-point enumeration (Phase A) ---
  #
  # Walks each fsm_eligible function's body and tags the yield-relevant
  # call sites with a sequential id. Kinds:
  #   :io    — stdlib call flagged :suspends in STD_LIB
  #   :lock  — WithBlock acquiring an exclusive / write-locked-read lock
  #   :yield — YieldExpr inside a BG STREAM
  #   :next  — NextExpr awaiting a promise
  #   :call  — FuncCall/MethodCall to a SUSPENDS-tagged named function
  #
  # Stores fn.fsm_suspend_points as an Array of { id:, kind:, node: }.
  # Does not descend into nested FunctionDef bodies.
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def enumerate_fsm_suspend_points!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @fn_nodes.each do |_name, fn_node|
      next unless fn_node.fsm_eligible
      points = []
      scan_suspend_points(fn_node.body, fn_node, points)
      fn_node.fsm_suspend_points = points
    end
  end

  sig { params(node: T.untyped, fn_node: T.untyped, points: T::Array[T::Hash[T.untyped, T.untyped]]).returns(T.untyped) }
  def scan_suspend_points(node, fn_node, points)
    T.bind(self, SemanticAnnotator) rescue nil
    case node
    when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      # terminal
    when Array
      node.each { |n| scan_suspend_points(n, fn_node, points) }
    when AST::FunctionDef
      # don't descend into nested defs
    when AST::NextExpr
      points << { id: points.size, kind: :next, node: node }
      scan_suspend_points(node.expr, fn_node, points)
    when AST::YieldExpr
      points << { id: points.size, kind: :yield, node: node }
      scan_suspend_points(node.expr, fn_node, points)
    when AST::WithBlock
      if with_block_suspends?(node)
        points << { id: points.size, kind: :lock, node: node }
      end
      node.each_pair { |_, v| scan_suspend_points(v, fn_node, points) }
    when AST::FuncCall, AST::MethodCall
      if func_call_suspends?(node)
        kind = node.matched_stdlib_def && node.matched_stdlib_def[:suspends] ? :io : :call
        points << { id: points.size, kind: kind, node: node }
      end
      node.each_pair { |_, v| scan_suspend_points(v, fn_node, points) }
    else
      node.each_pair { |_, v| scan_suspend_points(v, fn_node, points) } if node.respond_to?(:each_pair)
    end
  end

  # A WithBlock suspends if any of its captures acquires an exclusive /
  # write-locked-read capability. Mirrors visit_WithBlock's test for
  # recording the SUSPENDS effect. `:capability` has been normalized
  # (e.g. :infer → :EXCLUSIVE) by acquire_capability! at this point.
  sig { params(node: AST::WithBlock).returns(T::Boolean) }
  def with_block_suspends?(node)
    T.bind(self, SemanticAnnotator) rescue nil
    caps = node.capabilities
    return false unless caps.is_a?(Array)
    caps.any? do |c|
      cap = c.is_a?(Hash) ? c[:capability] : nil
      cap == :EXCLUSIVE || cap == :write_locked_read
    end
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def func_call_suspends?(node)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    return true if node.matched_stdlib_def && node.matched_stdlib_def[:suspends]
    return false if node.respond_to?(:fn_var_call) && node.fn_var_call
    callee = @fn_nodes[node.name]
    return false unless callee
    effs = callee.effects
    effs && effs.any? { |e| SUSPENDS_FAMILY.include?(e) }
  end

  # --- BG spawn-form classifier (Phase A) ---
  #
  # For each BgBlock / BgStreamBlock, decide whether it could be spawned as
  # an FsmTask (:fsm) or must use the existing stackful fiber path
  # (:stackful). A BG is :fsm iff every named function transitively reachable
  # from the body is itself fsm_eligible. Pure-compute bodies (no SUSPENDS
  # in the reachable set) are still :fsm — they collapse to a trivial
  # 1-state machine that runs in a single dispatch.
  #
  # A BG is :stackful iff any transitive callee is REENTRANT or EXTERN, or
  # the body directly calls a fn-variable / fn-pointer (opaque call graph).
  sig { params(program_node: AST::Program).returns(T::Array[T.untyped]) }
  def classify_bg_spawn_form!(program_node)
    T.bind(self, SemanticAnnotator) rescue nil
    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::BgBlock, AST::BgStreamBlock
        calls, has_fnptr = scan_for_calls(n.body)
        # Explicit stack-size prefix (@micro / @large / @xl) is a user
        # directive that the body needs a real stack — keep it stackful.
        explicit_stack = n.respond_to?(:stack_size) && n.stack_size
        if explicit_stack
          n.spawn_form = :stackful
          n.fsm_ineligible_reason = :explicit_stack_size
        else
          n.spawn_form, n.fsm_ineligible_reason = bg_spawn_form_for(calls, has_fnptr)
        end
        n.fsm_suspend_points = n.spawn_form == :fsm ? collect_bg_suspend_points(n) : nil
        n.body.each { |s| traverse.call(s) }
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(program_node.statements)
  end

  # Returns [spawn_form, reason]. reason is non-nil only for :stackful.
  sig { params(callee_names: T::Set[String], has_fnptr: T::Boolean).returns(T::Array[T.nilable(Symbol)]) }
  def bg_spawn_form_for(callee_names, has_fnptr)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @call_graph = T.let(@call_graph, T.untyped)
    return [:stackful, :fn_pointer] if has_fnptr
    visited = Set.new
    queue = callee_names.to_a.dup
    until queue.empty?
      name = queue.shift
      next if visited.include?(name)
      visited << name
      fn = @fn_nodes[name]
      # Stdlib / extern callees not in @fn_nodes: treat as FSM-compatible
      # unless the callee is explicitly EXTERN at the scope level.
      next unless fn
      effs = fn.effects || Set.new
      return [:stackful, :reentrant] if effs.include?(REENTRANT) || fn.reentrant == :reentrant
      return [:stackful, :extern]    if effs.include?(EXTERN)
      (@call_graph[name] || []).each { |c| queue << c }
    end
    [:fsm, nil]
  end

  # Walk a BG body and collect its suspend points using the same rules as
  # enumerate_fsm_suspend_points!, but anchored to the BgBlock scope.
  sig { params(bg_node: T.untyped).returns(T::Array[T::Hash[T.untyped, T.untyped]]) }
  def collect_bg_suspend_points(bg_node)
    T.bind(self, SemanticAnnotator) rescue nil
    points = []
    scan_suspend_points(bg_node.body, bg_node, points)
    points
  end

  # --- Stack tier recommendation ---
  #
  # Maps each function's effect set + stack variable usage to a fiber stack tier.
  # The tier is a lower bound: the runtime control plane can upsize adaptively.
  #
  # Tiers:
  #   :micro    (4 KB)   - pure compute, no allocations, no blocking
  #   :standard (16 KB)  - heap allocations, extern calls, moderate locals
  #   :large    (64 KB)  - recursive functions, deep call chains
  #   :xl       (256 KB) - recursive + heap-heavy
  #   :service  (2 MB)   - reentrant functions (auto-assigned when call chain is unbounded)
  #
  STACK_TIER_BUDGET = T.let({ micro: 4096, standard: 16384, large: 65536, xl: 262144, service: 2_097_152 }.freeze, T::Hash[Symbol, Integer])

  # Recursion co-op yield budget: matches the runtime's YIELD_BUDGET
  # constant in zig/runtime/runtime.zig. The compiler injects
  # `rt.checkYield()` at the entry of every non-TIGHT recursive fn
  # (plain :reentrant, :TAIL_CALL); the trampoline body of :THUNK
  # already includes one. For :MAX_DEPTH(N), TIGHT is implied iff
  # N <= BUDGET; if N > BUDGET, the compiler injects the yield to
  # avoid stalling the scheduler at deep recursion.
  RECURSION_YIELD_BUDGET = 4096

  # Mirror of MIRLowering#needs_recursion_yield? for compute_needs_rt!.
  # Both must agree -- a fn that gets a yield-injected prologue must
  # have needs_rt=true so callers thread `rt`.
  sig { params(fn_node: AST::FunctionDef).returns(T::Boolean) }
  def recursion_yield_needed?(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    return false if fn_node.tight_reentrance
    case fn_node.reentrance_kind
    when :reentrant, :reentrant_tail_call, :reentrant_max_depth
      true
    else
      false
    end
  end

  sig { returns(NilClass) }
  def compute_stack_tiers!
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @call_graph = T.let(@call_graph, T.untyped)
    # Phase 1: assign base tier per function from its own effects.
    # Reentrance variants (Phase 4g):
    #   :reentrant            unbounded -> :service (OS thread)
    #   :reentrant_thunk      bounded; trampoline keeps depth = 1 on
    #                         the fiber stack (recursive Frames live
    #                         on the heap)
    #   :reentrant_tail_call  bounded; TCO turns recursion into a
    #                         self-`jmp` loop, depth = 1
    #   :reentrant_not_logical bounded; runtime asserts depth = 1 or
    #                         traps via System UnexpectedRecursion
    #   :reentrant_max_depth  bounded by N; effective stack budget
    #                         is frame * N; mutual cycles fall back
    #                         to :unbounded (interleaved counters
    #                         are too hard to bound precisely -- TODO
    #                         (Phase 5+): SCC-aware product bound)
    @fn_nodes.each do |name, fn_node|
      effs = fn_node.effects || Set.new
      stack_bytes = fn_node.stack_vars_bytes || 0
      kind = fn_node.reentrance_kind

      if kind == :reentrant
        fn_node.stack_tier = :unbounded
        fn_node.stack_vars_bytes = stack_bytes
        next
      end

      if kind == :reentrant_max_depth
        n = fn_node.max_depth_n || 1
        if mutually_recursive_in_call_graph?(name)
          fn_node.stack_tier = :unbounded
          fn_node.stack_vars_bytes = stack_bytes
          next
        end
        # Bounded; multiply per-frame stack into the worst-case bound
        # before tier selection.
        stack_bytes = stack_bytes * n
      end

      # NOTE: kind in (:reentrant_thunk, :reentrant_tail_call,
      # :reentrant_not_logical, :reentrant_max_depth (single-self),
      # nil) all reach this base-tier path. Their effective depth
      # is bounded; treat per-frame size as the worst-case stack
      # contribution (modulo MAX_DEPTH's *N already applied above).

      tier = if effs.include?(HEAP) || effs.include?(BLOCKING) || effs.include?(EXTERN)
        :standard
      elsif fn_node.needs_rt
        :standard
      else
        :micro
      end

      # Promote tier if stack-local variables alone exceed the tier budget.
      budget = T.must(STACK_TIER_BUDGET[tier])
      while stack_bytes > budget / 2 && tier != :xl
        tier = case tier
               when :micro    then :standard
               when :standard then :large
               when :large    then :xl
               else :xl
               end
        budget = T.must(STACK_TIER_BUDGET[tier])
      end

      fn_node.stack_tier = tier
      fn_node.stack_vars_bytes = stack_bytes
    end

    # Phase 2: propagate :unbounded through call graph.
    # Any function that transitively calls an :unbounded function is also :unbounded.
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        fn = @fn_nodes[fn_name]
        next unless fn
        next if fn.stack_tier == :unbounded
        if callees.any? { |c| @fn_nodes[c]&.stack_tier == :unbounded }
          fn.stack_tier = :unbounded
          changed = T.let(true, T::Boolean)
        end
      end
    end
  end

  # Phase 4g: detect mutual recursion in @call_graph (the graph
  # already excludes self-loops -- see annotator.rb:530). Returns
  # true iff `start` participates in a cycle that goes through at
  # least one other function. Used to fall back :MAX_DEPTH(N) to
  # :unbounded when the depth bound becomes a product across
  # interleaved per-fn counters.
  sig { params(start: String).returns(T::Boolean) }
  def mutually_recursive_in_call_graph?(start)
    T.bind(self, SemanticAnnotator) rescue nil
    @call_graph = T.let(@call_graph, T.untyped)
    (@call_graph[start] || Set.new).any? do |callee|
      next false if callee == start
      reachable_in_call_graph?(callee, start)
    end
  end

  sig { params(from_name: String, target: String).returns(T::Boolean) }
  def reachable_in_call_graph?(from_name, target)
    T.bind(self, SemanticAnnotator) rescue nil
    @call_graph = T.let(@call_graph, T.untyped)
    visited = Set.new
    queue = [from_name]
    until queue.empty?
      n = queue.shift
      next if visited.include?(n)
      visited << n
      return true if n == target
      queue.concat((@call_graph[n] || Set.new).to_a)
    end
    false
  end

  # Compute the maximum stack tier needed by a set of function names,
  # following the call graph transitively. :unbounded propagates.
  TIER_ORDER = T.let({ micro: 0, standard: 1, large: 2, xl: 3, service: 4, unbounded: 5 }.freeze, T::Hash[Symbol, Integer])

  sig { params(fn_names: T::Set[String]).returns(Symbol) }
  def max_tier_for_calls(fn_names)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @call_graph = T.let(@call_graph, T.untyped)
    visited = Set.new
    max = T.let(:micro, Symbol)
    queue = fn_names.to_a.dup

    until queue.empty?
      name = queue.shift
      next if visited.include?(name)
      visited << name

      fn = @fn_nodes[name]
      if fn&.stack_tier
        max = fn.stack_tier if TIER_ORDER.fetch(fn.stack_tier, 0) > TIER_ORDER.fetch(max, 0)
      end

      (@call_graph[name] || []).each { |callee| queue << callee }
    end

    max
  end

  # --- TIGHT loop validation ---

  # Deep validation for TIGHT loops: walks the full AST subtree looking for
  # calls to @reentrant or EXTERN FN functions. Stops at FunctionDef boundaries.
  sig { params(stmts: T::Array[T.untyped], loop_node: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  def validate_tight_body!(stmts, loop_node)
    T.bind(self, SemanticAnnotator) rescue nil
    return if false
    stmts = [stmts] unless stmts.is_a?(Array)
    stmts.each { |s| validate_tight_node!(s, loop_node) }
  end

  sig { params(node: T.untyped, loop_node: T.any(AST::WhileLoop, AST::ForRange)).returns(T.untyped) }
  def validate_tight_node!(node, loop_node)
    T.bind(self, SemanticAnnotator) rescue nil
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    return if node.nil?
    case node
    when Symbol, String, Integer, Float, TrueClass, FalseClass, Type
    when Array
      node.each { |n| validate_tight_node!(n, loop_node) }
    when AST::FunctionDef
      # Don't descend into nested function definitions.
    when AST::FuncCall
      if node.respond_to?(:extern_call) && node.extern_call
        error!(loop_node, :TIGHT_CALLS_EXTERN_FN, name: node.name)
      end
      fn = @fn_nodes[node.name]
      if fn&.reentrant == :reentrant
        error!(loop_node, :TIGHT_CALLS_REENTRANT_FN, name: node.name)
      end
      node.args.each { |a| validate_tight_node!(a, loop_node) }
    when AST::MethodCall
      if node.respond_to?(:extern_call) && node.extern_call
        error!(loop_node, :TIGHT_CALLS_EXTERN_FN, name: node.name)
      end
      fn = @fn_nodes[node.name]
      if fn&.reentrant == :reentrant
        error!(loop_node, :TIGHT_CALLS_REENTRANT_FN, name: node.name)
      end
      validate_tight_node!(node.respond_to?(:object) ? node.object : nil, loop_node)
      node.args.each { |a| validate_tight_node!(a, loop_node) }
    else
      node.each_pair { |_, v| validate_tight_node!(v, loop_node) } if node.respond_to?(:each_pair)
    end
  end

  # --- Reentrancy analysis ---

  # Recursively walk an annotated AST subtree and collect:
  #   - names of every directly-called named function (FuncCall where !fn_var_call)
  #   - whether any fn-type variable or lambda is invoked (fn_var_call)
  #
  # Does NOT descend into nested FunctionDef bodies (none exist in practice in CLEAR —
  # all functions are top-level — but guarded for safety).
  sig { params(node: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  def scan_for_calls(node)
    T.bind(self, SemanticAnnotator) rescue nil
    calls    = Set.new
    has_fnptr = T.let([false], T::Array[T::Boolean])

    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
        # terminals
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef
        # Don't descend into nested function definitions (own scope).
      when AST::FuncCall
        if n.fn_var_call
          has_fnptr[0] = true
        else
          calls.add(n.name)
        end
        traverse.call(n.args)
      else
        if n.respond_to?(:each_pair)
          n.each_pair { |_, v| traverse.call(v) }
        end
      end
    end

    traverse.call(node)
    [calls, has_fnptr[0]]
  end

  # Post-pass: detect indirect mutual recursion in the call graph.
  # DFS reachability: for each function F, walk F's callees transitively
  # and report an error if F is reachable from itself.
  sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def check_indirect_reentrancy!
    T.bind(self, SemanticAnnotator) rescue nil
    @call_graph = T.let(@call_graph, T.untyped)
    @fn_nodes = T.let(@fn_nodes, T.untyped)
    @fn_direct_effects = T.let(@fn_direct_effects, T.untyped)
    @call_graph.each_key do |fn_name|
      node = @fn_nodes[fn_name]
      next if node.nil?
      next if node.reentrant  # already annotated — no complaint needed

      visited = Set.new
      queue   = (@call_graph[fn_name] || Set.new).to_a

      until queue.empty?
        callee = queue.shift
        next if visited.include?(callee)
        visited.add(callee)

        if callee == fn_name
          @fn_direct_effects[fn_name]&.add(EffectTracker::REENTRANT)
          arrow = node.arrow_token
          if arrow
            fix = Fix.new(
              description: "Add `EFFECTS REENTRANT` so the runtime knows to schedule this fn on a service stack.",
              confidence: :auto,
              edits: [Edit.new(
                span: Span.new(file: nil, line: arrow.line, col: arrow.column, length: 0),
                replacement: 'EFFECTS REENTRANT '
              )]
            )
            fixable!(node,
              message: T.must(DiagnosticRegistry.format(:REENTRANCY_MUTUAL_CYCLE, name: fn_name)),
              category: :reentrance,
              level: :error,
              fixes: [fix])
          else
            error!(node, :REENTRANCY_MUTUAL_CYCLE, name: fn_name)
          end
          break
        end

        (@call_graph[callee] || Set.new).each { |c| queue << c }
      end
    end
  end

  # Scan a function body for direct failure sources (Raise/OrRaise nodes).
  # Does not descend into nested FunctionDef nodes.
  sig { params(body: T::Array[T.untyped]).returns(T.nilable(T::Boolean)) }
  def scan_for_raises(body)
    T.bind(self, SemanticAnnotator) rescue nil
    found = T.let([false], T::Array[T::Boolean])
    traverse = T.let(nil, T.untyped)
    traverse = lambda do |n|
      return if found[0]
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FunctionDef
        # Don't descend into nested function definitions.
      when AST::Raise, AST::OrRaise
        found[0] = true
      when AST::WithBlock
        # MVCC: SNAPSHOT-transactions emit `Versioned.update[Multi](...)
        # catch |__err| switch (__err) { ..., else => return __err }`,
        # so the fn body has a raise path regardless of the user's
        # ON MvccConflict action. Detect structurally rather than via
        # heap_count proxy (T1 cleanup).
        found[0] = true if n.snapshot_mode == :transaction
        # WITH with a fallible lock-error clause raises whenever a path
        # through the lowering can hit `rt.setError(...); return
        # error.CheatError;`. Two cases:
        #   1. The user's matched-selector action is :raise or :exit —
        #      the matched arm emits the raise directly.
        #   2. The clause has bubble_types — unselected error variants
        #      (typically LockCycle / Deadlock) auto-emit rt.setError +
        #      return error.CheatError regardless of the user's action.
        # When neither holds (user matched all selectors AND used a
        # non-raising action like :pass / :return / :block), no path
        # raises, so we don't flag the enclosing fn.
        if (clause = n.lock_error_clause)
          action_raises  = %i[raise exit].include?(clause[:action])
          has_bubble     = clause[:bubble_types].is_a?(Array) && !clause[:bubble_types].empty?
          found[0] = true if action_raises || has_bubble
        end
        n.body.each { |stmt| traverse.call(stmt) } unless found[0]
        n.arms&.each { |arm| arm[:body]&.each { |stmt| traverse.call(stmt) } } unless found[0]
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(body)
    found[0]
  end
end
