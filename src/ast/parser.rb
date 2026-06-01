# typed: strict
require "sorbet-runtime"

require_relative "./ast"
require_relative "./lexer"
require_relative "./error_registry"
require_relative "./source_error"
require_relative "./fixable_error"
require_relative "../annotator/helpers/fixable_helpers"

# ==========================================
# PARSER
# ==========================================
class Parser
    extend T::Sig

  include ErrorHelper
  include FixableHelper

  @@stmt_rules = T.let({}, T::Hash[T.untyped, T.untyped])
  @@primary_rules = T.let({}, T::Hash[T.untyped, T.untyped])
  @@suffix_rules = T.let({}, T::Hash[T.untyped, T.untyped])
  @gradual_mode = T.let(false, T.nilable(T::Boolean))

  sig { params(type: Symbol, value: String, node_class: T.nilable(T::Class[T.anything]), pattern: T.nilable(T::Array[T.untyped]), inject: T::Array[TrueClass], block: T.untyped).returns(Proc) }
  def self.stmt(type, value, node_class = nil, pattern = nil, inject: [], &block)
    if pattern
      # If pattern provided, create a block that runs the engine
      @@stmt_rules[[type, value]] = lambda do
        T.bind(self, Parser) rescue nil
        start_token = current
        args = process_pattern(pattern)
        T.must(args).concat(inject)
        T.unsafe(node_class).new(start_token, *args)
      end
    else
      @@stmt_rules[[type, value]] = block
    end
  end

  sig { params(type: Symbol, value: T.nilable(String), node_class: T.nilable(T::Class[T.anything]), pattern: T.nilable(T::Array[T.untyped]), block: T.untyped).returns(Proc) }
  def self.primary(type, value=nil, node_class = nil, pattern = nil,  &block)
    if pattern
      # If pattern provided, create a block that runs the engine
      @@primary_rules[[type, value]] = lambda do
        T.bind(self, Parser) rescue nil
        start_token = current
        args = process_pattern(pattern)
        T.unsafe(node_class).new(start_token, *args)
      end
    else
      @@primary_rules[[type, value]] = block
    end
  end

  sig { params(type: Symbol, value: String, block: T.untyped).returns(Proc) }
  def self.suffix(type, value, &block)
    @@suffix_rules[[type, value]] = block
  end

  sig { params(tokens: T::Array[Lexer::Token], source_code: String, gradual: T.nilable(T::Boolean)).void }
  def initialize(tokens, source_code = "", gradual: nil)
    @tokens = tokens
    @pos = T.let(0, Integer)
    @source_code = source_code
    @last_requires_clauses = T.let({}, T::Hash[T.untyped, T.untyped])
    @suppress_struct_lit = T.let(false, T::Boolean)
    # `gradual` controls whether omitted type annotations on
    # parameters / return types parse as implicit Auto (per
    # docs/agents/gradual-typing.md §3.3). Defaults to the global
    # Parser.gradual_mode flag set by the CLI; can be overridden
    # per-instance by passing the kwarg explicitly. Without gradual
    # mode, omitted annotations behave exactly as before this feature
    # landed.
    @gradual = T.let(gradual.nil? ? self.class.gradual_mode : gradual, T::Boolean)
  end

  class << self
    extend T::Sig

    # Process-global gradual-mode flag. Set by `clear --gradual` at
    # build start; read by Parser.new instances that don't pass an
    # explicit gradual: kwarg. This matches how the existing CLI
    # threads compile-time choices (--optimized, --tsan, etc.) — one
    # build, one mode.
    sig { returns(T::Boolean) }
    def gradual_mode
      T.must(@gradual_mode)
    end

    sig { params(value: T::Boolean).returns(T::Boolean) }
    def gradual_mode=(value)
      @gradual_mode = T.let(value, T.nilable(T::Boolean))
      value
    end
  end

  sig { returns(T.nilable(AST::Program)) }
  def parse
    stmts = []
    stmts << parse_statement() while current.type != :EOF
    AST::Program.new(current, stmts)
  end

  private

  sig { returns(Lexer::Token) }
  def peek
    @tokens[@pos + 1] || Lexer::Token.new(:EOF, "", current.line, current.column)
  end

  sig { params(n: Integer).returns(T.untyped) }
  def peek_at(n)
    @tokens[@pos + n]
  end

  # COMMANDS
  stmt(:KEYWORD, 'REQUIRE') { T.bind(self, Parser); parse_require }
  stmt(:KEYWORD, 'EXTERN')  { T.bind(self, Parser); parse_extern_decl }
  stmt(:KEYWORD, 'MUTABLE') { T.bind(self, Parser); parse_mutable_var_decl }
  stmt(:KEYWORD, 'FN')      { T.bind(self, Parser); parse_function_def }
  stmt(:KEYWORD, 'METHOD')  { T.bind(self, Parser); parse_function_def(:package, is_method: true) }
  stmt(:KEYWORD, 'PUB')     { T.bind(self, Parser); parse_visibility_decl(:pub) }
  stmt(:KEYWORD, 'PRIVATE') { T.bind(self, Parser); parse_visibility_decl(:private) }
  stmt(:KEYWORD, 'IF') { T.bind(self, Parser); parse_if_statement }
  stmt(:KEYWORD, 'STRUCT') { T.bind(self, Parser); parse_struct_def }
  stmt(:KEYWORD, 'ENUM')   { T.bind(self, Parser); parse_enum_def }
  stmt(:KEYWORD, 'UNION')  { T.bind(self, Parser); parse_union_def }
  stmt(:KEYWORD, 'WHILE') { T.bind(self, Parser); parse_while_loop }
  stmt(:KEYWORD, 'FOR') { T.bind(self, Parser); parse_for_range }
  stmt(:KEYWORD, 'TIGHT') { T.bind(self, Parser); parse_tight_stmt }
  stmt(:KEYWORD, 'RETURN') { T.bind(self, Parser); parse_return }
  stmt(:KEYWORD, 'ASSERT', AST::Assert, ['ASSERT', :expression, {',' => :STRING}, ';'])
  stmt(:KEYWORD, 'ASSERT_RAISES') { T.bind(self, Parser); parse_assert_raises }
  stmt(:KEYWORD, 'TEST') { T.bind(self, Parser); parse_test_block }
  stmt(:KEYWORD, 'STUB') { T.bind(self, Parser); parse_stub }
  stmt(:KEYWORD, 'BENCHMARK') { T.bind(self, Parser); parse_benchmark_stmt }
  stmt(:KEYWORD, 'SMASH') { T.bind(self, Parser); parse_smash_stmt }
  stmt(:KEYWORD, 'PROFILE') { T.bind(self, Parser); parse_profile_stmt }
  stmt(:KEYWORD, 'RAISE') { T.bind(self, Parser); parse_raise_stmt }
  stmt(:KEYWORD, 'EXIT') { T.bind(self, Parser); parse_exit }
  stmt(:KEYWORD, 'DIE') { T.bind(self, Parser); parse_die }
  stmt(:KEYWORD, 'BREAK', AST::BreakNode, ['BREAK', ';'])
  stmt(:KEYWORD, 'CONTINUE', AST::ContinueNode, ['CONTINUE', ';'])
  stmt(:KEYWORD, 'WITH') { T.bind(self, Parser); parse_with_capability }
  stmt(:KEYWORD, 'SYNC') { T.bind(self, Parser); parse_sync_policy_block }
  stmt(:KEYWORD, 'DO')   { T.bind(self, Parser); parse_do_block }
  stmt(:KEYWORD, 'BG')   { T.bind(self, Parser); parse_bg_block }
  stmt(:KEYWORD, 'YIELD') { T.bind(self, Parser); parse_yield_expr }
  stmt(:KEYWORD, 'MATCH') { T.bind(self, Parser); parse_match_statement }
  stmt(:KEYWORD, 'PARTIAL') do
    T.bind(self, Parser) rescue nil
    consume(:KEYWORD, 'PARTIAL')
    parse_match_statement(partial: true)
  end
  stmt(:KEYWORD, 'PASS') do
    T.bind(self, Parser) rescue nil
    tok = consume(:KEYWORD, 'PASS')
    match!(:CHAR, ';')  # optional semicolon — PASS may appear bare before a ','
    AST::PassStmt.new(tok)
  end


  # IF and MATCH as expressions: x = IF cond THEN a ELSE b END
  primary(:KEYWORD, 'IF')    { T.bind(self, Parser); parse_if_expr }
  primary(:KEYWORD, 'MATCH') { T.bind(self, Parser); parse_match_expr }
  primary(:KEYWORD, 'PARTIAL') do
    T.bind(self, Parser) rescue nil
    consume(:KEYWORD, 'PARTIAL')
    parse_match_expr(partial: true)
  end

  # Primaries
  primary(:NUMBER) { T.bind(self, Parser); parse_literal(:NUMBER, :stack) }
  primary(:INT64) { T.bind(self, Parser); parse_literal(:INT64, :stack) }
  primary(:STRING) { T.bind(self, Parser); parse_literal(:STRING, :stack) }
  # Symbol literal: :identifier — only valid in expression position.
  # The ':' char is already consumed by the time the primary body runs.
  primary(:CHAR, ':') do
    T.bind(self, Parser) rescue nil
    colon_tok = consume(:CHAR, ':')
    error!(colon_tok, :EXPECTED_SYMBOL_AFTER_COLON) unless match?(:VAR_ID)
    ident_tok = consume(:VAR_ID)
    AST::Literal.new(colon_tok, :SYMBOL, T.must(ident_tok).value, :stack)
  end
  primary(:BYTE) { T.bind(self, Parser); parse_literal(:BYTE, :stack) }
  primary(:PREFIXED_INT) { T.bind(self, Parser); parse_literal(:PREFIXED_INT, :stack) }
  primary(:INT8)    { T.bind(self, Parser); parse_literal(:INT8,    :stack) }
  primary(:INT16)   { T.bind(self, Parser); parse_literal(:INT16,   :stack) }
  primary(:INT32)   { T.bind(self, Parser); parse_literal(:INT32,   :stack) }
  primary(:UINT16)  { T.bind(self, Parser); parse_literal(:UINT16,  :stack) }
  primary(:UINT32)  { T.bind(self, Parser); parse_literal(:UINT32,  :stack) }
  primary(:UINT64)  { T.bind(self, Parser); parse_literal(:UINT64,  :stack) }
  primary(:FLOAT32) { T.bind(self, Parser); parse_literal(:FLOAT32, :stack) }
  primary(:VAR_ID) { T.bind(self, Parser); parse_var_id }

  primary(:KEYWORD, 'TRUE') { T.bind(self, Parser); t = consume(:KEYWORD); AST::Literal.new(t, :BOOLEAN, true) }
  primary(:KEYWORD, 'FALSE') { T.bind(self, Parser); t = consume(:KEYWORD); AST::Literal.new(t, :BOOLEAN, false) }
  primary(:KEYWORD, 'NIL') { T.bind(self, Parser); t = consume(:KEYWORD); AST::Literal.new(t, :NIL, nil) }
  primary(:KEYWORD, 'DEFAULT') { T.bind(self, Parser); t = consume(:KEYWORD, 'DEFAULT'); AST::DefaultLit.new(t) }
  primary(:KEYWORD, 'CAST', AST::Cast, ['CAST', '(', :expression, 'AS', :type_annotation, ')'])
  primary(:KEYWORD, 'COPY', AST::Copy, ['COPY', :expression])
  primary(:KEYWORD, 'MOVE', AST::MoveNode, ['MOVE', :expression])
  primary(:KEYWORD, 'GIVE', AST::MoveNode, ['GIVE', :expression])
  primary(:KEYWORD, 'COPY', AST::CopyNode, ['COPY', :expression])
  primary(:KEYWORD, 'CLONE', AST::CloneNode, ['CLONE', :expression])
  primary(:KEYWORD, 'SHARE', AST::ShareNode, ['SHARE', :expression])
  primary(:KEYWORD, 'LINK', AST::LinkNode, ['LINK', :expression])
  primary(:KEYWORD, 'RESOLVE', AST::ResolveNode, ['RESOLVE', :expression])
  primary(:KEYWORD, 'FREEZE', AST::FreezeNode, ['FREEZE', :expression])
  primary(:KEYWORD, 'BG')   { T.bind(self, Parser); parse_bg_block }
  primary(:KEYWORD, 'NEXT') { T.bind(self, Parser); parse_next_expr }
  primary(:PERCENT, '%') { T.bind(self, Parser); parse_sigil_construct }
  primary(:KEYWORD, 'REQUIRE', AST::Require, ['REQUIRE', :STRING])

  # Pipeline operators use :pipe_expression (min precedence 2) so their
  # body expression stops before `|>` (precedence 1), enabling chaining:
  #   list |> SELECT _ * 2.0 |> WHERE _ > 5.0
  primary(:KEYWORD, 'SELECT', AST::SelectOp, ['SELECT', :pipe_expression])
  primary(:KEYWORD, 'WHERE', AST::WhereOp, ['WHERE', :pipe_expression])
  primary(:KEYWORD, 'INDEX', AST::IndexOp, ['INDEX', :pipe_expression])
  primary(:KEYWORD, 'REDUCE') { T.bind(self, Parser); parse_reduce_op }
  primary(:KEYWORD, 'ORDER_BY', AST::OrderByOp, ['ORDER_BY', :pipe_expression])
  primary(:KEYWORD, 'LIMIT', AST::LimitOp, ['LIMIT', :pipe_expression])
  primary(:KEYWORD, 'SKIP', AST::SkipOp, ['SKIP', :pipe_expression])
  primary(:KEYWORD, 'UNNEST', AST::UnnestOp, ['UNNEST', :pipe_expression])
  primary(:KEYWORD, 'DISTINCT', AST::DistinctOp, ['DISTINCT', :pipe_expression])
  primary(:KEYWORD, 'EACH')  { T.bind(self, Parser); parse_each_op }
  primary(:KEYWORD, 'TAP')   { T.bind(self, Parser); parse_tap_op }
  primary(:KEYWORD, 'FIND',    AST::FindOp,    ['FIND',    :pipe_expression])
  primary(:KEYWORD, 'ANY',     AST::AnyOp,     ['ANY',     :pipe_expression])
  primary(:KEYWORD, 'ALL',     AST::AllOp,     ['ALL',     :pipe_expression])
  primary(:KEYWORD, 'COUNT',   AST::CountOp,   ['COUNT',   :pipe_expression])
  primary(:KEYWORD, 'SUM',     AST::SumOp,     ['SUM',     :pipe_expression])
  primary(:KEYWORD, 'AVERAGE', AST::AverageOp, ['AVERAGE', :pipe_expression])
  primary(:KEYWORD, 'MIN',     AST::MinOp,     ['MIN',     :pipe_expression])
  primary(:KEYWORD, 'MAX',     AST::MaxOp,     ['MAX',     :pipe_expression])
  primary(:KEYWORD, 'TAKE_WHILE', AST::TakeWhileOp, ['TAKE_WHILE', :pipe_expression])
  primary(:KEYWORD, 'RECOVER') { T.bind(self, Parser); parse_recover_op }
  # COLLECT: pipe-terminal that joins a `~T@observable` (blocking)
  # and returns the underlying T. Takes no expression argument.
  primary(:KEYWORD, 'COLLECT', AST::CollectOp, ['COLLECT'])
  primary(:KEYWORD, 'WINDOW') { T.bind(self, Parser); parse_window_op }
  primary(:KEYWORD, 'JOIN') { T.bind(self, Parser); parse_join_op }
  primary(:KEYWORD, 'SHARD') { T.bind(self, Parser); parse_shard_op }
  primary(:KEYWORD, 'CONCURRENT') { T.bind(self, Parser); parse_concurrent_op }

  # Expression Grouping
  primary(:CHAR, '(') do
    T.bind(self, Parser) rescue nil
    consume(:CHAR, '(')
    expr = parse_expression
    # (expr AS name): optional binding group used in IF (expr AS name) && ...
    # parse_expression stops at AS (guard blocks non-@-prefixed tokens), so check explicitly.
    if match?(:KEYWORD, 'AS')
      consume(:KEYWORD, 'AS')
      name_tok = consume(:VAR_ID)
      consume(:CHAR, ')')
      bind = AST::BinaryOp.new(name_tok, expr, :BIND_VAR,
               AST::Identifier.new(name_tok, T.must(name_tok).value))
      bind.paren_bind = true
      next parse_suffixes(bind)
    end
    consume(:CHAR, ')')
    parse_suffixes(expr)
  end

  # Array Indexing: arr[index]
  suffix(:CHAR, '[') do |lhs|
    T.bind(self, Parser) rescue nil
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
    T.bind(self, Parser) rescue nil
    colon_token = consume(:DOUBLE_COLON, '::')
    method_token = consume(:VAR_ID)
    _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    AST::StaticCall.new(colon_token, lhs, T.must(method_token).value, args)
  end

  # Dot Access: obj.field OR obj.method() OR EnumType.Variant
  suffix(:CHAR, '.') do |lhs|
    T.bind(self, Parser) rescue nil
    dot_token = consume(:CHAR, '.')

    if match?(:CHAR, '*')
      star_token = consume(:CHAR, '*')
      AST::GetField.new(star_token, lhs, '*')
    else
      name_token = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
      name = T.must(name_token).value

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
    T.bind(self, Parser) rescue nil
    start_token, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
    AST::FuncCall.new(start_token, lhs, args)
  end

  # Optional Unwrap: maybe_value?
  suffix(:CHAR, '?') do |lhs|
    T.bind(self, Parser) rescue nil
    q_token = consume(:CHAR, '?')
    AST::OptionalUnwrap.new(q_token, lhs)
  end

  # Capability Wraps: expr @multiowned -> Rc(T), expr @shared -> Arc(T), expr @locked -> *Locked(T)
  # Supports `:` join: expr @shared:locked, expr @locked:multiowned (order-independent).
  # Three orthogonal dimensions:
  #   ownership: :multiowned | :shared         (who keeps it alive)
  #   sync:      :locked | :write_locked | :local | :versioned | :atomic  (how it's synchronized)
  #   layout:    :indirect                      (where it lives — heap pointer)
  # `:versioned` is MVCC (Versioned(T) atomic-pointer COW + EBR). `:atomic` is
  # a single-cell lock-free primitive (Atomic(T) on Int64/Float64/Bool). Both
  # compose with `:shared` (Arc<Versioned(T)> / [M1] Arc<Atomic(T)>); neither
  # composes with the lock sigils (`:locked` / `:write_locked` /
  # `:always_mutable`) -- mixing locks with a lock-free path is a type error.
  # Enforced by parse_cap_join's one-per-dimension rule plus annotator-side
  # combo validation.
  CAP_SIGIL_ATTRS = T.let({
    '@multiowned'     => { dim: :ownership, val: :multiowned  },
    '@shared'         => { dim: :ownership, val: :shared      },
    '@locked'         => { dim: :sync,      val: :locked      },
    '@writeLocked'    => { dim: :sync,      val: :write_locked },
    '@local'          => { dim: :sync,      val: :local       },
    '@versioned'      => { dim: :sync,      val: :versioned    },
    '@atomic'         => { dim: :sync,      val: :atomic      },
    '@indirect'       => { dim: :layout,    val: :indirect    },
    '@alwaysMutable'  => { dim: :sync,      val: :always_mutable },
  }.freeze, T::Hash[T.untyped, T.untyped])

  suffix(:VAR_ID, '@multiowned') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, lock_rank = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    cw = AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
    cw.lock_rank = lock_rank
    cw
  end

  suffix(:VAR_ID, '@shared') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, lock_rank = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    cw = AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
    cw.lock_rank = lock_rank
    cw
  end

  suffix(:VAR_ID, '@locked') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, lock_rank = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    cw = AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
    cw.lock_rank = lock_rank
    cw
  end

  suffix(:VAR_ID, '@writeLocked') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, lock_rank = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    cw = AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
    cw.lock_rank = lock_rank
    cw
  end

  suffix(:VAR_ID, '@local') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, _ = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@alwaysMutable') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, _ = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@versioned') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, _ = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@atomic') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, _ = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  suffix(:VAR_ID, '@indirect') do |lhs|
    T.bind(self, Parser) rescue nil
    token = consume(:VAR_ID)
    ownership, sync, layout, _ = parse_cap_join(T.must(token), CAP_SIGIL_ATTRS[T.must(token).value])
    AST::CapabilityWrap.new(token, lhs, ownership, sync, layout)
  end

  # Inline union variant constructor: TypeName.VariantName{ field: val, ... }
  # Only fires when lhs is a GetField whose target is a TYPE_ID (uppercase) identifier.
  # Returns SUFFIX_DECLINE (without consuming '{') for any other lhs, so callers
  # like parse_with_capability that legitimately follow an expression with '{' are unaffected.
  suffix(:CHAR, '{') do |lhs|
    T.bind(self, Parser) rescue nil
    if !T.unsafe(self).instance_variable_get(:@suppress_struct_lit) && lhs.is_a?(AST::GetField) && lhs.target.is_a?(AST::Identifier) &&
        lhs.target.name[0] =~ /[A-Z]/
      tok = current
      _, field_pairs = parse_comma_seq(:CHAR, '{', '}') do
        k = (T.must(current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID))).value
        consume(:CHAR, ':')
        v = parse_expression
        [k, v]
      end
      AST::UnionVariantLit.new(tok, lhs.target.name, lhs.field, field_pairs.to_h, :stack)
    else
      SUFFIX_DECLINE
    end
  end

  sig { params(type: Symbol, storage: Symbol).returns(T.untyped) }
  def parse_literal(type, storage)
    token = consume(type)
    node = AST::Literal.new(token, type, T.must(token).value, storage)
    parse_suffixes(node)
  end

  ## START PATTERN DSL
  sig { params(pattern: T::Array[T.untyped]).returns(T.nilable(T::Array[T.untyped])) }
  def process_pattern(pattern)
    captures = []

    pattern.each do |item|
      case item
      when String
        consume_literal(item)

      when Hash
        trigger, action = item.first

        if match_literal!(trigger)
          captures << run_action(action)
        else
          captures << :Any
        end

      when Symbol
        captures << run_action(item)
      end
    end

    captures
  end

  sig { params(item: Symbol).returns(T.untyped) }
  def run_action(item)
    # Convention: :UPPER_CASE is a Token Type to eat
    return T.must(consume(item)).value if item == item.upcase
    # :pipe_expression → parse_expression with min precedence = |> (1)
    # Excludes |> (prec 1, since 1 > 1 is false) but includes OR (prec 2).
    return parse_expression(1) if item == :pipe_expression
    # :down_case => parse function to run
    return send("parse_#{item}")
  end

  # Helpers for the literals (Keywords or Chars)
  sig { params(val: String).returns(T.nilable(Lexer::Token)) }
  def consume_literal(val)
    if val == '_'
      consume(:UNDERSCORE)
    elsif val.match?(/[a-zA-Z]/)
      consume(:KEYWORD, val)
    else
      consume(:CHAR, val)
    end
  end

  sig { params(val: String).returns(T.untyped) }
  def match_literal!(val)
    type = val.match?(/[a-zA-Z]/) ? :KEYWORD : :CHAR
    match!(type, val)
  end
  ## END PATTERN DSL


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

  sig { params(type: Symbol, value: T.nilable(String)).returns(T.nilable(Lexer::Token)) }
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
  SYNTAX_TOKENS_AT_STATEMENT_END = %w[; THEN DO ->].freeze

  sig { params(token: Lexer::Token, expected_type: Symbol, expected_value: T.nilable(String)).returns(T.untyped) }
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
  sig { params(prev_tok: Lexer::Token, next_tok: Lexer::Token, expected_value: String).returns(T.untyped) }
  def emit_syntax_insert_end_of_line!(prev_tok, next_tok, expected_value)
    line_text  = @source_code.lines[prev_tok.line - 1] || ''
    insert_col = line_text.rstrip.length + 1
    leader     = (expected_value == ';') ? '' : ' '

    fix = Fix.new(
      description: "Insert `#{expected_value}` at end of line #{prev_tok.line}.",
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: prev_tok.line, col: insert_col, length: 0),
        replacement: "#{leader}#{expected_value}"
      )]
    )

    message = "Expected `#{expected_value}` at end of line #{prev_tok.line}; got '#{next_tok.value}' on line #{next_tok.line}."
    fixable!(next_tok, message: message, category: :type, level: :error,
             fixes: [fix], raise_in_collector: true)
  end

  # Insert `<expected>` just before the unexpected token (same-line
  # missing-keyword shape, e.g., `IF x RETURN 1` needs `THEN` before
  # `RETURN`).
  sig { params(token: Lexer::Token, expected_value: String).returns(T.untyped) }
  def emit_syntax_insert_before_token!(token, expected_value)
    fix = Fix.new(
      description: "Insert `#{expected_value}` before '#{token.value}' at line #{token.line}.",
      confidence: :auto,
      edits: [Edit.new(
        span: Span.new(file: nil, line: token.line, col: token.column, length: 0),
        replacement: "#{expected_value} "
      )]
    )
    fixable!(token,
      message: "Expected `#{expected_value}`, got '#{token.value}' (line #{token.line}).",
      category: :type, level: :error,
      fixes: [fix], raise_in_collector: true)
  end

  sig { params(type: Symbol, val: T.nilable(String)).returns(T::Boolean) }
  def match?(type, val=nil)
    current.type == type && (val.nil? || current.value == val)
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
  sig { params(type: Symbol, value: T.nilable(String)).returns(T.untyped) }
  def match!(type, value=nil)
    if match?(type, value)
      consume(type) # We already know it matches, so this is safe
    else
      false
    end
  end

  sig { returns(T.untyped) }
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
  sig { returns(T.untyped) }
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
      op_char = T.must(op_token).value[0]  # '+=' → '+', '-=' → '-', etc.
      op_sym = AST::OP_TO_OP_CODE[op_char] || op_char.to_sym
      rhs = parse_expression
      consume(:CHAR, ';')

      # Desugar: target op= rhs  →  target = target op rhs
      desugared_value = AST::BinaryOp.new(op_token, deep_clone_node(target), op_sym, rhs)

      if target.is_a?(AST::Identifier)
        bind = AST::BindExpr.new(target_token, target.name, nil, desugared_value)
        # Preserve the original compound operator so atomic targets can lower
        # to fetch_<op> instead of load/modify/store.
        bind.compound_op = op_sym
        return bind
      else
        asgn = AST::Assignment.new(target_token, target, desugared_value)
        asgn.compound_op = op_sym
        return asgn
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

  sig { returns(T.untyped) }
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

  sig { params(as_param: T::Boolean).returns(T::Array[T.untyped]) }
  def parse_argument_list(as_param: true)
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

      name_tok = is_comptime ? nil : consume(:VAR_ID)
      p_name = name_tok&.value
      p_type = :Any
      default_val = nil

      if is_comptime
        consume(:CHAR, ':')
        p_type = T.must(consume(:TYPE_ID)).value.to_sym  # The type param name (T)
        p_name = "comptime"
      else
        # Syntax: name=default: Type  (default before type annotation)
        if match!(:CHAR, '=')
          default_val = parse_expression()
        end
        if match!(:CHAR, ':')
          p_type = parse_type_annotation
        elsif @gradual
          # Gradual mode: omitted annotation becomes implicit Auto.
          # The inference pass resolves these from call-site arg types.
          p_type = Type.new(:Auto, auto: true)
        end
      end

      # Shared by FN-param and USE-capture parsing. Params build an
      # AST::Param directly (single representation, no Hash seam);
      # USE-captures stay Hashes (distinct downstream shape).
      if as_param
        AST::Param.new(name: p_name, type: p_type, default: default_val,
                       mutable: is_mutable, takes: takes,
                       comptime: is_comptime, name_token: name_tok)
      else
        AST::Capture.new(name: p_name, type: p_type, default: default_val,
                         mutable: is_mutable, takes: takes,
                         comptime: is_comptime, name_token: name_tok)
      end
    end
     .last # always ignore the first token
  end

  # `MUTABLE name: T = expr;` (with initializer)
  # `MUTABLE name: T[N];`     (bare, fixed-size primitive array, zero-default)
  #
  # The bare form requires an explicit fixed-size array type whose element
  # type has a known zero literal (Int64/Float64/String/Bool family). It
  # synthesizes a ListLit of N zeroes so the rest of the pipeline lowers
  # the declaration via the existing fixed-array path.
  sig { returns(AST::VarDecl) }
  def parse_mutable_var_decl
    start_token = consume(:KEYWORD, 'MUTABLE')
    name = T.must(consume(:VAR_ID)).value
    type_annotation = nil
    if match!(:CHAR, ':')
      type_annotation = parse_type_annotation
    end

    if match!(:CHAR, '=')
      value = parse_expression
      consume(:CHAR, ';')
      return AST::VarDecl.new(start_token, name, type_annotation, value, true)
    end

    consume(:CHAR, ';')
    unless type_annotation
      error!(start_token, :MUTABLE_BARE_NEEDS_TYPE)
    end
    value = synthesize_default_for_type(T.must(start_token), type_annotation)
    AST::VarDecl.new(start_token, name, type_annotation, value, true)
  end

  # Build a default-initialized AST value for a `T[N]` annotation. Used by
  # `parse_mutable_var_decl` when no `= expr` was given. Restricted to
  # fixed-size raw arrays of element types with an obvious zero (primitives
  # and String); other types must be initialized explicitly.
  sig { params(tok: Lexer::Token, type: T.untyped).returns(AST::ListLit) }
  def synthesize_default_for_type(tok, type)
    unless type.is_a?(Type) && type.fixed?
      error!(tok, :MUTABLE_BARE_NEEDS_FIXED, type: type.respond_to?(:resolved) ? type.resolved : type)
    end
    elem = type.element_type
    elem_resolved = elem.respond_to?(:resolved) ? elem.resolved : elem
    zero_proc = case elem_resolved
                when :Int64, :Int32, :Int16, :Int8 then ->{ AST::Literal.new(tok, :INT64, 0, :stack) }
                when :Float64, :Float32 then ->{ AST::Literal.new(tok, :NUMBER, 0.0, :stack) }
                when :String then ->{ AST::Literal.new(tok, :STRING, "", :stack) }
                when :Bool, :Boolean then ->{ AST::Literal.new(tok, :BOOLEAN, false, :stack) }
                else
                  error!(tok, :MUTABLE_BARE_BAD_ELEMENT, type: elem_resolved.inspect)
                end
    items = Array.new(type.capacity.to_i) { zero_proc.call }
    AST::ListLit.new(tok, items, :stack)
  end

  sig { returns(AST::RequireNode) }
  def parse_require
    tok = consume(:KEYWORD, 'REQUIRE')
    raw = T.must(consume(:STRING)).value

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
      namespace = T.must(consume(:VAR_ID)).value
    end
    match!(:CHAR, ';')
    AST::RequireNode.new(tok, path, namespace, kind)
  end

  sig { params(visibility: Symbol).returns(T.untyped) }
  def parse_visibility_decl(visibility)
    consume(:KEYWORD)  # consume PUB or PRIVATE
    if match?(:KEYWORD, 'FN')
      parse_function_def(visibility)
    elsif match?(:KEYWORD, 'METHOD')
      parse_function_def(visibility, is_method: true)
    elsif match?(:KEYWORD, 'STRUCT')
      parse_struct_def(visibility)
    elsif match?(:KEYWORD, 'ENUM')
      parse_enum_def(visibility)
    elsif match?(:KEYWORD, 'UNION')
      parse_union_def(visibility)
    else
      error!(current, :VISIBILITY_BAD_KIND, got: current.value)
    end
  end

  # EXTERN FN name(params) RETURNS type FROM "module_name";
  # EXTERN STRUCT Name { fields } FROM "module_name";
  sig { returns(T.untyped) }
  def parse_extern_decl
    tok = consume(:KEYWORD, 'EXTERN')
    if match?(:KEYWORD, 'FN')
      parse_extern_fn(T.must(tok))
    elsif match?(:KEYWORD, 'STRUCT')
      parse_extern_struct(T.must(tok))
    else
      error!(current, :EXTERN_BAD_KIND, got: current.value)
    end
  end

  sig { params(extern_tok: Lexer::Token).returns(T.nilable(AST::ExternFnDecl)) }
  def parse_extern_fn(extern_tok)
    consume(:KEYWORD, 'FN')

    # Parse name: either "fnName", "fnName<T>", or "TypeName<T>.methodName"
    owner_type = nil
    owner_type_params = []
    fn_type_params = []

    if match?(:TYPE_ID)
      # Could be TypeName<T>.method or just a TYPE_ID-named function
      type_name = T.must(consume(:TYPE_ID)).value
      if match!(:CHAR, '<')
        loop do
          owner_type_params << T.must(consume(:TYPE_ID)).value.to_sym
          break unless match!(:CHAR, ',')
        end
        consume(:CHAR, '>')
      end
      if match!(:CHAR, '.')
        # It's a method: TypeName<T>.methodName
        owner_type = type_name
        name = T.must(consume(:VAR_ID)).value
      else
        # TYPE_ID without dot — treat as function name (unusual but valid)
        name = type_name
        fn_type_params = owner_type_params
        owner_type_params = []
      end
    else
      name = T.must(consume(:VAR_ID)).value
      # Optional generic type params on the function: fnName<T>
      if match!(:CHAR, '<')
        loop do
          fn_type_params << T.must(consume(:TYPE_ID)).value.to_sym
          break unless match!(:CHAR, ',')
        end
        consume(:CHAR, '>')
      end
    end

    params = parse_argument_list
    explicit_return = match!(:KEYWORD, 'RETURNS')
    return_type = explicit_return ? parse_type_annotation : nil

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
        eff_tok = consume(:VAR_ID)
        eff_name = T.must(eff_tok).value.to_sym
        unless [:alloc, :safe].include?(eff_name)
          emit_typo_suggestion!(
            eff_tok, T.must(eff_tok).value, %w[alloc safe],
            "Unknown effect ':#{eff_name}'",
            "closest effect",
            category: :type, cascade: true
          )
        end
        if eff_name == :safe
          effects[:safe] = true
        elsif eff_name == :alloc && match?(:CHAR, ':')
          consume(:CHAR, ':')
          qual_tok = consume(:VAR_ID)
          qualifier = T.must(qual_tok).value.to_sym
          unless [:frame, :heap].include?(qualifier)
            emit_typo_suggestion!(
              qual_tok, T.must(qual_tok).value, %w[frame heap],
              "Unknown alloc qualifier ':#{qualifier}'",
              "closest alloc qualifier",
              category: :type, cascade: true
            )
          end
          effects[:alloc] = qualifier
        else
          effects[:alloc] = :frame
        end
        break unless match!(:CHAR, ',')
      end
    end

    consume(:KEYWORD, 'FROM')
    from_module = T.must(consume(:STRING)).value
    match!(:CHAR, ';')
    node = AST::ExternFnDecl.new(extern_tok, name, params, return_type, from_module, effects)
    node.owner_type = owner_type if owner_type
    node.owner_type_params = owner_type_params if owner_type_params.any?
    node.fn_type_params = fn_type_params if fn_type_params.any?
    node
  end

  sig { params(extern_tok: Lexer::Token).returns(T.nilable(AST::ExternStructDecl)) }
  def parse_extern_struct(extern_tok)
    consume(:KEYWORD, 'STRUCT')
    name = T.must(consume(:TYPE_ID)).value

    # Optional generic type params: EXTERN STRUCT Parsed<T> { ... }
    type_params = []
    if match!(:CHAR, '<')
      loop do
        type_params << T.must(consume(:TYPE_ID)).value.to_sym
        break unless match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end

    # Fields can be empty: EXTERN STRUCT Opaque {} FROM "mod";
    fields = parse_struct_body

    # Optional: CLOSE "method" — register cleanup method for RAII
    close_method = nil
    if match!(:KEYWORD, 'CLOSE')
      close_method = T.must(consume(:STRING)).value
    end

    # Optional: AS "ZigTypeExpr" — alias to parameterized Zig type (e.g. Parsed(JsonRecord))
    as_type = nil
    if match!(:KEYWORD, 'AS')
      as_type = T.must(consume(:STRING)).value
    end

    from_module = nil
    if match!(:KEYWORD, 'FROM')
      from_module = T.must(consume(:STRING)).value
    end
    match!(:CHAR, ';')
    node = AST::ExternStructDecl.new(extern_tok, name, fields, from_module)
    node.type_params = type_params if type_params.any?
    node.close_method = close_method
    node.as_type = as_type
    node
  end

  sig { params(visibility: Symbol).returns(T.nilable(AST::StructDef)) }
  def parse_struct_def(visibility = :package)
    tok = consume(:KEYWORD, 'STRUCT')
    name = T.must(consume(:TYPE_ID)).value
    type_params = []
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      until match?(:CHAR, '>')
        type_params << T.must(consume(:TYPE_ID)).value
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end
    fields = parse_struct_body
    AST::StructDef.new(tok, name, fields, visibility, type_params)
  end

  sig { params(visibility: Symbol).returns(AST::EnumDef) }
  def parse_enum_def(visibility = :package)
    tok = consume(:KEYWORD, 'ENUM')
    name = T.must(consume(:TYPE_ID)).value
    consume(:CHAR, '{')
    variants = []
    until match?(:CHAR, '}')
      variants << T.must(consume(:TYPE_ID)).value
      match!(:CHAR, ',')
    end
    consume(:CHAR, '}')
    AST::EnumDef.new(tok, name, variants, visibility)
  end

  sig { params(visibility: Symbol).returns(T.nilable(AST::UnionDef)) }
  def parse_union_def(visibility = :package)
    tok = consume(:KEYWORD, 'UNION')
    name = T.must(consume(:TYPE_ID)).value

    # Parse optional generic type parameters: UNION Option<T> { ... }
    type_params = []
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      until match?(:CHAR, '>')
        type_params << T.must(consume(:TYPE_ID)).value
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
        fn_name = T.must(consume(:VAR_ID)).value
        _, raw_params = parse_comma_seq(:CHAR, '(', ')') do
          p_name = T.must(consume(:VAR_ID)).value
          consume(:CHAR, ':')
          p_type = parse_type_annotation
          AST::Param.new(name: p_name, type: p_type)
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
        var_name = T.must(consume(:TYPE_ID)).value
        if match?(:CHAR, '{')
          # Inline struct variant: Circle { radius: Number, color: String }
          _, field_pairs = parse_comma_seq(:CHAR, '{', '}') do
            fname_tok = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
            fname = T.must(fname_tok).value
            consume(:CHAR, ':')
            ftype = parse_type_annotation
            reject_auto_in_aggregate_field!(T.must(ftype), fname, fname_tok, "UNION inline-variant")
            [fname, ftype]
          end
          variants[var_name] = Schemas::InlineStructVariant.new(fields: field_pairs.to_h)
        elsif match!(:CHAR, ':')
          # Single-type payload: Data: Number  (or Data: Number @indirect)
          vtype = parse_type_annotation
          reject_auto_in_aggregate_field!(T.must(vtype), var_name, nil, "UNION variant payload")
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

  # Slice the source text spanning [start_tok, end_tok). Used to capture
  # the textual form of an expression we just parsed, so the runtime
  # error path can quote it back to the user (e.g. PRE clauses).
  sig { params(start_tok: Lexer::Token, end_tok: Lexer::Token).returns(String) }
  def source_slice_between(start_tok, end_tok)
    return "" unless @source_code && start_tok && end_tok
    lines = @source_code.lines
    sl, sc = start_tok.line, start_tok.column
    el, ec = end_tok.line, end_tok.column
    return "" if sl < 1 || sl > lines.length
    if sl == el
      T.must(lines[sl - 1])[sc - 1, ec - sc].to_s.strip
    else
      parts = []
      parts << T.must(lines[sl - 1])[sc - 1..]
      ((sl + 1)..(el - 1)).each { |l| parts << lines[l - 1] }
      parts << (T.must(lines[el - 1])[0, ec - 1] || "")
      parts.join.strip
    end
  end

  sig { params(visibility: Symbol, is_method: T::Boolean).returns(T.nilable(AST::FunctionDef)) }
  def parse_function_def(visibility = :package, is_method: false)
    fn_token = if is_method
      consume(:KEYWORD, 'METHOD')
    elsif match?(:KEYWORD, 'METHOD')
      is_method = true
      consume(:KEYWORD, 'METHOD')
    else
      consume(:KEYWORD, 'FN')
    end
    name_tok = consume(:VAR_ID)
    name = T.must(name_tok).value
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
        type_params << T.must(consume(:TYPE_ID)).value
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
    end

    params = parse_argument_list()

    captures = []
    if match!(:KEYWORD, 'USE')
      captures = parse_argument_list(as_param: false)
    end

    # Return lifetime syntax:
    #   - omitted              -- no lifetime constraint on the return
    #   - `foo:T`              -- single-source: returned value's lifetime
    #                              is bound to param `foo`. Stored as a
    #                              one-element Array of Identifier.
    #   - `(foo bar baz):T`    -- multi-source: returned value's lifetime
    #                              is the intersection of every named
    #                              binding's lifetime. Names are space-
    #                              and/or comma-separated inside the parens.
    #                              Stored as a multi-element Array.
    #   - `*:T`                -- wildcard / lazy: every parameter's
    #                              lifetime is conservatively folded into
    #                              the source set. Stored as the symbol
    #                              `:wildcard`; the annotator can replace it
    #                              with an explicit list.
    return_type = nil
    return_type_token = nil
    return_lifetime_token = nil
    explicit_return = match?(:KEYWORD, 'RETURNS')  # peek for the post-#335 stamp
    # Gradual mode: when RETURNS is omitted, treat as implicit Auto so
    # the inference pass picks the return type up from RETURN exprs.
    # We mark explicit_return = true so the existing fallible-return
    # enforcement uses the inferred type once resolved. Without
    # `--gradual`, omitted RETURNS keeps its current behavior
    # (implicit-Void / inferred per the legacy path).
    if !explicit_return && @gradual
      return_type = Type.new(:Auto, auto: true)
      explicit_return = true
    end
    if match!(:KEYWORD, 'RETURNS')
      shared_return = match!(:KEYWORD, 'SHARED')

      if match?(:CHAR, '(')
        # Multi-binding form: collect VAR_IDs separated by ',' or
        # whitespace until ')'. The lexer skips whitespace, so a
        # space-separated list parses as a sequence of bare VAR_IDs.
        return_lifetime_token = consume(:CHAR, '(')
        names = []
        while !match?(:CHAR, ')')
          names << parse_var_id
          # Allow optional commas between names; they're sugar.
          match!(:CHAR, ',')
        end
        consume(:CHAR, ')')
        consume(:CHAR, ':')
        return_lifetime = names
      elsif match?(:CHAR, '*')
        return_lifetime_token = consume(:CHAR, '*')
        consume(:CHAR, ':')
        return_lifetime = :wildcard
      elsif current.type == :VAR_ID
        # Backward-compat single-binding form. Wrap in a one-element
        # Array so downstream code uniformly iterates a list.
        return_lifetime_token = current
        return_lifetime = [parse_var_id]
        consume(:CHAR, ':')
      end

      return_type_token = current
      return_type = parse_type_annotation()
      return_type = mark_polymorphic_shared_type(T.must(return_type)) if shared_return
    end

    # Gates which sync families this function accepts on its parameters.
    # Mandatory whenever the body uses WITH on a parameter.
    requires_clause = nil
    early_requires_clauses = nil
    if match!(:KEYWORD, 'REQUIRES')
      requires_clause = parse_requires_clause
      # If this REQUIRES contained reentrance kinds (e.g. NON_REENTRANT),
      # parse_requires_clause stashed them on @last_requires_clauses --
      # forward them to the same `requires_clauses` hash that
      # parse_requires_clauses (post-RETURNS) populates.
      early_requires_clauses = @last_requires_clauses
    end

    # Legacy reentrance annotations are still accepted so `clear fix` can
    # migrate them to EFFECTS REENTRANT declarations.
    reentrant = nil
    tail_call = false
    reentrant_token = nil
    if match?(:VAR_ID) && %w[@reentrant @nonReentrant].include?(current.value)
      cap_tok = consume(:VAR_ID)
      reentrant = T.must(cap_tok).value == '@reentrant' ? :reentrant : :non_reentrant
      reentrant_token = cap_tok if reentrant == :reentrant
      # Check for :tailCall suffix
      if reentrant == :reentrant && match?(:CHAR, ':') && @tokens[@pos + 1]&.value == 'tailCall'
        consume(:CHAR, ':')
        consume(:VAR_ID)
        tail_call = true
      end
    end

    # EFFECTS REENTRANT variants:
    #   EFFECTS REENTRANT             -> :reentrant              (real recursion;
    #                                                             caller runs on @service)
    #   EFFECTS REENTRANT:THUNK       -> :reentrant_thunk        (CPS + trampoline)
    #   EFFECTS REENTRANT:TAIL_CALL   -> :reentrant_tail_call    (self-loop, verified)
    #   EFFECTS REENTRANT:NOT_LOGICAL -> :reentrant_not_logical  (runtime StackGuard;
    #                                                             requires `!T` return)
    effects_decl, effects_span = parse_effects_decl
    if effects_decl && reentrant
      error!(fn_token, :REENTRANT_LEGACY_AND_NEW, name: name)
    end

    # Reentrance constraints bind by parameter name; the annotator validates
    # that each name references a real parameter so the parser stays syntactic.
    requires_clauses = parse_requires_clauses(name)
    # Merge any reentrance kinds caught by the early-position
    # parse_requires_clause into the canonical hash. Duplicates
    # across the two positions still error.
    if early_requires_clauses && !early_requires_clauses.empty?
      early_requires_clauses.each do |k, v|
        if requires_clauses.key?(k)
          error!(fn_token, :DUPLICATE_REQUIRES_CLAUSE, fn: name, name: k)
        end
        requires_clauses[k] = v
      end
    end

    # PRE predicates keep their source slice so runtime failures can quote
    # the condition that failed.
    pre_clauses = []
    while match!(:KEYWORD, 'PRE')
      consume(:CHAR, ':')
      start_tok = current
      expr = parse_expression
      end_tok = current
      src = source_slice_between(start_tok, end_tok)
      pre_clauses << { expr: expr, source: src }
    end

    # DEBUG_POST predicates may reference parameters and the synthetic `result`.
    post_clauses = []
    while match!(:KEYWORD, 'DEBUG_POST')
      consume(:CHAR, ':')
      start_tok = current
      expr = parse_expression
      end_tok = current
      src = source_slice_between(start_tok, end_tok)
      post_clauses << { expr: expr, source: src }
    end

    arrow_token = current
    consume(:ARROW, '->')
    body = parse_block_body(['END', 'CATCH'])

    catch_block = nil
    # Parse CATCH clauses (unified error-system grammar):
    #
    #   CATCH <item> (',' <item>)* [ WITH(<filter> (',' <filter>)*) ]
    #
    # <item>   is a TYPE_ID — disambiguated via ERROR_KINDS into a kind
    #         or a type. Any mix and any count is valid:
    #           CATCH Input, NotFound           — kinds only
    #           CATCH ParseErr, BadJson         — types only
    #           CATCH Input, ParseErr           — mix
    # <filter> is a TYPE_ID (error type name) OR a STRING (message to
    #         match). The annotator validates the types against the
    #         registry; messages are compared as-is at runtime.
    #
    # Match semantics:
    #   Items are ORed. WITH filters (if present) are ORed among
    #   themselves and ANDed against the item-list match. Example:
    #     CATCH Input, ParseErr WITH(BadJson, "bad header")
    #   matches iff (kind is Input OR type is ParseErr) AND
    #               (type is BadJson OR message == "bad header").
    #
    # Clause shape stored on the AST:
    #   { items:        [{ form: :kind|:type, name:, token: }, ...],
    #     filters:      [{ form: :type|:message, value: }, ...],
    #     body:         [...] }
    # Annotator fills in clause[:kinds] / [:types] / [:filter_types] /
    # [:filter_messages] for lowering.
    catch_block = nil
    if match?(:KEYWORD, 'CATCH')
      catch_clauses = []
      default_body = nil
      while match?(:KEYWORD, 'CATCH')
        consume(:KEYWORD, 'CATCH')

        items = [parse_catch_item]
        while match!(:CHAR, ',')
          items << parse_catch_item
        end

        filters = []
        if match?(:KEYWORD, 'WITH')
          consume(:KEYWORD, 'WITH')
          consume(:CHAR, '(')
          filters << parse_catch_filter
          while match!(:CHAR, ',')
            filters << parse_catch_filter
          end
          consume(:CHAR, ')')
        end

        clause_body = parse_block_body(['CATCH', 'DEFAULT', 'END'])
        catch_clauses << AST::CatchClause.new(
          items: items,
          filters: filters,
          body: clause_body,
        )
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
    node.explicit_return_type = explicit_return  # post-#335: enforce-fallible-returns gate
    node.type_params = type_params unless type_params.empty?
    node.reentrant = reentrant
    node.tail_call = tail_call
    node.requires = requires_clause
    node.reentrant_token = reentrant_token
    node.arrow_token = arrow_token
    node.name_token = name_tok
    node.effects_decl = effects_decl
    node.effects_span = effects_span if effects_span
    node.max_depth_n = effects_span[:max_depth] if effects_span && effects_span[:max_depth]
    node.tight_reentrance = effects_span[:tight] if effects_span
    node.requires_clauses = requires_clauses unless requires_clauses.empty?
    node.return_type_token = return_type_token
    node.pre_clauses = pre_clauses unless pre_clauses.empty?
    node.post_clauses = post_clauses unless post_clauses.empty?
    node.is_method = is_method
    node
  end

  # Parse the REQUIRES clause body (the keyword has already been consumed):
  #
  #   <name-list> ':' <family-disjunction>
  #     [',' <name-list> ':' <family-disjunction>]*
  #
  # Disambiguation: while parsing a name-list (before ':'), every ',NAME'
  # extends the name-list. After ':' and the family disjunction, a ','
  # starts a new group.
  #
  # Returns: { param_name_string => Set[Symbol] }
  # Family table for REQUIRES.
  #   - LOCKED: mutex / rwlock (admits @locked, @writeLocked).
  #   - SNAPSHOTTED: retry-style umbrella (admits @versioned, @atomic).
  #   - VERSIONED / ATOMIC: escape hatches that forbid the other.
  #   - LOCAL: non-sync umbrella (admits @local, @multiowned, plain T).
  #     A WITH POLYMORPHIC body on a LOCAL-typed param lowers to direct
  #     field access -- no lock, no Arc unwrap, no snapshot. Lets a
  #     single transaction fn accept every supported binding kind.
  REQUIRES_VALID_FAMILIES = T.let(%w[LOCKED SNAPSHOTTED VERSIONED ATOMIC LOCAL ACTOR LOCK_FREE].to_set.freeze, T::Set[String])
  # Reentrancy constraints share the REQUIRES grammar slot, but are routed
  # into `requires_clauses` so they don't pollute the capability-family hash.
  REQUIRES_REENTRANCE_KINDS = T.let(%w[NON_REENTRANT].to_set.freeze, T::Set[String])

  sig { returns(T.nilable(T::Hash[String, T::Set[Symbol]])) }
  def parse_requires_clause
    requires_hash = {}
    @last_requires_clauses = {}

    loop do
      names = [T.must(consume(:VAR_ID)).value]
      while match!(:CHAR, ',')
        names << T.must(consume(:VAR_ID)).value
      end
      consume(:CHAR, ':')

      families = Set.new
      reentrance_kinds = []
      first = parse_requires_family_or_reentrance
      T.must(first)[:family] ? (families << T.must(first)[:family]) : reentrance_kinds << T.must(first)[:reentrance]
      while match!(:CHAR, '|')
        nxt = parse_requires_family_or_reentrance
        T.must(nxt)[:family] ? (families << T.must(nxt)[:family]) : reentrance_kinds << T.must(nxt)[:reentrance]
      end

      names.each do |n|
        requires_hash[n] = families if !families.empty?
        reentrance_kinds.each { |k| @last_requires_clauses[n] = k }
      end

      break unless match!(:CHAR, ',')
    end

    requires_hash
  end

  # Returns { family: Symbol } or { reentrance: Symbol } based on the
  # token. Family kinds go into the capability `requires` hash; reentrance
  # kinds are forwarded into `requires_clauses`.
  sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def parse_requires_family_or_reentrance
    tok = consume(:TYPE_ID)
    if REQUIRES_VALID_FAMILIES.include?(T.must(tok).value)
      { family: T.must(tok).value.to_sym }
    elsif REQUIRES_REENTRANCE_KINDS.include?(T.must(tok).value)
      kind = case T.must(tok).value
             when 'NON_REENTRANT' then :non_reentrant
             end
      { reentrance: kind }
    else
      candidates = REQUIRES_VALID_FAMILIES.to_a + REQUIRES_REENTRANCE_KINDS.to_a
      emit_typo_suggestion!(
        tok, T.must(tok).value, candidates,
        "Unknown REQUIRES family '#{T.must(tok).value}' (valid: #{REQUIRES_VALID_FAMILIES.to_a.join(', ')}; kinds: #{REQUIRES_REENTRANCE_KINDS.to_a.join(', ')})",
        "closest REQUIRES family/kind",
        category: :type, cascade: true
      )
    end
  end

  # Legacy thin wrapper: callers that only need families.
  sig { returns(Symbol) }
  def parse_requires_family
    res = parse_requires_family_or_reentrance
    error!(current, :EXPECTED_CAP_FAMILY) unless T.must(res)[:family]
    T.must(res)[:family]
  end

  # Legacy reentrance REQUIRES clauses can appear between the function header
  # and `->`. They coexist with capability-family REQUIRES until the grammar
  # is unified.
  #
  #   REQUIRES f: NON_REENTRANT REQUIRES g: NON_REENTRANT ->
  sig { params(fn_name: String).returns(T::Hash[String, Symbol]) }
  def parse_requires_clauses(fn_name)
    out = {}
    while match?(:KEYWORD, 'REQUIRES')
      consume(:KEYWORD, 'REQUIRES')
      name_tok = consume(:VAR_ID)
      consume(:CHAR, ':')
      kind_tok = consume(:TYPE_ID)
      kind =
        case T.must(kind_tok).value
        when 'NON_REENTRANT' then :non_reentrant
        else
          emit_typo_suggestion!(
            kind_tok, T.must(kind_tok).value, %w[NON_REENTRANT],
            "Unknown REQUIRES kind '#{T.must(kind_tok).value}'",
            "closest REQUIRES kind",
            category: :type, cascade: true
          )
        end
      if out.key?(T.must(name_tok).value)
        error!(name_tok, :DUPLICATE_REQUIRES_CLAUSE, fn: fn_name, name: T.must(name_tok).value)
      end
      out[T.must(name_tok).value] = kind
    end
    out
  end

  # REENTRANT, THUNK, and TAIL_CALL parse as TYPE_IDs matched by value because
  # the only context they appear in is right after EFFECTS.
  sig { returns(T.nilable(T::Array[T.untyped])) }
  def parse_effects_decl
    return [nil, nil] unless match?(:KEYWORD, 'EFFECTS')
    eff_kw = consume(:KEYWORD, 'EFFECTS')
    eff_tok = consume(:TYPE_ID)
    unless T.must(eff_tok).value == 'REENTRANT'
      emit_typo_suggestion!(
        eff_tok, T.must(eff_tok).value, %w[REENTRANT],
        "Unknown function effect '#{T.must(eff_tok).value}'",
        "closest function effect",
        category: :type, cascade: true
      )
    end
    span_start = eff_kw
    span_end_tok = eff_tok # tail of `EFFECTS REENTRANT` so far
    unless match!(:CHAR, ':')
      return [:reentrant, { start_tok: span_start, end_tok: span_end_tok, tight: false }]
    end

    # Optional `:TIGHT` modifier (mirrors `TIGHT WHILE`). Order:
    # `REENTRANT:TIGHT:VARIANT`. Valid before THUNK / TAIL_CALL only;
    # MAX_DEPTH implies TIGHT (so :TIGHT:MAX_DEPTH is redundant and
    # rejected); NOT_LOGICAL has depth=1 so TIGHT is meaningless and
    # rejected too.
    tight = false
    tight_tok = nil
    if match?(:KEYWORD, 'TIGHT')
      tight_tok = consume(:KEYWORD, 'TIGHT')
      tight = true
      span_end_tok = tight_tok
      # `:TIGHT` alone (no following variant) is allowed -- means "plain
      # :reentrant but skip the entry yield-check".
      if match!(:CHAR, ':')
        # fall through to variant parsing below
      else
        return [:reentrant, { start_tok: span_start, end_tok: span_end_tok, tight: true }]
      end
    end

    variant_tok = consume(:TYPE_ID)
    kind = case T.must(variant_tok).value
           when 'THUNK'       then :reentrant_thunk
           when 'TAIL_CALL'   then :reentrant_tail_call
           when 'NOT_LOGICAL' then :reentrant_not_logical
           when 'MAX_DEPTH'   then :reentrant_max_depth
           else
             emit_typo_suggestion!(
               variant_tok, T.must(variant_tok).value, %w[THUNK TAIL_CALL NOT_LOGICAL MAX_DEPTH],
               "Unknown REENTRANT variant '#{T.must(variant_tok).value}'",
               "closest REENTRANT variant",
               category: :type, cascade: true
             )
           end
    if tight && (kind == :reentrant_not_logical || kind == :reentrant_max_depth)
      label = kind == :reentrant_not_logical ? "NOT_LOGICAL" : "MAX_DEPTH"
      explanation = label == 'MAX_DEPTH' ?
        'MAX_DEPTH(N) implies TIGHT (the bounded depth replaces the yield-check); just write :MAX_DEPTH(N).' :
        'NOT_LOGICAL has depth=1 by runtime assertion, so TIGHT is meaningless.'
      error!(variant_tok, :INVALID_TIGHT_VARIANT, label: label, explanation: explanation)
    end
    span_end_tok = variant_tok
    max_depth_n = nil
    if kind == :reentrant_max_depth
      consume(:CHAR, '(')
      n_tok = current
      n_lit = consume_number
      max_depth_n = n_lit.value.to_i
      if max_depth_n <= 0
        error!(n_tok, :MAX_DEPTH_NONPOSITIVE, got: max_depth_n)
      end
      close_tok = consume(:CHAR, ')')
      span_end_tok = close_tok
    end
    [kind, { start_tok: span_start, end_tok: span_end_tok, max_depth: max_depth_n, tight: tight }]
  end

  sig { params(stop_words: T::Array[String]).returns(T.nilable(T::Array[T.untyped])) }
  def parse_block_body(stop_words = ['END'])
    stmts = []
    types = stop_words.map { |w| Lexer::KEYWORDS.include?(w) ? :KEYWORD : :CHAR }
    stop_words = stop_words.zip(types)
    # Keep going until we hit a stop word (END, ELSE, CATCH, }, etc)
    until stop_words.any? { |w, t| match?(T.must(t), w) } || match?(:EOF)
      stmt = parse_statement()
      stmts << stmt if stmt
    end
    stmts
  end

  sig { params(precedence: Integer).returns(T.untyped) }
  def parse_expression(precedence = 0)
    lhs = parse_unary

    while (op_token = current) && (op_prec = get_precedence(op_token)) && op_prec > precedence
      # GUARD CLAUSE: AS is used as a keyword in CAST, and only binds if followed by an alias ($...)
      if op_token.value == 'AS' && (peek.type == :TYPE_ID || peek.value[0] != '$')
        break
      end

      consume(op_token.type)
      lhs = parse_binary_op(lhs, op_token, op_prec)
    end

    lhs
  end

  sig { params(token: Lexer::Token).returns(T.nilable(Integer)) }
  def get_precedence(token)
    return nil unless token.type == :CHAR || token.type == :KEYWORD || token.type == :SMOOTH || token.type == :OR_RESCUE || token.type == :RANGE_EXCL || token.type == :RANGE_INCL

    # Precedence levels (higher = tighter binding)
    case token.value
    when '|>'             then 1
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

  sig { params(lhs: T.untyped, op_token: Lexer::Token, op_prec: Integer).returns(T.untyped) }
  def parse_binary_op(lhs, op_token, op_prec)
    op_val = op_token.value
    
    next_prec = (op_val == '**') ? op_prec - 1 : op_prec

    case op_val
    when 'AS'
      rhs = parse_var_id
      unless rhs.is_a?(AST::Identifier)
        error!(rhs, :EXPECTED_IDENT_AFTER_AS, got: rhs.class)
      end
      return AST::BinaryOp.new(op_token, lhs, :BIND_VAR, rhs)

    when 'OR'
      rhs = parse_or_rescue
      return AST::BinaryOp.new(op_token, lhs, :OR_RESCUE, rhs)

    when '|>'
      # SMOOTH binds Level 1, but its RHS allows chained pipe operators
      rhs = parse_expression(next_prec)
      # Predicate suffix: x |> isPositive? parses as OptionalUnwrap(Identifier).
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

    rhs = parse_expression(next_prec)
    op_sym = AST::OP_TO_OP_CODE[op_val] || op_val.to_sym
    
    AST::BinaryOp.new(op_token, lhs, op_sym, rhs)
  end

  sig { returns(T.untyped) }
  def parse_or_rescue
    # Syntax: ... OR RETURN
    if match!(:KEYWORD, 'RETURN')
      rhs = AST::ReturnNode.new(previous, nil)

    # Syntax: ... OR RAISE (bubble up error - Zig's `try`)
    elsif match!(:KEYWORD, 'RAISE')
      rhs = AST::OrRaise.new(previous)

    # Syntax: ... OR EXIT  (unified error system — mirrors RAISE):
    #   OR EXIT "msg"                   — inherit kind/type, replace msg
    #   OR EXIT Kind                    — set kind, clear type
    #   OR EXIT Kind, "msg"             — set kind, clear type, replace msg
    #   OR EXIT Kind, Type              — set kind + type
    #   OR EXIT Kind, Type, "msg"       — full
    #   OR EXIT Type                    — set type (kind auto-resolved)
    #   OR EXIT Type, "msg"             — set type + msg
    # Disambiguation: first TYPE_ID is a kind iff it's in ERROR_KINDS;
    # otherwise it's a type. Unspecified fields inherit from the
    # pre-existing rt.__error at lowering time.
    elsif match!(:KEYWORD, 'EXIT')
      exit_tok = previous
      kind = nil
      error_name = nil
      message = nil

      if match?(:STRING)
        # OR EXIT "msg" — pure message override
        message = parse_expression
      elsif match?(:TYPE_ID)
        first_tok = consume(:TYPE_ID)
        first_is_kind = ERROR_KINDS.include?(T.must(first_tok).value)
        if first_is_kind
          kind = T.must(first_tok).value.to_sym
        else
          error_name = T.must(first_tok).value
        end
        if match?(:CHAR, ',')
          consume(:CHAR, ',')
          if first_is_kind && match?(:TYPE_ID)
            # Kind, Type[, "msg"]
            error_name = T.must(consume(:TYPE_ID)).value
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
        # Kept for backward compat; equivalent to OR RAISE.
      end

      rhs = AST::OrExit.new(exit_tok, kind, error_name, message)

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

  sig { returns(T.untyped) }
  def parse_unary
    v = current.value
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
        error!(n_tok, :SIGIL_N_NONPOSITIVE, sigil: T.must(sigil_tok).value, count: n)
      end
      consume(:CHAR, ')')
      inner = parse_primary
      return AST::CallSiteOverride.new(sigil_tok, T.must(sigil_tok).value.sub('@', '').to_sym, n, inner)
    end
    parse_primary
  end

  # Sentinel returned by a suffix rule to signal "this suffix does not apply
  # to the current lhs — stop processing without consuming any tokens."
  SUFFIX_DECLINE = T.let(Object.new.freeze, Object)

  sig { params(lhs: T.untyped).returns(T.untyped) }
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

  sig { returns(T.untyped) }
  def parse_var_id
    var_token = consume(:VAR_ID)
    name = T.must(var_token).value
    node = AST::Identifier.new(var_token, name)

    # Predicate suffix: name? followed by ( → function call with ? suffix
    if match?(:CHAR, '?') && peek_at(1)&.value == '('
      consume(:CHAR, '?')
      name = "#{name}?"
    end

    if match?(:CHAR, '(')
      _, args = parse_comma_seq(:CHAR, '(', ')') { parse_expression }
      node = AST::FuncCall.new(var_token, name, args)
    end

    return parse_suffixes(node)
  end

  sig { returns(T.untyped) }
  def parse_if_statement
    if_token = consume(:KEYWORD, 'IF')
    parse_if_chain(T.must(if_token))
  end

  sig { params(if_token: Lexer::Token).returns(T.untyped) }
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
        error!(if_token, :MULTIPLE_BINDINGS_NEED_PARENS)
      end
      bindings = [AST::Binding.new(expr: condition, name: T.must(name_tok).value, name_token: name_tok)]
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
  # Returns nil if condition is not a paren-bind pattern.
  # Raises error if any bind in a && chain is bare (not paren-wrapped).
  sig { params(node: T.untyped, if_token: Lexer::Token).returns(T.nilable(T::Array[AST::Binding])) }
  def extract_paren_bindings(node, if_token)
    case node
    when AST::BinaryOp
      if node.op == :BIND_VAR
        return node.paren_bind ? [AST::Binding.new(expr: node.left, name: node.right.name, name_token: node.right.token)] : nil
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
  sig { params(node: T.untyped, if_token: Lexer::Token).void }
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
    parse_if_chain_expr(T.must(if_token))
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
  sig { params(partial: T::Boolean).returns(AST::MatchStatement) }
  def parse_match_expr(partial: false)
    tok = consume(:KEYWORD, 'MATCH')
    takes = match?(:KEYWORD, 'TAKES') && consume(:KEYWORD, 'TAKES')
    expr = parse_expression
    consume(:KEYWORD, 'START')

    cases = []
    default_case = T.let(nil, T.untyped)

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
        cases << AST::MatchCase.new(kind: :when, value: condition, body: [parse_expression])
      elsif match?(:CHAR, '{')
        pattern = parse_struct_pattern
        consume(:ARROW)
        cases << AST::MatchCase.new(kind: :struct_pattern, value: pattern, body: [parse_expression])
      else
        @suppress_struct_lit = true
        first_pattern = parse_expression
        @suppress_struct_lit = false
        # Multi-pattern arm: `Pat1, Pat2, ... [AS x | { dest }] -> body`.
        # The `,` here is part of the arm; arm-separator `,` is consumed
        # AFTER the body. AS / { ... } apply to the whole arm.
        extra_patterns = []
        while match?(:CHAR, ',') && multi_pattern_continues?
          consume(:CHAR, ',')
          @suppress_struct_lit = true
          extra_patterns << parse_expression
          @suppress_struct_lit = false
        end
        binding = nil
        destructure = nil
        if match?(:KEYWORD, 'AS')
          consume(:KEYWORD, 'AS')
          binding = T.must(consume(:VAR_ID)).value
        elsif match?(:CHAR, '{')
          destructure = parse_struct_pattern
        end
        consume(:ARROW)
        if extra_patterns.empty?
          cases << AST::MatchCase.new(kind: :eq, value: first_pattern, binding: binding, destructure: destructure, body: [parse_expression])
        else
          cases << AST::MatchCase.new(kind: :eq, value: first_pattern, extra_values: extra_patterns,
                     binding: binding, destructure: destructure, body: [parse_expression])
        end
      end
      match!(:CHAR, ',')
    end

    consume(:KEYWORD, 'END')
    AST::MatchStatement.new(tok, expr, cases, default_case, [], nil, !partial, !!takes)
  end

  # FOR var IN (start ..= end) DO body END   — range iteration
  # FOR var IN (start ..< end) DO body END   — range iteration
  # FOR var IN collection DO body END         — collection iteration
  sig { returns(T.untyped) }
  def parse_for_range
    tok = consume(:KEYWORD, 'FOR')
    var_name = T.must(consume(:VAR_ID)).value
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

  sig { params(partial: T::Boolean).returns(AST::MatchStatement) }
  def parse_match_statement(partial: false)
    tok = consume(:KEYWORD, 'MATCH')
    takes = match?(:KEYWORD, 'TAKES') && consume(:KEYWORD, 'TAKES')
    expr = parse_expression
    consume(:KEYWORD, 'START')

    cases = []
    default_case = T.let(nil, T.untyped)

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
        cases << AST::MatchCase.new(kind: :when, value: condition, body: body)
      elsif match?(:CHAR, '{')
        pattern = parse_struct_pattern
        consume(:ARROW)
        body = parse_block_body([',', 'DEFAULT', 'WHEN', 'END'])
        cases << AST::MatchCase.new(kind: :struct_pattern, value: pattern, body: body)
      else
        # Suppress struct literal parsing so TypeName.Variant{ ... } doesn't get
        # consumed as a constructor — the { starts a destructuring pattern.
        @suppress_struct_lit = true
        first_pattern = parse_expression
        @suppress_struct_lit = false
        # Multi-pattern arm: `Pat1, Pat2, Pat3 [AS x | { dest }] -> body`.
        # The `,` here (before the arrow) signals continuation; arm-
        # separator `,` is consumed AFTER the body, below. AS / { ... }
        # apply to the whole arm and bind across every pattern.
        extra_patterns = []
        while match?(:CHAR, ',') && multi_pattern_continues?
          consume(:CHAR, ',')
          @suppress_struct_lit = true
          extra_patterns << parse_expression
          @suppress_struct_lit = false
        end
        binding = nil
        destructure = nil
        if match?(:KEYWORD, 'AS')
          consume(:KEYWORD, 'AS')
          binding = T.must(consume(:VAR_ID)).value
        elsif match?(:CHAR, '{')
          # Union variant destructuring: Result.Ok{ value, count }
          destructure = parse_struct_pattern
        end
        consume(:ARROW)
        body = parse_block_body([',', 'DEFAULT', 'WHEN', 'END'])
        if extra_patterns.empty?
          cases << AST::MatchCase.new(kind: :eq, value: first_pattern, binding: binding, destructure: destructure, body: body)
        else
          cases << AST::MatchCase.new(kind: :eq, value: first_pattern, extra_values: extra_patterns,
                     binding: binding, destructure: destructure, body: body)
        end
      end
      match!(:CHAR, ',')  # consume comma separator between cases if present
    end

    consume(:KEYWORD, 'END')
    AST::MatchStatement.new(tok, expr, cases, default_case, [], nil, !partial, !!takes)
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
      name = T.must(name_tok).value

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
    form = ERROR_KINDS.include?(T.must(tok).value) ? :kind : :type
    AST::CatchItem.new(form: form, name: T.must(tok).value, token: T.must(tok))
  end

  # Parse a single CATCH WITH filter: a TYPE_ID (error type) or a
  # STRING literal (message).
  sig { returns(T.nilable(AST::CatchFilter)) }
  def parse_catch_filter
    if match?(:TYPE_ID)
      tok = consume(:TYPE_ID)
      AST::CatchFilter.new(form: :type, value: T.must(tok).value, token: T.must(tok))
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
    first_is_kind = ERROR_KINDS.include?(T.must(first_tok).value)

    kind = first_is_kind ? T.must(first_tok).value.to_sym : nil
    error_name = first_is_kind ? nil : T.must(first_tok).value
    message = nil

    if match?(:CHAR, ',')
      consume(:CHAR, ',')
      if first_is_kind && match?(:TYPE_ID)
        # Kind, Type[, "msg"]
        error_name = T.must(consume(:TYPE_ID)).value
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

  sig { returns(T.untyped) }
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
        return AST::WhileBindLoop.new(tok, condition, T.must(name_tok).value, name_tok, [stmt].compact, nil)
      end
      consume(:KEYWORD, 'DO')
      body = parse_stmts_until_end
      consume(:KEYWORD, 'END')
      return AST::WhileBindLoop.new(tok, condition, T.must(name_tok).value, name_tok, body, nil)
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

  sig { returns(T.nilable(T::Array[T.untyped])) }
  def parse_stmts_until_end
    parse_block_body(['END'])
  end

  sig { returns(T.nilable(T::Hash[String, T::Hash[Symbol, T.untyped]])) }
  def parse_struct_body
    _, pairs = parse_comma_seq(:CHAR, '{', '}') do
      name_tok = consume(:VAR_ID)
      name = T.must(name_tok).value

      # Syntax: name=default: Type  (default before type annotation)
      default_val = nil
      if match!(:CHAR, '=')
        default_val = parse_expression()
      end

      consume(:CHAR, ':')

      # Optional BORROWED modifier: field is a reference, not owned
      borrowed = match!(:KEYWORD, 'BORROWED') ? true : false

      type = parse_type_annotation()

      reject_auto_in_aggregate_field!(T.must(type), name, name_tok, "STRUCT")

      [name, AST::StructField.new(type: type, default: default_val, borrowed: borrowed)]
    end
    pairs.to_h
  end

  # Cross-callsite type inference into named aggregates is intentionally not
  # supported; aggregate field types must be concrete.
  sig { params(type: Type, field_name: String, field_tok: T.nilable(Lexer::Token), context_label: String).void }
  def reject_auto_in_aggregate_field!(type, field_name, field_tok, context_label)
    return unless type.is_a?(Type) && type.auto?
    auto_tok = type.respond_to?(:auto_token) ? type.auto_token : nil
    anchor = auto_tok || field_tok
    error!(anchor, :AUTO_NOT_ALLOWED_IN_FIELD, context: context_label, field: field_name)
  end

  sig { returns(T.untyped) }
  def parse_primary
    rule = @@primary_rules[[current.type, current.value]]
    rule ||= @@primary_rules[[current.type, nil]]
    return instance_exec(&rule) if rule
    return parse_unary() if current.type == :CHAR && AST::UNARY_OPS.include?(current.value)
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
    saved = @pos
    begin
      return false unless current.type == :CHAR && current.value == '<'
      @pos += 1 # skip '<'
      depth = 1
      loop do
        return false if current.nil?
        if current.type == :CHAR && current.value == '<'
          depth += 1
        elsif current.type == :CHAR && current.value == '>'
          depth -= 1
          @pos += 1
          return current.type == :CHAR && current.value == end_char if depth == 0
          next
        end
        @pos += 1
        if depth == 0
          return current.type == :CHAR && current.value == end_char
        end
      end
    ensure
      @pos = saved
    end
  end

  # Struct literal: Pair<Number>{ ... }
  sig { returns(T::Boolean) }
  def peek_is_generic_struct_lit?
    peek_generic_angle_params?('{')
  end

  sig { params(storage: Symbol).returns(T.untyped) }
  def parse_lit(storage)
    if match?(:TYPE_ID)
      type_token = consume(:TYPE_ID)
      name = T.must(type_token).value
      # Collection constructor: List[] / Pool[] (with optional capabilities)
      # Element type is inferred from first append/insert.
      if %w[List Pool Set].include?(name) && match?(:CHAR, '[')
        # List[] / List[1, 2, 3] -- empty or element-initialized.
        _, ctor_items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
        collection = { "List" => :list, "Pool" => :pool, "Set" => :set }.fetch(name)
        is_soa = false
        shard_count = nil
        if (caps = parse_constructor_capabilities(T.must(type_token), name))
          shard_count = caps[:shard_count]
          is_soa = caps[:is_soa] || false
        end
        node = AST::ListLit.new(type_token, ctor_items, storage)
        node.instance_variable_set(:@constructor_collection, collection)
        node.instance_variable_set(:@constructor_soa, is_soa)
        node.instance_variable_set(:@constructor_shard_count, shard_count)
        return node
      elsif match?(:CHAR, '<') && peek_is_generic_struct_lit?
        # Generic struct literal: Pair<Number>{ first: 1.0, second: 2.0 }
        consume(:CHAR, '<')
        type_args = []
        until match?(:CHAR, '>')
          type_args << type_annotation_source(T.must(parse_type_annotation))
          match!(:CHAR, ',')
        end
        consume(:CHAR, '>')
        _, fields = parse_comma_seq(:CHAR, '{', '}') do
          name_tok = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
          consume(:CHAR, ':'); v = parse_expression
          [[T.must(name_tok).value, v], name_tok]
        end
        lit = AST::StructLit.new(type_token, name, fields.map(&:first).to_h, storage, type_args)
        lit.field_tokens = fields.each_with_object({}) { |(kv, t), h| h[kv.first] = t }
        return lit
      elsif match?(:CHAR, '{') && !@suppress_struct_lit
        # Struct literal: User{ id: 1 }
        _, fields = parse_comma_seq(:CHAR, '{', '}') do
          name_tok = current.type == :TYPE_ID ? consume(:TYPE_ID) : consume(:VAR_ID)
          consume(:CHAR, ':'); v = parse_expression
          [[T.must(name_tok).value, v], name_tok]
        end
        lit = AST::StructLit.new(type_token, name, fields.map(&:first).to_h, storage)
        lit.field_tokens = fields.each_with_object({}) { |(kv, t), h| h[kv.first] = t }
        return lit
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
      return AST::Literal.new(current, :STRING, T.must(consume(:STRING)).value, storage)
    end
    return nil
  end

  sig { returns(T.untyped) }
  def parse_sigil_construct
    percent_token = consume(:PERCENT)
    # % is now a no-op for storage: escape analysis and declared types determine heap vs stack.
    lit = parse_lit(:stack)
    return parse_suffixes(lit) if !lit.nil?
    if match?(:CHAR, '(')
      params = parse_argument_list()
      captures = []
      if match!(:KEYWORD, 'USE')
        captures = parse_argument_list(as_param: false)
      end
      consume(:ARROW, '->')
      body = parse_expression
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
  sig { returns(T.untyped) }
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
        options[T.must(key_tok).value] = val
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

  # Parses a function type annotation: FN(Type, ...) -> ReturnType
  # Parameter names are optional (documentation only): FN(n: Int64) -> Bool is the same as FN(Int64) -> Bool.
  # Returns a Type whose raw is { params: [...], return: { type: Type }, fn_type: true }.
  sig { returns(Type) }
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
    Type.new(FunctionSignature.new(
      params: param_types.each_with_index.map { |t, i|
        AST::Param.new(name: "arg#{i}", type: t, required: true, mutable: false, takes: false)
      },
      return_type: return_type,
      reentrant: allows_reentrant
    ))
  end

  sig { returns(T.nilable(Type)) }
  def parse_type_annotation
    # Function type: FN(Type, ...) -> ReturnType
    return parse_fn_type_annotation if match?(:KEYWORD, 'FN')

    # Polymorphic shared-family type: SHARED T, SHARED !T, SHARED ~T, etc.
    # This is distinct from concrete `T @shared` Arc syntax.
    if match?(:KEYWORD, 'SHARED')
      consume(:KEYWORD, 'SHARED')
      return mark_polymorphic_shared_type(T.must(parse_type_annotation))
    end

    # Auto — gradual-typing placeholder. Resolved to a concrete type
    # by the inference pass (see docs/agents/gradual-typing.md). At
    # parse time it's just a sentinel Type whose `auto?` flag is set;
    # downstream code treats it as "unresolved, fill me in". Stash
    # the keyword token so the fix emitter can replace this exact
    # span with the resolved type's source form.
    if match?(:KEYWORD, 'Auto')
      auto_tok = consume(:KEYWORD, 'Auto')
      t = Type.new(:Auto, auto: true)
      t.auto_token = auto_tok
      return t
    end

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

    if match?(:KEYWORD, 'Auto')
      prefix_chars = "#{tense_prefix}#{error_prefix}#{optional_prefix}"
      error!(current, :AUTO_PREFIX_NOT_SUPPORTED, prefix: prefix_chars, prefix2: prefix_chars, prefix3: prefix_chars, prefix4: prefix_chars)
    end

    base = T.must(consume(:TYPE_ID)).value
    inner = ""

    # Generic type arguments: Pair<Number> or Map<String, Number>.
    # Type arguments are full type annotations, so Cache<Box @shared:locked>
    # preserves the synchronization family as part of T.
    # In type-annotation context, '<' is always a generic argument list, never a comparison.
    if match?(:CHAR, '<')
      consume(:CHAR, '<')
      type_args = []
      until match?(:CHAR, '>')
        type_args << type_annotation_source(T.must(parse_type_annotation))
        match!(:CHAR, ',')
      end
      consume(:CHAR, '>')
      base = "#{base}<#{type_args.join(',')}>"
    end

    # Element-level capability: T@shared[] means Array<Arc<T>>.
    # Parsed BEFORE the [] suffix so it attaches to the element type, not the collection.
    # Also handles T@shared:locked[] (Arc<Mutex<T>>[]).
    elem_caps = parse_element_capability
    elem_ownership = elem_caps[:ownership]
    elem_sync = elem_caps[:sync]

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
        error!(current, :ARRAY_TYPE_BAD)
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
          error!(current, :ARRAY_TYPE_EXPECTED_SIZE)
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
    observable  = caps&.dig(:observable) || false
    observable_token = caps&.dig(:observable_token)


    base_sym = "#{tense_prefix}#{error_prefix}#{optional_prefix}#{base}#{inner}".to_sym

    loc = is_indirect ? :heap : nil
    layout = is_indirect ? :indirect : nil
    # Mirror CapabilityWrap's auto-promotion so @indirect:atomic has the same
    # ownership whether it appears in an expression or a type annotation.
    if sync == :atomic && layout == :indirect && ownership.nil?
      ownership = :shared
    end
    t = Type.new(base_sym, ownership: ownership, sync: sync, layout: layout, location: loc, collection: collection, shard_count: shard_count, observable: observable)
    t.soa = true if is_soa
    t.elem_ownership = elem_ownership if elem_ownership
    t.elem_sync = elem_sync if elem_sync
    t.observable_token = observable_token if observable_token
    t
  end

  sig { params(type: Type).returns(Type) }
  def mark_polymorphic_shared_type(type)
    t = Type.new(type)
    t.ownership = :shared
    t.polymorphic_shared = true
    t
  end

  sig { params(type: Type).returns(String) }
  def type_annotation_source(type)
    t = type.is_a?(Type) ? type : Type.new(type)
    return "SHARED #{type_annotation_source(Type.new(t).tap { |inner| inner.ownership = :affine; inner.polymorphic_shared = false })}" if t.polymorphic_shared?

    parts = [t.resolved.to_s]

    ownership = case t.ownership
    when :shared then "@shared"
    when :multiowned then "@multiowned"
    when :link then "@link"
    when :split then "@split"
    when :frozen then "@frozen"
    end
    parts << ownership if ownership

    sync = case t.sync
    when :locked then "@locked"
    when :write_locked then "@writeLocked"
    when :versioned then "@versioned"
    when :atomic then "@atomic"
    when :local then "@local"
    when :always_mutable then "@alwaysMutable"
    end
    parts << sync if sync

    parts.join("")
  end

  # Parses `CONCURRENT(workers: N)? SELECT|WHERE|EACH ...`
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
        options[T.must(key_tok).value] = val
        break unless match?(:CHAR, ',')
        consume(:CHAR, ',')
      end
      consume(:CHAR, ')')
    end
    inner_op = parse_concurrent_inner_op(T.must(token))
    AST::ConcurrentOp.new(token, inner_op, options)
  end

  sig { params(parent_token: Lexer::Token).returns(T.untyped) }
  def parse_concurrent_inner_op(parent_token)
    if match?(:KEYWORD, 'SELECT')
      consume(:KEYWORD, 'SELECT')
      expr = parse_expression(1)  # stop before |> for chaining
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
      error!(current, :CONCURRENT_BAD_OP, got: current.value.inspect)
    end
  end

  # Parses `EACH { stmts... }` — side-effect block over a collection.
  # `_` is the implicit item binding inside the body.
  sig { returns(AST::EachOp) }
  def parse_each_op
    token = consume(:KEYWORD, 'EACH')
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')
    AST::EachOp.new(token, body)
  end

  sig { returns(AST::TapOp) }
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

  # All recognized capability tokens.
  ELEMENT_CAPABILITY_TOKENS = %w[@shared @multiowned @locked @writeLocked @link].freeze
  ELEMENT_SYNC_TOKENS = %w[@locked @writeLocked locked writeLocked].freeze
  CAPABILITY_TOKENS = %w[@multiowned @shared @split @locked @writeLocked @local @versioned @atomic @indirect @link @raw @symbol @list @pool @set @soa @sharded @observable].freeze

  # Unified capability parser. Parses an optional @cap or @cap:chain sequence.
  # Returns nil if no capability token is present, or a Hash:
  #   { ownership:, sync:, collection:, is_soa:, is_indirect:, shard_count: }
  # No semantic validation — just token consumption and duplicate detection.
  sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def parse_capabilities
    return nil unless match?(:VAR_ID) && CAPABILITY_TOKENS.include?(current.value)

    result = { ownership: nil, sync: nil, collection: nil, is_soa: false, is_indirect: false, shard_count: nil, observable: false }
    apply_capability!(result, T.must(consume(:VAR_ID)))

    # ':' chaining (e.g., @shared:locked, @soa:shared:locked, @list:soa)
    parse_capability_chain!(result)

    result
  end

  private

  sig { params(type_token: Lexer::Token, constructor_name: String).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def parse_constructor_capabilities(type_token, constructor_name)
    return nil unless (match?(:VAR_ID) && CAPABILITY_TOKENS.include?(current.value)) || match?(:CHAR, ':')

    result = { ownership: nil, sync: nil, collection: nil, is_soa: false, is_indirect: false, shard_count: nil, observable: false }
    allowed = ["@soa", "@sharded"]
    cap_tok = Lexer::Token.new(:VAR_ID, "@#{constructor_name.downcase}", type_token.line, type_token.column)

    if match?(:VAR_ID)
      tok = T.must(consume(:VAR_ID))
      normalized = tok.value.start_with?("@") ? tok.value : "@#{tok.value}"
      unless allowed.include?(normalized)
        error!(tok, :CAP_BAD_MODIFIER, cap: cap_tok.value, modifier: tok.value)
      end
      apply_capability!(result, tok, normalized)
    end

    parse_capability_chain!(result, allowed_values: allowed, cap_tok: cap_tok)
    result
  end

  sig do
    params(
      result: T::Hash[T.untyped, T.untyped],
      allowed_values: T.nilable(T::Array[String]),
      cap_tok: T.nilable(Lexer::Token)
    ).void
  end
  def parse_capability_chain!(result, allowed_values: nil, cap_tok: nil)
    while match?(:CHAR, ':')
      consume(:CHAR, ':')
      error!(current, :EXPECTED_CAP_AFTER_COLON) unless current.type == :VAR_ID

      tok = T.must(consume(:VAR_ID))
      normalized_value = tok.value.start_with?('@') ? tok.value : "@#{tok.value}"
      if allowed_values && !allowed_values.include?(normalized_value)
        error!(tok, :CAP_BAD_MODIFIER, cap: cap_tok&.value || "capability", modifier: tok.value)
      end
      apply_capability!(result, tok, normalized_value)
    end
  end

  sig { returns(T::Hash[Symbol, T.untyped]) }
  def parse_element_capability
    result = { ownership: nil, sync: nil }
    return result unless match?(:VAR_ID) && ELEMENT_CAPABILITY_TOKENS.include?(current.value)
    return result unless element_capability_suffix?

    apply_element_capability!(result, T.must(consume(:VAR_ID)).value)
    if match?(:CHAR, ':')
      consume(:CHAR, ':')
      apply_element_capability!(result, T.must(consume(:VAR_ID)).value)
    end
    result
  end

  sig { returns(T::Boolean) }
  def element_capability_suffix?
    next_tok = peek_at(1)
    return true if token_char?(next_tok, '[')
    return false unless token_char?(next_tok, ':')

    sync_tok = peek_at(2)
    token_var?(sync_tok) && ELEMENT_SYNC_TOKENS.include?(sync_tok.value) && token_char?(peek_at(3), '[')
  end

  sig { params(result: T::Hash[Symbol, T.untyped], value: String).void }
  def apply_element_capability!(result, value)
    case value
    when "@shared"
      result[:ownership] = :shared
    when "@multiowned"
      result[:ownership] = :multiowned
    when "@locked", "locked"
      result[:sync] = :locked
    when "@writeLocked", "writeLocked"
      result[:sync] = :write_locked
    when "@link"
      result[:ownership] = :link
    end
  end

  sig { params(token: T.nilable(Lexer::Token), value: String).returns(T::Boolean) }
  def token_char?(token, value)
    return false unless token

    token.type == :CHAR && token.value == value
  end

  sig { params(token: T.nilable(Lexer::Token)).returns(T::Boolean) }
  def token_var?(token)
    token&.type == :VAR_ID
  end

  # Apply a single capability token to the result hash. Detects duplicates.
  sig { params(result: T::Hash[Symbol, T.untyped], token: Lexer::Token, value: String).returns(T.untyped) }
  def apply_capability!(result, token, value = token.value)
    case value
    when "@multiowned"
      error!(token, :DUPLICATE_OWNERSHIP_CAP) if result[:ownership]
      result[:ownership] = :multiowned
    when "@shared"
      error!(token, :DUPLICATE_OWNERSHIP_CAP) if result[:ownership]
      result[:ownership] = :shared
    when "@split"
      error!(token, :DUPLICATE_OWNERSHIP_CAP) if result[:ownership]
      result[:ownership] = :split
    when "@link"
      error!(token, :DUPLICATE_OWNERSHIP_CAP) if result[:ownership]
      result[:ownership] = :link
    when "@locked"
      error!(token, :DUPLICATE_SYNC_CAP) if result[:sync]
      result[:sync] = :locked
    when "@writeLocked"
      error!(token, :DUPLICATE_SYNC_CAP) if result[:sync]
      result[:sync] = :write_locked
    when "@local"
      error!(token, :DUPLICATE_SYNC_CAP) if result[:sync]
      result[:sync] = :local
    when "@versioned"
      error!(token, :DUPLICATE_SYNC_CAP) if result[:sync]
      result[:sync] = :versioned
    when "@atomic"
      error!(token, :DUPLICATE_SYNC_CAP) if result[:sync]
      result[:sync] = :atomic
    when "@raw"
      error!(token, :DUPLICATE_SYNC_CAP) if result[:sync]
      result[:sync] = :raw
    when "@symbol"
      error!(token, :DUPLICATE_SYNC_CAP) if result[:sync]
      result[:sync] = :symbol
    when "@indirect"
      error!(token, :DUPLICATE_LAYOUT_CAP) if result[:is_indirect]
      result[:is_indirect] = true
    when "@soa"
      error!(token, :DUPLICATE_SOA_CAP) if result[:is_soa]
      result[:is_soa] = true
    when "@list"
      error!(token, :DUPLICATE_COLLECTION_CAP) if result[:collection]
      result[:collection] = :list
    when "@pool"
      error!(token, :DUPLICATE_COLLECTION_CAP) if result[:collection]
      result[:collection] = :pool
    when "@set"
      error!(token, :DUPLICATE_COLLECTION_CAP) if result[:collection]
      result[:collection] = :set
    when "@sharded"
      error!(token, :DUPLICATE_SHARD_COUNT_CAP) if result[:shard_count]
      consume(:CHAR, '(')
      count_tok = consume_number
      count = count_tok.value.to_i
      error!(count_tok, :SHARDED_TOO_FEW, count: count) if count < 2
      result[:shard_count] = count
      consume(:CHAR, ')')
    when "@observable"
      error!(token, :DUPLICATE_OBSERVABLE_CAP) if result[:observable]
      result[:observable] = true
      # Keep the token span so fixable errors can delete the source capability.
      result[:observable_token] = token
    else
      emit_typo_suggestion!(
        token, value, CAPABILITY_TOKENS,
        "Unknown capability modifier '#{value}'",
        "closest capability",
        category: :capability, cascade: true
      )
    end
  end

  public

  # parse_striped_modifier! removed — striped is now :sharded(N) @locked composition

  sig { returns(T.nilable(AST::WithBlock)) }
  def parse_with_capability
    with_token = consume(:KEYWORD, 'WITH')

    # VIEW forms are routed before the generic capability-list parser so they
    # don't participate in the comma-separated capability grammar.
    if match?(:KEYWORD, 'VIEW') || match?(:KEYWORD, 'MATERIALIZED')
      return parse_view_block(T.must(with_token))
    end

    # SNAPSHOT requires its own list shape, with each cell prefixed by SNAPSHOT.
    if match?(:KEYWORD, 'SNAPSHOT')
      return parse_snapshot_block(T.must(with_token))
    end

    # POLYMORPHIC marks a binding whose admissible sync family set has more
    # than one member; the annotator enforces that it matches REQUIRES.
    polymorphic = false
    if match?(:KEYWORD, 'POLYMORPHIC')
      consume(:KEYWORD, 'POLYMORPHIC')
      polymorphic = true
    end

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

    # `WITH RESTRIKT x { ... }` — a typo of an UPPERCASE capability
    # keyword tokenizes as TYPE_ID and the loop below would silently
    # exit the capability list, then fail at the `{` body. Catch this
    # shape early and offer a typo suggestion against the known
    # capability keyword set.
    if match?(:TYPE_ID)
      typo_tok = current
      emit_typo_suggestion!(
        typo_tok, typo_tok.value, AST::CAPABILITIES.map(&:to_s),
        "Unknown WITH capability '#{typo_tok.value}'",
        "closest WITH capability",
        category: :capability, cascade: true
      )
    end

    while match?(:KEYWORD) || match?(:VAR_ID) do
      capability = if match?(:KEYWORD) && current.value != 'AS'
        cap_tok = consume(:KEYWORD)
        cap = T.must(cap_tok).value.to_sym
        unless AST::CAPABILITIES.include?(cap)
          emit_typo_suggestion!(
            cap_tok, T.must(cap_tok).value, AST::CAPABILITIES.map(&:to_s),
            "Unknown WITH capability '#{cap}'",
            "closest WITH capability",
            category: :capability, cascade: true
          )
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
        alias_name = T.must(consume(:VAR_ID)).value
      end

      guard_expr = nil
      if match!(:KEYWORD, 'GUARD')
        unless alias_name
          error!(previous, :WITH_GUARD_REQUIRES_AS)
        end
        guard_expr = parse_expression
      end

      capabilities << AST::Capability.new(capability: capability, var_node: var_node, alias: alias_name, alias_mutable: alias_mutable, guard_expr: guard_expr)

      # Check for comma (continue) or opening brace (done)
      break unless match!(:CHAR, ',')
    end

    # WITH MATCH introduces per-family arms after the binding list.
    if match!(:KEYWORD, 'MATCH')
      arms = parse_with_match_arms
      consume(:KEYWORD, 'END')
      node = AST::WithBlock.new(with_token, capabilities, [])
      node.arms = arms
      node.polymorphic = polymorphic
      if escape_tok
        node.deadlock_escape = {
          kind: escape_tok.value == 'POSSIBLE_DEADLOCK' ? :deadlock : :lock_cycle,
          token: escape_tok,
        }
      end
      return node
    end

    # Parse block
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')

    node = AST::WithBlock.new(with_token, capabilities, body)
    node.lock_error_clause = parse_lock_error_clause
    node.polymorphic = polymorphic
    if escape_tok
      node.deadlock_escape = {
        kind: escape_tok.value == 'POSSIBLE_DEADLOCK' ? :deadlock : :lock_cycle,
        token: escape_tok,
      }
    end
    node
  end

  # Snapshot grammar:
  #
  #   WITH SNAPSHOT <var> AS <alias> { <body> }
  #     -- single read (immutable view).
  #
  #   WITH SNAPSHOT <var> AS MUTABLE <alias> { <body> }
  #     ON Conflict [RETRY(N) THEN] <action>
  #     -- single transaction (mutable view).
  #
  #   WITH SNAPSHOT a AS [MUTABLE] va, SNAPSHOT b AS [MUTABLE] vb
  #     [, ...]
  #   { <body> } [ON Conflict ...]
  #     -- multi-cell. Mixed read + mutable. ON Conflict required if
  #     any AS MUTABLE; the runtime sorts cell pointers by address
  #     (no deadlock) and commits via `Shared.updateMulti`.
  #
  # The annotator enforces ON Conflict presence when any cell is MUTABLE.
  sig { params(with_token: Lexer::Token).returns(T.nilable(AST::WithBlock)) }
  def parse_snapshot_block(with_token)
    capabilities = []
    any_mutable = T.let(false, T::Boolean)
    loop do
      snapshot_tok = consume(:KEYWORD, 'SNAPSHOT')
      var_node = parse_var_id
      consume(:KEYWORD, 'AS')
      alias_mutable = false
      alias_mutable = true if match!(:KEYWORD, 'MUTABLE')
      alias_name = T.must(consume(:VAR_ID)).value

      capabilities << AST::Capability.new(
        capability: :SNAPSHOT,
        var_node: var_node,
        alias: alias_name,
        alias_mutable: alias_mutable,
        snapshot_token: snapshot_tok,
      )
      any_mutable ||= alias_mutable

      break unless match!(:CHAR, ',')
    end

    # VERSIONED and ATOMIC snapshot surfaces differ on conflict handling, so
    # MATCH arms let the user choose per family.
    if match!(:KEYWORD, 'MATCH')
      arms = parse_with_match_arms
      consume(:KEYWORD, 'END')
      node = AST::WithBlock.new(with_token, capabilities, [])
      node.arms = arms
      node.snapshot_mode = any_mutable ? :transaction : :read
      return node
    end

    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')

    # Optional `ON Conflict ...` handler. Reuses the same generic
    # `parse_lock_error_clause` path so `RETRY(N) THEN` and the
    # action-list grammar match exactly. Conflict is registered as
    # a type in `error_registry.rb`, so the bare TYPE_ID selector
    # path accepts it without further changes.
    clause = parse_lock_error_clause

    node = AST::WithBlock.new(with_token, capabilities, body)
    node.snapshot_mode = any_mutable ? :transaction : :read
    node.lock_error_clause = clause
    node
  end

  # View grammar:
  #
  #   WITH VIEW <var> AS <alias> { <body> } [END]
  #   WITH MATERIALIZED VIEW <var> AS <alias> { <body> } [END]
  #
  # Builds an AST::WithBlock with view_kind = :view / :materialized_view
  # and a single capability entry { capability: :VIEW | :MATERIALIZED_VIEW,
  # var_node:, alias: }. The optional END after `}` is consumed if present.
  sig { params(with_token: Lexer::Token).returns(AST::WithBlock) }
  def parse_view_block(with_token)
    view_kind = nil
    view_token = nil
    if match?(:KEYWORD, 'MATERIALIZED')
      mat_tok = consume(:KEYWORD, 'MATERIALIZED')
      view_token = consume(:KEYWORD, 'VIEW')
      view_kind = :materialized_view
      capability = :MATERIALIZED_VIEW
      view_token = mat_tok # span starts at MATERIALIZED
    else
      view_token = consume(:KEYWORD, 'VIEW')
      view_kind = :view
      capability = :VIEW
    end

    var_node = parse_var_id
    consume(:KEYWORD, 'AS')
    alias_name = T.must(consume(:VAR_ID)).value

    # Optional ARROW for the WITH ... AS s -> ... shape used in docs.
    # The brace form `{ body }` is canonical; the arrow form is sugar.
    if match!(:ARROW, '->')
      body = parse_block_body(['END'])
      consume(:KEYWORD, 'END')
    else
      consume(:CHAR, '{')
      body = parse_block_body(['}'])
      consume(:CHAR, '}')
    end

    # `view_token` lets fixable errors replace VIEW with MATERIALIZED VIEW
    # using the exact source span.
    node = AST::WithBlock.new(with_token, [AST::Capability.new(
      capability: capability,
      var_node: var_node,
      alias: alias_name,
      alias_mutable: false,
      view_token: view_token,
    )], body)
    node.view_kind = view_kind
    node
  end

  # Parse one or more WHEN arms. Grammar:
  #
  #   WHEN <FAMILY>
  #       '->' '{' <body> '}'
  #       [ ON <selectors> <action> | RETRY '(' N ')' THEN <action> ]*
  #
  # Returns an array of arm hashes. The terminating END is consumed by
  # the caller.
  sig { returns(T.nilable(T::Array[T.untyped])) }
  def parse_with_match_arms
    arms = []
    while match?(:KEYWORD, 'WHEN')
      when_tok = consume(:KEYWORD, 'WHEN')
      family = parse_requires_family
      consume(:ARROW, '->')
      consume(:CHAR, '{')
      body = parse_block_body(['}'])
      consume(:CHAR, '}')

      # Per-arm ON / RETRY clauses, zero or more.
      lock_error_clauses = []
      while match?(:KEYWORD, 'ON') || match?(:KEYWORD, 'RETRY')
        clause = parse_lock_error_clause
        lock_error_clauses << clause if clause
      end

      arms << { family: family, body: body, lock_error_clauses: lock_error_clauses, token: when_tok }
    end

    if arms.empty?
      error!(current, :WITH_MATCH_NO_WHEN)
    end

    arms
  end

  # Top-level SYNC POLICY uses the same handler grammar as per-WITH ON clauses.
  # The annotator enforces single-instance, main-file-only, and required
  # handler coverage.
  sig { returns(T.nilable(AST::SyncPolicyDecl)) }
  def parse_sync_policy_block
    sync_tok = consume(:KEYWORD, 'SYNC')
    consume(:KEYWORD, 'POLICY')
    consume(:KEYWORD, 'START')

    handlers = []
    while match?(:KEYWORD, 'ON') || match?(:KEYWORD, 'RETRY')
      clause = parse_lock_error_clause
      handlers << clause if clause
    end

    if handlers.empty?
      error!(current, :SYNC_POLICY_NO_HANDLER)
    end

    consume(:KEYWORD, 'END')
    AST::SyncPolicyDecl.new(sync_tok, handlers)
  end

  # Parse an optional error-handling clause following a WITH block's `}`:
  #   ON <selectors> [RETRY(N) THEN] <action>
  #   RETRY(N) THEN <action>                  -- sugar for ON Transient
  # Returns a Hash { selectors:, kinds:, types:, action:, retries:, ... } or nil.
  # Selector validation (existence, retry-is-Transient) runs in the annotator.
  sig { returns(T.nilable(T::Hash[Symbol, T::Array[T.untyped]])) }
  def parse_lock_error_clause
    if match?(:KEYWORD, 'ON')
      consume(:KEYWORD, 'ON')
      selectors = parse_error_selectors
      retries = match_optional_retry!
      action = parse_lock_action
      T.must(action).merge(selectors: selectors, retries: retries)
    elsif match?(:KEYWORD, 'RETRY')
      retries = match_optional_retry!
      action = parse_lock_action
      # Sugar: `RETRY(N) THEN <action>` == `ON Transient RETRY(N) THEN <action>`.
      T.must(action).merge(selectors: [{ form: :kind, name: :Transient, token: T.must(action)[:token] }],
                   retries: retries)
    else
      nil
    end
  end

  # Consume `RETRY '(' N ')' THEN` if present. Returns the N or nil.
  sig { returns(T.nilable(Integer)) }
  def match_optional_retry!
    return nil unless match!(:KEYWORD, 'RETRY')
    consume(:CHAR, '(')
    tok = consume_number
    n = tok.value.to_i
    error!(tok, :RETRY_N_NONPOSITIVE, got: n) if n <= 0
    consume(:CHAR, ')')
    consume(:KEYWORD, 'THEN')
    n
  end

  # Parse comma-separated error selectors. Each is a bare TYPE_ID. A
  # TYPE_ID matching one of the 6 reserved kind names is a kind
  # selector; anything else is a type selector. Types are enum values
  # (no `:` prefix) per the unified error-system design; the 6 kind
  # names are effectively reserved.
  sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def parse_error_selectors
    selectors = [parse_error_selector]
    while match!(:CHAR, ',')
      selectors << parse_error_selector
    end
    selectors
  end

  sig { returns(T::Hash[T.untyped, T.untyped]) }
  def parse_error_selector
    unless match?(:TYPE_ID)
      error!(current, :EXPECTED_ERROR_SELECTOR)
    end
    tok = consume(:TYPE_ID)
    form = ERROR_KINDS.include?(T.must(tok).value) ? :kind : :type
    { form: form, name: T.must(tok).value.to_sym, token: tok }
  end

  # Parse a single error-handler action: RAISE | PASS | RETURN expr | EXIT "msg" | -> { stmts }.
  sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def parse_lock_action
    if match!(:KEYWORD, 'RAISE')
      { action: :raise, token: previous }
    elsif match!(:KEYWORD, 'PASS')
      { action: :pass, token: previous }
    elsif match!(:KEYWORD, 'RETURN')
      tok = previous
      value = parse_expression
      { action: :return, value: value, token: tok }
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
      error!(current, :EXPECTED_AFTER_ERROR_CLAUSE)
    end
  end

  # Parses an optional `:@cap` continuation after an expression-level capability sigil.
  # `tok` is the already-consumed first sigil token; `first_attrs` is its CAP_SIGIL_ATTRS entry.
  # Returns [ownership, sync] — either field may be nil.
  # Handles order-independent joins: @shared:locked and @locked:shared both work.
  # Parses a capability chain: @a:b:c (order-independent, max one per dimension).
  # Returns [ownership, sync, layout].
  sig { params(tok: Lexer::Token, first_attrs: T::Hash[Symbol, Symbol]).returns(T.nilable(T::Array[T.untyped])) }
  def parse_cap_join(tok, first_attrs)
    dims = { ownership: nil, sync: nil, layout: nil, lock_rank: nil }
    apply_cap_dim!(tok, first_attrs, dims)
    parse_lock_rank_arg!(tok, first_attrs, dims)

    while match?(:CHAR, ':')
      consume(:CHAR, ':')
      unless current.type == :VAR_ID
        error!(current, :EXPECTED_CAP_SIGIL_AFTER_COLON)
      end
      normalized = current.value.start_with?('@') ? current.value : "@#{current.value}"
      attrs = CAP_SIGIL_ATTRS[normalized]
      unless attrs
        # Chain form `@shared:foo` arrives without the `@`; root form
        # arrives with it. Match the candidate-set shape to whichever
        # form the user typed so the replacement slots in cleanly.
        has_at = current.value.start_with?('@')
        candidates = has_at ? CAP_SIGIL_ATTRS.keys : CAP_SIGIL_ATTRS.keys.map { |k| k.sub(/^@/, '') }
        emit_typo_suggestion!(
          current, current.value, candidates,
          "Unknown capability sigil '#{current.value}'",
          "closest capability sigil",
          category: :capability, cascade: true
        )
      end
      next_tok = consume(:VAR_ID)
      apply_cap_dim!(T.must(next_tok), attrs, dims)
      parse_lock_rank_arg!(T.must(next_tok), attrs, dims)
    end

    # Reject T @cap1 @cap2 (must use : join, e.g. @shared:locked)
    if match?(:VAR_ID) && current.value.start_with?('@') && CAP_SIGIL_ATTRS.key?(current.value)
      error!(current, :MIXED_AT_CAPABILITIES)
    end

    [dims[:ownership], dims[:sync], dims[:layout], dims[:lock_rank]]
  end

  sig { params(tok: Lexer::Token, attrs: T::Hash[Symbol, Symbol], dims: T::Hash[Symbol, T.nilable(Symbol)]).returns(T.nilable(Symbol)) }
  def apply_cap_dim!(tok, attrs, dims)
    dim = attrs[:dim]
    if dims[T.must(dim)]
      error!(tok, :DUPLICATE_CAPABILITY_DIM, dim: dim, current: dims[T.must(dim)], attempted: attrs[:val])
    end
    dims[T.must(dim)] = attrs[:val]
  end

  # Parse an optional `(rank: N)` argument after @locked / @writeLocked.
  # The N is an integer; sign and magnitude are free. Duplicate rank on
  # the same capability chain is an error.
  sig { params(sigil_tok: Lexer::Token, attrs: T::Hash[Symbol, Symbol], dims: T::Hash[Symbol, T.nilable(Symbol)]).returns(T.nilable(Integer)) }
  def parse_lock_rank_arg!(sigil_tok, attrs, dims)
    return unless attrs[:dim] == :sync
    return unless attrs[:val] == :locked || attrs[:val] == :write_locked
    return unless match?(:CHAR, '(')
    consume(:CHAR, '(')
    unless match?(:VAR_ID, 'rank')
      error!(current, :EXPECTED_RANK_KEYWORD, sigil: attrs[:val])
    end
    consume(:VAR_ID, 'rank')
    consume(:CHAR, ':')
    neg = match!(:CHAR, '-')
    num_tok = consume_number
    rank = num_tok.value.to_i
    rank = -rank if neg
    consume(:CHAR, ')')
    if dims[:lock_rank]
      error!(sigil_tok, :DUPLICATE_LOCK_RANK, current: dims[:lock_rank], attempted: rank)
    end
    dims[:lock_rank] = rank
  end

  # Branch-prefix sigils for DO blocks.
  # Each maps to the attribute(s) it sets on the branch hash.
  # After `:` the next word is also looked up here (with `@` prepended if absent).
  DO_BRANCH_SIGILS = T.let({
    '@micro'    => { stack_size: :micro    },
    '@stack'    => { stack_size: :stack    },
    '@standard' => { stack_size: :standard },
    '@large'    => { stack_size: :large    },
    '@xl'       => { stack_size: :xl       },
    '@service'  => { stack_size: :service  },
    '@pinned'   => { pinned: true          },
    '@parallel' => { parallel: true        },
    '@canSmash' => { can_smash: true       },
  }.freeze, T::Hash[T.untyped, T.untyped])

  # Sigils valid at the start of a BG body (stack size + pinned).
  BG_SIGILS = T.let({
    '@micro'    => { stack_size: :micro    },
    '@stack'    => { stack_size: :stack    },
    '@standard' => { stack_size: :standard },
    '@large'    => { stack_size: :large    },
    '@xl'       => { stack_size: :xl       },
    '@service'  => { stack_size: :service  },
    '@pinned'   => { pinned: true          },
    '@parallel' => { parallel: true        },
    '@arena'    => { pinned: true, arena: true },
    '@canSmash' => { can_smash: true       },
  }.freeze, T::Hash[T.untyped, T.untyped])

  # Parses an optional `@size_sigil(:cap_sigil)* ->` prefix from a DO branch.
  # Returns { pinned: Bool, stack_size: Symbol|nil }.
  # Only enters the prefix parser when the first token is a known DO branch sigil.
  # After `:`, the next identifier is normalised (@ prepended if absent).
  sig { returns(T.nilable(T::Hash[Symbol, T.nilable(FalseClass)])) }
  def parse_branch_prefix
    pinned     = T.let(false, T::Boolean)
    parallel   = T.let(false, T::Boolean)
    can_smash  = T.let(false, T::Boolean)
    stack_size = T.let(nil, T.untyped)

    # Enter the loop on a known sigil OR on a `@<typo>` token that the
    # user clearly intended as a sigil (so the typo path can fire).
    looks_like_sigil = current.type == :VAR_ID && current.value.start_with?('@')
    return { pinned: pinned, parallel: parallel, stack_size: stack_size, can_smash: can_smash } unless
      looks_like_sigil

    loop do
      tok      = consume(:VAR_ID)
      cap_name = T.must(tok).value.start_with?('@') ? T.must(tok).value : "@#{T.must(tok).value}"
      attrs    = DO_BRANCH_SIGILS[cap_name]
      unless attrs
        has_at = T.must(tok).value.start_with?('@')
        candidates = has_at ? DO_BRANCH_SIGILS.keys : DO_BRANCH_SIGILS.keys.map { |k| k.sub(/^@/, '') }
        emit_typo_suggestion!(
          tok, T.must(tok).value, candidates,
          "Unknown branch prefix #{T.must(tok).value.inspect}",
          "closest DO branch sigil",
          category: :type, cascade: true
        )
      end

      if attrs[:stack_size]
        error!(tok, :DUPLICATE_STACK_SIZE, kind: "branch") if stack_size
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

  sig { returns(T.nilable(AST::DoBlock)) }
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
      branches << { body: [stmt].compact, pinned: T.must(prefix)[:pinned], parallel: T.must(prefix)[:parallel], stack_size: T.must(prefix)[:stack_size], can_smash: T.must(prefix)[:can_smash] }
      break unless match!(:CHAR, ',')
    end

    consume(:CHAR, '}')
    AST::DoBlock.new(do_token, branches)
  end

  # Parses an optional `@size_sigil ->` prefix at the very start of a BG body.
  # Returns { ..., stack_size_token: } where stack_size_token is the
  # token of the FIRST sigil that contributed a stack_size (or nil).
  sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
  def parse_bg_prefix
    pinned     = T.let(false, T::Boolean)
    parallel   = T.let(false, T::Boolean)
    arena      = T.let(false, T::Boolean)
    can_smash  = T.let(false, T::Boolean)
    stack_size = T.let(nil, T.untyped)
    stack_size_token = T.let(nil, T.untyped)
    can_smash_token  = T.let(nil, T.untyped)

    # Enter the loop on a known sigil OR on `@<typo>` that the user
    # clearly intended as a BG sigil (so the typo path can fire).
    looks_like_sigil = current.type == :VAR_ID && current.value.start_with?('@')
    return { pinned: pinned, parallel: parallel, stack_size: stack_size, arena: arena, can_smash: can_smash, stack_size_token: nil, can_smash_token: nil } unless
      looks_like_sigil

    loop do
      tok      = consume(:VAR_ID)
      cap_name = T.must(tok).value.start_with?('@') ? T.must(tok).value : "@#{T.must(tok).value}"
      attrs    = BG_SIGILS[cap_name]
      unless attrs
        has_at = T.must(tok).value.start_with?('@')
        candidates = has_at ? BG_SIGILS.keys : BG_SIGILS.keys.map { |k| k.sub(/^@/, '') }
        emit_typo_suggestion!(
          tok, T.must(tok).value, candidates,
          "Unknown BG prefix #{T.must(tok).value.inspect}",
          "closest BG body sigil",
          category: :type, cascade: true
        )
      end

      if attrs[:stack_size]
        error!(tok, :DUPLICATE_STACK_SIZE, kind: "BG") if stack_size
        stack_size = attrs[:stack_size]
        stack_size_token = tok
      end
      pinned    = true if attrs[:pinned]
      parallel  = true if attrs[:parallel]
      arena     = true if attrs[:arena]
      if attrs[:can_smash]
        can_smash = true
        can_smash_token = tok
      end

      # More sigils chained with ':'?
      break unless match?(:CHAR, ':')
      consume(:CHAR, ':')
    end

    consume(:ARROW, '->')
    { pinned: pinned, parallel: parallel, stack_size: stack_size, arena: arena, can_smash: can_smash, stack_size_token: stack_size_token, can_smash_token: can_smash_token }
  end

  sig { returns(T.untyped) }
  def parse_bg_block
    bg_token = consume(:KEYWORD, 'BG')
    if match?(:KEYWORD, 'STREAM')
      return parse_bg_stream_block(T.must(bg_token))
    end
    open_brace = consume(:CHAR, '{')
    prefix = parse_bg_prefix
    body = parse_bg_then_body
    consume(:CHAR, '}')
    node = AST::BgBlock.new(bg_token, body, nil, T.must(prefix)[:stack_size], T.must(prefix)[:pinned], T.must(prefix)[:parallel], T.must(prefix)[:arena], T.must(prefix)[:can_smash])
    node.open_brace_token = open_brace
    node.prefix_token = T.must(prefix)[:stack_size_token]
    node.can_smash_token = T.must(prefix)[:can_smash_token]
    node
  end

  # Custom body parser for BG blocks that recognises THEN chains.
  sig { returns(T.nilable(T::Array[T.untyped])) }
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
  sig { returns(T.untyped) }
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
        binding_name = T.must(consume(:VAR_ID)).value
      end

      unless match?(:KEYWORD, 'THEN')
        error!(current, :EXPECTED_THEN_AFTER_AS_BG, got: current.value.inspect)
      end

      steps = [{ expr: expr, binding: binding_name }]
      while match?(:KEYWORD, 'THEN')
        consume(:KEYWORD, 'THEN')
        next_expr = parse_expression
        next_binding = nil
        if match?(:KEYWORD, 'AS')
          consume(:KEYWORD, 'AS')
          next_binding = T.must(consume(:VAR_ID)).value
        end
        steps << { expr: next_expr, binding: next_binding }
      end
      match!(:CHAR, ';')
      return AST::ThenChain.new(steps.first[:expr].token, steps)
    end

    consume(:CHAR, ';')
    expr
  end

  sig { params(bg_token: Lexer::Token).returns(AST::BgStreamBlock) }
  def parse_bg_stream_block(bg_token)
    consume(:KEYWORD, 'STREAM')
    consume(:CHAR, '{')
    body = parse_block_body(['}'])
    consume(:CHAR, '}')
    AST::BgStreamBlock.new(bg_token, body, nil)
  end

  sig { returns(AST::YieldExpr) }
  def parse_yield_expr
    tok = consume(:KEYWORD, 'YIELD')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::YieldExpr.new(tok, expr)
  end

  sig { returns(AST::NextExpr) }
  def parse_next_expr
    tok = consume(:KEYWORD, 'NEXT')
    expr = parse_expression
    AST::NextExpr.new(tok, expr)
  end

  sig { params(type: Symbol, open: T.nilable(String), close: T.nilable(String), blk: T.proc.returns(T.untyped)).returns(T.untyped) }
  def parse_comma_seq(type, open, close, &blk)
    start_token = consume(type, open)
    items = []
    until match?(:CHAR, close)
      items << blk.call
      match!(:CHAR, ',')
    end
    consume(:CHAR, close)
    [start_token, items]
  end

  # Deep-clone an AST node for compound assignment desugaring.
  # The target appears on both sides (LHS = target, RHS = target op expr),
  # so each side needs its own node to avoid double-visit issues.
  sig { params(node: T.untyped).returns(T.untyped) }
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
  sig { returns(AST::TestBlock) }
  def parse_test_block
    tok = consume(:KEYWORD, 'TEST')
    name = T.must(consume(:TYPE_ID)).value  # TestName is a TYPE_ID (capitalized)
    consume(:KEYWORD, 'DO')

    setup = []
    whens = []
    before_each = []
    after_each = []
    before_all = []
    after_all = []
    lets = []

    until match?(:KEYWORD, 'END')
      if match?(:KEYWORD, 'WHEN')
        whens << parse_when_block
      elsif test_hook_match?('BEFORE', 'EACH')
        before_each << parse_test_hook('BEFORE', 'EACH')
      elsif test_hook_match?('AFTER', 'EACH')
        after_each << parse_test_hook('AFTER', 'EACH')
      elsif test_hook_match?('BEFORE', 'ALL')
        before_all << parse_test_hook('BEFORE', 'ALL')
      elsif test_hook_match?('AFTER', 'ALL')
        after_all << parse_test_hook('AFTER', 'ALL')
      elsif match?(:KEYWORD, 'LET')
        lets << parse_let_binding
      else
        setup << parse_statement
      end
    end
    consume(:KEYWORD, 'END')

    block = AST::TestBlock.new(tok, name, setup, whens)
    block.before_each = before_each
    block.after_each = after_each
    block.before_all = before_all
    block.after_all = after_all
    block.lets = lets
    block
  end

  # `LET <name> = <expr>;` — fixture declaration. Same shape as a
  # var binding but stored on the enclosing TEST/WHEN block rather
  # than emitted in setup, so lowering can inject a fresh evaluation
  # at the top of every TEST THAT.
  sig { returns(AST::LetBinding) }
  def parse_let_binding
    tok = consume(:KEYWORD, 'LET')
    name = T.must(consume(:VAR_ID)).value
    consume(:CHAR, '=')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::LetBinding.new(tok, name, expr)
  end

  # Match `BEFORE EACH` or `AFTER EACH` as a two-keyword sequence. Used by
  # the test-block / when-block parsers; both share the same hook syntax.
  sig { params(first: String, second: String).returns(T::Boolean) }
  def test_hook_match?(first, second)
    match?(:KEYWORD, first) && @tokens[@pos + 1]&.value == second
  end

  # Parse `BEFORE EACH DO <stmts> END` (or AFTER EACH); returns the body
  # statement array. The kind sequence (BEFORE/AFTER + EACH/ALL) is
  # already validated by test_hook_match? at the call site.
  sig { params(first: String, second: String).returns(T::Array[T.untyped]) }
  def parse_test_hook(first, second)
    consume(:KEYWORD, first)
    consume(:KEYWORD, second)
    consume(:KEYWORD, 'DO')
    body = []
    until match?(:KEYWORD, 'END')
      body << parse_statement
    end
    consume(:KEYWORD, 'END')
    body
  end

  # WHEN "description" [TAGS [tag1, tag2, ...]] DO ... END
  sig { returns(AST::WhenBlock) }
  def parse_when_block
    tok = consume(:KEYWORD, 'WHEN')
    desc = T.must(consume(:STRING)).value
    tags = parse_when_tags  # [] if no TAGS clause
    consume(:KEYWORD, 'DO')

    setup = []
    tests = []
    benchmarks = []
    before_each = []
    after_each = []
    before_all = []
    after_all = []
    lets = []

    until match?(:KEYWORD, 'END')
      if match?(:KEYWORD, 'TEST') && @tokens[@pos + 1]&.value == 'THAT'
        tests << parse_test_that
      elsif match?(:KEYWORD, 'PENDING') &&
            @tokens[@pos + 1]&.value == 'TEST' &&
            @tokens[@pos + 2]&.value == 'THAT'
        # PENDING TEST THAT "..." DO ... END  — type-checked but skipped
        # at runtime via `return error.SkipZigTest;` in lowering.
        consume(:KEYWORD, 'PENDING')
        tt = parse_test_that
        tt.pending = true
        tests << tt
      elsif test_hook_match?('BEFORE', 'EACH')
        before_each << parse_test_hook('BEFORE', 'EACH')
      elsif test_hook_match?('AFTER', 'EACH')
        after_each << parse_test_hook('AFTER', 'EACH')
      elsif test_hook_match?('BEFORE', 'ALL')
        before_all << parse_test_hook('BEFORE', 'ALL')
      elsif test_hook_match?('AFTER', 'ALL')
        after_all << parse_test_hook('AFTER', 'ALL')
      elsif match?(:KEYWORD, 'LET')
        lets << parse_let_binding
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

    block = AST::WhenBlock.new(tok, desc, setup, tests, benchmarks)
    block.before_each = before_each
    block.after_each = after_each
    block.before_all = before_all
    block.after_all = after_all
    block.lets = lets
    block.tags = tags
    block
  end

  # `TAGS [tag1, tag2, ...]` — optional bracketed list of bare
  # identifiers that lower to test-name suffixes. Returns [] when the
  # clause is absent. Names are validated to be VAR_IDs (snake_case)
  # so `--tag slow` filtering can match unambiguously; allowing
  # arbitrary strings would invite typo-mismatches that pass silently.
  sig { returns(T::Array[String]) }
  def parse_when_tags
    return [] unless match!(:KEYWORD, 'TAGS')
    consume(:CHAR, '[')
    names = []
    until match?(:CHAR, ']')
      tag_tok = consume(:VAR_ID)
      names << T.must(tag_tok).value
      break unless match!(:CHAR, ',')
    end
    consume(:CHAR, ']')
    names
  end

  # TEST THAT "description" DO ... END
  sig { returns(AST::TestThat) }
  def parse_test_that
    tok = consume(:KEYWORD, 'TEST')
    consume(:KEYWORD, 'THAT')
    desc = T.must(consume(:STRING)).value
    consume(:KEYWORD, 'DO')

    body = []
    until match?(:KEYWORD, 'END')
      body << parse_statement
    end
    consume(:KEYWORD, 'END')

    AST::TestThat.new(tok, desc, body)
  end

  # ASSERT_RAISES Kind, expr;  OR  ASSERT_RAISES Kind, ErrorName, expr;
  sig { returns(AST::AssertRaises) }
  def parse_assert_raises
    tok = consume(:KEYWORD, 'ASSERT_RAISES')
    kind = T.must(consume(:TYPE_ID)).value  # e.g., Input, System, Transient

    consume(:CHAR, ',')

    # Peek: if next is TYPE_ID followed by comma, it's ASSERT_RAISES Kind, ErrorName, expr
    error_name = nil
    if current.type == :TYPE_ID && @tokens[@pos + 1]&.type == :CHAR && @tokens[@pos + 1]&.value == ','
      error_name = T.must(consume(:TYPE_ID)).value
      consume(:CHAR, ',')
    end

    expr = parse_expression
    consume(:CHAR, ';')

    AST::AssertRaises.new(tok, kind, error_name, expr)
  end

  # BENCHMARK expr x<N>;
  sig { returns(AST::BenchmarkStmt) }
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
  sig { returns(AST::SmashStmt) }
  def parse_smash_stmt
    tok = consume(:KEYWORD, 'SMASH')
    expr = parse_expression
    consume(:CHAR, ';')
    AST::SmashStmt.new(tok, expr)
  end

  # PROFILE expr;
  sig { returns(AST::ProfileStmt) }
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
  sig { returns(AST::StubDecl) }
  def parse_stub
    tok = consume(:KEYWORD, 'STUB')
    fn_name = T.must(consume(:VAR_ID)).value

    kind_tok = current
    if match?(:KEYWORD, 'RETURNS')
      consume(:KEYWORD, 'RETURNS')
      value = parse_expression
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :returns, value)
    elsif match?(:KEYWORD, 'CAPTURES')
      consume(:KEYWORD, 'CAPTURES')
      var_name = T.must(consume(:VAR_ID)).value
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :captures, var_name)
    elsif match?(:KEYWORD, 'SEQUENCE')
      consume(:KEYWORD, 'SEQUENCE')
      bracket_tok, items = parse_comma_seq(:CHAR, '[', ']') { parse_expression }
      values = AST::ListLit.new(bracket_tok, items, :stack)
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :sequence, values)
    elsif match?(:KEYWORD, 'WITH')
      consume(:KEYWORD, 'WITH')
      lambda_node = parse_expression  # should parse a lambda %(params) -> expr
      consume(:CHAR, ';')
      AST::StubDecl.new(tok, fn_name, :with, lambda_node)
    else
      error!(kind_tok, :STUB_BAD_AFTER, fn: fn_name)
    end
  end
end
