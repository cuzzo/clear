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
        when :PUSH  then stack.push(code.arg)  # Add a value directly to the stack
        when :LOAD  then stack.push(memory[code.arg])  # Load a value from memory onto the stack
        when :MATH  then math(code.arg, stack)

        # TAKE the value off the top of the stack, then store it in memory
        when :STORE then memory[code.arg] = stack.pop

        # CALL runs a procedure's bytecode in its own memory frame.
        # The procedure's params live in slots 0..N-1 of the new memory, populated
        # from the top of the caller's stack. We push back whatever :RETURN gives us.
        when :CALL
          procedure = code.arg
          args = stack.pop(procedure[:params].length)
          stack.push(run(procedure[:codes], args))

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
end

if __FILE__ == $PROGRAM_NAME
  code = File.read(File.expand_path("example.puck", __dir__))
  tokens = Tokenizer.new(code).tokenize
  ast = Parser.new(tokens).parse
  bc = Compiler.new.compile(ast)

  VM.new.run(bc)
  # => OUTPUT: 42
end
