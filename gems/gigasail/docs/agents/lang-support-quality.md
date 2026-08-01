# Multi-Language Support Quality Pass

This pass spot checked the validation DBs created for Python, TypeScript, Go, Lua, C, C++, C#, Java, Swift, and Kotlin. The goal was not to prove feature parity with Ruby, but to verify that Gigasail can ingest and display useful SARIF/coverage/risk evidence for each language, and to fix clear cross-language false positives found during review.

## Quality Checklist

- Gigasail DB exists and UI serves the repository.
- SARIF artifacts ingest into `sarif_findings` with stable paths and line anchors.
- Decomplex findings include enough detector-specific context to be actionable.
- Nil-kill static pressure findings do not flag obviously typed or non-null constructs as loose contracts.
- SlopCop and Boobytrap produce useful output when coverage/churn exists, and degrade clearly when coverage is absent.
- Espalier emits architecture facts where class/function ownership extraction is mature.
- Native lint SARIF is ingested when the local toolchain can produce it.
- Runtime or hazard evidence is present for languages where support currently exists.

## Fixes From This Pass

- Decomplex SARIF messages now include detector-specific payloads for the major findings. For example, Rich `console.py` now shows `Derived-State Staleness: max_height derived from size at line 995; size reassigned at line 996 but max_height is not recomputed` instead of only naming the method.
- Decomplex suppresses generated Lua/Teal `_tl_compat` compatibility prelude branches. LuaRocks no longer reports line-1 generated prelude missing-abstraction findings.
- Decomplex extracts Go `name type` struct field declarations, so fields like `I16 []int16` keep their type.
- Nil-kill no longer treats Python `-> None` as nullable pressure by itself. `str | None`, `None | str`, `Optional[...]`, `null`, and `undefined` still count.
- Nil-kill Go static evidence now preserves typed struct fields through to SARIF; fzf no longer reports `Slab#I16` as an untyped field.
- Nil-kill static evidence now consumes Decomplex Tree-sitter facts for Lua, Rust, Zig, C, C++, C#, Go, Java, Kotlin, and Swift through language providers instead of Ruby-specific extraction.
- Nil-kill preserves collision-free `state_type_records`, `state_protocol_records`, and `state_param_origin_records` so same owner/field names in different languages do not overwrite each other.
- Decomplex Tree-sitter node facade traversal is lazy/cached and nil-kill static fact walks are iterative, avoiding eager full-tree O(n) child indexing per Tree-sitter operation.

Regression tests added:

- `gems/decomplex/test/syntax_test.rb`: Lua generated prelude suppression and Go name-type struct fields.
- `gems/decomplex/test/report_test.rb`: actionable SARIF messages for derived-state staleness and broken protocols.
- `gems/nil-kill/spec/multi_language_runtime_spec.rb`: Python `-> None` nullable handling, Go typed struct field evidence, and Decomplex-backed nil-kill static facts for Lua, Rust, Zig, C, C++, C#, Go, Java, Kotlin, and Swift.

## Current Validation DBs

All UI servers responded with HTTP 200 on ports `8081` through `8090` after SARIF reingest and UI summary refresh.

| Language | Repo | Port | Logical Units | SARIF Artifacts | SARIF Findings | Coverage Lines | Quality Events |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Python | Rich | 8081 | 2,152 | 6 | 6,905 | 7,792 | 1,022 |
| TypeScript | Zod | 8082 | 2,437 | 6 | 8,246 | 8,908 | 1,365 |
| Go | fzf | 8083 | 1,421 | 7 | 13,219 | 16,422 | 608 |
| Lua | LuaRocks | 8084 | 1,043 | 6 | 5,731 | 0 | 0 |
| C | libuv | 8085 | 3,920 | 6 | 30,310 | 0 | 0 |
| C++ | fmt | 8086 | 6,014 | 6 | 5,120 | 0 | 0 |
| C# | Serilog | 8087 | 615 | 6 | 1,524 | 0 | 0 |
| Java | Gson | 8088 | 4,921 | 6 | 3,542 | 0 | 0 |
| Swift | Argument Parser | 8089 | 1,938 | 6 | 1,129 | 0 | 0 |
| Kotlin | Okio | 8090 | 3,357 | 6 | 2,243 | 0 | 0 |

Swift and Kotlin SARIF reingest skipped two non-SARIF JSON evidence files in each `tmp/gigasail-sarif` directory. That is expected because the ingest command accepts directories and ignores JSON files that are not SARIF documents.

