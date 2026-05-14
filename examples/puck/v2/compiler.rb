require_relative 'parser'

# An instruction / command for the VM to run
ByteCode = Struct.new(:op, :arg)

class Compiler
  def compile(ast)
    codes = []
    mem = {}
    procedures = {}

    ast.each do |node|
      if node[:type] == :Procedure
        procedures[node.var] = compile_procedure(node.val, procedures)

      elsif node[:type] == :Assignment
        # Push the current expression onto the VM's stack
        # Can be more than just hardcoded literals like `42`
        # It could be something like: `add_one(41)`.
        compile_expression(node.val, codes, mem, procedures)

        # Store that value in memory (x = 42)
        # In the example, `x` is the variable - all it does it point into the VM's memory
        codes << ByteCode.new(:STORE, mem[node.var] ||= mem.length)

      elsif node[:type] == :Syscall
        codes << ByteCode.new(:LOAD, mem.fetch(node.var))
        codes << ByteCode.new(:SYSCALL, node.val)
      end
    end

    return codes
  end

  # A procedure body is itself bytecode.
  # Its first instructions read the single parameter from its own memory slot 0.
  # Its last instruction is :RETURN, which pops the top of the stack and gives it
  # back to the caller.
  def compile_procedure(node_val, procedures)
    procedure_mem = { node_val[:param] => 0 }
    body = []
    compile_expression(node_val[:expression], body, procedure_mem, procedures)
    body << ByteCode.new(:RETURN)
    { params: [node_val[:param]], codes: body }
  end

  # This is a recursive function
  # Abstract Syntax Trees that we are compiling are... Trees
  # They are recursive structures
  # This can be hard to walk through
  def compile_expression(expression, codes, mem, procedures)
    case expression.type
      # When a literal integer, our simple case from before `42`, push the value directly:
      when :Integer
        codes << ByteCode.new(:PUSH, expression.value)

      # When a variable, load the value of the variable `result`:
      when :Variable
        codes << ByteCode.new(:LOAD, mem.fetch(expression.name))

      # When an Add command, load the two numbers, tell the VM to add them [:MATH, :+]:
      when :Add
        # Recursively compile the left and right sides, then add them:
        compile_expression(expression.left, codes, mem, procedures)
        compile_expression(expression.right, codes, mem, procedures)
        codes << ByteCode.new(:MATH, :+)

      # When a call like `add_one(1)`, tell the VM to call the function.
      when :Call
        # `add_one(1)` could be `add_one(add_one(1))`
        procedure = procedures.fetch(expression.name)

        # We need to recursively compile each param
        # Params aren't guaranteed to be simple literals like `41`
        compile_expression(expression.arg, codes, mem, procedures)
        codes << ByteCode.new(:CALL, procedure)
    end
  end
end
