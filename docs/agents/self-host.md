# CLEAR Self-Host Status

This document records the current state of the Ruby compiler to CLEAR
translation effort and the work remaining before generated `compiler/src/*.clear`
files should be committed as source.

The original inventory below was measured on 2026-07-08. The preflight audit
on 2026-07-20 supersedes its readiness conclusions because it tests generated
code through the actual CLEAR frontend, MIR, Zig emission, and behavioral
oracles rather than counting only translated Ruby syntax.

## 2026-07-21 Defect Burn-Down and Second Snapshot Refresh

The golden-migration defect catalog
(`gems/ruby-to-clear/docs/agents/golden-migration-defects.md`) was worked
down from seventeen defect families to two (aggregate receiver
materialization needs an ownership design; struct member overrides). The
translator suite is 591 examples with those 2 deliberate flags. Compiler
fixes landed alongside: `contains?` on fixed-size arrays dispatches as array
membership, inlined-module EXTERN declarations hoist to file scope with
per-unit alias dedup, `clear test` registers `--pkg` specs for FFI closure
scanning, module-scope owned values reject with `MODULE_SCOPE_OWNED_VALUE`,
bang-suffix parse failures surface the migration diagnostic, and emitted
type aliases carry a comptime reference so declared-but-unused aliases
survive block-scoped units.

The committed snapshot was regenerated from the post-fix translator. New
baseline (promoted to `analysis/results/baseline.md`): G1 159/213, G2 70,
G3 8, G4 7. G1 fell from 167 because the translator now honestly rejects
typed rescue instead of silently widening it to a catch-all. `mir/mir.clear`
and five more dependency files now generate; only
`semantic/tense_operation_plan.clear` remains ungenerable.

Known red: one fuzz negative cell
(`fuzz_call_ownership_contract_matrix_6813d4e281`, optional stream element
passed to a non-optional pipeline callee) compiles and leaks at every commit
back to the rebase point - a pre-existing soundness gap that negative-batch
packing masked until the corpus additions reshuffled batches. It stays red
until the pipeline argument check lands; do not re-mask it.

## 2026-07-20 Rebase and Snapshot Refresh

The branch was rebased onto current `origin/master` (7 lowering/incremental
bug-fix commits) with no conflicts. All post-rebase gates pass: 7,212 compiler
specs, 601 transpile tests with zero leaks, the current-language translator
suite (32/32), and the smoke lexer oracle. A fresh full-corpus verifier run
reproduced the recorded baseline exactly: G1 167/213, G2 70/213, G3 7/213,
G4 6/213. Results are now checked in at
`gems/ruby-to-clear/analysis/results/latest.{json,md}`.

The committed `compiler/src/**/*.clear` snapshot predated the current
translator: it still used retired bang-identifier syntax the parser in the
same tree rejects, so 9 of 14 files could not even parse. Every regenerable
file has been replaced by the current generation from that verifier run,
together with the 16 generated dependency files its REQUIRE closure needs.
Known limits of the refreshed snapshot:

- `ast/parser.clear` is retained stale: `parser.rb` fails G1 on the
  resource-budget `rescue` boundary in `Parser#parse` (the complex-rescue
  class already assigned to Ruby-source refactoring).
- The `type.clear -> struct_field.clear -> type.clear` package cycle is real
  in fresh generation (fresh `struct_field.clear` REQUIREs both `type.clear`
  and `ast.clear`) and remains the dominant G3 blocker: 49 roots fail on it.
  The previously committed `struct_field.clear` merely predated the REQUIRE
  emission, which is why the stale snapshot appeared acyclic. The acyclic
  parsed-type-syntax foundation is still prerequisite work.
- `mir/mir.clear` and `semantic/tense_operation_plan.clear` cannot be
  generated (their units fail G1), so `ast/std_lib.clear`, `mir/fsm_ops.clear`,
  `annotator/helpers/auto_inference.clear`, and
  `annotator/helpers/function_analysis.clear` fail G3 on missing dependencies.
