# frozen_string_literal: true

# Source-line metadata travels from the CLEAR source through the
# register bc emitter, through the optimizer/allocator pipeline, and
# arrives at the runner as a parallel `Int64[]` (4-byte LE-encoded by
# bc_run.rb). The runner's `formatVmError` consults it to produce
# `vm.cht:<line>` style crash messages instead of bare `ip=<N>`.
#
# These tests exercise the Ruby-side plumbing only -- the runner
# integration is covered by the broader VM smoke + bench corpus.

require "tmpdir"
require_relative "../examples/minivm/register_pipeline"

RSpec.describe MiniVM::Register::Pipeline do
  let(:layout) { MiniVM::Register::OpcodeLayout.new }
  let(:spec)   { MiniVM::Register::OpcodeSpec }

  def iconst(dst, const_idx)
    [spec::BY_NAME.fetch(:ICONST).code, dst, const_idx]
  end

  def iret(src)
    [spec::BY_NAME.fetch(:IRET).code, src]
  end

  describe "#run_with_lines" do
    it "returns ops + source_lines parallel arrays of the same length" do
      ops = iconst(0, 0) + iret(0)
      lines = [42, 0, 0, 42, 0]

      result = described_class.new.run_with_lines(ops, lines)

      expect(result.ops.length).to eq(result.source_lines.length)
    end

    it "preserves the source line of an ICONST through the pipeline" do
      ops = iconst(0, 0) + iret(0)
      lines = [42, 0, 0, 99, 0]

      result = described_class.new.run_with_lines(ops, lines)

      program = MiniVM::Register::Program.decode(result.ops, source_lines: result.source_lines)
      iconst_insn = program.instructions.find { |insn| insn.opcode == spec::BY_NAME.fetch(:ICONST).code }
      iret_insn = program.instructions.find { |insn| insn.opcode == spec::BY_NAME.fetch(:IRET).code }

      expect(iconst_insn.source_line).to eq(42)
      expect(iret_insn.source_line).to eq(99)
    end

    it "zero-pads operand positions in the output line array" do
      ops = iconst(0, 0) + iret(0)
      lines = [42, 0, 0, 99, 0]

      result = described_class.new.run_with_lines(ops, lines)

      # ICONST at position 0 carries line 42; positions 1,2 (operand) are 0.
      expect(result.source_lines[0]).to eq(42)
      expect(result.source_lines[1]).to eq(0)
      expect(result.source_lines[2]).to eq(0)
      # IRET at position 3 carries line 99; position 4 (operand) is 0.
      expect(result.source_lines[3]).to eq(99)
      expect(result.source_lines[4]).to eq(0)
    end

    it "preserves source_line on the fused instruction when the optimizer fuses compare+branch" do
      ilt = spec::BY_NAME.fetch(:ILT).code
      jf = spec::BY_NAME.fetch(:JF).code
      jiltf = spec::BY_NAME.fetch(:JILTF).code
      iret = spec::BY_NAME.fetch(:IRET).code

      # Layout: ILT r3 r1 r2; JF r3 target=9; IRET r0; <target> IRET r0.
      # The optimizer should fuse ILT+JF into JILTF, inheriting ILT's line.
      ops = [
        ilt, 3, 1, 2,           # ip=0..3
        jf, 3, 9,                # ip=4..6
        iret, 0,                 # ip=7..8 (fall-through return)
        iret, 0                  # ip=9..10 (target return)
      ]
      lines = [55, 0, 0, 0,
               88, 0, 0,
               66, 0,
               77, 0]

      result = described_class.new.run_with_lines(ops, lines)
      program = MiniVM::Register::Program.decode(result.ops, source_lines: result.source_lines)
      fused = program.instructions.find { |insn| insn.opcode == jiltf }

      expect(fused).not_to be_nil
      expect(fused.source_line).to eq(55)
    end
  end

  describe "Program.decode" do
    it "leaves source_line nil when no lines array is passed" do
      ops = iconst(0, 0) + iret(0)
      program = MiniVM::Register::Program.decode(ops)
      expect(program.instructions.map(&:source_line)).to eq([nil, nil])
    end

    it "reads the line at the opcode position, ignoring operand-position entries" do
      ops = iconst(0, 0) + iret(0)
      lines = [11, 999, 999, 22, 999]

      program = MiniVM::Register::Program.decode(ops, source_lines: lines)

      expect(program.instructions[0].source_line).to eq(11)
      expect(program.instructions[1].source_line).to eq(22)
    end
  end

  describe "Program#to_source_lines" do
    it "round-trips through decode -> to_source_lines for a no-op pipeline" do
      ops = iconst(0, 0) + iret(0)
      lines_in = [42, 0, 0, 99, 0]
      program = MiniVM::Register::Program.decode(ops, source_lines: lines_in)
      expect(program.to_source_lines).to eq(lines_in)
    end
  end
end

# End-to-end check that per-statement source-line plumbing -- AST token
# -> MIR::Stmt#source_line -> emitter `@current_source_line` -> packed
# `_register_lines.bin` -- attributes opcodes to their actual originating
# CLEAR statement, not the function start. Without this each opcode in
# `fib` would inherit the FunctionDef's line (function-level fallback).

require_relative "../examples/minivm/vm_golden_harness"
require_relative "../examples/minivm/register_bc_emitter"

