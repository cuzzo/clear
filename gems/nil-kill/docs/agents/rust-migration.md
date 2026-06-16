# Nil-Kill Rust Migration Assessment

## Purpose

Nil-Kill infer is currently too slow to be useful on large runtime traces and is
surprisingly slow even on tiny traces. This document estimates how separable the
slow path is from collection, how much of infer should move to Rust, how much
code that would be, and how much duplicated Ruby/Rust maintenance we would
accept at each migration level.

The short version: `collect` is mostly separable from `infer`, but `infer` is
not mostly a runtime JOIN problem. The measured hotspot is legacy Ruby static
source indexing over Tree-sitter nodes. The best first Rust migration is a
native, parallel static indexer that emits the same fact tables Ruby
`SourceIndex` emits today.

## Current Profile Data

Small workload:

- Target: `gems/slopcop`
- Command: Nil-Kill collect over `gems/slopcop/test/constraints_test.rb`
- Runtime evidence: 8 JSONL files, about 88 KB useful runtime data, 280 KB
  total temp directory
- Infer command: `nil-kill infer --no-sorbet`

Observed infer cost:

- Wall time: 74.84 seconds
- User CPU: 74.63 seconds
- Max RSS: 170 MB
- CPU-bound single-core execution
- Runtime evidence size too small to explain the runtime

StackProf CPU attribution:

- `NilKill::SourceIndex#initialize`: 95.6% total time
- `TreeSitter::Node#parent`: 86.0% self time
- `NilKill::Syntax::Context#wrap`: 90.8% total time
- `NilKill::Syntax::Context#scope_locals_for`: 88.0% total time
- `NilKill::Infer#build_actions`: 0.8% total time

Perf summary for the same small infer:

- 911B instructions
- 74.37 seconds task clock
- 3.54 IPC
- 0.60% branch misses
- High reported cache-miss rate on cache references

The performance shape matches the Decomplex Rust migration lesson: the Ruby
cost is dominated by wrapper-heavy Tree-sitter traversal and repeated parent /
context reconstruction, not by business logic alone.

## Current Boundaries

Approximate relevant Ruby sizes:

| Component | File | LoC | Role |
|---|---:|---:|---|
| Runtime tracer | `runtime_trace.rb` | 1,889 | Ruby collection hook and event writer |
| Source instrumentation | `source_instrumenter.rb` | 322 | In-place Ruby wrapping for collect |
| Runtime normalization | `runtime/normalizer.rb` | 453 | JSONL merge and normalized runtime facts |
| Static source index | `source_index.rb` | 2,921 | Legacy Ruby static facts for infer |
| Tree-sitter Ruby facade | `syntax.rb` | 1,616 | Ruby wrapper API over Tree-sitter |
| Infer/action planner | `infer.rb` | 2,086 | Orchestration and action generation |
| Report renderer | `report.rb` | 4,985 | Human/SARIF/JSON report rendering |

## Separation Estimate

### Collect vs Infer

Collect is mostly separable from infer.

Collect owns:

- Ruby source instrumentation.
- Runtime trace hooks.
- Coverage and method event emission.
- JSONL runtime event files.
- Runtime freshness metadata.

Infer consumes:

- JSONL runtime files.
- Static source facts from `SourceIndex`.
- Optional Sorbet diagnostics.
- Fact joins/action generation.
- Report rendering.

Shared surface:

- Event schema and type normalization.
- Target path selection and freshness metadata.
- Method/field identifiers that must join static and runtime facts.

Estimated separability: **75-85% separate**.

The shared 15-25% is schema/identity contract, not tracing mechanics. Rust infer
does not require porting the Ruby tracer if the trace JSONL format remains
stable.

### Infer vs Static Analysis

Infer is not well-separated from static analysis today.

`Infer#index_sources` builds nearly all static facts through `SourceIndex` and
then stores those facts directly in the mutable evidence store. Action
generation assumes the shape and quirks of those fact arrays.

Estimated separability:

- Runtime loading from infer: **mostly separate**.
- Static indexing from infer: **tightly coupled today**.
- Action generation from static facts: **moderately coupled**, but separable if
  a stable `source_index.json` schema is introduced.

This is why a Rust migration should first define a native static-index artifact
instead of trying to port action generation immediately.

### Infer vs Reporting and Auto-Fix

Report rendering and auto-fix should not move first.