## Nil-kill Static Evidence Spot Check

Static evidence was generated through `NilKill::StaticEvidence.build` with Tree-sitter grammars loaded from local `node_modules`. Output files were written under `/tmp/nil-kill-static-spots`. These timings were collected after the lazy Tree-sitter facade and iterative nil-kill fact walk changes, using full repository roots unless noted.

| Language Focus | Repo / Target | Time | Files | Methods | Fields | State Type Records | Protocol Records | Param-Origin Records | Parsed Languages |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| Ruby | `gems/nil-kill` | 19.254s | 95 | 1,765 | 288 | 14 | 426 | 87 | Python, Ruby |
| Python | Rich | 16.773s | 213 | 1,792 | 496 | 68 | 211 | 470 | Python |
| TypeScript | Zod | 36.036s | 405 | 1,143 | 113 | 15 | 94 | 12 | JavaScript, TypeScript |
| Lua | LuaRocks | 11.602s | 172 | 1,008 | 20 | 17 | 12 | 2 | C, C++, Lua |
| Rust | `gems/gigasail` | 14.192s | 19 | 772 | 701 | 701 | 121 | 0 | JavaScript, Ruby, Rust |
| Zig | `zig/` | 39.656s | 279 | 2,907 | 2,289 | 2,228 | 1,422 | 178 | C++, Zig |
| C | libuv | 31.700s | 368 | 3,249 | 1,201 | 961 | 590 | 0 | C, JavaScript, Python |
| C++ | fmt | 37.257s | 77 | 3,291 | 322 | 306 | 112 | 12 | C, C++, JavaScript, Python |
| C# | Serilog | 7.727s | 216 | 1,382 | 439 | 439 | 148 | 0 | C# |
| Go | fzf | 20.238s | 90 | 1,358 | 848 | 808 | 733 | 26 | Go, Ruby |
| Java | Gson | 14.725s | 262 | 3,041 | 1,071 | 1,071 | 73 | 23 | Java |
| Kotlin | Okio | 21.500s | 351 | 4,094 | 549 | 535 | 1,161 | 17 | C, Java, Kotlin |
| Swift | Argument Parser | 7.743s | 165 | 977 | 2,192 | 1,559 | 473 | 0 | Swift |

Spot checks of the generated JSON confirmed anchored facts for representative real code:

- Go/fzf: `Slab.I16 []int16` and `Slab.I32 []int32` are typed fields; Go methods carry params and signatures.
- Java/Gson: `Gson#getAdapter`, `GsonBuilder#setDateFormat`, and `Gson` typed fields are anchored with Java signatures, protocols, and param origins.
- Kotlin/Okio: `Segment#limit`, `Segment#prev`, `Buffer#offset`, and `FakeFileSystem` state/protocol records are anchored to Kotlin files.
- Swift/Argument Parser: `ArgumentSet` methods, typed fields, and collection protocols are anchored to Swift source.
- Rust, Zig, C, C++, C#, Lua, Python, TypeScript, and Ruby outputs were spot checked for non-empty methods/fields and language-specific protocol/origin records where the language adapter emits them.

## Language Findings

### Python / Rich

Status: good.

The strongest path is covered: Gigasail DB, Decomplex, Nil-kill, Espalier, SlopCop, Boobytrap, native lint, coverage, quality events, and one runtime stack-trace smoke event all ingest. Rich is the best multi-language validation target after CLEAR Ruby because it has meaningful Python type annotations and coverage.

Spot checks:

- Decomplex state-branch and derived-state findings now include state refs, predicates, and stale variable/source details.
- Nil-kill nullable signatures now avoid false positives for plain `-> None`, while still flagging real nullable params/returns.
- SlopCop and Boobytrap findings are anchored to real coverage/churn data.
- Native lint SARIF from Black is visible and path-anchored.

Remaining caveat: test/example files are included in the validation DB. That is useful for ingestion coverage, but production review should use source-role filtering in Gigasail.

### TypeScript / Zod

Status: good, with test-file noise.

TypeScript SARIF ingestion, coverage, Decomplex, Nil-kill, Espalier, SlopCop, and Boobytrap all produce anchored findings. Decomplex points at real large schema/parser functions and TypeScript annotations feed Nil-kill static pressure.

Spot checks:

- Decomplex state-branch density on Zod parser paths includes concrete `_def`/schema refs and predicates.
- Nil-kill flags `unknown`/`any`-style slots without requiring runtime tracing.
- SlopCop and Boobytrap coverage/churn rows ingest correctly.

