# Parser Refactor Plan

## Status and recommendation

`compiler/ruby/ast/parser.rb` should be refactored before Ruby-to-CLEAR is
asked to translate it again. The parser is valid working Ruby, but several of
its internal contracts are expressed through runtime conventions rather than
through types: broad token payloads, positional capture arrays, fixed-schema
hashes, sentinel unions, and mutable parser side channels. Translating those
conventions literally produces CLEAR that is difficult to read and difficult
to verify.

This is not a request to redesign the grammar or replace the parser. The
current declarative token-routing tables are useful and should remain. The
recommended work is to make the data and state transitions behind those tables
explicit and typed.

These changes are improvements to the Ruby compiler in their own right. They
make parser invariants locally visible, make speculative state restoration
exception-safe, improve diagnostics, reduce invalid intermediate states, and
give tests stable units below the full-parser level. Cleaner CLEAR output is a
consequence of those improvements, not the sole justification for them.

## Scope and evidence

The assessment covers `compiler/ruby/ast/parser.rb` and the immediate parser
contracts in:

- `compiler/ruby/ast/parser_rules.rb`
- `compiler/ruby/ast/lexer.rb`
- `compiler/ruby/ast/ast.rb`
- the parser-output fields consumed by the annotator and MIR

The parser itself is approximately 4,900 lines. The findings below are based
on concrete source patterns, the current FactMine, Decomplex, Espalier, and
NilKill reports, and the failed Ruby-to-CLEAR output previously observed.

Two boundaries are important:

1. This plan does not propose speculative metrics as a substitute for source
   review. In particular, the parser did not provide evidence for a new
   false-union detector, a general phase-fact-loss detector, or arbitrary
   shape-recovery analysis.
2. Tuples, unions, and hashes are not categorically bad. The problem is their
   use as anonymous records or control protocols where named types would make
   the contract safer and clearer.

The FactMine nested-tuple extraction defect discovered during this assessment
has already been fixed separately. It is a correctness fix to an existing
fact stream, not a reason to invent a new parser metric.

## Why direct translation currently fails the quality bar

Ruby-to-CLEAR is forced to recover meaning that the Ruby source encodes only
by convention. A representative parser operation does all of the following in
one expression:

- retrieves an untyped `Token#value`;
- asserts that an optional token exists;
- casts the payload to the type implied by the token kind;
- constructs an anonymous nested tuple;
- later recovers part of that tuple to construct a hash.

Literal translation therefore produces expressions such as nested `CAST`,
`OR_ELSE`, tuple construction, and panic calls where the intended operation is
simply “read an identifier and remember its token.” Improving CLEAR's emitter
cannot make that source contract inherently clear. The parser needs to state
the contract once, at the correct boundary.

The recurring translation hazards are:

- `T.untyped` token and rule payloads;
- `T.cast`, `T.must`, and `T.unsafe` used to recover local invariants;
- symbol-based dynamic action dispatch;
- positional arrays serving as heterogeneous capture records;
- fixed-key hashes serving as structs;
- optional return types for functions that actually return or raise;
- manual save/restore of parser state;
- AST properties that are part of the phase interface but have untyped or
  implicit defaults.

Ruby-to-CLEAR should translate explicit parser semantics. It should not need a
second, parser-specific inference system to rediscover these conventions.

## Refactor 1: give token payloads a checked API

### Current problem

`Lexer::Token` is a four-slot `Struct` whose `value` slot is broad. Parser code
knows that a `TYPE_ID` or `VAR_ID` carries a string, but repeatedly recovers
that fact with `T.cast`. The kind/value invariant is real, but it is neither
declared nor checked at the boundary where the value is read.

This was the direct cause of the unreadable generated expression that combined
`T.must(name_tok)`, `.value`, a string cast, and nested tuples.

### Recommendation

Add a small checked payload API to `Lexer::Token`, or to a parser-facing token
adapter. For example:

- `text!` for identifier and textual token kinds;
- `integer!` and `float!` where numeric payloads are stored as values;
- a deliberately named raw accessor only for the few grammar rules that truly
  accept multiple payload types.

The accessor must validate the token-kind/payload invariant and fail through a
normal compiler diagnostic or an internal invariant error. It must not silently
stringify arbitrary values.