Reports consume evidence/actions and are large, Ruby-heavy, and lower runtime
risk. Auto-fix now belongs mostly to `auto-type` and remains Ruby/Sorbet-first.
Moving these early would maximize duplication while missing the measured
hotspot.

Estimated separability:

- Infer action generation to report: **highly separable** if evidence JSON
  stays stable.
- Infer action generation to auto-fix: **separable by action schema**, but
  provider-specific fixes should stay outside Nil-Kill.

## Should JOINs Be Done Differently?

Yes, but JOINs are not the first bottleneck measured on the small case.

The expensive "join-like" work in the profile is contextual AST lookup:

- determine scope locals for a node,
- climb parents,
- wrap raw nodes repeatedly,
- infer local/hash/return origins from surrounding context.

This should become stack-carried state during traversal, not repeated
`node.parent` queries. In Rust, a tree cursor can carry owner/scope/local state
as it walks, producing facts with stable IDs in one pass.

Runtime and action JOINs should eventually be keyed by compact IDs:

- method id: language/path/owner/name/line/kind,
- field id: language/path/owner/field,
- location id: path/line/span,
- shape id: stable hash of normalized key/value shape.

For large traces, runtime aggregation may still need a Rust or SQLite-backed
streaming layer. But the small SlopCop profile proves that porting runtime JSON
merge first would not fix the core latency.

## Parallelization Assessment

The static indexing phase is a strong candidate for Rayon-style parallelism.

Current SlopCop measurement:

- 18 files indexed.
- Each file was built twice warm and once full.
- Aggregate measured indexing cost: about 71.13 seconds.
- Slowest file lower bound with current per-file work: about 14.94 seconds.

A Rust indexer can improve this in two ways:

1. Per-file parallelism.
2. Lower per-file cost by avoiding Ruby wrappers and repeated parent walks.

Recommended Rust execution model:

1. Parse and first-pass index every file in parallel.
2. Reduce global tables deterministically:
   - no-return methods,
   - struct fields,
   - known signatures,
   - global shape/type indexes.
3. Run any dependent second-pass facts in parallel.
4. Emit one deterministic JSON fact bundle for Ruby infer to consume.

For `src/`, this should scale well because the work is spread over many files.
The main limit will be the largest individual files and the number of dependent
fixpoint passes still required after global reduction.

## Migration Options

### Option A: Rust Runtime Aggregator Only

Scope:

- Port `Runtime::Normalizer#load_legacy_ruby!` style JSONL aggregation to Rust.
- Emit compact runtime aggregate JSON or SQLite.
- Ruby keeps `SourceIndex`, action generation, reports, and auto-fix.

Estimated Rust LoC: **1,000-2,000**.

Ruby redundancy:

- Low for runtime normalization.
- Does not duplicate static source indexing.

Expected speedup:

- Useful on huge trace sets if JSON parsing/merge is hot.
- Low impact on the measured SlopCop profile because runtime data was tiny and
  static indexing dominated.

Verdict: useful later, not the first migration.

### Option B: MVP Native Static Indexer

Scope:

- Create `gems/nil-kill/rust`.
- Implement native Ruby Tree-sitter traversal for the fact subset required by
  current `Infer#index_sources` and reports:
  - methods and signatures,
  - tlet sites,
  - struct declarations and fields,
  - hash shapes,
  - tuple arrays,
  - collection lookups,
  - return origins,
  - param origins,
  - deterministic guards,
  - type normalizers.
- Emit `source_index.json`.
- Ruby `Infer#index_sources` consumes the native fact bundle when available and
  falls back to Ruby `SourceIndex` for unsupported facts.

Estimated Rust LoC: **3,000-5,000**.

Ruby adapter/compat LoC: **300-700**.

Ruby redundancy:

- Moderate. Ruby `SourceIndex` and `Syntax` remain as oracle/fallback while
  Rust emits equivalent facts.
- Redundancy is bounded to the static-index layer.
- No duplication of collect, reporting, or auto-fix.

Expected speedup:

- High. This targets the measured 95.6% hotspot.
- File parallelism alone lowers the SlopCop lower bound from about 71s indexing
  to about 15s with the current algorithm.
- Native traversal plus stack-carried scope should plausibly push the same
  workload into low single-digit seconds.

Verdict: best first step.

### Option C: Actual Rust Infer Core

Scope:

- Include Option B.
- Port runtime normalization.
- Port action planning in `Infer#build_actions`:
  - signature proposals,
  - nil param/return candidates,
  - union candidates,
  - hash-record struct actions,
  - struct field actions,
  - flow graph,
  - fallibility pressure,
  - hidden enum pressure.
