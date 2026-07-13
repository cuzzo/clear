# Automatic Indirection and Layout Elision

Status: Implemented (constrained form)

Scope: EASY-mode storage-layout elision for `@indirect`, and the boundary
between automatic placement and explicit representation choices

Related: `docs/agents/auto-copy-clone.md`, `docs/agents/graph.md`

Implementation note (2026-07): CLEAR models collection-element layout as an
independent type axis, so `Foo@indirect[]@list` is a list of unique `*Foo`
elements while `Foo[]@list:indirect` is a unique box around a list of inline
`Foo` elements. Resolved intrinsic signature metadata—not method names—marks
consuming collection transport. EASY can move a direct payload into an
explicitly indirect element destination; DEFAULT and STRICT require an
explicit `@indirect` construction. A consumed unique box can move its payload
into an inline element and release only the empty allocation shell. If the
source remains live, the compiler rejects the hidden deep copy. Bare recursive
types now always produce fixable topology choices rather than silently choosing
one representation.

## 1. Decision

CLEAR should permit EASY mode to omit `@indirect` syntax only when the
program's already-resolved contract has fixed an indirect representation and
the compiler is merely elaborating the source into that contract. The
elaborated program must have exactly the same representation, allocation
count, ABI, cleanup, and runtime work as the explicit spelling.

DEFAULT and STRICT modes keep storage layout explicit. In every mode, if more
than one materially different layout is valid, the compiler must reject the
program and provide fixable alternatives with their performance consequences.
EASY is allowed to erase plumbing; it is not allowed to erase a performance
decision.

This document therefore rejects the broad proposal that EASY should box a
value because it escapes, enters a collection, or happens to be recursive. It
also narrows an earlier version of this design: even a uniquely recursive
field is not silently boxed by default. `@indirect`, `@node`, an indexed
arena, and a different contiguous formulation can have radically different
allocation and cache behavior. The fact that only `@indirect` preserves the
exact invalid inline spelling does not make it the uniquely best program.

This is deliberately narrower than “box every value that escapes.” Escape, ownership, and representation are separate questions:

- Moving `Foo` into a `Foo[]@list` stores `Foo` inline in the list. It does not require a box.
- Moving `Foo` into an inline global slot changes its storage location, not its representation.
- `Foo@indirect` changes the representation to a pointer-backed allocation and can change allocation count, ABI, cache locality, address stability, and destruction behavior.
- `Foo@node` selects a graph domain and compact handle representation; it is not merely spelling for a box.

The compiler must preserve these distinctions.

The most important terminology is:

- **Placement** answers where an already-fixed representation is constructed
  or moved. Stack-to-destination placement can often be optimized away.
- **Representation** answers whether a value is inline, pointer-backed,
  handle-backed, reference counted, or domain-managed. This changes the cost
  model and often the ABI.
- **Ownership transport** answers whether an operation moves, borrows, copies,
  or retains that representation.

Escape analysis may automate placement. It must not silently choose
representation or identity semantics.

## 2. Goals

The feature must support CLEAR's priorities:

1. Minimize global complexity and maximize local reasoning. A declaration or destination contract determines layout; callers do not need whole-program knowledge of a callee's implementation.
2. Maximize optionality. EASY removes a forced annotation, DEFAULT exposes layout, and STRICT exposes every potentially costly ownership operation.
3. Minimize cognitive complexity. Users need not name a representation when there is only one valid, cost-equivalent answer.
4. Maximize safety. No stack address may escape, no recursive value may have infinite size, and no inferred box may be used to conceal ambiguous aliasing.
5. Preserve near-perfect performance. Inferred and explicit `@indirect` must lower through the same MIR and runtime operations. The inference feature must add no allocation, copy, branch, header, or pointer chase beyond the explicit representation.

“Perfect performance” here means parity with the best explicit spelling of the same chosen representation. It does not mean that a pointer-backed recursive structure is universally as cache-efficient as an inline array, `@node`, or a purpose-built arena.

