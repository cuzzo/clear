require 'bundler/setup'
require_relative '../src/ast/ast'
require_relative '../src/mir/mir'
require_relative '../src/mir/cleanup_entry'
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

  def checked_program(items)
    state = MIRPassState.new
    MIRPassState::ORDER.each do |stage|
      state.mark!(stage)
      break if stage == :mir_lowered
    end
    MIR::Program.new(items, state)
  end

  def alloc_mark(name, alloc, type_info = Type.new(:String), scope: nil)
    MIR::AllocMark.new(name, alloc, type_info, scope || (alloc == :heap ? :heap : :function))
  end

  def owned_call(name = "makeList")
    MIR::Call.new(name, [MIR::Ident.new("rt")], false, true)
  end

  def boundary_fact(kind: :bg, dispatch: :local, captures: [])
    MIR::ExecutionBoundaryFact.new(kind: kind, dispatch: dispatch, captures: captures)
  end

  def boundary_capture(name, parallel_safe: true, forbidden_reason: nil)
    MIR::BoundaryCaptureFact.new(
      name: name,
      storage: :heap,
      sync: nil,
      ownership: nil,
      parallel_safe: parallel_safe,
      scheduler_affine: !parallel_safe,
      requires_pinned: !parallel_safe,
      forbidden_reason: forbidden_reason,
    )
  end

  describe "OWNERSHIP_CLEANUP_FOR_BORROW" do
    it "rejects cleanup for an indexed borrow alias" do
      body = [
        alloc_mark("tmp", :heap, Type.new(:Value)),
        MIR::Let.new(
          "tmp",
          MIR::IndexGet.new(MIR::Ident.new("items"), MIR::Lit.new("0")),
          false,
          nil,
          nil,
        ),
        MIR::Cleanup.new("tmp", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
      ]

      errors = checker.check_fn!(fn_def("borrow_cleanup", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_CLEANUP_FOR_BORROW") && e.include?("tmp") }).to be true
    end

    it "allows cleanup when the binding is produced by a deep copy" do
      body = [
        alloc_mark("tmp", :heap, Type.new(:Value)),
        MIR::Let.new(
          "tmp",
          MIR::DeepCopy.new(MIR::IndexGet.new(MIR::Ident.new("items"), MIR::Lit.new("0")), "Value", nil, :full_value, :heap),
          false,
          nil,
          nil,
        ),
        MIR::Cleanup.new("tmp", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
      ]

      errors = checker.check_fn!(fn_def("owned_copy_cleanup", body))
      expect(errors.none? { |e| e.include?("OWNERSHIP_CLEANUP_FOR_BORROW") }).to be true
    end
  end

  # ===========================================================================
  # HPT_LEAK -- heap-returning call result discarded
  # ===========================================================================

  describe "INDIRECT_DOUBLE_BOX" do
    it "flags a HeapCreate whose cell type is already a pointer" do
      hc = MIR::HeapCreate.new("*Val", MIR::Ident.new("v"), :heap, "blk")
      body = [
        alloc_mark("t", :heap),
        MIR::Let.new("t", hc, false, nil, nil),
        MIR::Cleanup.new("t", CleanupEntry.from({ kind: :heap, alloc: :heap, has_moved_guard: false })),
      ]
      errors = checker.check_fn!(fn_def("dbl", body))
      expect(errors.any? { |e| e.include?("INDIRECT_DOUBLE_BOX") && e.include?("*Val") }).to be true
    end

    it "passes a HeapCreate boxing a bare pointee type" do
      hc = MIR::HeapCreate.new("[]const u8", MIR::Ident.new("s"), :heap, "blk")
      body = [
        alloc_mark("t", :heap),
        MIR::Let.new("t", hc, false, nil, nil),
        MIR::Cleanup.new("t", CleanupEntry.from({ kind: :heap, alloc: :heap, has_moved_guard: false })),
      ]
      errors = checker.check_fn!(fn_def("ok", body))
      expect(errors.none? { |e| e.include?("INDIRECT_DOUBLE_BOX") }).to be true
    end
  end

  describe "HPT_LEAK" do
    it "detects discarded heap-returning call" do
      call = owned_call
      body = [
        MIR::ExprStmt.new(call, true),
      ]
      errors = checker.check_fn!(fn_def("hpt_leak", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("makeList") }).to be true
    end

    it "rejects heap-returning call bound to Let when the callee contract is absent" do
      call = owned_call
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", call, false, nil, nil),
        MIR::Cleanup.new("x", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
      ]
      errors = checker.check_fn!(fn_def("hpt_ok", body))
      expect(errors.any? { |e| e.include?("MIR_CALL_NO_CONTRACT") && e.include?("makeList") }).to be true
    end

    it "detects bound heap-returning call with no AllocMark" do
      call = owned_call
      body = [
        MIR::Let.new("x", call, false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("hpt_bound_no_alloc", body))
      expect(errors.any? { |e| e.include?("OWNED_RETURN_WITHOUT_ALLOC") && e.include?("x") }).to be true
    end

    it "rejects bound heap-returning call transferred out of scope when the callee contract is absent" do
      call = owned_call
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", call, false, nil, nil),
        MIR::TransferMark.new("x", :moved),
      ]
      errors = checker.check_fn!(fn_def("hpt_bound_transfer", body))
      expect(errors.any? { |e| e.include?("MIR_CALL_NO_CONTRACT") && e.include?("makeList") }).to be true
    end

    it "detects bound heap-returning call marked allocated but neither cleaned nor transferred" do
      call = owned_call
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", call, false, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("hpt_bound_alloc_only", body))
      expect(errors.any? { |e| e.include?("ALLOC_WITHOUT_CLEANUP") && e.include?("x") }).to be true
    end

    it "detects heap-returning binding marked as frame-allocated" do
      call = owned_call
      body = [
        alloc_mark("x", :frame),
        MIR::Let.new("x", call, false, nil, nil),
        MIR::Cleanup.new("x", CleanupEntry.from({ kind: :uniform, alloc: :frame, has_moved_guard: false })),
      ]
      errors = checker.check_fn!(fn_def("hpt_bound_frame_alloc", body))
      expect(errors.any? { |e| e.include?("OWNED_RETURN_ALLOC_NOT_HEAP") && e.include?("x") }).to be true
    end

    it "detects transfer marker with no allocation source" do
      body = [
        MIR::TransferMark.new("x", :moved),
      ]
      errors = checker.check_fn!(fn_def("transfer_without_alloc", body))
      expect(errors.any? { |e| e.include?("TRANSFER_WITHOUT_ALLOC") && e.include?("x") }).to be true
    end

    it "rejects ExprStmt with non-heap call when the callee contract is absent" do
      call = MIR::Call.new("doWork", [MIR::Ident.new("rt")], false)
      body = [
        MIR::ExprStmt.new(call, true),
      ]
      errors = checker.check_fn!(fn_def("no_heap", body))
      expect(errors.any? { |e| e.include?("MIR_CALL_NO_CONTRACT") && e.include?("doWork") }).to be true
    end

    it "detects heap call nested as argument" do
      inner = owned_call
      outer = MIR::Call.new("process", [inner], false)
      body = [
        MIR::ExprStmt.new(outer, true),
      ]
      errors = checker.check_fn!(fn_def("nested_hpt", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("makeList") }).to be true
    end

    it "detects discarded InlineZig stdlib call with allocates:true" do
      iz = MIR::InlineZig.new("CheatLib.clone({0})", "clone", MIR::OwnershipContract.empty, { allocates: true, return: :String, return_alloc: :heap })
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("stdlib_leak", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") }).to be true
    end

    it "detects discarded RawZig stdlib call with allocates:true" do
      rz = MIR::RawZig.new("try CheatLib.clone(value)", "raw_clone", MIR::OwnershipContract.empty, { allocates: true, return: :String, return_alloc: :heap })
      body = [
        MIR::ExprStmt.new(rz, false),
      ]
      errors = checker.check_fn!(fn_def("raw_stdlib_leak", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("RawZig block") }).to be true
    end

    it "rejects InlineZig stdlib call with allocates:true returning Void without explicit ownership facts" do
      iz = MIR::InlineZig.new("CheatLib.sort({0})", "sort", MIR::OwnershipContract.empty, { allocates: true, return: :Void })
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("stdlib_void", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_FACT_REQUIRED") }).to be true
    end

    it "detects HPT_LEAK inside nested lambda" do
      inner_call = owned_call
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

  describe "allocator and transfer invariants" do
    it "rejects return transfers without heap allocation proof" do
      missing = checker.check_fn!(fn_def("missing_return_alloc", [
        MIR::TransferMark.new("x", :return),
      ]))
      expect(missing.any? { |e| e.include?("RETURN_TRANSFER_WITHOUT_ALLOC") && e.include?("x") }).to be true

      frame_backed = checker.check_fn!(fn_def("frame_return_alloc", [
        alloc_mark("x", :frame),
        MIR::TransferMark.new("x", :return),
      ]))
      expect(frame_backed.any? { |e| e.include?("RETURN_TRANSFER_FRAME_ALLOC") && e.include?("x") }).to be true
    end

    it "rejects invalid allocator metadata" do
      iz = MIR::InlineZig.new("alloc({alloc})", "alloc", MIR::OwnershipContract.empty, nil, { alloc: :arena })
      body = [
        MIR::AllocMark.new("x", :arena, Type.new(:String), :heap),
        MIR::AllocMark.new("y", :heap, Type.new(:String), :nowhere),
        MIR::Cleanup.new("x", CleanupEntry.from({ kind: :uniform, alloc: :arena, has_moved_guard: false })),
        MIR::Let.new("x", iz, false, nil, nil),
      ]

      errors = checker.check_fn!(fn_def("bad_alloc_facts", body))
      expect(errors.any? { |e| e.include?("INVALID_ALLOCATOR_MARK") && e.include?(":arena") }).to be true
      expect(errors.any? { |e| e.include?("INVALID_ALLOCATOR_MARK") && e.include?(":nowhere") }).to be true
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_WITHOUT_TARGET") && e.include?("alloc") }).to be true
    end

    it "rejects double finalizers and cleanup after transfer" do
      entry = CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })
      double_finalizer = checker.check_fn!(fn_def("double_finalizer", [
        alloc_mark("x", :heap),
        MIR::Cleanup.new("x", entry),
        MIR::ErrCleanup.new("x", entry),
      ]))
      expect(double_finalizer.any? { |e| e.include?("OWNERSHIP_DOUBLE_FINALIZER") && e.include?("x") }).to be true

      after_transfer = checker.check_fn!(fn_def("cleanup_after_transfer", [
        alloc_mark("x", :heap),
        MIR::TransferMark.new("x", :moved),
        MIR::Cleanup.new("x", entry),
      ]))
      expect(after_transfer.any? { |e| e.include?("OWNERSHIP_DOUBLE_RELEASE") && e.include?("x") }).to be true
    end
  end

  describe "linear ownership hard errors" do
    it "rejects a MIR statement that is not registered for linear ownership traversal" do
      unknown = Class.new(Struct.new(:expr)) do
        include MIR::Stmt
      end
      stub_const("MIR::SpecUnknownStmt", unknown)

      body = [MIR::SpecUnknownStmt.new(MIR::Ident.new("x"))]
      errors = checker.check_fn!(fn_def("unknown_stmt", body))
      expect(errors.any? { |e| e.include?("LINEAR_STMT_NOT_REGISTERED") && e.include?("SpecUnknownStmt") }).to be true
    end

    it "rejects frame ownership transferred into an escaping sink" do
      body = [
        alloc_mark("x", :frame),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::TransferMark.new("x", :owned_sink, :heap),
      ]
      errors = checker.check_fn!(fn_def("frame_store_escape", body))
      expect(errors.any? { |e| e.include?("FRAME_ALLOC_ESCAPES") && e.include?("x") }).to be true
    end

    it "rejects owned sink transfer without destination allocator" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::TransferMark.new("x", :owned_sink),
      ]
      errors = checker.check_fn!(fn_def("implicit_sink_alloc", body))
      expect(errors.any? { |e| e.include?("IMPLICIT_OWNERSHIP_TRANSFER") && e.include?("x") }).to be true
    end

    it "rejects a read after ownership transfer" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::TransferMark.new("x", :owned_sink, :heap),
        MIR::ExprStmt.new(MIR::Ident.new("x"), false),
      ]
      errors = checker.check_fn!(fn_def("uaf_after_transfer", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_USE_AFTER_TRANSFER") && e.include?("x") }).to be true
    end

    it "rejects multiple success-path ownership transfers" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::TransferMark.new("x", :owned_sink, :heap),
        MIR::TransferMark.new("x", :return),
        MIR::ReturnStmt.new(MIR::Ident.new("x")),
      ]
      errors = checker.check_fn!(fn_def("double_transfer", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_DOUBLE_RELEASE") && e.include?("x") }).to be true
    end

    it "rejects transfer with an unguarded cleanup finalizer" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::Cleanup.new("x", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
        MIR::TransferMark.new("x", :owned_sink, :heap),
      ]
      errors = checker.check_fn!(fn_def("cleanup_and_transfer", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_DOUBLE_RELEASE") && e.include?("x") }).to be true
    end

    it "rejects MoveMark without an explicit transfer" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::Cleanup.new("x", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: true })),
        MIR::MoveMark.new("x"),
      ]
      errors = checker.check_fn!(fn_def("implicit_move", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_IMPLICIT_MOVE") && e.include?("x") }).to be true
    end

    it "rejects branch joins with different ownership state" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::IfStmt.new(
          MIR::Lit.new("cond"),
          [MIR::TransferMark.new("x", :owned_sink, :heap)],
          [],
        ),
      ]
      errors = checker.check_fn!(fn_def("branch_owner_split", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_UNVERIFIED_PATH") && e.include?("if") }).to be true
    end

    it "rejects return transfer with no ReturnStmt" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::TransferMark.new("x", :return),
      ]
      errors = checker.check_fn!(fn_def("return_transfer_no_return", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_UNVERIFIED_PATH") && e.include?("x") }).to be true
    end

    it "rejects return transfer that does not match returned expression" do
      body = [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::TransferMark.new("x", :return),
        MIR::ReturnStmt.new(MIR::Ident.new("y")),
      ]
      errors = checker.check_fn!(fn_def("return_transfer_wrong_expr", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_UNVERIFIED_PATH") && e.include?("x") }).to be true
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
        alloc_mark("parts", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("mismatch_inline", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("parts") }).to be true
    end

    it "rejects frame append on frame list without a callable/effect contract" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :frame }
      iz.target_var = "parts"
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("parts", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("ok_inline", body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") && e.include?("intrinsic") }).to be true
      expect(errors.none? { |e| e.include?("INLINE_ALLOC_MISMATCH") }).to be true
    end

    it "catches frame val_alloc stored in heap container" do
      iz = MIR::InlineZig.new("try {target}.put({key_alloc}, {val_alloc}, {index}, {value})", "index_set")
      iz.allocs = { key_alloc: :heap, val_alloc: :frame }
      iz.target_var = "map"
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("map", :heap),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("frame_val_in_heap", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("val_alloc") }).to be true
    end

    it "rejects heap key_alloc/val_alloc in heap container without a callable/effect contract" do
      iz = MIR::InlineZig.new("try {target}.put({key_alloc}, {val_alloc}, {index}, {value})", "index_set")
      iz.allocs = { key_alloc: :heap, val_alloc: :heap }
      iz.target_var = "map"
      cleanup = MIR::Cleanup.new("map", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false,
                                           zig_type: "CheatLib.StringMap(i64)" }))
      body = [
        alloc_mark("map", :heap),
        MIR::ExprStmt.new(iz, false),
        cleanup,
      ]
      errors = checker.check_fn!(fn_def("heap_map_ok", body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") && e.include?("index_set") }).to be true
      expect(errors.none? { |e| e.include?("INLINE_ALLOC_MISMATCH") }).to be true
    end

    it "rejects operations on non-local containers without an AllocMark" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "external_list"
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("external_ok", body))
      expect(errors.join("\n")).to include("INLINE_ALLOC_WITHOUT_ALLOCMARK")
    end

    it "detects mismatch for InlineZig found directly (not wrapped in ExprStmt)" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "items"
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("items", :frame),
        iz,
      ]
      errors = checker.check_fn!(fn_def("direct_iz", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("items") }).to be true
    end

    it "detects mismatch for allocator-bearing InlineZig wrapped in DiscardOwned" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "parts"
      cleanup = CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("parts", :frame),
        MIR::DiscardOwned.new(iz, cleanup, "void"),
      ]

      errors = checker.check_fn!(fn_def("discarded_iz", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("parts") }).to be true
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

    it "rejects pointer-passed param mutation without a callable/effect contract even when allocator is :heap" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :heap }
      iz.target_var = "items"
      body = [
        alloc_mark("items", :heap, Type.new(:"String[]", collection: :list)),
        MIR::TransferMark.new("items", :external_param),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_with_ptr_param(body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") && e.include?("intrinsic") }).to be true
      expect(errors.none? { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") }).to be true
    end

    it "ignores :frame allocator on a NON-pointer-passed local binding" do
      iz = MIR::InlineZig.new("try {0}.append({alloc}, {1})", "intrinsic")
      iz.allocs = { alloc: :frame }
      iz.target_var = "local_list"
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("local_list", :frame),
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
        alloc_mark("anything", :frame),
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
      body = [alloc_mark("x", :frame)]
      errors = checker.check_fn!(fn_def("no_save", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "passes for function body with only heap allocs" do
      body = [alloc_mark("x", :heap)]
      errors = checker.check_fn!(fn_def("heap_only", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "detects loop with frame alloc but no restoreLoopMark defer" do
      loop_body = [alloc_mark("tmp", :frame, scope: :iteration)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("loop_no_restore", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "passes for loop with restoreLoopMark defer (structural check)" do
      loop_body = [loop_restore_defer, alloc_mark("tmp", :frame, scope: :iteration)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("loop_with_restore", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "detects loop with mark_per_iter flag but no restoreLoopMark defer (lowerer bug)" do
      # mark_per_iter=true but lowerer failed to emit the defer -- checker catches it
      loop_body = [alloc_mark("tmp", :frame, scope: :iteration)]
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
      iz.target_var = "tmp"
      loop_body = [alloc_mark("tmp", :frame, scope: :iteration), MIR::ExprStmt.new(iz, false)]
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
      iz.target_var = "tmp"
      loop_body = [alloc_mark("tmp", :frame, scope: :iteration), MIR::Let.new("tmp", iz, false, nil, nil)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::ForStmt.new("i", MIR::Ident.new("items"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("for_no_restore", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside an if-branch (no restore)" do
      if_body = [alloc_mark("tmp", :frame, scope: :iteration)]
      loop_body = [MIR::IfStmt.new(MIR::Lit.new("cond"), if_body, [])]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("if_branch_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside an else-branch (no restore)" do
      else_body = [alloc_mark("tmp", :frame, scope: :iteration)]
      loop_body = [MIR::IfStmt.new(MIR::Lit.new("cond"), [], else_body)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("else_branch_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects loop with frame alloc inside a ScopeBlock (no restore)" do
      scope_body = [alloc_mark("tmp", :frame, scope: :iteration)]
      loop_body = [MIR::ScopeBlock.new(scope_body)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("scope_block_alloc", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "does NOT flag outer loop for frame alloc only inside a nested inner loop" do
      inner_loop_body = [alloc_mark("tmp", :frame, scope: :iteration)]
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
      if_body = [alloc_mark("tmp", :frame, scope: :iteration)]
      loop_body = [loop_restore_defer, MIR::IfStmt.new(MIR::Lit.new("cond"), if_body, [])]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("if_branch_with_restore", body))
      expect(errors.select { |e| e.include?("FRAME_NO_REWIND") }).to be_empty
    end

    it "passes for tight loop (no frame rewind needed)" do
      loop_body = [alloc_mark("tmp", :frame, scope: :iteration)]
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
      expect(errors.any? { |e| e.include?("bad_call") }).to be true
    end

    it "passes when stdlib_def is set" do
      iz = MIR::InlineZig.new("try CheatLib.makeList(u8, alloc, items)", "ok_call")
      iz.stdlib_def = { allocates: true }
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.select { |e| e.include?("INLINE_NO_CONTRACT") }).to be_empty
    end

    it "rejects opaque allocator ownership even when stdlib_def is set" do
      iz = MIR::InlineZig.new("const p = try rt.heapAlloc().create(Node); rt.heapAlloc().destroy(p);", "opaque_alloc")
      iz.stdlib_def = FunctionSignature.new(params: [], return_type: Type.new(:Void), intrinsic: true)
      iz.mark_opaque_ownership_operations!
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("OPAQUE_ZIG_OWNERSHIP") && e.include?("opaque_alloc") }).to be true
    end

    it "rejects formerly exempt CheatLib calls without a callable/effect contract" do
      iz = MIR::InlineZig.new("CheatLib.intAdd(a, b)", "math")
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") && e.include?("math") }).to be true
    end

    it "detects unaudited CheatLib call in Let init" do
      iz = MIR::InlineZig.new("try CheatLib.promote(T, rt, &val)", "promote")
      body = [MIR::Let.new("x", iz, false, nil, nil)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") }).to be true
    end

    it "detects unaudited InlineZig nested inside another expression" do
      iz = MIR::InlineZig.new("opaqueValue()", "nested_opaque")
      body = [MIR::ExprStmt.new(MIR::Call.new("use", [iz], false), false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("INLINE_NO_CONTRACT") && e.include?("nested_opaque") }).to be true
    end

    it "does not require contracts for simple assignment-shaped inline Zig" do
      iz = MIR::InlineZig.new("value.* = next", "assignment")
      expect(checker.send(:inline_zig_requires_contract?, iz)).to be false
    end
  end

  describe "MIR_CALL_NO_CONTRACT" do
    it "rejects plain MIR::Call without a callable/effect contract" do
      body = [MIR::ExprStmt.new(MIR::Call.new("callee", [MIR::Ident.new("x")], false), false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("MIR_CALL_NO_CONTRACT") && e.include?("callee") }).to be true
    end

    it "accepts MIR::Call with a typed callable/effect contract" do
      sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
      contract = MIR::CallableContract.new(sig, MIR::OwnershipContract.empty, 0)
      body = [MIR::ExprStmt.new(MIR::Call.new("callee", [], false, false, contract), false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.none? { |e| e.include?("MIR_CALL_NO_CONTRACT") }).to be true
    end

    it "rejects TAKES callable contracts without concrete consumed binding names" do
      param = AST::Param.new(name: "x", type: Type.new(:String), takes: true)
      sig = FunctionSignature.new(params: [param], return_type: Type.new(:Void))
      contract = MIR::CallableContract.new(sig, MIR::OwnershipContract.empty, 1)
      body = [MIR::ExprStmt.new(MIR::Call.new("takeIt", [MIR::Ident.new("x")], false, false, contract), false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("IMPLICIT_OWNERSHIP_TRANSFER") && e.include?("takeIt") }).to be true
    end

    it "accepts TAKES callable contracts that explicitly examined consuming params but found no owned binding" do
      param = AST::Param.new(name: "x", type: Type.new(:Int64), takes: true)
      sig = FunctionSignature.new(params: [param], return_type: Type.new(:Void))
      ownership = MIR::OwnershipContract.new(covers_consuming_params: true)
      contract = MIR::CallableContract.new(sig, ownership, 1)
      body = [MIR::ExprStmt.new(MIR::Call.new("takeInt", [MIR::Lit.new("1")], false, false, contract), false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.none? { |e| e.include?("IMPLICIT_OWNERSHIP_TRANSFER") }).to be true
    end

    it "rejects callable contracts that do not cover the callsite arguments" do
      sig = FunctionSignature.new(params: [], return_type: Type.new(:Void))
      contract = MIR::CallableContract.new(sig, MIR::OwnershipContract.empty, 1)
      body = [MIR::ExprStmt.new(MIR::Call.new("callee", [MIR::Ident.new("x")], false, false, contract), false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("MIR_CALL_NO_CONTRACT") && e.include?("callsite has 1 args") }).to be true
    end

    it "rejects MIR::MethodCall without a callable/effect contract" do
      body = [MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new("items"), "append", [MIR::Ident.new("x")], true), false)]
      errors = checker.check_fn!(fn_def("f", body))
      expect(errors.any? { |e| e.include?("MIR_CALL_NO_CONTRACT") && e.include?("append") }).to be true
    end
  end

  # ===========================================================================
  # ALLOC_CLEANUP_MISMATCH -- AllocMark allocator must match Cleanup allocator
  # ===========================================================================

  describe "ALLOC_CLEANUP_MISMATCH" do
    it "detects frame alloc with heap cleanup" do
      cleanup_entry = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })
      body = [
        alloc_mark("data", :frame),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("frame_alloc_heap_cleanup", body))
      expect(errors.any? { |e| e.include?("ALLOC_CLEANUP_MISMATCH") && e.include?("data") }).to be true
    end

    it "detects heap alloc with frame cleanup" do
      cleanup_entry = CleanupEntry.from({ kind: :heap_string, alloc: :frame, has_moved_guard: false })
      body = [
        alloc_mark("data", :heap),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("heap_alloc_frame_cleanup", body))
      expect(errors.any? { |e| e.include?("ALLOC_CLEANUP_MISMATCH") && e.include?("data") }).to be true
    end

    it "passes for matching frame alloc and frame cleanup" do
      cleanup_entry = CleanupEntry.from({ kind: :heap_string, alloc: :frame, has_moved_guard: false })
      body = [
        alloc_mark("data", :frame),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("ok_frame", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "passes for matching heap alloc and heap cleanup" do
      cleanup_entry = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: true })
      body = [
        alloc_mark("data", :heap),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("ok_heap", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "passes for cleanup with no AllocMark (TAKES parameter)" do
      cleanup_entry = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })
      body = [
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("takes_param", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "passes for alloc with no cleanup (moved/escaped via return)" do
      body = [
        alloc_mark("data", :heap),
      ]
      errors = checker.check_fn!(fn_def("moved", body))
      expect(errors.select { |e| e.include?("ALLOC_CLEANUP_MISMATCH") }).to be_empty
    end

    it "detects mismatch inside an if branch" do
      cleanup_entry = CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false })
      branch_body = [
        alloc_mark("line", :frame),
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
      expect(errors.any? { |e| e.include?("UNHOISTED_ALLOC") }).to be true
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
      call = owned_call
      body = [MIR::ExprStmt.new(call, true)]
      errors = checker.check_fn!(fn_def("hpt_still_works", body), strict: true)
      expect(errors.any? { |e| e.include?("HPT_LEAK") }).to be true
    end
  end

  describe "IMPLICIT_OWNERSHIP_TRANSFER" do
    def takes_signature
      FunctionSignature.new(
        params: [
          AST::Param.new(name: "value", type: Type.new(:Any), required: true, takes: true)
        ],
        return_type: Type.new(:Void),
        intrinsic: true
      )
    end

    it "rejects a TAKES stdlib call with no concrete consumed binding contract" do
      iz = MIR::InlineZig.new("try items.append({alloc}, m)", "intrinsic", MIR::OwnershipContract.empty, takes_signature, { alloc: :heap }, "items")
      body = [
        alloc_mark("items", :heap),
        MIR::Cleanup.new("items", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
        iz,
      ]
      errors = checker.check_fn!(fn_def("implicit_take", body))
      expect(errors.any? { |e| e.include?("IMPLICIT_OWNERSHIP_TRANSFER") && e.include?("items") }).to be true
    end

    it "rejects malformed ownership contracts at the MIR node boundary" do
      iz = MIR::InlineZig.new("try items.append({alloc}, m)", "intrinsic", MIR::OwnershipContract.empty, takes_signature, { alloc: :heap }, "items")
      rz = MIR::RawZig.new("try items.append(rt.heapAlloc(), m);", "intrinsic", MIR::OwnershipContract.empty, takes_signature)

      expect { iz[:ownership_contract] = { consumes: ["m"] } }.to raise_error(TypeError, /MIR::OwnershipContract/)
      expect { rz[:ownership_contract] = nil }.to raise_error(TypeError, /MIR::OwnershipContract/)
      expect { iz.ownership_contract.consumes << "late" }.to raise_error(FrozenError)
    end

    it "rejects a consumed binding that has no TransferMark" do
      contract = MIR::OwnershipContract.consumes(["m"])
      iz = MIR::InlineZig.new("try items.append({alloc}, m)", "intrinsic", contract, takes_signature, { alloc: :heap }, "items")
      body = [
        alloc_mark("items", :heap),
        MIR::Cleanup.new("items", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
        iz,
      ]
      errors = checker.check_fn!(fn_def("take_without_transfer", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_CONTRACT_WITHOUT_TRANSFER") && e.include?("m") }).to be true
    end

    it "rejects a transfer contract whose emitted Zig deep-copies the consumed source" do
      contract = MIR::OwnershipContract.consumes(["m"])
      iz = MIR::InlineZig.new(
        "try items.append({alloc}, try CheatLib.dupeValue(CheatLib.StringMap(i64), m, rt.heapAlloc()))",
        "intrinsic",
        contract,
        takes_signature,
        { alloc: :heap },
        "items"
      )
      iz.mark_copied_consumed_binding!("m")
      body = [
        alloc_mark("m", :heap),
        MIR::TransferMark.new("m", :owned_sink, :heap),
        alloc_mark("items", :heap),
        MIR::Cleanup.new("items", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
        iz,
      ]
      errors = checker.check_fn!(fn_def("take_copy_mismatch", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_TRANSFER_COPIED") && e.include?("m") }).to be true
    end

    it "preserves InlineZig ownership metadata when stripping try" do
      iz = MIR::InlineZig.new("try use(m)", "intrinsic")
      iz.mark_opaque_ownership_operations!
      iz.mark_copied_consumed_binding!("m")

      stripped = iz.without_try
      expect(stripped.code).to eq("use(m)")
      expect(stripped.opaque_ownership_operations).to be true
      expect(stripped.copied_consumed_bindings).to eq(["m"])
    end

    it "strips try from RawZig without regex parsing" do
      raw = MIR::RawZig.new("try rawCall()", "raw")
      expect(raw.without_try.code).to eq("rawCall()")
    end
  end

  # ===========================================================================
  # check_program! -- verifies all functions
  # ===========================================================================

  describe "#check_program!" do
    it "collects errors across multiple functions" do
      call1 = owned_call
      fn1 = fn_def("good", [
        alloc_mark("x", :heap),
        MIR::Let.new("x", call1, false, nil, nil),
        MIR::Cleanup.new("x", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
      ])

      call2 = owned_call
      fn2 = fn_def("bad", [
        MIR::ExprStmt.new(call2, true),
      ])

      program = checked_program([fn1, fn2])
      errors = checker.check_program!(program)
      expect(errors.any? { |e| e.include?("good::makeList") && e.include?("MIR_CALL_NO_CONTRACT") }).to be true
      expect(errors.any? { |e| e.include?("bad::makeList") && e.include?("HPT_LEAK") }).to be true
      expect(errors.any? { |e| e.include?("bad::makeList") && e.include?("MIR_CALL_NO_CONTRACT") }).to be true
    end

    it "returns empty for clean program" do
      fn1 = fn_def("ok", [
        MIR::Let.new("x", MIR::Lit.new("42"), false, nil, nil),
      ])
      program = checked_program([fn1])
      errors = checker.check_program!(program)
      expect(errors).to be_empty
    end
  end

  describe "execution boundary facts" do
    it "rejects BgBlock without a typed boundary fact" do
      bg = MIR::BgBlock.new("{}", {}, [MIR::ExprStmt.new(MIR::Lit.new("1"), false)])

      errors = checker.check_fn!(fn_def("missing_bg_fact", [bg]))

      expect(errors.any? { |e| e.include?("BOUNDARY_FACT_REQUIRED") && e.include?("MIR::BgBlock") }).to be true
    end

    it "rejects DoBlock when fact count does not match branch bodies" do
      do_block = MIR::DoBlock.new("{}", [[MIR::ExprStmt.new(MIR::Lit.new("1"), false)]])
      do_block.boundary_facts = []

      errors = checker.check_fn!(fn_def("bad_do_fact_count", [do_block]))

      expect(errors.any? { |e| e.include?("BOUNDARY_FACT_REQUIRED") && e.include?("0 boundary facts for 1 branch bodies") }).to be true
    end

    it "rejects parallel boundary captures not proven parallel safe" do
      bg = MIR::BgBlock.new("{}", {}, [MIR::ExprStmt.new(MIR::Lit.new("1"), false)])
      bg.boundary_fact = boundary_fact(
        dispatch: :parallel,
        captures: [boundary_capture("x", parallel_safe: false, forbidden_reason: :affine_locked)],
      )

      errors = checker.check_fn!(fn_def("unsafe_parallel_capture", [bg]))

      expect(errors.any? { |e| e.include?("BOUNDARY_CAPTURE_NOT_PARALLEL_SAFE") && e.include?("x") }).to be true
    end
  end

  describe "ownership registry invariants" do
    it "has no unregistered ownership-significant MIR node classes" do
      errors = checker.ownership_registry_errors

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
