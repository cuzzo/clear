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

  def registry_sig(return_type: Type.new(:Void), allocates: false, return_alloc: nil, mutates_receiver: false, params: [], fixed_return: true)
    sig = FunctionSignature.new(params: params, return_type: return_type, intrinsic: true)
    sig.emit = IntrinsicEmit.new(
      zig: "#{return_type.resolved}({0})",
      allocates: allocates,
      return_alloc: return_alloc,
      mutates_receiver: mutates_receiver,
    )
    sig.fixed_return = fixed_return if sig.respond_to?(:fixed_return=)
    sig
  end

  def registry_call(reason, sig, allocs: nil, target_var: nil, ownership_contract: MIR::OwnershipContract.empty)
    MIR::RegistryCall.new(
      entry: sig,
      args: [],
      reason: reason,
      ownership_contract: ownership_contract,
      allocs: allocs,
      target_var: target_var,
    )
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

  def structural_bg_plan
    MIR::FsmB1Body.new(
      "__bg_checker",
      MIR::FsmB1CtxStruct.new(
        "__BgCheckerCtx",
        "CheatLib.Promise(void)",
        [],
        MIR::FsmStep.new(0, 0, "__rt_checker", false, []),
      ),
      nil,
    )
  end

  def bg_block(run_body = [])
    MIR::BgBlock.new(structural_bg_plan, {}, run_body, nil)
  end

  def structural_do_block(branch_bodies)
    MIR::DoBlock.new(MIR::DoBlockPlan.new(wg_var: "__wg_checker", branches: []), branch_bodies)
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

    it "allows cleanup when a registry call returns an owned resource" do
      signature = FunctionSignature.new(params: [], return_type: Type.new(:TCPClient))
      signature.emit = IntrinsicEmit.new(zig: "accept()", allocates: true)
      registry_call = MIR::RegistryCall.new(
        entry: signature,
        args: [],
        reason: "accept resource",
        allocs: MIR::InlineAllocMetadata.new(result_alloc: :heap),
      )

      body = [
        alloc_mark("client", :heap, Type.new(:TCPClient)),
        MIR::Let.new("client", registry_call, false, nil, nil),
        MIR::Cleanup.new("client", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: true })),
      ]

      errors = checker.check_fn!(fn_def("registry_resource_cleanup", body))
      expect(errors.none? { |e| e.include?("OWNERSHIP_CLEANUP_FOR_BORROW") }).to be true
    end

    it "allows cleanup when an extern trampoline allocates its result" do
      signature = FunctionSignature.new(params: [], return_type: Type.new(:Void), intrinsic: true)
      signature.emit = IntrinsicEmit.new(zig: "parse()", allocates: true)
      trampoline = MIR::ExternTrampoline.new(
        id: 1,
        callee_name: "parse",
        alloc_kind: :heap,
        return_type: Type.new(:Parsed),
        stdlib_def: signature,
      )
      body = [
        alloc_mark("parsed", :heap, Type.new(:Parsed)),
        MIR::Let.new("parsed", trampoline, false, nil, nil),
        MIR::Cleanup.new("parsed", CleanupEntry.from({ kind: :resource, alloc: :heap, has_moved_guard: false })),
      ]

      errors = checker.check_fn!(fn_def("extern_trampoline_resource_cleanup", body))
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

    it "detects discarded registry stdlib call with allocates:true" do
      iz = registry_call("clone", FunctionSignature.intrinsic_contract(return_type: Type.new(:String), allocates: true, return_alloc: :heap))
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("stdlib_leak", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") }).to be true
    end

    it "detects fixed-return registry leaks even when ownership effect metadata is suppressed" do
      sig = FunctionSignature.intrinsic_contract(return_type: Type.new(:String), allocates: true, return_alloc: :heap)
      iz = registry_call("clone_fixed", sig, allocs: MIR.inline_alloc_metadata(alloc: :heap))

      errors = checker.check_fn!(fn_def("stdlib_fixed_leak", [MIR::ExprStmt.new(iz, false)]))

      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("clone_fixed") }).to be true
    end

    it "rejects registry stdlib call with allocates:true returning Void without explicit ownership facts" do
      iz = registry_call("sort", FunctionSignature.intrinsic_contract(return_type: Type.new(:Void), allocates: true))
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("stdlib_void", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_FACT_REQUIRED") }).to be true
    end

    it "does not require ownership facts for pure receiver-growth allocator metadata" do
      sig = FunctionSignature.intrinsic_contract(return_type: Type.new(:Void), allocates: true)
      T.must(sig.emit).mutates_receiver = true
      iz = registry_call("append", sig, allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "parts")
      body = [
        alloc_mark("parts", :heap, Type.new(:"Int64[]", collection: :list)),
        MIR::ExprStmt.new(iz, false),
      ]

      errors = checker.check_fn!(fn_def("receiver_growth", body))

      expect(errors.none? { |e| e.include?("OWNERSHIP_FACT_REQUIRED") }).to be true
    end

    it "does not require finalized owned facts for TAKES calls with only non-owning operands" do
      value_param = AST::Param.new(name: "value", type: Type.new(:Int64), default: nil, mutable: false,
        takes: true, comptime: false, name_token: nil, required: nil, sync: nil)
      sig = FunctionSignature.new(params: [value_param], return_type: Type.new(:Void), intrinsic: true)
      sig.emit = IntrinsicEmit.new(zig: "append({0})", allocates: true, mutates_receiver: true)
      contract = MIR::OwnershipContract.consume_operands([
        MIR::OwnershipOperandFact.non_owning(Type.new(:Int64), "spec"),
      ])
      iz = registry_call("append_scalar", sig,
        allocs: MIR.inline_alloc_metadata(alloc: :heap),
        target_var: "parts",
        ownership_contract: contract)
      body = [
        alloc_mark("parts", :heap, Type.new(:"Int64[]", collection: :list)),
        MIR::ExprStmt.new(iz, false),
      ]

      errors = checker.check_fn!(fn_def("non_owning_takes", body))

      expect(errors.none? { |e| e.include?("OWNERSHIP_FACT_REQUIRED") }).to be true
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
      iz = registry_call("alloc", FunctionSignature.intrinsic_contract(return_type: Type.new(:Void)), allocs: MIR::InlineAllocMetadata.new(alloc: :arena))
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
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "parts")
      body = [
        alloc_mark("parts", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("mismatch_inline", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("parts") }).to be true
    end

    it "accepts frame append on frame list when allocator metadata matches" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "parts")
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("parts", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("ok_inline", body))
      expect(errors.none? { |e| e.include?("INLINE_ALLOC_MISMATCH") }).to be true
    end

    it "catches frame val_alloc stored in heap container" do
      iz = registry_call("index_set", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(key_alloc: :heap, val_alloc: :frame), target_var: "map")
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("map", :heap),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("frame_val_in_heap", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("val_alloc") }).to be true
    end

    it "accepts heap key_alloc/val_alloc in heap container" do
      iz = registry_call("index_set", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(key_alloc: :heap, val_alloc: :heap), target_var: "map")
      cleanup = MIR::Cleanup.new("map", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false,
                                           zig_type: "CheatLib.StringMap(i64)" }))
      body = [
        alloc_mark("map", :heap),
        MIR::ExprStmt.new(iz, false),
        cleanup,
      ]
      errors = checker.check_fn!(fn_def("heap_map_ok", body))
      expect(errors.none? { |e| e.include?("INLINE_ALLOC_MISMATCH") }).to be true
    end

    it "rejects operations on non-local containers without an AllocMark" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "external_list")
      body = [
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_def("external_ok", body))
      expect(errors.join("\n")).to include("INLINE_ALLOC_WITHOUT_ALLOCMARK")
    end

    it "detects mismatch for registry call found directly (not wrapped in ExprStmt)" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "items")
      body = [
        MIR::FrameSave.new("rt"),
        alloc_mark("items", :frame),
        iz,
      ]
      errors = checker.check_fn!(fn_def("direct_iz", body))
      expect(errors.any? { |e| e.include?("INLINE_ALLOC_MISMATCH") && e.include?("items") }).to be true
    end

    it "detects mismatch for allocator-bearing registry call wrapped in DiscardOwned" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "parts")
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
  # `.append` (a structural op with `alloc: :receiver_storage`) must
  # resolve to `:heap`, not `:frame`. If lowering's `resolve_alloc_sym`
  # ever regresses, the checker catches it here independently.

  describe "CROSS_FRAME_PARAM_ALLOC" do
    # Helper: FnDef with one pointer-passed param.
    def fn_with_ptr_param(body)
      param = MIR::Param.new("items", "anytype", true)
      MIR::FnDef.new("record", [param], "void", body, :pub, true, nil)
    end

    it "detects :frame allocator on a pointer-passed @list param" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "items")
      body = [MIR::ExprStmt.new(iz, false)]
      errors = checker.check_fn!(fn_with_ptr_param(body))
      expect(errors.any? { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") && e.include?("items") }).to be true
    end

    it "accepts pointer-passed param mutation when allocator is :heap" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "items")
      body = [
        alloc_mark("items", :heap, Type.new(:"String[]", collection: :list)),
        MIR::TransferMark.new("items", :external_param),
        MIR::ExprStmt.new(iz, false),
      ]
      errors = checker.check_fn!(fn_with_ptr_param(body))
      expect(errors.none? { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") }).to be true
    end

    it "ignores :frame allocator on a NON-pointer-passed local binding" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "local_list")
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
      iz = registry_call("index_set", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(key_alloc: :frame, val_alloc: :frame), target_var: "map")
      param = MIR::Param.new("map", "anytype", true)
      fn = MIR::FnDef.new("update", [param], "void", [MIR::ExprStmt.new(iz, false)], :pub, true, nil)
      errors = checker.check_fn!(fn)
      ksay = errors.select { |e| e.include?("CROSS_FRAME_PARAM_ALLOC") }
      expect(ksay.length).to eq(2)
      expect(ksay.any? { |e| e.include?("key_alloc") }).to be true
      expect(ksay.any? { |e| e.include?("val_alloc") }).to be true
    end

    it "no-ops on functions with empty params (no false positives)" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "anything")
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
      iz = registry_call("iter", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "slice")
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

    it "detects restoreLoopMark enclosing non-iteration frame allocations" do
      loop_body = [loop_restore_defer, alloc_mark("tmp", :frame, scope: :function)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("loop_restore_wrong_scope", body))
      expect(errors.any? { |e|
        e.include?("FRAME_NO_REWIND") &&
          e.include?("not scoped to one iteration")
      }).to be true
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

    it "detects loop with frame registry alloc but no restoreLoopMark defer" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "tmp")
      loop_body = [alloc_mark("tmp", :frame, scope: :iteration), MIR::ExprStmt.new(iz, false)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("iz_loop_no_restore", body))
      expect(errors.any? { |e| e.include?("FRAME_NO_REWIND") }).to be true
    end

    it "detects ForStmt with frame Let init but no restoreLoopMark defer" do
      iz = registry_call("intrinsic", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "tmp")
      loop_body = [alloc_mark("tmp", :frame, scope: :iteration), MIR::Let.new("tmp", iz, false, nil, nil)]
      body = [
        MIR::FrameSave.new("rt"),
        MIR::ForStmt.new(MIR::Ident.new("items"), "i", loop_body, nil, nil, nil),
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

  describe "raw Zig carriers" do
    it "does not expose an opaque Zig MIR node" do
      expect(MIR.const_defined?(:InlineZig, false)).to be(false)
      expect(MIR.const_defined?(:RawBc, false)).to be(false)
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

    it "rejects ReassignWithCleanup when its allocator disagrees with the target AllocMark" do
      cleanup_entry = CleanupEntry.from({ kind: :heap_string, alloc: :frame, has_moved_guard: false })
      body = [
        alloc_mark("data", :frame),
        MIR::ReassignWithCleanup.new("data", MIR::Lit.new("\"next\""), "[]const u8", :heap),
        MIR::Cleanup.new("data", cleanup_entry),
      ]
      errors = checker.check_fn!(fn_def("reassign_alloc_mismatch", body))
      expect(errors.any? { |e|
        e.include?("ALLOC_CLEANUP_MISMATCH") &&
          e.include?("ReassignWithCleanup") &&
          e.include?("data")
      }).to be true
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
      iz = registry_call("items", takes_signature,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "items")
      body = [
        alloc_mark("items", :heap),
        MIR::Cleanup.new("items", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
        iz,
      ]
      errors = checker.check_fn!(fn_def("implicit_take", body))
      expect(errors.any? { |e| e.include?("IMPLICIT_OWNERSHIP_TRANSFER") && e.include?("items") }).to be true
    end

    it "freezes ownership contracts at the MIR node boundary" do
      iz = registry_call("items", takes_signature,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "items")

      expect {
        iz.ownership_contract.operands << MIR::OwnershipOperandFact.owned_binding("late", Type.new(:String), "spec", :heap)
      }.to raise_error(FrozenError)
    end

    it "rejects a consumed binding that has no TransferMark" do
      contract = MIR::OwnershipContract.consume_operands([
        MIR::OwnershipOperandFact.owned_binding("m", Type.new(:String), "spec", :heap),
      ])
      iz = registry_call("items", takes_signature, ownership_contract: contract,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "items")
      body = [
        alloc_mark("items", :heap),
        MIR::Cleanup.new("items", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })),
        iz,
      ]
      errors = checker.check_fn!(fn_def("take_without_transfer", body))
      expect(errors.any? { |e| e.include?("OWNERSHIP_CONTRACT_WITHOUT_TRANSFER") && e.include?("m") }).to be true
    end

    it "preserves registry ownership metadata when stripping try" do
      contract = MIR::OwnershipContract.consume_operands([
        MIR::OwnershipOperandFact.owned_binding("m", Type.new(:String), "spec", :heap),
      ])
      iz = registry_call("intrinsic", takes_signature, ownership_contract: contract,
        allocs: MIR.inline_alloc_metadata(alloc: :heap), target_var: "items")
      stripped = iz.without_try
      expect(stripped.ownership_contract).to eq(contract)
      expect(stripped.allocs).to eq(iz.allocs)
      expect(stripped.target_var).to eq("items")
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

    it "checks functions inside structural module namespaces" do
      namespace = MIR::ModuleNamespace.new("helper", [
        fn_def("bad_imported_fn", [MIR::ExprStmt.new(owned_call, true)]),
        MIR::StructDef.new("Payload", [], nil, :pub),
      ])
      program = checked_program([namespace])

      errors = checker.check_program!(program)

      expect(errors.any? { |e| e.include?("bad_imported_fn::makeList") && e.include?("HPT_LEAK") }).to be true
    end
  end

  describe "execution boundary facts" do
    it "rejects BgBlock without a typed boundary fact" do
      bg = bg_block([MIR::ExprStmt.new(MIR::Lit.new("1"), false)])

      errors = checker.check_fn!(fn_def("missing_bg_fact", [bg]))

      expect(errors.any? { |e| e.include?("BOUNDARY_FACT_REQUIRED") && e.include?("MIR::BgBlock") }).to be true
    end

    it "rejects DoBlock when fact count does not match branch bodies" do
      do_block = structural_do_block([[MIR::ExprStmt.new(MIR::Lit.new("1"), false)]])
      do_block.boundary_facts = []

      errors = checker.check_fn!(fn_def("bad_do_fact_count", [do_block]))

      expect(errors.any? { |e| e.include?("BOUNDARY_FACT_REQUIRED") && e.include?("0 boundary facts for 1 branch bodies") }).to be true
    end

    it "rejects parallel boundary captures not proven parallel safe" do
      bg = bg_block([MIR::ExprStmt.new(MIR::Lit.new("1"), false)])
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

  describe "checker edge coverage" do
    def owned_operand(name, alloc: :heap)
      MIR::OwnershipOperandFact.owned_binding(name, Type.new(:String), "spec", alloc)
    end

    def borrowed_operand(name)
      MIR::OwnershipOperandFact.borrowed_access(name, Type.new(:String), "spec", :heap)
    end

    def consumption_fact(operands)
      MIR::OwnershipConsumptionFact.new(
        operands: operands,
        target: :owned_sink,
        target_alloc: :heap,
        source: "spec",
        covers_consuming_params: true,
      )
    end

    it "covers fact and operand verifier diagnostics" do
      bad_mark = alloc_mark("bad", :heap)
      bad_mark.type_info = Type.new(:Untyped)
      checker.send(:verify_alloc_marks_typed!, "bad" => [bad_mark])

      reassign = MIR::ReassignWithCleanup.new("dst", MIR::Ident.new("owned"), "[]const u8", :heap)
      reassign.ownership_consumption = consumption_fact([owned_operand("owned")])
      checker.send(:verify_structural_ownership_contracts!, [reassign], Set.new, "owned" => [alloc_mark("owned", :heap)])

      mismatched = MIR::ReassignWithCleanup.new("dst", MIR::Ident.new("frame_owned"), "[]const u8", :heap)
      mismatched.ownership_consumption = consumption_fact([owned_operand("frame_owned", alloc: :frame)])
      checker.send(:verify_structural_ownership_contracts!, [mismatched], Set["frame_owned"], "frame_owned" => [alloc_mark("frame_owned", :frame)])

      missing_fact = MIR::Let.new("missing", MIR::Lit.new("1"), false, nil, nil)
      empty_fact = MIR::Let.new("empty", MIR::Lit.new("1"), false, nil, nil)
      empty_fact.ownership_consumption = consumption_fact([])
      borrowed_fact = MIR::Let.new("borrowed", MIR::Lit.new("1"), false, nil, nil)
      borrowed_fact.ownership_consumption = consumption_fact([borrowed_operand("borrowed")])
      checker.send(:verify_ownership_consumption_operands!, [missing_fact, empty_fact, borrowed_fact])

      implicit = MIR::ReassignWithCleanup.new("dst", MIR::DupeSlice.new(MIR::Lit.new("\"x\""), :heap), "[]const u8", :heap)
      expect(checker.send(:structural_consumed_names, implicit)).to eq([])

      owned_cleanup_source = MIR::Let.new("owned_src", MIR::Ident.new("src"), false, nil, nil)
      owned_cleanup_source.ownership_consumption = consumption_fact([owned_operand("src")])
      expect(checker.send(:cleanup_source_owns_value?,
        owned_cleanup_source,
        MIR::Cleanup.new("owned_src", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })))).to be true

      nameless_cleanup_source = MIR::Let.new("nameless_src", MIR::Ident.new("src"), false, nil, nil)
      nameless_cleanup_source.ownership_consumption = consumption_fact([
        MIR::OwnershipOperandFact.owned_binding("", Type.new(:String), "spec", :heap),
      ])
      expect(checker.send(:cleanup_source_owns_value?,
        nameless_cleanup_source,
        MIR::Cleanup.new("nameless_src", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false })))).to be false

      cleanup = MIR::Cleanup.new("count", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: false }))
      checker.send(:verify_alloc_cleanup_match!,
        { "count" => [alloc_mark("count", :heap, Type.new(:Int64))] },
        { "count" => [cleanup] },
        Set.new,
        Set.new)

      errors = checker.errors.join("\n")
      expect(errors).to include("ALLOC_MARK_TYPE_MISSING")
      expect(errors).to include("COPY_CLEANUP")
      expect(errors).to include("OWNERSHIP_CONTRACT_WITHOUT_TRANSFER")
      expect(errors).to include("AGGREGATE_CHILD_ALLOC_MISMATCH")
      expect(errors).to include("OWNERSHIP_CONSUMPTION_FACT_MISSING")
      expect(errors).to include("OWNERSHIP_CONSUMPTION_OPERAND_MISSING")
      expect(errors).to include("OWNERSHIP_CONSUMPTION_BORROWED_OPERAND")
      expect(errors).to include("IMPLICIT_OWNERSHIP_TRANSFER")
    end

    it "covers linear ownership traversal edge cases" do
      state = MIRChecker::LinearOwnershipState.new
      checker.send(:check_linear_stmt!, MIR::Panic.new("stop"), state)
      expect(state.terminated).to be true

      nested_state = MIRChecker::LinearOwnershipState.new
      [
        MIR::AssertRaisesCheck.new(MIR::Lit.new("expr"), "rt", :error, "E"),
        MIR::IfChain.new([MIR::IfChainBranch.new(cond: MIR::Lit.new("cond"), body: [MIR::ExprStmt.new(MIR::Lit.new("1"), false)])], []),
        MIR::DeferStmt.new([MIR::ExprStmt.new(MIR::Lit.new("1"), false)]),
        MIR::DeferStmt.new(MIR::ExprStmt.new(MIR::Lit.new("1"), false)),
        MIR::StreamSpawn.new({}, [MIR::ExprStmt.new(MIR::Lit.new("1"), false)]),
        MIR::SnapshotRead.new(MIR::CapabilityUnwrap.new(MIR::Ident.new("cell")), "rt", "view", "__guard", [MIR::ExprStmt.new(MIR::Lit.new("1"), false)]),
        MIR::SnapshotTransaction.new(MIR::CapabilityUnwrap.new(MIR::Ident.new("cell")), "rt", :heap, "view", Type.new(:Counter), [MIR::ExprStmt.new(MIR::Lit.new("1"), false)], nil, nil, nil, false),
        MIR::SnapshotMultiTxn.new([MIR::Ident.new("a"), MIR::Ident.new("b")], "rt", "alloc", ["a"], [MIR::ExprStmt.new(MIR::Lit.new("1"), false)], nil, nil, nil),
        MIR::PolymorphicMutate.new(MIR::Ident.new("cell"), "rt", "view", Type.new(:Counter), [MIR::ExprStmt.new(MIR::Lit.new("1"), false)]),
        MIR::PolymorphicFlowSignal.new(:return_value, MIR::Lit.new("1")),
        MIR::PolymorphicMutateFlow.new(MIR::Ident.new("cell"), "rt", "view", Type.new(:Counter), Type.new(:Int64), [MIR::ExprStmt.new(MIR::Lit.new("1"), false)], MIR::Lit.new("true"), [MIR::ExprStmt.new(MIR::Lit.new("0"), false)]),
        MIR::WithMatchDispatch.new(
          MIR::Ident.new("cell"),
          "alias",
          false,
          "rt",
          [MIR::WithMatchArm.new(family: :LOCKED, guard_var: "__guard", body: [MIR::ExprStmt.new(MIR::Lit.new("1"), false)])],
        ),
        fn_def("inner", [MIR::ExprStmt.new(MIR::Lit.new("1"), false)]),
        MIR::TestDef.new("case", [MIR::ExprStmt.new(MIR::Lit.new("1"), false)]),
        MIR::StructDef.new("S", [], [fn_def("method", [MIR::ExprStmt.new(MIR::Lit.new("1"), false)])], :private),
      ].each do |stmt|
        checker.send(:check_linear_stmt!, stmt, nested_state.copy)
      end

      ctx = Object.new
      ctx.define_singleton_method(:run_body) { [MIR::ExprStmt.new(MIR::Lit.new("1"), false)] }
      checker.send(:check_linear_stmt!, MIR::FsmB1Body.new("__blk", ctx, nil), nested_state.copy)

      duplicate = checker.check_fn!(fn_def("dup_alloc", [
        alloc_mark("x", :heap),
        alloc_mark("x", :heap),
      ]))
      expect(duplicate.any? { |e| e.include?("OWNERSHIP_UNVERIFIED_PATH") && e.include?("prior ownership") }).to be true

      block_errors = checker.check_fn!(fn_def("block_transfer_wrong_expr", [
        MIR::ExprStmt.new(MIR::BlockExpr.new("__blk", [
          alloc_mark("x", :heap),
          MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
          MIR::TransferMark.new("x", :block_result),
          MIR::BreakStmt.new("__blk", MIR::Ident.new("y")),
        ]), false),
      ]))
      expect(block_errors.any? { |e| e.include?("OWNERSHIP_UNVERIFIED_PATH") && e.include?("block break expression") }).to be true

      guarded_return = checker.check_fn!(fn_def("guarded_return", [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::Cleanup.new("x", CleanupEntry.from({ kind: :uniform, alloc: :heap, has_moved_guard: true })),
        MIR::TransferMark.new("x", :return),
        MIR::ReturnStmt.new(MIR::Ident.new("x")),
      ]))
      expect(guarded_return.any? { |e| e.include?("OWNERSHIP_IMPLICIT_MOVE") && e.include?("guarded cleanup") }).to be true
    end

    it "covers branch state helpers and nested expression traversal" do
      into = MIRChecker::LinearOwnershipState.new
      terminated = MIRChecker::LinearOwnershipState.new
      terminated.terminated = true
      checker.send(:linear_merge_branch_states!, [terminated], into, "dead")
      expect(into.terminated).to be true

      left = MIRChecker::LinearOwnershipState.new
      right = MIRChecker::LinearOwnershipState.new
      right.owned.add("branch_owned")
      checker.send(:linear_merge_branch_states!, [left, right], MIRChecker::LinearOwnershipState.new, "if")

      typed_state = MIRChecker::LinearOwnershipState.new
      typed_state.owned.add("owned")
      typed_state.released.add("released")
      typed_state.alloc_kinds["owned"] = :heap
      snapshot = typed_state.snapshot
      expect(snapshot.owned).to include(MIRChecker::PlaceId.from_path("owned"))
      expect(snapshot.alloc_kinds[MIRChecker::PlaceId.from_path("owned")]).to eq(:heap)
      expect(typed_state.summary).to include("owned=owned")
      expect(typed_state.same_state?(typed_state.copy)).to be(true)

      guarded_left = MIRChecker::LinearOwnershipState.new
      guarded_right = MIRChecker::LinearOwnershipState.new
      [guarded_left, guarded_right].each { |state| state.guarded_finalizers.add("x") }
      guarded_left.released.add("x")
      checker.send(:normalize_guarded_conditional_releases!, [guarded_left, guarded_right])
      expect(guarded_left.maybe_released).to include("x")

      nested_maybe = MIRChecker::LinearOwnershipState.new
      no_release = MIRChecker::LinearOwnershipState.new
      [nested_maybe, no_release].each { |state| state.guarded_finalizers.add("x") }
      nested_maybe.maybe_released.add("x")
      checker.send(:normalize_guarded_conditional_releases!, [nested_maybe, no_release])
      expect(no_release.maybe_released).to include("x")

      expected = MIRChecker::LinearOwnershipState.new
      actual = MIRChecker::LinearOwnershipState.new
      actual.owned.add("x")
      checker.send(:linear_require_same_state!, expected, actual, "loop")

      outer = MIRChecker::LinearOwnershipState.new
      inner = MIRChecker::LinearOwnershipState.new
      inner.owned.add("local")
      inner.alloc_kinds["local"] = :heap
      checker.send(:prune_scope_locals!, outer, inner, "scope")

      released = MIRChecker::LinearOwnershipState.new
      released.released.add("moved")
      checker.send(:check_linear_expr_uses!, MIR::Pipeline.new(nil, MIR::Ident.new("moved"), nil, [], nil, nil), released)
      checker.send(:check_linear_expr_uses!, MIR::Cast.new(MIR::BlockExpr.new("__blk", []), "void", :as), released)

      errors = checker.errors.join("\n")
      expect(errors).to include("control-flow branches rejoin")
      expect(errors).to include("nested control flow changes ownership state")
      expect(errors).to include("scope-local owned binding")
      expect(errors).to include("OWNERSHIP_USE_AFTER_TRANSFER")
    end

    it "covers move-mark, aggregate, and registry traversal branches" do
      checker.send(:verify_move_mark_scope!, [MIR::MoveMark.new("x")])
      checker.send(:verify_move_mark_scope!, [
        MIR::IfChain.new([MIR::IfChainBranch.new(cond: MIR::Lit.new("cond"), body: [MIR::MoveMark.new("branch")])], [MIR::MoveMark.new("default")]),
        MIR::WithMatchDispatch.new(
          MIR::Ident.new("cell"),
          "alias",
          false,
          "rt",
          [MIR::WithMatchArm.new(family: :LOCKED, guard_var: "__guard", body: [MIR::MoveMark.new("arm")])],
        ),
      ])

      aggregate = [
        MIR::IfChain.new(
          [MIR::IfChainBranch.new(cond: MIR::Ident.new("cond"), body: [MIR::Let.new("owner", MIR::StructInit.new("S", [{ name: "field", value: MIR::Ident.new("child") }]), false, nil, nil)])],
          [MIR::ExprStmt.new(MIR::StructInit.new("S", [{ name: "field", value: MIR::Ident.new("child") }]), false)],
        ),
      ]
      checker.send(:verify_aggregate_owned_children!, aggregate, {
        "owner" => [alloc_mark("owner", :heap)],
        "child" => [alloc_mark("child", :frame)],
      })

      unregistered_stmt = Class.new(Struct.new(:expr)) do
        include MIR::Stmt
      end
      unregistered_owned = Class.new(Struct.new(:alloc)) do
        include MIR::Expr
      end
      stub_const("MIR::SpecCheckerUnregisteredStmt", unregistered_stmt)
      stub_const("MIR::SpecCheckerOwnershipFieldExpr", unregistered_owned)
      registry_errors = checker.ownership_registry_errors

      errors = checker.errors.join("\n")
      expect(errors).to include("MOVEMARK_WITHOUT_GUARD")
      expect(errors).to include("AGGREGATE_CHILD_ALLOC_MISMATCH")
      expect(registry_errors.join("\n")).to include("LINEAR_STMT_NOT_REGISTERED")
      expect(registry_errors.join("\n")).to include("OWNERSHIP_NODE_NOT_REGISTERED")
    end

    it "covers owned return, FSM guard, and boundary-fact branches" do
      sig = FunctionSignature.intrinsic_contract(return_type: Type.new(:String), allocates: true, return_alloc: :heap)
      inline = registry_call("owned", sig, allocs: MIR.inline_alloc_metadata(alloc: :heap))
      expect(checker.send(:owned_return_init?, inline)).to be true

      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.required_move_guards = ["captured"]
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-TRANSFER-GUARD-WRITTEN/)

      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.owned_result_required = true
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-OWNED-RESULT-TRANSFER/)

      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.owned_result_required = true
      structure.ownership_facts = [MIR::FsmOwnershipFact.new(name: "result", target: :result, target_alloc: :heap, move_guarded: true)]
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-OWNED-RESULT-GUARD-WRITTEN/)

      bg = bg_block
      bg.boundary_fact = boundary_fact
      stream = MIR::StreamSpawn.new({}, [])
      do_block = structural_do_block([[]])
      checker.send(:verify_execution_boundary_facts!, [bg, stream, do_block])
      checker.send(:verify_execution_boundary_fact!, boundary_fact(kind: :bad_kind, dispatch: :bad_dispatch), "bad")

      errors = checker.errors.join("\n")
      expect(errors).to include("FSM-consumed BG body")
      expect(errors).to include("MIR::StreamSpawn has no typed ExecutionBoundaryFact")
      expect(errors).to include("MIR::DoBlock has no typed ExecutionBoundaryFact array")
      expect(errors).to include("invalid boundary kind")
      expect(errors).to include("invalid boundary dispatch")
    end

    it "covers callable, ownership-surface, and allocator side-channel helpers" do
      bad_signature_contract = Class.new(MIR::CallableContract) do
        def initialize; end
        def signature = Object.new
        def ownership_contract = MIR::OwnershipContract.empty
        def checked_arg_count = 0
      end.new
      checker.send(:verify_callable_contract!, bad_signature_contract, "badSig", "MIR::Call", Set.new, {})

      bad_ownership_contract = Class.new(MIR::CallableContract) do
        def initialize; end
        def signature = FunctionSignature.new(params: [], return_type: Type.new(:Void))
        def ownership_contract = Object.new
        def checked_arg_count = 0
      end.new
      checker.send(:verify_callable_contract!, bad_ownership_contract, "badOwn", "MIR::Call", Set.new, {})

      checker.send(:verify_ownership_contract_operands!,
        MIR::OwnershipContract.new(operands: [borrowed_operand("borrowed")]),
        "contract",
        Set.new,
        require_operands: true)
      checker.send(:verify_ownership_contract_operands!,
        MIR::OwnershipContract.new(operands: [MIR::OwnershipOperandFact.owned_binding("", Type.new(:String), "spec")]),
        "contract",
        Set.new,
        require_operands: true)

      malformed_registry = Struct.new(:ownership_contract, :stdlib_def, :reason) do
        include MIR::Expr
        def child_exprs = []
      end.new(Object.new, FunctionSignature.new(
        params: [AST::Param.new(name: "value", type: Type.new(:Int64), takes: true)],
        return_type: Type.new(:Void),
        intrinsic: true,
      ), "malformed")
      checker.send(:verify_explicit_ownership_contracts!, [MIR::Lit.new("not_zig"), malformed_registry], Set.new, {})

      method = MIR::MethodCall.new(MIR::Ident.new("items"), "pop", [], false, MIR::CallableContract.no_ownership(0), :heap)
      reassign = MIR::ReassignWithCleanup.new("dst", MIR::Ident.new("owned"), "[]const u8", :heap)
      reassign.ownership_consumption = consumption_fact([owned_operand("owned")])
      checker.send(:verify_ownership_surfaces_finalized!, [method, reassign], [])

      iz = registry_call("map", FunctionSignature.borrowing_intrinsic,
        ownership_contract: MIR::OwnershipContract.consume_operands([
          MIR::OwnershipOperandFact.owned_binding("owned", Type.new(:String), "spec", :heap),
        ]),
        allocs: MIR.inline_alloc_metadata(val_alloc: :heap),
        target_var: "map")
      checker.send(:check_consumed_allocators_match_sink!, iz, ["owned"], "owned" => [alloc_mark("owned", :frame)])

      takes_signature = FunctionSignature.new(
        params: [AST::Param.new(name: "value", type: Type.new(:Int64), takes: true)],
        return_type: Type.new(:Void),
        intrinsic: true,
      )
      covered_takes = registry_call("covered_takes", takes_signature,
        ownership_contract: MIR::OwnershipContract.new(covers_consuming_params: true))
      expect(checker.send(:stdlib_takes_ownership?, covered_takes)).to be true

      walker_seen = []
      checker.send(:walk_mir, [MIR::ExprStmt.new(MIR::Ident.new("walk"), false)]) { |node| walker_seen << node.class.name }
      checker.send(:walk_mir_expr, MIR::Ident.new("expr")) { |node| walker_seen << node.class.name }
      expect(walker_seen).to include("MIR::Ident")
      expect(checker.send(:ownership_effect_label, MIR::MethodCall.new(MIR::Ident.new("items"), "append", [], false))).to eq("append")

      errors = checker.errors.join("\n")
      expect(errors).to include("callable contract does not carry a FunctionSignature")
      expect(errors).to include("callable contract has no typed ownership contract")
      expect(errors).to include("tries to consume borrowed operand")
      expect(errors).to include("ownership operand with no tracked binding")
      expect(errors).to include("ownership_contract must be MIR::OwnershipContract")
      expect(errors).to include("MIR::MethodCall carries ownership")
      expect(errors).to include("MIR::ReassignWithCleanup consumes")
      expect(errors).to include("owned transfer allocator is incoherent")
    end

    it "covers frame-allocation and unhoisted-allocation helper branches" do
      mutating_sig = FunctionSignature.intrinsic_contract(return_type: Type.new(:Void), allocates: true)
      mutating_sig.emit = IntrinsicEmit.new(allocates: true, mutates_receiver: true, alloc: :frame)
      mutating_inline = registry_call("mutating", mutating_sig,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "items")
      frame_inline = registry_call("frame", FunctionSignature.borrowing_intrinsic,
        allocs: MIR.inline_alloc_metadata(alloc: :frame), target_var: "tmp")

      expect(checker.send(:expr_has_frame_alloc?, nil)).to be false
      expect(checker.send(:expr_has_frame_alloc?, mutating_inline)).to be false
      expect(checker.send(:expr_has_frame_alloc?, frame_inline)).to be true
      expect(checker.send(:expr_has_frame_alloc?, MIR::DupeSlice.new(MIR::Lit.new("\"x\""), :frame))).to be true
      expect(checker.send(:expr_has_frame_alloc?, MIR::Ident.new("plain"))).to be false

      expect {
        checker.send(:error, :SPEC_NOT_REGISTERED, "x", "bad")
      }.to raise_error(/unregistered MIR diagnostic code/)

      if_bind = MIR::IfBindStmt.new(
        [{ expr: MIR::DupeSlice.new(MIR::Lit.new("\"x\""), :heap), capture: "cap" }],
        [MIR::Cleanup.new("cap", CleanupEntry.from({ kind: :heap_string, alloc: :heap, has_moved_guard: false }))],
        [],
      )
      checker.send(:check_stmt_for_unhoisted, if_bind)
      expect(checker.errors.none? { |e| e.include?("UNHOISTED_ALLOC") }).to be true

      block_expr = MIR::BlockExpr.new("__blk", [MIR::TransferMark.new("x", :block_result)])
      expect(checker.send(:block_expr_transfers_result?, block_expr)).to be true
      checker.send(:check_expr_sources_for_unhoisted, Object.new, "expression", owned_position: false)
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
    def mir_ref(text)
      return nil if text.nil?

      head, tail = text.split(".", 2)
      tail ? MIR::FieldGet.new(MIR::Ident.new(head), tail) : MIR::Ident.new(text)
    end

    def fsm_cleanup_action(name, source_kind: :body, entry: nil, target: nil, guard: nil, allocator: nil)
      cleanup_entry = entry || CleanupEntry.build(:uniform, alloc: :heap, has_moved_guard: false)
      MIR::FsmDestroyCleanup.new(
        source_kind: source_kind,
        name: name,
        target: mir_ref(target || "__ctx_0.#{name}"),
        cleanup_entry: cleanup_entry,
        guard: mir_ref(guard),
        allocator: mir_ref(allocator),
      )
    end

    def fsm_destroy_stmt(name, source_kind: :body, target: "__ctx_0")
      MIR::FsmDestroyStmt.new(
        source_kind: source_kind,
        name: name,
        stmt: MIR::RcRelease.new(
          MIR::FieldGet.new(MIR::Ident.new(target), name),
          "Payload",
          "arcRelease",
          MIR::Ident.new("allocator"),
        ),
      )
    end

    def fsm_capture_fact(name, cleanup_at: :finalize)
      MIR::FsmCaptureFact.new(name: name, cleanup_at: cleanup_at)
    end

    def fsm_state_field_fact(name, finalize_at: :finalize, error_handled_in_setup: false)
      MIR::FsmStateFieldFact.new(
        name: name,
        finalize_at: finalize_at,
        error_handled_in_setup: error_handled_in_setup,
      )
    end

    def fsm_step_fact(index, reads: [], cleanups: [])
      MIR::FsmStepFact.new(index: index, reads: reads, cleanups: cleanups)
    end

    it "rejects capture cleanup placed in a step (not finalize)" do
      structure = MIR::FsmStructure.new(
        [fsm_capture_fact("needle", cleanup_at: 0)],
        [],
        [
          fsm_step_fact(0, reads: ["needle"], cleanups: ["needle"]),
          fsm_step_fact(1, reads: ["needle"]),
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
        [fsm_capture_fact("needle")],
        [],
        [fsm_step_fact(0)],
        [],
        0,
        nil,
      )
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-CAPTURE-CLEANUP-PRESENT/)
    end

    it "rejects finalize cleanup names without structural destroy actions" do
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-FINALIZE-ACTION-PRESENT/)
    end

    it "rejects finalization actions when ctx_id is missing" do
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        nil,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp")]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-CTX-ID/)
    end

    it "rejects destroy cleanup actions targeting the wrong ctx field" do
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp", target: "__ctx_0.other")]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-TARGET/)
    end

    it "rejects destroy cleanup actions with unknown sources" do
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp", source_kind: :mystery)]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-SOURCE/)
    end

    it "rejects destroy cleanup actions absent from finalize_cleanups" do
      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.destroy_actions = [fsm_cleanup_action("tmp")]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-FINALIZE-LIST/)
    end

    it "rejects destroy statement actions with unknown sources" do
      structure = MIR::FsmStructure.new([], [], [], ["tmp"], 0, nil)
      structure.destroy_actions = [fsm_destroy_stmt("tmp", source_kind: :mystery)]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-SOURCE/)
    end

    it "rejects destroy statement actions targeting the wrong ctx field" do
      structure = MIR::FsmStructure.new([], [], [], ["tmp"], 0, nil)
      structure.destroy_actions = [fsm_destroy_stmt("tmp", target: "__ctx_1")]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-TARGET/)
    end

    it "rejects destroy statement actions absent from finalize_cleanups" do
      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.destroy_actions = [fsm_destroy_stmt("tmp")]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-FINALIZE-LIST/)
    end

    it "returns no ctx target name for non-structural destroy statements" do
      non_release = MIR::FsmDestroyStmt.new(
        source_kind: :body,
        name: "tmp",
        stmt: MIR::Comment.new("not a release"),
      )
      release_without_field = MIR::FsmDestroyStmt.new(
        source_kind: :body,
        name: "tmp",
        stmt: MIR::RcRelease.new(MIR::Ident.new("tmp"), "Payload", "arcRelease", MIR::Ident.new("allocator")),
      )
      release_without_ctx_ident = MIR::FsmDestroyStmt.new(
        source_kind: :body,
        name: "tmp",
        stmt: MIR::RcRelease.new(
          MIR::FieldGet.new(MIR::FieldGet.new(MIR::Ident.new("__ctx_0"), "inner"), "tmp"),
          "Payload",
          "arcRelease",
          MIR::Ident.new("allocator"),
        ),
      )

      expect(non_release.ctx_cleanup_target_name).to be_nil
      expect(release_without_field.ctx_cleanup_target_name).to be_nil
      expect(release_without_ctx_ident.ctx_cleanup_target_name).to be_nil
    end

    it "rejects destroy cleanup actions with no-cleanup entries" do
      entry = CleanupEntry.no_cleanup(alloc: :heap, scope: :heap)
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp", entry: entry)]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-CLEANUP-ENTRY/)
    end

    it "rejects destroy cleanup actions with invalid allocators" do
      entry = CleanupEntry.from(
        kind: :uniform,
        alloc: :arena,
        scope: :heap,
        needs_cleanup: true,
        has_moved_guard: false,
      )
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp", entry: entry)]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-ALLOC/)
    end

    it "rejects resource destroy actions without a close plan" do
      entry = CleanupEntry.build(
        :resource,
        alloc: :heap,
        has_moved_guard: false,
      )
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp", entry: entry)]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-RESOURCE-PLAN/)
    end

    it "rejects resource destroy actions with an empty close plan" do
      entry = CleanupEntry.build(
        :resource,
        alloc: :heap,
        has_moved_guard: false,
        resource_close_plan: Schemas::ResourceClosePlan.composite([]),
      )
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp", entry: entry)]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-RESOURCE-PLAN/)
    end

    it "rejects malformed guard and allocator expression fields" do
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp")],
        [fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"])],
        ["tmp"],
        0,
        nil,
      )
      structure.destroy_actions = [fsm_cleanup_action("tmp", guard: "__ctx_0.bad;")]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-ZIG-FIELD/)
    end

    it "rejects malformed FSM lock destroy guard indices" do
      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.destroy_actions = [
        MIR::FsmDestroyLockRelease.new(
          name: "__ctx_0.lock",
          ctx_id: 0,
          guard_index: -1,
          lock_ref: mir_ref("__ctx_0.lock"),
          unlock_method: "unlock",
        ),
      ]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-LOCK-GUARD/)
    end

    it "derives lock destroy guard fields from typed guard indices" do
      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      action = MIR::FsmDestroyLockRelease.new(
        name: "__ctx_0.lock",
        ctx_id: 0,
        guard_index: 12,
        lock_ref: mir_ref("__ctx_0.lock"),
        unlock_method: "unlock",
      )
      structure.destroy_actions = [action]

      expect(action.guard_field).to eq("__lock_held_12")
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.not_to raise_error
    end

    it "rejects lock destroy actions outside the FSM ctx" do
      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.destroy_actions = [
        MIR::FsmDestroyLockRelease.new(
          name: "__ctx_1.lock",
          ctx_id: 1,
          guard_index: 0,
          lock_ref: mir_ref("__ctx_1.lock"),
          unlock_method: "unlock",
        ),
      ]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-LOCK-TARGET/)
    end

    it "rejects unknown FSM lock unlock methods" do
      structure = MIR::FsmStructure.new([], [], [], [], 0, nil)
      structure.destroy_actions = [
        MIR::FsmDestroyLockRelease.new(
          name: "__ctx_0.lock",
          ctx_id: 0,
          guard_index: 0,
          lock_ref: mir_ref("__ctx_0.lock"),
          unlock_method: "release",
        ),
      ]

      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-DESTROY-LOCK-METHOD/)
    end

    it "rejects step N reading a name whose cleanup is in step M < N" do
      structure = MIR::FsmStructure.new(
        [],
        [fsm_state_field_fact("tmp", finalize_at: nil)],
        [
          fsm_step_fact(0, reads: ["tmp"], cleanups: ["tmp"]),
          fsm_step_fact(1, reads: ["tmp"]),
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
        [fsm_state_field_fact("rf_buf")],
        [fsm_step_fact(1, reads: ["rf_buf"], cleanups: ["rf_buf"])],
        ["rf_buf"],
        0,
        "rf_buf",  # aliasing detected by lowering
      )
      structure.destroy_actions = [fsm_cleanup_action("rf_buf")]
      expect {
        MIRChecker.check_fsm_structure!(structure)
      }.to raise_error(MIRChecker::FsmStructureError, /INV-FSM-RESULT-NO-FINALIZED-ALIAS/)
    end

    it "passes a well-formed FSM structure" do
      structure = MIR::FsmStructure.new(
        [fsm_capture_fact("needle")],
        [fsm_state_field_fact("rf_buf")],
        [
          fsm_step_fact(0, reads: ["needle"]),
          fsm_step_fact(1, reads: ["needle", "rf_buf"], cleanups: ["needle", "rf_buf"]),
        ],
        ["needle", "rf_buf"],
        0,
        nil,
      )
      structure.destroy_actions = [
        fsm_cleanup_action("needle", source_kind: :capture),
        fsm_cleanup_action("rf_buf", allocator: "__ctx_0.alloc"),
        MIR::FsmDestroyLockRelease.new(
          name: "__ctx_0.lock",
          ctx_id: 0,
          guard_index: 0,
          lock_ref: mir_ref("__ctx_0.lock"),
          unlock_method: "unlockShared",
        ),
      ]
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
