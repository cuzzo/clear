# Automated Ownership Transport and Copy Elision

Status: Design proposal

## Decision summary

CLEAR should make ordinary sequential ownership substantially easier than
Rust, but it must automate **transport**, not guess **semantics**.

The recommended language rule is:

- plain value assignment has snapshot semantics;
- capability-bearing assignment preserves the capability's declared identity
  semantics;
- the compiler lowers either form to the cheapest observationally equivalent
  transport: move, borrow, retain, or materialized deep copy;
- the compiler never silently changes a plain value into `@multiowned` or
  `@shared`; and
- STRICT rejects hidden materialization costs but retains zero-cost move and
  borrow elision.

This is the same design pattern that made `@node` successful. A declaration
such as `left: ?Node@node` decides the topology and lifetime domain once. The
compiler then inserts store creation, handle conversion, resolution, and RAII
without making each assignment mention a pool. Automated copy elision should
work the same way: erase plumbing only after the relevant type or destination
has fixed the observable semantics.

## Goals

1. Make ordinary sequential CLEAR feel close to Ruby or Python while retaining
   deterministic cleanup and static safety.
2. Make safe concurrent code substantially easier to express and audit than
   equivalent Go code by preserving explicit synchronization and lifetime
   domains.
3. Default to the cheapest valid machine representation.
4. Preserve maximum local reasoning: a binding's type and the immediately
   visible operation must determine identity, mutation, and cleanup behavior.
5. Minimize global compiler complexity by using one ownership decision model
   across EASY, DEFAULT, and STRICT.
6. Allow performance-sensitive code to expose and prohibit hidden costs
   without forcing Rust's reference syntax into normal CLEAR.
7. Never trade memory safety, destructor correctness, or concurrency safety
   for ergonomic inference.

## Non-goals

- Inferring whether the programmer wanted a snapshot or shared mutable state.
- Silently converting affine values to `@multiowned` or `@shared`.
- Hiding synchronization, atomic reference counting, or cross-thread capture
  policy.
- Making resources, linear handles, promises, or other non-duplicable values
  copyable.
- Promising that every legal DEFAULT program is allocation-free.
- Reproducing Rust surface syntax such as explicit `&` on every borrow.

## Why the original proposal needs correction

The motivating proposal chooses among Move, Borrow, Clone, and Rc/Arc from
liveness and escape analysis. That is attractive but conflates optimization
with observable semantics.

Deep copy and reference counting are not interchangeable implementations:

- a deep copy creates an independent snapshot;
- Rc/Arc preserves object identity;
- later mutation is isolated after a deep copy but visible through a shared
  identity;
- destructor timing differs;
- Rc is scheduler-local while Arc may cross threads;
- layout and ABI differ; and
- cycles and weak references behave differently.

No amount of liveness analysis can determine which behavior the programmer
meant. Interleaved mutation is where the difference becomes obvious, but it is
not the only ambiguity. Identity comparison, resources, weak edges, API
boundaries, callbacks, background work, and destructor timing also expose it.

The statement “explicit copy/clone is only needed when mutation occurs between
alias creation and last use” is therefore too broad. It is valid only after the
language has already assigned deterministic semantics to the alias operation.

## Semantic model

### Plain values: snapshot semantics

In EASY and DEFAULT, assigning a duplicable plain value while retaining the
source is semantically an independent snapshot:

```clear
x = loadProfile();
y = x;
x.updateStatus("Active");
display(y); # observes the pre-update snapshot
```

The semantic model behaves as though `y = COPY x` were written. The compiler
does not necessarily copy at the assignment:

- if `x` is dead, it moves `x` into `y`;
- if neither side mutates and `y` remains local, it may borrow `x` until
  `y`'s last use;
- if later behavior distinguishes the values, it materializes the snapshot;
- if the value is statically copyable, it copies bits; and
- if the type cannot be duplicated, ordinary affine move rules apply.

This is an as-if optimization: every lowering must preserve snapshot behavior.
The compiler may not let an optimization turn later mutation into shared
mutation.

### Capability values: declared identity semantics

Capabilities decide the semantic family:

| Declared value | Assignment semantics when source remains live |
| --- | --- |
| Plain duplicable `T` | Independent snapshot |
| `T@multiowned` | Retain the scheduler-local shared identity |
| `T@shared` | Atomically retain the cross-scheduler shared identity |
| `T@link` | Retain the weak handle; resolution remains explicit |
| `T@node` | Copy the compact handle in the inferred node domain |
| `T@shared:node` | Copy the handle in a synchronized cross-scheduler node domain |
| Borrowed `WITH` alias | Borrow only; it may not escape |
| Resource / affine handle / plain promise | Move only unless the type explicitly defines duplication |

