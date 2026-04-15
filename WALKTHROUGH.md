# CLEAR Language Walkthrough

This guide showcases CLEAR: a memory-safe language that combines the ergonomics of scripting with the safety of affine types and the performance of hand-optimized C.

## 1. Immutability & Mutability

Bindings are immutable by default. Reassignment requires the `MUTABLE` keyword.

```ruby clear
x = 5;                        -- OKAY: Immutable binding (default)
name = "Alice";               -- OKAY: Immutable string
pi = 3.14159;                 -- OKAY: Immutable float

x = 6;                        -- COMPILER ERROR: x is immutable

MUTABLE counter = 0;          -- OKAY: Explicit mutability
counter = 1;                  -- OKAY: can reassign mutable binding
```

## 2. Primitive Types

CLEAR provides a comprehensive set of primitives for precise control over memory.

| Type | Description | Example |
| :--- | :--- | :--- |
| `Int8` .. `Int64` | Signed integers (8, 16, 32, 64-bit) | `42_i64`, `-1_i8` |
| `UInt8` .. `UInt64` | Unsigned integers (8, 16, 32, 64-bit) | `42_u64`, `-1_u8` |
| `Float32`, `Float64` | IEEE-754 floating point | `3.14159_f64`, `1.0_f32` |
| `Bool` | Boolean logic | `TRUE`, `FALSE` |
| `Byte` | Raw 8-bit data | `0x41_b` |
| `String` | UTF-8 encoded text (affine) | `"hello"` |
| `Void` | Absence of a value | `RETURN;` |

## 3. Types vs Capabilities

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

```ruby clear illustrative
STRUCT User { name: String }

FN process(u: User) RETURNS Void ->
  print(u.name);
  RETURN;
END

FN main() RETURNS Void ->
  -- At the call site, capabilities are unwrapped:
  shared_u = User{ name: "Alice" } @shared;
  WITH shared_u AS val { process(val); }
  RETURN;
END
```

If you change `@shared` to `@multiowned`, the `process` function remains untouched. The refactor is a one-line change at the declaration.

### WITH Blocks for Capability Unwrapping

For multi-statement access, use `WITH` blocks:

```ruby clear
MUTABLE counter: Int64@shared:locked = 0;

WITH EXCLUSIVE counter AS c {
    c += 1;
    print(c.toString());
}
```

## 4. Affine Ownership: GIVE & TAKES

CLEAR uses **affine types** by default. Every value has exactly one owner. When you assign a value, ownership is **moved**, not copied.

```ruby clear
FN process(TAKES s: String) RETURNS Void ->
    print(s);
    -- s is destroyed here (end of scope)
END

FN main() RETURNS Void ->
    msg = "Hello";

    process(msg);                   -- OKAY: Implicit transfer (by FN signature)

    print(GIVE msg);                -- COMPILER ERROR: USE AFTER MOVE: You can't GIVE `msg`.  `process(msg)` TOOK it away.
    print(msg);                     -- COMPILER ERROR: USE AFTER MOVE: You can't use `msg`.  `process(msg)` TOOK it away.

    RETURN;
END
```

For more details, see [docs/sharing-capabilities.md](docs/sharing-capabilities.md).

### Parameter Ownership

Function parameters are **implicit borrows** by default. Only `TAKES` transfers ownership.

| Param Style | Ownership | Can Move Into Container? | Can Mutate? |
| :--- | :--- | :--- | :--- |
| `v: Value` | Borrow | No | No |
| `MUTABLE v: Value` | Borrow | No | Yes |
| `TAKES v: Value` | Owned | Yes | No |
| `TAKES MUTABLE v: Value` | Owned | Yes | Yes |

```ruby clear
UNION Value { Nil, Num: Float64, Lambda { body: Value @indirect } }

-- Borrow: can read, cannot store or move
FN inspect(v: Value) RETURNS String ->
    MATCH v START
        Value.Num AS n -> RETURN n.toString();,
        DEFAULT -> RETURN "other";
    END
END

-- Owned: can store into collections
FN store!(TAKES v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
    map["item"] = v;                -- OKAY: v is owned via TAKES
    RETURN;
END

FN bad!(v: Value, MUTABLE map: HashMap<Value>) RETURNS Void ->
    map["item"] = v;                -- COMPILER ERROR: Cannot move borrowed value 'v'
    RETURN;
END
```

**Zero implicit copies.** Copy types (primitives, strings, enums) can be freely used after assignment. Non-Copy types (unions with `@indirect` or `[]T` variants, structs with heap data) follow move semantics. There are never implicit deep copies.

