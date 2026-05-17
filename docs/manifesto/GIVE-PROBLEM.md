# THE GIVE PROBLEM

In CLEAR, we separate **Types** from **Capabilities**.

*   **Type:** What the data is (e.g., `User`).
*   **Capability:** How the data is accessed (e.g., `affine`, `shared`).

By default, objects in CLEAR are **affine** (meaning they can only be used once, and passing them to a function "borrows" them). When a function needs to take ownership of an object (e.g., to store it in a long-lived list), it must explicitly `TAKES` it.

## The Friction: `GIVE` vs. `COPY`

If you have an affine object and you need to pass it to a function that `TAKES` it, you have two choices:
1.  **GIVE it:** Transfer ownership. The original variable becomes "dead" and can no longer be used.
2.  **COPY it:** Create a duplicate. The original variable remains "alive" and can still be used.

```CLEAR
STRUCT User { name: String }

FN addToCache(TAKES u: User) RETURNS Void ->
  -- This function now owns 'u'
  RETURN;
END

u = User{ name: "Alice" };
addToCache(GIVE u);           -- Explicit Move
print(u.name);                -- COMPILER ERROR: u is dead.

u2 = User{ name: "Bob" };
addToCache(COPY u2);          -- Explicit Copy
print(u2.name);               -- OKAY: u2 is still alive.
```

### Why this is Better than Rust

In Rust, "moving" or "copying" is often implicit based on the type (e.g., `i32` is `Copy`, `String` is not). This makes it difficult to reason about whether a variable is still alive after a function call without knowing the exact implementation details of the type.

In CLEAR, the **developer's intent** is always explicit:
*   If you see `GIVE`, you know the variable is gone.
*   If you see `COPY`, you know you're paying a performance cost to keep it.
*   If you see neither, it's a **Borrow** (safe and fast).

## Summary

| Keyword | Meaning | Result |
| :--- | :--- | :--- |
| `GIVE` | Move ownership | Original is dead, zero-cost transfer |
| `COPY` | Duplicate data | Original is alive, high-cost duplicate |
| (None) | Borrow | Original is alive, zero-cost reference |

**CLEAR optimizes for local reasoning and explicit intent, making ownership semantics intuitive for everyone.**
