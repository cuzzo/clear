# fsm_transform.rb -- Universal CPS transform for FSM-eligible BG bodies.
#
# Per CLAUDE.md Invariant 13, FSM emission is ONE general transform.
# Submodules:
#
#   FsmTransform::Segments           -- shared tail variants (Done /
#                                        Goto / LoopBack / CondBranch /
#                                        Io|Next|LockSuspend)
#   FsmTransform::RecursiveSplitter  -- AST -> segment graph (handles
#                                        nested WhileLoop / ForRange /
#                                        IF / WithBlock containing
#                                        suspends)
#   FsmTransform::Liveness           -- live-variable analysis across
#                                        segment boundaries
#                                        (cross-segment vars become
#                                        ctx struct fields)
#   FsmTransform::SuspendResolvers   -- per-suspend-kind resolvers
#                                        producing MIR::SuspendDescriptor
#                                        for IO and NEXT
#   FsmTransform::Emit               -- MIR-typed state-machine
#                                        builder that turns segments
#                                        + liveness into an
#                                        FsmGenericBody (LockSuspend
#                                        expansion lives here)
#
# Adding a new suspend kind = new Segments tail variant + new
# resolver in SuspendResolvers (or expansion in Emit for fan-out
# kinds like LOCK). NEVER a new top-level emit function.

require_relative "fsm_transform/segments"
require_relative "fsm_transform/recursive_splitter"
require_relative "fsm_transform/liveness"
require_relative "fsm_transform/suspend_resolvers"
require_relative "fsm_transform/emit"

