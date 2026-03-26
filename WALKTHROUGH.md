# CLEAR Language Walkthrough

A memory-safe language with Rust-level guarantees but substantially simpler syntax, optimized for local reasoning and architectural flexibility.

## Table of Contents

1. [Core Philosophy](#core-philosophy)
2. [Basic Syntax](#basic-syntax)
3. [Variables and Mutability](#variables-and-mutability)
4. [Types vs Capabilities](#types-vs-capabilities)
5. [Functions](#functions)
6. [Collections](#collections)
7. [Lifetimes and Scoping](#lifetimes-and-scoping)
8. [Error Handling](#error-handling)
9. [Concurrency](#concurrency)
10. [Pipelines](#pipelines)
11. [Memory Model](#memory-model)

---

## Core Philosophy

**Safety First, Speed Second**
- Immutable by default
- Explicit mutation with `MUTABLE` keyword
- No null pointer errors
- No data races
- Arena-based memory management (no garbage collection)

**Capabilities over Magic Types**
- Separate what an object *is* (Type) from how it is *accessed* (Capability).
- Functions take Types, not Capabilities, to minimize refactoring cost.
- Explicit scopes for mutation and sharing.

---

## Basic Syntax

### Comments
```
-- Single line comment
```

### Keywords
- `MUTABLE` - Mutable binding (immutable binding uses no keyword)
- `FN` - Function definition
- `RETURN` - Return from function
- `IF/THEN/ELSE/END` - Conditionals
- `WHILE/DO/END` - Loops
- `BREAK/CONTINUE` - Loop control
- `STRUCT` - Struct definition
- `ENUM` - Enum definition
- `UNION` - Tagged union definition
- `MATCH/START/DEFAULT/END` - Pattern matching
- `WITH` - Capability scoping block
- `BG` - Background fiber spawn
- `DO` - Fork-join parallel execution
- `CONCURRENT` - Parallel pipeline operator

---

## Variables and Mutability

### Immutable Variables (Default)
```clear
x = 5;                        -- Immutable binding (no keyword)
name = "Alice";               -- Immutable string
pi = 3.14159;                 -- Immutable float

x = 6;                        -- COMPILER ERROR: x is immutable
```

### Mutable Variables (Explicit)
```clear
MUTABLE counter = 0;          -- Mutable binding
counter = 1;                  -- OK: can reassign
```

---

## Types vs Capabilities

CLEAR distinguishes between what data *is* (Type) and how it is *accessed* (Capability). In Rust, capabilities like `Arc`, `Rc`, and `Mutex` are part of the type, leading to "function coloring" and high refactoring costs. In CLEAR, functions take **Types**, not **Capabilities**.

### Capability Annotations

Capabilities are applied at the **declaration site** with `@` suffixes:

| Capability | Rust Equivalent | CLEAR Syntax |
|---|---|---|
| Single-threaded shared ownership | `Rc<T>` | `value @multiowned` |
| Multi-threaded shared ownership | `Arc<T>` | `value @shared` |
| Mutex (exclusive lock) | `Arc<Mutex<T>>` | `value @shared:locked` |
| RwLock (read-write lock) | `Arc<RwLock<T>>` | `value @shared:writeLocked` |
| Heap pointer | `Box<T>` | `value @indirect` |
| Thread-local pointer | *(no direct equivalent)* | `value @local` |

### Zero Blast Radius Refactoring

In Rust, changing `Rc<User>` to `Arc<User>` means rewriting every function signature in the call chain. In CLEAR, functions take the plain type:

```clear
-- ILLUSTRATIVE
-- Function doesn't care about the capability
FN process(u: User) RETURNS Void ->
  print(u.name);
  RETURN;
END

-- At the call site, capabilities are unwrapped:
shared_u = User{ name: "Alice" } @shared;
WITH shared_u AS val { process(val); }
```

If you change `@shared` to `@multiowned`, the `process` function remains untouched. The refactor is a one-line change at the declaration.

### WITH Blocks for Capability Unwrapping

Capabilities are unwrapped at the call site using `WITH` blocks:

```clear
-- ILLUSTRATIVE
-- @locked requires EXCLUSIVE access (mutex)
counter = Counter{ value: 0 } @shared:locked;
WITH EXCLUSIVE counter AS c { c.value = c.value + 1; }

-- @shared requires WITH to unwrap the Arc
config = Config{ port: 8080 } @shared;
WITH config AS c { print(c.port); }
```

---

## Functions

### Definition
```clear
FN add(a: Int64, b: Int64) RETURNS Int64 ->
  RETURN a + b;
END
```

### Mutation Suffix `!`
Functions that take MUTABLE parameters must use the `!` suffix:
```clear
-- ILLUSTRATIVE
FN increment!(MUTABLE counter: Counter) RETURNS Void ->
  counter.value = counter.value + 1;
  RETURN;
END
```

### Ownership Transfer: `TAKES` and `GIVE`
CLEAR uses affine types by default — each value has one owner. To transfer ownership into a function, the parameter is marked `TAKES` and the caller uses `GIVE`:

```clear
-- ILLUSTRATIVE
FN consume(TAKES u: User) RETURNS Void ->
  -- This function now owns 'u'
  print(u.name);
  RETURN;
END

u = User{ name: "Alice" };
consume(GIVE u);              -- Ownership transferred
-- u is no longer usable here
```

Note: `GIVE` is required at the call site to make ownership transfer visible to the reader.

### Recursion
Recursive functions must be explicitly annotated:
```clear
FN fib(n: Int64) RETURNS Int64 @reentrant ->
  IF n <= 1 THEN RETURN n; END
  RETURN fib(n - 1) + fib(n - 2);
END
```

---

## Collections

### Arrays (Fixed-Size)
```clear
MUTABLE scores: Int64[5] = [10, 20, 30, 40, 50];
x = scores[2];               -- 30
scores[0] = 99;              -- Mutation via index
```

### Lists (Dynamic)
```clear
MUTABLE items = List[];
append(items, "Alice");
append(items, "Bob");
```

### Pools (Generational Handles)
```clear
-- ILLUSTRATIVE
MUTABLE pool: Entity[]@pool = [];
id = pool.insert(Entity{ x: 0.0, y: 0.0 });
entity = pool.get(id);       -- O(1) lookup, generation-checked
```

### Structs
```clear
STRUCT Point {
  x: Float64,
  y: Float64
}

-- Recursive structures use @indirect
STRUCT Node {
  value: Int64,
  left: Node @indirect,
  right: Node @indirect
}
```

---

## Lifetimes and Scoping

In Rust, lifetimes are globally tracked and can create "hidden poison" in mutable inputs. In CLEAR, lifetimes are **strictly local** to the function they occur in.

### The Local-Only Rule

Lifetimes in CLEAR:
- Cannot cross fiber boundaries.
- Cannot be passed into async functions or callbacks.
- Only exist within the scope of the calling function.

This eliminates "spooky action at a distance" where an async task holds onto a borrow, preventing mutation later.

### No Poison for Immutable Objects

In Rust, even a read-only borrow of an immutable object can prevent mutation later. In CLEAR, >90% of objects are immutable and thus **never** require lifetime tracking.

### `WITH RESTRICT` for Mutable Scopes

If you borrow from a mutable object, it becomes "poisoned" (restricted). This is explicitly scoped using `WITH RESTRICT`.

```clear
-- ILLUSTRATIVE
MUTABLE node = buildTree();

WITH RESTRICT node.child {
  -- 'node.child' is now immutable (restricted) inside this block.
  gc = node.grandChild();

  -- node.child.name = "New Name"; -- COMPILER ERROR: node.child is restricted
}

-- 'node.child' is mutable again here.
```

---

## Error Handling

### Automatic Error Propagation
The compiler automatically propagates errors for you. If you call a function that can fail and don't handle the error, the compiler inserts error propagation:

```clear
-- ILLUSTRATIVE
FN compute(x: Float64) RETURNS !Float64 ->
    half = divide(x, 2.0);      -- auto-propagates if divide fails
    RETURN half * 2.0;
END
```

### The `OR` Operator
When you want to *handle* an error instead of propagating:

```clear
-- ILLUSTRATIVE
val = divide(10.0, 0.0) OR 0.0;   -- Fallback value
name = getName() OR RAISE;         -- Explicit propagation
result = risky() OR PASS;          -- Silence (use with caution)
```

### Error Unions (`!T`)
Functions that can fail declare it in their return type:

```clear
-- ILLUSTRATIVE
FN divide(a: Float64, b: Float64) RETURNS !Float64 ->
    IF b == 0.0 THEN
        RAISE "Division by zero";
    END
    RETURN a / b;
END
```

---

## Concurrency

### BG — Background Fibers
Spawn a fiber that runs concurrently:

```clear
-- ILLUSTRATIVE
p = BG { expensive_computation(data); };
-- ... do other work ...
result = NEXT p;  -- Block until the fiber finishes
```

Modifiers control stack size and scheduling:

| Modifier | Effect |
|---|---|
| `@micro` | 4 KB stack |
| `@standard` | 16 KB stack (default) |
| `@large` | 64 KB stack |
| `@xl` | 256 KB stack |
| `@pinned` | Pin to local scheduler (no work stealing) |
| `@arena` | Thread-local arena allocation; implies @pinned |

### DO — Fork-Join

```clear
-- ILLUSTRATIVE
DO {
    update_database(record),
    send_notification(user),
    log_event(event)
}
-- All three are done here.
```

### CONCURRENT — Parallel Pipelines

```clear
-- ILLUSTRATIVE
results = items s> CONCURRENT(workers: 8) SELECT transform(_);
filtered = items s> CONCURRENT(workers: 4) WHERE predicate(_);
items s> CONCURRENT(workers: 2) EACH { _.value = 0.0; };
```

### Shared State
For cross-fiber shared state, use capabilities:

```clear
-- ILLUSTRATIVE
counter = Counter{ value: 0 } @shared:locked;

BG { WITH EXCLUSIVE counter AS c { c.value = c.value + 1; } };
BG { WITH EXCLUSIVE counter AS c { c.value = c.value + 1; } };
```

---

## Pipelines

### The Smooth Operator `s>`
The `s>` operator pipes values through higher-order functions and collection operators:

```clear
-- ILLUSTRATIVE
-- Filter, aggregate
alive = entities s> WHERE _.health > 0;
total = scores s> SUM _.value;
names = users s> SELECT _.name;

-- In-place mutation
entities s> EACH { _.x = _.x + _.vx; };
```

### Pipeline Operators

| Category | Operators |
|---|---|
| **Transform** | `SELECT`, `WHERE`, `ORDER_BY`, `LIMIT`, `DISTINCT`, `UNNEST`, `INDEX` |
| **Aggregate** | `SUM`, `AVERAGE`, `MIN`, `MAX`, `REDUCE`, `COUNT`, `ANY`, `ALL`, `FIND` |
| **Side Effects** | `EACH` |

### Function Piping
`s>` also pipes to functions:

```clear
-- ILLUSTRATIVE
result = data s> process s> validate s> format;
```

---

## Memory Model

### Arena Allocation
Every function has its own memory arena. Variables live as long as the function they were born in.

- **Stack** (~0ns): Primitives and small structs (≤ 128 slots)
- **Frame Arena** (~2ns): Large structs, temporary buffers
- **Heap** (~60ns): Dynamic collections, cross-fiber data, Rc/Arc

### Escaping the Arena
- `RETURN`: Values are copied by value to the caller's arena (RVO eliminates the copy when possible).
- `GIVE`: Ownership is transferred.
- `@shared` / `@multiowned`: Reference-counted objects that live as long as they are needed.

---

## Quick Reference: Capabilities

| Annotation | Purpose |
|---|---|
| `@multiowned` | Single-threaded shared ownership (Rc) |
| `@shared` | Multi-threaded shared ownership (Arc) |
| `@shared:locked` | Arc + Mutex |
| `@shared:writeLocked` | Arc + RwLock |
| `@locked` | Mutex (single-scheduler) |
| `@writeLocked` | RwLock (single-scheduler) |
| `@local` | Thread-local heap pointer |
| `@indirect` | Explicit heap allocation (Box) |

## Quick Reference: Sigils

| Sigil | Meaning | Example |
|---|---|---|
| `@` | Capability / pipeline binding | `value @shared`, `s> process AS @p` |
| `!` | Mutation suffix | `FN increment!(...)` |
| `s>` | Smooth operator (pipeline) | `items s> WHERE _ > 5` |
| `_` | Pipeline element placeholder | `s> SELECT _.name` |
| `!T` | Error union type | `RETURNS !Float64` |
| `?T` | Optional type | `RETURNS ?User` |
| `~T` | Promise / stream type | `p: ~Int64 = BG { 42; }` |
