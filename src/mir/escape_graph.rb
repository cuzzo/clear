# typed: false
# EscapeGraph -- the single value-flow escape analysis.
#
# Replaces the 5 fragmented proxies (E1 compute_heap_return_fns!, E2
# analyze!/per_fn_scan! 9 conditions, E3a tag_transitive_provenance!,
# E3b tag_carry_call_sites!, and the escape half of PromotionClassifier).
# See docs/agents/escape-graph-spec.md.
#
# ONE rule per value-producing declaration D:
#
#   storage(D) = :heap  iff  inherently_heap?(D)  ∨  escapes?(D)
#
#   inherently_heap?(D) = D's TYPE is heap-backed BY CONSTRUCTION,
#       escape-independent:
#       map ∨ set ∨ pool (heap hashtable/slab)
#       ∨ any_sync? ∨ multiowned? ∨ shared?   (Arc/Rc/Locked control
#                                               block IS heap).
#       Everything else -- structs (even requires_move? structs that
#       own heap fields), lists, strings -- is escape-conditional: a
#       non-escaping value lives in the frame; its owned fields clean
#       up at frame scope (SROA may even keep it :stack). This was
#       proven by the real oracle (SROA spec + manifest), NOT by
#       reproducing the buggy proxies' over-conservative buckets.
#   escapes?(D)         = D's node reaches a SINK in the value-flow
#                         graph (intra fixpoint + interprocedural RET
#                         fixpoint). Shapes are EDGES, not branches:
#                         no per-shape code, so no shape can be missed.
#
# Everything downstream (MIR AllocMark/Cleanup/MoveMark, emitter,
# MIRChecker's 7 invariants) is unchanged. The graph DECIDES; the
# checker PROVES (fail-closed: any escape gap surfaces as a located
# allocator/leak/double-free error, never a silent miscompile).
require "set"

