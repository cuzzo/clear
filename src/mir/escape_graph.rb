# typed: strict
# EscapeGraph -- the single value-flow escape analysis. Replaces the 5
# fragmented escape proxies (compute_heap_return_fns!, analyze!,
# tag_transitive_provenance!, tag_carry_call_sites!, the escape half
# of PromotionClassifier). See docs/agents/escape-graph-spec.md.
#
#   storage(D) = :heap iff inherently_heap?(D) (Arc/Rc/Locked) ∨ escapes?(D)
#
# MIRChecker (7 invariants) is the fail-closed oracle: any escape gap
# surfaces as a located allocator/leak/double-free error, never a
# silent miscompile.
require "set"
require "sorbet-runtime"

module EscapeGraph
  extend T::Sig
  module_function

  FnNodes = T.type_alias { T::Hash[T.untyped, T.untyped] }
  RetHeap = T.type_alias { T::Hash[T.untyped, T::Boolean] }

  sig { params(fn_nodes: FnNodes).returns([T::Set[String], T::Set[String]]) }
  def apply!(fn_nodes)
    # Loop-carry / concat-into-heap promotions must run BEFORE the RET
    # fixpoint so a `RETURN resp` of a loop-promoted heap string is
    # seen as heap-return.
    fn_nodes.each do |_n, fn|
      next unless fn&.body
      loop_carry_names(fn)           # side-effect: promote carry values
      promote_heapmut_concats!(fn)
    end
    ret_heap = compute_ret_heap_fixpoint(fn_nodes)
    heap_decls = T.let(Set.new, T::Set[String])
    fn_nodes.each do |name, fn|
      next unless fn&.body
      stamp_fn!(fn, decide_fn(fn, ret_heap, fn_nodes), name, heap_decls, ret_heap)
    end
    heap_fns = ret_heap.each_with_object(T.let(Set.new, T::Set[String])) { |(n, h), s| s << n.to_s if h }
    [heap_fns, heap_decls]
  end

  sig { params(fn_nodes: FnNodes).returns(RetHeap) }
  def compute_ret_heap_fixpoint(fn_nodes)
    ret = T.let({}, RetHeap)
    # Seed from cross-module return_provenance for imported functions
    # whose body isn't re-analyzed here.
    fn_nodes.each { |n, fn| ret[n] = fn.return_provenance == :heap }
    changed = T.let(true, T::Boolean)
    iters = 0
    while changed && iters < 200
      changed = false
      iters += 1
      fn_nodes.each do |name, fn|
        next if ret[name] || !fn&.body
        next if borrow_return?(fn)            # borrow carve-out: caller doesn't own
        rvals = return_values(fn.body)
        next if rvals.empty?
        if rvals.any? { |rv| return_value_is_heap?(rv, ret) }
          ret[name] = true
          fn.return_provenance = :heap
          changed = true
        end
      end
    end
    ret
  end

  sig { params(rv: T.untyped, ret_heap: RetHeap).returns(T::Boolean) }
  def return_value_is_heap?(rv, ret_heap)
    e = unwrap(rv)
    case e
    when AST::ListLit, AST::HashLit then true
    when AST::Literal               then false      # rodata scalar/string
    when AST::BinaryOp
      return return_value_is_heap?(e.left, ret_heap) if e.op == :OR_RESCUE
      ret_heap_type?(type_of(e)) || node_heap_provenance?(e)
    when AST::FuncCall
      return true if ret_heap[e.name.to_s] == true
      ret_heap_type?(type_of(e)) || node_heap_provenance?(e)
    else
      ret_heap_type?(type_of(e)) || node_heap_provenance?(e)
    end
  end

  # Only counts a returned IDENTIFIER naming a local heap-owned decl
  # the fn itself owns (loop-carry-promoted `resp`). Excludes returned
  # field/match-alias borrows (`w.inner`, `Value.Str AS s`) -- those
  # carry :heap on their type but are not ownership transfers; counting
  # them double-frees the source's field cleanup (174 prStr).
  sig { params(e: T.untyped).returns(T::Boolean) }
  def node_heap_provenance?(e)
    return false unless e.is_a?(AST::Identifier)
    sym = e.symbol
    return false if sym.nil? || sym.is_param || sym.storage != :heap
    # An @atomic-or-sync primitive cell has :heap symbol storage in M1
    # but is LOADED on return, not transferred.
    t = sym.type
    return true unless t.is_a?(Type)
    !(t.primitive? || t.any_sync?)
  end

  sig { params(fn: T.untyped, ret_heap: RetHeap, fn_nodes: FnNodes).returns(T::Hash[String, Symbol]) }
  def decide_fn(fn, ret_heap, fn_nodes = {})
    decls = T.let({}, T::Hash[String, T.untyped])
    walk(fn.body) do |n|
      decls[n.name.to_s] = n if decl?(n)
    end

    esc_strong  = T.let(Set.new, T::Set[String])
    esc_listret = T.let(Set.new, T::Set[String])
    each_sink_expr(fn) { |se| referenced_decls(se).each { |d| esc_strong << d } }
    loop_carry_names(fn).each   { |d| esc_strong << d }
    bg_capture_names(fn).each   { |d| esc_strong << d }
    callarg_escape_names(fn, fn_nodes).each { |d| esc_strong << d }
    if !borrow_return?(fn)
      if heap_ptr_return?(fn)
        return_values(fn.body).each { |rv| referenced_decls(rv).each { |d| esc_strong << d } }
      else
        # Plain return: a directly-returned list is moved out. A list
        # nested in a returned aggregate escapes ONLY if the field-value
        # node keeps its list_collection? type (moved into a @list
        # field); a plain-slice field is deep-copied by the transpiler
        # (dupeValue/blk_copy) so the source stays frame.
        return_values(fn.body).each do |rv|
          direct_return_decls(rv).each       { |d| esc_listret << d }
          aggregate_moved_list_decls(rv).each { |d| esc_listret << d }
        end
      end
    end

    reassigned_heap = T.let(Set.new, T::Set[String])
    init_refs = T.let({}, T::Hash[String, T::Array[String]])
    decls.each do |dn, dnode|
      init_refs[dn] = referenced_decls(dnode.value)
      reassigned_heap << dn if decl_value_is_heap_call?(dnode.value, ret_heap)
    end
    walk(fn.body) do |n|
      next unless n.is_a?(AST::Assignment) || (n.is_a?(AST::BindExpr) && !decl?(n))
      root = root_ident_name(n.name)
      next unless root && decls.key?(root)
      (init_refs[root] ||= []).concat(referenced_decls(n.value))
      reassigned_heap << root if decl_value_is_heap_call?(n.value, ret_heap)
    end
    [esc_strong, esc_listret].each do |esc|
      changed = T.let(true, T::Boolean)
      while changed
        changed = false
        esc.to_a.each do |a|
          (init_refs[a] || []).each { |b| (changed = true; esc << b) unless esc.include?(b) }
        end
      end
    end

    result = T.let({}, T::Hash[String, Symbol])
    decls.each do |dn, dnode|
      ti = type_of(dnode)
      heap =
        if struct_aggregate?(ti)
          # Structs/unions RVO to :stack with per-field cleanup; flat-
          # heap only via inherent (Arc) or a strong sink. NOT via
          # list-return / transitive call (would double-free the RVO'd
          # / dupeUnionValue'd copy -- 174 union_match_struct_fields).
          inherently_heap?(dnode) || esc_strong.include?(dn)
        else
          inherently_heap?(dnode) ||
            esc_strong.include?(dn) ||
            (collection_ti?(ti) && esc_listret.include?(dn)) ||
            reassigned_heap.include?(dn)
        end
      heap = false if heap && cannot_own_heap?(ti)
      result[dn] = heap ? :heap : :frame
    end
    result
  end

  # Type#struct? covers any non-primitive/string/array/map/optional
  # composite, including tagged unions.
  sig { params(ti: T.untyped).returns(T::Boolean) }
  def struct_aggregate?(ti)
    !!(ti.is_a?(Type) && ti.struct? && !ti.any_sync?)
  end

  sig { params(fn: T.untyped).returns(T::Boolean) }
  def heap_ptr_return?(fn)
    rt = fn.return_type
    !!(rt.is_a?(Type) && (rt.indirect? || rt.heap?))
  end

  # Mirrors MIRChecker INV-COPY-CLEANUP: capability-free primitive or
  # Id<T> is a Copy handle and never owns heap.
  sig { params(ti: T.untyped).returns(T::Boolean) }
  def cannot_own_heap?(ti)
    return false unless ti.is_a?(Type)
    no_caps = !ti.any_sync? && !ti.multiowned? && !ti.shared?
    !!(no_caps && (ti.primitive? || (ti.generic_instance? && ti.generic_base == :Id)))
  end

  sig { params(expr: T.untyped, ret_heap: RetHeap).returns(T::Boolean) }
  def decl_value_is_heap_call?(expr, ret_heap)
    e = unwrap(expr)
    case e
    when AST::BinaryOp
      !!(e.op == :OR_RESCUE && decl_value_is_heap_call?(e.left, ret_heap))
    when AST::FuncCall
      ret_heap[e.name.to_s] == true
    else
      false
    end
  end

  sig { params(fn: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def each_sink_expr(fn, &blk)
    walk(fn.body) do |n|
      case n
      when AST::Assignment
        if (n.name.is_a?(AST::GetField) || n.name.is_a?(AST::GetIndex)) &&
           heap_root_storage?(n.name)
          blk.call(n.value)                       # S-heapfield
        end
      end
    end
  end

  # Frame string-concat appended to a collection with composite element
  # type dangles after frame rewind (container cleanup frees the
  # embedded string field). String/primitive element types are excluded
  # because heap-promoting their concats LEAKS on deinit (matches old
  # E2 cond7 element-type gate).
  sig { params(fn: T.untyped).void }
  def promote_heapmut_concats!(fn)
    walk(fn.body) do |node|
      next unless node.is_a?(AST::MethodCall)
      next unless %w[append insert push put].include?(node.name.to_s)
      obj = node.object
      sym = obj.is_a?(AST::Identifier) || obj.is_a?(AST::GetField) ? obj.symbol : nil
      next unless sym
      ti = sym.type
      next unless ti.collection?
      elem_t = ti.element_type
      next unless elem_t && !elem_t.primitive? && !elem_t.string?
      node.args.each { |arg| promote_frame_concats!(arg) }
    end
  end

  sig { params(node: T.untyped).void }
  def promote_frame_concats!(node)
    return unless node # :nocov: defensive (callers internal-recurse + Array.compact upstream)
    case node
    when AST::BinaryOp
      if node.op == :ADD && node.string_concat
        node.storage = :heap
        ti = node.full_type
        ti.provenance = :heap if ti.is_a?(Type)
      end
      promote_frame_concats!(node.left)
      promote_frame_concats!(node.right)
    when AST::StringConcat
      node.storage = :heap
      node.parts&.each { |p| promote_frame_concats!(p) }
    else
      AST.wrapped_children(node).each { |c| promote_frame_concats!(c) }
    end
  end

  sig { params(expr: T.untyped, acc: T::Array[String]).returns(T::Array[String]) }
  def referenced_decls(expr, acc = [])
    return acc if expr.nil?
    e = unwrap(expr)
    case e
    when AST::Identifier
      acc << e.name.to_s
    when AST::StructLit, AST::UnionVariantLit
      e.fields.each { |k, v| referenced_decls(v.nil? ? k : v, acc) }
    when AST::BinaryOp
      # OR_RESCUE aliases the LHS success value. Other binary ops
      # (string concat, arithmetic) produce a fresh value; operands
      # are read by value and don't escape through the result.
      referenced_decls(e.left, acc) if e.op == :OR_RESCUE
    when AST::FuncCall
      e.args.each { |a| referenced_decls(a, acc) }
    when AST::MethodCall
      referenced_decls(e.object, acc)
      e.args.each { |a| referenced_decls(a, acc) }
    end
    acc
  end

  # Outer-scope binding reassigned inside a per-iteration-rewound loop
  # escapes the iteration frame. Reuses LoopFrameAnalysis's mark_per_iter
  # determination (single source of truth).
  sig { params(fn: T.untyped).returns(T::Set[String]) }
  def loop_carry_names(fn)
    out = T.let(Set.new, T::Set[String])
    walk(fn.body) do |node|
      body = case node
             when AST::WhileLoop then (node.tight ? nil : node.do_branch)
             when AST::ForRange  then node.body
             when AST::ForEach   then node.body
             end
      next unless body
      local_names = LoopFrameAnalysis.collect_local_names(body)
      rewound = LoopFrameAnalysis.local_frame_decls(body, local_names).reject { |d|
        LoopFrameAnalysis.escapes_to_outer?(d.name.to_s, body, local_names)
      }
      next if rewound.empty?      # loop has no mark_per_iter -> no carry hazard
      walk(body) do |bind|
        next unless bind.is_a?(AST::BindExpr) && bind.mode == :assign
        nm = bind.name
        next unless nm.is_a?(String) && !local_names.include?(nm)
        ti = bind.full_type
        next unless ti.is_a?(Type)
        str_carry = ti.string?
        carry = str_carry || (ti.escape_class == :slice_managed && !ti.numeric_map?)
        next unless carry
        out << nm
        # Stamp the carry DECL heap here (not only later via decide_fn)
        # so the RET fixpoint sees `RETURN resp` as a heap return. The
        # reassignment value must allocate heap too, else restoreLoopMark
        # rewinds the concat buffer -> UAF + invalid heap-free.
        if str_carry
          LoopFrameAnalysis.promote_value_to_heap!(bind.value)
          stamp_decl_heap!(fn, nm)
        end
      end
    end
    out
  end

  # A collection arg passed to a TAKES param or a MUTABLE @list param
  # must be heap: the callee frees / reallocs using its own allocator,
  # which must match the source (INV-1 single allocator per binding).
  sig { params(fn: T.untyped, fn_nodes: FnNodes).returns(T::Set[String]) }
  def callarg_escape_names(fn, fn_nodes)
    out = T.let(Set.new, T::Set[String])
    # Pre-walk decls so we can look up an aggregate arg's init expression.
    decls = T.let({}, T::Hash[String, T.untyped])
    walk(fn.body) { |n| decls[n.name.to_s] = n if decl?(n) }
    walk(fn.body) do |call|
      next unless call.is_a?(AST::FuncCall) || call.is_a?(AST::MethodCall)
      callee = fn_nodes[call.name.to_s] || fn_nodes[call.name]
      next unless callee.is_a?(AST::FunctionDef)
      args = call.args || []
      callee.params.each_with_index do |param, idx|
        arg = args[idx]
        next unless arg
        src = unwrap(arg)
        next unless src.is_a?(AST::Identifier)
        ti = src.full_type
        next unless ti.is_a?(Type)
        pt = param.type
        mut_list = param.mutable && pt.is_a?(Type) && pt.list_collection?
        if collection_ti?(ti)
          out << src.name.to_s if param.takes || mut_list
        elsif param.takes && (ti.struct? || ti.optional?)
          # The aggregate itself stays a value (RVO); only its collection
          # leaves escape. Without this, frame-allocated leaves underflow
          # the callee's heap-free in cleanup (#43).
          src_decl = decls[src.name.to_s]
          aggregate_moved_list_decls(src_decl&.value).each { |d| out << d } if src_decl
        end
      end
    end
    out
  end

  # capture_analysis.heap_promote_names deliberately excludes string
  # captures (those use the in-fiber bg_string-dupe mechanism, not heap
  # storage). Reading the stamp avoids re-deriving the exclusion here.
  sig { params(fn: T.untyped).returns(T::Set[String]) }
  def bg_capture_names(fn)
    out = T.let(Set.new, T::Set[String])
    AST.each_bg_block(fn.body) do |bg|
      names = bg.capture_analysis&.heap_promote_names
      out.merge(names) if names # :nocov: capture_analysis can be nilable upstream
    end
    out
  end

  # Decls returned directly (through GIVE/COPY/OR_RESCUE unwrap), not
  # nested in a Struct/Union literal (those are deep-copied, not moved).
  sig { params(rv: T.untyped).returns(T::Array[String]) }
  def direct_return_decls(rv)
    e = unwrap(rv)
    case e
    when AST::Identifier then [e.name.to_s]
    when AST::BinaryOp
      e.op == :OR_RESCUE ? direct_return_decls(e.left) : []
    else []
    end
  end

  # List decls moved (not deep-copied) into a returned Struct/Union
  # field. Discriminator: the field-value node's type is still
  # list_collection? (a same-shape @list field); a CopyNode / plain-
  # slice-coerced field loses that type and is deep-copied instead.
  sig { params(node: T.untyped, acc: T::Array[String]).returns(T::Array[String]) }
  def aggregate_moved_list_decls(node, acc = [])
    return acc if node.nil?
    case node
    when AST::BinaryOp
      aggregate_moved_list_decls(node.left, acc) if node.op == :OR_RESCUE
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each do |k, v|
        fv = v.nil? ? k : v
        if fv.is_a?(AST::Identifier)
          acc << fv.name.to_s if collection_ti?(fv.full_type)
        else
          aggregate_moved_list_decls(fv, acc)
        end
      end
    end
    acc
  end

  WRAPPER_NODES = T.let(
    [AST::MoveNode, AST::CopyNode, AST::CloneNode, AST::FreezeNode, AST::ShareNode].freeze,
    T::Array[T.untyped]
  )

  sig { params(e: T.untyped).returns(T.untyped) }
  def unwrap(e)
    e = e.value while WRAPPER_NODES.any? { |k| e.is_a?(k) }
    e
  end

  sig { params(decl_node: T.untyped).returns(T::Boolean) }
  def inherently_heap?(decl_node)
    ti = type_of(decl_node)
    ti.is_a?(Type) && inherently_heap_ti?(ti)
  end

  # Arc/Rc/Locked control block is heap by construction. @atomic is
  # NOT (a lock-free CPU cell, often inline primitive -- marking it
  # heap fires MIRChecker OWNED_RETURN_WITHOUT_ALLOC). map/set/pool
  # are NOT inherent either: their backing allocator follows the
  # binding (local non-escaping HashMap stays frame -- 25_index).
  sig { params(ti: Type).returns(T::Boolean) }
  def inherently_heap_ti?(ti)
    ti.locked? || ti.write_locked? || ti.versioned? || ti.multiowned? || ti.shared?
  end

  sig { params(ti: T.untyped).returns(T::Boolean) }
  def collection_ti?(ti)
    return false unless ti.is_a?(Type)
    ti.list_collection? || ti.map? || ti.set_collection? || ti.pool?
  end

  # Returning a string does NOT transfer heap ownership: strings are
  # codegen-duped at the RETURN site / bg_string-duped at capture. A
  # type-level :heap (e.g. an @indirect field borrow `RETURN w.inner`)
  # is NOT used here either -- that's not an ownership transfer.
  # node_heap_provenance? handles the legitimate loop-carry-local case.
  sig { params(ti: T.untyped).returns(T::Boolean) }
  def ret_heap_type?(ti)
    return false unless ti.is_a?(Type)
    inherently_heap_ti?(ti) || collection_ti?(ti)
  end

  sig do
    params(
      fn: T.untyped, decisions: T::Hash[String, Symbol], _name: T.untyped,
      heap_decls: T::Set[String], ret_heap: RetHeap,
    ).void
  end
  def stamp_fn!(fn, decisions, _name, heap_decls, ret_heap = {})
    return_nodes = return_values_nodes(fn.body)
    walk(fn.body) do |n|
      next unless decl?(n)
      # Each `_ = expr` is an independent declaration; the name-keyed
      # `decisions` map collapses them, so discards must be stamped
      # per-node here (else the hoisted HPT temp leaks).
      if n.name.to_s == "_"
        if decl_value_is_heap_call?(n.value, ret_heap)
          heap_decls << "_"
          stamp_node_heap!(n, return_nodes)
        end
        next
      end
      next unless decisions[n.name.to_s] == :heap
      heap_decls << n.name.to_s
      stamp_node_heap!(n, return_nodes)
    end
  end

  sig { params(n: T.untyped, return_nodes: T::Array[T.untyped]).void }
  def stamp_node_heap!(n, return_nodes)
    n.storage = :heap
    ft = n.full_type
    ft.provenance = :heap if ft.is_a?(Type) && !ft.heap_provenance?
    # Annotator stamps symbol on every binding-decl node; MIRPass runs
    # strictly after. Raises if nil -- means an annotator hole.
    sym = n.symbol
    Kernel.raise "EscapeGraph: stamp_node_heap! got nil symbol on #{n.class}" if sym.nil?
    sym.storage = :heap
    sym.type.provenance = :heap
    stamp_return_symbol!(return_nodes, n.name.to_s)
    v = n.value
    v.storage = :heap if v.is_a?(AST::Locatable)
  end

  sig { params(fn: T.untyped, name: String).void }
  def stamp_decl_heap!(fn, name)
    return_nodes = return_values_nodes(fn.body)
    walk(fn.body) do |n|
      next unless decl?(n) && n.name.to_s == name
      stamp_node_heap!(n, return_nodes)
    end
  end

  sig { params(return_nodes: T::Array[T.untyped], var_name: String).void }
  def stamp_return_symbol!(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value # :nocov: redundant -- return_values_nodes pre-filters
      ident = extract_ident(ret.value, var_name)
      sym = ident&.symbol
      next unless sym
      sym.storage = :heap
      sym.type.provenance = :heap
    end
  end

  sig { params(node: T.untyped, var_name: String).returns(T.untyped) }
  def extract_ident(node, var_name)
    case node
    when AST::Identifier
      node.name.to_s == var_name ? node : nil
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_value { |v| r = extract_ident(v, var_name); return r if r }
      nil
    end
  end

  sig { params(body: T.untyped).returns(T::Array[T.untyped]) }
  def return_values(body)
    vs = T.let([], T::Array[T.untyped])
    walk(body) { |n| vs << n.value if n.is_a?(AST::ReturnNode) && n.value }
    vs
  end

  sig { params(body: T.untyped).returns(T::Array[T.untyped]) }
  def return_values_nodes(body)
    ns = T.let([], T::Array[T.untyped])
    walk(body) { |n| ns << n if n.is_a?(AST::ReturnNode) && n.value }
    ns
  end

  sig { params(fn: T.untyped).returns(T::Boolean) }
  def borrow_return?(fn)
    return true if fn.return_lifetime
    rt = fn.return_type
    !!(rt.is_a?(Type) && rt.borrow_provenance?)
  end

  sig { params(n: T.untyped).returns(T::Boolean) }
  def decl?(n)
    !!(n.is_a?(AST::VarDecl) || (n.is_a?(AST::BindExpr) && n.mode == :decl))
  end

  sig { params(lhs: T.untyped).returns(T.nilable(String)) }
  def root_ident_name(lhs)
    return lhs if lhs.is_a?(String)        # BindExpr(:assign).name is a bare String
    n = T.let(lhs, T.untyped)
    n = n.target while n.is_a?(AST::GetField) || n.is_a?(AST::GetIndex)
    n.is_a?(AST::Identifier) ? n.name.to_s : nil
  end

  # Locatable provides full_type uniformly; non-Locatable nodes (rare:
  # Literal etc. in some contexts) have no resolved type for us to read.
  sig { params(node: T.untyped).returns(T.nilable(Type)) }
  def type_of(node)
    node.is_a?(AST::Locatable) ? node.full_type : nil
  end

  HEAP_STORAGES = T.let(%i[heap multiowned shared].freeze, T::Array[Symbol])

  sig { params(lhs: T.untyped).returns(T::Boolean) }
  def heap_root_storage?(lhs)
    root = T.let(lhs, T.untyped)
    root = root.target while root.is_a?(AST::GetField) || root.is_a?(AST::GetIndex)
    sym = root.is_a?(AST::Identifier) ? root.symbol : nil
    !!(sym && HEAP_STORAGES.include?(sym.storage))
  end

  sig { params(node: T.untyped, blk: T.proc.params(arg0: T.untyped).void).void }
  def walk(node, &blk)
    case node
    when nil               then nil
    when Array             then node.each { |x| walk(x, &blk) }
    when AST::FunctionDef  then nil  # do not descend into nested fns
    when AST::Locatable
      blk.call(node)
      node.each_pair { |_, v| walk(v, &blk) } if node.is_a?(Struct)
    end
  end
end
