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

    post_op = [
      [:LOADK, "R0", "K0"],
      [:RETURN, "R0"]       # Direct return
    ]

    expect(chunk.code).to eq(post_op)
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

    post_op = [
      [:JMP_FALSE, "R9", 2],  #  <-- Should be updated from 3 to 2
      [:RETURN, "R0"],        #  <-- Replaced instructions (Was at index 1 & 2, now 1)
      [:RETURN, "R0"]         #  <-- Target
    ]
    expect(chunk.code).to eq(post_op)
  end

  it "ignores MOVE followed by RETURN of a DIFFERENT register" do
    pre_op = [
      [:MOVE, "R1", "R0"],
      [:RETURN, "R5"] # Unrelated return
    ]

    chunk.code = pre_op
    optimizer.optimize(chunk)

    # Should not change anything
    expect(chunk.code).to eq(pre_op)
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

    post_op = [
      [:LOADK, "R0", "K0"],
      [:RETURN, "R0"]
    ]

    expect(chunk.code).to eq(post_op)
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

    post_op = [
      [:RETURN, "R0"]
    ]

    expect(chunk.code).to eq(post_op)
  end

  it "preserves code after a RETURN if it is a Jump Target" do
    # Before:
    # 0: JMP_FALSE R0 2
    # 1: RETURN R1      <-- Terminator
    # 2: RETURN R2      <-- Unreachable? NO! It is target of 0.
    pre_op = [
      [:JMP_FALSE, "R0", 2],
      [:RETURN, "R1"],
      [:RETURN, "R2"]
    ]

    chunk.code = pre_op
    optimizer.optimize(chunk)

    expect(chunk.code).to eq(pre_op)
  end

  it "optimizes redundant LOADK instructions" do
    # Before:
    # 0: LOADK R1 K0
    # 1: LOADK R2 K0    <-- Redundant! K0 is already in R1
    chunk.code = [
      [:LOADK, "R1", "K0"],
      [:LOADK, "R2", "K0"],
      [:RETURN, "R2"]
    ]

    optimizer.optimize(chunk)

    post_op = [
      [:LOADK, "R1", "K0"],
      [:MOVE, "R2", "R1"],  # Optimized to register move
      [:RETURN, "R2"]
    ]

    expect(chunk.code).to eq(post_op)
  end

  it "invalidates constant tracking if the register is overwritten" do
    # Before:
    # 0: LOADK R1 K0
    # 1: ADD R1 R1 R1   <-- R1 is modified! It no longer holds K0.
    # 2: LOADK R2 K0    <-- Cannot optimize this. K0 is lost.
    pre_op = [
      [:LOADK, "R1", "K0"],
      [:ADD, "R1", "R1", "R1"],
      [:LOADK, "R2", "K0"]
    ]

    chunk.code = pre_op
    optimizer.optimize(chunk)

    expect(chunk.code).to eq(pre_op)
  end

  it "clears constant tracking at jump targets" do
    # Before:
    # 0: LOADK R1 K0
    # 1: JMP 3
    # 2: RETURN R0      <-- Unreachable (Dead Code), will be removed!
    # 3: LOADK R2 K0    <-- Target of Jump (Moves to index 2)
    # 4: RETURN R2      <-- Moves to index 3
    chunk.code = [
      [:LOADK, "R1", "K0"],
      [:JMP, 3],
      [:RETURN, "R0"],
      [:LOADK, "R2", "K0"],
      [:RETURN, "R2"]
    ]

    optimizer.optimize(chunk)

    post_op = [
      [:LOADK, "R1", "K0"],
      [:JMP,2],
      [:LOADK, "R2", "K0"],
      [:RETURN, "R2"]
    ]

    expect(chunk.code).to eq(post_op)
  end
end