- The lexer behavioral oracle now drives the generated
  `lexer__new`/`lexer__tokenize` entry points through a registered package
  build. It compiles through every module-system stage and stops at the
  documented retained-identity boundary: the optional `budget` parameter's
  default branch mixes a borrowed payload with an owned
  `FrontendResourceBudget@multiowned` (`expected FrontendResourceBudget,
  found CheatLib.Rc(FrontendResourceBudget)`). That is stop/go criterion 6;
  it is the retained-parameter contract, not a build defect.

**G4 is weaker than it looks.** `clear test` compiles library-shaped modules
whose functions nothing references, and Zig analyzes declarations lazily, so
a unit can "pass G4" while unreachable functions contain type errors. The
lexer's G4 pass survived an unqualified imported type this way. The verifier
should force full analysis (emit a `std.testing.refAllDecls`-style reference
block) before G4 counts are trusted for library units.

Compiler fixes landed while making the refreshed snapshot buildable, each
with specs:

1. `clear build` now accepts `--pkg name=path` registrations (previously only
   `clear test` did); registered paths take precedence over
   `packages/<name>/src/lib.clear` discovery.
2. Package aliases imported by locally REQUIREd modules (not just the root
   file) are rewritten to package-file imports in the emitted root Zig.
3. Cross-module package calls lowered inside an imported module now classify
   `needs_rt`/`can_fail` from the module's imported signatures instead of
   defaulting to worst case (which emitted `try f(rt)` for pure package
   functions).
4. Package/module emission carries `PUB` visibility onto emitted Zig type
   defs, emits module-scope immutable bindings (frozen membership tables) as
   file-scope consts, aliases imported package types at the import site (the
   EXTERN STRUCT contract), dedupes repeated package imports landing in one
   Zig unit, and rewrites EXTERN FFI module imports inside emitted package
   files.

## 2026-07-20 Preflight Decision

Do not continue manual translation of `Type`, the parser, or later compiler
phases yet. The rebase onto current `origin/master` preserves the current Ruby
compiler architecture and its 7,197-example non-integration baseline, but the
generated frontend exposed several semantic prerequisites. Hand-editing around
them would hide compiler or language defects and make regeneration unsafe.

The next workstream is deliberately narrow:

1. make ruby-to-CLEAR's current-language suite green and keep generated files
   reproducible;
2. close the local retained-identity capability boundary exposed by the lexer;
3. reject cleanup-bearing module globals before Zig emission;
4. establish an acyclic parsed-type-syntax foundation for `Type` and
   `StructField`;
5. prove the lexer and then the Type foundation with behavioral/MessagePack
   equivalence before translating the parser.

`type__new(...)` is not a prerequisite failure. CLEAR already supports omitted
and defaulted parameters. The generated factory represents Ruby's actual
`new`/`initialize` sequence: construct a complete value, run translated
initialization, and return it. Keep it unless `Type` is intentionally rewritten
as pure aggregate construction. Adding constructor overloading or public
constructor syntax merely to hide this generated helper would add language
surface without improving correctness.

### Must be done before more self-host translation

#### 1. Make optional retention explicit in generated CLEAR

CLEAR intentionally rejects silently inferred optional bindings. For a Ruby
call statically known to return a nilable value, ruby-to-CLEAR must emit:

```ruby clear
value:? = maybeValue();
```

This lowering is implemented and regression-tested. Ruby has no native error
union or temporal result type, so the translator must not speculate `:!` or
`:~` bindings for ordinary Ruby calls.

#### 2. Support sound retained local identity at function boundaries

Nested lexers share one mutable `FrontendResourceBudget`. Generated code stores
that identity as `FrontendResourceBudget@multiowned`, but ordinary function
parameters expose only a borrowed payload. A structural `COPY` would create an
independent budget; copying an Rc handle's bits without a retain would permit
use-after-free or double release.

Do not weaken the ownership verifier and do not silently promote this local
identity to `@shared`. Preserve capability-at-bind-time semantics with a
retained-parameter contract. The likely shape is a plain `T` parameter with a
local capability requirement and an explicit retention effect:

```ruby clear illustrative
FN lexer(source: String, budget: FrontendResourceBudget) RETURNS Lexer
  REQUIRES budget: LOCAL
  EFFECTS RETAINS budget
->
  RETURN Lexer{ source: COPY source, budget: CLONE budget };
END
```

