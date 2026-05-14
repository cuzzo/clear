require_relative 'tokenizer'

# Our AST Node holds the semantic meaning of a GROUP of tokens
AstNode = Struct.new(:type, :var, :val)
ExprNode = Struct.new(:type, :name, :value, :left, :right, :args, keyword_init: true)

# 2. Parser: Parse semantic tokens into Language Constructs
class Parser
  # `core_path`: if given, the file's tokens are auto-spliced into every
  # MODULE's declaration block, so every program implicitly has the standard
  # library available. See `auto_require_core`.
  def initialize(tokens, core_path: nil)
    @tokens = tokens
    @pos = 0
    @core_path = core_path
    @core_inlined = false
    @case_counter = 0  # used to generate fresh local names for CASE lowering
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
      if @tokens[@pos].type == :REQUIRE
        handle_require_directive
      else
        nodes << parse_statement
      end
    end

    nodes
  end

  # Explicit `REQUIRE "path";` — splice the named file's tokens at the
  # current position. Same mechanism as auto_require_core, just user-driven.
  def handle_require_directive
    consume(:REQUIRE)
    path = consume(:STRING).value
    consume(:OPERATOR) # ;
    inline_tokens_from(path)
  end

  # Auto-require: every MODULE implicitly has core.puck's declarations
  # available. Called once, immediately after `MODULE Name;` is parsed.
  def auto_require_core
    return if @core_path.nil? || @core_inlined
    return unless File.exist?(@core_path)
    @core_inlined = true
    inline_tokens(File.read(@core_path))
  end

  def inline_tokens_from(path)
    base = @core_path ? File.dirname(@core_path) : "."
    abs = File.expand_path(path, base)
    raise "REQUIRE: cannot find #{path}" unless File.exist?(abs)
    inline_tokens(File.read(abs))
  end

  def inline_tokens(source)
    sub_tokens = Tokenizer.new(source).tokenize
    @tokens = @tokens[0...@pos] + sub_tokens + @tokens[@pos..]
  end

  def parse_statement
    if @tokens[@pos].type == :MACRO
      parse_macro

    elsif @tokens[@pos].type == :PROCEDURE
      parse_procedure

    elsif @tokens[@pos].type == :IF
      parse_if

    elsif @tokens[@pos].type == :CASE
      parse_case

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
      elsif @tokens[@pos].value == "["
        # Indexed write: name[index] := value;
        consume(:OPERATOR) # [
        index = parse_expression
        consume(:OPERATOR) # ]
        consume(:OPERATOR) # :=
        val = parse_expression
        consume(:OPERATOR) # ;
        AstNode.new(:ArraySet, name, { index: index, val: val })
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
    auto_require_core   # core.puck's declarations get spliced in here
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
    parsed = parse_params  # macros don't have VAR; we ignore parsed[:var]
    consume(:DO)
    body_param = consume(:SYMBOL).value
    consume(:END)
    consume(:OPERATOR) # ;
    template = parse_statements(:END)
    consume(:END)
    consume(:OPERATOR) # ;

    AstNode.new(:Macro, name, { params: parsed[:names], body_param: body_param, template: template })
  end

  def parse_procedure
    consume(:PROCEDURE)
    name = consume(:SYMBOL).value
    parsed = parse_params
    consume(:OPERATOR) # ;
    body = parse_statements(:END)
    consume(:END)
    consume(:OPERATOR) # ;

    # `params` stays a list of strings to keep the AST shape compatible with
    # earlier versions. The VAR-marked subset is stored in a parallel field.
    node_val = { params: parsed[:names], var_params: parsed[:var], body: body }
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

  # CASE expr OF v1: stmts | v2: stmts ... ELSE stmts END;
  #
  # Lowered to: __case_N := expr; IF __case_N = v1 THEN stmts ELSE IF ...
  # Wrapped in a :Block so a single statement-position parse can produce
  # multiple statements. (The Block AST node is transparent — the compiler
  # and macro_expander unwrap it.)
  def parse_case
    consume(:CASE)
    subject = parse_expression
    consume(:OF)

    arms = []
    loop do
      val = parse_term
      consume(:OPERATOR) # :
      body = []
      until @pos >= @tokens.length ||
            @tokens[@pos].type == :ELSE ||
            @tokens[@pos].type == :END ||
            (@tokens[@pos].type == :OPERATOR && @tokens[@pos].value == "|")
        body << parse_statement
      end
      arms << { value: val, body: body }
      break unless @tokens[@pos].type == :OPERATOR && @tokens[@pos].value == "|"
      consume(:OPERATOR) # |
    end

    else_body = []
    if @tokens[@pos].type == :ELSE
      consume(:ELSE)
      else_body = parse_statements(:END)
    end
    consume(:END)
    consume(:OPERATOR) # ;

    temp_name = "__case_#{@case_counter}"
    @case_counter += 1
    init = AstNode.new(:Assignment, temp_name, subject)
    if_chain = build_case_if_chain(temp_name, arms, else_body)
    AstNode.new(:Block, nil, [init] + if_chain)
  end

  def build_case_if_chain(temp_name, arms, else_body)
    return else_body if arms.empty?
    first, *rest = arms
    cond = ExprNode.new(
      type: :Compare,
      value: :"=",
      left: ExprNode.new(type: :Variable, name: temp_name),
      right: first[:value]
    )
    rest_chain = build_case_if_chain(temp_name, rest, else_body)
    [AstNode.new(:If, nil, {
      condition: cond,
      body: first[:body],
      else_body: rest_chain
    })]
  end

  # Returns { names: ["a", "b", ...], var: ["a"] } — `var` is the subset of
  # names preceded by the VAR keyword (pass-by-reference).
  def parse_params
    names = []
    var_set = []
    consume(:OPERATOR) # (

    unless @tokens[@pos].value == ")"
      parse_one_param(names, var_set)

      while @tokens[@pos].value == ","
        consume(:OPERATOR) # ,
        parse_one_param(names, var_set)
      end
    end

    consume(:OPERATOR) # )
    { names: names, var: var_set }
  end

  def parse_one_param(names, var_set)
    if @tokens[@pos].type == :VAR
      consume(:VAR)
      name = consume(:SYMBOL).value
      names << name
      var_set << name
    else
      names << consume(:SYMBOL).value
    end
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
    # `ARRAY(size)` -- a built-in expression that allocates a fixed-size
    # heap-backed array. Lives in expression position so you can write
    #   nums := ARRAY(10);
    if @tokens[@pos].type == :ARRAY
      consume(:ARRAY)
      consume(:OPERATOR) # (
      size = parse_expression
      consume(:OPERATOR) # )
      return ExprNode.new(type: :ArrayAlloc, value: size)

    elsif @tokens[@pos].type == :LEN
      # `LEN(x)` — length of any heap-allocated value (string or array).
      consume(:LEN)
      consume(:OPERATOR) # (
      arg = parse_expression
      consume(:OPERATOR) # )
      return ExprNode.new(type: :Length, value: arg)

    elsif @tokens[@pos].type == :INPUT
      # `INPUT()` — read one line from stdin, return as a string.
      consume(:INPUT)
      consume(:OPERATOR) # (
      consume(:OPERATOR) # )
      return ExprNode.new(type: :Input)

    elsif @tokens[@pos].type == :TIME
      # `TIME()` — monotonic clock in milliseconds.
      consume(:TIME)
      consume(:OPERATOR) # (
      consume(:OPERATOR) # )
      return ExprNode.new(type: :Time)

    # Parenthesized expression — grouping for precedence override.
    elsif @tokens[@pos].type == :OPERATOR && @tokens[@pos].value == "("
      consume(:OPERATOR) # (
      expr = parse_expression
      consume(:OPERATOR) # )
      return expr

    # If the current token is an Int:
    elsif @tokens[@pos].type == :INTEGER
      ExprNode.new(type: :Integer, value: consume(:INTEGER).value)

    # If the current token is a Float (e.g. 3.14):
    elsif @tokens[@pos].type == :FLOAT
      ExprNode.new(type: :Float, value: consume(:FLOAT).value)

    # If the current token is a string:
    elsif @tokens[@pos].type == :STRING
      ExprNode.new(type: :String, value: consume(:STRING).value)

    # If the current token is a symbol (like `result`):
    elsif @tokens[@pos].type == :SYMBOL
      name = consume(:SYMBOL).value

      if @tokens[@pos]&.type == :OPERATOR && @tokens[@pos].value == "("
        # `name(...)` is a function call.
        ExprNode.new(type: :Call, name: name, args: parse_call_args)

      elsif @tokens[@pos]&.type == :OPERATOR && @tokens[@pos].value == "["
        # `name[expr]` is an indexed read.
        consume(:OPERATOR) # [
        index = parse_expression
        consume(:OPERATOR) # ]
        ExprNode.new(type: :ArrayGet, name: name, value: index)

      else
        # Otherwise, it's a simple variable:
        ExprNode.new(type: :Variable, name: name)
      end

    # If we see anything else, it's a syntax error for now:
    else
      raise "Unexpected expression token #{@tokens[@pos].inspect}"
    end
  end
end
