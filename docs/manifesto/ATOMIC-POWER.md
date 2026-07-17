# Atomic Power: Shared Memory Without the Garbage Collector

In CLEAR, 99% of your data lives in **Arenas** (notebooks) that are incinerated when a function returns. This is fast and safe, but it has one flaw: **Data cannot survive the death of its creator.**

 * Sometimes, you need data to live longer than the function that created it.
 * Sometimes, you need data to be shared across multiple threads running in parallel.

**Enter the 'shared' Capability and `shared:atomic`.**

## 1. What is the 'shared' Capability?

In CLEAR, we separate **Types** from **Capabilities**.

*   **Type:** What the object *is* (e.g., `User`).
*   **Capability:** How the object is *accessed* (e.g., `shared`).

The `shared` capability (Arc in Rust) allows an object to live in the **Global Heap**, survive outside its creator's arena, and be shared safely across threads.

```CLEAR
-- Acquisition: Acquire 'shared' capability
sharedU = SHARE(User.new());

-- Usage: Pass the 'raw' Type to functions
process(sharedU);
```

## 2. Atomics: Primitives in the Ether

For simple numeric types like counters, CLEAR uses the **`shared:atomic`** capability. An Atomic primitive lives in the Global Heap and can be safely mutated by multiple threads at the same time.

```CLEAR
counter = SHARE:atomic(0);      -- Create an atomic integer
counter.increment();           -- Thread-safe mutation
```

## 3. How CLEAR Handles Them: "The Magic Count"

CLEAR does not use a Tracing Garbage Collector (like Java/Go) that pauses your program. Instead, CLEAR uses **Deterministic Reference Counting**.

Every `shared` object has a tiny backpack holding a number (the Reference Count). This number represents how many people are holding a handle to it.

 * **Creation:** Count = 1.
 * **Sharing:** When you pass a `shared` object to a thread (`SPAWN`), Count increments.
 * **Drop:** When a thread finishes, its handle goes out of scope and Count decrements.
 * **Destruction:** The microsecond Count hits 0, the memory is freed instantly.

 * **The Result:** Zero "Stop the World" pauses. Memory is freed precisely when it's no longer needed.

## 4. The Law: No Shared Cycles

Reference counting has one fatal weakness: **Cycles.** If A holds B, and B holds A, their RefCounts will never hit 0. They will leak memory forever.

CLEAR refuses to stop your program to scan for cycles. Therefore, CLEAR enforces **The Law**:

**A `shared` object CANNOT hold a reference to another `shared` object.**

### The Topology

This forces your memory to be a **DAG** (Directed Acyclic Graph). Data ownership always flows "Down" or "Across," never "Back Up."

By forbidding cycles, CLEAR guarantees:
1.  **No Memory Leaks:** It is mathematically impossible to leak a `shared` object.
2.  **No Deadlocks:** You avoid the circular dependencies that often lead to circular locking.
3.  **No GC Pauses:** There's no need to scan the heap.

## Summary

| Feature | Arena (Default) | Shared / Atomic |
| :--- | :--- | :--- |
| **Location** | Local Arena | Global Heap |
| **Lifetime** | Function Scope | Reference Counted |
| **Speed** | Blazing Fast (O(1)) | Fast (System Malloc) |
| **Concurrency** | Thread-Private (Safe) | Thread-Safe |
| **Usage** | 99% of variables | Shared counters, Queues, Configs |
| **Cost** | Zero GC | Zero GC (Deterministic) |
