require_relative 'compiler'

# Our VM is a Stack Machine
# ip = instruction pointer (where on the stack we are)
class VM
  def run(codes, memory = [])
    stack = []
    ip = 0

    while ip < codes.length
      code = codes[ip]
      ip += 1
      case code.op
        when :PUSH    then stack.push(code.arg)                # Add a value directly to the stack
        when :LOAD    then stack.push(memory[code.arg])        # Load a value from memory onto the stack
        when :MATH    then math(code.arg, stack)
        when :COMPARE then compare(code.arg, stack)

        # The first jump we have.  JUMP_IF_FALSE pops the top of the stack and,
        # if it is false, sets the instruction pointer to the patched address.
        # Otherwise execution continues on the next instruction.
        when :JUMP_IF_FALSE then ip = code.arg unless stack.pop

        # TAKE the value off the top of the stack, then store it in memory
        when :STORE then memory[code.arg] = stack.pop

        # CALL runs a procedure's bytecode in its own memory frame.
        # The procedure's params live in slots 0..N-1 of the new memory, populated
        # from the top of the caller's stack. We push back whatever :RETURN gives
        # us (nil if the procedure ran off the end without RETURN, e.g. an
        # IF-only body).
        when :CALL
          procedure = code.arg
          args = stack.pop(procedure[:params].length)
          result = run(procedure[:codes], args)
          stack.push(result) unless result.nil?

        # :RETURN ends the inner `run` and hands the top of the stack back to the caller.
        when :RETURN then return stack.pop

        # For now, hardcode all SYSCALLs to PRINT / Ruby's `puts`.
        # We only support print for now, so we ignore the argument SYSCALL(1, x).
        # `1` is the SYSCALL id.  We ignore it for now.
        when :SYSCALL then puts "OUTPUT: #{stack.pop}"
      end
    end
  end

  def math(op, stack)
    if op == :+
      stack.push(stack.pop + stack.pop)
    else
      raise "Unexpected Math Operator."
    end
  end

  def compare(op, stack)
    right = stack.pop
    left = stack.pop

    if op == :==
      stack.push(left == right)
    else
      raise "Unexpected Compare Operator."
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  code = File.read(File.expand_path("example.puck", __dir__))
  tokens = Tokenizer.new(code).tokenize
  ast = Parser.new(tokens).parse
  bc = Compiler.new.compile(ast)

  VM.new.run(bc)
  # => OUTPUT: 42
end
