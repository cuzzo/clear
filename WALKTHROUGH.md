# CLEAR Language Reference Guide

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
10. [Streams and Pipelines](#streams-and-pipelines)
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
- Explicit scopes for mutation and borrowing.

---

## Basic Syntax

### Comments
```
-- Single line comment
```

### Keywords
- `VAR` - Immutable binding
- `MUTABLE` - Mutable binding
- `SET` - Assignment to mutable variable
- `FN` - Function definition
- `RETURN` - Return from function
- `IF/THEN/ELSE/END` - Conditionals
- `WHILE/DO/END;FOR/DO/END;BREAK/CONTINUE` - Loops
- `STRUCT` - Struct definition
- `WITH` - Capability scoping block

---

## Variables and Mutability

### Immutable Variables (Default)
```
VAR x = 5;                    -- Immutable binding
VAR name = "Alice";           -- Immutable string
VAR pi = 3.14159;             -- Immutable float

SET x = 6;                    -- COMPILER ERROR: x is immutable
```

### Mutable Variables (Explicit)
```
MUTABLE counter = 0;          -- Mutable binding
SET counter = 1;              -- OK: can reassign
```

---

## Types vs Capabilities

CLEAR distinguishes between what data *is* (Type) and how it is *accessed* (Capability). In Rust, capabilities like `Arc`, `Rc`, and `Mutex` are often conflated with types, leading to "function coloring" and high refactoring costs. In CLEAR, functions take **Types**, not **Capabilities**.

### The CLEAR Model

* **Ownership:** Rc = `multiowned`, Arc = `shared`
* **Synchronization:** Mvcc = `shared:read`, RwLock = `shared:writeLocked`, Mutex = `shared:locked`
* **Interior Mutability:** Cell, RefCell -> combined = `alwaysMutable`
  * Automatically acts like Cell for data under 16 bytes
  * `alwaysMutable` must be unwrapped before individually passing into a function as an argument, like any other capability
* **Existence:** Option, Result => not a capability -> a tense:
  * `T?` = Optional T
  * Unwrapped like in Rust and Zig with `.?`

### Synchronization (Sub-capabilities of `shared`)

When an object is `shared` across threads, you choose a synchronization strategy:

- `shared:read`: Optimized for read-heavy MVCC.
- `shared:atomic`: Optimized for lock-free primitive updates (e.g., counters).
- `shared:writeLocked`: Equivalent to `Arc<RwLock<T>>`.
- `shared:locked`: Equivalent to `Arc<Mutex<T>>`.

```CLEAR
VAR u = User.new();                     -- affine User (default)
VAR s = SHARE(User.new());              -- shared User (thread-safe)
VAR sa = SHARE:atomic(0);               -- shared:atomic Integer
VAR sw = SHARE:writeLocked(User.new()); -- shared:writeLocked User
```

### Why This is Superior: Zero Blast Radius Refactoring

In Rust, if you need to change a `Rc<User>` to an `Arc<User>` (e.g., to pass it to another thread), you must:
1. Find every function signature taking `Rc<User>`.
2. Rewrite them to `Arc<User>`.
3. Update every call site.

In CLEAR, capabilities are acquired and discharged at the edges. Functions simply ask for a `User`.

```CLEAR
-- Function doesn't care about the capability
FN process(u: User) ->
  PRINT(u.name);
END

-- At the call site, you unwrap/sync the capability
VAR sharedU = SHARE(User.new());
process(sharedU); -- CLEAR automatically handles the "unwrapping" for the call
```

If you change `sharedU` from `multiowned` to `shared`, the `process` function remains untouched. The refactor is a one-line change at the definition.

### Interior Mutability & Scoping

For objects with the `alwaysMutable` capability (like `RefCell` in Rust), CLEAR provides elegant syntax to avoid manual `borrow_mut()` calls.

```CLEAR
-- 99% case: One-liners "just work"
-- Compiler handles the temporary lock/borrow
user.login_count += 1;

-- 1% case: Complex multi-field updates
WITH user.config {
  -- 'this' (_) is now the mutable inner content
  _.theme = "Light";
  _.retries = 5;
  _.last_updated = now();
} -- Lock is released here
```

This makes code-smell easy to detect. If you see `shared:locked` or `alwaysMutable` being passed around excessively, it's a sign that you should be unwrapping at the call site instead.

---

## Functions

### Definition
```
FN add(a, b) ->
  RETURN a + b;
END
```

### UpValues (Closures)
Functions must explicitly declare captured variables:
```
VAR x = 5;
FN readOnly() USE(x) ->
  PRINT(x);
END
```

### Mutation Suffix `!`
Functions that mutate their parameters use the `!` suffix:
```
FN increment!(MUTABLE counter) ->
  SET counter = counter + 1;
END
```

---

## Collections

### Arrays
In CLEAR, arrays are optimized automatically. You do not need a sigil to distinguish between stack and heap; the compiler handles it.

```
-- Fixed-size immutable array
VAR coords = [1, 2, 3];

-- Dynamic mutable array
MUTABLE items = [1, 2, 3];
items.push!(4);               -- OK
```

### Structs
```
STRUCT Point {
  x: Float64,
  y: Float64
}

-- Recursive structures use 'indirect'
STRUCT Node {
  value: Int64,
  left: indirect Node,
  right: indirect Node
}
```

---

## Lifetimes and Scoping

In Rust, lifetimes are globally tracked and can create "hidden poison" in mutable inputs. In CLEAR, lifetimes are **strictly local** to the function they occur in.

### 1. The Local-Only Rule

Lifetimes in CLEAR:
- Cannot cross thread boundaries.
- Cannot be passed into async functions or callbacks.
- Only exist within the scope of the calling function.

This eliminates "spooky action at a distance" where an async task holds onto a borrow, preventing you from mutating it later.

### 2. No Poison for Immutable Objects

In Rust, even a read-only borrow of an immutable object can prevent mutation later (if the input was mutable). In CLEAR, >90% of objects are immutable and thus **never** require lifetime tracking.

### 3. Explicit Path-Based Scoping

In Rust, a lifetime annotation like `'a` is often opaque. In CLEAR, you explicitly link a returned reference to its source path.

```CLEAR
-- CLEAR: Path is explicitly linked to the source field
FN grandChild(n: Node) -> n.child::Node
  RETURN n.child.child;
END

-- Rust (for comparison): Opaque lifetime symbol 'a
-- fn grandChild<'a>(&'a n: Node) -> &'a Node { ... }
```

### 4. `WITH RESTRICT` for Mutable Scopes

If you borrow from a mutable object, it becomes "poisoned" (restricted). This is explicitly scoped using `WITH RESTRICT`.

```CLEAR
MUTABLE node = buildTree();

WITH RESTRICT node.child {
  -- 'node.child' is now immutable (restricted) inside this block.
  VAR gc = node.grandChild();

  -- node.child.name = "New Name"; -- COMPILER ERROR: node.child is restricted
}

-- 'node.child' is mutable again here.
```

### 5. `GIVE` and `TAKES` (Ownership)

CLEAR uses affine types by default. Passing an object to a function "borrows" it unless the function explicitly `TAKES` it.

```CLEAR
FN saveUser(TAKES u: User) ->
  -- This function now owns 'u'
END

VAR u = User.new();
saveUser(GIVE u);             -- Explicitly move ownership
-- u is now dead here
```

---


## Error Handling

### The `OR` Operator
CLEAR handles errors via control flow, keeping the "Happy Path" clear.

```
VAR val = fetchData() OR RAISE;
VAR name = getName() OR "Guest";
```

### The `!!` Operator
Used for explicit panics:
```
VAR item = list.get(idx)!!;   -- Panic if out of bounds
```

---

## Concurrency

### `SPAWN` and `PARALLEL`
CLEAR achieves parallelism via isolated processes.

```
PARALLEL FOR item IN data ->
  process(item);
END
```

For shared state, use the `shared` capability or `shared:atomic`:
```
VAR counter = SHARE:atomic(0);  -- Atomic shared across threads
counter.increment!();
```

---

## Streams and Pipelines

### SMOOTH Operator `s>`
The `s>` operator is a "Safe, Smooth, Smart" pipe that manages unwrapping and error bubbling.

```
VAR result = data
  s> filter(%(x) -> x > 5)
  s> map(%(x) -> x * 2)
  s> sum();
```

---

## Memory Model

### Arena Allocation
Every function has its own memory arena. Variables live as long as the function they were born in.

### Escaping the Arena
- `RETURN`: Values are moved or copied to the caller's arena.
- `GIVE`: Ownership is transferred.
- `shared` / `multiowned`: Reference-counted objects that live as long as they are needed.

---

## Quick Reference: Capabilities

| Keyword | Purpose |
|---------|---------|
| `multiowned` | Single-threaded shared ownership (Rc) |
| `shared` | Multi-threaded shared ownership (Arc) |
| `alwaysMutable` | Interior Mutability (Cell/RefCell) |
| `read` | Syncronization without blocking (MVCC) |
| `locked` | Syncronization *ALWAYS* blocking (Mutex) |
| `writeLocked` | Syncronization blocking only to write (RwLock) |
| `indirect` | Explicit heap allocation (Box) |
| `Linear` | Must be consumed (Linear types) |

## Quick Reference: Sigils

| Sigil | Meaning | Example |
|-------|---------|---------|
| `&` | Borrow memory | `&data[1..10]` |
| `@` | Pipeline binding | `s> process AS @p` |
| `!` | Mutation suffix | `list.push!(item)` |
| `?` | Predicate suffix | `list.exists?(item)` |
| `!!` | Panic on error | `data.get(i)!!` |
| `_` | Placeholder | `s> SELECT _.name` |