## 3. Relationship to Automatic Copy/Clone

Automatic ownership transport and automatic indirection solve different problems and must remain separate compiler decisions.

- Auto copy/clone selects how a value is transported: move, borrow, copy, or an explicit user-selected sharing operation.
- Auto-box selects a physical representation only when indirection is already forced.
- Layout is resolved before ownership transport. Later compiler phases consume the resolved contract; they must not independently reconstruct it.
- Boxing never resolves alias ambiguity and never authorizes an implicit `@shared`/`@multiowned` upgrade.
- Mutation between inferred alias creation and the alias's last use is a compile error in EASY, DEFAULT, and STRICT. The diagnostic must require an explicit reference-counted alias when shared identity is intended, or an explicit copy when a snapshot is intended.

An inferred allocation must therefore not become a back door around the universal mutation-collision rule in `auto-copy-clone.md`.

The two designs should use the same cost principle:

- zero-runtime-cost moves and borrows are always eligible for automatic
  elaboration;
- trivial fixed-size value copies are eligible when they are equivalent to
  ordinary ABI value passing;
- retaining a capability already declared `@multiowned`, `@shared`, `@link`,
  or `@node` may remain terse because the declaration fixed identity and made
  its cost family locally visible;
- an unbounded or managed deep copy is potentially expensive and should
  normally be a fixable `COPY` error, not an invisible optimization; and
- a new box is allowed without call-site syntax only when an explicit resolved
  destination contract already requires that allocation.

This is slightly stricter than the current recommendation in
`auto-copy-clone.md`, which permits automatic non-mutating deep
materialization in EASY and DEFAULT. Before shipping both features, CLEAR
should choose one consistent hidden-cost policy. This document recommends a
cost threshold: automatic transport may keep source simple when the selected
operation is zero-cost, statically trivial, or already exposed by a declared
capability/destination; otherwise compilation emits a fixable error. A
profile-only warning is too weak for an unbounded copy in a loop.

## 4. Mode Policy

| Mode | Types | Ownership transport | Storage layout |
|---|---|---|---|
| EASY | Mostly inferred | Infer move/borrow/trivial copy and capability-preserving retain; never guess across mutation; require explicit potentially expensive deep `COPY` | Elide construction only after a contract fixes `@indirect`; do not infer opportunistic boxes |
| DEFAULT | Explicit, with local inference | Apply the same transport cost threshold as EASY; representation and potentially expensive deep `COPY` remain explicit | Explicit |
| STRICT | Explicit | Reject hidden cost; require explicit costly copy/share operations | Explicit |

DEFAULT does not infer `@indirect`. Explicit types are a local contract for layout and API shape. Silently changing an inline `Foo` to a pointer-backed `Foo@indirect` would invalidate cache, allocation, and ABI reasoning.

STRICT has the same layout rule and additionally rejects any hidden costful ownership transport. Zero-cost moves and borrows may still be proven and lowered without runtime work.

The modes are policy filters over one resolved layout and ownership plan. They
must not have separate inference engines:

- EASY may omit type and constructor syntax when the same plan is provable;
- DEFAULT requires the representation-bearing type contract but can still
  elide zero-cost ownership plumbing; and
- STRICT requires every cost-bearing representation and transport decision to
  be explicit.

## 5. When EASY May Elide `@indirect` Syntax

### 5.1 Recursive declarations require a layout choice

An unboxed recursive value has infinite size:

```clear
STRUCT Node {
  value: Int64,
  next: ?Node
}
```

`next` must be indirect in order to preserve this exact structural type:

```clear
STRUCT Node {
  value: Int64,
  next: ?Node@indirect
}
```

However, EASY should not silently select that result. The source may instead
be expressing a lifecycle-bounded tree/graph that should use `@node`, an
indexed arena, or a flat collection. Those alternatives do not preserve the
invalid inline representation, but they may be the correct and dramatically
faster program.