Remaining caveat: broken-protocol and Boobytrap rows in test suites are noisy. This is mostly a source-role/ranking issue, not a TypeScript parser failure.

### Go / fzf

Status: good.

Go has the best non-Ruby systems-language story in this pass. Gigasail ingests coverage, SlopCop coverage gaps, Boobytrap risk, Decomplex, Nil-kill static facts, and Go concurrency hazard SARIF.

Spot checks:

- SlopCop Go constraint SARIF flags channel and lock/sync hazards lacking race coverage.
- Decomplex identifies large terminal/control-flow functions with convergence across several detectors.
- Nil-kill now preserves typed struct fields such as `Slab.I16 []int16`, removing a concrete false positive.

Remaining caveat: Go hazard support is currently concurrency-focused. Other safety categories need explicit language rules if we want broader Go systems checks.

### Lua / LuaRocks

Status: usable static ingestion, experimental analysis quality.

Gigasail DB and SARIF ingestion work. Decomplex produces useful Lua findings after generated Teal prelude suppression. Nil-kill and Espalier are sparse, which matches the current maturity of Lua ownership/type extraction.

Spot checks:

- Generated `_tl_compat` prelude line-1 missing-abstraction findings are gone.
- Real Lua findings remain, e.g. repeated guard tuples and state-branch predicates.
- SlopCop/Boobytrap rows exist but are static/no-coverage quality because no Lua coverage was available.

Remaining caveat: Lua needs better function ownership and module/type conventions before Espalier and Nil-kill can be more than light static signals.

### C / libuv

Status: strong SARIF ingestion, experimental analysis quality.

Gigasail handles the large libuv DB and ingests Decomplex, SlopCop, Boobytrap, Nil-kill, Espalier, and syntax-lint SARIF. Decomplex results are plentiful and anchored.

Spot checks:

- Decomplex state-branch density points at real C state/predicate-heavy files like `src/win/pipe.c`.
- SlopCop/Boobytrap can rank paths, but no coverage was generated in this environment.
- Native syntax lint catches environment/header availability issues. Those are useful as toolchain diagnostics, not code-quality verdicts.

Remaining caveat: C has no coverage here, and C header/platform conditionals create noisy lint results unless the native build environment is configured.

### C++ / fmt

Status: strong SARIF ingestion, experimental analysis quality.

Gigasail ingests fmt SARIF and the UI handles template-heavy headers. Decomplex and Nil-kill produce anchored findings; Espalier has limited but nonzero ownership extraction.

Spot checks:

- Decomplex findings are anchored in headers and bundled tests.
- Nil-kill nullable findings around pointer/time APIs are plausible.
- Native C++ syntax lint found module/toolchain issues.

Remaining caveat: bundled third-party/test code is included, so production review needs source-role filtering. C++ templates and macros need more language-specific tuning before high confidence architecture claims.

### C# / Serilog

Status: usable static ingestion, moderate Decomplex signal.

SARIF ingestion works and Decomplex points at real branch-heavy formatting/parsing code. Nil-kill nullable signature findings map well to C# nullable-style APIs.

Spot checks:

- Decomplex state-branch findings include concrete property names and predicates.
- Nil-kill nullable signature findings are plausible in Serilog configuration APIs.
- SlopCop/Boobytrap are static/no-coverage quality because coverage was unavailable.

Remaining caveat: Espalier emitted no findings in this validation pass, so C# architecture extraction needs more work before it can be relied on.

### Java / Gson

Status: usable static ingestion, moderate Decomplex/Espalier signal.

Java SARIF ingestion works. Decomplex, Nil-kill, Espalier, SlopCop, and Boobytrap all produce anchored findings, with Decomplex pointing at real parser/adapter complexity.

Spot checks:

- Decomplex state-branch density in `TypeAdapters` and `JsonReader` has meaningful refs/predicates.
- Espalier emits read-only function facts for immutable-style value methods.
- Nil-kill untyped fields/methods are plausible where generic/reflection-heavy Java code defeats simple extraction.

Remaining caveat: no Java coverage or native lint was available in this environment, so risk ranking lacks coverage-backed confidence.

### Swift / Argument Parser

Status: usable static ingestion, experimental analysis quality.

Gigasail DB and SARIF ingestion work. Decomplex and Espalier produce anchored Swift findings; Nil-kill static evidence ingests. SlopCop is empty because no coverage was generated.

