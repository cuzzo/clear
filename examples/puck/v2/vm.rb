require_relative 'compiler'

# Our VM is a Stack Machine
# ip = instruction pointer (where on the stack we are)
class VM
  def run(codes)
    stack = []
    memory = []
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

        # For now, call one-argument procedures by popping the argument and pushing the return value.
        when :CALL
          arg = stack.pop
          procedure_memory = { code.arg[:param] => arg }
          stack.push(run_expression(code.arg[:expression], procedure_memory))

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

  def run_expression(expression, memory)
    case expression[:type]
      when :Integer then expression[:value]
      when :Variable then memory.fetch(expression[:name])
      when :Add then run_expression(expression[:left], memory) + run_expression(expression[:right], memory)
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  code = "PROCEDURE add_one(x); RETURN x + 1; END; result := add_one(41); SYSCALL(1, result);"
  tokens = Tokenizer.new(code).tokenize
  ast = Parser.new(tokens).parse
  bc = Compiler.new.compile(ast)

  VM.new.run(bc)
  # => OUTPUT: 42
end
