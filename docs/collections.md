# CLEAR Collections: Array, List, Pool

CLEAR has three collection types, each designed for a different access pattern. The choice is a capability annotation — the element type and functions that operate on it stay the same regardless of which collection you use.

## Quick Reference

| Collection | Zig Type | Access | Growth | Safety | Use when |
|---|---|---|---|---|---|
| `T[N]` | `[N]T` | Index O(1) | Fixed | Bounds-checked | Size known at compile time |
| `T[]@list` | `ArrayListUnmanaged(T)` | Index O(1), append O(1)* | Dynamic | Bounds-checked | Size unknown, sequential access |
| `T[N]@pool` | `Pool(T)` | Handle O(1) | Fixed | **Generational handles** | Frequent insert/remove, stable references |

\* Amortized O(1) — occasional reallocation when capacity is exceeded.

## Arrays — `T[N]`

Fixed-size, stack-allocated. The size is part of the type.

```clear
MUTABLE scores: Int64[5] = [10, 20, 30, 40, 50];
x = scores[2];          -- 30
scores[0] = 99;         -- mutation via index
ASSERT x == 30, "index access";
ASSERT scores[0] == 99, "mutation via index";
```

**When to use**: Size is known at compile time. No insertions or removals. The fastest option — no heap allocation, no bounds-growth overhead.

**Limitations**: Cannot append, remove, or resize. Index out of bounds is a runtime panic.

## Lists — `@list`

Dynamic-size, heap-allocated. Backed by `std.ArrayListUnmanaged(T)`.

```clear
MUTABLE users = List[];
users.append("Alice");
users.append("Bob");
n = users.length();       -- 2
name = users[0];           -- "Alice"
```

**When to use**: Size is unknown or grows over time. Elements accessed by index. The general-purpose dynamic array — equivalent to `Vec<T>` in Rust or `[]T` in Go.

**Limitations**: Removing from the middle is O(N) (shift elements). Handles/pointers to elements are invalidated on reallocation. Not suitable for frequent insert/remove of interior elements.

**Variant — sharded list**: `T[]@list:sharded(N)` splits the list into N shards for parallel pipeline operations (`|> EACH`, `|> SUM`). Each shard is an independent list. Round-robin distribution on append.

**Lazy inference**: `List[]` creates an untyped list. The element type is inferred from the first `append`:

```clear
MUTABLE items = List[];
items.append(42.0);  -- type inferred as Float64[]@list
```

## Pools — `@pool`

Handle-based, pre-allocated with fixed capacity. Backed by `Pool(T)` with **generational handles** for ABA safety. The capacity is specified at declaration time and all slots are allocated up front — no dynamic resizing, no reallocation. Insert and remove are O(1) via an internal free stack.

```clear
STRUCT Enemy { hp: Int64, name: String }

MUTABLE enemies: Enemy[1000]@pool = [];
id1: Id<Enemy> = enemies.insert(Enemy{ hp: 100, name: "Goblin" });
id2: Id<Enemy> = enemies.insert(Enemy{ hp: 200, name: "Dragon" });

-- Access via handle — returns ?T (optional). Must use OR to unwrap:
goblin = enemies.get(id1) OR Enemy{ hp: 0, name: "none" };

-- Or via [] syntax (equivalent to .get):
dragon = enemies[id2] OR Enemy{ hp: 0, name: "none" };

-- Remove: slot is freed, generation increments
enemies.remove(id1);

-- Stale handle returns null — OR provides a safe fallback:
gone = enemies.get(id1) OR Enemy{ hp: 0, name: "removed" };
```

**Important: every pool access returns `?T` (optional).** Like `@writeLocked`, using a pool is not a one-line optimization — it changes how you access data. Every `pool.get(id)` or `pool[id]` requires `OR default` to handle the case where the handle is stale or the slot was removed. This is by design: the pool guarantees you never read invalid data, but you must handle the "not found" case explicitly.

### How Generational Handles Work

Each pool slot stores a generation counter alongside the data:

```
Slot: { generation: u32, alive: bool, value: T }
Handle (Id<T>): u64 = [generation: upper 32 bits][index: lower 32 bits]
```

