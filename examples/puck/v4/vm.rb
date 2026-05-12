require_relative 'compiler'

# Our VM is a Stack Machine
# ip = instruction pointer (where on the stack we are)
class VM
  def run(program)
    run_codes(program[:codes], [], program[:procedures])
  end

  def run_codes(codes, memory, procedures)
    stack = []
    ip = 0

    while ip < codes.length
      code = codes[ip]
      ip += 1
      case code.op
        when :PUSH  then stack.push(code.arg)  # Add a value directly to the stack
        when :LOAD  then stack.push(memory[code.arg])  # Load a value from memory onto the stack
        when :MATH  then math(code.arg, stack)
        when :COMPARE then compare(code.arg, stack)
        when :JUMP then ip = code.arg
        when :JUMP_IF_FALSE then ip = code.arg unless stack.pop

        # TAKE the value off the top of the stack, then store it in memory
        when :STORE then memory[code.arg] = stack.pop

        # For now, call procedures by popping the arguments and pushing the return value if there is one.
        when :CALL
          result = run_procedure(code.arg, stack, procedures)
          stack.push(result) unless result.nil?

        when :RETURN then return stack.pop

        # For now, hardcode all SYSCALLs to PRINT / Ruby's `puts`.
        # We only support print for now, so we ignore the argument SYSCALL(1, x).
        # `1` is the SYSCALL id.  We ignore it for now.
        when :SYSCALL then puts "OUTPUT: #{stack.pop}"
      end
    end
  end

  def math(op, stack)
    right = stack.pop
    left = stack.pop
    stack.push(left.send(op, right))
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

  def run_procedure(procedure, stack, procedures)
    args = stack.pop(procedure[:params].length)
    memory = args
    run_codes(procedure[:codes], memory, procedures)
  end
end

if __FILE__ == $PROGRAM_NAME
  code = File.read(File.expand_path("example.puck", __dir__))
  tokens = Tokenizer.new(code).tokenize
  ast = Parser.new(tokens).parse
  program = Compiler.new.compile(ast)

  VM.new.run(program)
  # => OUTPUT: 42
end
