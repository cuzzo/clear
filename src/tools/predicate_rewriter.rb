# typed: strict
require "sorbet-runtime"

require 'set'
require_relative '../ast/lexer'
require_relative '../ast/parser'
require_relative '../ast/ast'
require_relative '../ast/fixable_error'

# PredicateRewriter — source-level preprocessor that turns hand-written
# null-comparison and length-comparison idioms into the canonical
# predicate forms:
#
#   x == NIL              ->  x.nil?()
#   x != NIL              ->  x.present?()
#   coll.length() == 0    ->  coll.empty?()
#   coll.length() <  1    ->  coll.empty?()      (i.e., < 1 means == 0 for Int64)
#   coll.length() != 0    ->  coll.any?()
#   coll.length() >  0    ->  coll.any?()
#   coll.length() >= 1    ->  coll.any?()
#
# Always-true / always-false patterns are NOT rewritten — those are
# bugs, not stylistic preferences. They surface as `clear fix`
# warnings via PredicateLinter (clear_fix integration).
#
# Mirrors the source-edit shape of MethodRewriter — parse to AST,
# walk for matching nodes, compute byte spans, apply
# right-to-left so positions stay valid.
#
# Idempotent: a second pass finds no `== NIL` / `length() == 0`
# patterns left to rewrite.

