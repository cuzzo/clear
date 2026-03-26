# Allocation

Allocation is the single largest hidden cost in most programs.

A typical web server handling 10K requests/second makes millions of allocations per second — each one touching a global lock, a free list, or a system call.  This inherently does not scale.

The difference between a well-tuned allocator and a naive one is often 2-10x total throughput.

CLEAR eliminates most allocation overhead by default. It gives you State-of-the-Art allocation strategies, without you needing to think about allocation at all.

The compiler analyzes every variable and assigns it to the cheapest allocator that's safe for its lifetime. The programmer never chooses an allocator — they write normal code and the compiler does the right thing.

## The Three Tiers

Every variable in CLEAR lives in one of three places:

| Tier | Cost | Lifetime | Lock? | What lives here |
|---|---|---|---|---|
| **Stack** | 0 ns | Function scope | No | Small values (≤ 1KB): numbers, bools, small structs |
| **Frame Arena** | ~2 ns (bump) | Function scope | No | Large values (> 1KB): big structs, temporary buffers |
| **Heap** | ~60 ns (GPA) | Unbounded | Yes* | Dynamic collections, cross-fiber data, Rc/Arc |

*Heap is lock-free for `@pinned` fibers (uses thread-local arena).

### Stack — Zero Cost

Primitives and small structs are placed directly on the fiber's stack. No allocation call, no cleanup — the stack pointer moves on function entry and rewinds on exit.

```clear
x = 42.0;                              -- stack: 8 bytes (f64)
point = Point{ x: 1.0, y: 2.0 };      -- stack: 16 bytes (2 × f64)
```

The compiler uses a **128-slot threshold** (~1KB on 64-bit): structs with ≤ 128 fields stay on the stack. Larger structs automatically move to the frame arena to prevent stack overflow on small fiber stacks.

### Frame Arena — Near Zero Cost

The frame arena is a bump allocator that lives for the duration of a function call. Every function that needs it saves a mark on entry and rewinds on exit — all allocations between those two points are freed in one O(1) pointer reset.

```clear
-- ILLUSTRATIVE
FN process() RETURNS Result ->
    -- These allocations use the frame arena (~2ns each):
    big_matrix = Matrix{ ... };          -- 16KB struct → frame arena
    temp_list: String[] = split(data);   -- dynamic array → frame arena

    RETURN transform(big_matrix);
    -- On return: frame mark rewinds. big_matrix and temp_list are gone.
END
```

**How the arena grows:**

```
First allocation:   4 KB block  (pre-allocated on the fiber stack)
Second overflow:    4 KB block  (heap-allocated)
Third overflow:    16 KB block
Fourth overflow:   64 KB block
Fifth+ overflow:  256 KB block  (max page size)
```

Blocks are cached — the arena reuses them across function calls without re-allocating. Rewind just resets a cursor; the blocks stay resident.

**Cost breakdown:**
- Allocation: align pointer + bump cursor = ~2ns
- Deallocation: reset cursor to saved mark = O(1), regardless of how many allocations were made
- No free-list, no coalescing, no fragmentation
- Returned frame structs are copied by value — Zig's optimizer applies Return Value Optimization (RVO) to eliminate the copy when possible

### Heap — The Escape Hatch

Data that outlives its creating function (returned collections, cross-fiber communication, Rc/Arc wrappers) goes on the heap via the global allocator (GPA). This is the slowest path — ~60ns per allocation, with a global lock.

```clear
-- ILLUSTRATIVE
MUTABLE users = List[];      -- heap: dynamic list (growable)
counts: HashMap<Int64> = {};         -- heap: hash map
shared_ref = counter @shared;       -- heap: Arc-wrapped
```

The compiler only uses the heap when it must. The vast majority of variables stay on the stack or frame arena.

## How the Compiler Decides

The annotator walks the AST and assigns storage based on type properties:

```
Is it a primitive (Float64, Int64, Bool, Byte)?
  → stack (always, no exceptions)

Is it a dynamic collection (@list, @pool, HashMap)?
  → heap (growable, unknown lifetime)

Is it Rc (@multiowned) or Arc (@shared)?
  → heap (reference-counted, shared ownership)

Is it a struct or fixed array?
  How many slots?
    ≤ 128 slots (~1KB) → stack
    > 128 slots        → frame arena

Is it returned from a function?
  The return value is copied by value (stack structs)
  or promoted to heap (lists, maps)
```

String literals are compile-time constants in read-only memory — zero allocation. `@indirect` forces heap allocation for recursive types (e.g., tree nodes with self-referential pointers).

This happens at compile time. The emitted Zig code uses the correct allocator with zero runtime decision-making.

## @arena Mode — Fiber-Lifetime Allocation

