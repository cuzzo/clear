# CLEAR Language Walkthrough

This guide showcases CLEAR: a memory-safe language that combines the ergonomics of scripting with the safety of affine types and the performance of arena-based memory.

## 1. Immutability & Mutability

Bindings are immutable by default. Reassignment requires the `MUTABLE` keyword.

```clear
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
| `Uint8` .. `Uint64` | Unsigned integers (8, 16, 32, 64-bit) | `255_u8`, `100_u32` |
| `Float32`, `Float64` | IEEE-754 floating point | `3.14159_f64`, `1.0_f32` |
| `Bool` | Boolean logic | `TRUE`, `FALSE` |
| `Char` | Unicode scalar value | `'a'`, `'Ω'`, `'🚀'` |
| `Byte` | Raw 8-bit data | `0x41_b` |
| `String` | UTF-8 encoded text (affine) | `"hello"` |
| `Void` | Absence of a value | `RETURN;` |

## 3. Affine Ownership: GIVE & TAKES

CLEAR uses **affine types** by default. Every value has exactly one owner. When you assign a value or pass it to a function, ownership is **moved**, not copied.

```clear
FN process(TAKES s: String) RETURNS Void ->
    print(s);                                       -- OKAY
    -- s is destroyed here (end of scope)
END

FN main() RETURNS Void ->
    msg = "Hello";                                  -- OKAY
    
    process(GIVE msg);                              -- OKAY: Explicit transfer
    
    print(msg);                                     -- COMPILER ERROR: Use after move
    RETURN;
END
```

Explicit `GIVE` at the call site ensures that "data disappearance" is always visible to the reader. For more details, see [docs/sharing-capabilities.md](docs/sharing-capabilities.md).

## 4. Capabilities: Shared & Synchronized

Capabilities are the "solution" to affine movement. They define *how* data is accessed without changing the underlying Type. Multiple capabilities are joined using the `:` sigil and attached directly to the type.

```clear
-- @shared:locked — Multi-threaded ownership (Arc) + Mutex
MUTABLE counter: Int64@shared:locked = 0;           -- OKAY

-- 1. One-line updates (Auto-locking)
counter += 1;                                       -- OKAY: Auto acquire/release

-- 2. Multi-statement access (Manual block)
WITH EXCLUSIVE counter AS c {                       -- OKAY: Manual lock
    c += 1;
    print(c.toString());
}                                                   -- OKAY: Unlock here
```

By separating **Types** from **Capabilities**, functions remain decoupled from synchronization strategies. A function taking `Int64` works whether the caller provides a stack value, an `Rc`, or an `Arc<Mutex>`.

## 5. Sharded Shared-Nothing Architecture

The `@sharded` capability partitions data across threads, enabling massive parallelism without lock contention by automatically pinning threads to specific data shards.

```clear
-- A sharded map distributes keys across independent thread-local heaps
MUTABLE registry: HashMap<Int64>@sharded(8) = {};   -- OKAY

-- CLEAR automatically pins this fiber to the correct shard
BG {
    registry["key"] = 42;                           -- OKAY
}

-- Sharding is also available for Pools and Lists
MUTABLE users: User[100]@pool:sharded(4) = [];      -- OKAY
MUTABLE logs: String[]@list:sharded(2) = [];        -- OKAY

-- Note: Sharding provides peak throughput but carries a risk of 
-- data skew if keys/items are not uniformly distributed.
```

## 6. Function Signatures & UFCS

Functions support explicit types, failable returns (`!T`), and optional types (`?T`). **Uniform Function Call Syntax (UFCS)** allows calling any function with method syntax if its first argument matches the receiver type.

```clear
STRUCT Point { x: Float64, y: Float64 }

-- FN Type::name(self, ...) defines a method
FN Point::distance(p: Point) RETURNS Float64 ->
    RETURN sqrt(p.x * p.x + p.y * p.y);             -- OKAY
END

FN findUser(id: Int64) RETURNS !?User ->
    IF id < 0 -> RAISE "Invalid ID";                -- OKAY: One-line shorthand
    -- Returns optional User or propagates error
    RETURN result;                                  -- OKAY