module EscapeGraph
  module_function

  # Wire point: replaces compute_heap_return_fns! + analyze! +
  # tag_transitive_provenance! + tag_carry_call_sites!. Stamps
  # storage/provenance on heap decls and returns the heap-return fn set
  # (the `heap_fns` PromotionClassifier consumes).
  #
  # @param fn_nodes [Hash{String=>AST::FunctionDef}]
  # @return [Array(Set<String>, Set<String>)]
  #   [0] names of functions whose return value is heap-owned (heap_fns)
  #   [1] names of decls stamped :heap (so BG-promotion guards skip them)
  def apply!(fn_nodes)
    # Promotion pre-pass: loop-carry string values and concat-into-heap
    # args are stamped :heap BEFORE the RET fixpoint so a `RETURN resp`
    # of a loop-carry-promoted heap string is seen as a heap return
    # (caller must own/free it).
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

  # ---- interprocedural: RET[fn] heap fixpoint (replaces E1) ----

  def compute_ret_heap_fixpoint(fn_nodes)
    ret = {}
    # Seed from the cross-module return_provenance stamp (the authority
    # for imported functions whose body we may not re-analyze here).
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

  # A returned value makes RET[fn] heap iff it is an inherently-heap
  # type, a frame-capable (list/String) value (escapes by return), or a
  # call to an already-heap-return fn. No stdlib name-lists: stdlib
  # heap results carry their heap-owning TYPE, so the type fallback
  # covers them (the old proxy used heap_fns + type, no name list).
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

  # True only when the return value is a bare Identifier that names a
  # LOCAL heap-owned decl the function itself owns (e.g. a loop-carry-
  # promoted `resp`). A returned field/borrow/match-alias (`w.inner`,
  # a `Value.Str AS s` binding, a param) carries :heap on its type too
  # but is NOT an ownership transfer -- counting it double-frees the
  # source's field cleanup (174 `prStr`). So: Identifier + non-param
  # symbol whose storage is :heap.
  def node_heap_provenance?(e)
    return false unless e.is_a?(AST::Identifier)
    sym = e.respond_to?(:symbol) ? e.symbol : nil
    return false unless sym
    return false if sym.respond_to?(:is_param) && sym.is_param
    return false unless sym.respond_to?(:storage) && sym.storage == :heap
    # A returned primitive / @atomic-or-sync cell is LOADED/unwrapped
    # (`c.*.load()`), not an ownership transfer -- even though M1 gives
    # the cell :heap symbol storage. Only genuine heap-owned values
    # (String/collection, no sync cap) transfer ownership on return.
    t = sym.respond_to?(:type) ? sym.type : nil
    t = t.is_a?(Type) ? t : nil
    return false if t && ((t.respond_to?(:primitive?) && t.primitive?) ||
                          (t.respond_to?(:any_sync?) && t.any_sync?))
    true
  rescue StandardError
    false
  end

  # ---- per-function decision (replaces E2 + E3a + E3b) ----

  # storage stamp = :heap ONLY for heap-ownership-capable types:
  #   - inherent (map/set/pool/sync): heap by construction
  #   - a list that escapes (incl. S-return: returning a list transfers
  #     heap ownership to the caller) or is bound from a heap source
  #   - a string that escapes via a NON-return sink (loop-carry, heap
  #     field/container store, BG capture). A *returned* frame string is
  #     NOT heap on the callee side: codegen heap-dupes at the RETURN
  #     site and the CALLER's binding carries the allocator. This is the
  #     list-vs-string return-ownership distinction in the language,
  #     encoded once -- not per-shape code.
  # Structs/unions/primitives are NEVER storage-stamped here: RVO/SROA
  # keep them :stack and their owned heap fields are CleanupClassifier's
  # per-field concern (matrix: struct_with_list/indirect_int storage
  # :stack, cleanup :heap/:frame).
  def decide_fn(fn, ret_heap, fn_nodes = {})
    decls = {}
    walk(fn.body) do |n|
      decls[n.name.to_s] = n if decl?(n)
    end

    # Two sink classes:
    #   STRONG -- value is stored where it must outlive the frame
    #     (heap field/container store, BG capture, loop-carry, and
    #     RETURN when the return type is @indirect/heap-ptr). ANY type
    #     stamped :heap.
    #   PLAIN-RETURN -- a normal `RETURN x` whose return type is not
    #     @indirect. RVO/copy for primitives/structs/rodata; codegen
    #     heap-dupe for frame strings (callee local stays frame); only
    #     @list transfers heap ownership to the caller -> @list only.
    esc_strong  = Set.new
    esc_listret = Set.new
    each_sink_expr(fn, include_return: false) { |se| referenced_decls(se).each { |d| esc_strong << d } }
    loop_carry_names(fn).each   { |d| esc_strong << d }  # S-loopcarry
    bg_capture_names(fn).each   { |d| esc_strong << d }  # S-bgcapture
    callarg_escape_names(fn, fn_nodes).each { |d| esc_strong << d }  # S-takes / S-mutlist
    if !borrow_return?(fn)
      if heap_ptr_return?(fn)
        # @indirect/heap-ptr return: the returned address must survive
        # frame rewind -> ANY referenced decl (incl. nested) escapes.
        return_values(fn.body).each { |rv| referenced_decls(rv).each { |d| esc_strong << d } }
      else
        # Plain return: a DIRECTLY returned list is moved out (ownership
        # transfer -> heap). A list referenced inside a returned
        # Struct/Union literal escapes ONLY if it is MOVED into a
        # same-shape `@list` field (the field-value node keeps its
        # list_collection? type); if the field type is a plain slice
        # the transpiler DEEP-COPIES it (dupeValue/blk_copy) and the
        # source stays frame -- PromotionClassifier owns that dupe.
        return_values(fn.body).each do |rv|
          direct_return_decls(rv).each       { |d| esc_listret << d }
          aggregate_moved_list_decls(rv).each { |d| esc_listret << d }
        end
      end
    end

    # Reverse value-flow: a's init/assign references b ⇒ b ──▶ a.
    # Also: a binding REASSIGNED from a heap-returning call owns heap
    # (e.g. `result = makeList()` inside an IF branch -- old E3a).
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
          # A struct/union binding is RVO'd to :stack; its owned heap
          # fields are CleanupClassifier's per-field concern (matrix:
          # struct_with_list/union_pure/indirect_int -> :stack). It is
          # heap ONLY when an Arc/Rc wrapper (inherent) or a STRONG
          # sink forces its address to outlive the frame (@indirect
          # return / heap-field store). NOT via list-return or a
          # transitive heap call (that would double-free the RVO'd /
          # dupeUnionValue'd copy).
          inherently_heap?(dnode) || esc_strong.include?(dn)
        else
          inherently_heap?(dnode) ||
            esc_strong.include?(dn) ||
            (collection_ti?(ti) && esc_listret.include?(dn)) ||
            # Transitive heap ownership: x = heapReturningFn() (at decl
            # or via reassignment). Ownership comes from the callee's
            # heap-return contract, not x's (often collection-erased)
            # inferred type -- so this is NOT type-gated.
            reassigned_heap.include?(dn)
        end
      # Never stamp a value that CAN NEVER own heap (the exact predicate
      # MIRChecker's INV-COPY-CLEANUP enforces -- read the authority,
      # don't re-derive). Primitives / Id<T> without caps are Copy
      # handles (e.g. `pid = pool.insert(...)` -> Id<User>).
      heap = false if heap && cannot_own_heap?(ti)
      result[dn] = heap ? :heap : :frame
    end
    result
  end

  # A user-defined struct OR union/enum (Type#struct? is true for any
  # non-primitive/string/array/map/optional composite -- it covers
  # tagged unions too). These are RVO'd to :stack with per-field
  # cleanup; never flat-heap-stamped except via a strong sink.
  def struct_aggregate?(ti)
    ti.is_a?(Type) && ti.respond_to?(:struct?) && ti.struct? &&
      !(ti.respond_to?(:any_sync?) && ti.any_sync?)
  rescue StandardError
    false
  end

  # The function's return type is an @indirect / heap-pointer: the
  # returned value's address must survive frame rewind, so the returned
  # binding (any type) must be heap-allocated. (Old E2 condition 3.)
  def heap_ptr_return?(fn)
    rt = fn.return_type
    rt = Type.new(rt) if rt && !rt.is_a?(Type)
    return false unless rt.is_a?(Type)
    (rt.respond_to?(:indirect?) && rt.indirect?) ||
      (rt.respond_to?(:heap?) && rt.heap?)
  rescue StandardError
    false
  end

  # Mirrors MIRChecker INV-COPY-CLEANUP exactly: a capability-free
  # primitive or Id<T> is a Copy handle and can never own heap memory.
  def cannot_own_heap?(ti)
    return false unless ti.is_a?(Type)
    no_caps = !ti.any_sync? && !ti.multiowned? && !ti.shared?
    no_caps && (ti.primitive? ||
                (ti.respond_to?(:generic_instance?) && ti.generic_instance? &&
                 ti.generic_base == :Id))
  rescue StandardError
    false
  end


  # The decl's initializer is a call to a user fn whose RET is heap
  # (E-call / transitive provenance: x = heapRetFn() ⇒ x owns heap).
  # Stdlib heap results are NOT matched here -- the binding's own type
  # carries heap provenance for those (no stdlib name-list smell).
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

  # ---- SINKS (spec §SINKS) ----

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

  # S-heapmut-arg (concat_into_heap): a frame string-concat passed into
  # a collection mutator whose ELEMENT type is a user-defined composite
  # (union/struct) dangles after the enclosing frame rewinds -- the
  # container's cleanup recursively frees the embedded string fields, so
  # the frame string is a true UAF. Promote the concat (incl. inside
  # Struct/Union literal fields) to heap. Element-type gate matches old
  # E2 cond7: String/primitive-element lists keep frame-allocated
  # cleanup, so a heap string there would LEAK on deinit.
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

  # Stamp every frame string-concat in `node` (descending wrapper /
  # Struct / Union / list literals via the canonical AST.wrapped_children)
  # to heap so the transpiler emits std.mem.concat(heapAlloc, ...).
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

  # ---- value-flow EDGES: which decl names does this expr reach ----

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
      # OR_RESCUE passes the LHS success value through (alias) -> recurse
      # left. Every other binary op (string concat `a + b`, arithmetic,
      # comparison) produces a FRESH value; its operands are read by
      # value and do NOT escape through the result. Recursing them
      # wrongly drags concat operands into a loop-carry's escape set
      # (`resp = resp + result` must not heap-stamp the frame `result`).
      referenced_decls(e.left, acc) if e.op == :OR_RESCUE
    when AST::FuncCall
      e.args.each { |a| referenced_decls(a, acc) }
    when AST::MethodCall
      referenced_decls(e.object, acc)
      e.args.each { |a| referenced_decls(a, acc) }
    end
    acc
  end

  # S-loopcarry: a binding declared OUTSIDE a per-iteration-rewound
  # loop but reassigned a fresh frame value INSIDE it escapes the
  # iteration frame (read in the next iteration / after the loop). Uses
  # LoopFrameAnalysis -- the existing authority for "does this loop get
  # mark_per_iter" -- so this reads a stamp, it does not re-derive.
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
        # The carry decl is heap (it survives per-iteration rewind);
        # its reassignment value must allocate from the SAME (heap)
        # allocator, or `resp = resp + x` concats into the frame that
        # restoreLoopMark then rewinds -> UAF + invalid heap-free.
        # Fully stamp the carry DECL heap here (not only via decide_fn)
        # so the RET fixpoint sees a `RETURN resp` of a heap string.
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

  # S-takes / S-mutlist: a collection identifier passed as a call arg
  # into (a) a TAKES param of a heap-cleanup collection type -- the
  # callee frees with heapAlloc, so the source must be heap (INV-1
  # single-allocator); or (b) a MUTABLE @list param -- the callee's
  # .append reallocs against the receiver's allocator, so a frame
  # source's growth buffer dies at the callee frame mark (UAF/leak).
  # Old E2 cond8/cond9; the spec's E-arg-takes / E-arg-mutlist edges.
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

  # S-bgcapture: a value captured by a BG/stream fiber outlives the
  # declaring frame. Uses capture_analysis.heap_promote_names -- the
  # capture-analysis authority for which captures need heap promotion
  # (it deliberately EXCLUDES string captures: those use the in-fiber
  # bg_string-dupe mechanism, not heap storage). Reads the stamp; does
  # not re-derive by walking identifiers.
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

  # Decls returned DIRECTLY as the return value (through GIVE/COPY/
  # OR_RESCUE unwrap) -- NOT nested inside a Struct/Union/call literal
  # (those are deep-copied by the transpiler, not moved).
  def direct_return_decls(rv)
    e = unwrap(rv)
    case e
    when AST::Identifier then [e.name.to_s]
    when AST::BinaryOp
      e.op == :OR_RESCUE ? direct_return_decls(e.left) : []
    else []
    end
  end

  # List decls referenced as a Struct/Union literal FIELD VALUE in the
  # return, where the field-value node still carries a list_collection?
  # type -> the @list container is moved into the aggregate (escape).
  # A CopyNode / plain-slice-coerced field is deep-copied (not moved):
  # its node type is no longer list_collection?, so it is excluded.
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

  # ---- the type predicates (the corrected DECISION RULE) ----

  def inherently_heap?(decl_node)
    ti = type_of(decl_node)
    ti.is_a?(Type) && inherently_heap_ti?(ti)
  end

  # Inherently heap = heap-backed BY CONSTRUCTION, escape-independent:
  # an Arc/Rc/Locked wrapper IS a heap control block (ContainerInit
  # always heap-allocates it). NOT map/set/pool: their backing allocator
  # follows the BINDING's allocator (frame vs heap), so a local non-
  # escaping HashMap lives in the frame -- proven by the real oracle
  # (25_index `grouped`, baseline :frame), not by the buggy proxies'
  # over-conservative "map = always heap" bucket. Collections are
  # uniformly escape-conditional, exactly like list/string/struct.
  def inherently_heap_ti?(ti)
    # Arc/Rc/Locked control block IS heap by construction. NOT @atomic
    # (a lock-free CPU cell, often a stack/inline primitive -- no alloc;
    # marking it heap fires MIRChecker OWNED_RETURN_WITHOUT_ALLOC) nor
    # @local/@raw/@symbol (data-access modes, not heap wrappers).
    return true if ti.respond_to?(:locked?)       && ti.locked?
    return true if ti.respond_to?(:write_locked?) && ti.write_locked?
    return true if ti.respond_to?(:versioned?)    && ti.versioned?
    return true if ti.respond_to?(:multiowned?)   && ti.multiowned?
    return true if ti.respond_to?(:shared?)       && ti.shared?
    false
  rescue StandardError
    false
  end

  # Any heap-owning collection container (list/map/set/pool). Uniformly
  # escape-conditional: returned/moved-out -> heap; local -> frame.
  def collection_ti?(ti)
    return false unless ti.is_a?(Type)
    (ti.respond_to?(:list_collection?) && ti.list_collection?) ||
      (ti.respond_to?(:map?) && ti.map?) ||
      (ti.respond_to?(:set_collection?) && ti.set_collection?) ||
      (ti.respond_to?(:pool?) && ti.pool?)
  rescue StandardError
    false
  end

  # RET[fn] is heap for collection ownership transfer (or an inherent
  # Arc/Rc/Locked). A string-returning fn does NOT make the caller's
  # binding heap-owned: strings are codegen-duped at the RETURN site /
  # bg_string-duped at capture. (Matches old E1's `!ti.string?` carve-out.)
  def ret_heap_type?(ti)
    return false unless ti.is_a?(Type)
    # Collection ownership transfer / Arc-Rc-Locked only. Type-level
    # :heap provenance is NOT used here: a returned @indirect field
    # borrow (`RETURN w.inner`) carries :heap on its type but is not an
    # ownership transfer. The genuine loop-carry-local case is handled
    # precisely by node_heap_provenance? (Identifier -> owned heap decl).
    inherently_heap_ti?(ti) || collection_ti?(ti)
  rescue StandardError
    false
  end

  # ---- stamping (the contract PromotionClassifier/CleanupClassifier read) ----

  def stamp_fn!(fn, decisions, _name, heap_decls, ret_heap = {})
    return_nodes = return_values_nodes(fn.body)
    walk(fn.body) do |n|
      next unless decl?(n)
      # Every `_ = expr` discard is an INDEPENDENT declaration; the
      # name-keyed `decisions` map collapses them, so a discarded
      # heap-returning call must be stamped per-node here (else the
      # hoisted HPT temp gets no cleanup -> leak).
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

  # Stamp ONE declaration node (and its symbol + the return identifier
  # reaching it) :heap. The single per-decl stamp contract that
  # PromotionClassifier / CleanupClassifier read.
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

  # Pre-pass stamp of a loop-carry string DECL by name, so the RET
  # fixpoint sees `RETURN <carry>` as a heap return.
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

  # ---- helpers ----

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
    return lhs if lhs.is_a?(String)        # BindExpr(:assign).name is the bare var name
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
    when AST::FunctionDef then nil  # do not descend nested fns
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
