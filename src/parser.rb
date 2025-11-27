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
        node_class.new(*args)
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
        node_class.new(*args)
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
    AST::Program.new(stmts)
  end

  private

  # COMMANDS
  stmt(:KEYWORD, 'VAR', AST::VarDecl, ['VAR', :VAR_ID, {':' => :type_annotation}, '=', :expression, ';'])
  stmt(:KEYWORD, 'SET', AST::Assignment, ['SET', :VAR_ID, '=', :expression, ';'])
  stmt(:KEYWORD, 'FN') { parse_function_def }
  stmt(:KEYWORD, 'IF') { parse_if_statement }
  stmt(:KEYWORD, 'STRUCT', AST::StructDef, ['STRUCT', :TYPE_ID, :struct_body])
  stmt(:KEYWORD, 'WHILE', AST::WhileLoop, ['WHILE', :expression, 'DO', :stmts_until_end, 'END'])
  stmt(:KEYWORD, 'RETURN', AST::ReturnNode, ['RETURN', :expression, ';'])
  stmt(:KEYWORD, 'ASSERT', AST::Assert, ['ASSERT', :expression, {',' => :STRING}, ';'])
  stmt(:KEYWORD, 'RAISE', AST::Raise, ['RAISE', :raise_msg, ';'])
  stmt(:KEYWORD, 'EXIT') { parse_exit }

  # Primaries
  primary(:NUMBER) { AST::Literal.new(:NUMBER, consume(:NUMBER).value) }
  primary(:STRING) { AST::Literal.new(:STRING, consume(:STRING).value) }
  primary(:VAR_ID) { parse_var_id }

  primary(:KEYWORD, 'TRUE') { consume(:KEYWORD); AST::Literal.new(:BOOLEAN, true) }
  primary(:KEYWORD, 'FALSE') { consume(:KEYWORD); AST::Literal.new(:BOOLEAN, false) }
  primary(:KEYWORD, 'NIL') { consume(:KEYWORD); AST::Literal.new(:NIL, nil) }
  primary(:KEYWORD, 'CAST', AST::Cast, ['CAST', '(', :expression, 'AS', :type_annotation, ')'])
  primary(:PERCENT, '%') { parse_sigil_construct }

  # Array Indexing: arr[index]
  suffix(:CHAR, '[') do |lhs|
    consume(:CHAR, '[')
    index = parse_expression
    consume(:CHAR, ']')
    AST::GetIndex.new(lhs, index)
  end

  # Dot Access: obj.field OR obj.method()
  suffix(:CHAR, '.') do |lhs|
    consume(:CHAR, '.')
    name = consume(:VAR_ID).value

    if match?(:CHAR, '(')
      # Method Call
      args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      AST::MethodCall.new(lhs, name, args)
    else
      # Field Access
      AST::GetField.new(lhs, name)
    end
  end

  # Functor/Call: myVar()
  # TODO: TEST
  suffix(:CHAR, '(') do |lhs|
    args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    AST::FuncCall.new(lhs.name, args) # Note: Logic depends on your AST
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

  def parse_exit()
    consume(:KEYWORD)
    context_expr = nil
    if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
       context_expr = parse_primary
    end
    match!(:CHAR, ";") # TDOO: Test
    rhs = AST::ThrowNode.new(context_expr)
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
    AST::FunctionDef.new(name, params, captures, return_type, body, catch_body, catch_var)
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
    lhs = parse_primary
    while AST::BINARY_OPS.include?(current.value) || current.value == 'OR'
      op = current.value
      consume(current.type)
      rhs = nil
      if op == 'OR'
        rhs = parse_or_rescue
        lhs = AST::BinaryOp.new(lhs, :OR_RESCUE, rhs)
      else
        rhs = parse_primary
        lhs = AST::BinaryOp.new(lhs, op, rhs)
      end
    end
    lhs
  end

  def parse_or_rescue
    # Syntax: ... OR RETURN
    if match!(:KEYWORD, 'RETURN')
      # TODO: TEST!
      rhs = AST::ReturnNode.new(nil)

    # Syntax: ... OR EXIT
    elsif match!(:KEYWORD, 'EXIT')
      context = nil
      if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
         context = parse_primary
      end
      rhs = AST::ThrowNode.new(context) # Nil value implies "Use the Pipe Result"


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
      return AST::UnaryOp.new(AST::OP_TO_OP_CODE[v], right)
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
    node = AST::Identifier.new(name)

    # 2. Check for Immediate Function Call: name(...)
    # We treat this as a special "suffix" of the identifier locally
    if match?(:CHAR, '(')
      args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      node = AST::FuncCall.new(name, args)
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

    AST::IfStatement.new(condition, then_branch, else_branch)
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
      if match!(:KEYWORD, 'USE')
        captures = parse_argument_list
      end
      consume(:ARROW, '->')
      # TODO - Lambdas can be multiple statements...
      body = parse_expression
      # TODO: Parse
      # consume(:CHAR, ';')
      return AST::Lambda.new(params, captures, body)
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