- Emit the final evidence/actions JSON consumed by Ruby report/auto-type.

Estimated Rust LoC: **8,000-12,000**.

Ruby adapter/compat LoC: **500-1,000**.

Ruby redundancy:

- High during migration if legacy Ruby `Infer` remains active.
- Moderate after deleting or freezing Ruby action generation.
- Some Ruby code still remains intentionally:
  - collect/tracer,
  - report rendering,
  - auto-type integration,
  - Sorbet command execution.

Expected speedup:

- Higher ceiling after static indexing is native.
- But the measured action-generation path is not the current problem, so this is
  not necessary for the first large win.

Verdict: second-stage migration after native static-index parity is proven.

### Option D: Full Nil-Kill Rust Rewrite

Scope:

- Port collect/tracing strategy or replace it with language-provider runners.
- Port source instrumentation or eliminate Ruby in-place instrumentation.
- Port static indexing, runtime normalization, action planning, reporting, and
  potentially rewrite orchestration.

Estimated Rust LoC: **18,000-30,000+**.

Ruby redundancy:

- Very high until the rewrite is complete.
- Risk of maintaining two Nil-Kills for a long time.

Expected speedup:

- Potentially best operationally, but not justified as a first move.
- Much of the code is not in the hot path.

Verdict: not recommended now.

## Recommended Migration Plan

### Phase 1: Parity Harness

Build a deterministic parity runner before implementing the Rust indexer.

Commands should support:

```text
nil-kill source-index --engine ruby --output ruby.json TARGETS...
nil-kill source-index --engine rust --output rust.json TARGETS...
diff ruby.json rust.json
```

The comparison should canonicalize ordering and ignore purely diagnostic timing
metadata. This mirrors the Decomplex Rust migration strategy and gives a safe
oracle while porting.

Estimated LoC: **300-600 Ruby**.

### Phase 2: Rust Static Index MVP

Implement only enough native indexing to replace the hot SlopCop path.

Required facts for MVP:

- method records,
- struct/class field declarations,
- hash shapes,
- return origins,
- param origins,
- collection index lookups,
- deterministic guards,
- type normalizers.

Estimated LoC: **3,000-5,000 Rust**.

Success criteria:

- SlopCop source-index parity on `gems/slopcop`.
- `nil-kill infer --no-sorbet` on the SlopCop profile drops from 74s to under
  10s.
- No changes to collect/tracing.

### Phase 3: Native Static Index for `src/`

Expand parity coverage to CLEAR `src/`.

Success criteria:

- Parity for high-value facts used by current reports.
- Native indexer handles large files without pathological parent-chain cost.
- `nil-kill infer --no-sorbet` reaches report output on current `src/` evidence
  without multi-minute stalls.

### Phase 4: Runtime Aggregator If Needed

After native source indexing lands, profile again on full `src/` evidence.

If runtime JSONL aggregation becomes material, port normalization to Rust or
write directly into SQLite/compact binary tables.

Estimated LoC: **1,000-2,000 Rust**.

### Phase 5: Rust Action Planner Only If Hot

Only port `Infer#build_actions` after static indexing and runtime aggregation
are no longer the bottleneck.

Estimated incremental LoC: **4,000-7,000 Rust**.

## Redundancy Summary

| Migration Level | Rust LoC | Ruby Redundancy | Long-Term Risk |
|---|---:|---|---|
| Runtime aggregator only | 1k-2k | Low | Low, but misses current hotspot |
| MVP static indexer | 3k-5k | Moderate and bounded | Acceptable if parity harness exists |
| Actual Rust infer core | 8k-12k | High during migration | Acceptable only after Ruby infer is frozen/deleted |
| Full rewrite | 18k-30k+ | Very high until complete | High |

The least bad redundancy is Option B: duplicate only `SourceIndex`/`Syntax`
behavior long enough to prove parity, then make Ruby `SourceIndex` a fallback or
test oracle. Keeping two complete infer engines indefinitely would be a mistake.

## Final Recommendation

Do not port `collect` now.

Do not port runtime JOINs first.

Port the static source indexer first, in Rust, with a Decomplex-style parity
harness. `collect` is separate enough to leave in Ruby, and the measured infer
hotspot is static Tree-sitter traversal. If the native static indexer emits the
same facts Ruby infer already consumes, Nil-Kill can get the Decomplex-style
speedup without maintaining two full implementations.
