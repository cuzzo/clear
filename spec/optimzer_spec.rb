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

  describe "Constant Folding" do
    it "folds simple addition of two constants" do
      # Before:
      # 0: LOADK R1 K0 (10)
      # 1: LOADK R2 K1 (20)
      # 2: ADD R3 R1 R2     <-- Should fold to 30
      # 3: RETURN R3
      chunk.constants = [10, 20]
      chunk.code = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:ADD, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      optimizer.optimize(chunk)

      # Note: 30 is added as a new constant at index 2 (K2)
      post_op = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:LOADK, "R3", "K2"],   # <-- Replaced with LOADK 30
        [:RETURN, "R3"]
      ]

      expect(chunk.code).to eq(post_op)
      expect(chunk.constants[2]).to eq(30)
    end

    it "folds multiplication of constants" do
      # Before:
      # 0: LOADK R1 K0 (5)
      # 1: LOADK R2 K1 (5)
      # 2: MUL R3 R1 R2
      # 3: RETURN R3
      chunk.constants = [5, 5]
      chunk.code = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:MUL, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      optimizer.optimize(chunk)

      # 5 * 5 = 25 (K2)
      post_op = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:LOADK, "R3", "K2"],
        [:RETURN, "R3"]
      ]

      expect(chunk.code).to eq(post_op)
      expect(chunk.constants[2]).to eq(25)
    end

    it "folds subtraction of constants" do
      # Before:
      # 0: LOADK R1 K0 (10)
      # 1: LOADK R2 K1 (4)
      # 2: SUB R3 R1 R2
      # 3: RETURN R3
      chunk.constants = [10, 4]
      chunk.code = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:SUB, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      optimizer.optimize(chunk)

      # 10 - 4 = 6 (K2)
      post_op = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:LOADK, "R3", "K2"],
        [:RETURN, "R3"]
      ]

      expect(chunk.code).to eq(post_op)
      expect(chunk.constants[2]).to eq(6)
    end

    it "folds chained operations" do
      # Before:
      # 0: LOADK R1 K0 (1)
      # 1: LOADK R2 K1 (2)
      # 2: ADD R3 R1 R2     <-- Folds to 3 (K3)
      # 3: LOADK R4 K2 (5)
      # 4: ADD R5 R3 R4     <-- Folds 3 + 5 to 8 (K4)
      # 5: RETURN R5
      chunk.constants = [1, 2, 5]
      chunk.code = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:ADD, "R3", "R1", "R2"],
        [:LOADK, "R4", "K2"],
        [:ADD, "R5", "R3", "R4"],
        [:RETURN, "R5"]
      ]

      optimizer.optimize(chunk)

      post_op = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:LOADK, "R3", "K3"], # R3 = 3
        [:LOADK, "R4", "K2"],
        [:LOADK, "R5", "K4"], # R5 = 8
        [:RETURN, "R5"]
      ]

      expect(chunk.code).to eq(post_op)
      expect(chunk.constants[3]).to eq(3)
      expect(chunk.constants[4]).to eq(8)
    end

    it "does NOT fold if inputs are not constants" do
      # Before:
      # 0: MOVE R1 R9       <-- Unknown value
      # 1: LOADK R2 K0 (10)
      # 2: ADD R3 R1 R2     <-- Cannot fold
      # 3: RETURN R3
      chunk.constants = [10]
      chunk.code = [
        [:MOVE, "R1", "R9"],
        [:LOADK, "R2", "K0"],
        [:ADD, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      optimizer.optimize(chunk)

      post_op = [
        [:MOVE, "R1", "R9"],
        [:LOADK, "R2", "K0"],
        [:ADD, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      expect(chunk.code).to eq(post_op)
    end

    it "aborts folding on division by zero" do
      # Before:
      # 0: LOADK R1 K0 (10)
      # 1: LOADK R2 K1 (0)
      # 2: DIV R3 R1 R2     <-- Unsafe, should remain DIV
      # 3: RETURN R3
      chunk.constants = [10, 0]
      chunk.code = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:DIV, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      optimizer.optimize(chunk)

      post_op = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:DIV, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      expect(chunk.code).to eq(post_op)
    end

    it "aborts folding on type mismatch (String addition)" do
      # Before:
      # 0: LOADK R1 K0 (10)
      # 1: LOADK R2 K1 ("Hello")
      # 2: ADD R3 R1 R2     <-- Unsafe math
      # 3: RETURN R3
      chunk.constants = [10, "Hello"]
      chunk.code = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:ADD, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      optimizer.optimize(chunk)

      post_op = [
        [:LOADK, "R1", "K0"],
        [:LOADK, "R2", "K1"],
        [:ADD, "R3", "R1", "R2"],
        [:RETURN, "R3"]
      ]

      expect(chunk.code).to eq(post_op)
    end
  end
end