The first implementation need not replace the lexer representation with a
large token class hierarchy. Centralizing the invariant is the high-value
step; a more precise lexer representation can be evaluated later.

### General compiler benefit

- One invariant check replaces scattered casts.
- Bad lexer/parser contracts fail near their origin.
- Token tests can cover the complete kind/value matrix.
- Parser call sites communicate intent instead of representation.
- Changes to token storage have one migration boundary.

### Ruby-to-CLEAR benefit

A checked `name_token.text!` call translates to one ordinary typed call. It
eliminates cascaded casts and prevents the transpiler from having to infer a
payload type from a token-kind test several expressions away.

## Refactor 2: retain declarative routing, remove the type-erasing rule executor

### Current problem

The parser-rule DSL currently represents rules with:

- `PatternStep#value: T.untyped`;
- `ParserRule#inject: T::Array[T.untyped]`;
- `PatternCapture`, a broad union of unrelated result types;
- `process_pattern`, which returns an array of captures;
- symbol-based `run_action` dispatch;
- action methods that read `args[0]` and `args[1]` positionally.

The routing tables are declarative, but the execution layer erases the types
of the values routed through them. The current fact data finds 29 positional
reads from these action argument arrays: 27 at index zero and two at index one.
That is a small enough surface to replace directly.

### Recommendation

Keep the statement, primary-expression, and suffix routing tables that map a
lookahead token to a grammar action. Replace the generic capture interpreter
with typed action entry points.

For the common one-capture operator rules, use a typed enum/helper whose input
and output are fixed. For rules with distinct shapes, call dedicated methods
with named parameters or let the method parse its own operands. Do not pass a
heterogeneous `Array[PatternCapture]` through a symbol dispatcher.

The end state should not need `PatternStep#value: T.untyped`, generic injected
values, or positional action arguments for parser construction.

### General compiler benefit

- Adding a rule produces a type-checked method contract.
- Missing and extra captures are found before runtime.
- Action coverage can be tested without exercising an untyped interpreter.
- Navigation from a routing entry to its implementation becomes direct.
- Grammar changes no longer require synchronized positional conventions.

### Ruby-to-CLEAR benefit

Static calls and typed arguments lower mechanically. Symbol reflection,
heterogeneous arrays, and runtime result unions require dynamic lowering or
large dispatch trees in CLEAR and obscure the actual grammar.

### Non-recommendation

Do not replace the parser with a parser generator as part of this work. The
current amount of declarative first-token routing is appropriate. The problem
is the type-erasing mini-interpreter underneath it, not the existence of Ruby
parsing methods.

## Refactor 3: replace record-shaped tuples with named parse results

### Concrete problem: struct literal fields

Both generic and non-generic struct-literal branches currently return this
shape from `parse_comma_seq`:

```ruby
[[T.must(name_tok).value, value], name_tok]
```

The caller then builds values with `fields.map(&:first).to_h` and separately
reconstructs the token map by destructuring the outer pair and reading
`kv.first`. This is an anonymous record with three semantic fields: field name,
field value, and the name token. Its two consumers interpret the positions
differently.

Introduce a result such as:

```ruby
class ParsedStructField < T::Struct
  const :name, String
  const :value, AST::Node
  const :name_token, Lexer::Token
end
```

Parse one list of these records and derive both `StructLit#fields` and
`StructLit#field_tokens` through named access. Share the field-list parser
between generic and non-generic struct literals.

If the two maps should always be produced together, a
`ParsedStructFields` result containing both typed maps is also reasonable. The
important point is that their relationship is constructed once, not recovered
from tuple positions twice.

### Other targeted candidates

Use the same test for other tuple replacements: does the tuple represent
multiple named semantic dimensions, especially dimensions with similar types?
`CapJoin`, with ownership, synchronization, layout, and lock-rank positions,
meets that test and should become a named result. A two-item helper result that
is immediately destructured and preserves precise generic types does not.

In particular, `parse_comma_seq` already preserves its element type and
returns a precise `[start_token, items]` pair. It is not itself a type-erasure
bug. Changing every such pair would add churn without addressing the observed
problem.

### General compiler benefit

