require 'bundler/setup'
require_relative '../src/mir/mir'
require_relative '../src/mir/mir_checker'

# Tests the post-lowering MIRChecker -- only two checks remain:
#   HPT_LEAK              -- heap-returning call result discarded (leak)
#   INLINE_ALLOC_MISMATCH -- operation allocator doesn't match container's AllocMark
#
# Other ownership checks run pre-lowering:
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
        MIR::AllocMark.new("x", :heap),
        MIR::Let.new("x", call, false, nil, nil),
        MIR::Cleanup.new("x", { kind: :heap_slice, alloc: :heap, has_moved_guard: false }),
      ]
      errors = checker.check_fn!(fn_def("hpt_ok", body))
      expect(errors).to be_empty
    end

    it "detects bound heap-returning call with no AllocMark" do
      call = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      body = [
        MIR::Let.new("x", call, false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("hpt_bound_no_alloc", body))
      expect(errors.any? { |e| e.include?("OWNED_RETURN_WITHOUT_ALLOC") && e.include?("x") }).to be true
    end

    it "passes for bound heap-returning call transferred out of scope" do
      call = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      body = [
        MIR::AllocMark.new("x", :heap),
        MIR::Let.new("x", call, false, nil, nil),
        MIR::TransferMark.new("x", :moved),
      ]
      errors = checker.check_fn!(fn_def("hpt_bound_transfer", body))
      expect(errors).to be_empty
    end

    it "detects bound heap-returning call marked allocated but neither cleaned nor transferred" do
      call = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      body = [
        MIR::AllocMark.new("x", :heap),
        MIR::Let.new("x", call, false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("hpt_bound_alloc_only", body))
      expect(errors.any? { |e| e.include?("ALLOC_WITHOUT_CLEANUP") && e.include?("x") }).to be true
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
      iz = MIR::InlineZig.new("CheatLib.clone({0})", "clone", nil, { allocates: true, return: :String, return_alloc: :heap })
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
        MIR::AllocMark.new("parts", :frame),
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
        MIR::AllocMark.new("parts", :frame),
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
        MIR::AllocMark.new("map", :heap),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("frame_val_in_heap", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("val_alloc") }).to be true
    end

    it "passes for heap key_alloc/val_alloc in heap container" do
      iz = MIR::InlineZig.new("try {target}.put({key_alloc}, {val_alloc}, {index}, {value})", "index_set")
      iz.allocs = { key_alloc: :heap, val_alloc: :heap }
      iz.target_var = "map"
      cleanup = MIR::Cleanup.new("map", { kind: :string_map, alloc: :heap, has_moved_guard: false,
                                           zig_type: "CheatLib.StringMap(i64)" })
      body = [
        MIR::AllocMark.new("map", :heap),
        MIR::ExprStmt.new(iz, false),
        cleanup,
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
        MIR::AllocMark.new("items", :frame),
        iz,
      ]
      errors = checker.check_fn!(fn_def("direct_iz", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("items") }).to be true
    end
  end

  # ===========================================================================
  # CROSS_FRAME_PARAM_ALLOC -- allocator on a pointer-passed param must be heap
  # ===========================================================================
  #
  # Pin for the test 380 UAF class. A `MUTABLE T[]@list` parameter is
  # pointer-passed; its Zig type is `*ArrayList(T)`. Buffer growth via
  # `.append` (an InlineZig op with `alloc: :receiver_storage`) must
  # resolve to `:heap`, not `:frame`. If lowering's `resolve_alloc_sym`
  # ever regresses, the checker catches it here independently.

  describe "CROSS_FRAME_PARAM_ALLOC" do
    # Helper: FnDef with one pointer-passed param.
    def fn_with_ptr_param(body)
      param = MIR::Param.new("items", "anytype", true)
      MIR::FnDef.new("record", [param], "void", body, :pub, true, nil)
    end

    it "detects :frame allocator on a pointer-passed @list param" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :frame }
      iz.target_var = "items"
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_with_ptr_param(body))
      expect(errors.any? { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") && e.include?("items") }).to be true
    end

    it "passes when the allocator on a pointer-passed param is :heap" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "items"
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_with_ptr_param(body))
      expect(errors).to be_empty
    end

    it "ignores :frame allocator on a NON-pointer-passed local binding" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :frame }
      iz.target_var = "local_list"
      body = [
        MIR::FrameSave.new("rt"),
        MIR::AllocMark.new("local_list", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      # Plain locals: cross-frame doesn't apply. The other invariants may
      # speak (alloc/cleanup match etc) but not this one.
      errors = checker.check_fn!(fn_def("local_only", body))
      expect(errors.none? { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") }).to be true
    end

    it "fires for every :frame allocator key, not just :alloc" do
      iz = MIR::InlineZig.new("try {target}.put({key_alloc}, {val_alloc}, {k}, {v})", "index_set")
      iz.allocs = { key_alloc: :frame, val_alloc: :frame }
      iz.target_var = "map"
      param = MIR::Param.new("map", "anytype", true)
      fn = MIR::FnDef.new("update", [param], "void", [MIR::ExprStmt.new(iz, false)], :pub, true, nil)
      errors = checker.check_fn!(fn)
      ksay = errors.select { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") }
      expect(ksay.length).to eq(2)
      expect(ksay.any? { |e| e.include?("key_alloc") }).to be true
      expect(ksay.any? { |e| e.include?("val_alloc") }).to be true
    end

    it "no-ops on functions with empty params (no false positives)" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :frame }
      iz.target_var = "anything"
      body = [
        MIR::FrameSave.new("rt"),
        MIR::AllocMark.new("anything", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("paramless", body))
      expect(errors.none? { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") }).to be true
    end

    it "leaves slice (non-pointer-passed) params alone" do
      param = MIR::Param.new("slice", "[]const TraceItem", false)
      iz = MIR::InlineZig.new("for ({0}) |x| {{ ... }}", "iter")
      iz.allocs = { alloc: :frame }
      iz.target_var = "slice"
      fn = MIR::FnDef.new("read_only", [param], "void", [MIR::ExprStmt.new(iz, false)], :pub, false, nil)
      errors = checker.check_fn!(fn)
      expect(errors.none? { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") }).to be true
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
      body = [MIR::AllocMark.new("x", :frame)]
      errors = checker.check_fn!(fn_def("no_save", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "passes for function body with only heap allocs" do
      body = [MIR::AllocMark.new("x", :heap)]
      errors = checker.check_fn!(fn_def("heap_only", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "detects loop with frame alloc but no restoreLoopMark defer" do
      loop_body = [MIR::AllocMark.new("tmp", :frame)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("loop_no_restore", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "passes for loop with restoreLoopMark defer (structural check)" do
      loop_body = [loop_restore_defer, MIR::AllocMark.new("tmp", :frame)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("loop_with_restore", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "detects loop with mark_per_iter flag but no restoreLoopMark defer (lowerer bug)" do
      # mark_per_iter=true but lowerer failed to emit the defer -- checker catches it
      loop_body = [MIR::AllocMark.new("tmp", :frame)]
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
      if_body = [MIR::AllocMark.new("tmp", :frame)]
      loop_body = [MIR::IfStmt.new(MIR::Lit.new("cond"), if_body, [])]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("if_branch_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside an else-branch (no restore)" do
      else_body = [MIR::AllocMark.new("tmp", :frame)]
      loop_body = [MIR::IfStmt.new(MIR::Lit.new("cond"), [], else_body)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("else_branch_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside a ScopeBlock (no restore)" do
      scope_body = [MIR::AllocMark.new("tmp", :frame)]
      loop_body = [MIR::ScopeBlock.new(scope_body)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("scope_block_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "does NOT flag outer loop for frame alloc only inside a nested inner loop" do
      inner_loop_body = [MIR::AllocMark.new("tmp", :frame)]
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
      if_body = [MIR::AllocMark.new("tmp", :frame)]
      loop_body = [loop_restore_defer, MIR::IfStmt.new(MIR::Lit.new("cond"), if_body, [])]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("if_branch_with_restore", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "passes for tight loop (no frame rewind needed)" do
      loop_body = [MIR::AllocMark.new("tmp", :frame)]
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
        MIR::AllocMark.new("data", :frame),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("frame_alloc_heap_cleanup", body))
      expect(errors.any? { |e| e.include?("ALLOC_CLEANUP_MISMATCH") && e.include?("data") }).to be true
    end

    it "detects heap alloc with frame cleanup" do
      cleanup_entry = { kind: :heap_string, alloc: :frame, has_moved_guard: false }
      body = [
        MIR::AllocMark.new("data", :heap),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("heap_alloc_frame_cleanup", body))
      expect(errors.any? { |e| e.include?("ALLOC_CLEANUP_MISMATCH") && e.include?("data") }).to be true
    end

    it "passes for matching frame alloc and frame cleanup" do
      cleanup_entry = { kind: :heap_string, alloc: :frame, has_moved_guard: false }
      body = [
        MIR::AllocMark.new("data", :frame),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("ok_frame", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "passes for matching heap alloc and heap cleanup" do
      cleanup_entry = { kind: :heap_string, alloc: :heap, has_moved_guard: true }
      body = [
        MIR::AllocMark.new("data", :heap),
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
        MIR::AllocMark.new("data", :heap),
      ]
      errors = checker.check_fn!(fn_def("moved", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "detects mismatch inside an if branch" do
      cleanup_entry = { kind: :heap_string, alloc: :heap, has_moved_guard: false }
      branch_body = [
        MIR::AllocMark.new("line", :frame),
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
  # UNHOISTED_ALLOC -- allocating expressions must appear only as Let.init
  # ===========================================================================
  #
  # Enabled via strict: true.  Disabled by default because the codebase still
  # has open violations being fixed in Phase 1-3 tasks.
  # ===========================================================================

  describe "UNHOISTED_ALLOC" do
    # --- DupeSlice ---

    it "passes: DupeSlice as Let.init" do
      body = [
        MIR::Let.new("s", MIR::DupeSlice.new(MIR::Ident.new("src"), :heap), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("ok_dupe", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "flags: DupeSlice in ReturnStmt" do
      body = [
        MIR::ReturnStmt.new(MIR::DupeSlice.new(MIR::Ident.new("src"), :heap)),
      ]
      errors = checker.check_fn!(fn_def("ret_dupe", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("DupeSlice") }).to be true
    end

    it "flags: DupeSlice as Call argument" do
      inner = MIR::DupeSlice.new(MIR::Ident.new("s"), :heap)
      body = [
        MIR::ExprStmt.new(MIR::Call.new("push", [inner], true), false),
      ]
      errors = checker.check_fn!(fn_def("arg_dupe", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("DupeSlice") }).to be true
    end

    # --- HeapCreate ---

    it "passes: HeapCreate as Let.init" do
      init = MIR::StructInit.new("Node", [])
      body = [
        MIR::Let.new("n", MIR::HeapCreate.new("Node", init, :heap, "blk"), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("ok_heap_create", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "flags: HeapCreate inside StructInit field (nested alloc)" do
      inner_hc = MIR::HeapCreate.new("Child", MIR::StructInit.new("Child", []), :heap, "blk_f")
      outer_init = MIR::StructInit.new("Parent", [{ name: "child", value: inner_hc }])
      body = [
        MIR::Let.new("p", MIR::HeapCreate.new("Parent", outer_init, :heap, "blk"), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("nested_hc", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("HeapCreate") }).to be true
    end

    it "flags: HeapCreate in ReturnStmt" do
      body = [
        MIR::ReturnStmt.new(MIR::HeapCreate.new("T", MIR::StructInit.new("T", []), :heap, "blk")),
      ]
      errors = checker.check_fn!(fn_def("ret_hc", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("HeapCreate") }).to be true
    end

    # --- ConcatStr ---

    it "passes: ConcatStr as Let.init" do
      body = [
        MIR::Let.new("s", MIR::ConcatStr.new([MIR::Ident.new("a"), MIR::Ident.new("b")], :heap, "rt"), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("ok_concat", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "flags: ConcatStr in ReturnStmt" do
      body = [
        MIR::ReturnStmt.new(MIR::ConcatStr.new([MIR::Ident.new("a")], :heap, "rt")),
      ]
      errors = checker.check_fn!(fn_def("ret_concat", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("ConcatStr") }).to be true
    end

    # --- MakeList ---

    it "passes: MakeList as Let.init" do
      body = [
        MIR::Let.new("xs", MIR::MakeList.new("i64", [], :heap), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("ok_make", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "passes: SharePromote as Let.init" do
      body = [
        MIR::Let.new("s", MIR::SharePromote.new(MIR::Ident.new("rc"), "User", :heap), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("ok_share_promote", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "flags: SharePromote as Call argument" do
      promote = MIR::SharePromote.new(MIR::Ident.new("rc"), "User", :heap)
      body = [
        MIR::ExprStmt.new(MIR::Call.new("useShared", [promote], false), false),
      ]
      errors = checker.check_fn!(fn_def("share_promote_arg", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("SharePromote") }).to be true
    end

    it "flags: MakeList in ExprStmt (discarded)" do
      body = [
        MIR::ExprStmt.new(MIR::MakeList.new("i64", [], :heap), true),
      ]
      errors = checker.check_fn!(fn_def("discard_make", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("MakeList") }).to be true
    end

    # --- ContainerInit ---

    it "passes: ContainerInit with nil alloc (stack value type)" do
      body = [
        MIR::Let.new("m", MIR::ContainerInit.new("MyMap", :map_empty, nil, nil), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("ok_ci_nil", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "passes: ContainerInit with non-nil alloc as Let.init" do
      body = [
        MIR::Let.new("pool", MIR::ContainerInit.new("Pool", :pool, :heap, 10), false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("ok_ci_heap", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "flags: ContainerInit with non-nil alloc in Call arg" do
      ci = MIR::ContainerInit.new("Pool", :pool, :heap, 10)
      body = [
        MIR::ExprStmt.new(MIR::Call.new("setup", [ci], false), false),
      ]
      errors = checker.check_fn!(fn_def("ci_arg", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("ContainerInit") }).to be true
    end

    # --- DeepCopy ---

    it "passes: DeepCopy(passthrough) anywhere (no-op, not an allocation)" do
      body = [
        MIR::ReturnStmt.new(MIR::DeepCopy.new(MIR::Ident.new("x"), nil, nil, :passthrough, nil)),
      ]
      errors = checker.check_fn!(fn_def("passthrough", body), strict: true)
      expect(errors.select { |e| e.include?("UNHOISTED_ALLOC") }).to be_empty
    end

    it "flags: DeepCopy(string) in ReturnStmt" do
      body = [
        MIR::ReturnStmt.new(MIR::DeepCopy.new(MIR::Ident.new("x"), nil, nil, :string, :heap)),
      ]
      errors = checker.check_fn!(fn_def("deep_copy_ret", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("DeepCopy") }).to be true
    end

    # --- Nesting / control flow ---

    it "flags: DupeSlice inside if-branch" do
      then_body = [MIR::ReturnStmt.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap))]
      body = [MIR::IfStmt.new(MIR::Lit.new("cond"), then_body, [])]
      errors = checker.check_fn!(fn_def("if_dupe", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("DupeSlice") }).to be true
    end

    it "flags: DupeSlice inside while loop body" do
      loop_body = [MIR::ReturnStmt.new(MIR::DupeSlice.new(MIR::Ident.new("s"), :heap))]
      body = [MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil)]
      errors = checker.check_fn!(fn_def("while_dupe", body), strict: true)
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") && e.include?("DupeSlice") }).to be true
    end

    it "does not flag existing non-strict checks for non-allocating expressions" do
      # Ensure strict mode doesn't accidentally break the normal HPT_LEAK check
      call = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      body = [MIR::ExprStmt.new(call, true)]
      errors = checker.check_fn!(fn_def("hpt_still_works", body), strict: true)
      expect(errors.any? { |e| e.include?("HPT_LEAK") }).to be true
    end
  end

  # ===========================================================================
  # check_program! -- verifies all functions
  # ===========================================================================

  describe "#check_program!" do
    it "collects errors across multiple functions" do
      call1 = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      fn1 = fn_def("good", [
        MIR::AllocMark.new("x", :heap),
        MIR::Let.new("x", call1, false, nil, nil),
        MIR::Cleanup.new("x", { kind: :heap_slice, alloc: :heap, has_moved_guard: false }),
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

  # ===========================================================================
  # FSM structural invariants
  # ===========================================================================
  #
  # Verifies the FSM-specific cleanup-placement checks. These exist
  # because the FSM lowering renders multi-step state machines as
  # opaque Zig text -- the regular checker can't see step boundaries
  # or `defer` placement. FsmStructure exposes those decisions to
  # the checker; check_fsm_structure! enforces invariants on it.
  #
  # The motivating bug: capture cleanups (`defer free(filepath)`)
  # were placed inside runStep0, firing at end of step 0 -- BEFORE
  # runStep1 ever ran. runStep1 then read freed capture memory,
  # producing wrong results in the file-search benchmark with no
  # compile-time warning.

  describe "check_fsm_structure!" do
    it "rejects capture cleanup placed in a step (not finalize)" do
      structure = MIR::FsmStructure.new(
        [{ name: "needle", cleanup_at: 0 }],
        [],
        [
          { index: 0, reads: ["needle"], cleanups: ["needle"] },
          { index: 1, reads: ["needle"], cleanups: [] },
        ],
        [],
        0,
        nil,
      )
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-CAPTURE-FINALIZE/)
    end

    it "rejects capture with no cleanup at all" do
      structure = MIR::FsmStructure.new(
        [{ name: "needle", cleanup_at: :finalize }],
        [],
        [{ index: 0, reads: [], cleanups: [] }],
        [],
        0,
        nil,
      )
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-CAPTURE-CLEANUP-PRESENT/)
    end

    it "rejects step N reading a name whose cleanup is in step M < N" do
      structure = MIR::FsmStructure.new(
        [],
        [{ name: "tmp", finalize_at: nil }],
        [
          { index: 0, reads: ["tmp"], cleanups: ["tmp"] },
          { index: 1, reads: ["tmp"], cleanups: [] },
        ],
        [],
        0,
        nil,
      )
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-STEP-READS-LIVE/)
    end

    it "rejects result aliasing a finalized state field" do
      structure = MIR::FsmStructure.new(
        [],
        [{ name: "rf_buf", finalize_at: :finalize }],
        [{ index: 1, reads: ["rf_buf"], cleanups: ["rf_buf"] }],
        ["rf_buf"],
        0,
        "rf_buf",  # aliasing detected by lowering
      )
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-RESULT-NO-FINALIZED-ALIAS/)
    end

    it "passes a well-formed FSM structure" do
      structure = MIR::FsmStructure.new(
        [{ name: "needle", cleanup_at: :finalize }],
        [{ name: "rf_buf", finalize_at: :finalize }],
        [
          { index: 0, reads: ["needle"], cleanups: [] },
          {
            index: 1,
            reads: ["needle", "rf_buf"],
            cleanups: ["needle", "rf_buf"],
          },
        ],
        ["needle", "rf_buf"],
        0,
        nil,
      )
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.not_to raise_error
    end

    it "ignores nil structure (non-FSM BgBlocks)" do
      expect {
        MIRChecker.check_fsm_structure!(nil)
      }.not_to raise_error
    end
  end
end
