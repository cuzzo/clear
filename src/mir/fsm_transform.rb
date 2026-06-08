# typed: strict
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
  extend T::Sig
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
  #   :alloc_var, :promise_var, :ctx_var,
  #   :promoted_decls, :capture_inits, :rt_name, :pin_mode,
  #   :inner_zig, :is_void, :arena_init_flag, :id, :bg_rt,
  #   :ctx_type, :promise_zig, :blk_label, :capture_fields
  sig { params(bg_block: T.untyped, ctx: T.untyped, lowering: T.untyped).returns(T.nilable(MIR::FsmLoweringResult)) }
  def transform(bg_block, ctx, lowering)
    T.bind(self, T.untyped) rescue nil
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
    segments = rec_segs.segments

    # Phase A's enumerated suspends must match what the splitter
    # found at the segment-graph level. Mismatch means a suspend is
    # nested inside a user fn call (e.g. `BG { doWrite(...) }` where
    # doWrite calls writeFile) -- the body must fall back to
    # stackful.
    expected = suspend_points.length
    io_next_count = segments.count { |s|
      s.tail.is_a?(Segments::IoSuspend) ||
        s.tail.is_a?(Segments::NextSuspend)
    }
    # Multi-cap WITH produces N LockSuspend specs (one per cap) but
    # Phase A enumeration counts the WITH as a single :lock suspend.
    # Collapse on with_node identity so the counts align.
    lock_with_nodes = segments.filter_map { |s|
      s.tail.is_a?(Segments::LockSuspend) ? s.tail.with_node : nil
    }.uniq
    actual = io_next_count + lock_with_nodes.length
    return nil if expected != actual

    liveness = Liveness.analyze(segments, ctx)
    ext_ctx = (ctx[:extra_ctx_fields] || []) +
              field_locals.map { |p| "#{p[:name]}: #{p[:zig_type]} = undefined," }
    emit_ctx = Emit::FsmEmitContext.from_hash(
      T.cast(
        ctx.merge(extra_ctx_fields: ext_ctx,
                  recursive_promoted_names: promoted_names),
        T::Hash[Symbol, T.nilable(Object)],
      ),
    )
    Emit.build_recursive(emit_ctx, rec_segs, liveness, lowering)
  end

  # Recursively walk the BG body collecting every VarDecl /
  # BindExpr(:decl) name and its Zig type. The recursive splitter
  # promotes all of them to ctx fields so reads/writes across
  # segment boundaries resolve via the capture_map. Returns
  # `[{ name:, zig_type: }, ...]` (deduped on name).
  sig { params(stmts: T.untyped).returns(T::Array[T.untyped]) }
  def collect_body_locals(stmts)
    T.bind(self, T.untyped) rescue nil
    out = []
    seen = {}
    AST.each_locatable(stmts) do |node|
      entry = local_entry_for_node(node)
      next unless entry
      name = entry[:name]
      next if seen[name]
      seen[name] = true
      out << entry
    end
    out
  end

  sig { params(node: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def local_entry_for_node(node)
    T.bind(self, T.untyped) rescue nil
    case node
    when AST::VarDecl
      local_entry(node.name, node.full_type!)
    when AST::BindExpr
      return nil unless node.mode == :decl
      entry = local_entry(node.name, node.full_type!)
      if entry
        # Mark suspend-result decls so the caller can include them in the
        # capture_map but skip duplicate ctx field declarations.
        entry[:is_suspend_result] = true if suspend_value?(node.value)
      end
      entry
    when AST::ForRange
      node.var_name ? { name: node.var_name, zig_type: "i64" } : nil
    when AST::ForEach
      foreach_local_entry(node)
    end
  end

  sig { params(node: AST::ForEach).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def foreach_local_entry(node)
    T.bind(self, T.untyped) rescue nil
    return nil unless node.var_name
    ct = Type.new(node.collection.full_type!(context: "FSM foreach collection"))
    desc = ct.fsm_foreach_descriptor
    elem_zig = desc&.var_zig_type || begin
      elem_t = ct.element_type
      elem_t ? Type.new(elem_t).zig_type : "anyopaque"
    end
    { name: node.var_name, zig_type: elem_zig }
  end

  # True if the BG body contains a WithBlock or an IF/WHILE/FOR
  # whose subtree contains a suspend. In those shapes the recursive
  # splitter renders cond_ast as a Zig STRING (or stashes the CS
  # body) at split time, hiding identifier reads from Liveness.
  # Falling back to "promote everything" guarantees correctness;
  # purely linear bodies skip this and let Liveness over-promote
  # nothing.
  sig { params(stmts: T.untyped).returns(T::Boolean) }
  def body_needs_conservative?(stmts)
    T.bind(self, T.untyped) rescue nil
    Array(stmts).any? do |s|
      next true if s.is_a?(AST::WithBlock)

      AST.child_bodies(s).any? do |body|
        contains_suspend_anywhere?(body) || body_needs_conservative?(body)
      end
    end
  end

  sig { params(stmts: T.untyped).returns(T::Boolean) }
  def contains_suspend_anywhere?(stmts)
    T.bind(self, T.untyped) rescue nil
    Array(stmts).any? do |s|
      next true if Segments.classify_suspend(s)
      next true if s.is_a?(AST::WithBlock)

      AST.child_bodies(s).any? { |body| contains_suspend_anywhere?(body) }
    end
  end

  # True if this BindExpr/VarDecl value is a suspend whose result is
  # already added to the ctx by the suspend descriptor's
  # ctx_field_decls. Used by collect_body_locals to avoid
  # double-declaring the result var.
  sig { params(value: T.untyped).returns(T::Boolean) }
  def suspend_value?(value)
    T.bind(self, T.untyped) rescue nil
    return true if value.is_a?(AST::NextExpr)
    return false unless AST.call?(value)
    md = value.matched_stdlib_def
    !!(md && md.emit&.suspends && md.emit&.fsm_setup)
  end

  sig { params(name: T.untyped, type_obj: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def local_entry(name, type_obj)
    T.bind(self, T.untyped) rescue nil
    return nil if name.nil?
    t = type_obj ? Type.new(type_obj) : nil
    zig_t = t ? t.zig_type : "anyopaque"
    { name: name, zig_type: zig_t }
  end
end
