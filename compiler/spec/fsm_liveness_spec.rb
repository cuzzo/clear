require 'bundler/setup'
require 'set'
require_relative '../ruby/ast/lexer' unless defined?(Lexer)
require_relative '../ruby/ast/parser' unless defined?(ClearParser)
require_relative '../ruby/ast/type' unless defined?(Type)
require_relative '../ruby/mir/mir' unless defined?(MIR::StdlibDefFsCoercion)
require_relative '../ruby/mir/fsm_transform/segments' unless defined?(FsmTransform::Segments::SplitResult)
require_relative '../ruby/mir/fsm_transform/liveness' unless defined?(FsmTransform::Liveness::CrossSegmentVarFact)

# Tests for FsmTransform::Liveness, the cross-segment live-set analysis
# that drives FSM ctx field decls. The analysis MUST flag:
#   (1) decls in segment K that are read in segment K+1+
#   (2) decls in segment K whose value is referenced by the suspend
#       tail's call args (charged to seg K+1 by collect_tail_uses
#       since the kernel reads them after the body returns)
# WITHOUT flagging decls used only within their own segment's body.

RSpec.describe FsmTransform::Liveness do
  # Build a fake stdlib_def so io_suspending_call? returns true.
  let(:io_def) { { suspends: true, fsm_setup: [] } }

  # Helper: build a minimal AST::BindExpr (decl mode) by hand.
  def bind_decl(name, value_node, full_type: nil)
    be = AST::BindExpr.new(nil, name, nil, value_node)
    be.mode = :decl
    be.full_type = full_type if full_type
    be
  end

  def ident(name, full_type: nil)
    n = AST::Identifier.new(nil, name)
    n.full_type = full_type if full_type
    n
  end

  def io_call(name, args, _stdlib_def)
    AST::FuncCall.new(nil, name, args).tap { |call| call.full_type = :Void }
  end

  describe "cross-segment promotion" do
    it "flags a pre-decl read in the post segment" do
      pre_x = bind_decl("x", AST::Literal.new(42, :Int64), full_type: :Int64)
      post_use = AST::ExprStmt.new(ident("x")) rescue ident("x")

      seg0 = FsmTransform::Segments::Segment.new(0, [pre_x],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [post_use],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })
      expect(result.cross_segment_vars).to have_key("x")
      fact = result.cross_segment_vars.fetch("x")
      expect(fact).to be_a(FsmTransform::Liveness::CrossSegmentVarFact)
      expect(fact.type_info).to eq(Type.new(:Int64))
      expect(fact.first_def_seg).to eq(0)
      expect(fact.last_use_seg).to eq(1)
    end

    it "flags a pre-decl referenced in the suspend call's args" do
      pre_buf = bind_decl("buf", AST::Literal.new("''", :String), full_type: :String)
      # suspend: writeFile(path, buf) -- buf is in args
      arg_buf = ident("buf")
      seg0 = FsmTransform::Segments::Segment.new(0, [pre_buf],
        FsmTransform::Segments::IoSuspend.new(io_call("writeFile", [arg_buf], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })
      expect(result.cross_segment_vars).to have_key("buf")
    end

    it "flags a pre-decl referenced by the suspend call receiver" do
      pre_file = bind_decl("file", AST::Literal.new("{}", :File), full_type: :File)
      receiver = ident("file")
      call = AST::MethodCall.new(nil, receiver, "read", [])
      call.full_type = :Void
      seg0 = FsmTransform::Segments::Segment.new(0, [pre_file],
        FsmTransform::Segments::IoSuspend.new(call, io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })
      expect(result.cross_segment_vars).to have_key("file")
    end

    it "does NOT flag a pre-decl used only within its own segment" do
      # x is declared and used in seg 0, never read in seg 1 nor in
      # the tail's args.
      pre_x = bind_decl("x", AST::Literal.new(1, :Int64), full_type: :Int64)
      seg0 = FsmTransform::Segments::Segment.new(0, [pre_x],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })
      expect(result.cross_segment_vars).not_to have_key("x")
    end

    it "collects destructuring targets as definitions and skips discards" do
      target = AST::DestructureTarget.new(Lexer::Token.new(:VAR_ID, "a", 1, 1), "a", Type.new(:Int64), false)
      target.full_type = Type.new(:Int64)
      discard = AST::DestructureTarget.new(Lexer::Token.new(:VAR_ID, "_", 1, 4), "_", Type.new(:Int64), false)
      discard.full_type = Type.new(:Int64)
      stmt = AST::DestructuringAssignment.new(nil, [target, discard], AST::Literal.new(1, :Int64))
      defs = {}

      described_class.send(:collect_defs, stmt, defs)

      expect(defs.keys).to contain_exactly("a")
      expect(defs.fetch("a")).to eq(Type.new(:Int64))
    end

    it "flags decls inside a cyclic segment as cross-iteration" do
      # Build a 5-seg LOOP graph manually:
      #   0 pre              -> Goto(1)
      #   1 cond             -> CondJump(cond, 2, 4)
      #   2 loop_pre         -> NextSuspend -> 3
      #   3 loop_post        -> LoopBack(1)
      #   4 post             -> Done
      # A decl in seg 3 read in seg 3 (same seg) but seg 3 is part
      # of the cycle (3 -> 1 -> 2 -> 3) and the cyclic widening
      # should flag it.
      x_def = bind_decl("x", AST::Literal.new(1, :Int64), full_type: :Int64)
      x_use = ident("x")
      cond  = AST::Literal.new(true, :Bool)

      promise = io_call("p", [], { suspends: true, fsm_setup: [] })
      next_tail = FsmTransform::Segments::NextSuspend.new(promise, "r")

      seg0 = FsmTransform::Segments::Segment.new(0, [], FsmTransform::Segments::Goto.new(1))
      seg1 = FsmTransform::Segments::Segment.new(1, [],
        FsmTransform::Segments::CondBranch.new(cond, 2, 4))
      seg2 = FsmTransform::Segments::Segment.new(2, [], next_tail)
      seg3 = FsmTransform::Segments::Segment.new(3, [x_def, x_use],
        FsmTransform::Segments::LoopBack.new(1))
      seg4 = FsmTransform::Segments::Segment.new(4, [], FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1, seg2, seg3, seg4],
        { captured: {} })
      expect(result.cross_segment_vars).to have_key("x")
    end

    it "does NOT flag a same-segment use in a non-cyclic segment" do
      # Seg 0 has x decl + x use, no loop -> not cross.
      x_def = bind_decl("x", AST::Literal.new(1, :Int64), full_type: :Int64)
      x_use = ident("x")
      seg0 = FsmTransform::Segments::Segment.new(0, [x_def, x_use],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [],
        FsmTransform::Segments::Done.new(nil))
      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })
      expect(result.cross_segment_vars).not_to have_key("x")
    end

    it "excludes captures (already in ctx as fields)" do
      cap_x = ident("needle")
      seg0 = FsmTransform::Segments::Segment.new(0, [],
        FsmTransform::Segments::IoSuspend.new(io_call("writeFile", [cap_x], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1],
        { captured: { "needle" => :placeholder } })
      expect(result.cross_segment_vars).not_to have_key("needle")
    end

    it "excludes captured names even when the body declares and reads them across segments" do
      cap_def = bind_decl("needle", AST::Literal.new(1, :Int64), full_type: :Int64)
      cap_use = ident("needle")
      seg0 = FsmTransform::Segments::Segment.new(0, [cap_def],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [cap_use],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1],
        { captured: { "needle" => :placeholder } })

      expect(result.cross_segment_vars).not_to have_key("needle")
    end

    it "treats NEXT result variables as cross-segment definitions" do
      promise = io_call("p", [], { suspends: true, fsm_setup: [] })
      seg0 = FsmTransform::Segments::Segment.new(0, [],
        FsmTransform::Segments::NextSuspend.new(promise, "result"))
      seg1 = FsmTransform::Segments::Segment.new(1, [ident("result")],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })

      fact = result.cross_segment_vars.fetch("result")
      expect(fact.type_info).to be_nil
      expect(fact.first_def_seg).to eq(0)
      expect(fact.last_use_seg).to eq(1)
    end

    it "does not treat IO result variables as body-local cross-segment definitions" do
      seg0 = FsmTransform::Segments::Segment.new(0, [],
        FsmTransform::Segments::IoSuspend.new(io_call("readFile", [], io_def), io_def, "result"))
      seg1 = FsmTransform::Segments::Segment.new(1, [ident("result")],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })

      expect(result.cross_segment_vars).not_to have_key("result")
    end

    it "preserves earliest definition, first type, and latest use" do
      first_def = bind_decl("item", AST::Literal.new(1, :Int64), full_type: :Int64)
      later_def = bind_decl("item", AST::Literal.new("two", :String), full_type: :String)
      seg0 = FsmTransform::Segments::Segment.new(0, [first_def],
        FsmTransform::Segments::Goto.new(1))
      seg1 = FsmTransform::Segments::Segment.new(1, [later_def],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg2 = FsmTransform::Segments::Segment.new(2, [ident("item")],
        FsmTransform::Segments::Goto.new(3))
      seg3 = FsmTransform::Segments::Segment.new(3, [ident("item")],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1, seg2, seg3], { captured: {} })

      fact = result.cross_segment_vars.fetch("item")
      expect(fact.type_info).to eq(Type.new(:Int64))
      expect(fact.first_def_seg).to eq(0)
      expect(fact.last_use_seg).to eq(3)
    end

    it "defaults to an empty capture set when context omits captured names" do
      pre_x = bind_decl("x", AST::Literal.new(42, :Int64), full_type: :Int64)
      seg0 = FsmTransform::Segments::Segment.new(0, [pre_x],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [ident("x")],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], {})

      expect(result.cross_segment_vars).to have_key("x")
    end

    it "continues past non-promoted locals when later locals cross segments" do
      local_def = bind_decl("local", AST::Literal.new(1, :Int64), full_type: :Int64)
      local_use = ident("local")
      cross_def = bind_decl("cross", AST::Literal.new(2, :Int64), full_type: :Int64)
      seg0 = FsmTransform::Segments::Segment.new(0, [local_def, local_use, cross_def],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [ident("cross")],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1], { captured: {} })

      expect(result.cross_segment_vars.keys).to eq(["cross"])
    end

    it "continues past captured locals when later locals cross segments" do
      captured_def = bind_decl("captured", AST::Literal.new(1, :Int64), full_type: :Int64)
      captured_use = ident("captured")
      cross_def = bind_decl("cross", AST::Literal.new(2, :Int64), full_type: :Int64)
      seg0 = FsmTransform::Segments::Segment.new(0, [captured_def, captured_use, cross_def],
        FsmTransform::Segments::IoSuspend.new(io_call("sleep", [], io_def), io_def, nil))
      seg1 = FsmTransform::Segments::Segment.new(1, [ident("cross")],
        FsmTransform::Segments::Done.new(nil))

      result = FsmTransform::Liveness.analyze([seg0, seg1],
        { captured: { "captured" => :placeholder } })

      expect(result.cross_segment_vars.keys).to eq(["cross"])
    end

    it "records string-target assignments as definitions" do
      defs = {}
      stmt = AST::Assignment.new(nil, "slot", ident("source"))

      FsmTransform::Liveness.send(:collect_defs, stmt, defs)

      expect(defs).to eq("slot" => nil)
    end

    it "normalizes raw declaration types into Type facts" do
      expect(FsmTransform::Liveness.send(:stmt_decl_type, bind_decl("n", AST::Literal.new(1, :Int64), full_type: :Int64))).to eq(Type.new(:Int64))
    end
  end
end
