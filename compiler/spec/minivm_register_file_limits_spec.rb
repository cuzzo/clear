# frozen_string_literal: true

require "tmpdir"
require_relative "../../examples/minivm/register_pipeline"

RSpec.describe MiniVM::Register::RegisterFileLimits do
  describe "constants" do
    it "exposes integer caps for i, f, s register files" do
      expect(described_class::I).to be_a(Integer).and(be > 0)
      expect(described_class::F).to be_a(Integer).and(be > 0)
      expect(described_class::S).to be_a(Integer).and(be > 0)
    end

    it "exposes the caps as a single keyed map for downstream iteration" do
      expect(described_class::ALL).to eq(
        i: described_class::I,
        f: described_class::F,
        s: described_class::S
      )
    end
  end

  describe ".validate_vm_cht!" do
    it "passes when every register file is declared at the cap" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "vm.cht")
        File.write(path, <<~CLR)
          MUTABLE iregs: Int64[#{described_class::I}];
          MUTABLE fregs: Float64[#{described_class::F}];
          MUTABLE sregs: String[#{described_class::S}];
        CLR
        expect(described_class.validate_vm_cht!(path)).to eq(true)
      end
    end

    it "raises when a register file is declared at a different size than its cap" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "vm.cht")
        File.write(path, <<~CLR)
          MUTABLE iregs: Int64[#{described_class::I + 1}];
          MUTABLE fregs: Float64[#{described_class::F}];
          MUTABLE sregs: String[#{described_class::S}];
        CLR
        expect { described_class.validate_vm_cht!(path) }
          .to raise_error(/iregs as size #{described_class::I + 1}.*RegisterFileLimits::I = #{described_class::I}/)
      end
    end

    it "raises when a register file declaration is missing entirely" do
      Dir.mktmpdir do |dir|
        path = File.join(dir, "vm.cht")
        File.write(path, <<~CLR)
          MUTABLE iregs: Int64[#{described_class::I}];
          MUTABLE sregs: String[#{described_class::S}];
        CLR
        expect { described_class.validate_vm_cht!(path) }
          .to raise_error(/no `MUTABLE fregs: ...\[N\]` declaration/)
      end
    end

    it "validates the actual checked-in vm.cht in the repository" do
      vm_path = File.expand_path("../../examples/minivm/vm.cht", __dir__)
      expect(described_class.validate_vm_cht!(vm_path)).to eq(true)
    end
  end
end

RSpec.describe MiniVM::Register::AllocatorRewriter do
  let(:layout) { MiniVM::Register::OpcodeLayout.new }

  # Build a program with `count` vregs that are all simultaneously live:
  # define v0..v(count-1) first, then read them in reverse order via an
  # accumulator. At the first IADD, v0..v(count-1) are all live, forcing
  # the allocator to assign distinct physical registers.
  def program_with_unique_int_regs(count)
    spec = MiniVM::Register::OpcodeSpec
    iconst = spec::BY_NAME.fetch(:ICONST).code
    iadd = spec::BY_NAME.fetch(:IADD).code
    iret = spec::BY_NAME.fetch(:IRET).code
    acc = count
    ops = []
    count.times { |i| ops.concat([iconst, i, 0]) }
    ops.concat([iconst, acc, 0])
    (count - 1).downto(0) { |i| ops.concat([iadd, acc, acc, i]) }
    ops.concat([iret, acc])
    MiniVM::Register::Program.decode(ops)
  end

  it "raises OverRegisterCap when a segment exceeds the integer register cap" do
    cap = MiniVM::Register::RegisterFileLimits::I
    program = program_with_unique_int_regs(cap + 1)

    expect { described_class.new.rewrite(program) }
      .to raise_error(MiniVM::Register::RegisterFileLimits::OverRegisterCap,
                      /needs i register \d+.*RegisterFileLimits::I = #{cap}/)
  end

  it "succeeds when register pressure is well under the cap" do
    program = program_with_unique_int_regs(8)
    expect { described_class.new.rewrite(program) }.not_to raise_error
  end

  # `program_with_unique_int_regs(count)` produces count+1 simultaneously-live
  # vregs (count value regs + 1 accumulator), so max physical index = count.
  # cap-1 reaches cap-1 and stays under the cap.
  it "succeeds when the highest assigned physical index is exactly cap-1" do
    cap = MiniVM::Register::RegisterFileLimits::I
    program = program_with_unique_int_regs(cap - 1)
    expect { described_class.new.rewrite(program) }.not_to raise_error
  end
end
