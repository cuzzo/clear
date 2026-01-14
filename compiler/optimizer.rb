require_relative "opcodes"
require "set"

class Optimizer
  def initialize(logger = nil)
    @logger = $logger || logger || Logger.new(STDOUT)
  end

  def optimize(chunk)
    original_size = chunk.code.size

    # PRE-PASS: Identify Jump Targets
    jump_targets = Set.new
    chunk.code.each do |ins|
      opcode = ins[0]
      if [:JMP, :JMP_FALSE, :JMP_TRUE, :JMP_IF_ERROR, :JMP_IF_OK].include?(opcode)
        target = (opcode == :JMP) ? ins[1] : ins[2]
        jump_targets.add(target)
      end
    end

    new_code = []
    addr_map = {}

    # State for Dead Code Elimination
    reachable = true

    # State for Constant Propagation
    # Maps Register Name (String) -> Constant Value (String)
    constants = {}

    i = 0
    while i < chunk.code.size
      ins = chunk.code[i]
      next_ins = chunk.code[i+1]

      # 1. Reachability Check
      if jump_targets.include?(i)
        reachable = true
        # Optimization Logic: Clear constant tracking at jump targets
        # We don't know where we came from, so we can't assume register states.
        constants.clear
      end

      unless reachable
        addr_map[i] = new_code.size
        i += 1
        next
      end

      addr_map[i] = new_code.size

      # Optimization 1: Redundant Jump to Next
      if ins[0] == :JMP && ins[1] == i + 1
        i += 1
        next
      end

      # Optimization 2: Redundant Return Elimination
      if ins[0] == :MOVE && next_ins && next_ins[0] == :RETURN
        move_dest = ins[1]
        move_src  = ins[2]
        ret_val   = next_ins[1]

        if move_dest == ret_val
          new_code << [:RETURN, move_src]
          addr_map[i+1] = new_code.size - 1
          i += 2
          reachable = false
          next
        end
      end

      # Optimization 3: Redundant LOADK
      # Pattern: LOADK R_dest K_const
      # Logic: If K_const is already in R_src, replace with MOVE R_dest R_src
      if ins[0] == :LOADK
        dest = ins[1]
        const = ins[2]

        if existing_reg = constants.key(const)
          # We found the constant in another register! Optimize to MOVE.
          ins = [:MOVE, dest, existing_reg]
        end
      end

      # =========================================================
      # Optimization 4: Constant Folding (Math on Literals)
      # Pattern: OP R_dest R_src1 R_src2
      # Logic: If src1 and src2 are known constants, do math now.
      # =========================================================
      if [:ADD, :SUB, :MUL, :DIV, :MOD].include?(ins[0])
        dest_reg = ins[1]
        src1_reg = ins[2]
        src2_reg = ins[3]

        # Check if we know the constants for both inputs
        if constants.key?(src1_reg) && constants.key?(src2_reg)
          val1 = get_const_value(chunk, constants[src1_reg])
          val2 = get_const_value(chunk, constants[src2_reg])

          # Attempt to calculate result (returns nil if unsafe/impossible)
          folded_result = calculate_fold(ins[0], val1, val2)

          if folded_result != nil
            # Success! Add new constant to chunk
            k_idx = chunk.add_constant(folded_result)
            k_key = "K#{k_idx}"

            # Replace opcode with LOADK
            ins = [:LOADK, dest_reg, k_key]

            # Update our tracking so subsequent instructions see the new value!
            # (The logic below will handle the actual map update)
          end
        end
      end

      # Track Register State (Constant Propagation)
      opcode = ins[0]
      if opcode == :LOADK
        constants[ins[1]] = ins[2]
      elsif opcode == :MOVE
        # If we know what is in src, we know what is in dest.
        # Otherwise, we moved garbage into dest, so we forget dest.
        src_reg = ins[2]
        if constants.has_key?(src_reg)
          constants[ins[1]] = constants[src_reg]
        else
          constants.delete(ins[1])
        end
      elsif [:JMP, :JMP_FALSE, :JMP_TRUE, :JMP_IF_ERROR, :JMP_IF_OK, :RETURN, :EXIT, :THROW].include?(opcode)
        # Control flow does not overwrite registers
      else
        # Heuristic: Assume any other instruction writes to the register at index 1
        # e.g., ADD R1 R2 R3 overwrites R1.
        target_reg = ins[1]
        if target_reg.is_a?(String) && target_reg.start_with?("R")
          constants.delete(target_reg)
        end
      end

      new_code << ins

      # Check Terminator
      if [:RETURN, :JMP, :EXIT, :THROW].include?(ins[0])
        reachable = false
      end

      i += 1
    end

    # Pass 2: Jump Patching
    new_code.each do |ins|
      patch_jumps(ins, addr_map)
    end

    chunk.code = new_code

    # Fix line info mapping (optional, keeping basic impl)
    new_lines = []
    chunk.code.each_with_index { |_, idx| new_lines << (chunk.line_info[idx] || 1) }
    chunk.line_info = new_lines

    if @logger.debug? && original_size != new_code.size
      @logger.debug("[Optimizer] Reduced code from #{original_size} to #{new_code.size} instrs.")
    end

    chunk
  end

  private

  def get_const_value(chunk, k_key)
    # k_key is "K0", "K10", etc.
    idx = k_key[1..-1].to_i
    chunk.constants[idx]
  end

  def calculate_fold(op, v1, v2)
    # Only fold Primitives (Numbers/Floats)
    return nil unless v1.is_a?(Numeric) && v2.is_a?(Numeric)

    begin
      case op
      when :ADD then v1 + v2
      when :SUB then v1 - v2
      when :MUL then v1 * v2
      when :DIV
        return nil if v2 == 0 # Safety check
        v1 / v2
      when :MOD
        return nil if v2 == 0
        v1 % v2
      else nil
      end
    rescue => e
      # If anything goes wrong (e.g. overflow, type error), abort fold
      nil
    end
  end

  def patch_jumps(ins, map)
    opcode = ins[0]
    target_idx = nil

    case opcode
    when :JMP
      target_idx = 1
    when :JMP_FALSE, :JMP_TRUE, :JMP_IF_ERROR, :JMP_IF_OK
      target_idx = 2
    end

    return unless target_idx

    old_target = ins[target_idx]
    # If the target was optimized away, map to the next available instruction
    new_target = map[old_target] || map.values.last + 1

    ins[target_idx] = new_target
  end
end

