# Retained Identity v5: Declaration-Sited Cost, Callee-Sited Correctness

Status: proposed design, 2026-07-22. Supersedes v4's destination-inferred
"cheapest operation" model. V4 erased the caller's selected carrier by
normalizing every kept parameter to an Rc handle, and therefore could not
distinguish copying a plain value from retaining an Rc/Arc value inside a
carrier-polymorphic function.

## Decision

CLEAR separates two decisions:

1. The declaration chooses the value's ownership carrier and therefore its
   cost model: plain value, `@multiowned`, or `@shared`.
2. The function author chooses the correctness model at every point where one
   owner must become multiple owners.

The correctness choices are:

- `COPY_OR_KEEP value`: another owner may either be independent or share the
  same identity. Preserve the carrier chosen by the caller.
- `COPY value`: the new top-level value must have independent identity. Nested
  fields follow their own declared ownership carriers. It is legal for locally
  declared values and parameters constrained as `UNIQUE`.

There is no `ALWAYS_COPY` and no `@willCopy`.

### Terminology: CLEAR `CLONE` versus Rust `.clone()`

CLEAR's historical `CLONE` is not Rust's `Clone` trait operation. In CLEAR,
`CLONE` has one narrow ownership meaning: create another Rc/Arc owner of the
same identity by incrementing the applicable reference count. It never means a
payload copy.

Rust's `.clone()` is type-defined: cloning a `Vec` copies its allocation and
elements, while cloning an `Rc` or `Arc` increments a reference count. CLEAR
intentionally keeps those mechanisms separate:

- `COPY`: create independent payload identity;
- `KEEP`: preserve the current owner while giving another owner the same
  identity;
- `GIVE`: transfer the current owner;
- `TAKES`: declare that the callee receives ownership.

`KEEP` is therefore a clearer public ownership verb for the operation formerly
spelled `CLONE`; the semantic operation has not changed. `COPY_OR_KEEP` means
that the callee permits either independent identity or retained identity and
the source declaration selects which mechanism applies.

## Rust translation completeness

The ownership model is intentionally not a spelling-level clone of Rust, but
it must preserve the semantics and cost class of safe, idiomatic Rust. The
following mappings are lossless when the carrier and copy plan remain present
through MIR:

| Rust | CLEAR |
|---|---|
| move into an owned parameter | final consuming use / `GIVE` into `TAKES` |
| `&T` | ordinary borrowed parameter or `WITH VIEW` |
| `&mut T` | `MUTABLE`/addressed argument under exclusive access |
| `Box<T>` | `@boxed`/indirect owned placement |
| `Rc<T>` | `@multiowned T` |
| `Arc<T>` | `@shared T` |
| `Rc::clone` / `Arc::clone` | `KEEP` or an inferred retain from an already explicit carrier |
| `Weak<T>` downgrade/upgrade | `LINK` / `RESOLVE` |
| derived `Clone` | structural `COPY` using the authoritative per-field CopyPlan |
| `Arc::unwrap_or_clone` | shared-to-`UNIQUE` `COPY`, optimized to move when uniquely held |

This genuinely removes one class of Rust complexity: public APIs need not be
duplicated or wrapper-parameterized for `T`, `Rc<T>`, and `Arc<T>`, and callers
need not repeat `.clone()` when a declaration and `SHARED` contract already
make retained identity inevitable. The compiler still emits the same move,
non-atomic retain, atomic retain, allocation, and cleanup operations.

It cannot eliminate semantic choices that Rust exposes:

- whether a new owner shares top-level identity;
- whether an outer value is copied while nested fields remain shared;
- whether mutation uses unique access, locking, versioning, or clone-on-write;
- whether a weak reference can expire;
- whether a value's address must remain stable;
- arbitrary behavior in a user-written Rust `Clone` implementation.

Erasing any of those choices would be a lossy translation, not simplification.

### Structural copy, not recursive graph duplication

Rust's derived `Clone` calls `clone` on every field. A struct containing a
`Vec<Arc<Node>>` therefore receives a new vector allocation while its nodes
remain shared. CLEAR must express the same topology without overloading one
word:

```clear
STRUCT Snapshot {
  name: String,
  nodes: []Node@shared,
}

copy = COPY snapshot;
```

