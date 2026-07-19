# typed: strict
# fsm_transform/recursive_splitter.rb -- recursive segment-graph
# splitter for FSM-eligible BG bodies.
#
# Walks the BG body AST top-down. For each control-flow construct
# (WhileLoop / WhileBindLoop / ForRange / IfStatement / WithBlock)
# whose subtree contains a suspend, recursively processes the inner
# body and splices the resulting segment fragment into the parent
# graph. Suspends become their own segment with a kind-specific
# tail; linear stmts accumulate into the surrounding segment.
#
# The output is a flat segment graph with the existing tail variants
# (Done / Goto / LoopBack / CondBranch / IoSuspend / NextSuspend /
# LockSuspend). The unified emit (FsmTransform::Emit.build_fsm_unified)
# walks this graph without caring about original AST nesting.
#
# Key design decisions:
#
#   * Builder allocates segment indices on demand. Forward references
#     (CondBranch.then_index, loop-back targets) are resolved by
#     reserving an index BEFORE recursing into the corresponding
#     sub-body, then filling it after.
#
#   * Each emit_*_fragment takes an `after_idx`: the index control
#     flows to once the fragment completes. The fragment's last
#     segment Gotos there. This is CPS-style.
#
#   * Linear stmts before/between suspends accumulate into a
#     "current segment" buffer. We flush when we hit a suspend
#     boundary or end of body.
#
#   * Suspends carry their `next_index` explicitly (recently added)
#     so they can target arbitrary positions in the graph.
#
# Adding a new control-flow form = a new emit_<kind>_fragment.
# Adding a new suspend kind = a resolver in SuspendResolvers (already
# kind-agnostic at the splitter level: classify_suspend produces
# the appropriate tail variant).

require "sorbet-runtime"

require_relative "../../ast/ast"
require_relative "../../semantic/capability_plan"
require_relative "../mir"
require_relative "context"
require_relative "segments"

