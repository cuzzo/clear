# Atomic Power: Shared Memory Without the Garbage Collector

In CHEAT, 99% of your data lives in **Arenas** (notebooks) that are incinerated when a function returns. This is fast and safe, but it has one flaw: **Data cannot survive the death of its creator.**

 * Sometimes, you need data to live longer than the function that created it.
 * Sometimes, you need data to be shared across multiple threads running in parallel.

**Enter the Atomic (`^`).**

## 1. What is an Atomic?

An Atomic is a piece of memory that lives in the Global Ether (the Heap), not in a specific function's notebook (the Arena).

It has two special superpowers:

 1. Immortality (Conditional): It survives as long as someone is holding a handle to it.
 2. Thread Safety: It can be safely mutated by multiple threads at the same time using the ! bang methods.

**The Sigil: `^`**

In CHEAT, any variable ending in `^` is an Atomic.

```
VAR counter^ = %0;          -- Create an atomic integer
counter^.increment!();      -- Thread-safe mutation
```

## 2. When do you NEED them?

You need Atomics when the "Birth -> Death" linear model of Arenas breaks down.

### Scenario A: The Background Job

You want to spawn a task that outlives the parent function.

```
FN trackLogin() ->
  -- If this were a normal VAR, it would die when trackLogin returns.
  VAR requestCount^ = %0;

  SPAWN %(requestCount^) ->
     -- This runs in the background for 5 seconds.
     -- It holds a handle to requestCount^, keeping it alive.
     network.send(requestCount^);
  END

  -- Function returns immediately.
  -- Normal variables die here.
  -- requestCount^ survives because the background job holds it.
END
```

### Scenario B: Shared State

You have 10 worker threads that need to update a single scorecard.

```
VAR score^ = %0;

PARALLEL FOR i IN (1..100) ->
   -- All threads safely increment the SAME memory address
   score^.increment!();
END
```

## 3. How CHEAT Handles Them: "The Magic Count"

CHEAT does not use a Tracing Garbage Collector (like Java/Go) that pauses your program to scan memory.

Instead, CHEAT uses **Deterministic Reference Counting.**

Every Atomic object has a tiny backpack holding a number (the Reference Count). This number represents how many people are holding a handle to it.

### Visualizing the Lifecycle

 * **Step 1: Creation** `VAR x^ = %Data();` CHEAT calls malloc (system heap) and sets Count = 1.

```
[ Global Heap ]
Address: 0x9999
+------------------+
| RefCount: 1      | <---- Main Function holds handle 'x^'
| Data: "MyData"   |
+------------------+
```

 * **Step 2: Sharing** `SPAWN %(x^) -> ...` The background thread grabs a handle. Count increments.

```
[ Global Heap ]
Address: 0x9999
+------------------+
| RefCount: 2      | <---- Main Function holds handle 'x^'
| Data: "MyData"   | <---- Background Thread holds handle 'x^'
+------------------+
```

 * **Step 3: Parent Exits** `Main` finishes. Its handle goes out of scope. Count decrements.

```
[ Global Heap ]
Address: 0x9999
+------------------+
| RefCount: 1      |      (Main is gone)
| Data: "MyData"   | <---- Background Thread still holding it
+------------------+
(Memory is NOT freed yet. It survives.)
```

 * **Step 4: Child Exits** The background thread finishes. Its handle goes out of scope. Count decrements to 0.

```
[ Global Heap ]
Address: 0x9999
+------------------+
| RefCount: 0      | <---- NO OWNERS
| Data: "MyData"   |
+------------------+
!!! INSTANT DESTRUCTION !!!
(free() is called immediately)
```

 * **The Result:** Zero "Stop the World" pauses. Memory is freed the exact microsecond it is no longer needed.

## 4. The Law: No Atomic Cycles

 * Reference counting has one fatal weakness: **Cycles.**
 * If A holds B, and B holds A, their RefCounts will never hit 0. They will leak memory forever.

Garbage Collected languages solve this by periodically stopping your program and scanning for cycles. CHEAT refuses to stop your program.

**Therefore, CHEAT enforces The Law:**

An Atomic **CANNOT** hold a reference to another Atomic.

### The Topology

This forces your memory to be a DAG (Directed Acyclic Graph). Data ownership always flows "Down" or "Across," never "Back Up."

**Allowed:**

```
      [ Global Config^ ]
          /      \
      [User^]  [User^]
```

*(A normal Struct can hold multiple Atomics, but an Atomic cannot hold them.)*

**Forbidden (Compiler Error):**

```
      [ Atomic A^ ]
           |
           v
      [ Atomic B^ ]  <--- ILLEGAL!
           |
           v
      [ Atomic A^ ]
```


**Why this is a Feature, not a Bug**

By forbidding cycles, CHEAT guarantees:

 * **No Memory Leaks:** It is mathematically impossible to leak an Atomic.
 * **No Deadlocks:** Since you can't create circular dependencies, you (mostly) avoid circular locking logic.
 * **No GC Pauses:** There's no need to scan the heap.

## Summary

| Feature | Arena (`%`) | Atomic (`^`) |
| :--- | :--- | :--- |
| **Location** | Stack / Local Notebook | Global Heap |
| **Lifetime** | Function Scope | Reference Counted |
| **Speed** | Blazing Fast ($O(1)$) | Fast (System Malloc) |
| **Concurrency** | Thread-Private (Safe) | Thread-Safe (Mutex/Atomic) |
| **Usage** | 99% of variables | Shared counters, Queues, Configs |
| **Cost** | Zero GC | Zero GC (Deterministic) |
