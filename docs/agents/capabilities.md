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
a = Counter{ value: 0 };
b = Counter{ value: 0 } @local;    -- pinned to core
c = Counter{ value: 0 } @locked;
d = Counter{ value: 0 } @shared;

increment(a);                                   -- stack object
increment(b);                                   -- direct deref
WITH EXCLUSIVE c AS inner { increment(inner) }  -- mutex guard
WITH d AS val { increment(val) }                -- arc unwrap
```

One function definition. Four concurrency strategies. Zero code changes to `increment`.

For one-line field mutations on `@locked`/`@writeLocked` variables, the compiler auto-wraps the statement in an inline mutex guard — no `WITH` block needed:

```clear
-- ILLUSTRATIVE
MUTABLE b = Counter{ value: 0 } @locked;
b.value += 1;  -- compiler auto-acquires and releases the mutex
```

## The Capability Dimensions

CLEAR has three orthogonal capability dimensions. They can be combined in any order via `:` chaining.

### Sync — how is concurrent access controlled?

| Capability | Mechanism | Cost | Use when |
|---|---|---|---|
| *(none)* | Affine ownership (single owner) | Zero | Default. One fiber owns the data. |
| `@alwaysMutable` | RefCell (`*RefCell(T)`) | ~1ns (pointer deref) | Interior mutability. Mutate through const bindings. |
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
config = AppConfig{ port: 8080 } @shared:locked;      -- Arc<Mutex<T>>
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

## Interior Mutability (@alwaysMutable)

`@alwaysMutable` is CLEAR's equivalent of Rust's `RefCell<T>`. It allows field mutation through const bindings - the binding itself doesn't change, but the data it points to can be modified.

```clear
STRUCT Config { theme: String, retries: Int64 }

-- const binding, mutable data
cfg = Config{ theme: "dark", retries: 3 } @alwaysMutable;

-- borrow, write, release (compiler auto-generates)
cfg.theme = "light";
cfg.retries = 5;

-- borrow, read, release, COPY
y = cfg.retries;
```

For scoped access (multiple mutations without repeated borrow/release):

```clear
-- ILLUSTRATIVE
WITH cfg AS c {
    c.theme = "light";
    c.retries = 10;
    update!(c);
}
```

| Rust | CLEAR |
|---|---|
| `RefCell<T>` | `T @alwaysMutable` |
| `Rc<RefCell<T>>` | `T @multiowned:alwaysMutable` |
| `Arc<Mutex<T>>` | `T @shared:locked` |

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

## Internal vs. External Capabilities

In CLEAR, capabilities can be applied in two places: at the Binding Level (variable declaration) and at the Struct Level (field definition). This allows you to define the "architectural physics" of a data structure once, rather than repeating it at every call site.

### 1. Struct-Level (Architectural Strategy)
When a capability is part of a STRUCT definition, it defines the inherent memory and concurrency strategy for that data type. This is ideal for recursive structures like Graphs or Trees where a node must be reference-counted to exist.

```ruby clear
STRUCT Node {
    id: Int64,
    parent: ?Node@link,        -- Weak reference (WeakRc/WeakArc)
    left: ?Node@multiowned,    -- Strong reference (Rc)
    right: ?Node@multiowned
}
```

* Reasoning: You define the "source of truth" for the data's architecture. If a Node must be shared, you bake that into the definition so the compiler can enforce it everywhere.

### 2. Binding-Level (Access Strategy)
When a capability is applied to a variable, it defines how the current fiber interacts with that instance.

```
-- A "plain" struct wrapped in a Mutex at the point of use
MUTABLE settings = AppSettings{...} @shared:locked;
```

### The "Unwrapping" Hierarchy

CLEAR maintains "Zero Blast Radius" refactoring by automatically unwrapping internal capabilities when a field is accessed or passed to a function.

 * Field Access: When you call myWrapper.inner, the compiler automatically handles the Rc dereference or Arc load.
 * Function Calls: Functions still take Types, not Capabilities.

```ruby clear illustrative
FN process(n: Node) -> ...

-- Works regardless of whether 'inner' is @multiowned, @shared, or affine.
w = Wrapper{ inner: Node{...} @multiowned };
process(w.inner);
```

### Risks and Technical Implications

While field-level capabilities are more expressive, they introduce specific architectural risks that the developer (and compiler) must manage:

 * Recursive Poisoning: If a STRUCT contains even one non-thread-safe field (like @multiowned or @local), the entire struct is considered "poisoned."
    * It cannot be captured in a @parallel block or moved across schedulers, even
    * if the top-level binding looks "plain."
        * Compiler Requirement: The annotator must recursively audit all struct fields during fiber capture analysis.
 * Hidden "Move" Costs: Moving a "plain-looking" struct by value may no longer be a zero-cost operation.
    * If the struct contains reference-counted fields, a move (or a COPY) will trigger internal retain/release logic (via CheatLib.releaseFields).
 * Refactoring Friction: While internal capabilities centralize logic, they "color" the struct.
    * Changing a field from @multiowned to @shared is a one-line change in the STRUCT, but it may cause compile errors in remote parts of the app that were capturing that struct in @parallel blocks (which were valid for @shared but invalid for @multiowned).
