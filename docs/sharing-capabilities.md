# Shared Data in CLEAR

CLEAR separates:

1. **what data is** (Types) from
2. **how it's accessed** (Gates & Boundaries) from
3. **the strategy it uses** (Capabilities) from
4. **when it's available** (Tense: `~T`)

## Types, Capabilities, and Execution Boundaries
Rust is not inherently complicated, nor is its type system much more complex than C++'s. The actual friction comes from Rust using a 'God-like' type system forced to handle too many things at once.

CLEAR breaks these into 4 separate components:

 * **Types:** The actual data / memory (User)
 * **Capabilities:** What you’re allowed to do with that data (User `@shared:locked`)
 * **Execution Boundaries:** When you're do things concurrently or in parallel (`BG/DO/CONCURRENT`)
 * **Synchronization Gates:** Where you explicitly mutate state concurrently (`WITH sharedUser AS user { … }`)

In CLEAR, concurrency is a property of the execution boundary, not the data type. CLEAR requires explicit `WITH` blocks for synchronization. While slightly less ergonomic than Rust for a simple Mutex, this design choice yields key structural dividends:

 * **Zero-Friction Pass-Through:** ~85% of your codebase handles shared data without a single synchronization annotation, making code substantially more maintainable / refactorable to optimize for different synchronization strategies.
 * **Polymorphic Synchronization:** A single function can gracefully handle any of `LOCKED`, `SNAPSHOTTED`, `ACTOR`, `BUFFERED` etc data using a single block of code.
 * **Pinpoint Cost Visibility:** You know exactly where and when your code blocks, yields, retries and the associated failure methods. Latency costs are isolated to the 15% of functions that actually mutate state, rather than hidden in a type signature 10 levels up the stack.

You do not need to worry about a developer accidentally “sneaking” a slow actor synchronization into a hot loop. The costs are enforced ONLY at the synchronization boundaries (`WITH` blocks). The compiler will simply reject incompatible synchronization strategies inside hot loops.

```ruby clear illustrative
FN transact(
  a: Account@shared, 
  b: Account@shared,
  amount: Float64
) 
 RETURNS !Bool
 REQUIRES a, b: LOCKED | SNAPSHOTTED | BUFFERED
->
 IF amount <= 0 -> RAISE;

  WITH 
   POLYMORPHIC a AS acctA,
   POLYMORPHIC b AS acctB {
     IF acctA.balance <= amount -> RAISE;
     acctA.balance -= amount;
     acctB.balance += amount;
   }
   ON LockTimeout ...
   ON Conflict ...
   ON QueueFull ...
  END
END
```

There is a user-defined default policy for handling failure methods.  Not every function needs to specify failures:

```ruby clear illustrative
FN transact(a: Account@shared, b: Account@shared) RETURNS !Bool ->
  WITH POLYMORPHIC a AS acctA, POLYMORPHIC b AS acctB { ... }
END
```

This function will take any shared object: Mutex (`@locked`), RwLock (`@writeLocked`), MVCC (`@versioned`), AtomicPtr (`@atomic`), RingBuffer (`@buffered`), Actor (`@actor`). It will handle failure methods by the user-defined synchronization policy (or the system default):

```ruby clear illustrative
SYNC POLICY
  ON MvccConflict RETRY(3) THEN RAISE
  ON AtomicConflict RETRY(3) THEN RAISE
  ON LockTimeout RETRY(3) THEN RAISE
  ON QueueFull BLOCK
  ON ActorTimeout RAISE
END
```

Third-party code / libraries must compile in `STRICT` mode, which requires them to explicitly handle all failure methods.  There is no chance your default sync policy creates spooky-action-at-distance in third party failure handling.

FAQ:
 * But what about lock acquisition? 
    * CLEAR automatically sorts locks. It raises errors on deadlock that MUST be handled if possible (regardless of compilation mode), rather than deadlocking.
 * But what about the Default Policy causing Spooky-Action-at-a-Distance internally? 
    * Compile in `STRICT` mode where this is not allowed, and then you know all synchronization failure methods are handled locally.
    * Default synchronization failure policies are meant to be a speed up for prototyping, not something to use in production.
 * But what about distributed failures?
    * `@actor` in CLEAR does not imply a distributed actor.
    * There is `@shared:actor` (single-machine) and `@distributed:actor` (n-machines).
    * `@distributed` is not interchangeable with `@shared`.
    * `FN foo(x: T@shared)` does not accept a `@distributed:actor`.
    * `FN foo(x: T@distributed)` does not accept a `@shared:actor` (it may not exist on the machine!)

> [!NOTE]
> `@actor` and `@buffered` are in scope for v0.3.  They are not currently available.  `@distributed` is in scope for v0.4.

### Analogy

Think of `DO/BG/CONCURRENT` blocks as Execution Boundaries, and ownership capabilities (`@shared`) as your Keys to pass the Boundary.  A type without proper ownership cannot pass through an Execution Boundary (that is unsafe).

If you want to do something in parallel (on multiple cores at once), the data must be `@shared`.  If you want to do something concurrently (on a single core at once), the data can be `@shared` OR `@local`.