Spot checks:

- Decomplex state-branch density in completion generation includes Swift option/subcommand predicates.
- Espalier has limited read-only function extraction.
- Nil-kill static untyped signatures are present where generic Swift inference is not yet mature.

Remaining caveat: Swift needs coverage ingestion and better function/owner extraction before architecture metrics should be treated as strong signal.

**Root cause found and fixed (2026-07-21):** minimal-fixture validation (a
6-line `struct Widget { var count: Int; init(...) { ... }; mutating func
increment() { ... } }`, not a repo clone) confirmed `init` was dropped from
`function_defs` entirely - `fact_mine_rust::syntax::parse_files` on this
fixture returned only `increment`, never `init`. Since constructors are
where most instance state gets initialized, this also underrepresented
Swift's real state-write edges (the CLI spot check that found this saw 1
edge produced vs 4 for an equivalent C# class). Root cause: Swift's `init`
has no separate "function" keyword (raw tree-sitter kind
`init_declaration`, distinct from `function_declaration`), so the
extractor's function-kind recognition never matched it. Fixed by widening
`SwiftAstAdapter::function_kind`
(`gems/fact-mine/src/ast/adapters/swift.rs`) to include
`init_declaration`. Verified against real, unmodified production code, not
just the fixture: re-running Espalier over
`swift-argument-parser/Sources/ArgumentParser/` (shallow clone, not
committed to this repo) found **147 real `init` declarations** now
correctly recognized as functions across the codebase, and the existing
`gems/fact-mine` oracle fixture for Swift (`examples/syntax-facts/oracles/
swift-core.json`) updated to reflect `sink`/`status` writes now correctly
attributed to `init` instead of the wrong `"(top-level)"`. Regression test:
`gems/fact-mine/tests/architecture_extraction_multilang_test.rs`
(`swift_init_is_recognized_as_a_function`).

### Kotlin / Okio

Status: usable static ingestion, moderate Decomplex signal.

Kotlin DB and SARIF ingestion work. Decomplex has useful findings in buffer/filesystem code, and Espalier emits a small set of function facts. Nil-kill static findings are anchored.

Spot checks:

- Decomplex state-branch density in `Buffer.kt` includes concrete buffer/segment refs and predicates.
- Espalier identifies some read-only/impure functions.
- Nil-kill untyped signatures point at equality/select APIs where extraction needs stronger Kotlin typing rules.

Remaining caveat: no coverage was generated, SlopCop is empty, and Kotlin parser extraction needs more language-specific tuning before architecture metrics are high confidence.

**Root cause found and fixed (2026-07-21):** minimal-fixture validation (a
5-line `class Widget(private var count: Int) { fun increment() { count +=
1 } }`, not a repo clone) confirmed why: Kotlin's `AstNormalizationAdapter`
(`gems/fact-mine/src/ast/adapters/kotlin.rs`) had no handling for
primary-constructor-declared properties - the single most idiomatic way
Kotlin declares instance state. The raw tree-sitter `class_parameter` node
never got recognized as a field/property declaration, so no
`StateDeclaration` was ever produced for it, and `count += 1` inside a
method produced zero state-write edges. This was likely the dominant cause
of Kotlin's "sparse" architecture signal, more than general parser
immaturity.

Root cause: `class_parameter` is a child of `primary_constructor`, which
is a *sibling* of `class_body` in tree-sitter-kotlin's grammar - not a
descendant of it - so it was structurally invisible to the class-body scan
regardless of any per-language field-detection logic. Fixed via a new
opt-in `AstNormalizationAdapter` hook, `supplementary_class_body_nodes`
(`gems/fact-mine/src/ast/adapters/base.rs` + `normalize_class` in
`ast/normalizer.rs`), that folds extra raw nodes into a class's scanned
body before the existing field-collection walk runs. It defaults to
returning nothing for every language (zero behavior change for anyone but
Kotlin) and is overridden in `gems/fact-mine/src/ast/adapters/kotlin.rs` to
surface `var`/`val` primary-constructor parameters specifically. Kotlin's
pre-existing `state_declaration_from_node` text heuristic
(`gems/fact-mine/src/syntax/kotlin.rs`) then picks the resulting node up
unchanged - no changes needed there.

