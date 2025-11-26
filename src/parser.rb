require_relative "./ast"

# ==========================================
# PARSER
# ==========================================
class Parser
  def initialize(tokens); @tokens = tokens; @pos = 0; end

  def parse
    stmts = []
    stmts << parse_statement() while current.type != :EOF
    AST::Program.new(stmts)
  end

  private
  def current; @tokens[@pos]; end

  def consume(type, value=nil)
    # 1. Capture the current token BEFORE moving the pointer
    token = current

    # 2. Validate it matches what we expect
    if (token.type == type) || (value && token.value == value)
      if value && token.value != value
         raise "Expected value '#{value}', got '#{token.value}'"
      end

      # 3. Advance the pointer
      @pos += 1

      # 4. RETURN THE CAPTURED TOKEN (Not 'current', which is now the next one!)
      token
    else
      raise "Expected #{value || type}, got #{token.value} (#{token.type}) line #{token.line}"
    end
  end

  def match?(type, val=nil)
    current.type == type && (val.nil? || current.value == val)
  end

  def parse_statement
    if match?(:KEYWORD, 'VAR') then parse_var_declare();
    elsif match?(:KEYWORD, 'SET') then parse_set_var();
    elsif match?(:KEYWORD, 'FN') then parse_function_def();
    elsif match?(:KEYWORD, 'IF') then parse_if_statement();
    elsif match?(:KEYWORD, 'WHILE') then parse_while_loop();
    elsif match?(:KEYWORD, 'STRUCT') then parse_struct_def();
    elsif match?(:KEYWORD, 'RETURN') then parse_return();
    elsif match?(:KEYWORD, 'ASSERT') then parse_assert();
    elsif match?(:KEYWORD, 'RAISE') then parse_raise();
    elsif match?(:HEWORD, 'EXIT') then parse_exit();
    else
      expr = parse_expression
      consume(:CHAR, ';')
      expr
    end
  end

  def parse_assert()
    consume(:KEYWORD)

    # 1. Parse the Condition
    condition = parse_expression

    # 2. Parse Optional Message
    message = "Assertion Failed"
    if match?(:CHAR, ',')
      consume(:CHAR)
      # For simplicity v1, strict string literal.
      # (For v2, use parse_expression to allow dynamic strings)
      message = consume(:STRING).value
    end

    consume(:CHAR, ';')
    AST::Assert.new(condition, message)
  end

  def parse_raise()
   consume(:KEYWORD)

   message_expr = nil

   # Check for optional message expression
   if !match?(:CHAR, ';')
     message_expr = parse_expression
   end

   consume(:CHAR, ';')
   AST::Raise.new(message_expr)
  end

  def parse_exit()
    consume(:KEYWORD)
    # Check for optional context message
    # (Look ahead: if it's a string or variable, parse it)
    # We assume EXIT is followed by an expression if not ')' or ';' or 'END'
    context_expr = nil
    if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
    # unless ['}', ')', ';', 'END'].include?(current.value)
       context_expr = parse_primary
    end

    # Store the context in the ThrowNode
    byebug
    rhs = AST::ThrowNode.new(context_expr)
  end

  def parse_return()
    consume(:KEYWORD)
    val = parse_expression
    consume(:CHAR, ';')
    AST::ReturnNode.new(val)
  end

  def parse_set_var()
    consume(:KEYWORD)
    name = consume(:VAR_ID).value
    consume(:CHAR, '=')
    val = parse_expression
    consume(:CHAR, ';')
    AST::Assignment.new(name, val)
  end

  def parse_var_declare()
    consume(:KEYWORD)
    name = consume(:VAR_ID).value
    type_node = :Any
    if match?(:CHAR, ':')
      consume(:CHAR)
      type_node = parse_type_annotation.to_sym
    end
    consume(:CHAR, '=')
    val = parse_expression
    consume(:CHAR, ';')
    AST::VarDecl.new(name, type_node, val)
  end

  def parse_argument_list()
    parse_comma_seq(:CHAR, '(', ')') do
      p_name = consume(:VAR_ID).value
      p_type = :Any

      if match?(:CHAR, ":")
        consume(:CHAR)
        p_type = parse_type_annotation
      end

      { name: p_name, type: p_type }
    end
  end

  def parse_function_def
    consume(:KEYWORD, 'FN')
    name = consume(:VAR_ID).value
    consume(:PERCENT, '%')

    # 1. Parse Params
    params = parse_argument_list

    # 2. Parse USE() UpValues
    captures = []
    if current.value == 'USE'
      consume(:KEYWORD)
      captures = parse_argument_list()
    end

    # 3. Parse optional RETURNS
    return_type = :Any
    if current.value == 'RETURNS'
      consume(:KEYWORD)
      return_type = parse_type_annotation.to_sym
    end

    consume(:ARROW, '->')
    body = []
    until match?(:KEYWORD, 'END') || match?(:KEYWORD, 'CATCH')
      stmt = parse_statement()
      body << stmt if stmt # Handle nil from STRUCT skip
    end

    # 2. Parse Optional CATCH block
    catch_body = []
    catch_var = nil
    if match?(:KEYWORD, 'CATCH')
      consume(:KEYWORD)
      catch_var = consume(:VAR_ID).value # Capture 'e' in CATCH e

      until match?(:KEYWORD, 'END')
        stmt = parse_statement()
        catch_body << stmt if stmt
      end
    end

    consume(:KEYWORD, 'END')
    AST::FunctionDef.new(name, params, captures, return_type, body, catch_body, catch_var)
  end

  def parse_expression
    lhs = parse_primary
    while AST::BINARY_OPS.include?(current.value) || current.value == 'OR'
      op = current.value
      consume(current.type)
      rhs = nil
      if op == 'OR'
        rhs = parse_or_rescue
        lhs = AST::BinaryOp.new(lhs, :OR_RESCUE, rhs)
      else
        #current.type == :SMOOTH ? consume(:SMOOTH) : consume(:CHAR)
        rhs = parse_primary
        lhs = AST::BinaryOp.new(lhs, op, rhs)
      end
    end
    lhs
  end

  def parse_or_rescue
    if match?(:KEYWORD, 'RETURN')
      # Syntax: ... OR RETURN
      # Meaning: Return the error object to the caller
      consume(:KEYWORD)
      rhs = AST::ReturnNode.new(nil) # Nil value implies "Use the Pipe Result"

    elsif match?(:KEYWORD, 'EXIT')
      # Syntax: ... OR EXIT
      # Meaning: Throw the error object (triggering local CATCH)
      consume(:KEYWORD)
      context = nil

      # CRITICAL FIX: Look ahead for the context string
      if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
         context = parse_primary
      end
      rhs = AST::ThrowNode.new(context) # Nil value implies "Use the Pipe Result"

    elsif match?(:KEYWORD, 'ELSE')
      # Syntax: ... OR ELSE value
      # Meaning: Replace the error with a default value
      consume(:KEYWORD)
      rhs = parse_primary # Parse the value (e.g., 0 or "default")

    else
      # Syntax: ... OR expression
      # Standard OR behavior
      rhs = parse_primary
    end
  end

  def parse_unary
    v = current.value
    if AST::UNARY_OPS.include?(v)
      consume(:CHAR)
      # Recursively parse the thing being negated (handles --5)
      right = parse_unary
      return AST::UnaryOp.new(AST::OP_TO_OP_CODE[v], right)
    end

    parse_primary
  end

  def parse_var_id
    name = consume(:VAR_ID).value
    if match?(:CHAR, '(')
       args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
       node = AST::FuncCall.new(name, args)
    else
       node = AST::Identifier.new(name)
    end

    # 2. Suffix Loop: Handle .method(), .field, and [index]
    loop do
      if match?(:CHAR, '.')
        consume(:CHAR)
        member = consume(:VAR_ID).value

        if match?(:CHAR, '(')
          # It's a Method Call: x.pop()
          args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
          node = AST::MethodCall.new(node, member, args)
        else
          # It's a Field Access: x.name (New!)
          # We need a new AST node for this, or treat it as "Get Field"
          node = AST::GetField.new(node, member)
        end

      elsif match?(:CHAR, '[')
        # It's an Index Access: x[0] (New!)
        consume(:CHAR, '[')
        index_expr = parse_expression
        consume(:CHAR, ']')
        node = AST::GetIndex.new(node, index_expr)

      else
        # No more suffixes, we are done.
        break
      end
    end
    return node
  end

  def parse_if_statement
    consume(:KEYWORD, 'IF')
    parse_if_chain
  end

  def parse_if_chain
    condition = parse_expression
    consume(:KEYWORD, 'THEN')

    # 2. Parse 'THEN' Block
    then_branch = []
    until match?(:KEYWORD, 'ELSE') || match?(:KEYWORD, 'ELSE_IF') || match?(:KEYWORD, 'END')
      stmt = parse_statement()
      then_branch << stmt if stmt
    end

    # 3. Parse Optional 'ELSE' Block
    else_branch = []
    if match?(:KEYWORD, 'ELSE_IF')
      consume(:KEYWORD, 'ELSE_IF')
      # We recurse! We treat the ELSIF as the start of a new IF node.
      # This new node becomes the single statement inside our 'else_branch'.
      # Note: We do NOT consume 'END' here, the recursion handles it.
      nested_if = parse_if_chain
      else_branch << nested_if

    elsif match?(:KEYWORD, 'ELSE')
      consume(:KEYWORD)
      until match?(:KEYWORD, 'END')
        stmt = parse_statement()
        else_branch << stmt if stmt
      end
      consume(:KEYWORD, 'END') # The chain finally ends here
    else
      consume(:KEYWORD, 'END')
    end

    AST::IfStatement.new(condition, then_branch, else_branch)
  end

  def parse_while_loop
    consume(:KEYWORD, 'WHILE')
    condition = parse_expression
    consume(:KEYWORD, 'DO')

    # Parse 'DO' Block
    do_branch = []
    until match?(:KEYWORD, 'END')
      stmt = parse_statement()
      do_branch << stmt if stmt
    end

    consume(:KEYWORD, 'END')
    AST::WhileLoop.new(condition, do_branch)
  end

  def parse_struct_def
    consume(:KEYWORD)
    name = consume(:TYPE_ID).value
    consume(:CHAR, '{')

    fields = {}

    # Parse fields: name: Type, name: Type...
    until match?(:CHAR, '}')
       field_name = consume(:VAR_ID).value
       consume(:CHAR, ':')
       field_type = parse_type_annotation

       fields[field_name] = field_type

       consume(:CHAR, ',') if match?(:CHAR, ',')
    end

    consume(:CHAR, '}')

    # Return a new AST Node (Make sure to add StructDef to AST module!)
    AST::StructDef.new(name, fields)
  end

  def parse_primary
    return AST::Literal.new(:NUMBER, consume(:NUMBER).value) if match?(:NUMBER)
    return AST::Literal.new(:STRING, consume(:STRING).value) if match?(:STRING)

    # CAST LOGIC
    if current.value == 'CAST'
      return parse_cast()

    elsif match?(:PERCENT)
      return parse_sigil_construct()

    elsif match?(:KEYWORD, 'TRUE')
      consume(:KEYWORD)
      return AST::Literal.new(:BOOLEAN, true)

    elsif match?(:KEYWORD, 'FALSE')
      consume(:KEYWORD)
      return AST::Literal.new(:BOOLEAN, false)

    elsif match?(:KEYWORD, 'NIL')
      consume(:KEYWORD)
      return AST::Literal.new(:NIL, nil)

    elsif current.value == '-' || current.value == '!'
      return parse_unary()

    elsif match?(:VAR_ID)
      return parse_var_id()
    end

    raise "Unexpected token #{current.value} (#{current.type}) line #{current.line}"
  end

  def parse_cast
    consume(current.type) # CAST
    consume(:CHAR, '(')

    val = parse_expression

    if current.value != 'AS'
      raise "Expected AS, got #{current.value}"
    end
    consume(current.type) # AS
    target = parse_type_annotation
    consume(:CHAR, ')')
    return AST::Cast.new(val, target)
  end

  def parse_sigil_construct
    consume(:PERCENT)
    if match?(:TYPE_ID)
      name = consume(:TYPE_ID).value
      fields = parse_comma_seq(:CHAR, '{', '}') do
        k = consume(:VAR_ID).value; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::StructLit.new(name, fields.to_h)
    elsif match?(:CHAR, '[')
      items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
      return AST::ListLit.new(items)
    elsif match?(:CHAR, '{')
      pairs = parse_comma_seq(:CHAR, '{', '}') do
        k = parse_expression; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::HashLit.new(pairs.to_h)
    elsif match?(:CHAR, '(')
      params = parse_argument_list
      captures = []
      if match?(:KEYWORD, 'USE')
        consume(:KEYWORD)
        captures = parse_argument_list
      end
      consume(:ARROW, '->')
      # TODO - Lambdas can be multiple statements...
      body = parse_expression
      consume(:CHAR, ';')
      return AST::Lambda.new(params, captures, body)
    end
  end

  def parse_type_annotation
    base = consume(:TYPE_ID).value
    if match?(:CHAR, '[')
      consume(:CHAR, '[')
      inner = parse_type_annotation
      consume(:CHAR, ']')
      return "#{base}[#{inner}]"
    end
    base
  end

  def parse_comma_seq(type, open, close)
    consume(type, open)
    items = []
    until match?(:CHAR, close)
      items << yield
      consume(:CHAR, ',') if match?(:CHAR, ',')
    end
    consume(:CHAR, close)
    items
  end
end