- Field swaps become type or constructor errors rather than semantic bugs.
- Diagnostics stay attached to the value they describe.
- Callers are searchable by semantic field name.
- Tests can construct and inspect parser results without knowing positions.
- Duplicate generic/non-generic parsing logic can share a typed boundary.

### Ruby-to-CLEAR benefit

Named records translate directly to CLEAR structs. Anonymous nested tuples
followed by projection and hash reconstruction translate literally and produce
the unreadable code that prompted this review.

## Refactor 4: replace fixed-schema metadata hashes with typed records

### Current problem

Several aliases use hashes even though their keys form a closed schema:

- `SigilAttrs` contains dimension/value data, stack size, and boolean flags;
- `CapDims` carries ownership, synchronization, layout, and lock rank;
- `EffectMetadata` and `EffectsDecl` transport a fixed set of effect details;
- `WithMatchArm` appears to transport a fixed arm schema.

These are not ordinary lookup maps. A misspelled key, wrong value under a valid
key, or impossible combination is discovered only by the consumer.

### Recommendation

Replace fixed-schema values with `T::Struct` records having typed fields and
defaults. Keep genuine maps as maps. For example, `SigilTable` can remain a
`Hash[String, SigilAttrs]` while `SigilAttrs` becomes a record.

Follow the pattern already established by `CapabilityParseResult`,
`DoBranchPrefix`, and `BgPrefix` rather than introducing a new abstraction.
Only convert `WithMatchArm` after confirming its keys are a closed schema at
all construction sites.

### General compiler benefit

- Closed schemas become explicit and documented.
- Key spelling and value type are checked at construction.
- Defaults and legal absence are defined once.
- Records prevent partially initialized or contradictory metadata.

### Ruby-to-CLEAR benefit

CLEAR structs have stable field types and names. Heterogeneous fixed-key Ruby
hashes require dynamic value unions, key dispatch, and repeated casts.

## Refactor 5: make nilability truthful

### Current problem

NilKill now identifies nine parser methods whose declared result is nilable
although reachable successful returns are non-nil and failures raise:

- `parse`
- `consume`
- `parse_extern_fn`
- `parse_extern_struct`
- `parse_struct_def`
- `parse_union_def`
- `parse_function_def`
- `parse_sync_policy_block`
- `parse_do_block`

These findings should still receive a short public-boundary and error-path
review before their signatures change. They are distinct from genuinely
optional parsing operations such as `peek_at`, `try_parse_*`, or an optional
retry/error clause.

### Recommendation

Use nilability only when `nil` represents a reachable, meaningful parser
outcome such as absence or failed speculation. A method that returns a value or
emits an error should declare a non-nil result, and the error path should be
typed as non-returning where supported.

### General compiler benefit

- Callers do not need assertions for impossible absence.
- APIs distinguish “optional grammar” from “error terminates parsing.”
- Error-path edits cannot silently introduce an accidental nil return.

### Ruby-to-CLEAR benefit

Truthful results remove optional wrappers, `OR_ELSE` panic expressions, and
unnecessary flow narrowing from generated code.

## Refactor 6: make parser state scoped and exception-safe

### Current problem

The parser has legitimate mutable state, but some state transitions are
implemented as manual protocols:

- `@suppress_struct_lit` is set and later reset around nested parsing without
  an `ensure` and without restoring the prior value;
- speculative parsers save and restore `@pos` manually in several places;
- `@last_requires_clauses` is reset, populated by one parser, and consumed by
  another as a hidden return channel.

There is already a good local example: generic-angle lookahead restores
`@pos` in an `ensure`. The remaining transitions should adopt an equally
explicit abstraction.

### Recommendation

- Add `with_suppressed_struct_literals { ... }`, restoring the previous value
  in `ensure` so nested use is safe.
- Add a cursor checkpoint abstraction that restores by default and commits
  explicitly, or an equivalent `with_checkpoint` helper.
- Replace `@last_requires_clauses` with a `RequiresParseResult` that returns
  both requirement families and reentrance clauses to its caller.

Do not hide arbitrary parser state in a generic transaction object. Each
scoped helper should have a small, named responsibility.

### General compiler benefit

- Exceptions and parse errors cannot leak temporary state.
- Nested speculative parsing restores the correct prior state.
- A method's outputs are represented by its return type, not call ordering.
- State behavior can be tested independently with deliberate failure cases.