This gives local reasoning. A reader does not need whole-program liveness to
know whether mutation is shared: it follows from the declared capability.

### No implicit capability upgrade

The compiler must not turn this:

```clear
x: Document = loadDocument();
y = x;
```

into Rc or Arc merely because both names escape. That would make identity,
cleanup, concurrency, and performance depend on distant uses.

If shared identity is intended, it is stated once:

```clear
x: Document@multiowned = loadDocument() @multiowned;
y = x; # implicit retain in EASY/DEFAULT
```

If cross-thread sharing is intended:

```clear
x: Document@shared:locked = loadDocument() @shared:locked;
```

As with `@node`, the declaration makes the architectural decision and later
syntax stays ordinary.

### Shared node domains

`T@shared:node` is a required capability composition. It means that handles
and their inferred node domain may cross schedulers safely. It must not be
implemented as an Arc around the existing unsynchronized `NodeStore` pointer.

The current PagedSlotMap backend moves payloads during growth and swap-remove.
A reader holding a payload pointer while another scheduler mutates the store
would therefore have a dangling or aliased pointer even if registry lookup
itself were locked.

The initial implementation must provide a complete access protocol, such as a
store guard retained for the full read/write expression or a storage layout
whose payload addresses remain stable. Read, mutation, insertion, removal,
growth, lexical release, and runtime teardown must all participate in the same
protocol. A raw payload pointer may never escape its guard.

`@shared:node` does not silently appear because a local `@node` escapes. The
declaration is the local, reviewable choice to pay synchronization cost and
permit cross-scheduler graph access.

Its acceptance requirements include:

- TSan hammer tests for concurrent lookup, traversal, mutation, insertion,
  removal, growth, and final release;
- deterministic interleavings for reader/writer versus move/remove hazards;
- Loom tests for every synchronization state transition that can be modeled;
- VOPR tests for randomized state-machine and allocation/failure sequences;
- exact-once payload and resource destruction oracles;
- stale-handle and generation safety under contention; and
- tagged wait/retry loops registered with the repository hazard detector and
  linked to their hammer/Loom/VOPR coverage.

## Transport selection

For an assignment, argument, return, field store, or collection store, the
compiler selects transport only after semantic intent is known.

```text
semantic intent fixed by source type + destination contract
                         |
                         v
              Is the source dead afterward?
                    /             \
                  yes              no
                  move             |
                                   v
                     Can a local borrow preserve semantics?
                          /                    \
                        yes                     no
                        borrow                  |
                                                v
                              materialize declared semantics
                              - plain value: deep copy
                              - Rc/Arc/Weak: retain
                              - @node: handle copy
                              - linear value: compile error
```

The order is a performance strategy, not a semantic priority. Move and borrow
are allowed only when they preserve the already selected behavior.

## Mutation and aliasing

### Disjoint lifetimes

```clear
x = loadData();
y = x;
print(y);       # last use of y
x.append("!"); # legal
```

The compiler may implement `y` as a borrow because the borrow ends before the
mutation.

### Overlapping mutation of plain values

```clear
x = loadData();
y = x;
x.append("!");
print(y);
```

Under snapshot semantics this is not ambiguous. The compiler materializes an
independent copy for `y`. Rejecting the program would reintroduce the exact
borrow-checker ceremony the feature is meant to remove.

STRICT rejects the hidden materialization and suggests explicit `COPY` or a
restructure. EASY and DEFAULT compile it safely.

### Overlapping mutation of shared identity

If `x` is `@multiowned` or `@shared`, `y = x` preserves identity. Mutation
visibility and synchronization follow that capability. The compiler does not
turn the assignment into a snapshot merely because mutation appears later.

This is why the capability must be visible at declaration time.

### Borrowed aliases

Function parameters remain implicit borrows unless declared `TAKES`. `WITH`
aliases remain explicit scoped borrows. An inferred local borrow is a compiler
optimization and must obey the same non-escape and mutation-exclusion rules.

The compiler should report inferred borrow spans in diagnostics and ownership
explanations, but normal source does not need `&` syntax.

## Calls and destinations

The callee or destination already provides semantic intent:

- a normal parameter borrows;
- `TAKES` requires an owned value;
- a plain owned field or collection element stores a snapshot;
- an `@multiowned` or `@shared` destination stores a retained handle;
- an `@node` destination inserts a plain payload or copies an existing handle;
- a `T@link` destination stores a weak handle; and
- a non-duplicable destination requires a move.

In EASY and DEFAULT:

- a dead source may move into `TAKES` or an owned destination;
- a live duplicable source is materialized automatically according to the
  destination contract; and
- a live non-duplicable source produces a prescriptive error.

`GIVE`, `COPY`, `CLONE`, `SHARE`, `LINK`, and explicit capability construction
remain legal. They override inference and document intent where that improves
clarity.

