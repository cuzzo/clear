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

require_relative "segments"

module FsmTransform
  module RecursiveSplitter
    extend T::Sig
    # The Builder owns the linear segment array and the next-index
    # counter. Segments are filled in any order (forward refs are
    # resolved by reserving an index, then filling later).
    class Builder
        extend T::Sig

      attr_reader :segments, :synthetic_fields

      sig { void }
      def initialize
        T.bind(self, T.untyped) rescue nil
        @segments = T.let([], T::Array[T.untyped])
        @synthetic_fields = T.let([], T::Array[T.untyped])
        @alias_overrides_for = T.let({}, T::Hash[T.untyped, T.untyped])
        @current_alias_overrides = T.let(nil, T.nilable(T::Hash[T.untyped, T.untyped]))
      end

      # Per-segment alias overrides keyed by segment index. Used by
      # WITH's recursively-split CS body so the CS-scope identifier
      # alias (e.g. `inner` -> `(__ctx.c.ctrl.data.*.data)`) is in
      # the capture_map when each CS segment is rendered.
      sig { params(idx: Integer).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def alias_overrides_for(idx)
        T.bind(self, T.untyped) rescue nil
        @alias_overrides_for[idx]
      end

      # Push a frame of alias overrides during a recursive emit call.
      # Any segment filled / pushed inside the block gets tagged
      # with the merged overrides.
      sig { params(overrides: T::Hash[String, String], blk: T.untyped).returns(T.untyped) }
      def with_alias_overrides(overrides, &blk)
        T.bind(self, T.untyped) rescue nil
        prev = @current_alias_overrides
        @current_alias_overrides = (prev || {}).merge(overrides || {})
        blk.call
      ensure
        @current_alias_overrides = prev
      end

      sig { params(idx: Integer).returns(T.nilable(T::Hash[String, String])) }
      def stamp_overrides(idx)
        T.bind(self, T.untyped) rescue nil
        return if @current_alias_overrides.nil? || @current_alias_overrides.empty?
        @alias_overrides_for[idx] = @current_alias_overrides.dup
      end

      # Synthetic ctx field decls produced by control-flow-form
      # synthesis (e.g. ForRange's iter / user var). The unified
      # emit reads these and adds them to extra_ctx_fields.
      sig { params(decl: String).returns(T.nilable(T::Array[String])) }
      def add_synthetic_field(decl)
        T.bind(self, T.untyped) rescue nil
        @synthetic_fields << decl unless @synthetic_fields.include?(decl)
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

      # Fill a previously-reserved index with the actual segment.
      sig { params(idx: Integer, stmts: T::Array[T.untyped], tail: T.untyped).returns(Integer) }
      def fill(idx, stmts, tail)
        T.bind(self, T.untyped) rescue nil
        @segments[idx] = Segments::Segment.new(idx, stmts, tail)
        stamp_overrides(idx)
        idx
      end

      # Allocate + fill in one step. Returns the index.
      sig { params(stmts: T::Array[T.untyped], tail: T.untyped).returns(Integer) }
      def push(stmts, tail)
        T.bind(self, T.untyped) rescue nil
        idx = reserve_index
        fill(idx, stmts, tail)
        idx
      end

      sig { returns(T::Array[FsmTransform::Segments::Segment]) }
      def finalize
        T.bind(self, T.untyped) rescue nil
        unfilled = @segments.each_with_index.select { |s, _| s == :placeholder }
        if unfilled.any?
          raise "RecursiveSplitter: unfilled segments at indices " \
                "#{unfilled.map(&:last).inspect}"
        end
        @segments
      end
    end

    module_function

    # Public entry. Returns [Segment, ...] on success, nil if the
    # body contains a shape we don't yet recognize (try/catch, etc.).
    #
    # `lowering` is used inside emit_*_fragment for cond-rendering
    # (loop / if conditions are lowered to Zig text at split time
    # since they appear in CondBranch tails as raw Zig).
    sig { params(body: T.untyped, lowering: T.untyped, ctx: BasicObject).returns(T.nilable(T::Array[T.untyped])) }
    def split(body, lowering, ctx: nil)
      T.bind(self, T.untyped) rescue nil
      return nil if contains_unsupported?(body)

      builder = Builder.new
      builder.instance_variable_set(:@__bg_ctx, ctx)
      done_idx = builder.reserve_index
      begin
        entry = emit_stmts(body, done_idx, builder, lowering)
      rescue UnsupportedShape
        return nil
      end
      return nil if entry.nil?

      # The Done segment has no body; it's the final exit.
      builder.fill(done_idx, [], Segments::Done.new(nil))

      # Entry is the first segment to execute; it MUST be index 0
      # for the dispatch to enter cleanly. Reorder if needed.
      segments = builder.finalize
      pre_renumber_overrides = builder.instance_variable_get(:@alias_overrides_for).dup
      mapping = nil
      if entry != 0
        segments, mapping = renumber_with_entry(segments, entry)
      end
      synth = builder.synthetic_fields.dup
      segments.define_singleton_method(:synthetic_fields) { synth }
      alias_table =
        if mapping
          pre_renumber_overrides.each_with_object({}) { |(orig, ov), h|
            new_idx = mapping.fetch(orig)
            h[new_idx] = ov
          }
        else
          pre_renumber_overrides
        end
      segments.define_singleton_method(:alias_overrides_for) { |i| alias_table[i] }
      segments
    rescue UnsupportedShape
      nil
    end

    class UnsupportedShape < StandardError; end

    # Emit segments for `stmts` such that control flow exits to
    # `after_idx`. Returns the entry index of the first segment
    # produced (or `after_idx` if `stmts` is empty / has no
    # control-flow that needs splitting).
    sig { params(stmts: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped).returns(T.untyped) }
    def emit_stmts(stmts, after_idx, builder, lowering)
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

      pre   = stmts[0...pivot_idx]
      pivot = stmts[pivot_idx]
      rest  = stmts[(pivot_idx + 1)..] || []

      # Emit `rest` first (so we know where pivot exits to).
      rest_entry = emit_stmts(rest, after_idx, builder, lowering)

      # Top-level NEXT/IO suspend pivots get their pre-stmts merged
      # in: the suspend's setup_stmts (rendered by the descriptor
      # at emit time) reference any locals declared in pre, so
      # pre + suspend MUST share a runFn frame. Emitting them as
      # separate segments would isolate the locals to runSeg<pre>'s
      # frame, leaving runSeg<suspend>'s setup with undeclared
      # references. Control-flow pivots (WhileLoop / IF / WITH)
      # don't share frame with pre and stay split.
      sus = Segments.classify_suspend(pivot)
      if sus
        emit_suspend_with_pre(sus, pre, rest_entry, builder)
      else
        pivot_entry = emit_pivot(pivot, rest_entry, builder, lowering)
        if pre.empty?
          pivot_entry
        else
          builder.push(pre, Segments::Goto.new(pivot_entry))
        end
      end
    end

    # Suspend with pre-stmts in the same segment. The pre's locals
    # live in the same Zig fn as the descriptor's setup_stmts.
    sig { params(susp_tail: T.untyped, pre: T.untyped, after_idx: BasicObject, builder: T.untyped).returns(Integer) }
    def emit_suspend_with_pre(susp_tail, pre, after_idx, builder)
      T.bind(self, T.untyped) rescue nil
      idx = builder.reserve_index
      tail =
        case susp_tail
        when Segments::IoSuspend
          Segments::IoSuspend.new(
            susp_tail.call_node, susp_tail.stdlib_def, susp_tail.result_var,
            after_idx,
          )
        when Segments::NextSuspend
          Segments::NextSuspend.new(
            susp_tail.promise_ast, susp_tail.result_var, after_idx,
          )
        else
          raise UnsupportedShape, "Unhandled suspend kind #{susp_tail.class}"
        end
      builder.fill(idx, pre, tail)
      idx
    end

    # Does this stmt introduce a segment split? True for top-level
    # suspends and control-flow constructs whose subtree contains a
    # suspend (including a WithBlock with a lock-suspending cap).
    sig { params(stmt: T.anything).returns(T::Boolean) }
    def stmt_introduces_split?(stmt)
      T.bind(self, T.untyped) rescue nil
      return true if Segments.classify_suspend(stmt)
      case stmt
      when AST::WhileLoop, AST::WhileBindLoop
        contains_suspend_anywhere?(stmt.do_branch)
      when AST::ForRange, AST::ForEach
        contains_suspend_anywhere?(stmt.body)
      when AST::IfStatement
        contains_suspend_anywhere?(stmt.then_branch) ||
          contains_suspend_anywhere?(stmt.else_branch || [])
      when AST::WithBlock
        with_lock_suspend?(stmt) || contains_suspend_anywhere?(stmt.body)
      else
        false
      end
    end

    # Recursively scan for any suspend in a subtree. A WithBlock with
    # a lock-suspending capability counts as a suspend even if its CS
    # body is straight-line.
    sig { params(stmts: T.untyped).returns(T::Boolean) }
    def contains_suspend_anywhere?(stmts)
      T.bind(self, T.untyped) rescue nil
      Array(stmts).any? do |stmt|
        next true if Segments.classify_suspend(stmt)
        case stmt
        when AST::WhileLoop, AST::WhileBindLoop
          contains_suspend_anywhere?(stmt.do_branch)
        when AST::ForRange, AST::ForEach
          contains_suspend_anywhere?(stmt.body)
        when AST::WithBlock
          with_lock_suspend?(stmt) || contains_suspend_anywhere?(stmt.body)
        when AST::IfStatement
          contains_suspend_anywhere?(stmt.then_branch) ||
            contains_suspend_anywhere?(stmt.else_branch || [])
        else
          false
        end
      end
    end

    # A WITH "lock-suspends" if any of its capabilities require the
    # FSM lock-acquire protocol (EXCLUSIVE / write_locked_read).
    # Plain @read caps don't suspend.
    sig { params(with_node: T.untyped).returns(T::Boolean) }
    def with_lock_suspend?(with_node)
      T.bind(self, T.untyped) rescue nil
      caps = with_node.capabilities || []
      caps.any? { |c|
        c[:capability] == :EXCLUSIVE || c[:capability] == :write_locked_read
      }
    end

    # Shape rejection. We accept:
    #   * WhileLoop / ForRange / IF nested arbitrarily, with
    #     IO/NEXT suspends at any depth.
    #   * WithBlock with exactly one EXCLUSIVE / write_locked_read
    #     capability and a straight-line CS body (no nested
    #     suspend). Multi-cap WITH and suspend-in-CS still punt to
    #     the legacy path or stackful.
    #   * try/catch around suspends: not supported.
    sig { params(body: T.untyped).returns(T::Boolean) }
    def contains_unsupported?(body)
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
    sig { params(with_node: T.untyped).returns(T::Boolean) }
    def with_unsupported?(with_node)
      T.bind(self, T.untyped) rescue nil
      caps = with_node.capabilities || []
      if with_lock_suspend?(with_node)
        unsuspending = caps.any? { |c|
          c[:capability] != :EXCLUSIVE && c[:capability] != :write_locked_read
        }
        return true if unsuspending
      end
      contains_unsupported?(with_node.body)
    end

    # NEXT on a non-Future (stream / promise-list) source is FSM
    # ineligible -- the suspend protocol assumes scalar Promise(T)
    # with a `.inner.result` field. Streams have a different shape.
    sig { params(stmt: T.untyped).returns(T::Boolean) }
    def stmt_unsupported_suspend?(stmt)
      T.bind(self, T.untyped) rescue nil
      sus = Segments.classify_suspend(stmt)
      return false unless sus.is_a?(Segments::NextSuspend)
      ft = sus.promise_ast.full_type
      return true if ft.nil?
      # Type may already be a Type-like object (test fixtures) or a
      # raw symbol that needs Type.new(...) wrapping. Try to call
      # future? directly first; only wrap if the object doesn't
      # answer.
      pt = ft.respond_to?(:future?) ? ft : (Type.new(ft) rescue nil)
      return true if pt.nil?
      return true unless pt.respond_to?(:future?) && pt.future?
      return true if pt.respond_to?(:stream?) && pt.stream?
      return true if pt.respond_to?(:promise_list?) && pt.promise_list?
      false
    end

    # Dispatch to the appropriate fragment emitter.
    sig { params(stmt: T.untyped, after_idx: T.untyped, builder: T.untyped, lowering: T.untyped).returns(Integer) }
    def emit_pivot(stmt, after_idx, builder, lowering)
      T.bind(self, T.untyped) rescue nil
      sus = Segments.classify_suspend(stmt)
      return emit_suspend(sus, after_idx, builder) if sus

      case stmt
      when AST::WhileLoop, AST::WhileBindLoop
        emit_while_fragment(stmt, after_idx, builder, lowering)
      when AST::ForRange
        emit_for_range_fragment(stmt, after_idx, builder, lowering)
      when AST::ForEach
        emit_for_each_fragment(stmt, after_idx, builder, lowering)
      when AST::IfStatement
        emit_if_fragment(stmt, after_idx, builder, lowering)
      when AST::WithBlock
        emit_with_fragment(stmt, after_idx, builder, lowering)
      else
        raise UnsupportedShape, "Unhandled pivot kind #{stmt.class}"
      end
    end

    # Suspend fragment: a single segment whose tail is the suspend.
    # The tail's next_index is set to after_idx so the resume
    # transitions to wherever this fragment exits.
    sig { params(susp_tail: T.untyped, after_idx: BasicObject, builder: T.untyped).returns(Integer) }
    def emit_suspend(susp_tail, after_idx, builder)
      T.bind(self, T.untyped) rescue nil
      idx = builder.reserve_index
      tail =
        case susp_tail
        when Segments::IoSuspend
          Segments::IoSuspend.new(
            susp_tail.call_node, susp_tail.stdlib_def, susp_tail.result_var,
            after_idx,
          )
        when Segments::NextSuspend
          Segments::NextSuspend.new(
            susp_tail.promise_ast, susp_tail.result_var, after_idx,
          )
        else
          raise UnsupportedShape, "Unhandled suspend kind #{susp_tail.class}"
        end
      builder.fill(idx, [], tail)
      idx
    end

    # WhileLoop fragment: cond-head + body that loops back to cond.
    #
    #   cond_seg: [], CondBranch(cond_zig, body_entry, after_idx)
    #   body_segs (recursive): exit to cond_seg's index
    sig { params(while_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped).returns(Integer) }
    def emit_while_fragment(while_stmt, after_idx, builder, lowering)
      T.bind(self, T.untyped) rescue nil
      cond_idx = builder.reserve_index

      body_stmts = while_stmt.do_branch.is_a?(Array) ?
                     while_stmt.do_branch : [while_stmt.do_branch]
      body_entry = emit_stmts(body_stmts, cond_idx, builder, lowering)

      cond_zig = lower_to_zig(while_stmt.condition, lowering)
      raise UnsupportedShape, "While cond did not lower" if cond_zig.nil?

      builder.fill(cond_idx, [],
        Segments::CondBranch.new(cond_zig, body_entry, after_idx))
      cond_idx
    end

    # ForRange fragment: synthesized iteration var + cond + incr.
    # The iter var and user var must be ctx FIELDS (not runFn
    # locals) because they cross segment boundaries (init seg
    # writes them, cond seg reads, body reads, incr writes).
    # Builder tracks the synthesized field decls for the unified
    # emit to register on the ctx struct.
    #
    #   init_seg: [ctx.__for_X = start; ctx.var = ctx.__for_X], Goto(cond)
    #   cond_seg: [], CondBranch(ctx.__for_X < end, body_entry, after_idx)
    #   body_segs: exit to incr_seg
    #   incr_seg: [ctx.__for_X += 1; ctx.var = ctx.__for_X], Goto(cond)
    sig { params(for_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped).returns(Integer) }
    def emit_for_range_fragment(for_stmt, after_idx, builder, lowering)
      T.bind(self, T.untyped) rescue nil
      var_name = for_stmt.var_name
      iter_var = "__for_#{builder.segments.length}"
      type_zig = "i64"

      # ctx_id is unknown at split time. The synthesized stmts use
      # the placeholder token __FSM_CTX which the unified emit
      # substitutes with __ctx_<id> before rendering.
      builder.add_synthetic_field("#{iter_var}: #{type_zig} = undefined,")
      builder.add_synthetic_field("#{var_name}: #{type_zig} = undefined,")

      start_zig = lower_to_zig(for_stmt.start_expr, lowering) or
        raise UnsupportedShape, "ForRange start did not lower"
      end_zig = lower_to_zig(for_stmt.end_expr, lowering) or
        raise UnsupportedShape, "ForRange end did not lower"

      ctx_iter = "__FSM_CTX.#{iter_var}"
      ctx_var  = "__FSM_CTX.#{var_name}"

      cond_op = for_stmt.inclusive ? "<=" : "<"
      cond_zig = "#{ctx_iter} #{cond_op} #{end_zig}"

      cond_idx = builder.reserve_index
      incr_idx = builder.reserve_index

      body_stmts = for_stmt.body.is_a?(Array) ? for_stmt.body : [for_stmt.body]
      body_entry = emit_stmts(body_stmts, incr_idx, builder, lowering)

      init_zig = "#{ctx_iter} = #{start_zig};\n#{ctx_var} = #{ctx_iter};"
      init_idx = builder.push([init_zig], Segments::Goto.new(cond_idx))

      builder.fill(cond_idx, [],
        Segments::CondBranch.new(cond_zig, body_entry, after_idx))
      builder.fill(incr_idx,
        ["#{ctx_iter} = #{ctx_iter} + 1;\n#{ctx_var} = #{ctx_iter};"],
        Segments::Goto.new(cond_idx))

      init_idx
    end

    # ForEach fragment: dispatches on the collection's
    # fsm_foreach_descriptor (defined on Type) so adding a new
    # collection = one new branch on Type#fsm_foreach_descriptor.
    # The splitter never inspects the type directly.
    sig { params(for_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped).returns(Integer) }
    def emit_for_each_fragment(for_stmt, after_idx, builder, lowering)
      T.bind(self, T.untyped) rescue nil
      coll_ast = for_stmt.collection
      coll_type = coll_ast.full_type
      ct = coll_type.is_a?(Type) ? coll_type : (coll_type ? Type.new(coll_type) : nil)
      raise UnsupportedShape, "ForEach without resolved coll type" if ct.nil?

      desc = ct.is_a?(Type) ? ct.fsm_foreach_descriptor : nil
      if desc.nil?
        raise UnsupportedShape, "ForEach over #{ct.inspect} not supported in FSM"
      end

      coll_zig = lower_to_zig(coll_ast, lowering)
      raise UnsupportedShape, "ForEach collection did not lower" if coll_zig.nil?

      var_name = for_stmt.var_name
      counter = builder.segments.length
      # Per-shape var type comes from the descriptor (e.g. map's
      # bound var is the KEY type, not the element/value type).
      elem_zig = desc[:var_zig_type] || begin
        elem_t = ct.is_a?(Type) ? ct.element_type : nil
        elem_t ? Type.new(elem_t).zig_type : "anyopaque"
      end
      ctx_var = "__FSM_CTX.#{var_name}"

      case desc[:kind]
      when :indexed_slice
        emit_for_each_indexed(for_stmt, after_idx, builder, lowering,
                              coll_zig, var_name, ctx_var, elem_zig,
                              counter, desc[:slice_suffix])
      when :pool_indexed
        emit_for_each_pool(for_stmt, after_idx, builder, lowering,
                           coll_zig, var_name, ctx_var, elem_zig, counter)
      when :iterator
        emit_for_each_iterator(for_stmt, after_idx, builder, lowering,
                               coll_zig, var_name, ctx_var, elem_zig,
                               counter, desc, ct)
      else
        raise UnsupportedShape, "Unknown FSM ForEach kind #{desc[:kind].inspect}"
      end
    end

    sig { params(for_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped, coll_zig: T.nilable(String), var_name: T.untyped, ctx_var: String, elem_zig: T.untyped, counter: Integer, desc: T.untyped, ct: T.untyped).returns(Integer) }
    def emit_for_each_iterator(for_stmt, after_idx, builder, lowering,
                               coll_zig, var_name, ctx_var, elem_zig,
                               counter, desc, ct)
      T.bind(self, T.untyped) rescue nil
      iter_field = "__feiter_#{counter}"
      has_field  = "__fehas_#{counter}"
      init_method     = desc[:init_method]
      advance_method  = desc[:advance_method]
      # Use a pointer-to-undefined as the receiver so Zig can match
      # whichever method signature (`*Self` or `*const Self`) the
      # collection exposes -- @as(T, undefined) is an rvalue and
      # auto-take-address may decay to `*const T`, which mismatches
      # collections that declare keyIterator on *Self.
      iter_type_zig =
        "@TypeOf(@as(*#{ct.zig_type}, undefined).#{init_method}())"

      builder.add_synthetic_field("#{var_name}: #{elem_zig} = undefined,")
      builder.add_synthetic_field("#{iter_field}: #{iter_type_zig} = undefined,")
      builder.add_synthetic_field("#{has_field}: bool = false,")

      ctx_iter = "__FSM_CTX.#{iter_field}"
      ctx_has  = "__FSM_CTX.#{has_field}"

      cond_idx = builder.reserve_index
      body_stmts = for_stmt.body.is_a?(Array) ? for_stmt.body : [for_stmt.body]
      body_entry = emit_stmts(body_stmts, cond_idx, builder, lowering)

      bind_zig = desc[:deref] ? "__nxt_#{counter}.*" : "__nxt_#{counter}"
      cond_pre = [
        "if (#{ctx_iter}.#{advance_method}()) |__nxt_#{counter}| {",
        "    #{ctx_var} = #{bind_zig};",
        "    #{ctx_has} = true;",
        "} else {",
        "    #{ctx_has} = false;",
        "}",
      ].join("\n")
      builder.fill(cond_idx, [cond_pre],
        Segments::CondBranch.new(ctx_has, body_entry, after_idx))

      builder.push(
        ["#{ctx_iter} = #{coll_zig}.#{init_method}();"],
        Segments::Goto.new(cond_idx),
      )
    end

    # Indexed slice: list / array. ctx.__feidx walks 0..len; body_init
    # assigns ctx.var from the slice; incr bumps the idx.
    sig { params(for_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped, coll_zig: T.nilable(String), var_name: T.untyped, ctx_var: String, elem_zig: T.untyped, counter: Integer, slice_suffix: T.untyped).returns(Integer) }
    def emit_for_each_indexed(for_stmt, after_idx, builder, lowering,
                              coll_zig, var_name, ctx_var, elem_zig,
                              counter, slice_suffix)
      T.bind(self, T.untyped) rescue nil
      iter_var = "__feidx_#{counter}"
      builder.add_synthetic_field("#{iter_var}: usize = 0,")
      builder.add_synthetic_field("#{var_name}: #{elem_zig} = undefined,")

      slice_zig = "#{coll_zig}#{slice_suffix}"
      ctx_iter = "__FSM_CTX.#{iter_var}"

      cond_idx = builder.reserve_index
      incr_idx = builder.reserve_index
      body_stmts = for_stmt.body.is_a?(Array) ? for_stmt.body : [for_stmt.body]
      body_entry = emit_stmts(body_stmts, incr_idx, builder, lowering)

      body_init_idx = builder.push(
        ["#{ctx_var} = #{slice_zig}[#{ctx_iter}];"],
        Segments::Goto.new(body_entry),
      )
      builder.fill(cond_idx, [],
        Segments::CondBranch.new("#{ctx_iter} < #{slice_zig}.len",
                                 body_init_idx, after_idx))
      builder.fill(incr_idx,
        ["#{ctx_iter} = #{ctx_iter} + 1;"],
        Segments::Goto.new(cond_idx))
      builder.push(["#{ctx_iter} = 0;"], Segments::Goto.new(cond_idx))
    end

    # Pool indexed: like :indexed_slice but body_init has a skip-dead
    # branch that Gotos straight to incr when the slot's `alive` flag
    # is false.
    sig { params(for_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped, coll_zig: T.nilable(String), var_name: T.untyped, ctx_var: String, elem_zig: T.untyped, counter: Integer).returns(Integer) }
    def emit_for_each_pool(for_stmt, after_idx, builder, lowering,
                           coll_zig, var_name, ctx_var, elem_zig, counter)
      T.bind(self, T.untyped) rescue nil
      iter_var = "__feidx_#{counter}"
      builder.add_synthetic_field("#{iter_var}: usize = 0,")
      builder.add_synthetic_field("#{var_name}: #{elem_zig} = undefined,")

      slots_zig = "#{coll_zig}.slots"
      ctx_iter = "__FSM_CTX.#{iter_var}"

      cond_idx = builder.reserve_index
      incr_idx = builder.reserve_index
      body_stmts = for_stmt.body.is_a?(Array) ? for_stmt.body : [for_stmt.body]
      body_entry = emit_stmts(body_stmts, incr_idx, builder, lowering)

      assign_idx = builder.push(
        ["#{ctx_var} = #{slots_zig}[#{ctx_iter}].value;"],
        Segments::Goto.new(body_entry),
      )
      skip_check_idx = builder.reserve_index
      builder.fill(skip_check_idx, [],
        Segments::CondBranch.new(
          "!#{slots_zig}[#{ctx_iter}].alive",
          incr_idx, assign_idx,
        ))
      builder.fill(cond_idx, [],
        Segments::CondBranch.new("#{ctx_iter} < #{slots_zig}.len",
                                 skip_check_idx, after_idx))
      builder.fill(incr_idx,
        ["#{ctx_iter} = #{ctx_iter} + 1;"],
        Segments::Goto.new(cond_idx))
      builder.push(["#{ctx_iter} = 0;"], Segments::Goto.new(cond_idx))
    end


    # IF fragment: pre + CondBranch to then-entry / else-entry. Both
    # branches Goto to after_idx (the convergence point).
    sig { params(if_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped).returns(Integer) }
    def emit_if_fragment(if_stmt, after_idx, builder, lowering)
      T.bind(self, T.untyped) rescue nil
      then_branch = if_stmt.then_branch.is_a?(Array) ?
                      if_stmt.then_branch : [if_stmt.then_branch]
      else_branch = if_stmt.else_branch
      else_branch = else_branch.is_a?(Array) ? else_branch : [else_branch] if else_branch

      then_entry = emit_stmts(then_branch, after_idx, builder, lowering)
      else_entry =
        if else_branch
          emit_stmts(else_branch, after_idx, builder, lowering)
        else
          after_idx
        end

      cond_zig = lower_to_zig(if_stmt.condition, lowering) or
        raise UnsupportedShape, "If cond did not lower"
      builder.push([], Segments::CondBranch.new(cond_zig, then_entry, else_entry))
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
    sig { params(with_stmt: T.untyped, after_idx: BasicObject, builder: T.untyped, lowering: T.untyped).returns(T.untyped) }
    def emit_with_fragment(with_stmt, after_idx, builder, lowering)
      T.bind(self, T.untyped) rescue nil
      caps = with_stmt.capabilities || []
      raise UnsupportedShape, "WITH with no capabilities" if caps.empty?

      ctx     = builder.instance_variable_get(:@__bg_ctx) || {}
      ctx_id  = ctx[:id]
      captured = ctx[:captured] || {}
      raise UnsupportedShape, "WITH split without ctx" if ctx_id.nil?

      caps_meta = caps.map { |c|
        m = lowering.fsm_cap_metadata(c, with_stmt, ctx_id, captured)
        raise UnsupportedShape, "fsm_cap_metadata failed" if m.nil?
        m
      }

      cap_indices = caps.map { builder.reserve_index }
      release_idx = builder.reserve_index

      body_stmts = with_stmt.body.is_a?(Array) ? with_stmt.body : [with_stmt.body]
      alias_overrides = caps_meta.to_h { |m|
        [m[:alias_name], m[:alias_data_ref]]
      }
      cs_entry = builder.with_alias_overrides(alias_overrides) do
        lowering.with_fiber_capture_map(
          alias_overrides, rt_override: ctx[:bg_rt],
        ) do
          emit_stmts(body_stmts, release_idx, builder, lowering)
        end
      end

      caps.each_with_index do |cap, i|
        post_acquire = (i + 1 < caps.length) ? cap_indices[i + 1] : cs_entry
        prior        = caps[0...i]
        builder.fill(cap_indices[i], [],
          Segments::LockSuspend.new(with_stmt, cap, prior,
                                    post_acquire, after_idx))
      end

      release_lines = caps_meta.each_with_index.map { |m, i|
        ["__ctx_#{ctx_id}.__lock_held_#{i} = false;",
         "#{m[:lock_field_ref]}.#{m[:unlock_method]}();"]
      }.reverse.flatten
      builder.fill(release_idx, release_lines, Segments::Goto.new(after_idx))

      cap_indices.first
    end

    # Lower an AST expression to a Zig text fragment. The lowering
    # provides .lower (AST -> MIR) and emit_expr (MIR -> Zig text);
    # we chain them. May return nil if the lowering fails.
    sig { params(ast_expr: T.untyped, lowering: T.untyped).returns(T.nilable(String)) }
    def lower_to_zig(ast_expr, lowering)
      T.bind(self, T.untyped) rescue nil
      return nil if ast_expr.nil?
      mir = lowering.lower(ast_expr)
      return nil if mir.nil?
      # emit_expr is private on MIRLowering -- bypass with send.
      lowering.send(:emit_expr, mir)
    rescue StandardError
      nil
    end

    # Renumber segments so that `entry` becomes index 0. Updates all
    # tail target_indices. Used when emit_stmts produces segments in
    # an order where the entry isn't at index 0 (it can happen when
    # post-segments are emitted before the body that flows into them).
    sig { params(segments: T.untyped, entry: T.untyped).returns(T::Array[T.untyped]) }
    def renumber_with_entry(segments, entry)
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

    sig { params(tail: T.anything, mapping: T.untyped).returns(T.untyped) }
    def remap_tail(tail, mapping)
      T.bind(self, T.untyped) rescue nil
      case tail
      when Segments::Done
        tail
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
      when Segments::IoSuspend
        Segments::IoSuspend.new(
          tail.call_node, tail.stdlib_def, tail.result_var,
          tail.next_index ? mapping.fetch(tail.next_index) : nil,
        )
      when Segments::NextSuspend
        Segments::NextSuspend.new(
          tail.promise_ast, tail.result_var,
          tail.next_index ? mapping.fetch(tail.next_index) : nil,
        )
      when Segments::LockSuspend
        Segments::LockSuspend.new(
          tail.with_node, tail.cap, tail.prior_caps,
          tail.post_acquire_idx ? mapping.fetch(tail.post_acquire_idx) : nil,
          tail.next_index ? mapping.fetch(tail.next_index) : nil,
        )
      else
        tail
      end
    end
  end
end
