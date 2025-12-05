require_relative "opcodes"
require "set"

class Optimizer
  def initialize(logger = nil)
    @logger = logger || $logger || Logger.new(STDOUT)
  end

  def optimize(chunk)
    original_size = chunk.code.size

    # PRE-PASS: Identify Jump Targets
    # We need to know which instructions are jumped TO, so we don't delete them
    # even if they look unreachable (e.g. following a RETURN).
    jump_targets = Set.new
    chunk.code.each do |ins|
      opcode = ins[0]
      if [:JMP, :JMP_FALSE, :JMP_TRUE, :JMP_IF_ERROR, :JMP_IF_OK].include?(opcode)
        # JMP target is idx 1, Conditional Jumps target is idx 2
        target = (opcode == :JMP) ? ins[1] : ins[2]
        jump_targets.add(target)
      end
    end

    new_code = []
    # Map old instruction pointer (index) to new instruction pointer
    # Used to fix Jumps later.
    addr_map = {}

    # State for Dead Code Elimination
    reachable = true

    i = 0
    while i < chunk.code.size
      ins = chunk.code[i]
      next_ins = chunk.code[i+1]

      # 1. Reachability Check
      # If this index is a target of a jump, it becomes reachable again!
      if jump_targets.include?(i)
        reachable = true
      end

      unless reachable
        # Skip Dead Code
        # We map it to the current size (the next valid instruction) so jumps landing here are valid
        addr_map[i] = new_code.size
        i += 1
        next
      end

      # Record mapping for this instruction
      addr_map[i] = new_code.size

      # Optimization 1: Redundant Jump to Next
      # Pattern: JMP (i+1)
      if ins[0] == :JMP && ins[1] == i + 1
        # Skip this instruction
        i += 1
        next
      end

      # Optimization 2: Redundant Return Elimination
      # Pattern: MOVE R1 R0 -> RETURN R1
      if ins[0] == :MOVE && next_ins && next_ins[0] == :RETURN
        move_dest = ins[1]
        move_src  = ins[2]
        ret_val   = next_ins[1]

        if move_dest == ret_val
          new_code << [:RETURN, move_src]
          addr_map[i+1] = new_code.size - 1
          i += 2

          # Return is a terminator
          reachable = false
          next
        end
      end

      # No optimization applied, copy instruction
      new_code << ins

      # Check Terminator to turn off reachability
      if [:RETURN, :JMP, :EXIT, :THROW].include?(ins[0])
        reachable = false
      end

      i += 1
    end

    # Pass 2: Jump Patching
    new_code.each do |ins|
      patch_jumps(ins, addr_map)
    end

    # Update Chunk
    chunk.code = new_code

    # Update Line Info (Simple approximation)
    new_lines = []
    chunk.code.each_with_index { |_, idx| new_lines << (chunk.line_info[idx] || 1) }
    chunk.line_info = new_lines

    if @logger.debug? && original_size != new_code.size
      @logger.debug("[Optimizer] Reduced code from #{original_size} to #{new_code.size} instrs.")
    end

    chunk
  end

  private

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
    new_target = map[old_target] || map.values.last + 1

    ins[target_idx] = new_target
  end
end

