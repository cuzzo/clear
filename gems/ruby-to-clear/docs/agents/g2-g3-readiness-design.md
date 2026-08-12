# G2/G3 Readiness Design

Status: measurement and readiness reference; implementation order superseded
by `typed-ir-course-correction.md`

> Course correction (2026-07-13): the failure patterns encountered while
> advancing G3 show that semantic facts are being lost between fragmented
> analysis and direct AST-to-text emission. Do not continue the source-workaround
> sequence described in historical checkpoints below. Follow
> `typed-ir-course-correction.md` for current architecture and execution order.

Baseline report: `gems/ruby-to-clear/analysis/results/latest.json`

## Continuation checkpoint: 2026-07-10

This checkpoint measures commit `f0abf7370` with a fresh 169-file verifier
run. It supersedes the older burn-down numbers below.

| Gate | Files | File coverage | Source LoC | LoC coverage | Change from pass start |
| --- | ---: | ---: | ---: | ---: | ---: |
| G1 | 153/169 | 90.53% | 85,816/96,845 | 88.61% | +9 files |
| G2 | 109/169 | 64.50% | 54,714/96,845 | 56.50% | +36 files |
| G3 | 7/169 | 4.14% | 245/96,845 | 0.25% | unchanged |
| G4 | 4/169 | 2.37% | 71/96,845 | 0.07% | unchanged |

The pass-start comparison is the last stable pre-work report: G1 144, G2 73,
G3 7, and G4 4. The largest result is not G1 emission. SCC-aware dependency
compilation and non-re-exporting module scopes removed the false duplicate
`Schema`/`sync` clusters and moved 36 files through G2. Unknown G2/G3 outcomes
fell to 11.

The readiness threshold is still not met. G2 remains 20.50 percentage points
short by files and 33.50 points short by source LoC. G3 remains 65.86 points
short by files and 74.75 points short by source LoC.

### Current frontier

1. `SymbolEntry#lifetime=` uses Ruby object identity through `equal?`. This one
   failed generated dependency blocks 92 roots. Lower it only after choosing an
   explicit CLEAR identity representation; `SymbolEntry#binding_id` is the
   likely contract. Do not map arbitrary Ruby `equal?` to value equality.
2. Seven roots fail MIR ownership verification after frontend analysis. Reduce
   these to the first incorrect allocation/transfer event rather than disabling
   the checker.
3. Seven roots still flatten distinct `Program` type declarations into one
   namespace. Type ownership must be retained through generated aliases and
   imported MIR.
4. Twenty roots contain generated CLEAR parser failures. The largest shapes are
   invalid `MUTABLE` placement and comma/semicolon handling in statement-form
   branches.
5. Sixteen roots remain explicit G1 manual-tail candidates: complex rescue,
   globals, implicit regexp match state, runtime regexp construction, shell
   literals, and dynamic process/runtime boundaries.
6. Three G4 failures remain after frontend success: missing `Proc`, an unused
   generated constant, and `try` emitted outside function scope.

The next high-leverage milestone is to resolve `SymbolEntry` identity and then
remeasure. That single provider currently dominates the dependency graph, so
working low-frequency G1 nodes first would not materially improve G3.

## Burn-down checkpoint

Checkpoint date: 2026-07-10

The first implementation burn-down completed all eight workstreams. "Complete"
here means the systemic/static cases were implemented and the dynamic/manual
tail was identified; it does not mean the readiness thresholds were reached.