For request/response workloads (web servers, KV stores), most allocations live only for the duration of one request. The `@arena` modifier tells the runtime to skip per-function rewind — the entire frame arena lives for the fiber's lifetime and is freed in one reset when the fiber completes.

```clear
-- ILLUSTRATIVE
BG { @arena ->
    request = parse(conn);       -- arena allocation (no per-function rewind)
    data = lookup(request.key);  -- arena allocation
    response = format(data);     -- arena allocation
    send(conn, response);
    -- Fiber exits: ONE arena reset frees everything. O(1).
}
```

Without `@arena`, each function (parse, lookup, format) saves and restores its own frame mark — correct but wastes time rewinding between calls when the data flows linearly through the pipeline.

With `@arena`, `restoreFrameMark` becomes a no-op. All allocations accumulate in the arena. When the fiber completes, the scheduler resets the arena once. This is the same strategy as Go's per-goroutine heap and Rust's `bumpalo` — but automatic, not opt-in.

`@arena` implies `@pinned` because the arena memory is thread-local.

## @pinned — Shared-Nothing Allocation

CLEAR is designed for shared-nothing architecture by default. `@pinned` fibers use a **thread-local arena** instead of the global GPA — zero locks, zero contention, zero cache-line bouncing. Since `@pinned` is the default for fibers that capture local state (the compiler auto-pins them), most server workloads never touch the GPA at all.

```clear
-- ILLUSTRATIVE
BG { @pinned ->
    -- Every heap allocation goes through the scheduler's local arena.
    -- No GPA lock, no atomic ops, no cache-line bouncing.
    data = fetch_from_db(query);
    result = transform(data);
}
```

With `@pinned`, each thread's fibers use their own arena — allocation scales linearly with core count. This is the default path for request handlers, background tasks, and any fiber that captures local state.

## Stack Pool — Fiber Stack Reuse

Fiber stacks are managed by a two-level cache:

| Level | Location | Latency | Capacity |
|---|---|---|---|
| **L1** | Per-scheduler LIFO cache | ~5ns (array pop) | 16 Standard stacks |
| **L2** | Global slab allocator | ~50ns (slab alloc) | Thousands per size class |

When a fiber completes, its stack goes back to the L1 cache. When a new fiber spawns with the same size class, it pops from L1 — no system call, no slab lookup.

Stack sizes are fixed at spawn time:

| Size | Bytes | Use case |
|---|---|---|
| Micro | 4 KB | Tiny tasks, channel relays |
| Standard | 16 KB | Default — most tasks |
| Large | 64 KB | Deep recursion, large locals |
| XL | 256 KB | Extreme stack usage |

The control plane's OnOverflow policy auto-upsizes tasks that overflow. The control plane's OnUnderflow policy auto-downsizes tasks that consistently use less than half their allocation. The programmer never manually tunes stack sizes.

## Why This Matters

### The Typical Program

Most programs allocate in the hot path without thinking about it. A JSON parser creates strings, arrays, and maps on every request. A game loop creates temporary vectors and matrices every frame. A data pipeline creates intermediate results at every stage.

In languages with garbage collection (Go, Java, Python), these allocations are fast (~10ns) but accumulate GC pressure. The GC pause — when it finally runs — can be 1-50ms, causing latency spikes.

In languages with manual allocation (C, C++, Rust), the programmer must choose the allocator and lifetime explicitly. This is fast and predictable but error-prone and verbose.

### CLEAR's Approach

CLEAR gets both: fast allocation (~2ns arena bump) with automatic lifetime management (mark/rewind at function boundaries). No GC pauses, no manual lifetime annotations, no `defer free()`.

The frame arena handles 90%+ of allocations in a typical program. The heap is only used for data that must outlive its creating function — and for `@pinned` fibers, even the heap is lock-free.

### Cost Comparison

| Allocator | Cost | Lock | Fragmentation | Used by |
|---|---|---|---|---|
| CLEAR frame arena | ~2 ns | None | None (bump) | Most CLEAR allocations |
| CLEAR heap (GPA) | ~60 ns | Global | Some | Dynamic collections |
| CLEAR @pinned heap | ~2 ns | None | None (arena) | Pinned fiber heap allocs |
| Go GC heap | ~10 ns + GC pause | None (GC) | Managed | All Go allocations |
| Rust Box/Vec | ~30 ns | Global (jemalloc) | Some | Explicit heap allocations |
| C malloc | ~50 ns | Global | Fragmentation | All dynamic allocations |

CLEAR's frame arena is 5-25x faster than conventional allocators for temporary data, with zero fragmentation and O(1) bulk cleanup. For the remaining heap allocations, `@pinned` eliminates lock contention — matching arena speed for thread-local workloads.
