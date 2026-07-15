# typed: strict

class ClearParser
  extend T::Sig

  private

  sig { returns(T.any(AST::IfStatement, AST::IfBind)) }
  def parse_comptime_statement
    consume(:KEYWORD, 'COMPTIME')
    unless match?(:KEYWORD, 'IF')
      error!(current, :PARSER_EXPECTED, expected: "IF", got: current.value, type: current.type, line: current.line)
    end
    parse_if_statement(is_comptime: true)
  end

  sig { params(is_comptime: T::Boolean).returns(T.any(AST::IfStatement, AST::IfBind)) }
  def parse_if_statement(is_comptime: false)
    if_token = consume(:KEYWORD, 'IF')
    parse_if_chain(if_token, is_comptime: is_comptime)
  end

  sig { params(if_token: Lexer::Token, is_comptime: T::Boolean).returns(T.any(AST::IfStatement, AST::IfBind)) }
  def parse_if_chain(if_token, is_comptime: false)
    if conditional_capture_ahead?
      return parse_refined_if_chain(if_token, is_comptime: is_comptime)
    end

    condition = parse_expression

    # Shorthand: IF condition -> single_statement;
    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      node = AST::IfStatement.new(if_token, condition, [stmt].compact, [])
      node.comptime = is_comptime
      return node
    end

    # Explicit predicate bindings refine left-to-right, so a later expression
    # may use an earlier alias without parentheses.
    if conditional_binding_predicate?
      bindings = [parse_conditional_binding(condition)]
      while match?(:KEYWORD, 'AND')
        consume(:KEYWORD, 'AND')
        next_expr = parse_expression
        unless conditional_binding_predicate?
          error!(current, :PARSER_EXPECTED, expected: "EXISTS AS or IS_OK AS", got: current.value, type: current.type, line: current.line)
        end
        bindings << parse_conditional_binding(next_expr)
      end
      return parse_if_bind_body(if_token, bindings)
    elsif match?(:KEYWORD, 'AS')
      emit_legacy_optional_binding!(current)
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      # Bare multi-bind error: IF expr AS name && expr2 AS name2 THEN
      if match?(:KEYWORD, 'AND') || match?(:LEGACY_LOGICAL, '&&')
        error!(if_token, :MULTIPLE_BINDINGS_NEED_PARENS)
      end
      bindings = [AST::Binding.new(expr: condition, name: name_tok.text!, name_token: name_tok)]
      return parse_if_bind_body(if_token, bindings)
    end

    # Paren-bind form: IF (expr EXISTS AS name) AND (...) THEN ...
    bindings = extract_paren_bindings(condition, if_token)
    unless bindings.empty?
      return parse_if_bind_body(if_token, bindings)
    end

    consume(:KEYWORD, 'THEN')
    then_branch = parse_block_body(['ELSE', 'ELSE_IF', 'END'])

    # Parse Optional 'ELSE_IF'
    else_branch = []
    if match!(:KEYWORD, 'ELSE_IF')
      # We recurse! We treat the ELSIF as the start of a new IF node.
      # This new node becomes the single statement inside our 'else_branch'.
      # Note: We do NOT consume 'END' here, the recursion handles it.
      nested_if = parse_if_chain(previous, is_comptime: is_comptime)
      else_branch << nested_if

    # Parse Optional 'ELSE'
    elsif match!(:KEYWORD, 'ELSE')
      else_branch = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    else
      consume(:KEYWORD, 'END')
    end

    node = AST::IfStatement.new(if_token, condition, then_branch, else_branch)
    node.comptime = is_comptime
    node
  end

  # A refinement capture is control flow, not a Boolean value. Parse a mixed
  # condition once and normalize its left-to-right AND steps to the same nested
  # IF/IfBind tree a user would otherwise have to write by hand. This keeps the
  # annotator, ownership analysis, and MIR on their established paths while
  # making ordinary guards and captures freely composable.
  sig { params(if_token: Lexer::Token, is_comptime: T::Boolean).returns(T.any(AST::IfStatement, AST::IfBind)) }
  def parse_refined_if_chain(if_token, is_comptime: false)
    steps = T.let([], T::Array[T.any(AST::Node, AST::Binding)])
    loop do
      atom = parse_expression(5)
      if conditional_binding_predicate?
        steps << parse_conditional_binding(atom)
      else
        steps.concat(refinement_steps(atom, if_token))
      end

      break unless match?(:KEYWORD, 'AND') || match?(:KEYWORD, 'OR')
      operator = consume(:KEYWORD)
      error!(operator, :CONDITIONAL_BINDING_UNDER_OR) if operator.value == 'OR'
    end

    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      return build_refined_if_tree(if_token, steps, [stmt].compact, [], is_comptime)
    end

    consume(:KEYWORD, 'THEN')
    then_branch = parse_block_body(['ELSE', 'ELSE_IF', 'END'])
    else_branch = T.let([], AST::RawBody)
    if match!(:KEYWORD, 'ELSE_IF')
      else_branch << parse_if_chain(previous, is_comptime: is_comptime)
    elsif match!(:KEYWORD, 'ELSE')
      else_branch = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    else
      consume(:KEYWORD, 'END')
    end
    build_refined_if_tree(if_token, steps, then_branch, else_branch, is_comptime)
  end

  # Token-only recognition chooses the refinement grammar without consuming or
  # replaying parser state. Delimiter depth prevents a later statement/block
  # from influencing the current IF decision.
  sig { returns(T::Boolean) }
  def conditional_capture_ahead?
    offset = T.let(0, Integer)
    depth = T.let(0, Integer)
    loop do
      token = peek_at(offset)
      return false unless token
      if token.type == :CHAR
        depth += 1 if OPEN_DELIMITERS.include?(token.text!)
        depth -= 1 if CLOSE_DELIMITERS.include?(token.text!)
      end
      return false if depth == 0 && ((token.type == :KEYWORD && %w[THEN ELSE END].include?(token.value)) || token.type == :ARROW || token.type == :EOF)
      if token.type == :KEYWORD && %w[EXISTS IS_OK].include?(token.value)
        following = peek_at(offset + 1)
        return true if following && following.type == :KEYWORD && following.value == 'AS'
      end
      offset += 1
    end
  end

  sig { params(node: AST::Node, if_token: Lexer::Token).returns(T::Array[T.any(AST::Node, AST::Binding)]) }
  def refinement_steps(node, if_token)
    return [node] unless node.is_a?(AST::BinaryOp)
    if node.op == :BIND_VAR
      right = T.cast(node.right, AST::Identifier)
      predicate = node.token.value == 'IS_OK' ? :is_ok : :exists
      return [AST::Binding.new(expr: node.left, name: right.name, name_token: right.token, predicate: predicate)]
    end
    if node.op == :OR && contains_refinement_binding?(node)
      error!(node.token, :CONDITIONAL_BINDING_UNDER_OR)
    end
    return [node] unless node.op == :AND

    refinement_steps(node.left, if_token) + refinement_steps(node.right, if_token)
  end

  sig { params(node: AST::Node).returns(T::Boolean) }
  def contains_refinement_binding?(node)
    return false unless node.is_a?(AST::BinaryOp)
    return true if node.op == :BIND_VAR

    contains_refinement_binding?(node.left) || contains_refinement_binding?(node.right)
  end

  sig do
    params(
      if_token: Lexer::Token,
      steps: T::Array[T.any(AST::Node, AST::Binding)],
      then_branch: AST::RawBody,
      else_branch: AST::RawBody,
      is_comptime: T::Boolean,
    ).returns(T.any(AST::IfStatement, AST::IfBind))
  end
  def build_refined_if_tree(if_token, steps, then_branch, else_branch, is_comptime)
    body = T.let(then_branch, AST::RawBody)
    index = steps.length - 1
    while index >= 0
      step = T.must(steps[index])
      nested = if step.is_a?(AST::Binding)
        bindings = T.let([], T::Array[AST::Binding])
        while index >= 0 && steps[index].is_a?(AST::Binding)
          bindings.unshift(T.cast(steps[index], AST::Binding))
          index -= 1
        end
        AST::IfBind.new(if_token, bindings, body, else_branch)
      else
        item = AST::IfStatement.new(if_token, step, body, else_branch)
        item.comptime = is_comptime
        index -= 1
        item
      end
      stamp_source_range!(nested, if_token, previous)
      body = [nested]
    end
    T.cast(body.fetch(0), T.any(AST::IfStatement, AST::IfBind))
  end

  sig { returns(T::Boolean) }
  def conditional_binding_predicate?
    match?(:KEYWORD, 'EXISTS') || match?(:KEYWORD, 'IS_OK')
  end

  sig { params(expr: AST::Node).returns(AST::Binding) }
  def parse_conditional_binding(expr)
    predicate_tok = consume(:KEYWORD)
    predicate = predicate_tok.value == 'IS_OK' ? :is_ok : :exists
    consume(:KEYWORD, 'AS')
    name_tok = consume(:VAR_ID)
    AST::Binding.new(expr: expr, name: name_tok.text!, name_token: name_tok, predicate: predicate)
  end

  sig { params(if_token: Lexer::Token, bindings: T::Array[AST::Binding]).returns(AST::IfBind) }
  def parse_if_bind_body(if_token, bindings)
    consume(:KEYWORD, 'THEN')
    then_branch = parse_block_body(['ELSE', 'ELSE_IF', 'END'])
    else_branch = []
    if match!(:KEYWORD, 'ELSE')
      else_branch = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    else
      consume(:KEYWORD, 'END')
    end
    AST::IfBind.new(if_token, bindings, then_branch, else_branch)
  end

  # Returns Array of {expr:, name:, name_token:} if condition is fully paren-bind.
  # Returns [] if condition is not a paren-bind pattern.
  # Raises error if any bind in a && chain is bare (not paren-wrapped).
  sig { params(node: AST::Node, if_token: Lexer::Token).returns(T::Array[AST::Binding]) }
  def extract_paren_bindings(node, if_token)
    case node
    when AST::BinaryOp
      if node.op == :BIND_VAR
        right = T.cast(node.right, AST::Identifier)
        predicate = node.token.value == 'IS_OK' ? :is_ok : :exists
        return node.paren_bind ? [AST::Binding.new(expr: node.left, name: right.name, name_token: right.token, predicate: predicate)] : []
      elsif node.op == :AND  # && maps to :AND in OP_TO_OP_CODE
        left_binds  = extract_paren_bindings(node.left, if_token)
        right_binds = extract_paren_bindings(node.right, if_token)
        # Only treat as bind-chain if at least one side is a paren-bind
        unless left_binds.empty? && right_binds.empty?
          # Validate: bare binds in && position are illegal
          validate_no_bare_bind!(node.left,  if_token) if left_binds.empty?
          validate_no_bare_bind!(node.right, if_token) if right_binds.empty?
          return left_binds.concat(right_binds)
        end
      end
    end
    []
  end

  # Raises an error if node is a non-paren BIND_VAR anywhere in the && tree.
  sig { params(node: AST::Node, if_token: Lexer::Token).void }
  def validate_no_bare_bind!(node, if_token)
    return unless node.is_a?(AST::BinaryOp)
    if node.op == :BIND_VAR && !node.paren_bind
      error!(if_token, :MULTIPLE_BINDINGS_NEED_PARENS)
    elsif node.op == :AND
      validate_no_bare_bind!(node.left,  if_token)
      validate_no_bare_bind!(node.right, if_token)
    end
  end

  # Expression-position IF: each branch is a single expression (no semicolons).
  sig { returns(AST::IfStatement) }
  def parse_if_expr
    if_token = consume(:KEYWORD, 'IF')
    parse_if_chain_expr(if_token)
  end

  sig { params(if_token: Lexer::Token).returns(AST::IfStatement) }
  def parse_if_chain_expr(if_token)
    condition = parse_expression
    consume(:KEYWORD, 'THEN')
    then_branch = [parse_expression]

    else_branch = []
    if match!(:KEYWORD, 'ELSE_IF')
      # Recursion consumes END; do not consume again here.
      else_branch = [parse_if_chain_expr(previous)]
    elsif match!(:KEYWORD, 'ELSE')
      else_branch = [parse_expression]
      consume(:KEYWORD, 'END')
    else
      consume(:KEYWORD, 'END')
    end

    AST::IfStatement.new(if_token, condition, then_branch, else_branch)
  end

  # Expression-position MATCH: each arm body is a single expression (no semicolons).

  sig { returns(T.any(AST::WhileLoop, AST::WhileBindLoop)) }
  def parse_while_loop
    tok = consume(:KEYWORD, 'WHILE')
    condition = parse_expression

    # WHILE expr EXISTS AS name [-> stmt | DO ... END]
    if match?(:KEYWORD, 'EXISTS')
      consume(:KEYWORD, 'EXISTS')
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      if match?(:ARROW, '->')
        consume(:ARROW, '->')
        stmt = parse_statement
        return AST::WhileBindLoop.new(tok, condition, name_tok.text!, name_tok, [stmt].compact, nil)
      end
      body = parse_keyword_block('DO')
      return AST::WhileBindLoop.new(tok, condition, name_tok.text!, name_tok, body, nil)
    elsif match?(:KEYWORD, 'AS')
      emit_legacy_optional_binding!(current)
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      if match?(:ARROW, '->')
        consume(:ARROW, '->')
        stmt = parse_statement
        return AST::WhileBindLoop.new(tok, condition, name_tok.text!, name_tok, [stmt].compact, nil)
      end
      body = parse_keyword_block('DO')
      return AST::WhileBindLoop.new(tok, condition, name_tok.text!, name_tok, body, nil)
    end

    # Shorthand: WHILE condition -> single_statement;
    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      return AST::WhileLoop.new(tok, condition, [stmt].compact)
    end

    body = parse_keyword_block('DO')
    AST::WhileLoop.new(tok, condition, body)
  end

end
