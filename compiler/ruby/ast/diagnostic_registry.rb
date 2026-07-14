# typed: strict
require "sorbet-runtime"

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
#   pending:      (optional, default false) Mark a code as
#                 reserved for a future feature whose implementation
#                 hasn't landed yet. The visitor that would fire it
#                 is intentionally a stub. `clear explain` still
#                 surfaces the entry (so docs can preview the planned
#                 diagnostic) but the example/audit specs skip it —
#                 we can't write a triggering snippet for an
#                 unimplemented compiler check.
#
# `clear explain <CODE>` reads from this table. As entries are
# enriched with cause / fix_hint / examples, the explain command
# becomes more useful without further plumbing.

module DiagnosticRegistry
  extend T::Sig

  DiagnosticKwValue = T.type_alias do
    T.nilable(T.any(String, Symbol, Integer, T::Boolean, T::Class[T.anything], T::Array[Symbol]))
  end
  DiagnosticEntryValue = T.type_alias { T.nilable(T.any(String, Symbol, T::Boolean)) }
  DiagnosticEntry = T.type_alias { T::Hash[Symbol, DiagnosticEntryValue] }
  CATEGORIES = T.let(%i[type ownership capability concurrency lifetime escape registry reentrance lint syntax mir test].freeze, T::Array[Symbol])
  SEVERITIES = T.let(%i[error warning hint info].freeze, T::Array[Symbol])

  sig { returns(T::Array[Symbol]) }
  def self.categories
    CATEGORIES
  end

  sig do
    params(
      severity: Symbol,
      category: Symbol,
      template: String,
      summary: String,
      cause: T.nilable(String),
      fix_hint: T.nilable(String),
      pending: T::Boolean,
    ).returns(DiagnosticEntry)
  end
  def self.entry(severity:, category:, template:, summary:, cause: nil, fix_hint: nil, pending: false)
    out = T.let({}, DiagnosticEntry)
    out[:severity] = severity
    out[:category] = category
    out[:template] = template
    out[:summary] = summary
    out[:cause] = cause if cause
    out[:fix_hint] = fix_hint if fix_hint
    out[:pending] = pending if pending
    out
  end

  DIAGNOSTICS = T.let({
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
    OPERATOR_TYPO_SUGGESTION: {
      severity: :error, category: :syntax,
      template: "Unknown operator `%{match}` -- did you mean `%{replace}`?",
      summary: "A source pre-scan found an operator typo with a mechanical replacement.",
      fix_hint: "Accept the suggested replacement when the surrounding expression expects that operator.",
    },

    # ===================================================================
    # CONTROL FLOW
    # ===================================================================

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
    NATIVE_CALL_ERROR: {
      severity: :error, category: :registry,
      template: "native_call requires 'Class' and 'Method' string literals.",
      summary:  "`native_call` only accepts string-literal class/method args.",
    },

    # ===================================================================
    # STRUCT FIELDS
    # ===================================================================
    FIXED_ARRAY_SIZE_AS_DYNAMIC: {
      severity: :error, category: :type,
      template: "Cannot initialize fixed-array '%{name}' to an unknown size. You must TRUNCATE to a specific size, or use `[]` to create a dynamic array.",
      summary:  "Fixed-size array `T[N]` requires a literal capacity.",
    },
    MUTABLE_BARE_NEEDS_TYPE: {
      severity: :error, category: :syntax,
      template: "MUTABLE bare declaration requires an explicit type annotation.",
      summary:  "`MUTABLE x;` (no `=` initializer) needs an explicit `: T[N]` so the parser can synthesize the default-zero list.",
    },
    MUTABLE_BARE_NEEDS_FIXED: {
      severity: :error, category: :syntax,
      template: "MUTABLE bare declaration requires a fixed-size array type T[N]; got %{type}.",
      summary:  "Only `T[N]` (fixed-size primitive arrays) support default-init via `MUTABLE x: T[N];`. Use `= [...]` for other shapes.",
    },
    MUTABLE_BARE_BAD_ELEMENT: {
      severity: :error, category: :syntax,
      template: "MUTABLE bare declaration: cannot default-init element type %{type}; provide an explicit `= [...]` initializer.",
      summary:  "`MUTABLE xs: T[N];` only synthesizes zeros for primitive element types (Int, Float, String, Bool).",
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
      cause: "A struct field assignment (`p.field = v`) requires the receiver binding `p` to be declared MUTABLE. CLEAR is immutable-by-default; without `MUTABLE p = ...`, no field of `p` can be reassigned.",
      fix_hint: "Add `MUTABLE` at the receiver's declaration. Capability-wrapped bindings (`@locked`, `@alwaysMutable`) also permit field writes through their unwrapping rules.",
    },
    ILLEGAL_FIELD_LOOKUP: entry(
      severity: :error,
      category: :type,
      template: "Type Error: Cannot determine struct type for field access '%{field}'. Receiver is '%{type}'.",
      summary: "Field access on a non-struct (or unresolved-type) target.",
    ),
    OPTIONAL_FIELD_REQUIRES_SAFE_NAV: {
      severity: :error, category: :type,
      template: "Type Error: Cannot access field '%{field}' on optional '%{type}' without safe navigation.",
      summary:  "Field access on an optional value requires `?.` so NIL propagates safely.",
      cause: "An indexed @list read and every other optional expression may be NIL. Plain `.` would silently assume a value exists and could turn an out-of-bounds read into a runtime trap.",
      fix_hint: "Use `%{target}?.%{field}`. The compiler then returns an optional field value and propagates NIL without dereferencing it.",
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
      cause: "Enum variants in CLEAR are tag-only — there's no payload to read. The set of enum values is fixed at declaration; `e.foo` would have nothing to return because variants carry no associated data.",
      fix_hint: "Use the enum value directly (`e == %{enum}.SomeVariant`), or `MATCH e START %{enum}.A -> ..., %{enum}.B -> ... END` for per-variant logic. If you need per-variant data, define a UNION instead — variants there can carry payloads.",
    },

    # ===================================================================
    # UNIONS
    # ===================================================================
    UNION_UNKNOWN_VARIANT: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' has no variant '%{variant}'.",
      summary:  "Reference to a variant that the union does not declare.",
      cause: "Union variants are closed-set: every legal variant name appears in the UNION declaration. References to variants outside that set can't be type-checked or pattern-matched, so the compiler rejects them at the use site.",
      fix_hint: "Either pick an existing variant of `%{union}` (check the declaration), or add `%{variant}` to the UNION definition if it's a new case. Watch for typos — the closest matching variant name is often what was intended.",
    },
    UNION_PAYLOAD_MISMATCH: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{variant}' expects %{expected}, got %{got}.",
      summary:  "Union variant constructor passed a payload of the wrong type.",
      cause: "Each union variant declares a payload type at the UNION definition. Constructors must pass a value matching that declared type so the variant tag and payload stay in sync — a `MATCH` on the variant later reads the payload as the declared type.",
      fix_hint: "Pass a `%{expected}` for the payload, OR widen the declared payload type at the UNION definition if you legitimately want both types in this variant (consider a sibling variant for the alternative shape).",
    },
    UNION_FIELD_ACCESS: {
      severity: :error, category: :type,
      template: "Type Error: '%{union}' is a union type. Access variants with 'Type.Variant(payload)'.",
      summary:  "Field access on a union value (use variant pattern matching instead).",
      cause: "Union values carry a tag plus a payload; the payload's shape depends on the active variant. A bare `u.field` can't be type-checked because different variants have different (or no) fields. CLEAR routes you through MATCH so the active variant is known.",
      fix_hint: "Pattern-match: `MATCH u START %{union}.SomeVariant AS x -> use(x), END`. The AS-binding gives you a typed handle on the payload only when the matched variant is active.",
    },
    UNION_INLINE_VARIANT_NEEDS_BRACES: {
      severity: :error, category: :type,
      template: "Type Error: '%{union}.%{variant}' is an inline struct variant — use '%{union2}.%{variant2}{ field: value }' to construct it.",
      summary:  "Inline-struct variant constructor requires braces, not parens.",
      cause: "Inline-struct variants carry named fields, not a single positional payload. Construction uses brace syntax (matching struct literals) so the field names are explicit at the construction site.",
      fix_hint: "Switch from `%{union}.%{variant}(...)` to `%{union2}.%{variant2}{ field: value, ... }` — each field named explicitly.",
    },
    UNION_INLINE_VARIANT_OLD_SYNTAX: {
      severity: :error, category: :type,
      template: "Type Error: '%{union}' variant '%{variant}' has inline struct fields — use '%{union2}.%{variant2}{ field: value }' instead.",
      summary:  "Old paren-style construction of an inline-struct variant.",
      cause: "Inline-struct variants migrated to brace-syntax construction; the old paren-style positional form was removed because it ambiguates field order across union evolution (adding a new field would silently shift positions).",
      fix_hint: "Rewrite the construction site to use named braces: `%{union2}.%{variant2}{ field: value, ... }`. Field order doesn't matter; missing fields raise an explicit error.",
    },
    UNION_INLINE_VARIANT_UNKNOWN_FIELD: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{union}.%{variant}' has no field '%{field}'.",
      summary:  "Inline-struct variant literal references a field the variant doesn't declare.",
      cause: "Inline-struct variants are closed: their field set is fixed at the UNION definition. Constructors that name a field outside that set can't be checked, and silently dropping unknown fields would let typos pass.",
      fix_hint: "Check the spelling against the declared fields of `%{union}.%{variant}`, drop the unknown field, or add it to the UNION's variant declaration if you need it.",
    },
    UNION_INLINE_VARIANT_TYPE_MISMATCH: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{union}.%{variant}' field '%{field}' expects %{expected}, got %{got}.",
      summary:  "Inline-struct variant field receives a value of the wrong type.",
      cause: "Each field on an inline-struct variant declares a type at the UNION definition. The construction site must supply a value matching that type so MATCH-based readers see the field as the declared type.",
      fix_hint: "Pass a `%{expected}` for `%{field}`, CAST the value if narrowing is intended (`CAST(value AS %{expected})`), or widen the field's declared type at the UNION definition.",
    },
    UNION_INLINE_VARIANT_MISSING_FIELD: {
      severity: :error, category: :type,
      template: "Type Error: Union variant '%{union}.%{variant}' is missing required field '%{field}'.",
      summary:  "Inline-struct variant literal omits a required field.",
      cause: "Inline-struct variants have no default values — every declared field is required at construction so MATCH readers can rely on the payload being fully populated.",
      fix_hint: "Add `%{field}: <value>` to the variant literal. If the field is genuinely optional, declare it as `?T` in the UNION definition and pass NIL when absent.",
    },
    UNION_INLINE_IN_GENERIC: {
      severity: :error, category: :type,
      template: "Type Error: Inline struct variants are not supported in generic unions.",
      summary:  "Generic unions don't yet support inline-struct variants.",
      cause: "Generic union variants currently support a single typed payload (`Variant: T`) so monomorphisation can substitute the payload type uniformly. Inline-struct variants would need per-instance field-type specialisation, which the monomorphiser doesn't yet handle.",
      fix_hint: "Replace the inline-struct variant with a payload-typed variant whose payload is a separately-declared STRUCT (`STRUCT Foo { ... }; UNION U<T> { Bar: Foo, ... }`). The struct can still be generic via its own type parameter.",
    },
    UNION_METHOD_MISSING: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' requires method '%{method}', but no function '%{fn}' exists.",
      summary:  "Union METHOD-clause names a function that wasn't declared.",
      cause: "A `METHOD` clause on a UNION attaches an externally-declared function as a method on the union type. The compiler resolves the function by name when the UNION is annotated; if no matching function is in scope at that point, the method binding can't be created.",
      fix_hint: "Define `FN %{fn}(...) ...` somewhere visible to the UNION declaration (same module, or imported via REQUIRE), or correct the name in the METHOD clause if it's a typo.",
    },
    UNION_METHOD_WRONG_ARITY: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' requires %{expected_arity} parameter(s), but function '%{fn}' has %{got_arity}.",
      summary:  "Method arity doesn't match the union's METHOD declaration.",
      cause: "The METHOD clause declares the method's signature (param count, types, return type); the bound function must match exactly so callers can dispatch through the union without surprises. Arity mismatch breaks the contract.",
      fix_hint: "Adjust `%{fn}` to take exactly %{expected_arity} parameter(s), OR change the METHOD declaration on the UNION to match the function's actual arity.",
    },
    UNION_METHOD_PARAM_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' parameter %{index} expects '%{expected}', but function '%{fn}' has '%{got}'.",
      summary:  "Method parameter type doesn't match the union's METHOD declaration.",
      cause: "METHOD declarations specify each parameter's type; the bound function must match exactly so the union's method dispatch remains type-safe. A divergence here would let callers pass values the function won't accept.",
      fix_hint: "Change `%{fn}`'s parameter %{index} to `%{expected}`, OR update the METHOD declaration to match the function's actual parameter type.",
    },
    UNION_METHOD_RETURN_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' requires return type '%{expected}', but function '%{fn}' returns '%{got}'.",
      summary:  "Method return type doesn't match the union's METHOD declaration.",
      cause: "Callers of `u.%{method}()` see the return type declared on the UNION's METHOD clause; the bound function must return exactly that type so callers' downstream uses type-check. A mismatch would silently hand the caller a wrong-typed value.",
      fix_hint: "Change `%{fn}`'s return type to `%{expected}`, OR update the METHOD declaration's return type to match the function.",
    },
    UNION_METHOD_WRONG_VISIBILITY: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' method '%{method}' is declared %{declared_vis} but function '%{fn}' is %{fn_vis} — visibility must match.",
      summary:  "Method visibility doesn't match the union's METHOD declaration.",
      cause: "Union method visibility is declared on the METHOD clause and must match the underlying function's visibility. Allowing them to differ would let a private function leak as a public method (or vice-versa), breaking module boundaries.",
      fix_hint: "Make the function's visibility match the METHOD declaration: change `FN %{fn}` to %{declared_vis}, OR change the METHOD declaration to %{fn_vis} so it matches the function.",
    },
    UNION_METHOD_DUPLICATE: {
      severity: :error, category: :type,
      template: "Type Error: Union '%{union}' declares method '%{method}' more than once.",
      summary:  "Two METHOD clauses on the same union name the same function.",
      cause: "Each method name binds to exactly one function on a UNION. Two METHOD clauses with the same name would create dispatch ambiguity at every call site of `u.%{method}()`.",
      fix_hint: "Drop one of the duplicate METHOD clauses, OR rename the second method on the UNION (and at its call sites) so each name is unique.",
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
    IS_A_NEEDS_COMPTIME: {
      severity: :error, category: :type,
      template: "`IS_A` type predicates must be written as `COMPTIME IF`.",
      summary:  "`IS_A` with a type operand is a compile-time predicate.",
      cause: "A type predicate branches while the compiler is specializing code, not while the program is running.",
      fix_hint: "Insert `COMPTIME` before `IF`.",
    },
    IS_A_OPERAND_NEEDS_TYPE: {
      severity: :error, category: :type,
      template: "Type Error: %{side} side of IS_A must be a type, got %{got}.",
      summary:  "`IS_A` compares compile-time type values; both operands must be types.",
      cause: "`IS_A` is a compile-time type predicate. A normal value such as an Int64, Bool, struct instance, or local variable cannot appear on either side.",
      fix_hint: "Use a type parameter or type name on both sides, and place the predicate under COMPTIME IF.",
    },
    IS_A_RUNTIME_NEEDS_UNION: {
      severity: :error, category: :type,
      template: "Runtime IS_A requires a union-typed value on the left, got %{got}.",
      summary:  "`value IS_A Variant` only works for closed union values.",
      cause: "The runtime form of `IS_A` is sugar for checking a union value's active tag. Non-union values do not carry a variant tag.",
      fix_hint: "Use `COMPTIME IF T IS_A SomeType THEN ... END` for static type-parameter checks, or change the value's type to a UNION and test one of that union's variants.",
    },
    IS_A_RUNTIME_UNKNOWN_VARIANT: {
      severity: :error, category: :type,
      template: "Runtime IS_A target %{target} is not a variant of union %{union}.",
      summary:  "`value IS_A Target` must name a variant of the value's union type.",
      cause: "The compiler lowers runtime `IS_A` to an active-tag comparison. That requires resolving the target to exactly one variant in the subject union.",
      fix_hint: "Use the explicit variant path, for example `%{union}.SomeVariant`, or choose a payload type that appears in exactly one variant of the union.",
    },
    IS_A_RUNTIME_AMBIGUOUS_PAYLOAD: {
      severity: :error, category: :type,
      template: "Runtime IS_A target %{target} matches multiple variants of union %{union}: %{variants}.",
      summary:  "Payload-type shorthand for runtime `IS_A` must resolve to one variant.",
      cause: "More than one variant in the union carries the requested payload type, so the shorthand would not say which active tag to test.",
      fix_hint: "Use the explicit variant path, for example `%{union}.SomeVariant`, to remove the ambiguity.",
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
      cause: "Reserved for a future warning: declaring a primitive-typed parameter `MUTABLE` is a footgun. CLEAR's `MUTABLE x: T` mutates the caller's binding through the parameter — but for primitives (Int64, Float64, Bool, etc.), the parameter is a copy and writes to it never reach the caller. The check would fire on `FN bump!(MUTABLE x: Int64) -> x = x + 1; END`, suggesting either dropping `MUTABLE` (if the local-only mutation is intentional) or returning the new value.",
      fix_hint: "While the check isn't wired, ask: did you mean to mutate the caller's variable? If so, return the new value and assign at the call site. If the local-only mutation is intentional, drop `MUTABLE` from the parameter declaration.",
      pending: true,
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
      template: "Syntax Error: Multiple optional bindings require parentheses around each binding.\n  Found: IF expr EXISTS AS name AND expr EXISTS AS name THEN\n  Use:   IF (expr EXISTS AS name) AND (expr EXISTS AS name) THEN",
      summary:  "Optional-binding chains in IF need each `expr EXISTS AS name` parenthesised.",
    },
    OPTIONAL_BINDING_REQUIRES_EXISTS: {
      severity: :error, category: :syntax,
      template: "Optional binding must state its test: use `expr EXISTS AS name`, not `expr AS name`.",
      summary:  "Optional conditional bindings require the explicit postfix `EXISTS` predicate.",
      fix_hint: "Insert `EXISTS` before `AS`; `clear fix` applies this mechanically.",
    },
    EXISTS_REQUIRES_OPTIONAL: {
      severity: :error, category: :type,
      template: "`EXISTS` requires an optional value, got '%{got}'.",
      summary:  "Postfix `EXISTS` tests whether `?T` contains a value.",
      fix_hint: "Remove `EXISTS` when the value is already non-optional, or correct the expression's type to `?T`.",
    },
    AMBIGUOUS_OPTIONAL_BOOL_LOGIC: {
      severity: :error, category: :type,
      template: "Ambiguous ?Bool %{op} operand: presence and payload truth are different questions. Choose `value EXISTS` (is a Bool present?) or `(value OR_ELSE FALSE)` (is its payload true, defaulting NIL to false?).",
      summary:  "Logical use of `?Bool` must choose presence or payload truth explicitly.",
      fix_hint: "Use `value EXISTS` for presence, or `(value OR_ELSE FALSE)` for payload truth. `clear fix` offers both edits for named values.",
    },
    STRING_CONCAT_REQUIRES_DOLLAR: {
      severity: :error, category: :type,
      template: "String concatenation uses `$+`; `+` is numeric addition.",
      summary:  "String concatenation must use the dedicated `$+` operator.",
      fix_hint: "Replace `+` with `$+`; `clear fix` applies this when operand types prove the expression is string concatenation.",
    },
    IS_OK_REQUIRES_FALLIBLE: {
      severity: :error, category: :type,
      template: "`IS_OK` requires a fallible value, got '%{got}'.",
      summary:  "Postfix `IS_OK` tests whether `!T` succeeded.",
      fix_hint: "Remove `IS_OK` when the value is not fallible, or correct the expression's type to `!T`.",
    },
    IS_READY_CANNOT_BIND: {
      severity: :error, category: :syntax,
      template: "`IS_READY` only polls settlement and cannot bind a payload. Use `IF future IS_READY THEN ...` and consume the outcome with `NEXT`.",
      summary:  "Readiness does not imply that a future succeeded, so `IS_READY AS` is invalid.",
    },
    IS_READY_REQUIRES_FUTURE: {
      severity: :error, category: :type,
      template: "`IS_READY` requires a single future, got '%{got}'. Streams and promise lists have no single settled state.",
      summary:  "Postfix `IS_READY` polls a single future without consuming it.",
    },
    INSERT_EXISTS_BEFORE_AS: {
      severity: :hint, category: :syntax,
      template: "Insert `EXISTS` before `AS`.",
      summary:  "Migrates a legacy optional binding to explicit presence testing.",
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
    PARSER_EXPECTED_AT_END_OF_LINE: {
      severity: :error, category: :syntax,
      template: "Expected `%{expected}` at end of line %{expected_line}; got '%{got}' on line %{got_line}.",
      summary: "Parser expected a token at the end of the previous line.",
      fix_hint: "Insert the expected token at the end of the previous line.",
    },
    PARSER_EXPECTED_BEFORE_TOKEN: {
      severity: :error, category: :syntax,
      template: "Expected `%{expected}`, got '%{got}' (line %{line}).",
      summary: "Parser expected a token before the current token.",
      fix_hint: "Insert the expected token before the current token.",
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
    # src/annotator/helpers/capabilities.rb's ad-hoc strings.

    WITH_CAP_BAD_TARGET: {
      severity: :error, category: :capability,
      template: "WITH %{capability} expects an identifier or field, got '%{got}'.",
      summary:  "WITH-block capture target must be a binding name or field, not an arbitrary expression.",
      cause: "WITH unwraps a *binding* (or a field path rooted at one). The acquire/unwrap dance — lock acquire, snapshot CAS, refcount bump — needs a stable name to operate on. A function call or arbitrary expression has no scope-tracked identity, so the unwrap can't be paired with a release at scope exit.",
      fix_hint: "Bind the value to a local first, then take WITH on the local: `x = produce(); WITH EXCLUSIVE x { ... }`. For field paths, name the root binding directly (`WITH EXCLUSIVE c.field { ... }`).",
    },
    WITH_EXCLUSIVE_NEEDS_LOCK: {
      severity: :error, category: :capability,
      template: "EXCLUSIVE capability requires a @locked or @writeLocked variable, got %{got}",
      summary:  "WITH EXCLUSIVE only applies to bindings declared with `@locked` or `@writeLocked`.",
      cause: "WITH EXCLUSIVE acquires a write lock — the binding must carry a lock to acquire. On a plain `T` there's nothing to lock, so the acquire would be a no-op or, worse, mask a missing-lock bug at runtime.",
      fix_hint: "Either annotate the declaration with `@locked` (Mutex — single-writer EXCLUSIVE access) or `@writeLocked` (RwLock — readers via WITH READ; writers via WITH EXCLUSIVE), or drop WITH EXCLUSIVE if no lock is actually needed (the value can be used directly).",
    },
    WITH_READ_NEEDS_WRITE_LOCK: {
      severity: :error, category: :capability,
      template: "WITH %{name}: read access requires a @writeLocked variable",
      summary:  "Read-style WITH on a `@locked` (read-only) cell is rejected — use `@writeLocked` if reads need to coexist with writes.",
      cause: "WITH READ takes a shared (reader) lock so multiple readers can coexist. A `@locked` Mutex has no reader/writer split — every acquire is exclusive — so WITH READ has nowhere to dispatch. Only `@writeLocked` (RwLock) supports the reader path.",
      fix_hint: "Promote the binding from `@locked` to `@writeLocked` (RwLock — readers via WITH READ alongside writers via WITH EXCLUSIVE), OR keep `@locked` and switch the reader to WITH EXCLUSIVE (single-writer access; readers and writers serialize).",
    },
    WITH_RESTRICT_NEEDS_MUTABLE: {
      severity: :error, category: :capability,
      template: "RESTRICT capability requires a mutable variable, but '%{name}' is immutable",
      summary:  "WITH RESTRICT scopes mutable poisoning — the captured binding must itself be MUTABLE.",
      cause: "WITH RESTRICT establishes an exclusive mutable borrow scope: writes through the alias are visible to the source, and the source can't be aliased elsewhere during the block. Both halves of that contract require the source binding to be mutable in the first place — there's nothing to RESTRICT on an immutable value.",
      fix_hint: "Declare the binding with `MUTABLE` at its definition (`MUTABLE %{name} = ...`). If the binding is intentionally immutable, drop the RESTRICT and use `WITH BORROWED` (immutable read-through) instead.",
    },
    WITH_MATERIALIZED_NEEDS_TENSE: {
      severity: :error, category: :capability,
      template: "WITH MATERIALIZED VIEW requires a `~T` (tense) source, got %{got} for '%{name}'.",
      summary:  "MATERIALIZED VIEW snapshots a tense / observable source — the binding must have type `~T`.",
      cause: "MATERIALIZED VIEW snapshots a *tense aggregate* (`~T`) at the WITH boundary — copying its current contents into an owned, locally-scoped value. On a non-tense source there's no snapshot semantics: the binding is already concrete, and the MATERIALIZED prefix has no effect to apply.",
      fix_hint: "Prefix the declared type with `~` so the source is tense (`MUTABLE %{name}: ~T = ...`), OR drop the MATERIALIZED clause and use the source directly (no WITH needed for a non-tense aggregate).",
    },
    WITH_VIEW_NEEDS_OBSERVABLE: {
      severity: :error, category: :capability,
      template: "WITH VIEW requires an `@observable` source, but '%{name}' has type %{got}. Use `WITH MATERIALIZED VIEW` for non-observable aggregates, or annotate the binding as `~T@observable`.",
      summary: "WITH VIEW can only borrow a live observable aggregate.",
      cause: "WITH VIEW reads a live observable aggregate in place. Non-observable tense values can still be read safely, but only by taking a materialized snapshot.",
      fix_hint: "Use `WITH MATERIALIZED VIEW` for non-observable aggregates, or change the binding declaration to `~T@observable` and initialize it from a pipeline-terminal fold.",
    },
    WITH_SNAPSHOT_NEEDS_VERSIONED_OR_ATOMIC: {
      severity: :error, category: :capability,
      template: "WITH SNAPSHOT requires a @versioned or @indirect:atomic variable. '%{name}' is %{actual}. Declare the binding as `T@versioned` / `T@shared:versioned` for an MVCC cell, or `T@indirect:atomic` for a lock-free atomic-pointer cell.",
      summary:  "WITH SNAPSHOT only works on MVCC cells (`@versioned`) or atomic-pointer cells (`@indirect:atomic`).",
      cause: "WITH SNAPSHOT reads a stable view of a cell that publishes new values atomically. MVCC (`@versioned`) and AtomicPtr (`@indirect:atomic`) are the two sync families that maintain such snapshots; other bindings have no snapshot infrastructure, so the SNAPSHOT acquire has nothing to capture.",
      fix_hint: "Add `@versioned` (MVCC — readers see a stable snapshot, writers retry on conflict) or `@indirect:atomic` (lock-free atomic pointer cell — readers snapshot, writers CAS-publish) to `%{name}`'s declaration. For non-snapshotted reads, use WITH EXCLUSIVE (locks) or direct access (refcounted handles) instead.",
    },
    CAP_FIELD_NEEDS_WITH_EXCLUSIVE: {
      severity: :error, category: :capability,
      template: "Cannot read field '%{field}' of %{cap} binding '%{name}' directly. Wrap with `WITH EXCLUSIVE %{name} AS x { ... x.%{field} ... }` to acquire the lock and unwrap the inner value.",
      summary:  "Direct field access on a locked binding requires WITH EXCLUSIVE to acquire the lock first.",
      cause: "`@locked` (Mutex) and `@writeLocked` (RwLock) bindings hide the inner T behind a lock. Reading `c.field` directly would skip the lock acquire — which is unsound — and the underlying type doesn't have the field anyway (it has `.ctrl`/`.data` and a lock). The compiler routes you through `WITH EXCLUSIVE` so the lock is acquired, the inner T is exposed via the alias, and the lock is released at scope end.",
      fix_hint: "Wrap the access in a WITH EXCLUSIVE block: `WITH EXCLUSIVE c AS x { print(x.field.toString()); }`. Both `@locked` and `@writeLocked` bindings use WITH EXCLUSIVE — there's no separate read-only form on a Mutex, and `@writeLocked` reads still need the writer lock to safely access state.",
    },
    CAP_FIELD_NEEDS_WITH_SNAPSHOT: {
      severity: :error, category: :capability,
      template: "Cannot read field '%{field}' of %{cap} binding '%{name}' directly. Wrap with `WITH SNAPSHOT %{name} AS x { ... x.%{field} ... }` to take a stable snapshot of the cell.",
      summary:  "Direct field access on an atomic-pointer cell requires WITH SNAPSHOT to read a stable T.",
      cause: "`@indirect:atomic` is a CAS-published heap cell — the inner T can be swapped out by other fibers between reads. Direct field access `c.field` would race against publishers, and the underlying `*AtomicPtr(T)` type doesn't have the field anyway. WITH SNAPSHOT loads the current pointer once and binds the alias to that snapshot; the alias's view is stable for the body's duration.",
      fix_hint: "Wrap the access in a WITH SNAPSHOT block: `WITH SNAPSHOT c AS x { print(x.field.toString()); }`. For mutating updates, use `WITH SNAPSHOT MUTABLE c AS x { x.field = ...; }` — the runtime CAS-publishes the modified clone at scope exit.",
    },
    WITH_NEEDS_MULTIOWNED: {
      severity: :error, category: :capability,
      template: "WITH %{name}: expected a @multiowned variable",
      summary:  "Inferred capability requires a `@multiowned` (Rc) binding.",
      cause: "Plain `WITH x` infers the capability from `x`'s sigil. Inference resolved to `:multiowned` because the path expected a refcounted handle, but the binding doesn't carry `@multiowned` — there's no Rc to clone, so the unwrap can't proceed. (Defensive check: in practice this branch fires only if storage briefly looks like multiowned but the symbol no longer carries it.)",
      fix_hint: "Annotate the declaration with `@multiowned` (Rc — single-scheduler refcount; cheap clones on WITH), OR pick a different capability whose semantics fit the binding (`@shared` for cross-fiber, `@locked` for mutable-shared).",
    },
    WITH_NEEDS_SHARED: {
      severity: :error, category: :capability,
      template: "WITH %{name}: expected a @shared variable",
      summary:  "Inferred capability requires a `@shared` (Arc) binding.",
      cause: "Plain `WITH x` resolved to `:shared` (Arc) capability but the binding doesn't carry `@shared` — there's no atomic refcount to bump on WITH entry. (Defensive: like WITH_NEEDS_MULTIOWNED, fires only when storage briefly looks shared but the symbol disagrees.)",
      fix_hint: "Annotate the declaration with `@shared` (Arc — atomic refcount; safe to clone across fibers), OR pick a different capability if the binding doesn't need cross-fiber sharing.",
    },
    WITH_ATOMIC_NEEDS_SHARED_ATOMIC: {
      severity: :error, category: :capability,
      template: "WITH ATOMIC requires an @shared:atomic variable. '%{name}' is %{actual}, not @shared:atomic.",
      summary:  "WITH ATOMIC needs a binding declared `T@shared:atomic`.",
      cause: "WITH ATOMIC dispatches to lock-free atomic primitives (load, store, fetchAdd, ...) on a `@shared:atomic` cell. Other bindings don't have those primitives wired — the unwrap has no atomic-op surface to expose.",
      fix_hint: "Add `@shared:atomic` to `%{name}`'s declaration so it lowers to a lock-free cell. For non-atomic shared mutation, use `@shared:locked` + `WITH EXCLUSIVE` instead.",
    },
    UNKNOWN_WITH_CAP_TYPE: {
      severity: :error, category: :capability,
      template: "Unknown capability type: %{type}",
      summary:  "Internal annotator error — WITH-block dispatch saw a capability tag it doesn't know.",
      cause: "The annotator's WITH-block dispatch table doesn't have a handler for the capability tag `%{type}`. This is an internal compiler bug (or a stale build): every legal capability should have a corresponding dispatch arm. User code can't trigger this directly.",
      fix_hint: "If you saw this from a user program, please report it as a compiler bug with the source snippet that triggered it. As a workaround, verify the capability sigil is one of: `@multiowned`, `@shared`, `@locked`, `@writeLocked`, `@versioned`, `@shared:atomic`, `@indirect:atomic`, `@local`.",
    },
    WITH_CANNOT_INFER_CAP: {
      severity: :error, category: :capability,
      template: "WITH %{name}: cannot infer capability; variable must be @multiowned, @shared, @locked, @writeLocked, @versioned, @shared:atomic, or another capability type",
      summary:  "Plain WITH without an explicit capability needs the binding to carry a recognised one.",
    },

    # WITH GUARD specifics
    WITH_GUARD_NOT_WITH_MATCH: {
      severity: :error, category: :capability,
      template: "WITH GUARD is not supported with WITH MATCH yet. WITH MATCH dispatches per-arm based on the binding's sync family; GUARD evaluates a single predicate after acquire. The two haven't been integrated. Run the GUARD check before the WITH MATCH (in the surrounding scope), or split the polymorphic-dispatch and guard-predicate concerns into two separate blocks.",
      summary:  "WITH MATCH and WITH GUARD can't be combined in the current release.",
      cause: "WITH MATCH switches the body shape based on the binding's sync family (LOCKED / ATOMIC / VERSIONED arms). WITH GUARD attaches a post-acquire predicate that aborts the body when false. The matching layer hasn't been wired through the per-arm preludes yet, so combining them is rejected.",
      fix_hint: "Move the GUARD predicate to a regular `IF` at the top of the body (each WITH MATCH arm checks the predicate itself), or restructure so GUARD-checked bindings are acquired in a separate (non-MATCH) WITH block that nests inside or wraps the polymorphic block.",
    },
    WITH_GUARD_NOT_ON_SNAPSHOT: {
      severity: :error, category: :capability,
      template: "WITH GUARD is not supported on mutable SNAPSHOT transactions in this release. Read-only SNAPSHOT works (the guard runs against the snapshot view); MUTABLE SNAPSHOT is rejected because the transaction would have to retry on guard failure, which interacts with the MVCC commit retry loop.",
      summary:  "Mutable SNAPSHOT transactions don't support WITH GUARD yet.",
      cause: "MUTABLE SNAPSHOT runs the body inside an MVCC retry loop — on commit-failure it re-executes the body. GUARD-failure also wants to abort the body, but its semantics (don't retry, don't commit) conflict with the MVCC retry contract.",
      fix_hint: "Use read-only `WITH SNAPSHOT c AS s GUARD ...` (drop MUTABLE), check the predicate AFTER the SNAPSHOT block reads, or move the mutation into a separate non-snapshot path.",
    },
    WITH_GUARD_ALL_BINDINGS_NEED_AS: {
      severity: :error, category: :capability,
      template: "WITH GUARD requires every participating binding to have an `AS` alias so the guard predicate can read the unwrapped value. Add `AS <alias>` to each binding in the WITH clause.",
      summary:  "Each binding in a WITH GUARD must use `AS <name>` so the guard body can read it.",
      cause: "WITH GUARD's predicate runs after each acquire and reads the unwrapped value. Without an AS alias, the unwrapped form has no name in scope — the predicate would have nothing to read.",
      fix_hint: "Add `AS <name>` to every binding in the WITH clause: `WITH EXCLUSIVE c AS x EXCLUSIVE d AS y GUARD x.v + y.v > 0 { ... }`.",
    },
    WITH_GUARD_EXPR_MUST_BE_BOOL: {
      severity: :error, category: :capability,
      template: "WITH GUARD expression must return Bool, got %{got}.",
      summary:  "The guard predicate's type must be Bool.",
      cause: "The GUARD predicate gates body execution: TRUE proceeds, FALSE raises GuardFail. A non-Bool expression has no defined truth value, so it's rejected at type-check.",
      fix_hint: "Wrap the guard expression so it returns Bool (e.g. `x.v > 0`, `x.name == \"ready\"`, `x.flags.contains(.active)`). If you intended a side effect, move it before the WITH and only test a Bool inside GUARD.",
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
      cause: "GUARD predicates evaluate ONCE, immediately after acquire. If the body then mutates the alias, the post-mutation state may no longer satisfy the predicate — but the body keeps running because there's no re-check. To prevent silent invalidation, the compiler rejects the alias being both MUTABLE and mutated inside the body.",
      fix_hint: "Pick one: (a) drop `MUTABLE` from the alias if you don't need to write through it; (b) drop the body's mutation if the read-only path is enough; (c) move the mutation outside the guarded WITH (acquire, check, release, then re-acquire MUTABLE for the write).",
    },

    # Borrow
    BORROW_WILDCARD_NEEDS_STRUCT: {
      severity: :error, category: :capability,
      template: "Wildcard borrow '*' requires a struct type, but '%{name}' is %{type}.",
      summary:  "`WITH BORROWED x.*` only applies to struct-typed targets — it expands to per-field borrows.",
      cause: "`WITH BORROWED x.*` is sugar for `BORROWED x.field1 BORROWED x.field2 ...`. The wildcard expansion only makes sense on a struct (which has named fields). Lists, maps, primitives, etc. don't expand.",
      fix_hint: "Borrow the whole binding instead: `WITH BORROWED %{name} { ... }`. For collections, iterate or index inside the body rather than borrowing each element.",
    },
    WITH_BORROWED_ON_QUALIFIED_VAR: {
      severity: :error, category: :capability,
      template: "Cannot use WITH BORROWED on %{qualifier} variable '%{name}'. %{remediation}",
      summary:  "WITH BORROWED rejected because the source binding is qualified in a way that conflicts.",
      cause: "WITH BORROWED produces an immutable read-through alias. Some qualifier on the source (e.g. an `@indirect:atomic` cell, a tense source, a lock-only binding) requires going through that qualifier's unwrap — a plain BORROWED would skip the synchronisation or transformation the qualifier provides.",
      fix_hint: "Use the unwrap form that matches the binding's qualifier: `WITH SNAPSHOT` for atomic / versioned cells, `WITH EXCLUSIVE` / `WITH READ` for locks, `WITH MATERIALIZED VIEW` for tense aggregates. The remediation in the message names the specific replacement.",
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
    PRE_CLAUSES_NEED_EXPLICIT_FALLIBLE_RETURN: {
      severity: :error, category: :type,
      template: "Function '%{fn}' has PRE clauses but no explicit return type. PRE clauses can fail at runtime, so the function must declare an error-union return. Add `RETURNS !Void` (or `RETURNS !T` for a value-returning function) to the signature.",
      summary: "PRE clauses require an explicit fallible return type.",
      fix_hint: "Add `RETURNS !Void` for an otherwise Void function, or `RETURNS !T` for a value-returning function.",
    },
    FALLIBLE_RETURN_NEEDS_ERROR_UNION: {
      severity: :error, category: :type,
      template: "Function '%{fn}' can fail (%{hint}) but its return type doesn't declare it. Change `RETURNS %{return_type}` to `RETURNS !%{return_type}` so callers can see the error union and handle it (Zig-style discipline). Add a CATCH at the call site, propagate via `try`, or mark the call's result with `OR <action>`.",
      summary: "A fallible function must declare an error-union return type.",
      fix_hint: "Prefix the declared return type with `!`, or handle the failure before it crosses the function boundary.",
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
    # src/annotator/helpers/pipe_analysis.rb's ad-hoc strings.

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
      cause: "Pipeline modifiers like `RAISE`, `RECOVER`, `OR_ELSE EXIT`, `OR_ELSE RAISE` operate on the error half of an error-union (`!T`). On a plain `T` they have nothing to dispatch on — there's no error case to handle. CLEAR rejects them at compile time so the user catches the misuse early.",
      fix_hint: "Either remove the modifier (the value is already plain T), make the upstream call fallible so it returns `!T` (e.g. mark the called fn `RETURNS !U`), or wrap the value with an explicit RAISE if you want to inject a failure.",
    },

    # ===================================================================
    # ANNOTATOR — control flow, assignment, indexing (Tranche 5a)
    # ===================================================================
    # Migrated from src/annotator.rb's ad-hoc strings. Templates copy
    # the existing user-facing wording verbatim.

    # Setup / imports / fn metadata
    REQUIRE_NEEDS_IMPORTER: {
      severity: :error, category: :registry,
      template: "REQUIRE is only supported when using the Importer. Pass importer: and source_dir: to SemanticAnnotator.new.",
      summary:  "REQUIRE statement reached annotation without an active importer (script-mode invocation).",
    },
    STYLE_MUTABLE_PARAM_NEEDS_BANG: {
      severity: :error, category: :ownership,
      template: "Style Error: Function '%{name}' has MUTABLE parameters. Its name must end in '!'",
      summary:  "Functions that take MUTABLE params should end with `!` to surface the mutation at every call site.",
    },
    MUTABLE_UNUSED: {
      severity: :warning, category: :lint,
      template: "MUTABLE '%{name}' is never reassigned — consider removing MUTABLE",
      summary: "A binding was declared MUTABLE but never reassigned.",
      fix_hint: "Remove the MUTABLE keyword unless the declaration is intentionally reserving future mutability.",
    },
    LOCAL_NEVER_SHARED: {
      severity: :info, category: :lint,
      template: "Variable '%{name}' is @local but never shared across fibers. You are paying for a heap allocation with no sharing benefit. Consider removing @local.",
      summary: "An @local binding never crosses a fiber boundary.",
      fix_hint: "Remove `@local` from the declaration when the binding stays within one fiber.",
    },
    BARE_VERSIONED_UNSHARED: {
      severity: :warning, category: :lint,
      template: "Bare `@versioned` on '%{name}' is unusual: a single-owner MVCC cell isn't reachable from another thread, so the lock-free commit path has no concurrent benefit. Use `@shared:versioned` for cross-thread sharing, or remove `@versioned` if the cell is truly local.",
      summary: "A single-owner @versioned cell pays MVCC cost without cross-thread reachability.",
      fix_hint: "Use `@shared:versioned` for cross-thread sharing, or remove `@versioned` if the binding is truly local.",
    },
    DUPLICATE_DECLARATION: {
      severity: :error, category: :type,
      template: "Duplicate %{label} declaration '%{name}'",
      summary: "A declaration name was registered more than once in the same namespace.",
    },
    DUPLICATE_FUNCTION_DECLARATION: {
      severity: :error, category: :type,
      template: "Duplicate function declaration '%{name}'",
      summary: "A function name was registered more than once.",
    },
    DUPLICATE_EXTERN_METHOD_DECLARATION: {
      severity: :error, category: :type,
      template: "Duplicate extern method declaration '%{owner}.%{name}'",
      summary: "An extern method was registered more than once for the same owner.",
    },

    # Reentrance
    REENTRANCE_DIRECT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' directly calls itself. Add `EFFECTS REENTRANT` to the function signature to declare the recursion budget.",
      summary:  "Function calls itself directly without declaring the recursion budget.",
      fix_hint: "Add `EFFECTS REENTRANT` to the function signature.",
    },
    REENTRANCE_INDIRECT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' calls itself recursively. Add `EFFECTS REENTRANT` to the function signature to allow this.",
      summary:  "Function reaches itself through a call chain without declaring the recursion budget.",
      fix_hint: "Add `EFFECTS REENTRANT` to the function signature to allow this.",
    },
    REENTRANCE_THUNK_NON_TAIL: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:THUNK on '%{name}' has non-tail recursion in a shape this phase does not yet recognize. Supported: simple recurrence (zero or more `IF base -> RETURN const;` followed by a final `RETURN expr <op> %{name}(args);`). Wider shapes (multi-recursion, arbitrary control flow with recursion) land in later sub-phases. For now, declare ':TAIL_CALL' or use plain 'EFFECTS REENTRANT'.",
      summary:  "EFFECTS REENTRANT:THUNK requires the recursion to be in tail position; this call isn't.",
      fix_hint: "a shape this phase does not yet recognize. Supported: simple recurrence (zero or more `IF base -> RETURN const;` followed by a final `RETURN expr <op> %{name}(args);`). Wider shapes (multi-recursion, arbitrary control flow with recursion) land in later sub-phases. For now, declare ':TAIL_CALL' or use plain 'EFFECTS REENTRANT'.",
    },
    REENTRANCE_TAIL_CALL_NOT_RECURSIVE: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:TAIL_CALL on '%{name}' but the function is not recursive. Remove :TAIL_CALL - it only applies to self-recursive functions.",
      summary:  "`EFFECTS REENTRANT:TAIL_CALL` declared on a function that doesn't recurse.",
      fix_hint: "Remove :TAIL_CALL - it only applies to self-recursive functions.",
    },

    # IF / MATCH / WHEN
    IF_AS_NEEDS_OPTIONAL: {
      severity: :error, category: :type,
      template: "IF ... EXISTS AS binding requires an optional type, got '%{got}'",
      summary:  "`IF expr AS name THEN ...` requires `expr` to be optional (`?T`).",
      cause: "`IF expr AS x` is the optional-narrowing form: when `expr` is `?T` and non-NIL, `x` is bound to the unwrapped `T` inside the THEN branch. On a plain `T` there's nothing to unwrap, so the AS binding has no defined meaning.",
      fix_hint: "Drop the `AS x` clause and use `expr` directly (it's already non-optional), OR make the source optional by returning `?T` from a fallible lookup so the AS narrow has something to unwrap.",
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
    MATCH_MULTI_ARM_PAYLOAD_MISMATCH: {
      severity: :error, category: :type,
      template: "MATCH multi-pattern arm: variants '%{head}' and '%{other}' have incompatible payloads, so the shared `%{kind} %{name}` cannot bind across both.",
      summary:  "Multi-pattern MATCH arm with `AS` or `{ destructure }` requires every variant to share the same payload shape.",
      cause:    "`Pat1, Pat2 AS x -> body` evaluates one body with one binding `x` for whichever variant matched at runtime. CLEAR (and the underlying Zig switch) only allows the shared binding when every variant in the arm carries the SAME payload type — same primitive, same inline-struct fields, or all unit. Variants with diverging payloads can't be unified into one binding without a runtime selector and a synthesized union type.",
      fix_hint: "Either drop the `AS` / `{ destructure }` (the variants can still share a body without a shared binding), split the arm into separate single-pattern arms each with its own `AS` / destructure, or change the union so the listed variants share a payload type.",
    },
    MATCH_DUPLICATE_PATTERN: {
      severity: :error, category: :type,
      template: "MATCH variant '%{variant}' is matched more than once. Duplicate patterns produce invalid Zig switch prongs.",
      summary:  "Each enum / union variant may appear at most once across all MATCH arms (single or multi-pattern).",
      cause:    "MATCH lowers to a Zig switch (or if-chain). A variant appearing in two arms — or twice in the same multi-pattern arm — would emit `case .A, .A => ...` or two separate `.A` prongs. Zig rejects both as duplicates; the catch in the annotator surfaces the user-side mistake clearly instead of letting it bottom out as a downstream codegen error.",
      fix_hint: "Remove the redundant pattern. If two arms have different bodies for the same variant, keep the one you want and delete the other; if a multi-pattern arm lists a variant twice, drop the duplicate.",
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
      template: "%{detail}",
      summary:  "Loop body consumes a value on the first iteration; subsequent iterations have nothing left to GIVE.",
      cause: "An affine value can only be TAKEN once. The loop body moves (GIVE / TAKES / RETURN / etc.) the binding, so the second iteration would be reading something that's already been transferred.",
      fix_hint: "Hoist the move out of the loop, or wrap the consuming reference with `COPY` (if the type permits) so each iteration gets its own owned copy. For shared aggregation, declare the binding `@multiowned` (single-scheduler Rc) or `@shared` (cross-fiber Arc).",
    },
    USE_OF_MOVED_VALUE: {
      severity: :error, category: :ownership,
      template: "%{detail}",
      summary:  "Binding was already TAKEN / GIVEN at a prior site and is no longer accessible.",
      cause: "An affine binding has exactly one owner. A prior expression (a `TAKES` parameter, `GIVE`, `RETURN`, `SHARE`, `NEXT`, etc.) consumed ownership; the current use is left holding nothing.",
      fix_hint: "Wrap the consuming reference with `COPY` (if the type permits — primitives, strings, and enums are Copy by default; non-Copy types need `@multiowned` / `@shared` to share). Or restructure so only one site consumes the value.",
    },
    INFERRED_ALIAS_MUTATION: {
      severity: :error, category: :ownership,
      template: "%{detail}",
      summary: "Mutation overlaps an implicitly inferred alias; CLEAR will not guess snapshot versus shared identity.",
      cause: "A plain assignment created two live names and one was mutated before the other's last use. Choosing COPY would isolate the mutation; choosing Rc/Arc identity would share it. That semantic choice is never inferred, including in EASY mode.",
      fix_hint: "Write `COPY source` for an independent snapshot, or explicitly declare Rc/Arc identity (`@multiowned` or `@shared`) and write `CLONE source`. You can also shorten the alias lifetime so it ends before mutation.",
    },
    STRICT_IMPLICIT_OWNERSHIP_COST: {
      severity: :error, category: :ownership,
      template: "%{detail}",
      summary: "STRICT mode rejects an implicit copy or reference-count retain.",
      cause: "The common ownership planner proved the operation safe, but its selected transport has a runtime cost. STRICT requires that cost to be visible in source.",
      fix_hint: "Write `COPY value` for a snapshot or `CLONE value` for an existing Rc/Arc identity, or shorten the lifetime so the operation can be a move/borrow.",
    },
    RECURSIVE_LAYOUT_REQUIRES_INDIRECT: {
      severity: :error, category: :type,
      template: "Layout Error: recursive field %{edge} has infinite inline size. Choose an explicit topology: `@node` for most mutable graphs; `@indirect` for a unique owned recursive edge; `@multiowned` for local shared tree/DAG identity; `@shared` for cross-execution shared identity; or `@link` for a non-owning edge into an independently owned, potentially enormous/open topology.",
      summary: "Recursive inline storage requires an explicit topology choice in every mode.",
      cause: "A value cannot contain itself inline because its size would be infinite.",
      fix_hint: "Prefer `@node` for ordinary graphs, `@indirect` for uniquely owned recursive trees, an RC capability for shared identity, or `@link` for non-owning cross-domain edges. CLEAR does not infer this performance- and identity-bearing choice, even in EASY.",
    },
    RECURSIVE_LAYOUT_AMBIGUOUS: {
      severity: :error, category: :type,
      template: "Layout Error: recursive component has multiple cycle-breaking choices (%{edges}). Choose explicitly: `@node` for most graphs; `@indirect` for selected unique-owner edges; `@multiowned` or `@shared` for shared identity; or `@link` for non-owning edges. These choices have different ownership, allocation, and traversal costs.",
      summary: "The compiler will not choose among performance-distinct recursive layouts.",
      cause: "More than one field can break the recursive layout cycle, and each choice changes allocation and cache behavior.",
      fix_hint: "Prefer `@node` for ordinary graphs. Use `@indirect` only for a selected unique-owner edge, RC capabilities for shared identity, and `@link` for non-owning references into separately owned domains.",
    },
    INDIRECT_ARGUMENT_EXPLICIT: {
      severity: :error, category: :type,
      template: "Layout Error: argument %{index} requires %{expected}. EASY may construct the forced indirect representation automatically; DEFAULT and STRICT require explicit `@indirect` layout.",
      summary: "A call cannot hide a heap-indirection choice outside EASY mode.",
      cause: "The callee ABI is pointer-backed but the argument is an inline value.",
      fix_hint: "Construct or declare the value with `@indirect`, or use EASY mode when this destination contract uniquely forces the representation.",
    },
    INDIRECT_FIELD_EXPLICIT: {
      severity: :error, category: :type,
      template: "Layout Error: field '%{field}' requires %{expected}. EASY may construct the forced indirect representation automatically; DEFAULT and STRICT require explicit `@indirect` layout.",
      summary: "A field initializer cannot hide a heap-indirection choice outside EASY mode.",
      cause: "The field representation is pointer-backed but the initializer is an inline value.",
      fix_hint: "Construct or declare the value with `@indirect`, or use EASY when the field contract uniquely forces it.",
    },
    INDIRECT_ELEMENT_PRIMITIVE: {
      severity: :error, category: :type,
      template: "Layout Error: `@indirect` element layout is not allowed for primitive %{type}; it adds an allocation and pointer chase without solving a recursive layout.",
      summary: "Primitive collection elements must remain inline.",
      cause: "Primitive values already have finite, compact layouts. Boxing each element would predictably damage locality and memory use.",
      fix_hint: "Use `%{type}[]@list`, or wrap the primitive in a STRUCT if stable identity is actually required.",
    },
    INDIRECT_ELEMENT_EXPLICIT: {
      severity: :error, category: :type,
      template: "Layout Error: inserting inline %{type} into `%{type}@indirect[]@list` requires a heap allocation. EASY may apply this uniquely forced layout; DEFAULT and STRICT require an explicit `@indirect` construction.",
      summary: "A collection insertion cannot hide a heap allocation outside EASY mode.",
      cause: "The destination stores pointers, while the source is an inline value. Converting it requires allocating one unique box.",
      fix_hint: "Construct the value with `@indirect`, change the collection to inline `%{type}[]@list`, or use `@node` when this is graph identity rather than unique indirection.",
    },
    INDIRECT_ELEMENT_IDENTITY: {
      severity: :error, category: :type,
      template: "Layout Error: %{actual} identity cannot be implicitly converted to unique `%{type}@indirect` ownership.",
      summary: "Identity-bearing capabilities are not interchangeable with a unique box.",
      cause: "@node, @link, @multiowned, and @shared each have distinct identity and lifetime semantics. Unwrapping one into @indirect would silently change those semantics.",
      fix_hint: "Make the destination use the same capability, explicitly COPY a payload when legal, or choose a different topology representation.",
    },
    INDIRECT_TRANSFER_REQUIRES_COPY: {
      severity: :error, category: :ownership,
      template: "Layout Error: `%{name}` is still live after insertion into an `@indirect` destination. Boxing can move a payload at zero copy cost only when the source is consumed; write `COPY %{name}` for an explicit snapshot, construct/move an `@indirect` value, or shorten the source lifetime.",
      summary: "Automatic boxing will not hide a deep copy.",
      cause: "The destination needs ownership while the original binding remains live. Preserving both values requires a potentially expensive semantic copy.",
      fix_hint: "Use `COPY` explicitly, create the source as `@indirect` and move it, keep inline elements, or restructure so the source is dead at insertion.",
    },
    COLLECTION_ELEMENT_LAYOUT_MISMATCH: {
      severity: :error, category: :type,
      template: "Layout Error: collection element layout mismatch; expected %{expected}, got %{actual}.",
      summary: "Inline-element and indirect-element collections are different concrete representations.",
      cause: "One collection stores payloads inline and the other stores pointers. Their ABIs and mutation costs are not interchangeable.",
      fix_hint: "Change the parameter/collection to the same element layout, or move elements explicitly between the two collections.",
    },
    USE_OF_MOVED_IN_LOOP_SHORT: {
      severity: :error, category: :ownership,
      template: "%{detail}",
      summary:  "Loop body uses a value that was already TAKEN on a prior iteration.",
      cause: "Same as USE_OF_MOVED_IN_LOOP — the binding was consumed on the first iteration; the second iteration has nothing left to GIVE.",
      fix_hint: "Same: hoist the move out of the loop, or `COPY` per-iteration, or upgrade to `@multiowned` / `@shared`.",
    },
    USE_OF_MOVED_PATH: {
      severity: :error, category: :ownership,
      template: "%{detail}",
      summary:  "Path's owner (root binding) was already TAKEN or GIVEN; sub-paths are no longer accessible.",
      cause: "Sub-path access (`b.field`, `arr[i]`) reads through an owner. If the owner itself was transferred (TAKES / GIVE / RETURN / etc.), the sub-path goes with it — the owner takes its fields along.",
      fix_hint: "Either consume the field directly (`GIVE b.field`) before the owner is transferred, or `COPY` the field, or restructure so the owner isn't moved before the field's last use.",
    },
    WHILE_AS_NEEDS_OPTIONAL: {
      severity: :error, category: :type,
      template: "WHILE ... EXISTS AS binding requires an optional type, got '%{got}'",
      summary:  "`WHILE expr AS name DO ...` requires `expr` to be optional (`?T`).",
      cause: "`WHILE expr AS x DO ...` loops while `expr` returns a non-NIL `?T`, binding the unwrapped `T` to `x` per iteration. On a plain non-optional `T`, the loop has no NIL termination signal — it would run forever — so the form is rejected.",
      fix_hint: "Make the source fallible (e.g. `iter.next()` on a stream returns `?T`), OR use a regular `WHILE <bool-expr> DO ...` for non-optional looping.",
    },
    WHILE_AS_IMMUTABLE_RECEIVER: {
      severity: :error, category: :ownership,
      template: "WHILE ... EXISTS AS binding: '%{method}' is called on immutable '%{recv}' -- the condition cannot advance and may loop forever. Declare '%{recv2}' as MUTABLE or use a regular WHILE loop.",
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
      template: "Cannot RETURN '%{name}' from inside a WITH block. WITH aliases are borrows of locked data and cannot escape their scope. Either RETURN COPY alias (breaks the borrow), or restructure so the value's lifetime exceeds the WITH (move the value out of the cell before the WITH body ends).",
      summary:  "WITH-scoped aliases (`AS x`) are non-escaping — they can't be returned.",
      cause: "A WITH ... AS alias block creates a scoped binding that doesn't outlive the WITH body. Returning the alias would let the caller see a value whose backing storage is gone.",
      fix_hint: "Either RETURN COPY alias (breaks the borrow), or restructure so the value's lifetime exceeds the WITH (move the value out of the cell before the WITH body ends).",
    },
    RETURN_FIELD_FROM_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot RETURN a field of a WITH-scoped binding. Field access borrows from the locked data; the borrow cannot escape the WITH scope.",
      summary:  "Field of a WITH-scoped binding can't be returned (would outlive the WITH).",
      fix_hint: "Field access borrows from the locked data; the borrow cannot escape the WITH scope.",
    },
    RETURN_INDEX_FROM_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "Cannot RETURN an indexed access of a WITH-scoped binding. Index access borrows from the locked data; the borrow cannot escape the WITH scope.",
      summary:  "Indexed access on a WITH-scoped binding can't be returned (would outlive the WITH).",
      fix_hint: "Index access borrows from the locked data; the borrow cannot escape the WITH scope.",
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
      template: "Atomic primitives do not support `%{op}`. Use a CAS loop via `c.compareAndSwap(old, new)` to update the cell atomically with an arbitrary computation, OR switch the binding from `@shared:atomic` to `@shared:locked` and do the math inside `WITH EXCLUSIVE c AS x { x.v *= 2; }` — the lock makes the read-modify-write atomic.",
      summary:  "Compound `*=` / `/=` not available on `@shared:atomic` targets.",
      cause: "`@shared:atomic` lowers to single-instruction atomic primitives (load, store, fetchAdd, fetchSub, AND/OR/XOR). Multiplication and division have no single-instruction atomic form on any mainstream architecture, so they're rejected at compile time rather than silently lowered to a non-atomic load+op+store race.",
      fix_hint: "Use a CAS loop via `c.compareAndSwap(old, new)` to update the cell atomically with an arbitrary computation, OR switch the binding from `@shared:atomic` to `@shared:locked` and do the math inside `WITH EXCLUSIVE c AS x { x.v *= 2; }` — the lock makes the read-modify-write atomic.",
    },
    ATOMIC_UNSUPPORTED_COMPOUND: {
      severity: :error, category: :capability,
      template: "Compound op %{op} is not supported on @shared:atomic targets.",
      summary:  "Compound op other than `+=` / `-=` / `&=` / `|=` / `^=` not available on `@shared:atomic`.",
      cause: "`@shared:atomic` only accepts compound ops that map to a single hardware atomic primitive. The supported set is exactly: `+=` (fetchAdd), `-=` (fetchSub), `&=` (fetchAnd), `|=` (fetchOr), `^=` (fetchXor). Anything else would require a non-atomic read-modify-write. Defensive code path: the lexer currently only produces `+= -= *= /=`, so this branch is unreachable in user code today; kept as a safety net for any future compound-op token.",
      fix_hint: "Either rewrite the op as a `compareAndSwap` loop (`c.compareAndSwap(old, new)`) — which atomically applies an arbitrary computation — OR switch the binding to `@shared:locked` and perform the op inside `WITH EXCLUSIVE c AS x { ... }` so the lock guarantees atomicity.",
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
    TYPE_MISMATCH_ASSIGN: {
      severity: :error, category: :type,
      template: "Type Mismatch: Cannot assign %{got} to %{expected}",
      summary:  "Right-hand side's type doesn't fit the assignment target's type.",
      cause: "The value being assigned to an existing binding doesn't match the binding's declared type. Coercion was tried and failed.",
      fix_hint: "Either change the value, change the declared type at the binding's declaration site, or use CAST for an explicit conversion.",
    },
    DESTRUCTURE_REQUIRES_FIXED_SHAPE: {
      severity: :error, category: :type,
      template: "Destructuring assignment requires a fixed-size RHS, got %{got}",
      summary:  "Destructuring only accepts values whose element count is statically known.",
      cause: "`a, b = value` must know exactly how many slots `value` contains at compile time. Dynamic arrays, streams, and unknown call results cannot be destructured safely.",
      fix_hint: "Use a fixed-size array or tuple-like value, or assign through explicit indexing after checking the shape.",
    },
    DESTRUCTURE_ARITY_MISMATCH: {
      severity: :error, category: :type,
      template: "Destructuring target count %{targets} does not match RHS size %{values}",
      summary:  "The number of destructuring targets must match the RHS fixed size.",
    },
    DESTRUCTURE_REQUIRES_COPYABLE_RHS: {
      severity: :error, category: :type,
      template: "Destructuring assignment currently requires a copyable RHS, got %{got}",
      summary:  "Only fixed-size values with copyable elements can be destructured today.",
      cause: "Owned element destructuring needs explicit per-slot ownership transfer and cleanup metadata. Lowering it as a plain fixed array would obscure ownership.",
      fix_hint: "Use copyable fixed-size values, or assign owned elements explicitly until owned destructuring is implemented.",
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
      cause: "A union value carries exactly one active variant at a time. The `T{ Variant: payload }` literal produces a single value; listing multiple variants would imply two simultaneously-active variants, which the tagged-union representation can't express.",
      fix_hint: "Pick the one variant you intend to construct: `%{name}{ Variant: payload }`. If you need a value that could be one of several variants, construct the appropriate one in a CONDITIONAL (`IF cond -> %{name}.A(x), ELSE %{name}.B(y) END`).",
    },
    UNION_VARIANT_IS_UNIT_NO_PAYLOAD: {
      severity: :error, category: :type,
      template: "Union variant '%{variant}' is a unit variant — use '%{union}.%{variant2}' (no payload).",
      summary:  "Tried to construct a unit variant with payload syntax.",
      cause: "Unit variants (`Variant` declared without a `: T` clause in the UNION) carry no associated data. Calling them like a payloaded variant (`Type.Variant(x)`) would supply a value the variant has no slot for.",
      fix_hint: "Drop the parentheses: `%{union}.%{variant2}` is the construction form for unit variants. If you need to carry data, declare the variant with a payload type (`%{variant}: T`) at the UNION definition.",
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
      template: "Type Error: %{detail}",
      summary:  "Generic type-error wrapper for messages produced elsewhere (e.g., Type#coerce_error).",
    },
    AUTO_INFERRED_TYPE: {
      severity: :info, category: :type,
      template: "Inferred type for %{label}: %{type}.",
      summary: "Auto inference resolved a type annotation.",
      fix_hint: "Replace `Auto` with the inferred type if you want the source to be explicit.",
    },
    AUTO_INFERRED_BINDING_TYPE: {
      severity: :info, category: :type,
      template: "Inferred type for `%{name}`: %{type}.",
      summary: "Auto inference resolved a binding type annotation.",
      fix_hint: "Replace `Auto` with the inferred type if you want the source to be explicit.",
    },
    AUTO_AMBIGUOUS_TYPE: {
      severity: :error, category: :type,
      template: "%{detail}",
      summary: "Auto inference found multiple incompatible candidate types.",
      fix_hint: "Choose a concrete type and update the annotation, or narrow the call sites that produce incompatible observations.",
    },
    AUTO_UNRESOLVED_TYPE: {
      severity: :error, category: :type,
      template: "%{detail}",
      summary: "Auto inference could not observe enough uses to choose a type.",
      fix_hint: "Replace `Auto` with a concrete type, or add enough typed use sites for inference to converge.",
    },

    # OR_ELSE / IF expression / unwrap
    OR_BREAK_OUTSIDE_WHILE: {
      severity: :error, category: :type,
      template: "OR_ELSE BREAK can only be used inside a WHILE loop",
      summary:  "`expr OR_ELSE BREAK` is only valid inside a WHILE loop body.",
      cause: "`OR_ELSE BREAK` is sugar for \"if the expression yielded NIL or an error, break out of the surrounding loop.\" Outside any loop there's nothing to break out of — the keyword has no target.",
      fix_hint: "Wrap the expression in a `WHILE` loop if iteration is what you want, OR use a different fallback (`OR_ELSE EXIT`, `OR_ELSE RAISE`, `OR <default>`) that has a defined meaning at the current scope.",
    },
    TYPE_MISMATCH_IN_OR: {
      severity: :error, category: :type,
      template: "Type mismatch in OR_ELSE: expected %{expected}, got %{got}",
      summary:  "Right-hand side of `OR_ELSE` must match the optional/error-union's payload type.",
      cause: "`expr OR_ELSE fallback` substitutes the fallback when `expr` is NIL (optional case) or an error (error-union case). The fallback's type must match the payload type because both branches feed into the same downstream binding — without type alignment, the binding would have no determinable type.",
      fix_hint: "Either change the fallback to produce a value of the expected payload type (e.g. `OR_ELSE 0` when the payload is `Int64`), CAST it explicitly (`OR_ELSE CAST(x AS PayloadT)`), or rewrite the LHS to widen its payload to a common type with the fallback.",
    },
    UNWRAP_NON_OPTIONAL: {
      severity: :error, category: :type,
      template: "Cannot unwrap non-optional type '%{got}' with '?'",
      summary:  "`expr?` only applies to optional types (`?T`).",
      cause: "The `?` postfix is the optional-unwrap operator: it asserts non-NIL and yields the inner `T`. On a plain `T` it would be a no-op, but allowing it would mask later refactors that change the type — so the compiler rejects it explicitly.",
      fix_hint: "Drop the trailing `?` (the value is already non-optional). If you intended to PROPAGATE failure, use `OR_ELSE RAISE` / `OR_ELSE EXIT` / `OR <default>` on a fallible source instead.",
    },
    IF_EXPR_THEN_NEEDS_VALUE: {
      severity: :error, category: :type,
      template: "IF expression: THEN branch must end with a value expression",
      summary:  "When IF is used as an expression, the THEN branch's last statement must be a value.",
      cause: "`x = IF cond THEN ... END` is the expression form: every branch must yield a value because that value is what gets assigned to `x`. A THEN that ends in a statement (assignment, RETURN, side-effect call) has nothing to feed the assignment.",
      fix_hint: "Make the last line of the THEN branch a value expression — drop the trailing `;` from a single-expression branch, or end with the value you want to bind. If you don't need a value, use the statement form: `IF cond THEN ... END;` (no surrounding assignment).",
    },
    IF_EXPR_NEEDS_ELSE: {
      severity: :error, category: :type,
      template: "IF used as expression requires an ELSE branch",
      summary:  "Expression-form IF must cover all paths via an ELSE.",
      cause: "An expression-form IF must yield a value on every path. Without ELSE, the path where `cond` is false has no value to assign — the binding would be uninitialised. CLEAR rejects this at compile time so there's no NIL/garbage path.",
      fix_hint: "Add an `ELSE -> <value>` arm. If the false case should fall through with NIL, declare the binding as `?T` and `ELSE -> NIL`. If only the true path matters and you want side-effects, use the statement form (`IF cond THEN ... END;`).",
    },
    IF_EXPR_ELSE_NEEDS_VALUE: {
      severity: :error, category: :type,
      template: "IF expression: ELSE branch must end with a value expression",
      summary:  "Expression-form IF's ELSE branch must end with a value.",
      cause: "Same rule as THEN: every branch of an expression-form IF must yield the binding's value. An ELSE that ends in a statement leaves the false-path binding uninitialised.",
      fix_hint: "End the ELSE branch with a value expression, or fall back to the statement form if the value is only needed on the true path.",
    },
    IF_EXPR_BRANCHES_INCOMPATIBLE: {
      severity: :error, category: :type,
      template: "IF expression branches have incompatible types: THEN returns %{then_type}, ELSE returns %{else_type}",
      summary:  "Expression-form IF needs both branches to produce the same type.",
      cause: "The result of an expression-form IF feeds a single binding with a single declared type. Allowing the THEN and ELSE branches to produce different types would force the binding into an ad-hoc union — CLEAR requires the user to declare that union explicitly.",
      fix_hint: "Pick one type and convert the other branch (e.g. `%{then_type}.toString()` if `%{else_type}` is String). For genuine variant data, define a UNION and have both branches construct different variants of it.",
    },
    IF_EXPR_RESULT_NOT_COPYABLE: {
      severity: :error, category: :type,
      template: "IF expression result type '%{type}' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-IF with RETURN for heap-allocated values.",
      summary:  "Expression-form IF only supports implicitly-copyable result types.",
      cause: "Expression-form IF lowers each branch into a load-and-yield sequence; the result must be a value the compiler can implicitly COPY (primitive, symbol, rodata string). Heap-owned values would need an explicit ownership decision per branch — handing them through expression-form IF would silently bypass the affine ownership rules.",
      fix_hint: "Convert to the statement form with explicit ownership: `MUTABLE result; IF cond -> result = produce_owned(); ELSE -> result = other_owned(); END;` — or for fn returns, use `IF cond -> RETURN A; ELSE -> RETURN B; END` directly.",
    },
    MATCH_EXPR_BRANCH_NEEDS_VALUE: {
      severity: :error, category: :type,
      template: "MATCH expression: every branch must end with a value expression",
      summary:  "Expression-form MATCH needs every branch to end with a value.",
      cause: "`x = MATCH subject START ... END` requires every arm to yield a value — the binding `x` reads from whichever arm matched. An arm ending in a statement (assignment, RETURN, side-effect) has nothing to feed the binding.",
      fix_hint: "End each arm with a value expression. For arms that genuinely have nothing to return, switch to the statement form (`MATCH subject START ... END;` with no surrounding assignment), or yield NIL and declare the binding `?T`.",
    },
    MATCH_EXPR_NEEDS_CASE: {
      severity: :error, category: :type,
      template: "MATCH expression must have at least one case",
      summary:  "Expression-form MATCH with no cases would have no value.",
      cause: "An expression-form MATCH with zero cases can never yield a value — there's no arm to dispatch to. The binding would be uninitialised on every path.",
      fix_hint: "Add at least one `WHEN <pattern> -> <value>` arm. If the subject is genuinely unbounded and you want a catch-all, use `PARTIAL MATCH` with a `DEFAULT -> <value>`.",
    },
    MATCH_EXPR_BRANCHES_INCOMPATIBLE: {
      severity: :error, category: :type,
      template: "MATCH expression branches have incompatible types: %{types}",
      summary:  "Expression-form MATCH branches must produce the same type.",
      cause: "The MATCH expression's binding has a single type; every arm must produce a value of that type. Allowing arms to produce different types would force an ad-hoc union — CLEAR requires that union to be declared explicitly.",
      fix_hint: "Pick a common result type and convert each arm's value to it (`Int.toString(x)` to lift to String, etc.), or declare a UNION and have each arm construct the appropriate variant.",
    },
    MATCH_EXPR_RESULT_NOT_COPYABLE: {
      severity: :error, category: :type,
      template: "MATCH expression result type '%{type}' must be implicitly copyable (primitive, symbol, or rodata string). Use statement-MATCH for heap-allocated values.",
      summary:  "Expression-form MATCH only supports implicitly-copyable result types.",
      cause: "Expression-form MATCH lowers each arm into a load-and-yield sequence; the result must be implicitly copyable (primitive, symbol, rodata string). Heap-owned values would need explicit ownership routing per arm — yielding them through expression-form MATCH would bypass affine ownership rules.",
      fix_hint: "Use the statement form with explicit ownership: `MUTABLE result; MATCH subject START WHEN A -> result = produce_a(); WHEN B -> result = produce_b(); END;` — or RETURN directly from each arm if the value is the function's return.",
    },

    # Capability / MOVE / GIVE / COPY / SHARE / LINK / FREEZE / CLONE / RESOLVE
    CAPABILITY_ON_PRIMITIVE: {
      severity: :error, category: :capability,
      template: "Capability @%{cap} cannot be applied to primitive type %{type}. Wrap in a STRUCT (e.g. STRUCT Wrapper { value: %{type} }) and apply the capability to the struct.",
      summary:  "Sigils that wrap a value (`@multiowned`, `@shared`, `@locked`, ...) only apply to heap-managed types.",
      fix_hint: "Wrap in a STRUCT (e.g. STRUCT Wrapper { value: %{type} }) and apply the capability to the struct.",
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
      cause: "Reserved for the field/index variants of GIVE (`GIVE b.field`, `GIVE arr[i]`). Today the broader `visit_MoveNode` rejects every non-Identifier with MOVE_NEEDS_IDENTIFIER, so this code never fires. Once `visit_MoveNode` is relaxed to admit field/index targets, GIVE_BAD_TARGET will fire for the genuinely-invalid cases (literals, expressions).",
      fix_hint: "While the lookup-style GIVE isn't supported, bind the value to a variable first and `GIVE` the variable.",
      pending: true,
    },
    GIVE_TO_BORROW_PARAM: {
      severity: :error, category: :ownership,
      template: "GIVE passed to non-TAKES parameter '%{param}'",
      summary:  "Ownership transfer must be declared on the callee parameter.",
      cause: "A call-site GIVE suppresses the caller's cleanup. If the callee parameter is not TAKES, the callee treats the value as a borrow and has no cleanup obligation, making ownership implicit and unverifiable.",
      fix_hint: "Mark the callee parameter as TAKES, or pass COPY/CLONE/borrowed value instead of GIVE.",
    },
    COPY_NON_COPYABLE: {
      severity: :error, category: :ownership,
      template: "Cannot COPY non-copyable type '%{type}'",
      summary:  "Some types (e.g., closed streams, raw fds) deliberately have no COPY semantics.",
      cause: "Reserved for resource types — `File`, `TCPClient`, `TCPServer`, raw fds, closed streams — that intentionally cannot be deep-copied. Today `visit_CopyNode` happily generates Zig code for any type, which produces broken behaviour for resources. Wiring this code requires extending `Type#copyable?` (or an equivalent registry on resource schemas) so the visitor can reject the truly non-copyable cases.",
      fix_hint: "Use `CLONE` for shared / refcounted handles. For linear resources, transfer ownership via `GIVE` or pass through a borrow.",
      pending: true,
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
      template: "ON / RETRY clause requires a WITH capability that can fail (EXCLUSIVE on @locked/@writeLocked, or read on @writeLocked). The declared capabilities never produce a lock-acquire error.",
      summary:  "ON / RETRY only attaches to WITH captures whose acquire can fail (locks with timeouts, snapshots, etc).",
      fix_hint: "(EXCLUSIVE on @locked/@writeLocked, or read on @writeLocked). The declared capabilities never produce a lock-acquire error.",
    },
    SELECTORS_NO_MATCH: {
      severity: :error, category: :capability,
      template: "Selectors [%{matched}] do not match %{possible}",
      summary:  "ON-clause error selectors don't match any of the WITH captures' fallible kinds.",
    },

    # BG / DO block
    DO_CAPTURES_WITH_SCOPED: {
      severity: :error, category: :escape,
      template: "DO block captures a WITH-scoped (BORROWED/RESTRICT) binding. WITH bindings are stack aliases that become invalid when the WITH block exits. Move the DO block outside the WITH block, or use COPY to get an owned value.",
      summary:  "DO branches can't capture WITH-scoped bindings — they must end with the WITH.",
      fix_hint: "WITH bindings are stack aliases that become invalid when the WITH block exits. Move the DO block outside the WITH block, or use COPY to get an owned value.",
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
      template: "BG STREAM block captures a WITH-scoped (BORROWED/RESTRICT) binding. WITH bindings are stack aliases that become invalid when the WITH block exits. Move the BG STREAM block outside the WITH block, or use COPY to get an owned value.",
      summary:  "BG STREAM fibers outlive the WITH — they can't capture WITH-scoped bindings.",
      fix_hint: "WITH bindings are stack aliases that become invalid when the WITH block exits. Move the BG STREAM block outside the WITH block, or use COPY to get an owned value.",
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
      template: "BG block captures a WITH-scoped (BORROWED/RESTRICT) binding. Either capture a longer-lived value (the original binding the WITH aliases, or a COPY), restructure so the BG runs inside the WITH and finishes before it exits, or use SHARE to extend the lifetime via Arc.",
      summary:  "BG fibers outlive the WITH — they can't capture WITH-scoped bindings.",
      cause: "A BG block captured a binding whose lifetime is bounded by an enclosing WITH alias. The fiber may outlive the WITH body — the capture would dangle.",
      fix_hint: "Either capture a longer-lived value (the original binding the WITH aliases, or a COPY), restructure so the BG runs inside the WITH and finishes before it exits, or use SHARE to extend the lifetime via Arc.",
    },
    BG_PINNED_CAPTURE_MISMATCH: {
      severity: :error, category: :capability,
      template: "BG block inside @pinned scope captures local variables but is not @pinned. Thread-local memory cannot escape to a stealable fiber. Add @pinned to this BG block, or avoid capturing variables from the pinned scope.",
      summary:  "BG blocks inside `@pinned` scopes that capture locals must themselves be `@pinned`.",
      fix_hint: "Thread-local memory cannot escape to a stealable fiber. Add @pinned to this BG block, or avoid capturing variables from the pinned scope.",
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
      template: "EFFECTS REENTRANT:TAIL_CALL on '%{fn}' requires at least one RETURN that directly calls '%{fn}' in tail position (e.g., RETURN %{fn}(...)). The recursive call cannot be wrapped in an expression.",
      summary:  "TAIL_CALL requires the function to actually contain a tail-recursive call.",
      fix_hint: "RETURN that directly calls '%{fn}' in tail position (e.g., RETURN %{fn}(...)). The recursive call cannot be wrapped in an expression.",
    },
    TAIL_CALL_NOT_TAIL_POSITION: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:TAIL_CALL: '%{fn}' is called in non-tail position. All recursive self-calls must be the ENTIRE return expression (e.g., RETURN %{fn}(...)). Non-tail recursion would consume the fiber stack on every invocation. If recursion is genuinely non-tail, declare ':THUNK' instead -- it handles arbitrary recursion via a heap state-struct.",
      summary:  "TAIL_CALL declared but the recursive call site isn't in tail position.",
      fix_hint: "All recursive self-calls must be the ENTIRE return expression (e.g., RETURN %{fn}(...)). Non-tail recursion would consume the fiber stack on every invocation. If recursion is genuinely non-tail, declare ':THUNK' instead -- it handles arbitrary recursion via a heap state-struct.",
    },

    # Stack safety
    STACK_SAFETY_MUTUAL_RECURSION: {
      severity: :error, category: :reentrance,
      template: "Stack safety: this fiber transitively calls '%{callee}' which is `:MAX_DEPTH(N)` AND mutually recursive. Mutual depth-bounds compose as a product across counters and can't be statically bounded; the spawn site must be `@service` (OS thread). Either declare `@service` explicitly or break the cycle (see `:THUNK` for unbounded-depth fibers).",
      summary:  "Stack-tier analysis found mutual recursion that can't be bounded.",
      fix_hint: "which is `:MAX_DEPTH(N)` AND mutually recursive. Mutual depth-bounds compose as a product across counters and can't be statically bounded; the spawn site must be `@service` (OS thread). Either declare `@service` explicitly or break the cycle (see `:THUNK` for unbounded-depth fibers).",
    },
    STACK_SAFETY_USER_SIZE_TOO_SMALL: {
      severity: :error, category: :reentrance,
      template: "Stack safety: @%{size} (%{budget} bytes) is too small for this fiber. Call-graph analysis requires at least @%{computed}. Use @%{computed} (or @service for OS-thread). (`@canSmash` is reserved for v0.3 -- runtime stack-hysteresis is implemented but not yet wired through the compiler.)",
      summary:  "User-declared stack tier is too small for the fiber's worst-case path.",
      fix_hint: "is too small for this fiber. Call-graph analysis requires at least @%{computed}. Use @%{computed} (or @service for OS-thread). (`@canSmash` is reserved for v0.3 -- runtime stack-hysteresis is implemented but not yet wired through the compiler.)",
    },
    STACK_SAFETY_STACK_ALIAS: {
      severity: :warning, category: :reentrance,
      template: "Stack sizing: @stack resolved to @%{computed}; replace @stack with @%{computed}. In STRICT mode, @stack will be rejected.",
      summary:  "`@stack` was accepted as a compatibility alias and resolved to a concrete stack tier.",
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
      fix_hint: "Usually a lowering bug — the cleanup classifier should have inserted the cleanup. Check src/mir/cleanup_classifier.rb. If your code has an unusual control-flow shape (early RETURN inside a complex block), that path may need explicit attention.",
    },
    CLEANUP_REQUIRED_WITHOUT_FINALIZER: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Cleanup-bearing AllocMark has no checker-visible finalizer or transfer.",
      cause: "The MIR carries an AllocMark whose concrete Type says the binding owns cleanup-bearing data, but no Cleanup, ErrCleanup, DestroyPtr errdefer, or TransferMark closes the ownership path. Frame arena rewind is not sufficient for values that own internal resources or collection storage requiring deinit.",
      fix_hint: "Lowering bug — make cleanup classification emit a Cleanup/ErrCleanup for the binding, or emit a TransferMark when ownership leaves the current scope. Do not rely on frame allocation alone as the cleanup story for cleanup-bearing types.",
    },
    CLEANUP_WITHOUT_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR::Cleanup or ErrCleanup with no matching AllocMark — orphan cleanup.",
      cause: "The MIR has a Cleanup node naming a binding the AllocMark side never declared. Means the lowering emitted cleanup for a value the allocator never tracked — runtime would try to free unknown memory.",
      fix_hint: "Lowering bug — the cleanup classifier disagreed with the alloc classifier. Trace the binding name through cleanup_classifier.rb.",
    },
    INDIRECT_DOUBLE_BOX: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR::HeapCreate boxes a value whose Zig type is already a pointer (double indirection).",
      cause: "A heap box is exactly one level of indirection: `HeapCreate(T)` produces `*T`. If T is itself `*U` the result is `**U` — a double box. Reading it yields a dangling `*U` after the inner allocation is cleaned up (UAF), and the field/binding type no longer matches. This is the failure mode the @indirect single-source layout guards against.",
      fix_hint: "Lowering bug — the HeapCreate cell type must be the BARE pointee (`transpile_type(base)`), never the already-pointerized field/binding type. Check the @indirect hoist sites in src/mir/mir_lowering.rb (lower_struct_lit / lower_union_variant_lit) use `field_type.resolved`, not `zig_type`.",
    },
    ALLOC_CLEANUP_MISMATCH: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Cleanup's allocator (heap/frame) doesn't match its AllocMark's allocator.",
      cause: "AllocMark allocated on heap but Cleanup is freeing on frame, or vice versa. Calling `frame.free()` on heap memory (or `heap.free()` on frame memory) is an allocator mismatch — runtime crash or corruption.",
      fix_hint: "Lowering bug — the per-binding allocator decision drifted between alloc and cleanup. Check that cleanup_classifier.rb gives both nodes the same allocator stamp.",
    },
    INLINE_ALLOC_MISMATCH: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Structural MIR op uses an allocator that doesn't match the container's AllocMark.",
      cause: "Storing frame-allocated data into a heap container (or heap data into a frame container) leaves dangling pointers after frame rewind. The checker compares the op's `:alloc` / `:key_alloc` / `:val_alloc` metadata against the container's AllocMark allocator and rejects mismatches.",
      fix_hint: "Make the container's allocator and the inserted data's allocator agree. Usually the fix is upgrading the container to heap (`@list:heap` or assignment-time promotion) or making the inserted data heap-owned.",
    },
    CROSS_FRAME_PARAM_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Allocator-bearing op on a pointer-passed parameter must not use the frame allocator.",
      cause: "A pointer-passed parameter (MUTABLE collection / `*T` Zig type) carries a lifetime that extends past this function's mark/restore. A `:frame` allocation here would die when the function returns, leaving the caller with a dangling buffer pointer — a cross-frame use-after-free.",
      fix_hint: "Lowering bug — `resolve_alloc_sym` for `:receiver_storage` should pick `:heap` when the receiver is a pointer-passed param. The matching escape promotion lives in escape_analysis.rb (Condition 9). If both look right, check that the MIR function context marks this as a collection parameter.",
    },
    INLINE_NO_CONTRACT: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "A raw Zig MIR carrier has no verifier-visible callable contract.",
      cause: "Opaque Zig text is not a valid MIR surface. MIRChecker cannot prove that raw text does not allocate, free, borrow, or transfer.",
      fix_hint: "Replace the raw Zig carrier with structural MIR, or lower it from a registry entry that carries a FunctionSignature and ownership metadata.",
    },
    OPAQUE_ZIG_OWNERSHIP: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Raw Zig hides allocator ownership operations.",
      cause: "Opaque Zig text contains allocator operations such as alloc, dupe, create, destroy, free, or deinit. A callable signature can describe boundary effects, but it cannot prove that arbitrary internal heap ownership is balanced.",
      fix_hint: "Decompose the operation into structural MIR with AllocMark, Cleanup, ErrCleanup, DestroyPtr, and TransferMark nodes, or move the operation behind a runtime API whose implementation is outside compiler MIR.",
    },
    OWNERSHIP_FACT_REQUIRED: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Ownership-capable MIR must be finalized into explicit ownership facts.",
      cause: "The MIR node can allocate, free, consume, store, capture, or return owned data, but that effect is still encoded through node-specific side channels. MIRChecker can only be a memory-safety gate when it reads a closed ownership fact stream.",
      fix_hint: "Lowering bug — run ownership finalization before MIRChecker and emit MIR::OwnedCreate / OwnedDestroy / OwnedTransfer / OwnedStore / OwnedReturn facts for this operation. Do not hide ownership in raw Zig text or ad-hoc node fields.",
    },
    BOUNDARY_FACT_REQUIRED: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Execution-boundary MIR must carry typed boundary/capture facts.",
      cause: "A BG, BG STREAM, DO branch, or similar execution boundary reached MIRChecker without the closed fact object that names its dispatch mode and captured capabilities. Without that fact, the checker cannot prove scheduler/capture safety.",
      fix_hint: "Lowering bug — copy the annotated capture analysis into MIR::ExecutionBoundaryFact before MIRChecker. Do not rely on parser flags or pre-MIR booleans as the final authority.",
    },
    BOUNDARY_CAPTURE_NOT_PARALLEL_SAFE: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "A non-parallel-safe capture crosses a parallel execution boundary.",
      cause: "The boundary dispatches work across schedulers, but one captured binding is scheduler-affine or non-atomic. That can break capability guarantees even if the emitted code happens to compile.",
      fix_hint: "Use a parallel-safe capability such as @shared where appropriate, pin the boundary instead of using @parallel, or avoid capturing the binding.",
    },
    MIR_CALL_NO_CONTRACT: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR call has no verifier-visible callable contract.",
      cause: "`MIR::Call`, `MIR::TailCall`, and `MIR::MethodCall` only carry emitted callee text and arguments. Without a typed callable contract, MIRChecker cannot prove whether arguments are borrowed, consumed, or returned.",
      fix_hint: "Lowering bug — attach a typed callable/effect contract to the MIR call or lower the operation into structural MIR nodes with explicit ownership events.",
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
    ALLOCATING_LET_WITHOUT_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Heap-allocating Let initializer has no checker-visible AllocMark.",
      cause: "A top-level MIR::Let may be the legal place for an allocating expression, but the binding still needs an AllocMark so MIRChecker can prove it is cleaned or explicitly transferred.",
      fix_hint: "Lowering bug — emit AllocMark for the binding from its finalized storage, then emit Cleanup/ErrCleanup or TransferMark at the ownership boundary.",
    },
    OWNED_RETURN_WITHOUT_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Owned-return call is bound without a checker-visible AllocMark.",
      cause: "A call whose return value owns heap data was lowered directly into a binding, but the binding has no MIR::AllocMark. Without the marker, MIRChecker cannot verify that cleanup exists on every path.",
      fix_hint: "Lowering bug — preserve return provenance through FunctionSignature import/reconstruction and make the cleanup classifier emit AllocMark + Cleanup for the binding.",
    },
    OWNED_RETURN_ALLOC_NOT_HEAP: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Owned-return call has a non-heap AllocMark.",
      cause: "A call whose return value owns heap data was paired with an AllocMark that says the value is frame-allocated. That lets AllocMark and Cleanup agree with each other while still freeing heap-owned data through the wrong allocator.",
      fix_hint: "Lowering bug — the AllocMark for a heap-provenance return must use :heap or :cleanup, never :frame.",
    },
    OWNED_RESULT_WITHOUT_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Owned-result expression is bound without a checker-visible AllocMark.",
      cause: "A MIR expression declared that it produces owned storage, but the receiving binding has no AllocMark. Without the marker, MIRChecker cannot verify cleanup or transfer.",
      fix_hint: "Lowering bug — propagate the expression's owned_result_alloc fact into the binding's allocation and cleanup plan.",
    },
    OWNED_RESULT_ALLOC_MISMATCH: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Owned-result expression allocator disagrees with its binding AllocMark.",
      cause: "The producer declared that its result is owned by one allocator, while the receiving binding was stamped with another. AllocMark and Cleanup may match each other while still freeing through the wrong allocator.",
      fix_hint: "Lowering bug — the receiving binding must use the producer's owned_result_alloc as the authoritative allocator.",
    },
    RETURN_TRANSFER_WITHOUT_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Return ownership transfer exists without a matching AllocMark.",
      cause: "A MIR::TransferMark(:return) says the caller owns a binding after return, but the callee has no checker-visible allocation event for that binding.",
      fix_hint: "Lowering bug — return transfers must be attached to a named binding with an AllocMark.",
    },
    RETURN_TRANSFER_FRAME_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Return ownership transfer is backed by frame allocation.",
      cause: "A value whose ownership leaves the function cannot be allocated in the callee's frame arena. The frame rewinds before the caller's cleanup runs, producing a dangling buffer or allocator mismatch.",
      fix_hint: "Escape analysis/lowering bug — escaping owned returns must set the binding storage to heap before MIR lowering emits AllocMark.",
    },
    FRAME_ALLOC_ESCAPES: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Frame-allocated ownership transfers to an escaping owner.",
      cause: "A frame allocation is only valid within the current frame lifetime. Transferring it to a return value, container, captured boundary, or external parameter lets another owner observe memory after the frame rewinds.",
      fix_hint: "Escape analysis bug — the binding reached an escape sink but was not stamped heap before MIR lowering emitted AllocMark.",
    },
    TRANSFER_WITHOUT_ALLOC: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "TransferMark exists without a matching AllocMark.",
      cause: "MIR::TransferMark suppresses local cleanup because ownership left the current scope. Without a matching AllocMark, there is no checker-visible allocation event to prove what was transferred.",
      fix_hint: "Lowering bug — emit TransferMark only alongside the AllocMark for the owned binding being moved.",
    },
    OWNERSHIP_USE_AFTER_TRANSFER: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR reads an owned binding after ownership left the scope.",
      cause: "Once MIR emits a TransferMark or equivalent release for an owned binding, later reads of that binding are use-after-free unless the binding has been reallocated.",
      fix_hint: "Lowering bug — emit the transfer at the actual ownership boundary after the final read, or materialize a separate owned copy before transferring.",
    },
    OWNERSHIP_DOUBLE_RELEASE: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR releases or transfers the same owned binding more than once.",
      cause: "A binding may have exactly one success-path owner at a time. Multiple TransferMark/release events for the same allocation are a double-free risk.",
      fix_hint: "Lowering bug — collapse the ownership transfer to one event, or split distinct allocations into distinct bindings.",
    },
    OWNERSHIP_DOUBLE_FINALIZER: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR registers more than one cleanup finalizer for the same owned binding.",
      cause: "Multiple Cleanup/ErrCleanup registrations for one allocation mean the same owned value can be freed more than once.",
      fix_hint: "Lowering bug — each AllocMark must own one cleanup strategy: normal cleanup, errcleanup plus transfer, destroy, or transfer.",
    },
    OWNERSHIP_UNVERIFIED_PATH: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR control flow rejoins with different ownership state.",
      cause: "MIRChecker cannot prove memory safety when one branch owns/transfers/finalizes a binding differently from another branch.",
      fix_hint: "Lowering bug — make ownership events explicit and identical at the join, or keep ownership entirely outside the branch.",
    },
    LINEAR_STMT_NOT_REGISTERED: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR statement is missing from linear ownership verification.",
      cause: "A statement node reached MIRChecker without being registered in the closed linear ownership traversal. Treating it as a generic expression would let new ownership-affecting statement types bypass leak/UAF/double-free checks.",
      fix_hint: "Register the statement in MIRChecker::LINEAR_STATEMENT_NODE_TYPES and add the structural traversal it needs. If it can affect ownership, expose that through explicit MIR ownership facts.",
    },
    OWNERSHIP_IMPLICIT_MOVE: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR suppresses cleanup without an explicit ownership transfer.",
      cause: "MoveMark changes runtime cleanup behavior. Without a matching TransferMark, the checker cannot prove who owns the value after cleanup is suppressed.",
      fix_hint: "Lowering bug — emit a TransferMark for the same binding at the same ownership boundary, or remove the MoveMark.",
    },
    OWNERSHIP_CLEANUP_FOR_BORROW: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR cleanup was emitted for a borrowed/non-owning binding.",
      cause: "A binding initialized from a borrowed view, such as an indexed element or field payload, received Cleanup/ErrCleanup even though it did not create or receive ownership. Cleaning that alias can free memory still owned by the source aggregate.",
      fix_hint: "Lowering bug — either deep-copy into a fresh owned binding, transfer ownership explicitly, or keep the borrowed alias cleanup-free.",
    },
    OWNERSHIP_STRUCTURAL_RC_COPY: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Reference-counted handles cannot be structurally copied.",
      cause: "Rc/Arc/Weak handles own a control-block count. Copying their pointer fields without a retain fabricates an uncounted owner and causes premature release, leaks, or use-after-free.",
      fix_hint: "Lowering bug — emit RcRetain/WeakUpgrade/RcDowngrade for direct handles. Aggregate copies must route RC fields through the runtime retain-aware dupeValue path.",
    },
    SHARDED_ELEMENT_REQUIRES_SHARED: {
      severity: :error, category: :ownership,
      template: "@sharded collections cannot store %{got}; cross-scheduler reference-counted elements must use @shared",
      summary:  "A scheduler-sharded collection cannot own non-atomic reference counts.",
      cause: "@multiowned uses scheduler-local non-atomic Rc state and allocator provenance. A shard may destroy or copy an element on a different scheduler, where releasing that Rc is unsafe.",
      fix_hint: "Declare the element/value as @shared, or use an unsharded collection that remains on one scheduler.",
    },
    MOVEMARK_WITHOUT_GUARD: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MoveMark exists outside the lexical scope that declares its moved guard.",
      cause: "MIR::MoveMark emits `name_moved = true`, but that variable is only declared by a visible guarded Cleanup/ErrCleanup. If lowering moves the marker out of the binding's scope, Zig sees an undeclared guard and ownership cannot be verified.",
      fix_hint: "Lowering bug — emit MoveMark only at the consuming expression in the same lexical body as the guarded cleanup, or remove it when success is represented by ErrCleanup + TransferMark.",
    },
    ERRCLEANUP_WITHOUT_TRANSFER: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "ErrCleanup exists without an explicit success-path ownership transfer.",
      cause: "MIR::ErrCleanup means the binding is cleaned only on error because success transfers ownership. Without a matching MIR::TransferMark, the success-path owner is implicit and MIRChecker cannot prove leak/double-free safety.",
      fix_hint: "Lowering bug — emit MIR::TransferMark at the same ownership boundary that converts Cleanup to ErrCleanup, or keep a normal Cleanup if ownership does not transfer.",
    },
    AGGREGATE_CHILD_ALLOC_MISMATCH: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Owned aggregate child allocator disagrees with the aggregate owner.",
      cause: "An owned temporary was inserted into an aggregate whose owner uses a different allocator. The aggregate cleanup cannot be authoritative if nested children were independently placed.",
      fix_hint: "Lowering bug — flow the aggregate destination allocator recursively into child materialization, or make the aggregate owner heap when its children must be heap.",
    },
    PROVENANCE_PLACEMENT_FORBIDDEN: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR still carries provenance-based heap/frame placement.",
      cause: "Heap/frame placement must be closed before MIR lowering and represented by binding AllocMark/Cleanup facts. A MIR node carrying side-channel placement means downstream code is still deciding ownership after placement.",
      fix_hint: "Delete the provenance path. Hoist the value to a binding if needed, stamp the binding's SymbolEntry#storage during escape analysis, then emit AllocMark/Cleanup from that binding placement.",
    },
    INLINE_ALLOC_WITHOUT_TARGET: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Allocator-bearing MIR op has no target binding for MIRChecker to verify.",
      cause: "Allocator-bearing MIR operations must be attached to the binding/container they mutate or produce. Without a target binding, MIRChecker cannot compare the operation allocator against authoritative placement.",
      fix_hint: "Hoist the operation into a named binding or attach target_var to the receiver/result binding. Do not infer the allocator locally in lowering.",
    },
    INLINE_ALLOC_WITHOUT_ALLOCMARK: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Allocator-bearing MIR op targets a binding that has no AllocMark.",
      cause: "Allocator-bearing MIR operation named a target, but the target has no checker-visible allocation marker. That means the operation allocator cannot be compared against authoritative binding placement.",
      fix_hint: "Lowering bug — the target binding must have an AllocMark emitted from CleanupClassifier placement before allocator-bearing operations can mutate it.",
    },
    INVALID_ALLOCATOR_MARK: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR uses an allocator symbol outside the closed heap/frame set.",
      cause: "Placement must be finalized before MIR lowering. AllocMark, Cleanup, and structural allocator metadata may only carry :heap or :frame. Any other symbol is a downstream side channel.",
      fix_hint: "Move the decision to escape analysis or cleanup classification, then emit only :heap or :frame into MIR.",
    },
    ALLOC_MARK_TYPE_MISSING: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "MIR::AllocMark has no concrete Type payload.",
      cause: "The lowering emitted an allocation ownership fact without the type needed to prove whether the value owns heap memory and what cleanup shape is legal. Nil or :Untyped type info makes cleanup verification coincidental.",
      fix_hint: "Lowering bug — derive the AllocMark type from the allocation producer or already-typed AST source before MIRChecker runs.",
    },
    COPY_CLEANUP: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "Cleanup attached to a primitive / Id<T> value — value types don't own heap memory.",
      cause: "A Cleanup paired with an AllocMark whose `type_info` is a primitive (Int*, Float*, Bool, Byte) or `Id<T>` (with no sync/rc capability) can't be right — these are pure value types that never own heap memory, so a cleanup is structurally meaningless.",
      fix_hint: "Lowering bug. Check that the cleanup classifier doesn't promote primitives to needing cleanup. The fix usually drops the cleanup node and the alloc-site decision rather than 'fixing' the cleanup.",
    },
    IMPLICIT_OWNERSHIP_TRANSFER: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "A consuming MIR operation has no explicit ownership contract.",
      cause: "The stdlib registry declares a TAKES/consuming parameter, but the lowered structural MIR node did not carry a typed ownership operand fact for the concrete binding being consumed. MIRChecker cannot prove whether that binding is cleaned, transferred, double-freed, or leaked.",
      fix_hint: "Lowering bug — carry typed MIR::OwnershipOperandFact entries from the annotated TAKES/GIVE site into the ownership contract, and emit matching MIR::TransferMark nodes. If the call deep-copies instead of consumes, do not mark the source moved.",
    },
    OWNERSHIP_CONTRACT_WITHOUT_TRANSFER: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "An ownership contract consumes a binding with no TransferMark.",
      cause: "The ownership contract's typed owned operand facts say a binding leaves the current scope, but MIR has no TransferMark for that binding. The checker cannot distinguish an intended transfer from a missing cleanup.",
      fix_hint: "Lowering bug — emit MIR::TransferMark at the consuming boundary, or keep the binding's normal Cleanup if ownership does not actually transfer.",
    },
    OWNERSHIP_TRANSFER_COPIED: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "A consuming ownership contract was lowered as a deep copy.",
      cause: "Copying and consuming are different ownership events. A deep copy leaves the source owned by the current scope; a consuming TAKES transfer removes local ownership. Treating both as the same event causes leaks or double-frees.",
      fix_hint: "Lowering bug — either pass the original binding and transfer it, or deep-copy into a separate owned temporary and consume that temporary while keeping the source cleanup.",
    },
    OWNERSHIP_CONSUMPTION_FACT_MISSING: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "A consuming MIR operation has no typed ownership operand fact.",
      cause: "MIRChecker cannot prove ownership safety from node shape, Zig text, or inferred names. Every consuming edge must carry explicit operand provenance from lowering.",
      fix_hint: "Lowering bug — emit a MIR::OwnershipConsumptionFact with typed MIR::OwnershipOperandFact entries at the consuming edge.",
    },
    OWNERSHIP_CONSUMPTION_OPERAND_MISSING: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "A consuming MIR operation has an empty ownership operand fact.",
      cause: "The lowered node claims to consume ownership but does not identify a concrete operand whose ownership can be tracked linearly.",
      fix_hint: "Lowering bug — attach the concrete owned operand, or mark the call as covering consuming params with no ownership only when every TAKES argument is non-owning/copyable.",
    },
    OWNERSHIP_CONSUMPTION_BORROWED_OPERAND: {
      severity: :error, category: :mir,
      template: "%{message}",
      summary:  "A borrowed operand was passed to an owning MIR sink.",
      cause: "Field/index access borrows from an owner. A borrowed access cannot be consumed because local cleanup still belongs to the container/root owner.",
      fix_hint: "Lowering bug or source error — consume an owned binding, use GIVE/remove to transfer ownership, or COPY to create an owned temporary.",
    },
    # Tranche 6: remaining ad-hoc strings — added in one big sweep
    TIGHT_CALLS_EXTERN_FN: {
      severity: :error, category: :reentrance,
      template: "TIGHT loop cannot call EXTERN FN '%{name}' (opaque to scheduler)",
      summary:  "EXTERN FN calls in a TIGHT loop are opaque to the scheduler — disallowed.",
    },
    TIGHT_CALLS_REENTRANT_FN: {
      severity: :error, category: :reentrance,
      template: "TIGHT loop cannot call plain EFFECTS REENTRANT function '%{name}'",
      summary:  "TIGHT loops disallow calls to plain EFFECTS REENTRANT functions (unbounded depth).",
    },
    REENTRANCY_MUTUAL_CYCLE: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' is part of a mutually recursive call cycle. Add EFFECTS REENTRANT or a bounded REENTRANT variant to the function signature.",
      summary:  "Function is in a mutual-recursion cycle but lacks an explicit reentrance declaration.",
    },
    PLAIN_REENTRANT_VARIANT_SUGGESTION: {
      severity: :info, category: :reentrance,
      template: "'%{fn}' is plain `EFFECTS REENTRANT` (forces callers onto `@service` / OS thread). %{reason} -- migrating to `%{suggestion}` lets callers stay on the regular fiber stack. (Phase 5 audit; opt-in via `clear fix`.)",
      summary: "A plain reentrant function appears to fit a bounded reentrance variant.",
      fix_hint: "Accept the suggested bounded variant when the body shape and recursion semantics match.",
    },
    REENTRANT_MAX_DEPTH_MUTUAL_DEMOTED: {
      severity: :warning, category: :reentrance,
      template: "EFFECTS REENTRANT:MAX_DEPTH(%{max_depth}) on '%{fn}' is silently demoted to ':unbounded' stack tier (4 MB :service OS thread per fiber) because the function is part of a mutual cycle (%{cycle}) and the compiler can't bound the SCC's interleaved-counter product (Phase 5+ work). The MAX_DEPTH(N) bound on this fn alone does NOT cap the cycle's stack depth -- a bounce between members can still grow the fiber stack arbitrarily. To fix: refactor the cycle into ONE directly-self-recursive fn (inline the partner's body or pass a state tag in a single combined fn) so the MAX_DEPTH counter actually bounds it; or accept ':unbounded' explicitly via the auto-fix below.",
      summary: "MAX_DEPTH on one member of a mutual-recursion cycle does not bound the whole cycle.",
      fix_hint: "Refactor the cycle into one directly self-recursive function, or accept plain `EFFECTS REENTRANT` explicitly.",
    },
    UNCONSTRAINED_FN_PARAM_REENTRANCE: {
      severity: :warning, category: :lint,
      template: "Function '%{fn}' has %{subject} (%{candidates}). Add 'REQUIRES <name>: NON_REENTRANT' (rejects reentrant callbacks) or 'EFFECTS REENTRANT' on '%{fn}' (propagates the cost).",
      summary: "A function accepts callback parameters without constraining their reentrance cost.",
      fix_hint: "Add a NON_REENTRANT requirement for callback parameters that must stay bounded, or declare the owner function reentrant.",
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
      cause: "The construction site or MATCH subject treats `%{name}` as a UNION (`%{name}.Variant(...)` / `MATCH x START %{name}.A -> ...`). The compiler resolves `%{name}` to a struct, enum, or other non-union type — operations that demand a UNION can't apply.",
      fix_hint: "Either change the syntax to match `%{name}`'s actual kind (struct literal `%{name}{ field: value }`, enum value `%{name}.Variant`), or import / declare a UNION named `%{name}` if that was the intent.",
    },
    UNION_VARIANT_IS_UNIT_NO_FIELDS: {
      severity: :error, category: :type,
      template: "Union variant '%{variant}' is a unit variant — use '%{union}.%{variant}' (no fields).",
      summary:  "Unit variant cannot accept inline-struct fields.",
      cause: "Unit variants carry no payload at all. Brace-syntax construction (`%{union}.%{variant}{ field: ... }`) implies inline-struct fields the variant doesn't declare; allowing it would silently drop the supplied fields.",
      fix_hint: "Drop the braces: `%{union}.%{variant}` is the construction form for unit variants. If the variant needs to carry data, declare it with an inline-struct or payload type at the UNION definition.",
    },
    UNION_VARIANT_NEEDS_PAYLOAD_OBJECT: {
      severity: :error, category: :type,
      template: "Union variant '%{variant}' takes a single typed payload — use '%{union}{ %{variant}: value }' instead.",
      summary:  "Single-payload variant cannot use the inline-struct '{ field: ... }' form.",
      cause: "Variants come in three shapes: unit (no data), single-payload (`Variant: T`), and inline-struct (`Variant: { f: T, ... }`). A single-payload variant takes exactly one positional payload; the brace-with-fields form is reserved for inline-struct variants and would set fields the variant doesn't declare.",
      fix_hint: "Use the colon form: `%{union}{ %{variant}: value }` (or shorthand `%{union}.%{variant}(value)` if the variant supports it). For per-field construction, redeclare the variant as an inline-struct at the UNION definition.",
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
      cause: "CLEAR functions take *types*, not capabilities. Capabilities are properties of bindings (the caller's local), unwrapped at the call site via WITH. Allowing `@multiowned` etc. on a parameter would conflate the type with the caller's wrapping — and would force every call site to wrap the value, even when the caller has a plain T.",
      fix_hint: "Drop the sigil from the parameter type (e.g. `c: Counter` not `c: Counter @multiowned`). The caller wraps as needed (`WITH c { fn(c); }` for a multiowned binding). To require a sync family on the param, use `REQUIRES c: LOCKED` (or ATOMIC, VERSIONED) — that's the supported way to constrain capabilities.",
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
      cause: "Observable collections need the underlying shape to support efficient diff publication. The only currently-supported collection observable is the DISTINCT terminal, which requires `@set` shape (set membership = O(1) diff). Plain `T[]` observables aren't lowered yet — diff over duplicates would be ambiguous.",
      fix_hint: "Add `@set` so the type is `~T[]@set:observable`. If you don't need set semantics (uniqueness), drop `@observable` and use a plain tense list (`~T[]`) — observers would need to compute their own diffs.",
    },
    OBSERVABLE_NOT_COMBINABLE: {
      severity: :error, category: :type,
      template: "@observable cannot be combined with %{labels}. %{explain} Drop the wrapper or pick a non-observable type.",
      summary:  "@observable rejects certain combined capabilities.",
      cause: "@observable layers a publish/subscribe channel on top of a tense source — every write fans out to subscribers. Some other capabilities are incompatible because they impose a representation that the publish layer can't observe atomically (e.g., `@indirect:atomic` already CAS-publishes a different snapshot, `@locked` blocks subscribers).",
      fix_hint: "Drop one of the conflicting wrappers (typically @observable if the consumer doesn't need diff feeds), OR pick a different sync model: `@versioned` cells get observable-like snapshots via WITH SNAPSHOT without the publish layer.",
    },
    OBSERVABLE_TERMINAL_MISMATCH: {
      severity: :error, category: :type,
      template: "Observable terminal mismatch: LHS stamped %{lhs}, pipe analyzer produced %{pipe}",
      summary:  "Observable destination terminal disagrees with the pipeline terminal analyzer.",
      cause: "The observable destination already carried a terminal stamp that disagreed with the pipeline analyzer. Choosing either side would hide a stale phase fact, so annotation rejects the program.",
      fix_hint: "Treat this as a compiler invariant failure unless the source explicitly declared conflicting observable shapes. The pipeline analyzer should be the authority for terminal kind.",
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
      template: "Type Error: polymorphic @shared parameters in '%{fn}' must use the same synchronization capability. Parameter '%{first}' is %{first_cap}, but parameter '%{second}' is %{second_cap}. Pick one sync family across all `@shared` params (`%{first_cap}` or `%{second_cap}`), or restrict the function to a single concrete family by adding `REQUIRES p1: <family>, p2: <family>` with the same family for both. If the params genuinely belong to different families, split the function into separate specialised versions.",
      summary:  "Polymorphic @shared parameters disagree on synchronization capability.",
      cause: "When a function takes multiple `@shared` parameters and dispatches polymorphically (via REQUIRES with multiple sync families), every shared param must agree on its sync family. Allowing them to diverge would force per-pair monomorphisation across families — the cross-product blows up combinatorially.",
      fix_hint: "Pick one sync family across all `@shared` params (`%{first_cap}` or `%{second_cap}`), or restrict the function to a single concrete family by adding `REQUIRES p1: <family>, p2: <family>` with the same family for both. If the params genuinely belong to different families, split the function into separate specialised versions.",
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
    TAKES_NEEDS_OWNED_BORROW: {
      severity: :error, category: :ownership,
      template: "Cannot pass borrowed access to TAKES parameter. Use COPY for an explicit deep-copy or move an owned binding.",
      summary:  "TAKES parameter needs ownership; borrowed access paths are borrows.",
    },
    LINK_NEEDS_RESOLVE_FOR_CALL: {
      severity: :error, category: :ownership,
      template: "Cannot pass @link variable '%{name}' to parameter '%{param}' — RESOLVE it first to get an optional strong reference.",
      summary:  "Cannot pass a weak @link reference where a concrete value is expected.",
    },
    REENTRANT_FN_TO_NON_REENTRANT_PARAM: {
      severity: :error, category: :reentrance,
      template: "Reentrancy Error: '%{name}' is plain EFFECTS REENTRANT but parameter '%{param}' does not accept plain reentrant callbacks. Add EFFECTS REENTRANT to the callee that owns '%{param}', or constrain the parameter explicitly with REQUIRES %{param}: NON_REENTRANT and pass a bounded/non-reentrant callback.",
      summary:  "Plain EFFECTS REENTRANT function passed to a parameter that doesn't permit plain reentrant callees.",
    },
    ARG_NEEDS_ATOMIC_CELL: {
      severity: :error, category: :type,
      template: "Type Error: Argument %{index} to '%{fn}' expects an @atomic %{expected} cell, but '%{name}' is %{actual}. Pass an @atomic binding, or change the parameter to bare %{expected} to load a value.",
      summary:  "Argument must be an @atomic cell binding (not a loaded value).",
      cause: "The parameter is typed as `@atomic %{expected}` — a *cell* the function will perform atomic ops on (load, fetchAdd, ...). Passing a loaded value (a plain `%{expected}`) would force the function to operate on a stack copy, defeating the atomic semantics.",
      fix_hint: "Pass the `@atomic` binding by name (e.g. `fn(c)` where `c: %{expected} @shared:atomic`), OR change the function's param to bare `%{expected}` if the loaded snapshot is enough (use `c.load()` at the call site).",
    },
    ARG_NEEDS_SHARED: {
      severity: :error, category: :type,
      template: "Type Error: Argument %{index} to '%{fn}' expects %{expected} @shared, got %{actual}.%{hint}",
      summary:  "Argument must be a @shared handle to be retained across boundaries.",
      cause: "The function will retain the value past the call (typically because it spawns a fiber, stores into a shared container, or returns a borrow that outlives the param). Plain `%{actual}` is affine — handing it to such a function would lose the original; only `@shared` (Arc) handles can be cloned cheaply at the boundary.",
      fix_hint: "Promote the binding to `@shared` at its declaration (`x = ... @shared`), then pass it directly. If you can't change the source, COPY before passing (`fn(COPY x)`), accepting the deep-copy cost. Alternatively, if the function doesn't actually need to retain the value, change its signature to take bare `%{expected}`.",
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
      template: "Lifetime Error: function '%{fn}' declares `RETURNS %{name}:T` AND `REQUIRES %{name}: ATOMIC | %{others}`. The returned value's lifetime model differs by family: ATOMIC is a bare pointer to a scope-bounded cell, while %{others_label} is reference-counted via Arc. The compiler can't pick one lifetime story at the declaration site. Either split into two functions (one per family) or drop the ATOMIC family from REQUIRES.",
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
      cause: "The function body has RETURN statements that yield different types (e.g. one returns Int64, another returns String). Without an explicit RETURNS annotation that admits the union — typically `:Any` — the inferred return type is ambiguous and callers can't be type-checked safely.",
      fix_hint: "Either pick one return type and convert the others (`String.fromInt(x)` to lift Ints, etc.), declare `RETURNS :Any` to accept the polymorphic return (the auto-fix wires this in directly), or refactor to a UNION and have each branch return the appropriate variant.",
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
    RETURN_LIFETIME_NOT_ASSOCIATED: {
      severity: :error, category: :lifetime,
      template: "Lifetime Error: Lifetime '%{sources}' specified on return, but returned value is not associated.",
      summary:  "Function declares a lifetime source on its return, but the returned value's path can't be traced to that source.",
    },
    WITH_CAP_BINDING_LOST: {
      severity: :error, category: :capability,
      template: "Cannot add capability '%{capability}' to '%{name}': binding not found in its declaring scope.",
      summary:  "Capability target binding is missing from the scope it was declared in.",
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
      cause: "Error types in CLEAR are registered the first time they appear in a `RAISE Kind, Name, ...` site. CATCH WITH(Name) selects against that registry — when the name has never been seen as a registered type, the selector has nothing to match.",
      fix_hint: "Either register the type at its first RAISE site (`RAISE Transient, %{name}, \"msg\"`), import the module that defines it, or check the spelling against an already-registered name in the same scope.",
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
      template: "Error type '%{name}' is not registered. The first RAISE / OR_ELSE EXIT site that names a new type must provide a kind: use 'RAISE Kind, %{name}, \"msg\"' or similar.",
      summary:  "Error type was never registered with a kind.",
      cause: "CLEAR's error registry binds a type name to a *kind* (Transient, Permanent, Internal, Reserved). The kind drives recovery semantics — RETRY targets Transient, OR_ELSE EXIT exits on Permanent, etc. The first site that names a new type must declare the kind so the registry has it for every later use.",
      fix_hint: "At the first RAISE site for `%{name}`, include the kind: `RAISE Transient, %{name}, \"description\"` (or Permanent / Internal). Subsequent RAISE / CATCH sites can omit the kind — the registered binding is reused.",
    },
    ERROR_TYPE_RESERVED_BY_STDLIB: {
      severity: :error, category: :type,
      template: "'%{name}' is reserved by the stdlib as kind '%{kind}'. Pick a different type name.",
      summary:  "Error type name conflicts with a stdlib-reserved one.",
      cause: "The CLEAR stdlib pre-registers a fixed set of error type names (e.g. `IO`, `Allocator`, `Overflow`) bound to specific kinds. User-declared types can't shadow these because cross-module CATCH selectors would become ambiguous.",
      fix_hint: "Rename the user-declared type (`MyIO`, `AppIO`, etc.) so it doesn't collide with the stdlib-reserved name. The stdlib type stays available under its canonical name.",
    },
    ERROR_TYPE_KIND_CONFLICT: {
      severity: :error, category: :type,
      template: "'%{name}' is already mapped to kind '%{kind}'%{first_loc}. Either use the same kind here, or pick a different type name.",
      summary:  "Same error type name registered with a different kind.",
      cause: "Each error type name binds to exactly one kind. Allowing the same name to mean two different kinds would break recovery dispatch (CATCH WITH(`%{name}`) would have to know which kind the call site actually raised).",
      fix_hint: "At this RAISE site, use the previously-registered kind (`%{kind}`), OR pick a fresh name for the variant that legitimately needs a different kind.",
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
      cause: "`@indirect:atomic` publishes whole-T snapshots via atomic pointer swap — every update CAS-publishes a fresh heap allocation. That's necessary for structs (which don't fit in a CAS word) but wasteful for primitives like `%{type}` that already fit in a single machine word and can be CAS'd directly.",
      fix_hint: "Use `@shared:atomic` for primitive cells: `MUTABLE c: %{type} = 0 @shared:atomic;` — direct atomic ops (`c.load()`, `c += 1`) without heap indirection. Reserve `@indirect:atomic` for structs.",
    },
    STRUCT_ATOMIC_NEEDS_INDIRECT: {
      severity: :error, category: :type,
      template: "@atomic on a STRUCT requires @indirect (publishes whole-T snapshots via atomic pointer swap). Use `%{type}{...} @indirect:atomic` instead. (For primitive cells like `Int64@shared:atomic`, atomic alone is correct -- those fit in a single CAS-able machine word.)",
      summary:  "@atomic on a struct requires @indirect.",
      cause: "Struct atomic semantics need to publish the whole T as a single atomic operation. Hardware CAS only works on machine-word-sized values — for any struct larger than that, you need pointer-level CAS, which means heap-allocating the struct and publishing the pointer. That's exactly what `@indirect:atomic` does.",
      fix_hint: "Add `@indirect` to the sigil chain: `%{type}{...} @indirect:atomic` (or full form `%{type}{...} @shared:indirect:atomic`). Reads land in `WITH SNAPSHOT`; writes via `WITH SNAPSHOT MUTABLE`.",
    },
    LOCAL_INDIRECT_ATOMIC: {
      severity: :error, category: :type,
      template: "@local:indirect:atomic is disallowed -- atomic without cross-thread visibility is pointless. Drop @local; @indirect:atomic implies cross-thread sharing.",
      summary:  "@local with @indirect:atomic is contradictory.",
      cause: "`@local` declares the binding lives entirely on the current thread/scheduler — no cross-thread visibility. But `@indirect:atomic` exists *specifically* to publish updates across threads. The two contradict: an atomic with no readers is paying for synchronisation hardware nobody can observe.",
      fix_hint: "Drop `@local` — `@indirect:atomic` already implies the cross-thread sharing semantics you need. If the value is genuinely thread-local, use plain affine ownership (no atomic, no @local needed).",
    },
    MULTIOWNED_INDIRECT_ATOMIC: {
      severity: :error, category: :type,
      template: "@multiowned:indirect:atomic is disallowed -- Rc isn't thread-safe (non-atomic refcount), so it can't back a cross-thread atomic-ptr cell. Drop @multiowned; @indirect:atomic uses Arc internally for the published-value lifetime.",
      summary:  "@multiowned with @indirect:atomic is unsound (Rc isn't atomic).",
      cause: "`@multiowned` is Rc — single-scheduler, non-atomic refcount. `@indirect:atomic` publishes pointers across threads, and the published values' refcounts must be atomic-safe so receivers can release them safely. Rc would race on the refcount; the combination is genuinely unsound.",
      fix_hint: "Drop `@multiowned` — `@indirect:atomic` uses Arc internally for the published-value lifetime, so you get atomic-safe sharing for free. If you wanted explicit shared ownership for non-atomic uses, use `@shared` (Arc) instead of `@multiowned` (Rc).",
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
      cause: "RETRY presumes the operation can succeed on a later attempt — only Transient-kind errors carry that promise. Permanent errors (a missing file, a parse error) won't change between attempts; Internal errors signal a bug rather than something to retry. The compiler rejects RETRY clauses that select non-Transient kinds so retry storms can't accidentally hide real bugs.",
      fix_hint: "Drop the non-Transient selector(s) from the RETRY clause, OR change the recovery action: `OR_ELSE RAISE` to propagate, `OR_ELSE EXIT` to exit the program, `CATCH e WITH(...) { ... }` to handle each kind explicitly.",
    },
    PARTIAL_MATCH_EXPR_NEEDS_DEFAULT: {
      severity: :error, category: :type,
      template: "PARTIAL MATCH used in expression position requires a DEFAULT branch. Either add a DEFAULT case, or change to `MATCH` (which forces every variant to have an exact case).",
      summary:  "PARTIAL MATCH expression must have a DEFAULT branch.",
      cause: "PARTIAL MATCH relaxes exhaustiveness — not every variant must have a case. In statement position that's fine (unmatched values fall through), but in expression position the binding needs a value on every path. Without a DEFAULT, an unmatched subject would leave the binding uninitialised.",
      fix_hint: "Add `DEFAULT -> <value>` to cover the unmatched paths. If exhaustiveness is actually achievable, switch to plain `MATCH` (the compiler then verifies every variant has an arm at compile time and no DEFAULT is needed).",
    },
    CAN_SMASH_NOT_SUPPORTED: {
      severity: :error, category: :reentrance,
      template: "`@canSmash` on BG/DO blocks is recognized but not yet supported by the compiler. The runtime has stack-hysteresis (page-guarded soft overflow detection) to protect fiber stacks, but the compiler does not yet wire that feature on. Use `@service` instead (spawns on a dedicated OS thread with a 4 MB pre-allocated stack); `@canSmash` is expected to be supported in v0.3.",
      summary:  "@canSmash is parsed but not yet implemented.",
    },

    # Tranche 8 — umbrella codes. These use a `%{message}` passthrough
    # template (same shape as the MIR-checker codes) for sites whose
    # message is built dynamically by the surrounding pass. The code
    # carries summary/cause metadata so `clear explain` works; the
    # rendered text is whatever the call site produces.
    CAPABILITY_VIOLATION_FIXABLE: {
      severity: :error, category: :capability,
      template: "%{detail}",
      summary:  "Capability mismatch with an interactive auto-fix available.",
      cause: "The capability declared on a binding (locked / write_locked / shared / multiowned / observable / ...) doesn't satisfy the operation being performed. The Capabilities validator computes a precise reason (wrong tense, missing wrapper, incompatible combination) and the message field carries the specific text.",
      fix_hint: "Read the message — it describes the exact mismatch and usually points at the right capability. `clear fix` typically offers an interactive auto-fix when the change is mechanical (add a missing wrapper, swap a tense).",
    },
    PURITY_VIOLATION: {
      severity: :error, category: :type,
      template: "%{detail}",
      summary:  "A pure function calls into impure code (effects / surface).",
      cause: "A function declared as pure (PURE keyword or implied via REQUIRES) called into code that has effects (yield / alloc_heap / io / fail). The effect lattice is inferred per-function and propagated through the call graph; a pure caller cannot escape its purity.",
      fix_hint: "Either remove the PURE declaration on the caller, or remove the impure call. If the impure work is needed, isolate it in a non-pure helper and only call into pure code from inside the pure body.",
    },
    VARDECL_TYPE_MISMATCH_FIXABLE: {
      severity: :error, category: :type,
      template: "%{detail}",
      summary:  "Variable declaration's value type doesn't match the declared type, with an interactive fix.",
      cause: "The value bound to the variable doesn't fit the declared type. Coercion was tried (slice widening, primitive autocast) and failed. An interactive fix is available when the language can suggest a literal CAST or the type annotation can be inferred from the value.",
      fix_hint: "Either change the declared type to match the value, change the value to the declared type, or use `CAST x AS Type` for an explicit conversion.",
    },
    OBSERVABLE_BINDING_NEEDS_FOLD_PIPE: {
      severity: :error, category: :type,
      template: "`~T@observable` bindings must be initialized by a pipeline-terminal fold over a tense stream (e.g. `running: ~Int64@observable = stream |> SUM _`). The producer fiber, atomic accumulator, and WaitGroup wiring all live in the fold's codegen path -- a bare declaration or a non-fold initializer has no producer, so NEXT/COLLECT would deadlock and cleanup would touch an uninitialized wrapper.",
      summary: "`~T@observable` bindings need a fold-pipe initializer.",
      cause: "Observable bindings are implemented by the fold-pipe codegen path. That path allocates the producer fiber, accumulator, and WaitGroup bridge. A bare observable declaration or arbitrary initializer would create a wrapper with no producer.",
      fix_hint: "Initialize the binding from a pipeline-terminal fold over a tense stream, or drop `@observable` if this binding should behave like a regular tense value.",
    },
    ATOMIC_ESCAPE_ASSIGN: {
      severity: :error, category: :escape,
      template: "%{detail}",
      summary:  "Assigning a value whose lifetime is tied to a sync-axis source escapes the source's scope.",
      cause: "A value whose lifetime is tied to a sync-axis source (e.g. `@shared:atomic` cell) was assigned into a binding that outlives the source's scope. The atomic cell is bounded by its declaring scope; the assignment would dangle.",
      fix_hint: "Migrate the source to `@shared:locked` (a longer lifetime model) — `clear fix` offers this as an interactive transformation. Or restructure so the assignment doesn't escape the source scope.",
    },
    ATOMIC_ESCAPE_RETURN: {
      severity: :error, category: :escape,
      template: "%{detail}",
      summary:  "Returning a value whose lifetime is tied to a sync-axis source escapes the source's scope.",
      cause: "A value whose lifetime is tied to a sync-axis source was returned from a function that doesn't declare `RETURNS source:T`. The source is bounded by its declaring scope; returning the value would dangle.",
      fix_hint: "Either declare `RETURNS x:T` on the function (propagates the lifetime to the caller), COPY the value before returning, or migrate the source to `@shared:locked`.",
    },
    STACK_NEEDS_SERVICE_FIXABLE: {
      severity: :error, category: :reentrance,
      template: "Stack safety: this fiber transitively calls '%{reentrant_fn}' which is `EFFECTS REENTRANT` (plain) -- the call chain is unbounded and MUST run on an OS thread. Declare `@service` explicitly on the spawn site (the compiler no longer auto-infers this). Alternatively, change '%{reentrant_fn}' to a bounded reentrance variant: `:THUNK` (heap CPS, depth=1 fiber stack), `:TAIL_CALL` (TCO loop, depth=1), `:NOT_LOGICAL` (asserts non-recursion), or `:MAX_DEPTH(N)` (bounded counter).",
      summary:  "Spawn site transitively calls a plain :reentrant function and must run on @service (OS thread).",
      cause: "A BG/DO spawn site transitively calls a function declared as plain `EFFECTS REENTRANT` (unbounded recursion). Plain reentrant chains can't fit on a fiber stack — they require an OS thread (`@service`).",
      fix_hint: "Either declare `@service` on the spawn site (`clear fix` replaces the existing tier sigil), or change the callee to a bounded reentrance variant (`:THUNK`, `:TAIL_CALL`, `:NOT_LOGICAL`, `:MAX_DEPTH(N)`).",
    },
    REENTRANT_MUTUAL_THUNK_UNSUPPORTED: {
      severity: :error, category: :reentrance,
      template: "EFFECTS REENTRANT:THUNK on '%{name}' is mutually recursive (cycle through other functions: %{cycle}) and the cycle's body shape isn't supported by the current tagged-union codegen (only IF base cases + a RETURN partner(args) tail call). Pick one: declare 'EFFECTS REENTRANT' on every cycle member (callers run on @service / OS thread); declare 'EFFECTS REENTRANT:NOT_LOGICAL' on every cycle member (return type changes from `T` to `!T`; runtime StackGuard raises System UnexpectedRecursion on actual re-entry); or declare 'EFFECTS REENTRANT:MAX_DEPTH(N)' on every cycle member (also `T` -> `!T`; runtime depth counter raises System MaxDepthExceeded above N -- pick N tight, this is NOT a workaround for being forced onto OS threads. If depth is unknown or unbounded, prefer ':THUNK' (heap CPS) or plain 'EFFECTS REENTRANT' + OS threads).",
      summary:  "Mutual-recursion cycle of :THUNK functions whose body shape isn't supported by the tagged-union codegen.",
      cause: "Mutual recursion through `:THUNK` functions requires a tagged-union trampoline whose codegen only handles a specific body shape: IF base cases plus a `RETURN partner(args)` tail call. The cycle's body shape isn't supported.",
      fix_hint: "Three options: (a) declare plain `EFFECTS REENTRANT` on every cycle member (callers run on `@service` / OS thread), (b) declare `:NOT_LOGICAL` (asserts no actual recursion at runtime), (c) declare `:MAX_DEPTH(N)` (bounded counter). `clear fix` offers each as an interactive auto-fix.",
    },
    INTRINSIC_REJECTED: {
      severity: :error, category: :type,
      template: "%{detail}",
      summary:  "Stdlib intrinsic rejected this call (the matched signature's reject_when fired).",
      cause: "A stdlib intrinsic (`.negative?`, `.zero?`, ...) rejected this call because the argument type isn't allowed. The stdlib uses `reject_when` patterns to rule out call shapes that look valid but produce wrong results — e.g. `.negative?` on an unsigned int.",
      fix_hint: "Check the message for the specific reject reason. Often the fix is to remove the call entirely (the answer is statically known) or use a different intrinsic.",
    },
    TYPE_COERCION_FAILED: {
      severity: :error, category: :type,
      template: "%{detail}",
      summary:  "Type coercion produced an error (Type#coerce! returned a diagnostic).",
      cause: "Type#coerce! tried to widen a value into the target type and failed. Common cases: array-overflow (initializer larger than `T[N]`), unrelated types (assigning Float64 to String), or capability mismatch.",
      fix_hint: "The error text describes the specific failure. Either change the source value, change the target type, or use `CAST x AS Type` for an explicit conversion.",
    },
    LOCK_CYCLE_DETECTED: {
      severity: :error, category: :concurrency,
      template: "Potential %{kind} over [%{types}]. Sites contributing to the cycle:\n%{sites}\nFix: acquire in a consistent order everywhere, or mark individual sites POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE if the ordering is programmer-enforced.",
      summary:  "Static lock-acquire graph contains a cycle (potential deadlock).",
      cause: "Static analysis of the lock-acquire graph found a cycle (or self-loop). Two locks A and B are acquired in inconsistent orders across different sites — at runtime this can deadlock if two threads hit them simultaneously.",
      fix_hint: "Fix the order — pick a consistent total order (rank locks by type, name, or memory address) and acquire ascending everywhere. Or, when the order is enforced by a different discipline (sharded data, CAS-loop), mark individual sites POSSIBLE_DEADLOCK / POSSIBLE_LOCK_CYCLE.",
    },
    REGISTRY_MISMATCH_REJECTED: {
      severity: :error, category: :registry,
      template: "%{detail}",
      summary:  "Identifier doesn't match any registered candidate, no typo-suggestion fix available.",
      cause: "An identifier was checked against a closed registry (error kinds, error types, sync families) and didn't match any candidate. The Levenshtein distance to every candidate exceeded the typo-suggestion threshold, so no auto-fix is offered.",
      fix_hint: "Check the spelling and the message for the list of valid candidates. The registry is closed — only the listed identifiers are accepted.",
    },
    TYPO_SUGGESTION_REJECTED: {
      severity: :error, category: :registry,
      template: "%{detail}",
      summary:  "Identifier rejected, no close-enough candidate to suggest as a typo fix.",
      cause: "An identifier didn't match any candidate in the relevant scope (variable, struct field, union variant, ...) and the closest candidate was outside the typo-suggestion threshold. No auto-fix is offered.",
      fix_hint: "Check the spelling and the surrounding scope. If the identifier should exist, verify it's been declared / imported in this scope.",
    },
    EFFECT_INFERENCE_VIOLATION: {
      severity: :error, category: :type,
      template: "%{detail}",
      summary:  "Per-function effect inference (P3.x) rejected the program (yield-across-lock, naked nested-WITH, recursive lock acquire, etc.).",
      cause: "Per-function effect inference (yield / alloc_heap / io / fail) detected a violation: hold-lock-across-yield, naked nested-WITH, recursive lock acquire on the same binding, etc. The specific check is described in the message.",
      fix_hint: "Most are structural: split the WITH (no nested re-acquire), avoid yielding while holding a lock, add `EFFECTS REENTRANT` if recursion is intentional. The message names the specific check.",
    },
    CAPABILITY_INVALID: {
      severity: :error, category: :capability,
      template: "%{detail}",
      summary:  "Capability declaration rejected by Capabilities.validate! (unsupported sigil combination, primitive cap, etc.).",
      cause: "Capabilities.validate! rejected the binding's capability stack — either an unsupported sigil combination (`@local:atomic`), a capability on an incompatible type (capability on a primitive), or a missing required capability.",
      fix_hint: "Read the message for the specific rejection. Common fixes: drop a contradictory sigil, wrap a primitive in a struct, add a missing wrapper (`@shared` for cross-fiber sharing).",
    },
  }.freeze, T::Hash[Symbol, T::Hash[Symbol, T.untyped]])

  FIX_DESCRIPTIONS = T.let({
    ADD_DECL_CAPABILITY_GENERIC: "Add `%{sigil}` to '%{name}' at its declaration (line %{line}).",
    ADD_EFFECTS_REENTRANT: "Add `EFFECTS REENTRANT` so the runtime knows to schedule this fn on a service stack.",
    ADD_ERROR_UNION_TO_RETURN: "Add `!` to the return type to declare the error union (Zig-style fallible signature).",
    ADD_NON_REENTRANT_REQUIRES: "Add %{requires} (rejects reentrant callbacks).",
    ADD_WITH_GUARD_ALIASES: "Add `AS <alias>` to each binding so the GUARD predicate can read the unwrapped value.",
    APPEND_MUTABLE_PARAM_BANG: "Append `!` to '%{name}' (signals that it takes a MUTABLE parameter).",
    CHANGE_BINDING_CAPABILITY_FOR_MOVE: "Change '%{name}' to `%{cap}` at its declaration (%{reason}).",
    CHANGE_DECL_CAPABILITY_GENERIC: "Change `%{old_sigil}` to `%{new_sigil}` on '%{name}' (line %{line}).",
    CHOOSE_RECURSIVE_LAYOUT: "%{description} on %{edge} using `%{capability}`.",
    CONSTRUCT_INDIRECT_LAYOUT: "Construct this value with explicit `@indirect` layout.",
    DECLARE_FN_REENTRANT: "Declare '%{fn}' as 'EFFECTS REENTRANT' (propagates the cost; caller runs on @service).",
    DECLARE_MAX_DEPTH_CYCLE: "Declare every cycle member ':MAX_DEPTH(%{depth})' and change each return type from `T` to `!T`. Runtime depth counter raises System MaxDepthExceeded above %{depth} entries. PICK N TIGHT: large N is not a workaround for being forced onto OS threads -- if depth is unknown/unbounded, prefer ':THUNK' (heap CPS) or plain 'EFFECTS REENTRANT' (OS threads).",
    DECLARE_MUTABLE_BINDING: "Declare '%{name}' as MUTABLE at its binding site (line %{line}).",
    DECLARE_NOT_LOGICAL_CYCLE: "Declare every cycle member ':NOT_LOGICAL' and change each return type from `T` to `!T`. Runtime StackGuard raises System UnexpectedRecursion if the cycle actually re-enters; callers must handle (or propagate via `!T`) that error.",
    DROP_MAX_DEPTH_MUTUAL: "Drop ':MAX_DEPTH(%{max_depth})' and accept the ':unbounded' tier explicitly. Same runtime cost as today but the choice is now in the source.",
    DROP_OBSERVABLE_CAPABILITY: "Drop `%{token}` from the binding's type annotation. The remaining type behaves as a regular binding (no producer fiber, no WITH VIEW); use this if you didn't actually want streaming-aggregate semantics.",
    DROP_THUNK_CYCLE: "Drop ':THUNK' on every cycle member; use plain 'EFFECTS REENTRANT' (callers run on @service).",
    DROP_WITH_GUARD_MUTABLE: "Drop `MUTABLE` from %{target} so the GUARD predicate stays valid (the body only reads through the alias).",
    INSERT_EXPECTED_AT_END_OF_LINE: "Insert `%{expected}` at end of line %{line}.",
    INSERT_EXPECTED_BEFORE_TOKEN: "Insert `%{expected}` before '%{got}' at line %{line}.",
    INSERT_EXISTS_BEFORE_AS: "Insert `EXISTS` before `AS`.",
    INSERT_COMPTIME_BEFORE_IF: "Insert COMPTIME before IF.",
    INSERT_RETURNS_ANY: "Insert `RETURNS :Any` so the function accepts the polymorphic return.",
    INSERT_RETURNS_FALLIBLE_VOID: "Insert `RETURNS !Void` so PRE-failure errors can propagate.",
    INSERT_SAFE_NAVIGATION: "Insert `?` before field access so NIL propagates safely.",
    INSERT_SERVICE_AFTER_OPEN_BRACE: "Insert `@service ->` after `{` (this fiber transitively calls a plain :reentrant fn).",
    MIGRATE_ATOMIC_ESCAPE: "Migrate '%{name}' from `@shared:atomic` to `@shared:locked` so its lifetime can outlive the declaring scope. NOTE: `@shared:locked` typically needs a STRUCT wrap around the primitive (e.g. `STRUCT Counter { v: Int64 }; c = Counter{v: 0} @shared:locked`); read/write sites become `WITH EXCLUSIVE c AS a { ... }`. Alternatively, wait for v0.3 atomic struct fields, which lift this escape restriction without the Arc cost.",
    PIN_AUTO_SLOT: "(%{position}) Pin %{label} to `%{type}`.%{note}",
    PREFIX_TENSE_TYPE: "Prefix the declared type with `~` so '%{name}' becomes a tense (`~T`) source. MATERIALIZED VIEW snapshots a tense aggregate at the WITH boundary.",
    PREFIX_COPY_SNAPSHOT: "Prefix the source with `COPY` to create an independent snapshot.",
    PREFIX_EXPLICIT_OWNERSHIP_COST: "Prefix the source with `%{keyword}` to make the ownership cost explicit.",
    REMOVE_LOCAL_CAPABILITY: "Remove `@local` capability from '%{name}' (never shared across fibers).",
    REMOVE_MUTABLE_UNUSED: "Remove MUTABLE keyword (binding is never reassigned).",
    REPLACE_CAN_SMASH_WITH_SERVICE: "Replace `@canSmash` with `@service` (OS-thread spawn -- supported today).",
    REPLACE_IDENTIFIER_WITH_CANDIDATE: "Replace '%{name}' with '%{best}' (%{label}).",
    REPLACE_LOCKED_WITH_WRITE_LOCKED: "Change `@locked` to `@writeLocked` on '%{name}' so concurrent readers can take `WITH READ` alongside `WITH EXCLUSIVE` writers.",
    REPLACE_MATCH_WITH_PARTIAL: "Replace `MATCH` with `PARTIAL MATCH` (relaxes exhaustiveness; allows DEFAULT and WHEN guards).",
    REPLACE_OPERATOR_TYPO: "Replace `%{match}` with `%{replace}` -- %{label}.",
    REPLACE_STRING_CONCAT_OPERATOR: "Replace `+` with `$+` for string concatenation.",
    TEST_OPTIONAL_BOOL_PRESENCE: "Test whether the optional Bool is present with `%{name} EXISTS`.",
    DEFAULT_OPTIONAL_BOOL_PAYLOAD: "Use the Bool payload, defaulting NIL to FALSE, with `(%{name} OR_ELSE FALSE)`.",
    REPLACE_REENTRANT_WITH_VARIANT: "Replace `EFFECTS REENTRANT` with `%{suggestion}` (%{reason}).",
    REPLACE_STACK_SIGIL_WITH_SERVICE: "Replace `@%{stack}` with `@service` (this fiber transitively calls a plain :reentrant fn).",
    UPGRADE_VERSIONED_TO_SHARED: "Upgrade `@versioned` to `@shared:versioned` for cross-thread sharing.",
    WITH_ADD_INDIRECT_ATOMIC: "Add `@indirect:atomic` to '%{name}' (lock-free atomic-pointer cell -- readers snapshot, writers CAS-publish).",
    WITH_ADD_LOCKED: "Add `@locked` to '%{name}' (Mutex -- single-writer EXCLUSIVE access).",
    WITH_ADD_MULTIOWNED: "Add `@multiowned` to '%{name}' (Rc -- single-scheduler refcount; cheap clones%{suffix}).",
    WITH_ADD_SHARED: "Add `@shared` to '%{name}' (Arc -- atomic refcount; safe %{suffix}).",
    WITH_ADD_SHARED_ATOMIC: "Add `@shared:atomic` to '%{name}' (lock-free atomic primitive -- `c.load()`, `c.fetchAdd(n)`, etc. via WITH ATOMIC).",
    WITH_ADD_VERSIONED: "Add `@versioned` to '%{name}' (MVCC cell -- readers see a stable snapshot; writers retry on conflict).",
    WITH_ADD_WRITE_LOCKED: "Add `@writeLocked` to '%{name}' (RwLock -- readers %{reader}; writers via `WITH EXCLUSIVE`).",
    WITH_VIEW_TO_MATERIALIZED: "Replace `VIEW` with `MATERIALIZED VIEW` (owned O(N) snapshot, works on any `~T` aggregate).",
    WIDEN_INT_ANNOTATION: "Widen annotation `%{old_type}` to `%{new_type}` (smallest type that fits %{value}).",
    WIDEN_INT_SUFFIX: "Widen suffix `_%{old_suffix}` to `_%{new_suffix}` (smallest type that fits %{value}).",
    WRAP_CAPABILITY_ACCESS: "Wrap with `WITH %{permission} %{name} AS %{alias_name} { ... }` to acquire the %{capability} unwrap; access the inner value through %{alias_name}.",
    WRAP_CONSUMER_WITH_CLONE: "Wrap the consuming reference with CLONE at line %{line} (bumps the refcount; both bindings stay live).",
    WRAP_CONSUMER_WITH_COPY: "Wrap the consuming reference with COPY at line %{line} (the original survives for the later use).",
    WRAP_RETURN_WITH_COPY: "Wrap the returned value with `COPY ` so it doesn't borrow from the parameter.",
    WRAP_VALUE_WITH_CAST: "Wrap value with `CAST(... AS %{type})` (narrowing -- verify it can't lose data).",
    REPLACE_AUTO_WITH_INFERRED: "Replace `Auto` with the inferred type `%{type}`.",
  }.freeze, T::Hash[Symbol, String])


  sig { params(code: Symbol).returns(T.nilable(DiagnosticEntry)) }
  def self.lookup(code)
    DIAGNOSTICS[code]
  end

  sig { params(code: Symbol).returns(T::Boolean) }
  def self.known?(code)
    DIAGNOSTICS.key?(code)
  end

  sig { returns(T::Array[Symbol]) }
  def self.codes
    DIAGNOSTICS.keys
  end

  # True when the registry entry exists but is reserved for a future
  # feature whose triggering visitor isn't implemented yet. Audit
  # tooling skips these — we can't write a bad/good example for an
  # unimplemented compiler check.
  sig { params(code: Symbol).returns(T::Boolean) }
  def self.pending?(code)
    entry = DIAGNOSTICS[code]
    !entry.nil? && entry[:pending] == true
  end

  # Format a registered code's template against `args`. Returns nil
  # when the code isn't known. The caller decides what to do with
  # nil — the legacy helper raises an internal-compiler-error there.
  sig { params(code: Symbol, args: T::Array[T.untyped], kwargs: T.untyped).returns(T.nilable(String)) }
  def self.format(code, args = [], **kwargs)
    format_from_hash(code, args, kwargs)
  end

  sig { params(code: Symbol, args: T::Array[T.untyped], kwargs: T.untyped).returns(T.nilable(String)) }
  def self.format_from_hash(code, args, kwargs)
    entry = DIAGNOSTICS[code]
    return nil unless entry

    format_template(T.cast(entry[:template], String), args, kwargs)
  end

  sig { params(template: String, args: T::Array[T.untyped], kwargs: T::Hash[Symbol, DiagnosticKwValue]).returns(String) }
  def self.format_template(template, args = [], kwargs = {})
    if !kwargs.empty? || template.include?("%{")
      return template % kwargs if !template.include?("%{") || named_template_args_complete?(template, kwargs)

      return "#{template} [Internal Args Error: #{kwargs.inspect}]"
    end

    return template % args if positional_template_args_complete?(template, args)

    "#{template} [Internal Args Error: #{args.inspect}]"
  end

  sig { params(template: String, kwargs: T.untyped).returns(T::Boolean) }
  def self.named_template_args_complete?(template, kwargs)
    keys = named_template_keys(template)
    i = T.let(0, Integer)
    while i < keys.length
      return false unless kwargs.key?(keys.fetch(i))

      i += 1
    end
    true
  end

  sig { params(template: String).returns(T::Array[Symbol]) }
  def self.named_template_keys(template)
    keys = T.let([], T::Array[Symbol])
    offset = T.let(0, Integer)
    loop do
      start_index = template.index("%{", offset)
      break unless start_index

      end_index = template.index("}", start_index + 2)
      break unless end_index

      keys << T.unsafe(template[(start_index + 2)...end_index]).to_sym
      offset = end_index + 1
    end
    keys
  end

  sig { params(template: String, args: T::Array[T.untyped]).returns(T::Boolean) }
  def self.positional_template_args_complete?(template, args)
    positional_placeholder_count(template) <= args.length
  end

  sig { params(template: String).returns(Integer) }
  def self.positional_placeholder_count(template)
    count = T.let(0, Integer)
    i = T.let(0, Integer)
    while i < template.length - 1
      if template[i] == "%"
        spec = template[i + 1]
        if spec == "s" || spec == "d"
          count += 1
          i += 1
        elsif spec == "%"
          i += 1
        end
      end
      i += 1
    end
    count
  end

  # ruby-to-clear: pub
  sig { params(code: Symbol, kwargs: T::Hash[Symbol, DiagnosticKwValue]).returns(String) }
  def self.fix_description_from_hash(code, kwargs)
    template = FIX_DESCRIPTIONS[code]
    Kernel.raise "Internal Compiler Error: Unknown fix description code :#{code}" unless template

    return template % kwargs if named_template_args_complete?(template, kwargs)

    missing = missing_named_template_key(template, kwargs)
    detail = missing ? "key{#{missing}} not found kwargs=#{kwargs.inspect}" : "kwargs=#{kwargs.inspect}"
    "#{template} [Internal Args Error: #{detail}]"
  end

  sig { params(template: String, kwargs: T.untyped).returns(T.nilable(Symbol)) }
  def self.missing_named_template_key(template, kwargs)
    keys = named_template_keys(template)
    i = T.let(0, Integer)
    while i < keys.length
      key = keys.fetch(i)
      return T.unsafe(key) unless kwargs.key?(key)

      i += 1
    end
    nil
  end

  sig { params(code: Symbol, kwargs: DiagnosticKwValue).returns(String) }
  def self.fix_description(code, **kwargs)
    fix_description_from_hash(code, kwargs)
  end

  # Self-check: every entry is well-formed. Returns an array of
  # error strings; empty == registry is consistent. Run by the
  # spec to make sure new entries don't drift.
  # ruby-to-clear: skip
  sig { returns(T::Array[String]) }
  def self.validate
    issues = T.let([], T::Array[String])
    DIAGNOSTICS.each do |code, entry|
      issues << "#{code}: missing :severity"  unless SEVERITIES.include?(entry[:severity])
      issues << "#{code}: missing :category"  unless CATEGORIES.include?(entry[:category])
      issues << "#{code}: missing :template"  unless entry[:template].is_a?(String)
      issues << "#{code}: missing :summary"   unless entry[:summary].is_a?(String)
    end
    FIX_DESCRIPTIONS.each do |code, template|
      issues << "#{code}: missing fix description template" unless template.is_a?(String)
    end
    issues
  end
end
