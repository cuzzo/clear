# typed: strict

class ClearParser
  extend T::Sig

  private

  sig { params(rule: ParserRule).returns(AST::Node) }
  def dispatch_primary_rule(rule)
    result = case rule.action
    when :parse_if_expr then parse_if_expr
    when :parse_match_expr then parse_match_expr
    when :parse_partial_match_expr then parse_partial_match_expr
    when :parse_stack_literal then parse_literal(rule.type, :stack)
    when :parse_symbol_literal then parse_symbol_literal
    when :parse_var_id then parse_var_id
    when :parse_true_literal then parse_boolean_literal(true)
    when :parse_false_literal then parse_boolean_literal(false)
    when :parse_nil_literal then parse_nil_literal
    when :parse_default_literal then parse_default_literal
    when :parse_cast then parse_cast
    when :parse_move_node then AST::MoveNode.new(consume(:KEYWORD), parse_expression)
    when :parse_copy_node then AST::CopyNode.new(consume(:KEYWORD, 'COPY'), parse_expression)
    when :parse_clone_node then AST::CloneNode.new(consume(:KEYWORD, 'CLONE'), parse_expression)
    when :parse_share_node then AST::ShareNode.new(consume(:KEYWORD, 'SHARE'), parse_expression)
    when :parse_link_node then AST::LinkNode.new(consume(:KEYWORD, 'LINK'), parse_expression)
    when :parse_resolve_node then AST::ResolveNode.new(consume(:KEYWORD, 'RESOLVE'), parse_expression)
    when :parse_freeze_node then AST::FreezeNode.new(consume(:KEYWORD, 'FREEZE'), parse_expression)
    when :parse_bg_block then parse_bg_block
    when :parse_next_expr then parse_next_expr
    when :parse_sigil_construct then parse_sigil_construct
    when :parse_require_expression then AST::Require.new(consume(:KEYWORD, 'REQUIRE'), consume(:STRING).text!)
    when :parse_select_op then parse_select_op
    when :parse_where_op then AST::WhereOp.new(consume(:KEYWORD, 'WHERE'), parse_expression(1))
    when :parse_index_op then AST::IndexOp.new(consume(:KEYWORD, 'INDEX'), parse_expression(1))
    when :parse_reduce_op then parse_reduce_op
    when :parse_order_by_op then AST::OrderByOp.new(consume(:KEYWORD, 'ORDER_BY'), parse_expression(1))
    when :parse_limit_op then AST::LimitOp.new(consume(:KEYWORD, 'LIMIT'), parse_expression(1))
    when :parse_skip_op then AST::SkipOp.new(consume(:KEYWORD, 'SKIP'), parse_expression(1))
    when :parse_unnest_op then AST::UnnestOp.new(consume(:KEYWORD, 'UNNEST'), parse_expression(1))
    when :parse_distinct_op then AST::DistinctOp.new(consume(:KEYWORD, 'DISTINCT'), parse_expression(1))
    when :parse_each_op then parse_each_op
    when :parse_tap_op then parse_tap_op
    when :parse_find_op then AST::FindOp.new(consume(:KEYWORD, 'FIND'), parse_expression(1))
    when :parse_any_op then AST::AnyOp.new(consume(:KEYWORD, 'ANY'), parse_expression(1))
    when :parse_all_op then AST::AllOp.new(consume(:KEYWORD, 'ALL'), parse_expression(1))
    when :parse_count_op then AST::CountOp.new(consume(:KEYWORD, 'COUNT'), parse_expression(1))
    when :parse_sum_op then AST::SumOp.new(consume(:KEYWORD, 'SUM'), parse_expression(1))
    when :parse_average_op then AST::AverageOp.new(consume(:KEYWORD, 'AVERAGE'), parse_expression(1))
    when :parse_min_op then AST::MinOp.new(consume(:KEYWORD, 'MIN'), parse_expression(1))
    when :parse_max_op then AST::MaxOp.new(consume(:KEYWORD, 'MAX'), parse_expression(1))
    when :parse_take_while_op then AST::TakeWhileOp.new(consume(:KEYWORD, 'TAKE_WHILE'), parse_expression(1))
    when :parse_recover_op then parse_recover_op
    when :parse_collect_op then AST::CollectOp.new(consume(:KEYWORD, 'COLLECT'))
    when :parse_window_op then parse_window_op
    when :parse_join_op then parse_join_op
    when :parse_shard_op then parse_shard_op
    when :parse_concurrent_op then parse_concurrent_op
    when :parse_try_expression then parse_try_expression
    when :parse_unwrap_expression then parse_unwrap_expression
    when :parse_group_expression then parse_group_expression
    else
      raise "Unknown primary parser action #{rule.action}"
    end
    T.must(result)
  end

  sig { returns(AST::SelectOp) }
  def parse_select_op
    token = consume(:KEYWORD, 'SELECT')
    reject_legacy_select_effect_spelling!
    modifier_order = parse_select_modifier_order
    effect_mode = select_effect_mode_for(modifier_order)
    AST::SelectOp.new(token, parse_expression(1), effect_mode,
      modifier_order&.include?('~') == true, modifier_order)
  end

  sig { void }
  def reject_legacy_select_effect_spelling!
    return unless match?(:CHAR, '!') || match?(:CHAR, '?')

    marker = current.value
    marker += '?' if marker == '!' && peek.type == :CHAR && peek.value == '?'
    fix = Fix.new(
      description: fix_description(:INSERT_SELECT_EFFECT_COLON, selector: "SELECT:#{marker}"),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: current.line, col: current.column, length: 0),
        replacement: ':',
      )],
    )
    fixable!(current, code: :SELECT_EFFECT_COLON_REQUIRED,
      selector: "SELECT:#{marker}", category: :syntax, level: :error,
      fixes: [fix], raise_in_collector: true)
  end

  VALID_SELECT_MODIFIER_ORDERS = T.let(%w[! ? !? ~ ~! ~? ~!? !~ !~! !~? !~!?].freeze, T::Array[String])

  sig { returns(T.nilable(String)) }
  def parse_select_modifier_order
    return nil unless match?(:CHAR, ':')
    modifier = peek
    return nil unless modifier.type == :CHAR && %w[! ? ~].include?(modifier.value)

    consume(:CHAR, ':')
    order = +''
    while match?(:CHAR, '!') || match?(:CHAR, '?') || match?(:CHAR, '~')
      order << current.value
      consume(:CHAR, current.value)
    end
    unless VALID_SELECT_MODIFIER_ORDERS.include?(order)
      error!(modifier, :SELECT_MODIFIER_ORDER_INVALID, order: order)
    end
    order
  end

  sig { params(order: T.nilable(String)).returns(T.nilable(Symbol)) }
  def select_effect_mode_for(order)
    return nil if order.nil? || order == '~'
    inner = order.delete('~')
    return :fallible_optional if inner.include?('!') && inner.include?('?')
    return :optional if inner.include?('?')
    return :fallible if inner.include?('!')

    nil
  end

  sig { returns(AST::Cast) }
  def parse_cast
    token = consume(:KEYWORD, 'CAST')
    consume(:CHAR, '(')
    value = parse_expression
    consume(:KEYWORD, 'AS')
    type = parse_type_annotation
    consume(:CHAR, ')')
    AST::Cast.new(token, value, type)
  end

  sig { returns(AST::Node) }
  def parse_partial_match_expr
    consume(:KEYWORD, 'PARTIAL')
    parse_match_expr(partial: true)
  end

  sig { returns(AST::Literal) }
  def parse_symbol_literal
    colon_tok = consume(:CHAR, ':')
    error!(colon_tok, :EXPECTED_SYMBOL_AFTER_COLON) unless match?(:VAR_ID) || match?(:TYPE_ID)
    ident_tok = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
    AST::Literal.new(colon_tok, :SYMBOL, ident_tok.text!, :stack)
  end

  sig { params(value: T::Boolean).returns(AST::Literal) }
  def parse_boolean_literal(value)
    t = consume(:KEYWORD)
    AST::Literal.new(t, :BOOLEAN, value)
  end

  sig { returns(AST::Literal) }
  def parse_nil_literal
    t = consume(:KEYWORD)
    AST::Literal.new(t, :NIL, nil)
  end

  sig { returns(AST::DefaultLit) }
  def parse_default_literal
    t = consume(:KEYWORD, 'DEFAULT')
    AST::DefaultLit.new(t)
  end

  sig { returns(AST::Node) }
  def parse_group_expression
    consume(:CHAR, '(')
    expr = parse_expression
    # (expr EXISTS AS name): optional binding group used in IF chains.
    if match?(:KEYWORD, 'EXISTS') || match?(:KEYWORD, 'IS_OK')
      predicate_tok = consume(:KEYWORD)
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      error!(current, :CONDITIONAL_BINDING_UNDER_OR) if match?(:KEYWORD, 'OR')
      consume(:CHAR, ')')
      bind = AST::BinaryOp.new(predicate_tok, expr, :BIND_VAR,
               AST::Identifier.new(name_tok, name_tok.text!))
      bind.paren_bind = true
      return parse_suffixes(bind)
    elsif match?(:KEYWORD, 'AS')
      emit_legacy_optional_binding!(current)
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      consume(:CHAR, ')')
      bind = AST::BinaryOp.new(name_tok, expr, :BIND_VAR,
               AST::Identifier.new(name_tok, name_tok.text!))
      bind.paren_bind = true
      return parse_suffixes(bind)
    end
    consume(:CHAR, ')')
    parse_suffixes(expr)
  end

  sig { params(as_token: Lexer::Token).void }
  def emit_legacy_optional_binding!(as_token)
    fix = Fix.new(
      description: fix_description(:INSERT_EXISTS_BEFORE_AS),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: as_token.line, col: as_token.column, length: 0),
        replacement: 'EXISTS '
      )]
    )
    fixable!(as_token,
      code: :OPTIONAL_BINDING_REQUIRES_EXISTS,
      category: :syntax,
      level: :error,
      fixes: [fix])
  end

  sig { params(rule: ParserRule, lhs: AST::Node).returns(AST::Node) }
  def dispatch_suffix_rule(rule, lhs)
    case rule.action
    when :parse_index_suffix then parse_index_suffix(lhs)
    when :parse_static_call_suffix then parse_static_call_suffix(lhs)
    when :parse_dot_suffix then parse_dot_suffix(lhs)
    when :parse_func_call_suffix then parse_func_call_suffix(lhs)
    when :parse_optional_unwrap_suffix then parse_optional_unwrap_suffix(lhs)
    when :parse_tense_navigation_suffix then parse_tense_navigation_suffix(lhs)
    when :parse_exists_suffix then parse_exists_suffix(lhs)
    when :parse_is_ok_suffix then parse_is_ok_suffix(lhs)
    when :parse_is_ready_suffix then parse_is_ready_suffix(lhs)
    when :parse_capability_wrap_suffix then parse_capability_wrap_suffix(lhs)
    when :parse_inline_union_variant_suffix then parse_inline_union_variant_suffix(lhs)
    else
      raise "Unknown suffix parser action #{rule.action}"
    end
  end

  sig { params(rule: ParserRule, lhs: AST::Node).returns(T::Boolean) }
  def suffix_rule_applicable?(rule, lhs)
    case rule.action
    when :parse_exists_suffix, :parse_is_ok_suffix
      !conditional_binding_suffix?
    when :parse_inline_union_variant_suffix
      !match_destructure_brace? && AST.inline_union_constructor_target?(lhs)
    when :parse_tense_navigation_suffix
      !tense_navigation_marker_run.nil?
    else
      true
    end
  end

  sig { returns(T::Boolean) }
  def conditional_binding_suffix?
    peek.type == :KEYWORD && peek.value == 'AS'
  end

  sig { params(lhs: AST::Node).returns(AST::UnaryOp) }
  def parse_exists_suffix(lhs)
    token = consume(:KEYWORD, 'EXISTS')
    AST::UnaryOp.new(token, :EXISTS, lhs)
  end

  sig { params(lhs: AST::Node).returns(AST::UnaryOp) }
  def parse_is_ok_suffix(lhs)
    token = consume(:KEYWORD, 'IS_OK')
    AST::UnaryOp.new(token, :IS_OK, lhs)
  end

  sig { params(lhs: AST::Node).returns(AST::UnaryOp) }
  def parse_is_ready_suffix(lhs)
    error!(current, :IS_READY_CANNOT_BIND) if conditional_binding_suffix?
    token = consume(:KEYWORD, 'IS_READY')
    AST::UnaryOp.new(token, :IS_READY, lhs)
  end

  sig { params(lhs: AST::Node).returns(AST::Node) }
  def parse_index_suffix(lhs)
    start_token = consume(:CHAR, '[')
    first = parse_expression
    if first.is_a?(AST::RangeLit)
      # parse_expression consumed the range operator: 0..<3 → RangeLit(0, 3, false)
      consume(:CHAR, ']')
      AST::Slice.new(first.token, lhs, first.start, first.finish, !first.inclusive)
    elsif match?(:RANGE, '..')
      # SLICE: list[0..3] (inclusive end)
      range_token = consume(:RANGE, '..')
      last = parse_expression
      consume(:CHAR, ']')
      AST::Slice.new(range_token, lhs, first, last, false)
    else
      # INDEX: list[0]
      # INDEX: hash["OK"]
      if match!(:CHAR, ',')
        indices = T.let([first], T::Array[AST::Node])
        loop do
          indices << parse_expression
          break unless match!(:CHAR, ',')
        end
        consume(:CHAR, ']')
        return AST::GetIndex.new(start_token, lhs, AST::TupleLit.new(start_token, indices, nil))
      end
      consume(:CHAR, ']')
      AST::GetIndex.new(start_token, lhs, first)
    end
  end

  sig { params(lhs: AST::Node).returns(AST::StaticCall) }
  def parse_static_call_suffix(lhs)
    colon_token = consume(:DOUBLE_COLON, '::')
    method_token = consume(:VAR_ID)
    _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    AST::StaticCall.new(colon_token, lhs, method_token.text!, args)
  end

  sig { params(lhs: AST::Node).returns(AST::Node) }
  def parse_dot_suffix(lhs)
    dot_token = consume(:CHAR, '.')

    if match?(:CHAR, '*')
      star_token = consume(:CHAR, '*')
      AST::GetField.new(star_token, lhs, '*')
    else
      name_token = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
      name = name_token.text!
      # The lexer intentionally keeps identifiers and numeric literals
      # separate, so Rust-style Tuple fields arrive as `_` then `0`.
      # Join only this exact positional spelling; ordinary names cannot
      # absorb a trailing number here.
      if name == "_" && (match?(:NUMBER) || match?(:INT64))
        name = "_#{consume_number.value}"
      end

      # Predicate suffix: name? followed by ( → method call with ? suffix
      if match?(:CHAR, '?') && peek_at(1)&.value == '('
        consume(:CHAR, '?')
        name = "#{name}?"
      end

      if match?(:CHAR, '(')
        # Method Call
        _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
        call = AST::MethodCall.new(name_token, lhs, name, args)
        stamp_source_range_from_node!(call, lhs, previous)
      else
        # Field Access
        AST::GetField.new(name_token, lhs, name)
      end
    end
  end

  sig { params(lhs: AST::Node).returns(AST::FuncCall) }
  def parse_func_call_suffix(lhs)
    start_token, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    call = AST::FuncCall.new(start_token, lhs, args)
    stamp_source_range_from_node!(call, lhs, previous)
    call
  end

  # TRY is a prefix propagation boundary. A reader sees the potential early
  # return before the operand, just as they do with Zig's `try` and Swift's
  # `try`.
  sig { returns(AST::UnaryOp) }
  def parse_try_expression
    token = consume(:KEYWORD, 'TRY')
    AST::UnaryOp.new(token, :TRY, parse_unary)
  end

  # UNWRAP makes an optional-to-definite conversion visible at the binding
  # site. Unlike TRY, it deliberately uses the existing explicit optional
  # unwrap semantics rather than adding an error channel to the function.
  sig { returns(AST::OptionalUnwrap) }
  def parse_unwrap_expression
    token = consume(:KEYWORD, 'UNWRAP')
    AST::OptionalUnwrap.new(token, parse_unary)
  end

  sig { params(lhs: AST::Node).returns(AST::Node) }
  def parse_optional_unwrap_suffix(lhs)
    marker_run = tense_navigation_marker_run
    if marker_run == "?"
      q_token = consume(:CHAR, '?')
      return AST::OptionalUnwrap.new(q_token, lhs)
    end
    return parse_tense_navigation_suffix(lhs) if marker_run

    q_token = consume(:CHAR, '?')
    AST::OptionalUnwrap.new(q_token, lhs)
  end

  sig { params(lhs: AST::Node).returns(AST::Node) }
  def parse_tense_navigation_suffix(lhs)
    token = current
    markers = T.must(tense_navigation_marker_run)
    unless TypeExpression::VALID_TENSE_ORDERS.include?(markers) && !markers.empty?
      error!(token, :TENSE_NAVIGATION_ORDER, markers: markers)
    end
    markers.each_char { |marker| consume(:CHAR, marker) }
    AST::TenseNavigation.new(token, lhs, markers)
  end

  sig { returns(T.nilable(String)) }
  def tense_navigation_marker_run
    offset = T.let(0, Integer)
    markers = +""
    loop do
      token = peek_at(offset)
      break if token.nil? || token.type != :CHAR || !%w[! ? ~].include?(token.value)

      markers << token.value
      offset += 1
    end
    dot = peek_at(offset)
    return nil if markers.empty? || dot.nil? || dot.type != :CHAR || dot.value != "."

    markers
  end

  sig { params(lhs: AST::Node).returns(AST::CapabilityWrap) }
  def parse_capability_wrap_suffix(lhs)
    token = consume(:VAR_ID)
    emit_boxed_capability_migration(token)
    attrs = T.must(CAP_SIGIL_ATTRS[token.text!])
    joined = parse_cap_join(token, attrs)
    cw = AST::CapabilityWrap.new(token, lhs, joined.ownership, joined.sync, joined.layout)
    cw.lock_rank = joined.lock_rank if joined.lock_rank
    cw
  end

  # Inline union variant constructor: TypeName.VariantName{ field: val, ... }
  # Only fires when lhs is a GetField whose target is a TYPE_ID (uppercase) identifier.
  # Applicability is checked before dispatch, so this method always constructs.
  sig { params(lhs: AST::Node).returns(AST::UnionVariantLit) }
  def parse_inline_union_variant_suffix(lhs)
    tok = current
    field_pairs = T.let([], T::Array[[String, AST::Node]])
    _, field_pairs = parse_comma_seq(:CHAR, '{', '}') do
      key_token = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
      k = key_token.text!
      consume(:CHAR, ':')
      v = parse_expression
      [k, v]
    end
    target = T.cast(lhs, AST::GetField)
    target_ident = T.cast(target.target, AST::Identifier)
    AST::UnionVariantLit.new(tok, target_ident.name, T.cast(target.field, String), field_pairs.to_h, :stack)
  end

  # In MATCH grammar, a brace immediately followed by the arm arrow is a
  # destructuring pattern rather than a struct/union constructor. The token
  # index makes that distinction explicit without parser-wide mode state.
  sig { returns(T::Boolean) }
  def match_destructure_brace?
    return false unless match?(:CHAR, '{')
    closing_index = @delimiter_closings[@pos]
    return false unless closing_index
    following = T.must(@tokens[closing_index + 1]) # token streams always end in EOF
    following.type == :ARROW
  end

  sig { params(type: Symbol, storage: Symbol).returns(AST::Node) }
  def parse_literal(type, storage)
    token = consume(type)
    node = AST::Literal.new(token, type, token.value, storage)
    parse_suffixes(node)
  end

  sig { params(val: String).returns(Symbol) }
  def literal_token_type(val)
    val.match?(/[a-zA-Z]/) ? :KEYWORD : :CHAR
  end



  sig { params(precedence: Integer).returns(AST::Node) }
  def parse_expression(precedence = 0)
    @budget.enter!
    expression = parse_expression_body(precedence)
    @budget.leave!
    expression
  end

  sig { params(precedence: Integer).returns(AST::Node) }
  def parse_expression_body(precedence)
    start_token = current
    lhs = parse_unary

    while (raw_op_token = current)
      op_prec = binary_operator_precedence(raw_op_token)
      break unless op_prec && op_prec > precedence
      op_token = canonical_binary_operator_token(raw_op_token)

      # GUARD CLAUSE: AS is used as a keyword in CAST, and only binds if followed by an alias ($...)
      if op_token.text! == 'AS' && (peek.type == :TYPE_ID || peek.text![0] != '$')
        break
      end

      consume(raw_op_token.type)
      lhs = parse_binary_op(lhs, op_token, op_prec)
    end

    stamp_source_range!(lhs, start_token, previous)
  end

  sig { params(token: Lexer::Token).returns(T.nilable(Integer)) }
  def binary_operator_precedence(token)
    if token.type == :LEGACY_LOGICAL
      return token.text! == '&&' ? 5 : 4
    end

    get_precedence(token)
  end

  sig { params(token: Lexer::Token).returns(T.nilable(Integer)) }
  def get_precedence(token)
    return nil unless token.type == :CHAR || token.type == :KEYWORD || token.type == :SMOOTH || token.type == :OR_ELSE || token.type == :RANGE_EXCL || token.type == :RANGE_INCL

    # Precedence levels (higher = tighter binding)
    case token.text!
    when '|>'             then 1
    when 'OR_ELSE', 'AS' then 2
    when '..<', '..<=', '..=' then 3
    when 'OR'             then 4
    when 'AND'            then 5
    when 'IS_A', '==', '!=', '<', '>', '<=', '>=' then 6
    when 'BIT_OR'          then 7
    when 'XOR'             then 8
    when 'BIT_AND'         then 9
    when '<<', '>>'        then 10
    when '+', '$+', '-', '%+', '%-', '!+', '!-' then 11
    when '*', '/', 'MOD', '%*', '!*'     then 12
    when '**'             then 13
    else nil
    end
  end

  sig { params(token: Lexer::Token).returns(Lexer::Token) }
  def canonical_binary_operator_token(token)
    return token unless token.type == :LEGACY_LOGICAL

    legacy = token.text!
    replacement = legacy == '&&' ? 'AND' : 'OR'
    fix = Fix.new(
      description: fix_description(
        :REPLACE_OPERATOR_TYPO,
        match: legacy,
        replace: replacement,
        label: "Boolean operator (use `#{replacement}`, not `#{legacy}`)",
      ),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: token.line, col: token.column, length: 2),
        replacement: replacement
      )]
    )
    fixable!(token,
      code: :OPERATOR_TYPO_SUGGESTION,
      match: legacy,
      replace: replacement,
      category: :syntax,
      level: :error,
      fixes: [fix])

    canonical = T.let(token.dup, Lexer::Token)
    canonical.type = :KEYWORD
    canonical.value = replacement
    canonical
  end

  sig { params(lhs: AST::Node, op_token: Lexer::Token, op_prec: Integer).returns(AST::Node) }
  def parse_binary_op(lhs, op_token, op_prec)
    op_val = op_token.text!
    
    next_prec = (op_val == '**') ? op_prec - 1 : op_prec

    case op_val
    when 'AS'
      as_rhs = parse_var_id
      unless as_rhs.is_a?(AST::Identifier)
        error!(as_rhs, :EXPECTED_IDENT_AFTER_AS, got: "expression")
      end
      return AST::BinaryOp.new(op_token, lhs, :BIND_VAR, as_rhs)

    when 'OR_ELSE'
      or_rhs = parse_or_else
      return AST::BinaryOp.new(op_token, lhs, :OR_ELSE, or_rhs)

    when 'OR'
      or_rhs = parse_expression(next_prec)
      return AST::BinaryOp.new(op_token, lhs, :OR, or_rhs)

    when 'AND'
      and_rhs = parse_expression(next_prec)
      return AST::BinaryOp.new(op_token, lhs, :AND, and_rhs)

    when 'IS_A'
      is_a_rhs = parse_is_a_rhs
      binding = nil
      if match?(:KEYWORD, 'AS')
        consume(:KEYWORD, 'AS')
        binding = consume(:VAR_ID).text!
      end
      return AST::IsA.new(op_token, lhs, is_a_rhs, binding)

    when '|>'
      # SMOOTH binds Level 1, but its RHS allows chained pipe operators
      pipe_rhs = parse_expression(next_prec)
      normalized_pipe_rhs = T.let(pipe_rhs, AST::Node)
      # Predicate suffix: x |> isPositive? parses as OptionalUnwrap(Identifier).
      # Unwrap and restore the ? suffix as part of the function name.
      if pipe_rhs.is_a?(AST::OptionalUnwrap)
        unwrap_rhs = T.unsafe(pipe_rhs)
        if unwrap_rhs.target.is_a?(AST::Identifier)
          target_ident = T.cast(unwrap_rhs.target, AST::Identifier)
          normalized_pipe_rhs = AST::Identifier.new(unwrap_rhs.token, "#{target_ident.name}?")
        end
      end
      return AST::BinaryOp.new(op_token, lhs, :SMOOTH, normalized_pipe_rhs)

    when '..<'
      range_rhs = parse_expression(next_prec)
      return AST::RangeLit.new(op_token, lhs, range_rhs, false)

    when '..<=', '..='
      range_rhs = parse_expression(next_prec)
      return AST::RangeLit.new(op_token, lhs, range_rhs, true)
    end

    rhs = parse_expression(next_prec)
    op_sym = AST::OP_TO_OP_CODE[op_val] || op_val.to_sym

    AST::BinaryOp.new(op_token, lhs, op_sym, rhs)
  end

  sig { returns(T.any(AST::Node, Type)) }
  def parse_is_a_rhs
    return parse_type_annotation if is_a_rhs_type_annotation?

    parse_unary
  end

  sig { returns(T::Boolean) }
  def is_a_rhs_type_annotation?
    return true if match?(:KEYWORD, 'FN')
    return true if match?(:KEYWORD, 'SHARED')
    return true if match?(:KEYWORD, 'Auto')
    return true if match?(:CHAR, '~') || match?(:CHAR, '!') || match?(:CHAR, '?')
    return true if match?(:CHAR, '[') || match?(:CHAR, '{')
    return false unless match?(:TYPE_ID)

    nxt = peek_at(1)
    return false unless nxt
    return true if nxt.type == :VAR_ID && CAPABILITY_TOKENS.include?(nxt.value)
    nxt.type == :CHAR && ["<", "["].include?(nxt.value)
  end

  sig { returns(AST::Node) }
  def parse_or_else
    # Syntax: ... OR_ELSE RETURN
    if match!(:KEYWORD, 'RETURN')
      rhs = AST::ReturnNode.new(previous, nil)

    # Syntax: ... OR_ELSE RAISE (bubble up error - Zig's `try`)
    elsif match!(:KEYWORD, 'RAISE')
      rhs = AST::OrElseRaise.new(previous)

    # Syntax: ... OR_ELSE EXIT  (unified error system — mirrors RAISE):
    #   OR_ELSE EXIT "msg"                   — inherit kind/type, replace msg
    #   OR_ELSE EXIT Kind                    — set kind, clear type
    #   OR_ELSE EXIT Kind, "msg"             — set kind, clear type, replace msg
    #   OR_ELSE EXIT Kind, Type              — set kind + type
    #   OR_ELSE EXIT Kind, Type, "msg"       — full
    #   OR_ELSE EXIT Type                    — set type (kind auto-resolved)
    #   OR_ELSE EXIT Type, "msg"             — set type + msg
    # Disambiguation: first TYPE_ID is a kind iff it's in ERROR_KINDS;
    # otherwise it's a type. Unspecified fields inherit from the
    # pre-existing rt.__error at lowering time.
    elsif match!(:KEYWORD, 'EXIT')
      exit_tok = previous
      kind = nil
      error_name = nil
      message = nil

      if match?(:STRING)
        # OR_ELSE EXIT "msg" — pure message override
        message = parse_expression
      elsif match?(:TYPE_ID)
        first_tok = consume(:TYPE_ID)
        first_is_kind = ERROR_KINDS.include?(first_tok.text!)
        if first_is_kind
          kind = first_tok.text!.to_sym
        else
          error_name = first_tok.text!
        end
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
      else
        # No args — legacy "just bubble the existing error" form.
        # Kept for backward compat; equivalent to OR_ELSE RAISE.
      end

      rhs = AST::OrElseExit.new(exit_tok, kind, error_name, message)

    # Syntax: ... OR_ELSE PASS (ignore error, use undefined/default)
    elsif match!(:KEYWORD, 'PASS')
      rhs = AST::OrElsePass.new(previous)

    # Syntax: ... OR_ELSE PRUNE (discard error, skip item — concurrent SELECT/WHERE)
    elsif match!(:KEYWORD, 'PRUNE')
      rhs = AST::OrElsePrune.new(previous)

    # Syntax: ... OR_ELSE BREAK (error-to-break coercion, valid only inside loops)
    elsif match!(:KEYWORD, 'BREAK')
      rhs = AST::OrElseBreak.new(previous)

    else
      # Syntax: ... OR ELSE value, or standard `... OR expression`.
      match!(:KEYWORD, 'ELSE')
      rhs = parse_primary
    end
  end

  sig { returns(AST::Node) }
  def parse_unary
    v = current.value
    if current.type == :CHAR && v == '&'
      marker = consume(:CHAR, '&')
      target = parse_unary
      if mark_explicit_mutable_receiver!(target, marker)
        return target
      end
      return AST::MutableBorrow.new(marker, target)
    end
    if current.type == :CHAR && AST::UNARY_OPS.include?(v)
      op_token = consume(:CHAR)
      # Recursively parse the thing being negated (handles --5)
      right = parse_unary
      return AST::UnaryOp.new(op_token, AST::OP_TO_OP_CODE[v], right)
    end
    # Call-site override syntax is reserved here; the annotator rejects it
    # until runtime semantics are implemented.
    if current.type == :VAR_ID && (current.value == '@thunk' || current.value == '@maxDepth')
      sigil_tok = consume(:VAR_ID)
      consume(:CHAR, '(')
      n_tok = current
      n_lit = consume_number
      n = n_lit.value.to_i
      if n <= 0
        error!(n_tok, :SIGIL_N_NONPOSITIVE, sigil: sigil_tok.text!, count: n)
      end
      consume(:CHAR, ')')
      inner = parse_primary
      return AST::CallSiteOverride.new(sigil_tok, sigil_tok.text!.sub('@', '').to_sym, n, inner)
    end
    parse_primary
  end

  # `&` marks the mutating call. Prefix TRY composes normally as
  # `TRY &cache.put(...)`; it is not a postfix wrapper around the receiver.
  sig { params(node: AST::Node, marker: Lexer::Token).returns(T::Boolean) }
  def mark_explicit_mutable_receiver!(node, marker)
    if node.is_a?(AST::MethodCall)
      node.mark_explicit_mutable_receiver!(marker)
      return true
    end

    wrapped = T.let(case node
    when AST::GetField, AST::GetIndex, AST::OptionalUnwrap, AST::TenseNavigation
      node.target
    end, T.nilable(AST::Node))
    return false if wrapped.nil?

    mark_explicit_mutable_receiver!(wrapped, marker)
  end
  private :mark_explicit_mutable_receiver!

  sig { params(lhs: AST::Node).returns(AST::Node) }
  def parse_suffixes(lhs)
    loop do
      rule = SUFFIX_RULE_INDEX[ClearParser.token_rule_key(current)]
      break unless rule
      break unless suffix_rule_applicable?(rule, lhs)
      lhs = dispatch_suffix_rule(rule, lhs)
    end
    lhs
  end

  sig { returns(AST::Node) }
  def parse_var_id
    var_token = consume(:VAR_ID)
    name = var_token.text!
    node = T.let(AST::Identifier.new(var_token, name), AST::Node)

    # Predicate suffix: name? followed by ( → function call with ? suffix
    if match?(:CHAR, '?') && peek_at(1)&.value == '('
      consume(:CHAR, '?')
      name = "#{name}?"
    end

    if match?(:CHAR, '(')
      _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      node = AST::FuncCall.new(var_token, name, args)
      stamp_source_range!(node, var_token, previous)
    end

    return parse_suffixes(node)
  end


  sig { returns(AST::Node) }
  def parse_primary
    rule = PRIMARY_RULE_INDEX[ClearParser.token_rule_key(current)]
    rule ||= PRIMARY_RULE_INDEX[ClearParser.rule_key(current.type, nil)]
    return dispatch_primary_rule(rule) if rule
    return parse_unary() if current.type == :CHAR && (AST::UNARY_OPS.include?(current.value) || current.value == '&')
    lit = parse_lit(:stack)
    return parse_suffixes(lit) if !lit.nil?
    error!(current, :UNEXPECTED_TOKEN_LINE, value: current.value, type: current.type, line: current.line)
  end

  # Returns true if, starting from current position '<', the token stream matches
  # a generic argument list followed by end_char. Kept as a token-level peek so
  # expression parsing can disambiguate `Pair<T>{...}` from `<`/`>`.
  # Used to disambiguate generic annotations from comparison operators.
  sig { params(end_char: String).returns(T::Boolean) }
  def peek_generic_angle_params?(end_char)
    return false unless match?(:CHAR, '<')
    offset = 1
    depth = 1
    loop do
      token = peek_at(offset)
      return false unless token
      if token.type == :CHAR && token.value == '<'
        depth += 1
      elsif token.type == :CHAR && (token.value == '>' || token.value == '>>')
        depth -= token.value == '>>' ? 2 : 1
        if depth == 0
          following = peek_at(offset + 1)
          return !following.nil? && following.type == :CHAR && following.value == end_char
        end
      end
      offset += 1
    end
  end

  # Struct literal: Pair<Number>{ ... }
  sig { returns(T::Boolean) }
  def peek_is_generic_struct_lit?
    peek_generic_angle_params?('{')
  end

  sig { returns(T::Array[ParsedStructField]) }
  def parse_struct_literal_fields
    _, fields = parse_comma_seq(:CHAR, '{', '}') do
      name_token = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
      consume(:CHAR, ':')
      ParsedStructField.new(
        name: name_token.text!,
        value: parse_expression,
        name_token: name_token,
      )
    end
    fields
  end

  sig do
    params(
      type_token: Lexer::Token,
      name: String,
      storage: Symbol,
      type_args: T.nilable(T::Array[Type]),
    ).returns(AST::StructLit)
  end
  def parse_struct_literal(type_token, name, storage, type_args = nil)
    values = T.let({}, T::Hash[String, AST::Node])
    field_tokens = T.let({}, T::Hash[String, Lexer::Token])
    parse_struct_literal_fields.each do |field|
      values[field.name] = field.value
      field_tokens[field.name] = field.name_token
    end

    literal = AST::StructLit.new(type_token, name, values, storage, type_args)
    literal.field_tokens = field_tokens
    literal
  end

  sig { params(storage: Symbol).returns(T.nilable(AST::Node)) }
  def parse_lit(storage)
    if match?(:TYPE_ID)
      type_token = consume(:TYPE_ID)
      name = type_token.text!
      # Collection constructor: List[] / Pool[] (with optional capabilities)
      # Element type is inferred from first append/insert.
      if %w[List Pool Set].include?(name) && match?(:CHAR, '[')
        # List[] / List[1, 2, 3] -- empty or element-initialized.
        _, ctor_items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
        collection = { "List" => :list, "Pool" => :pool, "Set" => :set }.fetch(name)
        is_soa = false
        shard_count = nil
        caps = parse_constructor_capabilities(type_token, name)
        shard_count = caps.shard_count
        is_soa = caps.is_soa
        node = AST::ListLit.new(type_token, ctor_items, storage)
        node.constructor_options = AST::CollectionConstructorFact.new(
          collection: collection,
          soa: is_soa,
          shard_count: shard_count
        )
        return node
      elsif name == "Tuple" && match?(:CHAR, '{')
        tuple_token, tuple_items = parse_comma_seq(:CHAR, '{', '}') { parse_expression }
        return AST::TupleLit.new(tuple_token, tuple_items, storage)
      elsif match?(:CHAR, '<') && peek_is_generic_struct_lit?
        # Generic struct literal: Pair<Number>{ first: 1.0, second: 2.0 }
        consume(:CHAR, '<')
        type_args = []
        until generic_close?
          type_args << parse_type_annotation
          match!(:CHAR, ',')
        end
        consume_generic_close
        return parse_struct_literal(type_token, name, storage, type_args)
      elsif match?(:CHAR, '{') && !match_destructure_brace?
        # Struct literal: User{ id: 1 }
        return parse_struct_literal(type_token, name, storage)
      else
        # Type name reference — e.g. enum variant access: Color.Red
        node = AST::Identifier.new(type_token, name)
        return parse_suffixes(node)
      end
    elsif match?(:CHAR, '[')
      bracket_token, items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
      return AST::ListLit.new(bracket_token, items, storage)
    elsif match?(:CHAR, '{')
      return parse_value_block_expr unless brace_literal_is_hash?

      start_token, pairs = parse_comma_seq(:CHAR, '{', '}') do
        k = parse_expression; consume(:CHAR, ':'); v = parse_expression
        [k, v]
      end
      return AST::HashLit.new(start_token, pairs.to_h, storage)
    elsif match?(:STRING)
      return AST::Literal.new(current, :STRING, consume(:STRING).text!, storage)
    end
    return nil
  end

  sig { returns(T.nilable(AST::Node)) }
  def parse_sigil_construct
    percent_token = consume(:PERCENT)
    # % is now a no-op for storage: escape analysis and declared types determine heap vs stack.
    lit = parse_lit(:stack)
    return parse_suffixes(lit) if !lit.nil?
    if match?(:CHAR, '(')
      params = parse_argument_list()
      captures = []
      if match!(:KEYWORD, 'USE')
        captures = parse_capture_list
      end
      consume(:ARROW, '->')
      body = match?(:CHAR, '{') ? parse_value_block_expr : parse_expression
      return AST::LambdaLit.new(percent_token, params, captures, body, :stack, nil)
    end
  end

  # REDUCE(initial_value) expression
  # e.g., myList |> REDUCE(0) acc + _.value
  #
  # The body must use the pipe-precedence (1) so it stops before the
  # next `|>` token, matching every other pipeline op (SELECT/WHERE/...).
  # Otherwise `list |> REDUCE(0) acc + _ |> COLLECT` parses as
  # `list |> REDUCE(0) (acc + _ |> COLLECT)` -- COLLECT gets eaten by
  # the body and the chain breaks.
  sig { returns(AST::ReduceOp) }
  def parse_reduce_op
    reduce_token = consume(:KEYWORD, 'REDUCE')
    consume(:CHAR, '(')
    initial_value = parse_expression
    consume(:CHAR, ')')
    body = parse_expression(1)
    AST::ReduceOp.new(reduce_token, initial_value, body)
  end

  # RECOVER(default_expr) — pipeline error recovery
  sig { returns(AST::RecoverOp) }
  def parse_recover_op
    tok = consume(:KEYWORD, 'RECOVER')
    consume(:CHAR, '(')
    default_expr = parse_expression
    consume(:CHAR, ')')
    AST::RecoverOp.new(tok, default_expr)
  end

  # WINDOW(size) expression        -- sliding window (positional arg)
  # WINDOW(size: N, time: 'Xms')  -- batch/tumbling window (named args)
  # e.g., prices |> WINDOW(3) SUM(_) / 3.0
  # e.g., stream |> WINDOW(size: 100) SELECT process(_)
  # e.g., stream |> WINDOW(size: 100, time: '500ms') EACH { ... }
  sig { returns(WindowPipelineOp) }
  def parse_window_op
    window_token = consume(:KEYWORD, 'WINDOW')
    consume(:CHAR, '(')
    # Named-param form (BatchWindowOp) if first token is VAR_ID followed by ':'
    if match?(:VAR_ID) && peek.type == :CHAR && peek.value == ':'
      options = {}
      loop do
        key_tok = consume(:VAR_ID)
        consume(:CHAR, ':')
        val = parse_expression
        options[key_tok.text!] = val
        break unless match?(:CHAR, ',')
        consume(:CHAR, ',')
      end
      consume(:CHAR, ')')
      body = parse_expression(1)
      AST::BatchWindowOp.new(window_token, options, body)
    else
      size = parse_expression
      consume(:CHAR, ')')
      body = parse_expression(1)  # pipe_expression precedence
      AST::WindowOp.new(window_token, size, body)
    end
  end

  # JOIN(right_source) key_expr_or_lambda
  # e.g., users |> JOIN(orders) _.userId
  # e.g., users |> JOIN(orders) %(a, b) -> a.id == b.userId
  sig { returns(AST::JoinOp) }
  def parse_join_op
    join_token = consume(:KEYWORD, 'JOIN')
    consume(:CHAR, '(')
    right_source = parse_expression
    consume(:CHAR, ')')
    key_expr = parse_expression(1)  # pipe_expression precedence
    AST::JoinOp.new(join_token, right_source, key_expr)
  end

  # SHARD(key_expr, target_map)
  # e.g., (0..<n) |> SHARD("key:" + _, map) |> CONCURRENT EACH { ... }
  # Routes items to owning schedulers by hashing the key expression.
  # `_` is the implicit item binding (same as SELECT/WHERE).
  sig { returns(AST::ShardOp) }
  def parse_shard_op
    shard_token = consume(:KEYWORD, 'SHARD')
    consume(:CHAR, '(')
    key_expr = parse_expression
    consume(:CHAR, ',')
    target_map = parse_expression
    consume(:CHAR, ')')
    AST::ShardOp.new(shard_token, key_expr, target_map)
  end

  sig { returns(AST::ConcurrentOp) }
  def parse_concurrent_op
    token = consume(:KEYWORD, 'CONCURRENT')
    options = {}
    if match?(:CHAR, '(')
      consume(:CHAR, '(')
      loop do
        key_tok = consume(:VAR_ID)
        consume(:CHAR, ':')
        val = parse_expression
        options[key_tok.text!] = val
        break unless match?(:CHAR, ',')
        consume(:CHAR, ',')
      end
      consume(:CHAR, ')')
    end
    inner_op = parse_concurrent_inner_op(token)
    AST::ConcurrentOp.new(token, inner_op, options)
  end

  sig { params(parent_token: Lexer::Token).returns(ConcurrentPipelineOp) }
  def parse_concurrent_inner_op(parent_token)
    if match?(:KEYWORD, 'SELECT')
      parse_select_op
    elsif match?(:KEYWORD, 'WHERE')
      consume(:KEYWORD, 'WHERE')
      expr = parse_expression(1)
      AST::WhereOp.new(previous, expr)
    elsif match?(:KEYWORD, 'EACH')
      parse_each_op
    elsif match?(:KEYWORD, 'SUM')
      consume(:KEYWORD, 'SUM')
      expr = parse_expression(1)
      AST::SumOp.new(previous, expr)
    elsif match?(:KEYWORD, 'COUNT')
      consume(:KEYWORD, 'COUNT')
      expr = parse_expression(1)
      AST::CountOp.new(previous, expr)
    elsif match?(:KEYWORD, 'MIN')
      consume(:KEYWORD, 'MIN')
      expr = parse_expression(1)
      AST::MinOp.new(previous, expr)
    elsif match?(:KEYWORD, 'MAX')
      consume(:KEYWORD, 'MAX')
      expr = parse_expression(1)
      AST::MaxOp.new(previous, expr)
    elsif match?(:KEYWORD, 'AVERAGE')
      consume(:KEYWORD, 'AVERAGE')
      expr = parse_expression(1)
      AST::AverageOp.new(previous, expr)
    else
      error!(current, :CONCURRENT_BAD_OP, got: current.value.inspect)
    end
  end

  # Parses `EACH { stmts... }` or `EACH callback` — side-effect iteration
  # over a collection. `_` is the implicit item binding inside the body.
  sig { returns(AST::EachOp) }
  def parse_each_op
    token = consume(:KEYWORD, 'EACH')
    body = if match?(:CHAR, '{')
      parse_brace_block
    else
      callback = parse_expression(1)
      [AST::FuncCall.new(token, callback.respond_to?(:name) ? T.unsafe(callback).name : callback.to_s,
        [AST::Identifier.new(token, "_")])]
    end
    AST::EachOp.new(token, body)
  end

  sig { returns(AST::TapOp) }
  def parse_tap_op
    token = consume(:KEYWORD, 'TAP')
    # TAP f -> single function call (short form)
    # TAP { body } -> block form
    if match?(:CHAR, '{')
      body = parse_brace_block
      AST::TapOp.new(token, body)
    else
      # Short form: TAP func -> becomes TAP { func(_); }
      expr = parse_expression(1)  # parse_pipe_expression
      AST::TapOp.new(token, [AST::FuncCall.new(token, expr.respond_to?(:name) ? T.unsafe(expr).name : expr.to_s, [AST::Identifier.new(token, "_")])])
    end
  end

  # All recognized capability tokens.
end