The CopyPlan for this expression performs:

1. a new top-level `Snapshot` value;
2. a new owned `name` buffer;
3. a new list allocation;
4. one `KEEP` for each `Node@shared` element.

Thus `COPY` guarantees new top-level identity, not a recursively independent
object graph. A recursively independent graph copy is domain-specific in the
presence of cycles, weak links, resources, caches, and shared subgraphs. It
belongs in an explicit normal function such as `deepCopyGraph`, not in the
ownership primitive.

`UNIQUE T` likewise means that the top-level `T` payload is exclusively owned.
It does not claim that every field reachable from `T` is unique. A type that
requires recursive uniqueness must express that in its field types or a
separate domain contract.

### Separate type predicates

The compiler must not use one `copyable?` predicate for several different
questions. It needs authoritative, strongly typed facts equivalent to:

- `trivially_copyable?`: implicit bit/value copy is legal and cheap;
- `structurally_duplicable?`: an explicit `COPY` plan exists;
- `retainable?`: `KEEP` is legal for this carrier;
- `linear?`: no second owner can be created;
- `copy_plan`: the exact fieldwise copy/keep/allocation/cleanup recipe.

An Rc/Arc handle is not trivially copyable, but it is retainable. A struct with
an Rc/Arc field can be structurally duplicable even though that field is kept
rather than copied. A file descriptor or closed stream may be linear and make
the enclosing struct non-duplicable unless a normal domain operation defines
different semantics.

The current runtime already follows much of this model: aggregate duplication
recurses into owned buffers and containers while Rc/Arc fields route through a
retain operation. The semantic type predicate and MIR vocabulary must agree
with that runtime contract rather than rejecting a struct merely because one
field is retained.

### User-defined Rust `Clone`

Rust permits `Clone::clone` to run arbitrary code. It may reset caches, preserve
singleton state, share internal buffers, or perform a domain-specific
transformation. That cannot soundly become CLEAR `COPY` or `KEEP` merely from
the method name.

A Rust-to-CLEAR translator must resolve the actual implementation:

- `Rc`/`Arc` clone becomes `KEEP`;
- a derived fieldwise clone becomes `COPY` when its CopyPlan is equivalent;
- a trivial value clone becomes an implicit value copy or explicit `COPY`;
- a custom clone becomes a translated normal method/function;
- generic `T: Clone` requires a compatibility protocol such as `Duplicable`,
  whose operation makes no stronger identity promise than the source trait.

`Duplicable` should not be added to CLEAR's core ownership vocabulary until a
real generic translation requires it. General functions already preserve
non-generic custom clone behavior. If introduced, it remains distinct from
`COPY`, `KEEP`, and `COPY_OR_KEEP` so arbitrary user code cannot weaken their
guarantees.

### Remaining intentional and real gaps

1. **Clone-on-write:** Rust `Cow` and `Arc::make_mut` copy only when mutation
   encounters multiple owners. Translating them to an unconditional `COPY` is
   semantically correct in many cases but can be materially slower. The
   reserved `@cow` design is the correct zero-overhead place to close this gap;
   `COPY_OR_KEEP` must not gain runtime refcount branching.
2. **Observable uniqueness:** `Arc::get_mut`, `try_unwrap`, and strong-count
   inspection let Rust branch on runtime ownership. Most CLEAR code should not
   depend on refcounts, but exact compatibility may eventually need a narrow
   `IF value IS UNIQUE AS owned`/`TRY TAKE UNIQUE value` operation. Do not add it
   without concrete translation cases.
3. **Address pinning:** CLEAR's existing `@pinned` means scheduler affinity,
   not Rust's guarantee that a pointee's address cannot change. Compiler-owned
   async state can hide Rust's `Pin` ceremony, which is a genuine simplification.
   FFI, self-referential values, and intrusive structures still need a distinct
   address-stability guarantee or an explicit unsupported diagnostic.
4. **Unsafe/custom smart pointers:** exact allocator, atomic-ordering, pointer,
   and destructor tricks are not promised by this model. They require a narrow
   systems escape hatch or remain intentionally outside safe CLEAR.