Similarly, a type with a synchronization capability (`@locked`, `@versioned`, etc) requires crossing a gate for safe access. 

The `WITH` block acts as this gate to safe access as the BG/DO blocks act as the gate to safe boundary crossing.  `WITH` blocks require a type of permission to safely access synchronized data - this gives the reader insight into the cost.

| Ownership (the keys) | Execution Boundaries | Synchronization | Access Gates | Access Permission (cost model) |
|---|---|---|---|---|
| @shared (any cores) | BG {} | @locked, @writeLocked | WITH {} | EXCLUSIVE |
| @local (pinned to a core) | DO {} | @versioned, @atomic | | SNAPSHOT |
| | CONCURRENT {} | @actor, @buffered | | EVENTUAL |

`@multiOwned` is an ownership capability, but it does not grant access through Execution Boundaries.  It allows an object to have multiple aliases (multiple owners - i.e. for a graph), but it does NOT grant permission to cross Execution Boundaries.

### Complexity Reduced?  Or just moved around?

It is a fair critique from Rust or Go that this is nothing new, and arguably more complex.  Rust has a single system to keep track of.  CLEAR has three.  If anything, that’s more complex, not less.

CLEAR thinks it is clearer to break the problem down into steps.  For one, developers not familiar with concurrent code know that anything `@shared` is something concurrent.  In Rust, it is hard to distinguish between `Arc<RwLock<T>>`, `DashMap<T>`, and `Vec<T>`.  Which one is something concurrent, that could have logical race bugs?

Secondly, while this might appear to be unergonomic, the concurrent benchmarks in CLEAR are only ~70% of the code as Rust (much more expressive than non-Rust people probably assume), and ~30% of the code as Go.

Lines of code on its own is a terrible benchmark for complexity. But CLEAR did not attempt to cherry-pick this metric. This is on top of the benefit of having polymorphic synchronization for almost no cost, and the ability to benchmark different strategies almost free.

Thirdly and most crucially, polymorphic synchronization allows your code to be maintainable in a way that is very difficult to achieve in Rust or Go.  `Arc<RwLock<T>>` is viral in Rust.  `T@shared` is not in CLEAR.

 * Step 1) update your with blocks to use POLYMORPHIC access permission.  
 * Step 2) change your synchronization strategy from @locked to @versioned.  
 * Step 3) run `clear profile`. 
 * Step 4) profit.

### CLEAR levels the playing field for non-experts

In Rust or Go, you need to fully understand the implications of your code before you even write and test it.  Unless you are an expert (and even if you are), this is difficult to get right.
If you get it wrong, it is typically painful to rearchitect your app to do it right. It is also possible after your code continues to grow, you may need to switch again (possibly back to where you started), which can be equally painful.

CLEAR was designed assuming that you cannot get everything right from the get-go, and to make it as easy as possible to experiment and optimize to get it right.  It was designed assuming you want to get there, even if you would have no chance in Rust or Go, because you need to understand things at a deeper level.

CLEAR was designed to act like a high-level language like Ruby, but give you systems level speed.

## Capabilities in Depth

When multiple fibers need to access the same data, CLEAR must answer two questions:

1. **Lifetime**: How does the data stay alive when multiple fibers reference it?
2. **Thread safety**: Is the reference count safe across schedulers (OS threads)?

## Quick Reference

| Capability | Zig Type | Refcount | Thread-safe? | `@parallel` | Use when |
|---|---|---|---|---|---|
| `@local` | `*T` | None | No (single-scheduler) | **Error** | Fibers on one scheduler share mutable state |
| `@multiowned` | `Rc(T)` | Non-atomic | No (single-scheduler) | **Error** | Multiple owners, single scheduler, read-mostly |
| `@shared` | `Arc(T)` | Atomic | Yes | Allowed | Cross-scheduler sharing (rare) |

## @local — Zero-Cost Shared Mutable Reference

```ruby clear
MUTABLE c = Counter{ value: 0 } @local;

BG { c.value += 1; }            # direct field access, no WITH block
BG { print(c.value); }          # direct read
```

**What it does**: Heap-allocates the value and returns a bare `*T` pointer. No Mutex, no RwLock, no reference counting. Multiple fibers share the pointer by value copy.

**Why it's safe**: The compiler auto-pins all BG/DO blocks that capture `@local` variables to the local scheduler. Cooperative scheduling on a single OS thread means no two fibers ever execute simultaneously — no data races are possible.

**When to use it**: This is the **default choice** for shared mutable state within a function scope. It's the fastest option — zero synchronization overhead.

**Compile-time enforcement**:

```ruby clear illustrative
BG { @parallel -> c.value = 1; }
# ERROR: @local variable cannot be used in @parallel block
```

## @multiowned — Non-Atomic Reference Counting (Rc)

```ruby clear illustrative
node = TreeNode{ left: NIL, right: NIL } @multiowned;

# Multiple owners via WITH block:
WITH node AS val { print(val.left); }
```