When you `insert`, the handle encodes the current generation and slot index. When you `remove`, the slot's generation increments. When you `get` with a stale handle, the generation in the handle doesn't match the slot's generation — the pool returns null instead of the wrong data.

This prevents the classic **use-after-free** / **type confusion** bug:

```
1. Insert User at slot 0, generation 0 → handle = 0x00000000_00000000
2. Remove User → slot 0 generation becomes 1
3. Insert Projectile at slot 0, generation 1 → handle = 0x00000001_00000000
4. Try to read old User handle (gen 0) → GENERATION MISMATCH → null
```

No garbage collector. No reference counting. Just a 4-byte integer comparison per access.

### When to use pools

- **Game entities** (ECS): enemies, projectiles, particles — frequently spawned and destroyed
- **Connection pools**: TCP clients, database handles — allocated and returned
- **Object caches**: LRU-style caches where entries are evicted and reused
- **Any workload with frequent insert/remove** where index-based access would leave holes

### Pools vs Lists

| Operation | List `T[]@list` | Pool `T[N]@pool` |
|---|---|---|
| Append/Insert | O(1) amortized | O(1) via free stack |
| Access | `list[i]` → `T` (direct) | `pool[id]` → `?T` (requires `OR`) |
| Remove from middle | O(N) shift | O(1) mark-dead |
| Stable references | No (realloc invalidates) | Yes (handles survive realloc) |
| Capacity | Dynamic (grows on demand) | Fixed (pre-allocated at declaration) |
| Memory after remove | Compacted | Holes (reused on next insert via free stack) |
| Safety after remove | Index may now point to different element | Handle returns null (generational) |
| Ergonomic cost | Direct access — no unwrapping | Every access needs `OR` fallback |

## Decision Tree

```
Is the size fixed at compile time?
├── Yes → T[N] (array)
└── No
    ├── Access pattern?
    │   ├── Sequential / index-based → T[]@list (list)
    │   └── Handle-based / frequent insert+remove → T[N]@pool (pool)
    └── Need stable references across insert/remove?
        ├── Yes → T[N]@pool (generational handles survive mutations)
        └── No → T[]@list (simpler, more cache-friendly for iteration)
```

Note: pools require a compile-time capacity `N`. All slots are pre-allocated up front, giving O(1) insert/remove via an internal free stack with no runtime reallocation. Choose a capacity that covers your expected maximum — the pool will panic if you exceed it.

## Hash Maps — `HashMap<V>` and `HashMap<K, V>`

Key-value maps. String-keyed by default, numeric-keyed with explicit `HashMap<K, V>`.

```clear
MUTABLE scores: HashMap<Int64> = {};     -- String → Int64
scores["alice"] = 100_i64;
scores["bob"] = 200_i64;
val = scores["alice"];                    -- 100
scores.delete("bob");
scores.contains?("alice");                 -- TRUE
scores.count();                           -- 1
```

**When to use**: Lookup by key. The general-purpose associative container.

## SOA Layout — Cache-Optimal Iteration

By default, collections store elements as **Array of Structures** (AOS): each element is a contiguous block of all its fields. When a pipeline accesses only a subset of fields, the CPU loads entire cache lines but uses only a fraction — wasting memory bandwidth.

The `:soa` capability switches to **Structure of Arrays** layout: each field gets its own contiguous array. A pipeline that touches one field iterates a dense, cache-friendly slice.

```clear
STRUCT Entity { x: Float64, y: Float64, vx: Float64, vy: Float64, health: Float64, mana: Float64, name: String, level: Float64 }

-- AOS (default): each entity is 8 fields × 8 bytes = 64 bytes per cache line.
-- SUM _.health loads all 8 fields but uses only 1 — 87.5% wasted bandwidth.
MUTABLE pool: Entity[10000]@pool = [];

-- SOA: health values are stored in a contiguous f64 array.
-- SUM _.health touches only that array — zero waste.
MUTABLE pool: Entity[10000]@pool:soa = [];
```

