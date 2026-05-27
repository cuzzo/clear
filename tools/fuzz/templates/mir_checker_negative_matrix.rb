# Template: malformed MIR that the checker must reject.
#
# Source-language fuzz should not be able to produce most of these shapes:
# they are exactly the invalid MIR states the compiler must never emit. This
# template therefore generates small Ruby programs that construct MIR directly,
# run MIRChecker, and fail if the expected hard error is absent.

MIR_CHECKER_NEGATIVE_CELLS = [
  { case_name: :double_transfer, error_code: :OWNERSHIP_DOUBLE_RELEASE },
  { case_name: :cleanup_then_transfer, error_code: :OWNERSHIP_DOUBLE_RELEASE },
  { case_name: :double_finalizer, error_code: :OWNERSHIP_DOUBLE_FINALIZER },
  { case_name: :implicit_move, error_code: :OWNERSHIP_IMPLICIT_MOVE },
  { case_name: :return_without_move_mark, error_code: :OWNERSHIP_IMPLICIT_MOVE },
  { case_name: :use_after_transfer, error_code: :OWNERSHIP_USE_AFTER_TRANSFER },
  { case_name: :branch_owner_split, error_code: :OWNERSHIP_UNVERIFIED_PATH },
  { case_name: :return_transfer_no_return, error_code: :OWNERSHIP_UNVERIFIED_PATH },
  { case_name: :return_transfer_wrong_expr, error_code: :OWNERSHIP_UNVERIFIED_PATH },
  { case_name: :frame_owned_sink_escape, error_code: :FRAME_ALLOC_ESCAPES },
  { case_name: :owned_sink_without_target_alloc, error_code: :IMPLICIT_OWNERSHIP_TRANSFER },
  { case_name: :aggregate_child_alloc_mismatch_struct, error_code: :AGGREGATE_CHILD_ALLOC_MISMATCH },
  { case_name: :aggregate_child_alloc_mismatch_array, error_code: :AGGREGATE_CHILD_ALLOC_MISMATCH },
  { case_name: :aggregate_child_alloc_mismatch_call_contract, error_code: :AGGREGATE_CHILD_ALLOC_MISMATCH },
  { case_name: :owned_return_alloc_not_heap, error_code: :OWNED_RETURN_ALLOC_NOT_HEAP },
  { case_name: :return_transfer_frame_alloc, error_code: :RETURN_TRANSFER_FRAME_ALLOC },
  { case_name: :mir_call_no_contract, error_code: :MIR_CALL_NO_CONTRACT },
  { case_name: :method_call_no_contract, error_code: :MIR_CALL_NO_CONTRACT },
  { case_name: :takes_contract_without_consumed_names, error_code: :IMPLICIT_OWNERSHIP_TRANSFER },
  { case_name: :inline_alloc_mismatch_primary, error_code: :INLINE_ALLOC_MISMATCH },
  { case_name: :inline_alloc_mismatch_value, error_code: :INLINE_ALLOC_MISMATCH },
  { case_name: :inline_alloc_without_allocmark, error_code: :INLINE_ALLOC_WITHOUT_ALLOCMARK },
  { case_name: :inline_alloc_without_target, error_code: :INLINE_ALLOC_WITHOUT_TARGET },
  { case_name: :inline_no_contract, error_code: :INLINE_NO_CONTRACT },
  { case_name: :copy_cleanup_primitive, error_code: :COPY_CLEANUP },
  { case_name: :indirect_double_box, error_code: :INDIRECT_DOUBLE_BOX },
  { case_name: :transfer_without_alloc, error_code: :TRANSFER_WITHOUT_ALLOC },
  { case_name: :cleanup_without_alloc, error_code: :CLEANUP_WITHOUT_ALLOC },
  { case_name: :alloc_without_cleanup, error_code: :ALLOC_WITHOUT_CLEANUP },
  { case_name: :errcleanup_without_transfer, error_code: :ERRCLEANUP_WITHOUT_TRANSFER },
  { case_name: :alloc_cleanup_mismatch, error_code: :ALLOC_CLEANUP_MISMATCH },
  { case_name: :invalid_allocmark_allocator, error_code: :INVALID_ALLOCATOR_MARK },
  { case_name: :invalid_allocmark_scope, error_code: :INVALID_ALLOCATOR_MARK },
  { case_name: :invalid_cleanup_allocator, error_code: :INVALID_ALLOCATOR_MARK },
  { case_name: :invalid_inline_allocator, error_code: :INVALID_ALLOCATOR_MARK },
  { case_name: :allocating_let_without_alloc, error_code: :ALLOCATING_LET_WITHOUT_ALLOC },
  { case_name: :cleanup_for_borrow_field, error_code: :OWNERSHIP_CLEANUP_FOR_BORROW },
  { case_name: :cleanup_for_borrow_index, error_code: :OWNERSHIP_CLEANUP_FOR_BORROW },
  { case_name: :raw_zig_no_contract, error_code: :RAW_NO_CONTRACT },
  { case_name: :frame_field_store_escape, error_code: :FRAME_ALLOC_ESCAPES },
  { case_name: :frame_capture_escape, error_code: :FRAME_ALLOC_ESCAPES },
  { case_name: :frame_aggregate_escape, error_code: :FRAME_ALLOC_ESCAPES },
  { case_name: :unhoisted_return_concat, error_code: :UNHOISTED_ALLOC },
  { case_name: :unhoisted_exprstmt_deepcopy, error_code: :UNHOISTED_ALLOC },
  { case_name: :unhoisted_call_arg_makelist, error_code: :UNHOISTED_ALLOC },
].map { |cell| cell.merge(expected: :compile_error) }.freeze

