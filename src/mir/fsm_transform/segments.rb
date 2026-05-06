# fsm_transform/segments.rb -- Segment splitter.
#
# Walks the BG body AST and produces a segment graph cut at suspend
# points. A segment is a list of straight-line stmts (no embedded
# suspends) ending in a SegmentTail that describes the transition
# to the next segment.
#
# Stage 1 (this file as initially shipped): LINEAR bodies only.
# - Top-level stmts that may contain a single suspending stdlib call
#   or a NEXT expression as the immediate value of a binding /
#   assignment, or as a bare statement.
# - Returns nil if the body contains anything Stage 1 doesn't
#   handle yet (WHILE with embedded suspend, WITH block, IF with
#   embedded suspend, try/catch, ...). The caller falls back to
#   the legacy per-shape emitter.
#
# Stage 2 will add WHILE handling (LoopBack tail + loop-head
# segment with CondBranch). Stage 3 adds WITH handling. After Stage
# 3, all FSM-eligible BG bodies route through this splitter.
#
# Tail kinds (the ENTIRETY of shape handling -- new suspend kinds
# add a new Tail variant here, not a new emit function):
#
#   Done                 final segment, signal wg.done() + Done
#   IoSuspend            suspending stdlib call (sleep, readFile,
#                          tcpRead, etc.) tagged via stdlib_def
#   NextSuspend          NEXT on a Promise (register on wg, yield)
#   LockSuspend          (Stage 3) WITH lock acquire
#   LoopBack             (Stage 2) back-edge to a prior segment
#   Goto                 unconditional fall-through (no yield)
#   CondBranch           (Stage 2) if/while head; selects target
#                          segment for next state

