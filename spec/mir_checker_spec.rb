require 'bundler/setup'
require_relative '../src/mir'
require_relative '../src/mir_checker'

# Tests the post-lowering MIRChecker -- only two checks remain:
#   HPT_LEAK              -- heap-returning call result discarded (leak)
#   INLINE_ALLOC_MISMATCH -- operation allocator doesn't match container's AllocMark
#
# All other ownership checks now run pre-lowering:
#   FlowChecker          -- LEAK, ORPHAN_DROP, ORPHAN_GUARD, FRAME_OVERFLOW
#   UseAfterMoveChecker  -- use-after-move (Rule 1)
#   BorrowChecker        -- MOVE_WHILE_BORROWED, ALIAS_VIOLATION

RSpec.describe MIRChecker do
  let(:checker) { MIRChecker.new }

  def fn_def(name, body)
    MIR::FnDef.new(name, [], "void", body, :pub, false, nil)
  end

  # ===========================================================================
  # HPT_LEAK -- heap-returning call result discarded
  # ===========================================================================

  describe "HPT_LEAK" do
    it "detects discarded heap-returning call" do
      call = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      body = [
        MIR::ExprStmt.new(call, true),
      ]
      errors = checker.check_fn!(fn_def("hpt_leak", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("makeList") }).to be true
    end

    it "passes for heap-returning call bound to Let" do
      call = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      body = [
        MIR::Let.new("x", call, false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("hpt_ok", body))
      expect(errors).to be_empty
    end

    it "passes for ExprStmt with non-heap call" do
      call = MIR::Call.new("doWork", [MIR::Ident.new("rt")], false)
      body = [
        MIR::ExprStmt.new(call, true),
      ]
      errors = checker.check_fn!(fn_def("no_heap", body))
      expect(errors).to be_empty
    end

    it "detects heap call nested as argument" do
      inner = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      outer = MIR::Call.new("process", [inner], false)
      body = [
        MIR::ExprStmt.new(outer, true),
      ]
      errors = checker.check_fn!(fn_def("nested_hpt", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("makeList") }).to be true
    end

    it "detects discarded InlineZig stdlib call with allocates:true" do
      iz = MIR::InlineZig.new("CheatLib.clone({0})", "clone", nil, { allocates: true, return: :String })
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("stdlib_leak", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") }).to be true
    end

    it "passes for InlineZig stdlib call with allocates:true returning Void" do
      iz = MIR::InlineZig.new("CheatLib.sort({0})", "sort", nil, { allocates: true, return: :Void })
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("stdlib_void", body))
      expect(errors).to be_empty
    end

    it "detects HPT_LEAK inside nested lambda" do
      inner_call = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      lambda_body = [
        MIR::ExprStmt.new(inner_call, true),
      ]
      lambda_fn = MIR::FnDef.new("lambda_impl", [], "void", lambda_body, :private, false, nil)
      body = [
        MIR::Let.new("f", MIR::LambdaExpr.new(lambda_fn), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("outer", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("makeList") }).to be true
    end
  end

  # ===========================================================================
  # INLINE_ALLOC_MISMATCH -- operation allocator vs container AllocMark
  # ===========================================================================

  describe "INLINE_ALLOC_MISMATCH" do
    it "detects heap append on frame list" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "parts"
      body = [
        MIR::AllocMark.new("parts", :list, :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("mismatch_inline", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("parts") }).to be true
    end

    it "passes for frame append on frame list" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :frame }
      iz.target_var = "parts"
      body = [
        MIR::FrameSave.new("rt"),
        MIR::AllocMark.new("parts", :list, :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("ok_inline", body))
      expect(errors).to be_empty
    end

    it "catches frame val_alloc stored in heap container" do
      iz = MIR::InlineZig.new("try {target}.put({key_alloc}, {val_alloc}, {index}, {value})", "index_set")
      iz.allocs = { key_alloc: :heap, val_alloc: :frame }
      iz.target_var = "map"
      body = [
        MIR::FrameSave.new("rt"),
        MIR::AllocMark.new("map", :string_map, :heap),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("frame_val_in_heap", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("val_alloc") }).to be true
    end

    it "passes for heap key_alloc/val_alloc in heap container" do
      iz = MIR::InlineZig.new("try {target}.put({key_alloc}, {val_alloc}, {index}, {value})", "index_set")
      iz.allocs = { key_alloc: :heap, val_alloc: :heap }
      iz.target_var = "map"
      body = [
        MIR::AllocMark.new("map", :string_map, :heap),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("heap_map_ok", body))
      expect(errors).to be_empty
    end

    it "skips operations on non-local containers (no AllocMark)" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "external_list"
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("external_ok", body))
      expect(errors).to be_empty
    end

    it "detects mismatch for InlineZig found directly (not wrapped in ExprStmt)" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "items"
      body = [
        MIR::FrameSave.new("rt"),
        MIR::AllocMark.new("items", :list, :frame),
        iz,
      ]
      errors = checker.check_fn!(fn_def("direct_iz", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("items") }).to be true
    end
  end

  # ===========================================================================
  # FRAME_NO_REWIND -- scopes that frame-allocate must have rewind
  # ===========================================================================

  describe "FRAME_NO_REWIND" do
    # Structural check: the checker looks for an actual DeferStmt(restoreLoopMark)
    # in the loop body, not a flag. If the loop body has frame allocs but no
    # restoreLoopMark defer, FRAME_NO_REWIND fires regardless of mark_per_iter.

    # Helper: the DeferStmt(restoreLoopMark) emitted by the lowerer for mark_per_iter loops.
    def loop_restore_defer
      MIR::DeferStmt.new(
        MIR::MethodCall.new(MIR::Ident.new("rt"), "restoreLoopMark",
                            [MIR::Ident.new("__mark")], false)
      )
    end

    it "passes for function body with frame alloc (only loop-level checked)" do
      body = [MIR::AllocMark.new("x", :list, :frame)]
      errors = checker.check_fn!(fn_def("no_save", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "passes for function body with only heap allocs" do
      body = [MIR::AllocMark.new("x", :list, :heap)]
      errors = checker.check_fn!(fn_def("heap_only", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "detects loop with frame alloc but no restoreLoopMark defer" do
      loop_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("loop_no_restore", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "passes for loop with restoreLoopMark defer (structural check)" do
      loop_body = [loop_restore_defer, MIR::AllocMark.new("tmp", :string, :frame)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("loop_with_restore", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "detects loop with mark_per_iter flag but no restoreLoopMark defer (lowerer bug)" do
      # mark_per_iter=true but lowerer failed to emit the defer -- checker catches it
      loop_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("flag_without_defer", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame InlineZig alloc but no restoreLoopMark defer" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :frame }
      loop_body = [MIR::ExprStmt.new(iz, false)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("iz_loop_no_restore", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects ForStmt with frame Let init but no restoreLoopMark defer" do
      iz = MIR::InlineZig.new("try CheatLib.init({alloc})", "intrinsic")
      iz.allocs = { alloc: :frame }
      loop_body = [MIR::Let.new("tmp", iz, false, nil, nil)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::ForStmt.new("i", MIR::Ident.new("items"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("for_no_restore", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside an if-branch (no restore)" do
      if_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      loop_body = [MIR::IfStmt.new(MIR::Lit.new("cond"), if_body, [])]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("if_branch_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside an else-branch (no restore)" do
      else_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      loop_body = [MIR::IfStmt.new(MIR::Lit.new("cond"), [], else_body)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("else_branch_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside a ScopeBlock (no restore)" do
      scope_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      loop_body = [MIR::ScopeBlock.new(scope_body)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("scope_block_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "does NOT flag outer loop for frame alloc only inside a nested inner loop" do
      inner_loop_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      inner_loop = MIR::WhileStmt.new(MIR::Lit.new("true"), inner_loop_body, nil, nil, nil)
      outer_loop_body = [inner_loop]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), outer_loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("nested_loop_alloc", body))
      # Inner loop has no restore -- flags it; outer loop body has no frame allocs -- clean
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }.length).to eq(1)
    end

    it "passes for loop with frame alloc inside if-branch when restoreLoopMark defer present" do
      if_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      loop_body = [loop_restore_defer, MIR::IfStmt.new(MIR::Lit.new("cond"), if_body, [])]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("if_branch_with_restore", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "passes for tight loop (no frame rewind needed)" do
      loop_body = [MIR::AllocMark.new("tmp", :string, :frame)]
      ws = MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil)
      ws.tight = true
      body = [MIR::FrameSave.new("rt"), ws]
      errors = checker.check_fn!(fn_def("tight_loop", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end
  end

  # ===========================================================================
  # INLINE_NO_CONTRACT -- InlineZig with CheatLib calls must have stdlib_def
  # ===========================================================================

  describe "INLINE_NO_CONTRACT" do
    it "detects InlineZig calling CheatLib without stdlib_def" do
      iz = MIR::InlineZig.new("try CheatLib.makeList(u8, alloc, items)", "bad_call")
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") }).to be true
      expect(errors.any? { |e| e.include?("CheatLib.makeList") }).to be true
    end

    it "passes when stdlib_def is set" do
      iz = MIR::InlineZig.new("try CheatLib.makeList(u8, alloc, items)", "ok_call")
      iz.stdlib_def = { allocates: true }
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.select { |e| e.include?("INLINE_NO_CONTRACT") }).to be_empty
    end

    it "passes for exempt CheatLib calls (pure reads/arithmetic)" do
      iz = MIR::InlineZig.new("CheatLib.intAdd(a, b)", "math")
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.select { |e| e.include?("INLINE_NO_CONTRACT") }).to be_empty
    end

    it "detects unaudited CheatLib call in Let init" do
      iz = MIR::InlineZig.new("try CheatLib.promote(T, rt, &val)", "promote")
      body = [MIR::Let.new("x", iz, false, nil, nil)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") }).to be true
    end
  end

  # ===========================================================================
  # ALLOC_CLEANUP_MISMATCH -- AllocMark allocator must match Cleanup allocator
  # ===========================================================================

  describe "ALLOC_CLEANUP_MISMATCH" do
    it "detects frame alloc with heap cleanup" do
      cleanup_entry = { kind: :heap_string, alloc: :heap, has_moved_guard: false }
      body = [
        MIR::AllocMark.new("data", :heap_string, :frame),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("frame_alloc_heap_cleanup", body))
      expect(errors.any? { |e| e.include?("ALLOC_CLEANUP_MISMATCH") && e.include?("data") }).to be true
    end

    it "detects heap alloc with frame cleanup" do
      cleanup_entry = { kind: :heap_string, alloc: :frame, has_moved_guard: false }
      body = [
        MIR::AllocMark.new("data", :heap_string, :heap),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("heap_alloc_frame_cleanup", body))
      expect(errors.any? { |e| e.include?("ALLOC_CLEANUP_MISMATCH") && e.include?("data") }).to be true
    end

    it "passes for matching frame alloc and frame cleanup" do
      cleanup_entry = { kind: :heap_string, alloc: :frame, has_moved_guard: false }
      body = [
        MIR::AllocMark.new("data", :heap_string, :frame),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("ok_frame", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "passes for matching heap alloc and heap cleanup" do
      cleanup_entry = { kind: :heap_string, alloc: :heap, has_moved_guard: true }
      body = [
        MIR::AllocMark.new("data", :heap_string, :heap),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("ok_heap", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "passes for cleanup with no AllocMark (TAKES parameter)" do
      cleanup_entry = { kind: :heap_string, alloc: :heap, has_moved_guard: false }
      body = [
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("takes_param", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "passes for alloc with no cleanup (moved/escaped via return)" do
      body = [
        MIR::AllocMark.new("data", :heap_string, :heap),
      ]
      errors = checker.check_fn!(fn_def("moved", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "detects mismatch inside an if branch" do
      cleanup_entry = { kind: :heap_string, alloc: :heap, has_moved_guard: false }
      branch_body = [
        MIR::AllocMark.new("line", :heap_string, :frame),
        MIR::Cleanup.new("line", cleanup_entry),
      ]
      body = [
        MIR::IfStmt.new(MIR::Lit.new("true"), branch_body, []),
      ]
      errors = checker.check_fn!(fn_def("branch_mismatch", body))
      expect(errors.any? { |e| e.include?("ALLOC_CLEANUP_MISMATCH") && e.include?("line") }).to be true
    end
  end

  # ===========================================================================
  # check_program! -- verifies all functions
  # ===========================================================================

  describe "#check_program!" do
    it "collects errors across multiple functions" do
      call1 = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      fn1 = fn_def("good", [
        MIR::Let.new("x", call1, false, nil, nil),
      ])

      call2 = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      fn2 = fn_def("bad", [
        MIR::ExprStmt.new(call2, true),
      ])

      program = MIR::Program.new([fn1, fn2])
      errors = checker.check_program!(program)
      expect(errors.length).to eq(1)
      expect(errors.first).to include("bad")
      expect(errors.first).to include("HPT_LEAK")
    end

    it "returns empty for clean program" do
      fn1 = fn_def("ok", [
        MIR::Let.new("x", MIR::Lit.new("42"), false, nil, nil),
      ])
      program = MIR::Program.new([fn1])
      errors = checker.check_program!(program)
      expect(errors).to be_empty
    end
  end
end
