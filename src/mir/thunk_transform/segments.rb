# thunk_transform/segments.rb -- Tail variants for the THUNK CPS
# segment graph.
#
# Mirrors fsm_transform/segments.rb's pattern: each segment has
# stmts + a tail variant that names the next state transition. The
# variant set differs from FSM:
#
#   Done(value)             -- frame completes; trampoline pops the
#                              parent and applies pending_op (or
#                              returns to the caller if parent is nil)
#   Goto(target_index)      -- internal transition within a single
#                              frame (no pop, no push)
#   CondBranch(cond, t, e)  -- conditional transition; cond is Zig
#                              text (rendered at split time)
#   RecurseTail(args)       -- tail-recursive call; trampoline
#                              REPLACES the current frame with a new
#                              one (same Frame type, fresh args). No
#                              parent linkage needed -- depth stays
#                              at 1.
#   RecurseStep(args, op)   -- non-tail recursive call; trampoline
#                              PUSHES a new frame whose parent is
#                              the current; current's pending_op
#                              tells the trampoline how to combine
#                              the child's Done value with this
#                              frame's locals on resume.
#
# Phase 4a defines the variants; the splitter (Phase 4b+) populates
# them.

module ThunkTransform
  module Segments
    # Each segment carries its index, stmts (mix of MIR / AST /
    # Strings during the transition window), and a tail variant.
    Segment = Struct.new(:index, :stmts, :tail)

    Done        = Struct.new(:value) do
      def kind; :done; end
    end

    Goto        = Struct.new(:target_index) do
      def kind; :goto; end
    end

    CondBranch  = Struct.new(:cond_zig, :then_index, :else_index) do
      def kind; :cond_branch; end
    end

    # Tail-position recursive call. `args_zig` is the pre-rendered
    # call-site argument list (a list of Zig text fragments, one per
    # parameter). `next_index` is unused for tail recursion (the
    # trampoline replaces the frame in place) but kept for shape
    # consistency with the splitter; expansion ignores it.
    RecurseTail = Struct.new(:args_zig, :next_index) do
      def kind; :recurse_tail; end
    end

    # Non-tail recursive call. `pending_op_id` is a small enum tag
    # the splitter assigns at split time -- on resume, the
    # trampoline applies the parent frame's pending_op to combine
    # the child's Done value with the parent's locals.
    # `bind_var` is the local name the child's return value binds
    # into (e.g. `tmp` in `tmp = factorial(n - 1); RETURN n * tmp;`).
    RecurseStep = Struct.new(:args_zig, :pending_op_id, :bind_var, :next_index) do
      def kind; :recurse_step; end
    end
  end
end
