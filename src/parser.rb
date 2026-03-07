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
  stmt(:KEYWORD, 'MUTABLE', AST::VarDecl, ['MUTABLE', :VAR_ID, {':' => :type_annotation}, '=', :expression, ';'], inject: [true])
  stmt(:KEYWORD, 'FN')      { parse_function_def }
  stmt(:KEYWORD, 'PUB')     { parse_visibility_decl(:pub) }
  stmt(:KEYWORD, 'PRIVATE') { parse_visibility_decl(:private) }
  stmt(:KEYWORD, 'IF') { parse_if_statement }
  stmt(:KEYWORD, 'STRUCT') { parse_struct_def }
  stmt(:KEYWORD, 'WHILE', AST::WhileLoop, ['WHILE', :expression, 'DO', :stmts_until_end, 'END'])
  stmt(:KEYWORD, 'RETURN') { parse_return }
  stmt(:KEYWORD, 'ASSERT', AST::Assert, ['ASSERT', :expression, {',' => :STRING}, ';'])
  stmt(:KEYWORD, 'RAISE', AST::Raise, ['RAISE', :raise_msg, ';'])
  stmt(:KEYWORD, 'EXIT') { parse_exit }
  stmt(:KEYWORD, 'DIE') { parse_die }
  stmt(:KEYWORD, 'BREAK', AST::BreakNode, ['BREAK', ';'])
  stmt(:KEYWORD, 'CONTINUE', AST::ContinueNode, ['CONTINUE', ';'])
  stmt(:KEYWORD, 'WITH') { parse_with_capability }
  stmt(:KEYWORD, 'DO')   { parse_do_block }
  stmt(:KEYWORD, 'MATCH') { parse_match_statement }
  stmt(:KEYWORD, 'PASS') do
    tok = consume(:KEYWORD, 'PASS')
    match!(:CHAR, ';')  # optional semicolon — PASS may appear bare before a ','
    AST::PassStmt.new(tok)
  end


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
  primary(:KEYWORD, 'MOVE', AST::MoveNode, ['MOVE', :expression])
  primary(:PERCENT, '%') { parse_sigil_construct }
  primary(:KEYWORD, 'REQUIRE', AST::Require, ['REQUIRE', :STRING])

  primary(:KEYWORD, 'SELECT', AST::SelectOp, ['SELECT', :expression])
  primary(:KEYWORD, 'WHERE', AST::WhereOp, ['WHERE', :expression])
  primary(:KEYWORD, 'INDEX', AST::IndexOp, ['INDEX', :expression])
  primary(:KEYWORD, 'REDUCE') { parse_reduce_op }
  primary(:KEYWORD, 'ORDER_BY', AST::OrderByOp, ['ORDER_BY', :expression])
  primary(:KEYWORD, 'LIMIT', AST::LimitOp, ['LIMIT', :expression])
  primary(:KEYWORD, 'UNNEST', AST::UnnestOp, ['UNNEST', :expression])
  primary(:KEYWORD, 'DISTINCT', AST::DistinctOp, ['DISTINCT', :expression])

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
    
    if match?(:CHAR, '*')
      star_token = consume(:CHAR, '*')
      AST::GetField.new(star_token, lhs, '*')
    else
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

  # Capability Wraps: expr @multiowned -> Rc(T), expr @shared -> Arc(T), expr @locked -> *Locked(T)
  suffix(:VAR_ID, '@multiowned') do |lhs|
    token = consume(:VAR_ID)
    AST::CapabilityWrap.new(token, lhs, :multiowned, nil)
  end

  suffix(:VAR_ID, '@shared') do |lhs|
    token = consume(:VAR_ID)
    AST::CapabilityWrap.new(token, lhs, :shared, nil)
  end

  suffix(:VAR_ID, '@locked') do |lhs|
    token = consume(:VAR_ID)
    AST::CapabilityWrap.new(token, lhs, nil, :locked)
  end

  suffix(:VAR_ID, '@writeLocked') do |lhs|
    token = consume(:VAR_ID)
    AST::CapabilityWrap.new(token, lhs, nil, :write_locked)
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
    # Keywordless bind/assign: x = ..., x: Type = ..., x.field = ..., x[0] = ...
    if current.type == :VAR_ID
      result = try_parse_bind_or_assign
      return result if result
    end

    rule = @@stmt_rules[[current.type, current.value]]
    return instance_exec(&rule) if rule
    expr = parse_expression
    consume(:CHAR, ';')
    expr
  end

  # Speculatively parse `target [: Type] = expression ;` as a BindExpr or Assignment.
  # Returns nil (and backtracks) if no `=` follows the target, so we fall through to
  # expression-statement parsing (e.g. method calls like `foo();`).
  def try_parse_bind_or_assign
    saved_pos = @pos
    target_token = current
    target = parse_var_id  # handles x, x.field, x[0]

    # Optional type annotation for simple identifiers: x: Type = ...
    opt_type = nil
    if target.is_a?(AST::Identifier) && match?(:CHAR, ':')
      consume(:CHAR, ':')
      opt_type = parse_type_annotation
    end

    unless match?(:CHAR, '=')
      @pos = saved_pos
      return nil
    end

    unless target.is_a?(AST::Identifier) || target.is_a?(AST::GetField) || target.is_a?(AST::GetIndex)
      @pos = saved_pos
      return nil
    end

    consume(:CHAR, '=')
    value = parse_expression
    consume(:CHAR, ';')

    if target.is_a?(AST::Identifier)
      AST::BindExpr.new(target_token, target.name, opt_type, value)
    else
      # Field or index assignment — always a reassignment, never a declaration
      AST::Assignment.new(target_token, target, value)
    end
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
        p_type = parse_type_annotation(allow_capabilities: false)
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

  def parse_visibility_decl(visibility)
    consume(:KEYWORD)  # consume PUB or PRIVATE
    if match?(:KEYWORD, 'FN')
      parse_function_def(visibility)
    elsif match?(:KEYWORD, 'STRUCT')
      parse_struct_def(visibility)
    else
      error!(current, "Expected FN or STRUCT after visibility modifier, got '#{current.value}'")
    end
  end

  def parse_struct_def(visibility = :package)
    tok = consume(:KEYWORD, 'STRUCT')
    name = consume(:TYPE_ID).value
    fields = parse_struct_body
    AST::StructDef.new(tok, name, fields, visibility)
  end

  def parse_function_def(visibility = :package)
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
    AST::FunctionDef.new(fn_token, name, params, captures, return_type, return_lifetime, body, catch_body, catch_var, visibility)
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

  def parse_expression(precedence = 0)
    lhs = parse_unary

    while (op_token = current) && (op_prec = get_precedence(op_token)) && op_prec > precedence
      # GUARD CLAUSE: AS is used as a keyword in CAST, and only binds if followed by an alias (@...)
      if op_token.value == 'AS' && (peek.type == :TYPE_ID || peek.value[0] != '@')
        break
      end

      consume(op_token.type)
      lhs = parse_binary_op(lhs, op_token, op_prec)
    end

    lhs
  end

  def get_precedence(token)
    return nil unless token.type == :CHAR || token.type == :KEYWORD || token.type == :SMOOTH || token.type == :OR_RESCUE || token.type == :RANGE_EXCL || token.type == :RANGE_INCL

    # Precedence levels (higher = tighter binding)
    case token.value
    when 'OR', 's>', 'AS' then 1
    when '..<', '..<=', '..=' then 2
    when '||'             then 3
    when '&&'             then 4
    when '==', '!=', '<', '>', '<=', '>=' then 5
    when '+', '-'         then 6
    when '*', '/', 'MOD'  then 7
    when '**'             then 8
    else nil
    end
  end

  def parse_binary_op(lhs, op_token, op_prec)
    op_val = op_token.value
    
    # 1. Handle Right-Associativity (e.g. power operator **)
    #    Subtract 1 from precedence so the next call consumes subsequent terms
    next_prec = (op_val == '**') ? op_prec - 1 : op_prec

    # 2. Special Operators
    case op_val
    when 'AS'
      rhs = parse_var_id
      unless rhs.is_a?(AST::Identifier)
        error!(rhs, "Syntax Error: Expected identifier after 'AS', got #{rhs.class}")
      end
      return AST::BinaryOp.new(op_token, lhs, :BIND_VAR, rhs)

    when 'OR'
      rhs = parse_or_rescue
      return AST::BinaryOp.new(op_token, lhs, :OR_RESCUE, rhs)

    when 's>'
      # SMOOTH binds Level 1, but its RHS allows chained pipe operators
      rhs = parse_expression(next_prec)
      return AST::BinaryOp.new(op_token, lhs, :SMOOTH, rhs)

    when '..<'
      rhs = parse_expression(next_prec)
      return AST::RangeLit.new(op_token, lhs, rhs, false)

    when '..<=', '..='
      rhs = parse_expression(next_prec)
      return AST::RangeLit.new(op_token, lhs, rhs, true)
    end

    # 3. Standard Operators (+, -, *, etc.)
    rhs = parse_expression(next_prec)
    op_sym = AST::OP_TO_OP_CODE[op_val] || op_val.to_sym
    
    AST::BinaryOp.new(op_token, lhs, op_sym, rhs)
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

  def parse_match_statement
    tok = consume(:KEYWORD, 'MATCH')
    expr = parse_expression
    consume(:KEYWORD, 'START')

    cases = []
    default_case = nil

    until match?(:KEYWORD, 'END') || match?(:EOF)
      if match?(:KEYWORD, 'DEFAULT')
        consume(:KEYWORD, 'DEFAULT')
        consume(:ARROW)
        default_case = parse_block_body(['END'])
        break
      end

      if match?(:KEYWORD, 'WHEN')
        consume(:KEYWORD, 'WHEN')
        condition = parse_expression
        consume(:ARROW)
        body = parse_block_body([',', 'DEFAULT', 'WHEN', 'END'])
        cases << { kind: :when, value: condition, body: body }
      elsif match?(:CHAR, '{')
        pattern = parse_struct_pattern
        consume(:ARROW)
        body = parse_block_body([',', 'DEFAULT', 'WHEN', 'END'])
        cases << { kind: :struct_pattern, value: pattern, body: body }
      else
        pattern = parse_expression
        consume(:ARROW)
        body = parse_block_body([',', 'DEFAULT', 'WHEN', 'END'])
        cases << { kind: :eq, value: pattern, body: body }
      end
      match!(:CHAR, ',')  # consume comma separator between cases if present
    end

    consume(:KEYWORD, 'END')
    AST::MatchStatement.new(tok, expr, cases, default_case, [], nil)
  end

  def parse_struct_pattern
    tok = consume(:CHAR, '{')
    fields = []
    partial = false

    until match?(:CHAR, '}') || match?(:EOF)
      # `...` means "ignore all remaining fields" (partial match)
      if match?(:ELLIPSIS, '...')
        consume(:ELLIPSIS, '...')
        partial = true
        break
      end

      name = consume(:VAR_ID).value
      consume(:CHAR, ':')

      # `_` as value means wildcard — ignore this field's value
      if current.type == :VAR_ID && current.value == '_'
        consume(:VAR_ID)
        fields << { name: name, value: :wildcard }
      else
        fields << { name: name, value: parse_expression }
      end

      match!(:CHAR, ',')  # optional comma between fields
    end

    consume(:CHAR, '}')
    AST::StructPattern.new(tok, fields, partial)
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
    return parse_suffixes(lit) if !lit.nil?
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
    # % is now a no-op for storage: escape analysis and declared types determine heap vs stack.
    lit = parse_lit(:stack)
    return parse_suffixes(lit) if !lit.nil?
    if match?(:CHAR, '(')
      params = parse_argument_list()
      captures = []
      if match!(:KEYWORD, 'USE')
        captures = parse_argument_list()
      end
      consume(:ARROW, '->')
      body = parse_expression
      return AST::LambdaLit.new(percent_token, params, captures, body, :stack, nil)
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

  def parse_type_annotation(allow_capabilities: true)
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

    # Check for heap prefix: %Type — tracked as location, not embedded in the symbol.
    is_heap = false
    if match?(:PERCENT)
      consume(:PERCENT)
      is_heap = true
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

      # Allow multiple dimensions (e.g., Number[][][])
      while match?(:CHAR, '[')
        consume(:CHAR, '[')
        if match!(:CHAR, ']')
          inner += "[]"
        elsif match?(:NUMBER)
          size = consume(:NUMBER).value.to_i
          consume(:CHAR, ']')
          inner += "[#{size}]"
        else
          error!(current, "Syntax Error: Expected ']' or size in array type.")
        end
      end
    end

    # Check for capability suffix: Type @multiowned, Type @shared, Type @locked.
    # Not permitted on function parameters (functions take plain Types, not Capabilities).
    ownership = nil
    sync      = nil
    if match?(:VAR_ID) && %w[@multiowned @shared @locked @writeLocked].include?(current.value)
      unless allow_capabilities
        error!(current, "Capability annotations are not allowed on function parameters. Use the plain type (e.g., 'Node' not 'Node @multiowned').")
      end
      case consume(:VAR_ID).value
      when "@multiowned" then ownership = :multiowned
      when "@shared"     then ownership = :shared
      when "@locked"       then sync      = :locked
      when "@writeLocked"  then sync      = :write_locked
      end
    end

    base_sym = "#{error_prefix}#{optional_prefix}#{base}#{inner}".to_sym
    Type.new(base_sym, ownership: ownership, sync: sync, location: is_heap ? :heap : nil)
  end

  def parse_with_capability
    with_token = consume(:KEYWORD, 'WITH')

    # Parse comma-separated list of capability specifications.
    # Syntax: WITH var_name { } — capability is inferred from the variable's type.
    # Explicit form: WITH RESTRICT/EXCLUSIVE var_name { } — traditional capabilities.
    # Locked form:   WITH EXCLUSIVE lockedVar AS alias { } — acquire mutex, bind inner value.
    capabilities = []

    while match?(:KEYWORD) || match?(:VAR_ID) do
      capability = if match?(:KEYWORD) && current.value != 'AS'
        cap = consume(:KEYWORD).value.to_sym
        unless AST::CAPABILITIES.include?(cap)
          error!(previous, "Unknown WITH capability: #{cap}")
        end
        cap
      else
        :infer  # VAR_ID: capability inferred from variable's type at annotation time
      end

      # Parse variable (supports foo, foo.bar, foo.bar.baz, etc.)
      var_node = parse_var_id

      # Optional alias binding: WITH EXCLUSIVE lockedVar AS alias { }
      alias_name = nil
      if match!(:KEYWORD, 'AS')
        alias_name = consume(:VAR_ID).value
      end

      capabilities << { capability: capability, var_node: var_node, alias: alias_name }

      # Check for comma (continue) or opening brace (done)
      break unless match!(:CHAR, ',')
    end

    # Parse block
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')

    AST::WithBlock.new(with_token, capabilities, body)
  end

  def parse_do_block
    do_token = consume(:KEYWORD, 'DO')
    consume(:CHAR, '{')
    branches = []

    until match?(:CHAR, '}') || match?(:EOF)
      # A branch is either a block-statement (WITH, IF, etc.) starting with a keyword,
      # or a bare expression. Keyword branches don't need a trailing semicolon.
      stmt = if match?(:KEYWORD)
        parse_statement
      else
        parse_expression
      end
      branches << [stmt].compact
      break unless match!(:CHAR, ',')
    end

    consume(:CHAR, '}')
    AST::DoBlock.new(do_token, branches)
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
