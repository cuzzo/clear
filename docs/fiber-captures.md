# Fiber Capture Semantics

When a BG or DO block references a variable from its enclosing scope, the compiler **captures** that variable into the fiber's context. How the capture works depends on the variable's type and the block type.

## BG Blocks — Asynchronous Ownership Transfer

BG fibers run asynchronously on their own stack with their own frame arena. The parent scope may continue executing (and rewinding its frame) while the fiber is still running. This means **frame-allocated data cannot be shared by reference** — it must be promoted to the heap or passed by pointer.

### Capture Rules by Type

| Type | Capture mode | What happens | Parent after capture |
|---|---|---|---|
| **Primitives** (Int64, Float64, Bool) | Copy | 8-byte value copied into fiber context | Still usable |
| **Strings** ([]const u8) | Move + promote | String bytes duped to heap; fiber owns the copy | **Moved** — cannot use |
| **Collections** (@list, @map) | Move + promote | Backing data promoted to heap via `promoteList`/`mapPromote` | **Moved** — cannot use |
| **Resources** (File, TCPClient, TCPServer) | Move | File descriptor transferred to fiber | **Moved** — cannot use |
| **Shared maps** (@sharded, :locked) | Pointer | Passed by `*T`; shared mutable access | Still usable (shared) |
| **Pools** (@pool) | Pointer | Passed by `*T`; shared mutable access | Still usable (shared) |
| **Structs** (small, stack) | Copy | Struct value copied into fiber context | Still usable |

### Why Strings and Collections Are Moved

Strings and collections in CLEAR are frame-allocated by default. A string like `fullPath = path + "/" + name` allocates its bytes in the function's frame arena. When the function's frame mark is restored (on return or frame rewind), that memory is invalidated.

A BG fiber runs on a separate timeline — the parent may restore its frame while the fiber is still reading the captured string. To prevent use-after-free, the compiler:

1. **Promotes** the data to the heap before spawning the fiber
2. **Moves** the variable in the parent scope (use-after-capture is a compile error)
3. The fiber **owns** the promoted data and frees it when done

This uses the same escape promotion system as function returns — `needs_escape_promotion?` identifies frame-backed types, and `escape_promote_code` generates the promotion.

```clear
-- ILLUSTRATIVE
fullPath = path + "/" + name;
p = BG { scanDir(fullPath); };   -- fullPath is promoted to heap, moved
-- fullPath is no longer usable here
```

If you need the value in both the parent and the fiber, use explicit COPY:

```clear
-- ILLUSTRATIVE (not yet implemented)
fullPath = path + "/" + name;
p = BG { scanDir(COPY fullPath); };  -- explicit copy; parent keeps original
print(fullPath);                      -- still valid
```

### Why Shared Collections Use Pointers

Collections with `@sharded` or `:locked` capabilities are already heap-allocated and thread-safe. They're captured by pointer (`*T`) because:

- Their backing data is on the heap (no frame escape issue)
- Multiple fibers need shared mutable access
- The parent retains ownership; fibers borrow

```clear
-- ILLUSTRATIVE
MUTABLE store: HashMap<String>@sharded(8):locked = {};
BG { store["key"] = "value"; };  -- store captured by pointer; parent still owns it
```

### Resource Ownership Transfer

Resources (files, sockets) are affine — they can only have one owner. When captured by a BG fiber, ownership transfers to the fiber. The parent's `defer close()` is suppressed by setting a `_moved` flag:

```clear
-- ILLUSTRATIVE
client = accept(server);
BG { handleClient!(client); };  -- client ownership transferred to fiber
-- client is moved; parent's defer close will NOT fire
```

## DO Blocks — Synchronous Shared Access

DO blocks are fork-join: all branches run concurrently, but the DO block **waits for all branches before continuing**. The parent's frame is still valid while branches execute.

### Capture Rules

| Type | Capture mode | Why |
|---|---|---|
| **All types** | `*const T` (read-only pointer) | Frame data valid; no escape needed |