def mir_checker_negative_case(case_name)
  case case_name
  when :double_transfer
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::TransferMark.new("x", :owned_sink, :heap),
        MIR::TransferMark.new("x", :return),
        MIR::ReturnStmt.new(MIR::Ident.new("x")),
      ]
    RUBY
  when :cleanup_then_transfer
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::Lit.new("owned"), false, nil, nil),
        MIR::Cleanup.new("x", cleanup(:heap, false)),
        MIR::TransferMark.new("x", :owned_sink, :heap),
      ]
    RUBY
  when :double_finalizer
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Cleanup.new("x", cleanup(:heap, true)),
        MIR::ErrCleanup.new("x", cleanup(:heap, true)),
      ]
    RUBY
  when :implicit_move
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Cleanup.new("x", cleanup(:heap, true)),
        MIR::MoveMark.new("x"),
      ]
    RUBY
  when :return_without_move_mark
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Cleanup.new("x", cleanup(:heap, true)),
        MIR::TransferMark.new("x", :return),
        MIR::ReturnStmt.new(MIR::Ident.new("x")),
      ]
    RUBY
  when :use_after_transfer
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::TransferMark.new("x", :owned_sink, :heap),
        MIR::ExprStmt.new(MIR::Ident.new("x"), false),
      ]
    RUBY
  when :branch_owner_split
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::IfStmt.new(MIR::Lit.new("cond"), [MIR::TransferMark.new("x", :owned_sink, :heap)], []),
      ]
    RUBY
  when :return_transfer_no_return
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::TransferMark.new("x", :return),
      ]
    RUBY
  when :return_transfer_wrong_expr
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::TransferMark.new("x", :return),
        MIR::ReturnStmt.new(MIR::Ident.new("y")),
      ]
    RUBY
  when :frame_owned_sink_escape
    <<~RUBY
      [
        alloc_mark("x", :frame),
        MIR::TransferMark.new("x", :owned_sink, :heap),
      ]
    RUBY
  when :owned_sink_without_target_alloc
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::TransferMark.new("x", :owned_sink),
      ]
    RUBY
  when :aggregate_child_alloc_mismatch_struct
    <<~RUBY
      [
        alloc_mark("child", :frame),
        alloc_mark("parent", :heap),
        MIR::Let.new("parent", MIR::StructInit.new("Parent", [{ name: "child", value: MIR::Ident.new("child") }]), false, nil, nil),
        MIR::Cleanup.new("parent", cleanup(:heap, false)),
      ]
    RUBY
  when :aggregate_child_alloc_mismatch_array
    <<~RUBY
      [
        alloc_mark("child", :frame),
        alloc_mark("items", :heap),
        MIR::Let.new("items", MIR::ArrayInit.new("Child", 1, [MIR::Ident.new("child")]), false, nil, nil),
        MIR::Cleanup.new("items", cleanup(:heap, false)),
      ]
    RUBY
  when :aggregate_child_alloc_mismatch_call_contract
    <<~RUBY
      contract = MIR::OwnershipContract.consumes(["child"])
      iz = inline_zig("try target.append(alloc, value)", :frame, "items")
      iz.allocs = { alloc: :frame, val_alloc: :frame }
      iz.ownership_contract = contract
      [
        alloc_mark("child", :heap),
        MIR::TransferMark.new("child", :owned_sink, :frame),
        alloc_mark("items", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
    RUBY
  when :owned_return_alloc_not_heap
    <<~RUBY
      [
        alloc_mark("x", :frame),
        MIR::Let.new("x", MIR::Call.new("make", [], false, true, MIR::CallableContract.no_ownership(0)), false, nil, nil),
      ]
    RUBY
  when :return_transfer_frame_alloc
    <<~RUBY
      [
        alloc_mark("x", :frame),
        MIR::TransferMark.new("x", :return),
        MIR::ReturnStmt.new(MIR::Ident.new("x")),
      ]
    RUBY
  when :mir_call_no_contract
    <<~RUBY
      [
        MIR::ExprStmt.new(MIR::Call.new("callee", [MIR::Ident.new("x")], false), false),
      ]
    RUBY
  when :method_call_no_contract
    <<~RUBY
      [
        MIR::ExprStmt.new(MIR::MethodCall.new(MIR::Ident.new("items"), "append", [MIR::Ident.new("x")], true), false),
      ]
    RUBY
  when :takes_contract_without_consumed_names
    <<~RUBY
      param = AST::Param.new(name: "x", type: Type.new(:String), takes: true)
      sig = FunctionSignature.new(params: [param], return_type: Type.new(:Void))
      contract = MIR::CallableContract.new(sig, MIR::OwnershipContract.empty, 1)
      [
        MIR::ExprStmt.new(MIR::Call.new("takeIt", [MIR::Ident.new("x")], false, false, contract), false),
      ]
    RUBY
  when :inline_alloc_mismatch_primary
    <<~RUBY
      iz = inline_zig("try target.append(alloc, value)", :heap, "items")
      [
        alloc_mark("items", :frame),
        MIR::ExprStmt.new(iz, false),
      ]
    RUBY
  when :inline_alloc_mismatch_value
    <<~RUBY
      iz = inline_zig("try target.put(key_alloc, val_alloc, key, value)", nil, "map")
      iz.allocs = { key_alloc: :heap, val_alloc: :frame }
      [
        alloc_mark("map", :heap),
        MIR::ExprStmt.new(iz, false),
      ]
    RUBY
  when :inline_alloc_without_allocmark
    <<~RUBY
      iz = inline_zig("try target.append(alloc, value)", :heap, "external_list")
      [
        MIR::ExprStmt.new(iz, false),
      ]
    RUBY
  when :inline_alloc_without_target
    <<~RUBY
      iz = inline_zig("try target.append(alloc, value)", :heap, nil)
      [
        MIR::ExprStmt.new(iz, false),
      ]
    RUBY
  when :inline_no_contract
    <<~RUBY
      [
        MIR::ExprStmt.new(MIR::InlineZig.new("CheatLib.intAdd(a, b)", "math"), false),
      ]
    RUBY
  when :copy_cleanup_primitive
    <<~RUBY
      [
        alloc_mark("n", :heap, Type.new(:Int64)),
        MIR::Cleanup.new("n", cleanup(:heap, false)),
      ]
    RUBY
  when :indirect_double_box
    <<~RUBY
      [
        alloc_mark("t", :heap),
        MIR::Let.new("t", MIR::HeapCreate.new("*Val", MIR::Ident.new("v"), :heap, "blk"), false, nil, nil),
        MIR::Cleanup.new("t", cleanup(:heap, false)),
      ]
    RUBY
  when :transfer_without_alloc
    <<~RUBY
      [
        MIR::TransferMark.new("x", :owned_sink, :heap),
      ]
    RUBY
  when :cleanup_without_alloc
    <<~RUBY
      [
        MIR::Cleanup.new("x", cleanup(:heap, false)),
      ]
    RUBY
  when :alloc_without_cleanup
    <<~RUBY
      [
        alloc_mark("x", :heap),
      ]
    RUBY
  when :errcleanup_without_transfer
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::ErrCleanup.new("x", cleanup(:heap, false)),
      ]
    RUBY
  when :alloc_cleanup_mismatch
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Cleanup.new("x", cleanup(:frame, false)),
      ]
    RUBY
  when :invalid_allocmark_allocator
    <<~RUBY
      [
        alloc_mark("x", :stack),
        MIR::Cleanup.new("x", cleanup(:heap, false)),
      ]
    RUBY
  when :invalid_allocmark_scope
    <<~RUBY
      [
        MIR::AllocMark.new("x", :heap, Type.new(:String), :block),
        MIR::Cleanup.new("x", cleanup(:heap, false)),
      ]
    RUBY
  when :invalid_cleanup_allocator
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Cleanup.new("x", cleanup(:stack, false)),
      ]
    RUBY
  when :invalid_inline_allocator
    <<~RUBY
      iz = inline_zig("try target.append(alloc, value)", :stack, "items")
      [
        alloc_mark("items", :heap),
        MIR::ExprStmt.new(iz, false),
      ]
    RUBY
  when :allocating_let_without_alloc
    <<~RUBY
      [
        MIR::Let.new("x", MIR::DupeSlice.new(MIR::Lit.new("\\"abc\\""), :heap), false, nil, nil),
      ]
    RUBY
  when :cleanup_for_borrow_field
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::FieldGet.new(MIR::Ident.new("owner"), "field"), false, nil, nil),
        MIR::Cleanup.new("x", cleanup(:heap, false)),
      ]
    RUBY
  when :cleanup_for_borrow_index
    <<~RUBY
      [
        alloc_mark("x", :heap),
        MIR::Let.new("x", MIR::IndexGet.new(MIR::Ident.new("owner"), MIR::Lit.new("0")), false, nil, nil),
        MIR::Cleanup.new("x", cleanup(:heap, false)),
      ]
    RUBY
  when :raw_zig_no_contract
    <<~RUBY
      [
        MIR::ExprStmt.new(MIR::RawZig.new("CheatLib.dupeValue(T, x, alloc)", "opaque_ownership", MIR::OwnershipContract.empty, nil), false),
      ]
    RUBY
  when :frame_field_store_escape
    <<~RUBY
      [
        alloc_mark("x", :frame),
        MIR::TransferMark.new("x", :field_store, :heap),
      ]
    RUBY
  when :frame_capture_escape
    <<~RUBY
      [
        alloc_mark("x", :frame),
        MIR::TransferMark.new("x", :capture, :heap),
      ]
    RUBY
  when :frame_aggregate_escape
    <<~RUBY
      [
        alloc_mark("x", :frame),
        MIR::TransferMark.new("x", :aggregate_store, :heap),
      ]
    RUBY
  when :unhoisted_return_concat
    <<~RUBY
      [
        MIR::ReturnStmt.new(MIR::ConcatStr.new([MIR::Lit.new("\\"a\\""), MIR::Lit.new("\\"b\\"")], :heap, nil)),
      ]
    RUBY
  when :unhoisted_exprstmt_deepcopy
    <<~RUBY
      [
        MIR::ExprStmt.new(MIR::DeepCopy.new(MIR::Ident.new("x"), "[]const u8", nil, :string, :heap), false),
      ]
    RUBY
  when :unhoisted_call_arg_makelist
    <<~RUBY
      [
        MIR::ExprStmt.new(MIR::Call.new("use", [MIR::MakeList.new("i64", [MIR::Lit.new("1")], :heap)], false, false, MIR::CallableContract.no_ownership(1)), false),
      ]
    RUBY
  end
