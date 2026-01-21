require_relative "./ast"
require_relative "./lexer"
require_relative "./source_error"

# ==========================================
# PARSER
# ==========================================
class Parser
  include ErrorHelper

  @@stmt_rules = {}
  @@primary_rules = {}
  @@suffix_rules = {}

  def self.stmt(type, value, node_class = nil, pattern = nil, inject: [], &block)
    if pattern
      # If pattern provided, create a block that runs the engine
      @@stmt_rules[[type, value]] = lambda do
        start_token = current
        args = process_pattern(pattern)
        args.concat(inject)
        node_class.new(start_token, *args)
      end
    else
      @@stmt_rules[[type, value]] = block
    end
  end

  def self.primary(type, value=nil, node_class = nil, pattern = nil,  &block)
    if pattern
      # If pattern provided, create a block that runs the engine
      @@primary_rules[[type, value]] = lambda do
        start_token = current
        args = process_pattern(pattern)
        node_class.new(start_token, *args)
      end
    else
      @@primary_rules[[type, value]] = block
    end
  end

  def self.suffix(type, value, &block)
    @@suffix_rules[[type, value]] = block
  end

  def initialize(tokens, source_code = "")
    @tokens = tokens
    @pos = 0
    @source_code = source_code
  end

  def parse
    stmts = []
    stmts << parse_statement() while current.type != :EOF
    AST::Program.new(current, stmts)
  end

  private

  def peek
    @tokens[@pos + 1] || Token.new(:EOF, "", current.line, current.column)
  end

  # COMMANDS
  stmt(:KEYWORD, 'VAR', AST::VarDecl, ['VAR', :VAR_ID, {':' => :type_annotation}, '=', :expression, ';'], inject: [false])
  stmt(:KEYWORD, 'MUTABLE', AST::VarDecl, ['MUTABLE', :VAR_ID, {':' => :type_annotation}, '=', :expression, ';'], inject: [true])
  stmt(:KEYWORD, 'SET') { parse_set_var }  #, AST::Assignment, ['SET', :VAR_ID, '=', :expression, ';'])
  stmt(:KEYWORD, 'FN') { parse_function_def }
  stmt(:KEYWORD, 'IF') { parse_if_statement }
  stmt(:KEYWORD, 'STRUCT', AST::StructDef, ['STRUCT', :TYPE_ID, :struct_body])
  stmt(:KEYWORD, 'WHILE', AST::WhileLoop, ['WHILE', :expression, 'DO', :stmts_until_end, 'END'])
  stmt(:KEYWORD, 'RETURN') { parse_return }
  stmt(:KEYWORD, 'ASSERT', AST::Assert, ['ASSERT', :expression, {',' => :STRING}, ';'])
  stmt(:KEYWORD, 'RAISE', AST::Raise, ['RAISE', :raise_msg, ';'])
  stmt(:KEYWORD, 'EXIT') { parse_exit }
  stmt(:KEYWORD, 'DIE') { parse_die }
  stmt(:KEYWORD, 'BREAK', AST::BreakNode, ['BREAK', ';'])
  stmt(:KEYWORD, 'CONTINUE', AST::ContinueNode, ['CONTINUE', ';'])
  stmt(:KEYWORD, 'WITH') { parse_with_capability }


  # Primaries
  primary(:NUMBER) { parse_literal(:NUMBER, :stack) }
  primary(:INT64) { parse_literal(:INT64, :stack) }
  primary(:STRING) { parse_literal(:STRING, :stack) }
  primary(:BYTE) { parse_literal(:BYTE, :stack) }
  primary(:VAR_ID) { parse_var_id }

  primary(:KEYWORD, 'TRUE') { t = consume(:KEYWORD); AST::Literal.new(t, :BOOLEAN, true) }
  primary(:KEYWORD, 'FALSE') { t = consume(:KEYWORD); AST::Literal.new(t, :BOOLEAN, false) }
  primary(:KEYWORD, 'NIL') { t = consume(:KEYWORD); AST::Literal.new(t, :NIL, nil) }
  primary(:KEYWORD, 'CAST', AST::Cast, ['CAST', '(', :expression, 'AS', :type_annotation, ')'])
  primary(:KEYWORD, 'COPY', AST::Copy, ['COPY', :expression])
  primary(:PERCENT, '%') { parse_sigil_construct }
  primary(:KEYWORD, 'REQUIRE', AST::Require, ['REQUIRE', :STRING])

  primary(:KEYWORD, 'SELECT', AST::SelectOp, ['SELECT', :expression])
  primary(:KEYWORD, 'WHERE', AST::WhereOp, ['WHERE', :expression])
  primary(:KEYWORD, 'INDEX', AST::IndexOp, ['INDEX', :expression])
  primary(:KEYWORD, 'REDUCE') { parse_reduce_op }
  primary(:KEYWORD, 'ORDER_BY', AST::OrderByOp, ['ORDER_BY', :expression])
  primary(:KEYWORD, 'LIMIT', AST::LimitOp, ['LIMIT', :expression])

  # Expression Grouping
  primary(:CHAR, '(') do
    consume(:CHAR, '(')
    expr = parse_expression
    consume(:CHAR, ')')
    expr
  end

  # Array Indexing: arr[index]
  suffix(:CHAR, '[') do |lhs|
    start_token = consume(:CHAR, '[')
    first = parse_expression
    # TODO: handle ..< and ..= and [..] and [5..] and [..5]
    if match?(:RANGE, '..')
      # SLICE: list[0..1]
      range_token = consume(:RANGE, '..')
      last = parse_expression
      consume(:CHAR, ']')
      AST::Slice.new(range_token, lhs, first, last)
    else
      # INDEX: list[0]
      # INDEX: hash["OK"]
      consume(:CHAR, ']')
      AST::GetIndex.new(start_token, lhs, first)
    end
  end

  # Dot Access: obj.field OR obj.method()
  suffix(:CHAR, '.') do |lhs|
    dot_token = consume(:CHAR, '.')
    name_token = consume(:VAR_ID)

    if match?(:CHAR, '(')
      # Method Call
      _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      AST::MethodCall.new(name_token, lhs, name_token.value, args)
    else
      # Field Access
      AST::GetField.new(name_token, lhs, name_token.value)
    end
  end

  # Functor/Call: myVar()
  suffix(:CHAR, '(') do |lhs|
    start_token, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    # FIX: Pass 'lhs' (the node), not 'lhs.name'
    AST::FuncCall.new(start_token, lhs, args)
  end

  # Optional Unwrap: maybe_value?
  suffix(:CHAR, '?') do |lhs|
    q_token = consume(:CHAR, '?')
    AST::OptionalUnwrap.new(q_token, lhs)
  end

  def parse_literal(type, storage)
    token = consume(type)
    node = AST::Literal.new(token, type, token.value, storage)
    parse_suffixes(node)
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
    if val == '_'
      consume(:UNDERSCORE)
    elsif val.match?(/[a-zA-Z]/)
      consume(:KEYWORD, val)
    else
      consume(:CHAR, val)
    end
  end

  def match_literal!(val)
    type = val.match?(/[a-zA-Z]/) ? :KEYWORD : :CHAR
    match!(type, val)
  end
  ## END PATTERN DSL


  def current
    @tokens[@pos]
  end

  def previous
    @tokens[@pos-1]
  end

  def consume(type, value=nil)
    # 1. Capture the current token BEFORE moving the pointer
    token = current

    # 2. Validate it matches what we expect
    if (token.type == type) || (value && token.value == value)
      if value && token.value != value
         error!(token, "Expected value '#{value}', got '#{token.value}'")
      end

      # 3. Advance the pointer
      @pos += 1

      # 4. RETURN THE CAPTURED TOKEN (Not 'current', which is now the next one!)
      token
    else
      error!(token, "Expected #{value || type}, got #{token.value} (#{token.type}) line #{token.line}")
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
    set_token = consume(:KEYWORD, 'SET')

    # 1. Parse the Target (L-Value)
    # parse_var_id handles "x", "x.y", "x[0]", "x.y[1]", etc.
    target = parse_var_id

    # Optional: Validation (Prevent "SET f() = 1")
    unless target.is_a?(AST::Identifier) ||
           target.is_a?(AST::GetField) ||
           target.is_a?(AST::GetIndex)
       error!(target, "Syntax Error: Invalid assignment target on line #{current.line}")
    end

    consume(:CHAR, '=')
    value = parse_expression
    consume(:CHAR, ';')

    # 2. Return Assignment Node
    # Note: 'target' is now a Node, not just a String name.
    # Your Compiler already handles this!
    AST::Assignment.new(set_token, target, value)
  end

  def parse_return
    ret_token = consume(:KEYWORD, 'RETURN')
    value = nil

    # optional expression -> RETURN; is valid for Void functions
    unless match?(:CHAR, ';')
      value = parse_expression
    end

    consume(:CHAR, ';')

    AST::ReturnNode.new(ret_token, value)
  end

  def parse_exit()
    exit_token = consume(:KEYWORD)
    context_expr = nil
    if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
      context_expr = parse_primary
    end
    match!(:CHAR, ";") # TDOO: Test
    AST::ThrowNode.new(exit_token, context_expr)
  end

  def parse_die()
    die_token = consume(:KEYWORD)
    context_expr = nil

    if match!(:CHAR, ';')
      status = AST::Literal.new(previous, :NUMBER, 1)
    else
      status = parse_expression
      consume(:CHAR, ';')
    end

    AST::DieNode.new(die_token, status)
  end

  def parse_argument_list()
    parse_comma_seq(:CHAR, '(', ')') do
      takes = match!(:KEYWORD, 'TAKES')
      is_mutable = match!(:KEYWORD, 'MUTABLE')

      p_name = consume(:VAR_ID).value
      p_type = :Any

      if match!(:CHAR, ":")
        p_type = parse_type_annotation()
      end

      # TODO: This shouldn't be allowed for function calls
      default_val = nil
      if match!(:CHAR, '=')
        default_val = parse_expression()
      end

      { name: p_name, type: p_type, default: default_val, mutable: is_mutable, takes: takes }
    end
     .last # always ignore the first token
  end

  def parse_function_def
    fn_token = consume(:KEYWORD, 'FN')
    name = consume(:VAR_ID).value

    params = parse_argument_list()

    # 2. Parse USE() UpValues
    captures = []
    if match!(:KEYWORD, 'USE')
      captures = parse_argument_list()
    end

    # 3. Parse optional RETURNS
    return_type = nil
    if match!(:KEYWORD, 'RETURNS')
      if current.type == :VAR_ID
        return_lifetime = parse_var_id
        consume(:CHAR, ':')
      end

      return_type = parse_type_annotation()
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
    AST::FunctionDef.new(fn_token, name, params, captures, return_type, return_lifetime, body, catch_body, catch_var)
  end

  def parse_block_body(stop_words = ['END'])
    stmts = []
    types = stop_words.map { |w| Lexer::KEYWORDS.include?(w) ? :KEYWORD : :CHAR }
    stop_words = stop_words.zip(types)
    # Keep going until we hit a stop word (END, ELSE, CATCH, }, etc)
    until stop_words.any? { |w, t| match?(t, w) } || match?(:EOF)
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

      op_token = consume(current.type)
      op_val = op_token.value

      if op_val == 'AS'
        # The Right-Hand Side MUST be an Identifier (e.g., @f)
        # We parse it as a Primary to handle the identifier logic
        rhs = parse_var_id

        # Validate it is an Identifier (not a function call foo() or array arr[0])
        unless rhs.is_a?(AST::Identifier)
          error!(rhs, "Syntax Error: Expected identifier after 'AS', got #{rhs.class}")
        end

        lhs = AST::BinaryOp.new(op_token, lhs, :BIND_VAR, rhs)

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
        error!(op_token, "Parser Error: Unknown operator '#{op_val}'")
      end

      # Wrap the tree (Left-Growing)
      lhs = AST::BinaryOp.new(op_token, lhs, op_sym, rhs)
    end

    lhs
  end

  def parse_or_rescue
    # Syntax: ... OR RETURN
    if match!(:KEYWORD, 'RETURN')
      # TODO: TEST!
      rhs = AST::ReturnNode.new(previous, nil)

    # Syntax: ... OR RAISE (bubble up error - Zig's `try`)
    elsif match!(:KEYWORD, 'RAISE')
      rhs = AST::OrRaise.new(previous)

    # Syntax: ... OR PASS (ignore error, use undefined/default)
    elsif match!(:KEYWORD, 'PASS')
      rhs = AST::OrPass.new(previous)

    # Syntax: ... OR EXIT
    elsif match!(:KEYWORD, 'EXIT')
      exit_token = previous
      context = nil
      if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
        context = parse_primary
      end
      rhs = AST::ThrowNode.new(exit_token, context) # Nil value implies "Use the Pipe Result"


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
    if current.type == :CHAR && AST::UNARY_OPS.include?(v)
      op_token = consume(:CHAR)
      # Recursively parse the thing being negated (handles --5)
      right = parse_unary
      return AST::UnaryOp.new(op_token, AST::OP_TO_OP_CODE[v], right)
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
    var_token = consume(:VAR_ID)
    name = var_token.value
    node = AST::Identifier.new(var_token, name)

    # 2. Check for Immediate Function Call: name(...)
    # We treat this as a special "suffix" of the identifier locally
    if match?(:CHAR, '(')
      _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      node = AST::FuncCall.new(var_token, name, args)
    end

    # 3. Apply general suffixes (Dot, Bracket, etc.)
    return parse_suffixes(node)
  end

  def parse_if_statement
    if_token = consume(:KEYWORD, 'IF')
    parse_if_chain(if_token)
  end

  def parse_if_chain(if_token)
    condition = parse_expression
    consume(:KEYWORD, 'THEN')
    then_branch = parse_block_body(['ELSE', 'ELSE_IF', 'END'])

    # Parse Optional 'ELSE_IF'
    else_branch = []
    if match!(:KEYWORD, 'ELSE_IF')
      # We recurse! We treat the ELSIF as the start of a new IF node.
      # This new node becomes the single statement inside our 'else_branch'.
      # Note: We do NOT consume 'END' here, the recursion handles it.
      nested_if = parse_if_chain(previous)
      else_branch << nested_if

    # Parse Optional 'ELSE'
    elsif match!(:KEYWORD, 'ELSE')
      else_branch = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    else
      consume(:KEYWORD, 'END')
    end

    AST::IfStatement.new(if_token, condition, then_branch, else_branch)
  end

  def parse_raise_msg
    return nil if match?(:CHAR, ';')
    parse_expression
  end

  def parse_stmts_until_end
    parse_block_body(['END'])
  end

  def parse_struct_body
    _, pairs = parse_comma_seq(:CHAR, '{', '}') do
      name = consume(:VAR_ID).value
      consume(:CHAR, ':')
      type = parse_type_annotation()

      default_val = nil
      if match!(:CHAR, '=')
        default_val = parse_expression()
      end

      # Store as a hash containing both type and default
      [name, { type: type, default: default_val }]
    end
    pairs.to_h
  end

  def parse_primary
    rule = @@primary_rules[[current.type, current.value]]
    rule ||= @@primary_rules[[current.type, nil]]
    return instance_exec(&rule) if rule
    return parse_unary() if current.type == :CHAR && AST::UNARY_OPS.include?(current.value)
    lit = parse_lit(:stack)
    return lit if !lit.nil?
    error!(current, "Unexpected token #{current.value} (#{current.type}) line #{current.line}")
  end

  def parse_lit(storage)
    if match?(:TYPE_ID)
      type_token = consume(:TYPE_ID)
      name = type_token.value
      _, fields = parse_comma_seq(:CHAR, '{', '}') do
        k = consume(:VAR_ID).value; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::StructLit.new(type_token, name, fields.to_h, storage)
    elsif match?(:CHAR, '[')
      bracket_token, items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
      return AST::ListLit.new(bracket_token, items, storage)
    elsif match?(:CHAR, '{')
      start_token, pairs = parse_comma_seq(:CHAR, '{', '}') do
        k = parse_expression; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::HashLit.new(start_token, pairs.to_h, storage)
    elsif match?(:STRING)
      # TODO: Should only ever happen in parse_sigil
      return AST::Literal.new(current, :STRING, consume(:STRING).value, storage)
    end
    return nil
  end

  def parse_sigil_construct
    percent_token = consume(:PERCENT)
    lit = parse_lit(:heap)
    return lit if !lit.nil?
    if match?(:CHAR, '(')
      params = parse_argument_list()
      captures = []
      if match!(:KEYWORD, 'USE')
        captures = parse_argument_list()
      end
      consume(:ARROW, '->')
      # TODO - Lambdas can be multiple statements...
      body = parse_expression
      # TODO: Parse
      # consume(:CHAR, ';')
      # TODO: Is this accurate?
      return AST::LambdaLit.new(percent_token, params, captures, body, :heap)
    end
  end

  # REDUCE(initial_value) expression
  # e.g., myList s> REDUCE(0) acc + _.value
  def parse_reduce_op
    reduce_token = consume(:KEYWORD, 'REDUCE')
    consume(:CHAR, '(')
    initial_value = parse_expression
    consume(:CHAR, ')')
    body = parse_expression
    AST::ReduceOp.new(reduce_token, initial_value, body)
  end

  def parse_type_annotation
    # Check for error union prefix: !Type (Zig-style error returns)
    error_prefix = ""
    if match!(:CHAR, '!')
      error_prefix = "!"
    end

    # Check for optional prefix: ?Type
    optional_prefix = ""
    if match!(:CHAR, '?')
      optional_prefix = "?"
    end

    # Check for heap prefix: %Type
    heap_prefix = ""
    if match?(:PERCENT)
      consume(:PERCENT)
      heap_prefix = "%"
    end

    base = consume(:TYPE_ID).value
    inner = ""

    if match!(:CHAR, '[')
      # Case 1: Dynamic "Number[]"
      if match!(:CHAR, ']')
        inner = "[]"

      # Case 2: Fixed Inferred "Number[*]"
      elsif match!(:CHAR, '*')
        consume(:CHAR, ']')
        inner = "[*]"

      # Case 3: Fixed Explicit "Number[10]"
      elsif match?(:NUMBER)
        size = consume(:NUMBER).value.to_i
        consume(:CHAR, ']')
        inner = "[#{size}]"

      else
        error!(current, "Syntax Error: Expected ']', '*', or size in array type.")
      end
    end

    "#{error_prefix}#{optional_prefix}#{heap_prefix}#{base}#{inner}".to_sym
  end

  def parse_with_capability
    with_token = consume(:KEYWORD, 'WITH')

    # Parse comma-separated list of capability specifications
    capabilities = []

    while match?(:KEYWORD) do
      capability = match!(:KEYWORD).value.to_sym
      unless AST::CAPABILITIES.include?(capability)
        error!(current, "Expected EXCLUSIVE or RESTRICT, got #{capability}")
      end

      # Parse variable (supports foo, foo.bar, foo.bar.baz, etc.)
      var_node = parse_var_id

      capabilities << { capability: capability, var_node: var_node }

      # Check for comma (continue) or opening brace (done)
      break unless match!(:CHAR, ',')
    end

    # Parse block
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')

    AST::WithBlock.new(with_token, capabilities, body)
  end

  def parse_comma_seq(type, open, close)
    start_token = consume(type, open)
    items = []
    until match?(:CHAR, close)
      items << yield
      match!(:CHAR, ',')
    end
    consume(:CHAR, close)
    [start_token, items]
  end
end

