# Parser Type-Slop Assessment

## Decision

`compiler/ruby/ast/parser.rb` is not ready to be used as the source of a
readable Ruby-to-CLEAR translation. The parser is valid Ruby and much of its
complexity is intrinsic to a language parser, but several source contracts
erase facts that CLEAR needs. Translating those contracts literally produces
large casts, nested tuple casts, optional checks that cannot execute, and
dictionary-shaped records whose fields must be rediscovered during emission.

Do not repair these symptoms in generated CLEAR. Clean the Ruby contracts in a
separate parser-focused branch, then regenerate. This assessment deliberately
does not modify parser source.

## Evidence Collected

The assessment covered `parser.rb` plus its direct AST, lexer, type, diagnostic,
and fixable-helper dependencies. All graph-backed tools used the same FactMine
facts.

| Tool | Material result | Interpretation |
|---|---:|---|
| Decomplex | 350 convergence methods, 165 root clusters, 66 decision-pressure findings | The largest parser methods are credible decomposition targets; this is ranking evidence, not proof that every branch is accidental complexity. |
| Decomplex | `ClearParser` temporal score 361 over 8 owner fields | Parser position and mode transitions need explicit phase/state contracts before mechanical translation. |
| Espalier | 182 functions, 8 state slots, 1,801 delegation edges, owner pressure 836.95 | Owner/state attribution is now credible. The parser is a large stateful coordinator, not a collection of isolated functions. |
| Espalier | 649 architecture nodes and 1,964 edges | Most apparent external receivers are dependencies, not parser-owned state. |
| Nil-kill | 9 high-confidence false-nilable return signatures | Declared return types disagree with non-nil return flow and should be tightened in Ruby. |
| Nil-kill | 2 genuinely redundant nil guards in the reviewed sources | `current.nil?` and a non-nil declaration safe-navigation site are source-contract issues, not transpiler workarounds. |

The nine return signatures identified by static flow are `parse`, `consume`,
`parse_extern_fn`, `parse_extern_struct`, `parse_struct_def`, `parse_union_def`,
`parse_function_def`, `parse_sync_policy_block`, and `parse_do_block`. Each must
still be reviewed at its public boundary before changing the signature, but the
tool now provides a concrete, high-confidence action instead of merely counting
nil checks.

The highest-ranked parser methods include `parse_type_annotation`,
`parse_assert_raises`, `parse_when_block`, `try_parse_bind_or_assign`, the match
statement/expression parsers, `parse_function_def`, `parse_extern_fn`, and
`parse_cap_join`. These are the first places to split parsing, validation, and
node construction when source cleanup begins.

## Confirmed Source Problems

### 1. Broad token values cross textual parser boundaries

`Lexer::Token#value` legitimately represents strings, numbers, and nil. The
problem is not that the lexer union exists; it is that parser routines which
require an identifier or keyword repeatedly consume the broad field and recover
`String` using `T.must` and `T.cast`. That directly creates unreadable CLEAR such
as casts nested inside tuple casts.

The source-level repair is a small typed token API (`string_value`,
`identifier_value`, or an equivalent checked accessor) used at the boundary.
The accessor must fail with the parser's normal diagnostic when the token kind
does not carry text. It must not silently stringify numeric values.

### 2. Generic sequence parsing erases element and tuple shape

`parse_comma_seq`-style helpers return values whose precise element type is
known by the caller but lost in the helper contract. Call sites then destructure
and cast the result. A typed result object or a small number of domain-specific
sequence helpers would preserve the relationship between values, tokens, and
separators. This is preferable to teaching Ruby-to-CLEAR to reproduce nested
Sorbet casts.

### 3. Hashes are being used as heterogeneous records

The following aliases have stable, named slots but are represented as hashes or
wide nullable unions:

- `EffectMetadata` / `EffectMetadataValue`
- `ElementCapability`
- `WithMatchArm` / `WithMatchArmValue`
- `SigilAttrs` / `SigilTable`
- `CapDims`

These should be reviewed for `T::Struct` or another explicit record type.
Presence, field type, and defaults then survive into CLEAR without key-based
recovery. This is a targeted recommendation; ordinary homogeneous lookup tables
should remain hashes.

### 4. Some aliases combine unrelated domain states

`PatternCapture`, `ReturnLifetime`, and several match/capability aliases admit
many unrelated variants and nil. Their consumers commonly branch on both type
and sentinel meaning. Split these into named result types or tagged variants
where the states are semantically distinct. Do not mechanically replace every
`T.any`: narrow, closed AST unions can be appropriate.

### 5. Nilable collections encode two states where one often suffices

The reviewed parser contains nilable arrays for union-method requirements and
default bodies. In this codebase an empty collection is normally the correct
absence representation. Review each site and retain nil only if it represents a
third state distinct from both "not initialized" and "initialized but empty."
This is source design work; CLEAR optional syntax must not be changed to conceal
it.

### 6. Proven non-nil values are checked or declared nilable

`current` returns a required `Lexer::Token`, yet a caller checks
`current.nil?`. Nil-kill also proves nine return signatures broader than their
flow. These contracts make downstream narrowing and call resolution harder and
should be corrected in Ruby after call-site review.

