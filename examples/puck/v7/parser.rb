require_relative 'tokenizer'

# Our AST Node holds the semantic meaning of a GROUP of tokens
AstNode = Struct.new(:type, :var, :val)
ExprNode = Struct.new(:type, :name, :value, :left, :right, :args, keyword_init: true)

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

  def parse
    return [parse_module] if @tokens[@pos]&.type == :MODULE

    parse_statements
  end

  def parse_statements(stop_type = nil)
    nodes = []
    stop_types = Array(stop_type)

    while @pos < @tokens.length && !stop_types.include?(@tokens[@pos].type)
      nodes << parse_statement
    end

    nodes
  end

  def parse_statement
    if @tokens[@pos].type == :MACRO
      parse_macro

    elsif @tokens[@pos].type == :PROCEDURE
      parse_procedure

    elsif @tokens[@pos].type == :IF
      parse_if

    elsif @tokens[@pos].type == :LOOP
      parse_loop

    elsif @tokens[@pos].type == :EXIT
      consume(:EXIT)
      consume(:OPERATOR) # ;
      AstNode.new(:Exit)

    elsif @tokens[@pos].type == :RETURN
      consume(:RETURN)
      expression = parse_expression
      consume(:OPERATOR) # ;
      AstNode.new(:Return, nil, expression)

    elsif @tokens[@pos][:type] == :SYSCALL
      consume(:SYSCALL)
      consume(:OPERATOR) # (
      syscall_id = consume(:INTEGER).value
      consume(:OPERATOR) # ,
      var = consume(:SYMBOL).value
      consume(:OPERATOR) # )
      consume(:OPERATOR) # ;
      AstNode.new(:Syscall, var, syscall_id)

    elsif @tokens[@pos].type == :SYMBOL
      name = consume(:SYMBOL).value

      if @tokens[@pos].value == ":="
        consume(:OPERATOR) # :=
        val = parse_expression
        consume(:OPERATOR) # ;
        AstNode.new(:Assignment, name, val)
      elsif @tokens[@pos].value == ";"
        consume(:OPERATOR) # ;
        AstNode.new(:CallStatement, name, [])
      else
        args = parse_call_args

        if @tokens[@pos]&.type == :DO
          consume(:DO)
          body = parse_statements(:END)
          consume(:END)
          consume(:OPERATOR) # ;
          AstNode.new(:MacroCall, name, { args: args, body: body })
        else
          consume(:OPERATOR) # ;
          AstNode.new(:CallStatement, name, args)
        end
      end

    else
      raise "Unexpected token #{@tokens[@pos].inspect}"
    end
  end

  def parse_module
    consume(:MODULE)
    name = consume(:SYMBOL).value
    consume(:OPERATOR) # ;
    declarations = parse_statements(:BEGIN)
    consume(:BEGIN)
    body = parse_statements(:END)
    consume(:END)
    consume(:OPERATOR) # .

    AstNode.new(:Module, name, { declarations: declarations, body: body })
  end

  def parse_macro
    consume(:MACRO)
    name = consume(:SYMBOL).value
    params = parse_params
    consume(:DO)
    body_param = consume(:SYMBOL).value
    consume(:END)
    consume(:OPERATOR) # ;
    template = parse_statements(:END)
    consume(:END)
    consume(:OPERATOR) # ;

    AstNode.new(:Macro, name, { params: params, body_param: body_param, template: template })
  end

  def parse_procedure
    consume(:PROCEDURE)
    name = consume(:SYMBOL).value
    params = parse_params
    consume(:OPERATOR) # ;
    body = parse_statements(:END)
    consume(:END)
    consume(:OPERATOR) # ;

    # For now, we store the node.val / payload of this AST Node as a hash
    node_val = { params: params, body: body }
    AstNode.new(:Procedure, name, node_val)
  end

  # `parse_if` handles both `IF ...` (the outer form) and `ELSIF ...` (the
  # nested form). For ELSIF the outer IF already owns the trailing `END;`,
  # so we skip those tokens.
  #
  # `IF x THEN ... ELSIF y THEN ... END;`
  # parses as
  # `If(x, body, else_body: [If(y, ...)])`
  # — i.e., ELSIF is literally a nested IF in the ELSE branch, with no
  # special AST node.
  def parse_if(keyword = :IF)
    consume(keyword)
    condition = parse_expression
    consume(:THEN)
    body = parse_statements([:ELSIF, :ELSE, :END])
    else_body = []

    if @tokens[@pos].type == :ELSIF
      else_body = [parse_if(:ELSIF)]
    elsif @tokens[@pos].type == :ELSE
      consume(:ELSE)
      else_body = parse_statements(:END)
    end

    if keyword == :IF
      consume(:END)
      consume(:OPERATOR) # ;
    end
    AstNode.new(:If, nil, { condition: condition, body: body, else_body: else_body })
  end

  def parse_loop
    consume(:LOOP)
    body = parse_statements(:END)
    consume(:END)
    consume(:OPERATOR) # ;
    AstNode.new(:Loop, nil, body)
  end

  def parse_params
    params = []
    consume(:OPERATOR) # (

    unless @tokens[@pos].value == ")"
      params << consume(:SYMBOL).value

      while @tokens[@pos].value == ","
        consume(:OPERATOR) # ,
        params << consume(:SYMBOL).value
      end
    end

    consume(:OPERATOR) # )
    params
  end

  def parse_call_args
    args = []
    consume(:OPERATOR) # (

    unless @tokens[@pos].value == ")"
      args << parse_expression

      while @tokens[@pos].value == ","
        consume(:OPERATOR) # ,
        args << parse_expression
      end
    end

    consume(:OPERATOR) # )
    args
  end

  # v4 supports all of our integer math operators.
  def parse_expression

    # Fisrt, grab the current term
    expression = parse_term

    while @tokens[@pos]&.type == :OPERATOR && ["+", "-", "*", "/", "%", "=", "<", "<=", ">", ">=", "#"].include?(@tokens[@pos].value)
      op = consume(:OPERATOR).value
      type = ["=", "<", "<=", ">", ">=", "#"].include?(op) ? :Compare : :Math
      expression = ExprNode.new(type: type, value: op.to_sym, left: expression, right: parse_term)
    end

    expression
  end

  def parse_term
    # If the current token is an Int:
    if @tokens[@pos].type == :INTEGER
      ExprNode.new(type: :Integer, value: consume(:INTEGER).value)

    # If the current token is a string:
    elsif @tokens[@pos].type == :STRING
      ExprNode.new(type: :String, value: consume(:STRING).value)

    # If the current token is a symbol (like `result`):
    elsif @tokens[@pos].type == :SYMBOL
      name = consume(:SYMBOL).value

      # If the next token is a `(`, it's a function call:
      if @tokens[@pos]&.type == :OPERATOR && @tokens[@pos].value == "("
        ExprNode.new(type: :Call, name: name, args: parse_call_args)

      # Otherwise, it's a simple variable:
      else
        ExprNode.new(type: :Variable, name: name)
      end

    # If we see anything else, it's a syntax error for now:
    else
      raise "Unexpected expression token #{@tokens[@pos].inspect}"
    end
  end
end
