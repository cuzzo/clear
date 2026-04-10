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