**What it does**: Wraps the value in `Rc(T)` — a non-atomic reference-counted pointer. Each `WITH` unwrap increments the refcount; scope exit decrements it. The value is freed when the last reference is released.

**What it does**: Wraps the value in `Rc(T)` — a non-atomic reference-counted pointer. Each `WITH` unwrap increments the refcount; scope exit decrements it. The value is freed when the last reference is released.

**Why it exists**: For **graph structures** and **shared ownership** patterns where multiple variables need to keep the same value alive. Unlike `@local` (which has one owner and shared pointers), `@multiowned` has multiple owners with automatic lifetime management.

**Read-only access**: `WITH node AS val` provides **read-only** access to the inner value. `@multiowned` does not support mutation — it's shared ownership, not shared mutation. This is analogous to Rust's `Rc<T>` (not `Rc<RefCell<T>>`).

**For shared mutation**, use:
- `@alwaysMutable` — interior mutability (`RefCell`), mutate through const bindings
- `@local` — zero-cost, single-scheduler, direct field writes
- `@locked` — mutex-protected, cross-scheduler safe

**Why it's NOT thread-safe**: `Rc` uses a plain integer for its refcount — no atomic CAS, no memory barriers. If two threads increment/decrement simultaneously, the count corrupts (use-after-free or double-free).

**Compile-time enforcement**:

```ruby clear illustrative
BG { @parallel -> WITH node AS val { ... } }
# ERROR: @multiowned (Rc) variable cannot be used in @parallel block —
# Rc uses a non-atomic reference count. Use @shared (Arc) for cross-scheduler sharing.
```

**When to use it**: Graphs, trees, and shared ownership patterns where all fibers run on the same scheduler and data is read-only. If you need mutation, use `@local`. If you need cross-scheduler sharing, use `@shared`.

## @shared — Atomic Reference Counting (Arc)

> [!NOTE]
> Technically `@shared` means permission to cross an execution boundary. Atomics and atomic pointers (`@shared:atomic`) are NOT wrapped in Arc.

```ruby clear illustrative
config = AppConfig{ port: 8080 } @shared;

BG { @parallel -> WITH config AS c { print(c.port); } }  # OK
BG { @parallel -> WITH config AS c { print(c.port); } }  # OK
```

**What it does**: Wraps the value in `Arc(T)` — an atomic reference-counted pointer. The refcount uses hardware atomic instructions (lock-prefixed CAS on x86), so it's safe to increment/decrement from any thread.

**Why it's expensive**: Every clone/drop of an `Arc` bounces the cache line containing the refcount between CPU cores. On a 16-core machine, this "cache-line bouncing" can cost ~100ns per operation (vs ~1ns for a non-atomic increment).

**When to use it**: Only when you **genuinely need** cross-scheduler sharing — data accessed by fibers on different OS threads. This is rare in practice: most shared state is within a single function scope (use `@local`) or within a single scheduler (use `@multiowned`).

## Combining with Sync Capabilities

Sharing capabilities can be combined with sync capabilities for mutable cross-thread access:

```ruby clear illustrative
# Arc + Mutex: one-line mutations auto-lock
MUTABLE counter = Counter{ value: 0 } @shared:locked;
BG { @parallel -> counter.value += 1; }                             # auto mutex

# Arc + RwLock: cross-scheduler read-heavy access
MUTABLE config = Config{ port: 8080 } @shared:writeLocked;
BG { @parallel -> WITH config AS c { print(c.port); } }            # read lock
BG { @parallel -> config.port = 9090; }                             # auto write lock
```

`@local` does not combine with `@locked` or `@writeLocked` — it's already a bare pointer with no wrapper. Mutation is direct.

## Decision Tree

```
Do multiple fibers need to access this data?
├── No  → default (no capability, single owner)
└── Yes
    ├── Does it need mutable access?
    │   ├── Same scheduler → @local (zero cost, direct field writes)
    │   └── Cross-scheduler → @locked or @writeLocked (mutex/rwlock)
    └── Do multiple fibers need to OWN it (keep it alive)?
        ├── Read-only, same scheduler → @multiowned (Rc)
        ├── Read-only, cross-scheduler → @shared (Arc)
        └── Mutable + shared ownership → @local (same scheduler)
            or @shared:locked (cross-scheduler)

Stable heap address needed (graph edges, self-referential)?
└── @indirect (combinable with any of the above)
```

**Note on primitives**: Capabilities cannot be applied to primitive types (`Int64`, `Float64`, `Bool`, `Byte`, `Float32`). Wrap in a `STRUCT` first — this makes the intent explicit and gives you named fields.

## Auto-Pinning

The compiler automatically pins BG/DO blocks to the local scheduler when they capture `@local`, `@multiowned`, `@shared`, `@locked`, or `@writeLocked` variables. This is a **cache-line bouncing optimization** for thread-safe types and a **safety requirement** for non-thread-safe types.

To override auto-pinning for thread-safe types:
```ruby clear illustrative
BG { @parallel -> ... }   # distribute across schedulers
```

For non-thread-safe types (`@local`, `@multiowned`), `@parallel` is a compile error.