The default diagnostic should therefore offer explicit, costed fixes. It may
offer `next: ?Node@indirect` as the first fix for unique ownership, but applying
that fix is a developer decision. If CLEAR later adds a declaration whose
semantic family is inherently reference-shaped, such as an explicitly
declared reference aggregate, recursion within that family can be automatic
because the declaration itself fixed the representation.

If a recursive strongly connected component has several valid cycle-breaking edges, choosing one can additionally change object size, pointer-chasing direction, allocation behavior, and traversal performance. A deterministic compiler preference is not sufficient: determinism does not make the alternatives performance-equivalent.

### 5.2 An explicit resolved destination contract

EASY may insert construction of `Foo@indirect` when the local destination or callee ABI already requires `Foo@indirect`:

```clear
FUNCTION remember(value: Foo@indirect) TAKES value DO
  # ...
END

x = Foo{}
remember(x)
```

The signature made the representation and allocation family explicit. EASY
only elides the call-site constructor. The compiler must allocate directly into
the destination representation rather than create a heap-independent temporary
and relocate it later. DEFAULT and STRICT may require the explicit constructor
according to their cost policy, but all three modes consume the same resolved
coercion plan.

This is ordinary coercion to an explicit contract, not caller-specific ABI inference.

The same rule applies when an EASY-inferred local is initialized directly into
an explicitly indirect field. It does not justify changing an inline local or
collection element into an indirect representation elsewhere.

## 6. When EASY Must Not Infer `@indirect`

### 6.1 Collection or global escape alone

```clear
x = Foo{}
values.append(x)
```

If `values` is `Foo[]@list`, the correct representation is an inline `Foo` element. Boxing it would add an allocation and pointer chase and destroy contiguous layout. Escape analysis may choose the destination storage, but it must not change the value representation.

The same rule applies to globals and returned aggregate values. An owned inline destination may receive a move directly.

### 6.2 Callee implementation behavior

```clear
x = Foo{}
bar(x)
```

A normal borrowed parameter cannot secretly retain `x` in a global. If `bar`
retains ownership, that requirement must appear in its type/effect contract,
such as `TAKES`, and its storage representation must be visible in the
destination or parameter type where relevant.

Even then, `TAKES Foo` does not mean `TAKES Foo@indirect`. A flat `Foo` may be
moved by value into an inline global or collection without boxing. If the
callee stores into an indirect global, either its parameter/destination
contract exposes that representation or the callee performs an explicit
cost-bearing conversion internally. The caller ABI must not change because a
callee body was edited.

Ordinary CLEAR user-struct parameters are already representation-polymorphic:
the Zig backend emits `anytype`, so the same source function accepts inline
`T`, frame pointers, `T@indirect`, and other compatible pointer-backed forms,
with Zig specializing and auto-dereferencing at each call site. Auto-box work
must preserve that property. A reader such as `FN read(x: Foo)` does not need
its signature rewritten merely because one caller has `Foo@indirect`.

A signature needs an explicit indirect contract only when indirection itself
is semantically relevant: the function takes ownership of the box, returns or
stores the box as such, requires stable address/identity, mutates through that
specific representation, or exposes a concrete public/FFI ABI. These are much
rarer than ordinary calls.

The compiler must not inspect `bar`'s body, discover a global store, and invent a caller-side box. That would make local reasoning depend on implementation details and would make separately compiled ABIs unstable.

### 6.3 Optional optimizations

EASY must not infer a box merely because it might avoid a future copy, might stabilize an address, or might make one branch cheaper. Those are trade-offs, not forced equivalences. The compiler must retain the inline representation or emit a diagnostic if the program requires the user to choose.

### 6.4 Ambiguous topology

For graphs, parent pointers, many-to-many cycles, or large recursive collections, `@indirect`, `@node`, and explicit shared ownership have different semantics and performance profiles. EASY must not choose among them.

