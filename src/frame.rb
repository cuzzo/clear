# A "Stack Frame" represents a running function
class Frame
  attr_accessor :chunk, :ip, :registers, :arena_mark
  attr_reader :stack_blob, :stack_pointer

  def initialize(chunk, arena_mark = 0) # Default 0 for main
    @chunk = chunk
    @ip = 0
    @registers = Array.new(256) # The 256 Registers
    @arena_mark = arena_mark

    # Eventually, @stack_blob will take over @registers
    # Items are either on the Heap (Arena) or the Stack
    # For now -> the stack is EITHER @registers OR @stack_blob.
    #
    # @stack_blob is a 1KB binary scratchpad for this function execution.
    # We use :nanbox mode so we can store Pointers and Numbers mixed.
    @stack_blob = FluxArray.new(1024, nil, type: :nanbox, register: false)
    @stack_pointer = 0
  end

  def alloca(size)
    addr = @stack_pointer
    @stack_pointer += size
    if @stack_pointer > @stack_blob.max_size
      raise "Stack Overflow: Frame scratchpad exceeded"
    end
    addr
  end

  def debug_str(ins)
    ins[1..]
      .map { |operand| operand_data(operand) }
      .zip(ins[1..]).map { |data, operand| joined_str(data, operand) }
      .join(" ")
  end

  def operand_data(operand)
    if operand.is_a?(String)
      idx = operand[1..].to_i
      case operand[0]
        when "R", "K"
          v = Value.resolve_val(registers[idx]) rescue Value.resolve_val(@stack_blob[idx])
          reg_debug_str(operand.start_with?("R") ? v : @chunk.constants[idx])
        else
          operand # functions
      end
    else
      operand
    end
  end

  def joined_str(data, operand)
    case data == operand # instruction pointer (jmp target, etc)
      when true then operand.is_a?(Numeric) ? "IP: #{operand}" : "##{operand}";
      when false then "#{operand}(#{data})";
    end
  end

  def reg_debug_str(v)
    if v.is_a?(FluxString) then "\"#{v}\""
    elsif v.is_a?(Numeric) then v
    elsif v.is_a?(Chunk) then "\\#{v.name}"
    elsif v.is_a?(FluxClosure) then "λ"
    elsif v.is_a?(FluxHash) then "{}:#{v.keys.count}"
    elsif v.is_a?(FluxArray) && !v.struct_type.nil? then "{}:#{v.size}"
    elsif v.is_a?(FluxArray) then "[]:#{v.size}"
    else v.class
    end
  end
end

