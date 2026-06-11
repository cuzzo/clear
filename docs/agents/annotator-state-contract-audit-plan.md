# Annotator State And Contract Audit Plan

This note records two report-backed architecture findings and a conservative
plan for deciding whether they justify code changes. The intent is not to start
a broad rewrite. The first job is to prove which state and contracts are
actually harmful, which are already isolated well enough, and which are worth
leaving alone.

## Findings

### Implicit Mutable Lifecycle State

SemanticAnnotator has 35 state slots in `gems/espalier/architecture.yml`, and
Espalier flags `@receiver_state` with 32 readers / 2 writers
(`gems/espalier/report.md:115`). The source shows stack-like state protocols for
function contexts, held locks, and snapshot frames
(`src/annotator/annotator.rb:228`, `src/annotator/annotator.rb:489`). These
protocols are handled carefully, but the design is order-sensitive.

The current source already moved much of the old ambient annotator state behind
`@receiver_state`, so the first step must reconcile report data with the current
implementation. If a slot is no longer independently owned by
`SemanticAnnotator`, it should not motivate a major refactor by itself.

### Loose Core Contracts

Nil-kill says core contracts are still too loose. It reports 78 `AstNode`
heterogeneous param slots and 135/192 heterogeneous params collapsing to 3
aliases (`gems/nil-kill/report.md:217`). It also points to `.type`,
`.return_type`, `.resolved_type`, and `full_type!` guard-collapse
opportunities. That is a sign the AST/type boundary still uses broad unions and
defensive checks where typed contracts should carry the invariant.

This is a real signal, but not every broad AST slot is a bug. Some slots are
deliberate walkers over the whole AST. The actionable work is to distinguish
intentional traversal from places where a method only needs a narrow semantic
protocol but accepts a grab-bag.

## Concrete /plan

This is the plan to execute before changing implementation. It starts by
proving ownership, then chooses the smallest code slice that can improve an
actual report signal.

### 1. Annotator Lifecycle State

#### Plan

1. Reconcile the report with current source.
   Espalier reports 35 state slots on `SemanticAnnotator`, but the current
   source mostly has a single mutable session object, `@receiver_state`, plus a
   small set of durable run fields such as importer, source path, registries,
   semantic index, program root, and branch termination. Treat the 35-slot
   number as a prompt to inspect ownership, not as proof that 35 raw annotator
   ivars exist today.
2. Classify each state as session/config, phase product, active lifecycle
   stack, or domain-local scratch. Only active lifecycle stacks are candidates
   for extraction in this pass.
3. For each active lifecycle state, prove why it must be reachable from
   `SemanticAnnotator` and whether the detailed protocol belongs somewhere
   narrower.
4. Pick one implementation slice only if it removes raw lifecycle protocol from
   the annotator or makes an invariant directly testable. Otherwise record the
   debt and make no code change.

#### State Residency Findings

| State | Why it must be reachable from the annotator | Does it belong directly on the annotator? | Proposed solution |
| --- | --- | --- | --- |
| `@receiver_state` | The annotator is implemented as a visitor assembled from many included domain modules. Those modules need a shared per-run context while one recursive annotation traversal is in progress. | Yes as a session root. It is already a narrower owner than raw `SemanticAnnotator` ivars. | Keep `ReceiverState` as the session object. Do not try to eliminate it unless the visitor/mixin architecture changes. |
| `function_contexts` | Return type, lifetime, type params, frame use, heap use, alloc counts, loop depth, and conditional depth are read by function, generic, effect, pipe, expression, lifetime, and execution visitors during one function traversal. | It must be reachable through the annotator facade, but the stack protocol does not need to be a raw array forever. `FunctionContext` already owns the per-function data. | Keep the current `current_fn_ctx`, `push_function_context!`, and `pop_function_context!` facade. Consider a typed `FunctionContextStack` only if it deletes stack-shape checks, adds mismatch protection, or improves Decomplex/nil-kill pressure. Do not extract just to move code. |
| `held_locks` / `held_lock_types` | WITH blocks install active lock facts that expression, capability, effect, and lock-order checks need while traversing nested calls. The facts are lexical, but the readers cross annotator domains. | The facts must be reachable from the annotator, but the detailed save/dup/restore protocol is a better fit for a lock context. | This is the best practical state cleanup candidate. Add a typed `HeldLockContext` or extend `LockAnalysisState` with active lock scope methods, while preserving existing annotator facade methods. It should own `with_locks`, rank/type lookup, and restoration in `ensure`. |
| `snapshot_txn_frames` | Snapshot transaction bodies collect purity violations during a nested visit, then report them after the body is analyzed. Effects and execution-boundary logic both need to query the active state. | It can remain under `ReceiverState`; all mutation is already centralized in the annotator-level transaction helper. | Defer extraction. Add a `SnapshotTxnContext` only if transaction modes grow or if a focused slice can remove branches and add meaningful invariant tests. |

#### Proposed Solution