## 5. Sharded Shared-Nothing Architecture

The `@sharded` capability partitions data across threads, enabling massive parallelism without lock contention by automatically pinning threads to specific data shards.

```ruby clear
-- A sharded map distributes keys across independent thread-local heaps
MUTABLE registry: HashMap<Int64>@sharded(8) = {};

-- CLEAR automatically pins this fiber to the correct shard
BG {
    registry["key"] = 42;
}

-- Sharding is also available for Pools and Lists
MUTABLE users: User[100]@pool:sharded(4) = [];
MUTABLE logs: String[]@list:sharded(2) = [];

-- Note: Sharding provides peak throughput but carries a risk of
-- data skew if keys/items are not uniformly distributed.
```

NOTE: shared-nothing architectures present problems if your workloads can be heavily skewed.

## 6. Function Signatures

Functions support explicit types, failable returns (`!T`), and optional types (`?T`).

```ruby clear
STRUCT Point { x: Float64, y: Float64 }

FN sum(p: Point) RETURNS Float64 ->
    RETURN p.x + p.y;
END

FN main() RETURNS Void ->
    p = Point{ x: 3.0, y: 4.0 };
    d = sum(p);
    RETURN;
END
```

Failable and optional returns:

```ruby clear illustrative
FN findUser(id: Int64) RETURNS !?User ->
    IF id < 0 -> RAISE "Invalid ID";
    RETURN result;
END
```

### Recursion

Recursive functions must be explicitly annotated with `@reentrant`:

```ruby clear
FN fib(n: Int64) RETURNS Int64 @reentrant ->
    IF n <= 1 -> RETURN n;
    RETURN fib(n - 1) + fib(n - 2);
END
```

## 7. Basic Control Flow

CLEAR provides standard control flow constructs with support for one-line shorthands.

```ruby clear
-- 1. IF / ELSE_IF / ELSE
x = 75;
IF x > 100 THEN
    print("Large");
ELSE_IF x > 50 THEN
    print("Medium");
ELSE
    print("Small");
END

-- 2. WHILE loops
MUTABLE i = 0;
WHILE i < 10 DO
    print(i.toString());
    i += 1;
END

-- 3. FOR loops (Range iteration)
FOR j IN (1 ..= 5) -> print(j.toString());     -- OKAY: Inclusive range
FOR j IN (1 ..< 5) -> print(j.toString());     -- OKAY: Exclusive range
```

## 8. Enums, Unions, and Pattern Matching

### Enums

Simple enumerations for discrete states:

```ruby clear
ENUM Direction { North, South, East, West }

FN describe(d: Direction) RETURNS String ->
    MATCH d START
        Direction.North -> RETURN "up";,
        Direction.South -> RETURN "down";,
        Direction.East  -> RETURN "right";,
        Direction.West  -> RETURN "left";
    END
END
```

### Tagged Unions (Sum Types)

Unions carry a payload per variant. Unit variants (no payload) are also supported:

```ruby clear
UNION Result { Ok: Float64, Err: String, Empty }

FN main() RETURNS Void ->
    -- Payload variant
    r = Result{ Ok: 42.0 };

    -- Unit variant (no payload)
    e = Result.Empty;

    MATCH r START
        Result.Ok    -> print("success");,
        Result.Err   -> print("error");,
        Result.Empty -> print("nothing");
    END
    RETURN;
END
```

### MATCH AS and Ownership

`MATCH ... AS` payload extraction follows the same ownership rules as parameters. The binding is a **borrow** of the source by default, or a **move** if the source is owned.

| Source Ownership | MATCH AS Produces | Can Store in Struct? |
| :--- | :--- | :--- |
| Borrowed (parameter, `map.get`) | Borrow | No |
| Owned (local, TAKES param) | Move (consumes source) | Yes |

```ruby clear illustrative
UNION Value { Nil, Num: Float64, List: Value[] }

-- Borrowed source: MATCH AS produces a borrow
FN sum(v: Value) RETURNS Float64 ->
    MATCH v START
        Value.List AS items ->       -- items is &[]Value (borrow)
            RETURN items.length();   -- OKAY: reading a borrow
        DEFAULT -> RETURN 0.0;
    END
END

-- Owned source: MATCH AS moves the payload
FN take!(TAKES v: Value) RETURNS Value[] ->
    MATCH v START
        Value.List AS items ->       -- items is []Value (owned, v consumed)
            RETURN items;            -- OKAY: returning owned data
        DEFAULT -> RETURN List[];
    END
END
```