### Ruby-to-CLEAR benefit

Structured scope and explicit result records map to normal control flow.
Manual save/restore and hidden instance-variable channels require ownership and
mutation analysis across distant statements.

## Refactor 7: remove sentinel unions from parser control flow

### Current problem

Suffix parsing uses `SuffixResult = T.any(AST::Node, Symbol)` and a special
`SUFFIX_DECLINE` symbol to mean that an inline-union suffix does not apply. The
symbol is not semantic parser output; it is a control sentinel sharing a result
type with AST nodes.

### Recommendation

Separate applicability from construction. For example, test
`inline_union_variant_suffix?` first and have the corresponding parse method
return an `AST::Node`. If one-pass probing is required, use a named outcome
whose variants cannot be confused with source-language symbols.

### General compiler benefit

- Result types contain semantic values only.
- Exhaustiveness and error handling become explicit.
- A newly introduced symbol-valued grammar feature cannot collide with an
  internal sentinel protocol.

### Ruby-to-CLEAR benefit

The generated code no longer needs a union between an AST reference and a
symbol solely to encode local control flow.

## Refactor 8: treat parser-output AST properties as a typed phase interface

### Current problem

Some properties written by the parser and consumed by later compiler phases
are implicit or untyped transport channels. Concrete examples include:

- `AST::Program#language_mode`, written by the parser and read by the
  annotator;
- `AST::StructLit#field_tokens`, written by the parser and used for member
  diagnostics in the annotator;
- boolean-like properties such as `comptime` and `tight`, for which later
  phases defensively apply truthiness or compare with `true`.

This is not evidence for a broad “phase fact loss” detector. It is a direct AST
contract issue: values crossing compiler phases should have declared types and
defined defaults.

### Recommendation

Give these properties typed accessors or struct members and initialize their
defaults at node construction:

- a typed language-mode enum/symbol with an explicit default;
- `field_tokens: Hash[String, Lexer::Token]`, defaulting to an empty map;
- boolean fields defaulting to `false`, not nil/truthy state.

Audit only properties that are actually part of the parser-to-annotator/MIR
interface. Do not convert arbitrary temporary annotations without a concrete
producer and consumer.

### General compiler benefit

- The AST becomes an explicit phase ABI.
- Missing initialization is caught where a node is built.
- Later phases can remove defensive coercion.
- Tests can assert complete node construction rather than call-order effects.

### Ruby-to-CLEAR benefit

Typed fields with defaults translate directly. Dynamic accessors and
truthiness coercion otherwise force optional storage and repeated narrowing
through every generated phase.

## Refactor 9: decompose hotspots around typed grammar results

### Current problem

The largest and most difficult parser methods combine several responsibilities:
lookahead, token consumption, metadata collection, validation, error recovery,
and AST construction. The main candidates include:

- `parse_type_annotation`
- `parse_assert_raises`
- `parse_when_block`
- `try_parse_bind_or_assign`
- match statement/expression parsing
- `parse_function_def`
- `parse_extern_fn`
- `parse_cap_join`

Line count alone is not a sufficient reason to split a parser method. Splits
that merely move fragments into helpers can make grammar flow harder to follow.

### Recommendation

Create boundaries only where a stable typed grammar result exists:

- `parse_function_def`: parse a `ParsedFunctionHeader`, typed effects and
  requirements, then the body, then construct the AST node;
- type annotations: distinguish parsed type syntax from capability validation
  and application;
- assertion parsing: separate the assertion selector/header from body parsing;
- match parsing: use explicit arm results shared by expression and statement
  forms only where their semantics are actually identical;
- capability joins: accumulate into the named capability record proposed
  above, then validate once.

Keep token and source-span information in each intermediate so decomposition
does not degrade diagnostics.

### General compiler benefit

- Grammar subcontracts can be tested in isolation.
- Validation and construction changes have smaller blast radii.
- Error recovery stays attached to a named grammar unit.
- Method complexity falls because responsibilities change, not merely because
  lines move elsewhere.

### Ruby-to-CLEAR benefit

Smaller typed stages avoid translating enormous nested branches with shared
mutable locals. They also expose ordinary function calls and records to the
transpiler instead of forcing it to reconstruct implicit phase boundaries.