module FsmTransform
  module Segments
    Done         = Struct.new(:_) { def kind; :done; end }
    IoSuspend    = Struct.new(:call_node, :stdlib_def, :result_var, :next_index) do
      def kind; :io; end
    end
    NextSuspend  = Struct.new(:promise_ast, :result_var, :next_index) do
      def kind; :next; end
    end
    # LockSuspend: ONE cap's lock-acquire suspend.
    #
    #   cap              this cap's capability hash (resolved type,
    #                    var_node, alias, etc. from the parser).
    #   prior_caps       caps already acquired earlier in the chain
    #                    (released in reverse order on this cap's
    #                    acquire-fail path).
    #   post_acquire_idx where to transition once this cap's lock is
    #                    successfully held: either the next cap's
    #                    LockSuspend spec idx (multi-cap chain) or
    #                    the CS body entry idx (last cap). Set by
    #                    the splitter; the Emit fan-out routes
    #                    LockTry/WokenCheck success through a
    #                    one-step `held_set` stub that flips this
    #                    cap's `__lock_held_<i>` flag and Gotos here.
    #   next_index       post-WITH continuation: where the splitter-
    #                    emitted release segment Gotos after running
    #                    explicit unlocks. Acquire-fail with :pass /
    #                    :block clauses Gotos here too.
    #
    # Multi-cap WITH = a chain of LockSuspend specs (one per cap)
    # followed by the recursively-split CS body (produced by the
    # splitter, may itself contain suspends) and a release segment
    # that explicitly unlocks every cap.
    LockSuspend  = Struct.new(:with_node, :cap, :prior_caps,
                              :post_acquire_idx, :next_index) do
      def kind; :lock; end
    end
    LoopBack     = Struct.new(:target_index) do
      def kind; :loop_back; end
    end
    Goto         = Struct.new(:target_index) do
      def kind; :goto; end
    end
    CondBranch   = Struct.new(:cond_ast, :then_index, :else_index) do
      def kind; :cond_branch; end
    end

    # A segment is a list of AST::Stmt nodes followed by a Tail.
    Segment = Struct.new(:index, :stmts, :tail)

    module_function

    # Public entry. Returns [Segment, ...] on success, nil if the
    # body contains a shape the splitter doesn't handle.
    #
    # Two shapes:
    #   - Linear: top-level stmts and top-level suspends only (Stage 1).
    #   - WhileLoop+NEXT: pre-stmts + a WhileLoop containing a single
    #     top-level NEXT (no IO suspend, no nested suspends) +
    #     post-stmts. Produces a 5-segment graph with CondJump head
    #     and LoopBack edge (Stage 2).
    #
    # Adding new shapes (IF with suspend, WhileLoop+IO, etc.) extends
    # this method's case dispatch + adds a new tail variant if needed.
    def split(body, lowering)
      # Rewrite pipeline+IO shapes (`readFile(p) |> stage`) into
      # linear stmts so the standard splitter sees the suspending
      # call at top level.
      body = rewrite_pipeline_io(body)

      if (loop_segments = split_while_loop_next(body))
        return loop_segments
      end

      return nil if contains_unsupported_shape?(body)

      segments = []
      current_stmts = []

      flush = lambda do |tail|
        segments << Segment.new(segments.length, current_stmts, tail)
        current_stmts = []
      end

      body.each do |stmt|
        suspend = classify_suspend(stmt)
        if suspend
          flush.call(suspend)
        else
          current_stmts << stmt
        end
      end
      flush.call(Done.new(nil))

      segments
    end

    # Stage 2 splitter: pre-stmts + WhileLoop containing one top-level
    # suspend (NEXT or IO) + post-stmts. Returns segments or nil if
    # the shape doesn't match.
    #
    # Output layout (5 segments, indices 0..4):
    #   0  pre              -- Goto(1)
    #   1  []  (cond head)  -- CondJump(cond, 2, 4)
    #   2  loop_pre         -- NextSuspend / IoSuspend -> 3
    #   3  loop_post        -- LoopBack(1)
    #   4  post             -- Done
    def split_while_loop_next(body)
      return nil unless body.is_a?(Array)

      # Find the WhileLoop. There must be exactly one; pre/post must
      # be linear (no suspends, no nested control-flow with suspends).
      loop_idx = nil
      body.each_with_index do |stmt, i|
        case stmt
        when AST::WhileLoop, AST::WhileBindLoop
          if contains_suspend_anywhere?(stmt.do_branch)
            return nil if loop_idx
            loop_idx = i
          end
        end
      end
      return nil if loop_idx.nil?

      pre  = body[0...loop_idx]
      post = body[(loop_idx + 1)..] || []
      pre.each  { |s| return nil if contains_suspend_anywhere?([s]) }
      post.each { |s| return nil if contains_suspend_anywhere?([s]) }

      loop_node = body[loop_idx]
      loop_body = loop_node.do_branch.is_a?(Array) ?
                    loop_node.do_branch : [loop_node.do_branch]

      # Find the single suspend inside the loop body. Accept either a
      # top-level NEXT (B2-LOOP+NEXT shape) or a top-level IO call
      # with stdlib_def fsm_setup template (B2-LOOP+IO shape -- the
      # accept-loop / read-loop pattern). Reject multiple suspends or
      # nested suspends.
      sus_idx = nil
      sus_tail = nil
      loop_body.each_with_index do |s, j|
        sus = classify_suspend(s)
        if sus.is_a?(NextSuspend) || sus.is_a?(IoSuspend)
          return nil if sus_idx        # multiple suspends in loop body
          sus_idx = j
          sus_tail = sus
        elsif sus.nil?
          # Nested suspend inside an expression -- bail.
          return nil if contains_suspend_anywhere?([s])
        end
      end
      return nil if sus_idx.nil?

      loop_pre  = loop_body[0...sus_idx]
      loop_post = loop_body[(sus_idx + 1)..] || []

      # Reject if loop_pre/loop_post contain further suspends (Stage 3).
      loop_pre.each  { |s| return nil if contains_suspend_anywhere?([s]) }
      loop_post.each { |s| return nil if contains_suspend_anywhere?([s]) }

      cond_node = loop_node.respond_to?(:condition) ? loop_node.condition : nil
      return nil if cond_node.nil?

      [
        Segment.new(0, pre,        Goto.new(1)),
        Segment.new(1, [],         CondBranch.new(cond_node, 2, 4)),
        Segment.new(2, loop_pre,   sus_tail),        # NextSuspend or IoSuspend
        Segment.new(3, loop_post,  LoopBack.new(1)),
        Segment.new(4, post,       Done.new(nil)),
      ]
    end

    # Stage 1 punt: anything outside top-level linear stmts +
    # top-level suspends is not yet handled.
    def contains_unsupported_shape?(body)
      body.any? { |stmt| stmt_unsupported?(stmt) }
    end

    def stmt_unsupported?(stmt)
      case stmt
      when AST::WhileLoop      then contains_suspend_anywhere?(stmt.do_branch)
      when AST::WhileBindLoop  then contains_suspend_anywhere?(stmt.do_branch)
      when AST::ForRange       then contains_suspend_anywhere?(stmt.body)
      when AST::ForEach        then contains_suspend_anywhere?(stmt.body)
      when AST::WithBlock      then true   # always treat as Stage 3
      when AST::IfStatement
        branches = [stmt.then_branch, stmt.else_branch].compact
        branches.any? { |b| contains_suspend_anywhere?(b) }
      when AST::CatchBlock     then true   # Stage 4 territory
      else
        # Top-level linear stmt (assign, var decl, bare expr).
        # Top-level suspends are handled by the splitter; nested
        # suspends (e.g. `f(NEXT p)` -- NEXT inside an arg) are
        # Stage 4 territory and not currently supported by the
        # legacy emitters either, so they fall outside FSM
        # eligibility upstream. Treat as supported here.
        false
      end
    end

    # Recursive scan for any suspend anywhere in a subtree --
    # used to reject control-flow constructs that contain
    # suspends (Stage 1 punts those to the legacy emitters).
    def contains_suspend_anywhere?(stmts)
      Array(stmts).any? do |stmt|
        case stmt
        when AST::WhileLoop, AST::WhileBindLoop
          contains_suspend_anywhere?(stmt.do_branch)
        when AST::ForRange, AST::ForEach
          contains_suspend_anywhere?(stmt.body)
        when AST::WithBlock
          true
        when AST::IfStatement
          contains_suspend_anywhere?(stmt.then_branch) ||
            contains_suspend_anywhere?(stmt.else_branch || [])
        when AST::CatchBlock
          true
        else
          !classify_suspend(stmt).nil?
        end
      end
    end

    # Identify the suspend tail (if any) that this top-level stmt
    # represents. Returns one of IoSuspend / NextSuspend / nil.
    def classify_suspend(stmt)
      case stmt
      when AST::FuncCall, AST::MethodCall
        if io_suspending_call?(stmt)
          IoSuspend.new(stmt, stmt.matched_stdlib_def, nil)
        end
      when AST::NextExpr
        NextSuspend.new(stmt.expr, nil)
      when AST::VarDecl, AST::BindExpr
        case stmt.value
        when AST::FuncCall, AST::MethodCall
          if io_suspending_call?(stmt.value)
            IoSuspend.new(stmt.value, stmt.value.matched_stdlib_def, stmt.name)
          end
        when AST::NextExpr
          NextSuspend.new(stmt.value.expr, stmt.name)
        end
      when AST::Assignment
        case stmt.value
        when AST::FuncCall, AST::MethodCall
          if io_suspending_call?(stmt.value)
            name = stmt.name.is_a?(String) ? stmt.name : nil
            IoSuspend.new(stmt.value, stmt.value.matched_stdlib_def, name)
          end
        when AST::NextExpr
          name = stmt.name.is_a?(String) ? stmt.name : nil
          NextSuspend.new(stmt.value.expr, name)
        end
      end
    end

    # An IO suspend is a stdlib call with both :suspends and
    # :fsm_setup metadata -- the FSM template tells us how to set
    # up the suspend.
    def io_suspending_call?(call_node)
      return false unless call_node.respond_to?(:matched_stdlib_def)
      md = call_node.matched_stdlib_def
      !!(md && md[:suspends] && md[:fsm_setup])
    end

    def suspending_call?(expr)
      (expr.is_a?(AST::FuncCall) || expr.is_a?(AST::MethodCall)) &&
        io_suspending_call?(expr)
    end

    # Rewrite top-level `LHS |> RHS` stmts whose synthesized call
    # would suspend. Lifts the suspending portion into a synthetic
    # BindExpr ahead of the post-stage chain so the standard
    # splitter sees the suspend at top level.
    #
    # Cases handled:
    #   1. LHS is a suspending FuncCall (e.g. `readFile(p) |> g`):
    #      lift LHS as `__pipe_v_K = readFile(p)`; replace LHS with
    #      `Identifier("__pipe_v_K")` carrying the call's full_type.
    #
    # NOT yet handled (kept as-is, falls to stackful):
    #   - `path |> readFile |> g` (RHS is a suspending Identifier;
    #     the suspending call is synthesized, not in the AST)
    #   - `BindExpr(:decl, name, value=BinaryOp(:SMOOTH))`
    #     (suspending pipeline as the value of a bind)
    #   - Multi-stage chains where the suspend isn't at the LHS-most
    #     position
    def rewrite_pipeline_io(body)
      return body unless body.is_a?(Array)
      out = []
      pipe_counter = 0
      body.each do |stmt|
        if stmt.is_a?(AST::BinaryOp) && stmt.op == :SMOOTH &&
           io_suspending_call?(stmt.left)
          synth_name = "__pipe_v_#{pipe_counter}"
          pipe_counter += 1

          tok = stmt.left.respond_to?(:token) ? stmt.left.token : nil
          bind = AST::BindExpr.new(tok, synth_name, nil, stmt.left)
          bind.mode = :decl
          bind.full_type = stmt.left.full_type if stmt.left.respond_to?(:full_type)
          out << bind

          ident = AST::Identifier.new(tok, synth_name)
          ident.full_type = stmt.left.full_type if stmt.left.respond_to?(:full_type)

          rewritten = AST::BinaryOp.new(stmt.token, ident, stmt.op, stmt.right)
          rewritten.full_type = stmt.full_type if stmt.respond_to?(:full_type)
          out << rewritten
        else
          out << stmt
        end
      end
      out
    end
  end
end