The final spelling must fit the existing `REQUIRES`/`EFFECTS` model. Its
semantics are non-negotiable: the caller supplies an existing local Rc
identity, MIR emits one retain, the callee may store that retained handle, and
ordinary borrowed parameters remain non-escaping. This is a general facility
for local caches, compiler contexts, graph sessions, and similar identity
graphs—not a lexer exception.

#### 3. Reject unsupported module-global ownership

The frontend currently accepts an owned module-level collection and later emits
a top-level Zig `defer`, which Zig rejects. Until CLEAR has a defined module
initialization/termination lifetime, reject cleanup-bearing top-level values
with a source-level diagnostic. Frozen Ruby membership sets should instead
lower to immutable compile-time data or generated membership predicates.

#### 4. Break the Type package cycle at the model boundary

Forty-nine independent compiler roots converge on the same generated package
cycle:

```text
type.clear -> struct_field.clear -> type.clear
```

Do not solve this by allowing arbitrary cyclic packages. Extract immutable
parsed type syntax and field-declaration metadata into an acyclic foundation.
Semantic/capability-aware `Type` can depend on that foundation, and parser AST
records can depend on syntax records without importing semantic `Type` back
into the foundation.

#### 5. Remove accidental dynamic boundaries

Every generated `Any` and `CAST` in the frontend wire path needs an explicit
disposition. Replace wire-facing `Any` with closed unions or typed syntax
records. The self-hosted frontend should define one closed `TypeExpression`
union so constructors produce it directly instead of repeatedly casting
nominal syntax records back into an interface-like union.

#### 6. Require stage-specific semantic oracles

A generated file is ready only when it passes all of:

- raw translation with no `unsupportedRuby`;
- dependency closure generation;
- CLEAR parser/annotator/MIR validation;
- Zig emission/build validation;
- its behavioral oracle against Ruby output.

For the lexer, the oracle must cover the complete hostile and corpus inputs and
must prove that nested lexers observe the same resource-budget counter. For the
Type foundation, use stable MessagePack snapshots/equivalence before beginning
the parser.

### Work that belongs in ruby-to-CLEAR

- Emit `:?` for known nilable Ruby results.
- Preserve `# ruby-to-clear: value` through required files and class reopenings
  instead of inventing `@multiowned` and `WITH POLYMORPHIC` scopes.
- Retain constructor default expressions until all declaration metadata has
  been collected.
- Map known Ruby keyword constructors to exact positional CLEAR calls.
- Lower enumerable blocks containing non-local returns to explicit loops.
- Copy scanner-backed borrowed strings when Ruby retains them.
- Inline immutable regex constants and lower frozen membership tables as
  compile-time data.
- Keep generated syntax current with CLEAR's collection, mutability, tense,
  operator, Tuple, and explicit-return rules.

### Work that belongs in the Ruby compiler source

- Replace complex `rescue`/`ensure` with explicit fallible results and resource
  scopes; do not import Ruby stack-unwinding semantics.
- Replace `$stdout`, `$stderr`, `$?`, and other globals with an explicit
  compiler/process context.
- Replace `const_get`, dynamic `is_a?`, and open reflection with closed unions
  or explicit registries.
- Replace implicit regexp match state with explicit match values.
- Prefer explicit loops where Ruby non-local block control flow obscures
  ownership or lifetime behavior.
- Remove metaprogramming and private-boundary `send` calls rather than teaching
  CLEAR to reproduce them.

### Work that should not block self-hosting

- Named call arguments. Signature-aware positional lowering is exact; named
  calls are a separate ergonomics decision touching parser, annotation, MIR,
  formatting, and function-value rules.
- Special constructor syntax solely to replace `type__new`.
- Ruby-style non-local closure returns or general exception unwinding.
- Runtime reflection, shell interpolation syntax, or arbitrary cyclic modules.
- Generic `Auto` escape hatches that weaken the frontend's closed types.

### Current measured status

The fresh verifier covered 213 Ruby compiler files and 114,742 nonblank source
lines:

| Gate | Passing files | Passing source LoC |
| --- | ---: | ---: |
| G1: raw translation | 168 / 213 (78.87%) | 67.25% |
| G2: dependency closure | 70 / 213 (32.86%) | 23.50% |
| G3: CLEAR frontend/MIR | 7 / 213 (3.29%) | 0.62% |
| G4: native Zig validation | 6 / 213 (2.82%) | 0.53% |

