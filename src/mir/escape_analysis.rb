# typed: strict
# src/escape_analysis.rb - Single pre-pass escape analysis for CLEAR compiler.
#
# Determines which declarations require heap allocation before CleanupClassifier
# runs. Replaces the cascade of upgrade_* methods in MIRPass.
#
# Pipeline position: after E1 (compute_heap_return_fns!) and PromotionClassifier,
# before LoopFrameAnalysis and CleanupClassifier.
#
# Phases:
#   E1 - compute_heap_return_fns!   fixed-point: which functions return heap values
#   E2 - analyze!                   one walk per fn: apply all 6 escape conditions
#   E3 - tag_transitive_provenance! propagate heap provenance to binding type_infos
#         tag_carry_call_sites!     stamp heap provenance on carry-call expressions

require "sorbet-runtime"

require_relative "../ast/type"
require_relative "../ast/ast"

module EscapeAnalysis
    extend T::Sig

  # ── Phase E1 ─────────────────────────────────────────────────────────────

  # Compute the set of functions whose return value is heap-owned.
  # Fixed-point iteration over the call graph.
  # Writes fn.return_provenance = :heap on each discovered function.
  # Returns a frozen Set of function names.
  sig { params(fn_nodes: T::Hash[String, T.untyped]).returns(T::Set[String]) }
  def self.compute_heap_return_fns!(fn_nodes)
    heap_fns = fn_nodes.each_with_object(Set.new) do |(name, fn), s|
      s << name if fn&.return_provenance == :heap
    end

    changed = T.let(true, T::Boolean)
    while changed
      changed = false
      fn_nodes.each do |name, fn|
        next unless fn&.body
        next if heap_fns.include?(name)
        next unless fn_body_returns_heap?(fn, fn_nodes, heap_fns)

        heap_fns << name
        fn.return_provenance = :heap
        changed = true
      end
    end

    heap_fns.freeze
  end

  # ── Phase E2 ─────────────────────────────────────────────────────────────

  # Per-function escape scan: applies all escape conditions to stamp
  # storage/provenance on declaration nodes before CleanupClassifier runs.
  #
  # Escape conditions handled:
  #   1. :always_returned    — collection returned on all paths → heap from start
  #   2. :bg_captured        — list/map/pool/set captured by BG block → heap
  #   3. :heap_ptr_return    — identifier returned from RETURNS %T fn → storage :heap
  #   4. :assign_escape      — frame value (requires_move?) assigned to heap field → storage :heap
  #   5. :loop_carry_string  — string reassigned in mark_per_iter loop → heap
  #   6. :transitive_callee  — declaration value is call to heap-returning fn → provenance :heap
  #   7. :concat_into_heap   — frame string-concat passed into heap container's mutator → heap
  #   8. :takes_arg_escape   — frame collection passed into a TAKES heap-cleanup param → heap
  #                            (INV-1: callee frees with heapAlloc, source must match)
  #
  # Replaces MIRPass#upgrade_loop_string_carries_to_heap!,
  #           MIRPass#upgrade_always_escaped_to_heap!,
  #           MIRPass#upgrade_bg_captures_to_heap!,
  #           MIRPass#upgrade_heap_ptr_returns_to_heap!,
  #           MIRPass#upgrade_assign_escapes_to_heap!.
  # (Condition 6 currently also handled by apply_transitive_heap_promotion! — E3 will remove that.)
  #
  # Must run AFTER E1 (heap_fns) and PromotionClassifier (promotion_plans),
  # BEFORE LoopFrameAnalysis and CleanupClassifier.
  #
  # @param fn_nodes       [Hash]  name -> AST::FunctionDef
  # @param heap_fns       [Set]   function names with heap return_provenance (from E1)
  # @param promotion_plans [Hash] name -> PromotionClassifier plan hash
  # @return [Set<String>] BG-upgraded variable names (for insert_bg_escape_promote! filtering)
  sig { params(fn_nodes: T::Hash[String, T.untyped], heap_fns: T::Set[String], promotion_plans: T::Hash[String, T.untyped]).returns(T::Set[String]) }
  def self.analyze!(fn_nodes, heap_fns:, promotion_plans: {})
    all_bg_upgraded = Set.new

    fn_nodes.each do |name, fn|
      next unless fn&.body
      plan   = promotion_plans[name]
      result = per_fn_scan!(fn, heap_fns, plan, fn_nodes)

      all_bg_upgraded.merge(result[:bg_upgraded])

      # Stamp carry-return metadata so mark_heap_carry_call_sites! can run after.
      if result[:carry_return_vars]&.any?
        fn.heap_carry_return      = true
        fn.heap_carry_return_vars = result[:carry_return_vars]
      end

      # Remove always-escaped vars from promotion plan — no runtime MIR::Promote needed.
      if result[:always_escaped]&.any? && plan.is_a?(Hash) && plan[:var_promotes]
        escaped = result[:always_escaped]
        plan[:var_promotes] = plan[:var_promotes].reject { |vp| escaped.include?(vp[:var]) }
      end
    end

    all_bg_upgraded
  end

  # ── Private helpers ──────────────────────────────────────────────────────

  # E1 helper: check whether any return in fn's body yields a heap value.
  sig { params(fn: AST::FunctionDef, fn_nodes: T::Hash[String, T.untyped], heap_fns: T::Set[String]).returns(T::Boolean) }
  private_class_method def self.fn_body_returns_heap?(fn, fn_nodes, heap_fns)
    returns = []
    AST.walk_body(fn.body) { |n| returns << n if n.is_a?(AST::ReturnNode) }

    returns.any? do |ret|
      next false unless ret.value
      return_expr_is_heap?(ret.value, fn_nodes, heap_fns)
    end
  end

  # E1 helper: true if a return-position expression produces a heap-owned value.
  sig { params(val: T.untyped, fn_nodes: T::Hash[String, T.untyped], heap_fns: T::Set[String]).returns(T::Boolean) }
  private_class_method def self.return_expr_is_heap?(val, fn_nodes, heap_fns)
    callee_name = case val
                  when AST::FuncCall   then val.name
                  when AST::MethodCall then val.name
                  end
    return heap_fns.include?(callee_name) if callee_name

    if val.is_a?(AST::GetField)
      root = T.let(val, AST::GetField)
      root = root.target while root.is_a?(AST::GetField) || root.is_a?(AST::GetIndex)
      if root.is_a?(AST::Identifier) && root.symbol
        decl     = root.symbol.reg
        decl_val = decl&.value
        callee2  = case decl_val
                   when AST::FuncCall   then decl_val.name
                   when AST::MethodCall then decl_val.name
                   end
        if callee2 && heap_fns.include?(callee2)
          ret_type = (Type.new(val.full_type) rescue nil)
          return !!(ret_type&.string? || ret_type&.collection? || ret_type&.map?)
        end
      end
    end

    if val.is_a?(AST::Identifier)
      ti = val.type_info
      ti = ti.is_a?(Type) ? ti : (ti ? (Type.new(ti) rescue nil) : nil)
      return false unless ti.is_a?(Type)
      return !!(ti.needs_escape_promotion? && !ti.string? && !ti.heap_provenance?)
    end

    false
  end

  # ── E2 private helpers ───────────────────────────────────────────────────

  sig { params(fn: AST::FunctionDef, heap_fns: T::Set[String], plan: T::Hash[Symbol, T.untyped], fn_nodes: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
  private_class_method def self.per_fn_scan!(fn, heap_fns, plan, fn_nodes = {})
    bg_upgraded    = Set.new
    always_escaped = Set.new
    carry_ret_vars = Set.new

    # Condition 3 context: does this function return a heap pointer?
    ret_t = fn.return_type
    ret_t = ret_t.is_a?(Type) ? ret_t : (Type.new(ret_t) rescue nil)
    heap_ptr_return = ret_t&.heap?

    # Conditions 1 + 3: collect return nodes once.
    return_nodes = e2_collect_returns(fn.body)

    # Condition 2: BG-captured collection/map/pool/set names.
    bg_names = e2_bg_capture_names(fn)

    # Condition 5: loop carry string names + side-effect promote on reassignment values.
    carry_names = e2_loop_carry_names!(fn)
    carry_ret_vars.merge(e2_carry_return_vars(fn, carry_names))

    # Condition 1: always-returned identifiers from the promotion plan.
    always_ret = if plan.is_a?(Hash) && plan[:var_promotes]&.any?
      plan[:var_promotes].select { |vp|
        return_nodes.all? { |r| r.value && e2_return_refs?(r.value, vp[:var]) }
      }.map { |vp| vp[:var] }.to_set
    else
      Set.new
    end

    # ── Declaration walk (conditions 1, 2, 3, 5, 6) ──
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::VarDecl) || (node.is_a?(AST::BindExpr) && node.mode == :decl)
      vname = node.name.to_s

      if always_ret.include?(vname)
        # Condition 1: always returned — heap storage + provenance on decl AND symbol.
        e2_stamp_full!(node)
        e2_stamp_symbol_via_return_ident!(return_nodes, vname)
        always_escaped << vname

      elsif bg_names.include?(vname)
        # Condition 2: BG-captured collection — heap storage + provenance.
        e2_stamp_full!(node)
        bg_upgraded << vname

      elsif heap_ptr_return
        # Condition 3: RETURNS %T — returned identifiers get storage :heap only
        # (no provenance write; classify_heap_struct_plain consults schema via storage).
        ident = e2_find_return_ident(return_nodes, vname)
        if ident
          sym_ti = ident.symbol&.type
          sym_ti = sym_ti.is_a?(Type) ? sym_ti : (Type.new(sym_ti) rescue nil)
          if sym_ti&.requires_move?
            node.storage = :heap
            ident.symbol.storage = :heap if ident.symbol
          end
        end

      elsif carry_names.include?(vname)
        # Condition 5: loop carry string — heap storage + provenance + upgrade literal value.
        e2_stamp_full!(node)
        val = node.value
        val.storage = :heap if val&.respond_to?(:storage=)
      end

      # Condition 6: transitive callee — declaration value is a heap-returning call.
      # Only stamp provenance (not storage); storage is managed by the node's own type.
      # This runs independently and does NOT skip already-stamped nodes.
      val = node.value
      callee_name = case val
                    when AST::FuncCall   then val.name.to_s
                    when AST::MethodCall then val.name.to_s
                    end
      if callee_name && heap_fns.include?(callee_name)
        ti = node.type_info rescue nil
        ti.provenance = :heap if ti.is_a?(Type) && !ti.heap_provenance?
      end
    end

    # ── Condition 4: assign escape (walk Assignments separately) ──
    # A frame value (requires_move?) assigned to a heap container field must be
    # heap-allocated so it survives beyond the current frame.
    # Storage only; no provenance write (classify_heap_struct_plain uses storage).
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::Assignment)
      rhs = node.value
      next unless rhs.is_a?(AST::Identifier) && rhs.symbol
      next unless [:frame, :stack].include?(rhs.symbol.storage)
      rhs_ti = rhs.symbol.type
      rhs_ti = rhs_ti.is_a?(Type) ? rhs_ti : (Type.new(rhs_ti) rescue nil)
      next unless rhs_ti&.requires_move?
      lhs_root = e2_root_ident(node.name)
      next unless lhs_root.is_a?(AST::Identifier) && lhs_root.symbol
      next unless [:heap, :multiowned, :shared].include?(lhs_root.symbol.storage)
      rhs.symbol.storage = :heap
      decl = rhs.symbol.reg
      decl.storage = :heap if decl&.respond_to?(:storage=)
    end

    # ── Condition 7: frame string-concat escape via heap-container mutator arg ──
    # Pattern:   heap_list.append(Value{ Str: s1 + s2 })
    #            heap_list.append(s1 + s2)
    #            heap_map[k] = Value{ Str: s1 + s2 }    (handled via Assignment in C4,
    #                                                    but the nested concat is still frame)
    #
    # When a string-concat expression (BinaryOp :ADD with string_concat=true) is
    # passed TAKES into a heap container's mutator (append/insert/push), its
    # frame-allocated result dangles after the call returns and the enclosing
    # frame rewinds. Promote the concat to :heap so mir_lowering emits
    # std.mem.concat(heapAlloc, ...) instead of frameAlloc.
    #
    # We walk INSIDE StructLit / UnionVariantLit field values so the common
    # shape `Container.append(Variant{ Str: concat })` is covered too.
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::MethodCall)
      next unless %w[append insert push put].include?(node.name.to_s)
      obj = node.object
      # Receiver must be a collection (Type#collection? covers HashMap /
      # @pool / @list / @set uniformly — the single source of truth).
      next unless obj.symbol
      t = obj.symbol.type
      sym_ti = t.is_a?(Type) ? t : (Type.new(t) rescue nil)
      next unless sym_ti && sym_ti.collection?

      # Only promote for lists whose element type is a user-defined
      # composite (union/struct). For primitive- and String-element lists
      # (e.g. String[]@list), the list's own cleanup is frame-allocated;
      # pushing a heap-allocated string there would leak on deinit. The
      # composite-element case is the one where the list's cleanup is
      # heap-allocated AND will recursively free embedded string fields —
      # so frame strings there are a true UAF and must be promoted.
      elem_t = sym_ti.element_type
      next unless elem_t && !elem_t.primitive? && !elem_t.string?

      node.args.each { |arg| e2_promote_frame_concats!(arg) }
    end

    # ── Condition 8: GIVE-to-TAKES allocator coordination ──
    # When a value is given to a TAKES param of a heap-cleanup type, the
    # callee will free with rt.heapAlloc(). The caller's source binding
    # therefore MUST be heap-allocated, or the alloc identities mismatch
    # at the boundary (silent UB on release; alignment crash on Debug).
    # See CLAUDE.md INV-1 (single allocator per binding lifetime).
    #
    # Closes the bug class documented by transpile-tests 277/278/280:
    # frame-allocated @list/@pool/@set GIVEn to TAKES of the same type.
    e2_walk_calls(fn.body) do |call|
      callee_name = call.name.to_s
      callee_fn = fn_nodes[callee_name]
      next unless callee_fn&.respond_to?(:params) && callee_fn.params

      args = call.args || []
      callee_fn.params.each_with_index do |param, idx|
        next unless param[:takes]
        arg = args[idx]
        next unless arg

        # Unwrap GIVE wrapper to find the source identifier.
        src = arg.is_a?(AST::MoveNode) ? arg.value : arg
        next unless src.is_a?(AST::Identifier) && src.symbol

        # Heap-cleanup-type? Only collections need allocator coordination
        # (string TAKES already auto-COPY via ensure_owned_value!).
        ti = src.symbol.type
        ti = ti.is_a?(Type) ? ti : (Type.new(ti) rescue nil)
        next unless ti && (ti.list_collection? || ti.pool? || ti.set_collection? ||
                           ti.map?)

        # Already heap? Nothing to do.
        next if [:heap, :multiowned, :shared].include?(src.symbol.storage)

        # Promote the source binding to heap so the callee's heapAlloc-bound
        # cleanup matches.
        src.symbol.storage = :heap
        decl = src.symbol.reg
        decl.storage = :heap if decl.respond_to?(:storage=)
        ti.provenance = :heap if ti.respond_to?(:provenance=) && !ti.heap_provenance?
      end
    end

    # ── Condition 9: MUTABLE @list arg crosses a frame boundary ──
    # When a `@list` is passed to a MUTABLE @list parameter, the callee
    # treats the receiver as pointer-passed (see needs_pointer_passing?
    # + the call-site routing in mir_lowering.rb). Inside the callee,
    # any `.append` allocates the growth buffer; if the receiver's
    # storage is :frame, the `:receiver_storage` resolver picks the
    # callee's frameAlloc(). The buffer's lifetime is then bounded by
    # the *callee's* frame mark (rewound on return), and the caller's
    # `items.items.ptr` is dangling -- subsequent allocations corrupt
    # the buffer or the next `.append` segfaults.
    #
    # Promote the caller's binding to :heap at the decl so the buffer
    # outlives any frame, and the cleanup uses heapAlloc consistently.
    e2_walk_calls(fn.body) do |call|
      callee_name = call.name.to_s
      callee_fn = fn_nodes[callee_name] || fn_nodes[callee_name.to_sym]
      next unless callee_fn&.respond_to?(:params) && callee_fn.params

      args = call.args || []
      callee_fn.params.each_with_index do |param, idx|
        next unless param[:mutable]
        param_t = param[:type]
        param_t = param_t.is_a?(Type) ? param_t : (Type.new(param_t) rescue nil)
        next unless param_t && param_t.list_collection?

        arg = args[idx]
        next unless arg.is_a?(AST::Identifier) && arg.symbol

        next if [:heap, :multiowned, :shared].include?(arg.symbol.storage)

        ti = arg.symbol.type
        ti = ti.is_a?(Type) ? ti : (Type.new(ti) rescue nil)
        next unless ti && ti.list_collection?

        arg.symbol.storage = :heap
        decl = arg.symbol.reg
        decl.storage = :heap if decl.respond_to?(:storage=)
        ti.provenance = :heap if ti.respond_to?(:provenance=) && !ti.heap_provenance?
      end
    end

    { bg_upgraded: bg_upgraded, always_escaped: always_escaped, carry_return_vars: carry_ret_vars }
  end

  # Recursively promote frame string-concat expressions to heap storage.
  # Handles concats nested inside union/struct literals (and list literals)
  # passed as mutator arguments to heap-owned containers. Returns true if
  # any promotion happened — caller uses that to cascade-promote the
  # receiver container.
  sig { params(node: T.untyped).returns(T::Boolean) }
  private_class_method def self.e2_promote_frame_concats!(node)
    return false unless node
    case node
    when AST::BinaryOp
      promoted = T.let(false, T::Boolean)
      if node.op == :ADD && node.string_concat
        node.storage = :heap
        ti = node.type_info
        ti.provenance = :heap if ti.is_a?(Type)
        promoted = true
      end
      promoted |= e2_promote_frame_concats!(node.left)
      promoted |= e2_promote_frame_concats!(node.right)
      promoted
    when AST::StringConcat
      node.storage = :heap
      node.parts&.each { |p| e2_promote_frame_concats!(p) }
      true
    when AST::StructLit, AST::UnionVariantLit
      promoted = T.let(false, T::Boolean)
      node.fields&.each_value { |v| promoted |= e2_promote_frame_concats!(v) }
      promoted
    when AST::ListLit
      promoted = T.let(false, T::Boolean)
      node.items.each { |it| promoted |= e2_promote_frame_concats!(it) }
      promoted
    else
      false
    end
  end

  # Collect all ReturnNode descendants in body.
  sig { params(body: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
  private_class_method def self.e2_collect_returns(body)
    nodes = []
    AST.walk_body(body) { |n| nodes << n if n.is_a?(AST::ReturnNode) }
    nodes
  end

  # Yield every FuncCall / MethodCall reachable from body — including those
  # nested in expressions (VarDecl/BindExpr/Assignment values, ReturnNode
  # values, struct/list/hash literal fields, control-flow conditions). Used
  # by Condition 8.
  sig { params(body: T::Array[T.untyped], blk: T.untyped).returns(T.nilable(T::Array[T.untyped])) }
  private_class_method def self.e2_walk_calls(body, &blk)
    AST.walk_body(body) { |stmt| e2_walk_calls_in_expr(stmt, &blk) }
  end

  sig { params(node: T.untyped, blk: T.untyped).returns(T.untyped) }
  private_class_method def self.e2_walk_calls_in_expr(node, &blk)
    return unless node
    case node
    when AST::FuncCall
      yield node
      node.args.each { |a| e2_walk_calls_in_expr(a, &blk) }
    when AST::MethodCall
      yield node
      e2_walk_calls_in_expr(node.object, &blk)
      node.args.each { |a| e2_walk_calls_in_expr(a, &blk) }
    when AST::VarDecl, AST::BindExpr, AST::Assignment
      e2_walk_calls_in_expr(node.value, &blk)
    when AST::ReturnNode
      e2_walk_calls_in_expr(node.value, &blk)
    when AST::MoveNode, AST::CopyNode, AST::CloneNode, AST::FreezeNode, AST::ShareNode, AST::CapabilityWrap
      e2_walk_calls_in_expr(node.value, &blk)
    when AST::BinaryOp
      e2_walk_calls_in_expr(node.left, &blk)
      e2_walk_calls_in_expr(node.right, &blk)
    when AST::UnaryOp
      e2_walk_calls_in_expr(node.right, &blk)
    when AST::GetField
      e2_walk_calls_in_expr(node.target, &blk)
    when AST::GetIndex
      e2_walk_calls_in_expr(node.target, &blk)
      e2_walk_calls_in_expr(node.index, &blk)
    when AST::StructLit
      node.fields&.each_value { |v| e2_walk_calls_in_expr(v, &blk) }
    when AST::ListLit
      node.items.each { |i| e2_walk_calls_in_expr(i, &blk) }
    when AST::IfStatement
      e2_walk_calls_in_expr(node.condition, &blk)
    when AST::WhileLoop
      e2_walk_calls_in_expr(node.condition, &blk)
    when AST::MatchStatement
      e2_walk_calls_in_expr(node.expr, &blk)
    end
  end

  # Collect names of BG-captured variables that need heap promotion at
  # their declaration site. Reads `bg.capture_analysis.heap_promote_names`
  # (computed once by BgCaptureClassifier in the annotator).
  #
  # Previously this re-walked every BG body (via e2_each_bg + helpers)
  # with its own per-type filter, duplicating effort that
  # CaptureStrategy.classify already performs. Now there is one writer
  # (BgCaptureClassifier) and one reader (this method).
  sig { params(fn: AST::FunctionDef).returns(T::Set[String]) }
  private_class_method def self.e2_bg_capture_names(fn)
    names = Set.new
    AST.each_bg_block(fn.body) do |bg|
      names.merge(bg.capture_analysis&.heap_promote_names || [])
    end
    names
  end

  # Find string variables reassigned inside loops that will have mark_per_iter.
  # Side effect: calls LoopFrameAnalysis.promote_value_to_heap! on each carry value.
  sig { params(fn: AST::FunctionDef).returns(T::Set[String]) }
  private_class_method def self.e2_loop_carry_names!(fn)
    carry_names = Set.new
    AST.walk_body(fn.body) do |node|
      body = case node
             when AST::WhileLoop then (node.tight ? nil : node.do_branch)
             when AST::ForRange  then node.body
             when AST::ForEach   then node.body
             end
      next unless body

      local_names  = LoopFrameAnalysis.collect_local_names(body)
      non_escaping = LoopFrameAnalysis.local_frame_decls(body, local_names).reject { |d|
        LoopFrameAnalysis.escapes_to_outer?(d.name.to_s, body, local_names)
      }
      next unless non_escaping.any?  # only when loop WILL have mark_per_iter

      AST.walk_body(body) do |bind|
        next unless bind.is_a?(AST::BindExpr) && bind.mode == :assign
        next unless bind.name.is_a?(String) && !local_names.include?(bind.name)
        ti = bind.type_info rescue nil
        next unless ti.is_a?(Type)
        # Outer-binding reassign in a mark_per_iter loop. Strings need
        # promotion regardless of initial provenance (a `last: String = ""`
        # outer var with rodata provenance still gets re-bound to a
        # frame concat result — Cond 5 promotes `last` to heap).
        # Allocator-backed containers (escape_class :slice_managed)
        # need promotion too, except numeric_map (AutoHashMapUnmanaged
        # is pure arena-allocated; legacy carve-out preserved).
        if ti.string?
          carry_names << bind.name
          LoopFrameAnalysis.promote_value_to_heap!(bind.value)
        elsif ti.escape_class == :slice_managed && !ti.numeric_map?
          # Local allocator-backed container (list/set/map/pool) assigned to an outer variable.
          # When the loop rewinds the frame between iterations, the local's backing
          # buffer is freed but the outer variable still holds it → use-after-free.
          # Fix: promote BOTH the local decl AND the outer variable to heap.
          # The outer variable must also be heap so its reassignment cleanup uses heapAlloc().
          rhs = bind.value
          next unless rhs.is_a?(AST::Identifier) && local_names.include?(rhs.name)
          # Promote the loop-local declaration.
          AST.walk_body(body) do |local_decl|
            next unless (local_decl.is_a?(AST::VarDecl) || (local_decl.is_a?(AST::BindExpr) && local_decl.mode == :decl)) && local_decl.name.to_s == rhs.name
            local_decl.storage = :heap
            decl_ti = local_decl.type_info rescue nil
            decl_ti = Type.new(decl_ti) if decl_ti && !decl_ti.is_a?(Type)
            decl_ti.provenance = :heap if decl_ti.is_a?(Type)
            if rhs.symbol
              rhs.symbol.storage = :heap
              sym_reg = rhs.symbol.reg
              sym_reg.storage = :heap if sym_reg&.respond_to?(:storage=)
            end
          end
          # Promote the outer variable's declaration so its cleanup uses heapAlloc().
          outer_name = bind.name
          AST.walk_body(fn.body) do |outer_decl|
            next unless (outer_decl.is_a?(AST::VarDecl) || (outer_decl.is_a?(AST::BindExpr) && outer_decl.mode == :decl)) && outer_decl.name.to_s == outer_name
            outer_decl.storage = :heap
            outer_ti = outer_decl.type_info rescue nil
            outer_ti = Type.new(outer_ti) if outer_ti && !outer_ti.is_a?(Type)
            outer_ti.provenance = :heap if outer_ti.is_a?(Type)
            outer_decl.symbol.storage = :heap if outer_decl.symbol
          end
        end
      end
    end
    carry_names
  end

  # Returns carry variable names that are directly returned (for heap_carry_return metadata).
  sig { params(fn: AST::FunctionDef, carry_names: T::Set[String]).returns(T::Set[String]) }
  private_class_method def self.e2_carry_return_vars(fn, carry_names)
    return Set.new if carry_names.empty?
    ret_t = fn.return_type
    ret_t = ret_t.is_a?(Type) ? ret_t : (Type.new(ret_t) rescue nil)
    # Unwrap `!T` so `RETURNS !String` correctly matches the carry-string
    # path. Without this, fns with the post-#338 fallible signature don't
    # get fn.heap_carry_return = true, which leaves callers without a
    # cleanup defer for the heap-allocated returned string.
    if ret_t&.error_union? && ret_t.payload_type
      ret_t = ret_t.payload_type
    end
    return Set.new unless ret_t&.string?
    result = Set.new
    AST.walk_body(fn.body) do |node|
      next unless node.is_a?(AST::ReturnNode) && node.value.is_a?(AST::Identifier)
      result << node.value.name if carry_names.include?(node.value.name)
    end
    result
  end

  # True if a return-position expression references the named variable.
  sig { params(node: T.untyped, var_name: String).returns(T::Boolean) }
  private_class_method def self.e2_return_refs?(node, var_name)
    case node
    when AST::Identifier then node.name == var_name
    when AST::StructLit, AST::UnionVariantLit
      node.fields.any? { |_, fval| e2_return_refs?(fval, var_name) }
    else false
    end
  end

  # Find the first Identifier matching var_name across all return node values.
  sig { params(return_nodes: T::Array[T.untyped], var_name: String).returns(T.untyped) }
  private_class_method def self.e2_find_return_ident(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value
      ident = e2_extract_ident(ret.value, var_name)
      return ident if ident
    end
    nil
  end

  sig { params(node: T.untyped, var_name: String).returns(T.nilable(AST::Identifier)) }
  private_class_method def self.e2_extract_ident(node, var_name)
    case node
    when AST::Identifier
      node.name == var_name ? node : nil
    when AST::StructLit, AST::UnionVariantLit
      node.fields.each_value { |v| r = e2_extract_ident(v, var_name); return r if r }
      nil
    else nil
    end
  end

  # Set both storage and provenance to :heap on a declaration node.
  sig { params(node: T.untyped).returns(T.nilable(Symbol)) }
  private_class_method def self.e2_stamp_full!(node)
    node.storage = :heap if node.respond_to?(:storage=)
    ti = node.type_info rescue nil
    ti.provenance = :heap if ti.is_a?(Type)
  end

  # Also stamp the SymbolEntry (scope entry) reached via the return identifier.
  sig { params(return_nodes: T::Array[T.untyped], var_name: String).returns(T::Array[T.untyped]) }
  private_class_method def self.e2_stamp_symbol_via_return_ident!(return_nodes, var_name)
    return_nodes.each do |ret|
      next unless ret.value
      ident = e2_extract_ident(ret.value, var_name)
      next unless ident&.symbol
      ident.symbol.storage = :heap
      sym_type = ident.symbol.type
      sym_type.provenance = :heap if sym_type.is_a?(Type)
    end
  end

  # Extract the root Identifier from a field/index chain (for assign_escape LHS).
  sig { params(node: T.untyped).returns(T.nilable(AST::Identifier)) }
  private_class_method def self.e2_root_ident(node)
    case node
    when AST::GetField, AST::GetIndex then e2_root_ident(node.target)
    when AST::Identifier              then node
    else nil
    end
  end

  # ── Phase E3 ─────────────────────────────────────────────────────────────

  # E3a: Propagate heap return_provenance from callees to caller binding type_info.
  # Must run BEFORE PromotionClassifier so HPT downgrade sees stable provenance.
  # Replaces MIRPass#apply_transitive_heap_promotion!
  #
  # @param fn_nodes [Hash]  name -> AST::FunctionDef
  # @param heap_fns [Set]   function names with heap return_provenance (from E1)
  sig { params(fn_nodes: T::Hash[String, T.untyped], heap_fns: T::Set[String]).returns(T::Hash[String, T.untyped]) }
  def self.tag_transitive_provenance!(fn_nodes, heap_fns)
    fn_nodes.each do |_name, fn|
      next unless fn&.body
      AST.walk_body(fn.body) do |node|
        case node
        when AST::VarDecl, AST::BindExpr
          val = node.value
          callee_name = val.is_a?(AST::FuncCall) ? val.name.to_s : nil
          next unless callee_name && heap_fns.include?(callee_name)
          T.must(node.type_info).provenance = :heap if node.type_info.is_a?(Type)
          if node.is_a?(AST::BindExpr) && node.mode == :assign
            decl = e3_find_decl(fn.body, node.name)
            decl.type_info.provenance = :heap if decl&.type_info.is_a?(Type)
          end
        when AST::Assignment
          val = node.value
          callee_name = val.is_a?(AST::FuncCall) ? val.name.to_s : nil
          next unless callee_name && heap_fns.include?(callee_name)
          sym = node.name.symbol
          decl = sym&.reg
          decl.type_info.provenance = :heap if decl&.type_info.is_a?(Type)
        end
      end
    end
  end

  # E3c: Propagate caller arg sync (and Arc-storage) into callee param
  # SymbolEntry. Two axes flow with the same all-callers-agree rule:
  #   - sync     (:locked / :write_locked / :always_mutable)
  #   - storage  (:shared / :multiowned for Arc/Rc-wrapped bindings)
  # The storage axis is what mir_lowering needs to emit Arc unwrap
  # (`x.ctrl.data.*` vs `x`) at WITH/field-access sites. Sync drives the
  # acquire/release method choice. Runs to fixed point so transitive calls
  # also pick up both axes.
  #
  # Rule: a param with no caller-derived value (and no explicit declared
  # value) adopts a caller's value iff every observed caller passes the
  # same non-nil value. Disagreement leaves the param at its current
  # value. Params with declared sync (legacy) are not overwritten.
  #
  # @param fn_nodes [Hash]  name -> AST::FunctionDef
  sig { params(fn_nodes: T::Hash[String, T.untyped]).returns(T.untyped) }
  def self.propagate_caller_sync!(fn_nodes)
    return if fn_nodes.empty?

    # Index callsites: callee_name => [{ args: }, ...].
    # AST.walk_body only visits top-level statements, not expression
    # sub-trees, so a `let x = foo(...)` would miss the FuncCall. Walk
    # every Locatable descendant.
    callsites = Hash.new { |h, k| h[k] = [] }
    fn_nodes.each do |_, caller_fn|
      next unless caller_fn&.body
      collect_callsites_deep(caller_fn.body, callsites)
    end

    max_iters = 8
    max_iters.times do
      changed = T.let(false, T::Boolean)
      fn_nodes.each do |callee_name, callee_fn|
        next unless callee_fn&.params
        sites = callsites[callee_name]
        next if sites.empty?

        callee_fn.params.each_with_index do |param, idx|
          entry = param[:symbol]
          next unless entry

          # ── sync axis ────────────────────────────────────────────────
          unless entry.sync && param_sync_was_declared?(param)
            unified = unify_caller_attr(sites, idx) { |s| s&.sync }
            if unified && entry.sync != unified && param_accepts_caller_sync?(callee_fn, param, unified)
              entry.sync = unified
              changed = true
            end
          end

          # ── storage axis (Arc / Rc) ──────────────────────────────────
          # We're trying to detect "this binding is Arc/Rc-wrapped" so
          # the callee's lowering knows to emit `x.ctrl.data.*` unwrap.
          # For struct types, that fact lives on entry.storage (:shared /
          # :multiowned). For collection types, finalize_storage maps
          # @shared:locked + collection to :heap, so the wrapping fact
          # lives on entry.type.ownership instead. Check both axes.
          unified_storage = unify_caller_attr(sites, idx) do |s|
            next s.storage if s&.storage == :shared || s&.storage == :multiowned
            t = s&.type
            if t.is_a?(Type)
              next :shared     if t.respond_to?(:shared?)     && t.shared?
              next :multiowned if t.respond_to?(:multiowned?) && t.multiowned?
            end
            nil
          end
          if unified_storage && entry.storage != unified_storage
            entry.storage = unified_storage
            changed = true
          end
        end
      end
      break unless changed
    end
  end

  # Walk every Locatable descendant (incl. expression sub-trees), record
  # FuncCalls.
  sig { params(body: T::Array[T.untyped], callsites: T::Hash[String, T::Array[T.untyped]]).returns(T.untyped) }
  private_class_method def self.collect_callsites_deep(body, callsites)
    stack = body.is_a?(Array) ? body.dup : [body]
    until stack.empty?
      node = stack.pop
      next unless node.is_a?(AST::Locatable)
      if node.is_a?(AST::FuncCall)
        T.must(callsites[node.name.to_s]) << { args: node.args }
      end
      next if node.is_a?(AST::FunctionDef) || node.is_a?(AST::LambdaLit)
      node.class.members.each do |m|
        v = node[m]
        if v.is_a?(Array)
          v.each { |c| stack.push(c) if c.is_a?(AST::Locatable) }
        elsif v.is_a?(AST::Locatable)
          stack.push(v)
        end
      end
    end
  end

  # Most-general unifier: returns the single non-nil value when every
  # callsite's arg projects to the same value, else nil.
  sig { params(sites: T::Array[T::Hash[T.untyped, T.untyped]], idx: Integer, project: T.untyped).returns(T.nilable(Symbol)) }
  private_class_method def self.unify_caller_attr(sites, idx, &project)
    observed = sites.map do |site|
      arg = site[:args][idx]
      next nil unless arg && arg.respond_to?(:symbol)
      project.call(arg.symbol)
    end
    return nil if observed.empty?
    unique = observed.uniq
    (unique.length == 1 && unique.first) ? unique.first : nil
  end

  # True when the param's declared type carried explicit sync (so the
  # entry.sync currently reflects an annotation, not a propagated value).
  sig { params(param: T::Hash[Symbol, T.untyped]).returns(T.nilable(T::Boolean)) }
  private_class_method def self.param_sync_was_declared?(param)
    t = param[:type]
    t.is_a?(Type) && t.any_sync?
  end

  sig { params(fn_node: AST::FunctionDef, param: T::Hash[Symbol, T.untyped], sync: Symbol).returns(T::Boolean) }
  private_class_method def self.param_accepts_caller_sync?(fn_node, param, sync)
    t = param[:type]
    return true if t.is_a?(Type) && (t.shared? || t.any_sync?)
    return true unless sync == :atomic

    requires = fn_node.respond_to?(:requires) ? fn_node.requires : nil
    families = requires && requires[param[:name].to_s]
    return false unless families.respond_to?(:include?)

    case sync
    when :atomic
      families.include?(:ATOMIC) || families.include?(:SNAPSHOTTED)
    when :versioned
      families.include?(:VERSIONED) || families.include?(:SNAPSHOTTED)
    when :locked
      families.include?(:LOCKED)
    when :write_locked
      families.include?(:LOCKED)
    when :local
      families.include?(:LOCAL)
    else
      false
    end
  end

  # E3b: Stamp heap provenance on call expressions that call heap-carry-return functions.
  # Must run AFTER E2 (which sets fn.heap_carry_return) and BEFORE CleanupClassifier.
  # Replaces MIRPass#mark_heap_carry_call_sites!
  #
  # @param fn_nodes [Hash]  name -> AST::FunctionDef
  sig { params(fn_nodes: T::Hash[String, T.untyped]).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def self.tag_carry_call_sites!(fn_nodes)
    carry_fns = fn_nodes.each_with_object(Set.new) do |(_, fn), s|
      s << fn.name.to_s if fn.respond_to?(:heap_carry_return) && fn.heap_carry_return
    end
    return if carry_fns.empty?

    fn_nodes.each do |_name, fn|
      next unless fn&.body
      AST.walk_body(fn.body) do |stmt|
        if stmt.is_a?(AST::VarDecl) || (stmt.is_a?(AST::BindExpr) && stmt.mode == :decl)
          val = stmt.value
          if val.is_a?(AST::FuncCall) || val.is_a?(AST::MethodCall)
            fn_name = val.name.to_s
            if carry_fns.include?(fn_name)
              call_ti = val.type_info rescue nil
              call_ti.provenance = :heap if call_ti.is_a?(Type) && !call_ti.heap_provenance?
              bind_ti = stmt.type_info rescue nil
              bind_ti.provenance = :heap if bind_ti.is_a?(Type) && !bind_ti.heap_provenance?
              bt2 = stmt.full_type
              bt2.provenance = :heap if bt2.is_a?(Type) && !bt2.heap_provenance?
            end
          end
          next
        end
        e3_top_level_exprs(stmt).each { |e| e3_mark_carry_expr!(e, carry_fns) }
      end
    end
  end

  sig { params(body: T::Array[T.untyped], var_name: String).returns(T.untyped) }
  private_class_method def self.e3_find_decl(body, var_name)
    return nil unless body
    body.each do |node|
      case node
      when AST::VarDecl  then return node if node.name == var_name
      when AST::BindExpr then return node if node.name == var_name && node.mode == :decl
      end
    end
    nil
  end

  sig { params(stmt: T.untyped).returns(T::Array[T.untyped]) }
  private_class_method def self.e3_top_level_exprs(stmt)
    case stmt
    when AST::VarDecl, AST::BindExpr then [stmt.value]
    when AST::Assignment              then [stmt.value]
    when AST::ReturnNode              then [stmt.value]
    when AST::Assert                  then [stmt.condition, stmt.message]
    when AST::FuncCall, AST::MethodCall then [stmt]
    when AST::IfStatement             then [stmt.condition]
    when AST::MatchStatement          then [stmt.expr]
    when AST::ForEach                 then [stmt.collection]
    else []
    end.compact
  end

  sig { params(node: T.untyped, carry_fns: T::Set[String]).returns(T.nilable(T::Array[T.untyped])) }
  private_class_method def self.e3_mark_carry_expr!(node, carry_fns)
    return unless node
    case node
    when AST::FuncCall
      if carry_fns.include?(node.name.to_s)
        ti = node.type_info rescue nil
        ti.provenance = :heap if ti.is_a?(Type) && !ti.heap_provenance?
      end
      node.args.each { |a| e3_mark_carry_expr!(a, carry_fns) }
    when AST::MethodCall
      if carry_fns.include?(node.name.to_s)
        ti = node.type_info rescue nil
        ti.provenance = :heap if ti.is_a?(Type) && !ti.heap_provenance?
      end
      e3_mark_carry_expr!(node.object, carry_fns)
      node.args.each { |a| e3_mark_carry_expr!(a, carry_fns) }
    when AST::BinaryOp
      e3_mark_carry_expr!(node.left, carry_fns)
      e3_mark_carry_expr!(node.right, carry_fns)
    when AST::UnaryOp
      e3_mark_carry_expr!(node.right, carry_fns)
    when AST::GetField then e3_mark_carry_expr!(node.target, carry_fns)
    when AST::GetIndex
      e3_mark_carry_expr!(node.target, carry_fns)
      e3_mark_carry_expr!(node.index, carry_fns)
    end
  end
end
