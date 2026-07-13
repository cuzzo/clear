# typed: strict
require "sorbet-runtime"
# Reentrance bridge — Thunk Phase 1.3
#
# Stamps the `EFFECTS REENTRANT[:VARIANT]` declaration into the canonical
# field on each FunctionDef.
#
# The bridge populates fn_node.reentrance_kind with one of:
#   nil                       no declaration
#   :reentrant                plain — propagates contagiously; caller @service
#   :reentrant_thunk          CPS + trampoline (Phase 4 lowering)
#   :reentrant_tail_call      self-loop, verified by stack pass
#   :reentrant_not_logical    runtime StackGuard; requires `!T` return type;
#                             raises `System UnexpectedRecursion` on re-entry
#   :reentrant_max_depth      runtime depth counter (max from max_depth_n);
#                             requires `!T`; raises `System MaxDepthExceeded`
#                             when depth > N
#
# Validation:
#   - `REQUIRES <name>: NON_REENTRANT` clauses are validated against the
#     parameter list. The fn-type check (the named param must be FN-typed)
#     is deferred to Phase 2.
#
# Mixed into SemanticAnnotator alongside EffectTracker.
module ReentranceBridge
    extend T::Sig
    extend T::Helpers

  requires_ancestor { SemanticAnnotator }

  # Compute and stamp the canonical reentrance_kind for every FunctionDef
  # in @fn_nodes. Idempotent. Validates REQUIRES clauses against the
  # parameter list of each function.
  sig { params(program_node: AST::Program).void }
  def bridge_reentrance!(program_node)
    T.bind(self, SemanticAnnotator) rescue nil
    program_node.statements.each do |stmt|
      next unless stmt.is_a?(AST::FunctionDef)
      fn_node = stmt
      kind = canonical_reentrance_kind(fn_node)
      fn_node.reentrance_kind = kind

      case kind
      when :reentrant_tail_call
        fn_node.tail_call  = true
      when :reentrant_not_logical
        # Phase 4f.2: MIRLowering emits the StackGuard prologue
        # directly from reentrance_kind. The guard raises
        # `error.UnexpectedRecursion` if the fn re-enters, and
        # function_raises_directly?(name) picks it up as a can_fail seed.
      when :reentrant_max_depth
        # Phase 4f.3: bounded recursion. The codegen path emits
        # safety.enterDepth(@src(), N) / defer safety.exitDepth(@src())
        # in the function prologue (driven by max_depth_n on the FunctionDef).
        # Recursion-yield: TIGHT is IMPLIED for :MAX_DEPTH(N) iff
        # N <= YIELD_BUDGET (4096). For N > BUDGET, the bounded
        # depth is large enough that the scheduler would stall;
        # the compiler injects the yield (effectively un-implies
        # TIGHT). User can opt out by switching to `:TIGHT:THUNK`.
        budget = EffectTracker::RECURSION_YIELD_BUDGET
        if (fn_node.max_depth_n || 0) <= budget
          fn_node.tight_reentrance = true
        else
          fn_node.tight_reentrance = false
        end
      end

      validate_requires_clauses!(fn_node)
      validate_not_logical_return!(fn_node)
      offer_unconstrained_fn_param_fix!(fn_node)
    end
  end

  # Phase 5a: corpus audit. For every fn with plain `EFFECTS REENTRANT`,
  # try to suggest a bounded variant that matches the body shape.
  # Emitted at level :info (silent in normal builds; visible to
  # `clear fix`). The goal is to shrink the @service-forced set
  # as the corpus migrates -- per docs/agents/thunks.md Phase 5.
  #
  # Suggestion priority (best-fit first):
  #   1. Simple-recurrence shape (splitter accepts) -> :THUNK
  #      (heap CPS; depth=1 fiber stack)
  #   2. Self-calls all in tail position           -> :TAIL_CALL
  #      (TCO loop; depth=1)
  #   Otherwise no auto-suggestion (the bounded-but-validated
  #   variants `:NOT_LOGICAL` / `:MAX_DEPTH(N)` change the return
  #   type and need user judgment about gas budgets, so we don't
  #   force them via auto-fix).
  sig { params(fn_node: AST::FunctionDef, body_facts: T.any(Annotator::Phases::BodyScanSummary, Annotator::Phases::FunctionBodySummary)).returns(NilClass) }
  def offer_plain_reentrant_variant_fix!(fn_node, body_facts)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless fn_node.reentrance_kind == :reentrant
    return unless fn_node.effects_span # no span => can't auto-edit
    return unless fn_node.effects_decl == :reentrant # only act on the new clause

    suggestion_reason = T.let([], T::Array[String])
    if thunk_all_self_calls_in_tail_position?(fn_node, body_facts)
      suggestion_reason = [
        "EFFECTS REENTRANT:TAIL_CALL",
        "all self-calls are in tail position; TCO turns this into a self-`jmp` loop with depth=1"
      ]
    elsif ThunkTransform::RecursiveSplitter.split(fn_node.body, fn_node.name)
      suggestion_reason = [
        "EFFECTS REENTRANT:THUNK",
        "the body matches the simple-recurrence shape; heap CPS keeps the fiber stack at depth=1"
      ]
    end
    return if suggestion_reason.empty?

    suggestion = T.must(suggestion_reason.first)
    edits = effects_clause_edits(fn_node, suggestion)
    return if edits.empty?

    span = fn_node.effects_span
    reason = T.must(suggestion_reason[1])

    fixable!(span[:start_tok],
      level: :info,
      category: :reentrance,
      code: :PLAIN_REENTRANT_VARIANT_SUGGESTION,
      fn: fn_node.name,
      reason: reason,
      suggestion: suggestion,
      fixes: [Fix.new(
        description: fix_description(:REPLACE_REENTRANT_WITH_VARIANT, suggestion: suggestion, reason: reason),
        confidence: :auto,
        edits: edits,
      )])
  end

  # Phase 4f.2/4f.3: `:NOT_LOGICAL` and `:MAX_DEPTH(N)` both compile
  # in a runtime guard that can raise. They require the user to
  # declare an error-union return type (`!T`) so callers handle (or
  # propagate) the failure explicitly. Errors raised:
  #   :NOT_LOGICAL  -> System UnexpectedRecursion (StackGuard)
  #   :MAX_DEPTH(N) -> System MaxDepthExceeded    (depth counter)
  sig { params(fn_node: AST::FunctionDef).returns(NilClass) }
  def validate_not_logical_return!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless [:reentrant_not_logical, :reentrant_max_depth].include?(fn_node.reentrance_kind)
    rt = fn_node.declared_return_type
    return if rt&.error_union?

    rt_str = rt ? rt.to_s : "Void"
    suggested = rt.nil? ? "!Void" : "!#{rt_str.sub(/\A!/, '')}"
    err_name = fn_node.reentrance_kind == :reentrant_not_logical ?
      "UnexpectedRecursion" : "MaxDepthExceeded"
    variant_text = fn_node.reentrance_kind == :reentrant_not_logical ?
      "EFFECTS REENTRANT:NOT_LOGICAL" :
      "EFFECTS REENTRANT:MAX_DEPTH(#{fn_node.max_depth_n})"
    error!(fn_node, :REENTRANT_NEEDS_FALLIBLE_RETURN,
      variant_text: variant_text, fn: fn_node.name, err: err_name, rt: rt_str, suggested: suggested)
  end

  # Thunk Phase 4b: tail-recursive `:reentrant_thunk` functions
  # piggyback on the existing :TAIL_CALL MIR emission for now -- the
  # generated Zig is identical to what `:TAIL_CALL` produces (an
  # `@call(.always_tail, ...)` self-loop). Phase 4c will replace this
  # with real heap-allocated CPS frames + a synthesized trampoline
  # for the non-tail case; Phase 4b only handles the tail case.
  #
  # The routing is transparent: we set fn_node.tail_call = true so
  # the existing emission path applies. The reentrance_kind stays
  # :reentrant_thunk for downstream effect-propagation rules (Phase
  # 5 will use this to keep :THUNK out of @service).
  sig { params(fn_node: AST::FunctionDef, body_facts: T.any(Annotator::Phases::BodyScanSummary, Annotator::Phases::FunctionBodySummary)).returns(T.nilable(T::Boolean)) }
  def route_thunk_to_tail_call_compat!(fn_node, body_facts)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless fn_node.reentrance_kind == :reentrant_thunk
    return unless thunk_all_self_calls_in_tail_position?(fn_node, body_facts)
    fn_node.tail_call = true
  end

  # Tail-call lowering relies on recursion becoming a self-loop; any
  # wrapped or nested self-call would still consume real stack.
  sig { params(fn_node: AST::FunctionDef, body_scan: Annotator::Phases::BodyScanSummary).void }
  def validate_tail_call!(fn_node, body_scan)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_name = fn_node.name
    all_self_calls = body_scan.call_site_facts.filter_map { |fact|
      fact.node if fact.callee_name == fn_name
    }

    blessed = body_scan.return_nodes.filter_map { |return_node|
      value = return_node.value
      value if value.is_a?(AST::FuncCall) && value.name == fn_name
    }
    blessed_ids = blessed.map(&:object_id).to_set

    if blessed.empty?
      error!(fn_node, :TAIL_CALL_NEEDS_RECURSIVE,
        fn: fn_name)
    end

    all_self_calls.each do |call|
      next if blessed_ids.include?(call.object_id)
      error!(call, :TAIL_CALL_NOT_TAIL_POSITION,
        fn: fn_name)
    end
  end

  # Plain `EFFECTS REENTRANT` callees require explicit `@service` on the
  # spawn site so OS-thread cost is an explicit user choice.
  sig { params(node: EffectTracker::AsyncValidationNode, call_names: T::Set[String], user_size: T.nilable(Symbol), can_smash: T::Boolean).void }
  def validate_fiber_stack!(node, call_names, user_size, can_smash)
    T.bind(self, SemanticAnnotator) rescue nil
    if can_smash
      emit_can_smash_unsupported_error!(node)
      return
    end

    plain_reentrant_callee = find_plain_reentrant_callee(call_names)
    if plain_reentrant_callee && user_size != :service
      emit_service_required_error!(node, plain_reentrant_callee, user_size)
      return
    end

    raw = max_tier_for_calls(call_names)
    # Bounded variants no longer hit :unbounded; only mutual-MAX_DEPTH falls
    # back to :unbounded here, which requires explicit @service below.
    computed = (raw == :unbounded) ? :service : raw

    if raw == :unbounded && user_size != :service
      mutual_md_callee = find_mutual_max_depth_callee(call_names)
      if mutual_md_callee
        error!(node, :STACK_SAFETY_MUTUAL_RECURSION,
          callee: mutual_md_callee)
        return
      end
    end

    if user_size == :stack
      warning!(node, T.must(DiagnosticRegistry.format(:STACK_SAFETY_STACK_ALIAS, computed: computed)))
      return
    end

    if user_size && EffectTracker::TIER_ORDER.fetch(user_size, 0) < EffectTracker::TIER_ORDER.fetch(computed, 0)
      error!(node, :STACK_SAFETY_USER_SIZE_TOO_SMALL,
        size: user_size,
        budget: EffectTracker::STACK_TIER_BUDGET[user_size],
        computed: computed)
    end
  end

  # Walk the call graph from the BG body and return the name of the first
  # plain `EFFECTS REENTRANT` callee. Bounded variants do not force @service.
  sig { params(call_names: T::Set[String]).returns(T.nilable(String)) }
  def find_plain_reentrant_callee(call_names)
    T.bind(self, SemanticAnnotator) rescue nil
    visited = T.let(Set.new, T::Set[String])
    queue = T.let(call_names.to_a.dup, T::Array[String])
    until queue.empty?
      name = T.must(queue.shift)
      next if visited.include?(name)
      visited << name
      fn = function_node_for(name)
      return name if fn && fn.reentrance_kind == :reentrant
      (function_call_graph[name] || []).each { |callee| queue << callee }
    end
    nil
  end

  # Return the first `:MAX_DEPTH(N)` callee that is still mutually recursive;
  # such functions force spawn sites to @service until SCC depth products exist.
  sig { params(call_names: T::Set[String]).returns(T.nilable(String)) }
  def find_mutual_max_depth_callee(call_names)
    T.bind(self, SemanticAnnotator) rescue nil
    visited = T.let(Set.new, T::Set[String])
    queue = T.let(call_names.to_a.dup, T::Array[String])
    until queue.empty?
      name = T.must(queue.shift)
      next if visited.include?(name)
      visited << name
      fn = function_node_for(name)
      return name if fn && fn.reentrance_kind == :reentrant_max_depth && mutually_recursive_in_call_graph?(name)
      (function_call_graph[name] || []).each { |callee| queue << callee }
    end
    nil
  end

  # Emit @service-required as a fixable when the spawn-site span is known;
  # DO branches fall back to a plain error because their span is ambiguous.
  sig { params(node: EffectTracker::AsyncValidationNode, reentrant_fn: String, user_size: T.nilable(Symbol)).void }
  def emit_service_required_error!(node, reentrant_fn, user_size)
    T.bind(self, SemanticAnnotator) rescue nil
    fix = service_required_fix(node, user_size)

    return error!(node, :STACK_NEEDS_SERVICE_FIXABLE, reentrant_fn: reentrant_fn) unless fix

    fixable!(node, code: :STACK_NEEDS_SERVICE_FIXABLE, reentrant_fn: reentrant_fn,
             category: :reentrance, level: :error,
             fixes: [fix], raise_in_collector: false)
  end

  sig { params(node: EffectTracker::AsyncValidationNode, user_size: T.nilable(Symbol)).returns(T.nilable(Fix)) }
  def service_required_fix(node, user_size)
    T.bind(self, SemanticAnnotator) rescue nil
    return nil unless node.is_a?(AST::BgBlock)

    prefix_token = node.prefix_token
    return replace_stack_sigil_with_service_fix(prefix_token, user_size) if prefix_token

    open_brace_token = node.open_brace_token
    return insert_service_after_open_brace_fix(open_brace_token) if open_brace_token

    nil
  end

  sig { params(token: Lexer::Token, user_size: T.nilable(Symbol)).returns(Fix) }
  def replace_stack_sigil_with_service_fix(token, user_size)
    Fix.new(
      description: DiagnosticRegistry.fix_description(:REPLACE_STACK_SIGIL_WITH_SERVICE, stack: user_size),
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: token.line, col: token.column, length: token.value.to_s.length),
        replacement: "@service",
      )],
    )
  end

  sig { params(token: Lexer::Token).returns(Fix) }
  def insert_service_after_open_brace_fix(token)
    Fix.new(
      description: DiagnosticRegistry.fix_description(:INSERT_SERVICE_AFTER_OPEN_BRACE),
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: token.line, col: token.column + 1, length: 0),
        replacement: " @service ->",
      )],
    )
  end

  # Thunk Phase 4f: validate that every `:reentrant_thunk` function
  # is genuinely recursive (direct or mutual) AND that the recursion
  # shape is supported by the current sub-phase. Runs as Pass 4.1
  # in the annotator (after check_indirect_reentrancy populates
  # function_call_graph cycles), so transitive reachability is available.
  #
  # Three buckets, each with a precise forward-pointing error
  # message naming the sub-phase that will (or won't) support it:
  #
  #   1. Not recursive at all (no path back to self in function_call_graph)
  #      -> "Remove ':THUNK' -- the function is not recursive."
  #   2. Directly self-recursive
  #      -> OK; Phase 4a-d already handle this (factorial-shape).
  #   3. Mutually recursive only (cycle goes through other fns)
  #      -> "Phase 4f.1 will land tagged-union frames; for now
  #          declare ':TAIL_CALL' or use plain 'EFFECTS REENTRANT'."
  # F1: REENTRANT:NOT_LOGICAL on a function that the call-graph
  # proves is reachable from itself (directly or transitively) is a
  # contract the runtime StackGuard cannot keep -- every call would
  # raise System UnexpectedRecursion. Reject at compile time and
  # nudge toward the variants that actually handle recursion
  # (`:THUNK` if you want to fold it; `:MAX_DEPTH(N)` if you want a
  # bounded depth). Runs after `check_indirect_reentrancy!` so the
  # call-graph is settled and transitive cycles are visible.
  sig { void }
  def validate_not_logical_recursion!
    T.bind(self, SemanticAnnotator) rescue nil
    fn_nodes = function_node_map
    fn_nodes.each do |name, fn_node|
      next unless fn_node.reentrance_kind == :reentrant_not_logical

      # `function_call_graph[name]` strips self-calls (annotator.rb:599), so
      # direct self-recursion shows up in the direct-effect map
      # as the REENTRANT marker recorded at visit_FunctionDef. Mutual
      # cycles still go through `reachable_from_self?`.
      direct = effect_direct_effects_for(name).include?(EffectTracker::REENTRANT)
      mutual = !direct && reachable_from_self?(name)
      next unless direct || mutual

      cycle_desc = direct ?
        "directly calls itself" :
        "is part of a mutually recursive call cycle (reachable from itself via #{thunk_cycle_members(name).sort.join(', ')})"

      error!(fn_node, :REENTRANT_NOT_LOGICAL_BUT_RECURSIVE, name: name, cycle_desc: cycle_desc)
    end
  end

  # F4: EFFECTS REENTRANT:MAX_DEPTH(N) on a function whose name
  # appears in a function_call_graph cycle silently demotes the cycle to
  # `:unbounded` stack tier (4 MB :service OS thread per fiber) --
  # the user picked `:MAX_DEPTH` precisely to avoid that cost; the
  # silent demotion defeats the choice. Computing a precise SCC
  # product bound is Phase 5+ work; until then, emit a fixable
  # warning so the user can make an informed call.
  #
  # Direct self-recursion is fine -- the depth counter handles it
  # exactly. Only the cross-fn cycle case demotes.
  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def validate_max_depth_mutual_cycle!
    T.bind(self, SemanticAnnotator) rescue nil
    fn_nodes = function_node_map
    fn_nodes.each do |name, fn_node|
      next unless fn_node.reentrance_kind == :reentrant_max_depth
      # Direct-only is fine; counter handles it.
      direct = effect_direct_effects_for(name).include?(EffectTracker::REENTRANT)
      mutual = !direct && reachable_from_self?(name)
      next unless mutual

      cycle_members = thunk_cycle_members(name).sort

      fixes = []
      drop_edits = effects_clause_edits(fn_node, "EFFECTS REENTRANT")
      if drop_edits.any?
        fixes << Fix.new(
          description: fix_description(:DROP_MAX_DEPTH_MUTUAL, max_depth: fn_node.max_depth_n),
          confidence: :auto,
          edits: drop_edits,
        )
      end

      if fixes.empty?
        fixable!(fn_node, code: :REENTRANT_MAX_DEPTH_MUTUAL_DEMOTED,
                 fn: name, max_depth: fn_node.max_depth_n, cycle: cycle_members.join(', '),
                 category: :reentrance, level: :warning,
                 raise_in_collector: false, fixes:)
      else
        fixable!(fn_node, code: :REENTRANT_MAX_DEPTH_MUTUAL_DEMOTED,
                 fn: name, max_depth: fn_node.max_depth_n, cycle: cycle_members.join(', '),
                 category: :reentrance, level: :warning,
                 fixes: fixes, raise_in_collector: false)
      end
    end
  end

  sig { void }
  def validate_thunk_recursion!
    T.bind(self, SemanticAnnotator) rescue nil
    fn_nodes = function_node_map
    fn_nodes.each do |name, fn_node|
      next unless fn_node.reentrance_kind == :reentrant_thunk
      next if fn_node.tail_call # tail-recursive :THUNK already routed (Phase 4b)
      next if fn_node.thunk_plan # simple-recurrence handled by Phase 4d codegen
      next if fn_node.mutual_thunk_plan # tagged-union mutual handled by Phase 4f.1

      direct = (function_call_graph[name] || Set.new).include?(name)
      mutually = !direct && reachable_from_self?(name)

      if direct
        # Direct self-recursion that Phase 4d's splitter didn't
        # match a known shape for. The annotator's Phase 4b error
        # path (in visit_FunctionDef) already fired with a precise
        # "this phase does not yet recognize" message; nothing
        # more to do here.
        next
      elsif mutually
        # Phase 4f.1: try to detect a tail-position 2-cycle of
        # `:reentrant_thunk` functions. If every member matches the
        # mutual-recurrence shape (zero or more IF base cases + one
        # final RETURN partner(args)), stamp `mutual_thunk_plan` on
        # each so MIR lowering synthesizes a tagged-union trampoline.
        # Otherwise fall through to the precise error.
        next if try_stamp_mutual_thunk_plan!(fn_node)
        emit_mutual_thunk_unsupported!(fn_node)
      else
        error!(fn_node, :REENTRANT_THUNK_NOT_RECURSIVE, name: name)
      end
    end
  end

  # Phase 4f.1: try to detect a tail-position mutual-recurrence
  # cycle including `fn_node`. If every cycle member is
  # `:reentrant_thunk`, has a matching return type, and matches the
  # `IF base; ...; RETURN partner(args);` shape (no nested calls,
  # no combine ops), stamp a MutualThunkPlan on every member and
  # return true. Otherwise return false (the caller emits the
  # precise error).
  sig { params(fn_node: AST::FunctionDef).returns(T::Boolean) }
  def try_stamp_mutual_thunk_plan!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_nodes = function_node_map
    cycle_names = thunk_cycle_members(fn_node.name)
    return false if cycle_names.size < 2
    # Phase 4f.1 scope: every cycle member must be defined locally
    # AND declare :reentrant_thunk AND not already be claimed by
    # the simple-recurrence (Phase 4d) path.
    cycle_fns = cycle_names.map { |n| fn_nodes[n] }
    return false if cycle_fns.any?(&:nil?)
    concrete_cycle_fns = T.let(cycle_fns.compact, T::Array[AST::FunctionDef])
    return false unless concrete_cycle_fns.all? { |f| f.reentrance_kind == :reentrant_thunk }
    return false if concrete_cycle_fns.any? { |f| f.tail_call || f.thunk_plan }

    # All members must agree on return type so the union can hold
    # any variant's payload and the trampoline can return a single
    # value type. (A Phase 4f.2 expansion may relax this via Zig
    # comptime-generated trampolines per (entry, ret-type) tuple.)
    #
    # `return_type` is a `Type` instance after analyze_routine; Type
    # defines `==` but NOT `eql?`/`hash`, so `Array#uniq` would fall
    # back to object identity and treat two `Type(@raw=:Bool)`
    # instances as distinct. Route through the resolved-symbol's
    # `to_s` so dedup is value-based. (CLEAR has no user-level type
    # aliases, so different `to_s` strings always mean different
    # canonical types -- this is correct, not just convenient.)
    ret_types = concrete_cycle_fns.map(&:return_type).map { |t| t&.to_s }.uniq
    return false unless ret_types.size == 1

    plans = T.let({}, T::Hash[String, ThunkTransform::RecursiveSplitter::MutualPlan])
    concrete_cycle_fns.each do |f|
      partners = cycle_names - [f.name]
      mp = ThunkTransform::RecursiveSplitter.split_mutual(f.body, f.name, partners)
      return false if mp.nil?
      plans[f.name] = mp
    end

    concrete_cycle_fns.each do |f|
      f.mutual_thunk_plan = ThunkTransform::RecursiveSplitter::MutualThunkPlan.new(
        cycle_fns: concrete_cycle_fns,
        own_plan:  T.must(plans[f.name]),
      )
    end
    true
  end

  # Phase 4f.2: emit the mutual-thunk-unsupported diagnostic as a
  # fixable finding with two migration paths. Falls back to plain
  # error! when neither path can be expressed as edits (cycle members
  # missing tokens, etc.).
  #
  # Fix 1 (interactive): drop ':THUNK' on every cycle member (use
  # plain 'EFFECTS REENTRANT'). Callers must be on @service.
  #
  # Fix 2 (interactive): swap ':THUNK' -> ':NOT_LOGICAL' on every
  # cycle member AND prepend `!` to each return type. Asserts at
  # runtime that the cycle is logically impossible; raises System
  # UnexpectedRecursion if violated.
  sig { params(fn_node: AST::FunctionDef).void }
  def emit_mutual_thunk_unsupported!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_nodes = function_node_map
    name = fn_node.name
    cycle_names = thunk_cycle_members(name)
    cycle_thunk_fns = cycle_names.filter_map { |n| fn_nodes[n] }
                                  .select { |f| f.reentrance_kind == :reentrant_thunk }

    fixes = []
    edits_plain = cycle_thunk_fns.flat_map { |f| effects_clause_edits(f, "EFFECTS REENTRANT") }
    if edits_plain.length == cycle_thunk_fns.length && !edits_plain.empty?
      fixes << Fix.new(
        description: fix_description(:DROP_THUNK_CYCLE),
        confidence: :interactive,
        edits: edits_plain,
      )
    end

    edits_nl = []
    nl_ok = !cycle_thunk_fns.empty?
    cycle_thunk_fns.each do |f|
      eff = effects_clause_edits(f, "EFFECTS REENTRANT:NOT_LOGICAL")
      if eff.empty?
        nl_ok = false
        break
      end
      edits_nl.concat(eff)
      rt = f.declared_return_type
      next if rt&.error_union?
      rt_tok = f.return_type_token
      if rt_tok.nil?
        nl_ok = false
        break
      end
      edits_nl << Edit.new(
        span: Span.new(file: nil, line: rt_tok.line, col: rt_tok.column, length: 0),
        replacement: "!"
      )
    end
    if nl_ok
      fixes << Fix.new(
        description: fix_description(:DECLARE_NOT_LOGICAL_CYCLE),
        confidence: :interactive,
        edits: edits_nl,
      )
    end

    # Fix 3: ':MAX_DEPTH(N)' on every cycle member. Same `!T` shape
    # as :NOT_LOGICAL, but the guard counts depth instead of asserting
    # zero. Default N = 64 (matches typical stack-budget-sized
    # recursion); user adjusts post-fix. This is an interactive fix
    # because there is NO universally-correct N -- a too-large N
    # silently lets stack-bound recursion through.
    edits_md = []
    md_ok = !cycle_thunk_fns.empty?
    default_n = 64
    cycle_thunk_fns.each do |f|
      eff = effects_clause_edits(f, "EFFECTS REENTRANT:MAX_DEPTH(#{default_n})")
      if eff.empty?
        md_ok = false
        break
      end
      edits_md.concat(eff)
      rt = f.declared_return_type
      next if rt&.error_union?
      rt_tok = f.return_type_token
      if rt_tok.nil?
        md_ok = false
        break
      end
      edits_md << Edit.new(
        span: Span.new(file: nil, line: rt_tok.line, col: rt_tok.column, length: 0),
        replacement: "!"
      )
    end
    if md_ok
      fixes << Fix.new(
        description: fix_description(:DECLARE_MAX_DEPTH_CYCLE, depth: default_n),
        confidence: :interactive,
        edits: edits_md,
      )
    end

    return error!(
      fn_node,
      :REENTRANT_MUTUAL_THUNK_UNSUPPORTED,
      name: name,
      cycle: cycle_names.sort.join(', ')
    ) if fixes.empty?

    fixable!(fn_node,
             code: :REENTRANT_MUTUAL_THUNK_UNSUPPORTED,
             name: name,
             cycle: cycle_names.sort.join(', '),
             category: :reentrance, level: :error,
             fixes: fixes, raise_in_collector: false)
  end

  # Build the Edit(s) that replace the entire `EFFECTS REENTRANT[:VARIANT]`
  # clause text on a function with `replacement`. Uses the parser-saved
  # effects_span tokens. Returns [] when the span is missing or crosses
  # lines (multi-line edits aren't expressible with the current Span
  # shape and the user's source layout would need manual editing anyway).
  sig { params(fn_node: AST::FunctionDef, replacement: String).returns(T::Array[Edit]) }
  def effects_clause_edits(fn_node, replacement)
    T.bind(self, SemanticAnnotator) rescue nil
    span = fn_node.effects_span
    return [] unless span && span[:start_tok] && span[:end_tok]
    s = span[:start_tok]
    e = span[:end_tok]
    return [] if s.line != e.line
    end_col = e.column + e.value.to_s.length
    [Edit.new(
      span: Span.new(file: nil, line: s.line, col: s.column, length: end_col - s.column),
      replacement: replacement,
    )]
  end

  # Strongly-connected component containing `start` in function_call_graph
  # (intersection of forward- and backward-reachable sets, plus
  # `start` itself when start is on a cycle). Used by Phase 4f.1
  # to enumerate cycle members for tagged-union frame codegen.
  sig { params(start: String).returns(T::Array[String]) }
  def thunk_cycle_members(start)
    T.bind(self, SemanticAnnotator) rescue nil
    start_s = start.to_s
    forward = compute_reachable(function_call_graph, start_s)
    reverse_graph = {}
    function_call_graph.each do |s, callees|
      callees.each { |t| (reverse_graph[t.to_s] ||= Set.new) << s.to_s }
    end
    backward = compute_reachable(reverse_graph, start_s)
    scc = forward & backward
    scc << start_s if forward.include?(start_s)
    scc.to_a
  end

  sig { params(graph: T::Hash[String, T::Set[String]], start: String).returns(T::Set[String]) }
  def compute_reachable(graph, start)
    T.bind(self, SemanticAnnotator) rescue nil
    seen = Set.new
    queue = (graph[start] || Set.new).to_a
    until queue.empty?
      n = queue.shift.to_s
      next if seen.include?(n)
      seen << n
      queue.concat((graph[n] || Set.new).to_a)
    end
    seen
  end

  # BFS over function_call_graph: is `start` reachable from itself via at
  # least one edge? (Used to detect mutual recursion -- a fn that
  # transitively calls back to itself but doesn't have a direct
  # self-call edge.)
  sig { params(start: String).returns(T::Boolean) }
  def reachable_from_self?(start)
    T.bind(self, SemanticAnnotator) rescue nil
    visited = Set.new
    queue   = (function_call_graph[start] || Set.new).to_a
    until queue.empty?
      callee = queue.shift
      next if visited.include?(callee)
      visited << callee
      return true if callee == start
      queue.concat((function_call_graph[callee] || Set.new).to_a)
    end
    false
  end

  # Yes/no version of the strict TAIL_CALL check (Phase 3's
  # validate_tail_call! errors -- this returns true/false). Used by
  # the Phase 4b router to decide whether the tail-call emission
  # path can handle a `:THUNK` function.
  #
  # Returns true iff the function is self-recursive AND every
  # recursive self-call is the direct value of a RETURN node.
  sig { params(fn_node: AST::FunctionDef, body_facts: T.any(Annotator::Phases::BodyScanSummary, Annotator::Phases::FunctionBodySummary)).returns(T::Boolean) }
  def thunk_all_self_calls_in_tail_position?(fn_node, body_facts)
    T.bind(self, SemanticAnnotator) rescue nil
    all = body_facts.call_site_facts.filter_map { |fact|
      fact.node if fact.callee_name == fn_node.name
    }
    return false if all.empty?
    blessed = body_facts.return_nodes.filter_map { |r|
      r.value if r.value.is_a?(AST::FuncCall) && r.value.name == fn_node.name
    }
    return false if blessed.empty?
    blessed_ids = blessed.map(&:object_id).to_set
    all.all? { |c| blessed_ids.include?(c.object_id) }
  end

  sig { params(fn_node: AST::FunctionDef).returns(T.nilable(Symbol)) }
  def canonical_reentrance_kind(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    fn_node.effects_decl
  end

  # Each REQUIRES clause must reference an actual parameter by name.
  # The FN-type check (parameter must be FN-typed for NON_REENTRANT to
  # make sense) is Phase 2's unconstrained-fn-param pass; here we only
  # check the binding exists.

  # Thunk Phase 2: warn on FN-typed parameters that lack a REQUIRES
  # constraint, and offer two interactive fixes:
  #
  #   [1] add `REQUIRES <name>: NON_REENTRANT` to each unconstrained param
  #       (the conservative default — matches today's implicit behavior;
  #       calls into the param accept thunked / tail-call / non-recursive
  #       callbacks but reject plain REENTRANT)
  #
  #   [2] add `EFFECTS REENTRANT` to the enclosing function
  #       (the propagation default — caller becomes reentrant too;
  #       calls into the param accept any callback shape)
  #
  # `clear fix --yes` picks [1] (NON_REENTRANT) since most callers don't
  # actually want their callee on @service. The smarter "default to [2]
  # when the body is transitively reentrant" auto-pick is a follow-up
  # since it requires Pass 6 (effects propagation), which runs AFTER
  # this bridge.
  #
  # Phase 1.5 emitted this finding at level :info (silent in normal
  # builds, visible to `clear fix`). Phase 2 escalates to :warning so
  # users see the diagnostic during regular `clear build`. Phase 3 will
  # promote to :error after a deprecation window.
  #
  # Skipped per-param when:
  #   - the function declares EFFECTS REENTRANT (caller opted in)
  #   - the function already has a REQUIRES clause for this name
  #
  # Skipped wholesale when:
  #   - the function declares ANY reentrance kind (REENTRANT plain,
  #     :THUNK, or :TAIL_CALL) -- the user has already taken a stance
  #     on reentrance and constraining the param is not their choice
  sig { params(fn_node: AST::FunctionDef).void }
  def offer_unconstrained_fn_param_fix!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    return if [:reentrant, :reentrant_thunk, :reentrant_tail_call, :reentrant_not_logical, :reentrant_max_depth].include?(fn_node.reentrance_kind)
    return unless fn_node.arrow_token

    existing = fn_node.requires_clauses || {}
    candidates = fn_node.params.filter_map do |p|
      name = p.name
      next nil if existing.key?(name)
      type = p.type
      next nil unless type.respond_to?(:fn_type?) && type.fn_type?
      raw = type.respond_to?(:raw) ? type.raw : nil
      next nil if raw.is_a?(FunctionSignature) && raw.reentrant == true
      name
    end
    return if candidates.empty?

    arrow = fn_node.arrow_token
    requires_insert = candidates.map { |n| "REQUIRES #{n}: NON_REENTRANT " }.join
    requires_desc = candidates.map { |n| "REQUIRES #{n}: NON_REENTRANT" }.join(' + ')
    constrain_fix = Fix.new(
      description: fix_description(:ADD_NON_REENTRANT_REQUIRES, requires: requires_desc),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: arrow.line, col: arrow.column, length: 2),
        replacement: "#{requires_insert}->",
      )],
    )
    propagate_fix = Fix.new(
      description: fix_description(:DECLARE_FN_REENTRANT, fn: fn_node.name),
      confidence: :interactive,
      edits: [Edit.new(
        span: Span.new(file: nil, line: arrow.line, col: arrow.column, length: 2),
        replacement: "EFFECTS REENTRANT ->",
      )],
    )

    msg_subject = candidates.size == 1 ?
      "an unconstrained FN-typed parameter" :
      "unconstrained FN-typed parameters"
    fixable!(arrow,
      level: :warning,
      category: :lint,
      code: :UNCONSTRAINED_FN_PARAM_REENTRANCE,
      fn: fn_node.name,
      subject: msg_subject,
      candidates: candidates.join(', '),
      fixes: [constrain_fix, propagate_fix])
  end

  sig { params(fn_node: AST::FunctionDef).void }
  def validate_requires_clauses!(fn_node)
    T.bind(self, SemanticAnnotator) rescue nil
    return if fn_node.requires_clauses.nil? || fn_node.requires_clauses.empty?
    # Params come from the parser as hashes ({ name:, type:, default:, ... }).
    # See pre_register_function in annotator.rb.
    param_names = fn_node.params.map { |p| p.name }.compact.to_set
    fn_node.requires_clauses.each do |bound_name, _kind|
      next if param_names.include?(bound_name)
      error!(fn_node, :REQUIRES_NON_REENTRANT_NOT_PARAM, fn: fn_node.name, name: bound_name)
    end
  end

  private :emit_mutual_thunk_unsupported!
  private :canonical_reentrance_kind
  private :compute_reachable
  private :emit_service_required_error!
  private :find_mutual_max_depth_callee
  private :find_plain_reentrant_callee
  private :insert_service_after_open_brace_fix
  private :offer_unconstrained_fn_param_fix!
  private :reachable_from_self?
  private :replace_stack_sigil_with_service_fix
  private :service_required_fix
  private :thunk_all_self_calls_in_tail_position?
  private :thunk_cycle_members
  private :try_stamp_mutual_thunk_plan!
  private :validate_not_logical_return!
  private :validate_requires_clauses!

end