| Workstream | Result |
| --- | --- |
| Dependency graph | 40 secondary missing-target failures now point to their failed provider and are excluded from primary fingerprints. |
| Receiver context | The 33-unit undefined-`self` cluster was eliminated by preserving class context across blockless `Struct.new`. |
| Constructors | Static constructor failures fell from 15 to 3; zero-argument, reopened, nested, and imported shapes are retained. |
| Type/native dependencies | Sorbet `T` leakage was removed; reachable-only native prelude emission is regression tested. |
| Arguments/blocks | Nine splat failures were eliminated; static hash `each_pair` is supported. Dynamic object reflection remains manual. |
| Rescue | Complex-rescue failures fell from 10 to 5. Catch-all function recovery is supported; typed dispatch and `ensure` remain manual. |
| Long-tail nodes | Static aliases and resolvable `defined?` are supported. Standard-stream globals remain a runtime-boundary decision. |
| G3 correctness | Scanner string/union typing, string deletion, float conversion, and optional token payloads were fixed. The next shared blocker is the native scanner `scan` return contract. |

The final checkpoint is 118/169 G1 files, 58/169 G2 files, and 14/169 G3
files. The next systemic task is to split scanner predicate scanning from
value-returning scanning: Ruby `StringScanner#scan` returns `String?`, while
`compilerRegexScan` currently returns `Bool`. A new native value helper and
context-aware lowering are required before the 35-unit lexer-dependent G3
cluster can advance.

## Objective

Move `ruby-to-clear` from structural emission coverage to a point where manual
migration is economically sensible. The target is not automatic translation of
all Ruby. The target is a generated CLEAR tree that parses and analyzes across
the compiler's important dependency closures, leaving a bounded, explicit tail
of Ruby-specific semantics for humans.

This plan uses the strict verification gates defined in
`true-clean-transpilation-audit.md`:

- G2 means the generated CLEAR and its generated dependencies parse.
- G3 means name resolution, types, effects, mutability, ownership, and other
  frontend checks pass.

G1 output is useful diagnostic input, but it is not evidence of valid CLEAR.

## Current Baseline

The current corpus is 169 Ruby files and 96,652 nonblank source LoC.

| Gate | Files | File coverage | Source LoC | LoC coverage |
| --- | ---: | ---: | ---: | ---: |
| G1 | 101/169 | 59.76% | 51,241/96,652 | 53.02% |
| G2 | 56/169 | 33.14% | 31,640/96,652 | 32.74% |
| G3 | 12/169 | 7.10% | 1,249/96,652 | 1.29% |
| G4 | 6/169 | 3.55% | 857/96,652 | 0.89% |

The largest normalized failures are:

| Failure | Affected units | Stage |
| --- | ---: | --- |
| Undefined `self` | 33 | G3/name resolution |
| Constructor call lacks known fields | 15 | G1/transpiler |
| Missing `ast/scope.clear` | 11 | G2/dependency closure |
| Complex `begin/rescue` | 10 | G1/transpiler |
| Missing `mir/mir.clear` | 10 | G2/dependency closure |
| Splat arguments lack a known call shape | 8 | G1/transpiler |
| Missing `annotator/annotator.clear` | 4 | G2/dependency closure |
| MIR ownership verification | 3 | G3/ownership |
| Global variable reads | 3 | G1/transpiler |
| `each_pair` destructuring | 3 | G1/transpiler |

The missing dependencies are mostly secondary failures: the required file did
not reach G1, so every dependent file also fails. Reports must preserve this
causal relationship instead of counting every dependent as an independent
require-path bug.

## Readiness Threshold

Manual takeover begins when one full, clean verifier run satisfies all of the
following:

1. G2 reaches at least **90% source LoC** and **85% of files**.
2. G3 reaches at least **75% source LoC** and **70% of files**.
3. The generated dependency closure for lexer, parser, annotator, MIR, and the
   compiler frontend contains no missing generated target.
4. No systemic transpiler or name-resolution fingerprint affects more than five
   files.
5. Every remaining G1 failure has a documented manual-migration disposition.
6. G2 and G3 percentages are measured from fresh strict output, without
   checked-in generated files masking missing output and without counting
   autofix-assisted success as raw success.

The stretch target before broad manual editing is **95% G2 LoC** and **85% G3
LoC**. Requiring 100% would spend disproportionate effort automating dynamic
Ruby constructs that are clearer and safer to migrate manually.