module FsmTransform
  module RecursiveSplitter
    extend T::Sig

    SegmentStmt = T.type_alias { T.any(AST::Node, MIR::Emittable) }
    AliasOverrideMap = T.type_alias { T::Hash[String, String] }
    AliasOverrideTable = T.type_alias { T::Hash[Integer, AliasOverrideMap] }
    SegmentSlot = T.type_alias { T.any(FsmTransform::Segments::Segment, Symbol) }
    SplitContext = T.type_alias { FsmTransform::ContextMap }
    SegmentRenumberResult = T.type_alias { [T::Array[FsmTransform::Segments::Segment], T::Hash[Integer, Integer]] }
    SegmentTail = T.type_alias do
      T.any(
        FsmTransform::Segments::Done,
        FsmTransform::Segments::IoSuspend,
        FsmTransform::Segments::NextSuspend,
        FsmTransform::Segments::LockSuspend,
        FsmTransform::Segments::LoopBack,
        FsmTransform::Segments::Goto,
        FsmTransform::Segments::CondBranch,
      )
    end
    SuspendTail = T.type_alias { T.any(FsmTransform::Segments::IoSuspend, FsmTransform::Segments::NextSuspend) }

    class SegmentList < T::Struct
      extend T::Sig

      const :segments, T::Array[FsmTransform::Segments::Segment]
      const :synthetic_fields, T::Array[MIR::ContextFieldDecl]
      const :alias_overrides_by_index, AliasOverrideTable

      sig { params(index: Integer).returns(T.nilable(AliasOverrideMap)) }
      def alias_overrides_for(index)
        alias_overrides_by_index[index]
      end
    end

    # The Builder owns the linear segment array and the next-index
    # counter. Segments are filled in any order (forward refs are
    # resolved by reserving an index, then filling later).
    class Builder
        extend T::Sig

      attr_reader :segments

      sig { returns(T::Array[MIR::ContextFieldDecl]) }
      attr_reader :synthetic_fields

      class Finalized < T::Struct
        const :segments, T::Array[FsmTransform::Segments::Segment]
        const :alias_overrides_by_index, AliasOverrideTable
      end

      sig { void }
      def initialize
        T.bind(self, T.untyped) rescue nil
        @segments = T.let([], T::Array[FsmTransform::RecursiveSplitter::SegmentSlot])
        @synthetic_fields = T.let([], T::Array[MIR::ContextFieldDecl])
        @alias_overrides_for = T.let({}, AliasOverrideTable)
        @current_alias_overrides = T.let(nil, T.nilable(AliasOverrideMap))
        @next_lock_index = T.let(0, Integer)
      end

      # Push a frame of alias overrides during a recursive emit call.
      # Any segment filled / pushed inside the block gets tagged
      # with the merged overrides.
      sig do
        type_parameters(:U)
          .params(overrides: AliasOverrideMap, blk: T.proc.returns(T.type_parameter(:U)))
          .returns(T.type_parameter(:U))
      end
      def with_alias_overrides(overrides, &blk)
        T.bind(self, T.untyped) rescue nil
        prev = @current_alias_overrides
        @current_alias_overrides = (prev || {}).merge(overrides || {})
        blk.call
      ensure
        @current_alias_overrides = prev
      end

      sig { params(idx: Integer).void }
      def stamp_overrides(idx)
        T.bind(self, T.untyped) rescue nil
        return if @current_alias_overrides.nil? || @current_alias_overrides.empty?
        @alias_overrides_for[idx] = @current_alias_overrides.dup
      end

      # Synthetic ctx field decls produced by control-flow-form
      # synthesis (e.g. ForRange's iter / user var). The unified
      # emit reads these and adds them to extra_ctx_fields.
      sig { params(decl: MIR::ContextFieldDecl).void }
      def add_synthetic_field(decl)
        T.bind(self, T.untyped) rescue nil
        @synthetic_fields << decl unless @synthetic_fields.any? { |field| field.name == decl.name }
        nil
      end

      # Reserve a segment index for later filling. Returns the
      # index. Callers MUST call `fill(idx, segment)` before the
      # builder is finalized.
      sig { returns(Integer) }
      def reserve_index
        T.bind(self, T.untyped) rescue nil
        idx = @segments.length
        @segments << :placeholder
        idx
      end

      sig { returns(Integer) }
      def reserve_lock_index
        idx = @next_lock_index
        @next_lock_index += 1
        idx
      end

      # Fill a previously-reserved index with the actual segment.
      sig { params(idx: Integer, stmts: T::Array[SegmentStmt], tail: SegmentTail).returns(Integer) }
      def fill(idx, stmts, tail)
        T.bind(self, T.untyped) rescue nil
        @segments[idx] = Segments::Segment.new(idx, stmts, tail)
        stamp_overrides(idx)
        idx
      end

      # Allocate + fill in one step. Returns the index.
      sig { params(stmts: T::Array[SegmentStmt], tail: SegmentTail).returns(Integer) }
      def push(stmts, tail)
        T.bind(self, T.untyped) rescue nil
        idx = reserve_index
        fill(idx, stmts, tail)
        idx
      end

      sig { returns(Finalized) }
      def finalize
        T.bind(self, T.untyped) rescue nil
        unfilled = @segments.each_with_index.select { |s, _| s == :placeholder }
        if unfilled.any?
          raise "RecursiveSplitter: unfilled segments at indices " \
                "#{unfilled.map(&:last).inspect}"
        end
        Finalized.new(
          segments: T.cast(@segments, T::Array[FsmTransform::Segments::Segment]),
          alias_overrides_by_index: @alias_overrides_for.dup,
        )
      end
          private :stamp_overrides