Storing a borrowed `MATCH AS` binding into a struct or union variant is a compile error:

```ruby clear illustrative
FN bad(items: Value[]) RETURNS Value ->
    -- items is a borrowed parameter
    RETURN Value.Lambda{ params: items };  -- COMPILER ERROR: Cannot store borrowed 'items'
END
```

### Generics

Structs and unions support type parameters:

```ruby clear
STRUCT Pair<T> { first: T, second: T }

p = Pair<Int64>{ first: 1, second: 2 };
```

## 9. Higher-Order Functions & Error Handling

CLEAR supports powerful functional pipelines via the Smooth operator `s>`.

```ruby clear illustrative
-- 1. Pipelines: Filter, Aggregate, Transform
alive = entities s> WHERE _.health > 0;
total = scores s> SUM _.value;
names = users s> SELECT _.name;

-- 2. Side effects & Function Piping
entities s> EACH { _.x += _.vx; };
result = data s> process s> validate s> format;

-- 3. Error Handling: Inline OR / OR RAISE
val = parseInt("abc") OR 0;                         -- OKAY: Fallback value
content = readFile("config.json") OR RAISE;         -- OKAY: Explicit propagation

-- 4. Function-level CATCH
FN main() RETURNS Void ->
    result = loadConfig("config.json") OR RAISE;
    print("Config: ${result}");
    RETURN;
CATCH e
    print("Failed to load: ${e}");
    RETURN;
END
```

