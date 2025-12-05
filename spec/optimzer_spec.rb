require "rspec"
require "logger"

require_relative "../src/chunk"
require_relative "../src/optimizer"

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
    # 0: JMP 3        <-- Jumps to RETURN
    # 1: MOVE R1 R0   <-- Removed
    # 2: RETURN R1    <-- Optimized
    # 3: RETURN R0    <-- Target of Jump
    chunk.code = [
      [:JMP, 3],
      [:MOVE, "R1", "R0"],
      [:RETURN, "R1"],
      [:RETURN, "R0"]
    ]

    optimizer.optimize(chunk)

    # After:
    # 0: JMP 2        <-- Should be updated from 3 to 2
    # 1: RETURN R0    <-- Replaced instructions (Was at index 1 & 2, now 1)
    # 2: RETURN R0    <-- Target

    expect(chunk.code.size).to eq(3)

    # Check the Jump Instruction
    jump_op = chunk.code[0]
    expect(jump_op).to eq([:JMP, 2])
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
end
