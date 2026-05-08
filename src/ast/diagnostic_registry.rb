# Single source of truth for compiler-emitted diagnostics.
#
# Before this file existed, `MESSAGES` (in source_error.rb) held just
# the message templates and ~9% of error sites went through it; the
# rest were ad-hoc string literals scattered across the compiler.
# This registry is the Layer-2 unification: every error gets a stable
# code, category, severity, and (eventually) cause + fix-hint + worked
# examples.
#
# Existing call sites that pass a Symbol code to `error!` continue to
# work unchanged — `MESSAGES` is now a derived view over this
# registry's templates. New code should still write
# `error!(node, :SOME_CODE, *args)` and add the entry here. The
# eventual goal is to refactor the ~470 ad-hoc string sites to the
# registry too (Layer 3).
#
# Schema for each entry:
#
#   severity:     :error | :warning | :hint | :info
#   category:     :type | :ownership | :capability | :escape |
#                 :registry | :reentrance | :lint | :syntax | :mir
#   template:     String with %s/%d sprintf placeholders.
#   summary:      Short user-facing one-liner that names the error
#                 without requiring the variable substitutions
#                 (used by `clear explain` and the audit tooling).
#   cause:        (optional) Markdown explaining what triggers this.
#   fix_hint:     (optional) Plain-text guidance for fixing it.
#   example_bad:  (optional) CLEAR snippet that triggers this error.
#   example_good: (optional) CLEAR snippet that doesn't.
#
# `clear explain <CODE>` reads from this table. As entries are
# enriched with cause / fix_hint / examples, the explain command
# becomes more useful without further plumbing.