end


    # Public entry. Returns [Segment, ...] on success, nil if the
    # body contains a shape we don't yet recognize (try/catch, etc.).
    #
    sig { params(body: T::Array[AST::Node], lowering: FsmTransform::LoweringApi, ctx: T.nilable(SplitContext)).returns(T.nilable(SegmentList)) }
    def self.split(body, lowering, ctx: nil)
      return nil if contains_unsupported?(body)

      builder = Builder.new
      done_idx = builder.reserve_index
      begin
        entry = emit_stmts(body, done_idx, builder, lowering, ctx || {})
      rescue UnsupportedShape
        return nil
      end

      # The Done segment has no body; it's the final exit.
      builder.fill(done_idx, [], Segments::Done.new)

      # Entry is the first segment to execute; it MUST be index 0
      # for the dispatch to enter cleanly.
      finalized = builder.finalize
      pre_renumber_overrides = finalized.alias_overrides_by_index
      segments, mapping = renumber_with_entry(finalized.segments, entry)
      synth = builder.synthetic_fields
      alias_table = pre_renumber_overrides.each_with_object({}) { |(orig, ov), h|
        new_idx = mapping.fetch(orig)
        h[new_idx] = ov
      }
      SegmentList.new(
        segments: segments,
        synthetic_fields: synth,
        alias_overrides_by_index: alias_table,
      )
    end

    class UnsupportedShape < StandardError; end

    # Emit segments for `stmts` such that control flow exits to
    # `after_idx`. Returns the entry index of the first segment
    # produced (or `after_idx` if `stmts` is empty / has no
    # control-flow that needs splitting).
    sig { params(stmts: T::Array[SegmentStmt], after_idx: Integer, builder: Builder, lowering: FsmTransform::LoweringApi, ctx: SplitContext).returns(Integer) }
    def self.emit_stmts(stmts, after_idx, builder, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      return after_idx if stmts.nil? || stmts.empty?

      # Find the first stmt that introduces a split (suspends or
      # contains a suspend in a sub-body).
      pivot_idx = stmts.index { |s| stmt_introduces_split?(s) }

      if pivot_idx.nil?
        # No splits in this block: bundle as one segment that
        # Gotos to after_idx.
        return builder.push(stmts, Segments::Goto.new(after_idx))
      end

      pre   = T.must(stmts[0...pivot_idx])
      pivot = stmts[pivot_idx]
      rest  = stmts[(pivot_idx + 1)..] || []

      # Emit `rest` first (so we know where pivot exits to).
      rest_entry = emit_stmts(rest, after_idx, builder, lowering, ctx)

      # Top-level NEXT/IO suspend pivots get their pre-stmts merged
      # in: the suspend's setup_stmts (rendered by the descriptor
      # at emit time) reference any locals declared in pre, so
      # pre + suspend MUST share a runFn frame. Emitting them as
      # separate segments would isolate the locals to runSeg<pre>'s
      # frame, leaving runSeg<suspend>'s setup with undeclared
      # references. Control-flow pivots (WhileLoop / IF / WITH)
      # don't share frame with pre and stay split.
      pivot_ast = pivot.is_a?(AST::Locatable) ? pivot : nil
      sus = pivot_ast ? Segments.classify_suspend(pivot_ast) : nil
      if sus
        emit_suspend_with_pre(sus, pre, rest_entry, builder)
      else
        pivot_entry = emit_pivot(pivot, rest_entry, builder, lowering, ctx)
        if pre.empty?
          pivot_entry
        else
          builder.push(pre, Segments::Goto.new(pivot_entry))
        end
      end
    end

    # Suspend with pre-stmts in the same segment. The pre's locals
    # live in the same Zig fn as the descriptor's setup_stmts.
    sig { params(susp_tail: SuspendTail, pre: T::Array[SegmentStmt], after_idx: Integer, builder: Builder).returns(Integer) }
    def self.emit_suspend_with_pre(susp_tail, pre, after_idx, builder)
      T.bind(self, T.untyped) rescue nil
      idx = builder.reserve_index
      raise UnsupportedShape, "Unhandled suspend kind #{susp_tail.class}" unless Segments.suspend_tail?(susp_tail)

      tail = susp_tail.with_next_index(after_idx)
      builder.fill(idx, pre, tail)
      idx
    end

    # Does this stmt introduce a segment split? True for top-level
    # suspends and control-flow constructs whose subtree contains a
    # suspend (including a WithBlock with a lock-suspending cap).
    sig { params(stmt: T.nilable(SegmentStmt)).returns(T::Boolean) }
    def self.stmt_introduces_split?(stmt)
      T.bind(self, T.untyped) rescue nil
      return false unless stmt
      return true if stmt.is_a?(AST::Locatable) && Segments.classify_suspend(stmt)
      case stmt
      when AST::WithBlock
        with_lock_suspend?(stmt) || contains_suspend_anywhere?(stmt.body)
      else
        return false unless stmt.is_a?(Struct)

        AST.child_bodies(stmt).any? { |body| contains_suspend_anywhere?(body) }
      end
    end

    # Recursively scan for any suspend in a subtree. A WithBlock with
    # a lock-suspending capability counts as a suspend even if its CS
    # body is straight-line.
    sig { params(stmts: T.nilable(T.any(SegmentStmt, T::Array[SegmentStmt]))).returns(T::Boolean) }
    def self.contains_suspend_anywhere?(stmts)
      T.bind(self, T.untyped) rescue nil
      Array(stmts).any? do |stmt|
        next true if stmt.is_a?(AST::Locatable) && Segments.classify_suspend(stmt)
        case stmt
        when AST::WithBlock
          with_lock_suspend?(stmt) || contains_suspend_anywhere?(stmt.body)
        else
          next false unless stmt.is_a?(Struct)

          AST.child_bodies(stmt).any? { |body| contains_suspend_anywhere?(body) }
        end
      end
    end

    # A WITH "lock-suspends" if any of its capabilities require the
    # FSM lock-acquire protocol (EXCLUSIVE / write_locked_read).
    # Plain @read caps don't suspend.
    sig { params(with_node: AST::WithBlock).returns(T::Boolean) }
    def self.with_lock_suspend?(with_node)
      T.bind(self, T.untyped) rescue nil
      CapabilityPlan.require_for(with_node).locks.any?
    end

    # Shape rejection. We accept:
    #   * WhileLoop / ForRange / IF nested arbitrarily, with
    #     IO/NEXT suspends at any depth.
    #   * WithBlock with exactly one EXCLUSIVE / write_locked_read
    #     capability and a straight-line CS body (no nested
    #     suspend). Multi-cap WITH and suspend-in-CS still punt to
    #     the legacy path or stackful.
    #   * try/catch around suspends: not supported.
    sig { params(body: T.nilable(T.any(SegmentStmt, T::Array[SegmentStmt]))).returns(T::Boolean) }
    def self.contains_unsupported?(body)
      T.bind(self, T.untyped) rescue nil
      Array(body).any? do |stmt|
        case stmt
        when AST::WithBlock
          with_unsupported?(stmt)
        when AST::CatchBlock then true
        when AST::WhileLoop, AST::WhileBindLoop
          contains_unsupported?(stmt.do_branch)
        when AST::ForRange, AST::ForEach
          contains_unsupported?(stmt.body)
        when AST::IfStatement
          contains_unsupported?(stmt.then_branch) ||
            contains_unsupported?(stmt.else_branch || [])
        else
          stmt_unsupported_suspend?(stmt)
        end
      end
    end

    # WITH shape gating. Accepts any WITH where every cap is
    # lock-suspending. Suspend-in-CS is supported via per-cap
    # `__lock_held_<i>` ctx flags that destroyTask reads to release
    # locks held across runFn boundaries on err paths.
    #
    # Mixed lock + non-lock caps are still rejected: the parser
    # could synthesize a non-lock leading cap (e.g. @multiowned)
    # for which we don't have a uniform acquire protocol.
    sig { params(with_node: AST::WithBlock).returns(T::Boolean) }
    def self.with_unsupported?(with_node)
      T.bind(self, T.untyped) rescue nil
      if with_lock_suspend?(with_node)
        with_plan = CapabilityPlan.require_for(with_node)
        return true unless with_plan.all.length == with_plan.locks.length
      end
      contains_unsupported?(with_node.body)
    end

    # NEXT on a non-Future (stream / promise-list) source is FSM
    # ineligible -- the suspend protocol assumes scalar Promise(T)
    # with a `.inner.result` field. Streams have a different shape.
    sig { params(stmt: T.nilable(SegmentStmt)).returns(T::Boolean) }
    def self.stmt_unsupported_suspend?(stmt)
      T.bind(self, T.untyped) rescue nil
      sus = stmt.is_a?(AST::Locatable) ? Segments.classify_suspend(stmt) : nil
      return false unless sus.is_a?(Segments::NextSuspend)
      pt = Type.from_node!(sus.promise_ast, context: "FSM suspend promise")
      return true unless pt.future?
      return true if pt.respond_to?(:stream?) && pt.stream?
      return true if pt.respond_to?(:promise_list?) && pt.promise_list?
      false
    end

    # Dispatch to the appropriate fragment emitter.
    sig { params(stmt: SegmentStmt, after_idx: Integer, builder: Builder, lowering: FsmTransform::LoweringApi, ctx: SplitContext).returns(Integer) }
    def self.emit_pivot(stmt, after_idx, builder, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      sus = stmt.is_a?(AST::Locatable) ? Segments.classify_suspend(stmt) : nil
      return emit_suspend(T.cast(sus, SuspendTail), after_idx, builder) if sus

      case stmt
      when AST::WhileLoop, AST::WhileBindLoop
        emit_while_fragment(stmt, after_idx, builder, lowering, ctx)
      when AST::ForRange
        emit_for_range_fragment(stmt, after_idx, builder, lowering, ctx)
      when AST::ForEach
        emit_for_each_fragment(stmt, after_idx, builder, lowering, ctx)
      when AST::IfStatement
        emit_if_fragment(stmt, after_idx, builder, lowering, ctx)
      when AST::WithBlock
        emit_with_fragment(stmt, after_idx, builder, lowering, ctx)
      else
        raise UnsupportedShape, "Unhandled pivot kind #{stmt.class}"
      end
    end

    # Suspend fragment: a single segment whose tail is the suspend.
    # The tail's next_index is set to after_idx so the resume
    # transitions to wherever this fragment exits.
    sig { params(susp_tail: SuspendTail, after_idx: Integer, builder: Builder).returns(Integer) }
    def self.emit_suspend(susp_tail, after_idx, builder)
      T.bind(self, T.untyped) rescue nil
      idx = builder.reserve_index
      raise UnsupportedShape, "Unhandled suspend kind #{susp_tail.class}" unless Segments.suspend_tail?(susp_tail)

      tail = susp_tail.with_next_index(after_idx)
      builder.fill(idx, [], tail)
      idx
    end

    sig { params(while_stmt: T.any(AST::WhileLoop, AST::WhileBindLoop), after_idx: Integer, builder: Builder, lowering: FsmTransform::LoweringApi, ctx: SplitContext).returns(Integer) }
    def self.emit_while_fragment(while_stmt, after_idx, builder, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      _ = [while_stmt, after_idx, builder, lowering, ctx]
      raise UnsupportedShape, "WhileLoop recursive FSM lowering requires structural MIR conditions"
    end

    sig { params(for_stmt: AST::ForRange, after_idx: Integer, builder: Builder, lowering: FsmTransform::LoweringApi, ctx: SplitContext).returns(Integer) }
    def self.emit_for_range_fragment(for_stmt, after_idx, builder, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      _ = [for_stmt, after_idx, builder, lowering, ctx]
      raise UnsupportedShape, "ForRange recursive FSM lowering requires structural MIR loop state"
    end

    sig { params(for_stmt: AST::ForEach, after_idx: Integer, builder: Builder, lowering: FsmTransform::LoweringApi, ctx: SplitContext).returns(Integer) }
    def self.emit_for_each_fragment(for_stmt, after_idx, builder, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      _ = [for_stmt, after_idx, builder, lowering, ctx]
      raise UnsupportedShape, "ForEach recursive FSM lowering requires structural MIR iterator state"
    end


    sig { params(if_stmt: AST::IfStatement, after_idx: Integer, builder: Builder, lowering: FsmTransform::LoweringApi, ctx: SplitContext).returns(Integer) }
    def self.emit_if_fragment(if_stmt, after_idx, builder, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      _ = [if_stmt, after_idx, builder, lowering, ctx]
      raise UnsupportedShape, "IfStatement recursive FSM lowering requires structural MIR conditions"
    end

    # WITH fragment: ONE LockSuspend per capability + recursively
    # split CS body + explicit-unlock release segment.
    #
    # Layout:
    #   cap[0].LockSuspend (post_acquire_idx = cap[1].LockSuspend)
    #   cap[1].LockSuspend (post_acquire_idx = cap[2].LockSuspend)
    #   ...
    #   cap[N-1].LockSuspend (post_acquire_idx = cs_body_entry)
    #   cs_body_entry: recursively-split CS body (flows to release_idx)
    #   release_idx: explicit "__lock_held_<i>=false; lock.unlock();"
    #               for each cap in REVERSE acquire order, then
    #               Goto(after_idx)
    #
    # The Emit fan-out routes LockTry/WokenCheck success through a
    # one-step `held_set` stub that flips this cap's
    # `__lock_held_<i>` flag to true and Gotos to post_acquire_idx.
    # destroyTask reads those flags to release any locks still held
    # on err paths (Zig defer can't span runFn boundaries when the
    # CS body suspends).
    #
    # CS body identifier resolution (`inner.value` -> `(__ctx_<id>.
    # c.ctrl.data.*.data).value`) requires the alias mappings in
    # the active capture_map BEFORE the body lowers. We compute
    # all caps' meta via lowering.fsm_cap_metadata and wrap the
    # recursive emit_stmts in a with_fiber_capture_map that adds
    # alias_name -> alias_data_ref entries.
    sig { params(with_stmt: AST::WithBlock, after_idx: Integer, builder: Builder, lowering: FsmTransform::LoweringApi, ctx: SplitContext).returns(Integer) }
    def self.emit_with_fragment(with_stmt, after_idx, builder, lowering, ctx)
      T.bind(self, T.untyped) rescue nil
      caps = CapabilityPlan.require_for(with_stmt).locks
      raise UnsupportedShape, "WITH with no capabilities" if caps.empty?

      ctx_id_raw = ctx[:id]
      raise UnsupportedShape, "WITH split without ctx" unless ctx_id_raw.is_a?(Integer)

      ctx_id = T.cast(ctx_id_raw, Integer)
      captured = T.cast(ctx[:captured] || {}, FsmTransform::CapturedMap)
      bg_rt_raw = ctx[:bg_rt]
      raise UnsupportedShape, "WITH split without runtime" unless bg_rt_raw.is_a?(String)

      bg_rt = T.cast(bg_rt_raw, String)

      caps_meta = T.let([], T::Array[FsmLowering::FsmCapMetadata])
      caps.each do |c|
        m = T.unsafe(lowering).fsm_cap_metadata(c, with_stmt, ctx_id, captured)
        raise UnsupportedShape, "fsm_cap_metadata failed" if m.nil?
        caps_meta << T.cast(m, FsmLowering::FsmCapMetadata)
      end

      cap_indices = caps.map { builder.reserve_index }
      lock_indices = caps.map { builder.reserve_lock_index }
      release_idx = builder.reserve_index

      body_stmts = with_stmt.body.is_a?(Array) ? with_stmt.body : [with_stmt.body]
      alias_overrides = T.let({}, T::Hash[String, String])
      caps_meta.each do |m|
        alias_overrides[m.fetch(:alias_name).to_s] = m.fetch(:alias_data_ref).to_s
      end
      cs_entry = T.cast(builder.with_alias_overrides(alias_overrides) do
        T.unsafe(lowering).with_fiber_capture_map(
          alias_overrides, rt_override: bg_rt,
        ) do
          emit_stmts(body_stmts, release_idx, builder, lowering, ctx)
        end
      end, Integer)

      caps.each_with_index do |cap, i|
        post_acquire = T.let((i + 1 < caps.length) ? T.must(cap_indices[i + 1]) : cs_entry, Integer)
        prior        = T.must(caps[0...i])
        builder.fill(T.must(cap_indices[i]), [],
          Segments::LockSuspend.new(with_stmt, cap, prior,
                                    post_acquire, after_idx,
                                    T.must(lock_indices[i]), lock_indices[0...i] || []))
      end

      release_stmts = T.let([], T::Array[MIR::Node])
      caps_meta.each_with_index.to_a.reverse.each do |m, i|
        release_stmts.concat(lock_release_stmts(
          ctx_id,
          T.must(lock_indices[i]),
          m.fetch(:lock_field_ref).to_s,
          m.fetch(:unlock_method).to_s,
        ))
      end
      builder.fill(release_idx, release_stmts, Segments::Goto.new(after_idx))

      T.must(cap_indices.first)
    end

    sig { params(ctx_id: Integer, lock_index: Integer, lock_field_ref: String, unlock_method: String).returns(T::Array[MIR::Node]) }
    def self.lock_release_stmts(ctx_id, lock_index, lock_field_ref, unlock_method)
      [
        MIR::Set.new(
          MIR::FieldGet.new(MIR::Ident.new("__ctx_#{ctx_id}"), "__lock_held_#{lock_index}"),
          MIR::Lit.new("false"),
          false,
        ),
        MIR::ExprStmt.new(
          MIR::MethodCall.new(MIR::Ident.new(lock_field_ref), unlock_method, [], false),
          false,
        ),
      ]
    end

    # Renumber segments so that `entry` becomes index 0. Updates all
    # tail target_indices. Used when emit_stmts produces segments in
    # an order where the entry isn't at index 0 (it can happen when
    # post-segments are emitted before the body that flows into them).
    sig { params(segments: T::Array[Segments::Segment], entry: Integer).returns(SegmentRenumberResult) }
    def self.renumber_with_entry(segments, entry)
      T.bind(self, T.untyped) rescue nil
      mapping = { entry => 0 }
      next_id = 1
      segments.each_with_index do |_, i|
        next if i == entry
        mapping[i] = next_id
        next_id += 1
      end
      remapped = segments.map { |seg|
        new_idx = mapping[seg.index]
        new_tail = remap_tail(seg.tail, mapping)
        Segments::Segment.new(new_idx, seg.stmts, new_tail)
      }.sort_by(&:index)
      [remapped, mapping]
    end

    sig { params(tail: SegmentTail, mapping: T::Hash[Integer, Integer]).returns(SegmentTail) }
    def self.remap_tail(tail, mapping)
      T.bind(self, T.untyped) rescue nil
      case tail
      when Segments::Goto
        Segments::Goto.new(mapping.fetch(tail.target_index))
      when Segments::LoopBack
        Segments::LoopBack.new(mapping.fetch(tail.target_index))
      when Segments::CondBranch
        Segments::CondBranch.new(
          tail.cond_ast,
          mapping.fetch(tail.then_index),
          mapping.fetch(tail.else_index),
        )
      when Segments::IoSuspend, Segments::NextSuspend
        tail.with_next_index(tail.next_index ? mapping.fetch(tail.next_index) : nil)
      when Segments::LockSuspend
        Segments::LockSuspend.new(
          tail.with_node, tail.cap, tail.prior_caps,
          tail.post_acquire_idx ? mapping.fetch(tail.post_acquire_idx) : nil,
          tail.next_index ? mapping.fetch(tail.next_index) : nil,
          tail.lock_index,
          tail.prior_lock_indices,
        )
      else
        tail
      end
    end

    private_class_method :emit_pivot,
      :emit_with_fragment,
      :stmt_introduces_split?,
      :with_unsupported?
    private_class_method :contains_suspend_anywhere?
    private_class_method :contains_unsupported?
    private_class_method :emit_for_each_fragment
    private_class_method :emit_for_range_fragment
    private_class_method :emit_if_fragment
    private_class_method :emit_stmts
    private_class_method :emit_suspend
    private_class_method :emit_suspend_with_pre
    private_class_method :emit_while_fragment
    private_class_method :lock_release_stmts
    private_class_method :remap_tail
    private_class_method :renumber_with_entry
    private_class_method :stmt_unsupported_suspend?
    private_class_method :with_lock_suspend?

end
end
