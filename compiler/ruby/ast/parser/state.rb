# typed: strict

class ClearParser
  extend T::Sig

  private

  # Pair structural delimiters once so token lookahead can skip nested forms in
  # O(1). Malformed pairs are deliberately left absent; the ordinary parser
  # remains responsible for reporting the syntax error at the real cursor.
  sig { params(tokens: T::Array[Lexer::Token]).returns(T::Array[T.nilable(Integer)]) }
  def index_delimiter_closings(tokens)
    opening_chars = T.let([], T::Array[String])
    opening_indices = T.let([], T::Array[Integer])
    closings = T.let([], T::Array[T.nilable(Integer)])

    tokens.each_with_index do |token, index|
      closings << nil
      next unless token.type == :CHAR
      value = token.text!
      if OPEN_DELIMITERS.include?(value)
        opening_chars << value
        opening_indices << index
      elsif !opening_chars.empty?
        opening = T.must(opening_chars.last)
        closing = CLOSE_DELIMITERS[T.must(OPEN_DELIMITERS.index(opening))]
        next unless closing == value
        opening_chars.pop
        opening_index = opening_indices.pop
        closings[T.must(opening_index)] = index
      end
    end
    closings.freeze
  end

  sig { returns(Lexer::Token) }
  def peek
    @tokens[@pos + 1] || Lexer::Token.new(:EOF, "", current.line, current.column)
  end

  sig { params(n: Integer).returns(T.nilable(Lexer::Token)) }
  def peek_at(n)
    @tokens[@pos + n]
  end

  # COMMANDS

  sig { returns(Lexer::Token) }
  def current
    T.must(@tokens[@pos])
  end

  sig { returns(Lexer::Token) }
  def previous
    T.must(@tokens[@pos-1])
  end

  # Consume a numeric literal (either :NUMBER float or :INT64 integer).
  sig { returns(Lexer::Token) }
  def consume_number
    if current.type == :NUMBER || current.type == :INT64
      tok = current
      @pos += 1
      tok
    else
      error!(current, :EXPECTED_NUMBER, value: current.value, type: current.type)
    end
  end

  sig { params(type: Symbol, value: T.nilable(String)).returns(Lexer::Token) }
  def consume(type, value=nil)
    # Return the consumed token rather than `current`, which advances to the next token.
    token = current

    if (token.type == type) || (value && token.value == value)
      if value && token.value != value
         emit_consume_error_with_fix(token, type, value)
      end

      @pos += 1
      token
    else
      emit_consume_error_with_fix(token, type, value)
    end
  end

  # Intercepts consume-failures with pattern-specific fixable findings
  # where they're safe. Every helper ultimately calls `error!` (directly
  # or via `fixable!` with `raise_in_collector: true`) so a parser error
  # still halts parsing at the first unrecoverable site — callers of
  # `clear fix` see the one finding in the collector and can apply the
  # suggested edit, then re-run.
  #
  # Two insertion strategies:
  #   end-of-prev-line — used when the missing token belongs after what
  #     the user wrote on the previous line (`;` after a statement,
  #     `THEN`/`DO`/`->` after a condition/signature that finished on
  #     the previous line).
  #   before-current   — used when the missing token belongs on the
  #     same line as the unexpected token (`THEN`/`DO` directly before
  #     an inline body on the same line as the condition).

  sig { params(token: Lexer::Token, expected_type: Symbol, expected_value: T.nilable(String)).returns(T.noreturn) }
  def emit_consume_error_with_fix(token, expected_type, expected_value)
    prev_tok = @pos > 0 ? @tokens[@pos - 1] : nil

    if expected_value && SYNTAX_TOKENS_AT_STATEMENT_END.include?(expected_value) && prev_tok
      if prev_tok.line < token.line
        return emit_syntax_insert_end_of_line!(prev_tok, token, expected_value)
      end
      if %w[THEN DO ->].include?(expected_value) && prev_tok.line == token.line
        return emit_syntax_insert_before_token!(token, expected_value)
      end
    end

    error!(token, :PARSER_EXPECTED, expected: expected_value || expected_type, got: token.value, type: token.type, line: token.line)
  end

  # Insert `<expected>` at the end of the previous source line (right
  # after its last non-whitespace character, so canonical formatting is
  # preserved). Works uniformly for `;`, `THEN`, `DO`, `->`.
  sig { params(prev_tok: Lexer::Token, next_tok: Lexer::Token, expected_value: String).returns(T.noreturn) }
  def emit_syntax_insert_end_of_line!(prev_tok, next_tok, expected_value)
    line_text  = @source_code.lines[prev_tok.line - 1] || ''
    insert_col = line_text.rstrip.length + 1
    leader     = (expected_value == ';') ? '' : ' '

    fix = Fix.new(
      description: fix_description(:INSERT_EXPECTED_AT_END_OF_LINE, expected: expected_value, line: prev_tok.line),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: prev_tok.line, col: insert_col, length: 0),
        replacement: "#{leader}#{expected_value}"
      )]
    )

    fixable!(next_tok,
             code: :PARSER_EXPECTED_AT_END_OF_LINE,
             expected: expected_value,
             expected_line: prev_tok.line,
             got: next_tok.value,
             got_line: next_tok.line,
             category: :type, level: :error,
             fixes: [fix], raise_in_collector: true)
  end

  # Insert `<expected>` just before the unexpected token (same-line
  # missing-keyword shape, e.g., `IF x RETURN 1` needs `THEN` before
  # `RETURN`).
  sig { params(token: Lexer::Token, expected_value: String).returns(T.noreturn) }
  def emit_syntax_insert_before_token!(token, expected_value)
    fix = Fix.new(
      description: fix_description(:INSERT_EXPECTED_BEFORE_TOKEN, expected: expected_value, got: token.value, line: token.line),
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: token.line, col: token.column, length: 0),
        replacement: "#{expected_value} "
      )]
    )
    fixable!(token,
      code: :PARSER_EXPECTED_BEFORE_TOKEN,
      expected: expected_value,
      got: token.value,
      line: token.line,
      category: :type, level: :error,
      fixes: [fix], raise_in_collector: true)
  end

  sig { params(type: Symbol, val: T.nilable(String)).returns(T::Boolean) }
  def match?(type, val=nil)
    current.type == type && (val.nil? || current.value == val)
  end

  # `>>` is a shift in expression context, but it is also two adjacent generic
  # closers in a type such as Outer<Inner<Int64>>. Split only while consuming a
  # generic close so the lexer can keep one unambiguous shift token elsewhere.
  sig { returns(T::Boolean) }
  def generic_close?
    match?(:CHAR, '>') || match?(:CHAR, '>>')
  end

  sig { returns(Lexer::Token) }
  def consume_generic_close
    return consume(:CHAR, '>') unless match?(:CHAR, '>>')

    combined = current
    first = T.let(combined.dup, Lexer::Token)
    second = T.let(combined.dup, Lexer::Token)
    first.value = '>'
    first.end_offset = combined.start_offset + 1 if combined.start_offset
    first.end_column = combined.column + 1
    second.value = '>'
    second.column = combined.column + 1
    second.start_offset = combined.start_offset + 1 if combined.start_offset
    @tokens[@pos] = second
    first
  end

  # Lookahead: peek `n` tokens past the current cursor and test type/value.
  sig { params(n: Integer, type: Symbol, val: T.nilable(String)).returns(T::Boolean) }
  def match_at?(n, type, val=nil)
    tok = peek_at(n)
    return false unless tok
    tok.type == type && (val.nil? || tok.value == val)
  end

  # Used by `parse_match_*` to decide whether the `,` at `current` is a
  # multi-pattern-arm continuation (next pattern follows) or an arm
  # separator. Returns true ONLY when the token AFTER `,` could start
  # another pattern. Tokens that can ONLY start a NEW arm or end the
  # current one (`->`, `AS`, `WHEN`, `DEFAULT`, `END`, `EOF`, `{`)
  # terminate the multi-pattern loop instead.
  sig { returns(T::Boolean) }
  def multi_pattern_continues?
    nxt = peek_at(1)
    return false unless nxt
    return false if nxt.type == :ARROW || nxt.type == :EOF
    return false if nxt.type == :KEYWORD && %w[AS WHEN DEFAULT END].include?(nxt.value)
    return false if nxt.type == :CHAR && nxt.value == '{'
    true
  end

  # Match and immediately eat
  sig { params(type: Symbol, value: T.nilable(String)).returns(T.any(Lexer::Token, FalseClass)) }
  def match!(type, value=nil)
    if match?(type, value)
      consume(type)
    else
      false
    end
  end


  sig { params(node: AST::Node, first: Lexer::Token, last: Lexer::Token).returns(AST::Node) }
  def stamp_source_range!(node, first, last)
    start_offset = first.start_offset || 0
    end_offset = last.end_offset || (start_offset + last.value.to_s.bytesize)
    node.source_range = AST::SourceRange.new(
      file: first.file || last.file,
      start_offset: start_offset,
      end_offset: end_offset,
      start_line: first.line,
      start_column: first.column,
      end_line: last.end_line || last.line,
      end_column: last.end_column || (last.column + last.value.to_s.length),
    )
    node
  end

  # Preserve the complete receiver/callee span when a postfix operation grows
  # an expression.  The token carried by a MethodCall is the method name, not
  # the beginning of `receiver.method(...)`; diagnostics and source rewrites
  # need the latter.
  sig { params(node: AST::Node, first: AST::Locatable, last: Lexer::Token).returns(AST::Node) }
  def stamp_source_range_from_node!(node, first, last)
    range = first.source_range
    end_offset = last.end_offset || ((last.start_offset || range.end_offset) + last.value.to_s.bytesize)
    node.source_range = AST::SourceRange.new(
      file: range.file || last.file,
      start_offset: range.start_offset,
      end_offset: end_offset,
      start_line: range.start_line,
      start_column: range.start_column,
      end_line: last.end_line || last.line,
      end_column: last.end_column || (last.column + last.value.to_s.length),
    )
    node
  end
end
