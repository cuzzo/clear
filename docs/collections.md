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

## Sharding

Both lists and pools support sharding for parallel pipeline operations:

```clear
MUTABLE data: Number[]@list:sharded(4) = [];
MUTABLE entities: Enemy[]@pool:sharded(4) = [];
```

Sharding splits the collection into N independent partitions. Pipeline operations (`s> EACH`, `s> SUM`, `s> WHERE`, etc.) process each shard in parallel via DO blocks — one fiber per shard, no contention between them.
