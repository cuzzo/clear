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
#       1. Fixed-point propagate acquires through @call_graph.
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
  LockEdge = Struct.new(:held, :acquired, :site_token, :fn_name, :opted_out, keyword_init: true)

  # Called once from SemanticAnnotator#initialize.
  def init_lock_analysis!
    @lock_direct_edges    ||= Hash.new { |h, k| h[k] = [] }
    @lock_direct_acquires ||= Hash.new { |h, k| h[k] = Set.new }
    @lock_held_calls      ||= Hash.new { |h, k| h[k] = [] }
    # WITH-with-clause sites are post-pass verified for reachable-handler
    # correctness: ON :X where :X cannot actually fire is a dead handler.
    @lock_clause_sites    ||= []
  end

  def record_lock_clause_site!(node, expanded_capabilities)
    return unless node.lock_error_clause
    fallible = expanded_capabilities.select { |c|
      c[:capability] == :EXCLUSIVE || c[:capability] == :write_locked_read
    }
    cap_types = fallible.filter_map { |c| lock_identity_of(c) }
    @lock_clause_sites << { node: node, cap_types: cap_types }
  end

  # ---- Phase 1 — lexical same-name nested-WITH check ------------------

  # Reject a nested WITH that re-acquires a fallible lock on a variable
  # already held by an enclosing WITH in the same function. Lexical,
  # same-name; does not chase aliases or cross function boundaries (Phase
  # 2 handles cross-function type-level cycles). Opt-outs downgrade to a
  # [Note].
  def check_nested_lock_reacquire!(node, expanded_capabilities)
    return unless @held_locks
    expanded_capabilities.each do |cap|
      next unless cap[:capability] == :EXCLUSIVE || cap[:capability] == :write_locked_read
      vn = cap_var_name(cap[:var_node])
      next unless @held_locks.key?(vn)
      outer_tok = @held_locks[vn][:token]
      escape    = node.deadlock_escape
      if escape && escape[:kind] == :deadlock
        note!(cap[:var_node], "POSSIBLE_DEADLOCK accepted: '#{vn}' already held by an enclosing WITH " \
                              "(outer line #{outer_tok&.line}). Reviewer: verify this cannot actually self-acquire " \
                              "at runtime (distinct instances, sorted acquire, etc.).")
      else
        error!(cap[:var_node],
               "Nested lock re-acquire: '#{vn}' is already held by an enclosing WITH " \
               "(outer line #{outer_tok&.line}). This is a structural self-deadlock. " \
               "If you know the instances are distinct and ordered, mark the inner WITH as " \
               "POSSIBLE_DEADLOCK.")
      end
    end
  end

  # ---- Phase 2 — type-level lock-cycle detection ----------------------

  # Extract the lock-identity symbol for a WITH capability. Returns the
  # inner type's base symbol (:Counter for Locked(Counter) or
  # @shared:locked Counter), or nil if we can't determine it.
  def lock_identity_of(cap)
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
  def record_with_acquire!(fn_name, cap, held_stack, escape)
    t = lock_identity_of(cap)
    return unless t
    @lock_direct_acquires[fn_name] << t
    site_tok = cap[:var_node].respond_to?(:token) ? cap[:var_node].token : nil
    acquirer_opt = !escape.nil?
    held_stack.each do |held|
      @lock_direct_edges[fn_name] << LockEdge.new(
        held: held[:type], acquired: t,
        site_token: site_tok, fn_name: fn_name,
        opted_out: acquirer_opt || held[:opted_out],
      )
    end
  end

  def record_held_call!(fn_name, callee_name, held_stack, site_token)
    held_stack.each do |held|
      @lock_held_calls[fn_name] << {
        held: held[:type], callee: callee_name, site_token: site_token,
        opted_out: held[:opted_out],
      }
    end
  end

  # Fixed-point propagate direct_acquires through @call_graph so every
  # fn's "transitive acquires" set contains every lock type it or any
  # transitive callee takes. Mirrors compute_needs_rt! / compute_can_fail!
  # structure.
  def propagate_lock_acquires!
    transitive = {}
    @lock_direct_acquires.each { |fn, set| transitive[fn] = set.dup }
    @call_graph.each_key { |fn| transitive[fn] ||= Set.new }

    loop do
      changed = false
      @call_graph.each do |fn, callees|
        callees.each do |callee|
          next unless transitive[callee]
          transitive[callee].each do |t|
            next if transitive[fn].include?(t)
            transitive[fn] << t
            changed = true
          end
        end
      end
      break unless changed
    end

    @lock_transitive_acquires = transitive
  end

  def resolve_held_calls!
    @lock_held_calls.each do |fn, sites|
      sites.each do |site|
        (@lock_transitive_acquires[site[:callee]] || Set.new).each do |t|
          @lock_direct_edges[fn] << LockEdge.new(
            held: site[:held], acquired: t,
            site_token: site[:site_token], fn_name: fn,
            opted_out: site[:opted_out] ? true : false,
          )
        end
      end
    end
  end

  # Build the global graph. When include_opted_out is false, excludes
  # opt-out edges — used for cycle-error reporting (non-opted cycles
  # are bugs). When true, includes every edge — used for handler
  # reachability analysis (opt-out edges are paths that CAN fire at
  # runtime, so ON :LockCycle handlers reaching them are live).
  def build_lock_graph(include_opted_out: false)
    adj = Hash.new { |h, k| h[k] = Set.new }
    nodes = Set.new
    live = []
    @lock_direct_edges.each do |_fn, edges|
      edges.each do |e|
        next if e.opted_out && !include_opted_out
        adj[e.held] << e.acquired
        nodes << e.held
        nodes << e.acquired
        live << e
      end
    end
    { nodes: nodes, adj: adj, edges: live }
  end

  # Iterative Tarjan SCC. Returns array of SCCs (each an array of nodes).
  def tarjan_scc(nodes, adj)
    index = {}
    lowlink = {}
    on_stack = {}
    stack = []
    sccs = []
    next_index = 0

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
            w = neighbors.shift
            if !index.key?(w)
              work.push([w, adj[w].to_a.dup, :enter])
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

  # Called as a post-pass once @call_graph is complete.
  def check_lock_cycles!
    propagate_lock_acquires!
    resolve_held_calls!

    non_opted = build_lock_graph(include_opted_out: false)
    tarjan_scc(non_opted[:nodes], non_opted[:adj]).each do |scc|
      next unless scc_is_cyclic?(scc, non_opted[:adj])
      report_lock_cycle!(scc, non_opted[:edges])
    end

    # Handler reachability: a dead ON :X handler is a compile error so
    # the programmer's intent stays honest with the code. Uses the FULL
    # graph (including opt-outs) because opt-out edges are exactly the
    # runtime paths where :LockCycle / :Deadlock can actually fire.
    check_lock_handler_reachability!
  end

  def check_lock_handler_reachability!
    return if @lock_clause_sites.nil? || @lock_clause_sites.empty?

    full = build_lock_graph(include_opted_out: true)
    types_in_cycle     = Set.new
    types_with_self    = Set.new
    tarjan_scc(full[:nodes], full[:adj]).each do |scc|
      if scc.length >= 2
        scc.each { |t| types_in_cycle << t }
      else
        node = scc.first
        if full[:adj][node].include?(node)
          types_in_cycle << node
          types_with_self << node
        end
      end
    end

    @lock_clause_sites.each do |site|
      verify_handler_reachability!(site, types_in_cycle, types_with_self)
    end
  end

  # The per-WITH narrowed possibility set:
  #   - :LockTimeout    always (any fallible acquire can time out)
  #   - :LockCycle      iff any of the WITH's cap types is in a graph cycle
  #   - :Deadlock       iff any of the WITH's cap types has a graph self-loop
  # Each selector in the clause must expand to at least one type in this
  # set. A selector that expands to the empty set here is dead code.
  def verify_handler_reachability!(site, types_in_cycle, types_with_self)
    node    = site[:node]
    clause  = node.lock_error_clause
    return unless clause

    possible = Set.new
    possible << :LockTimeout
    site[:cap_types].each do |t|
      possible << :LockCycle if types_in_cycle.include?(t)
      possible << :Deadlock  if types_with_self.include?(t)
    end

    clause[:selectors].each do |sel|
      expansion = case sel[:form]
                  when :kind then AST.types_for_kind(sel[:name]).to_set
                  when :type then Set.new([sel[:name]])
                  else Set.new
                  end
      reachable = expansion & possible
      next unless reachable.empty?

      label = sel[:form] == :type ? ":#{sel[:name]}" : sel[:name].to_s
      error!(sel[:token] || node,
             "You are trying to handle `#{label}` which is not a possible error at " \
             "this WITH. The static lock analysis proved it cannot fire. Remove the " \
             "handler, or mark an upstream lock acquire with POSSIBLE_DEADLOCK / " \
             "POSSIBLE_LOCK_CYCLE if you know a runtime path can reach it.")
    end
  end

  def scc_is_cyclic?(scc, adj)
    return true if scc.length > 1
    node = scc.first
    adj[node].include?(node)
  end

  def report_lock_cycle!(scc, edges)
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
    error!(anchor || @current_fn_node || @program_node, msg)
  end
end