The diagnostic should normally recommend `@node` for a lifecycle-bounded graph, `@indirect` for unique pointer-owned recursion, and `@shared`/LINK for independently owned cross-domain aliases.

### 6.5 Address stability and self-reference

Heap placement alone does not make a type safely self-referential. A value may
need pinning, staged initialization, or a handle-based design if an interior
pointer can refer back into its payload. EASY must not infer `@indirect` as a
way to make an otherwise illegal self-reference compile unless the existing
`@indirect` contract explicitly guarantees the required address stability and
initialization protocol.

### 6.6 Unbounded recursive destruction

A linked structure with one allocation per edge can have costly allocation
churn and recursively cascading destruction. A million-element linked list
must not acquire stack-overflow risk or an unexpected long destructor chain
because EASY silently chose boxes. Diagnostics for recursive layouts should
surface this risk and prefer `@node`, an arena, or a contiguous representation
for potentially large topologies.

### 6.7 Equality, copying, serialization, and reflection

An inferred pointer must not accidentally expose pointer identity where the
source type promised value semantics. Structural equality, deep copy,
serialization, schema hashes, reflection, and pattern matching must operate on
the resolved language type, not on an incidental backend pointer. If adding
indirection would change any of those observable operations, it is not a legal
elision.

## 7. Construction and ABI Rules

The compiler resolves representation before MIR lowering.

1. Type/schema analysis identifies layout cycles and explicit destination contracts.
2. The mode policy either admits EASY syntax elision for an already-fixed contract or emits a fixable layout-choice error.
3. The typed AST records the resolved storage contract.
4. Ownership/escape analysis chooses move, borrow, copy, and destination placement without changing that contract.
5. MIR contains the same explicit heap creation, allocation mark, transfer, and cleanup operations used by source-written `@indirect`.
6. MIR validation rejects late pointer casts, stack-address escapes, missing allocation rollback, duplicate cleanup, and any attempt to infer representation during code generation.

There must be no “stack first, migrate later” implementation. When indirection is required, construction is planned directly in its final storage. There must also be no legacy and inferred lowering path: inference produces the existing explicit semantic form before lowering.

Exported and separately compiled interfaces must have materialized, stable layout contracts. EASY may infer an internal function's signature while compiling its whole module, but the resolved interface must be recorded before callers are compiled. A public ABI cannot vary by call site.

Public and serialized schemas should be stricter than private locals. An
exported recursive type, FFI type, persistent schema, or cross-module generic
specialization must materialize its representation in interface metadata and
should require source-level explicitness when changing that representation is
an ABI or data-format change. EASY inference must never make recompilation of
an implementation silently alter downstream layout.

### 7.1 Semantic elision and source materialization are separate options

Automatic ownership and layout features should elaborate source into a typed
semantic plan. The compiler core and ordinary build must remain read-only and
hermetic: compiling a checkout must not modify that checkout. The simple
spelling may remain canonical when the operation is safely elidable.

Separately, the compiler should emit a complete machine-applicable fix plan.
An IDE, language server, or explicit authoring command such as
`clear fix --materialize-layout` may write `@indirect` through constructors,
locals, fields, and function signatures. This can be a sophisticated
constraint-solving autofix rather than a one-token suggestion.

EASY authoring mode may enable safe layout autofixes by default. DEFAULT and
STRICT may expose the same engine behind an opt-in editor/project setting.
Applying the fix does not relax either mode: it makes the selected contract
explicit so the resulting source satisfies that mode.

This preserves both options:

- application code can remain Ruby/Python-like when the compiler has a proof;
- performance-sensitive code can materialize every inferred decision without
  changing semantics or selecting a different lowering path.

The compiler must never “learn” from the materialized spelling through a
second code path. Explicit source, an unapplied fix overlay, and EASY-elided
source normalize to the same fact and the same MIR operation.

### 7.2 Autofix safety classes

The fix engine must distinguish propagation from choice:

1. **Mechanical propagation may auto-apply.** Once an explicit declaration or
   destination has fixed `Foo@indirect`, EASY may automatically update a
   private constructor, inferred local, or the uncommon private signature
   whose semantic contract must preserve the box. Ordinary struct parameters
   remain representation-polymorphic and must not be rewritten unnecessarily.
   The resulting program has the same already-selected representation and
   cost.
2. **Representation choice requires confirmation.** A bare recursive schema,
   body-derived global escape, optional optimization, or choice among
   `@indirect`, `@node`, inline handles, and `@shared` has materially different
   costs or semantics. The tool may prepare every alternative but must not
   choose one merely because EASY autofix is enabled.
3. **Public changes require confirmation.** Exported signatures, FFI types,
   serialized schemas, trait/interface requirements, and separately compiled
   generic APIs may never auto-change. The fix must show the ABI/data-format
   impact and all affected call sites.
4. **Cost-bearing propagation remains visible.** Even when an explicit
   destination has made allocation unavoidable, an on-by-default EASY fix
   should report that it inserted allocation and fallibility. `NO_HEAP`, hot,
   real-time, and other constrained scopes turn the fix into an error.

The tool may produce a project-wide patch after a user chooses a
representation. That patch can update every affected instantiation and private
signature in one operation, which avoids making the user manually chase type
errors. It must be derived from resolved type/layout facts, not a textual
walker or callee-body guess.

Recommended authoring defaults:

| Mode | Default autofix policy | Optional policy |
|---|---|---|
| EASY | `safe`: auto-apply private mechanical propagation; prompt for representation choices and public changes | `off` or `prompt-all` |
| DEFAULT | `off`: emit fixable diagnostics | `safe` or explicit `materialize` command |
| STRICT | `off`: require explicit source | explicit `materialize` command that applies fixes before recompilation |

CI and non-interactive builds are always read-only regardless of authoring
policy. A repository may check in the resulting explicit edits, including
private signature changes, so future compilation does not need to rediscover
the source materialization.

### 7.3 Compile-time complexity budget

Schema strongly connected components, destination contracts, and existing
escape/ownership facts are sufficient for this design. It does not justify a
new whole-program escape walker, call-graph fixpoint, or backward syntax scan.
Layout facts should be produced during ordinary declaration/type analysis and
consumed by the same ownership planner used by every mode. If a proposed
inference requires inspecting arbitrary callee bodies or repeatedly
re-specializing public ABIs, it violates the local-reasoning requirement even
before runtime cost is considered.

## 8. Diagnostics and Fixes

When inference is not provably cost-equivalent, the compiler should issue a fixable diagnostic such as:

```text
error[E_LAYOUT_CHOICE]: this value requires an explicit storage layout
  `Node` cannot be inline and the valid recursive representations have different costs

  fix: use `Node@indirect` for unique heap-owned identity
       one allocation and pointer traversal per indirect value
  fix: use `Node@node` for a lifecycle-bounded graph domain
       compact handles, paged storage, and automatic domain cleanup
  fix: use an inline `Node[]@list` representation
       contiguous elements; express edges as indices or handles
  fix: use `Node@shared` when ownership crosses independent lifetimes
       reference-counting and synchronization costs apply
```

DEFAULT and STRICT should use the same diagnostic when source omits a required layout annotation. Fixes must edit the type or construction site; they must not silently change the generated representation.

Compiler explanation output should report every elided EASY indirection and
its proof, for example “explicit destination requires `Foo@indirect`.” It
should report rejected recursive choices separately, including the estimated
allocation and locality consequences of each fix. This keeps hidden syntax
observable without charging ordinary users for it.

## 9. Resource and Failure Semantics

Inferred `@indirect` has exactly the existing RAII contract:

- allocation failure is propagated without leaking partially initialized fields;
- field destructors run once in reverse initialization order;
- moved values are not destroyed at the source;
- destination destruction releases the allocation exactly once;
- optional/union transitions clean the previously active payload correctly;
- nested managed payloads preserve their ownership capability;
- panics/errors during construction use the same rollback path as explicit construction.

