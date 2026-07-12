# Automatic Indirection in EASY Mode

Status: Design proposal

Scope: EASY-mode storage-layout elision for `@indirect`

Related: `docs/agents/auto-copy-clone.md`, `docs/agents/graph.md`

## 1. Decision

CLEAR should permit EASY mode to omit `@indirect` only when the compiler can prove that indirection is required by the program's already-declared semantics and that inserting it produces exactly the same representation, allocation count, and runtime work as writing `@indirect` explicitly.

DEFAULT and STRICT modes keep storage layout explicit. In every mode, if more than one materially different layout is valid, the compiler must reject the program and provide fixable alternatives with their performance consequences. EASY is allowed to erase syntax; it is not allowed to erase a performance decision.

This is deliberately narrower than “box every value that escapes.” Escape, ownership, and representation are separate questions:

- Moving `Foo` into a `Foo[]@list` stores `Foo` inline in the list. It does not require a box.
- Moving `Foo` into an inline global slot changes its storage location, not its representation.
- `Foo@indirect` changes the representation to a pointer-backed allocation and can change allocation count, ABI, cache locality, address stability, and destruction behavior.
- `Foo@node` selects a graph domain and compact handle representation; it is not merely spelling for a box.

The compiler must preserve these distinctions.

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

## 4. Mode Policy

| Mode | Types | Ownership transport | Storage layout |
|---|---|---|---|
| EASY | Mostly inferred | Infer zero-cost move/borrow/copy where unambiguous; never guess across mutation | Infer `@indirect` only when forced and cost-equivalent |
| DEFAULT | Explicit, with local inference | Infer safe ownership transport under the automatic ownership rules | Explicit |
| STRICT | Explicit | Reject hidden cost; require explicit costly copy/share operations | Explicit |

DEFAULT does not infer `@indirect`. Explicit types are a local contract for layout and API shape. Silently changing an inline `Foo` to a pointer-backed `Foo@indirect` would invalidate cache, allocation, and ABI reasoning.

STRICT has the same layout rule and additionally rejects any hidden costful ownership transport. Zero-cost moves and borrows may still be proven and lowered without runtime work.

## 5. When EASY May Infer `@indirect`

### 5.1 A uniquely forced recursive edge

An unboxed recursive value has infinite size:

```clear
STRUCT Node {
  value: Int64,
  next: ?Node
}
```

If `next` is the unique edge whose indirection breaks the recursive layout cycle, EASY may treat it as:

```clear
STRUCT Node {
  value: Int64,
  next: ?Node@indirect
}
```

The inferred form and explicit form must share one typed representation and one lowering path.

If a recursive strongly connected component has several valid cycle-breaking edges, choosing one can change object size, pointer-chasing direction, allocation behavior, and traversal performance. EASY must then error and offer explicit fixes. A deterministic compiler preference is not sufficient: determinism does not make the alternatives performance-equivalent.

### 5.2 An explicit destination contract

EASY may insert construction of `Foo@indirect` when the local destination or callee ABI already requires `Foo@indirect`:

```clear
FUNCTION remember(value: Foo@indirect) TAKES value DO
  # ...
END

x = Foo{}
remember(x)
```

The signature made the representation explicit. EASY only elides the call-site constructor. The compiler must allocate directly into the destination representation rather than create a heap-independent temporary and relocate it later.

This is ordinary coercion to an explicit contract, not caller-specific ABI inference.

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

A normal borrowed parameter cannot secretly retain `x` in a global. If `bar` retains ownership, that requirement must appear in its type/effect contract, such as `TAKES`, and its storage representation must be visible in the destination or parameter type where relevant.

The compiler must not inspect `bar`'s body, discover a global store, and invent a caller-side box. That would make local reasoning depend on implementation details and would make separately compiled ABIs unstable.

### 6.3 Optional optimizations

EASY must not infer a box merely because it might avoid a future copy, might stabilize an address, or might make one branch cheaper. Those are trade-offs, not forced equivalences. The compiler must retain the inline representation or emit a diagnostic if the program requires the user to choose.

### 6.4 Ambiguous topology

