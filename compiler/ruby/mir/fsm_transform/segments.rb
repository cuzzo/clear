# typed: strict
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

require_relative "../../ast/type"
require_relative "../../semantic/capability_plan"

module FsmTransform
  module Segments
    extend T::Sig
    SegmentBody = T.type_alias { T::Array[AST::Locatable] }
    LockWithNode = T.type_alias { AST::WithBlock }
    LockCap = T.type_alias { T.any(CapabilityPlan::CapabilityTransition, Symbol) }

    Done         = Struct.new(:_) do
      extend T::Sig
      sig { returns(Symbol) }
      def kind; :done; end
    end
    IoSuspend    = Struct.new(:call_node, :stdlib_def, :result_var, :next_index) do
      extend T::Sig
      sig { returns(Symbol) }
      def kind; :io; end

      sig { returns(T::Boolean) }
      def suspend?; true; end

      sig { params(index: T.nilable(Integer)).returns(IoSuspend) }
      def with_next_index(index)
        IoSuspend.new(call_node, stdlib_def, result_var, index)
      end

      sig { returns(T.nilable(Type)) }
      def result_type
        return nil unless call_node

        node = T.cast(call_node, AST::Node)
        type_object = node.type_object
        raise "FSM IO suspend result: missing type info" unless type_object
        concrete_type = T.cast(type_object, Type)
        raise "FSM IO suspend result: unresolved type info" if concrete_type.untyped?
        concrete_type
      end
    end
    NextSuspend  = Struct.new(:promise_ast, :result_var, :next_index) do
      extend T::Sig
      sig { returns(Symbol) }
      def kind; :next; end

      sig { returns(T::Boolean) }
      def suspend?; true; end

      sig { params(index: T.nilable(Integer)).returns(NextSuspend) }
      def with_next_index(index)
        NextSuspend.new(promise_ast, result_var, index)
      end

      sig { returns(T.nilable(Type)) }
      def result_type
        return nil unless promise_ast

        node = T.cast(promise_ast, AST::Node)
        type_object = node.type_object
        raise "FSM NEXT suspend result: missing type info" unless type_object
        concrete_type = T.cast(type_object, Type)
        raise "FSM NEXT suspend result: unresolved type info" if concrete_type.untyped?
        pt = Type.new(concrete_type)
        pt.tense_type
      end
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
                              :post_acquire_idx, :next_index,
                              :lock_index, :prior_lock_indices) do
      extend T::Sig

      sig do
        params(
          with_node: LockWithNode,
          cap: LockCap,
          prior_caps: T::Array[LockCap],
          post_acquire_idx: T.nilable(Integer),
          next_index: T.nilable(Integer),
          lock_index: T.nilable(Integer),
          prior_lock_indices: T::Array[Integer],
        ).void
      end
      def initialize(with_node, cap, prior_caps, post_acquire_idx, next_index, lock_index = nil, prior_lock_indices = [])
        super(with_node, cap, prior_caps, post_acquire_idx, next_index, lock_index || 0, prior_lock_indices)
      end

      sig { returns(Symbol) }
      def kind; :lock; end
    end
    LoopBack     = Struct.new(:target_index) do
      extend T::Sig
      sig { returns(Symbol) }
      def kind; :loop_back; end
    end
    Goto         = Struct.new(:target_index) do
      extend T::Sig
      sig { returns(Symbol) }
      def kind; :goto; end
    end
    CondBranch   = Struct.new(:cond_ast, :then_index, :else_index) do
      extend T::Sig
      sig { returns(Symbol) }
      def kind; :cond_branch; end
    end

    # A segment is a list of AST::Stmt nodes followed by a Tail.
    Segment = Struct.new(:index, :stmts, :tail)
    SegmentTail = T.type_alias { T.any(Done, IoSuspend, NextSuspend, LockSuspend, LoopBack, Goto, CondBranch) }
    SuspendTail = T.type_alias { T.any(IoSuspend, NextSuspend, LockSuspend) }

    class SplitResult < T::Struct
      const :segments, T::Array[Segment]
    end


    sig { params(tail: T.nilable(SegmentTail)).returns(T::Boolean) }
    def self.suspend_tail?(tail)
      tail.is_a?(IoSuspend) || tail.is_a?(NextSuspend) || tail.is_a?(LockSuspend)
    end

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
    sig { params(body: SegmentBody, lowering: T.untyped).returns(T.nilable(SplitResult)) }
    def self.split(body, lowering)
      # Rewrite pipeline+IO shapes (`readFile(p) |> stage`) into
      # linear stmts so the standard splitter sees the suspending
      # call at top level.
      T.bind(self, T.untyped) rescue nil
      body = rewrite_pipeline_io(body)

      if (loop_result = split_while_loop_next(body))
        return loop_result
      end

      return nil if contains_unsupported_shape?(body)

      segments = T.let([], T::Array[Segment])
      current_stmts = T.let([], SegmentBody)

      body.each do |stmt|
        suspend = classify_suspend(stmt)
        if suspend
          segments << Segment.new(segments.length, current_stmts, suspend)
          current_stmts = []
        else
          current_stmts << stmt
        end
      end
      segments << Segment.new(segments.length, current_stmts, Done.new(nil))

      SplitResult.new(segments: segments)
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
    sig { params(body: SegmentBody).returns(T.nilable(SplitResult)) }
    def self.split_while_loop_next(body)
      T.bind(self, T.untyped) rescue nil
      return nil unless body.is_a?(Array)

      # Find the WhileLoop. There must be exactly one; pre/post must
      # be linear (no suspends, no nested control-flow with suspends).
      loop_idx = T.let(nil, T.nilable(Integer))
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

      pre = segment_slice(body, 0, loop_idx)
      post = segment_slice(body, loop_idx + 1, body.length)
      pre.each  { |s| return nil if contains_suspend_anywhere?([s]) }
      post.each { |s| return nil if contains_suspend_anywhere?([s]) }

      loop_node = T.must(body[loop_idx])
      loop_body = loop_body_for(loop_node)
      return nil unless loop_body

      # Find the single suspend inside the loop body. Accept either a
      # top-level NEXT (B2-LOOP+NEXT shape) or a top-level IO call
      # with stdlib_def fsm_setup template (B2-LOOP+IO shape -- the
      # accept-loop / read-loop pattern). Reject multiple suspends or
      # nested suspends.
      sus_idx = T.let(nil, T.nilable(Integer))
      sus_tail = T.let(nil, T.nilable(SegmentTail))
      index = 0
      while index < loop_body.length
        s = loop_body.fetch(index)
        sus = classify_suspend(s)
        if sus.nil?
          # Nested suspend inside an expression -- bail.
          return nil if contains_suspend_anywhere?([s])
        else
          return nil unless sus_idx.nil? # multiple suspends in loop body
          sus_idx = index
          sus_tail = sus
        end
        index += 1
      end
      return nil if sus_idx.nil?

      loop_pre = segment_slice(loop_body, 0, sus_idx)
      loop_post = segment_slice(loop_body, sus_idx + 1, loop_body.length)

      # Reject if loop_pre/loop_post contain further suspends (Stage 3).
      loop_pre.each  { |s| return nil if contains_suspend_anywhere?([s]) }
      loop_post.each { |s| return nil if contains_suspend_anywhere?([s]) }

      cond_node = loop_condition_for(loop_node)
      return nil if cond_node.nil?

      segments = [
        Segment.new(0, pre,        Goto.new(1)),
        Segment.new(1, [],         CondBranch.new(cond_node, 2, 4)),
        Segment.new(2, loop_pre,   sus_tail),        # NextSuspend or IoSuspend
        Segment.new(3, loop_post,  LoopBack.new(1)),
        Segment.new(4, post,       Done.new(nil)),
      ]
      SplitResult.new(segments: segments)
    end

    sig { params(body: SegmentBody, start_index: Integer, end_index: Integer).returns(SegmentBody) }
    def self.segment_slice(body, start_index, end_index)
      result = T.let([], SegmentBody)
      index = start_index
      while index < end_index
        result << T.must(body[index])
        index += 1
      end
      result
    end
    private_class_method :segment_slice

    sig { params(node: AST::Locatable).returns(T.nilable(SegmentBody)) }
    def self.loop_body_for(node)
      case node
      when AST::WhileLoop
        node.do_branch
      when AST::WhileBindLoop
        node.do_branch
      else
        nil
      end
    end
    private_class_method :loop_body_for

    sig { params(node: AST::Locatable).returns(T.nilable(AST::Locatable)) }
    def self.loop_condition_for(node)
      case node
      when AST::WhileLoop
        T.cast(node.condition, AST::Locatable)
      when AST::WhileBindLoop
        T.cast(node.condition, AST::Locatable)
      else
        nil
      end
    end
    private_class_method :loop_condition_for

    # Stage 1 punt: anything outside top-level linear stmts +
    # top-level suspends is not yet handled.
    sig { params(body: SegmentBody).returns(T::Boolean) }
    def self.contains_unsupported_shape?(body)
      T.bind(self, T.untyped) rescue nil
      body.any? { |stmt| stmt_unsupported?(stmt) }
    end

    sig { params(stmt: AST::Node).returns(T::Boolean) }
    def self.stmt_unsupported?(stmt)
      T.bind(self, T.untyped) rescue nil
      case stmt
      when AST::WhileLoop, AST::WhileBindLoop
        contains_suspend_anywhere?(stmt.do_branch)
      when AST::ForRange, AST::ForEach
        contains_suspend_anywhere?(stmt.body)
      when AST::WithBlock, AST::CatchBlock
        true   # Stage 3/4 territory.
      when AST::IfStatement
        return true if contains_suspend_anywhere?(stmt.then_branch)

        else_branch = stmt.else_branch
        else_branch ? contains_suspend_anywhere?(else_branch) : false
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
  sig { params(stmts: T.nilable(SegmentBody)).returns(T::Boolean) }
  def self.contains_suspend_anywhere?(stmts)
    T.bind(self, T.untyped) rescue nil
    return false if stmts.nil?

    items = stmts
    index = 0
    while index < items.length
      stmt = items.fetch(index)
      case stmt
      when AST::WhileLoop
        loop_stmt = T.cast(stmt, AST::WhileLoop)
        return true if contains_suspend_anywhere?(loop_stmt.do_branch)
      when AST::WhileBindLoop
        loop_stmt = T.cast(stmt, AST::WhileBindLoop)
        return true if contains_suspend_anywhere?(loop_stmt.do_branch)
      when AST::ForRange
        range_stmt = T.cast(stmt, AST::ForRange)
        return true if contains_suspend_anywhere?(range_stmt.body)
      when AST::ForEach
        each_stmt = T.cast(stmt, AST::ForEach)
        return true if contains_suspend_anywhere?(each_stmt.body)
      when AST::WithBlock, AST::CatchBlock
        return true
      when AST::IfStatement
        if_stmt = T.cast(stmt, AST::IfStatement)
        return true if contains_suspend_anywhere?(if_stmt.then_branch)
        else_branch = if_stmt.else_branch
        unless else_branch.nil?
          return true if contains_suspend_anywhere?(else_branch)
        end
      else
        return true unless classify_suspend(stmt).nil?
      end
      index += 1
    end
    false
  end

    # Identify the suspend tail (if any) that this top-level stmt
    # represents. Returns one of IoSuspend / NextSuspend / nil.
    sig { params(stmt: AST::Node).returns(T.nilable(SegmentTail)) }
    def self.classify_suspend(stmt)
      T.bind(self, T.untyped) rescue nil
      case stmt
      when AST::FuncCall, AST::MethodCall, AST::NextExpr
        suspend_for(stmt, nil)
      when AST::VarDecl, AST::BindExpr
        suspend_for(stmt.value, stmt.name)
      when AST::Assignment
        suspend_for(stmt.value, stmt.name.is_a?(String) ? stmt.name : nil)
      when AST::DestructuringAssignment
        suspend_for(stmt.value, nil)
      end
    end

    # Classify a value-expression as a suspend point. Was inlined as the
    # identical FuncCall/MethodCall|NextExpr case 3x (top-level, VarDecl/
    # BindExpr value, Assignment value -- decomplex degenerate-union /
    # Missing-Abstraction). result_var is the binding name (nil if none).
    sig { params(v: T.nilable(AST::Node), name: T.nilable(String)).returns(T.nilable(SegmentTail)) }
    def self.suspend_for(v, name)
      T.bind(self, T.untyped) rescue nil
      return nil if v.nil?

      value = T.must(v)
      case value
      when AST::FuncCall, AST::MethodCall
        IoSuspend.new(value, value.matched_stdlib_def, name) if io_suspending_call?(value)
      when AST::NextExpr
        NextSuspend.new(value.expr, name)
      end
    end

    # An IO suspend is a stdlib call with both :suspends and
    # :fsm_setup metadata -- the FSM template tells us how to set
    # up the suspend.
    sig { params(call_node: T.any(AST::FuncCall, AST::MethodCall)).returns(T::Boolean) }
    def self.io_suspending_call?(call_node)
      T.bind(self, T.untyped) rescue nil
      md = call_node.matched_stdlib_def
      !!(md&.intrinsic_suspends? && md.intrinsic_contract.behavior.fsm_setup_present)
    end

    sig { params(expr: AST::Node).returns(T::Boolean) }
    def self.suspending_call?(expr)
      T.bind(self, T.untyped) rescue nil
      (AST.call?(expr)) &&
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
    sig { params(body: SegmentBody).returns(SegmentBody) }
    def self.rewrite_pipeline_io(body)
      T.bind(self, T.untyped) rescue nil
      return body unless body.is_a?(Array)
      out = []
      pipe_counter = 0
      body.each do |stmt|
        if stmt.is_a?(AST::BinaryOp) && stmt.smooth? &&
           io_suspending_call?(stmt.left)
          synth_name = "__pipe_v_#{pipe_counter}"
          pipe_counter += 1

          tok = stmt.left.token
          bind = AST::BindExpr.new(tok, synth_name, nil, stmt.left)
          bind.mode = :decl
          AST.stamp_synthetic_type!(bind, stmt.left.full_type!(context: "FSM pipeline split"), context: "synthetic AST type")
          out << bind

          ident = AST::Identifier.new(tok, synth_name)
          AST.stamp_synthetic_type!(ident, stmt.left.full_type!(context: "FSM pipeline split"), context: "synthetic AST type")
          rewritten = AST::BinaryOp.new(stmt.token, ident, stmt.op, stmt.right)
          AST.stamp_synthetic_type!(rewritten, stmt.full_type!(context: "FSM pipeline split"), context: "synthetic AST type")
          out << rewritten
        else
          out << stmt
        end
      end
      out
    end
    private_class_method :contains_suspend_anywhere?
    private_class_method :contains_unsupported_shape?
    private_class_method :io_suspending_call?
    private_class_method :rewrite_pipeline_io
    private_class_method :split_while_loop_next
    private_class_method :stmt_unsupported?
    private_class_method :suspend_for

end
end
