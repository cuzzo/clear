# Single Ownership Contract — Deletion-First Migration Plan

Status: Proposed

## Decision

CLEAR should have one immutable ownership contract for each typed value and
each operation that uses it. Annotation decides the contract once. Typed AST,
MIR, validation, and runtime lowering carry or consume that contract; none of
them may reconstruct ownership from syntax, names, Zig type strings, cleanup
presence, or runtime helper choice.

This is a red migration. There will be no compatibility adapter, fallback
inference, dual write, shadow comparison, feature flag, or old/new selection.
The legacy authorities are deleted first. The compiler is expected to be red
until the replacement is complete.

## Problem

Ownership is currently spread across overlapping representations:

- `Type`, placement, `SymbolEntry`, and `OwnershipGraph` hold semantic facts.
- `CleanupClassifier` reconstructs ownership and creates `CleanupEntry` values.
- `MIRPass` and lowering infer transfers, captures, moved guards, and owned
  results again from AST/MIR shapes.
- `MIR::OwnershipEffect`, `OwnershipConsumptionFact`, lifecycle marks, and
  cleanup entries describe overlapping parts of the same decision.
- generic Zig helpers correctly need structural copy/drop mechanics, but a
  caller can currently reach those mechanics after making an independent
  ownership decision.

Each local rule can appear reasonable while two phases disagree. The RC
capture use-after-free was one such disagreement: annotation produced a
borrowed view while cleanup classification treated the same capture as an
owner.

## Target Model

`Ownership::Contract` is the only semantic authority. It is immutable and has
three typed components, all under the same root object:

1. `value`
   - stable `PlaceId` or explicit temporary identity;
   - full CLEAR `Type`;
   - disposition: `owned`, `borrowed`, or `non_owning`;
   - storage/allocator provenance;
   - lifetime sources;
   - destructor specification, or `none`.
2. `operands`
   - one entry per source value;
   - action: `borrow`, `move`, `retain`, `deep_copy`, `create`, `downgrade`, or
     `upgrade`;
   - target allocator when the action creates storage.
3. `result`
   - the resulting value contract;
   - the source operation that created its cleanup obligation.

Function and intrinsic signatures use this same contract vocabulary for
parameters and results. There is no separate call-only ownership model.

The compiler derives consequences mechanically:

- `borrow` creates no cleanup obligation and carries lifetime sources;
- `move` transfers the existing obligation and invalidates the source;
- `retain`, `deep_copy`, and `create` create a new obligation;
- `downgrade` creates a weak-handle obligation;
- `upgrade` creates an optional retained result;
- scope exit must discharge every live obligation exactly once.

MIR lifecycle nodes remain useful proof events, but they are generated from
the contract rather than being a second authority. The checker verifies
conservation of obligations and agreement with the attached contract. The
emitter only maps typed actions to runtime calls.

Zig's `dupeValue`, `cleanup`, `retainOne`, and collection materializers remain
mechanical implementations for an already-authorized owned operation. They do
not decide whether a source is borrowed or owned.

## Non-Negotiable Architecture Rules

- Every ownership-relevant typed AST expression and binding has a contract.
- Every ownership-relevant MIR operation has the same contract or a stable
  reference to it.
- Missing contracts are internal compiler errors, never a cue to infer.
- No ownership decision may depend on a rendered Zig type string.
- No cleanup/transfer lookup may use a display name when a stable place or
  binding identity exists.
- The emitter cannot inspect AST nodes, `Type` ownership, or cleanup shape to
  choose ownership behavior.
- Runtime generic copy/drop helpers are callable only from a typed ownership
  action.

## Migration Sequence

### 0. Freeze the proof surface

Before demolition, keep the current green baselines:

- collection operation × Rc/Arc matrix;
- recursive struct/union/optional/materializer × Rc/Arc matrix;
- malformed-MIR borrowed-cleanup and structural-RC-copy cases;
- unit, integration, transpile, fuzz, examples, benchmarks, MiniVM, and Zig
  runtime lanes.

Add an architecture inventory that names every legacy authority listed in the
next phase. This is an inventory, not an adapter.

### 1. Delete the legacy authorities — expected RED checkpoint

Delete, in one demolition change, all code that can independently answer an
ownership question:

- `AST.capture_expr_owns_result?` and syntax-class ownership predicates;
- `CleanupClassifier` ownership reconstruction, including
  `binding_cleanup_facts`, capture-result inference, and its `classify_*`
  ownership dispatch;