end

def mir_checker_negative_source(case_name, error_code)
  body_src = mir_checker_negative_case(case_name)
  <<~RUBY
    require 'bundler/setup'
    require File.expand_path('spec/coverage_bootstrap', Dir.pwd) if ENV['COVERAGE'] == '1'
    require File.expand_path('src/ast/ast', Dir.pwd)
    require File.expand_path('src/mir/mir', Dir.pwd)
    require File.expand_path('src/mir/cleanup_entry', Dir.pwd)
    require File.expand_path('src/mir/mir_checker', Dir.pwd)

    def fn_def(name, body)
      MIR::FnDef.new(name, [], "void", body, :pub, false, nil)
    end

    def alloc_mark(name, alloc, type_info = Type.new(:String))
      MIR::AllocMark.new(name, alloc, type_info, alloc == :heap ? :heap : :function)
    end

    def cleanup(alloc, moved_guard)
      CleanupEntry.from({ kind: :uniform, alloc: alloc, has_moved_guard: moved_guard })
    end

    def inline_zig(code, alloc, target)
      iz = MIR::InlineZig.new(code, "inline_contract")
      iz.allocs = alloc ? { alloc: alloc } : {}
      iz.target_var = target
      iz.stdlib_def = FunctionSignature.new(params: [], return_type: Type.new(:Void), intrinsic: true)
      iz
    end

    body = begin
      #{body_src.rstrip.gsub("\n", "\n  ")}
    end

    errors = MIRChecker.new.check_fn!(fn_def("#{case_name}", body), strict: true)
    expected = "#{error_code}"
    if errors.any? { |error| error.include?(expected) }
      exit 0
    end

    warn "expected MIRChecker to reject #{case_name} with \#{expected}"
    warn "actual errors:"
    errors.each { |error| warn "  - \#{error}" }
    exit 1
  RUBY
end

FuzzGenerator.register(:mir_checker_negative_matrix, cells: MIR_CHECKER_NEGATIVE_CELLS) do |p|
  {
    kind: :mir_checker,
    source: mir_checker_negative_source(p[:case_name], p[:error_code]),
    error_code: p[:error_code],
  }
end