## Design Principles

- Fail closed. Unsupported semantics must remain a G1 failure rather than emit
  plausible but incorrect CLEAR.
- Fix the transpiler or generated dependency model before editing generated
  CLEAR by hand.
- Preserve Ruby names. CLEAR autofix owns CLEAR naming and mutation conventions,
  including adding `!` where required.
- Prefer static metadata gathered from the full source dependency closure over
  local string heuristics.
- Implement a Ruby feature only when its semantics have a stable CLEAR mapping.
  Mark dynamic reflection, arbitrary exception matching, and process-global
  state for manual migration when no such mapping exists.
- Measure files and source LoC. A large core file is not equivalent to a tiny
  data record.

## Workstream 1: Dependency Graph

### Problem

Each source file is transpiled as a unit, but generated `REQUIRE` paths and
metadata discovery are still partly derived from the current file. A required
unit that fails G1 disappears from the generated tree and creates many secondary
G2 failures. Relative paths can also be interpreted from the invoking unit
rather than the declaring source file.

### Implementation

1. Build a source graph before transpilation. Each node records its absolute
   Ruby path, canonical generated path, direct `require_relative` edges, and
   metadata-only edges.
2. Canonicalize every generated path relative to `compiler/ruby`; generated
   output must use the identical relative path under `compiler/src`.
3. Resolve a `REQUIRE` relative to the generated file containing it, not the
   process working directory.
4. Transpile the graph in dependency order where possible. Detect strongly
   connected components and transpile each component as one metadata closure.
5. Separate primary dependency failures from secondary blocked units in the
   verifier. A blocked dependent does not acquire a new root-cause fingerprint.
6. Compile representative entrypoint closures in addition to standalone files.

### Acceptance

- Every emitted local `REQUIRE` maps to exactly one manifest unit.
- No required target is satisfied only by a stale checked-in CLEAR file.
- Lexer, parser, annotator, MIR, and frontend entrypoint closures have zero
  missing-target failures.
- Graph tests cover `../`, nested directories, cycles, suppressed requirements,
  metadata-only imports, and two files with the same basename.

## Workstream 2: Receiver and Module Context

### Problem

Thirty-three G3 failures report undefined `self`. Instance methods are flattened
to functions, but some generated bodies retain Ruby's implicit receiver without
receiving or reconstructing the corresponding CLEAR value. Imported method
metadata can also lose whether a method is an instance, class, module, or free
function.

### Implementation

1. Replace boolean context flags with an explicit method context record:
   ownership path, receiver kind, receiver type, emitted receiver parameter,
   singleton status, and imported/local origin.
2. Store that context in imported method metadata. Do not reconstruct receiver
   behavior from the emitted function name.
3. For flattened instance methods, emit a typed receiver parameter and lower
   `self`, instance fields, and implicit calls through that parameter.
4. For class/module methods, lower static calls to free functions without a
   fabricated `self`.
5. Reject ambiguous mixin/dynamic-dispatch cases and add them to the manual tail.
6. Add a post-emission invariant: `self` may occur only inside a CLEAR construct
   where the frontend defines it.

### Acceptance

- The undefined-`self` fingerprint falls from 33 units to zero.
- Unit tests cover local/imported instance methods, nested modules, singleton
  methods, field reads/writes, implicit calls, and same-named methods on
  different receiver types.
- No replacement global receiver or untyped receiver is introduced.

## Workstream 3: Constructor Metadata

### Problem

Fifteen units fail because `.new` cannot be assigned to known CLEAR fields.
Metadata is incomplete for constructors declared in dependencies, inherited
initializers, `Struct.new`, Sorbet structs, aliases, and conditionally assigned
instance fields.

### Implementation

1. Define one `ConstructorShape` model containing target type, ordered
   positional fields, keyword fields, defaults, optionality, rest policy, and
   provenance.