The first implementation priority is the structural CopyPlan and predicate
split. `@cow` is second if real translated code demonstrates material use.
Generic custom-clone compatibility and observable-refcount operations are
deferred until concrete source programs require them.

### Clone-on-write is a declaration capability

The lossless Rc/Arc clone-on-write spelling is:

```clear
MUTABLE local = User{} @multiowned:cow;
MUTABLE crossScheduler = User{} @shared:cow;
```

`@multiowned:cow` corresponds to an Rc-backed copy-on-write owner.
`@shared:cow` corresponds to an Arc-backed copy-on-write owner. `:cow` is a
write policy layered on the retained ownership carrier; it is not another
fan-out operation.

```clear
MUTABLE u = User{ name: "before" } @multiowned:cow;
old = KEEP u;

TRY &u.rename("after");

# u was detached before mutation because old retained the original identity.
# old still observes "before"; u observes "after".
```

The lowering of the addressed mutation is:

```text
exclusive access to the owner slot
  -> if this is its only strong owner, mutate the payload in place
  -> otherwise execute the payload CopyPlan
  -> rebind this owner slot to the new allocation
  -> release this slot's ownership of the old allocation
  -> mutate the new payload
```

For `@shared:cow`, the count operation and lifetime transitions are atomic.
The payload is still mutated only through exclusive access to the current
owner slot. Atomic reference counting does not make simultaneous mutation of
one binding legal.

No `COPY_ON_WRITE_IF_APPLICABLE_OR_KEEP` operation exists. At fan-out:

- `KEEP` on a concrete COW carrier retains the current allocation;
- `COPY_OR_KEEP` on a carrier-polymorphic parameter selects `KEEP` for either
  COW carrier;
- last use moves the handle;
- only a later addressed mutation invokes the COW policy.

This preserves declaration-sited cost choice: the programmer accepts the
uniqueness check and possible CopyPlan when writing `:cow`, not at every use.

#### Capability compatibility

The first supported combinations are only:

- `@multiowned:cow`;
- `@shared:cow`.

Plain `T@cow` has no retained control block on which to test uniqueness and is
rejected initially. `@locked:cow`, `@writeLocked:cow`, `@versioned:cow`,
`@alwaysMutable:cow`, and atomic-cell combinations are rejected because they
mix incompatible mutation visibility models. A later standalone borrowed-or-
owned `T@cow` may model Rust `Cow<'a, T>`, but that is a distinct second phase,
not required for Rc/Arc `make_mut` parity.

The payload must be structurally duplicable. Linear resources make the COW
composition illegal unless the containing type's explicit CopyPlan defines a
sound duplication strategy.

#### Mutation visibility and contracts

COW is shared ownership, not coherent shared mutation. After a detach, other
owners intentionally continue observing the old value. Therefore:

- `@shared:cow` satisfies ownership/cross-scheduler `SHARED` requirements for
  reads, moves, and keeps;
- it does not satisfy `LOCKED`, `SNAPSHOTTED`, `VERSIONED`, or any contract
  promising that all aliases observe one mutation;
- a new narrow `COW`/`FORKABLE` requirement may be added only when a function
  specifically depends on detaching mutation;
- an unconstrained mutable-polymorphic function must promise only to update
  the supplied owner binding, not every alias in the program.

This distinction must be represented in capability-family admission rather
than inferred from the function body.

#### Fallibility

Detachment can allocate and execute a fallible CopyPlan. A mutation through a
COW carrier must therefore participate in the existing call-site error
projection. A concrete uniquely held owner may optimize the copy path away,
but the static operation remains potentially fallible unless the allocator and
CopyPlan are proven infallible. DEFAULT/STRICT must not hide allocation failure.

#### Weak links

`LINK` observes one allocation identity. If COW detaches an owner, existing
weak links remain attached to the old allocation; they never silently retarget
to the new value. When no strong owner of the old allocation remains,
`RESOLVE` fails normally. An implementation may move rather than copy when no
other strong owner exists, but it must preserve this weak-link behavior.

`COPY` is not allowed on an unconstrained carrier-polymorphic parameter. A
function that requires independent identity declares the parameter `UNIQUE`;
a caller holding `@multiowned` or `@shared` data must explicitly copy at that
boundary. This keeps a required payload copy visible at the place where the
shared cost model meets the unique contract.

