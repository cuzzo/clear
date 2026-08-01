# Parser type slop blocks readable Ruby-to-CLEAR output

Status: source cleanup required before resuming whole-parser transpilation.

This note records why work on the generated CLEAR parser was stopped. It is a
diagnosis and handoff, not an implementation plan for the current branch. The
parser cleanup will be performed elsewhere.

## Decision

Do not continue repairing `compiler/src/ast/parser.clear` around the current
Ruby types. The generated failures are no longer merely isolated Ruby-to-CLEAR
lowering defects. Several important parser invariants are absent or incorrectly
typed in the Ruby source, and the transpiler consequently emits defensive casts,
optional recovery, and erased aggregate types.

Fix the Ruby parser/AST typing first, then regenerate the CLEAR parser. Resume
manual CLEAR work only for residual target-language issues after the regenerated
code is readable and structurally faithful.

## Triggering example

The immediate warning sign was generated code equivalent to:

```clear
CAST([
  CAST([
    castTokenValueToString(
      (name_tok OR_ELSE CAST(panic("T.must failed") AS Token)).value
    ),
    v
  ] AS Tuple<String, Node>),
  name_tok
] AS Tuple<Tuple<String, Node>, ?Token>)
```

The Ruby operation is conceptually simple: consume a required identifier token,
obtain its text, parse its value, and retain the token for source diagnostics.
The generated expression is not an acceptable long-term representation of that
operation.

## Concrete findings

The following counts were observed in `compiler/ruby/ast/parser.rb` on
2026-07-13. They are snapshots, not permanent acceptance thresholds:

- 163 `T.must` calls.
- 59 `T.cast` calls.
- 54 occurrences of `T.must(consume(...))`.
- 73 generated `castTokenValueToString` calls in the CLEAR parser.
- 182 generated `OR_ELSE ... panic("T.must failed") ... Token` recoveries.

Raw counts do not prove that every use is wrong. They do show that nullability
and token-value narrowing are being repeatedly reconstructed at use sites.

### `consume` has false nullability

`ClearParser#consume` is declared to return `T.nilable(Lexer::Token)`. Its success
path returns the consumed token. Its failure path calls
`emit_consume_error_with_fix`, which is declared `T.noreturn`; that helper either
raises through a fixable diagnostic or calls `error!`.

Therefore the semantic return type of `consume` is `Lexer::Token`, not an
optional token. The false optional propagates into nearly every grammar rule as
`T.must` in Ruby and `OR_ELSE panic` in CLEAR.

This is source type slop, not a reason to weaken CLEAR's type checker or teach an
autofixer to insert more recovery expressions.

### The lexer value union is legitimate

It would be incorrect to make every token value a `String`. CLEAR's generated
lexer accurately represents token values as:

```clear
UNION TokenValue {
  Nil,
  Str: String,
  Int: Int64,
  UInt: UInt64,
  Float: Float64
}
```

Numeric literals should remain numeric. EOF may have no payload. The problem is
not the existence of this union; the problem is that parser operations that
require text do not express that requirement at a typed boundary.

Ruby currently defines `Lexer::Token` with an untyped `Struct.new`. Although
`Lexer#add` restricts values to `Float`, `Integer`, or `String`, Sorbet cannot
derive the dependent invariant “this token kind has this value variant.” The
parser then repeatedly casts `.value` to `String` after it has already consumed a
string-valued token kind.

### Required textual values need a named boundary

Identifier, type-identifier, keyword, punctuation, and string-token consumers
should obtain text through a typed operation. Possible designs include:

- typed token variants;
- a checked `Token#text`/`token_text(token)` accessor;
- `consume_text(...)` and `consume_identifier(...)` parser primitives that
  return both the token and its `String` value.

Whichever design is selected, an invalid non-text payload must fail once at that
boundary as an internal lexer/parser invariant. Grammar rules should not contain
unchecked casts or know how the token payload union is represented in CLEAR.

Do not replace every token payload with `String`, stringify numeric values, or
make CLEAR casts implicit. Those approaches hide the invariant instead of
encoding it.

### Generic parser combinators cross an erasure boundary

The Ruby `parse_comma_seq` method has a Sorbet type parameter and is reasonable
for homogeneous values such as `AST::Node[]`. Ruby-to-CLEAR currently lowers its
element result to an erased target representation. Complex element shapes, such
as a nested tuple containing a field name, AST node, and diagnostic token, then
require nested `CAST` expressions at the caller.

For structured results, prefer one of the following:

- a named typed record that survives lowering;
- a specialized parsing helper that directly produces the typed maps or arrays
  consumed by the AST constructor;
- a future Ruby-to-CLEAR generic-IR improvement that preserves the instantiated
  element type through block lowering.

The struct-literal case should not encode a transient
`[[String, AST::Node], Token]` value only to immediately split it into two maps.
A typed helper can directly return the field-value and field-token maps.

### The AST also exposes untyped state

`AST::StructLit` is another legacy `Struct.new`. Its core members (`name`,
`fields`, `storage`, and `type_args`) currently lower to `Any`. Its
`field_tokens` and `borrowed_field_names` accessors have no Sorbet signatures.
The generated `field_tokens` field was manually made
`HashMap<String, ?Token>`, but that target-only repair does not make the Ruby AST
contract sound.

The parser cleanup should include the AST records it constructs. Otherwise a
clean parser boundary will immediately lose its types when values enter the AST.

## Recommended cleanup sequence

1. Correct `consume` to return a required token and verify all failure helpers
   are genuinely non-returning in both Ruby and CLEAR lowering.
2. Define the lexer token payload union explicitly in Ruby, or provide checked,
   typed payload accessors that preserve the legitimate numeric variants.
3. Introduce typed parser primitives for required textual tokens and replace
   repeated `T.cast(T.must(consume(...)).value, String)` patterns.
4. Type the AST records and accessors touched by parser construction, beginning
   with `AST::StructLit`.
5. Replace structured uses of erased generic combinators with named records or
   specialized typed helpers. Retain the generic combinator for simple
   homogeneous sequences.
6. Add Ruby parser tests for the invariants and Ruby-to-CLEAR translation tests
   for the resulting source shapes.
7. Regenerate the CLEAR parser and assess readability before resuming the
   compatibility/message-pack gate.

## Tests that should accompany the cleanup

- `consume` returns `Lexer::Token` on success and raises on mismatch; no caller
  should need `T.must`.
- Every token kind used as parser text rejects a numeric or empty payload at the
  typed boundary with a clear internal-invariant failure.
- Numeric literal tokens retain `Int64`, `UInt64`, or `Float64` payloads without
  string conversion.
- Struct literal parsing produces typed field-value and field-token maps for
  empty, single-field, multi-field, generic, and trailing-comma forms.
- Ruby-to-CLEAR output for a representative struct literal contains no nested
  tuple casts and no optional recovery around required consumed tokens.
- The parser message-pack compatibility stage remains the end-to-end acceptance
  gate after regeneration.

## Readiness criteria for transpilation

The parser is ready to transpile when:

- required token consumption is non-null in source and generated code;
- textual payload narrowing is named and centralized;
- parser-created AST values do not immediately degrade to `Any`;
- common grammar rules are readable without stacked `T.must`/`T.cast` recovery;
- representative generated CLEAR reads like the Ruby operation rather than a
  serialization of Sorbet escape hatches;
- the remaining casts correspond to real dynamic language cases and are
  documented locally.

Until those conditions hold, manually making the generated parser compile is
likely to make the codebase harder to maintain and will be overwritten by the
next parser regeneration.
