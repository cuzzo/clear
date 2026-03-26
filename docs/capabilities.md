# CLEAR Capabilities

## Types vs Capabilities

In most languages, a type carries both its data layout *and* its concurrency strategy. A `Mutex<Counter>` in Rust is a different type from `Arc<Counter>` which is a different type from `Counter`. Functions that take one can't take the others. Changing your concurrency model means rewriting every function signature in the call chain.

CLEAR separates these concerns:

```
Type        = what the data IS        (Counter, User, Config)
Capability  = how the data is ACCESSED (@local, @locked, @shared)
```

Functions take **Types**. Capabilities are applied at the **declaration site** and unwrapped at the **call site**. The function never knows or cares.

```clear
-- ILLUSTRATIVE
FN increment(c: Counter) RETURNS Counter ->
    RETURN Counter{ value: c.value + 1 };
END

-- All of these call the SAME function:
a = Counter{ value: 0 } @local;
b = Counter{ value: 0 } @locked;
c = Counter{ value: 0 } @shared;

increment(a)                              -- direct deref
WITH EXCLUSIVE b AS inner { increment(inner) }  -- mutex guard
WITH c AS val { increment(val) }          -- arc unwrap
```

One function definition. Three concurrency strategies. Zero code changes to `increment`.

For one-line field mutations on `@locked`/`@writeLocked` variables, the compiler auto-wraps the statement in an inline mutex guard — no `WITH` block needed:

```clear
-- ILLUSTRATIVE
MUTABLE b = Counter{ value: 0 } @locked;
b.value = b.value + 1;  -- compiler auto-acquires and releases the mutex
```

## The Capability Dimensions

CLEAR has three orthogonal capability dimensions. They can be combined in any order via `:` chaining.

### Sync — how is concurrent access controlled?

| Capability | Mechanism | Cost | Use when |
|---|---|---|---|
| *(none)* | Affine ownership (single owner) | Zero | Default. One fiber owns the data. |
| `@local` | Bare heap pointer (`*T`) | ~1ns (pointer deref) | Multiple fibers, same scheduler. No lock needed. |
| `@locked` | Mutex (`*Locked(T)`) | ~20ns (acquire/release) | Cross-scheduler mutable access. |
| `@writeLocked` | RwLock (`*RwLocked(T)`) | ~20ns write, ~5ns read | Cross-scheduler, read-heavy workloads. |

### Ownership — who keeps the data alive?

| Capability | Mechanism | Cost | Use when |
|---|---|---|---|
| *(none)* | Affine (single owner, move semantics) | Zero | Default. Data lives in one scope. |
| `@multiowned` | Rc (non-atomic refcount) | ~2ns (inc/dec) | Multiple owners, same scheduler. Graphs, trees. |
| `@shared` | Arc (atomic refcount) | ~5-20ns (atomic CAS) | Multiple owners across schedulers. |

### Layout — where does the data physically live?

| Capability | Mechanism | Cost | Use when |
|---|---|---|---|
| *(none)* | Stack or frame (compiler decides) | Zero | Default. Small values. |
| `@indirect` | Heap pointer (`*T`) | ~1ns (pointer deref) | Stable address needed (graph edges, self-referential structs). |

### Combining dimensions

```clear
-- ILLUSTRATIVE
config = AppConfig{ port: 8080 } @shared:locked;     -- Arc<Mutex<T>>
node   = TreeNode{ left: NIL }   @multiowned;         -- Rc<T>
cache  = LargeStruct{ data: [] } @local:indirect;     -- *T (both intents expressed)
counter = Counter{ value: 0 }    @local;              -- *T (zero-cost sharing)
```

Invalid same-dimension combinations are compile errors:
```clear
-- ILLUSTRATIVE
x = Foo{} @locked:writeLocked;    -- ERROR: duplicate sync
x = Foo{} @shared:multiowned;     -- ERROR: duplicate ownership
```

## Why This Design Matters

### 1. Functions are reusable across concurrency strategies

In Rust, if you write `fn process(data: &Counter)`, it can't accept `Arc<Mutex<Counter>>` without unwrapping at every call site — and the unwrapping pattern differs for `Mutex` vs `RwLock` vs `RefCell`. In Go, there's no type-level distinction at all; you hope the caller remembered to lock.

In CLEAR, `FN process(c: Counter)` works for all capability variants. The caller handles unwrapping. The function is concurrency-agnostic.

### 2. Cost is visible where decisions are made

The capability annotation appears once — at the declaration:

```clear
counter = Counter{ value: 0 } @shared:locked;
```

This single line tells you the full cost model: atomic refcount + mutex. Every subsequent use of `counter` pays this cost, but you don't see the cost annotation repeated at each use site. The cost signal is at the **decision point**, not scattered across the codebase.

Compare to Rust where `Arc::clone(&counter)` and `counter.lock().unwrap()` appear at every use, mixing concurrency plumbing with business logic.

### 3. Refactoring is a one-line change

When profiling reveals that `@shared:locked` is too expensive (atomic refcount + mutex on every access), the fix is one line:

```diff
- counter = Counter{ value: 0 } @shared:locked;
+ counter = Counter{ value: 0 } @local;
```

No function signatures change. No call sites change. No WITH blocks need rewriting (the compiler removes them). The entire concurrency strategy shifts from "cross-scheduler mutex" to "zero-cost single-scheduler" with a single edit.

This makes **Profile-Guided Optimization** practical:
1. Profile shows `@shared:locked` counter is hot (20ns × 10M ops = 200ms)
2. Check: is it actually accessed cross-scheduler? (Usually no.)
3. Change to `@local` → 1ns × 10M ops = 10ms. **20× speedup, one line.**

### 4. The compiler enforces safety automatically

When you change `@shared:locked` to `@local`, the compiler:
- Auto-pins all BG/DO blocks that capture it (stays on one scheduler)
- Errors if any `@parallel` block tries to capture it
- Removes the mutex/arc overhead from generated code

You can't accidentally create a data race by downgrading a capability. The type system catches it at compile time.

### 5. Complexity lives in the struct definition, not the function

In traditional languages, concurrency concerns "infect" function signatures:

```rust
// Rust: every function in the chain must know about Arc<Mutex<T>>
fn process(data: Arc<Mutex<AppState>>) { ... }
fn helper(data: Arc<Mutex<AppState>>) { ... }
fn inner(data: Arc<Mutex<AppState>>) { ... }
```

In CLEAR:
```clear
-- ILLUSTRATIVE
FN process(state: AppState) RETURNS Void -> helper(state); END
FN helper(state: AppState) RETURNS Void -> inner(state); END
FN inner(state: AppState) RETURNS Void -> ... END
```

The concurrency strategy is decided once, at the point where `AppState` is created. Functions downstream are clean — they just take `AppState`.

## Quick Decision Guide

```
Is the data shared across fibers?
├── No  → default (no capability)
└── Yes
    ├── Mutable?
    │   ├── Same scheduler → @local (zero cost, auto-pinned)
    │   └── Cross-scheduler → @locked or @writeLocked
    └── Multiple owners?
        ├── Same scheduler → @multiowned (Rc)
        └── Cross-scheduler → @shared (Arc)

Stable heap address needed (graphs)?
└── @indirect (combinable with any of the above)
```

## Why Capabilities Can't "Leak" Through Structs

A natural concern: what if a `@local` struct contains a field that points to `@shared` data? Could capturing the `@local` outer struct in a `@parallel` block silently expose the inner `@shared` pointer to cross-scheduler access?

**This can't happen.** Capabilities exist on *bindings*, not on *struct field definitions*. Struct fields are always plain Types:

```clear
STRUCT Node {
    value: Int64,
    left: Node,          -- plain Type, no capability
    right: Node,         -- plain Type, no capability
}
```

You cannot write:

```clear
STRUCT Node {
    value: Int64,
    left: Node @shared,      -- NOT valid CLEAR syntax
    cache: Counter @local,   -- NOT valid CLEAR syntax
}
```

Capabilities are applied at the **declaration site**, when a value is bound to a variable:

```clear
-- ILLUSTRATIVE
root = Node{ value: 1, left: NIL, right: NIL } @local;
```

This means a struct's field types are always capability-free. When the compiler checks whether a BG block captures `@local` or `@shared` state, it only needs to check the **top-level binding** — there's no capability nesting to recurse into.

The separation is enforced at two levels:

1. **Parser**: The type annotation grammar (`field: Type`) does not accept capability suffixes on struct field definitions. `STRUCT Foo { x: Counter @locked }` is a parse error.

2. **Functions**: Functions take plain Types (`FN process(c: Counter)`), not capabilities. A function can't receive or return a capability-wrapped value — it always works with the unwrapped inner type.

This is a deliberate design constraint. Capabilities describe how a *binding* is accessed, not what a *type* contains. The cost and safety of a capability is always visible at the single line where the binding is declared — never hidden inside a type definition.