- `CleanupEntry` as an independently produced semantic record;
- `MIR::OwnershipEffect.from_*` tree reconstruction;
- name/tree scanners such as `collect_ownership_transfers`, lowering ownership
  scanners, and owned-result/cleanup inference helpers;
- lowering fallbacks that select retain/deep-copy/pass-through from `Type`, AST
  class, cleanup presence, or Zig spelling;
- emitter fallbacks that infer ownership behavior from MIR shape;
- compatibility reads of absent ownership facts.

Do not add the replacement in this change. Run the full gates and save the red
manifest. It should show broad failures at every ownership boundary. A
suspiciously green area indicates an undeleted authority and blocks progress.

The architecture test must already reject reintroducing any deleted constant,
method, file, compatibility shim, or `contract || infer(...)` pattern.

### 2. Introduce the contract resolver

Add `Ownership::Contract` and one annotation-boundary resolver. It receives
typed operands, stable places, signature contracts, placement, and lifetime
facts. It is the only module allowed to choose an ownership action.

Make typed-AST verification fail closed when a relevant node lacks a contract.
Restore parser/type/annotation tests first. Do not restore MIR or runtime tests
with temporary behavior.

### 3. Make calls and generic operations use the same vocabulary

Express normal parameters, `TAKES`, `GIVE`, `COPY`, `LINK`, `RESOLVE`, return
lifetimes, collection stores, materializers, option/union coercions, and
execution-boundary captures as `Ownership::Contract` operands/actions/results.

Intrinsic registry entries must build the same contract objects as user
functions. There is no intrinsic-only ownership metadata path.

Restore the capability cross-products at this phase. Any uncovered generic
operation is a blocker, not an exclusion, unless the type system rejects that
operation before ownership is relevant.

### 4. Lower contracts mechanically into MIR

Lower each action through a closed dispatcher:

- `borrow` → borrowed value/lifetime edge;
- `move` → transfer and source invalidation;
- `retain` → typed retain op plus new obligation;
- `deep_copy` → typed deep-copy op plus new obligation;
- `create` → allocation plus new obligation;
- weak actions → typed downgrade/upgrade ops.

Generate lifecycle proof nodes from these actions. MIR lowering may choose
representation details, but it may not change disposition, allocator,
lifetime, or cleanup ownership.

Restore MIR snapshots, hoisting, branch/loop, error, FSM, and concurrency tests.

### 5. Replace validation with contract conservation

The MIR checker verifies:

- every ownership operation has a contract;
- every owned result creates exactly one obligation;
- every move transfers one existing obligation;
- borrowed/non-owning values are never cleaned or moved;
- retain/deep-copy create independent obligations;
- direct structural Rc/Arc copies are impossible;
- joins agree on disposition, allocator, and lifetime;
- every exit discharges or transfers every live obligation exactly once.

Delete validators made redundant by this conservation model rather than
keeping both sets “for safety.” Restore malformed-MIR negative tests only
through the new validator.

### 6. Restrict runtime and emission to typed actions

The emitter accepts only closed MIR ownership operations. Remove generic
fallback emission. Each runtime copy/drop/materializer entry point must be
reachable from an explicit contract action, and tests must cover Rc and Arc
through direct, optional, struct, union, list, map, pool, and legal sharded
shapes.

### 7. Prove the old system cannot return

The final architecture gate fails if:

- any deleted legacy symbol or file returns;
- an ownership-bearing node has a nil contract;
- a phase invokes ownership inference outside the resolver;
- cleanup or transfer decisions use names instead of stable identities;
- MIR or emission branches on Zig strings for ownership;
- a fallback supplies ownership when the contract is absent.

Run all GitHub CI-equivalent gates. The migration is complete only when the
full repository is green and the forbidden-legacy inventory is empty.

## Commit Discipline

Use a dedicated migration branch with these reviewable checkpoints:

1. proof-surface inventory, green;
2. legacy demolition, intentionally red with saved failure manifest;
3. contract resolver and typed AST, partially green;
4. calls/generic operations, cross-products green;
5. MIR lowering and conservation checker, compiler green;
6. runtime/emitter closure, repository green;
7. architecture proof that legacy paths are absent.

No checkpoint may introduce a second implementation to reduce failures. If a
vertical area cannot yet use the contract, it remains red until it can.
