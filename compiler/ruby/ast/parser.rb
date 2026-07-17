# typed: strict
require "sorbet-runtime"

require_relative "./ast"
require_relative "./schemas"
require_relative "./type"
require_relative "./lexer"
require_relative "./parser_rules"
require_relative "./error_registry"
require_relative "./source_error"
require_relative "./fixable_error"
require_relative "./frontend_resource_budget"
require_relative "./fixable_suggestion_helper"
require_relative "./parsed_type_syntax"

# ==========================================
# PARSER
# ==========================================
class ClearParser
  extend T::Sig

  OPEN_DELIMITERS = T.let('([{'.freeze, String)
  CLOSE_DELIMITERS = T.let(')]}'.freeze, String)

  class CapabilityParseResult < T::Struct
    prop :ownership, T.nilable(Symbol), default: nil
    prop :sync, T.nilable(Symbol), default: nil
    prop :collection, T.nilable(Symbol), default: nil
    prop :is_soa, T::Boolean, default: false
    prop :is_indirect, T::Boolean, default: false
    prop :shard_count, T.nilable(Integer), default: nil
    prop :observable, T::Boolean, default: false
    prop :observable_token, T.nilable(Lexer::Token), default: nil
  end

  class TaskPrefix < T::Struct
    const :pinned, T::Boolean, default: false
    const :parallel, T::Boolean, default: false
    const :stack_size, T.nilable(Symbol), default: nil
    const :arena, T::Boolean, default: false
    const :can_smash, T::Boolean, default: false
    const :stack_size_token, T.nilable(Lexer::Token), default: nil
    const :can_smash_token, T.nilable(Lexer::Token), default: nil
  end

  class ParsedStructField < T::Struct
    const :name, String
    const :value, AST::Node
    const :name_token, Lexer::Token
  end

  class SigilAttrs < T::Struct
    const :dim, T.nilable(Symbol), default: nil
    const :val, T.nilable(Symbol), default: nil
    const :stack_size, T.nilable(Symbol), default: nil
    const :pinned, T::Boolean, default: false
    const :parallel, T::Boolean, default: false
    const :arena, T::Boolean, default: false
    const :can_smash, T::Boolean, default: false
  end

  class CapJoin < T::Struct
    prop :ownership, T.nilable(Symbol), default: nil
    prop :sync, T.nilable(Symbol), default: nil
    prop :layout, T.nilable(Symbol), default: nil
    prop :lock_rank, T.nilable(Integer), default: nil
  end

  class ElementCapability < T::Struct
    prop :ownership, T.nilable(Symbol), default: nil
    prop :sync, T.nilable(Symbol), default: nil
    prop :layout, T.nilable(Symbol), default: nil
  end

  class ParsedEffectsDecl < T::Struct
    const :kind, T.nilable(Symbol), default: nil
    const :span, T.nilable(AST::EffectSpan), default: nil
    const :max_depth, T.nilable(Integer), default: nil
    const :tight, T::Boolean, default: false
  end

  class ParsedExternEffects < T::Struct
    extend T::Sig

    prop :alloc, T.nilable(Symbol), default: nil
    prop :safe, T::Boolean, default: false

    sig { returns(T::Hash[Symbol, T.any(Symbol, TrueClass)]) }
    def to_h
      alloc_kind = alloc
      return { alloc: alloc_kind, safe: true } if alloc_kind && safe
      return { alloc: alloc_kind } if alloc_kind
      return { safe: true } if safe

      {}
    end
  end

  # A VAR_ID-led form is parsed once, then classified from the token that
  # follows it.  Keeping the classification with the node lets statement,
  # value-block, and BG parsers share the same non-replaying path.
  class ParsedVarForm < T::Struct
    const :node, AST::Node
    const :assignment, T::Boolean
  end

  class RequiresKind < T::Struct
    const :family, T.nilable(Symbol), default: nil
    const :reentrance, T.nilable(Symbol), default: nil
  end

  class ParsedRequiresClause < T::Struct
    const :capabilities, T::Hash[String, T::Set[Symbol]]
    const :reentrance, T::Hash[String, Symbol]
  end

  class ParsedMatchStart < T::Struct
    const :token, Lexer::Token
    const :subject, AST::Node
    const :takes, T::Boolean
  end

  class ParsedMatchArm < T::Struct
    const :kind, Symbol
    const :value, AST::Node
    const :extra_values, T::Array[AST::Node]
    const :binding, T.nilable(String), default: nil
    const :destructure, T.nilable(AST::StructPattern), default: nil
  end

  include ErrorHelper
  include FixableSuggestionHelper

  ArgumentType = T.type_alias { T.any(Symbol, Type) }
  ReturnLifetime = T.type_alias { T.nilable(T.any(Symbol, T::Array[AST::Node])) }
  SigilTable = T.type_alias { T::Hash[String, SigilAttrs] }
  WindowPipelineOp = T.type_alias { T.any(AST::WindowOp, AST::BatchWindowOp) }
  ConcurrentPipelineOp = T.type_alias do
    T.any(AST::SelectOp, AST::WhereOp, AST::EachOp, AST::SumOp, AST::CountOp,
          AST::MinOp, AST::MaxOp, AST::AverageOp)
  end

  @gradual_mode = T.let(false, T.nilable(T::Boolean))
  @ownership_mode = T.let(:default, T.nilable(Symbol))

  sig do
    params(
      dim: T.nilable(Symbol),
      val: T.nilable(Symbol),
      stack_size: T.nilable(Symbol),
      pinned: T::Boolean,
      parallel: T::Boolean,
      arena: T::Boolean,
      can_smash: T::Boolean,
    ).returns(SigilAttrs)
  end
  def self.sigil_attrs(dim: nil, val: nil, stack_size: nil, pinned: false, parallel: false, arena: false, can_smash: false)
    SigilAttrs.new(
      dim: dim,
      val: val,
      stack_size: stack_size,
      pinned: pinned,
      parallel: parallel,
      arena: arena,
      can_smash: can_smash,
    )
  end

  sig { override.returns(String) }
  attr_reader :source_code

  sig do
    params(
      tokens: T::Array[Lexer::Token],
      source_code: String,
      gradual: T.nilable(T::Boolean),
      budget: T.nilable(FrontendResourceBudget),
    ).void
  end
  def initialize(tokens, source_code = "", gradual: nil, budget: nil)
    @tokens = tokens
    @pos = T.let(0, Integer)
    @source_code = source_code
    @budget = T.let(budget || FrontendResourceBudget.new, FrontendResourceBudget)
    @delimiter_closings = T.let(index_delimiter_closings(tokens), T::Array[T.nilable(Integer)])
    # `gradual` controls whether omitted type annotations on
    # parameters / return types parse as implicit Auto (per
    # docs/agents/gradual-typing.md §3.3). Defaults to the global
    # ClearParser.gradual_mode flag set by the CLI; can be overridden
    # per-instance by passing the kwarg explicitly. Without gradual
    # mode, omitted annotations behave exactly as before this feature
    # landed.
    @gradual = T.let(gradual.nil? ? self.class.gradual_mode : gradual, T::Boolean)
  end

  class << self
    extend T::Sig

    # Process-global gradual-mode flag. Set by `clear --gradual` at
    # build start; read by ClearParser.new instances that don't pass an
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

    sig { returns(Symbol) }
    def ownership_mode
      @ownership_mode || :default
    end

    sig { params(value: Symbol).returns(Symbol) }
    def ownership_mode=(value)
      @ownership_mode = T.let(value, T.nilable(Symbol))
      value
    end

    # Standalone syntax-only entry point for formatter/oracle/self-host
    # comparisons. It deliberately does not expose semantic Type.
    sig { params(source: String, file: T.nilable(String)).returns(ParsedTypeSyntax) }
    def parse_type_syntax(source, file: nil)
      budget = FrontendResourceBudget.new
      tokens = Lexer.new(source, file: file, budget: budget).tokenize
      parser = new(tokens, source, budget: budget)
      parser.parse_type_syntax_document
    end
  end

  sig { returns(ParsedTypeSyntax) }
  def parse_type_syntax_document
    syntax = parse_type_annotation_syntax
    current_token = current
    unless current_token.type == :EOF
      error!(current_token, :PARSER_EXPECTED,
        expected: "end of type", got: current_token.value,
        type: current_token.type, line: current_token.line)
    end
    syntax
  end

  sig { returns(AST::Program) }
  def parse
    @budget.check_source!(@source_code)
    @budget.check_tokens!(@tokens.length)
    stmts = []
    stmts << parse_statement() while current.type != :EOF
    program = AST::Program.new(current, stmts)
    first = @tokens.first || current
    stamp_source_range!(program, first, current)
    program.language_mode = @gradual ? :easy : self.class.ownership_mode
    program
  rescue FrontendResourceBudget::Exceeded => e
    raise ParserError.new(current, "Frontend #{e.kind} resource limit exceeded (limit #{e.limit})", @source_code)
  rescue SystemStackError
    raise ParserError.new(current, "Frontend nesting resource limit exceeded", @source_code)
  end

  private

  STMT_RULES = T.let([
    rule(:KEYWORD, 'REQUIRE', action: :parse_require),
    rule(:KEYWORD, 'EXTERN', action: :parse_extern_decl),
    rule(:KEYWORD, 'MUTABLE', action: :parse_mutable_var_decl),
    rule(:KEYWORD, 'FN', action: :parse_function_def),
    rule(:KEYWORD, 'METHOD', action: :parse_method_function_def),
    rule(:KEYWORD, 'PUB', action: :parse_pub_visibility),
    rule(:KEYWORD, 'PRIVATE', action: :parse_private_visibility),
    rule(:KEYWORD, 'IF', action: :parse_if_statement),
    rule(:KEYWORD, 'COMPTIME', action: :parse_comptime_statement),
    rule(:KEYWORD, 'STRUCT', action: :parse_struct_def),
    rule(:KEYWORD, 'PROTOCOL', action: :parse_protocol_def),
    rule(:KEYWORD, 'IMPLEMENTATION', action: :parse_implementation_def),
    rule(:KEYWORD, 'ENUM', action: :parse_enum_def),
    rule(:KEYWORD, 'UNION', action: :parse_union_def),
    rule(:KEYWORD, 'WHILE', action: :parse_while_loop),
    rule(:KEYWORD, 'FOR', action: :parse_for_range),
    rule(:KEYWORD, 'TIGHT', action: :parse_tight_stmt),
    rule(:KEYWORD, 'RETURN', action: :parse_return),
    rule(:KEYWORD, 'ASSERT', action: :parse_assert),
    rule(:KEYWORD, 'ASSERT_RAISES', action: :parse_assert_raises),
    rule(:KEYWORD, 'TEST', action: :parse_test_block),
    rule(:KEYWORD, 'STUB', action: :parse_stub),
    rule(:KEYWORD, 'BENCHMARK', action: :parse_benchmark_stmt),
    rule(:KEYWORD, 'SMASH', action: :parse_smash_stmt),
    rule(:KEYWORD, 'PROFILE', action: :parse_profile_stmt),
    rule(:KEYWORD, 'RAISE', action: :parse_raise_stmt),
    rule(:KEYWORD, 'EXIT', action: :parse_exit),
    rule(:KEYWORD, 'DIE', action: :parse_die),
    rule(:KEYWORD, 'BREAK', action: :parse_break),
    rule(:KEYWORD, 'CONTINUE', action: :parse_continue),
    rule(:KEYWORD, 'WITH', action: :parse_with_capability),
    rule(:KEYWORD, 'SYNC', action: :parse_sync_policy_block),
    rule(:KEYWORD, 'DO', action: :parse_do_block),
    rule(:KEYWORD, 'BG', action: :parse_bg_block),
    rule(:KEYWORD, 'YIELD', action: :parse_yield_expr),
    rule(:KEYWORD, 'CLOSE', action: :parse_close_stream),
    rule(:KEYWORD, 'MATCH', action: :parse_match_statement),
    rule(:KEYWORD, 'PARTIAL', action: :parse_partial_match_statement),
    rule(:KEYWORD, 'PASS', action: :parse_pass_statement),
  ].freeze, T::Array[ParserRule])

  STMT_RULE_INDEX = T.let(index_rules(STMT_RULES), T::Hash[String, ParserRule])

  PRIMARY_RULES = T.let([
    rule(:KEYWORD, 'IF', action: :parse_if_expr),
    rule(:KEYWORD, 'MATCH', action: :parse_match_expr),
    rule(:KEYWORD, 'PARTIAL', action: :parse_partial_match_expr),
    rule(:NUMBER, action: :parse_stack_literal),
    rule(:INT64, action: :parse_stack_literal),
    rule(:STRING, action: :parse_stack_literal),
    rule(:CHAR, ':', action: :parse_symbol_literal),
    rule(:BYTE, action: :parse_stack_literal),
    rule(:PREFIXED_INT, action: :parse_stack_literal),
    rule(:INT8, action: :parse_stack_literal),
    rule(:INT16, action: :parse_stack_literal),
    rule(:INT32, action: :parse_stack_literal),
    rule(:UINT16, action: :parse_stack_literal),
    rule(:UINT32, action: :parse_stack_literal),
    rule(:UINT64, action: :parse_stack_literal),
    rule(:FLOAT32, action: :parse_stack_literal),
    rule(:VAR_ID, action: :parse_var_id),
    rule(:KEYWORD, 'TRUE', action: :parse_true_literal),
    rule(:KEYWORD, 'FALSE', action: :parse_false_literal),
    rule(:KEYWORD, 'NIL', action: :parse_nil_literal),
    rule(:KEYWORD, 'DEFAULT', action: :parse_default_literal),
    rule(:KEYWORD, 'CAST', action: :parse_cast),
    rule(:KEYWORD, 'MOVE', action: :parse_move_node),
    rule(:KEYWORD, 'GIVE', action: :parse_move_node),
    rule(:KEYWORD, 'COPY', action: :parse_copy_node),
    rule(:KEYWORD, 'CLONE', action: :parse_clone_node),
    rule(:KEYWORD, 'SHARE', action: :parse_share_node),
    rule(:KEYWORD, 'LINK', action: :parse_link_node),
    rule(:KEYWORD, 'RESOLVE', action: :parse_resolve_node),
    rule(:KEYWORD, 'FREEZE', action: :parse_freeze_node),
    rule(:KEYWORD, 'BG', action: :parse_bg_block),
    rule(:KEYWORD, 'NEXT', action: :parse_next_expr),
    rule(:PERCENT, '%', action: :parse_sigil_construct),
    rule(:KEYWORD, 'REQUIRE', action: :parse_require_expression),
    rule(:KEYWORD, 'SELECT', action: :parse_select_op),
    rule(:KEYWORD, 'WHERE', action: :parse_where_op),
    rule(:KEYWORD, 'INDEX', action: :parse_index_op),
    rule(:KEYWORD, 'REDUCE', action: :parse_reduce_op),
    rule(:KEYWORD, 'ORDER_BY', action: :parse_order_by_op),
    rule(:KEYWORD, 'LIMIT', action: :parse_limit_op),
    rule(:KEYWORD, 'SKIP', action: :parse_skip_op),
    rule(:KEYWORD, 'UNNEST', action: :parse_unnest_op),
    rule(:KEYWORD, 'DISTINCT', action: :parse_distinct_op),
    rule(:KEYWORD, 'EACH', action: :parse_each_op),
    rule(:KEYWORD, 'TAP', action: :parse_tap_op),
    rule(:KEYWORD, 'FIND', action: :parse_find_op),
    rule(:KEYWORD, 'ANY', action: :parse_any_op),
    rule(:KEYWORD, 'ALL', action: :parse_all_op),
    rule(:KEYWORD, 'COUNT', action: :parse_count_op),
    rule(:KEYWORD, 'SUM', action: :parse_sum_op),
    rule(:KEYWORD, 'AVERAGE', action: :parse_average_op),
    rule(:KEYWORD, 'MIN', action: :parse_min_op),
    rule(:KEYWORD, 'MAX', action: :parse_max_op),
    rule(:KEYWORD, 'TAKE_WHILE', action: :parse_take_while_op),
    rule(:KEYWORD, 'RECOVER', action: :parse_recover_op),
    rule(:KEYWORD, 'COLLECT', action: :parse_collect_op),
    rule(:KEYWORD, 'WINDOW', action: :parse_window_op),
    rule(:KEYWORD, 'JOIN', action: :parse_join_op),
    rule(:KEYWORD, 'SHARD', action: :parse_shard_op),
    rule(:KEYWORD, 'CONCURRENT', action: :parse_concurrent_op),
    rule(:CHAR, '(', action: :parse_group_expression),
  ].freeze, T::Array[ParserRule])

  PRIMARY_RULE_INDEX = T.let(index_rules(PRIMARY_RULES), T::Hash[String, ParserRule])

  SUFFIX_RULES = T.let([
    rule(:CHAR, '[', action: :parse_index_suffix),
    rule(:DOUBLE_COLON, '::', action: :parse_static_call_suffix),
    rule(:CHAR, '.', action: :parse_dot_suffix),
    rule(:CHAR, '(', action: :parse_func_call_suffix),
    rule(:CHAR, '!!', action: :parse_raise_suffix),
    rule(:CHAR, '?', action: :parse_optional_unwrap_suffix),
    rule(:KEYWORD, 'EXISTS', action: :parse_exists_suffix),
    rule(:KEYWORD, 'IS_OK', action: :parse_is_ok_suffix),
    rule(:KEYWORD, 'IS_READY', action: :parse_is_ready_suffix),
    rule(:VAR_ID, '@multiowned', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@shared', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@node', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@locked', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@writeLocked', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@local', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@alwaysMutable', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@versioned', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@atomic', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@boxed', action: :parse_capability_wrap_suffix),
    rule(:VAR_ID, '@indirect', action: :parse_capability_wrap_suffix),
    rule(:CHAR, '{', action: :parse_inline_union_variant_suffix),
  ].freeze, T::Array[ParserRule])

  SUFFIX_RULE_INDEX = T.let(index_rules(SUFFIX_RULES), T::Hash[String, ParserRule])

  # Capability Wraps: expr @multiowned -> Rc(T), expr @shared -> Arc(T), expr @locked -> *Locked(T)
  # Supports `:` join: expr @shared:locked, expr @locked:multiowned (order-independent).
  # Three orthogonal dimensions:
  #   ownership: :multiowned | :shared         (who keeps it alive)
  #   sync:      :locked | :write_locked | :local | :versioned | :atomic  (how it's synchronized)
  #   layout:    :indirect                      (source spelling: @boxed)
  # `:versioned` is MVCC (Versioned(T) atomic-pointer COW + EBR). `:atomic` is
  # a single-cell lock-free primitive (Atomic(T) on Int64/Float64/Bool). Both
  # compose with `:shared` (Arc<Versioned(T)> / [M1] Arc<Atomic(T)>); neither
  # composes with the lock sigils (`:locked` / `:write_locked` /
  # `:always_mutable`) -- mixing locks with a lock-free path is a type error.
  # Enforced by parse_cap_join's one-per-dimension rule plus annotator-side
  # combo validation.
  CAP_SIGIL_ATTRS = T.let({
    '@multiowned'     => sigil_attrs(dim: :ownership, val: :multiowned),
    '@shared'         => sigil_attrs(dim: :ownership, val: :shared),
    '@node'           => sigil_attrs(dim: :ownership, val: :node),
    '@locked'         => sigil_attrs(dim: :sync, val: :locked),
    '@writeLocked'    => sigil_attrs(dim: :sync, val: :write_locked),
    '@local'          => sigil_attrs(dim: :sync, val: :local),
    '@versioned'      => sigil_attrs(dim: :sync, val: :versioned),
    '@atomic'         => sigil_attrs(dim: :sync, val: :atomic),
    '@boxed'          => sigil_attrs(dim: :layout, val: :indirect),
    '@indirect'       => sigil_attrs(dim: :layout, val: :indirect),
    '@alwaysMutable'  => sigil_attrs(dim: :sync, val: :always_mutable),
  }.freeze, SigilTable)

  ELEMENT_CAPABILITY_TOKENS = %w[@shared @multiowned @node @locked @writeLocked @alwaysMutable @link @boxed @indirect].freeze
  ELEMENT_SYNC_TOKENS = %w[@locked @writeLocked @alwaysMutable locked writeLocked alwaysMutable].freeze
  CAPABILITY_TOKENS = %w[@multiowned @shared @node @split @locked @writeLocked @alwaysMutable @local @versioned @atomic @boxed @indirect @link @raw @symbol @c @size @list @pool @set @soa @sharded @observable].freeze
  CAPABILITY_OWNERSHIP_VALUES = T.let({
    "@multiowned" => :multiowned,
    "@shared" => :shared,
    "@node" => :node,
    "@split" => :split,
    "@link" => :link,
  }.freeze, T::Hash[String, Symbol])
  CAPABILITY_SYNC_VALUES = T.let({
    "@locked" => :locked,
    "@writeLocked" => :write_locked,
    "@alwaysMutable" => :always_mutable,
    "@local" => :local,
    "@versioned" => :versioned,
    "@atomic" => :atomic,
    "@raw" => :raw,
    "@symbol" => :symbol,
    "@c" => :c,
    "@size" => :size,
  }.freeze, T::Hash[String, Symbol])
  CAPABILITY_COLLECTION_VALUES = T.let({
    "@list" => :list,
    "@pool" => :pool,
    "@set" => :set,
  }.freeze, T::Hash[String, Symbol])

  # Branch-prefix sigils for DO blocks.
  # Each maps to the attribute(s) it sets on the branch hash.
  # After `:` the next word is also looked up here (with `@` prepended if absent).
  DO_BRANCH_SIGILS = T.let({
    '@micro'    => sigil_attrs(stack_size: :micro),
    '@stack'    => sigil_attrs(stack_size: :stack),
    '@standard' => sigil_attrs(stack_size: :standard),
    '@large'    => sigil_attrs(stack_size: :large),
    '@xl'       => sigil_attrs(stack_size: :xl),
    '@service'  => sigil_attrs(stack_size: :service),
    '@pinned'   => sigil_attrs(pinned: true),
    '@parallel' => sigil_attrs(parallel: true),
    '@canSmash' => sigil_attrs(can_smash: true),
  }.freeze, SigilTable)

  # Sigils valid at the start of a BG body (stack size + pinned).
  BG_SIGILS = T.let({
    '@micro'    => sigil_attrs(stack_size: :micro),
    '@stack'    => sigil_attrs(stack_size: :stack),
    '@standard' => sigil_attrs(stack_size: :standard),
    '@large'    => sigil_attrs(stack_size: :large),
    '@xl'       => sigil_attrs(stack_size: :xl),
    '@service'  => sigil_attrs(stack_size: :service),
    '@pinned'   => sigil_attrs(pinned: true),
    '@parallel' => sigil_attrs(parallel: true),
    '@arena'    => sigil_attrs(pinned: true, arena: true),
    '@canSmash' => sigil_attrs(can_smash: true),
  }.freeze, SigilTable)

end

require_relative "parser/state"
require_relative "parser/statements_and_control_flow"
require_relative "parser/declarations_and_definitions"
require_relative "parser/types"
require_relative "parser/expressions_and_postfix"
require_relative "parser/predicates_and_refinements"
require_relative "parser/collections_capabilities_and_tenses"

class ClearParser
  private :match_optional_retry!,
    :parse_lock_rank_arg!,
    :starts_function_requirement?,
    :parse_when_block
  private :apply_cap_dim!
  private :deep_clone_node
  private :parse_benchmark_stmt
  private :parse_bg_body_stmt
  private :parse_task_prefix
  private :parse_bg_stream_block
  private :parse_bg_then_body
  private :parse_comma_seq
  private :parse_error_selector
  private :parse_error_selectors
  private :parse_generic_type_params
  private :parse_generic_type_param_symbols
  private :parse_lock_action
  private :parse_lock_error_clause
  private :parse_profile_stmt
  private :parse_smash_stmt
  private :parse_snapshot_block
  private :parse_stub
  private :parse_test_that
  private :parse_view_block
  private :parse_when_tags
  private :parse_with_match_arms
  private :test_hook_match?
end