END

FN main() RETURNS Void ->
    p = Point{ x: 3.0, y: 4.0 };
    d = p.distance();                               -- OKAY: UFCS method call
    RETURN;
END
```

## 7. Basic Control Flow

CLEAR provides standard control flow constructs with support for one-line shorthands.

```clear
-- 1. IF / ELSE_IF / ELSE
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

-- 3. FOR loops (Collection or Range iteration)
FOR item IN items -> print(item.toString());        -- OKAY: One-line shorthand
FOR j IN (1 ..= 5) DO print(j.toString()); END      -- OKAY: Inclusive range
```

## 8. Higher-Order Functions & Error Handling

CLEAR supports powerful functional pipelines via the Smooth operator `s>`.

```clear
-- 1. Pipelines: Filter, Aggregate, Transform
alive = entities s> WHERE _.health > 0;             -- OKAY
total = scores s> SUM _.value;                      -- OKAY
names = users s> SELECT _.name;                     -- OKAY

-- 2. side effects & Function Piping
entities s> EACH { _.x += _.vx; };                  -- OKAY
result = data s> process s> validate s> format;     -- OKAY

-- 3. Error Handling: Inline OR ELSE / OR RAISE
val = parseInt("abc") OR ELSE 0;                    -- OKAY: Fallback value
content = readFile("config.json") OR RAISE;         -- OKAY: Explicit propagation

-- 4. Function-level CATCH
FN main() RETURNS Void ->
    result = loadConfig("config.json") OR RAISE;
    print("Config: ${result}");
    RETURN;
CATCH e                                             -- OKAY: Handles any raised error
    print("Failed to load: ${e}");
    RETURN;
END
```

See [docs/pipelines.md#operators](docs/pipelines.md#operators) for a full list of higher-order function operators.

## 9. Time as Tense (~T)

Tense represents a value that will exist in the future. CLEAR eliminates the complexity of `Future/Promise/Observable` with a single unified tense.

- `~User` is read as **"Future User"**.
- `~User[]` is read as **"Future Users"**.
- A **STREAM** of users is simply one way to produce "Future Users".

```clear
-- 1. Promise (~T): A single future value
p: ~String = BG { sleep(100); RETURN "Data"; };
val = NEXT p;                                       -- OKAY: Blocks until ready