No tracing collector or delayed cleanup is introduced.

Allocation is also an effect and a failure boundary. If `@indirect`
construction can fail, EASY may omit the constructor spelling only when the
surrounding function already admits the resulting error/effect or when normal
EASY effect inference can expose it at the function boundary. It must not:

- turn a promised infallible public function into a fallible ABI;
- hide allocation inside a `NO_HEAP`, real-time, interrupt, or equivalent
  constrained context;
- retry allocation with a different ownership action;
- abort where explicit `@indirect` would propagate an error; or
- introduce allocation into a loop whose declared cost policy forbids it.

DEFAULT and STRICT diagnostics should point to both the representation fix and
the required `HEAP`/fallibility contract. EASY may infer private effects, but
exported effects must remain stable and inspectable.

## 10. Verification Plan

Implementation is complete only with:

- positive tests for explicit indirect recursion and EASY coercion into already-resolved indirect destinations;
- compile-fail tests for bare direct recursion, optional recursion, multiple recursive edges, mutually recursive SCCs, DEFAULT omission, STRICT omission, and mutation collisions;
- layout assertions proving `Foo[]@list` remains contiguous and unboxed;
- generated-MIR/ABI equivalence tests between inferred EASY and explicit `@indirect` programs;
- allocation-count and instruction-level benchmarks proving no additional allocation, copy, branch, or pointer chase versus explicit `@indirect`;
- allocator-failure injection at every construction step;
- destructor-count oracles for scalar, managed, optional, union, collection, and nested payloads;
- fuzz matrices spanning mode, source/destination, recursion shape, ownership capability, move/borrow/copy, overwrite, error exit, and allocation failure;
- module-boundary and separate-compilation tests proving stable interfaces;
- regressions proving collection/global escape does not cause boxing;
- regressions proving inferred boxing cannot suppress alias-mutation errors;
- effect/fallibility tests proving an elided constructor cannot change a public ABI or enter `NO_HEAP`/equivalent scopes;
- equality, serialization, reflection, and schema-hash equivalence tests;
- deep-chain teardown tests proving the explicit representation's destruction behavior is preserved and diagnosed where it is unbounded;
- compile-time benchmarks proving fact production remains linear in declarations and ordinary annotation events rather than adding a whole-program walker.
- autofix tests proving project-wide constructor/private-signature propagation is complete, deterministic, idempotent, and produces the same MIR as an unapplied EASY overlay;
- guard tests proving default autofix never edits public/FFI/serialized contracts or chooses among materially different layouts.

## 11. Acceptance Criteria

The feature may ship only when all of the following are true:

1. EASY source can omit construction syntax when an already-resolved destination contract requires `@indirect`.
2. The inferred program has the same resolved type, MIR, ABI, allocation count, cleanup behavior, and benchmark performance as its explicit equivalent.
3. No bare recursion, ordinary escape, list insertion, global move, or return causes opportunistic boxing.
4. DEFAULT and STRICT require explicit layout whenever representation is not already fixed by a destination contract.
5. Every ambiguous or potentially performance-affecting choice is a fixable compile error in every mode.
6. Mutation across an inferred alias is rejected in every mode.
7. The implementation reuses the explicit `@indirect` lowering and runtime path; no parallel compatibility path exists.
8. Allocation failure/effect behavior, equality, serialization, reflection, and public ABI are identical between elided and explicit source.
9. Potentially unbounded deep copies and representation-changing allocations remain explicit, fixable decisions.
10. EASY's default authoring autofix may propagate an already-fixed private layout, while public or performance-selecting changes require confirmation.
11. DEFAULT/STRICT can opt into the same source-materialization tool without creating a second type checker or weakening their compile policy.

## 12. Design Corrections and Previously Missing Hazards

