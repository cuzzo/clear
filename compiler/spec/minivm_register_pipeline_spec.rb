# frozen_string_literal: true

require_relative "../../examples/minivm/register_pipeline"

RSpec.describe MiniVM::Register::Pipeline do
  it "exposes register opcode metadata for branch targets and register refs" do
    spec = MiniVM::Register::OpcodeSpec

    expect(spec.branch_target_indexes(MiniVM::Register::OpcodeLayout::JF)).to eq([1])
    expect(spec.branch_target_indexes(spec::BY_NAME.fetch(:ICALL).code)).to eq([])
    expect(spec.code_target_indexes(spec::BY_NAME.fetch(:ICALL).code)).to eq([1])
    expect(spec.branch_target_indexes(spec::BY_NAME.fetch(:JILTF).code)).to eq([2])
    expect(spec.register_uses(spec::BY_NAME.fetch(:IADD).code, [0, 1, 2])).to eq([[:i, 1], [:i, 2]])
    expect(spec.register_defs(spec::BY_NAME.fetch(:IADD).code, [0, 1, 2])).to eq([[:i, 0]])
    expect(spec.register_uses(spec::BY_NAME.fetch(:ICALL).code, [4, 20, 2, 8, 8, 0, 7, 1, 3])).to eq([[:i, 7], [:f, 3]])
    expect(spec.register_defs(spec::BY_NAME.fetch(:NCALL).code, [2, 5, 1, 0])).to eq([[:f, 5]])
  end

  it "profiles planned packed encoding size and operand ranges" do
    program = MiniVM::Register::Program.decode([
      0, 7, 300,
      66, 1, 2, 4000,
      32, 1, 3, 2, 2, 0, 7, 1, 8,
      2,
    ])

    profile = MiniVM::Register::OpcodeSpec.profile_packing(program)

    expect(profile).to be_packable
    expect(profile.instruction_count).to eq(4)
    expect(profile.max_by_kind[:reg]).to eq(8)
    expect(profile.max_by_kind[:const]).to eq(300)
    expect(profile.max_by_kind[:target]).to eq(4000)
    expect(profile.max_by_kind[:native_id]).to eq(2)
    expect(profile.count_by_kind[:tag]).to eq(3)
    expect(profile.raw_i64_bytes).to eq(17 * 8)
    expect(profile.packed_bytes).to be < profile.raw_i64_bytes
  end

  it "packs and unpacks register ops through the planned byte format" do
    ops = [
      0, 7, 300,
      66, 1, 2, 4000,
      32, 1, 3, 2, 2, 0, 7, 1, 8,
      30, 4, 20, 1, 8, 8, 0, 9,
      2,
    ]

    packed = MiniVM::Register::OpcodeSpec.pack_ops(ops)

    expect(packed[0, 4]).to eq([82, 66, 67, 49])
    expect(packed.length).to be < ops.length * 8
    expect(MiniVM::Register::OpcodeSpec.unpack_ops(packed)).to eq(ops)
  end

  it "reports operands that do not fit the planned packed encoding" do
    program = MiniVM::Register::Program.decode([
      0, 300, 70_000,
      2,
    ])

    profile = MiniVM::Register::OpcodeSpec.profile_packing(program)

    expect(profile).not_to be_packable
    expect(profile.failures).to include(/reg=300/)
    expect(profile.failures).to include(/const=70000/)
  end

  it "round-trips fixed-width and variable-width register instructions" do
    identity_optimizer = Class.new { def optimize(program) = program }.new
    identity_allocator = Class.new { def rewrite(program) = program }.new
    ops = [
      0, 0, 0,
      32, 3, 1, 3, 2, 2, 0, 2, 1,
      30, 4, 20, 1, 8, 8, 0, 9,
      2,
    ]

    expect(described_class.new(optimizer: identity_optimizer, allocator: identity_allocator).run(ops)).to eq(ops)
  end

  it "records instruction labels and successors for future direct threading" do
    program = MiniVM::Register::Program.decode([
      0, 0, 0,
      15, 0, 9,
      14, 11,
      2,
      1, 0,
      2,
    ])

    expect(program.direct_thread_labels).to include(
      0 => "op_0",
      3 => "op_3",
      6 => "op_6",
      8 => "op_8",
      9 => "op_9",
      11 => "op_11"
    )
    expect(program.successor_ips(program.instructions[1])).to eq([9, 6])
    expect(program.successor_ips(program.instructions[2])).to eq([11])
    expect(program.successor_ips(program.instructions[3])).to eq([])
  end

  it "has explicit optimizer and allocator/rewriter hooks" do
    optimizer = Class.new do
      attr_reader :seen

      def optimize(program)
        @seen = program
        program
      end
    end.new
    allocator = Class.new do
      attr_reader :seen

      def rewrite(program)
        @seen = program
        program
      end
    end.new

    ops = [0, 0, 0, 2]
    expect(described_class.new(optimizer: optimizer, allocator: allocator).run(ops)).to eq(ops)
    expect(optimizer.seen).to be_a(MiniVM::Register::Program)
    expect(allocator.seen).to be_a(MiniVM::Register::Program)
  end

  it "fuses adjacent integer compare plus false branch when the temp dies at the branch" do
    identity_allocator = Class.new { def rewrite(program) = program }.new
    ops = [
      0, 0, 0,
      0, 1, 1,
      8, 2, 0, 1,
      15, 2, 19,
      4, 0, 0, 1,
      14, 6,
      1, 0,
      2,
    ]

    expect(described_class.new(allocator: identity_allocator).run(ops)).to eq([
      0, 0, 0,
      0, 1, 1,
      66, 0, 1, 16,
      4, 0, 0, 1,
      14, 6,
      1, 0,
      2,
    ])
  end

  it "does not fuse compare plus branch when the compare temp is live at the target" do
    identity_allocator = Class.new { def rewrite(program) = program }.new
    ops = [
      0, 0, 0,
      0, 1, 1,
      8, 2, 0, 1,
      15, 2, 15,
      1, 0,
      1, 2,
      2,
    ]

    expect(described_class.new(allocator: identity_allocator).run(ops)).to eq(ops)
  end
end
