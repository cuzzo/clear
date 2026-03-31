# CLEAR Language Walkthrough

This guide showcases CLEAR: a memory-safe language that combines the ergonomics of scripting with the safety of affine types and the performance of arena-based memory.

## 1. Immutability & Mutability

Bindings are immutable by default. Reassignment requires the `MUTABLE` keyword.

```clear
-- OKAY: Immutable binding
x = 10
-- COMPILER ERROR: Cannot reassign immutable binding
x = 20

-- OKAY: Explicit mutability
MUTABLE y = 10
y = 20
```

## 2. Primitive Types

CLEAR provides a robust set of primitives. `Number` is an alias for `Float64`.

| Type | Description | Example |
| :--- | :--- | :--- |
| `Int64` | 64-bit signed integer | `42_i64` |
| `Float64` | 64-bit float | `3.14` |
| `Number` | Alias for Float64 | `1.0` |
| `Bool` | Boolean | `TRUE`, `FALSE` |
| `Char` | Unicode character | `'a'` |
| `String` | UTF-8 string (affine) | `"hello"` |
| `Void` | Empty return type | `RETURN` |

## 3. Higher-Order Functions & Error Handling

CLEAR supports functional primitives and elegant error propagation.

```clear
numbers = [1, 2, 3, 4, 5]

-- Map and Filter
evens = numbers.filter(FN(n) -> n % 2 == 0)
doubled = numbers.map(FN(n) -> n * 2)

-- Inline Error Handling
-- OKAY: Provide a default value
val = parseInt("abc") OR ELSE 0

-- OKAY: Propagate error up the stack
FN loadConfig(path: String) RETURNS !String ->
    content = readFile(path) OR RAISE
    RETURN content
END

-- OKAY: Handle errors at the bottom of a block
FN main() RETURNS Void ->
    result = loadConfig("config.json")
    CATCH err ->
        print("Failed to load: ${err}")
        RETURN
    END
    print("Config: ${result}")
END
```

## 4. Time as Tense (~T)

Tense represents a value that will exist in the future (a promise). It allows composition without worrying about the underlying concurrency capability yet.

```clear
-- ~String is a promise of a String
FN fetchRemote() RETURNS ~String ->
    RETURN BG {
        sleep(100)
        RETURN "Data"
    }
END

-- Tense types compose naturally
p1 = fetchRemote()
p2 = fetchRemote()

-- Execution happens in parallel; we wait only when needed
val1 = NEXT p1
val2 = NEXT p2
```

## 5. Concurrency & Parallelism

CLEAR makes fan-out architectures and background tasks trivial.

```clear
-- Background execution
p: ~Int64 = BG {
    RETURN slowComputation()
}

-- Parallel branches
DO {
    :branch1 -> step1()
    :branch2 -> step2()
}

-- Fan-out: processing a list in parallel
results = urls.map(FN(url) -> BG { fetch(url) })
data = results.map(FN(p) -> NEXT p)
```

## 6. Capabilities: Shared & Synchronized

Capabilities define *how* data is accessed. Functions take Types; call sites provide Capabilities.

```clear
-- @shared: Atomic Reference Counting (Arc)
-- @locked: Internal mutability / Mutex
MUTABLE counter: Int64@shared@locked = 0

DO {
    :increment ->
        WITH counter AS !c ->
            c = c + 1
        END
    :read ->
        print(counter)
END
```

## 7. Sharded Shared-Nothing Architecture

The `@shard` capability partitions data across threads. This allows for massive parallelism without lock contention.

```clear
-- A sharded map automatically distributes keys across thread-local heaps
MUTABLE registry: String{Int64}@shard = {}

-- OKAY: CLEAR automatically pins threads to shards to avoid contention
BG {
    registry["key"] = 42
}

-- Note: Sharding provides high throughput but can risk data skew 
-- if keys are not uniformly distributed.
```

## 8. Collections: Array, List, and Pool

| Sigil | Collection | Purpose |
| :--- | :--- | :--- |
| `T[N]` | `Array` | Fixed-size, stack-allocated (if small) |
| `T[]@list` | `List` | Dynamic-size, heap-backed |
| `T[]@pool` | `Pool` | Fixed-capacity, pre-allocated |

```clear
-- Fixed Array
arr: Int64[3] = [1, 2, 3]

-- Dynamic List
MUTABLE items: Int64[]@list = []
items.append(1)

-- Pre-allocated Pool
MUTABLE users: User[]@pool = []
```

## 9. Strings, Buffers, and RingBuffers

Strings in CLEAR are affine and can be specialized for performance.

```clear
s = "Standard String"

-- String@raw: A mutable byte buffer
MUTABLE buf: String@raw = Buffer::new(1024)
buf.appendBytes(0x41)

-- String@ring: A circular buffer for streaming
MUTABLE ring: String@ring = RingBuffer::new(256)
```

## 10. Affine Ownership: GIVE & TAKES

CLEAR uses affine types to ensure memory safety without a garbage collector.

```clear
FN process(TAKES s: String) RETURNS Void ->
    print(s)
    -- s is destroyed here
END

FN main() RETURNS Void ->
    msg = "Hello"
    
    -- OKAY: Transfer ownership to the function
    process(GIVE msg)
    
    -- COMPILER ERROR: Use after move
    print(msg)
END
```

## 11. Refcounting & Cyclic Structures

For data that must be shared by multiple owners, use `@multiowned` (Rc). For recursive or cyclic structures, use `@indirect` (Box).

```clear
-- Reference counted data
x: String@multiowned = "Shared"

-- Cyclic structure using @indirect (Box)
-- See: examples/scheme/ for a full implementation of a Lisp AST
STRUCT Node {
    value: Int64,
    next: Node@indirect?
}
```

## 12. FFI: Native Integration

CLEAR integrates directly with Zig and C.

```clear
-- Define a native struct layout
EXTERN STRUCT Vec2 { x: Float64, y: Float64 }

-- Call a native function from a Zig module
EXTERN FN computeDistance(v: Vec2) RETURNS Float64 FROM "math_native"

-- Showcase: See benchmarks/24_json_api/ for high-performance 
-- direct std.json FFI integration.
```
