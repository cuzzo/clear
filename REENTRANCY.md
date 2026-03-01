# REENTRANCY ATE MY BABY

## WITH blocks are non-reentrant

In CLEAR, when you open a `WITH` block on an object to acquire a capability (like mutation or sharing), no other `WITH` block for that same object can start until the first one finishes.

  * This applies to other threads, but crucially, it also applies to your own recursive functions or callbacks.
  * This restriction gives you Rust-level determinism for mutable access to shared objects, with significantly less cognitive overhead.

### The Mental Model: Capabilities are Edges

In CLEAR, we separate **Types** from **Capabilities**:
*   **Types** (e.g., `Player`) are passed into functions.
*   **Capabilities** (e.g., `shared:locked`, `alwaysMutable`) are managed at the "edges" using `WITH` blocks.

**The Rule:** Functions take the **Type**, not the **Capability**. You must unwrap the capability using `WITH` before calling the function.

```CLEAR
-- CLEAR's Solution: Unwrapping at the call site
WITH sharedPlayer AS player {
  -- 'player' is now the raw Type (User), unwrapped from its 'shared' capability
  damage!(player);               -- OKAY
  heal!(player);                 -- OKAY
  
  -- heal!(sharedPlayer);       -- COMPILER ERROR! 
  -- Functions take User, not shared:locked User.
}
```

This prevents the "Infinite Mirror" pattern where a function modifying an object accidentally tries to re-acquire a lock it already holds.

### Why this matters

Re-entrancy bugs (where state changes under your feet while you're in the middle of an operation) are the root of most concurrent complexity.

#### The Problem (Sheer Chaos):

In most languages (Java, C, Go, Swift), you cannot trust from one line of code to the next. While you are reading a list, another thread can `pop()` from it, causing your next line to crash with an `IndexOutOfBounds` error.

#### The CLEAR Solution: Scoped Sovereignty

By banning re-entrancy via `WITH` blocks, CLEAR guarantees that while you are inside that scope:
1.  **You are the sole owner** of that object's state.
2.  **No one else** (not other threads, and not your own callbacks) can touch it.

This turns a **global problem** (unpredictable concurrency bugs) into a **local problem** (simple logic).

### Comparison with Other Models

*   **Actor Model (Erlang/Go Channels):** Safe, but treats your RAM like a slow network cable. It often leads to "God Actors" that serialize your entire program.
*   **Rust (Borrow Checker):** Perfect safety, but high cognitive cost. Rust forces you to infect every function signature with lifetimes and capability types (like `Arc<RwLock<T>>`).
*   **CLEAR:** Gives you Rust's safety and performance, but keeps your functions "pure" by handling capabilities at the call site.

### Simplified Refactoring

In Rust, if you change an object from `Rc` (single-threaded) to `Arc` (multi-threaded), you must update every function signature that takes that object.

In CLEAR, you only change the capability at the definition site. Because your functions only take the raw Type (e.g., `User`), the rest of your codebase remains untouched. The "Refactoring Blast Radius" is zero.

---

### A final note on local reasoning

CLEAR optimizes for the **ROI on brain power**.

*   **Rust** optimizes for the toaster (minimum RAM/CPU at any cognitive cost).
*   **CLEAR** optimizes for the developer (maximum safety and speed with minimum cognitive load).

By enforcing explicit scopes for capabilities, CLEAR ensures that "poisoning" (restricting access to data) is always visible and local. You don't need to be a systems programming expert to write blazing-fast, thread-safe code. You just need to follow the `WITH` block.