2. Populate it from `initialize`, `T::Struct` props/consts, `Struct.new`, static
   factory declarations, and imported metadata closures.
3. Track all statically named instance-field writes in `initialize`, including
   conditional writes. Missing branches produce optional fields or require an
   explicit default; they must not silently become `NIL` for a nonoptional type.
4. Resolve type aliases before constructor lookup.
5. Allow a conservative fallback only when the target CLEAR struct and all
   argument-to-field mappings are known. Dynamic `send`, computed field names,
   open keyword rest, and runtime class values remain manual.

### Acceptance

- Known-field constructor failures fall from 15 units to zero for static class
  targets.
- Constructor tests include imported classes, positional plus keyword args,
  defaults, optional fields, conditionally assigned fields, aliases, Sorbet
  structs, and plain structs.
- Unknown dynamic constructors still fail G1 with a precise diagnostic.

## Workstream 4: Exceptions

### Problem

Modifier rescue and simple untyped fallback can be represented as value
recovery. Ten units use richer `begin/rescue` shapes: typed clauses, exception
bindings, multiple clauses, `else`, `ensure`, or statement-oriented recovery.

### Implementation

1. Classify rescue nodes into value fallback, function-boundary catch, cleanup,
   and unsupported dynamic matching.
2. Lower untyped single-clause value rescue to the existing `OR` recovery form.
3. Lower function-boundary typed rescue to CLEAR `CATCH` only when exception
   type and binding semantics are representable.
4. Lower `ensure` only when CLEAR cleanup/defer semantics preserve execution on
   success, error, and early exit.
5. Mark arbitrary Ruby exception matching, retry, and nonlocal control transfer
   for manual migration.

### Acceptance

- Every current rescue site is classified by semantic shape.
- Supported shapes have Ruby/CLEAR behavior fixtures for success and error paths.
- Unsupported shapes fail locally without discarding otherwise translatable
  surrounding declarations.

## Workstream 5: Arguments and Blocks

### Problem

Splat calls lack target-shape expansion, and collection blocks still reject
destructuring, block arguments, and control flow in several known operations.

### Implementation

1. Expand literal array splats immediately.
2. Expand typed tuple splats using the target signature and tuple arity.
3. Forward dynamic splats only to a declared CLEAR variadic target; otherwise
   retain a manual-migration diagnostic.
4. Introduce a block parameter pattern model for one value, tuple/pair
   destructuring, nested destructuring, and explicit block forwarding.
5. Implement `each_pair` through the hash iterator primitive with exact key and
   value bindings.
6. Model `next` as per-iteration continuation and `break` as loop termination in
   effect blocks. Permit `return` only when the chosen CLEAR lowering preserves
   Ruby's nonlocal return.
7. Share block safety analysis across `each`, `map`, `filter_map`, `any?`,
   `each_value`, and `each_with_index` rather than maintaining independent
   rejection lists.

### Acceptance

- The eight current splat failures are either translated from known shapes or
  explicitly assigned to manual migration.
- Current `each_pair`, block-argument, `break`, and `next` fingerprints are
  eliminated for representable blocks.
- Behavior fixtures verify empty collections, early exit, skipped elements,
  mutation, pair ordering, and returned values.

## Workstream 6: Long-Tail Prism Nodes

### Implementation

- Globals: map only known runtime facilities such as standard streams through
  explicit helper APIs. Treat arbitrary mutable globals as manual migration.
- Aliases: resolve static `alias`/`alias_method` declarations into metadata and
  emit wrappers when receiver and signature are known.
- `defined?`: fold statically known locals, constants, and methods; reject
  reflection-dependent cases rather than returning an invented Boolean.
- Indexed and property compound writes: evaluate receiver and index once, then
  perform read-modify-write so side effects are not duplicated.
- Keep a generated-node conformance test for every newly supported Prism class.