-- 2. Open Stream (~T[?]): Asynchronous generator
gen: ~Int64[?] = BG STREAM {
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

## 10. Collections: Array, List, and Pool

All collections are **automatically monomorphized** — the compiler generates zero-overhead, type-specific native code for every unique `T`.

| Sigil | Collection | Purpose |
| :--- | :--- | :--- |
| `T[N]` | `Array` | Fixed-size, stack-allocated (if small) |
| `T[]@list` | `List` | Dynamic-size, heap-backed |
| `T[N]@pool` | `Pool` | Fixed-capacity, generational handles |

```clear
-- 1. Fixed Array
vals = [10, 20, 30];                                -- OKAY: Type inference

-- 2. Dynamic List
MUTABLE items: Int64[]@list = [];                   -- OKAY
MUTABLE names: String[] = List[];                   -- OKAY

-- 3. Generational Pool
-- Pools provide peak cache locality. Switching from List to @pool:soa 
-- (Structure of Arrays) is a one-line refactor for massive speed.
-- See: [benchmarks/22_pool_vs_multiowned/](benchmarks/22_pool_vs_multiowned/)
MUTABLE users: User[100]@pool = [];                 -- OKAY

id = users.insert(User{ name: "Alice" });           -- OKAY: Returns stable handle
user = users.get(id) OR RAISE;                      -- OKAY: Returns ?T (checks for stale handles)
```

## 11. Strings, Buffers, and RingBuffers

Strings in CLEAR are affine and can be specialized for performance profiles.

```clear
s = "Standard String";                              -- OKAY

-- String@raw: A mutable byte buffer
MUTABLE buf: String@raw = Buffer::new(1024);        -- OKAY
buf.appendBytes(0x41);                              -- OKAY

-- String@ring: A circular buffer for streaming
MUTABLE ring: String@ring = RingBuffer::new(256);   -- OKAY
```

## 12. Concurrency: BG & DO

CLEAR makes background tasks and fork-join parallelism trivial.

```clear
-- BG: Background execution
p: ~Int64 = BG { RETURN slowComputation(); };       -- OKAY

-- DO: Fork-Join parallel execution
DO {                                                -- OKAY
    :branch1 -> step1();
    :branch2 -> step2();
}

-- Fan-out: processing a list in parallel
results = urls |> SELECT BG { fetch(_) };
data = results |> SELECT NEXT _;                    -- OKAY
```

## 13. Refcounting & Cyclic Structures

For data shared by multiple owners, use `@multiowned` (single-threaded Rc). For recursive or cyclic structures, use `@indirect` (Box).

```clear
-- Reference counted data (Rc)
x: String@multiowned = "Shared";                    -- OKAY

-- Cyclic structure using @indirect
-- See: examples/scheme/ for a full Lisp AST implementation
STRUCT Node {                                       -- OKAY
    value: Int64,
    next: Node@indirect?
}
```

## 14. Match, Enums, and Generics

CLEAR supports powerful pattern matching with destructuring and exhaustive checks (`MATCH IFF`).

```clear
UNION Shape {
    Circle: Float64,
    Rect: { w: Float64, h: Float64 }
}

FN area(s: Shape) RETURNS Float64 ->
    MATCH IFF s START                               -- OKAY: IFF ensures exhaustiveness
        Shape.Circle AS r -> RETURN 3.14 * r * r;
        Shape.Rect{ w, h } -> RETURN w * h;         -- OKAY: Destructure fields
    END
END
```

## 15. Modules & Imports

CLEAR uses a simple namespace-based module system via `REQUIRE`.

```clear
REQUIRE "math_utils.cht" AS m;                      -- OKAY: Local file alias
REQUIRE "pkg:geometry";                             -- OKAY: Package import

FN main() RETURNS Void ->
    p = geometry.Point{ x: 1, y: 2 };
    print(m.square(10).toString());
    RETURN;
END
```

See [docs/modules.md](docs/modules.md) for visibility (`PUB`/`PRIVATE`) and build details.

## 16. FFI: Native Integration

CLEAR integrates directly with Zig and C with zero-overhead.

```clear
-- Define a native struct layout
EXTERN STRUCT Vec2 { x: Float64, y: Float64 };      -- OKAY

-- Call a native function from a Zig module
EXTERN FN computeDistance(v: Vec2) RETURNS Float64 FROM "math_native"; -- OKAY

-- Showcase: See benchmarks/24_json_api/ for high-performance 
-- direct std.json FFI integration via EXTERN FN.
```

## 17. The Reality of Concurrency

In an ideal world, every workload would distribute perfectly across available cores and memory. In reality, concurrency is difficult because of the "messy middle":

1.  **Skew:** Data is rarely uniform. Sharded collections can develop "hot shards" that bottleneck the system.
2.  **Outliers:** The 0.1% of workers that take 100x longer than typical (due to cache misses or deep recursion) destroy p99 response times.
3.  **Non-Cooperation:** Problems like head-of-line blocking and thundering herds can stall an entire thread pool.
4.  **Variadic Depth:** Real-world recursion and loops often exceed the fixed stack sizes of traditional fibers.

CLEAR handles these issues through its **Control Plane** — an active runtime observer that uses live telemetry to manage execution.

- **Fiber Overflow:** The runtime detects imminent stack overflows and auto-upsizes future tasks to `@large` or `@xl` stacks.
- **Workload Migration (v0.2):** Telemetry-driven migration allows the runtime to detect skewed workloads and move fibers away from bottlenecked schedulers.
- **Shared-Nothing Safety:** By enforcing sharding and affine moves at the language level, the Control Plane can optimize memory layout without fear of data races.

See [docs/control-plane.md](docs/control-plane.md) for more on how CLEAR manages the reality of high-performance systems.

