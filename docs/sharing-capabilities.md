# Sharing Capabilities: @local, @multiowned, @shared

CLEAR separates **what data is** (Types) from **how it's accessed** (Capabilities). This guide covers the three reference-counting / sharing capabilities and when to use each.

## The Problem

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

```clear
MUTABLE c = Counter{ value: 0 } @local;

BG { c.value = c.value + 1; }   -- direct field access, no WITH block
BG { print(c.value); }          -- direct read
```

**What it does**: Heap-allocates the value and returns a bare `*T` pointer. No Mutex, no RwLock, no reference counting. Multiple fibers share the pointer by value copy.

**Why it's safe**: The compiler auto-pins all BG/DO blocks that capture `@local` variables to the local scheduler. Cooperative scheduling on a single OS thread means no two fibers ever execute simultaneously — no data races are possible.

**When to use it**: This is the **default choice** for shared mutable state within a function scope. It's the fastest option — zero synchronization overhead.

**Compile-time enforcement**:
```clear
BG { @parallel -> c.value = 1; }
-- ERROR: @local variable cannot be used in @parallel block
```

## @multiowned — Non-Atomic Reference Counting (Rc)

```clear
node = TreeNode{ left: NIL, right: NIL } @multiowned;

-- Multiple owners via WITH block:
WITH node AS val { print(val.left); }
```

**What it does**: Wraps the value in `Rc(T)` — a non-atomic reference-counted pointer. Each `WITH` unwrap increments the refcount; scope exit decrements it. The value is freed when the last reference is released.

**Why it exists**: For **graph structures** and **shared ownership** patterns where multiple variables need to keep the same value alive. Unlike `@local` (which has one owner and shared pointers), `@multiowned` has multiple owners with automatic lifetime management.

**Why it's NOT thread-safe**: `Rc` uses a plain integer for its refcount — no atomic CAS, no memory barriers. If two threads increment/decrement simultaneously, the count corrupts (use-after-free or double-free).

**Compile-time enforcement**:
```clear
BG { @parallel -> WITH node AS val { ... } }
-- ERROR: @multiowned (Rc) variable cannot be used in @parallel block —
-- Rc uses a non-atomic reference count. Use @shared (Arc) for cross-scheduler sharing.
```

**When to use it**: Graphs, trees, and shared ownership patterns where all fibers run on the same scheduler. If you need cross-scheduler sharing, use `@shared` instead.

## @shared — Atomic Reference Counting (Arc)

```clear
config = AppConfig{ port: 8080 } @shared;

BG { @parallel -> WITH config AS c { print(c.port); } }  -- OK
BG { @parallel -> WITH config AS c { print(c.port); } }  -- OK
```

**What it does**: Wraps the value in `Arc(T)` — an atomic reference-counted pointer. The refcount uses hardware atomic instructions (lock-prefixed CAS on x86), so it's safe to increment/decrement from any thread.

**Why it's expensive**: Every clone/drop of an `Arc` bounces the cache line containing the refcount between CPU cores. On a 16-core machine, this "cache-line bouncing" can cost ~100ns per operation (vs ~1ns for a non-atomic increment).

**When to use it**: Only when you **genuinely need** cross-scheduler sharing — data accessed by fibers on different OS threads. This is rare in practice: most shared state is within a single function scope (use `@local`) or within a single scheduler (use `@multiowned`).

## Combining with Sync Capabilities

Sharing capabilities can be combined with sync capabilities for mutable cross-thread access:

```clear
-- Arc + Mutex: cross-scheduler mutable access
counter = Counter{ value: 0 } @shared:locked;
BG { @parallel -> WITH EXCLUSIVE counter AS c { c.value = c.value + 1; } }

-- Arc + RwLock: cross-scheduler read-heavy access
config = Config{ port: 8080 } @shared:writeLocked;
BG { @parallel -> WITH config AS c { print(c.port); } }            -- read lock
BG { @parallel -> WITH EXCLUSIVE config AS c { c.port = 9090; } }  -- write lock
```

`@local` does not combine with `@locked` or `@writeLocked` — it's already a bare pointer with no wrapper. Mutation is direct.

## Decision Tree

```
Do multiple fibers need to access this data?
├── No → plain value (default, stack-allocated)
└── Yes
    ├── Do multiple fibers need to OWN it (keep it alive)?
    │   ├── No → @local (shared pointer, single owner)
    │   └── Yes
    │       ├── Same scheduler? → @multiowned (Rc, fast)
    │       └── Cross-scheduler? → @shared (Arc, thread-safe)
    └── Does it need mutable access?
        ├── @local: direct field write (c.value = 1)
        ├── @multiowned: WITH block (read-only unwrap)
        ├── @locked: WITH EXCLUSIVE (Mutex guard)
        └── @writeLocked: WITH / WITH EXCLUSIVE (RwLock)
```

## Auto-Pinning

The compiler automatically pins BG/DO blocks to the local scheduler when they capture `@local`, `@multiowned`, `@shared`, `@locked`, or `@writeLocked` variables. This is a **cache-line bouncing optimization** for thread-safe types and a **safety requirement** for non-thread-safe types.

To override auto-pinning for thread-safe types:
```clear
BG { @parallel -> ... }   -- distribute across schedulers
```

For non-thread-safe types (`@local`, `@multiowned`), `@parallel` is a compile error.