### Acceptance

- Current global and alias fingerprints are removed or explicitly classified as
  manual work.
- Compound-write fixtures prove single evaluation of receiver and index.
- No supported visitor emits a placeholder, comment-only body, or untyped stub.

## Workstream 7: G3 Type and Ownership Correctness

### Problem

Once a file reaches G2, most failures are not parser problems. Undefined
receivers and type names dominate, followed by optional/default mismatches and
three MIR ownership failures. Native declarations can also leak into unrelated
files and make standalone backend builds fail.

### Implementation

1. Make emitted type references contribute dependency edges. `Type`, `VarDecl`,
   `Proc`, union members, and constructor result types must be declared locally
   or imported by a generated `REQUIRE`.
2. Extend prelude reachability so native extern declarations are emitted only
   when a reachable generated expression calls them. Include transitive native
   type dependencies but no unrelated externs.
3. Infer optional fields and defaults from constructor/control-flow metadata;
   never substitute `NIL` for a required `Bool` or other concrete field.
4. Capture CLEAR frontend diagnostics as structured data and group them by
   declaration, not only normalized text.
5. For each ownership failure, minimize a Ruby fixture and determine whether
   the correction belongs in value/category lowering, explicit `COPY`/borrow
   generation, or CLEAR autofix.
6. Treat autofix as a diagnostic oracle. If autofix adds `!`, `MUTABLE`, or
   `COPY`, teach the transpiler/context model to emit the necessary semantics;
   keep raw and assisted metrics separate.

### Acceptance

- No G3 unit fails solely because a statically referenced generated type was
  omitted from its closure.
- Unused native extern declarations are absent from generated files.
- The three current ownership failures have minimized regression fixtures and
  pass raw G3.
- Raw G3 reaches the readiness threshold without relying on autofix output.

## Execution Order

1. Add dependency-graph modeling and causal failure reporting.
2. Fix receiver context and imported method metadata.
3. Complete static constructor shapes.
4. Add type-reference dependency edges and native prelude reachability.
5. Implement known splat and block patterns.
6. Classify and lower supported rescue shapes.
7. Handle the long-tail Prism nodes.
8. Minimize and fix remaining G3 type/ownership failures.
9. Run differential lexer/parser oracles after their closures reach G4.

Dependency and receiver work comes first because it unlocks many files at once
and makes later diagnostics trustworthy. A missing `mir/mir.clear` should not
be debugged independently in ten dependents when one constructor failure in the
provider is the primary cause.

## Verification and Reporting

Every implementation batch must run:

```text
ruby gems/ruby-to-clear/analysis/bin/ruby-to-clear-verify --jobs 4 --timeout 240
```

Each report must include:

- raw G1/G2/G3/G4 files and source LoC;
- change from the pinned baseline above;
- primary versus secondary/blocked failure counts;
- top normalized fingerprints;
- regressions by unit and gate;
- raw versus autofix-assisted results;
- the revision, manifest hash, and artifact directory.

A batch is accepted only when it adds regression fixtures, does not reduce any
later gate without an approved explanation, and does not convert a hard failure
into semantically unverified output.

## Manual-Migration Handoff

At the readiness threshold, generate a manifest of remaining units. Each entry
must name the first unsupported construct, source location, dependency closure,
estimated affected LoC, and one disposition:

- manual rewrite in Ruby before retranspilation;
- manual CLEAR implementation after generated code stabilizes;
- intentional Ruby-only boundary;
- deferred language/runtime design decision.

Manual edits should begin with isolated leaves and explicit runtime boundaries.
Core generated files shared by many dependents should remain transpiler-owned
until their dependency closures are stable, otherwise regeneration will erase
work and conceal systemic bugs.

## 2026-07-10 Burn-Down Checkpoint

Revision `3e4e227a8` completed the prioritized implementation pass. The raw
169-unit verifier reports:

