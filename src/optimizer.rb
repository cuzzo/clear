require_relative "opcodes"

class Optimizer
  def initialize(logger = nil)
    @logger = logger || Logger.new(STDOUT)
  end

  def optimize(chunk)
    original_size = chunk.code.size

    # Pass 1: Redundant Return Elimination
    # Pattern:
    #   MOVE R_dest, R_src
    #   RETURN R_dest
    # Optimization:
    #   (Delete MOVE)
    #   RETURN R_src

    new_code = []
    # Map old instruction pointer (index) to new instruction pointer
    # Used to fix Jumps later.
    addr_map = {}

    i = 0
    while i < chunk.code.size
      ins = chunk.code[i]
      next_ins = chunk.code[i+1]

      # Record where the current old_ip lands in the new_code
      addr_map[i] = new_code.size

      # Check Pattern
      if ins[0] == :MOVE && next_ins && next_ins[0] == :RETURN
        move_dest = ins[1] # "R1"
        move_src  = ins[2] # "R2"
        ret_val   = next_ins[1] # "R1"

        if move_dest == ret_val
          # MATCH FOUND!
          # Skip the MOVE.
          # Emit RETURN R_src instead of RETURN R_dest
          new_code << [:RETURN, move_src]

          # We consumed two instructions (MOVE and RETURN)
          # Map the second instruction (RETURN) to this same new slot
          addr_map[i+1] = new_code.size - 1

          i += 2
          next
        end
      end

      # No optimization applied, copy instruction
      new_code << ins
      i += 1
    end

    # Pass 2: Jump Patching
    # We must update any JMP arguments because the addresses have shifted.
    new_code.each do |ins|
      patch_jumps(ins, addr_map)
    end

    # Update Chunk
    chunk.code = new_code

    # Optional: Fix line numbers (simplistic mapping)
    # Ideally, you'd rebuild line_info in parallel with new_code
    new_lines = []
    chunk.code.each_with_index do |_, idx|
       # This is an approximation. A real impl would track source lines during Pass 1.
       new_lines << (chunk.line_info[idx] || 1)
    end
    chunk.line_info = new_lines

    if @logger.debug? && original_size != new_code.size
      @logger.debug("[Optimizer] Reduced code from #{original_size} to #{new_code.size} instrs.")
    end

    chunk
  end

  private

  def patch_jumps(ins, map)
    opcode = ins[0]

    # Identify which operand is the Jump Target
    # Based on OpCodes::DEFINITIONS
    target_idx = nil

    case opcode
    when :JMP
      target_idx = 1
    when :JMP_FALSE, :JMP_TRUE, :JMP_IF_ERROR, :JMP_IF_OK
      target_idx = 2
    end

    return unless target_idx

    old_target = ins[target_idx]

    # Map old target IP to new target IP
    # If the target was the end of the file (e.g. JMP to code.size), handle gracefully
    new_target = map[old_target] || map.values.last + 1

    ins[target_idx] = new_target
  end
end
