# typed: false
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

module EscapeGraph
  module_function

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
    heap_decls = Set.new
    fn_nodes.each do |name, fn|
      next unless fn&.body
      stamp_fn!(fn, decide_fn(fn, ret_heap, fn_nodes), name, heap_decls, ret_heap)
    end
    heap_fns = ret_heap.each_with_object(Set.new) { |(n, h), s| s << n if h }
    [heap_fns, heap_decls]
  end

  def compute_ret_heap_fixpoint(fn_nodes)
    ret = {}
    # Seed from cross-module return_provenance for imported functions
    # whose body isn't re-analyzed here.
    fn_nodes.each do |n, fn|
      ret[n] = (fn.respond_to?(:return_provenance) && fn.return_provenance == :heap)
    end
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
        if rvals.any? { |rv| return_value_is_heap?(rv, ret) }
          ret[name] = true
          fn.return_provenance = :heap if fn.respond_to?(:return_provenance=)
          changed = true
        end
      end
    end
    ret
  end

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
  def node_heap_provenance?(e)
    return false unless e.is_a?(AST::Identifier)
    sym = e.respond_to?(:symbol) ? e.symbol : nil
    return false unless sym
    return false if sym.respond_to?(:is_param) && sym.is_param
    return false unless sym.respond_to?(:storage) && sym.storage == :heap
    # An @atomic-or-sync primitive cell has :heap symbol storage in M1
    # but is LOADED on return, not transferred.
    t = sym.respond_to?(:type) ? sym.type : nil
    t = t.is_a?(Type) ? t : nil
    return false if t && ((t.respond_to?(:primitive?) && t.primitive?) ||
                          (t.respond_to?(:any_sync?) && t.any_sync?))
    true
  rescue StandardError
    false
  end

  def decide_fn(fn, ret_heap, fn_nodes = {})
    decls = {}
    walk(fn.body) do |n|
      decls[n.name.to_s] = n if decl?(n)
    end

    esc_strong  = Set.new
    esc_listret = Set.new
    each_sink_expr(fn, include_return: false) { |se| referenced_decls(se).each { |d| esc_strong << d } }
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

    reassigned_heap = Set.new
    init_refs = {}
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
      changed = true
      while changed
        changed = false
        esc.to_a.each do |a|
          (init_refs[a] || []).each { |b| (changed = true; esc << b) unless esc.include?(b) }
        end
      end
    end

    result = {}
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
  def struct_aggregate?(ti)
    ti.is_a?(Type) && ti.respond_to?(:struct?) && ti.struct? &&
      !(ti.respond_to?(:any_sync?) && ti.any_sync?)
  rescue StandardError
    false
  end

  def heap_ptr_return?(fn)
    rt = fn.return_type
    rt = Type.new(rt) if rt && !rt.is_a?(Type)
    return false unless rt.is_a?(Type)
    (rt.respond_to?(:indirect?) && rt.indirect?) ||
      (rt.respond_to?(:heap?) && rt.heap?)
  rescue StandardError
    false
  end

  # Mirrors MIRChecker INV-COPY-CLEANUP: capability-free primitive or
  # Id<T> is a Copy handle and never owns heap.
  def cannot_own_heap?(ti)
    return false unless ti.is_a?(Type)
    no_caps = !ti.any_sync? && !ti.multiowned? && !ti.shared?
    no_caps && (ti.primitive? ||
                (ti.respond_to?(:generic_instance?) && ti.generic_instance? &&
                 ti.generic_base == :Id))
  rescue StandardError
    false
  end


  def decl_value_is_heap_call?(expr, ret_heap)
    e = unwrap(expr)
    case e
    when AST::BinaryOp
      e.op == :OR_RESCUE && decl_value_is_heap_call?(e.left, ret_heap)
    when AST::FuncCall
      ret_heap[e.name.to_s] == true
    else
      false
    end
  end

  def each_sink_expr(fn, include_return: true)
    return_values(fn.body).each { |rv| yield rv } if include_return && !borrow_return?(fn)
    walk(fn.body) do |n|
      case n
      when AST::Assignment
        if (n.name.is_a?(AST::GetField) || n.name.is_a?(AST::GetIndex)) &&
           heap_root_storage?(n.name)
          yield n.value                        # S-heapfield
        end
      end
    end
  end

  # Frame string-concat appended to a collection with composite element
  # type dangles after frame rewind (container cleanup frees the
  # embedded string field). String/primitive element types are excluded
  # because heap-promoting their concats LEAKS on deinit (matches old
  # E2 cond7 element-type gate).
  def promote_heapmut_concats!(fn)
    walk(fn.body) do |node|
      next unless node.is_a?(AST::MethodCall)
      next unless %w[append insert push put].include?(node.name.to_s)
      obj = node.object
      next unless obj.respond_to?(:symbol) && obj.symbol
      t = obj.symbol.type
      ti = t.is_a?(Type) ? t : (Type.new(t) rescue nil)
      next unless ti && ti.respond_to?(:collection?) && ti.collection?
      elem_t = ti.respond_to?(:element_type) ? ti.element_type : nil
      next unless elem_t && !elem_t.primitive? && !elem_t.string?
      node.args.each { |arg| promote_frame_concats!(arg) }
    end
  rescue StandardError
    nil
  end

  def promote_frame_concats!(node)
    return unless node
    case node
    when AST::BinaryOp
      if node.op == :ADD && node.respond_to?(:string_concat) && node.string_concat
        node.storage = :heap if node.respond_to?(:storage=)
        ti = node.full_type
        ti.provenance = :heap if ti.is_a?(Type)
      end
      promote_frame_concats!(node.left)
      promote_frame_concats!(node.right)
    when AST::StringConcat
      node.storage = :heap if node.respond_to?(:storage=)
      node.parts&.each { |p| promote_frame_concats!(p) }
    else
      AST.wrapped_children(node).each { |c| promote_frame_concats!(c) }
    end
  rescue StandardError
    nil
  end

  def referenced_decls(expr, acc = [])
    return acc if expr.nil?
    e = unwrap(expr)
    case e
    when AST::Identifier
      acc << e.name.to_s
    when AST::StructLit, AST::UnionVariantLit
      flds = e.fields
      flds.each { |k, v| referenced_decls(v.nil? ? k : v, acc) } if flds.respond_to?(:each)
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
  def loop_carry_names(fn)
    out = Set.new
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
        next unless bind.is_a?(AST::BindExpr) && bind.respond_to?(:mode) && bind.mode == :assign
        nm = bind.name
        next unless nm.is_a?(String) && !local_names.include?(nm)
        ti = bind.respond_to?(:full_type) ? bind.full_type : nil
        next unless ti.is_a?(Type)
        str_carry = ti.respond_to?(:string?) && ti.string?
        carry = str_carry ||
                (ti.respond_to?(:escape_class) && ti.escape_class == :slice_managed &&
                 !(ti.respond_to?(:numeric_map?) && ti.numeric_map?))
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
  rescue StandardError
    out
  end

  # A collection arg passed to a TAKES param or a MUTABLE @list param
  # must be heap: the callee frees / reallocs using its own allocator,
  # which must match the source (INV-1 single allocator per binding).
  def callarg_escape_names(fn, fn_nodes)
    out = Set.new
    walk(fn.body) do |call|
      next unless call.is_a?(AST::FuncCall) || call.is_a?(AST::MethodCall)
      callee = fn_nodes[call.name.to_s] || fn_nodes[call.name]
      next unless callee.respond_to?(:params) && callee.params
      args = call.args || []
      callee.params.each_with_index do |param, idx|
        arg = args[idx]
        next unless arg
        src = unwrap(arg)                       # strip GIVE/COPY
        next unless src.is_a?(AST::Identifier)
        ti = src.respond_to?(:full_type) ? src.full_type : nil
        ti = ti.is_a?(Type) ? ti : nil
        next unless ti && collection_ti?(ti)
        takes = param.respond_to?(:takes) && param.takes
        pt = param.respond_to?(:type) ? param.type : nil
        pt = pt.is_a?(Type) ? pt : (pt ? (Type.new(pt) rescue nil) : nil)
        mut_list = param.respond_to?(:mutable) && param.mutable &&
                   pt && pt.respond_to?(:list_collection?) && pt.list_collection?
        out << src.name.to_s if takes || mut_list
      end
    end
    out
  rescue StandardError
    out
  end

  # capture_analysis.heap_promote_names deliberately excludes string
  # captures (those use the in-fiber bg_string-dupe mechanism, not heap
  # storage). Reading the stamp avoids re-deriving the exclusion here.
  def bg_capture_names(fn)
    out = Set.new
    AST.each_bg_block(fn.body) do |bg|
      names = bg.capture_analysis&.heap_promote_names
      out.merge(names) if names
    end
    out
  rescue StandardError
    out
  end

  # Decls returned directly (through GIVE/COPY/OR_RESCUE unwrap), not
  # nested in a Struct/Union literal (those are deep-copied, not moved).
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
  def aggregate_moved_list_decls(node, acc = [])
    return acc if node.nil?
    case node
    when AST::BinaryOp
      aggregate_moved_list_decls(node.left, acc) if node.op == :OR_RESCUE
    when AST::StructLit, AST::UnionVariantLit
      flds = node.fields
      if flds.respond_to?(:each)
        flds.each do |k, v|
          fv = v.nil? ? k : v
          if fv.is_a?(AST::Identifier)
            ft = fv.respond_to?(:full_type) ? fv.full_type : nil
            acc << fv.name.to_s if collection_ti?(ft)
          else
            aggregate_moved_list_decls(fv, acc)   # nested aggregate
          end
        end
      end
    end
    acc
  rescue StandardError
    acc
  end

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

  def inherently_heap?(decl_node)
    ti = type_of(decl_node)
    ti.is_a?(Type) && inherently_heap_ti?(ti)
  end

  # Arc/Rc/Locked control block is heap by construction. @atomic is
  # NOT (a lock-free CPU cell, often inline primitive -- marking it
  # heap fires MIRChecker OWNED_RETURN_WITHOUT_ALLOC). map/set/pool
  # are NOT inherent either: their backing allocator follows the
  # binding (local non-escaping HashMap stays frame -- 25_index).
  def inherently_heap_ti?(ti)
    return true if ti.respond_to?(:locked?)       && ti.locked?
    return true if ti.respond_to?(:write_locked?) && ti.write_locked?
    return true if ti.respond_to?(:versioned?)    && ti.versioned?
    return true if ti.respond_to?(:multiowned?)   && ti.multiowned?
    return true if ti.respond_to?(:shared?)       && ti.shared?
    false
  rescue StandardError
    false
  end

  def collection_ti?(ti)
    return false unless ti.is_a?(Type)
    (ti.respond_to?(:list_collection?) && ti.list_collection?) ||
      (ti.respond_to?(:map?) && ti.map?) ||
      (ti.respond_to?(:set_collection?) && ti.set_collection?) ||
      (ti.respond_to?(:pool?) && ti.pool?)
  rescue StandardError
    false
  end

  # Returning a string does NOT transfer heap ownership: strings are
  # codegen-duped at the RETURN site / bg_string-duped at capture. A
  # type-level :heap (e.g. an @indirect field borrow `RETURN w.inner`)
  # is NOT used here either -- that's not an ownership transfer.
  # node_heap_provenance? handles the legitimate loop-carry-local case.
  def ret_heap_type?(ti)
    return false unless ti.is_a?(Type)
    inherently_heap_ti?(ti) || collection_ti?(ti)
  rescue StandardError
    false
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

  def stamp_node_heap!(n, return_nodes)
    n.storage = :heap if n.respond_to?(:storage=)
    ft = n.full_type if n.respond_to?(:full_type)
    ft.provenance = :heap if ft.is_a?(Type) && !ft.heap_provenance?
    sym = n.respond_to?(:symbol) ? n.symbol : nil
    if sym
      sym.storage = :heap if sym.respond_to?(:storage=)
      st = sym.respond_to?(:type) ? sym.type : nil
      st.provenance = :heap if st.is_a?(Type)
    end
    stamp_return_symbol!(return_nodes, n.name.to_s)
    v = n.value
    v.storage = :heap if v.respond_to?(:storage=)
  end

  def stamp_decl_heap!(fn, name)
    return_nodes = return_values_nodes(fn.body)
    walk(fn.body) do |n|
      next unless decl?(n) && n.name.to_s == name
      stamp_node_heap!(n, return_nodes)
    end
  end

  def stamp_return_symbol!(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value
      ident = extract_ident(ret.value, var_name)
      next unless ident&.symbol
      ident.symbol.storage = :heap if ident.symbol.respond_to?(:storage=)
      st = ident.symbol.respond_to?(:type) ? ident.symbol.type : nil
      st.provenance = :heap if st.is_a?(Type)
    end
  end

  def extract_ident(node, var_name)
    case node
    when AST::Identifier
      node.name.to_s == var_name ? node : nil
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_value { |v| r = extract_ident(v, var_name); return r if r }
      nil
    end
  end

  def return_values(body)
    vs = []
    walk(body) { |n| vs << n.value if n.is_a?(AST::ReturnNode) && n.value }
    vs
  end

  def return_values_nodes(body)
    ns = []
    walk(body) { |n| ns << n if n.is_a?(AST::ReturnNode) && n.value }
    ns
  end

  def borrow_return?(fn)
    return true if fn.respond_to?(:return_lifetime) && fn.return_lifetime
    rt = fn.return_type
    rt = Type.new(rt) if rt && !rt.is_a?(Type)
    rt.is_a?(Type) && rt.respond_to?(:borrow_provenance?) && rt.borrow_provenance?
  rescue StandardError
    false
  end

  def decl?(n)
    n.is_a?(AST::VarDecl) ||
      (n.is_a?(AST::BindExpr) && (!n.respond_to?(:mode) || n.mode == :decl))
  end

  def root_ident_name(lhs)
    return lhs if lhs.is_a?(String)        # BindExpr(:assign).name is a bare String
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

  def heap_root_storage?(lhs)
    root = lhs
    root = root.target while root.respond_to?(:target) && (root.is_a?(AST::GetField) || root.is_a?(AST::GetIndex))
    sym = root.respond_to?(:symbol) ? root.symbol : nil
    sym && %i[heap multiowned shared].include?(sym.storage)
  rescue StandardError
    false
  end


  def walk(node, &blk)
    case node
    when nil
    when Array then node.each { |x| walk(x, &blk) }
    when AST::FunctionDef then nil  # do not descend into nested fns
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
