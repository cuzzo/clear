require_relative "./ast"
require_relative "./lexer"
require_relative "./error_registry"
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

  def peek_at(n)
    @tokens[@pos + n]
  end

  # COMMANDS
  stmt(:KEYWORD, 'REQUIRE') { parse_require }
  stmt(:KEYWORD, 'EXTERN')  { parse_extern_decl }
  stmt(:KEYWORD, 'MUTABLE', AST::VarDecl, ['MUTABLE', :VAR_ID, {':' => :type_annotation}, '=', :expression, ';'], inject: [true])
  stmt(:KEYWORD, 'FN')      { parse_function_def }
  stmt(:KEYWORD, 'PUB')     { parse_visibility_decl(:pub) }
  stmt(:KEYWORD, 'PRIVATE') { parse_visibility_decl(:private) }
  stmt(:KEYWORD, 'IF') { parse_if_statement }
  stmt(:KEYWORD, 'STRUCT') { parse_struct_def }
  stmt(:KEYWORD, 'ENUM')   { parse_enum_def }
  stmt(:KEYWORD, 'UNION')  { parse_union_def }
  stmt(:KEYWORD, 'WHILE') { parse_while_loop }
  stmt(:KEYWORD, 'FOR') { parse_for_range }
  stmt(:KEYWORD, 'TIGHT') { parse_tight_stmt }
  stmt(:KEYWORD, 'RETURN') { parse_return }
  stmt(:KEYWORD, 'ASSERT', AST::Assert, ['ASSERT', :expression, {',' => :STRING}, ';'])
  stmt(:KEYWORD, 'ASSERT_RAISES') { parse_assert_raises }
  stmt(:KEYWORD, 'TEST') { parse_test_block }
  stmt(:KEYWORD, 'STUB') { parse_stub }
  stmt(:KEYWORD, 'BENCHMARK') { parse_benchmark_stmt }
  stmt(:KEYWORD, 'SMASH') { parse_smash_stmt }
  stmt(:KEYWORD, 'PROFILE') { parse_profile_stmt }
  stmt(:KEYWORD, 'RAISE') { parse_raise_stmt }
  stmt(:KEYWORD, 'EXIT') { parse_exit }
  stmt(:KEYWORD, 'DIE') { parse_die }
  stmt(:KEYWORD, 'BREAK', AST::BreakNode, ['BREAK', ';'])
  stmt(:KEYWORD, 'CONTINUE', AST::ContinueNode, ['CONTINUE', ';'])
  stmt(:KEYWORD, 'WITH') { parse_with_capability }
  stmt(:KEYWORD, 'DO')   { parse_do_block }
  stmt(:KEYWORD, 'BG')   { parse_bg_block }
  stmt(:KEYWORD, 'YIELD') { parse_yield_expr }
  stmt(:KEYWORD, 'MATCH') { parse_match_statement }
  stmt(:KEYWORD, 'PASS') do
    tok = consume(:KEYWORD, 'PASS')
    match!(:CHAR, ';')  # optional semicolon — PASS may appear bare before a ','
    AST::PassStmt.new(tok)
  end


  # IF and MATCH as expressions: x = IF cond THEN a ELSE b END
  primary(:KEYWORD, 'IF')    { parse_if_expr }
  primary(:KEYWORD, 'MATCH') { parse_match_expr }

  # Primaries
  primary(:NUMBER) { parse_literal(:NUMBER, :stack) }
  primary(:INT64) { parse_literal(:INT64, :stack) }
  primary(:STRING) { parse_literal(:STRING, :stack) }
  # Symbol literal: :identifier — only valid in expression position.
  # The ':' char is already consumed by the time the primary body runs.
  primary(:CHAR, ':') do
    colon_tok = consume(:CHAR, ':')
    error!(colon_tok, "Expected a symbol name (lowercase identifier) after ':'") unless match?(:VAR_ID)
    ident_tok = consume(:VAR_ID)
    AST::Literal.new(colon_tok, :SYMBOL, ident_tok.value, :stack)
  end
  primary(:BYTE) { parse_literal(:BYTE, :stack) }
  primary(:PREFIXED_INT) { parse_literal(:PREFIXED_INT, :stack) }
  primary(:INT8)    { parse_literal(:INT8,    :stack) }
  primary(:INT16)   { parse_literal(:INT16,   :stack) }
  primary(:INT32)   { parse_literal(:INT32,   :stack) }
  primary(:UINT16)  { parse_literal(:UINT16,  :stack) }
  primary(:UINT32)  { parse_literal(:UINT32,  :stack) }
  primary(:UINT64)  { parse_literal(:UINT64,  :stack) }
  primary(:FLOAT32) { parse_literal(:FLOAT32, :stack) }
  primary(:VAR_ID) { parse_var_id }

  primary(:KEYWORD, 'TRUE') { t = consume(:KEYWORD); AST::Literal.new(t, :BOOLEAN, true) }
  primary(:KEYWORD, 'FALSE') { t = consume(:KEYWORD); AST::Literal.new(t, :BOOLEAN, false) }
  primary(:KEYWORD, 'NIL') { t = consume(:KEYWORD); AST::Literal.new(t, :NIL, nil) }
  primary(:KEYWORD, 'DEFAULT') { t = consume(:KEYWORD, 'DEFAULT'); AST::DefaultLit.new(t) }
  primary(:KEYWORD, 'CAST', AST::Cast, ['CAST', '(', :expression, 'AS', :type_annotation, ')'])
  primary(:KEYWORD, 'COPY', AST::Copy, ['COPY', :expression])
  primary(:KEYWORD, 'MOVE', AST::MoveNode, ['MOVE', :expression])
  primary(:KEYWORD, 'GIVE', AST::MoveNode, ['GIVE', :expression])
  primary(:KEYWORD, 'COPY', AST::CopyNode, ['COPY', :expression])
  primary(:KEYWORD, 'CLONE', AST::CloneNode, ['CLONE', :expression])
  primary(:KEYWORD, 'LINK', AST::LinkNode, ['LINK', :expression])
  primary(:KEYWORD, 'RESOLVE', AST::ResolveNode, ['RESOLVE', :expression])
  primary(:KEYWORD, 'FREEZE', AST::FreezeNode, ['FREEZE', :expression])
  primary(:KEYWORD, 'BG')   { parse_bg_block }
  primary(:KEYWORD, 'NEXT') { parse_next_expr }
  primary(:PERCENT, '%') { parse_sigil_construct }
  primary(:KEYWORD, 'REQUIRE', AST::Require, ['REQUIRE', :STRING])

  # Pipeline operators use :pipe_expression (min precedence 2) so their
  # body expression stops before `s>` (precedence 1), enabling chaining:
  #   list s> SELECT _ * 2.0 s> WHERE _ > 5.0
  primary(:KEYWORD, 'SELECT', AST::SelectOp, ['SELECT', :pipe_expression])
  primary(:KEYWORD, 'WHERE', AST::WhereOp, ['WHERE', :pipe_expression])
  primary(:KEYWORD, 'INDEX', AST::IndexOp, ['INDEX', :pipe_expression])
  primary(:KEYWORD, 'REDUCE') { parse_reduce_op }
  primary(:KEYWORD, 'ORDER_BY', AST::OrderByOp, ['ORDER_BY', :pipe_expression])
  primary(:KEYWORD, 'LIMIT', AST::LimitOp, ['LIMIT', :pipe_expression])
  primary(:KEYWORD, 'SKIP', AST::SkipOp, ['SKIP', :pipe_expression])
  primary(:KEYWORD, 'UNNEST', AST::UnnestOp, ['UNNEST', :pipe_expression])
  primary(:KEYWORD, 'DISTINCT', AST::DistinctOp, ['DISTINCT', :pipe_expression])
  primary(:KEYWORD, 'EACH')  { parse_each_op }
  primary(:KEYWORD, 'TAP')   { parse_tap_op }
  primary(:KEYWORD, 'FIND',    AST::FindOp,    ['FIND',    :pipe_expression])
  primary(:KEYWORD, 'ANY',     AST::AnyOp,     ['ANY',     :pipe_expression])
  primary(:KEYWORD, 'ALL',     AST::AllOp,     ['ALL',     :pipe_expression])
  primary(:KEYWORD, 'COUNT',   AST::CountOp,   ['COUNT',   :pipe_expression])
  primary(:KEYWORD, 'SUM',     AST::SumOp,     ['SUM',     :pipe_expression])
  primary(:KEYWORD, 'AVERAGE', AST::AverageOp, ['AVERAGE', :pipe_expression])
  primary(:KEYWORD, 'MIN',     AST::MinOp,     ['MIN',     :pipe_expression])
  primary(:KEYWORD, 'MAX',     AST::MaxOp,     ['MAX',     :pipe_expression])
  primary(:KEYWORD, 'TAKE_WHILE', AST::TakeWhileOp, ['TAKE_WHILE', :pipe_expression])
  primary(:KEYWORD, 'RECOVER') { parse_recover_op }
  primary(:KEYWORD, 'WINDOW') { parse_window_op }
  primary(:KEYWORD, 'JOIN') { parse_join_op }
  primary(:KEYWORD, 'SHARD') { parse_shard_op }
  primary(:KEYWORD, 'CONCURRENT') { parse_concurrent_op }

  # Expression Grouping
  primary(:CHAR, '(') do
    consume(:CHAR, '(')
    expr = parse_expression
    # (expr AS name): optional binding group used in IF (expr AS name) && ...
    # parse_expression stops at AS (guard blocks non-@-prefixed tokens), so check explicitly.
    if match?(:KEYWORD, 'AS')
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      consume(:CHAR, ')')
      bind = AST::BinaryOp.new(name_tok, expr, :BIND_VAR,
               AST::Identifier.new(name_tok, name_tok.value))
      bind.paren_bind = true
      next parse_suffixes(bind)
    end
    consume(:CHAR, ')')
    parse_suffixes(expr)
  end

  # Array Indexing: arr[index]
  suffix(:CHAR, '[') do |lhs|
    start_token = consume(:CHAR, '[')
    first = parse_expression
    if first.is_a?(AST::RangeLit)
      # parse_expression consumed the range operator: 0..<3 → RangeLit(0, 3, false)
      consume(:CHAR, ']')
      node = AST::Slice.new(first.token, lhs, first.start, first.finish)
      node.instance_variable_set(:@exclusive, !first.inclusive)
      node
    elsif match?(:RANGE, '..')
      # SLICE: list[0..3] (inclusive end)
      range_token = consume(:RANGE, '..')
      last = parse_expression
      consume(:CHAR, ']')
      node = AST::Slice.new(range_token, lhs, first, last)
      node.instance_variable_set(:@exclusive, false)
      node
    else
      # INDEX: list[0]
      # INDEX: hash["OK"]
      consume(:CHAR, ']')
      AST::GetIndex.new(start_token, lhs, first)
    end
  end

  # Static Call: TypeName::method(args)
  suffix(:DOUBLE_COLON, '::') do |lhs|
    colon_token = consume(:DOUBLE_COLON, '::')
    method_token = consume(:VAR_ID)
    _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    AST::StaticCall.new(colon_token, lhs, method_token.value, args)
  end

  # Dot Access: obj.field OR obj.method() OR EnumType.Variant
  suffix(:CHAR, '.') do |lhs|
    dot_token = consume(:CHAR, '.')

    if match?(:CHAR, '*')
      star_token = consume(:CHAR, '*')
      AST::GetField.new(star_token, lhs, '*')
    else
      name_token = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
      name = name_token.value

      # Predicate suffix: name? followed by ( → method call with ? suffix
      if match?(:CHAR, '?') && peek_at(1)&.value == '('
        consume(:CHAR, '?')
        name = "#{name}?"
      end

      if match?(:CHAR, '(')
        # Method Call
        _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
        AST::MethodCall.new(name_token, lhs, name, args)
      else
        # Field Access
        AST::GetField.new(name_token, lhs, name)
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
  # Supports `:` join: expr @shared:locked, expr @locked:multiowned (order-independent).
  # Three orthogonal dimensions:
  #   ownership: :multiowned | :shared         (who keeps it alive)
  #   sync:      :locked | :write_locked | :local  (how it's synchronized)
  #   layout:    :indirect                      (where it lives — heap pointer)
  CAP_SIGIL_ATTRS = {
    '@multiowned'     => { dim: :ownership, val: :multiowned  },
    '@shared'         => { dim: :ownership, val: :shared      },
    '@locked'         => { dim: :sync,      val: :locked      },
    '@writeLocked'    => { dim: :sync,      val: :write_locked },
    '@local'          => { dim: :sync,      val: :local       },
    '@indirect'       => { dim: :layout,    val: :indirect    },
    '@alwaysMutable'  => { dim: :sync,      val: :always_mutable },
  }.freeze

  suffix(:VAR_ID, '@multiowned') do |lhs|
    token = consume(:VAR_ID)
    ownership, sync, layout = parse_cap_join(token, CAP_SIGIL_ATTRS[token.value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@shared') do |lhs|
    token = consume(:VAR_ID)
    ownership, sync, layout = parse_cap_join(token, CAP_SIGIL_ATTRS[token.value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@locked') do |lhs|
    token = consume(:VAR_ID)
    ownership, sync, layout = parse_cap_join(token, CAP_SIGIL_ATTRS[token.value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@writeLocked') do |lhs|
    token = consume(:VAR_ID)
    ownership, sync, layout = parse_cap_join(token, CAP_SIGIL_ATTRS[token.value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@local') do |lhs|
    token = consume(:VAR_ID)
    ownership, sync, layout = parse_cap_join(token, CAP_SIGIL_ATTRS[token.value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@alwaysMutable') do |lhs|
    token = consume(:VAR_ID)
    ownership, sync, layout = parse_cap_join(token, CAP_SIGIL_ATTRS[token.value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@indirect') do |lhs|
    token = consume(:VAR_ID)
    ownership, sync, layout = parse_cap_join(token, CAP_SIGIL_ATTRS[token.value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  # Inline union variant constructor: TypeName.VariantName{ field: val, ... }
  # Only fires when lhs is a GetField whose target is a TYPE_ID (uppercase) identifier.
  # Returns SUFFIX_DECLINE (without consuming '{') for any other lhs, so callers
  # like parse_with_capability that legitimately follow an expression with '{' are unaffected.
  suffix(:CHAR, '{') do |lhs|
    if !@suppress_struct_lit && lhs.is_a?(AST::GetField) && lhs.target.is_a?(AST::Identifier) &&
        lhs.target.name[0] =~ /[A-Z]/
      tok = current
      _, field_pairs = parse_comma_seq(:CHAR, '{', '}') do
        k = (current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)).value
        consume(:CHAR, ':')
        v = parse_expression
        [k, v]
      end
      AST::UnionVariantLit.new(tok, lhs.target.name, lhs.field, field_pairs.to_h, :stack)
    else
      SUFFIX_DECLINE
    end
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
    # :pipe_expression → parse_expression with min precedence = s> (1)
    # Excludes s> (prec 1, since 1 > 1 is false) but includes OR (prec 2).
    return parse_expression(1) if item == :pipe_expression
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

  # Consume a numeric literal (either :NUMBER float or :INT64 integer).
  def consume_number
    if current.type == :NUMBER || current.type == :INT64
      tok = current
      @pos += 1
      tok
    else
      error!(current, "Expected a number, got #{current.value} (#{current.type})")
    end
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

    # Compound assignment: x += expr  →  x = x + expr
    if match?(:COMPOUND_ASSIGN)
      unless target.is_a?(AST::Identifier) || target.is_a?(AST::GetField) || target.is_a?(AST::GetIndex)
        @pos = saved_pos
        return nil
      end

      op_token = consume(:COMPOUND_ASSIGN)
      op_char = op_token.value[0]  # '+=' → '+', '-=' → '-', etc.
      op_sym = AST::OP_TO_OP_CODE[op_char] || op_char.to_sym
      rhs = parse_expression
      consume(:CHAR, ';')

      # Desugar: target op= rhs  →  target = target op rhs
      desugared_value = AST::BinaryOp.new(op_token, deep_clone_node(target), op_sym, rhs)

      if target.is_a?(AST::Identifier)
        return AST::BindExpr.new(target_token, target.name, nil, desugared_value)
      else
        return AST::Assignment.new(target_token, target, desugared_value)
      end
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

  def parse_tight_stmt
    tight_token = consume(:KEYWORD, 'TIGHT')
    if match?(:KEYWORD, 'FOR')
      node = parse_for_range
      node.tight = true
      return node
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
      consume(:KEYWORD, 'DO')
      body  = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    end

    node = AST::WhileLoop.new(tight_token, cond, body, nil)
    node.tight = true
    node
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

      # comptime: T — compile-time type parameter (EXTERN FN only)
      is_comptime = false
      if match?(:VAR_ID) && current.value == "comptime"
        # Peek ahead: if next is ':', it's a comptime param
        if peek_at(1)&.type == :CHAR && peek_at(1)&.value == ":"
          consume(:VAR_ID) # consume 'comptime'
          is_comptime = true
        end
      end

      p_name = consume(:VAR_ID).value unless is_comptime
      p_type = :Any
      default_val = nil

      if is_comptime
        consume(:CHAR, ':')
        p_type = consume(:TYPE_ID).value.to_sym  # The type param name (T)
        p_name = "comptime"
      else
        # Syntax: name=default: Type  (default before type annotation)
        if match!(:CHAR, '=')
          default_val = parse_expression()
        end
        if match!(:CHAR, ':')
          p_type = parse_type_annotation
        end
      end

      { name: p_name, type: p_type, default: default_val, mutable: is_mutable, takes: takes, comptime: is_comptime }
    end
     .last # always ignore the first token
  end

  def parse_require
    tok = consume(:KEYWORD, 'REQUIRE')
    raw = consume(:STRING).value

    if raw.start_with?("pkg:")
      # Package import: REQUIRE "pkg:math"  →  kind=:package, path="math"
      pkg_name  = raw.sub(/\Apkg:/, '')
      path      = pkg_name
      namespace = pkg_name.gsub(/[^a-zA-Z0-9_]/, '_').sub(/\A(\d)/, '_\1')
      kind      = :package
    else
      # Local file import: REQUIRE "file.cht"
      path      = raw
      namespace = File.basename(path, '.cht')
                      .gsub(/[^a-zA-Z0-9_]/, '_')
                      .sub(/\A(\d)/, '_\1')
      kind      = :local
    end

    if match!(:KEYWORD, 'AS')
      namespace = consume(:VAR_ID).value
    end
    match!(:CHAR, ';')
    AST::RequireNode.new(tok, path, namespace, kind)
  end

  def parse_visibility_decl(visibility)
    consume(:KEYWORD)  # consume PUB or PRIVATE
    if match?(:KEYWORD, 'FN')
      parse_function_def(visibility)
    elsif match?(:KEYWORD, 'STRUCT')
      parse_struct_def(visibility)
    elsif match?(:KEYWORD, 'ENUM')
      parse_enum_def(visibility)
    elsif match?(:KEYWORD, 'UNION')
      parse_union_def(visibility)
    else
      error!(current, "Expected FN, STRUCT, ENUM, or UNION after visibility modifier, got '#{current.value}'")
    end
  end

  # EXTERN FN name(params) RETURNS type FROM "module_name";
  # EXTERN STRUCT Name { fields } FROM "module_name";
  def parse_extern_decl
    tok = consume(:KEYWORD, 'EXTERN')
    if match?(:KEYWORD, 'FN')
      parse_extern_fn(tok)
    elsif match?(:KEYWORD, 'STRUCT')
      parse_extern_struct(tok)
    else
      error!(current, "Expected FN or STRUCT after EXTERN, got '#{current.value}'")
    end
  end

  def parse_extern_fn(extern_tok)
    consume(:KEYWORD, 'FN')

    # Parse name: either "fnName", "fnName<T>", or "TypeName<T>.methodName"
    owner_type = nil
    owner_type_params = []
    fn_type_params = []

    if match?(:TYPE_ID)
      # Could be TypeName<T>.method or just a TYPE_ID-named function
      type_name = consume(:TYPE_ID).value
      if match!(:CHAR, '<')
        loop do
          owner_type_params << consume(:TYPE_ID).value.to_sym
          break unless match!(:CHAR, ',')
        end
        consume(:CHAR, '>')
      end
      if match!(:CHAR, '.')
        # It's a method: TypeName<T>.methodName
        owner_type = type_name
        name = consume(:VAR_ID).value
      else
        # TYPE_ID without dot — treat as function name (unusual but valid)
        name = type_name
        fn_type_params = owner_type_params
        owner_type_params = []
      end
    else
      name = consume(:VAR_ID).value
      # Optional generic type params on the function: fnName<T>
      if match!(:CHAR, '<')
        loop do
          fn_type_params << consume(:TYPE_ID).value.to_sym
          break unless match!(:CHAR, ',')
        end
        consume(:CHAR, '>')
      end
    end

    params = parse_argument_list
    return_type = match!(:KEYWORD, 'RETURNS') ? parse_type_annotation : nil

    # Optional: EFFECTS :alloc:frame, :alloc:heap, :safe — declare side effects.
    # :alloc:frame → inject rt.frameAlloc() for Alloc-typed parameters
    # :alloc:heap  → inject rt.heapAlloc() for Alloc-typed parameters
    # :alloc       → shorthand for :alloc:frame
    # :safe        → run directly on fiber stack (skip onRootStack trampoline).
    #                Use for pure compute FFI (SHA256, math, JSON parsing).
    #                Do NOT use for filesystem I/O or deep-stack functions.
    effects = {}
    if match!(:KEYWORD, 'EFFECTS')
      loop do
        consume(:CHAR, ':')
        eff_name = consume(:VAR_ID).value.to_sym
        unless [:alloc, :safe].include?(eff_name)
          error!(current, "Unknown effect ':#{eff_name}'. Valid effects: :alloc, :safe")
        end
        if eff_name == :safe
          effects[:safe] = true
        elsif eff_name == :alloc && match?(:CHAR, ':')
          consume(:CHAR, ':')
          qualifier = consume(:VAR_ID).value.to_sym
          unless [:frame, :heap].include?(qualifier)
            error!(current, "Unknown alloc qualifier ':#{qualifier}'. Use :alloc:frame or :alloc:heap")
          end
          effects[:alloc] = qualifier
        else
          effects[:alloc] = :frame
        end
        break unless match!(:CHAR, ',')
      end
    end

    consume(:KEYWORD, 'FROM')
    from_module = consume(:STRING).value
    match!(:CHAR, ';')
    node = AST::ExternFnDecl.new(extern_tok, name, params, return_type, from_module, effects)
    node.owner_type = owner_type if owner_type
    node.owner_type_params = owner_type_params if owner_type_params.any?
    node.fn_type_params = fn_type_params if fn_type_params.any?
    node
  end

  def parse_extern_struct(extern_tok)
    consume(:KEYWORD, 'STRUCT')
    name = consume(:TYPE_ID).value

    # Optional generic type params: EXTERN STRUCT Parsed<T> { ... }
    type_params = []
    if match!(:CHAR, '<')
      loop do
        type_params << consume(:TYPE_ID).value.to_sym
        break unless match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end

    # Fields can be empty: EXTERN STRUCT Opaque {} FROM "mod";
    fields = parse_struct_body

    # Optional: CLOSE "method" — register cleanup method for RAII
    close_method = nil
    if match!(:KEYWORD, 'CLOSE')
      close_method = consume(:STRING).value
    end

    # Optional: AS "ZigTypeExpr" — alias to parameterized Zig type (e.g. Parsed(JsonRecord))
    as_type = nil
    if match!(:KEYWORD, 'AS')
      as_type = consume(:STRING).value
    end

    from_module = nil
    if match!(:KEYWORD, 'FROM')
      from_module = consume(:STRING).value
    end
    match!(:CHAR, ';')
    node = AST::ExternStructDecl.new(extern_tok, name, fields, from_module)
    node.type_params = type_params if type_params.any?
    node.close_method = close_method
    node.as_type = as_type
    node
  end

  def parse_struct_def(visibility = :package)
    tok = consume(:KEYWORD, 'STRUCT')
    name = consume(:TYPE_ID).value
    type_params = []
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      until match?(:CHAR, '>')
        type_params << consume(:TYPE_ID).value
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end
    fields = parse_struct_body
    AST::StructDef.new(tok, name, fields, visibility, type_params)
  end

  def parse_enum_def(visibility = :package)
    tok = consume(:KEYWORD, 'ENUM')
    name = consume(:TYPE_ID).value
    consume(:CHAR, '{')
    variants = []
    until match?(:CHAR, '}')
      variants << consume(:TYPE_ID).value
      match!(:CHAR, ',')
    end
    consume(:CHAR, '}')
    AST::EnumDef.new(tok, name, variants, visibility)
  end

  def parse_union_def(visibility = :package)
    tok = consume(:KEYWORD, 'UNION')
    name = consume(:TYPE_ID).value

    # Parse optional generic type parameters: UNION Option<T> { ... }
    type_params = []
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      until match?(:CHAR, '>')
        type_params << consume(:TYPE_ID).value
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end

    consume(:CHAR, '{')
    variants = {}
    method_reqs = []
    until match?(:CHAR, '}')
      if match?(:KEYWORD, 'FN') || (match?(:KEYWORD, 'PUB') && peek.type == :KEYWORD && peek.value == 'FN') ||
         (match?(:KEYWORD, 'PRIVATE') && peek.type == :KEYWORD && peek.value == 'FN')
        # Method requirement stub: [PUB|PRIVATE] FN name(param: Type, ...) RETURNS Type
        stub_vis = :package
        if match?(:KEYWORD, 'PUB')
          consume(:KEYWORD, 'PUB')
          stub_vis = :pub
        elsif match?(:KEYWORD, 'PRIVATE')
          consume(:KEYWORD, 'PRIVATE')
          stub_vis = :private
        end
        fn_tok = consume(:KEYWORD, 'FN')
        fn_name = consume(:VAR_ID).value
        _, raw_params = parse_comma_seq(:CHAR, '(', ')') do
          p_name = consume(:VAR_ID).value
          consume(:CHAR, ':')
          p_type = parse_type_annotation
          { name: p_name, type: p_type }
        end
        ret_type = nil
        if match!(:KEYWORD, 'RETURNS')
          ret_type = parse_type_annotation
        end
        # Optional default body: FN name(...) RETURNS T -> body END
        default_body = nil
        if match?(:ARROW, '->')
          consume(:ARROW, '->')
          default_body = parse_block_body(['END'])
          consume(:KEYWORD, 'END')
        end
        method_reqs << { token: fn_tok, name: fn_name, params: raw_params,
                         return_type: ret_type, body: default_body, visibility: stub_vis }
      else
        var_name = consume(:TYPE_ID).value
        if match?(:CHAR, '{')
          # Inline struct variant: Circle { radius: Number, color: String }
          # Supports @indirect on fields for recursive types.
          # NOTE: @indirect is consumed by parse_type_annotation (line ~1425)
          # but silently discarded. We detect it by checking if the type was
          # marked as indirect BEFORE parse_type_annotation returns.
          indirect_fields = Set.new
          _, field_pairs = parse_comma_seq(:CHAR, '{', '}') do
            fname = (current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)).value
            consume(:CHAR, ':')
            # Peek: will parse_type_annotation consume @indirect?
            ftype = parse_type_annotation
            # parse_type_annotation consumed @indirect silently.
            # We detect it was present by checking @last_indirect_consumed.
            indirect_fields << fname if @last_indirect_consumed
            @last_indirect_consumed = false
            [fname, ftype]
          end
          var_data = { kind: :inline_struct, fields: field_pairs.to_h }
          var_data[:indirect_fields] = indirect_fields unless indirect_fields.empty?
          variants[var_name] = var_data
        elsif match!(:CHAR, ':')
          # Single-type payload: Data: Number  (or Data: Number @indirect)
          vtype = parse_type_annotation
          if @last_indirect_consumed
            @last_indirect_consumed = false
            vtype = { kind: :indirect_payload, type: vtype }
          end
          variants[var_name] = vtype
        else
          # Unit variant: Point
          variants[var_name] = nil
        end
      end
      match!(:CHAR, ',')
    end
    consume(:CHAR, '}')
    node = AST::UnionDef.new(tok, name, variants, visibility)
    node.type_params = type_params unless type_params.empty?
    node.methods = method_reqs unless method_reqs.empty?
    node
  end

  def parse_function_def(visibility = :package)
    fn_token = consume(:KEYWORD, 'FN')
    name = consume(:VAR_ID).value
    # Predicate suffix: FN name?(...) — ? is part of the function name
    if match?(:CHAR, '?')
      consume(:CHAR, '?')
      name = "#{name}?"
    end

    # Parse optional generic type parameters: FN name<T, U>(...)
    type_params = []
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      until match?(:CHAR, '>')
        type_params << consume(:TYPE_ID).value
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end

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

    # 4. Parse optional @reentrant / @nonReentrant / @reentrant:tailCall function annotation.
    reentrant = nil
    tail_call = false
    if match?(:VAR_ID) && %w[@reentrant @nonReentrant].include?(current.value)
      cap_tok = consume(:VAR_ID)
      reentrant = cap_tok.value == '@reentrant' ? :reentrant : :non_reentrant
      # Check for :tailCall suffix
      if reentrant == :reentrant && match?(:CHAR, ':') && @tokens[@pos + 1]&.value == 'tailCall'
        consume(:CHAR, ':')
        consume(:VAR_ID)
        tail_call = true
      end
    end

    consume(:ARROW, '->')
    body = parse_block_body(['END', 'CATCH'])

    # 2. Parse Optional CATCH blocks (multi-clause)
    # Syntax:
    #   CATCH ErrorName WITH("msg")
    #     body;
    #   CATCH ErrorName
    #     body;
    #   DEFAULT
    #     body;
    #   END
    catch_block = nil
    # Parse CATCH clauses:
    #   CATCH Kind                       -- match on error kind
    #   CATCH Kind WITH(ErrorName)       -- match on kind + specific error
    #   DEFAULT                          -- catch-all
    catch_block = nil
    if match?(:KEYWORD, 'CATCH')
      catch_clauses = []
      default_body = nil
      while match?(:KEYWORD, 'CATCH')
        consume(:KEYWORD, 'CATCH')
        kind = consume(:TYPE_ID).value  # Transient, Input, System, etc.
        error_name = nil
        if match?(:KEYWORD, 'WITH')
          consume(:KEYWORD, 'WITH')
          consume(:CHAR, '(')
          error_name = consume(:TYPE_ID).value
          consume(:CHAR, ')')
        end
        clause_body = parse_block_body(['CATCH', 'DEFAULT', 'END'])
        catch_clauses << { kind: kind, error_name: error_name, body: clause_body }
      end
      if match?(:KEYWORD, 'DEFAULT')
        consume(:KEYWORD, 'DEFAULT')
        default_body = parse_block_body(['END'])
      end
      catch_block = AST::CatchBlock.new(fn_token, catch_clauses, default_body)
    end

    consume(:KEYWORD, 'END')
    node = AST::FunctionDef.new(fn_token, name, params, captures, return_type, return_lifetime, body,
      catch_block ? catch_block.catch_clauses : [], catch_block ? catch_block.default_body : nil, visibility)
    node.type_params = type_params unless type_params.empty?
    node.reentrant = reentrant
    node.tail_call = tail_call
    node
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
    when 's>'             then 1
    when 'OR', 'AS'       then 2
    when '..<', '..<=', '..=' then 3
    when '||'             then 4
    when '&&'             then 5
    when '==', '!=', '<', '>', '<=', '>=' then 6
    when '+', '-', '%+', '%-', '!+', '!-' then 7
    when '*', '/', 'MOD', '%*', '!*'     then 8
    when '**'             then 9
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
      # Predicate suffix: x s> isPositive? parses as OptionalUnwrap(Identifier).
      # Unwrap and restore the ? suffix as part of the function name.
      if rhs.is_a?(AST::OptionalUnwrap) && rhs.target.is_a?(AST::Identifier)
        rhs = AST::Identifier.new(rhs.token, "#{rhs.target.name}?")
      end
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

    # Syntax: ... OR EXIT "message" (set error context message + raise)
    elsif match!(:KEYWORD, 'EXIT')
      msg = parse_expression
      rhs = AST::OrExit.new(previous, msg)

    # Syntax: ... OR PASS (ignore error, use undefined/default)
    elsif match!(:KEYWORD, 'PASS')
      rhs = AST::OrPass.new(previous)

    # Syntax: ... OR PRUNE (discard error, skip item — concurrent SELECT/WHERE)
    elsif match!(:KEYWORD, 'PRUNE')
      rhs = AST::OrPrune.new(previous)

    # Syntax: ... OR BREAK (error-to-break coercion, valid only inside loops)
    elsif match!(:KEYWORD, 'BREAK')
      rhs = AST::OrBreak.new(previous)

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

  # Sentinel returned by a suffix rule to signal "this suffix does not apply
  # to the current lhs — stop processing without consuming any tokens."
  SUFFIX_DECLINE = Object.new.freeze

  def parse_suffixes(lhs)
    loop do
      rule = @@suffix_rules[[current.type, current.value]]
      break unless rule
      # Run the rule, passing the current 'lhs' into it.
      # If the rule returns SUFFIX_DECLINE, it did not consume anything and
      # the suffix loop should stop (leaving the token for the caller).
      result = instance_exec(lhs, &rule)
      break if result.equal?(SUFFIX_DECLINE)
      lhs = result
    end
    lhs
  end

  def parse_var_id
    # 1. Base Case: Always start with an Identifier
    var_token = consume(:VAR_ID)
    name = var_token.value
    node = AST::Identifier.new(var_token, name)

    # Predicate suffix: name? followed by ( → function call with ? suffix
    if match?(:CHAR, '?') && peek_at(1)&.value == '('
      consume(:CHAR, '?')
      name = "#{name}?"
    end

    # 2. Check for Immediate Function Call: name(...)
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

    # Shorthand: IF condition -> single_statement;
    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      return AST::IfStatement.new(if_token, condition, [stmt].compact, [])
    end

    # Single bare bind: IF expr AS name [THEN ...]
    # AS is not consumed by parse_expression (guard blocks non-@-prefixed identifiers),
    # so we check for it explicitly here.
    if match?(:KEYWORD, 'AS')
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      # Bare multi-bind error: IF expr AS name && expr2 AS name2 THEN
      if match?(:CHAR, '&&')
        error!(if_token,
          "Syntax Error: Multiple optional bindings require parentheses around each binding.\n" \
          "  Found: IF expr AS name && expr AS name THEN\n" \
          "  Use:   IF (expr AS name) && (expr AS name) THEN")
      end
      bindings = [{ expr: condition, name: name_tok.value, name_token: name_tok }]
      return parse_if_bind_body(if_token, bindings)
    end

    # Paren-bind form: IF (expr AS name) [&& (expr2 AS name2)] THEN ...
    # Paren primary marks BinaryOp(:BIND_VAR) with paren_bind:true when (expr AS name) is parsed.
    if (bindings = extract_paren_bindings(condition, if_token))
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
  # Returns nil if condition is not a paren-bind pattern.
  # Raises error if any bind in a && chain is bare (not paren-wrapped).
  def extract_paren_bindings(node, if_token)
    case node
    when AST::BinaryOp
      if node.op == :BIND_VAR
        return node.paren_bind ? [{ expr: node.left, name: node.right.name, name_token: node.right.token }] : nil
      elsif node.op == :AND  # && maps to :AND in OP_TO_OP_CODE
        left_binds  = extract_paren_bindings(node.left, if_token)
        right_binds = extract_paren_bindings(node.right, if_token)
        # Only treat as bind-chain if at least one side is a paren-bind
        if left_binds || right_binds
          # Validate: bare binds in && position are illegal
          validate_no_bare_bind!(node.left,  if_token) unless left_binds
          validate_no_bare_bind!(node.right, if_token) unless right_binds
          return (left_binds || []).concat(right_binds || [])
        end
      end
    end
    nil
  end

  # Raises an error if node is a non-paren BIND_VAR anywhere in the && tree.
  def validate_no_bare_bind!(node, if_token)
    return unless node.is_a?(AST::BinaryOp)
    if node.op == :BIND_VAR && !node.paren_bind
      error!(if_token,
        "Syntax Error: Multiple optional bindings require parentheses around each binding.\n" \
        "  Found: IF expr AS name && expr AS name THEN\n" \
        "  Use:   IF (expr AS name) && (expr AS name) THEN")
    elsif node.op == :AND
      validate_no_bare_bind!(node.left,  if_token)
      validate_no_bare_bind!(node.right, if_token)
    end
  end

  # Expression-position IF: each branch is a single expression (no semicolons).
  def parse_if_expr
    if_token = consume(:KEYWORD, 'IF')
    parse_if_chain_expr(if_token)
  end

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
  def parse_match_expr
    tok = consume(:KEYWORD, 'MATCH')
    takes = match?(:KEYWORD, 'TAKES') && consume(:KEYWORD, 'TAKES')
    exhaustive = match?(:KEYWORD, 'IFF') && consume(:KEYWORD, 'IFF')
    expr = parse_expression
    consume(:KEYWORD, 'START')

    cases = []
    default_case = nil

    until match?(:KEYWORD, 'END') || match?(:EOF)
      if match?(:KEYWORD, 'DEFAULT')
        consume(:KEYWORD, 'DEFAULT')
        consume(:ARROW)
        default_case = [parse_expression]
        match!(:CHAR, ',')
        break
      end

      if match?(:KEYWORD, 'WHEN')
        consume(:KEYWORD, 'WHEN')
        condition = parse_expression
        consume(:ARROW)
        cases << { kind: :when, value: condition, body: [parse_expression] }
      elsif match?(:CHAR, '{')
        pattern = parse_struct_pattern
        consume(:ARROW)
        cases << { kind: :struct_pattern, value: pattern, body: [parse_expression] }
      else
        @suppress_struct_lit = true
        pattern = parse_expression
        @suppress_struct_lit = false
        binding = nil
        destructure = nil
        if match?(:KEYWORD, 'AS')
          consume(:KEYWORD, 'AS')
          binding = consume(:VAR_ID).value
        elsif match?(:CHAR, '{')
          destructure = parse_struct_pattern
        end
        consume(:ARROW)
        cases << { kind: :eq, value: pattern, binding: binding, destructure: destructure, body: [parse_expression] }
      end
      match!(:CHAR, ',')
    end

    consume(:KEYWORD, 'END')
    AST::MatchStatement.new(tok, expr, cases, default_case, [], nil, !!exhaustive, !!takes)
  end

  # FOR var IN (start ..= end) DO body END   — range iteration
  # FOR var IN (start ..< end) DO body END   — range iteration
  # FOR var IN collection DO body END         — collection iteration
  def parse_for_range
    tok = consume(:KEYWORD, 'FOR')
    var_name = consume(:VAR_ID).value
    consume(:KEYWORD, 'IN')

    # Ranges need parens for precedence; collections don't.
    if match?(:CHAR, '(')
      consume(:CHAR, '(')
      expr = parse_expression
      consume(:CHAR, ')')
    else
      expr = parse_expression
    end

    # Shorthand: FOR var IN range -> single_statement;
    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      body = [stmt].compact
    else
      consume(:KEYWORD, 'DO')
      body = parse_stmts_until_end
      consume(:KEYWORD, 'END')
    end

    if expr.is_a?(AST::RangeLit)
      AST::ForRange.new(tok, var_name, expr.start, expr.finish, expr.inclusive, body, nil)
    else
      AST::ForEach.new(tok, var_name, expr, body, nil, false)
    end
  end

  def parse_match_statement
    tok = consume(:KEYWORD, 'MATCH')
    takes = match?(:KEYWORD, 'TAKES') && consume(:KEYWORD, 'TAKES')
    exhaustive = match?(:KEYWORD, 'IFF') && consume(:KEYWORD, 'IFF')
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
        # Suppress struct literal parsing so TypeName.Variant{ ... } doesn't get
        # consumed as a constructor — the { starts a destructuring pattern.
        @suppress_struct_lit = true
        pattern = parse_expression
        @suppress_struct_lit = false
        binding = nil
        destructure = nil
        if match?(:KEYWORD, 'AS')
          consume(:KEYWORD, 'AS')
          binding = consume(:VAR_ID).value
        elsif match?(:CHAR, '{')
          # Union variant destructuring: Result.Ok{ value, count }
          destructure = parse_struct_pattern
        end
        consume(:ARROW)
        body = parse_block_body([',', 'DEFAULT', 'WHEN', 'END'])
        cases << { kind: :eq, value: pattern, binding: binding, destructure: destructure, body: body }
      end
      match!(:CHAR, ',')  # consume comma separator between cases if present
    end

    consume(:KEYWORD, 'END')
    AST::MatchStatement.new(tok, expr, cases, default_case, [], nil, !!exhaustive, !!takes)
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

      if match?(:CHAR, ':')
        consume(:CHAR, ':')
        # `_` as value means wildcard — ignore this field's value
        if current.type == :VAR_ID && current.value == '_'
          consume(:VAR_ID)
          fields << { name: name, value: :wildcard }
        else
          fields << { name: name, value: parse_expression }
        end
      else
        # Bare name: destructuring bind — extract field into a local variable.
        # { x, y } means bind subject.x to x, subject.y to y.
        fields << { name: name, value: :bind }
      end

      match!(:CHAR, ',')  # optional comma between fields
    end

    consume(:CHAR, '}')
    AST::StructPattern.new(tok, fields, partial)
  end

  ERROR_KINDS = AST::ERROR_KINDS.map(&:to_s).freeze

  # RAISE Kind;
  # RAISE Kind, ErrorName;
  # RAISE Kind, ErrorName, "message";
  def parse_raise_stmt
    tok = consume(:KEYWORD, 'RAISE')

    # Legacy: RAISE "string"; (bare string = System error with message)
    if match?(:STRING)
      msg = parse_expression
      consume(:CHAR, ';')
      return AST::Raise.new(tok, :System, nil, msg)
    end

    if match?(:CHAR, ';')
      consume(:CHAR, ';')
      return AST::Raise.new(tok, :System, nil, nil)
    end

    # Kind (required TYPE_ID from the 6 error kinds)
    kind_tok = consume(:TYPE_ID)
    kind = kind_tok.value.to_sym
    unless ERROR_KINDS.include?(kind_tok.value)
      error!(kind_tok, "RAISE expects an error kind: #{ERROR_KINDS.join(', ')}. Got '#{kind_tok.value}'")
    end

    error_name = nil
    message = nil

    if match?(:CHAR, ',')
      consume(:CHAR, ',')
      # Next could be a TYPE_ID (error name) or a STRING (message)
      if match?(:TYPE_ID)
        error_name = consume(:TYPE_ID).value
        if match?(:CHAR, ',')
          consume(:CHAR, ',')
          message = parse_expression
        end
      else
        message = parse_expression
      end
    end

    consume(:CHAR, ';')
    AST::Raise.new(tok, kind, error_name, message)
  end

  def parse_while_loop
    tok = consume(:KEYWORD, 'WHILE')
    condition = parse_expression

    # WHILE expr AS name [-> stmt | DO ... END]
    if match?(:KEYWORD, 'AS')
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      if match?(:ARROW, '->')
        consume(:ARROW, '->')
        stmt = parse_statement
        return AST::WhileBindLoop.new(tok, condition, name_tok.value, name_tok, [stmt].compact, nil)
      end
      consume(:KEYWORD, 'DO')
      body = parse_stmts_until_end
      consume(:KEYWORD, 'END')
      return AST::WhileBindLoop.new(tok, condition, name_tok.value, name_tok, body, nil)
    end

    # Shorthand: WHILE condition -> single_statement;
    if match?(:ARROW, '->')
      consume(:ARROW, '->')
      stmt = parse_statement
      return AST::WhileLoop.new(tok, condition, [stmt].compact)
    end

    consume(:KEYWORD, 'DO')
    body = parse_stmts_until_end
    consume(:KEYWORD, 'END')
    AST::WhileLoop.new(tok, condition, body)
  end

  def parse_stmts_until_end
    parse_block_body(['END'])
  end

  def parse_struct_body
    _, pairs = parse_comma_seq(:CHAR, '{', '}') do
      name = consume(:VAR_ID).value

      # Syntax: name=default: Type  (default before type annotation)
      default_val = nil
      if match!(:CHAR, '=')
        default_val = parse_expression()
      end

      consume(:CHAR, ':')

      # Optional BORROWED modifier: field is a reference, not owned
      borrowed = match!(:KEYWORD, 'BORROWED') ? true : false

      type = parse_type_annotation()

      [name, { type: type, default: default_val, borrowed: borrowed }]
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

  # Returns true if, starting from current position '<', the token stream matches:
  #   < TYPE_ID (, TYPE_ID)* > end_char
  # Used to disambiguate generic annotations from comparison operators.
  def peek_generic_angle_params?(end_char)
    saved = @pos
    begin
      return false unless current.type == :CHAR && current.value == '<'
      @pos += 1 # skip '<'
      loop do
        return false unless current.type == :TYPE_ID
        @pos += 1 # skip TYPE_ID
        if current.type == :CHAR && current.value == ','
          @pos += 1 # skip ','
        elsif current.type == :CHAR && current.value == '>'
          @pos += 1 # skip '>'
          return current.type == :CHAR && current.value == end_char
        else
          return false
        end
      end
    ensure
      @pos = saved
    end
  end

  # Struct literal: Pair<Number>{ ... }
  def peek_is_generic_struct_lit?
    peek_generic_angle_params?('{')
  end

  def parse_lit(storage)
    if match?(:TYPE_ID)
      type_token = consume(:TYPE_ID)
      name = type_token.value
      # Collection constructor: List[] / Pool[] (with optional capabilities)
      # Element type is inferred from first append/insert.
      if %w[List Pool Set].include?(name) && match?(:CHAR, '[')
        consume(:CHAR, '[')
        consume(:CHAR, ']')
        collection = { "List" => :list, "Pool" => :pool, "Set" => :set }.fetch(name)
        is_soa = false
        shard_count = nil
        if match?(:VAR_ID) && current.value == "@soa"
          consume(:VAR_ID)
          is_soa = true
        elsif match?(:CHAR, ':')
          dummy_tok = Lexer::Token.new(:VAR_ID, "@#{name.downcase}", type_token.line, type_token.column)
          mods = parse_collection_modifiers!(dummy_tok)
          shard_count = mods[:shard_count]
          is_soa = mods[:soa]
        end
        node = AST::ListLit.new(type_token, [], storage)
        node.instance_variable_set(:@constructor_collection, collection)
        node.instance_variable_set(:@constructor_soa, is_soa)
        node.instance_variable_set(:@constructor_shard_count, shard_count)
        return node
      elsif match?(:CHAR, '<') && peek_is_generic_struct_lit?
        # Generic struct literal: Pair<Number>{ first: 1.0, second: 2.0 }
        consume(:CHAR, '<')
        type_args = []
        until match?(:CHAR, '>')
          type_args << consume(:TYPE_ID).value
          match!(:CHAR, ',')
        end
        consume(:CHAR, '>')
        _, fields = parse_comma_seq(:CHAR, '{', '}') do
          k = (current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)).value; consume(:CHAR, ':'); v = parse_expression
          [k, v]
        end
        return AST::StructLit.new(type_token, name, fields.to_h, storage, type_args)
      elsif match?(:CHAR, '{') && !@suppress_struct_lit
        # Struct literal: User{ id: 1 }
        _, fields = parse_comma_seq(:CHAR, '{', '}') do
          k = (current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)).value; consume(:CHAR, ':'); v = parse_expression
          [k, v]
        end
        return AST::StructLit.new(type_token, name, fields.to_h, storage)
      else
        # Type name reference — e.g. enum variant access: Color.Red
        node = AST::Identifier.new(type_token, name)
        return parse_suffixes(node)
      end
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

  # RECOVER(default_expr) — pipeline error recovery
  def parse_recover_op
    tok = consume(:KEYWORD, 'RECOVER')
    consume(:CHAR, '(')
    default_expr = parse_expression
    consume(:CHAR, ')')
    AST::RecoverOp.new(tok, default_expr)
  end

  # WINDOW(size) expression        -- sliding window (positional arg)
  # WINDOW(size: N, time: 'Xms')  -- batch/tumbling window (named args)
  # e.g., prices s> WINDOW(3) SUM(_) / 3.0
  # e.g., stream s> WINDOW(size: 100) SELECT process(_)
  # e.g., stream s> WINDOW(size: 100, time: '500ms') EACH { ... }
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
        options[key_tok.value] = val
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
  # e.g., users s> JOIN(orders) _.userId
  # e.g., users s> JOIN(orders) %(a, b) -> a.id == b.userId
  def parse_join_op
    join_token = consume(:KEYWORD, 'JOIN')
    consume(:CHAR, '(')
    right_source = parse_expression
    consume(:CHAR, ')')
    key_expr = parse_expression(1)  # pipe_expression precedence
    AST::JoinOp.new(join_token, right_source, key_expr)
  end

  # SHARD(key_expr, target_map)
  # e.g., (0..<n) s> SHARD("key:" + _, map) s> CONCURRENT EACH { ... }
  # Routes items to owning schedulers by hashing the key expression.
  # `_` is the implicit item binding (same as SELECT/WHERE).
  def parse_shard_op
    shard_token = consume(:KEYWORD, 'SHARD')
    consume(:CHAR, '(')
    key_expr = parse_expression
    consume(:CHAR, ',')
    target_map = parse_expression
    consume(:CHAR, ')')
    AST::ShardOp.new(shard_token, key_expr, target_map)
  end

  # Parses a function type annotation: FN(Type, ...) -> ReturnType
  # Parameter names are optional (documentation only): FN(n: Int64) -> Bool is the same as FN(Int64) -> Bool.
  # Returns a Type whose raw is { params: [...], return: { type: Type }, fn_type: true }.
  def parse_fn_type_annotation
    consume(:KEYWORD, 'FN')
    consume(:CHAR, '(')
    param_types = []
    until match?(:CHAR, ')')
      # Allow optional name annotation: `name: Type` or just `Type`
      if match?(:VAR_ID) && peek.type == :CHAR && peek.value == ':'
        consume(:VAR_ID)   # name is for documentation only
        consume(:CHAR, ':')
      end
      param_types << parse_type_annotation
      break unless match!(:CHAR, ',')
    end
    consume(:CHAR, ')')
    consume(:ARROW, '->')
    return_type = parse_type_annotation
    # Parse optional @reentrant capability on fn-type annotations.
    # FN(Int64) -> Bool @reentrant means the parameter accepts @reentrant functions.
    allows_reentrant = false
    if match?(:VAR_ID) && current.value == '@reentrant'
      consume(:VAR_ID)
      allows_reentrant = true
    end
    Type.new({
      params: param_types.each_with_index.map { |t, i|
        { name: "arg#{i}", type: t, required: true, mutable: false, takes: false }
      },
      return: { type: return_type },
      fn_type: true,
      reentrant: allows_reentrant
    })
  end

  def parse_type_annotation
    # Function type: FN(Type, ...) -> ReturnType
    return parse_fn_type_annotation if match?(:KEYWORD, 'FN')

    # Check for tense (Promise) prefix: ~Type
    tense_prefix = ""
    if match!(:CHAR, '~')
      tense_prefix = "~"
    end

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

    # Generic type arguments: Pair<Number> or Map<String, Number>
    # In type-annotation context, '<' is always a generic argument list, never a comparison.
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      type_args = []
      until match?(:CHAR, '>')
        type_args << consume(:TYPE_ID).value
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
      base = "#{base}<#{type_args.join(',')}>"
    end

    # Element-level capability: T@shared[] means Array<Arc<T>>.
    # Parsed BEFORE the [] suffix so it attaches to the element type, not the collection.
    # Also handles T@shared:locked[] (Arc<Mutex<T>>[]).
    elem_ownership = nil
    elem_sync = nil
    if match?(:VAR_ID) && %w[@shared @multiowned @locked @writeLocked @link].include?(current.value)
      # Lookahead: next token must be '[' (simple) or ':' followed by sync then '['
      next_tok = peek_at(1)
      is_elem_cap = (next_tok&.type == :CHAR && next_tok&.value == '[')
      if !is_elem_cap && next_tok&.type == :CHAR && next_tok&.value == ':'
        # Check for :locked[] or :writeLocked[] pattern
        sync_tok = peek_at(2)
        bracket_tok = peek_at(3)
        is_elem_cap = sync_tok&.type == :VAR_ID &&
                      %w[@locked @writeLocked locked writeLocked].include?(sync_tok&.value) &&
                      bracket_tok&.type == :CHAR && bracket_tok&.value == '['
      end
      if is_elem_cap
        cap_tok = consume(:VAR_ID)
        case cap_tok.value
        when "@shared"     then elem_ownership = :shared
        when "@multiowned" then elem_ownership = :multiowned
        when "@locked"     then elem_sync = :locked
        when "@writeLocked" then elem_sync = :write_locked
        when "@link"       then elem_ownership = :link
        end
        # Parse optional :sync suffix (e.g., @shared:locked)
        if match?(:CHAR, ':')
          consume(:CHAR, ':')
          sync_tok = consume(:VAR_ID)
          case sync_tok.value
          when "@locked", "locked"       then elem_sync = :locked
          when "@writeLocked", "writeLocked" then elem_sync = :write_locked
          end
        end
      end
    end

    if match!(:CHAR, '[')
      # Case 1: Dynamic "Number[]"
      if match!(:CHAR, ']')
        inner = "[]"

      # Case 2: Fixed Inferred "Number[*]"
      elsif match!(:CHAR, '*')
        consume(:CHAR, ']')
        inner = "[*]"

      # Case 3: Fixed Explicit "Number[10]"
      elsif match?(:NUMBER) || match?(:INT64)
        size = consume_number.value.to_i
        consume(:CHAR, ']')
        inner = "[#{size}]"

      # Case 4: Open stream marker "T[?]" (used inside tense type ~T[?])
      elsif match?(:CHAR, '?')
        consume(:CHAR, '?')
        consume(:CHAR, ']')
        inner = "[?]"

      # Case 5: Infinite stream marker "T[INF]" (used inside tense type ~T[INF])
      elsif match?(:TYPE_ID) && current.value == 'INF'
        consume(:TYPE_ID)
        consume(:CHAR, ']')
        inner = "[INF]"

      else
        error!(current, "Syntax Error: Expected ']', '*', '?', 'INF', or size in array type.")
      end

      # Allow multiple dimensions (e.g., Number[][][])
      while match?(:CHAR, '[')
        consume(:CHAR, '[')
        if match!(:CHAR, ']')
          inner += "[]"
        elsif match?(:NUMBER) || match?(:INT64)
          size = consume_number.value.to_i
          consume(:CHAR, ']')
          inner += "[#{size}]"
        else
          error!(current, "Syntax Error: Expected ']' or size in array type.")
        end
      end
    end

    # Capability suffix: T @shared, T[]@list:soa, T[N]@soa:shared:locked, HashMap<V>@sharded(N), etc.
    # Parser only does token consumption and duplicate detection. Semantic validation
    # (e.g., "@list requires array", "@soa requires fixed array") is in the annotator.
    caps = parse_capabilities
    ownership   = caps&.dig(:ownership)
    sync        = caps&.dig(:sync)
    collection  = caps&.dig(:collection)
    is_soa      = caps&.dig(:is_soa) || false
    is_indirect = caps&.dig(:is_indirect) || false
    shard_count = caps&.dig(:shard_count)

    # @indirect on non-array types (union fields) only sets @last_indirect_consumed
    # (signals union field parser). The Type itself is not heap-boxed.
    is_indirect = false if is_indirect && !inner.start_with?("[")

    base_sym = "#{tense_prefix}#{error_prefix}#{optional_prefix}#{base}#{inner}".to_sym

    loc = is_heap ? :heap : (is_indirect ? :heap : nil)
    t = Type.new(base_sym, ownership: ownership, sync: sync, location: loc, collection: collection, shard_count: shard_count)
    t.soa = true if is_soa
    t.elem_ownership = elem_ownership if elem_ownership
    t.elem_sync = elem_sync if elem_sync
    t
  end

  # Parses `CONCURRENT(workers: N)? SELECT|WHERE|EACH ...`
  def parse_concurrent_op
    token = consume(:KEYWORD, 'CONCURRENT')
    options = {}
    if match?(:CHAR, '(')
      consume(:CHAR, '(')
      loop do
        key_tok = consume(:VAR_ID)
        consume(:CHAR, ':')
        val = parse_expression
        options[key_tok.value] = val
        break unless match?(:CHAR, ',')
        consume(:CHAR, ',')
      end
      consume(:CHAR, ')')
    end
    inner_op = parse_concurrent_inner_op(token)
    AST::ConcurrentOp.new(token, inner_op, options)
  end

  def parse_concurrent_inner_op(parent_token)
    if match?(:KEYWORD, 'SELECT')
      consume(:KEYWORD, 'SELECT')
      expr = parse_expression(1)  # stop before s> for chaining
      AST::SelectOp.new(previous, expr)
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
      error!(current, "Expected SELECT, WHERE, EACH, SUM, COUNT, MIN, MAX, or AVERAGE after CONCURRENT, got #{current.value.inspect}")
    end
  end

  # Parses `EACH { stmts... }` — side-effect block over a collection.
  # `_` is the implicit item binding inside the body.
  def parse_each_op
    token = consume(:KEYWORD, 'EACH')
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')
    AST::EachOp.new(token, body)
  end

  def parse_tap_op
    token = consume(:KEYWORD, 'TAP')
    # TAP f -> single function call (short form)
    # TAP { body } -> block form
    if match?(:CHAR, '{')
      consume(:CHAR, '{')
      body = parse_block_body(['}'])
      consume(:CHAR, '}')
      AST::TapOp.new(token, body)
    else
      # Short form: TAP func -> becomes TAP { func(_); }
      expr = parse_expression(1)  # parse_pipe_expression
      AST::TapOp.new(token, [AST::FuncCall.new(token, expr.respond_to?(:name) ? expr.name : expr.to_s, [AST::Identifier.new(token, "_")])])
    end
  end

  # Parses an optional `:sharded(N)` or `:soa` suffix after @pool or @list.
  # Returns { shard_count:, soa: } hash with parsed values.
  # Raises a ParserError if the syntax is malformed or N < 2.
  def parse_collection_modifiers!(cap_tok)
    result = { shard_count: nil, soa: false }
    return result unless match?(:CHAR, ':')
    consume(:CHAR, ':')
    unless match?(:VAR_ID) && %w[sharded soa].include?(current.value)
      error!(current, "Expected 'sharded(N)' or 'soa' after '#{cap_tok.value}:' — unknown modifier '#{current.value}'")
    end
    mod_name = current.value
    consume(:VAR_ID)
    if mod_name == 'sharded'
      consume(:CHAR, '(')
      count_tok = consume_number
      n = count_tok.value.to_i
      if n < 2
        error!(count_tok, "@pool:sharded / @list:sharded requires N >= 2, got #{n}")
      end
      consume(:CHAR, ')')
      result[:shard_count] = n
    elsif mod_name == 'soa'
      result[:soa] = true
    end
    result
  end

  # Backwards-compatible wrapper (returns shard_count only).
  def parse_sharded_modifier_if_present!(cap_tok)
    parse_collection_modifiers!(cap_tok)[:shard_count]
  end

  # All recognized capability tokens.
  CAPABILITY_TOKENS = %w[@multiowned @shared @split @locked @writeLocked @local @indirect @link @raw @symbol @list @pool @set @soa @sharded].freeze

  # Unified capability parser. Parses an optional @cap or @cap:chain sequence.
  # Returns nil if no capability token is present, or a Hash:
  #   { ownership:, sync:, collection:, is_soa:, is_indirect:, shard_count: }
  # No semantic validation — just token consumption and duplicate detection.
  def parse_capabilities
    return nil unless match?(:VAR_ID) && CAPABILITY_TOKENS.include?(current.value)

    result = { ownership: nil, sync: nil, collection: nil, is_soa: false, is_indirect: false, shard_count: nil }
    apply_capability!(result, consume(:VAR_ID))

    # ':' chaining (e.g., @shared:locked, @soa:shared:locked, @list:soa)
    while match?(:CHAR, ':')
      consume(:CHAR, ':')
      unless current.type == :VAR_ID || current.type == :INT64
        error!(current, "Expected a capability modifier after ':'")
      end
      # After ':', accept both 'locked' and '@locked' forms.
      tok = consume(:VAR_ID)
      normalized_value = tok.value.start_with?('@') ? tok.value : "@#{tok.value}"
      apply_capability!(result, tok, normalized_value)
    end

    result
  end

  private

  # Apply a single capability token to the result hash. Detects duplicates.
  def apply_capability!(result, token, value = token.value)
    case value
    when "@multiowned"
      error!(token, "Duplicate ownership") if result[:ownership]
      result[:ownership] = :multiowned
    when "@shared"
      error!(token, "Duplicate ownership") if result[:ownership]
      result[:ownership] = :shared
    when "@split"
      error!(token, "Duplicate ownership") if result[:ownership]
      result[:ownership] = :split
    when "@link"
      error!(token, "Duplicate ownership") if result[:ownership]
      result[:ownership] = :link
    when "@locked"
      error!(token, "Duplicate sync") if result[:sync]
      result[:sync] = :locked
    when "@writeLocked"
      error!(token, "Duplicate sync") if result[:sync]
      result[:sync] = :write_locked
    when "@local"
      error!(token, "Duplicate sync") if result[:sync]
      result[:sync] = :local
    when "@raw"
      error!(token, "Duplicate sync") if result[:sync]
      result[:sync] = :raw
    when "@symbol"
      error!(token, "Duplicate sync") if result[:sync]
      result[:sync] = :symbol
    when "@indirect"
      error!(token, "Duplicate indirect") if result[:is_indirect]
      @last_indirect_consumed = true
      result[:is_indirect] = true
    when "@soa"
      error!(token, "Duplicate soa") if result[:is_soa]
      result[:is_soa] = true
    when "@list"
      error!(token, "Duplicate collection") if result[:collection]
      result[:collection] = :list
    when "@pool"
      error!(token, "Duplicate collection") if result[:collection]
      result[:collection] = :pool
    when "@set"
      error!(token, "Duplicate collection") if result[:collection]
      result[:collection] = :set
    when "@sharded"
      error!(token, "Duplicate shard count") if result[:shard_count]
      consume(:CHAR, '(')
      result[:shard_count] = consume_number.value.to_i
      consume(:CHAR, ')')
    else
      error!(token, "Unknown capability modifier: #{value}")
    end
  end

  public

  # parse_striped_modifier! removed — striped is now :sharded(N) @locked composition

  def parse_with_capability
    with_token = consume(:KEYWORD, 'WITH')

    # Optional deadlock-escape modifier: one of POSSIBLE_DEADLOCK /
    # POSSIBLE_LOCK_CYCLE, immediately after WITH. Acts as a per-block
    # opt-out from the static nested-lock checks; code still emits a
    # [Note] at each opted-out site so the risk remains visible.
    escape_tok = nil
    if match?(:KEYWORD, 'POSSIBLE_DEADLOCK') || match?(:KEYWORD, 'POSSIBLE_LOCK_CYCLE')
      escape_tok = consume(:KEYWORD)
    end

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

      # Optional alias binding: WITH EXCLUSIVE lockedVar AS [MUTABLE] alias { }
      alias_name = nil
      alias_mutable = false
      if match!(:KEYWORD, 'AS')
        if match!(:KEYWORD, 'MUTABLE')
          alias_mutable = true
        end
        alias_name = consume(:VAR_ID).value
      end

      capabilities << { capability: capability, var_node: var_node, alias: alias_name, alias_mutable: alias_mutable }

      # Check for comma (continue) or opening brace (done)
      break unless match!(:CHAR, ',')
    end

    # Parse block
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')

    node = AST::WithBlock.new(with_token, capabilities, body)
    node.lock_error_clause = parse_lock_error_clause
    if escape_tok
      node.deadlock_escape = {
        kind: escape_tok.value == 'POSSIBLE_DEADLOCK' ? :deadlock : :lock_cycle,
        token: escape_tok,
      }
    end
    node
  end

  # Parse an optional error-handling clause following a WITH block's `}`:
  #   ON <selectors> [RETRY(N) THEN] <action>
  #   RETRY(N) THEN <action>                  -- sugar for ON Transient
  # Returns a Hash { selectors:, kinds:, types:, action:, retries:, ... } or nil.
  # Selector validation (existence, retry-is-Transient) runs in the annotator.
  def parse_lock_error_clause
    if match?(:KEYWORD, 'ON')
      consume(:KEYWORD, 'ON')
      selectors = parse_error_selectors
      retries = match_optional_retry!
      action = parse_lock_action
      action.merge(selectors: selectors, retries: retries)
    elsif match?(:KEYWORD, 'RETRY')
      retries = match_optional_retry!
      action = parse_lock_action
      # Sugar: `RETRY(N) THEN <action>` == `ON Transient RETRY(N) THEN <action>`.
      action.merge(selectors: [{ form: :kind, name: :Transient, token: action[:token] }],
                   retries: retries)
    else
      nil
    end
  end

  # Consume `RETRY '(' N ')' THEN` if present. Returns the N or nil.
  def match_optional_retry!
    return nil unless match!(:KEYWORD, 'RETRY')
    consume(:CHAR, '(')
    tok = consume_number
    n = tok.value.to_i
    error!(tok, "RETRY(N) requires N > 0, got #{n}") if n <= 0
    consume(:CHAR, ')')
    consume(:KEYWORD, 'THEN')
    n
  end

  # Parse comma-separated error selectors. Each is either a bare TYPE_ID
  # (error kind: Transient, System, ...) or `:' TYPE_ID (error type symbol:
  # :LockTimeout, :Deadlock, ...).
  def parse_error_selectors
    selectors = [parse_error_selector]
    while match!(:CHAR, ',')
      selectors << parse_error_selector
    end
    selectors
  end

  def parse_error_selector
    if match!(:CHAR, ':')
      tok = consume(:TYPE_ID)
      { form: :type, name: tok.value.to_sym, token: tok }
    elsif match?(:TYPE_ID)
      tok = consume(:TYPE_ID)
      { form: :kind, name: tok.value.to_sym, token: tok }
    else
      error!(current, "Expected error selector: a kind like 'Transient' or a type like ':LockTimeout'")
    end
  end

  # Parse a single error-handler action: RAISE | PASS | EXIT "msg" | -> { stmts }.
  def parse_lock_action
    if match!(:KEYWORD, 'RAISE')
      { action: :raise, token: previous }
    elsif match!(:KEYWORD, 'PASS')
      { action: :pass, token: previous }
    elsif match!(:KEYWORD, 'EXIT')
      tok = previous
      msg = parse_expression
      { action: :exit, message: msg, token: tok }
    elsif match?(:ARROW, '->')
      tok = consume(:ARROW, '->')
      consume(:CHAR, '{')
      body = parse_block_body(['}'])
      consume(:CHAR, '}')
      { action: :block, body: body, token: tok }
    else
      error!(current, "Expected RAISE, PASS, EXIT \"msg\", or -> { ... } after error clause")
    end
  end

  # Parses an optional `:@cap` continuation after an expression-level capability sigil.
  # `tok` is the already-consumed first sigil token; `first_attrs` is its CAP_SIGIL_ATTRS entry.
  # Returns [ownership, sync] — either field may be nil.
  # Handles order-independent joins: @shared:locked and @locked:shared both work.
  # Parses a capability chain: @a:b:c (order-independent, max one per dimension).
  # Returns [ownership, sync, layout].
  def parse_cap_join(tok, first_attrs)
    dims = { ownership: nil, sync: nil, layout: nil }
    apply_cap_dim!(tok, first_attrs, dims)

    while match?(:CHAR, ':')
      consume(:CHAR, ':')
      unless current.type == :VAR_ID
        error!(current, "Expected a capability sigil after ':'")
      end
      normalized = current.value.start_with?('@') ? current.value : "@#{current.value}"
      attrs = CAP_SIGIL_ATTRS[normalized]
      unless attrs
        error!(current, "Unknown capability sigil '#{current.value}'. " \
                        "Expected @multiowned, @shared, @locked, @writeLocked, @local, or @indirect")
      end
      next_tok = consume(:VAR_ID)
      apply_cap_dim!(next_tok, attrs, dims)
    end

    # Reject T @cap1 @cap2 (must use : join, e.g. @shared:locked)
    if match?(:VAR_ID) && current.value.start_with?('@') && CAP_SIGIL_ATTRS.key?(current.value)
      error!(current, "Cannot use two separate @ capabilities. Join with ':' instead (e.g., @shared:locked not @shared @locked).")
    end

    [dims[:ownership], dims[:sync], dims[:layout]]
  end

  def apply_cap_dim!(tok, attrs, dims)
    dim = attrs[:dim]
    if dims[dim]
      error!(tok, "Duplicate #{dim} capability: already have @#{dims[dim]}, cannot add @#{attrs[:val]}")
    end
    dims[dim] = attrs[:val]
  end

  # Branch-prefix sigils for DO blocks.
  # Each maps to the attribute(s) it sets on the branch hash.
  # After `:` the next word is also looked up here (with `@` prepended if absent).
  DO_BRANCH_SIGILS = {
    '@micro'    => { stack_size: :micro    },
    '@standard' => { stack_size: :standard },
    '@large'    => { stack_size: :large    },
    '@xl'       => { stack_size: :xl       },
    '@service'  => { stack_size: :service  },
    '@pinned'   => { pinned: true          },
    '@parallel' => { parallel: true        },
    '@canSmash' => { can_smash: true       },
  }.freeze

  # Sigils valid at the start of a BG body (stack size + pinned).
  BG_SIGILS = {
    '@micro'    => { stack_size: :micro    },
    '@standard' => { stack_size: :standard },
    '@large'    => { stack_size: :large    },
    '@xl'       => { stack_size: :xl       },
    '@service'  => { stack_size: :service  },
    '@pinned'   => { pinned: true          },
    '@parallel' => { parallel: true        },
    '@arena'    => { pinned: true, arena: true },
    '@canSmash' => { can_smash: true       },
  }.freeze

  # Parses an optional `@size_sigil(:cap_sigil)* ->` prefix from a DO branch.
  # Returns { pinned: Bool, stack_size: Symbol|nil }.
  # Only enters the prefix parser when the first token is a known DO branch sigil.
  # After `:`, the next identifier is normalised (@ prepended if absent).
  def parse_branch_prefix
    pinned     = false
    parallel   = false
    can_smash  = false
    stack_size = nil

    return { pinned: pinned, parallel: parallel, stack_size: stack_size, can_smash: can_smash } unless
      current.type == :VAR_ID && DO_BRANCH_SIGILS.key?(current.value)

    loop do
      tok      = consume(:VAR_ID)
      cap_name = tok.value.start_with?('@') ? tok.value : "@#{tok.value}"
      attrs    = DO_BRANCH_SIGILS[cap_name]
      error!(tok, "Unknown branch prefix #{tok.value.inspect}. " \
                  "Expected @micro, @standard, @large, @xl, @pinned, @parallel, or @canSmash") unless attrs

      if attrs[:stack_size]
        error!(tok, "Duplicate stack size in branch prefix") if stack_size
        stack_size = attrs[:stack_size]
      end
      pinned    = true if attrs[:pinned]
      parallel  = true if attrs[:parallel]
      can_smash = true if attrs[:can_smash]

      break unless match?(:CHAR, ':')
      consume(:CHAR, ':')
    end

    consume(:ARROW, '->')
    { pinned: pinned, parallel: parallel, stack_size: stack_size, can_smash: can_smash }
  end

  def parse_do_block
    do_token = consume(:KEYWORD, 'DO')
    consume(:CHAR, '{')
    branches = []

    until match?(:CHAR, '}') || match?(:EOF)
      prefix = parse_branch_prefix

      # A branch is either a block-statement (WITH, IF, etc.) starting with a keyword,
      # or a bare expression. Keyword branches don't need a trailing semicolon.
      stmt = if match?(:KEYWORD)
        parse_statement
      else
        parse_expression
      end
      branches << { body: [stmt].compact, pinned: prefix[:pinned], parallel: prefix[:parallel], stack_size: prefix[:stack_size], can_smash: prefix[:can_smash] }
      break unless match!(:CHAR, ',')
    end

    consume(:CHAR, '}')
    AST::DoBlock.new(do_token, branches)
  end

  # Parses an optional `@size_sigil ->` prefix at the very start of a BG body.
  # Returns the stack_size symbol (:micro/:standard/:large/:xl) or nil.
  def parse_bg_prefix
    pinned     = false
    parallel   = false
    arena      = false
    can_smash  = false
    stack_size = nil

    return { pinned: pinned, parallel: parallel, stack_size: stack_size, arena: arena, can_smash: can_smash } unless
      current.type == :VAR_ID && BG_SIGILS.key?(current.value)

    loop do
      tok      = consume(:VAR_ID)
      cap_name = tok.value.start_with?('@') ? tok.value : "@#{tok.value}"
      attrs    = BG_SIGILS[cap_name]
      error!(tok, "Unknown BG prefix #{tok.value.inspect}") unless attrs

      if attrs[:stack_size]
        error!(tok, "Duplicate stack size in BG prefix") if stack_size
        stack_size = attrs[:stack_size]
      end
      pinned    = true if attrs[:pinned]
      parallel  = true if attrs[:parallel]
      arena     = true if attrs[:arena]
      can_smash = true if attrs[:can_smash]

      # More sigils chained with ':'?
      break unless match?(:CHAR, ':')
      consume(:CHAR, ':')
    end

    consume(:ARROW, '->')
    { pinned: pinned, parallel: parallel, stack_size: stack_size, arena: arena, can_smash: can_smash }
  end

  def parse_bg_block
    bg_token = consume(:KEYWORD, 'BG')
    if match?(:KEYWORD, 'STREAM')
      return parse_bg_stream_block(bg_token)
    end
    consume(:CHAR, '{')
    prefix = parse_bg_prefix
    body = parse_bg_then_body
    consume(:CHAR, '}')
    AST::BgBlock.new(bg_token, body, nil, prefix[:stack_size], prefix[:pinned], prefix[:parallel], prefix[:arena], prefix[:can_smash])
  end

  # Custom body parser for BG blocks that recognises THEN chains.
  def parse_bg_then_body
    stmts = []
    until match?(:CHAR, '}') || match?(:EOF)
      stmt = parse_bg_body_stmt
      stmts << stmt if stmt
    end
    stmts
  end

  # Parse one statement from a BG block body.
  # If the expression is followed by AS or THEN, builds a ThenChain node.
  def parse_bg_body_stmt
    # Keywordless bind/assign: x = ..., x.field = ..., x[0] = ...
    if current.type == :VAR_ID
      result = try_parse_bind_or_assign
      return result if result
    end

    # Keyword statements (IF, WHILE, RETURN, etc.) — cannot start THEN chains
    rule = @@stmt_rules[[current.type, current.value]]
    return instance_exec(&rule) if rule

    expr = parse_expression

    # THEN chain: expr [AS name] THEN expr [AS name] THEN ...
    if match?(:KEYWORD, 'AS') || match?(:KEYWORD, 'THEN')
      binding_name = nil
      if match?(:KEYWORD, 'AS')
        consume(:KEYWORD, 'AS')
        binding_name = consume(:VAR_ID).value
      end

      unless match?(:KEYWORD, 'THEN')
        error!(current, "Expected THEN after AS binding in BG block, got #{current.value.inspect}")
      end

      steps = [{ expr: expr, binding: binding_name }]
      while match?(:KEYWORD, 'THEN')
        consume(:KEYWORD, 'THEN')
        next_expr = parse_expression
        next_binding = nil
        if match?(:KEYWORD, 'AS')
          consume(:KEYWORD, 'AS')
          next_binding = consume(:VAR_ID).value
        end
        steps << { expr: next_expr, binding: next_binding }
      end
      match!(:CHAR, ';')
      return AST::ThenChain.new(steps.first[:expr].token, steps)
    end

    consume(:CHAR, ';')
    expr
  end

  def parse_bg_stream_block(bg_token)
    consume(:KEYWORD, 'STREAM')
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')
    AST::BgStreamBlock.new(bg_token, body, nil)
  end

  def parse_yield_expr
    tok = consume(:KEYWORD, 'YIELD')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::YieldExpr.new(tok, expr)
  end

  def parse_next_expr
    tok = consume(:KEYWORD, 'NEXT')
    expr = parse_expression
    AST::NextExpr.new(tok, expr)
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

  # Deep-clone an AST node for compound assignment desugaring.
  # The target appears on both sides (LHS = target, RHS = target op expr),
  # so each side needs its own node to avoid double-visit issues.
  def deep_clone_node(node)
    case node
    when AST::Identifier
      AST::Identifier.new(node.token, node.name)
    when AST::GetField
      AST::GetField.new(node.token, deep_clone_node(node.target), node.field)
    when AST::GetIndex
      AST::GetIndex.new(node.token, deep_clone_node(node.target), deep_clone_node(node.index))
    else
      node.dup
    end
  end

  # ── Test Framework Parsing ──────────────────────────────────────

  # TEST <name> DO ... END
  def parse_test_block
    tok = consume(:KEYWORD, 'TEST')
    name = consume(:TYPE_ID).value  # TestName is a TYPE_ID (capitalized)
    consume(:KEYWORD, 'DO')

    setup = []
    whens = []

    until match?(:KEYWORD, 'END')
      if match?(:KEYWORD, 'WHEN')
        whens << parse_when_block
      else
        setup << parse_statement
      end
    end
    consume(:KEYWORD, 'END')

    AST::TestBlock.new(tok, name, setup, whens)
  end

  # WHEN "description" DO ... END
  def parse_when_block
    tok = consume(:KEYWORD, 'WHEN')
    desc = consume(:STRING).value
    consume(:KEYWORD, 'DO')

    setup = []
    tests = []
    benchmarks = []

    until match?(:KEYWORD, 'END')
      if match?(:KEYWORD, 'TEST') && @tokens[@pos + 1]&.value == 'THAT'
        tests << parse_test_that
      elsif match?(:KEYWORD, 'BENCHMARK')
        benchmarks << parse_benchmark_stmt
      elsif match?(:KEYWORD, 'SMASH')
        benchmarks << parse_smash_stmt
      elsif match?(:KEYWORD, 'PROFILE')
        benchmarks << parse_profile_stmt
      elsif match?(:KEYWORD, 'STUB')
        setup << parse_stub
      else
        setup << parse_statement
      end
    end
    consume(:KEYWORD, 'END')

    AST::WhenBlock.new(tok, desc, setup, tests, benchmarks)
  end

  # TEST THAT "description" DO ... END
  def parse_test_that
    tok = consume(:KEYWORD, 'TEST')
    consume(:KEYWORD, 'THAT')
    desc = consume(:STRING).value
    consume(:KEYWORD, 'DO')

    body = []
    until match?(:KEYWORD, 'END')
      body << parse_statement
    end
    consume(:KEYWORD, 'END')

    AST::TestThat.new(tok, desc, body)
  end

  # ASSERT_RAISES Kind, expr;  OR  ASSERT_RAISES Kind, ErrorName, expr;
  def parse_assert_raises
    tok = consume(:KEYWORD, 'ASSERT_RAISES')
    kind = consume(:TYPE_ID).value  # e.g., Input, System, Transient

    consume(:CHAR, ',')

    # Peek: if next is TYPE_ID followed by comma, it's ASSERT_RAISES Kind, ErrorName, expr
    error_name = nil
    if current.type == :TYPE_ID && @tokens[@pos + 1]&.type == :CHAR && @tokens[@pos + 1]&.value == ','
      error_name = consume(:TYPE_ID).value
      consume(:CHAR, ',')
    end

    expr = parse_expression
    consume(:CHAR, ';')

    AST::AssertRaises.new(tok, kind, error_name, expr)
  end

  # BENCHMARK expr x<N>;
  def parse_benchmark_stmt
    tok = consume(:KEYWORD, 'BENCHMARK')
    expr = parse_expression

    # Parse optional iteration count: x1000 or x 1000
    iterations = 1000  # default
    if match?(:VAR_ID) && current.value =~ /^x(\d+)$/
      iterations = $1.to_i
      consume(:VAR_ID)
    end
    consume(:CHAR, ';')

    AST::BenchmarkStmt.new(tok, expr, iterations)
  end

  # SMASH expr;
  def parse_smash_stmt
    tok = consume(:KEYWORD, 'SMASH')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::SmashStmt.new(tok, expr)
  end

  # PROFILE expr;
  def parse_profile_stmt
    tok = consume(:KEYWORD, 'PROFILE')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::ProfileStmt.new(tok, expr)
  end

  # STUB fn RETURNS value;
  # STUB fn CAPTURES var;
  # STUB fn SEQUENCE [values];
  # STUB fn WITH %(params) -> expr;
  def parse_stub
    tok = consume(:KEYWORD, 'STUB')
    fn_name = consume(:VAR_ID).value

    kind_tok = current
    if match?(:KEYWORD, 'RETURNS')
      consume(:KEYWORD, 'RETURNS')
      value = parse_expression
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :returns, value)
    elsif match?(:KEYWORD, 'CAPTURES')
      consume(:KEYWORD, 'CAPTURES')
      var_name = consume(:VAR_ID).value
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :captures, var_name)
    elsif match?(:KEYWORD, 'SEQUENCE')
      consume(:KEYWORD, 'SEQUENCE')
      values = parse_list_literal
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :sequence, values)
    elsif match?(:KEYWORD, 'WITH')
      consume(:KEYWORD, 'WITH')
      lambda_node = parse_expression  # should parse a lambda %(params) -> expr
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :with, lambda_node)
    else
      error!(kind_tok, "Expected RETURNS, CAPTURES, SEQUENCE, or WITH after STUB #{fn_name}")
    end
  end
end