See [docs/pipelines.md#operators](docs/pipelines.md#operators) for a full list of higher-order function operators.

Pipelines are automatically fused for efficiency.

## 10. Time as Tense (~T)

Tense represents a value that will exist in the future. CLEAR eliminates the complexity of `Future/Promise/Observable` with a single unified tense.

- `~User` is read as **"Future User"**.
- `~User[]` is read as **"Future Users"**.
- A **STREAM** of users is simply one way to produce "Future Users".

```ruby clear illustrative
-- 1. Promise (~T): A single future value
p: ~String = BG { sleep(100); RETURN "Data"; };
val = NEXT p;                                       -- OKAY: Blocks until ready

-- 2. Open Stream (~?T[]): Asynchronous generator
-- NEXT on ~?T[] returns ?T, with NIL signaling exhaustion.
gen: ~?Int64[] = BG STREAM {
    YIELD 10;
    YIELD 20;
};
val = NEXT gen;                                     -- OKAY: Returns ?Int64 (NIL when exhausted)

-- 3. Infinite Stream (~T[INF]): Lazy rendezvous generator
counter: ~Int64[INF] = BG STREAM {
    MUTABLE i = 0;
    WHILE TRUE DO { YIELD i; i += 1; }
};
v1 = NEXT counter;                                  -- OKAY: Returns Int64 (never NIL)
```

## 11. Collections: Array, List, and Pool

All collections are **automatically monomorphized** -- the compiler generates zero-overhead, type-specific native code for every unique `T`.

| Sigil | Collection | Purpose |
| :--- | :--- | :--- |
| `T[N]` | `Array` | Fixed-size, stack-allocated (if small) |
| `T[]@list` | `List` | Dynamic-size, heap-backed |
| `T[N]@pool` | `Pool` | Fixed-capacity, generational handles |
| `T[]@set` | `Set` | Dynamic-size, heap-backed, distinct items |


```ruby clear
STRUCT User { name: String }

-- 1. Fixed Array
vals = [10, 20, 30];

-- 2. Dynamic List
MUTABLE items: Int64[]@list = [];
items.append(42);

-- 3. Generational Pool
-- Pools provide peak cache locality. Switching from List to @pool:soa
-- (Structure of Arrays) is a one-line refactor for massive speed.
MUTABLE users: User[100]@pool = [];

id = users.insert(User{ name: "Alice" });           -- Returns stable handle
user = users.get(id) OR RAISE;                      -- Returns ?T (checks stale handles)
```

### Element-Level Capabilities

Capabilities normally apply to the **collection** (`T[]@shared` = one shared list). For rare cases where each **element** needs its own capability, place the capability before the array suffix:

```ruby clear illustrative
-- Collection-level (common): one Arc wrapping the whole list
MUTABLE shared_list: User[]@list:shared = [];

-- Element-level (rare): each element is individually Arc'd
MUTABLE arc_users: User@shared[]@list = [];

-- Element-level with pool: each slot holds an Arc'd user
MUTABLE arc_pool: User@shared[100]@pool = [];
```

Element-level capabilities are primarily useful in struct fields where individual elements need independent lifetime management (e.g., a graph where each node is shared across multiple edges).

## 12. Strings and Buffers

Strings in CLEAR are Copy (like Rust's `&str` — a pointer + length). Assignment copies the slice header.

```ruby clear
x = "hello";
y = x;                         -- x is moved (strings are owned, non-Copy)
-- z = x;                      -- would be use-after-move error
z = COPY y;                    -- OK: explicit deep-copy

-- String concatenation
full = "foo" + "bar";          -- "foobar" (single allocation, no intermediate)
```

Like arrays, Strings have capabilities:

`String@raw` (byte buffer) and `String@ring` (v0.2 - circular buffer for streaming).

## 13. Graphs, Cycles, and @indirect

For recursive or cyclic data structures, use `@indirect` (heap-allocated pointer, like Rust's `Box<T>`). Combined with `@reentrant` for recursive traversal:

```ruby clear illustrative
-- Recursive tree node using @indirect for child pointers
STRUCT Node {
    value: Int64,
    left: ?Node@indirect,     -- Optional heap-allocated child
    right: ?Node@indirect
}

-- Recursive traversal must be @reentrant
FN sumTree(n: Node) RETURNS Int64 @reentrant ->
    MUTABLE total = n.value;
    IF n.left -> total += sumTree(n?.left OR 0);
    IF n.right -> total += sumTree(n?.right OR 0);
    RETURN total;
END
```

`@indirect` gives the node a stable heap address, enabling graph structures. `@multiowned` (Rc) enables shared ownership for DAGs. For cyclic graphs, use `@link` -- CLEAR's weak reference.

`?.` is the safe navigate operator to peak into optional types.  It combines with `OR` to handle missing data like an error.

### Weak References with @link

`@link` creates a weak reference that does not keep the target alive. It works with both `@multiowned` (WeakRc) and `@shared` (WeakArc).

- `LINK expr` -- downgrade a strong reference to a weak reference
- `RESOLVE expr` -- upgrade a weak reference back to an optional strong reference (`?T`)

```ruby clear illustrative
-- Parent-child with back-pointer cycle
STRUCT Parent {
    name: String,
    child: ?Child@multiowned@indirect
}

STRUCT Child {
    name: String,
    parent: ?Parent@link          -- weak back-pointer, breaks the cycle
}

FN main() RETURNS Void ->
    p = Parent{ name: "Alice", child: NIL } @multiowned;

    -- LINK downgrades the strong Rc to a WeakRc
    weak_p = LINK p;

    -- RESOLVE upgrades back to ?Parent@multiowned (optional)
    WITH RESOLVE weak_p AS strong {
        ASSERT strong.name == "Alice", "resolved";
    }
    ELSE -> ASSERT FALSE, "should have resolved";

    RETURN;
END
```

Key rules:
- `LINK` only works on `@multiowned` or `@shared` values (compile-time error otherwise)
- `RESOLVE` only works on `@link` values (compile-time error otherwise)
- `RESOLVE` returns `?T` -- the target may have been dropped, so you must handle NIL
- Cleanup is automatic: weak references are released when they go out of scope
- No runtime cost when the strong reference is still alive; RESOLVE is a simple count check

## 14. Concurrency: BG & DO

CLEAR makes background tasks and fork-join parallelism trivial.

```ruby clear illustrative
-- BG: Background execution
p: ~Int64 = BG { RETURN slowComputation(); };

-- DO: Fork-Join parallel execution
DO {
    step1(),
    step2()
}

-- CONCURRENT: Parallel pipelines
results = items s> CONCURRENT(workers: 8) SELECT transform(_);
```

### BG Stack Modifiers

| Modifier | Stack Size | Use |
|---|---|---|
| `@micro` | 4 KB | Lightweight tasks |
| `@standard` | 16 KB | Default |
| `@large` | 64 KB | File I/O, deep recursion |
| `@xl` | 256 KB | Very deep call stacks |
| `@pinned` | (any) | Pin to local scheduler |
| `@arena` | (any) | Thread-local arena; implies @pinned |

## 15. Modules & Imports

CLEAR uses a simple namespace-based module system via `REQUIRE`.

```ruby clear illustrative
REQUIRE "math_utils.cht" AS m;                      -- Local file alias
REQUIRE "pkg:geometry";                             -- Package import

FN main() RETURNS Void ->
    p = geometry.Point{ x: 1, y: 2 };
    print(m.square(10).toString());
    RETURN;
END
```

See [docs/modules.md](docs/modules.md) for visibility (`PUB`/`PRIVATE`) and build details.

## 16. FFI: Native Integration

CLEAR integrates directly with Zig and C libraries via `EXTERN` declarations. All EXTERN FN calls automatically trampoline to the OS stack (g0) for fiber safety.

### Importing Functions and Types

```ruby clear illustrative
-- Import a struct type from a Zig module
EXTERN STRUCT Vec2 { x: Float64, y: Float64 } FROM "math_native";

-- Import a free function
EXTERN FN computeDistance(v: Vec2) RETURNS Float64 FROM "math_native";

-- Import with allocator injection (EFFECTS)
EXTERN FN parseJson(data: String) RETURNS !JsonDoc
    EFFECTS :alloc:heap FROM "json_native";
```

### Local Struct Definitions (no FROM)

For passing default options or defining Zig-compatible layouts:

```ruby clear illustrative
-- Local struct (no external module)
EXTERN STRUCT ParseOptions {};
EXTERN STRUCT JsonRecord { id: Int64, data: Int64[] };

-- Comptime type parameters for generic FFI
EXTERN FN parseFromSliceLeaky<T>(comptime: T, content: String, options: ParseOptions)
    RETURNS !T EFFECTS :alloc:heap FROM "std.json";
```

### Method Calls on EXTERN Structs

```ruby clear illustrative
EXTERN STRUCT Dir {} FROM "std.fs";
EXTERN FN cwd() RETURNS Dir FROM "std.fs";
EXTERN FN Dir.makePath(self: Dir, path: String) RETURNS Void FROM "std.fs";

-- Chained method call (both trampolined to g0)
cwd().makePath("data");
```

### EXTERN STRUCT CLOSE (RAII)

```ruby clear illustrative
EXTERN STRUCT Buffer { data: String }
    CLOSE "deinit" FROM "native_resource";

-- Buffer.deinit() is auto-called when buf goes out of scope
buf = createBuffer("hello");
-- defer buf.deinit() emitted automatically
```

 * See [json_api](benchmarks/24_json_api/server.cht) for an example.
 * See [docs/ffi.md](docs/ffi.md) for the complete FFI guide.

## 17. Memory Model

### Arena Allocation

Every function has its own memory arena. Variables live as long as the function they were born in.

- **Stack** (~0ns): Primitives and small structs (up to 128 slots)
- **Frame Arena** (~2ns): Large structs, temporary buffers, string concat
- **Heap** (~60ns): Dynamic collections, cross-fiber data, Rc/Arc

### Escaping the Arena

- `RETURN`: Values stay in the caller's frame arena (no heap dupe for strings).
- `GIVE`: Ownership is transferred to the callee.
- `@shared` / `@multiowned`: Reference-counted objects that live as long as they are referenced.

### Loop Arena Rewind

Inside loops, the frame arena is rewound each iteration to prevent unbounded growth. Mutable variables that accumulate across iterations (like string concatenation) are automatically detected and excluded from the rewind.

CLEAR additionally inserts cooperative yielding into loops to prevent head-of-line blocking, etc.

This destroys SIMD optimizations. CLEAR can detect when a SIMD optimization is possible and warn you to use `TIGHT` loops:

```ruby clear illustrative
TIGHT FOR i IN (1..<1000) -> ...
```

CLEAR will also warn you when you're using a `TIGHT` loop and you should not.  

NOTE: misusing `TIGHT` loops can destroy your p99 latency.

## 18. The Reality of Concurrency

In an ideal world, every workload would distribute perfectly across available cores and memory. In reality, concurrency is difficult because of the "messy middle":

1.  **Skew:** Data is rarely uniform. Sharded collections can develop "hot shards" that bottleneck the system.
2.  **Outliers:** The 0.1% of workers that take 100x longer than typical (due to cache misses or deep recursion) destroy p99 response times.
3.  **Non-Cooperation:** Problems like head-of-line blocking and thundering herds can stall an entire thread pool.
4.  **Variadic Depth:** Real-world recursion and loops often exceed the fixed stack sizes of traditional fibers.

CLEAR handles these issues through its **Control Plane** -- an active runtime observer that uses live telemetry to manage execution.

- **Fiber Overflow:** The runtime detects imminent stack overflows and auto-upsizes future tasks to `@large` or `@xl` stacks.
- **Workload Mismatch (v0.2):** Telemetry-driven alerting when the runtime detects contented or skewed workloads. `./clear profile` can automatically suggest fixes.  
- **Shared-Nothing Safety:** By enforcing sharding and affine moves at the language level, the Control Plane can optimize memory layout without fear of data races.
- **Workload Migration (v0.4+):** Telemetry-driven migration allows the runtime to detect contention and skew in real-time and react to it, *IF* you have the protection enabled (added memory).  


See [docs/control-plane.md](docs/control-plane.md) for more on how CLEAR manages the reality of high-performance systems.

## 19. Function Lifetimes

Functions cannot returned borrowed data freely, but can with a lifetime.  This is simplified from Rust.

```ruby clear
FN grandChild(n: Node) RETURNS n.left.?Node ->
  RETURN n?.left?.right;
END
```

Lifetimes are scoped with `<param>.<path>.`.  `n.left.` is the path and `?Node` is the return type.

This is a less restrictive lifetime than `n.?Node`.

Standard `IMMUTABLE` returned borrows *just work*:

```ruby clear illustrative
gc = node.grandChild();
print(gc?.value OR 0);
```

`MUTABLE` returned borrows require a scope - because the object you're borrowing from is restricted while you hold the borrow to prevent use-after-free:

```ruby clear illustrative
WITH RESTRICT node AS n {
  MUTABLE gc = n.grandChild();
  gc.value = 0;
  node.left = Nil; -- COMPIILER ERROR: `node` is RESTRICTED.  It's immutable in this scope.
  n.left = Nil;    -- COMPIILER ERROR: `n` is RESTRICTED.  It's immutable in this scope.
}
```

## 20. STRUCT lifetimes

It's sometimes useful to define a STRUCT with a borrowed field (iterators are a prime example):

```
STRUCT SliceIter {
    source: BORROWED Int64[], -- Allows `source` to be a BORROW, must be initialized in a scope.
    pos: Int64,
    len: Int64
}

FN hasNext(iter: SliceIter) RETURNS Bool ->
    RETURN iter.pos < iter.len;
END

FN iterExample() RETURNS Void ->
  WITH BORROWED data AS ref { -- create a borrowed version
    MUTABLE iter = SliceIter{ source: ref, pos: 0, len: n };
    WHILE hasNext(iter) DO
      total += currentVal(iter);
      iter = advance(iter);
    END
    RETURN iter;       -- COMPILER ERROR: You can't return `iter`.  It's BORROWED.  You don't own it.
  }
END
```

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
| `@link` | To create cyclic graphs (WeakRef/Ref) |
| `@sharded(N)` | Shared-nothing partitioned across N shards |

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

## Integer Overflow Operators

CLEAR uses fixed-width integers (Int64, Int32, etc.) that can overflow. Three tiers of arithmetic operators control what happens on overflow:

### Default: `+`, `-`, `*`

Panics on overflow in **debug** builds, wraps silently in **release** builds. This matches Rust's semantics - catches accidental overflow during development, zero overhead in production.

```
a: Int64 = 9223372036854775807_i64;
b = a + 1_i64;  -- debug: PANIC!  release: wraps to -9223372036854775808
```

### Wrapping: `%+`, `%-`, `%*`

Always wraps on overflow in **all** build modes. Use for hash functions, random number generators, checksums, and any code that intentionally overflows.

```
-- LCG random number generator (intentional overflow)
MUTABLE state: Int64 = seed;
state = state %* 6364136223846793005_i64 %+ 1442695040888963407_i64;

-- Max + 1 wraps to min
max: Int64 = 9223372036854775807_i64;
min = max %+ 1_i64;  -- always -9223372036854775808, never panics
```

### Checked: `!+`, `!-`, `!*`

Always panics on overflow in **all** build modes, including release. Use for financial calculations, safety-critical code, and anywhere overflow indicates a logic error.

```
-- Financial calculation: overflow means a bug, even in production
balance = balance !+ deposit;  -- panics if result exceeds Int64 range
total = quantity !* price;     -- panics on overflow, even in release
```

### Summary

| Operator | Debug build | Release build | Use case |
|----------|-------------|---------------|----------|
| `+`, `-`, `*` | panic | wrap | General arithmetic |
| `%+`, `%-`, `%*` | wrap | wrap | Hash, RNG, checksum |
| `!+`, `!-`, `!*` | panic | panic | Financial, safety |

Float arithmetic (`Float64`) is unaffected - IEEE 754 handles overflow via infinity/NaN.