For graphs, parent pointers, many-to-many cycles, or large recursive collections, `@indirect`, `@node`, and explicit shared ownership have different semantics and performance profiles. EASY must not choose among them.

The diagnostic should normally recommend `@node` for a lifecycle-bounded graph, `@indirect` for unique pointer-owned recursion, and `@shared`/LINK for independently owned cross-domain aliases.

## 7. Construction and ABI Rules

The compiler resolves representation before MIR lowering.

1. Type/schema analysis identifies layout cycles and explicit destination contracts.
2. The mode policy either admits a uniquely forced EASY inference or emits a fixable error.
3. The typed AST records the resolved storage contract.
4. Ownership/escape analysis chooses move, borrow, copy, and destination placement without changing that contract.
5. MIR contains the same explicit heap creation, allocation mark, transfer, and cleanup operations used by source-written `@indirect`.
6. MIR validation rejects late pointer casts, stack-address escapes, missing allocation rollback, duplicate cleanup, and any attempt to infer representation during code generation.

There must be no “stack first, migrate later” implementation. When indirection is required, construction is planned directly in its final storage. There must also be no legacy and inferred lowering path: inference produces the existing explicit semantic form before lowering.

Exported and separately compiled interfaces must have materialized, stable layout contracts. EASY may infer an internal function's signature while compiling its whole module, but the resolved interface must be recorded before callers are compiled. A public ABI cannot vary by call site.

## 8. Diagnostics and Fixes

When inference is not provably cost-equivalent, the compiler should issue a fixable diagnostic such as:

```text
error[E_LAYOUT_CHOICE]: this value requires an explicit storage layout
  `Node` has multiple valid recursive representations with different costs

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

Compiler explanation output should report every inferred EASY indirection and its proof, for example “unique recursive cycle-breaking edge” or “explicit destination requires `Foo@indirect`.” This keeps hidden syntax observable without charging ordinary users for it.

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

## 10. Verification Plan

Implementation is complete only with:

- positive tests for unique direct recursion, optional recursion, and explicit indirect destinations;
- compile-fail tests for multiple recursive edges, mutually recursive ambiguous SCCs, DEFAULT omission, STRICT omission, and mutation collisions;
- layout assertions proving `Foo[]@list` remains contiguous and unboxed;
- generated-MIR/ABI equivalence tests between inferred EASY and explicit `@indirect` programs;
- allocation-count and instruction-level benchmarks proving no additional allocation, copy, branch, or pointer chase versus explicit `@indirect`;
- allocator-failure injection at every construction step;
- destructor-count oracles for scalar, managed, optional, union, collection, and nested payloads;
- fuzz matrices spanning mode, source/destination, recursion shape, ownership capability, move/borrow/copy, overwrite, error exit, and allocation failure;
- module-boundary and separate-compilation tests proving stable interfaces;
- regressions proving collection/global escape does not cause boxing;
- regressions proving inferred boxing cannot suppress alias-mutation errors.

## 11. Acceptance Criteria

The feature may ship only when all of the following are true:

1. EASY source can omit a uniquely forced `@indirect` annotation.
2. The inferred program has the same resolved type, MIR, ABI, allocation count, cleanup behavior, and benchmark performance as its explicit equivalent.
3. No ordinary escape, list insertion, global move, or return causes opportunistic boxing.
4. DEFAULT and STRICT require explicit layout whenever representation is not already fixed by a destination contract.
5. Every ambiguous or potentially performance-affecting choice is a fixable compile error in every mode.
6. Mutation across an inferred alias is rejected in every mode.
7. The implementation reuses the explicit `@indirect` lowering and runtime path; no parallel compatibility path exists.

## 12. Recommendation

Implement this constrained EASY-only elision. It advances CLEAR's “Ruby/Python ease with systems performance” goal precisely where the compiler possesses a proof, while preserving DEFAULT's local layout reasoning and STRICT's cost transparency.

Do not implement general escape-driven auto-boxing. It would conflate placement with representation, introduce invisible allocations and cache regressions, destabilize APIs, and work against the same CLEAR goals the feature is intended to serve.
