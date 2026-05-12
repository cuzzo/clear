require 'strscan'

# Our token that holds semantic meaning from raw code
Token = Struct.new(:type, :value)

# Our AST Node holds the semantic meaning of a GROUP of tokens
AstNode = Struct.new(:type, :var, :val)

# An instruction / command for the VM to run
ByteCode = Struct.new(:op, :arg)

# 1. Tokenizer: Break raw puck code into semantic tokens
class Tokenizer
  def initialize(code)
    @scanner = StringScanner.new(code)
  end

  # Scan the raw code string until the end, extract tokens along the way
  def tokenize
    tokens = []
    until @scanner.eos?
      next if @scanner.skip(/\s+/) # Tokens are separated by whitespace

      if match = @scanner.scan(/\d+/)
        tokens << Token.new(:INTEGER, match.to_i)

      elsif match = @scanner.scan(/:=|[(),;]/)
        tokens << Token.new(:OPERATOR, match)

      elsif match = @scanner.scan(/SYSCALL|[a-zA-Z_]\w*/)
        type = match == "SYSCALL" ? :SYSCALL : :SYMBOL
        tokens << Token.new(type, match)
      else
        raise "Unexpected character #{@scanner.peek(1).inspect} at position #{@scanner.pos}"
      end
    end

    return tokens
  end
end

# 2. Parser: Parse semantic tokens into Language Constructs
class Parser
  def initialize(tokens)
    @tokens = tokens
    @pos = 0
  end

  # Take a token off the list
  def consume(type)
    t = @tokens[@pos]
    @pos += 1
    raise "Expected #{type}" unless t[:type] == type
    t
  end

  # For now, we only support SYSCALL to print
  def parse
    nodes = []

    # For now we only support SYMBOL and SYSCALL tokens
    # SYSCALL = PRINT
    # SYMBOL = 42
    while @pos < @tokens.length
      if @tokens[@pos].type == :SYMBOL
        var = consume(:SYMBOL).value
        consume(:OPERATOR) # :=
        val = consume(:INTEGER).value
        consume(:OPERATOR) # ;
        nodes << AstNode.new(:Assignment, var, val)

      elsif @tokens[@pos][:type] == :SYSCALL
        consume(:SYSCALL)
        consume(:OPERATOR) # (
        syscall_id = consume(:INTEGER).value
        consume(:OPERATOR) # ,
        var = consume(:SYMBOL).value
        consume(:OPERATOR) # )
        consume(:OPERATOR) # ;
        nodes << AstNode.new(:Syscall, var, syscall_id)
      else
        raise "Unexpected token #{@tokens[@pos].inspect}"
      end
    end

    return nodes
  end
end

class Compiler
  def compile(ast)
    codes = []
    mem = {}

    ast.each do |node|
      if node[:type] == :Assignment
        # Push a value onto the VM's stack (42)
        codes << ByteCode.new(:PUSH, node.val)
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
end

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

        # TAKE the value off the top of the stack, then store it in memory
        when :STORE then memory[code.arg] = stack.pop

        # For now, hardcode all SYSCALLs to PRINT / Ruby's `puts`.
        # We only support print for now, so we ignore the argument SYSCALL(1, x).
        # `1` is the SYSCALL id.  We ignore it for now.
        when :SYSCALL then puts "OUTPUT: #{stack.pop}"
      end
    end
  end
end

if __FILE__ == $PROGRAM_NAME
  code = "result := 42; SYSCALL(1, result);"
  tokens = Tokenizer.new(code).tokenize
  ast = Parser.new(tokens).parse
  bc = Compiler.new.compile(ast)

  VM.new.run(bc)
  # => OUTPUT: 42
end