### 7. Parser state and phases are implicit

Espalier identifies exactly eight `ClearParser` fields:
`gradual`, `gradual_mode`, `last_requires_clauses`, `ownership_mode`, `pos`,
`source_code`, `suppress_struct_lit`, and `tokens`. Position and temporary mode
flags are mutated across a very large call graph. Scoped mode helpers and
explicit parse-result records would make save/restore obligations visible. The
analysis does not justify turning external receiver fields into parser state.

### 8. Dynamic diagnostic helpers leak untyped operations inward

`source_error.rb`, `fixable_error.rb`, and `fixable_helpers.rb` use dynamic
dispatch and `T.unsafe` around heterogeneous diagnostic objects. Some reflection
is legitimate at an adapter boundary, but parser-facing methods should expose a
typed diagnostic protocol. Keep unavoidable reflection in the helper boundary
rather than propagating it through parsing code.

## Tool Defects Found and Corrected

The assessment exposed tool defects before source findings were trusted:

- FactMine previously promoted mutations through arbitrary local receivers to
  owner state. Receiver ownership is now normalized generically, while concrete
  receiver spellings remain in language adapters.
- External receiver reads/writes are no longer counted in Decomplex or Espalier
  owner-state metrics.
- FactMine now propagates declared return types through branches whose other
  path calls a `noreturn` function. This enabled Nil-kill to prove the parser's
  false-nilable returns.
- FactMine now expands declared type aliases recursively before nil-flow
  reasoning. Nilable aliases no longer produce false dead-nil diagnostics.
- Ruby `Module#name` is modeled as nilable in the Ruby syntax adapter. Generic
  flow analysis no longer marks `self.class.name&.` as dead navigation.
- Nil-kill preserves structured declared return types and emits a
  language-neutral `fix_sig_return` action when a nilable declaration has a
  strong non-nil return origin.
- Espalier's direct static-evidence load path now initializes its shared root
  constant without duplicate-constant warnings or load-order failure.

Regression tests cover each corrected fact boundary. FactMine's architecture
suite additionally enforces that type grammars and other language semantics do
not migrate into generic analysis.

## Missing Analyzer Capabilities

The current tools find flow and structural pressure, but they do not yet model
all of the type slop that matters to translation.

### FactMine: emit structured declaration-pressure facts

FactMine should derive language-neutral facts from its normalized `TypeExpr`:

- union width and nested union width;
- untyped/unknown leaf count;
- nilability and nilable-collection shape;
- collection nesting depth;
- stable hash-key use that suggests a record;
- casts or assertions immediately following a typed boundary;
- result-shape erasure across helper calls.

Only parsing Sorbet spelling belongs in Ruby language modules. The facts above
operate on normalized type trees and therefore belong in shared FactMine passes.

### Nil-kill: own optionality and contract contradictions

Nil-kill should consume those type facts and report:

- a nilable collection initialized and consumed identically to an empty one;
- nilable returns whose paths are all non-nil;
- non-nil parameters or locals guarded for nil;
- safe navigation on proven non-nil values;
- optionality introduced only by a broad alias.

Only the first item needs a cautious recommendation rather than an automatic
edit: nil can represent a meaningful third state.

### Decomplex: rank type-driven complexity without parsing Ruby

Decomplex currently reports no fat unions for this corpus because its detector
is driven by dispatch shape rather than declared type trees. It should consume
FactMine's normalized declaration-pressure facts and combine them with branch,
fan-in, and state pressure. It must not recognize `T.any`, `T::Hash`, or any
other language spelling itself.

### Espalier: expose architectural concentration

Espalier should aggregate generic pressure facts by owner, helper boundary, and
phase. Useful additions are cast concentration across an edge, untyped values
crossing owner boundaries, record candidates used by multiple phases, and state
slots whose writes span unrelated parser phases. Espalier should not decide
whether a Ruby alias is good or bad.

## Recommended Source-Cleanup Order

1. Add typed token accessors and replace repeated textual `T.cast`/`T.must`
   chains.
2. Correct the proven false-nilable signatures and redundant nil guards after
   checking callers.
3. Replace heterogeneous metadata hashes with named records.
4. Remove nilable collections where nil has no distinct meaning.
5. Replace erased generic parse results with typed result records.
6. Split only the highest-pressure methods where parsing, validation, and AST
   construction can form stable boundaries.
7. Rerun Sorbet and parser/message-pack tests, then regenerate CLEAR once.

Do not interleave manual CLEAR cleanup with these changes: regeneration would
discard it, and the source contracts would continue producing the same slop.

## Completion Criteria Before Transpilation

The parser is ready for another Ruby-to-CLEAR attempt when:

- identifier/name consumers no longer cast the raw token union repeatedly;
- all high-confidence false-nilable return actions have been resolved;
- each remaining nilable collection documents a distinct nil state;
- stable heterogeneous metadata has named fields;
- the worst generic parse-result casts are gone;
- FactMine emits no known false owner-state or nil-flow facts for the corpus;
- Sorbet and the parser's message-pack stage pass before generation.

At that point remaining failures should be classified one by one as a small
Ruby-to-CLEAR lowering defect, a CLEAR autofix opportunity, or a genuinely
manual translation decision.