After value-metadata and deferred-default fixes, generated `type.clear` fell
from 6,121 to 4,817 lines, its 305 invented polymorphic receiver scopes fell to
zero, and it contains no `unsupportedRuby` sites. It still has 30 casts and 24
`Any` spellings requiring semantic classification; not every spelling is wrong,
because `Any` is also a real source-language type name.

The old ruby-to-CLEAR golden suite is not a valid green baseline after the
language changes: 332 of 562 examples still expect legacy arrays, logical
operators, bang mutation, implicit returns, and older ownership behavior. These
expectations must be migrated and then kept green before committing regenerated
compiler sources. The current-language focused suite passes 32/32 examples,
Sorbet passes, and the rebased Ruby compiler baseline passes independently.

The sections below retain the 2026-07-08 inventory for historical comparison;
its syntax-coverage percentages must not be interpreted as self-host readiness.

## Commit Policy

Do not commit generated `compiler/src/**/*.clear` as source until:

- the relevant Ruby source set translates with no missing generated
  dependencies;
- generated files needed by `REQUIRE` are present;
- unsupported placeholders are limited to small, explicitly reviewed TODOs;
- `./clear build compiler/src/ast/parser.clear` or the equivalent stage target
  gets past dependency resolution and parser/type-checking;
- manual fixes are minimal enough that regeneration remains practical.

The current generated output is not there yet. `compiler/src/ast/parser.clear`
now requires generated helper files, and the current dirty tree has missing
dependencies such as `compiler/src/annotator/helpers/function_return.clear`.
Several generated files still contain `unsupportedRuby(...)` placeholders.

## Current Metrics

Full compiler Ruby scope:

| Metric | Clean | Total | Percent |
| --- | ---: | ---: | ---: |
| Nonblank source lines | 90,863 | 94,332 | 96.32% |
| Prism node sites | 465,849 | 467,314 | 99.69% |
| Ruby `CallNode` sites | 89,811 | 90,728 | 98.99% |
| Call-related sites | 89,448 | 90,728 | 98.59% |
| Function bodies | 4,944 | 5,691 | 86.87% |

Strict file status:

- files: 165
- parse errors: 0
- complete files: 52
- partial files: 113
- failed transpiles: 0
- dirty function bodies: 747

Current self-host seed set, which matches the files represented by the local
generated `compiler/src/**/*.clear` work plus missing required helper sources:

| Metric | Percent |
| --- | ---: |
| Nonblank source lines clean | 98.63% |
| Prism node sites clean | 99.85% |
| Ruby `CallNode` sites clean | 99.73% |
| Function bodies clean | 93.71% |

Seed set counts:

- files: 18
- nonblank source lines: 17,772
- unsupported line ranges: 243
- functions: 1,113
- dirty function bodies: 70

The line metric is already above the 95% target. The remaining problem is that
unsupported sites are spread across enough functions to keep generated code from
being buildable.

## Lexer Status

Updated 2026-07-08:

- `compiler/ruby/ast/lexer.rb` now translates with `unsupportedRuby(...)` count
  `0` in the default `ruby-to-clear` mode.
- With `gems/ruby-to-clear/config/compiler_regex_helpers.json`, the lexer also
  translates with `unsupportedRuby(...)` count `0`.
- The configured lexer output emits inline `EXTERN` declarations for
  `compiler_regex`, maps `StringScanner` to `CompilerRegexScanner`, and lowers
  Ruby regex/scanner calls to `compilerRegex*` helpers.
- The configured lexer output was 321 lines in the latest smoke check.
- `compiler/src/compiler_regex.zig` has a direct Zig unit test for the
  PCRE2-backed scanner path.

This resolves the previous lexer-specific blockers: interpolated regexes,
`StringScanner` helper calls, `to_i(base)`, codepoint `chr`, and the dynamic
regex in `strip_digit_separators`.

## Biggest Gaps

Full compiler placeholder categories:

