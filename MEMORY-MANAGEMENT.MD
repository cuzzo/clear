# Memory Magic: How CLEAR "Clears" Memory Management

Most languages give you a choice:

  1. *Manual Memory Management (C/Zig/Rust):* Fast, but you spend 50% of your time fighting the compiler or debugging segfaults.
  2. *Garbage Collection (Java/Python/Go):* Easy, but you suffer unpredictable latency spikes ("Stop the World") and high RAM overhead.

*CLEAR chooses Option 3: Arena-Based Memory with Page Swizzling.*

This document explains exactly how we achieve "Safety like Java" with "Speed like C," and how we solve the "Escape Problem" that usually makes Arena allocators difficult to use.

## 1. The Baseline: The Simple (Dumb) Arena

In CLEAR, every function call gets its own Arena. Think of an Arena as a dedicated Notebook for that specific function call.

How it works:

  1. Allocation: When you create a variable (VAR x = ...), CLEAR simply writes it on the next blank line of the notebook. This is the fastest possible way to allocate memory (incrementing a pointer).
  2. Deallocation: When the function ends, we don't erase line-by-line. We just throw the notebook in the incinerator.

Allocation is O(1). Deallocation is O(1). Zero fragmentation.

### 2. The Trap: The "Escape Problem"

If a child function allocates data in its own notebook, that data is destroyed when the child returns.

*The Scenario:*

```CLEAR
FN makeUser() -> User ->
  VAR name = "Alice";       -- Allocated in makeUser's Arena
  RETURN User{ name: name };
END
```

### The "Slow" Fix (Deep Copy)

We could pause execution and copy "Alice" from Arena B to Arena A.

 * Small Data: Fine.
 * Big Data (1GB Video): Terrible. This kills performance.

## 3. The CLEAR Solution A: Destination Passing (RVO)

For known return types (Structs, Fixed Arrays), CLEAR uses Destination Passing Style.

*The Trick*

  * `Main` knows `makeUser` is going to return a `User` struct.
  * So, `Main` reserves a slot in **Arena A** before calling `makeUser`.
  * It effectively tells the child: **"Don't write the answer in your notebook. Write it directly in mine."**

 1. `makeUser` calculates the result.
 2. Instead of allocating the result in **Arena B**, it writes directly to the pointer provided by **Arena A**.
 3. Arena B is wiped.
 4. The result is safe in Arena A. **Zero Copying**.

## 4. The CLEAR Solution B: Page Handoffs ("The Loose Leaf")

 * RVO works for fixed sizes.
 * But what if `makeUser` generates a **Dynamic String** or **List of unknown size**??
 * It can't write into A because it doesn't know how much space to ask for.

CLEAR Arenas are Linked Lists of Pages (usually 4KB or 64KB blocks). When the compiler sees a large dynamic object being returned, it allocates that object on a Fresh Page (a loose leaf paper), separate from the standard scratchpad.

When the function returns, we don't copy the data. We simply **change the owner of the page.**

 * **Cost:** Two pointer swaps => O(1).
 * **Result:** A 1GB array moves from Child to Parent instantly without copying a byte.

### 5. Capabilities: Life Beyond the Arena

When an object needs to outlive its creator or be shared across threads, we use **Capabilities**.

| Capability | Purpose |
|------------|---------|
| `multiowned` | Shared ownership on a single thread (Rc). |
| `shared` | Shared ownership across threads (Arc). |
| `indirect` | Explicit heap allocation (Box). |

Capabilities are properties of the storage, not the type. Functions take the raw Type (e.g., `User`), while the caller manages the capability.

```CLEAR
VAR sharedU = SHARE(User.new()); -- Acquire 'shared' capability
process(sharedU);                -- Function takes raw 'User'
```

### 6. Solving Recursion: The `indirect` Capability

Recursive structures like Trees or Linked Lists are handled using the `indirect` capability.

```CLEAR
STRUCT Node {
  value: Int64,
  left: indirect Node,
  right: indirect Node
}
```

The `indirect` keyword tells CLEAR to allocate the child node on the heap rather than trying to fit an infinite structure on the stack.

## Summary

*   **Default:** Objects live in the Arena (Stack-like performance).
*   **Returns:** Handled via Destination Passing (RVO) or Page Swizzling (O(1)).
*   **Long-lived / Shared:** Use `shared` or `multiowned` capabilities.
*   **Recursive / Large:** Use the `indirect` capability.

**CLEAR doesn't break the laws of physics. It just manages the paperwork so you don't have to.**