The compiler detects when SOA would help and suggests it:

```
NOTE: Pipeline accesses 1 of 8 fields (health). Consider @soa
      for better cache performance on 'Entity'.
```

**When `:soa` helps most:**
- Pipelines that touch < 50% of fields (SUM, MIN, MAX, AVERAGE on one field)
- Large structs (8+ fields)
- High-volume iteration (thousands of elements)

**When `:soa` doesn't help:**
- Small structs (< 4 fields) — cache lines already fit the whole struct
- EACH that reads/writes most fields — no bandwidth savings
- Random-access by handle (`pool.get(id)`) — must reassemble the struct

**How it works under the hood:**

All pipeline operators (SUM, MIN, MAX, AVERAGE, COUNT, ANY, ALL, WHERE, FIND, SELECT) automatically use field-slice iteration on `:soa` pools. The compiler rewrites `_.health` to `data.items(.health)[i]` — a direct index into the contiguous field array. No materialization, no struct reassembly for the common case.

For operators that produce struct output (WHERE, FIND), structs are reassembled only for matching elements — the predicate still uses field-slice access, so most iterations touch only the predicate field.

`:soa` works on both `@pool` and `@list`:

```clear
MUTABLE pool: Entity[10000]@pool:soa = [];   -- SOA pool (generational handles)
MUTABLE items: Entity[]@list:soa = [];  -- SOA list (dense, indexed)
```

Same API as their non-SOA counterparts. The difference is invisible except in pipeline performance.

**FFI restriction:** `@soa` collections cannot be passed to `EXTERN FN` — SOA memory layout is incompatible with the C ABI. Materialize to a regular collection first if you need FFI.

## Sharding — True Shared-Nothing Parallel Collections

Lists, pools, and hash maps all support sharding for parallel access:

```clear
MUTABLE data: Float64[]@list:sharded(4) = [];
MUTABLE entities: Enemy[10000]@pool:sharded(4) = [];
MUTABLE counts: HashMap<Int64>@sharded(4) = {};
```

Sharding splits the collection into N independent partitions. Each shard is a complete, independent data structure — no shared state, no locks, no atomic operations between shards.

**How it works:**
- **Lists**: Round-robin distribution on `append`. `length()` sums across shards.
- **Pools**: Round-robin distribution on `insert`. Handle encodes shard index in upper bits.
- **Hash maps**: Key-based routing via `hash(key) % N`. Same key always maps to same shard.

**Pipeline operations** (`|> EACH`, `|> SUM`, `|> WHERE`, etc.) process each shard in parallel via DO blocks — one fiber per shard, no contention between them.

### The DragonflyDB Model — Each Thread Owns Its Partition

`@sharded(N)` uses the same architecture as DragonflyDB: each scheduler thread owns a subset of shards, and fibers pinned to that scheduler access those shards with zero locks, zero atomics, and zero synchronization.

**Shard ownership**: Shard `i` is owned by scheduler `i % S` (where S = number of schedulers). With 8 shards and 2 schedulers, each scheduler owns 4 shards.

**Hot path** (shard owned by the current scheduler): Direct access. No locks, no atomics. Cooperative scheduling ensures only one fiber runs at a time per scheduler, so there's no data race.

**Cold path** (shard owned by another scheduler): The operation is transparently routed to the owning scheduler via SPSC ring buffers. The calling fiber yields until the owning scheduler executes the operation inline and signals completion via an atomic done flag. Correct, but slower — design your workload so each fiber processes ONLY its own partition.

### `SHARD` Pipeline — True Shared-Nothing Workloads

The `SHARD` pipeline operator partitions work so each fiber owns its shard exclusively:

```clear
MUTABLE map: HashMap<String>@sharded(8) = {};
n = 1000000;

-- SHARD routes each key to the scheduler that owns its shard.
-- CONCURRENT EACH runs one fiber per shard — zero locks, zero routing.
(0..<n) |> SHARD("key:${toString(_)}", map) |> CONCURRENT EACH {
    map[_] = "value";
};
```

