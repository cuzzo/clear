require_relative 'parser'

# An instruction / command for the VM to run
ByteCode = Struct.new(:op, :arg)

class Compiler
  def compile(ast)
    codes = []
    mem = {}
    procedures = {}

    ast.each do |node|
      compile_statement(node, codes, mem, procedures)
    end

    return codes
  end

  # A procedure body is itself bytecode.
  # Params live in their own memory slots; the body's statements compile against that frame.
  def compile_procedure(node_val, procedures)
    procedure_mem = {}
    node_val[:params].each { |param| procedure_mem[param] ||= procedure_mem.length }
    body = []
    node_val[:body].each { |stmt| compile_statement(stmt, body, procedure_mem, procedures) }
    { params: node_val[:params], codes: body }
  end

  def compile_statement(node, codes, mem, procedures)
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

    elsif node[:type] == :CallStatement
      node.val.each { |arg| compile_expression(arg, codes, mem, procedures) }
      codes << ByteCode.new(:CALL, procedures.fetch(node.var))

    elsif node[:type] == :If
      # IF is the first place we emit a forward jump.
      # We do not yet know how long the body will be, so we emit a placeholder
      # JUMP_IF_FALSE, remember its position, compile the body, then patch the
      # placeholder's target to point past the body. This is "patching".
      compile_expression(node.val[:condition], codes, mem, procedures)
      jump = codes.length
      codes << ByteCode.new(:JUMP_IF_FALSE)
      node.val[:body].each { |stmt| compile_statement(stmt, codes, mem, procedures) }
      codes[jump].arg = codes.length

    elsif node[:type] == :Return
      compile_expression(node.val, codes, mem, procedures)
      codes << ByteCode.new(:RETURN)

    elsif node[:type] == :Syscall
      codes << ByteCode.new(:LOAD, mem.fetch(node.var))
      codes << ByteCode.new(:SYSCALL, node.val)
    end
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

      # When a Math command, load the two numbers, tell the VM to send the math operator:
      when :Math
        # Recursively compile the left and right sides, then do math:
        compile_expression(expression.left, codes, mem, procedures)
        compile_expression(expression.right, codes, mem, procedures)
        codes << ByteCode.new(:MATH, expression.value)

      when :Equal
        compile_expression(expression.left, codes, mem, procedures)
        compile_expression(expression.right, codes, mem, procedures)
        codes << ByteCode.new(:COMPARE, :==)

      # When a call like `add_one(1)`, tell the VM to call the function.
      when :Call
        # `add_one(1)` could be `add_one(add_one(1))`
        procedure = procedures.fetch(expression.name)

        # We need to recursively compile each param
        # Params aren't guaranteed to be simple literals like `41`
        expression.args.each { |arg| compile_expression(arg, codes, mem, procedures) }
        codes << ByteCode.new(:CALL, procedure)
    end
  end
end
