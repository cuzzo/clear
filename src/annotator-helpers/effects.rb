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

  # Atomics M1.6.5: contention / blocking axis for sync capabilities.
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
  SUSPENDS_FAMILY      = [SUSPENDS, SUSPENDS_CONDITIONAL, SUSPENDS_LOOP].freeze

  ALL_EFFECTS = [
    HEAP, BLOCKING, REENTRANT, LOOP_UNBOUND, EXTERN,
    YIELD, IO,
    SUSPENDS, SUSPENDS_CONDITIONAL, SUSPENDS_LOOP,
    CONTENTION, CONTENTION_MAYBE, BLOCKING_MAYBE,
  ].freeze

  # Display format: :SUSPENDS_LOOP -> "SUSPENDS:LOOP".
  def self.display(effect)
    case effect
    when SUSPENDS             then "SUSPENDS"
    when SUSPENDS_CONDITIONAL then "SUSPENDS:CONDITIONAL"
    when SUSPENDS_LOOP        then "SUSPENDS:LOOP"
    else effect.to_s
    end
  end

  # --- Phase 1: Direct collection ---

  def effects_init!
    @fn_direct_effects = {}   # fn_name => Set of direct effect symbols
    # Per-caller map of callee => worst-case call-site context
    # {loop: bool, cond: bool}. Populated by record_call_site during body
    # scanning. Used by compute_effects! to promote SUSPENDS → SUSPENDS_LOOP
    # or SUSPENDS_CONDITIONAL when the call site sits in that context.
    @call_site_context = Hash.new { |h, k| h[k] = {} }
    # Atomics M1.6.5: per-(caller, callee) list of arg-family sets, one
    # entry per call site. Used by compute_effects! to resolve callee
    # ?-form effects (CONTENTION_MAYBE / BLOCKING_MAYBE) into concrete
    # CONTENTION / BLOCKING (or to drop them) based on what families the
    # caller actually passes. Each entry is an Array<Set<Symbol>> matching
    # the call's positional args.
    @call_site_arg_families = Hash.new { |h, k| h[k] = Hash.new { |hh, kk| hh[kk] = [] } }
  end

  # Called at the start of visit_FunctionDef to prepare a fresh effect set.
  def effects_begin_function(fn_name)
    @fn_direct_effects[fn_name] = Set.new
  end

  # Record a direct effect for the function currently being analyzed.
  # For SUSPENDS specifically, promote based on current loop/conditional
  # context so the recorded effect reflects where the suspension occurs.
  def record_effect(effect)
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
  def promote_suspends_for_current_context(effect)
    return effect unless effect == SUSPENDS
    if current_loop_depth > 0
      SUSPENDS_LOOP
    elsif current_conditional_depth > 0
      SUSPENDS_CONDITIONAL
    else
      SUSPENDS
    end
  end

  def current_loop_depth
    current_fn_ctx&.loop_depth || @loop_depth || 0
  end

  def current_conditional_depth
    current_fn_ctx&.conditional_depth || @conditional_depth || 0
  end

  # Record a call site's context so transitive propagation can promote the
  # callee's SUSPENDS effects. Worst-case merge across multiple call sites.
  def record_call_site(callee_name)
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

  # Atomics M1.6.5: record the per-arg family Sets at this call site.
  # `arg_family_sets` is an Array of Set<Symbol> in positional order (same
  # length as node.args). compute_effects! reads this to resolve callee
  # CONTENTION_MAYBE / BLOCKING_MAYBE into concrete effects when the
  # families are concrete, or keeps them MAYBE when polymorphism propagates.
  def record_call_arg_families(callee_name, arg_family_sets)
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
  def compute_effects!
    # Seed from direct effects.
    resolved = {}
    @fn_direct_effects.each { |name, effs| resolved[name] = effs.dup }

    # F2: recursive functions that emit `rt.checkYield()` (either at
    # the prologue for plain :reentrant / :TAIL_CALL / :MAX_DEPTH, or
    # inside the trampoline loop for :THUNK) yield to the scheduler.
    # Seed YIELD on those fns so P3.3 (`hold-lock-across-yield`) sees
    # the suspension when the call happens inside a WITH lock body.
    # TIGHT skips the yield emission, so TIGHT fns aren't seeded.
    # NOT_LOGICAL never yields (the StackGuard doesn't suspend).
    @fn_nodes.each do |name, fn_node|
      next if fn_node.tight_reentrance
      kind = fn_node.reentrance_kind
      next unless [:reentrant, :reentrant_tail_call, :reentrant_thunk, :reentrant_max_depth].include?(kind)
      (resolved[name] ||= Set.new).add(YIELD)
    end

    # Propagate: if foo calls bar, foo inherits bar's effects
    # (with context promotion for SUSPENDS family, plus Atomics M1.6.5
    # ?-form resolution from per-call-site arg families).
    changed = true
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

  # Atomics M1.6.5: resolve callee's ?-form effects (CONTENTION_MAYBE,
  # BLOCKING_MAYBE) into concrete effects (CONTENTION, BLOCKING) when the
  # caller's call sites pin the family. Returns a new Set or the original
  # callee_set if no resolution applies.
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
  def resolve_maybe_effects(callee_set, caller_name, callee_name)
    has_block_maybe = callee_set.include?(BLOCKING_MAYBE)
    has_cont_maybe  = callee_set.include?(CONTENTION_MAYBE)
    return callee_set unless has_block_maybe || has_cont_maybe

    call_sites = @call_site_arg_families[caller_name][callee_name]
    return callee_set if call_sites.empty?

    any_concrete_lockable = false
    any_concrete_sync     = false
    any_polymorphic_arg   = false

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
  def inherit_effects_from_callee(caller_set, callee_set, site_ctx)
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
  def compute_needs_rt!
    needs_rt = {}
    @fn_nodes.each do |name, fn_node|
      ret_type = fn_node.full_type.is_a?(Type) ? fn_node.full_type[:return]&.dig(:type) : nil
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

    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        next if needs_rt[fn_name]
        if callees.any? { |c| needs_rt[c] }
          needs_rt[fn_name] = true
          changed = true
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
  def compute_can_fail!
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

    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        next if can_fail[fn_name]
        if callees.any? { |c| can_fail[c] }
          can_fail[fn_name] = true
          changed = true
        end
      end
    end

    @fn_nodes.each do |name, fn_node|
      fn_node.can_fail = (can_fail[name] == true)
    end
  end

  # PASS 5a (post-#334): enforce Zig-style fallible-signature discipline.
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
  def enforce_fallible_returns!
    # Post-#335: the rule is implemented but currently a NO-OP (off
    # behind FALLIBLE_RETURNS_ENFORCE = false). Flipping it to true
    # turns each "fn can fail but doesn't declare !T" into a hard
    # compile error. The migration cost is currently ~600 spec
    # fixtures and an unknown count of transpile-tests / examples /
    # benchmarks that need `RETURNS T` -> `RETURNS !T` -- too big
    # to land in one commit. The scaffolding (parser's
    # `explicit_return_type` stamp, this method, the diagnostic hint
    # helper) stays in place so the migration can be picked up
    # incrementally, and the flag flipped once the tree is clean.
    return unless FALLIBLE_RETURNS_ENFORCE

    @fn_nodes.each do |name, fn_node|
      next unless fn_node.can_fail
      next if name == "main"
      next if fn_node.respond_to?(:extern) && fn_node.extern
      next if fn_node.respond_to?(:synthesized) && fn_node.synthesized

      # Post-#335: only enforce on EXPLICIT `RETURNS T` clauses. A fn
      # without `RETURNS` is implicit-Void / inferred and stays exempt
      # (the user didn't author a non-error type, so there's nothing
      # to migrate). Stamped at parse time on FunctionDef#explicit_return_type.
      next unless fn_node.respond_to?(:explicit_return_type) && fn_node.explicit_return_type

      ret = fn_node.return_type
      next unless ret

      ret_t = ret.is_a?(Type) ? ret : Type.new(ret)
      next if ret_t.error_union?

      # Find at least one source of fallibility for the diagnostic.
      hint = fallibility_hint_for(name)
      error!(fn_node,
        "Function '#{name}' can fail (#{hint}) but its return type " \
        "doesn't declare it. Change `RETURNS #{ret_t.resolved}` to " \
        "`RETURNS !#{ret_t.resolved}` so callers can see the error " \
        "union and handle it (Zig-style discipline). Add a CATCH at " \
        "the call site, propagate via `try`, or mark the call's result " \
        "with `OR <action>`.")
    end
  end

  # Set to true to flip the fallible-signature check from a NO-OP into
  # a hard compile error. See `enforce_fallible_returns!` for the
  # migration scope.
  FALLIBLE_RETURNS_ENFORCE = false

  # Best-effort source-of-fallibility hint for the enforce_fallible_returns!
  # diagnostic. Reports either a direct RAISE (if the fn raises directly)
  # or names a fallible callee (transitive fallibility).
  def fallibility_hint_for(name)
    return "raises directly via RAISE" if @fn_raises_directly[name]
    callees = @call_graph[name] || []
    fallible_callee = callees.find { |c| @fn_nodes[c]&.can_fail }
    return "calls fallible '#{fallible_callee}'" if fallible_callee
    "transitively"
  end

  # PASS 5b: scan all AST nodes for Identifiers used as fn-type arguments.
  # Any named function referenced as a value must adopt the rt-bearing calling
  # convention (*Runtime, params) !return — mark it needs_rt=true and can_fail=true.
  def mark_fn_value_references!(program_node)
    traverse = lambda do |n|
      case n
      when nil, Symbol, String, Integer, Float, TrueClass, FalseClass, Type
      when Array
        n.each { |item| traverse.call(item) }
      when Hash
        n.each_value { |v| traverse.call(v) }
      when AST::FuncCall, AST::MethodCall
        n.args&.each do |arg|
          arg_ft = arg.respond_to?(:full_type) ? arg.full_type : nil
          if arg.is_a?(AST::Identifier) && arg_ft.is_a?(Type) && arg_ft.fn_type?
            fn = @fn_nodes[arg.name]
            if fn
              fn.needs_rt = true
              fn.can_fail  = true
            end
          end
          traverse.call(arg)
        end
        traverse.call(n.respond_to?(:object) ? n.object : nil)
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
  def compute_fsm_eligibility!
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
  def enumerate_fsm_suspend_points!
    @fn_nodes.each do |_name, fn_node|
      next unless fn_node.fsm_eligible
      points = []
      scan_suspend_points(fn_node.body, fn_node, points)
      fn_node.fsm_suspend_points = points
    end
  end

  def scan_suspend_points(node, fn_node, points)
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
  def with_block_suspends?(node)
    caps = node.capabilities
    return false unless caps.is_a?(Array)
    caps.any? do |c|
      cap = c.is_a?(Hash) ? c[:capability] : nil
      cap == :EXCLUSIVE || cap == :write_locked_read
    end
  end

  def func_call_suspends?(node)
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
  def classify_bg_spawn_form!(program_node)
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
  def bg_spawn_form_for(callee_names, has_fnptr)
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
  def collect_bg_suspend_points(bg_node)
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
  STACK_TIER_BUDGET = { micro: 4096, standard: 16384, large: 65536, xl: 262144, service: 2_097_152 }.freeze

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
  def recursion_yield_needed?(fn_node)
    return false if fn_node.tight_reentrance
    case fn_node.reentrance_kind
    when :reentrant, :reentrant_tail_call, :reentrant_max_depth
      true
    else
      false
    end
  end

  def compute_stack_tiers!
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
      budget = STACK_TIER_BUDGET[tier]
      while stack_bytes > budget / 2 && tier != :xl
        tier = case tier
               when :micro    then :standard
               when :standard then :large
               when :large    then :xl
               else :xl
               end
        budget = STACK_TIER_BUDGET[tier]
      end

      fn_node.stack_tier = tier
      fn_node.stack_vars_bytes = stack_bytes
    end

    # Phase 2: propagate :unbounded through call graph.
    # Any function that transitively calls an :unbounded function is also :unbounded.
    changed = true
    while changed
      changed = false
      @call_graph.each do |fn_name, callees|
        fn = @fn_nodes[fn_name]
        next unless fn
        next if fn.stack_tier == :unbounded
        if callees.any? { |c| @fn_nodes[c]&.stack_tier == :unbounded }
          fn.stack_tier = :unbounded
          changed = true
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
  def mutually_recursive_in_call_graph?(start)
    (@call_graph[start] || Set.new).any? do |callee|
      next false if callee == start
      reachable_in_call_graph?(callee, start)
    end
  end

  def reachable_in_call_graph?(from_name, target)
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
  TIER_ORDER = { micro: 0, standard: 1, large: 2, xl: 3, service: 4, unbounded: 5 }.freeze

  def max_tier_for_calls(fn_names)
    visited = Set.new
    max = :micro
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
  def validate_tight_body!(stmts, loop_node)
    return if stmts.nil?
    stmts = [stmts] unless stmts.is_a?(Array)
    stmts.each { |s| validate_tight_node!(s, loop_node) }
  end

  def validate_tight_node!(node, loop_node)
    return if node.nil?
    case node
    when Symbol, String, Integer, Float, TrueClass, FalseClass, Type
    when Array
      node.each { |n| validate_tight_node!(n, loop_node) }
    when AST::FunctionDef
      # Don't descend into nested function definitions.
    when AST::FuncCall
      if node.respond_to?(:extern_call) && node.extern_call
        error!(loop_node, "TIGHT loop cannot call EXTERN FN '#{node.name}' (opaque to scheduler)")
      end
      fn = @fn_nodes[node.name]
      if fn&.reentrant == :reentrant
        error!(loop_node, "TIGHT loop cannot call @reentrant function '#{node.name}'")
      end
      node.args&.each { |a| validate_tight_node!(a, loop_node) }
    when AST::MethodCall
      if node.respond_to?(:extern_call) && node.extern_call
        error!(loop_node, "TIGHT loop cannot call EXTERN FN '#{node.name}' (opaque to scheduler)")
      end
      fn = @fn_nodes[node.name]
      if fn&.reentrant == :reentrant
        error!(loop_node, "TIGHT loop cannot call @reentrant function '#{node.name}'")
      end
      validate_tight_node!(node.respond_to?(:object) ? node.object : nil, loop_node)
      node.args&.each { |a| validate_tight_node!(a, loop_node) }
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
  def scan_for_calls(node)
    calls    = Set.new
    has_fnptr = [false]

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
  def check_indirect_reentrancy!
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
          error!(node, "Reentrancy Error: '#{fn_name}' is part of a mutually recursive call cycle. " \
                       "Add @reentrant or @nonReentrant to the function signature.")
          break
        end

        (@call_graph[callee] || Set.new).each { |c| queue << c }
      end
    end
  end

  # Scan a function body for direct failure sources (Raise/OrRaise nodes).
  # Does not descend into nested FunctionDef nodes.
  def scan_for_raises(body)
    found = [false]
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
        # WITH with a fallible lock-error clause (RAISE / EXIT) also
        # routes through `return error.CheatError`. PASS / block-action
        # exit via `break :__with_<id>` and don't raise.
        if n.lock_error_clause && [:raise, :exit].include?(n.lock_error_clause[:action])
          found[0] = true
        end
        n.body&.each { |stmt| traverse.call(stmt) } unless found[0]
        n.arms&.each { |arm| arm[:body]&.each { |stmt| traverse.call(stmt) } } unless found[0]
      else
        n.each_pair { |_, v| traverse.call(v) } if n.respond_to?(:each_pair)
      end
    end
    traverse.call(body)
    found[0]
  end
end
