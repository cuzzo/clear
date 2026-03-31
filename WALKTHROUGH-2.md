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

CLEAR provides a comprehensive set of primitives for precise control over memory and performance.

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

## 3. Function Signatures

Functions are defined with the `FN` keyword and use an arrow `->` to start the body.

```clear
-- Simple function with explicit types
FN add(a: Int64, b: Int64) RETURNS Int64 ->
    RETURN a + b;                                   -- OKAY
END

-- Failable function (!) and optional types (?)
FN findUser(id: Int64) RETURNS !?User ->
    IF id < 0 -> RAISE "Invalid ID";                -- OKAY: One-line shorthand
    -- logic to return optional User
    RETURN result;                                  -- OKAY
END
```

## 4. Structs & Uniform Function Call Syntax (UFCS)

Structs define data layouts. Functions defined with a type prefix can be called using method syntax.

```clear
STRUCT Point {
    x: Float64,
    y: Float64
}

-- UFCS: Method-style call for functions
FN Point::distance(p: Point) RETURNS Float64 ->
    RETURN sqrt(p.x * p.x + p.y * p.y);             -- OKAY
END

FN main() RETURNS Void ->
    p = Point{ x: 3.0, y: 4.0 };                    -- OKAY: Struct literal
    d = p.distance();                               -- OKAY: UFCS method call
    d2 = Point::distance(p);                        -- OKAY: Equivalent static call
    RETURN;
END
```

## 5. Basic Control Flow

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

-- 3. FOR loops (Collection iteration)
items = [1, 2, 3];
FOR item IN items -> print(item.toString());        -- OKAY: One-line shorthand

-- 4. FOR loops (Range iteration)
FOR j IN (1 ..= 5) DO                               -- OKAY: Inclusive range
    print(j.toString());
END
```

## 6. Higher-Order Functions & Error Handling

CLEAR supports powerful functional pipelines via the Smooth operator `s>`.

```clear
-- 1. Pipelines: Filter, Aggregate, Transform
alive = entities s> WHERE _.health > 0;             -- OKAY
total = scores s> SUM _.value;                      -- OKAY
names = users s> SELECT _.name;                     -- OKAY

-- 2. Function Piping & In-place Mutation
result = data s> process s> validate s> format;     -- OKAY
entities s> EACH { _.x = _.x + _.vx; };             -- OKAY

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

| Category | Operators |
|---|---|
| **Transform** | `SELECT`, `WHERE`, `ORDER_BY`, `LIMIT`, `DISTINCT`, `UNNEST`, `INDEX` |
| **Aggregate** | `SUM`, `AVERAGE`, `MIN`, `MAX`, `REDUCE`, `COUNT`, `ANY`, `ALL`, `FIND` |
| **Side Effects** | `EACH` |

