require "rspec"
require "logger"

require_relative "../src/chunk"
require_relative "../src/optimizer"

if $logger.nil?
  $logger = Logger.new(STDOUT)
  $logger.level = Logger::INFO
end

RSpec.describe Optimizer do
  let(:optimizer) { Optimizer.new }
  let(:chunk) { Chunk.new("test") }

  it "optimizes redundant MOVE followed by RETURN" do
    # Before:
    # 0: LOADK R0 K0
    # 1: MOVE R1 R0   <-- Redundant
    # 2: RETURN R1    <-- Returns dest of move
    chunk.code = [
      [:LOADK, "R0", "K0"],
      [:MOVE, "R1", "R0"],
      [:RETURN, "R1"]
    ]

    optimizer.optimize(chunk)

    # Expect:
    # 0: LOADK R0 K0
    # 1: RETURN R0    <-- Optimized
    expect(chunk.code.size).to eq(2)
    expect(chunk.code[1]).to eq([:RETURN, "R0"])
  end

  it "updates JMP targets when instructions are removed" do
    # Before:
    # 0: JMP_FALSE R9 3  <-- Conditional Jump (Allows fallthrough, so 1 & 2 are reachable)
    # 1: MOVE R1 R0      <-- Redundant
    # 2: RETURN R1       <-- Optimized
    # 3: RETURN R0       <-- Target of Jump
    chunk.code = [
      [:JMP_FALSE, "R9", 3],
      [:MOVE, "R1", "R0"],
      [:RETURN, "R1"],
      [:RETURN, "R0"]
    ]

    optimizer.optimize(chunk)

    # After:
    # 0: JMP_FALSE R9 2  <-- Should be updated from 3 to 2
    # 1: RETURN R0       <-- Replaced instructions (Was at index 1 & 2, now 1)
    # 2: RETURN R0       <-- Target

    expect(chunk.code.size).to eq(3)

    # Check the Jump Instruction
    jump_op = chunk.code[0]
    expect(jump_op).to eq([:JMP_FALSE, "R9", 2])
  end

  it "ignores MOVE followed by RETURN of a DIFFERENT register" do
    chunk.code = [
      [:MOVE, "R1", "R0"],
      [:RETURN, "R5"] # Unrelated return
    ]

    optimizer.optimize(chunk)

    # Should not change anything
    expect(chunk.code.size).to eq(2)
    expect(chunk.code[0]).to eq([:MOVE, "R1", "R0"])
  end

  it "removes JMP instructions that jump to the immediate next line" do
    # Before:
    # 0: LOADK R0 K0
    # 1: JMP 2        <-- Redundant! 2 is the next line.
    # 2: RETURN R0
    chunk.code = [
      [:LOADK, "R0", "K0"],
      [:JMP, 2],
      [:RETURN, "R0"]
    ]

    optimizer.optimize(chunk)

    # After:
    # 0: LOADK R0 K0
    # 1: RETURN R0
    expect(chunk.code.size).to eq(2)
    expect(chunk.code[1]).to eq([:RETURN, "R0"])
  end

  it "removes unreachable code after a RETURN" do
    # Before:
    # 0: RETURN R0
    # 1: RETURN R1    <-- Unreachable (Dead Code)
    # 2: LOADK R2 K0  <-- Unreachable
    chunk.code = [
      [:RETURN, "R0"],
      [:RETURN, "R1"],
      [:LOADK, "R2", "K0"]
    ]

    optimizer.optimize(chunk)

    # After:
    # 0: RETURN R0
    expect(chunk.code.size).to eq(1)
    expect(chunk.code[0]).to eq([:RETURN, "R0"])
  end

  it "preserves code after a RETURN if it is a Jump Target" do
    # Before:
    # 0: JMP_FALSE R0 2
    # 1: RETURN R1      <-- Terminator
    # 2: RETURN R2      <-- Unreachable? NO! It is target of 0.
    chunk.code = [
      [:JMP_FALSE, "R0", 2],
      [:RETURN, "R1"],
      [:RETURN, "R2"]
    ]

    optimizer.optimize(chunk)

    # After: No Change (All code is reachable)
    expect(chunk.code.size).to eq(3)
    expect(chunk.code[2]).to eq([:RETURN, "R2"])
  end
end

