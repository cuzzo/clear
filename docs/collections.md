# CLEAR Collections: Array, List, Pool

CLEAR has three collection types, each designed for a different access pattern. The choice is a capability annotation — the element type and functions that operate on it stay the same regardless of which collection you use.

## Quick Reference

| Collection | Zig Type | Access | Growth | Safety | Use when |
|---|---|---|---|---|---|
| `T[N]` | `[N]T` | Index O(1) | Fixed | Bounds-checked | Size known at compile time |
| `T[]@list` | `ArrayListUnmanaged(T)` | Index O(1), append O(1)* | Dynamic | Bounds-checked | Size unknown, sequential access |
| `T[]@pool` | `Pool(T)` | Handle O(1) | Dynamic | **Generational handles** | Frequent insert/remove, stable references |

\* Amortized O(1) — occasional reallocation when capacity is exceeded.

## Arrays — `T[N]`

Fixed-size, stack-allocated. The size is part of the type.

```clear
scores: Int64[5] = [10, 20, 30, 40, 50];
x = scores[2];          -- 30
scores[0] = 99;         -- mutation via index
```

**When to use**: Size is known at compile time. No insertions or removals. The fastest option — no heap allocation, no bounds-growth overhead.

**Limitations**: Cannot append, remove, or resize. Index out of bounds is a runtime panic.

## Lists — `T[]@list`

Dynamic-size, heap-allocated. Backed by `std.ArrayListUnmanaged(T)`.

```clear
MUTABLE users: String[]@list = [];
append(users, "Alice");
append(users, "Bob");
n = length(users);       -- 2
name = users[0];          -- "Alice"
```

**When to use**: Size is unknown or grows over time. Elements accessed by index. The general-purpose dynamic array — equivalent to `Vec<T>` in Rust or `[]T` in Go.

**Limitations**: Removing from the middle is O(N) (shift elements). Handles/pointers to elements are invalidated on reallocation. Not suitable for frequent insert/remove of interior elements.

**Variant — sharded list**: `T[]@list:sharded(N)` splits the list into N shards for parallel pipeline operations (`s> EACH`, `s> SUM`). Each shard is an independent `ArrayListUnmanaged(T)`. Round-robin distribution on append.

## Pools — `T[]@pool`

Handle-based, heap-allocated. Backed by `Pool(T)` with **generational handles** for ABA safety.

```clear
STRUCT Enemy { hp: Int64, name: String }

MUTABLE enemies: Enemy[]@pool = [];
id1: Id<Enemy> = enemies.insert(Enemy{ hp: 100, name: "Goblin" });
id2: Id<Enemy> = enemies.insert(Enemy{ hp: 200, name: "Dragon" });

-- Access via handle (O(1), generation-checked):
goblin = enemies.get(id1);

-- Remove: slot is freed, generation increments
enemies.remove(id1);

-- Stale handle returns null (not a crash, not type confusion):
enemies.get(id1);    -- null (generation mismatch)
```

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

| Operation | List `T[]@list` | Pool `T[]@pool` |
|---|---|---|
| Append | O(1) amortized | O(1) or O(N) scan for free slot |
| Access by position | `list[i]` — O(1) | Not supported (use handles) |
| Access by handle | Not supported | `pool.get(id)` — O(1) |
| Remove from middle | O(N) shift | O(1) mark-dead |
| Stable references | No (realloc invalidates) | Yes (handles survive realloc) |
| Memory after remove | Compacted | Holes (reused on next insert) |
| Safety after remove | Index may now point to different element | Handle returns null (generational) |

## Decision Tree

```
Is the size fixed at compile time?
├── Yes → T[N] (array)
└── No
    ├── Access pattern?
    │   ├── Sequential / index-based → T[]@list (list)
    │   └── Handle-based / frequent insert+remove → T[]@pool (pool)
    └── Need stable references across insert/remove?
        ├── Yes → T[]@pool (generational handles survive mutations)
        └── No → T[]@list (simpler, more cache-friendly for iteration)
```