RSpec.describe "Per-statement source-line attribution" do
  it "stamps each register opcode with the source line of its originating CLEAR statement" do
    fixture = File.expand_path("../examples/minivm/fib21.cht", __dir__)
    src = File.read(fixture)
    src_dir = File.dirname(fixture)

    imp = ModuleImporter.new(base_dir: src_dir)
    fe = CompilerFrontend.compile(src, importer: imp, source_dir: src_dir)
    lo = MIRLowering.new(
      struct_schemas: fe.struct_schemas,
      enum_schemas: fe.enum_schemas,
      union_schemas: fe.union_schemas,
      fn_sigs: fe.fn_sigs,
      moved_guard_info: fe.moved_guard_info,
      importer: imp,
      source_dir: src_dir,
      target: :bc
    )
    prog = lo.lower_program(fe.ast)
    MIRChecker.new.check_program!(prog, strict: true)
    bc = RegisterBcEmitter.new(fe, source: src).compile(prog)

    program = MiniVM::Register::Program.decode(bc.ops, source_lines: bc.source_lines)
    spec = MiniVM::Register::OpcodeSpec

    by_opcode_line = program.instructions
      .reject { |insn| insn.source_line.to_i == 0 }
      .group_by { |insn| insn.source_line }
      .transform_values { |insns| insns.map { |i| spec::BY_CODE[i.opcode].name } }

    # fib21.cht:
    #   line 2:  IF n <= 1_i64 THEN
    #   line 3:  RETURN n;
    #   line 5:  RETURN fib(n - 1_i64) + fib(n - 2_i64);
    #   line 9:  RETURN fib(21_i64);
    expect(by_opcode_line.keys).to contain_exactly(2, 3, 5, 9)
    expect(by_opcode_line.fetch(2)).to include(:JILTEF) # fused compare-branch
    expect(by_opcode_line.fetch(3)).to eq([:IRET])      # inner RETURN n
    expect(by_opcode_line.fetch(5)).to include(:IADD, :ICALL) # the fib(n-1)+fib(n-2)
    expect(by_opcode_line.fetch(9)).to include(:ICALL)  # main's RETURN fib(21)
  end

  it "emits a register-to-variable-name table joining emitter virtuals with allocator physicals" do
    fixture = File.expand_path("../examples/minivm/fib21.cht", __dir__)
    src = File.read(fixture)
    src_dir = File.dirname(fixture)

    imp = ModuleImporter.new(base_dir: src_dir)
    fe = CompilerFrontend.compile(src, importer: imp, source_dir: src_dir)
    lo = MIRLowering.new(
      struct_schemas: fe.struct_schemas,
      enum_schemas: fe.enum_schemas,
      union_schemas: fe.union_schemas,
      fn_sigs: fe.fn_sigs,
      moved_guard_info: fe.moved_guard_info,
      importer: imp,
      source_dir: src_dir,
      target: :bc
    )
    prog = lo.lower_program(fe.ast)
    MIRChecker.new.check_program!(prog, strict: true)
    bc = RegisterBcEmitter.new(fe, source: src).compile(prog)

    # fib has one named param `n` -> physical register 0.
    fib_table = bc.var_names.find { |fv| fv.bindings.any? { |b| b.name == "n" } }
    expect(fib_table).not_to be_nil
    n_binding = fib_table.bindings.find { |b| b.name == "n" }
    expect(n_binding.kind).to eq(:i)
    expect(n_binding.virt).to eq(0) # post-allocation, this field holds the physical reg
  end

  it "stamps each binding with its CLEAR source line so shadowed registers resolve correctly" do
    # Three sequential Int64 locals on three lines map to the same
    # physical register (linear-scan reuse). The names table must
    # carry one row per binding with the source line stamped, so the
    # runtime snapshot can pick `y` over `x` when paused at line 4.
    src = <<~CHT
      FN main() RETURNS Void ->
          x: Int64 = 10_i64;
          y: Int64 = x * 2_i64;
          z: Int64 = y + 5_i64;
          print(z.toString());
          RETURN;
      END
    CHT

    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "main.cht"), src)
      imp = ModuleImporter.new(base_dir: dir)
      fe = CompilerFrontend.compile(src, importer: imp, source_dir: dir)
      lo = MIRLowering.new(
        struct_schemas: fe.struct_schemas,
        enum_schemas: fe.enum_schemas,
        union_schemas: fe.union_schemas,
        fn_sigs: fe.fn_sigs,
        moved_guard_info: fe.moved_guard_info,
        importer: imp,
        source_dir: dir,
        target: :bc
      )
      prog = lo.lower_program(fe.ast)
      MIRChecker.new.check_program!(prog, strict: true)
      bc = RegisterBcEmitter.new(fe, source: src).compile(prog)

      main_table = bc.var_names.find { |fv| fv.bindings.any? { |b| b.name == "x" } }
      expect(main_table).not_to be_nil
      by_name = main_table.bindings.to_h { |b| [b.name, b] }
      expect(by_name.keys).to contain_exactly("x", "y", "z")

      # Each binding's source_line matches the CLEAR line of its decl.
      expect(by_name.fetch("x").source_line).to eq(2)
      expect(by_name.fetch("y").source_line).to eq(3)
      expect(by_name.fetch("z").source_line).to eq(4)

      # x, y, z share one phys slot via linear-scan reuse, so each
      # binding's end_source_line points at the next binding's
      # source_line for that slot. The last binding has -1 (sentinel:
      # "lives until function return"). x@2 -> y@3 -> z@4 gives
      # x.end=3, y.end=4, z.end=-1.
      expect(by_name.fetch("x").end_source_line).to eq(3)
      expect(by_name.fetch("y").end_source_line).to eq(4)
      expect(by_name.fetch("z").end_source_line).to eq(-1)

      # All three landed on the same physical register (the test would
      # be vacuous otherwise -- if the allocator handed each its own
      # slot, the shadowing case never arises). If the allocator
      # changes and this assertion fails, the test stops exercising
      # the actual fix; pick a different fixture that forces reuse.
      phys_set = main_table.bindings.map { |b| [b.kind, b.virt] }.uniq
      expect(phys_set.size).to eq(1)
    end
  end
end