## Motivating example

```clear
u1 = User{};
u2 = User{}@multiowned;

foo(u1);
foo(u2); # Move the handle if this is its last use; otherwise retain it.

FN foo(TAKES u: User) ->
  cache(u);
  queue(u); # Error: cache consumed carrier-polymorphic parameter u.
END

FN cache(TAKES u: User) USES(c: Cache<User>) ->
  c.add(u);
END

IMPLEMENTATION Cache<T> {
  METHOD add(self, TAKES item: T) ->
    &self.values.put(item);
  END
}

FN queue(TAKES u: User) ->
  # ...
END
```

The declaration of `u1` or `u2` selects the cost model. The implementation of
`foo` selects the correctness model. Adding `queue` must not require editing
every caller merely because some callers chose plain values while others chose
reference-counted values.

The fix is local to `foo`:

```clear
FN foo(TAKES u: User) ->
  cache(COPY_OR_KEEP u);
  queue(u);
END
```

The first consuming use must be changed because that is where another owner is
created. The final consuming use moves the remaining owner.

The compiler diagnostic should be:

```text
u is consumed by cache and used again by queue.

u is a carrier-polymorphic parameter. Choose how the additional owner is
created:
  cache(COPY_OR_KEEP u);  # preserve the caller's ownership model

If both consumers require independent identity, constrain the parameter as
UNIQUE and use COPY.
```

## Operation table

| Source carrier | Final consuming use | `COPY_OR_KEEP value` | `COPY value` |
|---|---|---|---|
| plain value | move payload | copy payload | copy payload |
| `@multiowned` | move Rc handle | non-atomic retain | not legal until converted at a `UNIQUE` boundary |
| `@shared` | move Arc handle | atomic retain | not legal until converted at a `UNIQUE` boundary |

`COPY_OR_KEEP` is a compile-time carrier choice, never runtime clone-on-write.
It creates the ownership operation selected by the source declaration:

- plain carrier: payload copy;
- `@multiowned`: Rc retain;
- `@shared`: Arc retain.

It does not promise independent identity. Code requiring independence must use
a `UNIQUE` contract and `COPY`.

## Parameter contracts

### Carrier-polymorphic ownership

```clear
FN consume(TAKES value: User) ->
  # Accepts a moved plain value, Rc handle, or Arc handle.
END
```

One consuming path needs no annotation: the owner moves. Multiple live
consuming paths require `COPY_OR_KEEP` at the first fan-out.

### Unique ownership

```clear
FN forkIndependent(TAKES value: UNIQUE User) ->
  cache(COPY value);
  queue(value);
END
```

`UNIQUE` means the function receives an exclusively owned payload. It does not
itself create another owner; the first of two consuming uses still needs
`COPY`.

`UNIQUE` should be rare. Appropriate uses include:

- destructive zero-copy transformations;
- in-place buffer reuse;
- FFI ownership transfer;
- closing or consuming resources;
- secret-data wiping;
- operations whose correctness requires the absence of aliases.

A shared caller must make the independent copy explicit:

```clear
shared = User{}@multiowned;
forkIndependent(COPY shared); # Produces the UNIQUE argument at the boundary.
```

This is the only place `COPY` may consume a non-unique carrier: it is an
explicit conversion required by a `UNIQUE` parameter contract. The compiler
must reject such a copy when `User` is not copyable.

### Shared identity

```clear
FN register(TAKES session: SHARED Session) ->
  # Every keeper must observe the same identity.
END
```

`SHARED` means copying the payload would be semantically wrong. It accepts the
appropriate retained-identity families and rejects a plain value in
DEFAULT/STRICT mode. If both `@multiowned` and `@shared` satisfy `SHARED`, a
separate thread-safety requirement must distinguish single-thread Rc from
cross-thread Arc; `SHARED` must not silently make `@multiowned` thread-safe.

Multiple consuming uses of a `SHARED` parameter retain automatically because
the parameter contract already declares that shared identity is required.

## Static rules

1. A final consuming use moves the payload or handle.
2. Multiple consuming uses in mutually exclusive control-flow branches do not
   require duplication.
