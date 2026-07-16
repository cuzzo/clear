# typed: strict
require "set"
require "sorbet-runtime"
require_relative "diagnostic_registry"

# Tracker grouping for the diagnostic registry.
#
# DiagnosticRegistry has 400+ codes across 11 categories. The
# `category:` field is too coarse for a "what should I work on next"
# view — `:type` alone has ~190 entries spanning typo errors,
# generics, MATCH patterns, pipeline operators, capability-on-type
# interactions, etc.
#
# This module slices each category into smaller themed buckets and
# adds two human-judgment fields:
#
#   frequency:   1..5 — how often a Python/Ruby/JS-level scripter
#                       encounters the bucket. 5 = day-1 universal,
#                       1 = niche (only when going deep on a feature).
#   alien_factor: :low | :medium | :high — how alien the diagnostic's
#                       concepts are to a scripter without a
#                       Rust/Zig/OCaml background.
#
# `tools/diagnostic_tracker.rb` reads this and renders a tracker
# view showing coverage progress (annotated vs pending vs untouched)
# per bucket. Dev-only — not part of the user-facing `clear` CLI.
module DiagnosticBuckets
  extend T::Sig

  BUCKETS = T.let([
    # ============================================================
    # :type — 191 codes / 20 buckets
    # ============================================================

    {
      id: :type_identifier_typo,
      title: "Identifier / typo",
      category: :type,
      frequency: 5,
      alien_factor: :low,
      summary: "Misspelled name or undeclared symbol. Universal across every language; auto-fix typo suggestions cover the common cases.",
      codes: %i[
        UNDEFINED_VAR ASSIGN_UNDEFINED_VAR MISSING_FUNCTION
        STRUCT_FIELD_UNRESOLVABLE ILLEGAL_FIELD_LOOKUP OPTIONAL_FIELD_REQUIRES_SAFE_NAV
        ENUM_UNKNOWN_VARIANT UNION_UNKNOWN_VARIANT
        MATCH_FIELD_UNKNOWN MATCH_DESTRUCTURE_FIELD_UNKNOWN
        UNKNOWN_TYPE UNKNOWN_STRUCT_TYPE UNION_TYPE_UNKNOWN
        UNION_INLINE_VARIANT_UNKNOWN_FIELD
        DUPLICATE_DECLARATION DUPLICATE_FUNCTION_DECLARATION
        DUPLICATE_EXTERN_METHOD_DECLARATION
      ],
    },

    {
      id: :type_function_call,
      title: "Function call signature",
      category: :type,
      frequency: 5,
      alien_factor: :low,
      summary: "Wrong arity, wrong arg type, wrong return. Familiar to anyone who's used a typed language; same shape as Python's TypeError.",
      codes: %i[
        ARITY_MISMATCH ARITY_MISMATCH_RANGE ARGUMENT_TYPE_ERROR
        NOT_A_FUNCTION RETURN_MISMATCH
        STDLIB_METHOD_NO_ARGS STDLIB_METHOD_ARITY
        INTRINSIC_NO_OVERLOAD INTRINSIC_REJECTED
      ],
    },

    {
      id: :type_mismatch,
      title: "Type mismatch (assign / return / coerce)",
      category: :type,
      frequency: 5,
      alien_factor: :low,
      summary: "Right-hand side type doesn't fit the target. Static-typing surprise for Python/JS devs; CLEAR offers an interactive `CAST(... AS T)` fix for many of these.",
      codes: %i[
        TYPE_MISMATCH_ASSIGN VARDECL_TYPE_MISMATCH_FIXABLE
        FIELD_TYPE_MISMATCH
        RETURN_VOID_FROM_TYPED
        INT_LITERAL_OVERFLOW
        LIST_LITERAL_MIXED_TYPES HASHMAP_MIXED_VALUES
        BOUNDED_STREAM_MIXED_TYPES TYPE_COERCION_FAILED
      ],
    },

    {
      id: :type_struct_literal,
      title: "Struct literal completeness",
      category: :type,
      frequency: 4,
      alien_factor: :low,
      summary: "Struct construction missing required fields. Auto-fix candidate — fill in defaults for known field types.",
      codes: %i[
        STRUCT_LITERAL_MISSING_FIELDS
      ],
    },

    {
      id: :type_array_init,
      title: "Array / collection initialization",
      category: :type,
      frequency: 3,
      alien_factor: :medium,
      summary: "Fixed-size arrays, @soa, @pool, @sharded all need explicit capacity at declaration. Different from dynamic arrays in Python/JS.",
      codes: %i[
        FIXED_ARRAY_SIZE_AS_DYNAMIC FIXED_ARRAY_SIZE_MISMATCH
        SOA_NEEDS_FIXED_ARRAY POOL_NEEDS_FIXED_CAPACITY
        SHARDED_NEEDS_2_PLUS COLLECTION_NEEDS_ARRAY_TYPE TYPE_NODE_LIMIT
        COLLECTION_HINT_VALUE_ONLY
      ],
    },

    {
      id: :type_indexing,
      title: "Indexing & subscript",
      category: :type,
      frequency: 4,
      alien_factor: :low,
      summary: "Map keys must match the declared key type; strings are byte-indexed differently. `STRING_INDEX_BY_INT` is a classic Python-dev gotcha.",
      codes: %i[
        NUMERIC_MAP_KEY_BAD STRING_MAP_KEY_BAD
        STRING_INDEX_BY_INT UNSUPPORTED_INDEX
        TUPLE_INDEX_SYNTAX FIXED_POSITION_OUT_OF_BOUNDS
        RANK_INDEX_ARITY RANK_INDEX_INTEGER RANK_LITERAL_SIZE
        RANK_DYNAMIC_LITERAL_NEEDS_SHAPE
      ],
    },

    {
      id: :type_optional_error_union,
      title: "Optional / error union (`?T`, `!T`)",
      category: :type,
      frequency: 4,
      alien_factor: :high,
      summary: "CLEAR uses Zig-style `!T` error unions and `?T` optionals. No equivalent in Python/Ruby/JS — exception model is fundamentally different.",
      codes: %i[
        UNWRAP_NON_OPTIONAL IF_AS_NEEDS_OPTIONAL WHILE_AS_NEEDS_OPTIONAL
        EXISTS_REQUIRES_OPTIONAL AMBIGUOUS_OPTIONAL_BOOL_LOGIC
        IS_OK_REQUIRES_FALLIBLE IS_READY_REQUIRES_FUTURE
        MODIFIER_NEEDS_ERROR_UNION TYPE_MISMATCH_IN_OR
        OR_BREAK_OUTSIDE_WHILE
        PRE_CLAUSES_NEED_EXPLICIT_FALLIBLE_RETURN
        FALLIBLE_RETURN_NEEDS_ERROR_UNION
        CATCH_WITH_UNREGISTERED ERROR_TYPE_NOT_REGISTERED
        ERROR_TYPE_RESERVED_BY_STDLIB ERROR_TYPE_KIND_CONFLICT
        RETRY_ONLY_TRANSIENT
      ],
    },

    {
      id: :type_if_match_expr,
      title: "IF / MATCH as expression",
      category: :type,
      frequency: 3,
      alien_factor: :medium,
      summary: "When IF/MATCH yield a value (`x = IF c THEN ... END`), every branch must produce the same type and an ELSE/DEFAULT is required. Familiar to OCaml/Rust devs; new to scripters.",
      codes: %i[
        IF_EXPR_THEN_NEEDS_VALUE IF_EXPR_NEEDS_ELSE IF_EXPR_ELSE_NEEDS_VALUE
        IF_EXPR_BRANCHES_INCOMPATIBLE IF_EXPR_RESULT_NOT_COPYABLE
        MATCH_EXPR_BRANCH_NEEDS_VALUE MATCH_EXPR_NEEDS_CASE
        MATCH_EXPR_BRANCHES_INCOMPATIBLE MATCH_EXPR_RESULT_NOT_COPYABLE
        AMBIGUOUS_RETURN PARTIAL_MATCH_EXPR_NEEDS_DEFAULT
      ],
    },

    {
      id: :type_match_pattern,
      title: "MATCH pattern errors",
      category: :type,
      frequency: 3,
      alien_factor: :medium,
      summary: "MATCH on enums/unions, struct destructuring, exhaustiveness. Pattern-match concept is novel for Python/JS devs; familiar from Rust/Swift.",
      codes: %i[
        MATCH_ENUM_CAPTURE MATCH_UNIT_CAPTURE
        MATCH_NEEDS_STRUCT_TYPE MATCH_FIELD_TYPE_MISMATCH
        WHEN_NEEDS_BOOL MATCH_CASE_TYPE_MISMATCH
        MATCH_NEEDS_ENUM_OR_UNION MATCH_FORBIDS_DEFAULT
        MATCH_FORBIDS_WHEN MATCH_NON_EXHAUSTIVE
        MATCH_MULTI_ARM_PAYLOAD_MISMATCH MATCH_DUPLICATE_PATTERN
      ],
    },

    {
      id: :type_loops_control,
      title: "Loops & control flow",
      category: :type,
      frequency: 4,
      alien_factor: :low,
      summary: "FOR/WHILE/IF condition type checks plus BREAK/CONTINUE-outside-loop guards. Self-explanatory for any scripter.",
      codes: %i[
        FOR_RANGE_START_NEEDS_INT64 FOR_RANGE_END_NEEDS_INT64
        FOR_IN_NEEDS_COLLECTION CONDITION_NEEDS_BOOL
        ASSERT_NEEDS_BOOL
        BREAK_OUTSIDE_LOOP CONTINUE_OUTSIDE_LOOP
        INVALID_ASSIGNMENT_TARGET DESTRUCTURE_REQUIRES_FIXED_SHAPE
        DESTRUCTURE_ARITY_MISMATCH DESTRUCTURE_REQUIRES_COPYABLE_RHS
      ],
    },

    {
      id: :type_generics,
      title: "Generics — `STRUCT Foo<T>` / `FN bar<T>`",
      category: :type,
      frequency: 2,
      alien_factor: :high,
      summary: "Type-parameter declarations and inference. No equivalent in Python/JS; familiar to TypeScript / typed-Ruby devs but CLEAR's monomorphization model is stricter.",
      codes: %i[GENERIC_UNKNOWN_PROTOCOL GENERIC_PROTOCOL_BOUND_FAILED GENERIC_SHARED_BOUND_FAILED GENERIC_PROJECTION_UNKNOWN_OWNER GENERIC_PROJECTION_NEEDS_PROTOCOL GENERIC_UNKNOWN_ASSOCIATED_TYPE GENERIC_MAP_KEY_MISMATCH GENERIC_MAP_METHOD_UNKNOWN GENERIC_MAP_METHOD_ARITY GENERIC_MAP_METHOD_ARGUMENT
        GENERIC_MISSING_TYPE_ARGS GENERIC_WRONG_ARG_COUNT
        GENERIC_UNKNOWN_TYPE_ARG GENERIC_NOT_GENERIC
        GENERIC_DUPLICATE_TYPE_PARAM GENERIC_TYPE_PARAM_SHADOWS_BUILTIN
        GENERIC_TYPE_PARAM_SHADOWS GENERIC_DUP_TYPE_PARAM_KIND
        GENERIC_FN_DUPLICATE_PARAM GENERIC_FN_PARAM_SHADOWS_BUILTIN
        GENERIC_FN_CANNOT_INFER GENERIC_FN_CONFLICT
        GENERIC_TYPE_PARAM_SHADOWS_NOMINAL
        IMPLEMENTATION_UNKNOWN_OWNER IMPLEMENTATION_NONLOCAL_OWNER
        IMPLEMENTATION_DUPLICATE IMPLEMENTATION_WRONG_FILE
        IMPLEMENTATION_BINDER_ARITY IMPLEMENTATION_BINDER_HAS_BOUND
        IMPLEMENTATION_BINDER_DUPLICATE IMPLEMENTATION_BINDER_SHADOWS_TYPE
        IMPLEMENTATION_DUPLICATE_MEMBER IMPLEMENTATION_MEMBER_SHADOWS_OWNER
        IMPLEMENTATION_METHOD_NEEDS_SELF TOP_LEVEL_METHOD_REQUIRES_IMPLEMENTATION
        CONFORMANCE_UNKNOWN_PROTOCOL CONFORMANCE_UNKNOWN_OWNER CONFORMANCE_ORPHAN CONFORMANCE_DUPLICATE
        CONFORMANCE_PROTOCOL_ARITY CONFORMANCE_OWNER_ARITY CONFORMANCE_REQUIREMENTS
        DOT_CALL_REQUIRES_METHOD UNKNOWN_INHERENT_METHOD
      ],
    },

    {
      id: :type_type_predicates,
      title: "Type predicates (`IS_A`)",
      category: :type,
      frequency: 2,
      alien_factor: :high,
      summary: "Compile-time type predicates and runtime union-variant tests. Familiar to Rust/Zig users; unusual for Ruby/Python users.",
      codes: %i[
        IS_A_NEEDS_COMPTIME IS_A_OPERAND_NEEDS_TYPE
        IS_A_RUNTIME_NEEDS_UNION IS_A_RUNTIME_UNKNOWN_VARIANT
        IS_A_RUNTIME_AMBIGUOUS_PAYLOAD
      ],
    },

    {
      id: :type_static_methods,
      title: "Static methods & resources (`File::open`)",
      category: :type,
      frequency: 2,
      alien_factor: :low,
      summary: "`Type::method(...)` form for resource constructors. Familiar from C++/Rust syntax-wise; resource ownership is a separate concept (see :ownership).",
      codes: %i[
        STATIC_UNKNOWN_TYPE STATIC_NOT_RESOURCE
        STATIC_UNKNOWN_METHOD STATIC_ARITY STATIC_ARG_TYPE
      ],
    },

    {
      id: :type_auto_inference,
      title: "Gradual typing (`Auto`)",
      category: :type,
      frequency: 1,
      alien_factor: :medium,
      summary: "CLEAR's `--gradual` mode lets parameters omit type annotations and infer from call-site usage. Niche; only matters for users opting into gradual typing.",
      codes: %i[
        AUTO_NOT_ALLOWED_IN_FIELD AUTO_PREFIX_NOT_SUPPORTED
        AUTO_INFERRED_TYPE AUTO_INFERRED_BINDING_TYPE
        AUTO_AMBIGUOUS_TYPE AUTO_UNRESOLVED_TYPE
      ],
    },

    {
      id: :type_pipeline,
      title: "Pipeline operators (`|>`)",
      category: :type,
      frequency: 2,
      alien_factor: :medium,
      summary: "WHERE / SELECT / EACH / TAP / WINDOW / JOIN clauses, plus their argument-type guards. Familiar to Elixir / F# / LINQ devs; new to most scripters.",
      codes: %i[
        PIPE_BAD_DESTINATION PIPE_NOT_CALLABLE
        WHERE_NEEDS_BOOL PIPE_CLAUSE_NEEDS_BOOL TAKE_WHILE_NEEDS_BOOL
        PIPE_NEEDS_NUMERIC
        EACH_NEEDS_COLLECTION TAP_NEEDS_COLLECTION
        UNNEST_NEEDS_ARRAY SELECT_NEEDS_LIST PIPE_OP_NEEDS_LIST
        LIMIT_COUNT_NEEDS_NUMBER SKIP_COUNT_NEEDS_NUMBER
        JOIN_RIGHT_NEEDS_LIST JOIN_LAMBDA_ARITY JOIN_LAMBDA_NEEDS_BOOL
        COLLECT_NEEDS_OBSERVABLE
      ],
    },

    {
      id: :type_concurrent_window_shard,
      title: "CONCURRENT / WINDOW / SHARD options",
      category: :type,
      frequency: 1,
      alien_factor: :high,
      summary: "Knobs on parallel pipelines: stream window sizing, shard keys, concurrency limits. Highly CLEAR-specific; only matters when writing data-pipeline code.",
      codes: %i[
        CONCURRENT_EACH_BAD_INPUT
        CONCURRENT_OPT_NEEDS_NUMBER CONCURRENT_OPT_NEEDS_POSITIVE
        CONCURRENT_CAPACITY_BAD_INPUT CONCURRENT_PARALLEL_NEEDS_BOOL
        CONCURRENT_SIZE_BAD_VALUE CONCURRENT_UNKNOWN_OPTION
        CONCURRENT_BAD_FOLLOWING_OP
        WINDOW_SIZE_NEEDS_NUMBER WINDOW_SIZE_NEEDS_POSITIVE
        WINDOW_TIME_NEEDS_STRING_LIT WINDOW_TIME_BAD_FORMAT
        WINDOW_TIME_NEEDS_POSITIVE WINDOW_NEEDS_SIZE_OR_TIME
        WINDOW_BAD_OPTION WINDOW_NEEDS_COLLECTION_INPUT
        SHARD_NEEDS_RANGE_OR_COLLECTION SHARD_TARGET_BAD
        SHARD_KEY_NEEDS_STRING SHARD_KEY_NEEDS_NUMERIC
      ],
    },

    {
      id: :type_bg_streams,
      title: "BG / streams / promises",
      category: :type,
      frequency: 2,
      alien_factor: :medium,
      summary: "BG STREAM / YIELD / NEXT / @split. Async/await is a partial onramp for JS devs; CLEAR's fiber model is stricter about consumption and capability requirements.",
      codes: %i[
        BG_STREAM_NO_YIELD BG_STREAM_INCONSISTENT_YIELD BG_STREAM_YIELDS_REQUIRED
        YIELD_OUTSIDE_BG_STREAM CLOSE_OUTSIDE_BG_STREAM
        NEXT_NEEDS_FUTURE
        ATSPLIT_STREAM_ONLY ATSPLIT_NEEDS_OPEN_STREAM
        RC_PROMISE_NEEDS_SHARED SOA_TO_EXTERN_FN C_EXTERN_UNSUPPORTED_TYPE
      ],
    },

    {
      id: :type_capability_on_type,
      title: "Capability-on-type interactions",
      category: :type,
      frequency: 2,
      alien_factor: :high,
      summary: "Capability sigils require specific underlying types: `@boxed:atomic` on a struct, `@observable` on a Set, `@multiowned` not on local primitives. Hard to reason about without a capability mental model.",
      codes: %i[
        FN_PARAM_NO_CAPABILITY
        INDIRECT_ATOMIC_PRIMITIVE STRUCT_ATOMIC_NEEDS_INDIRECT
        LOCAL_INDIRECT_ATOMIC MULTIOWNED_INDIRECT_ATOMIC
        RECURSIVE_LAYOUT_REQUIRES_INDIRECT RECURSIVE_LAYOUT_AMBIGUOUS
        INDIRECT_ARGUMENT_EXPLICIT INDIRECT_FIELD_EXPLICIT
        INDIRECT_ELEMENT_PRIMITIVE INDIRECT_ELEMENT_EXPLICIT
        INDIRECT_ELEMENT_IDENTITY COLLECTION_ELEMENT_LAYOUT_MISMATCH
        OBSERVABLE_REQUIRES_SET OBSERVABLE_NOT_COMBINABLE
        OBSERVABLE_TERMINAL_MISMATCH
        OBSERVABLE_BINDING_NEEDS_FOLD_PIPE
        POLY_SHARED_INCONSISTENT
        ARG_NEEDS_ATOMIC_CELL ARG_NEEDS_SHARED
      ],
    },

    {
      id: :type_union_variants,
      title: "Union variant & method constraints",
      category: :type,
      frequency: 3,
      alien_factor: :medium,
      summary: "Tagged unions: payload type-checks, variant counts, inline-struct variants, declared methods. Tagged unions are unfamiliar to most scripters; closest analogue is TypeScript's discriminated unions.",
      codes: %i[
        UNION_PAYLOAD_MISMATCH UNION_FIELD_ACCESS UNION_LITERAL_VARIANT_COUNT
        UNION_VARIANT_IS_UNIT_NO_PAYLOAD UNION_VARIANT_IS_UNIT_NO_FIELDS
        UNION_VARIANT_NEEDS_PAYLOAD_OBJECT NOT_A_UNION_TYPE
        UNION_INLINE_VARIANT_NEEDS_BRACES UNION_INLINE_VARIANT_OLD_SYNTAX
        UNION_INLINE_VARIANT_TYPE_MISMATCH UNION_INLINE_VARIANT_MISSING_FIELD
        UNION_INLINE_IN_GENERIC
        UNION_METHOD_MISSING UNION_METHOD_WRONG_ARITY
        UNION_METHOD_PARAM_TYPE UNION_METHOD_RETURN_TYPE
        UNION_METHOD_WRONG_VISIBILITY UNION_METHOD_DUPLICATE
        ENUM_FIELD_ACCESS
      ],
    },

    {
      id: :type_range_literal,
      title: "Range literals (`a..<b`)",
      category: :type,
      frequency: 2,
      alien_factor: :low,
      summary: "Range start/end must be numeric. Two trivial codes — bound for free with the rest of any batch.",
      codes: %i[
        RANGE_START_NEEDS_NUMERIC RANGE_END_NEEDS_NUMERIC
      ],
    },

    {
      id: :type_misc_catchall,
      title: "Defaults / lints / catch-alls",
      category: :type,
      frequency: 2,
      alien_factor: :medium,
      summary: "Parameter defaults, function purity, effect inference, and the `TYPE_ERROR_GENERIC` pass-through used by older error sites that haven't been migrated to specific codes.",
      codes: %i[
        DEFAULT_NEEDS_STRUCT_PARAM DEFAULT_STRUCT_MISSING_DEFAULTS
        DEFAULT_VALUE_TYPE_MISMATCH
        UNKNOWN_LITERAL TYPE_ERROR_GENERIC STRING_CONCAT_REQUIRES_DOLLAR
        PURITY_VIOLATION EFFECT_INFERENCE_VIOLATION
        CALL_SITE_OVERRIDE_UNIMPLEMENTED
      ],
    },

    # ============================================================
    # :capability — 53 codes / 10 buckets
    # ============================================================

    {
      id: :cap_direct_field_access,
      title: "Direct field access on capability binding",
      category: :capability,
      frequency: 5,
      alien_factor: :high,
      summary: "Reading or writing a field directly on a `@locked` / `@writeLocked` / `@boxed:atomic` binding is rejected. The lock or atomic cell must be unwrapped via `WITH EXCLUSIVE` (locks) or `WITH SNAPSHOT` (atomic) so the inner value is accessible through the alias.",
      codes: %i[
        CAP_FIELD_NEEDS_WITH_EXCLUSIVE
        CAP_FIELD_NEEDS_WITH_SNAPSHOT
      ],
    },

    {
      id: :cap_with_block_match,
      title: "WITH block — capability requirement",
      category: :capability,
      frequency: 4,
      alien_factor: :high,
      summary: "WITH unwraps a binding's capability into an alias. The body's expected capability must match what the binding actually carries (`WITH EXCLUSIVE` needs a lock, `WITH SNAPSHOT` needs `@versioned`/`@atomic`, etc.). Misalignment is the most-common capability error.",
      codes: %i[
        WITH_CAP_BAD_TARGET WITH_EXCLUSIVE_NEEDS_LOCK
        WITH_READ_NEEDS_WRITE_LOCK WITH_RESTRICT_NEEDS_MUTABLE
        WITH_MATERIALIZED_NEEDS_TENSE WITH_VIEW_NEEDS_OBSERVABLE
        WITH_SNAPSHOT_NEEDS_VERSIONED_OR_ATOMIC
        WITH_NEEDS_MULTIOWNED WITH_NEEDS_SHARED
        WITH_ATOMIC_NEEDS_SHARED_ATOMIC UNKNOWN_WITH_CAP_TYPE
        GENERIC_SHARED_MAP_REQUIRES_WITH
      ],
    },

    {
      id: :cap_duplicates,
      title: "Duplicate capability declarations",
      category: :capability,
      frequency: 3,
      alien_factor: :low,
      summary: "Each capability dimension (ownership, sync, layout, collection, etc.) admits at most one sigil. Repeating a sigil — or stacking two from the same dimension — is rejected at parse time.",
      codes: %i[
        DUPLICATE_OWNERSHIP_CAP DUPLICATE_SYNC_CAP
        DUPLICATE_LAYOUT_CAP DUPLICATE_SOA_CAP
        DUPLICATE_COLLECTION_CAP DUPLICATE_SHARD_COUNT_CAP
        DUPLICATE_OBSERVABLE_CAP DUPLICATE_LOCK_RANK
        DUPLICATE_CAPABILITY_DIM
      ],
    },

    {
      id: :cap_unknown_typo,
      title: "Unknown / typo capability sigils",
      category: :capability,
      frequency: 4,
      alien_factor: :low,
      summary: "Capability sigil typos (`@sharred` -> `@shared`) and unknown WITH-form keywords (`WITH RESTRIKT` -> `WITH RESTRICT`). These all have auto-fix typo suggestions wired.",
      codes: %i[
        UNKNOWN_CAPABILITY_MODIFIER UNKNOWN_CAPABILITY_SIGIL
        UNKNOWN_WITH_CAPABILITY
      ],
    },

    {
      id: :cap_syntax,
      title: "Capability syntax — modifiers, mixed forms",
      category: :capability,
      frequency: 2,
      alien_factor: :medium,
      summary: "`@cap(modifier)` parens, mixing `:` and `,` capability separators, sharded counts that need ≥ 2, sigils that need a positive count argument.",
      codes: %i[
        MIXED_AT_CAPABILITIES CAP_BAD_MODIFIER
        SHARDED_TOO_FEW SIGIL_N_NONPOSITIVE TYPE_CAPABILITY_SITE_LIMIT
      ],
    },

    {
      id: :cap_with_guard,
      title: "WITH GUARD / borrow / inference",
      category: :capability,
      frequency: 2,
      alien_factor: :high,
      summary: "WITH GUARD's predicate constraints, BORROWED wildcards, and capability inference rules. Edge-case shapes that only experienced users hit, but the messages are alien without the borrow-checker mental model.",
      codes: %i[
        WITH_CANNOT_INFER_CAP WITH_GUARD_NOT_WITH_MATCH
        WITH_GUARD_NOT_ON_SNAPSHOT WITH_GUARD_ALL_BINDINGS_NEED_AS
        WITH_GUARD_EXPR_MUST_BE_BOOL WITH_GUARD_REFS_SIBLING_ALIAS
        WITH_GUARD_MUTABLE_MUTATED BORROW_WILDCARD_NEEDS_STRUCT
        WITH_BORROWED_ON_QUALIFIED_VAR
      ],
    },

    {
      id: :cap_foreign_views,
      title: "Foreign pointer views",
      category: :capability,
      frequency: 2,
      alien_factor: :high,
      summary: "Foreign pointers require a bounded WITH UNSAFE VIEW before access; ordinary VIEW and direct indexing are rejected with a fix.",
      codes: %i[
        WITH_UNSAFE_VIEW_NEEDS_FOREIGN_POINTER FOREIGN_VIEW_REQUIRES_WITH
        FOREIGN_POINTER_DIRECT_INDEX WITH_VIEW_FOREIGN_NEEDS_UNSAFE
        DIRECT_VIEW_ACCESS_REQUIRES_WITH
      ],
    },

    {
      id: :cap_pre_post,
      title: "PRE / DEBUG_POST clauses",
      category: :capability,
      frequency: 2,
      alien_factor: :medium,
      summary: "Function-level PRE (precondition) and DEBUG_POST (debug-postcondition) clauses. Predicates must be Bool, DEBUG_POST has additional shape constraints (not in CATCH, parameters must be unsynchronized).",
      codes: %i[
        PRE_EXPR_MUST_BE_BOOL DEBUG_POST_EXPR_MUST_BE_BOOL
        DEBUG_POST_NEEDS_UNSYNC_PARAM DEBUG_POST_NOT_WITH_CATCH
      ],
    },

    {
      id: :cap_purity_parallel,
      title: "Purity & parallel safety",
      category: :capability,
      frequency: 2,
      alien_factor: :high,
      summary: "PURE functions can't call impure code; @local / @multiowned bindings can't cross fiber boundaries inside @parallel BG blocks. Three rules that concretize CLEAR's effect/concurrency model.",
      codes: %i[
        PURE_FN_CANNOT_CALL_IMPURE LOCAL_VAR_NOT_IN_PARALLEL
        MULTIOWNED_NOT_IN_PARALLEL
      ],
    },

    {
      id: :cap_atomic_ops,
      title: "Atomic compound ops",
      category: :capability,
      frequency: 1,
      alien_factor: :high,
      summary: "Compound assignment on `@atomic` cells is restricted to operations that map to single-instruction atomic primitives (fetchAdd / fetchSub / etc.). `*=` / `/=` aren't atomic; arbitrary compound ops aren't lowered.",
      codes: %i[
        ATOMIC_NO_MUL_DIV_COMPOUND ATOMIC_UNSUPPORTED_COMPOUND
      ],
    },

    {
      id: :cap_misc,
      title: "Capability misc / catch-alls",
      category: :capability,
      frequency: 2,
      alien_factor: :medium,
      summary: "CAPABILITY_ON_PRIMITIVE (most caps require a struct wrapper), CAPABILITY_VIOLATION_FIXABLE (umbrella), BG capture/parallel mismatches, ON RETRY needing a fallible cap, SELECTORS_NO_MATCH, CAPABILITY_INVALID umbrella.",
      codes: %i[
        CAPABILITY_ON_PRIMITIVE ON_RETRY_NEEDS_FALLIBLE_CAP
        SELECTORS_NO_MATCH BG_ARENA_AND_PARALLEL
        BG_PINNED_CAPTURE_MISMATCH CAPABILITY_VIOLATION_FIXABLE
        CAPABILITY_INVALID WITH_CAP_BINDING_LOST
      ],
    },
  ].freeze, T::Array[T::Hash[Symbol, T.untyped]])

  COVERED_CODES = T.let(BUCKETS.flat_map { |bucket|
    T.cast(bucket[:codes], T::Array[Symbol])
  }.to_set.freeze, T::Set[Symbol])

  BUCKETS_BY_CATEGORY = T.let(BUCKETS.group_by { |bucket|
    T.cast(bucket[:category], Symbol)
  }.transform_values { |buckets| buckets.freeze }.freeze, T::Hash[Symbol, T::Array[T::Hash[Symbol, T.untyped]]])

  # All codes referenced by any bucket — used by the audit to confirm
  # bucket assignments are exhaustive for their category.
  sig { returns(T::Set[Symbol]) }
  def self.covered_codes
    COVERED_CODES
  end

  # Buckets for a specific category (e.g. `:type`).
  sig { params(cat: Symbol).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
  def self.for_category(cat)
    BUCKETS_BY_CATEGORY.fetch(cat, [])
  end

  # Status of a single code:
  #   :pending   — registry has `pending: true`
  #   :annotated — DiagnosticExamples loader picked up bad+good
  #   :todo      — code exists but isn't pending and has no example
  #
  # `examples` should be the `DiagnosticExamples.all` hash; passed in
  # so callers can reuse it across many lookups.
  sig { params(code: Symbol, examples: T::Hash[Symbol, T::Hash[Symbol, T.nilable(String)]]).returns(Symbol) }
  def self.status_of(code, examples)
    return :pending if DiagnosticRegistry.pending?(code)
    e = examples[code]
    return :annotated if e && e[:bad] && e[:good]
    :todo
  end

  # ASCII stars for the frequency rank (1..5).
  sig { params(rank: Integer).returns(String) }
  def self.frequency_stars(rank)
    "#{'★' * rank}#{'☆' * (5 - rank)}"
  end

  # ASCII tag for the alien-factor severity.
  sig { params(level: Symbol).returns(String) }
  def self.alien_label(level)
    case level
    when :low    then "Low"
    when :medium then "Med"
    when :high   then "High"
    else "?"
    end
  end
end