Do not perform a broad "remove annotator state" refactor. The current design has
already consolidated ambient state into `ReceiverState`, and the annotator still
needs a shared session root because of the visitor/mixin architecture.

If we take a state cleanup slice, start with held-lock lifecycle state. It has
the strongest practical case because it combines active lexical state, map/list
restoration, ordering facts, and cross-domain readers. The target shape is:

- a typed lock context object held by `ReceiverState`;
- public annotator facade methods kept stable for existing modules;
- focused specs for nested lock restoration, rank ordering, and ensure-time
  cleanup;
- Decomplex flat or improved in the touched files;
- no unrelated cleanup to offset metric movement.

Function context and snapshot transaction wrappers should be deferred unless a
later metric or feature change proves a larger benefit. Moving them now would
mostly add indirection around protocols that are already centralized.

### 2. Loose Core Contracts

#### Plan

1. Use nil-kill's `AstNode` pressure to rank investigation, not to mechanically
   introduce one giant `AstNode` union.
2. Separate intentionally broad AST traversal from weak semantic contracts.
   Whole-tree walkers such as child wrapping and background traversal are
   supposed to accept many node shapes. Methods that only need `#full_type!`,
   `#token`, `#value`, `#resolved_type`, or a concrete `Type` fact should not.
3. Classify top hotspots into:
   - accepted broad walkers;
   - boundary normalizers that should remain broad but be isolated;
   - narrow semantic helpers that should get stronger signatures or a small
     named protocol alias.
4. Implement only the smallest slice that improves the targeted nil-kill signal
   without creating broad call-site churn.

#### Contract Findings

| Hotspot class | Why it is loose today | Proposed solution |
| --- | --- | --- |
| Whole-AST walkers | Generic traversal helpers intentionally see many node classes and container shapes. Typing them as a huge `T.any(...)` would make the code noisier without proving a stronger invariant. | Mark these as accepted broad contracts, or give them a semantic alias only if the alias names a real protocol. Do not make a giant `AstNode` union the default answer. |
| Type boundary slots such as `.type`, `.return_type`, `.resolved_type`, and `full_type!` | Parser and tests can still create raw type specs, while annotator phases want normalized `Type` facts. That leads to defensive checks after the phase boundary. | Introduce or tighten small boundary helpers that normalize raw type specs once and return concrete `Type` or `T.nilable(Type)` facts. Prefer reducing repeated probes over changing every AST slot at once. |
| Diagnostic and source-location APIs | Error reporting accepts AST nodes, lexer tokens, and sometimes raw strings or symbols for messages/codes. That is a useful boundary, but the current broad signature hides the intended protocol. | Add explicit aliases or split entrypoints such as diagnostic site and diagnostic message/code. Keep the legacy wrapper during migration if call-site churn would be high. |
| Small annotator helpers with broad `node` params | Some helpers accept a grab-bag of AST nodes but only read one capability, such as `#value`, `#token`, or `#full_type!`. | Audit callers and narrow these first when the caller set is small. Good candidates are capture-site recording and borrow-return classification, because they are localized compared with whole-AST walkers. |

#### Proposed Solution

Do not try to "solve" nil-kill by adding huge aliases. The practical approach
is a staged contract cleanup:

1. Document accepted broad traversal contracts so they stop driving broad
   refactor decisions.
2. Pick one narrow contract slice with a small caller set. The first likely
   slice is annotator helper narrowing, not a full AST type-slot rewrite.
3. For `.type` / `.return_type` / `.resolved_type` pressure, add or tighten
   phase-boundary normalization helpers that return concrete `Type` facts, then
   replace repeated defensive checks only where the normalized invariant is
   proven.
4. Re-run nil-kill after each slice and continue only if the targeted alias or
   guard-collapse count improves without Decomplex regression.

The larger AST/type boundary should be improved incrementally. A sweeping
rewrite of AST field types is not justified until the reports show that smaller
normalization and helper-signature fixes cannot collapse the repeated guards.

## Decision Criteria

Make no major change unless it produces a major benefit. A proposed change is
worth doing when it has a concrete before/after claim:

- Decomplex total is flat or improves, and the targeted detector count drops.
- Nil-kill guard-collapse or untyped pressure improves for the targeted
  contract.
- SlopCop/Boobytrap do not expose new untested branch risk in the touched code.
- The resulting code has a clearer single owner for one lifecycle protocol or
  one type contract.

If the metrics are neutral and the code is only cosmetically cleaner, document
the accepted debt and leave the implementation alone.

## Verification For Any Future Slice

Each future implementation slice should run:

- focused `bundle exec prspec ...` for the touched annotator/AST behavior;
- `COVERAGE=1 bundle exec prspec spec/` when behavior crosses shared compiler
  boundaries;
- Decomplex before and after the slice;
- nil-kill recollect/infer/report only for changes that alter Sorbet contracts
  or annotation fact shapes;
- SlopCop and Boobytrap at the end of a multi-slice cleanup.

New or changed Ruby code must remain strongly typed. Changed branch coverage
should stay above 80%, and any generated report movement should be explained
before continuing.
