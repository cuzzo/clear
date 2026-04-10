require 'bundler/setup'
require_relative '../src/mir'
require_relative '../src/mir_checker'

RSpec.describe MIRChecker do
  let(:checker) { MIRChecker.new }

  def fn_def(name, body)
    MIR::FnDef.new(name, [], "void", body, :pub, false, nil)
  end

  describe "#check_fn!" do
    it "passes for matching AllocMark + Cleanup" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
      ]
      errors = checker.check_fn!(fn_def("ok", body))
      expect(errors).to be_empty
    end

    it "detects LEAK: AllocMark without Cleanup" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
      ]
      errors = checker.check_fn!(fn_def("leak", body))
      expect(errors.any? { |e| e.include?("LEAK") && e.include?("x") }).to be true
    end

    it "detects ORPHAN: Cleanup without AllocMark" do
      body = [
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
      ]
      errors = checker.check_fn!(fn_def("orphan", body))
      expect(errors.any? { |e| e.include?("ORPHAN") && e.include?("x") }).to be true
    end

    it "detects ALLOC_MISMATCH" do
      body = [
        MIR::AllocMark.new("x", :list, :frame),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
      ]
      errors = checker.check_fn!(fn_def("mismatch", body))
      expect(errors.any? { |e| e.include?("ALLOC_MISMATCH") }).to be true
    end

    it "detects ESCAPE: return escape without guarded Cleanup" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
        MIR::ReturnMark.new(["x"]),
      ]
      errors = checker.check_fn!(fn_def("escape", body))
      expect(errors.any? { |e| e.include?("ESCAPE") }).to be true
    end

    it "passes for return escape with guarded Cleanup + MoveMark" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: true }),
        MIR::ReturnMark.new(["x"]),
        MIR::MoveMark.new("x"),
      ]
      errors = checker.check_fn!(fn_def("ok_escape", body))
      expect(errors).to be_empty
    end

    it "detects FRAME_ESCAPE: frame alloc escapes without promote" do
      body = [
        MIR::AllocMark.new("x", :list, :frame),
        MIR::Cleanup.new("x", { kind: :list, alloc: :frame, has_moved_guard: true }),
        MIR::ReturnMark.new(["x"]),
        MIR::MoveMark.new("x"),
      ]
      errors = checker.check_fn!(fn_def("frame_escape", body))
      expect(errors.any? { |e| e.include?("FRAME_ESCAPE") }).to be true
    end

    it "passes for frame alloc with EscapePromote" do
      body = [
        MIR::AllocMark.new("x", :list, :frame),
        MIR::Cleanup.new("x", { kind: :list, alloc: :frame, has_moved_guard: true }),
        MIR::EscapePromote.new("x", "ArrayList(u8)", :list, nil, nil),
        MIR::ReturnMark.new(["x"]),
        MIR::MoveMark.new("x"),
      ]
      errors = checker.check_fn!(fn_def("ok_promote", body))
      expect(errors).to be_empty
    end

    it "exempts TAKES params from GUARD_NO_SUPPRESS" do
      body = [
        MIR::AllocMark.new("v", :takes_union, :heap),
        MIR::Cleanup.new("v", { kind: :takes_union, alloc: :heap, has_moved_guard: true }),
      ]
      errors = checker.check_fn!(fn_def("takes", body))
      expect(errors).to be_empty
    end

    it "exempts MATCH AS bindings from GUARD_NO_SUPPRESS" do
      body = [
        MIR::AllocMark.new("s", :match_as_slice, :heap),
        MIR::Cleanup.new("s", { kind: :match_as_slice, alloc: :heap, has_moved_guard: true }),
      ]
      errors = checker.check_fn!(fn_def("match_as", body))
      expect(errors).to be_empty
    end

    it "detects GUARD_NO_SUPPRESS for non-exempt kinds" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: true }),
      ]
      errors = checker.check_fn!(fn_def("no_suppress", body))
      expect(errors.any? { |e| e.include?("GUARD_NO_SUPPRESS") }).to be true
    end

    it "walks into nested control flow" do
      inner_body = [
        MIR::AllocMark.new("y", :string_map, :heap),
        # No Cleanup for y -- should be caught
      ]
      body = [
        MIR::IfStmt.new(MIR::Lit.new("true"), inner_body, nil),
      ]
      errors = checker.check_fn!(fn_def("nested", body))
      expect(errors.any? { |e| e.include?("LEAK") && e.include?("y") }).to be true
    end

    it "verifies RawZig ownership contracts" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
        MIR::RawZig.new("raw code", "test", { consumes: ["x"], produces: [] }),
      ]
      errors = checker.check_fn!(fn_def("contract", body))
      # consumes x but no MoveMark
      expect(errors.any? { |e| e.include?("RAW_CONTRACT") }).to be true
    end

    it "detects ALLOC_MISMATCH when EscapePromote + frame cleanup without guard" do
      body = [
        MIR::AllocMark.new("x", :list, :frame),
        MIR::Cleanup.new("x", { kind: :list, alloc: :frame, has_moved_guard: false }),
        MIR::EscapePromote.new("x", "ArrayList(u8)", :list, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("promote_mismatch", body))
      expect(errors.any? { |e| e.include?("ALLOC_MISMATCH") }).to be true
    end

    it "passes for EscapePromote + frame cleanup with moved guard" do
      body = [
        MIR::AllocMark.new("x", :list, :frame),
        MIR::Cleanup.new("x", { kind: :list, alloc: :frame, has_moved_guard: true }),
        MIR::EscapePromote.new("x", "ArrayList(u8)", :list, nil, nil),
        MIR::ReturnMark.new(["x"]),
        MIR::MoveMark.new("x"),
      ]
      errors = checker.check_fn!(fn_def("promote_ok", body))
      expect(errors).to be_empty
    end

    it "detects REASSIGN_LEAK for Set without ReassignMark" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
        MIR::Set.new(MIR::Ident.new("x"), MIR::Lit.new("new_value")),
      ]
      errors = checker.check_fn!(fn_def("reassign_leak", body))
      expect(errors.any? { |e| e.include?("REASSIGN_LEAK") }).to be true
    end

    it "passes for Set with ReassignMark" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
        MIR::ReassignMark.new("x", :heap),
        MIR::Set.new(MIR::Ident.new("x"), MIR::Lit.new("new_value")),
      ]
      errors = checker.check_fn!(fn_def("reassign_ok", body))
      expect(errors).to be_empty
    end

    it "detects FRAME_OVERFLOW for loop with frame alloc and no mark_per_iter" do
      loop_body = [
        MIR::AllocMark.new("tmp", :string, :frame),
        MIR::Cleanup.new("tmp", { kind: :string, alloc: :frame, has_moved_guard: false }),
      ]
      body = [
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("frame_overflow", body))
      expect(errors.any? { |e| e.include?("FRAME_OVERFLOW") }).to be true
    end

    it "passes for loop with frame alloc and mark_per_iter" do
      loop_body = [
        MIR::AllocMark.new("tmp", :string, :frame),
        MIR::Cleanup.new("tmp", { kind: :string, alloc: :frame, has_moved_guard: false }),
      ]
      body = [
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, true),
      ]
      errors = checker.check_fn!(fn_def("frame_ok", body))
      expect(errors.select { |e| e.include?("FRAME_OVERFLOW") }).to be_empty
    end

    it "passes for loop with heap alloc and no mark_per_iter" do
      loop_body = [
        MIR::AllocMark.new("tmp", :list, :heap),
        MIR::Cleanup.new("tmp", { kind: :list, alloc: :heap, has_moved_guard: false }),
      ]
      body = [
        MIR::WhileStmt.new(MIR::Lit.new("true"), loop_body, nil, nil, nil),
      ]
      errors = checker.check_fn!(fn_def("heap_loop", body))
      expect(errors.select { |e| e.include?("FRAME_OVERFLOW") }).to be_empty
    end

    it "detects BG_ESCAPE for BgBlock capture needing promotion" do
      body = [
        MIR::AllocMark.new("s", :string, :frame),
        MIR::Cleanup.new("s", { kind: :string, alloc: :frame, has_moved_guard: false }),
        MIR::BgBlock.new("raw zig", { "s" => :String }),
      ]
      errors = checker.check_fn!(fn_def("bg_escape", body))
      expect(errors.any? { |e| e.include?("BG_ESCAPE") }).to be true
    end

    it "passes for BgBlock capture with EscapePromote" do
      body = [
        MIR::AllocMark.new("s", :string, :frame),
        MIR::EscapePromote.new("s", "[]const u8", :string, nil, nil),
        MIR::Cleanup.new("s", { kind: :string, alloc: :frame, has_moved_guard: true }),
        MIR::BgBlock.new("raw zig", { "s" => :String }),
        MIR::ReturnMark.new(["s"]),
        MIR::MoveMark.new("s"),
      ]
      errors = checker.check_fn!(fn_def("bg_ok", body))
      expect(errors.select { |e| e.include?("BG_ESCAPE") }).to be_empty
    end

    it "detects ALLOC_MISMATCH from CatchWrapper error reassign" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
        MIR::CatchWrapper.new("raw zig", [{ name: "x", alloc: :frame, line: 5 }]),
      ]
      errors = checker.check_fn!(fn_def("catch_mismatch", body))
      expect(errors.any? { |e| e.include?("ALLOC_MISMATCH") && e.include?("INV-9") }).to be true
    end

    it "passes for CatchWrapper with matching allocator" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
        MIR::CatchWrapper.new("raw zig", [{ name: "x", alloc: :heap, line: 5 }]),
      ]
      errors = checker.check_fn!(fn_def("catch_ok", body))
      expect(errors.select { |e| e.include?("ALLOC_MISMATCH") && e.include?("INV-9") }).to be_empty
    end

    it "passes for CatchWrapper with no error reassigns" do
      body = [
        MIR::AllocMark.new("x", :list, :heap),
        MIR::Cleanup.new("x", { kind: :list, alloc: :heap, has_moved_guard: false }),
        MIR::CatchWrapper.new("raw zig", []),
      ]
      errors = checker.check_fn!(fn_def("catch_empty", body))
      expect(errors.select { |e| e.include?("ALLOC_MISMATCH") }).to be_empty
    end

    it "detects FIELD_LEAK for Set with needs_field_cleanup" do
      body = [
        MIR::Set.new(MIR::FieldGet.new(MIR::Ident.new("user"), "name"), MIR::Lit.new("new"), true),
      ]
      errors = checker.check_fn!(fn_def("field_leak", body))
      expect(errors.any? { |e| e.include?("FIELD_LEAK") && e.include?("user.name") }).to be true
    end

    it "passes for Set without needs_field_cleanup" do
      body = [
        MIR::Set.new(MIR::FieldGet.new(MIR::Ident.new("user"), "name"), MIR::Lit.new("new")),
      ]
      errors = checker.check_fn!(fn_def("field_ok", body))
      expect(errors.select { |e| e.include?("FIELD_LEAK") }).to be_empty
    end

    it "detects HPT_LEAK for discarded heap-returning call" do
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
      expect(errors.select { |e| e.include?("HPT_LEAK") }).to be_empty
    end

    it "passes for ExprStmt with non-heap call" do
      call = MIR::Call.new("doWork", [MIR::Ident.new("rt")], false)
      body = [
        MIR::ExprStmt.new(call, true),
      ]
      errors = checker.check_fn!(fn_def("no_heap", body))
      expect(errors.select { |e| e.include?("HPT_LEAK") }).to be_empty
    end

    it "detects HPT_LEAK for heap call nested as argument" do
      inner = MIR::Call.new("makeList", [MIR::Ident.new("rt")], false, true)
      outer = MIR::Call.new("process", [inner], false)
      body = [
        MIR::ExprStmt.new(outer, true),
      ]
      errors = checker.check_fn!(fn_def("nested_hpt", body))
      expect(errors.any? { |e| e.include?("HPT_LEAK") && e.include?("makeList") }).to be true
    end

  end

  describe "#check_program!" do
    it "verifies all functions in a program" do
      fn1 = fn_def("good", [
        MIR::AllocMark.new("a", :list, :heap),
        MIR::Cleanup.new("a", { kind: :list, alloc: :heap, has_moved_guard: false }),
      ])
      fn2 = fn_def("bad", [
        MIR::AllocMark.new("b", :list, :heap),
        # Missing Cleanup
      ])
      program = MIR::Program.new([fn1, fn2])
      errors = checker.check_program!(program)
      expect(errors.length).to eq(1)
      expect(errors.first).to include("bad")
      expect(errors.first).to include("LEAK")
    end
  end
end