| Gate | Files | File % | Source LoC | LoC % | Delta from pinned baseline |
|---|---:|---:|---:|---:|---:|
| G1 | 126/169 | 74.56% | 63,435/96,652 | 65.63% | +8 files, +5,866 LoC |
| G2 | 65/169 | 38.46% | 34,064/96,652 | 35.24% | +7 files, +2,217 LoC |
| G3 | 14/169 | 8.28% | 2,204/96,652 | 2.28% | unchanged |
| G4 | 7/169 | 4.14% | 1,633/96,652 | 1.69% | unchanged |

The pass removed the scanner value/type cluster, direct class-writer parser
failures, missing typed constructor defaults, unwrapped scoped-union arguments,
and imported enum-name loss. Twenty-two units now reach MIR ownership
verification, making ownership the largest coherent post-G2 blocker rather
than generated garbage being counted as success.

The readiness targets remain G2 at 85% of files and 90% of LoC, and G3 at 70%
of files and 75% of LoC. The current gaps are therefore 46.54/54.76 percentage
points for G2 and 61.72/72.72 points for G3. This is not ready for broad manual
CLEAR takeover.

### Remaining Automated Work, In Order

1. Fix the shared MIR ownership failures (22-file fingerprint cluster), with a
   minimized fixture for every distinct ownership diagnostic.
2. Remove the seven statement-if parser failures and the two stray-semicolon
   pipeline failures.
3. Resolve generated receiver/dependency names (`fatal?`, `primitive?`,
   `respondsTo?`) and duplicate `require!` declarations.
4. Preserve concrete struct types through `Program.statements`, `TestBlock`,
   and `StructField.type` accesses.
5. Finish bounded block/enumerator forms: statically typed `each_pair`,
   block-argument `each_value`, enumerator `each_with_index`, and nonlocal
   returns lowered to explicit loops.
6. Complete practical rescue and remaining known constructor shapes.
7. Add the missing generated Type/Proc/VarDecl dependency edges before G4.

### Manual Tail

Manual migration is appropriate only for Ruby features whose runtime model is
intentionally outside CLEAR: dynamic `const_get` registries, genuinely dynamic
`send`, implicit `Regexp.last_match` state, shell/xstring execution, and global
process state. These should receive explicit Ruby registries or boundary APIs,
then be retranspiled. The ownership, parser, receiver, constructor, and static
enumerator clusters remain transpiler/compiler work and must not be hidden by
hand-editing generated CLEAR.

## 2026-07-11 Dependency-Closure Checkpoint

The raw 169-unit verifier after the dependency/constructor pass reports:

| Gate | Files | File % | Source LoC | LoC % | Delta from `9bfbaf879` |
|---|---:|---:|---:|---:|---:|
| G1 | 153/169 | 90.53% | 85,848/96,877 | 88.62% | +32 LoC |
| G2 | 105/169 | 62.13% | 55,675/96,877 | 57.47% | -4 files, +961 LoC |
| G3 | 7/169 | 4.14% | 245/96,877 | 0.25% | unchanged |
| G4 | 6/169 | 3.55% | 237/96,877 | 0.24% | +2 files, +166 LoC |

The apparent G2 file regression is dependency accounting, not lost frontend
coverage: 35 roots are now explicitly classified as blocked by a failed direct
generated dependency. Parser failures fell from 20 to 10 and unknown/collision
failures fell from 11 to 3. `IntrinsicEmit` and `ZigType` now pass G4.

Most importantly, the former 92-file undefined-receiver/accessor cluster and
the subsequent 87-file field/union mismatch clusters now compile through
`Scope` construction. The top fingerprint is 87 instances of the unqualified
`AST::Param#name` accessor emitted as `name()`, followed by seven post-lowering
ownership-verifier failures. The next automated batch must preserve typed
block-element receiver metadata and then fix the remaining ownership
diagnostics; broad manual CLEAR edits are still premature.