**How it works**:
1. SHARD hashes each key, appends it to the owning shard's queue
2. One fiber per shard is pinned to the owning scheduler
3. Each fiber processes only its own queue — no cross-shard access, no locks
4. The result is true DragonflyDB-style shared-nothing: N partitions, N fibers, zero synchronization

**When to use `@sharded(N)` vs `@sharded(N):locked`**:
- `@sharded(N)` + `CONCURRENT EACH`: each fiber owns its partition. Maximum throughput.
- `@sharded(N):locked`: any fiber can access any key. RwLock per shard. Use when the workload can't be partitioned (e.g., random key distribution across all fibers).

### One-Line Optimization

`@sharded(N)` is a one-line declaration change. Functions don't need to know — a function that takes `HashMap<String>` seamlessly accepts `HashMap<String>@sharded(8)`:

```clear
-- One-line change: add @sharded(8) to the declaration
MUTABLE map: HashMap<String>@sharded(8) = {};

-- Functions: no @sharded needed in parameter types
FN doWork!(MUTABLE map: HashMap<String>, key: String) RETURNS !Void ->
    map[key] = "value";
END

-- BG blocks: auto-pinned when they capture a @sharded map
BG { doWork!(map, "hello"); }
-- [Note] BG block auto-pinned — captures shared/locked resource.
```

The compiler handles everything:
- **Unified API**: All HashMap variants (plain, `@sharded`, `@sharded:locked`) have the same `.put()`/`.get()` interface. Functions use Zig `anytype` generics to accept any variant.
- **Auto-pinning**: BG blocks that capture a `@sharded` map are automatically pinned to a scheduler. No `@pinned` annotation needed.
- **Fiber distribution**: Pinned BG fibers are distributed round-robin across schedulers via `spawnPinned()`, so each scheduler gets work.

### Sharding Variants

| Variant | Model | Locking | Use when |
|---|---|---|---|
| `@sharded(N)` | Shared-nothing | None (fiber-pinned) | Partitioned workloads (CONCURRENT EACH) |
| `@sharded(N):locked` | RwLock per shard | Per-shard RwLock | Cross-shard access from any fiber |
| `@sharded(N):writeLocked` | RwLock per shard | Per-shard RwLock | Same as :locked (alias) |

### When You Need Shared Mutable Maps

For rare cases where multiple schedulers must read/write the same keys concurrently (e.g., a global session registry), use `@shared:writeLocked`:

```clear
MUTABLE sessions: HashMap<Session> @shared:writeLocked = {};
-- Arc<RwLock<HashMap>>: readers are parallel, writers are serialized
```

This is CLEAR's escape hatch — it works like Java's `ConcurrentHashMap` but with explicit intent. The capability annotation makes the cost visible at the declaration site, and the compiler's capability audit will tell you if you're paying for it unnecessarily.

## Hashing — Secure by Default

CLEAR uses **seeded Wyhash** as the default hash function for all hash maps. The seed is randomized per process, which prevents Hash DoS attacks (where an attacker crafts keys that all collide, turning O(1) lookups into O(n) traversals).

This follows CLEAR's "Correct > Scalable > Fast" ordering: the default is safe against adversarial input, with near-zero overhead compared to unsalted hashes.

### Future: `@fastTrusted` Capability

For performance-critical internal infrastructure where keys are not attacker-controlled (e.g., internal service meshes, compiler symbol tables, game engine registries), CLEAR plans to offer an opt-in unsalted hash:

```
-- Planned syntax (not yet implemented):
MUTABLE symbols: HashMap<SymbolInfo>@fastTrusted = {};
MUTABLE fast_sharded: HashMap<Int64>@sharded(8):fastTrusted = {};
```

`@fastTrusted` would switch to unsalted FNV-1a or raw Wyhash — faster, but vulnerable to Hash DoS if keys come from untrusted input. The name is deliberate: it forces the developer to declare "I trust this data source."

**Why not yet**: The default seeded Wyhash is fast enough for v1 (within ~5% of unsalted FNV). The capability will be added when real-world profiling shows the hash function is the bottleneck, not before. Premature escape hatches encourage premature optimization.
