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
        when :COMPARE then compare(code.arg, stack)

        # TAKE the value off the top of the stack, then store it in memory
        when :STORE then memory[code.arg] = stack.pop

        # For now, call procedures by popping the arguments and pushing the return value if there is one.
        when :CALL
          result = run_procedure(code.arg, stack)
          stack.push(result) unless result.nil?

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

  def run_procedure(procedure, stack)
    args = stack.pop(procedure[:params].length)
    memory = procedure[:params].zip(args).to_h
    run_statements(procedure[:body], memory)
  end

  def run_statements(nodes, memory)
    nodes.each do |node|
      if node.type == :Assignment
        memory[node.var] = run_expression(node.val, memory)

      elsif node.type == :Return
        return run_expression(node.val, memory)

      elsif node.type == :If
        run_statements(node.val[:body], memory) if run_expression(node.val[:condition], memory)

      elsif node.type == :Syscall
        puts "OUTPUT: #{memory.fetch(node.var)}"
      end
    end

    nil
  end

  def run_expression(expression, memory)
    case expression.type
      when :Integer then expression.value
      when :Variable then memory.fetch(expression.name)
      when :Add then run_expression(expression.left, memory) + run_expression(expression.right, memory)
      when :Equal then run_expression(expression.left, memory) == run_expression(expression.right, memory)
      when :Call then raise "Nested procedure calls are compiled before VM execution."
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