## Language modes

Type inference and ownership transport are separate policy dials.

| Mode | Type declarations | Ownership transport | Hidden cost policy |
| --- | --- | --- | --- |
| EASY | Broad local inference | Automatic move, borrow, retain, and snapshot materialization | Allowed and explainable |
| DEFAULT | Explicit API types; `Auto` locals available | Same semantic automation as EASY | Allowed, with diagnostics and profiling |
| STRICT | Explicit types | Zero-cost moves and borrows remain inferred; costly retain/deep-copy materialization must be explicit | Hidden allocation/retain is an error |

STRICT should not require Rust-style explicit references. A proven local borrow
has no hidden runtime cost and no semantic ambiguity. STRICT exists to expose
cost and effects, not to add syntax for the compiler's internal pointers.

STRICT diagnostics should distinguish:

- implicit deep copy;
- implicit Rc retain;
- implicit atomic Arc retain;
- implicit node insertion;
- heap promotion; and
- synchronization or blocking.

This matches CLEAR's existing direction: STRICT is “no hidden HEAP/BLOCKING,”
not “spell every borrow like Rust.”

## Diagnostics and tooling

When materialization is impossible:

```text
Ownership Error: `socket` is still used after this assignment, but Socket is
move-only.

  saved = socket
          ^^^^^^ ownership would need to be duplicated here
  send(socket, data)
       ^^^^^^ source is used again here

Remedies:
  - move it explicitly: `saved = GIVE socket`
  - shorten one lifetime
  - store a duplicable descriptor type instead
```

In STRICT:

```text
Strict Cost Error: this assignment requires an implicit deep copy of `profile`.

  current = profile
            ^^^^^^^ source remains live and the snapshot is later distinguished

Use `current = COPY profile`, restructure the lifetimes, or remove STRICT from
this scope.
```

The compiler should provide:

- `clear explain ownership <file>:<line>` showing semantic intent, selected
  transport, allocator, and last-use evidence;
- optional warnings for implicit materialization inside loops;
- profile attribution for implicit copies and retains; and
- stable diagnostics whose remedies use CLEAR terms rather than Rust terms.

## Safety requirements

Automatic transport is permitted only when the compiler can prove:

1. a move invalidates every alias derived from the source;
2. an inferred borrow cannot escape and ends before conflicting mutation or
   destruction;
3. deep copy recursively duplicates every owned field and rolls back every
   partial allocation on error;
4. retain/release uses the capability's correct control block and allocator;
5. Rc never crosses a parallel execution boundary, including when nested in
   an aggregate;
6. Arc and WeakArc teardown is race-safe;
7. resources and other linear values are never implicitly duplicated;
8. destructor obligations are conserved through every branch and error path;
   and
9. the emitter cannot substitute a different semantic action based on lowered
   representation.

The known Arc cleanup, OOM, strong/weak race, and recursive boundary defects
must be fixed before automatic materialization is implemented. Automating an
unsound primitive would amplify the defect across otherwise ordinary code.

## Compiler architecture

This feature must not recreate separate EASY, DEFAULT, and STRICT ownership
engines.

The typed operation should carry one immutable intent:

```text
OwnershipIntent
  semantic_action: snapshot | shared_identity | weak_identity |
                   node_handle | borrow | move_only
  source_place
  destination_contract
  escape/lifetime facts
  allowed_materializations
```

A single planner chooses a transport:

```text
Move | Borrow | DeepCopy | RetainRc | RetainArc | RetainWeak | CopyNodeHandle
```

Modes only validate the resulting plan:

- EASY and DEFAULT accept every safe plan;
- STRICT rejects plans containing disallowed hidden costs.

MIR carries the chosen plan. Lowering and emission implement it mechanically;
they do not reconstruct intent from types, names, AST shapes, or cleanup
presence.

This architectural constraint is mandatory given the failed ownership-contract
migration documented in `ownership-cleanup-retrospective.md`.

## Analyses required

1. **Place-based liveness**: last use and move invalidation for roots, fields,
   indices, and captured paths.
2. **Alias lifetime analysis**: non-lexical active ranges for inferred borrows.
3. **Mutation effects**: writes through roots, fields, methods, collection
   operations, and aliases.
4. **Escape analysis**: returns, heap stores, captures, suspended FSM state,
   and execution boundaries.
5. **Recursive capability analysis**: contained Rc, Arc, resources, links, and
   node handles.
6. **Cost classification**: bit copy, move, local borrow, heap copy, Rc retain,
   Arc retain, node insertion, synchronization.
7. **Obligation validation**: every created owner is cleaned or transferred
   exactly once.

## Implementation sequence

### Phase 0: Repair and prove primitives

