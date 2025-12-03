# Language Reference Guide

A memory-safe, interpreted language with Rust-level guarantees but substantially simpler syntax.

## Table of Contents

1. [Core Philosophy](#core-philosophy)
2. [Basic Syntax](#basic-syntax)
3. [Variables and Mutability](#variables-and-mutability)
4. [Types](#types)
5. [Functions](#functions)
6. [Collections](#collections)
7. [Slices and Borrowing](#slices-and-borrowing)
8. [Atomics](#atomics)
9. [Control Flow](#control-flow)
10. [Error Handling](#error-handling)
11. [Concurrency](#concurrency)
12. [Streams and Pipelines](#streams-and-pipelines)
13. [Memory Model](#memory-model)

---

## Core Philosophy

**Safety First, Speed Second**
- Immutable by default
- Explicit mutation with `MUTABLE` keyword
- No null pointer errors
- No data races
- Arena-based memory management (no garbage collection)

**Explicit Over Implicit**
- Clear syntax for operations that allocate, mutate, or error
- Visible sigils for special behaviors
- No hidden costs

---

## Basic Syntax

### Comments
```
-- Single line comment
```

### Keywords
- `VAR` - Immutable binding
- `MUTABLE` - Mutable binding
- `SET` - Assignment to mutable variable
- `FN` - Function definition
- `RETURN` - Return from function
- `IF/THEN/ELSE/END` - Conditionals
- `MATCH/START/WHEN/END` - Conditionals
- `WHILE/DO/END;FOR/DO/END;BREAK/CONTINUE` - Loops
- `STRUCT` - Struct definition

---

## Variables and Mutability

### Immutable Variables (Default)
```
VAR x = 5;                    -- Immutable binding
VAR name = "Alice";           -- Immutable string
VAR pi = 3.14159;             -- Immutable float

SET x = 6;                    -- COMPILER ERROR: x is immutable
```

### Mutable Variables (Explicit)
```
MUTABLE counter = 0;          -- Mutable binding
SET counter = 1;              -- OK: can reassign
SET counter = counter + 1;    -- OK: can mutate
```

### Type Annotations
```
VAR x : UInt64 = 5;
VAR name : String = "Alice";
MUTABLE count : Int32 = 0;
```

---

## Types

### Scalar Types
```
-- Number (default numeric type)
Number                        -- NaN-boxed float (see Numeric Types below)

-- Integers
UInt8, UInt16, UInt32, UInt64
Int8, Int16, Int32, Int64

-- Floating Point
Float32, Float64

-- Boolean
Bool                          -- TRUE or FALSE

-- String
String                        -- UTF-8 strings
```

### Type Inference
```
VAR x = 5;                    -- Inferred as Number
VAR y = 3.14;                 -- Inferred as Float64
VAR flag = TRUE;              -- Inferred as Bool
VAR text = "hello";           -- Inferred as String
```

## Numeric Types

### The `Number` Type (Default)

**Numeric literals implicitly default to type `Number`**, which uses NaN-boxing to efficiently represent both integers and floating-point values in a single 64-bit value.
```
VAR x = 42;                   -- Type: Number (stored as integer internally)
VAR y = 3.14;                 -- Type: Number (stored as float internally)
VAR z = x + y;                -- Type: Number (promotes to float)
```

### Integer Precision Limits

**`Number` can safely represent integers in the range:**
- **Safe range:** -2^53 to 2^53 (approximately ±9 quadrillion)
- **Precision:** 53 bits for integers
```
-- Safe: within 53-bit range
VAR small = 9007199254740992;         -- 2^53, exact
VAR count = 1000000;                  -- Exact

-- Unsafe: exceeds 53-bit precision
VAR tooBig = 9007199254740993;        -- 2^53 + 1, loses precision!
VAR huge : UInt64 = 9007199254740993; -- Use explicit UInt64 for large integers
```

**Why 53 bits?** NaN-boxing uses IEEE 754 double-precision floats, which have 53 bits of integer precision (52 explicit + 1 implicit).

### Suffix Syntax

```
i8, i16, i32, i64              -- Signed integers
u8, u16, u32, u64              -- Unsigned integers
f32, f64                       -- Floats
```

```
VAR a = 255;                   -- Number (255 in decimal)
VAR b = 255u8;                 -- UInt8 (255)
VAR c = 255i64;                -- Int64 (255)
```

### Prefix Syntax

```
0xFF                           -- 255 in Hex
0o400                          -- 255 in Octal
0b101                          -- 5 in Binary
```

### Combined

```
VAR a = 0xFF;                  -- Number (255 in decimal)
VAR b = 0xFFu8;                -- UInt8 (255 as byte)
VAR c = 0xDEADBEEFu32;         -- UInt32
```

---

## Functions

### Function Definition
```
FN add(a, b) ->
  RETURN a + b;
END

FN greet(name) ->
  RETURN "Hello, " + name + "!";
END
```

### With Type Annotations
```
FN add(a : UInt64, b : UInt64) -> UInt64 ->
  RETURN a + b;
END

FN greet(name : String) -> String ->
  RETURN "Hello, " + name + "!";
END
```

### UpValues (Closures)

Functions must explicitly declare captured variables:
```
FN outer() ->
  VAR x = 5;
  MUTABLE y = 10;

  -- Capture immutable upvalue
  FN readOnly() USE(x) ->
    PRINT(x);
    SET x = 6;                -- COMPILER ERROR: x is immutable
  END

  -- Capture mutable upvalue
  -- Mutates, is forbidden non-sequentially (ASYNC, concurrent, etc)
  -- See Atomics section below for non-sequential mutation
  FN modify!() USE(MUTABLE y) ->
    SET y = y + 1;            -- OK: explicitly mutable
  END

  -- Multiple captures
  -- Mutates, is forbidden non-sequentially (ASYNC, concurrent, etc)
  FN both!() USE(x, MUTABLE y) ->
    PRINT(x);
    SET y = y + x;
  END
END
```

### Mutation Suffix `!`

Functions that mutate their parameters use `!` suffix:
```
FN increment!(MUTABLE counter) ->
  SET counter = counter + 1;
END

MUTABLE x = 5;
increment!(x);                -- x is now 6
```

---

## Collections

### Arrays

**The `%` sigil means "allocate memory on the *HEAP*":**

 * *dyanmic strings require `%`.

```
-- Fixed-size immutable array (on STACK)
VAR coords = [1, 2, 3];
coords.push!(4);              -- COMPILER ERROR: immutable and fixed

-- Fixed-size mutable array (on STACK)
MUTABLE items = [1, 2, 3];
items.push!(4);               -- COMPILER ERROR: items is MUTABLE, not dynamic
items.set!(0, 99);            -- OK: can mutate elements
items.set!(4, 99);            -- COMPILER ERROR: cannot set an index larger than the size of a fixed array
items.set!(4, 99) OR PASS;    -- COMPILER ERROR: 4 > 3, this will ALWAYS error, and NEVER pass.
items.set!(getIdx(), 99);     -- COMPILER ERROR: Out of bounds (potentiall).
items.set!(getIdx(), 99) OR PASS; -- OK: will do something if getIdx() returns BEWTEEN 0 AND 2.

-- Dynamic mutable array (on HEAP)
MUTABLE items = %[1, 2, 3];   -- Created on HEAP => Slower than stack, but (nearly) unbound in size.
items.push!(4);               -- OK: size becomes 4. This **CAN** run-time error on Out-of-Memory. BEWARE!
items.set!(0, 99);            -- OK: can mutate elements of determined size
items.set!(10, 99);           -- COMPILER ERROR: Out of bounds.
items.set!(getIndex(), 99);   -- COMPILER ERROR: Out of bounds (potentially).

-- Fixed-size mutable array (on HEAP)
MUTABLE items : Number[*] = %[1, 2, 3]; -- Created on HEAP => needlessly slow for the given size, but okay

-- Dynamic mutable array (on STACK)
MUTABLE items : Number[] = [];  -- Dynamic List, created on STACK => FAST but VERY limited in size.
items << 1;                    -- COMPILER ERROR: stack overflow (possible)
items << 1 OR PASS;            -- OK: will succeed

FOR i IN (1..=2**64) DO
  items << i OR PASS;          -- OK: **BUT** you'll only end up with 2**14 or so items.
END

-- Dynamic by default
MUTABLE items = %[];           -- Created on HEAP => SLOW but (nearly) unlimited in size.
FOR i IN (1..=2**64) DO
  items << i;                  -- OK: you'll end up with all your items
END

MUTABLE items = %[];           -- Created on HEAP => SLOW but (nearly) unlimited in size.
FOR i IN (1..=2**1000) DO
  items << i;                  -- OK: but you'll probably OOM
END
-- The Compiler protects the STACK (Logic Integrity).
-- The OS protects the HEAP (Resource Availability).


VAR str = "hello, worl";
str.concat!(0, "d");          -- COMPILER ERROR: immutable and fixed

MUTABLE str = "hello, worl";
str.concat!(0, "d");          -- COMPILER ERROR: str is MUTABLE, not dynamic

MUTABLE str = %"hello, worl";
str.concat!(0, "d");          -- OK: on heap, *could* OOM - BEWARE!


MUTABLE str : String[] = "";  -- Dynamic string, created on STACK => FAST but VERY limited in size.
FOR i IN (1..=2**64) DO
  str.concat!("x") OR PASS;   -- OK: but you'll only end up with 2**14 or so chars in your string.
END


VAR str = %"hello, worl";     -- OKAY, but needless slow, as it's created on the heap, rather than the stack.
```

**Key takeaways**

 * Heap arrays are *DYNAMIC* by default.
 * Stack arrays are *FIXED* (to size at initialization) by default.

### Array Types
```
T[n]     -- Fixed size n (exact)
T[*]     -- Fixed size, determined at runtime
T[]      -- Dynamic size (can grow/shrink - not applicable to IMMUTABLE VAR)
```

**Examples:**
```
-- Fixed size, immutable binding
VAR coords : Float64[3] = [0.0, 1.0, 2.0];

-- Fixed capacity, mutable binding
MUTABLE buffer : UInt8[100] = [];
buffer.push!(1);                   -- Can grow up to capacity

-- Dynamic size, mutable binding
MUTABLE list : UInt64[] = %[1, 2, 3];
list.push!(4);                     -- Can grow indefinitely


MUTABLE list : UInt64[100] = %[1, 2, 3]; -- compiler error, don't assign a DYNAMIC list to a fixed-size list. Either change the fixed-size from [100] to Dynamic [], or remove the `%` sigil -- which signifies a dynamic heap object.
```

### Type Inference for Arrays
```
VAR fixed = [1, 2, 3];        -- Type: UInt64[3] (fixed size)
MUTABLE fixed = [1, 2, 3];    -- Type: UInt64[3] (fixed size)
MUTABLE dynamic = %[1, 2, 3]; -- Type: UInt64[] (dynamic size)

VAR fixed = [2, 1.0, 3] ;     -- Type: Float64[3] (fixed size)

VAR dynamic = %[1, 2, 3];     -- Type: UInt64[] (dynamic size, on heap, slow, doesn't really make sense, but allowed)
```

**NOTE:** The default type for array values IS NOT Number

 * Arrays are designed by default to run incredibly fast in native libraries like BLAS/Torch, etc.

### Structs
```
STRUCT Point {
  x: Float64,
  y: Float64
}

STRUCT Person {
  name: String,
  age: UInt8,
  scores: UInt32[5]           -- Fixed-size array allowed
}

-- Instantiation
VAR p = Point{ x: 1.0, y: 2.0 }; -- created on STACK

-- Note well: a struct is always fixed-size in the stack
-- Even if some of it's data `scores` is on the HEAP.
VAR person = Person{{
  name: "Alice",
  age: 30,
  scores: %[100, 95, 87, 92, 88]
}};

VAR p2 = %Point{ x: 2.0, y: 3.0 }; -- created on HEAP, necessary for recursive structures!

-- Imagine this binary tree node
STRUCT Node {
  left: %Node, -- OK: Recursive structures MUST exist on the HEAP, otherwise instant OOM
  right: %Node
}

STRUCT Node {
  left: Node, -- COMPILER ERROR: Recursive structures MUST exist on the HEAP!
  right: Node
}


```

 * Structs are designed for cache locality.
 * No `%` means no cache miss!

**Struct Restrictions:**
- ✅ Fixed-size arrays: `T[n]`
- ✅ Pointers to dynamic arrays: `%T[]`
- ❌ Dynamic arrays inline: `T[]` (unknown size)
- ❌ Variable size inline: `T[*]` (unknown size)


### Function Returns: HEAP vs STACK: `GIVE`

CHEAT handles memory gracefully, by wiping clean the memory used by a function after it completes.

 * This presents a problem, if you want to return a HEAP object.
 * The HEAP object will die when the function completes.
   * You cannot return it, otherwise you'd return a pointer to garbage.
 * Therefore, you must SAVE the return object.
   * However, you can't just SAVE it forever. That would be a memory leak.
 * You must TRANSFER it to the callee, who will automatically destroy it when done.
   * `GIVE` handles this.

```
-- Must prefix HEAP returns with `%` for consistency
FN %stringCypherMaker(limit : Int64) -> %String[]
  MUTABLE s = %"";
  FOR i IN (1..=limit) DO
    s.concat!((i XOR 5).to_s);
  END

  -- We are transferring OWNERSHIP of the heap memory to the caller.
  -- 'GIVE' prevents the automatic cleanup that usually happens here.
  RETURN GIVE s;
END
-- SCOPE END: Because we used GIVE, 's' is NOT freed.
-- It survives and moves to the caller.

VAR myHeapStr = %stringCypherMaker(10_000_000); -- it is clear you have a HEAP object, and that ownership was accepted.
```

Let's see what would happen without `GIVE`:

```
FN stringCypherMaker(limit : Int64) -> %String[]
  MUTABLE s = %"";
  FOR i IN (1..=limit) DO
    s.concat!((i XOR 5).to_s)
  END
  RETURN s; -- COMPILER ERROR: Not allowed
END
-- SCOPE END: death
-- `s` would be a pointer to nothing (dangling pointer / use after free).
-- This would be a run-time error, NOT ALLOWED!


VAR stackStr = stringCypherMaker(10_000_000); -- I want a stack object, but was given a (dangling) pointer to a heap object.
print(stackStr); -- Run-time error, NOT ALLOWED!
```

### Function Inputs: HEAP vs STACK: `TAKES`

CHEAT treats pointers like an interpreted language (e.g., Ruby or Python).

 * **Pass by Reference:** When you call a function with a large object, you do not `COPY` the data. You pass a `Pointer` to it.
   * In C, this is a `Pointer`. In Rust, this is a `Borrow`.
   * In CHEAT, this happens automatically behind the scenes.
 * **The Ownership Problem:** By default, the function can read/write the object, but the CALLER keeps "Ownership" (responsibility to free it).
 * **The Data Structure Dilemma:**
   * If a function inserts an object into a Tree or List, that Tree needs to *own* the object.
   * If the **caller** *also* still owns it, the **caller* will destroy it when its scope ends.
   * The Tree would then hold a pointer to dead memory.
     * *Dead memory means runtime errors, and runtime errors are NOT allowed!*
 * **The Solution:** You must SURRENDER the object to the function.
   * `TAKES` handles this in the function definition.
   * `GIVE` handles this at the call site.

```
-- 'TAKES' warns the compiler: "I am assuming full responsibility for this memory."
FN addChild!(MUTABLE parent: Node, TAKES child: %Node) ->
  parent.list << child;
  -- function ends.
  -- We do NOT free 'child' here, because it is now part of 'parent'.
  -- When 'parent' eventually dies, it will kill 'child'.
END

MUTABLE root = %Node{};
MUTABLE leaf = %Node{};

-- We must use GIVE to satisfy the TAKES requirement
addChild!(root, GIVE leaf);  -- COMPILER ERROR: leaf.print(); -- Variable 'leaf' is dead. You GAVE it away!
```

Let's see what would happen without `TAKES`:

```
FN addChild!(MUTABLE parent: Node, child: Node) ->
  -- No TAKES
   parent.list << child;
  -- Function ends. The function was just "borrowing" child.
END
-- SCOPE END: death.
-- 'leaf' was owned by this block. It is now destroyed (freed).


MUTABLE root = %Node{};
MUTABLE leaf = %Node{};
addChild!(root, leaf);
-- 'root' now contains a pointer to the memory where 'leaf' USED to be.
root.printChildren(); -- Run-time error (Use After Free). NOT ALLOWED!
```

In CHEAT, functions do not specify whether they acccept HEAP objects or STACK objects.

  * 99% of the time, your function will work with either (a pointer/borrow).
  * If your function needs to `TAKE` ownership, it *must* take a HEAP object.
    * *Why?* You cannot "take" a stack object because it is physically bound to the caller's stack frame. It cannot survive the caller.

```

FN addChild!(MUTABLE parent: Node, TAKES child: Node) ->
  -- COMPILER ERROR: You can only `TAKE` HEAP objects.
END

FN addChild!(MUTABLE parent: Node, TAKES child: %Node) ->
  -- OK
END
```

#### Why `GIVE` is explicit?

CHEAT could infer that a CALLER must GIVE based on the function signature. But this would lead to confusion:

```
MUTABLE root = %Node{};
MUTABLE leaf = %Node{};

addChild!(root, leaf);

print(leaf.name); -- COMPILER ERROR: Variable `leaf` is dead. You GAVE it away!
-- USER: What??? I didn't GIVE anything away!
```

Compare to:

```
MUTABLE root = %Node{};
MUTABLE leaf = %Node{};

addChild!(root, GIVE leaf);

print(leaf.name); -- COMPILER ERROR: Variable `leaf` is dead. You GAVE it away!
-- USER: Oh, right. I see that on the line above.
```

#### What happens when you want to GIVE a STACK object?

If you have a stack object but need to pass it to a function that TAKES ownership, you must promote it to the Heap using the `%` sigil AND `COPY` it.

```
FN saveToDatabase(TAKES val: %String) ...

VAR tinyStackStr = "alice";

-- Error: specific types don't match (Stack vs Heap)
saveToDatabase(GIVE tinyStackStr);

-- OK: We create a heap copy on the fly
saveToDatabase(GIVE %COPY(tinyStackStr));

print(tinyStackStr); -- OK: You created a COPY
```

 * Again, the `COPY` keyword *could* be inferred.
 * However, in CHEAT, we prefer the user to expressly be aware of memory.
   * We pass-by-reference implicitly so that you don't COPY implicitly.
   * Therefore, when `GIVING` stack objects, we also do not want to implicitly copy them.
   * Therefore, you must `GIVE %COPY()`
   * `COPY` by default would return a STACK object - just as a `""` and `[]` by default are STACK objects.
   * `%COPY` returns a HEAP object.

---

## Slices and Borrowing

**The `&` sigil means "borrow/reference":**


### Creating Slices
```
VAR data = [0, 1, 2, 3, 4, 5];
VAR slice = &data[1..<3];        -- Immutable slice: [1, 2]
MUTABLE slice = &data[1..<3];    -- COMPILER ERROR: You cannot create a MUTABLE view of an IMMUTABLE object.

MUTABLE data = %[0, 1, 2, 3, 4, 5];
MUTABLE slice = &data[0..=3];    -- Mutable slice: [0, 1, 2, 3]
```

### Slice Syntax
```
&arr[0..<5]    -- Elements 0-4 (exclusive: less than 5)
&arr[0..=5]    -- Elements 0-5 (inclusive: equals 5)
&arr[..<5]     -- Start to 4
&arr[5..]      -- 5 to end
&arr[..]       -- Entire array
```

**Mnemonic:** Read the symbols!
- `..<` = "to less than" (exclusive)
- `..=` = "to equals" (inclusive)

### Borrowing Rules

**Rust-style borrow rules:**
```
VAR data = [1, 2, 3];
VAR slice1 = &data[0..<2];     -- Immutable borrow
VAR slice2 = &data[1..<3];     -- OK: multiple immutable borrows

MUTABLE data = %[1, 2, 3];
VAR slice = &data[0..<2];      -- Immutable borrow
SET data = [4, 5, 6];         -- COMPILER ERROR: data is borrowed
FREE slice;
SET data = [4, 5, 6];         -- OKAY

MUTABLE data = %[1, 2, 3];
MUTABLE slice = &data[0..<2];  -- Exclusive mutable borrow
VAR slice2 = &data[1..<3];     -- COMPILER ERROR: already mutably borrowed
```

**Key Rules:**
- Many immutable borrows OR one mutable borrow
- Original is locked while borrowed
- Slices cannot outlive their source (arena-based)

### Function Parameters with Slices

* Implicitly, any function that takes an array can take a Slice.
* You don't need to do anything to be able to accept the real array or a Slice (or a Stream).

```
FN sum(numbers : UInt64[*]) -> UInt64 ->
  VAR total = 0;
  FOR num IN numbers ->
    SET total = total + num;
  END
  RETURN total;
END

VAR data = [1, 2, 3, 4, 5];
VAR result = sum(data);          -- Passes a pointer / slice by default
VAR partial = sum(data[0..<3]);  -- Explicitly pass a slice - OKAY
```

---

## Atomics

**The `^` sigil means "atomic" (shared across threads):**

### Creating Atomics
```
VAR counter^ = %0;           -- Atomic integer - note the %0 - this integer is special, it lives on the HEAP
GLOBAL totalRequests^ = %0;  -- Global atomic

VAR counter = %0             -- COMPILER ERROR, you cannot create a primitive on the HEAP. If you don't know what the HEAP is, you probably want to remove the `%` sigil. If you want to create an `Atomic`, use the `^` suffix.
```

### Atomic Operations

All atomic operations require `!` suffix (mutation):
```
counter^.increment!();
counter^.decrement!();
counter^.add!(5);
counter^.store!(10);
counter^.compareAndSwap!(expected, new);

VAR value = counter^.get();   -- Atomic read (no mutation, no !)
```

### Using Atomics in Functions
```
FN worker(counter^) ->
  counter^.increment!();
END

VAR count^ = %0;
PARALLEL FOR i IN (1..1000) ->
  worker(count^);
END
PRINT(count^.get());          -- Prints 1000
```

### Why Atomics Can Escape Arenas
```
FN createCounter() -> ^UInt64 ->
  VAR counter^ = %0;
  RETURN counter^;            -- OK: atomics can escape (ref-counted)
END

VAR globalCounter^ = createCounter();
```

### TODO:
Atomics use reference counting or garbage collection to outlive their arena.

---

## Control Flow

### If/Then/Else
```
IF x > 5 THEN
  PRINT("Greater");
ELSE_IF x == 5 THEN
  PRINT("Equal");
ELSE
  PRINT("Less");
END
```

### Loops
```
-- For loop
FOR (i=0; i < 10; i++) DO
  PRINT(i);
END
-- Note that for speed for loop variables (`i`) are of type **Int64**

-- For loop with array
VAR items = %[1, 2, 3];
FOR item IN items DO
  PRINT(item);
END

-- WHILE loop
MUTABLE i = 0;
WHILE i < 10 DO
  PRINT(i);
  SET i = i + 1;
END

-- BREAK and CONTINUE
FOR i IN (1..=100) DO
  IF i == 50 THEN BREAK; END
  IF i % 2 == 0 THEN CONTINUE; END
  PRINT(i);
END
```

---

## Error Handling

### The `!!` Operator

**`!!` means "panic on error" (unhandled error):**
```
VAR data : UInt8[10] = %[0] * 10;
VAR idx = getUserInput();

-- Unsafe operation with panic
data.set!(idx, 99)!!;         -- Panics if idx out of bounds
```

### The `OR` Operator
```
-- Provide default value
VAR value = data.get(idx) OR 0;

-- Continue on error
data.set!(idx, 99) OR PASS;

-- Return on error
FN process(data, idx)!! ->
  data.set!(idx, 99) OR RETURN;
  -- continues only if successful
END

-- NOTE the explicit `!!` in the function name.
-- Users know immediately this function can error.
```

### Safe Patterns
```
-- Check bounds first
IF idx < data.length() THEN
  data.set!(idx, 99);          -- compiler error, does not know this is safe
  data.set!(idx, 99) OR PASS;  -- OKAY
END

-- Handle error explicitly
FN getMyData(data, idx) ->
  RETURN data.get(idx);
CATCH
  print "FAILED TO CATCH";
  RETURN %MyData::DEFAULT;
END
```

 * Every function must return EXACTLY one type.
 * That means you must return a suitable default.
   * OR, explicitly raise an error.

```
-- Fail explicitly
FN getMyData(data, idx)!! ->
  RETURN data.get(idx)!!
END
-- Note the `!!` in the function signature, and in the function call.
```

---

## Concurrency

### Parallel Loops
```
VAR data = [1, 2, 3, 4, 5];

PARALLEL FOR item IN data ->
  process(item);              -- Each iteration runs in parallel
END
```

### Parallel Map
```
VAR results = data
  s> PARALLEL map(%(x) -> x * 2);
```

### Restrictions in Parallel Contexts
```
MUTABLE counter = 0;

PARALLEL FOR i IN (1..100) ->
  SET counter = counter + 1;  -- COMPILER ERROR: mutable capture in parallel
END

-- Use atomics instead:
VAR counter^ = %0;

PARALLEL FOR i IN (1..100) ->
  counter^.increment!();      -- OK: atomic operation
END
```

### Atomic Captures
```
FN parallelProcess(data) ->
  VAR progress^ = %0;

  PARALLEL FOR item IN data ->
    FN worker() USE(progress^) ->
      processItem(item);
      progress^.increment!();
    END
    worker();
  END

  RETURN progress^.get();
END
```

---

## Streams and Pipelines

### SMOOTH Operator `s>` (the pipeline operator)
```
VAR result = data
  s> filter(%(x) -> x > 5)
  s> map(%(x) -> x * 2)
  s> sum();
```

### Pipeline Binding with `@`

**The `@` sigil means "bind intermediate result in pipeline":**
```
VAR result = data
  s> parse AS @parsed
  s> validate AS @valid
  s> transform
  s> merge(@parsed, @valid);  -- Reference earlier stages
```

**Scope:** `@` bindings only exist within the pipeline expression.

### Streams
```
-- Auto-collection (default)
VAR result = data
  s> map(%(x) -> x * 2)
  s> filter(%(x) -> x > 10);  -- Automatically collects to array

-- Explicit stream
VAR stream = data
  s> map(%(x) -> x * 2)
  s> filter(%(x) -> x > 10)
  s> STREAM;                  -- Returns lazy stream

-- OR
VAR stream = ASYNC data s> map(%(x) -> x * 2);
VAR stream : Stream<Int64> = data s> map(...);

-- Force collection
VAR result = stream |> COLLECT;
VAR result = SYNC stream;
```

### Lambda Functions
```
%(x) -> x * 2;                 -- Single parameter
%(x, y) -> x + y;              -- Multiple parameters
%() -> 42;                     -- No parameters
%(x) -> {                      -- Multi-line
  VAR result = x * 2;
  RETURN result;
};
```

 * Note the `%`. Lambdas are created as memory on the HEAP.

---

## Memory Model

### Arena-Based Allocation

Every function has its own memory arena:
```
FN outer() ->
  VAR data = [1, 2, 3];       -- Allocated in outer's arena

  FN inner() ->
    VAR temp = [4, 5, 6];     -- Allocated in inner's arena
  END

  inner();
  -- inner's arena is wiped here

END
-- outer's arena is wiped here
```

### What Can Escape Arenas

✅ **Can escape:**
- Atomics (`^`) - reference counted
- Return values (written directly to caller's arena)

❌ **Cannot escape:**
- Slices - must not outlive source
- Regular allocated values (arena-bound)

### The `%` HEAP Allocator
```
VAR x = 5;                                -- No allocation (scalar / primitive)
VAR x = %5;                               -- COMPILER ERROR: Don't create primitives on the HEAP. Remove the `%` sigil.
VAR x^ = %5;                              -- OK: Atomics MUST be on the HEAP, see section above.
MUTABLE list = %[1, 2, 3];                -- Allocates dynamic, mutable HEAP array
VAR list = %[1, 2, 3];                    -- Allocates fixed, immutable HEAP array
MUTABLE string = %"";                     -- Allocates dynamic, mutable HEAP string
VAR string = %"";                         -- Allocates fixed, immutable HEAP string
VAR myObj = %MyClass{};                   -- Allocates an immutable struct on the HEAP
MUTABLE myObj = %MyClass{};               -- Allocates an mutable struct on the HEAP.
```

### Safe Navigator

What happens if you want to do something like:

```
VAR result = arr[4].get("my key").items[10] OR PASS;
```

 * **Problem:** If arr[4] fails, you still try to call .get() on... what? The error?
   * That would be a compiler error. It doesn't make sense.
   * But it *is* how we like to write code.

You'd have to write this:

```
VAR step1 = arr[4] OR PASS;
IF step1 THEN
   VAR step2 = step1.get("my key") OR PASS;
   IF step2 THEN
     VAR result = step2.items[10] OR PASS;
   END
END
```

No thanks! We can safe navigate `?.` like we SMOOTH operate `s>`:

```
VAR result = arr[4]?.get("my key")?.items[10] OR PASS;
```

This could be expressed as a SMOOTH operation, but save navigation is more efficient here:

```
VAR result = arr
  s> get(4)
  s> get("my key")
  s> get_items -- ONLY if exists
  s> get(10) OR PASS;
```

**Verdict**
 * `?.` is likely what you want to traverse *through* an object.
   * `users[10]?.address?.city`
 * `s>` is likely what you want for a multi-step transformation.
   * `input s> parse s> fetch s> respond`

Since there are no result objects, like the SMOOTH operator, the Safe Navigator has: Zero overhead, zero allocations, total safety.

---

## Quick Reference: Sigils

| Sigil | Meaning | Example |
|-------|---------|---------|
| `%` | Allocate memory on the heap | `%[1, 2, 3]` |
| `&` | Borrow memory | &data[1..=10] |
| `^` | Atomic (thread-safe) | `counter^.increment!()` |
| `@` | Pipeline binding | `s> process AS @p` |
| `!` | Mutation suffix | `list.push!(item)` |
| `?` | Predicate suffix | `list.includes?(item)` |
| `!!` | Panic on error | `data.get(i)!!` |
| `_` | Placeholder | `s> SELECT _.orders |

---

## Quick Reference: Operators

| Operator | Meaning | Example |
|----------|---------|---------|
| `..<` | Exclusive range (less than) | `arr[0..<5]` → 0-4 |
| `..=` | Inclusive range (equals) | `arr[0..=5]` → 0-5 |
| `..` | Open range | `arr[5..]` → 5 to end |
| `s>` | SMOOTH Pipeline | `data s> map s> filter` |
| `?.` | Save Navigate | `data?.items?.count` |
| `OR` | Error handling | `x.get(i) OR default` |

## Quick Reference: Memory Ownership Table

| Syntax | Ownership | Lifetime | Can Escape? | Notes |
|--------|-----------|----------|-------------|-------|
| `VAR x = 5` | Caller | Function scope | ✅ (copied) | Scalar values are copied on return |
| `VAR x = [1,2,3]` | Caller | Function scope | ✅ (copied) | Fixed-size stack arrays are copied |
| `VAR x = %[1,2,3]` | Caller | Arena | ❌ (arena-bound) | Heap arrays die when arena is wiped |
| `VAR x = &arr[..]` | Borrowed | Until borrow ends | ❌ (borrowed) | Slice cannot outlive source |
| `VAR x^ = %0` | Ref-counted | Ref count → 0 | ✅ (ref-counted) | Atomics use reference counting |
| `RETURN x` | Caller | Caller's arena | ✅ (moved) | Value written to caller's arena |
| `RETURN GIVE %x` | Caller | Caller's arena | ✅ (transferred) | Heap ownership transferred to caller |
| `FN f(TAKES x)` | Callee | Callee's control | ✅ (taken) | Caller surrenders ownership |
| `MUTABLE x = %[]` | Caller | Arena | ❌ (arena-bound) | Mutable heap data still arena-bound |
| `VAR x = %Point{}` | Caller | Arena | ❌ (arena-bound) | Heap-allocated struct (for recursion) |
| `GLOBAL x^ = %0` | Global | Program lifetime | ✅ (global) | Global atomics live until program ends |


## Quick Reference: Higher-Order Functions

* CHEAT prefers SQL-like syntax where possible

```
SELECT     -- Transform/project (like map)
WHERE      -- Filter (like filter)
UNNEST     -- Flatten (like flatMap)
EACH       -- Iterate with side effects (like forEach)
INDEX      -- GROUP BY / turn into a HashMap
SORT       -- ...
```

These give you placeholder values and create an implicit lambda:

```
VAR bill = users AS @u
  s> flatmap( %(x) -> x.orders )
  s> map( %(x) -> x.price * @u.discount )
  s> reduce(0, %(acc, x) -> acc + x );
```

Can be written as (and is preferred):

```
VAR bill = users AS @u
  s> UNNEST _.orders
  s> SELECT _.price * @u.discount
  s> reduce(0, %(acc, x) -> acc + x );
```

 * Note the `_` as the implicit passed in-variable to the implicit lambda.

---

## Complete Example
```
-- A parallel word counter with atomics

STRUCT WordCount {
  word: String,
  count: UInt64
}

FN countWords(text : String) -> WordCount[] ->
  VAR words = text.split(" ");
  VAR counts^ = %HashMap();

  words
    s> PARALLEL each(%(word) -> {
      counts^.incrementKey!(word);
    });

  RETURN counts^
    s> entries AS @pairs
    s> SELECT WordCount {
         word: _.key,
         count: _.value
       }
    s> SORT(a, b) -> a.count - b.count; -- NOTE that SORT does not take a lambda `%`.

-- SQL-like HIGHER-ORDER Array functions DO NOT have the overhead of creating arenas.
-- No searching through the heap, chasing pointers.
-- They are made for *speed*.
END

-- Usage
VAR text = "hello world hello rust world";
VAR results = countWords(text);

FOR wc IN results ->
  PRINT("{wc.word}: {wc.count}");
END
```

---

## Memory Safety Guarantees

✅ **This language guarantees:**
- No use-after-free (arena-based + borrow checking)
- No data races (atomics only for shared mutation)
- No null pointer dereferences (no null)
- No buffer overflows (bounds checking)
- No iterator invalidation (borrow rules)
- No memory leaks (arena cleanup)

**Trade-off:** Less flexible than Rust, but substantially simpler to learn and use.

 * Rust philosophy is that pre-mature optimization is the root of all evil.
 * CHEAT gives you Rust guarantees, allows for *near* Rust speed when fully optimized.
   * But makes the process substantially simpler.

---

## Design Principles Summary

1. **Immutable by default** - safety through immutability
2. **Explicit mutation** - `MUTABLE` and `!` make changes visible
3. **Arena-based** - automatic memory management without GC
4. **Borrow checking** - Rust-style safety for references
5. **Atomic primitives** - safe concurrent programming
6. **Pipeline-oriented** - functional data transformation
7. **Clear error handling** - `OR` and `!!` make errors explicit
8. **Self-documenting** - sigils and keywords explain behavior

---

*This language prioritizes being **correct first, fast second** - making it impossible to write unsafe code while keeping syntax substantially simpler than Rust.*