| Category | Sites | Functions | Notes |
| --- | ---: | ---: | --- |
| Constructor metadata | 842 | 395 | mostly unknown fields for `.new(...)` and keyword constructors |
| Block control flow | 135 | 121 | `next`, `return`, `break`, pair destructuring inside blocks |
| Write/operator forms | 115 | 70 | `[]=`, `foo +=`, `hash[key] ||=`, call/index operator writes |
| Splat call shapes | 99 | 55 | `*args`, generated overloads, explicit spread support |
| Rescue/exception forms | 91 | 82 | `rescue` modifiers and begin/rescue blocks |
| Global process state | 37 | 23 | `$stdout`, `$stderr`, `$?`, similar Ruby globals |
| Regex/match state | 23 | 10 | interpolated regex and `Regexp.last_match` |
| Stdlib adapter gaps | 23 | 9 | `defined?`, `to_i(base)`, small host-runtime APIs |
| Dynamic dispatch placeholders | 16 | 9 | unsupported emitted `send` / `public_send` |

Dynamic/reflection in source is larger than the emitted placeholder count:

| Call | Sites |
| --- | ---: |
| `public_send` | 18 |
| `send` | 13 |
| `__send__` | 4 |
| `const_get` | 4 |
| `define_method` | 3 |
| `const_defined?` | 1 |
| `instance_variable_set` | 1 |

These 44 dynamic/reflection sites live in 30 function bodies across 21 files.
They are the most likely true manual source-refactor work. The other buckets
should mostly be solved by improving `ruby-to-clear`.

## Current Hot Files

The largest full-compiler dirty files by unsupported site count are:

| File | Sites | Dirty Functions |
| --- | ---: | ---: |
| `compiler/ruby/mir/lowering/expressions.rb` | 165 | 62 |
| `compiler/ruby/mir/lowering/control_flow.rb` | 101 | 36 |
| `compiler/ruby/mir/lowering/functions.rb` | 97 | 37 |
| `compiler/ruby/mir/lowering/variables.rb` | 70 | 25 |
| `compiler/ruby/mir/lowering/capabilities.rb` | 62 | 27 |
| `compiler/ruby/mir/lowering/concurrency.rb` | 55 | 24 |
| `compiler/ruby/tools/doctor.rb` | 46 | 17 |
| `compiler/ruby/annotator/helpers/fixable_helpers.rb` | 44 | 30 |

For the current self-host seed set, the largest gaps are:

| File | Sites | Dirty Functions |
| --- | ---: | ---: |
| `compiler/ruby/annotator/helpers/fixable_helpers.rb` | 44 | 30 |
| `compiler/ruby/ast/type.rb` | 23 | 15 |
| `compiler/ruby/annotator/helpers/intrinsic_registry.rb` | 19 | 7 |
| `compiler/ruby/ast/lexer.rb` | 0 | 0 |
| `compiler/ruby/ast/schemas.rb` | 7 | 4 |
| `compiler/ruby/ast/source_error.rb` | 6 | 4 |

## Required ruby-to-clear Work

These are translator improvements rather than Ruby source changes.

1. Constructor metadata

   Extend metadata preloading to cover:

   - all local and `require_relative` `T::Struct` declarations;
   - `Struct.new` assigned constants and superclass forms;
   - ordinary `initialize` keyword and positional signatures;
   - nested constants and namespace aliases;
   - generated helper files that currently miss constructor field maps.

   This is the largest bucket and should be handled before hand-editing
   generated Clear.

2. Block control flow

   Add lowering for common control-flow forms inside safe collection blocks:

   - `next` in `each`, `map`, `filter_map`, `any?`, `all?`, `find`;
   - `break` in effect-only loops where it maps to `BREAK`;
   - local `return` patterns that should become explicit function returns;
   - pair destructuring in `each_pair`, hash iteration, and tuple-like blocks.

3. Write/operator nodes

   Add Prism handlers for:

   - `IndexOrWriteNode`;
   - `IndexOperatorWriteNode`;
   - `CallOperatorWriteNode`;
   - `CallOrWriteNode`.

   These should map to explicit read/modify/write CLEAR statements where the
   receiver and setter are known.

4. Splat support

   Support high-confidence splats:

   - constructor and method call splats when parameter metadata is known;
   - array literal splats;
   - generated overloads or explicit helper functions for dynamic rest cases.

