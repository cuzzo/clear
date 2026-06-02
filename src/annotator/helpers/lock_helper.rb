# typed: strict
require "sorbet-runtime"
require "set"

# All lock-safety analysis lives here. Two layers in one module so they
# share state (@held_lock_types, @held_locks, the lock-edge accumulator)
# without cross-file surgery:
#
#   Phase 1 — lexical same-name nested-WITH check
#     Catches `WITH EXCLUSIVE c { WITH EXCLUSIVE c { ... } }` (and the
#     write_locked_read variant) as a structural self-deadlock. Pure
#     AST walk; no type analysis, no call-graph. Opt-out: per-WITH
#     POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE modifier downgrades the
#     error to a [Note].
#
#   Phase 2 — global type-level cycle detection
#     Per-fn collection of:
#       - direct_acquires: lock types acquired by fallible WITH blocks
#       - direct_edges:    (held, acquired) pairs from nested WITH sites
#       - held_calls:      (held, callee) pairs for held-during-call sites
#     Post-pass:
#       1. Fixed-point propagate acquires through function_call_graph.
#       2. Resolve held_calls into synthetic edges via callee's transitive
#          acquires.
#       3. Build the global held->acquired graph over non-opted-out edges.
#       4. Tarjan SCC; cycles = errors.
#
# Opt-outs: a WITH carrying POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE emits
# edges with :opted_out = true. These are excluded from the cycle graph
# but still surface in diagnostics so the risk remains visible in code
# review.
#
# Future Phase 3 (@locked(rank: N)) will slot in here too, adding
# rank-based validation before the SCC step.
module LockHelper
    extend T::Sig

  class LockEdge < T::Struct
    const :held, Symbol
    const :acquired, Symbol
    const :site_token, T.nilable(Lexer::Token)
    const :fn_name, String
    const :opted_out, T::Boolean
  end

  class LockHeldCallSite < T::Struct
    const :held, Symbol
    const :callee, String
    const :site_token, Lexer::Token
    const :opted_out, T::Boolean
  end

  class LockClauseSite < T::Struct
    const :node, AST::WithBlock
    const :cap_types, T::Array[Symbol]
  end

  class LockGraph < T::Struct
    const :nodes, T::Set[Symbol]
    const :adj, T::Hash[Symbol, T::Set[Symbol]]
    const :edges, T::Array[LockEdge]
  end

  DirectEdges = T.type_alias { T::Hash[String, T::Array[LockEdge]] }
  DirectAcquires = T.type_alias { T::Hash[String, T::Set[Symbol]] }
  HeldCallSites = T.type_alias { T::Hash[String, T::Array[LockHeldCallSite]] }
  TransitiveAcquires = T.type_alias { T::Hash[String, T::Set[Symbol]] }

  # Called once from SemanticAnnotator#initialize.
  sig { returns(DirectEdges) }
  def init_lock_analysis!
    T.bind(self, SemanticAnnotator) rescue nil
    @lock_direct_edges    = T.let(Hash.new { |h, k| h[k] = [] }, T.nilable(DirectEdges))
    @lock_direct_acquires = T.let(Hash.new { |h, k| h[k] = Set.new }, T.nilable(DirectAcquires))
    @lock_held_calls      = T.let(Hash.new { |h, k| h[k] = [] }, T.nilable(HeldCallSites))
    # WITH-with-clause sites are post-pass verified for reachable-handler
    # correctness: ON :X where :X cannot actually fire is a dead handler.
    @lock_clause_sites    = T.let([], T.nilable(T::Array[LockClauseSite]))
    # Phase 3: per-type lock rank. First declaration of a type with
    # @locked(rank: N) / @writeLocked(rank: N) establishes the rank;
    # every subsequent declaration of that type must agree.
    @lock_type_ranks      = T.let({}, T.nilable(T::Hash[Symbol, Integer]))
    @lock_transitive_acquires = T.let({}, T.nilable(TransitiveAcquires))
    T.must(@lock_direct_edges)
  end

  # First declaration of T with a rank wins; subsequent mismatches error.
  sig { params(type_sym: Symbol, rank: Integer, node: AST::CapabilityWrap).returns(T.nilable(Integer)) }
  def record_lock_type_rank!(type_sym, rank, node)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless type_sym && rank
    lock_type_ranks = T.must(@lock_type_ranks)
    existing = lock_type_ranks[type_sym]
    if existing.nil?
      lock_type_ranks[type_sym] = rank
    elsif existing != rank
      error!(node, :LOCK_RANK_INCONSISTENT, type: type_sym, previous: existing, rank: rank)
    end
  end

  # For the Phase 3 ordering check: return the rank of a WITH capability's
  # lock type, or nil if the type has no rank declared anywhere.
  sig { params(cap: AST::Capability).returns(T.nilable(Integer)) }
  def rank_of_cap(cap)
    T.bind(self, SemanticAnnotator) rescue nil
    t = lock_identity_of(cap)
    return nil unless t
    T.must(@lock_type_ranks)[t]
  end

  sig { params(node: AST::WithBlock, expanded_capabilities: T::Array[AST::Capability]).void }
  def record_lock_clause_site!(node, expanded_capabilities)
    T.bind(self, SemanticAnnotator) rescue nil
    return unless node.lock_error_clause
    fallible = expanded_capabilities.select { |c|
      c[:capability] == :EXCLUSIVE || c[:capability] == :write_locked_read
    }
    cap_types = fallible.filter_map { |c| lock_identity_of(c) }
    T.must(@lock_clause_sites) << LockClauseSite.new(node: node, cap_types: cap_types)
    nil
  end

  # ---- Phase 1 — lexical same-name nested-WITH check ------------------

  # Reject a nested WITH that re-acquires a fallible lock on a variable
  # already held by an enclosing WITH in the same function. Lexical,
  # same-name; does not chase aliases or cross function boundaries (Phase
  # 2 handles cross-function type-level cycles). Opt-outs downgrade to a
  # [Note].
  sig { params(node: AST::WithBlock, expanded_capabilities: T::Array[AST::Capability]).returns(T.nilable(T::Array[AST::Capability])) }
  def check_nested_lock_reacquire!(node, expanded_capabilities)
    T.bind(self, SemanticAnnotator) rescue nil
    @held_locks = T.let(@held_locks, T.nilable(SemanticAnnotator::HeldLockMap))
    held_locks = @held_locks
    return unless held_locks
    expanded_capabilities.each do |cap|
      next unless cap[:capability] == :EXCLUSIVE || cap[:capability] == :write_locked_read
      vn = cap_var_name(cap[:var_node])
      next unless held_locks.key?(vn)
      outer_tok = T.must(held_locks[vn]).token
      escape    = node.deadlock_escape
      if escape && escape[:kind] == :deadlock
        note!(cap[:var_node], "POSSIBLE_DEADLOCK accepted: '#{vn}' already held by an enclosing WITH " \
                              "(outer line #{outer_tok&.line}). Reviewer: verify this cannot actually self-acquire " \
                              "at runtime (distinct instances, sorted acquire, etc.).")
      else
        error!(cap[:var_node], :LOCK_NESTED_REACQUIRE, name: vn, outer_line: outer_tok&.line)
      end
    end
  end

  # ---- Phase 3 — rank-based DAG enforcement ---------------------------

  # Reject a WITH whose fallible acquire's rank is not strictly greater
  # than every currently-held ranked lock. Only runs between pairs of
  # ranked types — unranked types are ignored (Phase 2's graph-based
  # cycle detection covers those). POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE
  # on the inner WITH downgrades the error to a [Note] so the risk is
  # visible but not blocking.
  sig { params(node: AST::WithBlock, expanded_capabilities: T::Array[AST::Capability]).returns(T.nilable(T::Array[AST::Capability])) }
  def check_lock_rank_ordering!(node, expanded_capabilities)
    T.bind(self, SemanticAnnotator) rescue nil
    @held_lock_types = T.let(@held_lock_types, T.nilable(T::Array[SemanticAnnotator::HeldLockTypeEntry]))
    held_lock_types = @held_lock_types
    return unless held_lock_types && !held_lock_types.empty?
    lock_type_ranks = @lock_type_ranks
    return unless lock_type_ranks && !lock_type_ranks.empty?
    escape = node.deadlock_escape
    expanded_capabilities.each do |cap|
      next unless cap[:capability] == :EXCLUSIVE || cap[:capability] == :write_locked_read
      cap_rank = rank_of_cap(cap)
      next unless cap_rank
      held_lock_types.each do |entry|
        held_rank = lock_type_ranks[entry.type]
        next unless held_rank
        next if cap_rank > held_rank
        if escape
          msg = "Lock rank violation: acquiring ':#{lock_identity_of(cap)}' at rank #{cap_rank} while " \
                "':#{entry.type}' (rank #{held_rank}) is held. Ranks must be strictly ascending along " \
                "the acquire path to prove LockCycle freedom by construction."
          note!(cap[:var_node], msg + " (POSSIBLE_#{escape[:kind].to_s.upcase} accepted.)")
        else
          error!(cap[:var_node], :LOCK_RANK_VIOLATION,
            cap: lock_identity_of(cap), cap_rank: cap_rank,
            held: entry.type, held_rank: held_rank)
        end
      end
    end
  end

  # ---- Phase 2 — type-level lock-cycle detection ----------------------

  # Extract the lock-identity symbol for a WITH capability. Returns the
  # inner type's base symbol (:Counter for Locked(Counter) or
  # @shared:locked Counter), or nil if we can't determine it.
  sig { params(cap: AST::Capability).returns(T.nilable(Symbol)) }
  def lock_identity_of(cap)
    T.bind(self, SemanticAnnotator) rescue nil
    ti = cap[:resolved_type]
    return nil unless ti
    return nil unless ti.respond_to?(:base_type)
    ti.base_type
  end

  # held_stack is an Array of { type:, opted_out: } entries. An edge is
  # opted_out if EITHER the current WITH (the acquirer) is opted out, OR
  # the outer held scope that emitted the edge was opted out. This lets
  # the programmer put the opt-out at the site that reads most naturally
  # — the outer holder, the inner acquire, or both — and each form has
  # the same suppression effect on the cycle graph.
  sig { params(fn_name: String, cap: AST::Capability, held_stack: T::Array[SemanticAnnotator::HeldLockTypeEntry], escape: T.nilable(SemanticAnnotator::DeadlockEscape)).void }
  def record_with_acquire!(fn_name, cap, held_stack, escape)
    T.bind(self, SemanticAnnotator) rescue {}
    t = lock_identity_of(cap)
    return unless t
    T.must(T.must(@lock_direct_acquires)[fn_name]) << t
    site_tok = cap[:var_node].token
    acquirer_opt = !escape.nil?
    held_stack.each do |held|
      T.must(T.must(@lock_direct_edges)[fn_name]) << LockEdge.new(
        held: held.type, acquired: t,
        site_token: site_tok, fn_name: fn_name,
        opted_out: acquirer_opt || held.opted_out,
      )
    end
  end

  sig { params(fn_name: String, callee_name: String, held_stack: T::Array[SemanticAnnotator::HeldLockTypeEntry], site_token: Lexer::Token).void }
  def record_held_call!(fn_name, callee_name, held_stack, site_token)
    T.bind(self, SemanticAnnotator) rescue nil
    held_stack.each do |held|
      T.must(T.must(@lock_held_calls)[fn_name]) << LockHeldCallSite.new(
        held: held.type,
        callee: callee_name,
        site_token: site_token,
        opted_out: held.opted_out
      )
    end
  end

  # Fixed-point propagate direct_acquires through function_call_graph so every
  # fn's "transitive acquires" set contains every lock type it or any
  # transitive callee takes. Mirrors compute_needs_rt! / compute_can_fail!
  # structure.
  sig { returns(T::Hash[String, T::Set[Symbol]]) }
  def propagate_lock_acquires!
    T.bind(self, SemanticAnnotator) rescue nil
    transitive = T.let({}, TransitiveAcquires)
    T.must(@lock_direct_acquires).each { |fn, set| transitive[fn] = set.dup }
    function_call_graph.each_key { |fn| transitive[fn] ||= Set.new }

    loop do
      changed = T.let(false, T::Boolean)
      function_call_graph.each do |fn, callees|
        callees.each do |callee|
          next unless transitive[callee]
          T.must(transitive[callee]).each do |t|
            fn_set = T.must(transitive[fn])
            next if fn_set.include?(t)
            fn_set << t
            changed = true
          end
        end
      end
      break unless changed
    end

    @lock_transitive_acquires = transitive
    transitive
  end

  sig { void }
  def resolve_held_calls!
    T.bind(self, SemanticAnnotator) rescue nil
    T.must(@lock_held_calls).each do |fn, sites|
      sites.each do |site|
        (T.must(@lock_transitive_acquires)[site.callee] || Set.new).each do |t|
          T.must(T.must(@lock_direct_edges)[fn]) << LockEdge.new(
            held: site.held, acquired: t,
            site_token: site.site_token, fn_name: fn,
            opted_out: site.opted_out,
          )
        end
      end
    end
    nil
  end

  # Build the global graph. When include_opted_out is false, excludes
  # opt-out edges — used for cycle-error reporting (non-opted cycles
  # are bugs). When true, includes every edge — used for handler
  # reachability analysis (opt-out edges are paths that CAN fire at
  # runtime, so ON :LockCycle handlers reaching them are live).
  sig { params(include_opted_out: T::Boolean).returns(LockGraph) }
  def build_lock_graph(include_opted_out: false)
    T.bind(self, SemanticAnnotator) rescue nil
    adj = T.let(Hash.new { |h, k| h[k] = Set.new }, T::Hash[Symbol, T::Set[Symbol]])
    nodes = T.let(Set.new, T::Set[Symbol])
    live = T.let([], T::Array[LockEdge])
    T.must(@lock_direct_edges).each do |_fn, edges|
      edges.each do |e|
        next if e.opted_out && !include_opted_out
        T.must(adj[e.held]) << e.acquired
        nodes << e.held
        nodes << e.acquired
        live << e
      end
    end
    LockGraph.new(nodes: nodes, adj: adj, edges: live)
  end

  # Iterative Tarjan SCC. Returns array of SCCs (each an array of nodes).
  sig { params(nodes: T::Set[Symbol], adj: T::Hash[Symbol, T::Set[Symbol]]).returns(T::Array[T::Array[Symbol]]) }
  def tarjan_scc(nodes, adj)
    T.bind(self, SemanticAnnotator) rescue nil
    index = {}
    lowlink = {}
    on_stack = {}
    stack = []
    sccs = []
    next_index = 0
    w = T.let(nil, T.untyped)

    nodes.each do |root|
      next if index.key?(root)
      work = [[root, adj[root].to_a.dup, :enter]]
      until work.empty?
        v, neighbors, phase = work.last
        case phase
        when :enter
          index[v] = next_index
          lowlink[v] = next_index
          next_index += 1
          stack.push(v)
          on_stack[v] = true
          work[-1][2] = :resume
        when :resume
          if neighbors.any?
            w = T.must(neighbors.shift)
            if !index.key?(w)
              work.push([w, T.must(adj[w]).to_a.dup, :enter])
            elsif on_stack[w]
              lowlink[v] = [lowlink[v], index[w]].min
            end
          else
            if lowlink[v] == index[v]
              component = []
              loop do
                w = stack.pop
                on_stack[w] = false
                component << w
                break if w == v
              end
              sccs << component
            end
            work.pop
            lowlink[work.last[0]] = [lowlink[work.last[0]], lowlink[v]].min unless work.empty?
          end
        end
      end
    end
    sccs
  end

  # Called as a post-pass once function_call_graph is complete.
  sig { void }
  def check_lock_cycles!
    T.bind(self, SemanticAnnotator) rescue nil
    propagate_lock_acquires!
    resolve_held_calls!

    non_opted = build_lock_graph(include_opted_out: false)
    tarjan_scc(non_opted.nodes, non_opted.adj).each do |scc|
      next unless scc_is_cyclic?(scc, non_opted.adj)
      report_lock_cycle!(scc, non_opted.edges)
    end

    # Handler reachability: a dead ON :X handler is a compile error so
    # the programmer's intent stays honest with the code. Uses the FULL
    # graph (including opt-outs) because opt-out edges are exactly the
    # runtime paths where :LockCycle / :Deadlock can actually fire.
    check_lock_handler_reachability!
    nil
  end

  sig { void }
  def check_lock_handler_reachability!
    T.bind(self, SemanticAnnotator) rescue nil
    return if @lock_clause_sites.nil? || @lock_clause_sites.empty?

    full = build_lock_graph(include_opted_out: true)
    types_in_cycle     = Set.new
    types_with_self    = Set.new
    tarjan_scc(full.nodes, full.adj).each do |scc|
      if scc.length >= 2
        scc.each { |t| types_in_cycle << t }
      else
        node = T.must(scc.first)
        if T.must(full.adj[node]).include?(node)
          types_in_cycle << node
          types_with_self << node
        end
      end
    end

    @lock_clause_sites.each do |site|
      verify_handler_reachability!(site, types_in_cycle, types_with_self)
    end
    nil
  end

  # The per-WITH narrowed possibility set:
  #   - :LockTimeout    always (any fallible acquire can time out)
  #   - :LockCycle      iff any of the WITH's cap types is in a graph cycle
  #   - :Deadlock       iff any of the WITH's cap types has a graph self-loop
  # Each selector in the clause must expand to at least one type in this
  # set. A selector that expands to the empty set here is dead code.
  sig { params(site: LockClauseSite, types_in_cycle: T::Set[Symbol], types_with_self: T::Set[Symbol]).void }
  def verify_handler_reachability!(site, types_in_cycle, types_with_self)
    T.bind(self, SemanticAnnotator) rescue nil
    node    = site.node
    clause  = node.lock_error_clause
    return unless clause

    # MVCC L5 + True-Sync-Polymorphism (#324 / #330):
    # SNAPSHOT-transaction blocks have a per-cell-family possibility
    # set:
    #   @versioned       -> {MvccConflict}    (Versioned.update bounded retry)
    #   @indirect:atomic -> {AtomicConflict}  (AtomicPtr.update bounded retry)
    # LockTimeout / LockCycle / Deadlock never apply because the
    # lock-free CAS paths don't acquire a mutex. The cell-family
    # check mirrors the dispatch in
    # SemanticAnnotator#validate_lock_error_clause!.
    if node.snapshot_mode == :transaction
      has_atomic_ptr = (node.capabilities || []).any? { |c|
        next false unless c[:capability] == :SNAPSHOT
        sym = c[:var_node]&.respond_to?(:symbol) ? c[:var_node].symbol : nil
        sym && sym.atomic? && sym.respond_to?(:layout) && sym.indirect?
      }
      possible = Set.new([has_atomic_ptr ? :AtomicConflict : :MvccConflict])
    else
      possible = Set.new
      possible << :LockTimeout if site.cap_types.any?
      site.cap_types.each do |t|
        possible << :LockCycle if types_in_cycle.include?(t)
        possible << :Deadlock  if types_with_self.include?(t)
      end
    end
    possible << :GuardFail if (node.capabilities || []).any? { |c| c[:guard_expr] }

    clause.selectors.each do |sel|
      expansion = case sel.form
                  when :kind then AST.types_for_kind(sel.name).to_set
                  when :type then Set.new([sel.name])
                  else Set.new
                  end
      reachable = expansion & possible
      next unless reachable.empty?

      label = sel.name.to_s
      error!(sel.token || node, :SELECTOR_NOT_POSSIBLE, label: label)
    end
    nil
  end

  sig { params(scc: T::Array[Symbol], adj: T::Hash[Symbol, T::Set[Symbol]]).returns(T::Boolean) }
  def scc_is_cyclic?(scc, adj)
    T.bind(self, SemanticAnnotator) rescue nil
    return true if scc.length > 1
    node = T.must(scc.first)
    T.must(adj[node]).include?(node)
  end

  sig { params(scc: T::Array[Symbol], edges: T::Array[LockEdge]).returns(T.noreturn) }
  def report_lock_cycle!(scc, edges)
    T.bind(self, SemanticAnnotator) rescue nil
    scc_set = scc.to_set
    participating = edges.select { |e| scc_set.include?(e.held) && scc_set.include?(e.acquired) }
    sample = participating.first
    site_lines = participating.map { |e|
      line = e.site_token&.line || "?"
      "  - #{e.fn_name} (line #{line}): holds :#{e.held}, acquires :#{e.acquired}"
    }.uniq.join("\n")

    types_str = scc.map { |t| ":#{t}" }.join(", ")
    kind = scc.length == 1 ? "self-loop (same-type nested acquire)" : "lock cycle (graph SCC)"
    msg = "Potential #{kind} over [#{types_str}]. " \
          "Sites contributing to the cycle:\n#{site_lines}\n" \
          "Fix: acquire in a consistent order everywhere, or mark individual sites " \
          "POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE if the ordering is programmer-enforced."
    anchor = sample&.site_token
    error!(anchor || semantic_program, :LOCK_CYCLE_DETECTED, message: msg)
  end
end