Verified against real, unmodified production code, not just the fixture:
`Pipe(internal val maxBufferSize: Long)` in Okio's own
`okio/src/jvmMain/kotlin/okio/Pipe.kt` (shallow clone, not committed to
this repo) now correctly produces a `state` node for `maxBufferSize`
owned by `Pipe`, and a broader sweep of Okio's `commonMain/kotlin/okio/`
directory found 51 owners, 83 states, and 667 functions (state extraction
was near-zero for this style of declaration before the fix). Regression
test: `gems/fact-mine/tests/architecture_extraction_multilang_test.rs`
(`kotlin_primary_constructor_property_is_recognized_as_state`). C# and Lua
were also validated with equivalent minimal fixtures in the same test file
and found to already work correctly - architecture extraction was not
broadly broken for those two.

## Cross-Cutting Assessment

The common ingestion path is solid: all ten DBs load, SARIF artifacts persist, UI summaries refresh, and servers respond. Decomplex is the most broadly useful analyzer across all languages because Tree-sitter extraction gives it enough syntax to anchor complexity findings.

The biggest quality divider is coverage. Python, TypeScript, and Go have coverage-backed SlopCop/Boobytrap signal; the other seven languages currently have static-only or churn-only risk, which should be presented as lower confidence.

Nil-kill is useful for Python, TypeScript, Go, C#, Java, Swift, and Kotlin static pressure, but language-specific type extraction determines signal quality. The Go struct-field and Python `-> None` fixes show the right pattern: false positives should be fixed in the shared syntax/provider layer with regression tests, not tuned per repository.

Espalier is useful where class/function ownership extraction is mature. It is sparse for Lua, C, C#, and Swift/Kotlin compared with Ruby/TypeScript/Go/Java. Treat missing Espalier signal in those languages as adapter immaturity, not proof of good architecture.

## Recommended Next Work

- Add source-role filtering in Gigasail views and ranking so `src`/production findings can be reviewed separately from tests, examples, vendored code, and generated code.
- Add explicit generated/vendor detection to the shared source filter for common language artifacts.
- Improve C/C++ native build-aware lint/coverage collection; static parser output alone is not enough for high-confidence systems-language review.
- Add coverage ingestion recipes for Lua, C#, Java, Swift, and Kotlin validation repos.
- Continue adding language-specific ownership/type extraction only when a spot check finds a concrete false positive or missing high-value signal.

## Second Validation Round (2026-07-21): Mini-Corpus Audit and Fixes

Following the first pass above, a second round audited Espalier/Decomplex
output against the `gems/gigasail/docs/agents/cross-lang-support.md`
mini-corpus repositories (already on disk, real production code, not
synthetic fixtures) across all eight of those languages plus a systemic
Decomplex issue. Every language produced at least one real, verifiable bug
- not vague noise. All fixes below are in `gems/fact-mine` (the shared
extraction layer every analyzer consumes) or `gems/decomplex`, are covered
by regression tests, and were re-verified against the real repository that
surfaced them after fixing.

### Fixed and verified

- **Decomplex `derived-state-staleness` (systemic, cross-language):** three
  distinct root causes in `fact-mine`'s shared dataflow scanner
  (`src/syntax/local_flow.rs`) were each independently rediscoverable in a
  different language - a bare co-declared variable with no initializer of
  its own misread as a *read* of its declaration statement (C, `wrk`); an
  empty-init `for (; cond; step)` loop's condition-only reads misattributed
  as writes (C, `wrk`); a call whose receiver starts with `self.`/`this.`
  misread as a state write because of a keyword argument's `=` (Python,
  `requests`). Verified eliminating the exact reported false positives in
  `wrk` (4→0) and `cJSON` (1→0), with `requests` down from 9→7 (one
  distinct fourth root cause - nested attribute mutation, `self.a.b = x`
  misattributed to `self.a` - remains open, not reproduced cleanly within
  budget).
- **Kotlin:** primary-constructor properties (`class Widget(private var
  count: Int)`) produced zero state declarations - `class_parameter` is a
  child of `primary_constructor`, a *sibling* of `class_body`, structurally
  unreachable by the class-body scan. Fixed via a new opt-in
  `AstNormalizationAdapter` hook, `supplementary_class_body_nodes`
  (defaults to a no-op for every other language).
- **Swift:** `init` was dropped from `function_defs` entirely (`init` has
  no separate "function" keyword in the grammar). Fixed by widening
  `function_kind`. Verified: 147 real `init`s recognized across
  `swift-argument-parser`.
