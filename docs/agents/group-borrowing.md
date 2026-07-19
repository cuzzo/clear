# Group Borrowing for CLEAR

Status: proposed design; no language change approved

Date: 2026-07-19

Primary source: [Group Borrowing: Zero-Cost Memory Safety with Fewer
Restrictions](https://verdagon.dev/blog/group-borrowing), Evan Ovadia with
Nick Smith, 2025-08-28

Scope: ownership checking, mutable argument aliasing, interior-borrow
invalidation, and the boundary between borrowing and synchronization
capabilities

## Executive Decision

CLEAR should adopt the central *analysis technique* from group borrowing, but
not its proposed user-facing group system.

The useful observation is that mutation is not inherently unsafe when aliases
exist. The unsafe event is destroying, moving, or changing the representation
of something while a reference into that thing remains live. Two mutable
references to the same stable object can therefore be sound when the called
operation only mutates stable fields and does not invalidate an interior
borrow.

CLEAR can exploit that distinction without adding named groups, lifetime
parameters, group unions, or another family of capabilities. The compiler
should infer:

- which relative paths an operation may replace, relocate, or destroy;
- which interior borrows are live at each operation;
- which function parameters may alias safely; and
- which call invalidates a particular borrow.

The common language remains the language CLEAR already has:

```clear
FN transfer(MUTABLE from: Account, MUTABLE to: Account) RETURNS Void ->
  from.balance -= 10;
  to.balance += 10;
END

MUTABLE account = Account{ balance: 100 };
transfer(&account, &account);
```

The call is currently rejected because two overlapping arguments include a
mutable parameter. Under this proposal it is valid if `transfer`'s inferred
alias-safety summary proves that its mutations cannot invalidate a live
interior borrow.

This is a meaningful ergonomic improvement with no required run-time cost. It
also fits CLEAR better than importing Rust's full borrow vocabulary or
Carbon's planned family of pointer types. It is not yet proven enough to
replace the existing conservative rule in one step. It should be introduced
behind a compiler experiment and enabled only after adversarial ownership
tests establish soundness.

## Terminology: Carbon Is Not a Rust Dialect

Carbon is not a dialect of Rust. The Carbon project describes it as an
[experimental successor to C++](https://github.com/carbon-language/carbon-lang/blob/trunk/README.md).
Its safety direction borrows the high-level goal of compile-time temporal and
data-race safety from Rust, but Carbon is designed around incremental C++
migration and interoperation. Its own proposal says that matching Rust exactly
is not its goal.

The comparison in this document is therefore between:

- the group-borrowing research proposal;
- CLEAR's implemented ownership and capability model;
- Carbon's published, substantially provisional safety direction; and
- Rust's established aliasing model as the common point of reference.

It is not a comparison between two completed implementations. Group borrowing
is a research design, and Carbon explicitly labels its temporal and data-race
model as directional pending dedicated proposals.

## What Group Borrowing Contributes

The initial document begins with single ownership, then separates two concepts
that conventional alias-xor-mutation checking tends to combine:

1. a reference to an object; and
2. a reference to a destructible or relocatable object *inside* it.

Mutating an object through either of two aliases does not by itself make the
other alias dangle. Mutating a dynamic container can, however, relocate its
elements and invalidate references to those elements. Changing a union
variant can destroy the previous payload. Replacing an owned field can destroy
the previous child object.

The proposal models those independently destructible regions as child groups.
Groups can be related and unified as aliases become known. Function contracts
describe which group paths may mutate, allowing a caller to identify precisely
which live reference a call may invalidate.

This admits code that a conservative alias-xor-mutation rule rejects while
still diagnosing the dangerous sequence:

```clear
MUTABLE entity = makeEntity();

IF entity.rings[0] EXISTS AS ring THEN
  &entity.rebuildRings();
  print(ring.name);
END
```

The useful diagnostic is not merely "mutable alias exists." It is:

```text
`ring` borrows `entity.rings[*]`.
`rebuildRings` may relocate `entity.rings[*]`.
The borrow is used after that invalidating call.
```

The full research proposal also requires mutually isolated members within a
group: one member must not indirectly own or reference another member in a way
that allows mutating the first to destroy the second. That is an important
soundness condition, not optional terminology. CLEAR should enforce the
condition internally and conservatively rather than expose general group
construction in source code.

## CLEAR Today

CLEAR already has most of the structural foundation:

- affine ownership is the default;
- parameters borrow unless declared `TAKES`;
- `MUTABLE` parameters and `&value` make mutation visible at the call site;
- `WITH RESTRICT` gives a mutable borrow an explicit lexical scope;
- the ownership graph records variables and field paths, parent/child
  relationships, and immutable or mutable borrow edges;
- indexed places are represented using wildcard child paths; and
- returned borrows can identify their source path.

The current call check is deliberately conservative. If two argument paths
overlap and either parameter is mutable, it emits `ARG_ALIAS_CONFLICT`.
Likewise, `OwnershipGraph#can_write?` rejects writes through a path with active
borrows on it or its ancestors.

That rule is sound and understandable, but it conflates stable mutation with
invalidation. It rejects calls such as `transfer(&account, &account)` even
when neither mutation can destroy `account` or an independently borrowed child.

Current intrinsic contracts also expose mostly a Boolean
`mutates_receiver`. That is sufficient to require `&receiver`; it is not
sufficient to decide which interior borrows a call invalidates.

## Proposed CLEAR Model

### 1. Keep the source language small

Do not add general syntax for group names, group unions, lifetime equations,
or alias modes.

Continue to use:

- `MUTABLE` for a borrowed value the callee may mutate;
- `&x` to acknowledge mutation of a named value;
- `TAKES` for ownership transfer;
- `WITH RESTRICT` when the programmer wants a scoped restrictive borrow; and
- existing capabilities for allocation, synchronization, and visibility.

Inference should handle ordinary functions. If a foreign or dynamically
dispatched operation cannot be inspected, its invalidation behavior must be
conservative. A future explicit boundary annotation may reuse `EFFECTS`, for
example `EFFECTS INVALIDATES buffer.*`, but it should be added only when a real
uninferable API requires it.

### 2. Add an authoritative invalidation summary

Each callable should have one immutable summary expressed relative to its
receiver and parameters. Conceptually:

```text
InvalidationSummary
  stable_writes:       Set<RelativePlacePath>
  replaced_paths:      Set<RelativePlacePath>
  relocated_children: Set<RelativePlacePath>
  destroyed_paths:    Set<RelativePlacePath>
  returned_borrows:   Set<BorrowOrigin>
  captured_borrows:   Set<BorrowOrigin>
  alias_compatibility: PairwiseParameterMatrix
```

The exact Ruby representation should use small immutable typed values rather
than strings. `RelativePlacePath` must use the same canonical path identity as
the ownership graph; it must not introduce another derived path format.

The distinctions are semantic:

| Operation | Invalidation effect |
| --- | --- |
| Write a scalar field in place | no address invalidation |
| Replace an owned field | invalidate that field's descendants |
| Append to a relocating list | invalidate `list[*]` |
| Delete or clear container entries | invalidate affected child paths |
| Change a union variant | invalidate the old payload |
| Consume a `TAKES` parameter | invalidate its root and descendants |

Container facts must match the actual runtime representation. For example, a
map implementation with stable entry addresses and one that relocates entries
cannot share a convenient but false invalidation contract.

### 3. Infer alias compatibility inside the callee

A function is compiled once, so soundness cannot depend on rediscovering its
body separately for every call site. Analysis should infer a pairwise
compatibility certificate for its mutable receiver and parameters.

For each potentially aliased pair, the function is compatible only if:

- no interior borrow from either side remains live across an operation that
  could invalidate the same child path through the other side;
- no returned or captured borrow has an ambiguous or unsound origin;
- ownership is not transferred twice through aliases;
- a variant or dynamic-layout mutation cannot invalidate a later access; and
- all indirect calls have summaries strong enough to prove the same facts.

The analysis is ordered, not merely a set intersection. A borrow created after
an invalidating operation can be safe; the same borrow used across that
operation is not. Existing ownership events and graph snapshots should be
extended rather than re-derived from AST or MIR text.

Recursive call components require a monotone fixed point. Unknown calls,
function pointers, FFI without a contract, and failed convergence resolve to
"not alias compatible," never optimistic safety.

### 4. Instantiate the summary at the call site

At a call, relative parameter paths map onto actual ownership paths. The
current prefix-overlap check becomes:

1. identify which actual arguments overlap;
2. ask the callee summary whether those parameter positions may alias;
3. apply its invalidation paths to the actual roots;
4. reject any invalidated live interior borrow; and
5. retain the current `ARG_ALIAS_CONFLICT` behavior when proof is absent.

This produces more precise errors without weakening the default:

```text
argument 2 aliases argument 1, and `replaceItems` may relocate `items[*]`
while `selected` still borrows that path
```

### 5. Preserve the annotation-to-MIR authority boundary

Annotation owns the safety decision and attaches the resolved summary or
operation plan to the call. MIR consumes that plan for cleanup and transfer;
it must not infer alias safety again. A verifier should reject a lowering that
destroys or relocates a place outside the attached plan.

There is no run-time borrow table, reference counting, generation check, or
hidden cleanup mechanism in this design. The result remains zero-cost in the
same practical sense as CLEAR's present ownership checks.

## Interaction with Capabilities

Borrowing and capabilities answer different questions:

- borrowing says who may access a value and whether an access can outlive a
  mutation or destruction;
- capabilities say how a value is allocated, synchronized, shared, or made
  visible across execution contexts.

Group identity must therefore remain an internal ownership fact, not an
`@group`, `@shared`, or `@exclusive` capability. Overloading `@shared` to mean
"may alias" would make a thread-sharing guarantee accidentally change local
borrow semantics.

The first implementation should not relax rules across `BG`, `DO`, captured
closures, `@shared` state, `@node`, `LINK`, or `RESOLVE`. Existing ownership,
sendability, lock, and capability checks continue to apply. Once local
single-execution-context behavior is proven, summaries can be carried across
those boundaries deliberately.

`@alwaysMutable`-style interior mutation, where supported, likewise remains a
capability/property decision. It can create stable writes, but it cannot grant
permission to relocate a child that has a live borrow.

## Examples of the Intended Boundary

### Harmless whole-object aliasing

```clear
FN bumpTwice(MUTABLE left: Counter, MUTABLE right: Counter) RETURNS Void ->
  left.value += 1;
  right.value += 1;
END

MUTABLE counter = Counter{ value: 0 };
bumpTwice(&counter, &counter);
ASSERT counter.value == 2;
```

This should be accepted. Both mutations preserve the address and type of the
object and its field.

### Interior borrow invalidated by relocation

```clear
MUTABLE names = ["Ada", "Grace"];

IF names[0] EXISTS AS first THEN
  &names.append("Linus");
  print(first);
END
```

This must remain an error if `append` may relocate the backing elements.

### Parent and child arguments

```clear
FN powerUp(owner: Entity, MUTABLE ring: Ring) RETURNS Void ->
  ring.power += owner.bonus;
END

MUTABLE entity = makeEntity();
powerUp(entity, &entity.primaryRing);
```

This can be accepted if reading `owner.bonus` cannot destroy or relocate
`primaryRing`, and the function neither captures nor returns an ambiguous
borrow. The proof is about paths and operation order, not merely the fact that
the arguments share a root.

### Ownership transfer remains strict

```clear
FN consumeBoth(TAKES left: Buffer, TAKES right: Buffer) RETURNS Void ->
  # ...
END

buffer = makeBuffer();
consumeBoth(GIVE buffer, GIVE buffer);
```

This remains illegal. Group borrowing relaxes safe mutation; it does not make
double ownership transfer coherent.

## The Common Problem Class This Makes Easier

The largest practical win is **temporary multi-place mutation beneath one
owner**.

This occurs whenever a short operation needs two ordinary borrowed values but
their identities cannot be proven disjoint syntactically:

- two elements selected from a list, map, pool, graph, or ECS by run-time IDs;
- a whole context plus one object owned by that context;
- a tree or graph node plus a parent, child, or neighbor;
- two entries involved in swapping, balancing, collision resolution, transfer,
  or comparison-and-update;
- a compiler session plus a declaration, type, or work item stored in one of
  its tables; and
- a cache plus its selected entry while only unrelated cache metadata changes.

These are common in parsers, compilers, simulations, schedulers, caches, scene
graphs, databases, and network state machines. They are not inherently
shared-ownership problems. Usually one collection or context still owns every
value, and all temporary references end before the operation returns.

Rust does not universally require `Rc` or `Arc` for this code. Its best
solutions often use field splitting, `split_at_mut`, a checked `get_many_mut`
API, arena IDs, or a data-structure-specific cursor. Those solutions preserve
static ownership, but they can force the caller to reorganize a natural
operation around the storage layout. When that becomes inconvenient, programs
sometimes reach for:

- `Rc<RefCell<T>>` for dynamically checked single-threaded mutation;
- `Arc<Mutex<T>>` or `Arc<RwLock<T>>` for shared mutation, even when the
  algorithm itself does not need cross-thread shared ownership;
- cloned values followed by write-back;
- repeated ID lookups after every mutation; or
- unsafe code hidden in a collection-specific helper.

`Rc` and `Arc` alone only provide shared ownership; mutation generally adds
`RefCell`, `Mutex`, `RwLock`, atomics, or another interior-mutability mechanism.
Group borrowing can avoid the entire combination when it was introduced only
to overcome conservative alias analysis. That removes heap control blocks,
reference-count traffic, dynamic borrow checks, and unnecessary locks.

### The ordinary case remains ordinary

Two independent local values already need no reference counting:

```clear
MUTABLE x = Counter{ value: 1 };
MUTABLE y = Counter{ value: 2 };
combine(&x, &y);
```

Group borrowing is valuable when `x` and `y` are ordinary borrowed views whose
relationship is known only at run time. They may be distinct, may share an
owner, or may even designate the same object:

```clear
FN collide(MUTABLE left: Entity, MUTABLE right: Entity) RETURNS Void ->
  left.velocity = left.velocity - 1;
  right.velocity = right.velocity + 1;
END

MUTABLE entities: []Entity = loadEntities();

IF entities[leftId] EXISTS AS x AND entities[rightId] EXISTS AS y THEN
  collide(&x, &y);
END
```

The collection remains the sole owner. `x` and `y` are temporary borrows, not
reference-counted entity handles. If `leftId == rightId`, the call can still be
memory-safe because `collide` only performs stable in-place writes. Whether
colliding an entity with itself is *logically* meaningful is a program
precondition, separate from memory safety.

The compiler must reject a different implementation of `collide` if it stores
one borrow somewhere, consumes either entity, changes a relevant variant, or
performs an operation that can relocate the borrowed elements.

### Whole owner plus selected child

Passing a context and one of its members to the same operation is another
frequent source of artificial restructuring:

```clear
FN updateOne(MUTABLE world: World, MUTABLE entity: Entity) RETURNS Void ->
  world.updated += 1;
  entity.position = nextPosition(entity.position);
END

MUTABLE world = loadWorld();

IF world.entities[id] EXISTS AS entity THEN
  updateOne(&world, &entity);
END
```

This is safe when `world.updated` is stable and the operation does not mutate
the structure of `world.entities`. It becomes unsafe if `updateOne` appends to,
clears, replaces, or otherwise relocates `world.entities` while `entity` is
live. A group-aware checker can distinguish those two function bodies instead
of rejecting both because the argument paths overlap.

This pattern is particularly useful in the compiler itself. An analysis pass
can borrow a session and a selected fact or AST node without cloning the fact,
looking it up repeatedly, or moving the session's tables behind pervasive
shared ownership. The mutation summary must still reject table insertion or
replacement when the runtime map layout can invalidate that selected entry.

### Pairwise graph and arena algorithms

Graphs often need to mutate two nodes selected through an edge:

```clear
FN relax(MUTABLE from: Node, MUTABLE to: Node) RETURNS Void ->
  candidate = from.distance + 1;
  IF candidate < to.distance THEN
    to.distance = candidate;
  END
END

MUTABLE graph = loadGraph();

IF graph.nodes[edge.from] EXISTS AS from AND
   graph.nodes[edge.to] EXISTS AS to THEN
  relax(&from, &to);
END
```

The nodes can remain values owned by the graph or arena. They do not need to be
individually wrapped in reference-counted cells merely because an edge chooses
the pair dynamically. This preserves contiguous storage and predictable
allocation.

Again, the permission is narrow. `relax` may update stable node state; it may
not resize `graph.nodes` through an alias while `from` or `to` is live. A graph
whose nodes actually own arbitrary references to one another may violate the
mutual-isolation requirement and still need handles, a stable arena, shared
ownership, or a different topology.

### Natural helper boundaries

Without a sufficiently precise checker, a programmer may inline logic solely
so the compiler can see field disjointness, or split a helper according to
storage topology:

```clear
# The desired API remains about the operation.
settle(&accounts[payer], &accounts[payee]);

# It should not need to become an API about splitting the collection.
# splitAroundIndex(...); settleLeftRight(...);
```

Group-aware summaries make the abstraction boundary usable: the callee proves
once which mutations invalidate storage, and every caller uses that proof.
This is more compositional than requiring each caller to reconstruct a
data-structure-specific disjointness argument.

### When this can replace `Rc` or `Arc`

| Situation | Ordinary ownership plus group borrowing? |
| --- | --- |
| Two temporary aliases used during one call | Yes, if the callee is proven alias-compatible |
| Two dynamically indexed elements | Yes, without requiring unequal indices when same-object mutation is safe |
| Whole owner plus a child | Yes, if owner mutation cannot invalidate the child |
| Arena nodes selected by handles | Yes, if storage remains stable for the borrow |
| Borrow escapes into independently owned state | No |
| Multiple long-lived owners may destroy the value independently | No; this is real shared ownership |
| Value crosses `BG`/thread boundaries | Not by group borrowing; synchronization/sendability rules apply |
| Concurrent mutation | No; use CLEAR's synchronization capabilities |
| Container relocates while an element borrow is live | No |
| Arbitrary internal ownership cycles | Usually no; mutual isolation is not proven |

The intended result is that `foo(&x, &y)` accepts ordinary owned or borrowed
values whenever the operation is actually safe. It does **not** silently turn
`x` or `y` into shared owners, extend either lifetime, or synchronize access.
When ownership genuinely is shared or work is concurrent, `@shared`, locking,
or the relevant ownership representation remains necessary.

This boundary is important to the value proposition. The proposal is useful
if it eliminates incidental shared-ownership machinery from common local
algorithms. It is unsound if it is presented as a general substitute for
reference counting or synchronization.

### Why this matters more in `--easy` mode

Group borrowing is not merely a small optimization when combined with CLEAR's
EASY ownership elaboration. It gives the compiler a better *semantic answer*
before EASY has to select or request ownership machinery.

Today, CLEAR's automatic ownership-transport design intentionally refuses to
guess between a snapshot and shared identity when a plain inferred alias
overlaps mutation. That is the correct rule when the mutation could invalidate
the alias or when observable identity is ambiguous. It is unnecessarily broad
when both names are only temporary borrows and every mutation is stable.

Group borrowing refines the rule:

```text
live alias + mutation
  is not automatically an ownership conflict

live interior borrow + operation that may invalidate its path
  is an ownership conflict
```

That means EASY can keep this as ordinary owned storage:

```clear
MUTABLE x = loadEntity();
MUTABLE y = loadEntity();
foo(&x, &y);
```

It can also keep dynamically selected values as borrows from their one owner:

```clear
IF entities[leftId] EXISTS AS x AND entities[rightId] EXISTS AS y THEN
  foo(&x, &y);
END
```

Neither spelling asks for `@multiowned`, `@shared`, `CLONE`, a box, or a
lock. If `x` and `y` happen to identify the same entity, the inferred callee
certificate decides whether that alias is safe. The programmer does not need
to select an RC/ARC-style representation merely to make the borrow checker
accept a short call.

The ownership planner should use this priority order:

1. prove a zero-cost move or temporary borrow;
2. apply group/path analysis to prove overlapping temporary borrows safe;
3. use an already-permitted trivial copy or non-mutating materialization only
   when a borrow cannot satisfy the value contract;
4. elaborate `@boxed` only when a resolved destination contract already
   requires that representation; and
5. emit a fixable semantic-choice error when the program genuinely requires a
   snapshot, shared identity, stable allocation, or synchronization.

In particular, the compiler must not respond to a failed group proof by
silently upgrading a plain value to `@multiowned` or `@shared`. It must not add
a lock, and it must not opportunistically box a value merely to give it a
stable address. Those operations change visible identity, allocation,
synchronization, or layout semantics.

This ordering improves both modes:

- In EASY, more Ruby-like code remains ordinary, allocation-free CLEAR without
  forcing the developer to understand why Rust might suggest `Rc<RefCell<T>>`,
  `Arc<Mutex<T>>`, or a specialized split API.
- In DEFAULT and STRICT, the same proof accepts the same ownership topology;
  the modes differ only in how much otherwise-valid ownership plumbing and
  cost must be written explicitly.

The result is a larger usability win than the raw cost of a reference count or
box suggests. It avoids infecting surrounding APIs and collection element
types with shared-ownership wrappers. A single temporary aliasing problem no
longer forces constructors, fields, returns, and generic constraints to carry
an RC/ARC-like type throughout the program.

This proposal therefore narrows the universal mutation-collision rule in the
[automatic ownership transport design](auto-copy-clone.md). The compiler still
never guesses snapshot versus shared identity. Instead, it first proves that
no snapshot or shared identity is needed because the values are non-escaping
borrows and the mutations preserve every live borrowed path.

## Comparison with Carbon

Carbon's [updated safety strategy](https://github.com/carbon-language/carbon-lang/blob/trunk/proposals/p005914-updating-carbon-s-safety-strategy.md)
targets a memory-safe language that can be adopted incrementally from large
C++ codebases. Carbon plans compile-time temporal safety, compile-time
data-race safety, and run-time spatial checks. Its
[safety design](https://github.com/carbon-language/carbon-lang/blob/trunk/docs/design/safety/README.md)
also distinguishes Strict and Permissive modes and calls for unsafe operations
to be semantically and syntactically narrow.

The most relevant Carbon direction is safe shared mutation. Carbon expects
more distinguished pointer types than Rust, including shared-mutable and
exclusive-mutable pointers. Its motivating container example allows iterators
to use shared-mutable pointers while operations that invalidate iterators
require exclusive mutable access and therefore preclude outstanding shared
mutable pointers. Carbon explicitly accepts additional visible type-system
complexity to preserve C++ patterns and incremental migration.

| Concern | Carbon's published direction | Proposed CLEAR subset |
| --- | --- | --- |
| Primary constraint | Incremental C++ migration and interop | Simple safe systems/concurrent programming |
| Maturity | Experimental; temporal/data-race details provisional | Existing conservative checker plus proposed extension |
| Mutable aliasing | Multiple pointer categories for shared and exclusive mutation | Existing `MUTABLE`/`&`; compiler infers alias compatibility |
| Invalidation | Invalidating operations require exclusive access in the container example | Invalidate only affected child paths and live interior borrows |
| User-visible cost | More pointer types and some unavoidable safety complexity | No common-case group or lifetime syntax |
| Spatial safety | Planned run-time enforcement, including release bounds checks | Existing checked/fallible access rules remain unchanged |
| Unsafe boundary | Narrow `unsafe`; Strict and Permissive modes | Existing explicit unsafe/view/FFI boundaries; no broad unsafe mode added here |
| Concurrency | Planned type-system data-race safety with incremental adoption | Existing bind-time synchronization capabilities remain authoritative |
| Optimization contract | Fewer assumptions about unsafe code than Rust | Do not infer backend alias promises from safety alone |

The designs agree on the important insight that useful shared mutation needs
more precision than Rust's basic shared-or-exclusive choice. Their tradeoffs
differ:

- Carbon is willing to expose more pointer distinctions because C++ APIs and
  automated migration demand them.
- CLEAR does not need to preserve the C++ object and pointer vocabulary, so it
  can keep the source model smaller and place path/invalidation detail in the
  compiler.
- Carbon's iterator example still uses exclusive access at an invalidating
  operation. Group borrowing can be more precise by naming the particular
  child group invalidated, leaving unrelated child borrows usable.
- Carbon's plan is broader: it includes migration modes, unsafe integration,
  runtime spatial protection, inheritance, and C++ interoperability. This
  CLEAR proposal is intentionally only an ownership precision improvement.

CLEAR should take two additional lessons from Carbon:

1. unsafe operations should remain narrow and auditable rather than turning an
   entire ownership region into unchecked code; and
2. the backend must not convert an ownership proof into a stronger `noalias`
   optimization promise unless that promise was independently established.

The latter matters as mutable aliasing becomes more permissive. A program can
be memory-safe while allowing aliases that would violate a backend's
`noalias` contract. The current compiler does not appear to rely on such an
emission, and this proposal must not introduce one implicitly.

## Why Not Adopt Carbon's Pointer Taxonomy

Adding shared-mutable and exclusive-mutable pointer types would make
individual low-level relationships explicit, but it would work against
CLEAR's goal of expressing mutation through `MUTABLE`, `&`, scoped borrowing,
and bind-time capabilities.

It would also create two nearby meanings of "shared":

- shared as an alias/permission property; and
- `@shared` as a synchronization and execution-context property.

That ambiguity is especially harmful in CLEAR, where polymorphic
synchronization is a defining feature. Internal group analysis offers most of
the local aliasing benefit without diluting capability meaning.

If inference later proves insufficient at public or foreign boundaries, the
first escape hatch should be precise effect/invalidation contracts. New
pointer kinds should require concrete examples that those contracts cannot
express cleanly.

## What CLEAR Should Not Adopt

- No public `group` declarations or lifetime algebra in ordinary code.
- No capability spelling for local alias groups.
- No implicit permission to transfer ownership through aliases.
- No optimistic assumptions for FFI, dynamic calls, recursion, or unknown
  container layouts.
- No run-time borrow checker or reference-counting fallback.
- No relaxation across concurrency boundaries in the first implementation.
- No rewriting every current ownership diagnostic before the safety model is
  proven.

## Implementation Plan

### Phase 1: summaries without changed acceptance

- Introduce canonical immutable invalidation paths and summaries.
- Classify existing mutations as stable, replace, relocate, or destroy.
- Infer summaries for ordinary functions and declare them for intrinsics.
- Attach summaries to annotated calls and assert that MIR consumes them.
- Keep the current overlapping-mutable-argument rejection.

This phase should expose incorrect or incomplete intrinsic ownership contracts
without changing the accepted language.

### Phase 2: invalidation diagnostics

- Use summaries to identify the exact child borrow invalidated by a call.
- Preserve the existing conservative rejection when paths or summaries are
  unknown.
- Add source-range diagnostics that point to borrow creation, invalidating
  operation, and later use.

### Phase 3: inferred alias compatibility

- Analyze each mutable parameter pair under a possible-alias hypothesis.
- Infer the compatibility matrix through the call graph.
- Permit overlapping call arguments only for pairs proven compatible.
- Keep double transfer, ambiguous returned borrows, and captured borrows
  rejected.

### Phase 4: hostile and compositional testing

- Expand ownership fuzzing across field, index, union, list, map, tuple,
  optional, fallible, and capability nesting.
- Generate operation-order permutations: borrow/mutate/use, mutate/borrow/use,
  branch joins, loop backedges, early returns, errors, and cleanup.
- Compare accepted programs under leak checking and sanitizer modes.
- Add negative diagnostic/range snapshots for minimized failures.

### Phase 5: evaluate non-local boundaries

Only after the local model is stable, assess summaries across closures,
`BG`/`DO`, shared values, interfaces, and FFI. Each boundary should be enabled
independently and remain conservative until its ownership transport is fully
modeled.

## Testing and Soundness Requirements

At minimum, the test matrix must cover:

- the same root passed to two or more mutable parameters;
- parent/child, child/parent, sibling, and wildcard-index overlap;
- stable field mutation versus field replacement;
- list growth, shrink, clear, and element replacement;
- map insertion/deletion under the actual entry-stability contract;
- union variant replacement and payload borrowing;
- returned and captured interior borrows;
- `TAKES` mixed with borrowed and mutable parameters;
- conditionals, loops, early return, `TRY`, `UNWRAP`, and `OR_ELSE` paths;
- recursive and mutually recursive summaries;
- unknown indirect calls and FFI;
- capabilities and tenses nested around affected types; and
- annotation-to-MIR plan preservation.

Required invariant:

```text
No MIR operation may destroy, replace, or relocate a place unless the
annotation-owned invalidation plan includes that place, and no live borrow may
overlap an included place after the operation.
```

The invariant should have direct verifier tests as well as source-level tests.
It is the defense against a later lowerer independently guessing a weaker
ownership plan.

Acceptance requires all existing unit, integration, transpile, fuzz,
sanitizer, and leak suites to remain green. New and changed production lines
require 100% line coverage. Acceptance should be based on soundness and useful
programs admitted, not solely on fewer diagnostics.

## Cost and Expected Benefit

A focused implementation is estimated at roughly 800-1,500 production lines,
plus 600-1,000 lines of tests and generated/fuzz cases:

| Work | Estimated production LoC |
| --- | ---: |
| Summary and canonical path model | 150-300 |
| Mutation/invalidation classification | 150-300 |
| Ordered alias-compatibility analysis | 250-450 |
| Call-site application and diagnostics | 150-300 |
| MIR verifier integration | 100-150 |

Expected wins:

- fewer false-positive alias errors;
- less repeated indexing, cloning, and lookup used only to appease the
  ownership checker;
- more precise invalidation diagnostics;
- one authoritative contract for mutation and ownership lowering;
- better optimization opportunities from clearer effects, without unsafe
  alias assumptions; and
- a stronger foundation for self-hosted compiler data structures with complex
  parent/child access patterns.

The benefit is material but bounded. This does not eliminate ownership
reasoning, make arbitrary internal graphs safe, solve concurrent mutation, or
replace synchronization capabilities.

## Risks and Stop Conditions

The principal risk is unsoundness hidden behind friendlier aliasing. Stop or
retain the conservative rule if any of these occur:

- path identity must be re-derived separately in annotation and MIR;
- function compatibility depends on call-site specialization to be sound;
- unknown calls are treated optimistically;
- container invalidation facts cannot be tied to their runtime layouts;
- recursive summary inference is non-monotone or fails to converge; or
- the feature requires common users to write group/lifetime syntax.

Complexity is also a real concern. Carbon explicitly accepts more visible
type-system complexity because C++ migration is its central constraint. CLEAR
does not share that constraint and should not pay that price without evidence.

## Recommendation

Prototype Phases 1 and 2 first. They improve the architecture and diagnostics
even if CLEAR never relaxes mutable aliasing. They also reveal whether the
existing ownership paths and intrinsic contracts are precise enough for the
idea.

Proceed to Phase 3 only if the prototype can prove useful examples such as
same-object stable mutation and parent/child access without introducing a
second ownership model or re-deriving facts in MIR. If it can, the result would
strengthen CLEAR's position: more permissive than a basic Rust-style
alias-xor-mutation rule, less visible machinery than Carbon's planned pointer
taxonomy, and still aligned with CLEAR's capability-first approach.