## Proposed implementation sequence

### Stage 0: lock the baseline

- Record parser message-pack/golden test results.
- Run Sorbet and the relevant compiler test suites.
- Preserve the current NilKill, FactMine, Decomplex, and Espalier reports as
  measurement baselines.
- Do not edit generated CLEAR manually.

### Stage 1: correct boundary contracts

- Add checked token payload accessors.
- Review and correct the nine false-nilable parser results.
- Type and initialize concrete parser-output AST properties.

This stage should remove many downstream assertions without changing grammar.

### Stage 2: introduce named parse records

- Replace the struct-literal nested tuples.
- Replace `CapJoin`/`CapDims`, effects, requirements, and confirmed fixed-schema
  metadata hashes.
- Share duplicate struct-literal field parsing.

### Stage 3: retire the type-erasing rule executor

- Convert the 29 positional action reads to typed entry points.
- Preserve declarative first-token routing.
- Remove broad captures, injected untyped values, and reflective symbol
  dispatch once their last callers are gone.

### Stage 4: scope parser state

- Add scoped struct-literal suppression.
- Centralize cursor checkpoints and commits.
- Return requires-clause data explicitly instead of using a side channel.

### Stage 5: decompose only the remaining measured hotspots

- Introduce typed grammar results for function headers, type syntax,
  assertions, matches, and capability joins.
- Re-run complexity and flow reports after each extraction; do not assume that
  a lower line count means a better design.

### Stage 6: regenerate and evaluate Ruby-to-CLEAR

- Re-run Ruby-to-CLEAR only after the source refactors and Ruby tests pass.
- Compare generated code with the prior cast-heavy output.
- Fix genuine, narrowly scoped transpiler or CLEAR autofix defects centrally.
- Do not compensate for remaining parser source slop in the transpiler.

Each stage should be split into small semantic commits. The parser message-pack
stage should remain green throughout so a refactor cannot silently change the
language.

## Validation requirements

The work is complete only when all of the following hold:

- Parser message-pack/golden stages pass without changed language behavior.
- Sorbet passes with fewer boundary assertions and no new `T.untyped` escape
  hatches.
- Identifier-like parser sites use the checked token API rather than raw
  `.value` casts.
- The reviewed false-nilable methods have truthful signatures.
- Struct-literal fields no longer use the nested pair representation.
- Closed metadata schemas use named records; real lookup tables remain hashes.
- Parser actions no longer exchange heterogeneous positional capture arrays.
- Temporary parser flags and cursor positions restore correctly on success,
  decline, and raised parser errors.
- Parser-to-annotator/MIR AST fields have declared types and defaults.
- Regenerated CLEAR no longer contains the nested cast/panic/tuple expression
  that triggered this review.

Targeted tests should cover:

- every checked token payload accessor, including a mismatched kind/value;
- action routing and action result types;
- speculative cursor rollback and explicit commit;
- nested struct-literal suppression and restoration after an error;
- struct-literal value/token pairing and duplicate-field diagnostics;
- capability/effect/default combinations in the new records;
- AST transport-field defaults and later-phase consumers.

## Explicit non-goals

- A wholesale parser rewrite or parser-generator migration.
- Treating every tuple, hash, union, or optional as a defect.
- Replacing `parse_comma_seq` merely because it returns a precise pair.
- Building a general tuple-shape recovery or phase-fact-loss analysis.
- Building false-union analysis to justify this work; no concrete parser case
  was found.
- Adding parser-specific inference heuristics to Ruby-to-CLEAR.
- Manually cleaning generated CLEAR before the Ruby source contracts are
  corrected.
- Changing grammar or language semantics as part of structural refactoring.

## Expected outcome

After these stages, the parser remains recognizably the same recursive-descent
parser with the same declarative routing and grammar. Its important differences
are that tokens expose checked values, parser helpers return named data, state
changes are scoped, and the AST boundary is typed.

That is the right prerequisite for Ruby-to-CLEAR: the transpiler can lower
ordinary records, calls, branches, and typed fields instead of rediscovering
parser conventions. It is also a materially better Ruby implementation—safer
to change, easier to test, easier to diagnose, and less dependent on hidden
knowledge held by callers.