3. Multiple simultaneously live consuming uses of a carrier-polymorphic
   parameter require `COPY_OR_KEEP` at every non-final fan-out.
4. `COPY_OR_KEEP` on a statically plain local is an error: use `COPY`.
5. `COPY_OR_KEEP` on a `UNIQUE` parameter is an error: use `COPY`.
6. `COPY` on an unconstrained carrier-polymorphic parameter is an error: use
   `COPY_OR_KEEP`, or change the parameter contract to `UNIQUE` if independent
   identity is required.
7. `COPY` requires a copyable payload.
8. `COPY_OR_KEEP` requires a copyable payload when instantiated with a plain
   carrier. A non-copyable plain caller must choose a retained carrier or the
   function must be restructured.
9. A declaration-sited `@multiowned` or `@shared` local may be retained without
   a per-use `CLONE`; the declaration already made that cost model explicit.
10. Escape through a closure, background task, container, returned object, or
    transitive `TAKES` call counts as a consuming use.
11. A loop may create a dynamic number of owners. Its body must contain the
    applicable explicit `COPY` or `COPY_OR_KEEP`; a single operation outside
    the loop cannot justify all iterations.

## Why provenance is limited to the contract boundary

The compiler must not track a permanent "originally came from a parameter"
taint after a value has crossed a `UNIQUE` boundary. `TAKES ... UNIQUE` makes
the parameter locally owned inside the function. It is therefore eligible for
`COPY` exactly like a local declaration.

Conversely, assigning an unconstrained parameter to a new local name does not
make it unique:

```clear
FN bad(TAKES value: User) ->
  alias = value;
  copy = COPY alias; # Error: alias retains value's carrier-polymorphic contract.
END
```

This fact belongs in the value's ownership plan, not in name-based syntax or a
second flow-sensitive provenance system.

## No `ALWAYS_COPY`

`ALWAYS_COPY` would duplicate the meaning of `COPY` on a `UNIQUE` value. If an
unconstrained parameter must always become independent, the function is not
actually carrier-polymorphic at that boundary; its contract is `UNIQUE`.

That produces a visible and checkable API:

```clear
FN persistSnapshot(TAKES value: UNIQUE User) ->
  # ...
END
```

Callers with plain unique values move them for free. Callers with retained
values explicitly `COPY` to satisfy the contract. No hidden deep copy occurs
inside an apparently carrier-neutral call.

## No `@willCopy`

`@willCopy` is unnecessary because the `UNIQUE` contract exposes the
independence requirement and the shared-to-unique call edge contains the
explicit `COPY`. Adding another caller annotation would restate information
already present at the only boundary where it matters.

## Conditional independence

An algorithm that only sometimes needs an independent payload must not hide a
possible deep copy behind `COPY_OR_KEEP`; that operation permits aliasing. It
has three honest options:

1. accept `UNIQUE` and let the caller decide whether converting a retained
   value is acceptable;
2. split the independent operation into a helper with a `UNIQUE` contract;
3. use a future explicit `@cow` facility when avoiding the copy on the
   non-mutating path materially matters.

`@cow` is orthogonal and remains deferred. It must have explicit semantics and
must not be smuggled into `COPY_OR_KEEP` based on runtime reference counts.

## Lowering requirements

The v4 "all kept parameters use one Rc ABI" lowering is incompatible with this
design. It would turn the plain-carrier branch of `COPY_OR_KEEP` into a retain
and erase the declaration's cost choice.

The implementation must instead preserve the statically known carrier through
annotation and MIR:

```text
source declaration carrier
  + parameter ownership contract
  + consuming-use/liveness facts
  + explicit fan-out operation
  -> CallEdgeOwnershipPlan
```

The plan must select exactly one of:

- payload move;
- Rc-handle move;
- Arc-handle move;
- payload copy;
- Rc retain;
- Arc retain;
- shared-to-unique payload copy at an explicit contract boundary.

No later phase may rediscover or reinterpret that choice. MIR and Zig emission
consume the plan. Cleanup and transfer marks must be produced by the existing
authoritative lifecycle plan.

A carrier-polymorphic body requires compile-time carrier specialization or an
equivalent zero-runtime-cost representation strategy. Runtime tags or runtime
copy-versus-retain branches are forbidden. The implementation must measure and
cap specialization growth for functions with multiple carrier-polymorphic
parameters; it may not silently introduce an unchecked `2^N` code-size model.