- **TypeScript:** constructor-parameter properties had the same bug as
  Kotlin, but for a different structural reason - the constructor is a
  normal class member (reachable), but parameter normalization
  (`normalize_parameter_init`, shared/generic) discards modifier/type
  structure before the syntax layer ever runs. Fixed by reusing
  `supplementary_class_body_nodes` to re-supply the raw parameter nodes
  through the structure-preserving generic normalization path instead.
  Separately, `abstract class Foo` was dropped as an owner entirely
  (distinct grammar node, not `class_declaration`) - fixed by widening
  `class_node`. Verified on real Zod (`ZodType`, its core abstract base
  class, now recognized) and a minimal DI-container reproduction.
- **Go:** (1) any struct with an `interface{}`-typed field *anywhere in its
  body* was classified as an interface itself (substring search over the
  whole declaration, not just its own header) - fixed by truncating the
  search to the header before the first `{`. (2) function signatures
  truncated mid-word at any `interface{}` parameter (same "first brace"
  assumption, applied to signature-header truncation) - fixed with a
  paren-depth-aware brace finder. (3) embedded fields (`type Embedded
  struct { Basic; Vunique string }`) vanished from state extraction
  entirely - an anonymous embed has no separate name token, so neither
  `state_declaration_from_node`'s LVAR-name lookup nor
  `field_name_from_declaration` (unset for Go) had anything to find; fixed
  by deriving the name from the embedded type reference itself. Verified
  on real `mapstructure`: `DecoderConfig` no longer misclassified,
  `Decode`/`decodeSlice` signatures now complete, `Embedded`/
  `EmbeddedPointer`/`EmbeddedAndNamed` all correctly capture their embedded
  fields.
- **Java:** the state-declaration text heuristic had no node-type guard at
  all (every other language's version restricts to
  `FIELD_DECLARATION`-shaped nodes) - any node whose text loosely resembled
  `word word ... = ...` matched, including comments (`// TODO this seems
  wrong` parsed as a field literally named `wrong`). Fixed by adding the
  same guard other languages already have. Verified: 0 comment-derived
  bogus states remain in `commons-cli` (previously ~14). A second, distinct
  Java issue - fields with initializers missing at their real declaration
  line, appearing instead as a phantom duplicate at the corresponding
  setter's assignment line - was confirmed still present and is not yet
  root-caused.
- **C#:** a field whose initializer contains no literal `{` at all
  (`static readonly Lazy<T> _x = new Lazy<T>(GetAllOptions,
  LazyThreadSafetyMode.ExecutionAndPublication);`) was never truncated by
  the existing brace-based name search, so it read past the field's own
  name into the initializer and returned its trailing identifier instead.
  Fixed by truncating at the declarator's own `=` first. This turned out
  to be broader than the reported case: *any* C# field with a plain
  literal initializer (`int x = 1;`) was silently producing zero state
  declarations at all before this fix, not just a garbled name - confirmed
  via a corrected `type_metadata/csharp` oracle fixture. Verified on real
  `SmartEnum.cs`: all four `Lazy<T>` fields now keep their own names.

### Found, not yet fixed

- **C:** Espalier's owner-fallback heuristic fabricates a bogus "owner"
  node (confidence: partial) for the majority of real functions in both
  `cJSON` and `wrk` - traced to Espalier's own Ruby architecture-building
  layer (`gems/espalier/lib/espalier/architecture_artifact.rb` and
  whatever upstream analyzer synthesizes these pseudo-owners), not
  `fact-mine`'s extraction - a separate investigation domain from the
  Rust-side fixes above, not yet started.
- **C++:** operator overloads (`operator=`, `operator()`, `operator
  bool`) extract the wrong token as the function name (the parameter name
  or return type instead of the operator); template specializations split
  into a clean-named empty owner plus an angle-bracket-garbled owner
  holding all real methods; macro tokens before a class name (visibility
  macros) create phantom owner nodes, and in one case (plog's `Logger`)
  swallow all of the real class's methods entirely.
- **JavaScript:** object-literal "instance" state detection only catches
  fields set via direct assignment (`obj.x = value`) - misses
  increment-mutated (`res.lastId++`), method-mutated (`.unshift()`), and
  init-only fields on the same object.
- **Python:** (1) `self.x: Type = value` (annotated) produces *two* state
  nodes (`x` and `@x`) instead of one, at a ~48% duplication rate in one
  sampled repo. (2) `Enum`/`IntEnum` member values produce zero state
  nodes at all.