See [docs/pipelines.md#operators](docs/pipelines.md#operators) for a full list of higher-order function operators.

## 7. Time as Tense (~T)

Tense represents a value that will exist in the future. It allows composition of asynchronous logic and streams before deciding on a concurrency capability.

```clear
-- 1. Promise (~T): A single value in the future
p: ~String = BG { sleep(100); RETURN "Data"; };
val = NEXT p;                                       -- OKAY: Blocks until ready

-- 2. Bounded Stream (~T[N]): N concurrent parallel fibers
stream: ~Int64[3] = [
    BG { compute(1); },
    BG { compute(2); },
    BG { compute(3); }
];
v1 = NEXT stream;                                   -- OKAY: Popped in spawn order

-- 3. Open Stream (~T[?]): Asynchronous generator
gen: ~Int64[?] = BG STREAM {
    YIELD 10;
    YIELD 20;
};
val = NEXT gen;                                     -- OKAY: Returns ?Int64 (NIL when exhausted)

-- 4. Infinite Stream (~T[INF]): Lazy rendezvous generator
counter: ~Int64[INF] = BG STREAM {
    MUTABLE i = 0;
    WHILE TRUE DO
        YIELD i;
        i += 1;
    END
};
v1 = NEXT counter;                                  -- OKAY: Returns Int64 (never NIL)
```

## 8. Capabilities: Shared & Synchronized

Capabilities define *how* data is accessed. Functions take Types; call sites provide Capabilities. Joined capabilities use the `:` sigil.

```clear
-- @shared:locked — Atomic refcount + Mutex
MUTABLE counter: Int64@shared:locked = 0;           -- OKAY: Combined capabilities

-- Thread-safe mutation via WITH block
BG {
    WITH EXCLUSIVE counter AS c {                   -- OKAY: Acquire lock
        c += 1;                                     -- Mutate the alias
    }
}

-- Note: Functions still take the plain Type (Int64), making business 
-- logic decoupled from the synchronization strategy.
```

## 9. Sharded Shared-Nothing Architecture

Sharded collections partition data across threads, enabling massive parallelism without lock contention by automatically pinning threads to specific data shards.

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

## 10. Collections: Array, List, and Pool

CLEAR provides three core collection types with distinct memory and performance profiles.

| Sigil | Collection | Purpose |
| :--- | :--- | :--- |
| `T[N]` | `Array` | Fixed-size, stack-allocated (if small) |
| `T[]@list` | `List` | Dynamic-size, heap-backed |
| `T[N]@pool` | `Pool` | Fixed-capacity, pre-allocated handles |

```clear
-- 1. Fixed Array
arr: Int64[3] = [1, 2, 3];                          -- OKAY
vals = [10, 20, 30];                                -- OKAY: Type inference

-- 2. Dynamic List
MUTABLE items: Int64[]@list = [];                   -- OKAY: Empty list literal
MUTABLE names: String[] = List[];                   -- OKAY: Explicit List initializer

-- 3. Generational Pool
-- Pools require a fixed capacity for their backing storage
MUTABLE users: User[100]@pool = [];                 -- OKAY: Empty pool literal
MUTABLE entities: Entity[50] = Pool[];              -- OKAY: Explicit Pool initializer

id = users.insert(User{ name: "Alice" });           -- OKAY: Returns generational handle
```

## 11. Strings, Buffers, and RingBuffers

Strings in CLEAR are affine by default and can be specialized for specific performance profiles.

```clear
s = "Standard String";                              -- OKAY

-- String@raw: A mutable byte buffer
MUTABLE buf: String@raw = Buffer::new(1024);        -- OKAY
buf.appendBytes(0x41);                              -- OKAY

-- String@ring: A circular buffer for streaming
MUTABLE ring: String@ring = RingBuffer::new(256);   -- OKAY
```

## 12. Concurrency: BG & DO

CLEAR makes both background tasks and fork-join parallelism trivial.

```clear
-- BG: Background execution
p: ~Int64 = BG {                                    -- OKAY
    RETURN slowComputation();
};

-- DO: Fork-Join parallel execution
DO {                                                -- OKAY
    :branch1 -> step1();
    :branch2 -> step2();
}

-- Fan-out: processing a list in parallel
results = urls |> SELECT BG { fetch(_) };
data = results |> SELECT NEXT _;                    -- OKAY
```

## 13. Affine Ownership: GIVE & TAKES

CLEAR uses affine types to ensure memory safety without a garbage collector. Values have exactly one owner.

```clear
FN process(TAKES s: String) RETURNS Void ->
    print(s);                                       -- OKAY
    -- s is destroyed here (end of scope)
END

FN main() RETURNS Void ->
    msg = "Hello";                                  -- OKAY
    
    process(GIVE msg);                              -- OKAY: Transfer ownership
    
    print(msg);                                     -- COMPILER ERROR: Use after move
    RETURN;
END
```

## 14. Refcounting & Cyclic Structures

For shared data, use `@multiowned` (single-threaded Rc). For recursive or cyclic structures, use `@indirect` (Box).

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

## 15. FFI: Native Integration

CLEAR integrates directly with Zig and C with zero-overhead.

```clear
-- Define a native struct layout
EXTERN STRUCT Vec2 { x: Float64, y: Float64 };      -- OKAY

-- Call a native function from a Zig module
EXTERN FN computeDistance(v: Vec2) RETURNS Float64 FROM "math_native"; -- OKAY

-- Showcase: See benchmarks/24_json_api/ for high-performance 
-- direct std.json FFI integration via EXTERN FN.
```
