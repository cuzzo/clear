class Chunk
  attr_accessor :code, :constants, :name, :handler_info, :line_info
  def initialize(name = "main")
    @name = name
    @code = []
    @constants = []
    @handler_info = {}
    @line_info = []
    @logger = $logger || Logger.new(STDOUT)
  end

  def add_constant(val)
    idx = @constants.index(val) || @constants.size
    @constants << val unless @constants.include?(val)
    idx
  end

  def emit(node, opcode, *operands)
    signature = OpCodes::DEFINITIONS[opcode]
    if signature
      if operands.size != signature.size && signature.last != OpCodes::T_REST && operands.size != signature.size - 1
        raise "Compiler Error: #{opcode} expects #{signature.size} args, got #{operands.size}"
      end
    end
    line_number = node.nil? ? -1 : node.line
    @code << [opcode, *operands]
    @line_info << line_number
  end

  # Returns the index of the instruction we just added
  # so we can patch it later.
  def emit_with_index(node, opcode, *operands)
    line_number = node.nil? ? -1 : node.line
    @code << [opcode, *operands]
    @line_info << line_number
    @code.size - 1
  end

  # Updates an operand of a previously emitted instruction
  # offset: the index returned by emit_with_index
  # operand_index: usually 1 (the first operand after the opcode)
  # value: the jump target
  def patch(offset, value, op_index = 1)
    # instruction is [OPCODE, OP1, OP2...]
    # We usually want to patch OP1, which is at index 1
    @code[offset][op_index] = value
  end

  def current_address
    @code.size
  end

  def disassemble
    @logger.debug("== #{@name} ==")
    @code.each_with_index do |ins, i|
      @logger.debug(sprintf("%04d  %-10s %s", i, ins[0], ins[1..-1].join(" ")))
    end
    @logger.debug("")
  end

  def to_h
    {
      name: @name,
      code: @code,
      constants: @constants.map do |c|
        v = c.is_a?(Chunk) ? c.to_h : c
        k = c.is_a?(Chunk) ? "chunks" : c.is_a?(String) ? "string" : "number"
        { k => v }
      end
    }
  end
end

