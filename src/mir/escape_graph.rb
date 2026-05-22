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
require_relative "escape_analysis"

module EscapeGraph
  extend T::Sig
  module_function

  # Values are always AST::FunctionDef (compiler_frontend.rb populates it
  # via `fn_nodes[s.name] = s if s.is_a?(AST::FunctionDef)` + synthesized
  # test-body wrappers, also FunctionDefs). The value type being concrete
  # lets `fn.body` drop the defensive `fn&.body` nil-guard.
  FnNodes = T.type_alias { T::Hash[T.untyped, AST::FunctionDef] }
  RetHeap = T.type_alias { T::Hash[T.untyped, T::Boolean] }

  sig { params(fn_nodes: FnNodes, schema_lookup: T.untyped).returns([T::Set[String], T::Set[String]]) }
  def apply!(fn_nodes, schema_lookup = nil)
    # Schema lookup for struct/union field inspection -- threaded so the
    # escape graph can ask "does this struct own heap fields".
    @schema_lookup = T.let(schema_lookup, T.untyped)
    # The escape graph, fixpointed across functions. ret_heap[f] -- does
    # f return heap-owned data -- is itself an escape result (f's return
    # value escapes f), so it is derived from decide_fn and iterated to
    # a fixpoint, not computed by a separate pass.
    # Annotation's heap-return decisions (big-struct / @indirect / heap
    # return types) -- captured ONCE before the fixpoint mutates
    # return_provenance, so reading them never self-amplifies.
    annotated_heap_ret = T.let(Set.new, T::Set[T.untyped])
    fn_nodes.each { |n, fn| annotated_heap_ret << n if fn.return_provenance == :heap }
    ret_heap = T.let({}, RetHeap)
    fn_nodes.each { |n, _| ret_heap[n] = annotated_heap_ret.include?(n) }
    decisions = T.let({}, T::Hash[T.untyped, T::Hash[String, Symbol]])
    changed = T.let(true, T::Boolean)
    iters = 0
    while changed && iters < 50
      iters += 1
      changed = false
      fn_nodes.each do |name, fn|
        next unless fn.body
        decisions[name] = decide_fn(fn, ret_heap, fn_nodes)
        rh = fn_returns_heap?(fn, T.must(decisions[name]), fn_nodes, ret_heap, annotated_heap_ret)
        if rh != ret_heap[name]
          ret_heap[name] = rh
          changed = true
        end
      end
    end

    heap_decls = T.let(Set.new, T::Set[String])
    fn_nodes.each do |name, fn|
      next unless fn.body
      stamp_fn!(fn, T.must(decisions[name]), name, heap_decls, ret_heap)
      fn.return_provenance = :heap if ret_heap[name]
    end
    # Cross-module SYNC propagation: caller's arg sync flows into callee's
    # param SymbolEntry. Part of escape (the sync axis is whether the value
    # crosses threads / scheduler boundaries). Folded here so a single pass
    # marks every escape decision.
    EscapeAnalysis.propagate_caller_sync!(fn_nodes)
    # Loop-frame escape promotions (frame decls that escape via outer mutation
    # / outer field assignment) belong to escape analysis. Folding the
    # promotion side-effects here means a single pass marks every escape;
    # LoopFrameAnalysis.analyze! at MIRPass step 4 only sets mark_per_iter.
    LoopFrameAnalysis.analyze!(fn_nodes)
    # Final escape-axis pass: every CopyNode in the AST gets its allocator
    # set from its eventual container's FINALIZED storage (post-escape-
    # promotion). Single source of truth for "one collection = one
    # allocator": no annotator guessing pre-escape, no per-callsite
    # ad-hoc decision.
    fn_nodes.each_value { |fn| stamp_copy_node_alloc!(fn) if fn.body }
    heap_fns = ret_heap.each_with_object(T.let(Set.new, T::Set[String])) { |(n, h), s| s << n.to_s if h }
    [heap_fns, heap_decls]
  end

  # Storage → allocator mapping. The CopyNode.alloc field only takes
  # :heap or :frame: heap-wrapper storage modes (sync/shared/multiowned/
  # link/frozen) all imply heap allocation for the contained data;
  # frame/stack imply frame allocation.
  sig { params(storage: T.nilable(Symbol)).returns(Symbol) }
  def storage_to_alloc(storage)
    case storage
    when :frame, :stack then :frame
    else :heap
    end
  end

  # Resolve a SymbolEntry to its authoritative storage.
  # The Identifier's `.symbol` field can lag behind the decl's symbol after
  # escape analysis upgrades the decl (sym.reg points to the decl node,
  # whose symbol is the authoritative entry). Single source of truth.
  sig { params(sym: T.untyped).returns(T.nilable(Symbol)) }
  def authoritative_storage(sym)
    return nil unless sym
    decl = sym.respond_to?(:reg) ? sym.reg : nil
    decl_sym = decl && decl.respond_to?(:symbol) ? decl.symbol : nil
    decl_sym&.storage || sym.storage
  end

  # Walk every CopyNode reachable from fn.body and set CopyNode.alloc to
  # the eventual container's finalized allocator. Replaces ad-hoc
  # container_alloc threading at hundreds of annotator sites with one
  # uniform pass that has all the data (post-EscapeGraph storage is
  # final).
  sig { params(fn: T.untyped).void }
  def stamp_copy_node_alloc!(fn)
    AST.walk_body(fn.body) do |node|
      case node
      when AST::VarDecl, AST::BindExpr
        # The init expression's CopyNodes inherit the binding's
        # finalized container allocator.
        ca = storage_to_alloc(authoritative_storage(node.symbol))
        stamp_copies_in_expr!(node.value, ca) if node.value
      when AST::MethodCall, AST::FuncCall
        # Method-call args (including TAKES) live in the receiver's
        # container. Resolve to the authoritative storage on the decl,
        # because Identifier.symbol may lag behind post-escape upgrades.
        receiver = node.is_a?(AST::MethodCall) ? node.object : nil
        rec_sym = receiver.respond_to?(:symbol) ? receiver.symbol : nil
        rec_storage = authoritative_storage(rec_sym)
        ca = rec_storage ? storage_to_alloc(rec_storage) : nil
        next unless ca
        node.args.each { |arg| stamp_copies_in_expr!(arg, ca) }
      end
    end
  end

  # Recursively walk expr and set every CopyNode's alloc. Stops at
  # nested-binding boundaries (calls have their own container context,
  # handled by the top-level walk_body MethodCall/FuncCall arm).
  sig { params(expr: T.untyped, alloc: Symbol).void }
  def stamp_copies_in_expr!(expr, alloc)
    return unless expr
    case expr
    when AST::CopyNode
      expr.alloc = alloc
      stamp_copies_in_expr!(expr.value, alloc)
    when AST::StructLit, AST::UnionVariantLit
      expr.fields.each_value { |fv| stamp_copies_in_expr!(fv, alloc) }
    when AST::ListLit
      expr.items.each { |i| stamp_copies_in_expr!(i, alloc) }
    when AST::MethodCall, AST::FuncCall
      # Don't descend into calls: their args have their own container
      # context (the receiver, or the callee's heap-TAKES contract).
      # The top-level walk_body visit will reach this MethodCall/FuncCall
      # via its own arm and handle args correctly.
    end
  end

  sig { params(fn_nodes: FnNodes).returns(RetHeap) }
  def compute_ret_heap_fixpoint(fn_nodes)
    ret = T.let({}, RetHeap)
    # Seed from cross-module return_provenance for imported functions
    # whose body isn't re-analyzed here.
    fn_nodes.each { |n, fn| ret[n] = fn.return_provenance == :heap }
    # Seed from local heuristics that were previously scattered across
    # the annotator: String return type implies heap (callers must own
    # the result); a return value that COPIES a non-implicitly-copyable
    # value or wraps a COPY in a StructLit allocates heap.
    fn_nodes.each do |name, fn|
      next if ret[name] || !fn.body
      next if borrow_return?(fn)
      if local_fn_returns_heap?(fn)
        ret[name] = true
        fn.return_provenance = :heap
      end
    end
    changed = T.let(true, T::Boolean)
    iters = 0
    while changed && iters < 200
      changed = false
      iters += 1
      fn_nodes.each do |name, fn|
        next if ret[name] || !fn.body
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

  sig { params(fn: T.untyped).returns(T::Boolean) }
  def local_fn_returns_heap?(fn)
    if fn.respond_to?(:catch_clauses) && fn.catch_clauses.is_a?(Array) && fn.catch_clauses.any?
      ret_type = fn.respond_to?(:return_type) ? fn.return_type : nil
      bare = if ret_type.respond_to?(:error_union?) && ret_type.error_union? &&
                ret_type.respond_to?(:payload_type)
                ret_type.payload_type || ret_type
             else
                ret_type
             end
      if bare.respond_to?(:string?) && bare.string?
        sym_sync = bare.respond_to?(:sync) ? bare.sync : nil
        return true unless sym_sync == :symbol || sym_sync == :raw
      end
    end
    return_values(fn.body).any? do |v|
      next false unless v
      next true if v.is_a?(AST::CopyNode) && !copy_implicitly_copyable?(v)
      if (v.is_a?(AST::StructLit) || v.is_a?(AST::UnionVariantLit)) &&
         v.respond_to?(:fields) && v.fields
        next true if v.fields.any? { |_, fv| fv.is_a?(AST::CopyNode) }
      end
      false
    end
  end

  sig { params(node: AST::CopyNode).returns(T::Boolean) }
  def copy_implicitly_copyable?(node)
    ti = node.full_type
    return false unless ti.is_a?(Type)
    resolver = ->(name) { nil }
    ti.implicitly_copyable?(resolver)
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
    walk(fn.body) { |n| decls[n.name.to_s] = n if decl?(n) }

    # The escape graph. `heap` is the set of bindings that are heap:
    # they escape a frame-scope, are heap by construction, or hold
    # heap-owned data. `flow` records value aliasing -- if two bindings
    # share a value, they share an allocator, so heap propagates across.
    heap = T.let(Set.new, T::Set[String])
    flow = T.let(Hash.new { |h, k| h[k] = [] }, T::Hash[String, T::Array[String]])

    decls.each { |dn, d| heap << dn if inherently_heap?(d) }

    # ONE generic scope-aware walk recognizing the escape methods.
    # heap_ptr_ret: this fn's return type is a heap pointer (*T) -- the
    # returned binding IS the heap object, so it escapes on return
    # regardless of shape.
    heap_ptr_ret = !borrow_return?(fn) && heap_ptr_return?(fn)
    # Function-top-level bindings: a container declared here and filled
    # inside any loop outlives every iteration, so it must be heap. A
    # container declared inside a loop body is reclaimed with that loop.
    top_locals = frame_local_names(fn.body)
    collect_escapes!(fn.body, T.let(Set.new, T::Set[String]), false,
                     decls, flow, heap, ret_heap, fn_nodes, !borrow_return?(fn), heap_ptr_ret,
                     top_locals)

    # Fixpoint: heap propagates across value-aliasing edges.
    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      flow.each do |src, dsts|
        next if heap.include?(src)
        next unless dsts.any? { |d| heap.include?(d) }
        heap << src
        changed = true
      end
    end

    result = T.let({}, T::Hash[String, Symbol])
    decls.each_key { |dn| result[dn] = heap.include?(dn) ? :heap : :frame }
    result
  end

  # Does `fn` return heap-owned data the caller must free? This is just
  # the escape graph applied to the return: the returned value escapes
  # `fn`, and is heap iff it carries heap-owned data. A borrow-return
  # transfers no ownership.
  sig do
    params(fn: T.untyped, decisions: T::Hash[String, Symbol], fn_nodes: FnNodes,
           ret_heap: RetHeap, annotated_heap_ret: T::Set[T.untyped]).returns(T::Boolean)
  end
  def fn_returns_heap?(fn, decisions, fn_nodes, ret_heap, annotated_heap_ret)
    return false if borrow_return?(fn)
    # Annotation already classified this as a heap return (big-struct /
    # @indirect / heap-typed result), or the return type is a heap
    # pointer -- a heap-owned result by construction.
    return true if annotated_heap_ret.include?(fn.name) || heap_ptr_return?(fn)
    decls = T.let({}, T::Hash[String, T.untyped])
    walk(fn.body) { |n| decls[n.name.to_s] = n if decl?(n) }
    heap_set = T.let(Set.new, T::Set[String])
    decisions.each { |k, v| heap_set << k if v == :heap }
    return_values(fn.body).any? do |rv|
      rv && escaping_value_is_heap?(rv, decls, heap_set, ret_heap, fn_nodes)
    end
  end

  # The single escape walk. A binding's value ESCAPES when it reaches a
  # place that outlives its declaring frame-scope -- the only escape
  # methods, recognized uniformly here:
  #   M1 RETURN                  -- reaches a function return
  #   M2 enclosing-scope store   -- stored into a binding/field/element
  #                                 declared in an enclosing frame-scope
  #                                 (loop-carry, BG-yield, outer assign)
  #   M3 fiber/closure capture   -- referenced from inside a BG/lambda
  #                                 body while declared outside it
  #   M4 TAKES                   -- passed as a TAKES argument
  # Frame-scopes are the function body, loop bodies, and BG/lambda
  # bodies. Aliasing edges (B = A, field/element store) carry heap
  # transitively. No per-mechanism / per-type branch.
  sig do
    params(stmts: T.untyped, outer: T::Set[String], in_fiber: T::Boolean,
           decls: T::Hash[String, T.untyped], flow: T::Hash[String, T::Array[String]],
           heap: T::Set[String], ret_heap: RetHeap, fn_nodes: FnNodes,
           count_return: T::Boolean, heap_ptr_ret: T::Boolean,
           top_locals: T::Set[String]).void
  end
  def collect_escapes!(stmts, outer, in_fiber, decls, flow, heap, ret_heap, fn_nodes, count_return, heap_ptr_ret, top_locals)
    return unless stmts.is_a?(Array)
    local = frame_local_names(stmts)

    mark = ->(d) { heap << d if decls.key?(d) }
    # value-aliasing edge: A and B share a value -> share an allocator.
    link = ->(a, b) do
      next unless decls.key?(a) && decls.key?(b) && a != b
      (flow[a] ||= []) << b
      (flow[b] ||= []) << a
    end
    # bindings whose value becomes part of `expr`, excluding COPY/CLONE
    # (those are independent copies, not the source binding).
    moved = ->(expr) { referenced_decls(expr).reject { |d| copy_typed_decl?(decls[d]) } }

    each_in_frame(stmts) do |n|
      case n
      when AST::Identifier
        # M3: a fiber/closure body referencing an enclosing binding.
        heap << n.name.to_s if in_fiber && outer.include?(n.name.to_s) && decls.key?(n.name.to_s)
      when AST::ReturnNode
        # M1: a returned binding escapes only when genuinely moved out
        # -- a heap-backed collection, a heap-pointer object, or a
        # string binding whose value is a fresh heap allocation.
        # Structs/unions RVO into the caller's slot: the binding itself
        # does not escape (its owned heap fields are heap by their own
        # assignment).
        if count_return && n.value
          referenced_decls(n.value).each do |d|
            nd = decls[d]
            ti = nd && type_of(nd)
            # heap_ptr_ret: the returned binding IS a heap *T object.
            # collection: heap-backed by construction when owned-returned.
            # string: heap only when its value is a fresh heap alloc
            # (a concat / heap call); a rodata/borrow string stays frame.
            heap << d if heap_ptr_ret ||
                         (ti.is_a?(Type) && collection_ti?(ti)) ||
                         (ti.is_a?(Type) && ti.string? && nd &&
                          escaping_value_is_heap?(nd.value, decls, heap, ret_heap, fn_nodes))
          end
        end
      when AST::VarDecl, AST::BindExpr
        decl_mode = n.is_a?(AST::VarDecl) || (n.is_a?(AST::BindExpr) && n.mode == :decl)
        b = n.name.is_a?(String) ? n.name : n.name.to_s
        if decl_mode
          escape_decl_value!(b, n.value, outer, in_fiber, decls, flow, heap, ret_heap, fn_nodes, link, mark)
        else
          # reassignment: target = value.
          root = root_ident_name(n.name)
          next unless root && decls.key?(root)
          if outer.include?(root)
            moved.call(n.value).each(&mark)                          # M2
            carried_root!(root, decls, heap)                         # M2: loop-carry
            # Reassigned with a value carrying heap-owned data (a
            # struct literal with a heap field): the binding must be
            # heap so it owns and frees that data with one allocator.
            heap << root if escaping_value_is_heap?(n.value, decls, heap, ret_heap, fn_nodes)
          else
            moved.call(n.value).each { |d| link.call(d, root) }
          end
        end
      when AST::Assignment
        root = root_ident_name(n.name)
        next unless root && decls.key?(root)
        # field/index store: value becomes part of `root`; whole-binding
        # store: value aliases `root`. Either way, if root is in an
        # enclosing scope the value escapes (M2), else it aliases root.
        if outer.include?(root)
          moved.call(n.value).each(&mark)                            # M2
          carried_root!(root, decls, heap)                           # M2: loop-carry
          # A heap value stored into a field/element of an enclosing
          # container forces that container heap: it must own and free
          # the heap data with one allocator (INV-1).
          heap << root if escaping_value_is_heap?(n.value, decls, heap, ret_heap, fn_nodes)
        else
          moved.call(n.value).each { |d| link.call(d, root) }
        end
      when AST::YieldExpr
        # YIELD: the value is pushed onto the stream and consumed
        # outside the producing fiber -- it escapes the fiber frame,
        # exactly like a function return escapes the function.
        referenced_decls(n.expr).each(&mark) if n.expr
      when AST::FuncCall, AST::MethodCall
        if n.is_a?(AST::MethodCall) && ELEMENT_STORE_METHODS.include?(n.name.to_s)
          # Element store (append/insert/push/put): the element JOINS the
          # container -- they share one allocator. A flow edge, not an
          # unconditional heap mark: if either escapes, both become heap;
          # if neither does, both stay frame (consistent cleanup).
          croot = root_ident_name(n.object)
          # Container declared at function scope and appended-to inside
          # a loop: it outlives every iteration, so its backing buffer
          # must be heap. A container declared inside a loop body is
          # reclaimed with that loop and stays frame.
          carried_root!(croot, decls, heap) if croot && outer.include?(croot) &&
                                               top_locals.include?(croot)
          each_call_arg_target(n, fn_nodes) do |arg, _pt, _takes, _ml|
            # ALL referenced decls join the container -- copy-typed
            # strings included: once stored, the container owns and
            # frees them with its allocator (not the `moved` exclusion,
            # which is for ownership-transfer escapes only).
            referenced_decls(arg).each do |d|
              next unless decls.key?(d)
              (croot && decls.key?(croot)) ? link.call(d, croot) : mark.call(d)
            end
            # An anonymous element that is COMMITTED heap -- a heap-
            # returning user call, or a list/hash literal -- forces the
            # container heap (it owns and frees that element with one
            # allocator). COPY/CLONE and intrinsic results (toString,
            # ...) ADAPT to the container's allocator, so they do not
            # force it.
            u = unwrap(arg)
            next if u.is_a?(AST::CopyNode) || u.is_a?(AST::CloneNode) ||
                    u.is_a?(AST::MethodCall) || u.is_a?(AST::Literal)
            if croot && decls.key?(croot) &&
               escaping_value_is_heap?(arg, decls, heap, ret_heap, fn_nodes)
              heap << croot
            end
          end
        else
          each_call_arg_target(n, fn_nodes) do |arg, _pt, takes, mut_list|
            next unless takes || mut_list
            moved.call(arg).each(&mark)                              # M4
          end
        end
      end
    end

    # Recurse into nested frame-scopes (loop / BG / lambda bodies).
    each_nested_frames(stmts) do |body, is_fiber|
      collect_escapes!(body, outer | local, in_fiber || is_fiber,
                       decls, flow, heap, ret_heap, fn_nodes, count_return || is_fiber,
                       heap_ptr_ret && !is_fiber, top_locals)
    end
  end

  # M2 loop-carry: a string- or collection-typed binding declared in an
  # enclosing frame-scope and reassigned inside a nested one (loop / BG /
  # lambda) carries a heap BACKING BUFFER that the nested frame's
  # per-iteration rewind would reclaim -- the binding must be heap so
  # the buffer survives. Primitives are copied by value; structs / unions
  # RVO by value into the binding's slot (their owned fields are heap by
  # their own construction) -- neither needs the carry promotion.
  sig { params(root: String, decls: T::Hash[String, T.untyped], heap: T::Set[String]).void }
  def carried_root!(root, decls, heap)
    d = decls[root]
    return unless d
    ti = type_of(d)
    return unless ti.is_a?(Type) && (ti.string? || collection_ti?(ti))
    heap << root
  end

  # Escape edges for a declaration `b = value`.
  sig do
    params(b: String, value: T.untyped, outer: T::Set[String], in_fiber: T::Boolean,
           decls: T::Hash[String, T.untyped], flow: T::Hash[String, T::Array[String]],
           heap: T::Set[String], ret_heap: RetHeap, fn_nodes: FnNodes,
           link: T.untyped, mark: T.untyped).void
  end
  def escape_decl_value!(b, value, outer, in_fiber, decls, flow, heap, ret_heap, fn_nodes, link, mark)
    return unless decls.key?(b)
    v = unwrap(value)
    case v
    when AST::BgBlock, AST::BgStreamBlock
      # `b = BG { ... tail }` -- the fiber yields `tail` out via the
      # promise `b` (an enclosing-scope binding for the fiber). The
      # yielded value escapes the fiber frame: b carries heap iff the
      # yield is heap.
      tail = bg_tail_expr(v)
      heap << b if tail && escaping_value_is_heap?(tail, decls, heap, ret_heap, fn_nodes)
    when AST::NextExpr
      # `b = NEXT q` -- b receives q's payload; they share an allocator.
      q = v.expr
      link.call(q.name.to_s, b) if q.is_a?(AST::Identifier)
    else
      referenced_decls(value).each do |d|
        next unless decls.key?(d)
        copy_typed_decl?(decls[d]) ? nil : link.call(d, b)
      end
      heap << b if heap_valued?(value, ret_heap, fn_nodes)
      # A struct/union literal that constructs heap-owned data (an
      # @indirect field, a heap collection field) makes the binding own
      # heap memory -- it must be heap so its cleanup uses one allocator.
      if (v.is_a?(AST::StructLit) || v.is_a?(AST::UnionVariantLit)) &&
         escaping_value_is_heap?(value, decls, heap, ret_heap, fn_nodes)
        heap << b
      end
    end
  end

  # True when an expression yields heap-owned data when it escapes a
  # scope: a heap-returning call, or any constructed value that is not a
  # bare rodata/stack literal. References to bindings already known heap
  # also count.
  sig do
    params(expr: T.untyped, decls: T::Hash[String, T.untyped],
           heap: T::Set[String], ret_heap: RetHeap, fn_nodes: FnNodes).returns(T::Boolean)
  end
  def escaping_value_is_heap?(expr, decls, heap, ret_heap, fn_nodes)
    return false if expr.nil?
    # COPY / CLONE allocate a fresh independent value -- heap-owned when
    # it escapes. Checked BEFORE unwrap (unwrap would strip the marker).
    return true if expr.is_a?(AST::CopyNode) || expr.is_a?(AST::CloneNode)
    # An @indirect payload heap-allocates (heapAlloc.create).
    return true if expr.respond_to?(:needs_heap_create) && expr.needs_heap_create
    e = unwrap(expr)
    return false if e.nil? || e.is_a?(AST::Literal)
    case e
    when AST::FuncCall
      heap_valued?(e, ret_heap, fn_nodes)
    when AST::Identifier
      # A TAKES parameter of a heap-backed type (collection, dynamic
      # array, string) is owned heap data -- the caller transferred
      # ownership, so a struct/return carrying it owns heap.
      if e.symbol&.takes
        pt = type_of(e)
        return true if pt.is_a?(Type) && (collection_ti?(pt) || pt.array? || pt.string?)
      end
      # The escape decision is authoritative: a binding in the heap set
      # (or already heap-provenance-stamped) owns heap data, regardless
      # of whether its TYPE is nominally Copy (a heap-owned string
      # binding -- its value a fresh concat -- IS a heap transfer).
      return true if heap.include?(e.name.to_s) || e.symbol&.heap_provenance?
      # A struct/union value with heap-owning fields, used in an owning
      # position (return / store), transfers heap to the new owner --
      # the value's own heap fields go with it.
      ti = type_of(e)
      !!(ti.is_a?(Type) && ti.struct? && @schema_lookup &&
         ti.needs_cleanup?(@schema_lookup))
    when AST::StringConcat, AST::ListLit, AST::HashLit
      true   # fresh allocation
    when AST::StructLit, AST::UnionVariantLit
      e.fields.values.any? { |fv| fv && escaping_value_is_heap?(fv, decls, heap, ret_heap, fn_nodes) }
    when AST::BinaryOp
      return escaping_value_is_heap?(e.left, decls, heap, ret_heap, fn_nodes) if e.op == :OR_RESCUE
      !!(e.respond_to?(:string_concat) && e.string_concat)
    when AST::MethodCall
      # A value-producing method call (toString, substr, ...) that
      # allocates yields a fresh owned result -- heap when it escapes.
      e.heap_provenance? || method_allocates?(e)
    else
      # @indirect payloads carry needs_heap_create from annotation.
      !!(e.respond_to?(:needs_heap_create) && e.needs_heap_create)
    end
  end

  # A binding is heap-VALUED when initialized from a call that returns
  # heap-OWNED data (the caller owns it), looking through `OR RAISE`. A
  # borrow-returning call yields a borrow, not ownership -- not heap.
  sig { params(value: T.untyped, ret_heap: RetHeap, fn_nodes: FnNodes).returns(T::Boolean) }
  def heap_valued?(value, ret_heap, fn_nodes)
    e = unwrap(value)
    case e
    when AST::FuncCall
      callee = fn_nodes[e.name.to_s] || fn_nodes[e.name]
      if callee.is_a?(AST::FunctionDef)
        # User function: ret_heap (does its returned value escape it) is
        # authoritative -- a borrow-return yields no ownership.
        !borrow_return?(callee) && ret_heap[e.name.to_s] == true
      else
        # Intrinsic / imported: annotation's heap stamp on the call is
        # the only signal -- it marks genuine heap-owned results.
        !!e.heap_provenance?
      end
    when AST::BinaryOp
      !!(e.op == :OR_RESCUE && heap_valued?(e.left, ret_heap, fn_nodes))
    else false
    end
  end

  # True when an intrinsic method call allocates a fresh value (its
  # stdlib registry entry is marked `allocates`) -- the same signal the
  # FSM exit / cleanup classifier read.
  sig { params(call: T.untyped).returns(T::Boolean) }
  def method_allocates?(call)
    md = call.respond_to?(:matched_stdlib_def) ? call.matched_stdlib_def : nil
    !!(md && md.emit&.allocates)
  end

  # The expression a BG/stream fiber yields -- the last body statement.
  sig { params(bg: T.untyped).returns(T.untyped) }
  def bg_tail_expr(bg)
    body = bg.respond_to?(:body) ? bg.body : nil
    return nil unless body.is_a?(Array) && !body.empty?
    tail = body.last
    tail.is_a?(AST::ReturnNode) ? tail.value : tail
  end

  # Binding names declared in this frame-scope. Descends if / match /
  # with branches (same frame) but not nested loop / fiber bodies.
  sig { params(stmts: T.untyped).returns(T::Set[String]) }
  def frame_local_names(stmts)
    names = T.let(Set.new, T::Set[String])
    each_in_frame(stmts) do |n|
      if (n.is_a?(AST::VarDecl) || (n.is_a?(AST::BindExpr) && n.mode == :decl)) && n.name.is_a?(String)
        names << n.name
      end
    end
    names
  end

  # True when `n` opens a nested frame-scope -- its body is reclaimed
  # independently of the enclosing frame.
  sig { params(n: T.untyped).returns(T::Boolean) }
  def nested_frame?(n)
    n.is_a?(AST::ForRange) || n.is_a?(AST::ForEach) ||
      n.is_a?(AST::WhileLoop) || n.is_a?(AST::WhileBindLoop) ||
      n.is_a?(AST::BgBlock) || n.is_a?(AST::BgStreamBlock) || n.is_a?(AST::LambdaLit)
  end

  # Yield every node within the current frame-scope -- descending if /
  # match / with branches, stopping at nested frame-scope bodies.
  sig { params(node: T.untyped, blk: T.untyped).void }
  def each_in_frame(node, &blk)
    return if node.nil?
    if node.is_a?(Array)
      node.each { |c| each_in_frame(c, &blk) }
      return
    end
    return unless node.is_a?(Struct)
    blk.call(node)
    return if nested_frame?(node)
    node.to_a.each { |c| each_in_frame(c, &blk) }
  end

  # Yield (body, is_fiber) for each nested frame-scope directly inside
  # the current one.
  sig { params(stmts: T.untyped, blk: T.untyped).void }
  def each_nested_frames(stmts, &blk)
    each_in_frame(stmts) do |n|
      case n
      when AST::ForRange, AST::ForEach        then blk.call(n.body, false)
      when AST::WhileLoop, AST::WhileBindLoop then blk.call(n.do_branch, false)
      when AST::BgBlock, AST::BgStreamBlock   then blk.call(n.body, true)
      when AST::LambdaLit                     then blk.call(n.body, true)
      end
    end
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
      # Initialized from a heap-returning call. A free function has no
      # receiver to inherit an allocator from, so annotation's
      # heap_provenance? stamp on the call is authoritative.
      ret_heap[e.name.to_s] == true || e.heap_provenance?
    when AST::NextExpr
      # NEXT receives the value a producer fiber yielded. A BG fiber's
      # body is just another scope: its yielded tail expression ESCAPES
      # that scope (handed out via the promise), exactly like a function
      # return. So the consumer binding is heap iff the fiber yields
      # heap -- not a separate rule, the same escape question.
      ret_ti = e.full_type
      ret_ti = Type.new(ret_ti) if ret_ti && !ret_ti.is_a?(Type)
      if ret_ti.is_a?(Type) && cannot_own_heap?(ret_ti)
        false
      else
        bg = next_producer_bg(e.expr)
        bg ? bg_yields_heap?(bg) : !!(ret_ti.is_a?(Type) && !cannot_own_heap?(ret_ti))
      end
    else
      false
    end
  end

  # The BG fiber a promise/stream binding was produced by (looking
  # through `BG {...} OR RAISE`). nil if `expr` is not such a binding.
  sig { params(expr: T.untyped).returns(T.untyped) }
  def next_producer_bg(expr)
    return nil unless expr.is_a?(AST::Identifier)
    v = expr.symbol&.reg&.value
    v = v.left if v.is_a?(AST::BinaryOp) && v.op == :OR_RESCUE
    (v.is_a?(AST::BgBlock) || v.is_a?(AST::BgStreamBlock)) ? v : nil
  end

  # True when a BG fiber's yielded tail value escapes the fiber as heap
  # data -- anything but a rodata/stack literal or a stack-primitive.
  sig { params(bg: T.untyped).returns(T::Boolean) }
  def bg_yields_heap?(bg)
    body = bg.respond_to?(:body) ? bg.body : nil
    return false unless body.is_a?(Array) && !body.empty?
    tail = body.last
    tail = tail.value if tail.respond_to?(:value) && tail.is_a?(AST::ReturnNode)
    return false unless tail
    return false if tail.is_a?(AST::Literal)
    ti = tail.respond_to?(:full_type) ? tail.full_type : nil
    ti = Type.new(ti) if ti && !ti.is_a?(Type)
    !!(ti.is_a?(Type) && !cannot_own_heap?(ti))
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
    when AST::Identifier
      # The Hoist pass lifted the frame string-concat into a __hoist_N
      # temp; promote that binding -- a sanctioned symbol.storage write.
      sym = node.symbol
      decl = sym.respond_to?(:reg) ? sym.reg : nil if sym
      sym.storage = :heap if sym && decl && concat_valued_decl?(decl)
    when AST::BinaryOp
      promote_frame_concats!(node.left)
      promote_frame_concats!(node.right)
    when AST::StringConcat
      node.parts.each { |p| promote_frame_concats!(p) }
    else
      AST.wrapped_children(node).each { |c| promote_frame_concats!(c) }
    end
  end

  # True when `decl`'s value is a string-concat expression (the shape the
  # Hoist pass moves into a temp).
  sig { params(decl: T.untyped).returns(T::Boolean) }
  def concat_valued_decl?(decl)
    v = decl.respond_to?(:value) ? decl.value : nil
    v.is_a?(AST::StringConcat) ||
      (v.is_a?(AST::BinaryOp) && v.op == :ADD && !!v.string_concat)
  end

  sig { params(expr: T.untyped, acc: T::Array[String]).returns(T::Array[String]) }
  def referenced_decls(expr, acc = [])
    return acc if expr.nil?
    # COPY / CLONE produce an independent value -- the source is read by
    # value, not moved, so it does NOT escape through them.
    return acc if expr.is_a?(AST::CopyNode) || expr.is_a?(AST::CloneNode)
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
    when AST::GetField, AST::GetIndex
      # `obj.field` / `obj[i]` -- the value is part of `obj`.
      referenced_decls(e.target, acc)
    when AST::MethodCall
      # A method's result may be extracted from its receiver (remove /
      # get / values). Arguments are NOT part of the result.
      referenced_decls(e.object, acc)
    end
    # A free-function call's result is its return value, never its
    # arguments -- no recursion into FuncCall.
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
    decls = T.let({}, T::Hash[String, T.untyped])
    walk(fn.body) { |n| decls[n.name.to_s] = n if decl?(n) }
    walk(fn.body) do |call|
      next unless call.is_a?(AST::FuncCall) || call.is_a?(AST::MethodCall)
      each_call_arg_target(call, fn_nodes) do |arg, target_type, takes, mut_list|
        is_copy = arg.is_a?(AST::CopyNode)
        src = unwrap(arg)
        if src.is_a?(AST::StructLit) || src.is_a?(AST::UnionVariantLit)
          # Struct/union literal arg with collection-typed fields:
          # appending {data: data_list} into items[] makes data_list
          # escape via items's storage. Without this branch, the
          # nested data list stays frame-allocated while items lives
          # past the loop iteration, causing UAF after rewind.
          aggregate_moved_list_decls(src).each { |d| out << d } if takes
          next
        end
        next unless src.is_a?(AST::Identifier)
        ti = src.full_type
        next unless ti.is_a?(Type)
        if collection_ti?(ti)
          out << src.name.to_s if takes || mut_list
        elsif (takes || is_copy) && (ti.struct? || ti.optional?)
          src_decl = decls[src.name.to_s]
          aggregate_moved_list_decls(src_decl.value).each { |d| out << d } if src_decl
        end
      end
    end
    out
  end

  # Yields (arg, target_param_type, takes, mut_list) for every consuming slot
  # of `call`. Unifies user-FunctionDef calls (callee.params) with stdlib
  # element-store method calls (append/insert/push/put) where the receiver's
  # element_type is the target. Without this unification, stdlib intrinsic
  # dispatch skipped the aggregate-leaf escape rule, leaving frame-allocated
  # leaves inside COPY'd union/struct elements that the runtime's dupe path
  # then tried to free with mismatched alignment.
  ELEMENT_STORE_METHODS = T.let(%w[append insert push put].freeze, T::Array[String])

  # Containers whose append/insert/push/put receives a heap-owned arg
  # must be promoted to heap so element + container share an allocator.
  # Without this, a frame @list ends up holding heap-pointer-bearing
  # elements (the :list_with_elem_cleanup workaround).
  sig { params(fn: T.untyped, ret_heap: RetHeap, already_heap: T::Set[String]).returns(T::Set[String]) }
  def heap_arg_consumer_names(fn, ret_heap, already_heap)
    out = T.let(Set.new, T::Set[String])
    walk(fn.body) do |call|
      next unless call.is_a?(AST::MethodCall) && ELEMENT_STORE_METHODS.include?(call.name.to_s)
      receiver = call.object
      next unless receiver.is_a?(AST::Identifier)
      rec_ti = receiver.full_type
      next unless rec_ti.is_a?(Type) && rec_ti.collection?
      # Already heap? No promotion needed.
      next if receiver.symbol&.heap_provenance?
      (call.args || []).each do |arg|
        if arg_carries_heap?(arg, ret_heap, already_heap)
          out << receiver.name.to_s
          break
        end
      end
    end
    out
  end

  # True when this arg expression carries heap-owned data into a container.
  # Sources of heap:
  #   - a function call whose return is heap-allocated (per ret_heap)
  #   - a CopyNode whose alloc is :heap (the existing stamper writes
  #     :frame for frame containers; :heap means the source is heap-bound)
  #   - a StructLit/UnionVariantLit whose fields recursively carry heap
  sig { params(arg: T.untyped, ret_heap: RetHeap, already_heap: T::Set[T.untyped]).returns(T::Boolean) }
  def arg_carries_heap?(arg, ret_heap, already_heap = Set.new)
    arg = unwrap(arg)
    case arg
    when AST::FuncCall, AST::MethodCall
      !!(ret_heap[arg.name.to_s] == true)
    when AST::CopyNode
      arg.alloc == :heap
    when AST::StructLit, AST::UnionVariantLit
      arg.fields.any? { |_, fv| arg_carries_heap?(fv, ret_heap, already_heap) }
    when AST::ListLit
      arg.items.any? { |it| arg_carries_heap?(it, ret_heap, already_heap) }
    when AST::Identifier
      # Already-marked heap_provenance OR will-be-promoted by another
      # escape rule already collected this pass (callarg_escape etc.).
      return true if arg.symbol&.heap_provenance?
      already_heap.include?(arg.name.to_s)
    when AST::BinaryOp
      return true if arg.respond_to?(:storage) && arg.storage == :heap
      return true if arg.respond_to?(:string_concat) && arg.string_concat
      arg_carries_heap?(arg.left, ret_heap, already_heap) || arg_carries_heap?(arg.right, ret_heap, already_heap)
    when AST::StringConcat
      return true if arg.respond_to?(:storage) && arg.storage == :heap
      true
    else
      false
    end
  end

  sig { params(call: T.untyped, fn_nodes: FnNodes, blk: T.untyped).void }
  def each_call_arg_target(call, fn_nodes, &blk)
    callee = fn_nodes[call.name.to_s] || fn_nodes[call.name]
    if callee.is_a?(AST::FunctionDef)
      args = call.args || []
      callee.params.each_with_index do |param, idx|
        a = args[idx]
        next unless a
        pt = param.type
        mut_list = param.mutable && pt.is_a?(Type) && pt.list_collection?
        blk.call(a, pt, param.takes, mut_list)
      end
    elsif call.is_a?(AST::MethodCall) && ELEMENT_STORE_METHODS.include?(call.name.to_s)
      obj = call.object
      obj_ti = (obj.respond_to?(:full_type) ? obj.full_type : nil)
      # @list/@set/@pool collections AND plain dynamic arrays (T[]) are
      # all appendable element-store targets.
      return unless obj_ti.is_a?(Type) &&
                    (collection_ti?(obj_ti) || (obj_ti.array? && obj_ti.dynamic?))
      elem_t = obj_ti.element_type
      return unless elem_t.is_a?(Type)
      (call.args || []).each { |a| blk.call(a, elem_t, true, false) }
    end
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

  # Heap by construction -- the runtime ALWAYS heap-allocates the
  # backing: Arc/Rc/Locked control block; sharded / striped concurrent
  # collections; @set (insert intrinsic hardwired to heap); and string /
  # striped HashMaps (their hashtable carries a heap allocator --
  # map_init_needs_alloc?). @atomic is NOT (a lock-free CPU cell);
  # numeric maps / @pool are NOT (backing follows the binding).
  # A binding whose type is Copy (String / primitive): returning or
  # storing it copies the value -- the binding itself does not escape.
  sig { params(dnode: T.untyped).returns(T::Boolean) }
  def copy_typed_decl?(dnode)
    return false unless dnode
    ti = type_of(dnode)
    return false unless ti.is_a?(Type)
    ti.string? || ti.primitive?
  end

  sig { params(ti: Type).returns(T::Boolean) }
  def inherently_heap_ti?(ti)
    # Heap-by-construction: every sync / ownership wrapper (Locked,
    # RwLocked, Versioned, AlwaysMutable, Arc, Rc, ...) carries a
    # heap-allocated control block; sharded / striped concurrent
    # collections, @set, string HashMaps, @indirect, and streams /
    # promises / observables (fiber / channel / ring buffers).
    ti.any_sync? || ti.any_rc? || ti.link? ||
      ti.sharded? || ti.striped? || ti.set_collection? || ti.map_init_needs_alloc? ||
      (ti.respond_to?(:indirect?) && ti.indirect?) ||
      ti.stream? || ti.tense_observable? || ti.shared_promise? || ti.promise_list?
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
      name = n.name.to_s
      # Each `_ = expr` is an independent declaration; the name-keyed
      # `decisions` map collapses them, so discards are decided per-node.
      heap = if name == "_"
               decl_value_is_heap_call?(n.value, ret_heap)
             else
               decisions[name] == :heap
             end
      if heap
        heap_decls << name
        stamp_node_heap!(n, return_nodes, fn)
      else
        stamp_node_frame!(n)
      end
    end
  end

  # Escape analysis is the single writer of the definitive placement and
  # writes Symbol#storage. node.storage is left at annotation's value
  # EXCEPT when the binding is itself a heap-pointer object -- a decl
  # returned from a heap-pointer-returning function (`*T`). That is a
  # pointer-representation fact, not an allocator decision; the lowering
  # needs node.storage = :heap to emit the `*T` form.
  sig { params(n: T.untyped, return_nodes: T::Array[T.untyped], fn: T.untyped).void }
  def stamp_node_heap!(n, return_nodes, fn)
    # Annotator stamps symbol on every binding-decl node; MIRPass runs
    # strictly after. Raises if nil -- means an annotator hole.
    sym = n.symbol
    return if sym.nil?   # synthesized decl without a symbol -- nothing to stamp
    sym.storage = :heap
    stamp_return_symbol!(return_nodes, n.name.to_s)
    n.storage = :heap if returned_as_heap_ptr?(n, fn, return_nodes)
  end

  # True when this decl is itself a heap-pointer object: its name is
  # (part of) a value returned from a heap-pointer-returning function.
  sig { params(n: T.untyped, fn: T.untyped, return_nodes: T::Array[T.untyped]).returns(T::Boolean) }
  def returned_as_heap_ptr?(n, fn, return_nodes)
    return false if borrow_return?(fn)
    return false unless heap_ptr_return?(fn)
    nm = n.name.to_s
    return_nodes.any? { |ret| ret.value && !extract_ident(ret.value, nm).nil? }
  end

  # Not escaped: the definitive storage is the annotation-derived
  # placement (:stack / :frame / :rodata). Corrects a symbol the
  # annotator over-promoted to :heap; sync / ownership-wrapper storage
  # modes (:shared / :multiowned / :locked / ...) are a separate axis
  # and are left untouched.
  sig { params(n: T.untyped).void }
  def stamp_node_frame!(n)
    sym = n.symbol
    return unless sym && sym.storage == :heap
    ns = n.respond_to?(:storage) ? n.storage : nil
    sym.storage = (ns && %i[stack frame rodata borrow].include?(ns)) ? ns : :frame
  end

  sig { params(fn: T.untyped, name: String).void }
  def stamp_decl_heap!(fn, name)
    return_nodes = return_values_nodes(fn.body)
    walk(fn.body) do |n|
      next unless decl?(n) && n.name.to_s == name
      stamp_node_heap!(n, return_nodes, fn)
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
    !!fn.return_lifetime
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
    when AST::MatchCase
      node.each_pair { |_, v| walk(v, &blk) }
    end
  end
end