## Diagnostics

Diagnostics must describe the correctness choice rather than merely reporting
use-after-move:

- Name the first consuming use and the later live use.
- Offer `COPY_OR_KEEP` for a carrier-polymorphic parameter.
- Offer `UNIQUE` plus `COPY` only when independent identity appears to be the
  intended contract.
- For `COPY_OR_KEEP` on a known plain or `UNIQUE` value, fix to `COPY`.
- For a non-copyable plain instantiation, suggest a retained carrier or a
  single-owner restructuring.
- For a plain argument passed to `SHARED`, suggest declaring the source
  `@multiowned`/`@shared`; EASY may autofix the declaration, but DEFAULT and
  STRICT must not silently allocate or change identity.

## Required tests

### Compiler specs

- Carrier-polymorphic `TAKES` with one consuming use: move only.
- Two consuming uses: diagnostic and fix at the first use.
- Fixed `COPY_OR_KEEP`: plain copy, Rc retain, and Arc retain plans.
- `UNIQUE` parameter with `COPY`: payload copy plus final move.
- `UNIQUE` alone does not permit two unannotated consuming uses.
- `SHARED` rejects plain values and preserves identity across consumers.
- Mutually exclusive branches do not require duplication.
- Sequential and nested transitive `TAKES` calls do.
- Aliasing an unconstrained parameter into a new local does not permit `COPY`.
- Non-copyable plain payloads reject `COPY_OR_KEEP` fan-out.
- Source ranges and fixable diagnostics point to the first consuming use.

### Transpile tests

- The complete `User`/`Cache<User>`/queue example above for plain,
  `@multiowned`, and `@shared` callers.
- Independent snapshot through a `UNIQUE` function.
- Shared-to-unique explicit `COPY` at the call boundary.
- Shared-identity registration that proves all consumers observe mutation.
- Last-use moves that emit no retain.
- Error exits after copy/retain with leak-free cleanup.

### Fuzz matrices

Cross:

- source carrier: plain, `@multiowned`, `@shared`;
- parameter contract: polymorphic, `UNIQUE`, `SHARED`;
- fan-out: none, sequential, exclusive branches, nested call, closure escape,
  loop, return-plus-store;
- operation: absent, `COPY`, `COPY_OR_KEEP`;
- payload: copyable, non-copyable;
- post-call source use: dead, read, consume, mutate.

Every positive cell must run under leak checking. Every negative cell must pin
the diagnostic and fix. Mutants that swap copy/retain/move or drop a lifecycle
mark must be killed.

### Code-generation assertions

- Plain `COPY_OR_KEEP` emits a payload copy and no retain.
- Rc `COPY_OR_KEEP` emits exactly one non-atomic retain and no payload copy.
- Arc `COPY_OR_KEEP` emits exactly one atomic retain and no payload copy.
- Last-use calls emit no retain or copy.
- Shared-to-unique conversion contains an explicit payload copy.
- No runtime carrier tag or copy-versus-retain branch is emitted.
- Carrier specialization remains within the documented bound.

## Acceptance criteria

1. The example compiles after changing only `foo` to use
   `COPY_OR_KEEP`; neither existing call site changes.
2. A function requiring independence uses `UNIQUE`, and shared callers receive
   a fixable error requiring an explicit boundary `COPY`.
3. `ALWAYS_COPY`, `@willCopy`, and per-use Rc/Arc spelling are absent.
4. Every copy, retain, and move has one authoritative ownership plan and one
   lifecycle plan.
5. No implicit payload copy or heap allocation occurs in DEFAULT/STRICT.
6. Unit, transpile, fuzz, leak, ownership-invariant, and Zig runtime tests pass.

## Non-goals

- No public `Rc<T>`/`Arc<T>` wrapper types in ordinary function signatures.
- No runtime-dispatched carrier choice.
- No reinterpretation of `COPY` as retain.
- No automatic deep copy of an unconstrained parameter.
- No `ALWAYS_COPY` or `@willCopy`.
- No clone-on-write behavior until `@cow` has a separate accepted design.