5. Rescue support

   Support a small subset first:

   - `expr rescue default`;
   - `begin ... rescue ... end` with local fallback;
   - `JSON.parse(...) rescue nil` style host-code patterns.

   Broader exception semantics should not be generalized beyond what the
   compiler source actually uses.

6. Ruby stdlib adapters

   Keep translating common host APIs to first-party CLEAR packages:

   - `File` / `Dir` -> `stdlib/fs`;
   - `File.basename`, `dirname`, `join`, `expand_path` -> `stdlib/path`;
   - `JSON` -> `stdlib/json`;
   - `StringScanner` or regex scanning -> `stdlib/scanner` or `stdlib/regex`;
   - `OptionParser` -> `stdlib/cli`;
   - process globals and status -> `stdlib/process`.

7. Measurement tooling

   Promote the stricter unsupported-site counter into a checked-in audit tool.
   The current markdown audit's `useful LoC coverage` is optimistic because it
   counts unsupported comment blocks but not every inline `unsupportedRuby(...)`
   expression.

## Required Ruby Source Refactors

These source shapes should not survive into self-hosted CLEAR.

1. Replace dynamic visitor dispatch.

   `send("visit_#{...}")` should become generated closed dispatch. This is a
   compiler-appropriate pattern in Ruby, but CLEAR should see an explicit case
   over known AST node variants.

2. Replace bounded `public_send` / `send` property access.

   Current uses include registry hydration, enum-like field access, MIR
   property access, token field reads, and helper calls across private
   boundaries. Replace with explicit methods, typed protocols, or closed cases.

3. Replace metaprogrammed `define_method`.

   `SymbolEntry` lifecycle and flow delegators should be generated explicitly
   or expressed as a static table that `ruby-to-clear` can lower.

4. Replace dynamic constant lookup.

   `const_get` / `const_defined?` should become explicit registries or closed
   maps. This helps both translation and stage1 determinism.

5. Replace `instance_variable_set`.

   The remaining optional metadata mutation in `Type` should become a declared
   field or typed side table.

6. Replace implicit regex match state.

   `Regexp.last_match` should become an explicit match result object. This also
   matches the likely `stdlib/regex` API.

7. Reduce Ruby globals.

   `$stdout`, `$stderr`, `$?`, and similar globals should go through explicit
   process/io APIs.

## Required CLEAR Language / Runtime Work

Some gaps are better solved in CLEAR than in the translator.

- Native package build support through generated `build.zig`; see
  `docs/agents/build-system.md`.
- `stdlib/path`, `stdlib/fs`, `stdlib/process`, and `stdlib/json`.
- The compiler-local regex/native wrapper in `compiler/src/compiler_regex.*`
  for compiler code that should remain regex-based.
- More complete generic type predicates. `COMPTIME IF T IS_A String@symbol`
  now parses and lowers, but `String@symbol` still erases to the same Zig type
  as `String` in equality checks.
- Stable generated dispatch tables for visitors and parser rules.
- A generated source dependency manifest so the self-host compiler can rebuild
  when generated support files change.

## Build-System Dependency

The self-host compiler now has a bootstrap-specific native regex bridge:

`ruby-to-clear` injects inline `EXTERN ... FROM "compiler_regex"` declarations
for generated compiler files. `compiler/src/build.zig` points the build at the
native module directory and links PCRE2 through the existing CLEAR build path.
This is not a general stdlib regex package. Filesystem, JSON, process, and
future native dependencies should still move toward generated build metadata so
they do not require one-off CLI wiring.

## Near-Term Plan

1. Keep generated `*.clear` out of commits except for narrow, known-good
   stdlib files.
2. Promote strict translation metrics into a repeatable audit command.
3. Fix constructor metadata until the seed set has no constructor placeholders.
4. Generate every required helper source in the seed set, including currently
   missing annotator helper dependencies.
5. Add write/operator node lowering.
6. Add block control-flow lowering for the common safe subsets.
7. Refactor the 44 dynamic/reflection source sites, starting with visitor
   dispatch and `IntrinsicRegistry` hydration.
8. Add or design native support for fs/path, JSON, process, and CLI argument
   parsing; keep regex on the compiler-local PCRE2 bridge for now.
9. Regenerate the seed set and require zero missing `REQUIRE` dependencies.
10. Build the generated parser target before committing generated compiler
    source.