## Hash Maps — `HashMap<V>` and `HashMap<K, V>`

Key-value maps. String-keyed by default, numeric-keyed with explicit `HashMap<K, V>`.

```clear
MUTABLE scores: HashMap<Int64> = {};     -- String → Int64
scores["alice"] = 100_i64;
scores["bob"] = 200_i64;
val = scores["alice"];                    -- 100
scores.delete("bob");
scores.contains("alice");                 -- TRUE
scores.count();                           -- 1
```

**When to use**: Lookup by key. The general-purpose associative container.

## Sharding — Lock-Free Parallel Collections

Lists, pools, and hash maps all support sharding for parallel access:

```clear
MUTABLE data: Number[]@list:sharded(4) = [];
MUTABLE entities: Enemy[]@pool:sharded(4) = [];
MUTABLE counts: HashMap<Int64>:sharded(4) = {};
```

Sharding splits the collection into N independent partitions. Each shard is a complete, independent data structure — no shared state, no locks, no atomic operations between shards.

**How it works:**
- **Lists**: Round-robin distribution on `append`. `length()` sums across shards.
- **Pools**: Round-robin distribution on `insert`. Handle encodes shard index in upper bits.
- **Hash maps**: Key-based routing via `hash(key) % N`. Same key always maps to same shard.

**Pipeline operations** (`s> EACH`, `s> SUM`, `s> WHERE`, etc.) process each shard in parallel via DO blocks — one fiber per shard, no contention between them.

### Why Not a ThreadSafeHashMap?

A `ThreadSafeHashMap` (like Java's `ConcurrentHashMap`) uses internal lock striping — N segments, each with its own lock. Every operation pays lock/unlock overhead (~20ns).

CLEAR's `HashMap:sharded(N)` achieves the same result with **zero synchronization overhead**:

| Approach | Per-operation cost | Contention under load |
|---|---|---|
| `ConcurrentHashMap` (lock striping) | ~20ns (lock/unlock per op) | Degrades with more threads per stripe |
| `HashMap:sharded(N)` (CLEAR) | ~0ns (no lock, direct hash table access) | Zero (each shard owned by one scheduler) |

The key insight: CLEAR's scheduler pins fibers to shards. No two fibers ever access the same shard simultaneously, so no synchronization is needed. The sharding IS the thread safety.

### Key Skew and Why It's Not Your Problem

A common concern with sharding: what if one key is much hotter than others? If `hash("alice") % 4 == 0` and "alice" is 90% of your traffic, doesn't Shard 0 get overwhelmed?

**In CLEAR's default mode (single scheduler), this doesn't matter.** All shards run on one thread sequentially. A "hot shard" just means more time is spent on that shard's data — the same as a non-sharded map. There's no idle-core waste because there's only one core.

**In multi-scheduler mode (`CLEAR_THREADS=N`), the fix is one line:**

```diff
- MUTABLE counts: HashMap<Int64>:sharded(4) = {};
+ MUTABLE counts: HashMap<Int64>:sharded(64) = {};
```

With 64 shards, the probability that two hot keys collide in the same shard drops from 25% to 1.5%. CLEAR's work-stealing scheduler balances fiber load across cores — if one shard's fibers are busy, idle cores steal other fibers to stay productive.

No rearchitecture. No actor patterns. No map-reduce rewrites. Change one number.

### When You Need Shared Mutable Maps

For rare cases where multiple schedulers must read/write the same keys concurrently (e.g., a global session registry), use `@shared:writeLocked`:

```clear
MUTABLE sessions: HashMap<Session> @shared:writeLocked = {};
-- Arc<RwLock<HashMap>>: readers are parallel, writers are serialized
```

This is CLEAR's escape hatch — it works like Java's `ConcurrentHashMap` but with explicit intent. The capability annotation makes the cost visible at the declaration site, and the compiler's capability audit will tell you if you're paying for it unnecessarily.