module PredicateRewriter
  extend T::Sig


  class Edit < T::Struct
    const :start, Integer
    const :len, Integer
    const :replacement, String
  end

  class CompareSpan < T::Struct
    const :start, Integer
    const :end_pos, Integer
    const :other_start, Integer
    const :other_end, Integer
  end

  sig { params(source: String).returns(String) }
  def self.rewrite(source)
    tokens = ::Lexer.new(source).tokenize
    ast = ::ClearParser.new(tokens, source).parse
    edits = []
    walk(ast, source, edits)
    apply_edits(source, edits)
  end

  # Walk the parsed AST and emit FixableFindings for length-comparison
  # patterns that are always-true (`>= 0`) or always-false (`< 0`).
  # No source rewrite is offered — the bug is "the comparison is
  # meaningless," not "the syntax is wrong" — so the finding has no
  # auto-fix; the user has to decide what they meant.
  sig { params(source: String).returns(T.untyped) }
  def self.lint!(source)
    return unless FixCollector.enabled?
    tokens = ::Lexer.new(source).tokenize
    ast = ::ClearParser.new(tokens, source).parse
    walk_lint(ast)
  rescue CompilerError, ParserError
    # Lint is best-effort; a malformed file just yields no findings.
  end

  sig { params(node: T.untyped).returns(T.nilable(Array)) }
  def self.walk_lint(node)
    return if terminal?(node)
    if node.is_a?(Array)
      node.each { |n| walk_lint(n) }
      return
    end
    return unless node.respond_to?(:each_pair)
    node.each_pair { |_, v| walk_lint(v) }
    emit_length_lint(node) if node.is_a?(AST::BinaryOp)
  end

  # `coll.length() >= 0` is always true (length is unsigned).
  # `coll.length() <  0` is always false.
  sig { params(node: AST::BinaryOp).returns(T.nilable(Array)) }
  def self.emit_length_lint(node)
    return unless length_call?(node.left)
    lit = int_lit_value(node.right)
    return unless lit == 0

    case node.op
    when :GTE
      push_always_finding(node, "always true: `length() >= 0` — length is non-negative")
    when :LT
      push_always_finding(node, "always false: `length() < 0` — length is non-negative")
    end
  end

  sig { params(node: AST::BinaryOp, message: String).returns(Array) }
  def self.push_always_finding(node, message)
    anchor = node.token ? node.token : nil
    return unless anchor
    finding = FixableFinding.new(
      level: :warning,
      message: message,
      token: anchor,
      category: :lint,
      fixes: []
    )
    FixCollector.push(finding)
  end

  # ---- AST traversal ----

  sig { params(node: T.untyped, source: String, edits: Array).returns(T.nilable(Array)) }
  def self.walk(node, source, edits)
    return if terminal?(node)
    if node.is_a?(Array)
      node.each { |n| walk(n, source, edits) }
      return
    end
    return unless node.respond_to?(:each_pair)
    # Children first (post-order), so inner edits are computed before
    # the outer one. Apply right-to-left at the end keeps offsets sane.
    node.each_pair { |_, v| walk(v, source, edits) }

    edit = match_pattern(node, source)
    edits << edit if edit
  end

  sig { params(n: T.untyped).returns(T::Boolean) }
  def self.terminal?(n)
    n.nil? || n.is_a?(Symbol) || n.is_a?(String) || n.is_a?(Integer) ||
      n.is_a?(Float) || n.is_a?(TrueClass) || n.is_a?(FalseClass)
  end

  sig { params(node: T.untyped, source: String).returns(T.nilable(PredicateRewriter::Edit)) }
  def self.match_pattern(node, source)
    return nil unless node.is_a?(AST::BinaryOp)
    match_nil_compare(node, source) ||
      match_length_compare(node, source)
  end

  # ---- NIL comparisons ----

  # `expr == NIL` / `expr != NIL` rewrite to `expr.nil?()` /
  # `expr.present?()`. Operator is preserved by mapping:
  #   ==  ->  .nil?()
  #   !=  ->  .present?()
  #
  # Only the NIL-on-RHS form is rewritten. The reversed form
  # `NIL == expr` could in principle rewrite to the same target,
  # but bounding the right-operand's source span without a full
  # expression parser is fragile for chains (`NIL == users.find(p)`),
  # so v1 leaves it alone — users (or a future pre-pass) can flip
  # the operands first.
  sig { params(node: AST::BinaryOp, source: String).returns(T.nilable(Edit)) }
  def self.match_nil_compare(node, source)
    return nil unless [:EQ, :NEQ].include?(node.op)
    return nil unless nil_literal?(node.right)
    other = node.left
    return nil unless other

    span = compute_compare_span(node, source)
    return nil unless span
    other_text = source[span.other_start...span.other_end]
    return nil unless other_text && !other_text.strip.empty?

    pred = node.op == :EQ ? "nil?" : "present?"
    Edit.new(
      start: span.start,
      len: span.end_pos - span.start,
      replacement: "#{paren_if_needed(other_text)}.#{pred}()",
    )
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def self.nil_literal?(node)
    node.is_a?(AST::Literal) && node.type == :NIL
  end

  # ---- length() comparisons ----

  # `coll.length() <op> <lit>` rewrites depend on (op, lit):
  #
  #   ==  0   ->  empty?
  #   !=  0   ->  any?
  #   >   0   ->  any?
  #   >=  1   ->  any?
  #   <   1   ->  empty?
  #
  # Always-true / always-false combinations (`>= 0`, `< 0`) are NOT
  # rewritten — PredicateLinter surfaces them as warnings instead.
  sig { params(node: AST::BinaryOp, source: String).returns(T.nilable(Edit)) }
  def self.match_length_compare(node, source)
    op = node.op
    return nil unless [:EQ, :NEQ, :GT, :GTE, :LT, :LTE].include?(op)

    # Only rewrite the form `coll.length() <op> <lit>`. The reversed
    # form `<lit> <op> coll.length()` is left alone for the same
    # reason as reversed-NIL — bounding the right operand without a
    # full expression parser is fragile.
    return nil unless length_call?(node.left)

    length_call = node.left
    lit         = int_lit_value(node.right)
    return nil unless lit
    return nil unless length_call.args.empty?
    compare_op = op

    pred = pick_length_predicate(compare_op, lit)
    return nil unless pred  # always-true / always-false: leave for the linter

    span = compute_compare_span(node, source)
    return nil unless span
    receiver = receiver_source_for_method_call(length_call, source)
    return nil unless receiver && !receiver.strip.empty?

    Edit.new(
      start: span.start,
      len: span.end_pos - span.start,
      replacement: "#{paren_if_needed(receiver)}.#{pred}()",
    )
  end

  sig { params(node: T.untyped).returns(T::Boolean) }
  def self.length_call?(node)
    node.is_a?(AST::MethodCall) && node.name == "length"
  end

  sig { params(node: T.any(AST::Literal, AST::MethodCall)).returns(T.nilable(Integer)) }
  def self.int_lit_value(node)
    return nil unless node.is_a?(AST::Literal)
    return nil unless node.type == :INT64 || node.type == :INT
    node.value
  end

  # Map (op, literal) -> canonical predicate name. nil means
  # "no rewrite — either always-true/false or shape we don't simplify."
  sig { params(op: Symbol, lit: Integer).returns(T.nilable(String)) }
  def self.pick_length_predicate(op, lit)
    case [op, lit]
    when [:EQ, 0], [:LT, 1], [:LTE, 0]
      "empty?" # length <= 0 means == 0 for unsigned length
    when [:NEQ, 0], [:GT, 0], [:GTE, 1]
      "any?"
    end
  end

  # ---- Source span helpers ----

  # Returns `{start:, end:, other_start:, other_end:}` for a BinaryOp
  # whose right side is a small literal (NIL or Int). The "other" range
  # is the left operand used for the rewrite payload. nil if span
  # couldn't be cleanly resolved.
  sig { params(node: AST::BinaryOp, source: String).returns(T.nilable(CompareSpan)) }
  def self.compute_compare_span(node, source)
    return nil unless literal_node?(node.right)

    # `<expr> <op> <literal>`
    lhs_start = leftmost_offset(node.left, source)
    lhs_end   = rightmost_compact_offset(node.left, source)
    lit_off   = offset_for(source, node.right.token.line, node.right.token.column)
    return nil unless lhs_start && lhs_end && lit_off
    lit_len   = literal_source_length(node.right, source, lit_off)
    return nil unless lit_len
    lhs_start, lhs_end = expand_paren_wrap(source, lhs_start, lhs_end)
    end_off = lit_off + lit_len
    CompareSpan.new(
      start: lhs_start,
      end_pos: end_off,
      other_start: lhs_start,
      other_end: lhs_end,
    )
  end

  # If the source character immediately before `lhs_start` is `(` AND
  # the character at `lhs_end` is `)`, those are a matched outer pair
  # wrapping the whole LHS (parens are dropped by the parser). Walk
  # outward as far as the pairs match so the rewrite span includes
  # them — otherwise replacing from inside the parens orphans the
  # opening one. Returns the expanded (lhs_start, lhs_end).
  sig { params(source: String, lhs_start: Integer, lhs_end: Integer).returns(Array) }
  def self.expand_paren_wrap(source, lhs_start, lhs_end)
    while lhs_start > 0 &&
          lhs_end < source.length &&
          source[lhs_start - 1] == '(' &&
          source[lhs_end] == ')'
      lhs_start -= 1
      lhs_end   += 1
    end
    [lhs_start, lhs_end]
  end

  sig { params(node: AST::Literal).returns(T::Boolean) }
  def self.literal_node?(node)
    node.is_a?(AST::Literal) && [:NIL, :INT64, :INT].include?(node.type)
  end

  # Source byte-length of a literal token starting at `lit_off`. For
  # NIL it's the fixed string `NIL`; for ints we scan forward through
  # digits / underscores / a numeric type suffix (e.g. `0_i64`,
  # `1_000`) so the source span includes the whole literal as written.
  sig { params(node: AST::Literal, source: String, lit_off: Integer).returns(Integer) }
  def self.literal_source_length(node, source, lit_off)
    case node.type
    when :NIL
      3
    when :INT64, :INT
      i = lit_off
      i += 1 while i < source.length && source[i] =~ /[0-9_]/
      # Optional type suffix.
      if (m = source[i..].match(/\A(i8|i16|i32|i64|u8|u16|u32|u64|f32|f64)/))
        i += m[0].length
      end
      i - lit_off
    end
  end

  # Find the byte offset of the leftmost source character of `node`'s
  # textual span. For a MethodCall `expr.method(...)` this is the
  # leftmost position of `expr`; for a chain `a.b.c.method()` it's
  # `a`'s position. Walks the AST recursively.
  sig { params(node: T.untyped, source: String).returns(Integer) }
  def self.leftmost_offset(node, source)
    case node
    when AST::MethodCall
      leftmost_offset(node.object, source)
    when AST::FuncCall
      offset_for(source, node.token.line, node.token.column) if node.token
    else
      return nil unless node.token
      offset_for(source, node.token.line, node.token.column)
    end
  end

  # Find the byte offset just past the rightmost char of `node`'s
  # textual span. For our patterns the RHS is always a simple literal
  # or method-call form; we approximate by walking a balanced-paren
  # scan from the node's leftmost-token position. Returns nil if the
  # walk hits an unmatched close.
  sig { params(node: T.untyped, source: String).returns(Integer) }
  def self.rightmost_compact_offset(node, source)
    start = leftmost_offset(node, source)
    return nil unless start
    # Walk forward until we see a top-level operator/close-paren
    # /comma/semicolon that ends this expression. This is the same
    # boundary heuristic the formatter uses internally.
    walk_to_expr_end(source, start)
  end

  # Walk source forward from `start`, tracking nesting depth and
  # string state, stopping at the first character that ends an
  # expression at depth 0. The returned offset points just past the
  # last char of the expression.
  sig { params(source: String, start: Integer).returns(Integer) }
  def self.walk_to_expr_end(source, start)
    i = start
    depth = 0
    in_str = false
    in_triple = false
    last_non_ws = i
    while i < source.length
      c = source[i]
      if in_triple
        if source[i, 3] == '"""'
          in_triple = false
          i += 3
          last_non_ws = i - 1
          next
        end
      elsif in_str
        if c == '\\' && i + 1 < source.length
          i += 2; last_non_ws = i - 1; next
        elsif c == '"'
          in_str = false
        end
      else
        if source[i, 3] == '"""'
          in_triple = true; i += 3; last_non_ws = i - 1; next
        elsif c == '"'
          in_str = true
        elsif c == '#'
          # Skip line comment
          nl = source.index("\n", i) || source.length
          i = nl
          next
        elsif '([{'.include?(c)
          depth += 1
        elsif ')]}'.include?(c)
          if depth == 0
            return last_non_ws + 1
          end
          depth -= 1
        elsif depth == 0 && (c == ',' || c == ';' || c == "\n")
          return last_non_ws + 1
        elsif depth == 0 && (c == ' ' || c == "\t")
          # Possible operator boundary — peek next non-ws char
          j = i
          j += 1 while j < source.length && (source[j] == ' ' || source[j] == "\t")
          if j < source.length && expression_terminator_op?(source, j)
            return last_non_ws + 1
          end
        end
      end
      last_non_ws = i unless c == ' ' || c == "\t" || c == "\n"
      i += 1
    end
    last_non_ws + 1
  end

  # True when the chars at `j` start a comparison/logical operator
  # that would end a sub-expression in our patterns. Used to detect
  # the boundary of the operand to the left of the comparison.
  sig { params(source: String, j: Integer).returns(T::Boolean) }
  def self.expression_terminator_op?(source, j)
    return true if source[j, 2] == '==' || source[j, 2] == '!=' ||
                   source[j, 2] == '>=' || source[j, 2] == '<=' ||
                   source[j, 2] == '&&' || source[j, 2] == '||'
    return true if '<>'.include?(source[j])
    false
  end

  # Extract the receiver source text for a `coll.length()` call.
  # Used to build the rewrite payload `<receiver>.empty?()` etc.
  # The call's `.token` points at the method name (`length` for
  # `coll.length()`), so the receiver ends one char before the `.`
  # that precedes that name. Walking back through whitespace handles
  # `coll  .length()` style spacing.
  sig { params(call: AST::MethodCall, source: String).returns(String) }
  def self.receiver_source_for_method_call(call, source)
    obj_start = leftmost_offset(call.object, source)
    return nil unless obj_start
    name_off  = offset_for(source, call.token.line, call.token.column)
    return nil unless name_off
    # Walk back from `name_off - 1` skipping whitespace, then expect
    # a `.`. Receiver text ends just before that `.`.
    i = name_off - 1
    i -= 1 while i > obj_start && source[i] =~ /\s/
    return nil unless i >= obj_start && source[i] == '.'
    obj_end = i
    return nil unless obj_end > obj_start
    source[obj_start...obj_end]
  end

  # Wrap source text in parens iff it could be misparsed when
  # followed by `.method?()`. A bare identifier or method-call chain
  # is fine; a binary expression like `a + b` would need wrapping
  # to keep `.nil?` from binding to `b`.
  sig { params(text: String).returns(String) }
  def self.paren_if_needed(text)
    stripped = text.strip
    # Identifier or chain (a.b.c, a.b()) — no parens needed.
    return stripped if stripped =~ /\A[a-zA-Z_@$][\w?]*(\.[a-zA-Z_@$][\w?]*(?:\([^()]*\))?)*\Z/
    # Already parenthesized — no need to add another layer.
    return stripped if stripped.start_with?('(') && stripped.end_with?(')')
    # Anything else — be safe.
    "(#{stripped})"
  end

  # ---- Source-offset helpers (mirrors MethodRewriter) ----

  sig { params(source: String, line: Integer, col: Integer).returns(Integer) }
  def self.offset_for(source, line, col)
    return nil if line < 1 || col < 1
    off = 0
    cur_line = 1
    while cur_line < line
      nl = source.index("\n", off)
      return nil unless nl
      off = nl + 1
      cur_line += 1
    end
    target = off + col - 1
    return nil if target > source.length
    target
  end

  # ---- Edit application ----

  sig { params(source: String, edits: T::Array[Edit]).returns(String) }
  def self.apply_edits(source, edits)
    sorted = edits.sort_by { |e| -e.start }
    out = source.dup
    sorted.each do |e|
      out[e.start, e.len] = e.replacement
    end
    out
  end

  private_class_method :emit_length_lint
  private_class_method :apply_edits
  private_class_method :compute_compare_span
  private_class_method :expand_paren_wrap
  private_class_method :expression_terminator_op?
  private_class_method :length_call?
  private_class_method :literal_node?
  private_class_method :literal_source_length
  private_class_method :match_length_compare
  private_class_method :match_nil_compare
  private_class_method :match_pattern
  private_class_method :nil_literal?
  private_class_method :pick_length_predicate
  private_class_method :push_always_finding
  private_class_method :receiver_source_for_method_call
  private_class_method :rightmost_compact_offset
  private_class_method :terminal?
  private_class_method :walk
  private_class_method :walk_lint
  private_class_method :walk_to_expr_end

end