The motivating proposal had the right high-level distinction between EASY,
DEFAULT, and STRICT, but it did not fully account for these issues:

1. **Escape does not imply boxing.** A value can move directly into an inline
   list, global, return slot, coroutine frame, or callee-owned destination.
   Boxing on escape would often pessimize the correct code.
2. **Finite layout does not imply optimal layout.** Making recursive syntax
   compile with one box per edge may be dramatically worse than `@node`, an
   arena, indices, or a flat representation.
3. **Optional recursion is still allocation.** `?Node@indirect` avoids an
   allocation for `NIL`, but every present edge still allocates and pointer
   chases. Optionality does not make the choice free.
4. **Allocator provenance is semantic.** A box retained globally cannot use a
   caller frame allocator. The destination contract must determine allocator,
   lifetime, rollback, and deallocation; inference cannot guess among frame,
   arena, domain, and general heap allocation.
5. **Allocation changes effects and failure.** An elided constructor may add
   `HEAP`, OOM propagation, cleanup rollback, and loop cost. Public fallibility
   and constrained scopes must remain stable.
6. **Heap address is not shared ownership.** Boxing does not make a value safe
   to alias, mutate concurrently, or send across schedulers. `@shared`,
   `@shared:node`, locks, atomics, or explicit transfer rules remain required.
7. **Self-reference may require pinning.** Allocating a payload indirectly is
   insufficient if interior addresses are observed before initialization or
   if the representation can later move.
8. **Destruction can become adversarial.** Per-node allocation and recursive
   RAII teardown can cause allocator churn, long destructor chains, or stack
   overflow even without a tracing collector.
9. **ABI and persistence outlive inference.** Public, FFI, serialized, and
   separately compiled schemas cannot silently change when implementation
   escape facts change.
10. **Generics need one materialized contract per ABI.** An internal
    monomorphization may consume resolved layout facts, but a generic public
    interface cannot be inline for one caller and indirect for another unless
    that distinction is explicitly part of specialization and interface
    metadata.
11. **Backend pointers must not leak semantics.** Equality, hashing,
    reflection, matching, copying, and serialization cannot accidentally
    become pointer-identity operations.
12. **Build semantics and source mutation are separate.** The compiler should
    elaborate a typed plan without requiring an edit. An EASY authoring tool
    may auto-apply safe private propagation as an explicit, reviewable source
    transaction; builds themselves remain read-only, and compilation cannot
    depend on whether the editor/fixer ran.

These are why auto-boxing is materially harder than auto move/borrow. The
compiler already has most facts needed for safe placement, but representation
selection changes more observable contracts and admits more performance
trade-offs.

## 13. Recommendation

Implement this constrained EASY-only syntax elision. It advances CLEAR's
“Ruby/Python ease with systems performance” goal precisely where a destination
or declaration has already made the representation decision, while preserving
DEFAULT's local layout reasoning and STRICT's cost transparency.

Do not implement general escape-driven or recursion-driven auto-boxing. It
would conflate placement with representation, introduce invisible allocations
and cache regressions, destabilize APIs, and work against the same CLEAR goals
the feature is intended to serve.

The original three-tier proposal drew the correct boundary for DEFAULT and
STRICT but made EASY too permissive. “The compiler can make this recursive
type finite” is a correctness proof, not a performance-equivalence proof.
EASY should automate direct placement, zero-cost ownership plumbing, trivial
copies, and coercion to already-declared representations. It should stop with
costed fixes when the decision creates an avoidable allocation, pointer chase,
unbounded copy, identity change, or unstable public contract.

An on-by-default EASY autofix is compatible with this recommendation if it
automatically *propagates* an already-selected private layout rather than
automatically *selecting* a costly layout. DEFAULT and STRICT should be able to
enable the identical fixer to materialize explicit source. This provides the
ergonomic benefit of automatically updating instantiations and signatures
without turning hidden auto-boxing into permanent language semantics.