module DiagnosticRegistry
  CATEGORIES = %i[type ownership capability concurrency lifetime escape registry reentrance lint syntax mir test].freeze
  SEVERITIES = %i[error warning hint info].freeze

  DIAGNOSTICS = {
    # ===================================================================
    # PARSER (syntax)
    # ===================================================================
    UNEXPECTED_TOKEN: {
      severity: :error, category: :syntax,
      template: "Unexpected token '%{value}' (%{type}). Expected an expression or statement.",
      summary:  "Parser found a token where it expected something else.",
      cause: "The parser expected one shape (expression, statement, type, ...) and found a token that doesn't fit. Often comes from a missing keyword, a missed terminator, or a malformed expression.",
      fix_hint: "Read the line where the unexpected token sits and the line above it. The grammar rule the parser was trying to match is usually obvious from context (in a function call, struct literal, type annotation, ...).",
    },
    INVALID_ASSIGNMENT: {
      severity: :error, category: :syntax,
      template: "Invalid assignment target. You can only SET variables, fields, or indices.",
      summary:  "The left-hand side of `=` is not a valid assignment target.",
    },
    MISSING_CAST_TYPE: {
      severity: :error, category: :syntax,
      template: "Syntax Error: CAST expects a Type identifier after 'AS', got %{got}.",
      summary:  "`CAST x AS <Type>` requires a TYPE_ID after `AS`.",
    },
    UNKNOWN_OPERATOR: {
      severity: :error, category: :syntax,
      template: "Unknown operator '%{value}'.",
      summary:  "The lexer saw an operator-shaped token it does not recognise.",
    },

    # ===================================================================
    # CONTROL FLOW
    # ===================================================================
    ILLEGAL_BREAK: {
      severity: :error, category: :type,
      template: "'BREAK' used outside of a loop.",
      summary:  "BREAK only makes sense inside a FOR / WHILE loop body.",
    },
    ILLEGAL_CONTINUE: {
      severity: :error, category: :type,
      template: "'CONTINUE' used outside of a loop.",
      summary:  "CONTINUE only makes sense inside a FOR / WHILE loop body.",
    },

    # ===================================================================
    # MEMORY / STORAGE
    # ===================================================================

    # ===================================================================
    # BINDINGS
    # ===================================================================
    UNDEFINED_VAR: {
      severity: :error, category: :type,
      template: "Undefined variable '%{name}'.",
      summary:  "The named binding does not exist in scope.",
      cause: "The identifier doesn't resolve to any binding in the current scope (locals, parameters, captures) or any visible enclosing scope. Identifiers are resolved at annotation time; missing names always surface here.",
      fix_hint: "Check the spelling. If the binding lives in a different module, add a REQUIRE. If it's a struct field or method, qualify with the receiver.",
    },
    UNRECOGNIZED_LITERAL: {
      severity: :error, category: :syntax,
      template: "Unrecognized literal: %{value}",
      summary:  "The literal token doesn't match any known literal shape.",
    },
    IMMUTABLE_ASSIGNMENT: {
      severity: :error, category: :ownership,
      template: "Variable '%{name}' is immutable.",
      summary:  "Assignment target was declared without `MUTABLE`; reassignment is rejected.",
      cause: "A binding declared without `MUTABLE` cannot be reassigned. CLEAR is immutable-by-default — `MUTABLE x = 0` is required to allow `x = 1`.",
      fix_hint: "Add `MUTABLE` at the binding's declaration site. `clear fix` offers this as an interactive fix when the declaration is locatable.",
    },
    VARIABLE_REBIND: {
      severity: :error, category: :ownership,
      template: "Cannot rebind immutable variable '%{name}'.",
      summary:  "Cannot redeclare a binding that is already in scope as immutable.",
    },
    NATIVE_CALL_ERROR: {
      severity: :error, category: :registry,
      template: "native_call requires 'Class' and 'Method' string literals.",
      summary:  "`native_call` only accepts string-literal class/method args.",
    },

    # ===================================================================
    # STRUCT FIELDS
    # ===================================================================
    MISSING_FIELD_VALUE: {
      severity: :error, category: :type,
      template: "Missing value for field '%{field}' in struct '%{struct}'",
      summary:  "Struct literal omits a required field.",
    },
    MISSING_REQUIRED_STRUCT_FIELD: {
      severity: :error, category: :type,
      template: "Missing required field '%{field}' in instantiation of '%{struct}'",
      summary:  "Struct literal omits a required field (alternate phrasing).",
    },
    VARIABLE_ASSIGNMENT_TYPE_ERROR: {
      severity: :error, category: :type,
      template: "Type Error: Variable '%{name}' declared as %{declared} but assigned %{assigned}",
      summary:  "Declared type does not accept the assigned value's type.",
    },
    FIXED_ARRAY_SIZE_AS_DYNAMIC: {
      severity: :error, category: :type,
      template: "Cannot initialize fixed-array '%{name}' to an unknown size. You must TRUNCATE to a specific size, or use `[]` to create a dynamic array.",
      summary:  "Fixed-size array `T[N]` requires a literal capacity.",
    },
    FIXED_ARRAY_SIZE_MISMATCH: {
      severity: :error, category: :type,
      template: "Cannot initialize array of size %{size} to fixed-size '%{name}'",
      summary:  "Initializer's element count differs from the declared `T[N]`.",
    },
    IMMUTABLE_FIELD_ASSIGNMENT: {
      severity: :error, category: :ownership,
      template: "Cannot modify field '%{field}' of immutable object '%{name}'.",
      summary:  "Field write through an immutable receiver is rejected.",
    },
    IMMUTABLE_LIST_ASSIGNMENT: {
      severity: :error, category: :ownership,
      template: "Cannot modify index of immutable list '%{name}'.",
      summary:  "Indexed write through an immutable list is rejected.",
    },
    LIST_TYPE_MISMATCH: {
      severity: :error, category: :type,
      template: "List contains mixed types. Item %{index} is '%{got}', expected '%{expected}'.",
      summary:  "List literal element types are inconsistent with the inferred element type.",
    },
    ILLEGAL_FIELD_LOOKUP: {
      severity: :error, category: :type,
      template: "Type Error: Cannot determine struct type for field access '%{field}'. Object is '%{type}'.",
      summary:  "Field access on a non-struct (or unresolved-type) target.",
    },
    STRUCT_FIELD_UNRESOLVABLE: {
      severity: :error, category: :type,
      template: "Type Error: Struct '%{struct}' has no field '%{field}'",
      summary:  "Field access on a struct that does not declare that field.",
    },

    # ===================================================================
    # ENUMS
    # ===================================================================
    ENUM_UNKNOWN_VARIANT: {
      severity: :error, category: :type,
      template: "Type Error: Enum '%{enum}' has no variant '%{variant}'.",
      summary:  "Reference to a variant that the enum does not declare.",
    },
    ENUM_FIELD_ACCESS: {
      severity: :error, category: :type,
      template: "Type Error: '%{enum}' is an enum type. Enum values do not have fields.",
      summary:  "Field access on an enum value (enum variants carry no fields).",
    },

    # ===================================================================
    # UNIONS
    # ===================================================================
    UNION_UNKNOWN_VARIANT: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' has no variant '%{variant}'.",
      summary:  "Reference to a variant that the union does not declare.",
    },
    UNION_PAYLOAD_MISMATCH: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{variant}' expects %{expected}, got %{got}.",
      summary:  "Union variant constructor passed a payload of the wrong type.",
    },
    UNION_FIELD_ACCESS: {
      severity: :error, category: :type,
      template: "Type Error: '%{union}' is a union type. Access variants with 'Type.Variant(payload)'.",
      summary:  "Field access on a union value (use variant pattern matching instead).",
    },
    UNION_INLINE_VARIANT_NEEDS_BRACES: {
      severity: :error, category: :type,
      template: "Type Error: '%{union}.%{variant}' is an inline struct variant — use '%{union2}.%{variant2}{ field: value }' to construct it.",
      summary:  "Inline-struct variant constructor requires braces, not parens.",
    },
    UNION_INLINE_VARIANT_OLD_SYNTAX: {
      severity: :error, category: :type,
      template: "Type Error: '%{union}' variant '%{variant}' has inline struct fields — use '%{union2}.%{variant2}{ field: value }' instead.",
      summary:  "Old paren-style construction of an inline-struct variant.",
    },
    UNION_INLINE_VARIANT_UNKNOWN_FIELD: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{union}.%{variant}' has no field '%{field}'.",
      summary:  "Inline-struct variant literal references a field the variant doesn't declare.",
    },
    UNION_INLINE_VARIANT_TYPE_MISMATCH: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{union}.%{variant}' field '%{field}' expects %{expected}, got %{got}.",
      summary:  "Inline-struct variant field receives a value of the wrong type.",
    },
    UNION_INLINE_VARIANT_MISSING_FIELD: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{union}.%{variant}' is missing required field '%{field}'.",
      summary:  "Inline-struct variant literal omits a required field.",
    },
    UNION_INLINE_IN_GENERIC: {
      severity: :error, category: :type,
      template: "Type Error: Inline struct variants are not supported in generic unions.",
      summary:  "Generic unions don't yet support inline-struct variants.",
    },
    UNION_METHOD_MISSING: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' requires method '%{method}', but no function '%{fn}' exists.",
      summary:  "Union METHOD-clause names a function that wasn't declared.",
    },
    UNION_METHOD_WRONG_ARITY: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' requires %{expected_arity} parameter(s), but function '%{fn}' has %{got_arity}.",
      summary:  "Method arity doesn't match the union's METHOD declaration.",
    },
    UNION_METHOD_PARAM_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' parameter %{index} expects '%{expected}', but function '%{fn}' has '%{got}'.",
      summary:  "Method parameter type doesn't match the union's METHOD declaration.",
    },
    UNION_METHOD_RETURN_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' requires return type '%{expected}', but function '%{fn}' returns '%{got}'.",
      summary:  "Method return type doesn't match the union's METHOD declaration.",
    },
    UNION_METHOD_WRONG_VISIBILITY: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' is declared %{declared_vis} but function '%{fn}' is %{fn_vis} — visibility must match.",
      summary:  "Method visibility doesn't match the union's METHOD declaration.",
    },
    UNION_METHOD_DUPLICATE: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' declares method '%{method}' more than once.",
      summary:  "Two METHOD clauses on the same union name the same function.",
    },

    # ===================================================================
    # MATCH
    # ===================================================================
    MATCH_ENUM_CAPTURE: {
      severity: :error, category: :type,
      template: "Cannot capture payload from enum variant: enums have no payload. Remove 'AS %{binding}'.",
      summary:  "MATCH binding `AS x` not valid for enum variants (they have no payload).",
    },
    MATCH_UNIT_CAPTURE: {
      severity: :error, category: :type,
      template: "Cannot bind 'AS %{binding}': '%{variant}' is a unit variant with no payload.",
      summary:  "MATCH binding `AS x` not valid for unit-shape union variants.",
    },

    # ===================================================================
    # GENERICS
    # ===================================================================
    GENERIC_DUPLICATE_TYPE_PARAM: {
      severity: :error, category: :type,
      template: "Type Error: Duplicate type parameter '%{param}' in generic struct '%{struct}'.",
      summary:  "Generic struct lists the same type parameter name twice.",
    },
    GENERIC_TYPE_PARAM_SHADOWS_BUILTIN: {
      severity: :error, category: :type,
      template: "Type Error: Type parameter '%{param}' shadows built-in type '%{builtin}'.",
      summary:  "Generic struct's type parameter shadows a built-in type name.",
    },
    GENERIC_MISSING_TYPE_ARGS: {
      severity: :error, category: :type,
      template: "Type Error: '%{type}' is a generic type — type arguments are required (e.g., %{type2}<%{hint}>).",
      summary:  "Reference to a generic struct without supplying its type arguments.",
    },
    GENERIC_WRONG_ARG_COUNT: {
      severity: :error, category: :type,
      template: "Type Error: '%{type}' expects %{expected} type argument(s), got %{got}.",
      summary:  "Generic instantiation has the wrong number of type arguments.",
    },
    GENERIC_UNKNOWN_TYPE_ARG: {
      severity: :error, category: :type,
      template: "Type Error: Unknown type argument '%{type}'.",
      summary:  "Type argument refers to a type that isn't in scope.",
    },
    GENERIC_NOT_GENERIC: {
      severity: :error, category: :type,
      template: "Type Error: '%{type}' is not a generic type — remove the type arguments.",
      summary:  "Type arguments supplied to a non-generic type.",
    },
    GENERIC_FN_DUPLICATE_PARAM: {
      severity: :error, category: :type,
      template: "Type Error: Duplicate type parameter '%{param}' in generic function '%{fn}'.",
      summary:  "Generic function lists the same type parameter name twice.",
    },
    GENERIC_FN_PARAM_SHADOWS_BUILTIN: {
      severity: :error, category: :type,
      template: "Type Error: Type parameter '%{param}' in function '%{fn}' shadows built-in type '%{builtin}'.",
      summary:  "Generic function's type parameter shadows a built-in type name.",
    },
    GENERIC_FN_CANNOT_INFER: {
      severity: :error, category: :type,
      template: "Type Error: Cannot infer type argument '%{param}' for '%{fn}' — no parameter uses type '%{type}'.",
      summary:  "Generic function call: a type parameter isn't constrained by any argument.",
    },
    GENERIC_FN_CONFLICT: {
      severity: :error, category: :type,
      template: "Type Error: Conflicting inference for '%{param}' in '%{fn}': got '%{first}' and '%{second}'.",
      summary:  "Generic function call: the same type parameter inferred to two different types.",
    },

    # ===================================================================
    # FUNCTION CALLS
    # ===================================================================
    MISSING_FUNCTION: {
      severity: :error, category: :type,
      template: "Missing function '%{name}'.",
      summary:  "Call site refers to a function name that isn't declared.",
    },
    ARITY_MISMATCH: {
      severity: :error, category: :type,
      template: "Function '%{name}' expects %{expected} arguments, got %{got}.",
      summary:  "Call site passes the wrong number of arguments.",
      cause: "The call site passes a different number of arguments than the function declares. CLEAR doesn't allow ad-hoc overloading; arity must match exactly (with optional defaults filling missing trailing args).",
      fix_hint: "Check the function's signature. If you wanted to skip arguments, declare them with defaults at the function. If you wanted variadic behaviour, use a list parameter.",
    },
    ARITY_MISMATCH_RANGE: {
      severity: :error, category: :type,
      template: "Function '%{name}' expects between %{min} and %{max} arguments, got %{got}.",
      summary:  "Variadic-or-defaults function call passes a count outside the allowed range.",
    },
    ARGUMENT_TYPE_ERROR: {
      severity: :error, category: :type,
      template: "Type Error: Function '%{fn}' argument %{index} expects %{expected}, got %{got}",
      summary:  "Argument value's type doesn't match the parameter's declared type.",
      cause: "The argument's type doesn't match the parameter's declared type. Coercion was tried (slice widening, primitive autocast, generic substitution) and failed.",
      fix_hint: "Check the argument and the parameter's declared type — the message gives both. Either change the argument, change the parameter's type, or use CAST.",
    },
    PRIMITIVE_PASSED_AS_MUTABLE: {
      severity: :error, category: :ownership,
      template: "Parameter '%{name}' is MUTABLE but has primitive type '%{type}'. Primitives are passed by value, so mutating them locally has no effect on the caller.",
      summary:  "Declaring a primitive-typed parameter `MUTABLE` is meaningless (pass-by-value).",
    },
    IMMUTABLE_ARG_PASSED_AS_MUTABLE: {
      severity: :error, category: :ownership,
      template: "Argument %{index} ('%{param}') is MUTABLE, but you passed immutable variable '%{actual}'.",
      summary:  "Callee's MUTABLE parameter requires a mutable binding at the call site.",
    },
    IMMUTABLE_ARG_PASSED_AS_EXPRESSION: {
      severity: :error, category: :ownership,
      template: "Argument %{index} ('%{param}') is MUTABLE. You cannot pass a value/expression, you must pass a Mutable Variable.",
      summary:  "Callee's MUTABLE parameter requires a binding, not a temporary expression.",
    },
    ILLEGAL_UPVALUE: {
      severity: :error, category: :ownership,
      template: "Cannot capture '%{name}' - undefined in outer scope.",
      summary:  "Lambda body references a name that doesn't exist in any enclosing scope.",
    },
    RETURN_MISMATCH: {
      severity: :error, category: :type,
      template: "Type Error: Function expected to return '%{expected}', but returned '%{got}'",
      summary:  "RETURN value's type doesn't match the function's declared return type.",
      cause: "A RETURN statement's value doesn't match the function's declared return type. Coercion was tried and failed.",
      fix_hint: "Either change the returned value to match the declared return type, or change the declared return type to match what the function actually returns.",
    },

    # ===================================================================
    # STATIC METHOD CALLS (`Type::method`)
    # ===================================================================
    STATIC_UNKNOWN_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: Unknown type '%{type}'. Cannot perform '::' static method call.",
      summary:  "`T::method` where T is not a known type.",
    },
    STATIC_NOT_RESOURCE: {
      severity: :error, category: :type,
      template: "Type Error: '%{type}' does not support '::' static method calls. Only resource types have static constructors.",
      summary:  "`T::method` only works on resource-shaped types (e.g., TCPServer::listen).",
    },
    STATIC_UNKNOWN_METHOD: {
      severity: :error, category: :type,
      template: "Type Error: No static method '%{method}' on '%{type}'. Available: %{available}.",
      summary:  "`T::method` where T is a resource type but doesn't declare that static method.",
    },
    STATIC_ARITY: {
      severity: :error, category: :type,
      template: "Type Error: '%{type}::%{method}' expects %{expected} argument(s), got %{got}.",
      summary:  "Static-method call passes the wrong number of arguments.",
    },
    STATIC_ARG_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: Argument %{index} to '%{type}::%{method}': expected %{expected}, got %{got}.",
      summary:  "Static-method call argument has the wrong type.",
    },

    # ===================================================================
    # PARSER — capability sigils & duplication checks
    # ===================================================================
    # Added in Tranche 1a (Layer 3). Migration of parser.rb call sites
    # in T1b. Templates carry the existing message text verbatim so
    # the user-facing wording doesn't change during migration.

    DUPLICATE_OWNERSHIP_CAP: {
      severity: :error, category: :capability,
      template: "Duplicate ownership",
      summary:  "More than one ownership-axis sigil (`@multiowned`, `@shared`, `@split`, `@link`).",
    },
    DUPLICATE_SYNC_CAP: {
      severity: :error, category: :capability,
      template: "Duplicate sync",
      summary:  "More than one sync-axis sigil (`@locked`, `@writeLocked`, `@local`, `@versioned`, `@atomic`, `@raw`, `@symbol`).",
    },
    DUPLICATE_LAYOUT_CAP: {
      severity: :error, category: :capability,
      template: "Duplicate layout",
      summary:  "More than one layout-axis sigil (currently `@indirect` is the only layout sigil).",
    },
    DUPLICATE_SOA_CAP: {
      severity: :error, category: :capability,
      template: "Duplicate soa",
      summary:  "`@soa` applied more than once on the same type.",
    },
    DUPLICATE_COLLECTION_CAP: {
      severity: :error, category: :capability,
      template: "Duplicate collection",
      summary:  "More than one collection sigil (`@list`, `@pool`, `@set`).",
    },
    DUPLICATE_SHARD_COUNT_CAP: {
      severity: :error, category: :capability,
      template: "Duplicate shard count",
      summary:  "`@sharded(N)` declared more than once on the same type.",
    },
    DUPLICATE_OBSERVABLE_CAP: {
      severity: :error, category: :capability,
      template: "Duplicate observable",
      summary:  "`@observable` declared more than once on the same type.",
    },
    DUPLICATE_LOCK_RANK: {
      severity: :error, category: :capability,
      template: "Duplicate rank on capability chain (already %{current}, cannot also set %{attempted}).",
      summary:  "`@locked(rank: N)` / `@writeLocked(rank: N)` rank set twice on the same chain.",
    },
    DUPLICATE_CAPABILITY_DIM: {
      severity: :error, category: :capability,
      template: "Duplicate %{dim} capability: already have @%{current}, cannot add @%{attempted}",
      summary:  "Two sigils on the same axis (ownership / sync / layout) — pick one.",
    },
    UNKNOWN_CAPABILITY_MODIFIER: {
      severity: :error, category: :capability,
      template: "Unknown capability modifier: %{value}",
      summary:  "Capability sigil isn't recognised.",
    },
    UNKNOWN_CAPABILITY_SIGIL: {
      severity: :error, category: :capability,
      template: "Unknown capability sigil '%{value}'. Expected @multiowned, @shared, @locked, @writeLocked, @local, @versioned, @atomic, or @indirect",
      summary:  "Capability sigil after `:` in a chain isn't one of the recognised set.",
    },
    UNKNOWN_WITH_CAPABILITY: {
      severity: :error, category: :capability,
      template: "Unknown WITH capability: %{value}",
      summary:  "WITH-block capability keyword (`EXCLUSIVE`, `BORROWED`, `RESTRICT`, `VIEW`, `MATERIALIZED`, `GUARD`) isn't recognised.",
    },
    MIXED_AT_CAPABILITIES: {
      severity: :error, category: :capability,
      template: "Cannot use two separate @ capabilities. Join with ':' instead (e.g., @shared:locked not @shared @locked).",
      summary:  "Two `@cap` sigils side-by-side — they must be joined with `:`.",
    },
    EXPECTED_CAP_SIGIL_AFTER_COLON: {
      severity: :error, category: :syntax,
      template: "Expected a capability sigil after ':'",
      summary:  "Capability-chain `:` not followed by a sigil.",
    },
    EXPECTED_CAP_AFTER_COLON: {
      severity: :error, category: :syntax,
      template: "Expected a capability modifier after ':'",
      summary:  "Capability `:` not followed by a recognized modifier.",
    },
    EXPECTED_RANK_KEYWORD: {
      severity: :error, category: :syntax,
      template: "Expected 'rank' keyword inside @%{sigil}(...) arguments.",
      summary:  "`@locked(...)` / `@writeLocked(...)` argument list must start with `rank:`.",
    },
    CAP_BAD_MODIFIER: {
      severity: :error, category: :capability,
      template: "Expected 'sharded(N)' or 'soa' after '%{cap}:' — unknown modifier '%{modifier}'",
      summary:  "Modifier after `@<container>:` isn't recognised (only `sharded(N)` and `soa` are valid).",
    },
    SHARDED_TOO_FEW: {
      severity: :error, category: :capability,
      template: "@pool:sharded / @list:sharded requires N >= 2, got %{count}",
      summary:  "`@sharded(N)` requires at least 2 shards.",
    },
    SIGIL_N_NONPOSITIVE: {
      severity: :error, category: :capability,
      template: "%{sigil}(N) requires a positive integer N (got %{count}).",
      summary:  "Sigil with `(N)` parameter (`@sharded(N)`, etc) requires N > 0.",
    },

    # ===================================================================
    # PARSER — REQUIRES / EFFECTS clauses
    # ===================================================================
    DUPLICATE_REQUIRES_CLAUSE: {
      severity: :error, category: :syntax,
      template: "Function '%{fn}' has duplicate REQUIRES clause for '%{name}'.",
      summary:  "Same name listed in two REQUIRES clauses on one function.",
    },
    UNKNOWN_REQUIRES_FAMILY: {
      severity: :error, category: :syntax,
      template: "Unknown REQUIRES family or kind '%{name}'. Expected a capability family (%{families}) or a reentrance kind (%{kinds}).",
      summary:  "REQUIRES clause references a name that isn't a known family or kind.",
    },
    UNKNOWN_REQUIRES_KIND: {
      severity: :error, category: :syntax,
      template: "Unknown REQUIRES kind '%{value}'. Valid: NON_REENTRANT.",
      summary:  "REQUIRES kind isn't `NON_REENTRANT`.",
    },
    EXPECTED_CAP_FAMILY: {
      severity: :error, category: :syntax,
      template: "Expected capability family, got reentrance kind",
      summary:  "REQUIRES expected a capability family (LOCKED, ATOMIC, ...) but saw a reentrance kind.",
    },
    UNKNOWN_EFFECT: {
      severity: :error, category: :syntax,
      template: "Unknown effect ':%{value}'. Valid effects: :alloc, :safe",
      summary:  "EXTERN-effect annotation references an unknown effect tag.",
    },
    UNKNOWN_FN_EFFECT: {
      severity: :error, category: :syntax,
      template: "Unknown effect '%{value}'. Function-level EFFECTS only accepts REENTRANT today.",
      summary:  "Function-level EFFECTS clause references something other than REENTRANT.",
    },
    UNKNOWN_ALLOC_QUALIFIER: {
      severity: :error, category: :syntax,
      template: "Unknown alloc qualifier ':%{value}'. Use :alloc:frame or :alloc:heap",
      summary:  "EXTERN `:alloc` effect needs a `:frame` or `:heap` qualifier.",
    },
    UNKNOWN_REENTRANT_VARIANT: {
      severity: :error, category: :syntax,
      template: "Unknown REENTRANT variant ':%{value}'. Valid: :TIGHT, :TIGHT:THUNK, :TIGHT:TAIL_CALL, :THUNK, :TAIL_CALL, :NOT_LOGICAL, :MAX_DEPTH(N).",
      summary:  "EFFECTS REENTRANT variant isn't one of the recognised set.",
    },
    INVALID_TIGHT_VARIANT: {
      severity: :error, category: :syntax,
      template: ":TIGHT:%{label} is invalid. %{explanation}",
      summary:  ":TIGHT:<label> only allows :THUNK or :TAIL_CALL.",
    },
    MAX_DEPTH_NONPOSITIVE: {
      severity: :error, category: :syntax,
      template: ":MAX_DEPTH(N) requires a positive integer N (got %{got}).",
      summary:  "EFFECTS REENTRANT:MAX_DEPTH(N) needs N > 0.",
    },
    REENTRANT_LEGACY_AND_NEW: {
      severity: :error, category: :syntax,
      template: "Function '%{name}' has both legacy '@reentrant' annotation and new 'EFFECTS REENTRANT' clause. Pick one.",
      summary:  "Legacy `@reentrant` and new `EFFECTS REENTRANT` are mutually exclusive.",
    },

    # ===================================================================
    # PARSER — WITH / MATCH / SYNC POLICY / error clauses
    # ===================================================================
    WITH_GUARD_REQUIRES_AS: {
      severity: :error, category: :syntax,
      template: "WITH GUARD requires an AS alias so the guard can reference the unwrapped value",
      summary:  "WITH GUARD must bind an alias (`AS x`) so the guard body can reference the unwrapped value.",
    },
    WITH_MATCH_NO_WHEN: {
      severity: :error, category: :syntax,
      template: "WITH MATCH requires at least one WHEN arm.",
      summary:  "WITH MATCH block has no WHEN arms.",
    },
    SYNC_POLICY_NO_HANDLER: {
      severity: :error, category: :syntax,
      template: "SYNC POLICY block must contain at least one ON / RETRY handler.",
      summary:  "SYNC POLICY block needs at least one ON / RETRY clause.",
    },
    RETRY_N_NONPOSITIVE: {
      severity: :error, category: :syntax,
      template: "RETRY(N) requires N > 0, got %{got}",
      summary:  "RETRY count must be positive.",
    },
    EXPECTED_ERROR_SELECTOR: {
      severity: :error, category: :syntax,
      template: "Expected error selector: a kind like 'Transient' or a type like 'LockTimeout'",
      summary:  "ON / CATCH clause needs a kind name (e.g. Transient) or type name (e.g. LockTimeout).",
    },
    EXPECTED_AFTER_ERROR_CLAUSE: {
      severity: :error, category: :syntax,
      template: "Expected RAISE, PASS, RETURN <expr>, EXIT \"msg\", or -> { ... } after error clause",
      summary:  "ON / CATCH selector must be followed by an action.",
    },
    CATCH_WITH_BAD_INNER: {
      severity: :error, category: :syntax,
      template: "Expected a type name (e.g. ParseErr) or a string message inside CATCH WITH(...)",
      summary:  "`CATCH WITH(...)` filter takes a type or a string-literal message.",
    },

    # ===================================================================
    # PARSER — BG / branch prefixes / STUB / EXTERN / visibility
    # ===================================================================
    UNKNOWN_BRANCH_PREFIX: {
      severity: :error, category: :syntax,
      template: "Unknown branch prefix %{value}. Valid: @micro, @stack, @standard, @large, @xl, @service, @pinned, @parallel, @canSmash.",
      summary:  "Branch-prefix sigil on a DO block isn't recognised.",
    },
    DUPLICATE_STACK_SIZE: {
      severity: :error, category: :syntax,
      template: "Duplicate stack size in %{kind} prefix",
      summary:  "Two stack-size sigils (`@micro`, `@stack`, `@standard`, `@large`, `@xl`, `@service`) on one block.",
    },
    UNKNOWN_BG_PREFIX: {
      severity: :error, category: :syntax,
      template: "Unknown BG prefix %{value}",
      summary:  "BG-block prefix sigil isn't recognised.",
    },
    EXPECTED_THEN_AFTER_AS_BG: {
      severity: :error, category: :syntax,
      template: "Expected THEN after AS binding in BG block, got %{got}",
      summary:  "BG `{ AS name -> body }` binding must be followed by THEN.",
    },
    VISIBILITY_BAD_KIND: {
      severity: :error, category: :syntax,
      template: "Expected FN, METHOD, STRUCT, ENUM, or UNION after visibility modifier, got '%{got}'",
      summary:  "PUB / PRIVATE / PACKAGE must be followed by a declaration keyword.",
    },
    EXTERN_BAD_KIND: {
      severity: :error, category: :syntax,
      template: "Expected FN or STRUCT after EXTERN, got '%{got}'",
      summary:  "EXTERN must be followed by FN or STRUCT.",
    },
    STUB_BAD_AFTER: {
      severity: :error, category: :syntax,
      template: "Expected RETURNS, CAPTURES, SEQUENCE, or WITH after STUB %{fn}",
      summary:  "STUB <fn-name> must be followed by RETURNS, CAPTURES, SEQUENCE, or WITH.",
    },

    # ===================================================================
    # PARSER — IF / AS bindings / Auto / arrays / CONCURRENT
    # ===================================================================
    MULTIPLE_BINDINGS_NEED_PARENS: {
      severity: :error, category: :syntax,
      template: "Syntax Error: Multiple optional bindings require parentheses around each binding.\n  Found: IF expr AS name && expr AS name THEN\n  Use:   IF (expr AS name) && (expr AS name) THEN",
      summary:  "Optional-binding chains in IF need each `expr AS name` parenthesised.",
    },
    EXPECTED_IDENT_AFTER_AS: {
      severity: :error, category: :syntax,
      template: "Syntax Error: Expected identifier after 'AS', got %{got}",
      summary:  "`AS` binding requires a plain identifier as the new name.",
    },
    EXPECTED_NUMBER: {
      severity: :error, category: :syntax,
      template: "Expected a number, got %{value} (%{type})",
      summary:  "Numeric literal expected at this position.",
    },
    EXPECTED_SYMBOL_AFTER_COLON: {
      severity: :error, category: :syntax,
      template: "Expected a symbol name (lowercase identifier) after ':'",
      summary:  "After `:` in this context, the parser expects a lowercase symbol name.",
    },
    AUTO_NOT_ALLOWED_IN_FIELD: {
      severity: :error, category: :type,
      template: "Auto is not allowed in %{context} field declarations. Field '%{field}' must have a concrete type. Cross-callsite field inference is intentionally not supported -- replace `Auto` with the field's actual type (e.g. Int64, String, Foo[], HashMap<String, Bar>).",
      summary:  "`Auto` cannot be used as the type of a struct / union / enum field.",
    },
    AUTO_PREFIX_NOT_SUPPORTED: {
      severity: :error, category: :type,
      template: "`%{prefix}Auto` is not supported. `Auto` cannot be combined with the prefix `%{prefix2}` -- the inferred type's wrapping is not defined yet. Use `Auto` alone (the inferencer will pick the concrete type) or write the wrapped type explicitly (e.g. `%{prefix3}Int64`, `%{prefix4}String`).",
      summary:  "Sigil-prefixed `Auto` (e.g. `?Auto`, `!Auto`, `%Auto`) isn't supported.",
    },
    ARRAY_TYPE_BAD: {
      severity: :error, category: :syntax,
      template: "Syntax Error: Expected ']', '*', '?', 'INF', or size in array type.",
      summary:  "Array type opener `[` not followed by a recognised size / capacity marker.",
    },
    ARRAY_TYPE_EXPECTED_SIZE: {
      severity: :error, category: :syntax,
      template: "Syntax Error: Expected ']' or size in array type.",
      summary:  "Array-type size position needs a literal or a recognised marker.",
    },
    CONCURRENT_BAD_OP: {
      severity: :error, category: :syntax,
      template: "Expected SELECT, WHERE, EACH, SUM, COUNT, MIN, MAX, or AVERAGE after CONCURRENT, got %{got}",
      summary:  "CONCURRENT must be followed by a recognised pipeline stage.",
    },

    # ===================================================================
    # PARSER — generic Expected/Unexpected token
    # ===================================================================
    PARSER_EXPECTED: {
      severity: :error, category: :syntax,
      template: "Expected %{expected}, got %{got} (%{type}) line %{line}",
      summary:  "Generic Expected-X-got-Y. Used by the central `consume()` parser helper.",
    },
    UNEXPECTED_TOKEN_LINE: {
      severity: :error, category: :syntax,
      template: "Unexpected token %{value} (%{type}) line %{line}",
      summary:  "Generic Unexpected-token. Used when the primary parser hits a token outside its grammar.",
    },

    # ===================================================================
    # CAPABILITIES — WITH blocks, GUARD/RESTRICT/BORROWED, PRE/DEBUG_POST
    # ===================================================================
    # Added in Tranche 3. Migrated from
    # src/annotator-helpers/capabilities.rb's ad-hoc strings.

    WITH_CAP_BAD_TARGET: {
      severity: :error, category: :capability,
      template: "WITH %{capability} expects an identifier or field, got '%{got}'.",
      summary:  "WITH-block capture target must be a binding name or field, not an arbitrary expression.",
    },
    WITH_EXCLUSIVE_NEEDS_LOCK: {
      severity: :error, category: :capability,
      template: "EXCLUSIVE capability requires a @locked or @writeLocked variable, got %{got}",
      summary:  "WITH EXCLUSIVE only applies to bindings declared with `@locked` or `@writeLocked`.",
    },
    WITH_READ_NEEDS_WRITE_LOCK: {
      severity: :error, category: :capability,
      template: "WITH %{name}: read access requires a @writeLocked variable",
      summary:  "Read-style WITH on a `@locked` (read-only) cell is rejected — use `@writeLocked` if reads need to coexist with writes.",
    },
    WITH_RESTRICT_NEEDS_MUTABLE: {
      severity: :error, category: :capability,
      template: "RESTRICT capability requires a mutable variable, but '%{name}' is immutable",
      summary:  "WITH RESTRICT scopes mutable poisoning — the captured binding must itself be MUTABLE.",
    },
    WITH_MATERIALIZED_NEEDS_TENSE: {
      severity: :error, category: :capability,
      template: "WITH MATERIALIZED VIEW requires a `~T` (tense) source, got %{got} for '%{name}'.",
      summary:  "MATERIALIZED VIEW snapshots a tense / observable source — the binding must have type `~T`.",
    },
    WITH_SNAPSHOT_NEEDS_VERSIONED_OR_ATOMIC: {
      severity: :error, category: :capability,
      template: "WITH SNAPSHOT requires a @versioned or @indirect:atomic variable. '%{name}' is %{actual}. Declare the binding as `T@versioned` / `T@shared:versioned` for an MVCC cell, or `T@indirect:atomic` for a lock-free atomic-pointer cell.",
      summary:  "WITH SNAPSHOT only works on MVCC cells (`@versioned`) or atomic-pointer cells (`@indirect:atomic`).",
    },
    WITH_NEEDS_MULTIOWNED: {
      severity: :error, category: :capability,
      template: "WITH %{name}: expected a @multiowned variable",
      summary:  "Inferred capability requires a `@multiowned` (Rc) binding.",
    },
    WITH_NEEDS_SHARED: {
      severity: :error, category: :capability,
      template: "WITH %{name}: expected a @shared variable",
      summary:  "Inferred capability requires a `@shared` (Arc) binding.",
    },
    WITH_ATOMIC_NEEDS_SHARED_ATOMIC: {
      severity: :error, category: :capability,
      template: "WITH ATOMIC requires an @shared:atomic variable. '%{name}' is %{actual}, not @shared:atomic.",
      summary:  "WITH ATOMIC needs a binding declared `T@shared:atomic`.",
    },
    UNKNOWN_WITH_CAP_TYPE: {
      severity: :error, category: :capability,
      template: "Unknown capability type: %{type}",
      summary:  "Internal annotator error — WITH-block dispatch saw a capability tag it doesn't know.",
    },
    WITH_CANNOT_INFER_CAP: {
      severity: :error, category: :capability,
      template: "WITH %{name}: cannot infer capability; variable must be @multiowned, @shared, @locked, @writeLocked, @versioned, @shared:atomic, or another capability type",
      summary:  "Plain WITH without an explicit capability needs the binding to carry a recognised one.",
    },

    # WITH GUARD specifics
    WITH_GUARD_NOT_WITH_MATCH: {
      severity: :error, category: :capability,
      template: "WITH GUARD is not supported with WITH MATCH yet.",
      summary:  "WITH MATCH and WITH GUARD can't be combined in the current release.",
    },
    WITH_GUARD_NOT_ON_SNAPSHOT: {
      severity: :error, category: :capability,
      template: "WITH GUARD is not supported on mutable SNAPSHOT transactions in this release.",
      summary:  "Mutable SNAPSHOT transactions don't support WITH GUARD yet.",
    },
    WITH_GUARD_ALL_BINDINGS_NEED_AS: {
      severity: :error, category: :capability,
      template: "WITH GUARD requires every participating binding to have an AS alias so the guard can reference the unwrapped value.",
      summary:  "Each binding in a WITH GUARD must use `AS <name>` so the guard body can read it.",
    },
    WITH_GUARD_EXPR_MUST_BE_BOOL: {
      severity: :error, category: :capability,
      template: "WITH GUARD expression must return Bool, got %{got}.",
      summary:  "The guard predicate's type must be Bool.",
    },
    WITH_GUARD_REFS_SIBLING_ALIAS: {
      severity: :error, category: :capability,
      template: "WITH GUARD '%{own_alias}' references '%{name}', a sibling alias bound by the same WITH. Multi-object consistency for aliased objects is not supported: synchronized sources (locked, atomic, versioned) cannot provide a cross-object atomic snapshot, so a guard spanning multiple aliases would be checking values that are no longer consistent by the time the body runs. Each GUARD may only reference its own alias. %{remediation}",
      summary:  "A WITH GUARD predicate can only read its own alias, not sibling aliases bound by the same WITH.",
      cause: "A GUARD expression in a multi-binding WITH block refers to a sibling alias from the same WITH. The sibling isn't in scope yet at guard-evaluation time — guards run after each individual acquire, not after all of them.",
      fix_hint: "Move the guarded binding to its own WITH block, or restructure so the guard only references the binding it guards.",
    },
    WITH_GUARD_MUTABLE_MUTATED: {
      severity: :error, category: :capability,
      template: "WITH GUARD aliases cannot be MUTABLE and mutated inside the body: %{names} %{verb} declared MUTABLE and mutated inside the WITH. Only MUTABLE objects that change inside the body are rejected because their value could be modified after the GUARD predicate evaluates, silently invalidating it. Drop the mutation, drop MUTABLE from the alias, or move the mutation outside the guarded WITH.",
      summary:  "GUARD aliases mutated inside the body would silently invalidate the guard.",
    },

    # Borrow
    BORROW_WILDCARD_NEEDS_STRUCT: {
      severity: :error, category: :capability,
      template: "Wildcard borrow '*' requires a struct type, but '%{name}' is %{type}",
      summary:  "`WITH BORROWED x.*` only applies to struct-typed targets — it expands to per-field borrows.",
    },
    WITH_BORROWED_ON_QUALIFIED_VAR: {
      severity: :error, category: :capability,
      template: "Cannot use WITH BORROWED on %{qualifier} variable '%{name}'. %{remediation}",
      summary:  "WITH BORROWED rejected because the source binding is qualified in a way that conflicts.",
    },

    # PRE / DEBUG_POST
    PRE_EXPR_MUST_BE_BOOL: {
      severity: :error, category: :capability,
      template: "PRE expression must return Bool, got %{got}.",
      summary:  "PRE-condition must be a Bool-typed expression.",
    },
    DEBUG_POST_EXPR_MUST_BE_BOOL: {
      severity: :error, category: :capability,
      template: "DEBUG_POST expression must return Bool, got %{got}.",
      summary:  "DEBUG_POST predicate must be a Bool-typed expression.",
    },
    DEBUG_POST_NEEDS_UNSYNC_PARAM: {
      severity: :error, category: :capability,
      template: "DEBUG_POST cannot reference synchronized parameter '%{name}'. The predicate runs after the function returns and any locks have been released; reading a synchronized field outside its lock is racy. Move the check inside a WITH block in the body, or assert against an unsynchronized snapshot value instead.",
      summary:  "DEBUG_POST runs after lock release — referencing a synchronized parameter is a data race.",
    },
    DEBUG_POST_NOT_WITH_CATCH: {
      severity: :error, category: :capability,
      template: "DEBUG_POST clauses cannot be combined with CATCH on the same function. Split into two functions (one with CATCH, one with DEBUG_POST that calls it), or move the assertion into a separate validation helper.",
      summary:  "DEBUG_POST and CATCH on the same function aren't supported.",
    },

    # Purity / parallel restrictions
    PURE_FN_CANNOT_CALL_IMPURE: {
      severity: :error, category: :capability,
      template: "%{surface} must be pure, but '%{callee}' %{reason}. %{hint}",
      summary:  "A pure context (PRE / GUARD / etc) calls something that has observable side effects.",
    },
    LOCAL_VAR_NOT_IN_PARALLEL: {
      severity: :error, category: :capability,
      template: "@local variable cannot be used in @parallel block — it requires single-scheduler affinity.",
      summary:  "`@local` storage is per-scheduler; `@parallel` distributes across schedulers, breaking the affinity guarantee.",
    },
    MULTIOWNED_NOT_IN_PARALLEL: {
      severity: :error, category: :capability,
      template: "@multiowned (Rc) variable cannot be used in @parallel block — Rc uses a non-atomic reference count. Use @shared (Arc) for cross-scheduler sharing.",
      summary:  "`@multiowned` uses non-atomic refcounting and isn't safe across `@parallel` schedulers.",
    },

    # ===================================================================
    # PIPELINES — pipe stages, CONCURRENT, SHARD, JOIN, WINDOW
    # ===================================================================
    # Added in Tranche 4. Migrated from
    # src/annotator-helpers/pipe_analysis.rb's ad-hoc strings.

    PIPE_BAD_DESTINATION: {
      severity: :error, category: :type,
      template: "Invalid pipe destination. Must be a Function Call or Identifier.",
      summary:  "The right-hand side of `|>` must be a function call or a bare identifier.",
    },
    PIPE_NOT_CALLABLE: {
      severity: :error, category: :type,
      template: "Cannot pipe into non-callable '%{name}' (Resolved Type: %{type})",
      summary:  "Tried to pipe into something that isn't a function or method.",
    },
    COLLECT_NEEDS_OBSERVABLE: {
      severity: :error, category: :type,
      template: "COLLECT requires a `~T@observable` source, got %{got}. Streaming aggregates produce observables when the source is a tense stream; non-observable sources fold synchronously and don't need COLLECT.",
      summary:  "COLLECT only applies to observable sources (`~T@observable`).",
    },

    # Bool-required predicate clauses (WHERE / ANY / ALL / FIND / COUNT
    # / TAKE_WHILE). One template, parameterised by clause name; the
    # got-type goes in a third arg (empty when the type is unavailable).
    WHERE_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "WHERE clause must evaluate to Bool",
      summary:  "WHERE filter expression's type must be Bool.",
    },
    PIPE_CLAUSE_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "%{clause} clause must evaluate to Bool, got %{got}",
      summary:  "Predicate-style pipeline clauses (FIND / ANY / ALL / COUNT) need a Bool result.",
    },
    TAKE_WHILE_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "TAKE_WHILE predicate must evaluate to Bool, got %{got}",
      summary:  "TAKE_WHILE's predicate must produce a Bool.",
    },

    # Numeric-required aggregations (SUM / AVERAGE / MIN / MAX).
    PIPE_NEEDS_NUMERIC: {
      severity: :error, category: :type,
      template: "%{op} requires a numeric expression, got %{got}",
      summary:  "Numeric-aggregation stages (SUM / AVERAGE / MIN / MAX) require a numeric expression.",
    },

    # Collection-input checks
    EACH_NEEDS_COLLECTION: {
      severity: :error, category: :type,
      template: "Cannot EACH non-collection type %{got}. EACH requires an array, @list, @list:sharded(N), @pool, @pool:sharded(N), or a range",
      summary:  "EACH operates on collections only.",
    },
    TAP_NEEDS_COLLECTION: {
      severity: :error, category: :type,
      template: "Cannot TAP non-collection type %{got}.",
      summary:  "TAP operates on collections only.",
    },
    UNNEST_NEEDS_ARRAY: {
      severity: :error, category: :type,
      template: "UNNEST requires an array expression, got %{got}. Use SELECT instead for non-array fields.",
      summary:  "UNNEST flattens nested arrays — non-array inputs should use SELECT.",
    },
    SELECT_NEEDS_LIST: {
      severity: :error, category: :type,
      template: "Cannot SELECT from non-list type %{got}",
      summary:  "SELECT operates on list-shaped inputs.",
    },
    PIPE_OP_NEEDS_LIST: {
      severity: :error, category: :type,
      template: "Cannot %{op} non-list type %{got}",
      summary:  "Generic 'this pipeline op needs a list' — message names which op.",
    },
    CONCURRENT_EACH_BAD_INPUT: {
      severity: :error, category: :type,
      template: "CONCURRENT EACH input must be a finite stream or collection, got %{got}",
      summary:  "CONCURRENT EACH can't run on infinite streams.",
    },

    # WINDOW
    WINDOW_SIZE_NEEDS_NUMBER: {
      severity: :error, category: :type,
      template: "WINDOW size must be a number, got %{got}",
      summary:  "WINDOW size: option must be a numeric expression.",
    },
    WINDOW_SIZE_NEEDS_POSITIVE: {
      severity: :error, category: :type,
      template: "WINDOW size must be > 0",
      summary:  "WINDOW size: option must be a positive integer.",
    },
    WINDOW_TIME_NEEDS_STRING_LIT: {
      severity: :error, category: :type,
      template: "WINDOW time must be a string literal like '500ms' or '1s'",
      summary:  "WINDOW time: option needs a string literal in `<n><unit>` form.",
    },
    WINDOW_TIME_BAD_FORMAT: {
      severity: :error, category: :type,
      template: "WINDOW time format must be like '500ms', '1s', '2min', '1h', got '%{got}'",
      summary:  "WINDOW time: literal didn't match the supported unit shapes.",
    },
    WINDOW_TIME_NEEDS_POSITIVE: {
      severity: :error, category: :type,
      template: "WINDOW time must be > 0",
      summary:  "WINDOW time: must resolve to a positive duration.",
    },
    WINDOW_NEEDS_SIZE_OR_TIME: {
      severity: :error, category: :type,
      template: "WINDOW requires at least one of size: or time:",
      summary:  "WINDOW needs at least one of size: / time: to define the boundary.",
    },
    WINDOW_BAD_OPTION: {
      severity: :error, category: :type,
      template: "Unknown WINDOW option '%{name}', valid: %{valid}",
      summary:  "WINDOW option key isn't recognised.",
    },
    WINDOW_NEEDS_COLLECTION_INPUT: {
      severity: :error, category: :type,
      template: "WINDOW(size:, time:) requires a collection or stream input",
      summary:  "WINDOW only operates on collections / streams.",
    },

    # LIMIT / SKIP
    LIMIT_COUNT_NEEDS_NUMBER: {
      severity: :error, category: :type,
      template: "LIMIT count must be a number, got %{got}",
      summary:  "LIMIT N — N must be a numeric expression.",
    },
    SKIP_COUNT_NEEDS_NUMBER: {
      severity: :error, category: :type,
      template: "SKIP count must be a number, got %{got}",
      summary:  "SKIP N — N must be a numeric expression.",
    },

    # JOIN
    JOIN_RIGHT_NEEDS_LIST: {
      severity: :error, category: :type,
      template: "JOIN right source must be a list, got %{got}",
      summary:  "JOIN's right-hand source must be a list-shaped collection.",
    },
    JOIN_LAMBDA_ARITY: {
      severity: :error, category: :type,
      template: "JOIN lambda must take exactly 2 parameters",
      summary:  "JOIN's predicate lambda must accept exactly two arguments (left, right).",
    },
    JOIN_LAMBDA_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "JOIN lambda must return Bool, got %{got}",
      summary:  "JOIN's predicate lambda must produce Bool.",
    },

    # CONCURRENT options
    CONCURRENT_OPT_NEEDS_NUMBER: {
      severity: :error, category: :type,
      template: "CONCURRENT %{name} must be a number, got %{got}",
      summary:  "CONCURRENT numeric option (`capacity:`, `batch:`, etc.) needs a numeric expression.",
    },
    CONCURRENT_OPT_NEEDS_POSITIVE: {
      severity: :error, category: :type,
      template: "CONCURRENT %{name} must be greater than 0, got %{got}",
      summary:  "CONCURRENT numeric option must be > 0.",
    },
    CONCURRENT_CAPACITY_BAD_INPUT: {
      severity: :error, category: :type,
      template: "CONCURRENT capacity only applies to stream or sharded sources; use batch: N to control work chunking for collections",
      summary:  "`capacity:` is for stream / sharded inputs; collections use `batch:` instead.",
    },
    CONCURRENT_PARALLEL_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "CONCURRENT parallel must be a Bool (TRUE or FALSE), got %{got}",
      summary:  "`parallel:` accepts only TRUE / FALSE.",
    },
    CONCURRENT_SIZE_BAD_VALUE: {
      severity: :error, category: :type,
      template: "CONCURRENT size must be one of %{valid}, got %{got}",
      summary:  "`size:` must be one of the recognised stack sizes.",
    },
    CONCURRENT_UNKNOWN_OPTION: {
      severity: :error, category: :type,
      template: "Unknown CONCURRENT option '%{name}'. Valid options: %{valid}",
      summary:  "CONCURRENT option key isn't in the recognised set.",
    },
    CONCURRENT_BAD_FOLLOWING_OP: {
      severity: :error, category: :type,
      template: "CONCURRENT does not support %{got}",
      summary:  "CONCURRENT can only modify a recognised pipeline op (SELECT / WHERE / EACH / ...).",
    },

    # SHARD
    SHARD_NEEDS_RANGE_OR_COLLECTION: {
      severity: :error, category: :type,
      template: "SHARD input must be a range or collection, got %{got}",
      summary:  "SHARD distributes a range or collection across partitions.",
    },
    SHARD_TARGET_BAD: {
      severity: :error, category: :type,
      template: "SHARD target must be a HashMap@sharded(N) without :locked. %{remediation}",
      summary:  "SHARD into-clause needs a `HashMap@sharded(N)` without lock decoration.",
    },
    SHARD_KEY_NEEDS_STRING: {
      severity: :error, category: :type,
      template: "SHARD key expression must evaluate to String for a String-keyed map, got %{got}",
      summary:  "SHARD into a String-keyed map requires the key to resolve to String.",
    },
    SHARD_KEY_NEEDS_NUMERIC: {
      severity: :error, category: :type,
      template: "SHARD key expression must evaluate to a numeric type for %{map_key_type}-keyed map, got %{got}",
      summary:  "SHARD into a numeric-keyed map requires a numeric key.",
    },

    # Modifiers (RAISE etc)
    MODIFIER_NEEDS_ERROR_UNION: {
      severity: :error, category: :type,
      template: "%{name} requires the expression to return an error union (!T), but got %{got}",
      summary:  "Pipeline modifier (`RAISE`, `RECOVER`, etc.) needs an error-union-typed input.",
    },

    # ===================================================================
    # ANNOTATOR — control flow, assignment, indexing (Tranche 5a)
    # ===================================================================
    # Migrated from src/annotator.rb's ad-hoc strings. Templates copy
    # the existing user-facing wording verbatim.

    # Setup / imports / fn metadata
    REQUIRE_NEEDS_IMPORTER: {
      severity: :error, category: :registry,
      template: "REQUIRE is only supported when using the Importer. %{hint}",
      summary:  "REQUIRE statement reached annotation without an active importer (script-mode invocation).",
    },
    STYLE_MUTABLE_PARAM_NEEDS_BANG: {
      severity: :error, category: :ownership,
      template: "Style Error: Function '%{name}' has MUTABLE parameters. Its name must end in '!'",
      summary:  "Functions that take MUTABLE params should end with `!` to surface the mutation at every call site.",
    },

    # Reentrance
    REENTRANCE_DIRECT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' directly calls itself. %{hint}",
      summary:  "Function calls itself directly without an `@reentrant` annotation declaring the recursion budget.",
    },
    REENTRANCE_INDIRECT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' calls itself recursively. %{hint}",
      summary:  "Function reaches itself through a call chain without declaring the recursion budget.",
    },
    REENTRANCE_THUNK_NON_TAIL: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:THUNK on '%{name}' has non-tail recursion in %{hint}",
      summary:  "EFFECTS REENTRANT:THUNK requires the recursion to be in tail position; this call isn't.",
    },
    REENTRANCE_TAIL_CALL_NOT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "@reentrant:tailCall on '%{name}' but the function is not recursive. %{hint}",
      summary:  "`@reentrant:tailCall` declared on a function that doesn't recurse.",
    },

    # IF / MATCH / WHEN
    IF_AS_NEEDS_OPTIONAL: {
      severity: :error, category: :type,
      template: "IF ... AS binding requires an optional type, got '%{got}'",
      summary:  "`IF expr AS name THEN ...` requires `expr` to be optional (`?T`).",
    },
    MATCH_NEEDS_STRUCT_TYPE: {
      severity: :error, category: :type,
      template: "MATCH struct pattern requires a struct type, got %{got}",
      summary:  "MATCH with a struct-shaped pattern requires the matched expression to be a struct.",
    },
    MATCH_FIELD_UNKNOWN: {
      severity: :error, category: :type,
      template: "MATCH struct pattern: field '%{field}' does not exist on type %{type}",
      summary:  "MATCH struct pattern references a field the struct doesn't declare.",
    },
    MATCH_FIELD_TYPE_MISMATCH: {
      severity: :error, category: :type,
      template: "MATCH struct pattern: field '%{field}' has type %{declared}, but pattern value has type %{got}",
      summary:  "MATCH struct-pattern field comparison's literal type doesn't match the field's declared type.",
    },
    WHEN_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "WHEN condition must be Bool, got %{got}",
      summary:  "MATCH ... WHEN clause's condition must be Bool-typed.",
    },
    MATCH_CASE_TYPE_MISMATCH: {
      severity: :error, category: :type,
      template: "MATCH case type %{case} does not match expression type %{expr}",
      summary:  "MATCH case literal's type doesn't match the matched expression's type.",
    },
    MATCH_DESTRUCTURE_FIELD_UNKNOWN: {
      severity: :error, category: :type,
      template: "MATCH destructure: field '%{field}' does not exist on variant %{variant}",
      summary:  "MATCH inline-struct-variant destructure references a field the variant doesn't declare.",
    },

    # FOR / WHILE / IF / BREAK / CONTINUE / ASSERT
    FOR_RANGE_START_NEEDS_INT64: {
      severity: :error, category: :type,
      template: "FOR range start must be Int64, got %{got}",
      summary:  "`FOR i IN (a ..< b)` — `a` must be Int64.",
    },
    FOR_RANGE_END_NEEDS_INT64: {
      severity: :error, category: :type,
      template: "FOR range end must be Int64, got %{got}",
      summary:  "`FOR i IN (a ..< b)` — `b` must be Int64.",
    },
    FOR_IN_NEEDS_COLLECTION: {
      severity: :error, category: :type,
      template: "FOR ... IN requires an array, list, or map, got %{got}",
      summary:  "`FOR x IN coll` — `coll` must be a collection.",
    },
    CONDITION_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "Condition must be a Boolean, got %{got}",
      summary:  "IF / WHILE condition must be Bool-typed.",
    },
    USE_OF_MOVED_IN_LOOP: {
      severity: :error, category: :ownership,
      template: "%{message}",
      summary:  "Loop body consumes a value on the first iteration; subsequent iterations have nothing left to GIVE.",
      cause: "An affine value can only be TAKEN once. The loop body moves (GIVE / TAKES / RETURN / etc.) the binding, so the second iteration would be reading something that's already been transferred.",
      fix_hint: "Hoist the move out of the loop, or wrap the consuming reference with `COPY` (if the type permits) so each iteration gets its own owned copy. For shared aggregation, declare the binding `@multiowned` (single-scheduler Rc) or `@shared` (cross-fiber Arc).",
    },
    USE_OF_MOVED_VALUE: {
      severity: :error, category: :ownership,
      template: "%{message}",
      summary:  "Binding was already TAKEN / GIVEN at a prior site and is no longer accessible.",
      cause: "An affine binding has exactly one owner. A prior expression (a `TAKES` parameter, `GIVE`, `RETURN`, `SHARE`, `NEXT`, etc.) consumed ownership; the current use is left holding nothing.",
      fix_hint: "Wrap the consuming reference with `COPY` (if the type permits — primitives, strings, and enums are Copy by default; non-Copy types need `@multiowned` / `@shared` to share). Or restructure so only one site consumes the value.",
    },
    USE_OF_MOVED_IN_LOOP_SHORT: {
      severity: :error, category: :ownership,
      template: "%{message}",
      summary:  "Loop body uses a value that was already TAKEN on a prior iteration.",
      cause: "Same as USE_OF_MOVED_IN_LOOP — the binding was consumed on the first iteration; the second iteration has nothing left to GIVE.",
      fix_hint: "Same: hoist the move out of the loop, or `COPY` per-iteration, or upgrade to `@multiowned` / `@shared`.",
    },
    USE_OF_MOVED_PATH: {
      severity: :error, category: :ownership,
      template: "%{message}",
      summary:  "Path's owner (root binding) was already TAKEN or GIVEN; sub-paths are no longer accessible.",
      cause: "Sub-path access (`b.field`, `arr[i]`) reads through an owner. If the owner itself was transferred (TAKES / GIVE / RETURN / etc.), the sub-path goes with it — the owner takes its fields along.",
      fix_hint: "Either consume the field directly (`GIVE b.field`) before the owner is transferred, or `COPY` the field, or restructure so the owner isn't moved before the field's last use.",
    },
    WHILE_AS_NEEDS_OPTIONAL: {
      severity: :error, category: :type,
      template: "WHILE ... AS binding requires an optional type, got '%{got}'",
      summary:  "`WHILE expr AS name DO ...` requires `expr` to be optional (`?T`).",
    },
    WHILE_AS_IMMUTABLE_RECEIVER: {
      severity: :error, category: :ownership,
      template: "WHILE ... AS binding: '%{method}' is called on immutable '%{recv}' -- the condition cannot advance and may loop forever. Declare '%{recv2}' as MUTABLE or use a regular WHILE loop.",
      summary:  "`WHILE recv.next() AS x` would never terminate if `recv` is immutable.",
    },
    BREAK_OUTSIDE_LOOP: {
      severity: :error, category: :type,
      template: "BREAK must be used inside a loop",
      summary:  "BREAK only makes sense inside a FOR / WHILE body.",
    },
    CONTINUE_OUTSIDE_LOOP: {
      severity: :error, category: :type,
      template: "CONTINUE must be used inside a loop",
      summary:  "CONTINUE only makes sense inside a FOR / WHILE body.",
    },
    ASSERT_NEEDS_BOOL: {
      severity: :error, category: :type,
      template: "Assert condition must be Boolean",
      summary:  "ASSERT's predicate must be Bool-typed.",
    },

    # RETURN / WITH-scoped escape
    RETURN_VOID_FROM_TYPED: {
      severity: :error, category: :type,
      template: "Function expects return type %{expected}, got Void",
      summary:  "Function returns nothing on a path where its declared return type expects a value.",
    },
    RETURN_FROM_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot RETURN '%{name}' from inside a WITH block. %{hint}",
      summary:  "WITH-scoped aliases (`AS x`) are non-escaping — they can't be returned.",
      cause: "A WITH ... AS alias block creates a scoped binding that doesn't outlive the WITH body. Returning the alias would let the caller see a value whose backing storage is gone.",
      fix_hint: "Either RETURN COPY alias (breaks the borrow), or restructure so the value's lifetime exceeds the WITH (move the value out of the cell before the WITH body ends).",
    },
    RETURN_FIELD_FROM_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot RETURN a field of a WITH-scoped binding. %{hint}",
      summary:  "Field of a WITH-scoped binding can't be returned (would outlive the WITH).",
    },
    RETURN_INDEX_FROM_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot RETURN an indexed access of a WITH-scoped binding. %{hint}",
      summary:  "Indexed access on a WITH-scoped binding can't be returned (would outlive the WITH).",
    },

    # Function calls
    INTRINSIC_NO_OVERLOAD: {
      severity: :error, category: :type,
      template: "No overload for '%{name}' matches arguments (%{args}).\nCandidates: %{candidates}",
      summary:  "Stdlib function has overloads but none match the call's argument types.",
    },

    # Atomic compound ops
    ATOMIC_NO_MUL_DIV_COMPOUND: {
      severity: :error, category: :capability,
      template: "Atomic primitives do not support `%{op}`. %{hint}",
      summary:  "Compound `*=` / `/=` not available on `@shared:atomic` targets.",
    },
    ATOMIC_UNSUPPORTED_COMPOUND: {
      severity: :error, category: :capability,
      template: "Compound op %{op} is not supported on @shared:atomic targets.",
      summary:  "Compound op other than `+=` / `-=` / `&=` / `|=` / `^=` not available on `@shared:atomic`.",
    },

    # Assignment
    INVALID_ASSIGNMENT_TARGET: {
      severity: :error, category: :type,
      template: "Invalid assignment target: %{got}",
      summary:  "Left-hand side of `=` must be an identifier, field access, or index expression.",
    },
    ASSIGN_UNDEFINED_VAR: {
      severity: :error, category: :type,
      template: "Cannot assign to undefined variable '%{name}'",
      summary:  "Assignment target was never declared in any enclosing scope.",
    },
    ASSIGN_VAR_IMMUTABLE: {
      severity: :error, category: :ownership,
      template: "Variable '%{name}' is immutable",
      summary:  "Assignment target was declared without `MUTABLE`.",
    },
    ASSIGN_INDEX_IMMUTABLE_LIST: {
      severity: :error, category: :ownership,
      template: "Cannot modify index of immutable list '%{name}'",
      summary:  "Indexed write on a list whose binding is not MUTABLE.",
    },
    ASSIGN_FIELD_IMMUTABLE_STRUCT: {
      severity: :error, category: :ownership,
      template: "Cannot modify field of immutable struct '%{name}'",
      summary:  "Field write on a struct whose binding is not MUTABLE.",
    },
    TYPE_MISMATCH_ASSIGN: {
      severity: :error, category: :type,
      template: "Type Mismatch: Cannot assign %{got} to %{expected}",
      summary:  "Right-hand side's type doesn't fit the assignment target's type.",
      cause: "The value being assigned to an existing binding doesn't match the binding's declared type. Coercion was tried and failed.",
      fix_hint: "Either change the value, change the declared type at the binding's declaration site, or use CAST for an explicit conversion.",
    },

    # Indexing / hashmap / strings
    NUMERIC_MAP_KEY_BAD: {
      severity: :error, category: :type,
      template: "Numeric map keys must be a number type, got %{got}",
      summary:  "HashMap with numeric keys was indexed with a non-numeric value.",
    },
    STRING_MAP_KEY_BAD: {
      severity: :error, category: :type,
      template: "Map keys must be Strings, got %{got}",
      summary:  "HashMap with String keys was indexed with a non-String value.",
    },
    STRING_INDEX_BY_INT: {
      severity: :error, category: :type,
      template: "Cannot index String by integer. Use String@raw for byte access, or .codepoints() for iteration.",
      summary:  "Plain String can't be indexed by integer — use `String@raw` or codepoint iteration.",
    },
    UNSUPPORTED_INDEX: {
      severity: :error, category: :type,
      template: "Unsupported Index",
      summary:  "Indexing-by-int isn't supported on this type.",
    },

    # Containers / unions / structs / generics in annotator
    HASHMAP_MIXED_VALUES: {
      severity: :error, category: :type,
      template: "HashMap must have all values be the same type",
      summary:  "HashMap literal contains values of different types.",
    },
    UNKNOWN_STRUCT_TYPE: {
      severity: :error, category: :type,
      template: "Unknown struct type: '%{name}'",
      summary:  "Struct literal references a struct name that wasn't declared.",
    },
    UNION_LITERAL_VARIANT_COUNT: {
      severity: :error, category: :type,
      template: "Union literal '%{name}' must specify exactly one variant, got %{got}.",
      summary:  "Union literal `T{ Variant: ... }` must list exactly one variant.",
    },
    UNION_VARIANT_IS_UNIT_NO_PAYLOAD: {
      severity: :error, category: :type,
      template: "Union variant '%{variant}' is a unit variant — use '%{union}.%{variant2}' (no payload).",
      summary:  "Tried to construct a unit variant with payload syntax.",
    },
    STRUCT_LITERAL_MISSING_FIELDS: {
      severity: :error, category: :type,
      template: "Cannot use '%{name}{}' — field(s) %{fields} have no default values",
      summary:  "Struct literal omits required fields (no defaults declared).",
    },

    # ===================================================================
    # ANNOTATOR — types, ownership ops, BG, lifetimes (Tranche 5b)
    # ===================================================================

    # Struct fields / lists / streams / ranges
    FIELD_TYPE_MISMATCH: {
      severity: :error, category: :type,
      template: "Field '%{field}' expected %{expected}, got %{got}",
      summary:  "Struct literal field's value type doesn't match the field's declared type.",
    },
    BOUNDED_STREAM_MIXED_TYPES: {
      severity: :error, category: :type,
      template: "Bounded stream literal contains mixed promise types: %{types}. All BG blocks must produce the same type.",
      summary:  "`~T[]` bounded-stream literal must have homogeneous BG-block types.",
    },
    LIST_LITERAL_MIXED_TYPES: {
      severity: :error, category: :type,
      template: "List literal contains mixed types: First item is %{base}, item %{index} is %{got}",
      summary:  "List literal elements have inconsistent types.",
    },
    RANGE_START_NEEDS_NUMERIC: {
      severity: :error, category: :type,
      template: "Range start must be a numeric type, got %{got}",
      summary:  "`a ..< b` — `a` must be a numeric type.",
    },
    RANGE_END_NEEDS_NUMERIC: {
      severity: :error, category: :type,
      template: "Range end must be a numeric type, got %{got}",
      summary:  "`a ..< b` — `b` must be a numeric type.",
    },
    UNKNOWN_LITERAL: {
      severity: :error, category: :type,
      template: "UNKNOWN LITERAL!",
      summary:  "Internal annotator error — saw a literal node it doesn't know how to type-infer.",
    },
    TYPE_ERROR_GENERIC: {
      severity: :error, category: :type,
      template: "Type Error: %{message}",
      summary:  "Generic type-error wrapper for messages produced elsewhere (e.g., Type#coerce_error).",
    },

    # OR / IF expression / unwrap
    OR_BREAK_OUTSIDE_WHILE: {
      severity: :error, category: :type,
      template: "OR BREAK can only be used inside a WHILE loop",
      summary:  "`expr OR BREAK` is only valid inside a WHILE loop body.",
    },
    TYPE_MISMATCH_IN_OR: {
      severity: :error, category: :type,
      template: "Type mismatch in OR: expected %{expected}, got %{got}",
      summary:  "Right-hand side of `OR` must match the optional/error-union's payload type.",
    },
    UNWRAP_NON_OPTIONAL: {
      severity: :error, category: :type,
      template: "Cannot unwrap non-optional type '%{got}' with '?'",
      summary:  "`expr?` only applies to optional types (`?T`).",
    },
    IF_EXPR_THEN_NEEDS_VALUE: {
      severity: :error, category: :type,
      template: "IF expression: THEN branch must end with a value expression",
      summary:  "When IF is used as an expression, the THEN branch's last statement must be a value.",
    },
    IF_EXPR_NEEDS_ELSE: {
      severity: :error, category: :type,
      template: "IF used as expression requires an ELSE branch",
      summary:  "Expression-form IF must cover all paths via an ELSE.",
    },
    IF_EXPR_ELSE_NEEDS_VALUE: {
      severity: :error, category: :type,
      template: "IF expression: ELSE branch must end with a value expression",
      summary:  "Expression-form IF's ELSE branch must end with a value.",
    },
    IF_EXPR_BRANCHES_INCOMPATIBLE: {
      severity: :error, category: :type,
      template: "IF expression branches have incompatible types: THEN returns %{then_type}, ELSE returns %{else_type}",
      summary:  "Expression-form IF needs both branches to produce the same type.",
    },
    IF_EXPR_RESULT_NOT_COPYABLE: {
      severity: :error, category: :type,
      template: "IF expression result type '%{type}' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-IF with RETURN for heap-allocated values.",
      summary:  "Expression-form IF only supports implicitly-copyable result types.",
    },
    MATCH_EXPR_BRANCH_NEEDS_VALUE: {
      severity: :error, category: :type,
      template: "MATCH expression: every branch must end with a value expression",
      summary:  "Expression-form MATCH needs every branch to end with a value.",
    },
    MATCH_EXPR_NEEDS_CASE: {
      severity: :error, category: :type,
      template: "MATCH expression must have at least one case",
      summary:  "Expression-form MATCH with no cases would have no value.",
    },
    MATCH_EXPR_BRANCHES_INCOMPATIBLE: {
      severity: :error, category: :type,
      template: "MATCH expression branches have incompatible types: %{types}",
      summary:  "Expression-form MATCH branches must produce the same type.",
    },
    MATCH_EXPR_RESULT_NOT_COPYABLE: {
      severity: :error, category: :type,
      template: "MATCH expression result type '%{type}' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-MATCH for heap-allocated values.",
      summary:  "Expression-form MATCH only supports implicitly-copyable result types.",
    },

    # Capability / MOVE / GIVE / COPY / SHARE / LINK / FREEZE / CLONE / RESOLVE
    CAPABILITY_ON_PRIMITIVE: {
      severity: :error, category: :capability,
      template: "Capability @%{cap} cannot be applied to primitive type %{type}. %{hint}",
      summary:  "Sigils that wrap a value (`@multiowned`, `@shared`, `@locked`, ...) only apply to heap-managed types.",
    },
    MOVE_NEEDS_IDENTIFIER: {
      severity: :error, category: :ownership,
      template: "MOVE can only be applied to a variable identifier",
      summary:  "`MOVE expr` requires `expr` to be a bare binding name.",
    },
    GIVE_ON_COPY_TYPE: {
      severity: :error, category: :ownership,
      template: "GIVE cannot be applied to Copy types (%{type} is implicitly copyable)",
      summary:  "Implicitly-copyable values don't need GIVE — they get copied automatically.",
    },
    STORE_WITH_SCOPED_INTO_CONTAINER: {
      severity: :error, category: :escape,
      template: "Cannot store WITH-scoped '%{name}' into %{container}. WITH bindings cannot escape their block.",
      summary:  "WITH-scoped binding can't be persisted into a container that outlives the WITH.",
    },
    STORE_STRING_NEEDS_COPY: {
      severity: :error, category: :ownership,
      template: "Cannot store string variable '%{name}' into %{container} without COPY. Strings are frame-arena managed; use COPY for heap ownership.",
      summary:  "Frame-arena strings need COPY before storing into a longer-lived container.",
    },
    LINK_NEEDS_SHARED_OR_MULTIOWNED: {
      severity: :error, category: :ownership,
      template: "LINK can only be applied to @shared or @multiowned variables, got '%{got}'",
      summary:  "LINK creates a weak reference and only applies to refcounted bindings.",
    },
    RESOLVE_NEEDS_LINK: {
      severity: :error, category: :ownership,
      template: "RESOLVE can only be applied to @link variables, got '%{got}'",
      summary:  "RESOLVE upgrades a `@link` weak ref into an optional strong ref.",
    },
    FREEZE_NEEDS_OWNED: {
      severity: :error, category: :ownership,
      template: "FREEZE can only be applied to @multiowned or @shared values, got '%{got}'",
      summary:  "FREEZE turns an owned refcount handle into immutable shared data.",
    },
    GIVE_BAD_TARGET: {
      severity: :error, category: :ownership,
      template: "GIVE can only be used on variables, fields, or array elements",
      summary:  "GIVE must name a place — not an expression result.",
    },
    COPY_NON_COPYABLE: {
      severity: :error, category: :ownership,
      template: "Cannot COPY non-copyable type '%{type}'",
      summary:  "Some types (e.g., closed streams, raw fds) deliberately have no COPY semantics.",
    },
    CLONE_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot CLONE WITH-scoped '%{name}'. WITH bindings are protected borrows; use COPY to return owned data.",
      summary:  "CLONE on a WITH-scoped binding would create another reference that outlives the WITH.",
    },
    CLONE_BAD_TARGET: {
      severity: :error, category: :ownership,
      template: "CLONE is only supported on @split streams, @shared promises, and owned shared handles, got '%{got}'",
      summary:  "CLONE has a narrow set of supported targets.",
    },
    SHARE_NEEDS_TYPED: {
      severity: :error, category: :ownership,
      template: "SHARE requires a typed value",
      summary:  "SHARE can't be applied to a value with no resolvable type.",
    },
    SHARE_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot SHARE WITH-scoped '%{name}'. WITH bindings are protected borrows; use COPY to return owned data.",
      summary:  "SHARE on a WITH-scoped binding would create a reference that outlives the WITH.",
    },

    # ON / RETRY / SELECTORS
    ON_RETRY_NEEDS_FALLIBLE_CAP: {
      severity: :error, category: :capability,
      template: "ON / RETRY clause requires a WITH capability that can fail %{hint}",
      summary:  "ON / RETRY only attaches to WITH captures whose acquire can fail (locks with timeouts, snapshots, etc).",
    },
    SELECTORS_NO_MATCH: {
      severity: :error, category: :capability,
      template: "Selectors [%{matched}] do not match %{possible}",
      summary:  "ON-clause error selectors don't match any of the WITH captures' fallible kinds.",
    },

    # BG / DO block
    DO_CAPTURES_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "DO block captures a WITH-scoped (BORROWED/RESTRICT) binding. %{hint}",
      summary:  "DO branches can't capture WITH-scoped bindings — they must end with the WITH.",
    },
    BG_STREAM_NO_YIELD: {
      severity: :error, category: :type,
      template: "BG STREAM block has no YIELD statements. Use BG { } for a plain promise.",
      summary:  "BG STREAM without YIELD has no stream output — use BG instead.",
    },
    BG_STREAM_INCONSISTENT_YIELD: {
      severity: :error, category: :type,
      template: "BG STREAM block yields inconsistent types: %{types}. All YIELD expressions must produce the same type.",
      summary:  "BG STREAM produces a typed stream; every YIELD must produce the same element type.",
    },
    BG_STREAM_CAPTURES_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "BG STREAM block captures a WITH-scoped (BORROWED/RESTRICT) binding. %{hint}",
      summary:  "BG STREAM fibers outlive the WITH — they can't capture WITH-scoped bindings.",
    },
    YIELD_OUTSIDE_BG_STREAM: {
      severity: :error, category: :type,
      template: "YIELD can only be used inside a BG STREAM { } block.",
      summary:  "YIELD only makes sense inside BG STREAM bodies.",
    },
    BG_ARENA_AND_PARALLEL: {
      severity: :error, category: :capability,
      template: "@arena cannot be combined with @parallel — arena memory is thread-local and cannot be stolen.",
      summary:  "`@arena` storage is per-scheduler; `@parallel` work-steals across schedulers, breaking arena affinity.",
    },
    BG_CAPTURES_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "BG block captures a WITH-scoped (BORROWED/RESTRICT) binding. %{hint}",
      summary:  "BG fibers outlive the WITH — they can't capture WITH-scoped bindings.",
      cause: "A BG block captured a binding whose lifetime is bounded by an enclosing WITH alias. The fiber may outlive the WITH body — the capture would dangle.",
      fix_hint: "Either capture a longer-lived value (the original binding the WITH aliases, or a COPY), restructure so the BG runs inside the WITH and finishes before it exits, or use SHARE to extend the lifetime via Arc.",
    },
    BG_PINNED_CAPTURE_MISMATCH: {
      severity: :error, category: :capability,
      template: "BG block inside @pinned scope captures local variables but is not @pinned. %{hint}",
      summary:  "BG blocks inside `@pinned` scopes that capture locals must themselves be `@pinned`.",
    },

    # NEXT / move / borrow
    NEXT_NEEDS_FUTURE: {
      severity: :error, category: :type,
      template: "NEXT requires a future value (~T), got %{got}",
      summary:  "NEXT awaits a `~T` (future / stream) — the operand must be one.",
    },
    MOVE_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot move WITH-scoped '%{name}'. WITH bindings cannot escape their block.",
      summary:  "Moving a WITH-scoped binding would let it escape — rejected.",
    },
    MOVE_BORROWED_INDEX: {
      severity: :error, category: :ownership,
      template: "Cannot move borrowed value from '%{source}' (container index is a borrow). Use COPY for an explicit deep-copy.",
      summary:  "Indexed access borrows from the container — moves out aren't allowed.",
    },
    MOVE_BORROWED_PARAM: {
      severity: :error, category: :ownership,
      template: "Cannot move borrowed value '%{name}'. Parameters are implicit borrows unless TAKES.",
      summary:  "Function parameters are borrows; declare TAKES to allow moves out.",
      cause: "MOVE / GIVE attempted to take ownership of a parameter that was passed as a borrow. Borrow parameters can't be moved — the caller still owns the value.",
      fix_hint: "If the function should consume the parameter, declare it with TAKES at the parameter site. If the function should leave the caller's value intact, COPY the value before moving from the copy.",
    },
    BORROWED_VAR_NOT_FOUND: {
      severity: :error, category: :ownership,
      template: "Variable not found",
      summary:  "Borrow analysis couldn't find the binding being borrowed.",
    },
    LIFETIME_ALREADY_BORROWED: {
      severity: :error, category: :ownership,
      template: "Lifetime Error: '%{name}' (or part of it) is already borrowed.",
      summary:  "Borrow checker rejects a second simultaneous borrow.",
      cause: "A binding was borrowed (via WITH / BORROWED / RESTRICT) and the borrow is still live when a second borrow / mutation was attempted. CLEAR enforces single-mutable-borrow via lifetime tracking.",
      fix_hint: "End the existing borrow (close the WITH block) before starting a new one. If the operations need to interleave, restructure so they don't overlap, or use a synchronization primitive.",
    },
    ASSIGN_WHILE_BORROWED: {
      severity: :error, category: :ownership,
      template: "Lifetime Error: Cannot assign to '%{name}' because it is currently borrowed.",
      summary:  "Borrow checker rejects mutation while a borrow is live.",
    },

    # Promise tracking
    PROMISE_NOT_CONSUMED: {
      severity: :error, category: :ownership,
      template: "Promise '%{name}' must be consumed before it goes out of scope. Use NEXT, COLLECT, or RETURN it.",
      summary:  "Every BG promise must be awaited (NEXT) or otherwise consumed before its scope ends.",
      cause: "A `~T` promise binding fell out of scope without being awaited or moved into a longer-lived owner. Unawaited promises leak the underlying allocation and represent silent fire-and-forget work.",
      fix_hint: "Either AWAIT the promise to get the value, MOVE it to a binding that outlives the current scope (return, struct field, longer-lived pool), or explicitly DROP it if the result is discardable.",
    },

    # EFFECTS REENTRANT:TAIL_CALL specifics
    TAIL_CALL_NEEDS_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:TAIL_CALL on '%{fn}' requires at least one %{hint}",
      summary:  "TAIL_CALL requires the function to actually contain a tail-recursive call.",
    },
    TAIL_CALL_NOT_TAIL_POSITION: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:TAIL_CALL: '%{fn}' is called in non-tail position. %{hint}",
      summary:  "TAIL_CALL declared but the recursive call site isn't in tail position.",
    },

    # Stack safety
    STACK_SAFETY_MUTUAL_RECURSION: {
      severity: :error, category: :reentrance,
      template: "Stack safety: this fiber transitively calls '%{callee}' %{hint}",
      summary:  "Stack-tier analysis found mutual recursion that can't be bounded.",
    },
    STACK_SAFETY_USER_SIZE_TOO_SMALL: {
      severity: :error, category: :reentrance,
      template: "Stack safety: @%{size} (%{budget} bytes) %{hint}",
      summary:  "User-declared stack tier is too small for the fiber's worst-case path.",
    },

    # Borrow store
    STORE_BORROWED_INTO_CONTAINER: {
      severity: :error, category: :ownership,
      template: "Cannot store borrowed value '%{name}' into %{container}. Use COPY for an explicit deep-copy.",
      summary:  "Borrowed values can't be persisted into containers — they don't own the underlying memory.",
    },

    # ===================================================================
    # MIR CHECKER (post-lowering invariants)
    # ===================================================================
    # These mirror the codes already used by `MIRChecker#error`. They
    # are listed here for unification — `clear explain` can document
    # them alongside the rest. The MIR checker still uses its own
    # `error(:KIND, fn, msg)` formatter for now; migrating that
    # emit path is a follow-up.
    HPT_LEAK: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Heap-returning call result discarded — the allocated value never gets cleanup.",
      cause: "A call that allocates on the heap (e.g. `makeList`, `clone`, `intToString`) appeared in statement position without being bound to a variable. The MIR checker has no AllocMark to verify lifetime, so the heap allocation is structurally a leak.",
      fix_hint: "Bind the result: `result = heapCall(...)` so the lowering inserts an AllocMark + matching Cleanup. If you genuinely don't need the value, bind to `_` to make the discard explicit.",
    },
    ALLOC_WITHOUT_CLEANUP: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR::AllocMark with no matching Cleanup or ErrCleanup on every path.",
      cause: "Every heap allocation must have a matching cleanup on every control-flow path, including error paths and early returns. The checker found a path where the AllocMark is reachable but no Cleanup/ErrCleanup is.",
      fix_hint: "Usually a lowering bug — the cleanup classifier should have inserted the cleanup. Check src/mir/promotion_plan.rb. If your code has an unusual control-flow shape (early RETURN inside a complex block), that path may need explicit attention.",
    },
    CLEANUP_WITHOUT_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR::Cleanup or ErrCleanup with no matching AllocMark — orphan cleanup.",
      cause: "The MIR has a Cleanup node naming a binding the AllocMark side never declared. Means the lowering emitted cleanup for a value the allocator never tracked — runtime would try to free unknown memory.",
      fix_hint: "Lowering bug — the cleanup classifier disagreed with the alloc classifier. Trace the binding name through promotion_plan.rb.",
    },
    ALLOC_CLEANUP_MISMATCH: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Cleanup's allocator (heap/frame) doesn't match its AllocMark's allocator.",
      cause: "AllocMark allocated on heap but Cleanup is freeing on frame, or vice versa. Calling `frame.free()` on heap memory (or `heap.free()` on frame memory) is an allocator mismatch — runtime crash or corruption.",
      fix_hint: "Lowering bug — the per-binding allocator decision drifted between alloc and cleanup. Check that promotion_plan.rb gives both nodes the same allocator stamp.",
    },
    INLINE_ALLOC_MISMATCH: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "InlineZig op uses an allocator that doesn't match the container's AllocMark.",
      cause: "Storing frame-allocated data into a heap container (or heap data into a frame container) leaves dangling pointers after frame rewind. The checker compares the InlineZig op's `:alloc` / `:key_alloc` / `:val_alloc` against the container's AllocMark allocator and rejects mismatches.",
      fix_hint: "Make the container's allocator and the inserted data's allocator agree. Usually the fix is upgrading the container to heap (`@list:heap` or assignment-time promotion) or making the inserted data heap-owned.",
    },
    INLINE_NO_CONTRACT: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "InlineZig calls CheatLib without a stdlib_def — checker can't see ownership effects.",
      cause: "`MIR::InlineZig` whose Zig text calls `CheatLib.<fn>` must declare a `stdlib_def` so the checker knows which calls allocate, take ownership, etc. Without it, ownership analysis is blind across the inline.",
      fix_hint: "Add `stdlib_def: { allocates: ..., return: ... }` matching the registry entry for the called CheatLib helper, or replace the InlineZig with a registered stdlib call shape that the lowering already handles.",
    },
    RAW_NO_CONTRACT: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "RawZig with allocating CheatLib calls and no ownership_contract.",
      cause: "Same as INLINE_NO_CONTRACT but for `MIR::RawZig` (the unsafer escape hatch). Allocating CheatLib calls inside RawZig need an explicit `ownership_contract` so the checker can see them.",
      fix_hint: "Add an `ownership_contract` declaring the allocations and ownership transfers. Strongly consider replacing the RawZig with an InlineZig + stdlib_def, or with a stdlib registry entry, since RawZig is the last-resort form.",
    },
    RAW_UNJUSTIFIED: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "RawZig used without a justifying need (use stdlib registries instead).",
      cause: "RawZig is the unsafest emit path and must be reserved for cases the registries truly can't express. The checker found a RawZig whose call shape could be expressed via STD_LIB / POOL_METHODS / SET_METHODS / MAP_METHODS / INDEX_OPS instead.",
      fix_hint: "Move the operation to the appropriate stdlib registry. The registries support effects, ownership, alloc, and ranged metadata — a RawZig is only justified when none of those mechanisms cover the case.",
    },
    FRAME_NO_REWIND: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Loop body frame-allocates but has no per-iteration restoreLoopMark defer.",
      cause: "A loop whose body frame-allocates (a `String[]@list = []` per iteration, an interpolated string, etc.) needs save/restore around each iteration so the arena rewinds between rounds. Without it, the frame grows unboundedly with each loop turn.",
      fix_hint: "Lowering bug if the loop is non-TIGHT — the mark/restore should have been inserted automatically. If the loop is TIGHT, that's the cause: TIGHT skips the per-iteration mark/restore. Either remove TIGHT, or hoist the allocation out of the loop body.",
    },
    UNHOISTED_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Allocating expression appears in argument / sub-expression position without an AllocMark.",
      cause: "Every MIR node that allocates memory (DupeSlice, HeapCreate, ConcatStr, AllocSlice, MakeList, CapWrap, SharePromote, deep DeepCopy, ContainerInit) must appear as the direct init of a `MIR::Let` so it has an AllocMark. Found one in argument / return / field-value position instead.",
      fix_hint: "Lowering bug — HPT hoisting (hoist_alloc) should have lifted the call into a Let. Check the producer pass that emitted the allocating node; it should bind the result to a fresh local.",
    },
    COPY_CLEANUP: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Cleanup attached to a primitive / Id<T> value — value types don't own heap memory.",
      cause: "A Cleanup paired with an AllocMark whose `type_info` is a primitive (Int*, Float*, Bool, Byte) or `Id<T>` (with no sync/rc capability) can't be right — these are pure value types that never own heap memory, so a cleanup is structurally meaningless.",
      fix_hint: "Lowering bug. Check that the cleanup classifier doesn't promote primitives to needing cleanup. The fix usually drops the cleanup node and the alloc-site decision rather than 'fixing' the cleanup.",
    },
    # Tranche 6: remaining ad-hoc strings — added in one big sweep
    TIGHT_CALLS_EXTERN_FN: {
      severity: :error, category: :reentrance,
      template: "TIGHT loop cannot call EXTERN FN '%{name}' (opaque to scheduler)",
      summary:  "EXTERN FN calls in a TIGHT loop are opaque to the scheduler — disallowed.",
    },
    TIGHT_CALLS_REENTRANT_FN: {
      severity: :error, category: :reentrance,
      template: "TIGHT loop cannot call @reentrant function '%{name}'",
      summary:  "TIGHT loops disallow calls to @reentrant functions (unbounded depth).",
    },
    REENTRANCY_MUTUAL_CYCLE: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' is part of a mutually recursive call cycle. Add @reentrant or @nonReentrant to the function signature.",
      summary:  "Function is in a mutual-recursion cycle but lacks an explicit reentrancy annotation.",
    },
    INT_LITERAL_OVERFLOW: {
      severity: :error, category: :type,
      template: "Integer literal (%{val}) overflows %{type} (range %{min}..%{max})",
      summary:  "Integer literal does not fit in the target integer type.",
    },
    STDLIB_METHOD_NO_ARGS: {
      severity: :error, category: :type,
      template: "%{label}.%{method} takes no arguments, got %{got}",
      summary:  "Stdlib method takes no arguments but received some.",
    },
    STDLIB_METHOD_ARITY: {
      severity: :error, category: :type,
      template: "%{label}.%{method} requires exactly %{expected} argument(s), got %{got}",
      summary:  "Stdlib method called with the wrong number of arguments.",
    },
    STRICT_TEST_NEEDS_STUB: {
      severity: :error, category: :test,
      template: "Strict test mode: '%{name}' is an IO function that must be stubbed. Add STUB %{name} RETURNS <value>; to the WHEN block.",
      summary:  "Strict test mode requires every IO function to be stubbed.",
    },
    STRICT_TEST_HAS_IO_EFFECTS: {
      severity: :error, category: :test,
      template: "Strict test mode: '%{name}' has IO effects (%{effects}). Either stub '%{name}' or stub the IO functions it calls.",
      summary:  "Strict test mode rejects un-stubbed functions that transitively perform IO.",
    },
    UNION_TYPE_UNKNOWN: {
      severity: :error, category: :type,
      template: "Unknown union type: '%{name}'",
      summary:  "Union type is not registered in this scope.",
    },
    NOT_A_UNION_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: '%{name}' is not a union type.",
      summary:  "Identifier referenced as a union but is something else.",
    },
    UNION_VARIANT_IS_UNIT_NO_FIELDS: {
      severity: :error, category: :type,
      template: "Union variant '%{variant}' is a unit variant — use '%{union}.%{variant}' (no fields).",
      summary:  "Unit variant cannot accept inline-struct fields.",
    },
    UNION_VARIANT_NEEDS_PAYLOAD_OBJECT: {
      severity: :error, category: :type,
      template: "Union variant '%{variant}' takes a single typed payload — use '%{union}{ %{variant}: value }' instead.",
      summary:  "Single-payload variant cannot use the inline-struct '{ field: ... }' form.",
    },
    REENTRANT_NEEDS_FALLIBLE_RETURN: {
      severity: :error, category: :reentrance,
      template: "%{variant_text} on '%{fn}' requires an error-union return type (`!T`) so callers can handle the runtime guard's `System %{err}`. Declared return type is '%{rt}'; change it to '%{suggested}'.",
      summary:  "Bounded-reentrance functions must return an error union so callers can catch the depth-guard error.",
    },
    REENTRANT_NOT_LOGICAL_BUT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:NOT_LOGICAL on '%{name}' but the function %{cycle_desc} -- the runtime StackGuard would raise System UnexpectedRecursion on every call. NOT_LOGICAL is for functions the user asserts are NEVER reachable from themselves (e.g. a callback hook that mustn't recurse). For real recursion, declare 'EFFECTS REENTRANT:THUNK' (heap-CPS trampoline; depth = number of frames the heap can hold) or 'EFFECTS REENTRANT:MAX_DEPTH(N)' (bounded recursion; raises System MaxDepthExceeded above N).",
      summary:  "NOT_LOGICAL asserts non-recursion but the function is recursive.",
    },
    REENTRANT_THUNK_NOT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:THUNK on '%{name}' but the function is not recursive (neither direct nor mutual). Remove ':THUNK', or change to plain 'EFFECTS REENTRANT' if recursion may appear via callees registered later.",
      summary:  ":THUNK is reserved for recursive functions; this one isn't recursive.",
    },
    REQUIRES_NON_REENTRANT_NOT_PARAM: {
      severity: :error, category: :reentrance,
      template: "Function '%{fn}' has 'REQUIRES %{name}: NON_REENTRANT' but '%{name}' is not a parameter of '%{fn}'.",
      summary:  "REQUIRES :NON_REENTRANT must reference a parameter.",
    },
    LOCK_RANK_INCONSISTENT: {
      severity: :error, category: :concurrency,
      template: "Inconsistent lock rank for type '%{type}': previously declared as rank %{previous}, now rank %{rank}. All declarations of a ranked lock type must agree on the rank.",
      summary:  "Lock-rank declarations for the same type disagree.",
    },
    LOCK_NESTED_REACQUIRE: {
      severity: :error, category: :concurrency,
      template: "Nested lock re-acquire: '%{name}' is already held by an enclosing WITH (outer line %{outer_line}). This is a structural self-deadlock. If you know the instances are distinct and ordered, mark the inner WITH as POSSIBLE_DEADLOCK.",
      summary:  "Inner WITH re-acquires a lock already held by an enclosing WITH.",
    },
    LOCK_RANK_VIOLATION: {
      severity: :error, category: :concurrency,
      template: "Lock rank violation: acquiring ':%{cap}' at rank %{cap_rank} while ':%{held}' (rank %{held_rank}) is held. Ranks must be strictly ascending along the acquire path to prove LockCycle freedom by construction. If ordering is enforced by a different discipline, mark the inner WITH with POSSIBLE_LOCK_CYCLE.",
      summary:  "Acquired lock has lower rank than a currently-held lock.",
    },
    SELECTOR_NOT_POSSIBLE: {
      severity: :error, category: :concurrency,
      template: "You are trying to handle `%{label}` which is not a possible error at this WITH. The static lock analysis proved it cannot fire. Remove the handler, or mark an upstream lock acquire with POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE if you know a runtime path can reach it.",
      summary:  "ON-clause selector cannot fire at this WITH (provably impossible).",
    },
    GENERIC_DUP_TYPE_PARAM_KIND: {
      severity: :error, category: :type,
      template: "Type Error: Duplicate type parameter '%{param}' in generic %{kind} '%{name}'.",
      summary:  "Generic STRUCT/FN declares the same type parameter twice.",
    },
    GENERIC_TYPE_PARAM_SHADOWS: {
      severity: :error, category: :type,
      template: "Type Error: Type parameter '%{param}' shadows built-in type '%{param}'.",
      summary:  "Generic type parameter shadows a built-in type name.",
    },
    FN_PARAM_NO_CAPABILITY: {
      severity: :error, category: :type,
      template: "Capability annotations are not allowed on function parameters. Use the plain type (e.g., 'Node' not 'Node @multiowned').",
      summary:  "FN-type parameter syntax disallows capability sigils.",
    },
    ATSPLIT_STREAM_ONLY: {
      severity: :error, category: :type,
      template: "@split is currently only supported on stream types.",
      summary:  "@split capability requires a stream type.",
    },
    COLLECTION_NEEDS_ARRAY_TYPE: {
      severity: :error, category: :type,
      template: "Collection capability %{cap} requires an array type (e.g. %{example})",
      summary:  "@list / @pool / @set must be applied to an array element type.",
    },
    OBSERVABLE_REQUIRES_SET: {
      severity: :error, category: :type,
      template: "@observable on `T[]` requires `@set` (e.g. `~T[]@set:observable` for DISTINCT). Plain `~T[]@observable` is not a supported shape; the only collection observable today is the DISTINCT terminal's `~T[]@set:observable`.",
      summary:  "@observable on a list requires @set.",
    },
    OBSERVABLE_NOT_COMBINABLE: {
      severity: :error, category: :type,
      template: "@observable cannot be combined with %{labels}. %{explain} Drop the wrapper or pick a non-observable type.",
      summary:  "@observable rejects certain combined capabilities.",
    },
    SOA_NEEDS_FIXED_ARRAY: {
      severity: :error, category: :type,
      template: "@soa requires a fixed-size array type (e.g. Particle[10000]@soa)",
      summary:  "@soa requires a fixed-size array.",
    },
    SHARDED_NEEDS_2_PLUS: {
      severity: :error, category: :type,
      template: "@sharded requires N >= 2, got %{got}",
      summary:  "@sharded(N) requires N >= 2.",
    },
    POOL_NEEDS_FIXED_CAPACITY: {
      severity: :error, category: :type,
      template: "Pool requires a fixed capacity — use %{element}[N]@pool instead of []@pool",
      summary:  "@pool requires a fixed capacity.",
    },
    UNKNOWN_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: Unknown type '%{name}'.",
      summary:  "Type identifier is not registered in this scope.",
    },
    POLY_SHARED_INCONSISTENT: {
      severity: :error, category: :type,
      template: "Type Error: polymorphic @shared parameters in '%{fn}' must use the same synchronization capability. Parameter '%{first}' is %{first_cap}, but parameter '%{second}' is %{second_cap}.%{hint}",
      summary:  "Polymorphic @shared parameters disagree on synchronization capability.",
    },
    RC_PROMISE_NEEDS_SHARED: {
      severity: :error, category: :type,
      template: "~T@multiOwned is not valid. Promises span fiber boundaries, so the ref-count must be atomic. Use ~T@shared instead.",
      summary:  "Promise types require @shared (atomic refcount), not @multiOwned.",
    },
    ATSPLIT_NEEDS_OPEN_STREAM: {
      severity: :error, category: :type,
      template: "@split is currently only valid on open streams (~?T[]).",
      summary:  "@split applies only to open streams.",
    },
    SOA_TO_EXTERN_FN: {
      severity: :error, category: :type,
      template: "@soa collections cannot be passed to EXTERN FN — SOA memory layout is incompatible with C ABI. Materialize to a regular array first.",
      summary:  "@soa collections have a structure-of-arrays layout that's incompatible with C ABI.",
    },
    NOT_A_FUNCTION: {
      severity: :error, category: :type,
      template: "Cannot call '%{name}' - not a function",
      summary:  "Identifier is bound but is not a callable function.",
    },
    TAKES_NEEDS_OWNED_INDEX: {
      severity: :error, category: :ownership,
      template: "Cannot pass container index access to TAKES parameter. Index access returns a borrow. Use .remove(i) to take ownership, or COPY to deep-copy.",
      summary:  "TAKES parameter needs ownership; container[i] is a borrow.",
    },
    LINK_NEEDS_RESOLVE_FOR_CALL: {
      severity: :error, category: :ownership,
      template: "Cannot pass @link variable '%{name}' to parameter '%{param}' — RESOLVE it first to get an optional strong reference.",
      summary:  "Cannot pass a weak @link reference where a concrete value is expected.",
    },
    REENTRANT_FN_TO_NON_REENTRANT_PARAM: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' is @reentrant but parameter '%{param}' does not accept @reentrant functions. Declare the parameter type as 'FN(...) -> Type @reentrant' to allow this.",
      summary:  "@reentrant function passed to a parameter that doesn't permit @reentrant callees.",
    },
    ARG_NEEDS_ATOMIC_CELL: {
      severity: :error, category: :type,
      template: "Type Error: Argument %{index} to '%{fn}' expects an @atomic %{expected} cell, but '%{name}' is %{actual}. Pass an @atomic binding, or change the parameter to bare %{expected} to load a value.",
      summary:  "Argument must be an @atomic cell binding (not a loaded value).",
    },
    ARG_NEEDS_SHARED: {
      severity: :error, category: :type,
      template: "Type Error: Argument %{index} to '%{fn}' expects %{expected} @shared, got %{actual}.%{hint}",
      summary:  "Argument must be a @shared handle to be retained across boundaries.",
    },
    ARG_ALIAS_CONFLICT: {
      severity: :error, category: :ownership,
      template: "Aliasing Error: Argument %{index} ('%{name}') conflicts with argument %{other_index}. Cannot pass the same variable defined at '%{path}' twice if one usage is MUTABLE. This violates exclusive mutability.",
      summary:  "Two arguments share the same variable, and at least one is mutable.",
    },
    MUTABLE_ARG_RESTRICTED: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: Cannot pass '%{name}' as mutable argument because it is currently RESTRICTed.",
      summary:  "Argument is RESTRICTed; cannot be passed as mutable.",
    },
    MUTABLE_PARAM_NEEDS_RESTRICT: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: param `%{name}` is mutable, must be RESTRICTed before it can be borrowed.",
      summary:  "Mutable parameter must be RESTRICTed before being aliased.",
    },
    LIFETIME_RETURNS_REQUIRES_FAMILY_CONFLICT: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: function '%{fn}' declares `RETURNS %{name}:T` AND `REQUIRES %{name}: ATOMIC | %{others}`. The returned value's lifetime model differs by family: ATOMIC is a bare pointer to a scope-bounded cell (M2.2), while %{others_label} is reference-counted via Arc. The compiler can't pick one lifetime story at the declaration site. Either split into two functions (one per family) or drop the ATOMIC family from REQUIRES.",
      summary:  "Function declares RETURNS for a name whose REQUIRES mixes ATOMIC with another family.",
    },
    LIFETIME_ROOT_NOT_PARAM: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: Scoped lifetime '%{name}' is not a parameter.",
      summary:  "Lifetime annotation references a name that is not a parameter.",
    },
    LIFETIME_NOT_A_STRUCT: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: Type '%{type}' is not a struct, cannot access field '%{field}'.",
      summary:  "Lifetime path drills into a field on a non-struct type.",
    },
    LIFETIME_NO_FIELD: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: Type '%{type}' has no field '%{field}'.",
      summary:  "Lifetime path references a field that doesn't exist on the struct.",
    },
    DEFAULT_NEEDS_STRUCT_PARAM: {
      severity: :error, category: :type,
      template: "Type Error: DEFAULT can only be used for struct-type parameters, not '%{type}'",
      summary:  "DEFAULT is only valid for struct-typed parameters.",
    },
    DEFAULT_STRUCT_MISSING_DEFAULTS: {
      severity: :error, category: :type,
      template: "Type Error: DEFAULT for '%{name}' requires '%{type}' to have defaults for all fields; missing: %{missing}",
      summary:  "DEFAULT requires every field of the struct to have a default.",
    },
    DEFAULT_VALUE_TYPE_MISMATCH: {
      severity: :error, category: :type,
      template: "Type Error: Default value for '%{name}' expects %{expected}, got %{got}",
      summary:  "Default value's type doesn't match the parameter's declared type.",
    },
    CAPTURE_NO_DEFAULT: {
      severity: :error, category: :ownership,
      template: "Captures cannot have default values: '%{name}'",
      summary:  "Lambda captures don't accept default values.",
    },
    CAPTURE_UNDEFINED_VAR: {
      severity: :error, category: :ownership,
      template: "Cannot capture undefined variable '%{name}'",
      summary:  "Lambda capture references an undefined variable.",
    },
    CAPTURE_IMMUTABLE_AS_MUTABLE: {
      severity: :error, category: :ownership,
      template: "Cannot capture immutable variable '%{name}' as MUTABLE",
      summary:  "Lambda cannot capture an immutable binding as MUTABLE.",
    },
    AMBIGUOUS_RETURN: {
      severity: :error, category: :type,
      template: "Ambiguous Return: Function returns multiple types %{types}, specify :Any as type",
      summary:  "Function has multiple return types of differing kinds without an :Any annotation.",
    },
    RETURN_BORROWED_NO_COPY_OR_LIFETIME: {
      severity: :error, category: :lifetime,
      template: "Cannot return borrowed value without COPY or a lifetime annotation. Type '%{type}' is not implicitly copyable.",
      summary:  "Returning a borrow without COPY or a `RETURNS x:T` lifetime annotation.",
      cause: "A RETURN statement returns a borrowed value (e.g. a field of a parameter) without either copying it or declaring a lifetime annotation on the function. CLEAR can't statically prove the return outlives the source.",
      fix_hint: "Either COPY the value before returning, declare `RETURNS x:T` on the function so the lifetime propagates to the caller, or restructure to return an owned value.",
    },
    RETURN_LIFETIME_MISMATCH: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: Expected return %{sources_msg}; actual return derived from: %{actual}",
      summary:  "Returned value's lifetime path doesn't match any declared `RETURNS x:T` source.",
    },
    WITH_EXCLUSIVE_NEEDS_LOCK_GOT: {
      severity: :error, category: :concurrency,
      template: "EXCLUSIVE capability requires a @locked or @writeLocked variable, got %{got}",
      summary:  "EXCLUSIVE WITH-block needs a @locked or @writeLocked binding.",
      cause: "A WITH EXCLUSIVE block requires the binding to have a lock-axis sync capability (`@locked`, `@writeLocked`). Without one, there's nothing to acquire — the EXCLUSIVE keyword has no meaning.",
      fix_hint: "Either add `@locked` / `@writeLocked` to the binding's type, or remove the EXCLUSIVE keyword. If the binding is meant to be lock-free, the WITH block isn't needed.",
    },
    WITH_READ_NEEDS_WRITE_LOCK_NAME: {
      severity: :error, category: :concurrency,
      template: "WITH %{name}: read access requires a @writeLocked variable",
      summary:  "WITH (read) requires a @writeLocked binding for the read-side polymorphism to apply.",
    },
    SYNC_POLICY_DUPLICATE: {
      severity: :error, category: :concurrency,
      template: "Only one SYNC POLICY block is allowed per program. The first one was declared earlier in this file.",
      summary:  "Multiple SYNC POLICY blocks declared.",
    },
    SYNC_POLICY_NEEDS_MAIN_FILE: {
      severity: :error, category: :concurrency,
      template: "SYNC POLICY may only be declared in the file containing `FN main`. Move the policy to the program's main file, or remove it here.",
      summary:  "SYNC POLICY must live next to FN main.",
    },
    SYNC_POLICY_INLINE_ONLY: {
      severity: :error, category: :concurrency,
      template: "`%{name}` must be handled in-line — SYNC POLICY defaults are not allowed for this error. Remove it from the policy and add an `ON %{name} ...` handler at the WITH site (use `WITH POLYMORPHIC POSSIBLE_%{escape} ...` if the static cycle check needs to be opted out).",
      summary:  "Some errors must be handled in-line at the WITH site, not via SYNC POLICY.",
    },
    SYNC_POLICY_INVALID_ERROR: {
      severity: :error, category: :concurrency,
      template: "`%{name}` is not a valid SYNC POLICY error. SYNC POLICY only handles: %{required}.",
      summary:  "Selector names an error type that SYNC POLICY does not cover.",
    },
    SYNC_POLICY_NEEDS_TYPE_NOT_KIND: {
      severity: :error, category: :concurrency,
      template: "SYNC POLICY handlers must name a specific error type, not a kind. `ON %{name} ...` (and the `RETRY(N) THEN` sugar that desugars to `ON Transient ...`) is rejected here. Use `ON LockTimeout ...`, `ON MvccConflict ...`, or `ON AtomicConflict ...` explicitly.",
      summary:  "SYNC POLICY selectors must be types, not kinds.",
    },
    SYNC_POLICY_INCOMPLETE: {
      severity: :error, category: :concurrency,
      template: "SYNC POLICY must handle every required error (%{required}). Missing: %{missing}.",
      summary:  "SYNC POLICY must cover every required error type.",
    },
    CATCH_WITH_UNREGISTERED: {
      severity: :error, category: :type,
      template: "CATCH ... WITH(%{name}): error type '%{name}' is not registered.",
      summary:  "CATCH ... WITH refers to an unregistered error type.",
    },
    MATCH_NEEDS_ENUM_OR_UNION: {
      severity: :error, category: :type,
      template: "MATCH requires an enum or union type, got '%{type}'. Use `PARTIAL MATCH` to match on non-discriminated types (WHEN guards, ranges, etc. require PARTIAL).",
      summary:  "MATCH requires a discriminated subject (enum or union).",
    },
    MATCH_FORBIDS_DEFAULT: {
      severity: :error, category: :type,
      template: "MATCH cannot have a DEFAULT branch — every variant must be handled explicitly. If you want a catch-all, change to `PARTIAL MATCH` (which permits DEFAULT and WHEN guards).",
      summary:  "MATCH must be exhaustive — DEFAULT requires PARTIAL MATCH.",
    },
    MATCH_FORBIDS_WHEN: {
      severity: :error, category: :type,
      template: "MATCH cannot contain WHEN guards — every variant must be handled by an exact case. Use `PARTIAL MATCH` if you need WHEN guards.",
      summary:  "MATCH must be exhaustive — WHEN guards require PARTIAL MATCH.",
    },
    MATCH_NON_EXHAUSTIVE: {
      severity: :error, category: :type,
      template: "MATCH on %{kind} '%{name}' is non-exhaustive: missing variants: %{missing}. Either add cases for the missing variants, or change to `PARTIAL MATCH` to allow non-exhaustive matching.",
      summary:  "MATCH does not cover every variant.",
    },
    ERROR_TYPE_NOT_REGISTERED: {
      severity: :error, category: :type,
      template: "Error type '%{name}' is not registered. The first RAISE / OR EXIT site that names a new type must provide a kind: use 'RAISE Kind, %{name}, \"msg\"' or similar.",
      summary:  "Error type was never registered with a kind.",
    },
    ERROR_TYPE_RESERVED_BY_STDLIB: {
      severity: :error, category: :type,
      template: "'%{name}' is reserved by the stdlib as kind '%{kind}'. Pick a different type name.",
      summary:  "Error type name conflicts with a stdlib-reserved one.",
    },
    ERROR_TYPE_KIND_CONFLICT: {
      severity: :error, category: :type,
      template: "'%{name}' is already mapped to kind '%{kind}'%{first_loc}. Either use the same kind here, or pick a different type name.",
      summary:  "Same error type name registered with a different kind.",
    },
    CALL_SITE_OVERRIDE_UNIMPLEMENTED: {
      severity: :error, category: :type,
      template: "%{sigil}(%{n}) is parsed but not yet implemented. Per-call-site monomorphization (cloning the callee + rewriting recursive calls inside the clone so the depth counter / trampoline applies to internal recursion) lands in v0.3 alongside the broader monomorphization pass. For now, declare the variant on the function instead: %{variant_hint} (call-site overrides will be a strictly additive feature when 4.1/4.2 land).",
      summary:  "Per-call-site reentrance override is reserved but not yet implemented.",
    },
    INDIRECT_ATOMIC_PRIMITIVE: {
      severity: :error, category: :type,
      template: "@indirect:atomic is for STRUCTS. For primitive type %{type}, use `@shared:atomic` (the v0.2 primitive-as-cell form). The atomic primitive already fits in a single CAS-able machine word; @indirect would add a pointless heap indirection.",
      summary:  "@indirect:atomic is for structs; primitives use @shared:atomic.",
    },
    STRUCT_ATOMIC_NEEDS_INDIRECT: {
      severity: :error, category: :type,
      template: "@atomic on a STRUCT requires @indirect (publishes whole-T snapshots via atomic pointer swap). Use `%{type}{...} @indirect:atomic` instead. (For primitive cells like `Int64@shared:atomic`, atomic alone is correct -- those fit in a single CAS-able machine word.)",
      summary:  "@atomic on a struct requires @indirect.",
    },
    LOCAL_INDIRECT_ATOMIC: {
      severity: :error, category: :type,
      template: "@local:indirect:atomic is disallowed -- atomic without cross-thread visibility is pointless. Drop @local; @indirect:atomic implies cross-thread sharing.",
      summary:  "@local with @indirect:atomic is contradictory.",
    },
    MULTIOWNED_INDIRECT_ATOMIC: {
      severity: :error, category: :type,
      template: "@multiowned:indirect:atomic is disallowed -- Rc isn't thread-safe (non-atomic refcount), so it can't back a cross-thread atomic-ptr cell. Drop @multiowned; @indirect:atomic uses Arc internally for the published-value lifetime.",
      summary:  "@multiowned with @indirect:atomic is unsound (Rc isn't atomic).",
    },
    WITH_MATCH_VERSIONED_AS_MUTABLE: {
      severity: :error, category: :concurrency,
      template: "WITH MATCH with `AS MUTABLE` and a VERSIONED arm is not supported: writes through a Versioned read-snapshot don't commit (silent data loss in the VERSIONED arm; only the LOCKED arm would mutate the live cell). For transactional mutation on a versioned cell use:\n    WITH SNAPSHOT %{name} AS MUTABLE va { ... } ON MvccConflict <action>\nand keep WITH MATCH for read-side polymorphism.",
      summary:  "WITH MATCH AS MUTABLE on a versioned cell silently drops writes.",
    },
    WITH_MATCH_MULTI_CELL: {
      severity: :error, category: :concurrency,
      template: "WITH MATCH with multiple cells (%{names}) is not yet supported: lower_with_match_block emits the per-arm prelude for the first capability only. Split into separate WITH MATCH blocks (one per cell) until multi-cell dispatch lands.",
      summary:  "Multi-cell WITH MATCH is not yet supported.",
    },
    WITH_RETRYABLE_FALLIBLE_BODY: {
      severity: :error, category: :concurrency,
      template: "%{with_name} body must be non-fallible for atomicity, but it contains fallible work (%{detail}). Retryable synchronization bodies may run more than once and cannot safely propagate user failures from inside the update callback. Move fallible work outside the WITH body, store the result in a local, then commit only non-fallible mutations inside the WITH.",
      summary:  "Retryable WITH body must not contain fallible work.",
      cause: "A retryable WITH (SNAPSHOT MUTABLE / POLYMORPHIC) body must be non-fallible — it may run multiple times during retry. User-level `?` / `!` propagation from inside the body would lose track of which retry the failure belongs to.",
      fix_hint: "Move fallible work outside the WITH (read state via WITH SNAPSHOT, do fallible work, then commit the result inside the WITH). The body should only contain the actual mutation.",
    },
    WITH_SNAPSHOT_BODY_NOT_PURE: {
      severity: :error, category: :concurrency,
      template: "WITH SNAPSHOT ... AS MUTABLE body must be pure for atomicity, but the body has %{kinds} effect(s). Yielding the fiber breaks the EBR pin and atomicity guarantees; IO can't be rolled back if the transaction aborts. Move the impure work outside the transaction (read state via WITH SNAPSHOT, do IO, then commit).",
      summary:  "WITH SNAPSHOT AS MUTABLE body must be pure (no yields, no IO).",
    },
    WITH_SNAPSHOT_NEEDS_HANDLER: {
      severity: :error, category: :concurrency,
      template: "WITH SNAPSHOT ... AS MUTABLE has no `ON %{error} ...` handler and the SYNC POLICY does not provide one. Either add `ON %{error} ...` at this WITH, or extend the program SYNC POLICY (a complete policy is mandatory).",
      summary:  "WITH SNAPSHOT AS MUTABLE needs a conflict handler in-line or via SYNC POLICY.",
    },
    WITH_ATOMIC_HANDLER_WRONG_ERROR: {
      severity: :error, category: :concurrency,
      template: "`ON MvccConflict` isn't valid on `@indirect:atomic`. AtomicPtr.update raises `AtomicConflict` (after 256 CAS losses), not `MvccConflict`. Use `ON AtomicConflict ...` instead, or drop the handler to fall back to the SYNC POLICY.",
      summary:  "@indirect:atomic raises AtomicConflict; ON MvccConflict is a category mismatch.",
    },
    INDIRECT_ATOMIC_FIELD_WRITE: {
      severity: :error, category: :concurrency,
      template: "`@indirect:atomic` requires `WITH SNAPSHOT %{name} AS MUTABLE x { x.%{field} = ...; }` for mutation. Atomic pointer swap publishes a new whole-T snapshot, not a per-field write -- the `WITH SNAPSHOT` block clones the snapshot, mutates the clone, and CAS-publishes it. (This is different from primitive `@shared:atomic` Int64/Float64/Bool, which use direct ops like `c += 1` because they fit in a single CAS-able machine word.)",
      summary:  "Per-field writes through @indirect:atomic must go via WITH SNAPSHOT AS MUTABLE.",
    },
    WITH_MULTI_OBJECT_ATOMIC: {
      severity: :error, category: :concurrency,
      template: "Multi-object WITH cannot admit ATOMIC: `%{name}` is (or could be) `@atomic` / `@indirect:atomic`, which gives no atomicity across cells. Either narrow the binding's REQUIRES to a non-ATOMIC family (e.g. `LOCKED | VERSIONED`, or just `VERSIONED` for cross-cell MVCC transactions), or refactor to single-cell WITH blocks. Per design contract docs/agents/atomicptr.md §4 + docs/agents/true-synchronization-polymorphism.md.",
      summary:  "Multi-binding WITH cannot include ATOMIC cells (no portable multi-pointer atomic).",
    },
    WITH_SNAPSHOT_MATCH_VERSIONED_NEEDS_HANDLER: {
      severity: :error, category: :concurrency,
      template: "WITH SNAPSHOT ... AS MUTABLE MATCH: VERSIONED arm has no `ON MvccConflict` handler and the SYNC POLICY does not provide one. Either add `WHEN VERSIONED -> { ... } ON MvccConflict ...`, or extend the program SYNC POLICY.",
      summary:  "Per-arm VERSIONED needs an MvccConflict handler.",
    },
    WITH_SNAPSHOT_MATCH_ATOMIC_FORBIDS_HANDLER: {
      severity: :error, category: :concurrency,
      template: "WITH SNAPSHOT ... AS MUTABLE MATCH: ATOMIC arm forbids conflict handlers (AtomicPtr.update retries until success -- Rust `rcu` semantics; there's no conflict path to handle). Drop the trailing handler clause from the ATOMIC arm.",
      summary:  "ATOMIC arm of WITH MATCH cannot carry a conflict handler.",
    },
    RETRY_ONLY_TRANSIENT: {
      severity: :error, category: :type,
      template: "RETRY only targets Transient errors. Non-retryable types in selector: %{types}",
      summary:  "RETRY clause must select Transient error types only.",
    },
    PARTIAL_MATCH_EXPR_NEEDS_DEFAULT: {
      severity: :error, category: :type,
      template: "PARTIAL MATCH used in expression position requires a DEFAULT branch. Either add a DEFAULT case, or change to `MATCH` (which forces every variant to have an exact case).",
      summary:  "PARTIAL MATCH expression must have a DEFAULT branch.",
    },
    CAN_SMASH_NOT_SUPPORTED: {
      severity: :error, category: :reentrance,
      template: "`@canSmash` on BG/DO blocks is recognized but not yet supported by the compiler. The runtime has stack-hysteresis (page-guarded soft overflow detection) to protect fiber stacks, but the compiler does not yet wire that feature on. Use `@service` instead (spawns on a dedicated OS thread with a 2 MB pre-allocated stack); `@canSmash` is expected to be supported in v0.3.",
      summary:  "@canSmash is parsed but not yet implemented.",
    },

    # Tranche 8 — umbrella codes. These use a `%{message}` passthrough
    # template (same shape as the MIR-checker codes) for sites whose
    # message is built dynamically by the surrounding pass. The code
    # carries summary/cause metadata so `clear explain` works; the
    # rendered text is whatever the call site produces.
    CAPABILITY_VIOLATION_FIXABLE: {
      severity: :error, category: :capability,
      template: "%{message}",
      summary:  "Capability mismatch with an interactive auto-fix available.",
      cause: "The capability declared on a binding (locked / write_locked / shared / multiowned / observable / ...) doesn't satisfy the operation being performed. The Capabilities validator computes a precise reason (wrong tense, missing wrapper, incompatible combination) and the message field carries the specific text.",
      fix_hint: "Read the message — it describes the exact mismatch and usually points at the right capability. `clear fix` typically offers an interactive auto-fix when the change is mechanical (add a missing wrapper, swap a tense).",
    },
    PURITY_VIOLATION: {
      severity: :error, category: :type,
      template: "%{message}",
      summary:  "A pure function calls into impure code (effects / surface).",
      cause: "A function declared as pure (PURE keyword or implied via REQUIRES) called into code that has effects (yield / alloc_heap / io / fail). The effect lattice is inferred per-function and propagated through the call graph; a pure caller cannot escape its purity.",
      fix_hint: "Either remove the PURE declaration on the caller, or remove the impure call. If the impure work is needed, isolate it in a non-pure helper and only call into pure code from inside the pure body.",
    },
    VARDECL_TYPE_MISMATCH_FIXABLE: {
      severity: :error, category: :type,
      template: "%{message}",
      summary:  "Variable declaration's value type doesn't match the declared type, with an interactive fix.",
      cause: "The value bound to the variable doesn't fit the declared type. Coercion was tried (slice widening, primitive autocast) and failed. An interactive fix is available when the language can suggest a literal CAST or the type annotation can be inferred from the value.",
      fix_hint: "Either change the declared type to match the value, change the value to the declared type, or use `CAST x AS Type` for an explicit conversion.",
    },
    ATOMIC_ESCAPE_ASSIGN: {
      severity: :error, category: :escape,
      template: "%{message}",
      summary:  "Assigning a value whose lifetime is tied to a sync-axis source escapes the source's scope.",
      cause: "A value whose lifetime is tied to a sync-axis source (e.g. `@shared:atomic` cell) was assigned into a binding that outlives the source's scope. The atomic cell is bounded by its declaring scope; the assignment would dangle.",
      fix_hint: "Migrate the source to `@shared:locked` (a longer lifetime model) — `clear fix` offers this as an interactive transformation. Or restructure so the assignment doesn't escape the source scope.",
    },
    ATOMIC_ESCAPE_RETURN: {
      severity: :error, category: :escape,
      template: "%{message}",
      summary:  "Returning a value whose lifetime is tied to a sync-axis source escapes the source's scope.",
      cause: "A value whose lifetime is tied to a sync-axis source was returned from a function that doesn't declare `RETURNS source:T`. The source is bounded by its declaring scope; returning the value would dangle.",
      fix_hint: "Either declare `RETURNS x:T` on the function (propagates the lifetime to the caller), COPY the value before returning, or migrate the source to `@shared:locked`.",
    },
    STACK_NEEDS_SERVICE_FIXABLE: {
      severity: :error, category: :reentrance,
      template: "%{message}",
      summary:  "Spawn site transitively calls a plain :reentrant function and must run on @service (OS thread).",
      cause: "A BG/DO spawn site transitively calls a function declared as plain `EFFECTS REENTRANT` (unbounded recursion). Plain reentrant chains can't fit on a fiber stack — they require an OS thread (`@service`).",
      fix_hint: "Either declare `@service` on the spawn site (`clear fix` replaces the existing tier sigil), or change the callee to a bounded reentrance variant (`:THUNK`, `:TAIL_CALL`, `:NOT_LOGICAL`, `:MAX_DEPTH(N)`).",
    },
    REENTRANT_MUTUAL_THUNK_UNSUPPORTED: {
      severity: :error, category: :reentrance,
      template: "%{message}",
      summary:  "Mutual-recursion cycle of :THUNK functions whose body shape isn't supported by the tagged-union codegen.",
      cause: "Mutual recursion through `:THUNK` functions requires a tagged-union trampoline whose codegen only handles a specific body shape: IF base cases plus a `RETURN partner(args)` tail call. The cycle's body shape isn't supported.",
      fix_hint: "Three options: (a) declare plain `EFFECTS REENTRANT` on every cycle member (callers run on `@service` / OS thread), (b) declare `:NOT_LOGICAL` (asserts no actual recursion at runtime), (c) declare `:MAX_DEPTH(N)` (bounded counter). `clear fix` offers each as an interactive auto-fix.",
    },
    INTRINSIC_REJECTED: {
      severity: :error, category: :type,
      template: "%{message}",
      summary:  "Stdlib intrinsic rejected this call (matched_def[:reject_when] fired).",
      cause: "A stdlib intrinsic (`.negative?`, `.zero?`, ...) rejected this call because the argument type isn't allowed. The stdlib uses `reject_when` patterns to rule out call shapes that look valid but produce wrong results — e.g. `.negative?` on an unsigned int.",
      fix_hint: "Check the message for the specific reject reason. Often the fix is to remove the call entirely (the answer is statically known) or use a different intrinsic.",
    },
    TYPE_COERCION_FAILED: {
      severity: :error, category: :type,
      template: "%{message}",
      summary:  "Type coercion produced an error (Type#coerce! returned a diagnostic).",
      cause: "Type#coerce! tried to widen a value into the target type and failed. Common cases: array-overflow (initializer larger than `T[N]`), unrelated types (assigning Float64 to String), or capability mismatch.",
      fix_hint: "The error text describes the specific failure. Either change the source value, change the target type, or use `CAST x AS Type` for an explicit conversion.",
    },
    LOCK_CYCLE_DETECTED: {
      severity: :error, category: :concurrency,
      template: "%{message}",
      summary:  "Static lock-acquire graph contains a cycle (potential deadlock).",
      cause: "Static analysis of the lock-acquire graph found a cycle (or self-loop). Two locks A and B are acquired in inconsistent orders across different sites — at runtime this can deadlock if two threads hit them simultaneously.",
      fix_hint: "Fix the order — pick a consistent total order (rank locks by type, name, or memory address) and acquire ascending everywhere. Or, when the order is enforced by a different discipline (sharded data, CAS-loop), mark individual sites POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE.",
    },
    REGISTRY_MISMATCH_REJECTED: {
      severity: :error, category: :registry,
      template: "%{message}",
      summary:  "Identifier doesn't match any registered candidate, no typo-suggestion fix available.",
      cause: "An identifier was checked against a closed registry (error kinds, error types, sync families) and didn't match any candidate. The Levenshtein distance to every candidate exceeded the typo-suggestion threshold, so no auto-fix is offered.",
      fix_hint: "Check the spelling and the message for the list of valid candidates. The registry is closed — only the listed identifiers are accepted.",
    },
    TYPO_SUGGESTION_REJECTED: {
      severity: :error, category: :registry,
      template: "%{message}",
      summary:  "Identifier rejected, no close-enough candidate to suggest as a typo fix.",
      cause: "An identifier didn't match any candidate in the relevant scope (variable, struct field, union variant, ...) and the closest candidate was outside the typo-suggestion threshold. No auto-fix is offered.",
      fix_hint: "Check the spelling and the surrounding scope. If the identifier should exist, verify it's been declared / imported in this scope.",
    },
    EFFECT_INFERENCE_VIOLATION: {
      severity: :error, category: :type,
      template: "%{message}",
      summary:  "Per-function effect inference (P3.x) rejected the program (yield-across-lock, naked nested-WITH, recursive lock acquire, etc.).",
      cause: "Per-function effect inference (yield / alloc_heap / io / fail) detected a violation: hold-lock-across-yield, naked nested-WITH, recursive lock acquire on the same binding, etc. The specific check is described in the message.",
      fix_hint: "Most are structural: split the WITH (no nested re-acquire), avoid yielding while holding a lock, mark a function `@reentrant` if recursion is intentional. The message names the specific check.",
    },
    CAPABILITY_INVALID: {
      severity: :error, category: :capability,
      template: "%{message}",
      summary:  "Capability declaration rejected by Capabilities.validate! (unsupported sigil combination, primitive cap, etc.).",
      cause: "Capabilities.validate! rejected the binding's capability stack — either an unsupported sigil combination (`@local:atomic`), a capability on an incompatible type (capability on a primitive), or a missing required capability.",
      fix_hint: "Read the message for the specific rejection. Common fixes: drop a contradictory sigil, wrap a primitive in a struct, add a missing wrapper (`@shared` for cross-fiber sharing).",
    },
  }.freeze

  module_function

  def lookup(code)
    DIAGNOSTICS[code]
  end

  def known?(code)
    DIAGNOSTICS.key?(code)
  end

  def codes
    DIAGNOSTICS.keys
  end

  # Format a registered code's template against `args`. Returns nil
  # when the code isn't known. The caller decides what to do with
  # nil — the legacy helper raises an internal-compiler-error there.
  def format(code, args = [], **kwargs)
    entry = DIAGNOSTICS[code]
    return nil unless entry
    template = entry[:template]
    use_kwargs = !kwargs.empty? || template.include?("%{")
    begin
      use_kwargs ? template % kwargs : template % args
    rescue KeyError, ArgumentError
      payload = use_kwargs ? kwargs.inspect : args.inspect
      "#{template} [Internal Args Error: #{payload}]"
    end
  end

  # Self-check: every entry is well-formed. Returns an array of
  # error strings; empty == registry is consistent. Run by the
  # spec to make sure new entries don't drift.
  def validate
    issues = []
    DIAGNOSTICS.each do |code, entry|
      issues << "#{code}: missing :severity"  unless SEVERITIES.include?(entry[:severity])
      issues << "#{code}: missing :category"  unless CATEGORIES.include?(entry[:category])
      issues << "#{code}: missing :template"  unless entry[:template].is_a?(String)
      issues << "#{code}: missing :summary"   unless entry[:summary].is_a?(String)
    end
    issues
  end
end
