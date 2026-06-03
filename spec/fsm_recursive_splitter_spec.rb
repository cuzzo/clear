require 'bundler/setup'
require 'set'
require_relative '../src/ast/lexer'
require_relative '../src/ast/parser'
require_relative '../src/ast/type'
require_relative '../src/mir/mir'
require_relative '../src/mir/fsm_transform/segments'
require_relative '../src/mir/fsm_transform/recursive_splitter'

# Tests for FsmTransform::RecursiveSplitter -- the unified
# AST-walker that produces flat segment graphs for any nested
# combination of WhileLoop / ForRange / IfStatement with
# IO / NEXT suspends.

RSpec.describe FsmTransform::RecursiveSplitter do
  describe "synthetic FSM ctx fragments" do
    it "renders ctx fields late and passes through plain strings" do
      step_ref = FsmTransform::Segments::CtxFieldRef.new(name: "step")
      fragment = FsmTransform::Segments::SyntheticZig.new(parts: [
        step_ref, " = ", step_ref, " + 1;",
      ])

      expect(FsmTransform::Segments.render_synthetic_zig(fragment, "__ctx_4"))
        .to eq("__ctx_4.step = __ctx_4.step + 1;")
      expect(FsmTransform::Segments.render_synthetic_zig("return;", "__ctx_4"))
        .to eq("return;")
    end
  end

  # Minimal lowering double: returns the input unchanged for AST
  # nodes (the splitter uses .lower and .emit_expr to render
  # cond / start / end exprs; for shape tests we just need a
  # string back).
  let(:lowering) {
    Class.new {
      def lower(node); node; end
      def emit_expr(node)
        case node
        when AST::Identifier   then node.name
        when AST::Literal      then node.value.to_s
        when AST::BinaryOp     then "#{emit_expr(node.left)} #{render_op(node.op)} #{emit_expr(node.right)}"
        else                        node.respond_to?(:to_s) ? node.to_s : "<expr>"
        end
      end
      def render_op(op)
        case op
        when :LESSTHAN, :LT then "<"
        when :PLUS          then "+"
        else op.to_s
        end
      end
      # The splitter's WITH path now requires per-cap metadata
      # (lock_field_ref, alias_data_ref, unlock_method) and a
      # capture-map scoping helper so the recursively-split CS body
      # can resolve the alias identifier. Provide deterministic
      # stubs for the spec.
      def fsm_cap_metadata(cap, _with_node, ctx_id, _captured)
        var_name = cap[:var_node].respond_to?(:name) ? cap[:var_node].name : "x"
        alias_name = cap[:alias] || var_name
        ref = "__ctx_#{ctx_id}.#{var_name}"
        {
          cap:            cap,
          lock_kind:      :mutex_excl,
          try_method:     "tryLockForFsm",
          unlock_method:  "unlock",
          lock_field_ref: ref,
          alias_name:     alias_name,
          alias_data_ref: "(#{ref}.data)",
          retries:        0,
        }
      end
      def with_fiber_capture_map(_entries, rt_override: nil); yield; end
    }.new
  }

  let(:default_ctx) { { id: 0, captured: {}, bg_rt: "__rt_bg0" } }

  FUTURE_TYPE = Type.new(:"~Int64")

  def ident(name)
    n = AST::Identifier.new(nil, name)
    n.instance_variable_set(:@full_type, FUTURE_TYPE)
    def n.full_type; @full_type; end
    n
  end
  def lit(v); AST::Literal.new(nil, :Int64, v, nil); end
  def binop(left, op, right); AST::BinaryOp.new(nil, left, op, right); end
  def while_stmt(cond, body); AST::WhileLoop.new(nil, cond, body, nil); end
  def for_range(var, s, e, body); AST::ForRange.new(nil, var, s, e, false, body, nil, nil); end
  def for_each(var, collection, body); AST::ForEach.new(nil, var, collection, body, nil, false); end
  def if_stmt(cond, then_b, else_b); AST::IfStatement.new(nil, cond, then_b, else_b); end
  def segments_for(segment_list)
    expect(segment_list).not_to be_nil
    segment_list.segments
  end

  def io_call(name, stdlib_def)
    fc = Struct.new(:args, :receiver, :matched_stdlib_def, :full_type).new(
      [], nil, stdlib_def, :Void)
    fc
  end

  let(:io_def) { { suspends: true, fsm_setup: [] } }

  describe "flat shapes (sanity)" do
    it "empty body returns a single Done segment without renumbering" do
      segment_list = FsmTransform::RecursiveSplitter.split([], lowering)
      segs = segments_for(segment_list)

      expect(segs.length).to eq(1)
      expect(segs.first.index).to eq(0)
      expect(segs.first.tail).to be_a(FsmTransform::Segments::Done)
      expect(segment_list.alias_overrides_by_index).to eq({})
    end

    it "single suspend at top level" do
      stmt = io_call("sleep", io_def)
      # In the AST this would be a stmt-level FuncCall. classify_suspend
      # in Segments handles AST::FuncCall; we use the generic Struct
      # which doesn't match. Test with NEXT instead.
      promise = ident("p")
      next_expr = AST::NextExpr.new(nil, promise)
      segment_list = FsmTransform::RecursiveSplitter.split([next_expr], lowering)
      segs = segments_for(segment_list)
      expect(segs.first.tail).to be_a(FsmTransform::Segments::NextSuspend)
      # The suspend's next_index points at the Done segment.
      done_idx = segs.find_index { |s| s.tail.is_a?(FsmTransform::Segments::Done) }
      expect(segs.first.tail.next_index).to eq(done_idx)
    end

    it "linear stmts only (no suspend) returns Goto-to-Done" do
      stmts = [lit(1), lit(2)]
      segment_list = FsmTransform::RecursiveSplitter.split(stmts, lowering)
      segs = segments_for(segment_list)
      expect(segs.first.tail).to be_a(FsmTransform::Segments::Goto)
      done_idx = segs.find_index { |s| s.tail.is_a?(FsmTransform::Segments::Done) }
      expect(segs.first.tail.target_index).to eq(done_idx)
    end
  end

  describe "edge guards" do
    it "raises if a reserved builder segment is finalized unfilled" do
      builder = FsmTransform::RecursiveSplitter::Builder.new
      builder.reserve_index

      expect { builder.finalize }.to raise_error(/unfilled segments/)
    end

    it "rejects catch blocks and unhandled pivot statements" do
      catch_block = AST::CatchBlock.new(nil, [], nil)
      expect(FsmTransform::RecursiveSplitter.contains_unsupported?([catch_block]))
        .to eq(true)

      builder = FsmTransform::RecursiveSplitter::Builder.new
      expect {
        FsmTransform::RecursiveSplitter.emit_pivot(AST::PassStmt.new(nil), 0, builder, lowering)
      }.to raise_error(FsmTransform::RecursiveSplitter::UnsupportedShape, /Unhandled pivot kind/)
    end

    it "rejects unsupported and unknown foreach descriptor shapes" do
      promise = ident("p")
      next_expr = AST::NextExpr.new(nil, promise)

      unsupported_coll = AST::Identifier.new(nil, "unsupported_items")
      unsupported_coll.full_type = Type.new(:Any)
      expect(FsmTransform::RecursiveSplitter.split(
        [for_each("v", unsupported_coll, [next_expr])], lowering)).to be_nil

      unknown_type = Type.new(:UnknownCollection)
      unknown_type.define_singleton_method(:fsm_foreach_descriptor) do
        TypeFsmForEachDescriptor.new(kind: :unknown, var_zig_type: "i64")
      end
      unknown_coll = AST::Identifier.new(nil, "unknown_items")
      unknown_coll.full_type = unknown_type
      expect(FsmTransform::RecursiveSplitter.split(
        [for_each("v", unknown_coll, [next_expr])], lowering)).to be_nil
    end

    it "returns nil when expression lowering fails" do
      bad_lowering = Class.new {
        def lower(_node)
          raise "bad lower"
        end
      }.new

      expect(FsmTransform::RecursiveSplitter.lower_to_zig(ident("x"), bad_lowering))
        .to be_nil
    end

    it "remaps loop-back tails and passes through unknown tails" do
      remapped = FsmTransform::RecursiveSplitter.remap_tail(
        FsmTransform::Segments::LoopBack.new(4),
        { 4 => 1 },
      )
      passthrough = Object.new

      expect(remapped.target_index).to eq(1)
      expect(FsmTransform::RecursiveSplitter.remap_tail(passthrough, {}))
        .to equal(passthrough)
    end
  end

  describe "WhileLoop with NEXT" do
    it "produces cond + body + done" do
      promise = ident("p")
      next_expr = AST::NextExpr.new(nil, promise)
      cond = binop(ident("i"), :LESSTHAN, lit(3))
      body = [next_expr]
      segment_list = FsmTransform::RecursiveSplitter.split([while_stmt(cond, body)], lowering)
      segs = segments_for(segment_list)
      cond_seg = segs.find { |s| s.tail.is_a?(FsmTransform::Segments::CondBranch) }
      expect(cond_seg).not_to be_nil
      expect(cond_seg.tail.cond_ast).to include("i").and include("<")
      sus_seg = segs.find { |s| s.tail.is_a?(FsmTransform::Segments::NextSuspend) }
      expect(sus_seg).not_to be_nil
      # The suspend's next_index points back to the cond seg (loop back).
      expect(sus_seg.tail.next_index).to eq(cond_seg.index)
    end
  end

  describe "ForRange with NEXT" do
    it "synthesizes init / cond / incr around the body" do
      promise = ident("p")
      next_expr = AST::NextExpr.new(nil, promise)
      stmt = for_range("i", lit(0), lit(3), [next_expr])
      segment_list = FsmTransform::RecursiveSplitter.split([stmt], lowering)
      segs = segments_for(segment_list)
      init_seg = segs.find { |s|
        s.stmts.any? { |st|
          FsmTransform::Segments.render_synthetic_zig(st, "__ctx_9").include?("__ctx_9.__for_")
        }
      }
      expect(init_seg).not_to be_nil
      cond_seg = segs.find { |s| s.tail.is_a?(FsmTransform::Segments::CondBranch) }
      expect(cond_seg).not_to be_nil
      rendered_cond = FsmTransform::Segments.render_synthetic_zig(cond_seg.tail.cond_ast, "__ctx_9")
      expect(rendered_cond).to match(/__ctx_9\.__for_\d+ < 3/)
      incr_seg = segs.find { |s|
        s.stmts.any? { |st|
          rendered = FsmTransform::Segments.render_synthetic_zig(st, "__ctx_9")
          rendered.include?("__ctx_9.__for_") && rendered.include?("+ 1")
        }
      }
      expect(incr_seg).not_to be_nil
      # Synthetic fields registered for the unified emit.
      expect(segment_list.synthetic_fields).to include(/__for_\d+: i64/)
      expect(segment_list.synthetic_fields).to include(/i: i64/)
    end
  end

  describe "ForEach iterator with NEXT" do
    it "synthesizes iterator state and a condition segment" do
      promise = ident("p")
      next_expr = AST::NextExpr.new(nil, promise)
      coll = AST::Identifier.new(nil, "items")
      coll.full_type = Type.new(:"Int64[]", collection: :set)

      segment_list = FsmTransform::RecursiveSplitter.split(
        [for_each("v", coll, [next_expr])], lowering)
      segs = segments_for(segment_list)

      expect(segment_list.synthetic_fields).to include(/v: i64/)
      expect(segment_list.synthetic_fields).to include(/__feiter_\d+:/)
      expect(segment_list.synthetic_fields).to include(/__fehas_\d+: bool/)
      init_seg = segs.find { |s|
        s.stmts.any? { |st|
          FsmTransform::Segments.render_synthetic_zig(st, "__ctx_9").include?("items.keyIterator()")
        }
      }
      expect(init_seg).not_to be_nil
      cond_seg = segs.find { |s|
        s.tail.is_a?(FsmTransform::Segments::CondBranch) &&
          s.stmts.any? { |st|
            FsmTransform::Segments.render_synthetic_zig(st, "__ctx_9").include?(".next()")
          }
      }
      expect(cond_seg).not_to be_nil
      sus_seg = segs.find { |s| s.tail.is_a?(FsmTransform::Segments::NextSuspend) }
      expect(sus_seg.tail.next_index).to eq(cond_seg.index)
    end
  end

  describe "IF with suspend in then-branch" do
    it "produces CondBranch with separate then/else paths" do
      promise = ident("p")
      next_expr = AST::NextExpr.new(nil, promise)
      cond = ident("flag")
      stmts = [if_stmt(cond, [next_expr], nil)]
      segment_list = FsmTransform::RecursiveSplitter.split(stmts, lowering)
      segs = segments_for(segment_list)
      cond_seg = segs.find { |s| s.tail.is_a?(FsmTransform::Segments::CondBranch) }
      expect(cond_seg).not_to be_nil
      # then_index points at a NextSuspend segment
      then_seg = segs[cond_seg.tail.then_index]
      expect(then_seg.tail).to be_a(FsmTransform::Segments::NextSuspend)
      # else_index falls through to Done (no else branch given)
      done_idx = segs.find_index { |s| s.tail.is_a?(FsmTransform::Segments::Done) }
      expect(cond_seg.tail.else_index).to eq(done_idx)
    end
  end

  describe "nested: IF inside WhileLoop body" do
    it "produces a graph with nested CondBranch inside the loop" do
      promise = ident("p")
      next_expr = AST::NextExpr.new(nil, promise)
      inner_if = if_stmt(ident("flag"), [next_expr], nil)
      while_body = [inner_if]
      cond = binop(ident("i"), :LESSTHAN, lit(3))
      segment_list = FsmTransform::RecursiveSplitter.split(
        [while_stmt(cond, while_body)], lowering)
      segs = segments_for(segment_list)
      # There should be at least 2 CondBranch tails: the outer
      # while-cond and the inner if-cond.
      cond_segs = segs.select { |s| s.tail.is_a?(FsmTransform::Segments::CondBranch) }
      expect(cond_segs.length).to be >= 2
      sus_seg = segs.find { |s| s.tail.is_a?(FsmTransform::Segments::NextSuspend) }
      expect(sus_seg).not_to be_nil
    end
  end

  describe "WithBlock with lock-suspending capability" do
    it "produces a LockSuspend segment for a single-cap EXCLUSIVE WITH" do
      cap = AST::Capability.new(capability: :EXCLUSIVE, var_node: ident("lock"))
      with_node = AST::WithBlock.new(nil, [cap], [])
      segment_list = FsmTransform::RecursiveSplitter.split(
        [with_node], lowering, ctx: default_ctx)
      segs = segments_for(segment_list)
      lock_seg = segs.find { |s| s.tail.is_a?(FsmTransform::Segments::LockSuspend) }
      expect(lock_seg).not_to be_nil
      expect(lock_seg.tail.with_node).to equal(with_node)
      # post_acquire_idx points at the recursively-split CS body
      # entry (which Gotos to the release segment, then Done).
      expect(lock_seg.tail.post_acquire_idx).to be_a(Integer)
      expect(lock_seg.tail.prior_caps).to eq([])
    end

    it "produces N LockSuspend segments for an N-cap WITH" do
      cap1 = AST::Capability.new(capability: :EXCLUSIVE, var_node: ident("a"))
      cap2 = AST::Capability.new(capability: :EXCLUSIVE, var_node: ident("b"))
      with_node = AST::WithBlock.new(nil, [cap1, cap2], [])
      segment_list = FsmTransform::RecursiveSplitter.split(
        [with_node], lowering, ctx: default_ctx)
      segs = segments_for(segment_list)
      lock_segs = segs.select { |s|
        s.tail.is_a?(FsmTransform::Segments::LockSuspend)
      }
      expect(lock_segs.length).to eq(2)
      # First cap chains to the second; second's post_acquire goes
      # to the CS body entry (not another cap).
      expect(lock_segs[0].tail.cap).to eq(cap1)
      expect(lock_segs[0].tail.post_acquire_idx).to eq(lock_segs[1].index)
      expect(lock_segs[0].tail.prior_caps).to eq([])
      expect(lock_segs[1].tail.cap).to eq(cap2)
      expect(lock_segs[1].tail.post_acquire_idx).to be_a(Integer)
      expect(lock_segs[1].tail.post_acquire_idx).not_to eq(lock_segs[0].index)
      expect(lock_segs[1].tail.prior_caps).to eq([cap1])
    end

    it "rejects multi-cap WITH where any cap is non-lock-suspending" do
      cap1 = AST::Capability.new(capability: :EXCLUSIVE, var_node: ident("a"))
      cap2 = AST::Capability.new(capability: :infer, var_node: ident("b"))
      with_node = AST::WithBlock.new(nil, [cap1, cap2], [])
      expect(FsmTransform::RecursiveSplitter.split(
        [with_node], lowering, ctx: default_ctx)).to be_nil
    end

    it "supports WITH whose CS body contains a suspend (held flags + destroyTask release)" do
      cap = AST::Capability.new(capability: :EXCLUSIVE, var_node: ident("lock"))
      next_expr = AST::NextExpr.new(nil, ident("p"))
      with_node = AST::WithBlock.new(nil, [cap], [next_expr])
      segment_list = FsmTransform::RecursiveSplitter.split(
        [with_node], lowering, ctx: default_ctx)
      segs = segments_for(segment_list)
      # Both LockSuspend AND a NextSuspend (in the CS body) appear.
      expect(segs.any? { |s| s.tail.is_a?(FsmTransform::Segments::LockSuspend) }).to be true
      expect(segs.any? { |s| s.tail.is_a?(FsmTransform::Segments::NextSuspend) }).to be true
    end
  end
end