- fix current Arc cleanup, OOM rollback, and WeakArc teardown races;
- close recursive execution-boundary capability holes;
- establish fail-complete fuzz execution;
- add managed-payload, weak-reference, node, resource, concurrency, and OOM
  matrices.

No automatic copy feature should proceed while these primitives are unsound.

### Phase 1: Auto-move only

Elide `GIVE` where the destination owns the value and the source is dead.
Preserve diagnostics and allow explicit `GIVE` as documentation.

This is zero-cost and does not change semantics.

### Phase 2: Local borrow elision

Allow local `y = x` and argument passing to borrow when snapshot semantics are
observationally indistinguishable. Prove the borrow ends before mutation,
escape, or destruction.

### Phase 3: Capability-preserving retain elision

For values already declared `@multiowned`, `@shared`, `@link`, or `@node`,
insert the representation-appropriate retain/handle copy when the source
remains live. Do not infer a different capability.

### Phase 4: Snapshot materialization

For plain duplicable values, materialize the semantic snapshot only when move
or borrow elision cannot preserve behavior. Require complete recursive copy
and allocator-failure coverage first.

### Phase 5: STRICT cost enforcement

Run the same planner, then reject hidden costly actions. Add scoped diagnostics,
ownership explanations, and performance attribution.

### Phase 6: EASY integration

Use the same ownership planner after EASY type inference. EASY must not have a
separate fallback ownership system.

## Performance model

For common sequential code, the expected order is:

1. last-use move: equivalent to ideal C ownership transfer;
2. local borrow: equivalent to a raw pointer/reference with compile-time
   lifetime proof;
3. small static copy: equivalent to ordinary C value passing;
4. Rc retain for declared shared-local identity;
5. Arc retain for declared cross-thread identity;
6. deep copy only when snapshot semantics are observably required.

Near-perfect C performance is realistic for move/borrow-heavy code. It cannot
be promised for programs whose semantics genuinely require independent deep
copies or shared atomic ownership. CLEAR's advantage is choosing the zero-cost
case automatically and making unavoidable costs observable, not pretending
those costs do not exist.

DEFAULT should warn or profile implicit materialization in hot loops. STRICT
turns those costs into errors for code that requires deterministic control.

Copy-on-write is not part of the initial design. It can reduce copies but adds
hidden reference counting, uniqueness checks, and more complex concurrent
semantics. It should be considered only as an explicit capability with its own
benchmarks and safety model.

## Fit with CLEAR's goals

### Maximum local reasoning

The corrected model fits well because types and destination contracts decide
observable behavior locally. Whole-function analysis changes only transport,
never the meaning of mutation or identity.

Silent affine-to-Rc inference would fit poorly: distant escape behavior would
change local layout, destructor timing, and mutation visibility.

### Minimum global complexity

One semantic model and one planner serve all modes. EASY adds type inference;
STRICT adds a cost policy. Neither adds a second ownership system.

The implementation is still substantial. It should be pursued only after the
existing ownership/runtime safety matrix is trustworthy.

### Maximum optionality

Developers can begin with ordinary assignments, inspect inferred costs, add
capabilities where shared identity is intended, and apply STRICT only to hot
or high-integrity scopes. Explicit ownership operators remain available at
every level.

### Maximum safety

Snapshot semantics remove mutation ambiguity for plain values. Capability
semantics keep shared mutation explicit. Linear resources remain non-copyable.
Recursive boundary checking prevents hidden Rc from crossing threads.

### Ruby/Python ease for sequential code

Most sequential code becomes ordinary assignment and calls. Moves, temporary
borrows, and unavoidable snapshots are compiler-managed. Developers intervene
only for architectural choices—shared identity, graph lifetime, resources—or
for explicit performance control.

### Easier concurrency than Go

CLEAR should not make concurrency easy by hiding sharing. It should make it
easy by making illegal sharing unrepresentable and by attaching synchronization
policy to the value. `@shared:locked`, `@shared:versioned`, atomics, and
polymorphic synchronization remain visible; retain/release and capture plumbing
can be elided.

This is a stronger local model than Go's convention-based sharing plus tracing
GC, while requiring less per-use ceremony than Rust.

## Final recommendation

Adopt automated ownership transport in EASY and DEFAULT, with STRICT rejecting
hidden costly materialization. Do not adopt automatic affine-to-Rc/Arc upgrade.

Define plain assignment as snapshot semantics, declared capabilities as shared
identity semantics, and compiler-selected move/borrow as invisible as-if
optimizations. This provides the ergonomic win without making meaning depend
on distant liveness facts.

The feature is a strong fit for CLEAR only in this constrained form. The
unconstrained proposal—choosing deep clone versus Rc/Arc from escape analysis—
would reduce syntax while increasing global semantic complexity, which is the
opposite of CLEAR's primary goal.
