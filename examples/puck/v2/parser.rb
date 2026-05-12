require_relative 'tokenizer'

# Our AST Node holds the semantic meaning of a GROUP of tokens
AstNode = Struct.new(:type, :var, :val)

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

    # We now support PROCEDURE, as well as SYMBOL and SYSCALL tokens
    while @pos < @tokens.length
      if @tokens[@pos].type == :PROCEDURE
        nodes << parse_procedure

      elsif @tokens[@pos].type == :SYMBOL
        var = consume(:SYMBOL).value
        consume(:OPERATOR) # :=
        val = parse_expression
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

  # For now, we only parse 1 argument, and 1 statement
  # Next, we will parse arguments and function bodies / statements with loops
  def parse_procedure
    consume(:PROCEDURE)
    name = consume(:SYMBOL).value
    consume(:OPERATOR) # (
    param = consume(:SYMBOL).value # get the one argument
    consume(:OPERATOR) # )
    consume(:OPERATOR) # ;
    consume(:RETURN)
    expression = parse_expression  # parse the body
    consume(:OPERATOR) # ;
    consume(:END)
    consume(:OPERATOR) # ;

    # For now, we store the node.val / payload of this AST Node as a hash
    node_val = { param: param, expression: expression }
    AstNode.new(:Procedure, name, node_val)
  end

  # For now, we only support the + operator
  # It is trivial to add the other operators, but we will take this one step at a time
  def parse_expression

    # Fisrt, grab the current term
    expression = parse_term

    # If we see the add operator, we translate to an :Add command for the Compiler
    if @tokens[@pos]&.type == :OPERATOR && @tokens[@pos].value == "+"
      consume(:OPERATOR) # +
      expression = { type: :Add, left: expression, right: parse_term }
    end

    expression
  end

  def parse_term
    # If the current token is an Int:
    if @tokens[@pos].type == :INTEGER
      { type: :Integer, value: consume(:INTEGER).value }

    # If the current token is a symbol (like `result`):
    elsif @tokens[@pos].type == :SYMBOL
      name = consume(:SYMBOL).value

      # If the next token is a `(`, it's a function call:
      if @tokens[@pos]&.type == :OPERATOR && @tokens[@pos].value == "("
        consume(:OPERATOR) # (
        arg = parse_expression
        consume(:OPERATOR) # )
        { type: :Call, name: name, arg: arg }

      # Otherwise, it's a simple variable:
      else
        { type: :Variable, name: name }
      end

    # If we see anything else, it's a syntax error for now:
    else
      raise "Unexpected expression token #{@tokens[@pos].inspect}"
    end
  end
end

