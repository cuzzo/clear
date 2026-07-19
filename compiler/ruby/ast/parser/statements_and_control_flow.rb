# typed: strict

class ClearParser
  extend T::Sig

  private

  sig { params(rule: ParserRule).returns(AST::Node) }
  def dispatch_stmt_rule(rule)
    result = case rule.action
    when :parse_require then parse_require
    when :parse_extern_decl then parse_extern_decl
    when :parse_mutable_var_decl then parse_mutable_var_decl
    when :parse_function_def then parse_function_def
    when :parse_method_function_def then parse_function_def(:package, is_method: true)
    when :parse_pub_visibility then parse_visibility_decl(:pub)
    when :parse_private_visibility then parse_visibility_decl(:private)
    when :parse_if_statement then parse_if_statement
    when :parse_comptime_statement then parse_comptime_statement
    when :parse_struct_def then parse_struct_def
    when :parse_protocol_def then parse_protocol_def
    when :parse_implementation_def then parse_implementation_def
    when :parse_enum_def then parse_enum_def
    when :parse_union_def then parse_union_def
    when :parse_while_loop then parse_while_loop
    when :parse_for_range then parse_for_range
    when :parse_tight_stmt then parse_tight_stmt
    when :parse_return then parse_return
    when :parse_assert then parse_assert
    when :parse_assert_raises then parse_assert_raises
    when :parse_test_block then parse_test_block
    when :parse_stub then parse_stub
    when :parse_benchmark_stmt then parse_benchmark_stmt
    when :parse_smash_stmt then parse_smash_stmt
    when :parse_profile_stmt then parse_profile_stmt
    when :parse_raise_stmt then parse_raise_stmt
    when :parse_exit then parse_exit
    when :parse_die then parse_die
    when :parse_break then parse_break
    when :parse_continue then parse_continue
    when :parse_with_capability then parse_with_capability
    when :parse_sync_policy_block then parse_sync_policy_block
    when :parse_do_block then parse_do_block
    when :parse_bg_block then parse_bg_block
    when :parse_yield_expr then parse_yield_expr
    when :parse_close_stream then parse_close_stream
    when :parse_match_statement then parse_match_statement
    when :parse_partial_match_statement then parse_partial_match_statement
    when :parse_pass_statement then parse_pass_statement
    else
      raise "Unknown statement parser action #{rule.action}"
    end
    T.must(result)
  end

  sig { returns(AST::Assert) }
  def parse_assert
    token = consume(:KEYWORD, 'ASSERT')
    condition = parse_expression
    message = T.let(:Any, T.any(Symbol, String))
    if match!(:CHAR, ',')
      message = consume(:STRING).text!
    end
    consume(:CHAR, ';')
    AST::Assert.new(token, condition, message)
  end

  sig { returns(AST::BreakNode) }
  def parse_break
    token = consume(:KEYWORD, 'BREAK')
    consume(:CHAR, ';')
    AST::BreakNode.new(token)
  end

  sig { returns(AST::ContinueNode) }
  def parse_continue
    token = consume(:KEYWORD, 'CONTINUE')
    consume(:CHAR, ';')
    AST::ContinueNode.new(token)
  end

  sig { returns(AST::Node) }
  def parse_partial_match_statement
    consume(:KEYWORD, 'PARTIAL')
    parse_match_statement(partial: true)
  end

  sig { returns(AST::PassStmt) }
  def parse_pass_statement
    tok = consume(:KEYWORD, 'PASS')
    match!(:CHAR, ';')  # optional semicolon — PASS may appear bare before a ','
    AST::PassStmt.new(tok)
  end

  SYNTAX_TOKENS_AT_STATEMENT_END = %w[; THEN DO ->].freeze

  sig { returns(AST::Node) }
  def parse_statement
    @budget.enter!
    statement = parse_statement_body
    @budget.leave!
    statement
  end

  sig { returns(AST::Node) }
  def parse_statement_body
    start_token = current
    node = T.let(nil, T.nilable(AST::Node))
    # Destructuring bind/assign must win before scalar bind parsing:
    # a, b = ...
    # a: Int32, b: Float64 = ...
    if current.type == :VAR_ID
      if destructuring_assignment?
        node = parse_destructuring_assign
      else
        parsed = parse_var_form
        consume(:CHAR, ';')
        node = parsed.node
      end
    else
      rule = STMT_RULE_INDEX[ClearParser.token_rule_key(current)]
      if rule
        node = dispatch_stmt_rule(rule)
      else
        node = parse_expression
        consume(:CHAR, ';')
      end
    end
    stamp_source_range!(node, start_token, previous)
  end

  # A comma immediately after the first target makes this a destructuring
  # assignment.  For a typed first target, scan only the type annotation and
  # look for its top-level comma.  This is token lookahead: it never advances
  # or restores the parser cursor and never recursively parses an expression.
  sig { returns(T::Boolean) }
  def destructuring_assignment?
    return true if match_at?(1, :CHAR, ',')
    return false unless match_at?(1, :CHAR, ':')

    offset = 2
    delimiters = T.let([], T::Array[String])
    loop do
      token = peek_at(offset)
      return false unless token
      return false if token.type == :EOF

      if token.type == :CHAR
        value = token.text!
        case value
        when '(', '[', '{', '<'
          delimiters << value
        when ')', ']', '}', '>'
          delimiters.pop unless delimiters.empty?
        when ','
          return true if delimiters.empty?
        when '=', ';'
          return false if delimiters.empty?
        end
      end
      offset += 1
    end
  end

  # Parse identifier-only destructuring:
  #   a, b = expr;
  #   a: Int32, b: Float64 = expr;
  # Existing names are reassigned by the annotator; new names are declared.
  sig { params(default_mutable: T::Boolean).returns(AST::DestructuringAssignment) }
  def parse_destructuring_assign(default_mutable: false)
    start_token = current
    targets = [parse_destructure_target(default_mutable: default_mutable)]

    while match!(:CHAR, ',')
      targets << parse_destructure_target(default_mutable: default_mutable)
    end

    consume(:CHAR, '=')
    value = parse_expression
    consume(:CHAR, ';')
    AST::DestructuringAssignment.new(start_token, targets, value)
  end

  sig { params(default_mutable: T::Boolean).returns(AST::DestructureTarget) }
  def parse_destructure_target(default_mutable: false)
    mutable = default_mutable
    mutable = true if match!(:KEYWORD, 'MUTABLE')
    name_tok = consume(:VAR_ID)
    type_annotation = nil
    if match!(:CHAR, ':')
      type_annotation = parse_type_annotation
    end
    AST::DestructureTarget.new(name_tok, name_tok.text!, type_annotation, mutable)
  end

  # Parse a VAR_ID-led expression exactly once.  If `=`, `op=`, or a type
  # annotation follows, classify the already-parsed expression as an assignment
  # target.  Calls and value blocks therefore cannot be recursively parsed once
  # during assignment speculation and again as an expression statement.
  sig { returns(ParsedVarForm) }
  def parse_var_form
    target_token = current
    target = parse_expression

    # Optional type annotation for simple identifiers: x: Type = ...
    opt_type = nil
    if target.is_a?(AST::Identifier) && match?(:CHAR, ':')
      consume(:CHAR, ':')
      opt_type = parse_inferred_wrapper_annotation || parse_type_annotation
    end

    # Compound assignment: x += expr  →  x = x + expr
    if match?(:COMPOUND_ASSIGN)
      unless target.is_a?(AST::Identifier) || target.is_a?(AST::GetField) || target.is_a?(AST::GetIndex)
        error!(target_token, :INVALID_ASSIGNMENT)
      end

      op_token = consume(:COMPOUND_ASSIGN)
      op_char = op_token.text![0]  # '+=' → '+', '-=' → '-', etc.
      op_sym = AST::OP_TO_OP_CODE[T.unsafe(op_char)] || T.unsafe(op_char).to_sym
      rhs = parse_expression

      # Desugar: target op= rhs  →  target = target op rhs
      desugared_value = AST::BinaryOp.new(op_token, deep_clone_node(target), op_sym, rhs)

      if target.is_a?(AST::Identifier)
        bind = AST::BindExpr.new(target_token, target.name, nil, desugared_value)
        # Preserve the original compound operator so atomic targets can lower
        # to fetch_<op> instead of load/modify/store.
        bind.compound_op = op_sym
        return ParsedVarForm.new(node: bind, assignment: true)
      else
        asgn = AST::Assignment.new(target_token, target, desugared_value)
        asgn.compound_op = op_sym
        return ParsedVarForm.new(node: asgn, assignment: true)
      end
    end

    unless match?(:CHAR, '=')
      consume(:CHAR, '=') if opt_type
      return ParsedVarForm.new(node: target, assignment: false)
    end

    unless target.is_a?(AST::Identifier) || target.is_a?(AST::GetField) || target.is_a?(AST::GetIndex)
      error!(target_token, :INVALID_ASSIGNMENT)
    end

    consume(:CHAR, '=')
    value = parse_expression

    node = if target.is_a?(AST::Identifier)
      AST::BindExpr.new(target_token, target.name, opt_type, value)
    else
      # Field or index assignment — always a reassignment, never a declaration
      AST::Assignment.new(target_token, target, value)
    end
    ParsedVarForm.new(node: node, assignment: true)
  end

  # Binding-only shorthand: `x:! = expr`, `x:? = expr`, `x:!? = expr`, and
  # `x:~ = expr`
  # retain/infer the wrapper around the RHS payload without spelling a
  # redundant concrete type. It is intentionally not a general type spelling.
  sig { returns(T.nilable(Type)) }
  def parse_inferred_wrapper_annotation
    return nil unless match?(:CHAR, '!') || match?(:CHAR, '?') || match?(:CHAR, '~')

    start = current.value
    next_token = peek_at(1)
    suffix = if start == '!' && next_token&.type == :CHAR && T.must(next_token).value == '?'
      "!?".freeze
    else
      start
    end
    required_count = suffix.length
    terminal = peek_at(required_count)
    return nil unless terminal&.type == :CHAR && T.must(terminal).value == '='

    required_count.times { consume(:CHAR) }
    Type.new("#{suffix}Auto")
  end

  sig { returns(AST::Node) }
  def parse_tight_stmt
    tight_token = consume(:KEYWORD, 'TIGHT')
    if match?(:KEYWORD, 'FOR')
      for_node = T.unsafe(parse_for_range)
      for_node.tight = true
      return for_node
    end
    unless match?(:KEYWORD, 'WHILE')
      raise "Expected WHILE or FOR after TIGHT (got #{current.value.inspect})"
    end
    # Reuse the standard WHILE pattern; then annotate as tight
    consume(:KEYWORD, 'WHILE')
    cond  = parse_expression

    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      body = [stmt].compact
    else
      body = parse_keyword_block('DO')
    end

    while_node = AST::WhileLoop.new(tight_token, cond, body, nil)
    while_node.tight = true
    while_node
  end

  sig { returns(AST::ReturnNode) }
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

  sig { returns(AST::ThrowNode) }
  def parse_exit()
    exit_token = consume(:KEYWORD)
    context_expr = nil
    if !match?(:CHAR, ';') && !match?(:CHAR, ')') && !match?(:KEYWORD, 'END')
      context_expr = parse_primary
    end
    match!(:CHAR, ";") # TDOO: Test
    AST::ThrowNode.new(exit_token, context_expr)
  end

  sig { returns(AST::DieNode) }
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


  sig { params(stop_words: T::Array[String]).returns(AST::RawBody) }
  def parse_block_body(stop_words = ['END'])
    stmts = T.let([], AST::RawBody)
    # Keep going until we hit a stop word (END, ELSE, CATCH, }, etc)
    until stop_words.any? { |word| match?(literal_token_type(word), word) } || match?(:EOF)
      stmt = parse_statement()
      stmts << stmt if stmt
    end
    stmts
  end

  sig { params(type: Symbol, open: String, close: String).returns(AST::RawBody) }
  def parse_statement_block(type, open, close)
    consume(type, open)
    body = parse_block_body([close])
    consume(literal_token_type(close), close)
    body
  end

  sig { params(open: String, terminator: String).returns(AST::RawBody) }
  def parse_keyword_block(open, terminator: 'END')
    parse_statement_block(:KEYWORD, open, terminator)
  end

  sig { returns(AST::RawBody) }
  def parse_brace_block
    parse_statement_block(:CHAR, '{', '}')
  end

  sig { returns(AST::BlockExpr) }
  def parse_value_block_expr
    block_token = consume(:CHAR, '{')
    body = T.let([], AST::RawBody)
    result = T.let(nil, T.nilable(AST::Node))

    until match?(:CHAR, '}') || match?(:EOF)
      if current.type == :VAR_ID && destructuring_assignment?
        body << parse_destructuring_assign
        next
      end

      if current.type == :VAR_ID
        parsed = parse_var_form
        if parsed.assignment || match!(:CHAR, ';')
          consume(:CHAR, ';') if parsed.assignment
          body << parsed.node
          next
        end
        result = parsed.node
        break
      end

      if (stmt = parse_value_block_keyword_statement)
        body << stmt
        next
      end

      expr = parse_expression
      if match!(:CHAR, ';')
        body << expr
        next
      else
        result = expr
        break
      end
    end

    unless result
      error!(current, :UNEXPECTED_TOKEN_LINE, value: current.value, type: current.type, line: current.line)
    end

    consume(:CHAR, '}')
    AST::BlockExpr.new(block_token, body, result)
  end

  VALUE_BLOCK_STATEMENT_KEYWORDS = T.let(Set[
    'ASSERT', 'ASSERT_RAISES', 'BENCHMARK', 'BREAK', 'CONTINUE', 'DIE',
    'DO', 'ENUM', 'EXIT', 'EXTERN', 'FN', 'FOR', 'METHOD', 'MUTABLE',
    'IF', 'MATCH', 'PARTIAL', 'PASS', 'PRIVATE', 'PROFILE', 'PUB', 'RAISE', 'RETURN', 'SMASH',
    'STRUCT', 'STUB', 'SYNC', 'TEST', 'TIGHT', 'UNION', 'WHILE', 'WITH',
    'YIELD'
  ], T::Set[String])

  sig { returns(T.nilable(AST::Node)) }
  def parse_value_block_keyword_statement
    return nil unless current.type == :KEYWORD
    return nil unless VALUE_BLOCK_STATEMENT_KEYWORDS.include?(current.value)

    parse_statement
  end

  sig { returns(T::Boolean) }
  def brace_literal_is_hash?
    return false unless match?(:CHAR, '{')
    return true if match_at?(1, :CHAR, '}')
    first = peek_at(1)
    if first&.type == :KEYWORD && VALUE_BLOCK_STATEMENT_KEYWORDS.include?(T.must(first).value)
      return false
    end

    depth = 0
    offset = 0
    loop do
      token = peek_at(offset)
      return false unless token

      if token.type == :CHAR
        token_value = token.text!
        case token_value
        when '{', '(', '['
          if depth > 0 && (closing_index = @delimiter_closings[@pos + offset])
            offset = closing_index - @pos + 1
            next
          end
          depth += 1
        when '}', ')', ']'
          depth -= 1
          return false if depth <= 0
        when ';'
          return false if depth == 1
        when ':'
          return !top_level_assignment_before_brace_delimiter?(offset + 1) if depth == 1
        end
      end

      offset += 1
    end
  end

  sig { params(start_offset: Integer).returns(T::Boolean) }
  def top_level_assignment_before_brace_delimiter?(start_offset)
    depth = 1
    offset = start_offset

    loop do
      token = peek_at(offset)
      return false unless token

      if token.type == :COMPOUND_ASSIGN && depth == 1
        return true
      elsif token.type == :CHAR
        token_value = token.text!
        case token_value
        when '{', '(', '['
          if (closing_index = @delimiter_closings[@pos + offset])
            offset = closing_index - @pos + 1
            next
          end
          depth += 1
        when '}', ')', ']'
          depth -= 1
          return false if depth <= 0
        when ',', ';'
          return false if depth == 1
        when '='
          return true if depth == 1
        end
      end

      offset += 1
    end
  end

  sig { params(partial: T::Boolean).returns(AST::MatchStatement) }
  def parse_match_expr(partial: false)
    start = parse_match_start

    cases = []
    default_case = T.let(nil, T.nilable(AST::RawBody))

    until match?(:KEYWORD, 'END') || match?(:EOF)
      if match?(:KEYWORD, 'DEFAULT')
        consume(:KEYWORD, 'DEFAULT')
        consume(:ARROW)
        default_case = [parse_expression]
        match!(:CHAR, ',')
        break
      end

      arm = parse_match_arm
      cases << build_match_case(arm, [parse_expression])
      match!(:CHAR, ',')
    end

    consume(:KEYWORD, 'END')
    AST::MatchStatement.new(start.token, start.subject, cases, default_case, [], nil, !partial, start.takes)
  end

  # FOR var IN (start ..= end) DO body END   — range iteration
  # FOR var IN (start ..< end) DO body END   — range iteration
  # FOR var IN collection DO body END         — collection iteration
  sig { returns(T.any(AST::ForRange, AST::ForEach)) }
  def parse_for_range
    tok = consume(:KEYWORD, 'FOR')
    var_name = consume(:VAR_ID).text!
    consume(:KEYWORD, 'IN')

    # Grouping is an ordinary primary expression. Let the shared expression
    # parser consume it so suffixes such as `(source).values()` remain part of
    # the iterable instead of being mistaken for tokens after the FOR source.
    expr = parse_expression

    # Shorthand: FOR var IN range -> single_statement;
    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      body = [stmt].compact
    else
      body = parse_keyword_block('DO')
    end

    if expr.is_a?(AST::RangeLit)
      AST::ForRange.new(tok, var_name, expr.start, expr.finish, expr.inclusive, body, nil)
    else
      AST::ForEach.new(tok, var_name, expr, body, nil, false)
    end
  end

  sig { params(partial: T::Boolean).returns(AST::MatchStatement) }
  def parse_match_statement(partial: false)
    start = parse_match_start

    cases = []
    default_case = T.let(nil, T.nilable(AST::RawBody))

    until match?(:KEYWORD, 'END') || match?(:EOF)
      if match?(:KEYWORD, 'DEFAULT')
        consume(:KEYWORD, 'DEFAULT')
        consume(:ARROW)
        default_case = parse_block_body(['END'])
        break
      end

      arm = parse_match_arm
      body = parse_block_body([',', 'DEFAULT', 'WHEN', 'END'])
      cases << build_match_case(arm, body)
      match!(:CHAR, ',')  # consume comma separator between cases if present
    end

    consume(:KEYWORD, 'END')
    AST::MatchStatement.new(start.token, start.subject, cases, default_case, [], nil, !partial, start.takes)
  end

  sig { returns(ParsedMatchStart) }
  def parse_match_start
    token = consume(:KEYWORD, 'MATCH')
    takes = !!match!(:KEYWORD, 'TAKES')
    subject = parse_expression
    consume(:KEYWORD, 'START')
    ParsedMatchStart.new(token: token, subject: subject, takes: takes)
  end

  # Parse the shared MATCH arm header and consume its arrow. Statement and
  # expression MATCH forms differ only in how they parse the body afterward.
  sig { returns(ParsedMatchArm) }
  def parse_match_arm
    if match!(:KEYWORD, 'WHEN')
      condition = parse_expression
      consume(:ARROW)
      return ParsedMatchArm.new(kind: :when, value: condition, extra_values: [])
    end

    if match?(:CHAR, '{')
      pattern = parse_struct_pattern
      consume(:ARROW)
      return ParsedMatchArm.new(kind: :struct_pattern, value: pattern, extra_values: [])
    end

    first_pattern = parse_expression
    extra_patterns = T.let([], T::Array[AST::Node])
    while match?(:CHAR, ',') && multi_pattern_continues?
      consume(:CHAR, ',')
      extra_patterns << parse_expression
    end

    binding = T.let(nil, T.nilable(String))
    destructure = T.let(nil, T.nilable(AST::StructPattern))
    if match!(:KEYWORD, 'AS')
      binding = consume(:VAR_ID).text!
    elsif match?(:CHAR, '{')
      destructure = parse_struct_pattern
    end
    consume(:ARROW)
    ParsedMatchArm.new(
      kind: :eq,
      value: first_pattern,
      extra_values: extra_patterns,
      binding: binding,
      destructure: destructure,
    )
  end

  sig { params(arm: ParsedMatchArm, body: AST::RawBody).returns(AST::MatchCase) }
  def build_match_case(arm, body)
    AST::MatchCase.new(
      kind: arm.kind,
      value: arm.value,
      body: body,
      binding: arm.binding,
      destructure: arm.destructure,
      extra_values: arm.extra_values,
    )
  end

  sig { returns(AST::StructPattern) }
  def parse_struct_pattern
    tok = consume(:CHAR, '{')
    fields = []
    partial = T.let(false, T::Boolean)

    until match?(:CHAR, '}') || match?(:EOF)
      # `...` means "ignore all remaining fields" (partial match)
      if match?(:ELLIPSIS, '...')
        consume(:ELLIPSIS, '...')
        partial = true
        break
      end

      name_tok = consume(:VAR_ID)
      name = name_tok.text!

      if match?(:CHAR, ':')
        consume(:CHAR, ':')
        # `_` as value means wildcard — ignore this field's value
        if current.type == :VAR_ID && current.value == '_'
          consume(:VAR_ID)
          fields << AST::PatternField.new(name: name, value: :wildcard, name_token: name_tok)
        else
          fields << AST::PatternField.new(name: name, value: parse_expression, name_token: name_tok)
        end
      else
        # Bare name: destructuring bind — extract field into a local variable.
        # { x, y } means bind subject.x to x, subject.y to y.
        fields << AST::PatternField.new(name: name, value: :bind, name_token: name_tok)
      end

      match!(:CHAR, ',')  # optional comma between fields
    end

    consume(:CHAR, '}')
    AST::StructPattern.new(tok, fields, partial)
  end

  ERROR_KINDS = T.let(AST::ERROR_KINDS.map(&:to_s).freeze, T::Array[String])

  # RAISE grammar (unified error system):
  #   RAISE                            -- System kind, no type, no msg
  #   RAISE "msg"                      -- System + msg
  #   RAISE Kind                       -- kind only
  #   RAISE Kind, "msg"                -- kind + msg
  #   RAISE Kind, Type                 -- kind + type (first use or verify)
  #   RAISE Kind, Type, "msg"          -- full
  #   RAISE Type                       -- type only (kind looked up at annotator)
  #   RAISE Type, "msg"                -- type + msg
  #
  # Disambiguation: the first TYPE_ID after RAISE is a KIND iff it's in
  # ERROR_KINDS; any other TYPE_ID is a TYPE. When only one TYPE_ID is
  # present, `kind` is nil and the annotator resolves it from the
  # registered (type, kind) entry.
  # Parse a single CATCH item: a bare TYPE_ID that's either a kind (if
  # in ERROR_KINDS) or a type.
  sig { returns(AST::CatchItem) }
  def parse_catch_item
    tok = consume(:TYPE_ID)
    form = ERROR_KINDS.include?(tok.text!) ? :kind : :type
    AST::CatchItem.new(form: form, name: tok.text!, token: tok)
  end

  # Parse a single CATCH WITH filter: a TYPE_ID (error type) or a
  # STRING literal (message).
  sig { returns(T.nilable(AST::CatchFilter)) }
  def parse_catch_filter
    if match?(:TYPE_ID)
      tok = consume(:TYPE_ID)
      AST::CatchFilter.new(form: :type, value: tok.text!, token: tok)
    elsif match?(:STRING)
      tok = current
      str_expr = parse_expression
      AST::CatchFilter.new(form: :message, value: str_expr, token: tok)
    else
      error!(current, :CATCH_WITH_BAD_INNER)
    end
  end

  sig { returns(AST::Raise) }
  def parse_raise_stmt
    tok = consume(:KEYWORD, 'RAISE')

    # Legacy: RAISE "string";
    if match?(:STRING)
      msg = parse_expression
      consume(:CHAR, ';')
      return AST::Raise.new(tok, :System, nil, msg)
    end

    if match?(:CHAR, ';')
      consume(:CHAR, ';')
      return AST::Raise.new(tok, :System, nil, nil)
    end

    first_tok = consume(:TYPE_ID)
    first_is_kind = ERROR_KINDS.include?(first_tok.text!)

    kind = first_is_kind ? first_tok.text!.to_sym : nil
    error_name = first_is_kind ? nil : first_tok.text!
    message = nil

    if match?(:CHAR, ',')
      consume(:CHAR, ',')
      if first_is_kind && match?(:TYPE_ID)
        # Kind, Type[, "msg"]
        error_name = consume(:TYPE_ID).text!
        if match?(:CHAR, ',')
          consume(:CHAR, ',')
          message = parse_expression
        end
      else
        # Kind, "msg"  or  Type, "msg"
        message = parse_expression
      end
    end

    consume(:CHAR, ';')
    AST::Raise.new(tok, kind, error_name, message)
  end

end