module FsmTransform
  module_function

  # Public entry. Given a BG block and the surrounding lowering
  # context (captures, runtime, etc.), produce an MIR::FsmGenericBody
  # for the wrapper emitter to render.
  #
  # Returns nil when the body falls outside the transform's coverage
  # for the current stage (e.g. contains a WHILE with a suspend
  # in its body during Stage 1). The caller falls back to the
  # legacy per-shape emitter for those cases. As stages land, the
  # nil-returning path shrinks until it disappears.
  #
  # ctx is a hash with keys:
  #   :node, :captured, :capture_close_zig, :pointer_captures,
  #   :bg_string_promotes, :alloc_var, :promise_var, :ctx_var,
  #   :promoted_decls, :capture_inits, :rt_name, :pin_mode,
  #   :inner_zig, :is_void, :arena_init_flag, :id, :bg_rt,
  #   :ctx_type, :promise_zig, :blk_label, :capture_fields
  def transform(bg_block, ctx, lowering)
    suspend_points = bg_block.fsm_suspend_points || []

    # The recursive splitter + Emit.build_recursive is the SOLE
    # FSM emit path. Any FSM-eligible body flows through it,
    # including pure-compute (B1) bodies (a 1-state FSM that runs
    # + signals wg.done) and bodies with mixed suspend kinds
    # (WITH+IO, IO+WITH, IF/loop containing suspends). When the
    # transform returns nil, the BgBlock lowering falls back to
    # stackful (the body could not be lowered as an FSM).
    #
    # Conservative promotion is required when the body contains
    # control-flow that hides reads from Liveness:
    #   * WithBlock -- CS body lowers at LockSuspend expansion
    #     time, after Liveness has already run.
    #   * IF / WHILE / FOR with a suspend in scope -- cond_ast is
    #     rendered to a Zig string at split time so identifier
    #     reads in the cond are invisible to Liveness's MIR walk.
    # Pure linear bodies (NEXT chains, single IO + post-stmts) go
    # through Liveness cleanly; conservative promotion would
    # over-promote unused locals.
    need_conservative = body_needs_conservative?(bg_block.body)
    all_locals = need_conservative ? collect_body_locals(bg_block.body) : []
    # All names get capture_map entries so body refs lower to
    # `__ctx.NAME`. Suspend-result decls (`r = NEXT p`, etc.) are
    # already declared as ctx fields by their suspend descriptor's
    # ctx_field_decls, so omit them from the field-decl list to
    # avoid duplicate struct members.
    promoted_names = all_locals.map { |p| p[:name] }
    field_locals   = all_locals.reject { |p| p[:is_suspend_result] }
    captured_map   = (ctx[:captured] || {}).keys.to_a
    ctx_id         = ctx[:id]
    promo_capture_map = (captured_map + promoted_names).to_h { |n|
      [n, "__ctx_#{ctx_id}.#{n}"]
    }
    rec_segs = lowering.with_fiber_capture_map(promo_capture_map, rt_override: ctx[:bg_rt]) do
      RecursiveSplitter.split(bg_block.body, lowering, ctx: ctx)
    end
    return nil if rec_segs.nil?

    # Phase A's enumerated suspends must match what the splitter
    # found at the segment-graph level. Mismatch means a suspend is
    # nested inside a user fn call (e.g. `BG { doWrite(...) }` where
    # doWrite calls writeFile) -- the body must fall back to
    # stackful.
    expected = suspend_points.length
    io_next_count = rec_segs.count { |s|
      s.tail.is_a?(Segments::IoSuspend) ||
        s.tail.is_a?(Segments::NextSuspend)
    }
    # Multi-cap WITH produces N LockSuspend specs (one per cap) but
    # Phase A enumeration counts the WITH as a single :lock suspend.
    # Collapse on with_node identity so the counts align.
    lock_with_nodes = rec_segs.filter_map { |s|
      s.tail.is_a?(Segments::LockSuspend) ? s.tail.with_node : nil
    }.uniq
    actual = io_next_count + lock_with_nodes.length
    return nil if expected != actual

    liveness = Liveness.analyze(rec_segs, ctx)
    ext_ctx = (ctx[:extra_ctx_fields] || []) +
              field_locals.map { |p| "#{p[:name]}: #{p[:zig_type]} = undefined," }
    Emit.build_recursive(
      ctx.merge(extra_ctx_fields: ext_ctx,
                recursive_promoted_names: promoted_names),
      rec_segs, liveness, lowering,
    )
  end

  # Recursively walk the BG body collecting every VarDecl /
  # BindExpr(:decl) name and its Zig type. The recursive splitter
  # promotes all of them to ctx fields so reads/writes across
  # segment boundaries resolve via the capture_map. Returns
  # `[{ name:, zig_type: }, ...]` (deduped on name).
  def collect_body_locals(stmts)
    out = []
    seen = {}
    visit = lambda do |node|
      case node
      when Array
        node.each { |n| visit.call(n) }
      when AST::VarDecl
        entry = local_entry(node.name, node.full_type || node.type || node.value&.full_type)
        if entry && !seen[entry[:name]]
          seen[entry[:name]] = true
          out << entry
        end
        visit.call(node.value) if node.value
      when AST::BindExpr
        if node.mode == :decl
          entry = local_entry(node.name, node.full_type || node.type || node.value&.full_type)
          if entry && !seen[entry[:name]]
            seen[entry[:name]] = true
            # Mark suspend-result decls so the caller can include
            # them in the capture_map (so body refs become
            # __ctx.NAME) but skip them from the ctx field-decl
            # list (the suspend descriptor's ctx_field_decls
            # already declares the field; emitting it again would
            # be a duplicate struct member).
            entry[:is_suspend_result] = true if suspend_value?(node.value)
            out << entry
          end
        end
        visit.call(node.value) if node.value
      when AST::WhileLoop
        visit.call(node.do_branch)
      when AST::WhileBindLoop
        visit.call(node.do_branch)
      when AST::ForRange
        if node.var_name && !seen[node.var_name]
          seen[node.var_name] = true
          out << { name: node.var_name, zig_type: "i64" }
        end
        visit.call(node.body)
      when AST::ForEach
        if node.var_name && !seen[node.var_name]
          ct_obj = node.collection&.full_type
          ct = ct_obj.is_a?(Type) ? ct_obj : (ct_obj ? Type.new(ct_obj) : nil)
          # Defer to the FSM ForEach descriptor for the bound var
          # type (map's `k` is the KEY type, not element_type which
          # is the value type). Falls back to element_type for
          # collections that don't set var_zig_type.
          desc = ct.respond_to?(:fsm_foreach_descriptor) ?
                   ct.fsm_foreach_descriptor : nil
          elem_zig = (desc && desc[:var_zig_type]) || begin
            elem_t = ct&.respond_to?(:element_type) ? ct.element_type : nil
            elem_t ? Type.new(elem_t).zig_type : "anyopaque"
          end
          seen[node.var_name] = true
          out << { name: node.var_name, zig_type: elem_zig }
        end
        visit.call(node.body)
      when AST::IfStatement
        visit.call(node.then_branch)
        visit.call(node.else_branch) if node.else_branch
      when AST::WithBlock
        visit.call(node.body)
      end
    end
    visit.call(stmts)
    out
  end

  # True if the BG body contains a WithBlock or an IF/WHILE/FOR
  # whose subtree contains a suspend. In those shapes the recursive
  # splitter renders cond_ast as a Zig STRING (or stashes the CS
  # body) at split time, hiding identifier reads from Liveness.
  # Falling back to "promote everything" guarantees correctness;
  # purely linear bodies skip this and let Liveness over-promote
  # nothing.
  def body_needs_conservative?(stmts)
    Array(stmts).any? do |s|
      case s
      when AST::WithBlock then true
      when AST::WhileLoop, AST::WhileBindLoop
        contains_suspend_anywhere?(s.do_branch) ||
          body_needs_conservative?(s.do_branch)
      when AST::ForRange, AST::ForEach
        contains_suspend_anywhere?(s.body) ||
          body_needs_conservative?(s.body)
      when AST::IfStatement
        contains_suspend_anywhere?(s.then_branch) ||
          contains_suspend_anywhere?(s.else_branch || []) ||
          body_needs_conservative?(s.then_branch) ||
          body_needs_conservative?(s.else_branch || [])
      else false
      end
    end
  end

  def contains_suspend_anywhere?(stmts)
    Array(stmts).any? do |s|
      next true if Segments.classify_suspend(s)
      case s
      when AST::WhileLoop, AST::WhileBindLoop then contains_suspend_anywhere?(s.do_branch)
      when AST::ForRange, AST::ForEach then contains_suspend_anywhere?(s.body)
      when AST::WithBlock then true
      when AST::IfStatement
        contains_suspend_anywhere?(s.then_branch) ||
          contains_suspend_anywhere?(s.else_branch || [])
      else false
      end
    end
  end

  # True if this BindExpr/VarDecl value is a suspend whose result is
  # already added to the ctx by the suspend descriptor's
  # ctx_field_decls. Used by collect_body_locals to avoid
  # double-declaring the result var.
  def suspend_value?(value)
    return true if value.is_a?(AST::NextExpr)
    return false unless value.is_a?(AST::FuncCall) || value.is_a?(AST::MethodCall)
    md = value.matched_stdlib_def
    !!(md && md[:suspends] && md[:fsm_setup])
  end

  def local_entry(name, type_obj)
    return nil if name.nil?
    t = type_obj ? Type.new(type_obj) : nil
    zig_t = t ? t.zig_type : "anyopaque"
    { name: name, zig_type: zig_t }
  end
end