DO branches capture everything by `*const` pointer. This is safe because:

1. The parent's frame mark is NOT restored until after `wg.wait()` completes
2. All branches finish before the parent continues
3. No frame-allocated data escapes its scope

```clear
-- ILLUSTRATIVE
DO {
    process_a(data),    -- data captured by *const pointer
    process_b(data)     -- same pointer; both branches read the same data
}
-- data is still valid here
```

### DO Does Not Move

Unlike BG, DO blocks do not move captured variables. The parent retains full ownership because the synchronous wait guarantees frame validity.

## Escape Promotion System

BG captures reuse the same escape promotion infrastructure as function returns:

### Type Predicate: `needs_escape_promotion?`

Returns true for any type whose backing data is frame-allocated:
- `@list` — ArrayList backing buffer is frame-allocated
- Non-numeric `HashMap` — keys and bucket array are frame-allocated
- `String` — `[]const u8` bytes point into the frame arena

Returns false for:
- `@sharded` maps (always heap-backed)
- Numeric maps (keys are integers, no string copies)
- Primitives, structs (stack-allocated, safe to copy)

### Promotion Code: `escape_promote_code`

| Type | Promotion | Effect |
|---|---|---|
| `@list` | `promoteList(T, rt, &list)` | Copies backing buffer from frame to heap (in-place) |
| `HashMap<V>` | `mapPromote(V, heapAlloc, &map)` | Clones buckets + re-dupes keys to heap (in-place) |
| `String` | `alloc.dupe(u8, str)` | Allocates new heap buffer, copies bytes (new binding) |

### How It Flows

```
Annotator:
  _bg_walk() → marks frame-backed captures as :moved (uses needs_escape_promotion?)

Transpiler:
  emit_capture_escape_promotions() → generates promotion code per captured variable
  - Strings: new binding (const __bgp_name = try alloc.dupe(u8, name))
  - Collections: in-place (try promoteList(...) / try mapPromote(...))

  BG context init references promoted bindings for strings, originals for collections
  Fiber body has defer-free for promoted strings
```

## Stack Size Considerations

Each BG fiber gets its own stack, which includes a 4KB frame arena carved from the bottom. For functions that do heavy frame allocation (string operations, `listAll`, `readFile`), the default 16KB stack may not suffice.

| Stack size | Total | Frame arena | Use case |
|---|---|---|---|
| `@micro` | 4 KB | 4 KB | Trivial computation, no frame ops |
| `@standard` | 16 KB | 4 KB | Light work, few allocations |
| `@large` | 64 KB | 4 KB | String-heavy, recursive functions |
| `@xl` | 256 KB | 4 KB | Deep recursion, large buffers |

```clear
-- ILLUSTRATIVE
BG { @large -> scanDir(path); }
```

## Safety Guarantees

The compiler enforces these at compile time:

| Rule | Error |
|---|---|
| Use moved variable after BG capture | "variable was moved" |
| `@local` in `@parallel` BG | "@local requires single-scheduler affinity" |
| `@multiowned` (Rc) in `@parallel` BG | "Rc is non-atomic; use @shared (Arc)" |
| `@arena` + `@parallel` | "Arena memory is thread-local" |
| Nested BG from `@pinned` scope without `@pinned` | "Thread-local memory would escape" |

## Summary

| | BG (async) | DO (sync) |
|---|---|---|
| **Execution** | Asynchronous, own stack | Fork-join, waits for all |
| **Frame safety** | Must promote frame data | Frame valid during execution |
| **Primitives** | Copy (value) | Pointer (*const T) |
| **Strings** | Move + heap promote | Pointer (*const T) |
| **Collections** | Move + heap promote | Pointer (*const T) |
| **Resources** | Move (ownership transfer) | Pointer (*const T) |
| **Shared state** | Pointer (*T) | Pointer (*const T) |
| **Parent access** | Moved vars inaccessible | All vars still usable |
