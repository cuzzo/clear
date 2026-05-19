# typed: false
# EscapeGraph — the single value-flow escape analysis (Stage B).
#
# Replaces the 5 fragmented proxies. ONE question per declaration D:
# does D's value reach a SINK (outlive its declaring frame)? Shapes are
# EDGES, not branches. See docs/agents/escape-graph-spec.md.
#
# Stage B status: STANDALONE + READ-ONLY. Nothing in production reads
# `decide`. It exists only for the characterization harness (diff vs the
# old 5-proxy pipeline). Wired atomically in Stage C, never before.
#
#   storage(D) = :heap  iff  escapes?(D) ∧ heap_source?(D)
#     escapes?(D)     = D reaches a SINK in the value-flow graph
#                       (intra fixpoint + interprocedural RET fixpoint)
#     heap_source?(D) = D's value is a heap-needing origin (collection/
#                       string/map builder, requires_move?, heap-ret call,
#                       declared owned-heap contract); excludes rodata.
require "set"

module EscapeGraph
  module_function

  # @param fn_nodes [Hash{String=>AST::FunctionDef}]
  # @return [Hash{String=>Hash{String=>Symbol}}] fn => { decl_name => :heap|:frame }
  def decide(fn_nodes)
    callees = build_call_graph(fn_nodes)
    ret_heap = compute_ret_heap_fixpoint(fn_nodes, callees)
    out = {}
    fn_nodes.each do |name, fn|
      next unless fn&.body
      out[name] = decide_fn(fn, ret_heap)
    end
    out
  end

  # ---- interprocedural: RET[fn] heap fixpoint (replaces E1) ----

  def build_call_graph(fn_nodes)
    g = Hash.new { |h, k| h[k] = Set.new }
    fn_nodes.each do |name, fn|
      next unless fn&.body
      walk(fn.body) do |n|
        case n
        when AST::FuncCall   then g[name] << n.name.to_s unless n.respond_to?(:fn_var_call) && n.fn_var_call
        when AST::MethodCall then g[name] << n.name.to_s
        end
      end
    end
    g
  end

  def compute_ret_heap_fixpoint(fn_nodes, _callees)
    ret = {}
    fn_nodes.each_key { |n| ret[n] = false }
    changed = true
    iters = 0
    while changed && iters < 200
      changed = false
      iters += 1
      fn_nodes.each do |name, fn|
        next if ret[name] || !fn&.body
        next if borrow_return?(fn)            # borrow carve-out: caller doesn't own
        rvals = return_values(fn.body)
        next if rvals.empty?
        if rvals.any? { |rv| expr_is_heap_source?(rv, fn, ret) }
          ret[name] = true
          changed = true
        end
      end
    end
    ret
  end

  # ---- per-function decision ----

  def decide_fn(fn, ret_heap)
    decls = {}                       # name => decl node
    walk(fn.body) do |n|
      if n.is_a?(AST::VarDecl) || (n.is_a?(AST::BindExpr) && decl_mode?(n))
        decls[n.name.to_s] = n
      end
    end

    # Seed ESC: decls whose value reaches a SINK directly.
    esc = Set.new
    each_sink_expr(fn) { |sink_expr| referenced_decls(sink_expr).each { |d| esc << d } }

    # Propagate: edge b ──▶ a (a's init/assign references b); a∈ESC ⇒ b∈ESC.
    # Build reverse: for each decl a, the decls its initializer references.
    init_refs = {}
    decls.each { |dn, dnode| init_refs[dn] = referenced_decls(dnode.value) }
    walk(fn.body) do |n|                       # assignments feed the decl too
      next unless n.is_a?(AST::Assignment) || (n.is_a?(AST::BindExpr) && !decl_mode?(n))
      root = root_ident_name(n.name)
      next unless root && decls.key?(root)
      (init_refs[root] ||= []).concat(referenced_decls(n.value))
    end
    changed = true
    while changed
      changed = false
      esc.to_a.each do |a|
        (init_refs[a] || []).each { |b| (changed = true; esc << b) unless esc.include?(b) }
      end
    end

    result = {}
    decls.each do |dn, dnode|
      heap = inherently_heap?(dnode) ||
             (esc.include?(dn) && heap_source?(dnode, fn, ret_heap))
      result[dn] = heap ? :heap : :frame
    end
    result
  end

  # ---- SINKS (spec §SINKS) ----

  def each_sink_expr(fn)
    # S-return (borrow carve-out applied at fn level)
    unless borrow_return?(fn)
      return_values(fn.body).each { |rv| yield rv }
    end
    walk(fn.body) do |n|
      case n
      when AST::Assignment
        # S-heapfield: store into a heap-storage field/container
        root = root_ident_name(n.name)
        if n.name.is_a?(AST::GetField) || n.name.is_a?(AST::GetIndex)
          yield n.value if heap_root_storage?(n.name)
        end
      when AST::MethodCall
        # S-heapmut-arg: arg into a heap-container mutator (.append/.put/...)
        if mutator?(n.name) && heap_receiver?(n.object)
          n.args.each { |a| yield a }
        end
      when AST::FuncCall, AST::MethodCall
        # S-takes / S-mutlist handled via callee param flags
        cargs = n.is_a?(AST::MethodCall) ? n.args : n.args
        cargs.each_with_index do |a, _i|
          yield a if arg_is_takes_or_mutlist_sink?(n, a)
        end
      when AST::BgBlock, AST::BgStreamBlock
        # S-bgcapture: every identifier the BG body references that is a
        # local decl is captured.
        walk([n.respond_to?(:body) ? n.body : nil].compact) do |m|
          yield m if m.is_a?(AST::Identifier)
        end
      end
    end
  end

  # ---- value-flow: which decl names does this expr reach (EDGES) ----

  def referenced_decls(expr, acc = [])
    return acc if expr.nil?
    e = unwrap(expr)
    case e
    when AST::Identifier
      acc << e.name.to_s
    when AST::StructLit, AST::UnionVariantLit
      flds = e.fields
      if flds.respond_to?(:each)
        flds.each { |k, v| referenced_decls(v.nil? ? k : v, acc) }
      end
    when AST::BinaryOp
      if e.op == :OR_RESCUE
        referenced_decls(e.left, acc)         # E-orresc: success value
      else
        referenced_decls(e.left, acc); referenced_decls(e.right, acc)
      end
    when AST::FuncCall
      e.args.each { |a| referenced_decls(a, acc) }
    when AST::MethodCall
      referenced_decls(e.object, acc); e.args.each { |a| referenced_decls(a, acc) }
    end
    acc
  end

  # Unwrap GIVE/COPY/clone/freeze/share wrappers (E-wrap).
  def unwrap(e)
    while e.respond_to?(:value) &&
          (e.is_a?(AST::MoveNode) || e.is_a?(AST::CopyNode) ||
           (defined?(AST::CloneNode)  && e.is_a?(AST::CloneNode)) ||
           (defined?(AST::FreezeNode) && e.is_a?(AST::FreezeNode)) ||
           (defined?(AST::ShareNode)  && e.is_a?(AST::ShareNode)))
      e = e.value
    end
    e
  end

  # ---- SOURCES (spec §SOURCES) ----

  def heap_source?(decl_node, fn, ret_heap)
    ti = type_of(decl_node)
    return true if expr_is_heap_source?(decl_node.value, fn, ret_heap)
    return true if ti && ti_requires_move?(ti)
    false
  end

  def expr_is_heap_source?(expr, _fn, ret_heap)
    e = unwrap(expr)
    case e
    when AST::ListLit, AST::HashLit then true            # list/set/map literal
    when AST::Literal then false                          # scalar/string rodata: NOT a source
    when AST::BinaryOp
      return true if e.op == :ADD && e.respond_to?(:string_concat) && e.string_concat
      return expr_is_heap_source?(e.left, _fn, ret_heap) if e.op == :OR_RESCUE
      false
    when AST::FuncCall
      nm = e.name.to_s
      return true if HEAP_STDLIB.include?(nm)
      ret_heap[nm] == true
    when AST::MethodCall
      ALLOC_METHODS.include?(e.name.to_s)
    when AST::Identifier
      t = e.respond_to?(:type_info) ? e.type_info : nil
      t = t.is_a?(Type) ? t : (Type.new(t) rescue nil) if t
      !!(t && ti_requires_move?(t))
    else
      false
    end
  end

  HEAP_STDLIB   = %w[makeList concat substr intToString charAtCodepoint join split].freeze
  ALLOC_METHODS = %w[append split concat substr push insert put].freeze

  # ---- helpers ----

  def return_values(body)
    vs = []
    walk(body) { |n| vs << n.value if n.is_a?(AST::ReturnNode) && n.value }
    vs
  end

  def borrow_return?(fn)
    return true if fn.respond_to?(:return_lifetime) && fn.return_lifetime
    rt = fn.return_type
    rt = Type.new(rt) if rt && !rt.is_a?(Type)
    rt.is_a?(Type) && rt.respond_to?(:borrow_provenance?) && rt.borrow_provenance?
  rescue StandardError
    false
  end

  def decl_mode?(n)
    return true unless n.respond_to?(:mode)
    n.mode == :decl
  end

  def root_ident_name(lhs)
    n = lhs
    n = n.target while n.respond_to?(:target) && (n.is_a?(AST::GetField) || n.is_a?(AST::GetIndex))
    return n.name.to_s if n.is_a?(AST::Identifier)
    return n.name.to_s if n.respond_to?(:name) && n.name.is_a?(String)
    nil
  end

  def type_of(node)
    t = node.respond_to?(:type_info) ? node.type_info : nil
    t ||= node.respond_to?(:full_type) ? node.full_type : nil
    t.is_a?(Type) ? t : (t ? (Type.new(t) rescue nil) : nil)
  end

  # Inherently heap-backed types: map / set / pool are a heap hashtable
  # regardless of escape (only @list and String are frame-vs-heap by
  # escape). Spec refinement surfaced by the characterization gate
  # (14_hashmap `counts` map: local, never escapes, yet MUST be heap).
  def inherently_heap?(decl_node)
    ti = type_of(decl_node)
    return false unless ti.is_a?(Type)
    (ti.respond_to?(:map?) && ti.map?) ||
      (ti.respond_to?(:set_collection?) && ti.set_collection?) ||
      (ti.respond_to?(:pool?) && ti.pool?)
  rescue StandardError
    false
  end

  def ti_requires_move?(ti)
    ti.respond_to?(:requires_move?) && ti.requires_move?
  rescue StandardError
    false
  end

  def heap_root_storage?(lhs)
    root = lhs
    root = root.target while root.respond_to?(:target) && (root.is_a?(AST::GetField) || root.is_a?(AST::GetIndex))
    sym = root.respond_to?(:symbol) ? root.symbol : nil
    sym && [:heap, :multiowned, :shared].include?(sym.storage)
  rescue StandardError
    false
  end

  def heap_receiver?(obj)
    sym = obj.respond_to?(:symbol) ? obj.symbol : nil
    sym && [:heap, :multiowned, :shared].include?(sym.storage)
  rescue StandardError
    false
  end

  def mutator?(name)
    %w[append put insert push set add remove delete].include?(name.to_s)
  end

  def arg_is_takes_or_mutlist_sink?(_call, _arg)
    # Conservative first cut: callee-param TAKES/mutable-@list resolution
    # needs the resolved callee signature; characterization will show
    # whether the simpler S-return/S-heapfield coverage already supersets.
    false
  end

  # ---- Stage B characterization (READ-ONLY) ----
  # Diff EscapeGraph vs the OLD 5-proxy stamps already on the decl nodes.
  # Appends one line per DIVERGE to `path`. Never mutates anything.
  # Gate (spec): on the green corpus EscapeGraph must be a SUPERSET
  # (never :frame where old=:heap) -> only OLD_HEAP_NEW_FRAME lines are
  # disqualifying; NEW_HEAP_OLD_FRAME is expected on the 20 manifest
  # cells (the fix) and benign elsewhere (more heap = safe).
  def characterize!(fn_nodes, path)
    decisions = decide(fn_nodes)
    File.open(path, "a") do |f|
      fn_nodes.each do |name, fn|
        next unless fn&.body
        nd = decisions[name] || {}
        walk(fn.body) do |n|
          next unless n.is_a?(AST::VarDecl) || (n.is_a?(AST::BindExpr) && decl_mode?(n))
          dn = n.name.to_s
          old_heap = old_decision_heap?(n)
          new_heap = nd[dn] == :heap
          next if old_heap == new_heap
          tag = (old_heap && !new_heap) ? "OLD_HEAP_NEW_FRAME(DISQUALIFYING)" : "NEW_HEAP_OLD_FRAME"
          f.puts "#{tag}\t#{name}::#{dn}"
        end
      end
    end
  rescue StandardError => e
    File.open(path, "a") { |f| f.puts "HARNESS_ERROR\t#{e.class}: #{e.message}" }
  end

  def old_decision_heap?(node)
    return true if node.respond_to?(:storage) && node.storage == :heap
    ti = node.respond_to?(:full_type) ? node.full_type : nil
    ti ||= node.respond_to?(:type_info) ? node.type_info : nil
    !!(ti.is_a?(Type) && ti.respond_to?(:heap_provenance?) && ti.heap_provenance?)
  rescue StandardError
    false
  end

  def walk(node, &blk)
    case node
    when nil
    when Array then node.each { |x| walk(x, &blk) }
    when AST::FunctionDef then nil  # don't descend nested fns
    else
      blk.call(node) if node.respond_to?(:token)
      if node.respond_to?(:each_pair)
        node.each_pair { |_, v| walk(v, &blk) }
      elsif node.is_a?(Struct)
        node.to_a.each { |v| walk(v, &blk) }
      end
    end
  end
end
