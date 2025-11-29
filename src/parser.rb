require_relative "./ast"

# ==========================================
# PARSER
# ==========================================
class Parser
  @@stmt_rules = {}
  @@primary_rules = {}
  @@suffix_rules = {}

  def self.stmt(type, value, node_class = nil, pattern = nil, &block)
    if pattern
      # If pattern provided, create a block that runs the engine
      @@stmt_rules[[type, value]] = lambda do
        args = process_pattern(pattern)
        node_class.new(current.line, *args)
      end
    else
      @@stmt_rules[[type, value]] = block
    end
  end

  def self.primary(type, value=nil, node_class = nil, pattern = nil,  &block)
    if pattern
      # If pattern provided, create a block that runs the engine
      @@primary_rules[[type, value]] = lambda do
        args = process_pattern(pattern)
        node_class.new(current.line, *args)
      end
    else
      @@primary_rules[[type, value]] = block
    end
  end

  def self.suffix(type, value, &block)
    @@suffix_rules[[type, value]] = block
  end

  def initialize(tokens); @tokens = tokens; @pos = 0; end

  def parse
    stmts = []
    stmts << parse_statement() while current.type != :EOF
    AST::Program.new(current.line, stmts)
  end

  def peek
    @tokens[@pos + 1] || Token.new(:EOF, "", current.line)
  end

  private

  # COMMANDS
  stmt(:KEYWORD, 'VAR', AST::VarDecl, ['VAR', :VAR_ID, {':' => :type_annotation}, '=', :expression, ';'])
  stmt(:KEYWORD, 'SET') { parse_set_var }  #, AST::Assignment, ['SET', :VAR_ID, '=', :expression, ';'])
  stmt(:KEYWORD, 'FN') { parse_function_def }
  stmt(:KEYWORD, 'IF') { parse_if_statement }
  stmt(:KEYWORD, 'STRUCT', AST::StructDef, ['STRUCT', :TYPE_ID, :struct_body])
  stmt(:KEYWORD, 'WHILE', AST::WhileLoop, ['WHILE', :expression, 'DO', :stmts_until_end, 'END'])
  stmt(:KEYWORD, 'RETURN', AST::ReturnNode, ['RETURN', :expression, ';'])
  stmt(:KEYWORD, 'ASSERT', AST::Assert, ['ASSERT', :expression, {',' => :STRING}, ';'])
  stmt(:KEYWORD, 'RAISE', AST::Raise, ['RAISE', :raise_msg, ';'])
  stmt(:KEYWORD, 'EXIT') { parse_exit }
  stmt(:KEYWORD, 'DIE') { parse_die }
  stmt(:KEYWORD, 'BREAK', AST::BreakNode, ['BREAK', ';'])
  stmt(:KEYWORD, 'CONTINUE', AST::ContinueNode, ['CONTINUE', ';'])

  # Primaries
  primary(:NUMBER) { AST::Literal.new(current.line, :NUMBER, consume(:NUMBER).value) }
  primary(:STRING) { AST::Literal.new(current.line, :STRING, consume(:STRING).value) }
  primary(:VAR_ID) { parse_var_id }

  primary(:KEYWORD, 'TRUE') { consume(:KEYWORD); AST::Literal.new(current.line, :BOOLEAN, true) }
  primary(:KEYWORD, 'FALSE') { consume(:KEYWORD); AST::Literal.new(current.line, :BOOLEAN, false) }
  primary(:KEYWORD, 'NIL') { consume(:KEYWORD); AST::Literal.new(current.line, :NIL, nil) }
  primary(:KEYWORD, 'CAST', AST::Cast, ['CAST', '(', :expression, 'AS', :type_annotation, ')'])
  primary(:PERCENT, '%') { parse_sigil_construct }

  # Array Indexing: arr[index]
  suffix(:CHAR, '[') do |lhs|
    consume(:CHAR, '[')
    index = parse_expression
    consume(:CHAR, ']')
    AST::GetIndex.new(current.line, lhs, index)
  end

  # Dot Access: obj.field OR obj.method()
  suffix(:CHAR, '.') do |lhs|
    consume(:CHAR, '.')
    name = consume(:VAR_ID).value

    if match?(:CHAR, '(')
      # Method Call
      args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      AST::MethodCall.new(current.line, lhs, name, args)
    else
      # Field Access
      AST::GetField.new(current.line, lhs, name)
    end
  end

  # Functor/Call: myVar()
  suffix(:CHAR, '(') do |lhs|
    args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    # FIX: Pass 'lhs' (the node), not 'lhs.name'
    AST::FuncCall.new(current.line, lhs, args)
  end

  ## START PATTERN DSL
  def process_pattern(pattern)
    captures = []

    pattern.each do |item|
      case item
      # RULE 1: String Literal -> Match & Ignore
      # Example: '=', ';'
      when String
        consume_literal(item)

      # RULE 2: Hash -> Optional
      # Example: { ':' => :type_annotation }
      when Hash
        trigger, action = item.first # Get key/value pair

        if match_literal!(trigger)
          captures << run_action(action)
        else
          captures << :Any
        end

      # RULE 3: Symbol -> Capture Token or Run Method
      when Symbol
        captures << run_action(item)
      end
    end

    captures
  end

  def run_action(item)
    # Convention: :UPPER_CASE is a Token Type to eat
    return consume(item).value if item == item.upcase
    # :down_case => parse function to run
    return send("parse_#{item}")
  end

  # Helpers for the literals (Keywords or Chars)
  def consume_literal(val)
    # Heuristic: Letters = Keyword, Symbols = Char
    type = val.match?(/[a-zA-Z]/) ? :KEYWORD : :CHAR
    consume(type, val)
  end

  def match_literal!(val)
    type = val.match?(/[a-zA-Z]/) ? :KEYWORD : :CHAR
    match!(type, val)
  end
  ## END PATTERN DSL


  def current
    @tokens[@pos]
  end

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

  # Match and immediately eat
  def match!(type, value=nil)
    if match?(type, value)
      consume(type) # We already know it matches, so this is safe
    else
      false
    end
  end

  def parse_statement
    rule = @@stmt_rules[[current.type, current.value]]
    return instance_exec(&rule) if rule
    expr = parse_expression
    consume(:CHAR, ';')
    expr
  end

  def parse_set_var
    consume(:KEYWORD, 'SET')

    # 1. Parse the Target (L-Value)
    # parse_var_id handles "x", "x.y", "x[0]", "x.y[1]", etc.
    target = parse_var_id

    # Optional: Validation (Prevent "SET f() = 1")
    unless target.is_a?(AST::Identifier) ||
           target.is_a?(AST::GetField) ||
           target.is_a?(AST::GetIndex)
       raise "Syntax Error: Invalid assignment target on line #{current.line}"
    end

    consume(:CHAR, '=')
    value = parse_expression
    consume(:CHAR, ';')

    # 2. Return Assignment Node
    # Note: 'target' is now a Node, not just a String name.
    # Your Compiler already handles this!
    AST::Assignment.new(current.line, target, value)
  end

  def parse_exit()
    consume(:KEYWORD)
    context_expr = nil
    if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
      context_expr = parse_primary
    end
    match!(:CHAR, ";") # TDOO: Test
    AST::ThrowNode.new(current.line, context_expr)
  end

  def parse_die()
    consume(:KEYWORD)
    context_expr = nil

    if match!(:CHAR, ';')
      status = AST::Literal.new(current.line, :NUMBER, 1)
    else
      status = parse_expression
      consume(:CHAR, ';')
    end

    AST::DieNode.new(current.line, status)
  end

  def parse_argument_list()
    parse_comma_seq(:CHAR, '(', ')') do
      p_name = consume(:VAR_ID).value
      p_type = :Any

      if match!(:CHAR, ":")
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
    if match!(:KEYWORD, 'USE')
      captures = parse_argument_list()
    end

    # 3. Parse optional RETURNS
    return_type = :Any
    if match!(:KEYWORD, 'RETURNS')
      return_type = parse_type_annotation.to_sym
    end

    consume(:ARROW, '->')
    body = parse_block_body(['END', 'CATCH'])

    # 2. Parse Optional CATCH block
    catch_body = []
    catch_var = nil
    if match!(:KEYWORD, 'CATCH')
      catch_var = consume(:VAR_ID).value # Capture 'e' in CATCH e
      catch_body = parse_block_body(['END'])
    end

    consume(:KEYWORD, 'END')
    AST::FunctionDef.new(current.line, name, params, captures, return_type, body, catch_body, catch_var)
  end

  def parse_block_body(stop_words = ['END'])
    stmts = []
    # Keep going until we hit a stop word (END, ELSE, CATCH, etc)
    until stop_words.any? { |w| match?(:KEYWORD, w) } || match?(:EOF)
      stmt = parse_statement()
      stmts << stmt if stmt
    end
    stmts
  end

  def parse_expression
    # Start at the lowest level (Level 1)
    parse_precedence_level(1)
  end

  def parse_precedence_level(level)
    # 1. Base Case: Unary/Primary
    if level > AST::MAX_PRECEDENCE
      return parse_unary
    end

    # 2. Recursive Step: Parse LHS at higher precedence
    #    This ensures tight binding for *, +, ||, etc.
    lhs = parse_precedence_level(level + 1)

    level_data = AST::PRECEDENCE_MAP[level]
    return lhs unless level_data

    current_ops = level_data[:ops]

    # 3. Left-Associativity Loop
    #    Handles 'OR' and 's>' in the order they appear
    while current_ops.include?(current.value)
      # GUARD CLAUSE, AS is used as a keyword in CAST
      break if current.value == 'AS' && (peek.type == :TYPE_ID || peek.value[0] != '@')

      op_val = consume(current.type).value

      if op_val == 'AS'
        # The Right-Hand Side MUST be an Identifier (e.g., @f)
        # We parse it as a Primary to handle the identifier logic
        rhs = parse_var_id

        # Validate it is an Identifier (not a function call foo() or array arr[0])
        unless rhs.is_a?(AST::Identifier)
          raise "Syntax Error: Expected identifier after 'AS', got #{rhs.class}"
        end

        lhs = AST::BinaryOp.new(current.line, lhs, :BIND_VAR, rhs)

      elsif op_val == 'OR'
        # Special handling for OR logic (RETURN/EXIT/ELSE)
        # We assume parse_or_rescue parses a Primary or similar high-precedence node
        rhs = parse_or_rescue
        op_val = :OR_RESCUE

      elsif op_val == 's>'
        # RHS is parsed at the NEXT HIGHER level (Level 2)
        # This prevents it from consuming the next 'OR' or 's>'
        # allowing the loop to handle the chain.
        rhs = parse_precedence_level(level + 1)
        op_val = :SMOOTH

      else
        # Standard Operators
        rhs = parse_precedence_level(level + 1)
      end

      # Standard Operators (+, -, *, etc.)
      # FIX: Look up the Symbol immediately. Never pass 'op_val' (String) to the AST.
      # FALLBACK: USE existing symbol
      op_sym = AST::OP_TO_OP_CODE[op_val] || op_val

      # Guard against forgotten operators
      if op_sym.nil?
        raise "Parser Error: Unknown operator '#{op_val}'"
      end

      # Wrap the tree (Left-Growing)
      lhs = AST::BinaryOp.new(current.line, lhs, op_sym, rhs)
    end

    lhs
  end

  def parse_or_rescue
    # Syntax: ... OR RETURN
    if match!(:KEYWORD, 'RETURN')
      # TODO: TEST!
      rhs = AST::ReturnNode.new(current.line, nil)

    # Syntax: ... OR EXIT
    elsif match!(:KEYWORD, 'EXIT')
      context = nil
      if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
        context = parse_primary
      end
      rhs = AST::ThrowNode.new(current.line, context) # Nil value implies "Use the Pipe Result"


    # Syntax: ... OR ELSE value
    elsif match!(:KEYWORD, 'ELSE')
      # Meaning: Replace the error with a default value
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
      return AST::UnaryOp.new(current.line, AST::OP_TO_OP_CODE[v], right)
    end
    parse_primary
  end

  def parse_suffixes(lhs)
    loop do
      rule = @@suffix_rules[[current.type, current.value]]
      break unless rule
      # Run the rule, passing the current 'lhs' into it
      # The result becomes the new 'lhs' for the next iteration
      lhs = instance_exec(lhs, &rule)
    end
    lhs
  end

  def parse_var_id
    # 1. Base Case: Always start with an Identifier
    name = consume(:VAR_ID).value
    node = AST::Identifier.new(current.line, name)

    # 2. Check for Immediate Function Call: name(...)
    # We treat this as a special "suffix" of the identifier locally
    if match?(:CHAR, '(')
      args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      node = AST::FuncCall.new(current.line, name, args)
    end

    # 3. Apply general suffixes (Dot, Bracket, etc.)
    return parse_suffixes(node)
  end

  def parse_if_statement
    consume(:KEYWORD, 'IF')
    parse_if_chain
  end

  def parse_if_chain
    condition = parse_expression
    consume(:KEYWORD, 'THEN')
    then_branch = parse_block_body(['ELSE', 'ELSE_IF', 'END'])

    # Parse Optional 'ELSE_IF'
    else_branch = []
    if match!(:KEYWORD, 'ELSE_IF')
      # We recurse! We treat the ELSIF as the start of a new IF node.
      # This new node becomes the single statement inside our 'else_branch'.
      # Note: We do NOT consume 'END' here, the recursion handles it.
      nested_if = parse_if_chain
      else_branch << nested_if

    # Parse Optional 'ELSE'
    elsif match!(:KEYWORD, 'ELSE')
      else_branch = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    else
      consume(:KEYWORD, 'END')
    end

    AST::IfStatement.new(current.line, condition, then_branch, else_branch)
  end

  def parse_raise_msg
    return nil if match?(:CHAR, ';')
    parse_expression
  end

  def parse_stmts_until_end
    parse_block_body(['END'])
  end

  def parse_struct_body
    pairs = parse_comma_seq(:CHAR, '{', '}') do
      name = consume(:VAR_ID).value
      consume(:CHAR, ':')
      type = parse_type_annotation

      [name, type]
    end
    pairs.to_h
  end

  def parse_primary
    rule = @@primary_rules[[current.type, current.value]]
    rule ||= @@primary_rules[[current.type, nil]]
    return instance_exec(&rule) if rule
    return parse_unary() if current.value == '-' || current.value == '!'
    raise "Unexpected token #{current.value} (#{current.type}) line #{current.line}"
  end

  def parse_sigil_construct
    consume(:PERCENT)
    if match?(:TYPE_ID)
      name = consume(:TYPE_ID).value
      fields = parse_comma_seq(:CHAR, '{', '}') do
        k = consume(:VAR_ID).value; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::StructLit.new(current.line, name, fields.to_h)
    elsif match?(:CHAR, '[')
      items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
      return AST::ListLit.new(current.line, items)
    elsif match?(:CHAR, '{')
      pairs = parse_comma_seq(:CHAR, '{', '}') do
        k = parse_expression; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::HashLit.new(current.line, pairs.to_h)
    elsif match?(:CHAR, '(')
      params = parse_argument_list
      captures = []
      if match!(:KEYWORD, 'USE')
        captures = parse_argument_list
      end
      consume(:ARROW, '->')
      # TODO - Lambdas can be multiple statements...
      body = parse_expression
      # TODO: Parse
      # consume(:CHAR, ';')
      return AST::Lambda.new(current.line, params, captures, body)
    end
  end

  def parse_type_annotation
    base = consume(:TYPE_ID).value
    if match!(:CHAR, '[')
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
      match!(:CHAR, ',')
    end
    consume(:CHAR, close)
    items
  end
end

