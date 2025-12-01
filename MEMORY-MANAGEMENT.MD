# Memory Magic: How CHEAT "Cheats" at Memory Management

Most languages give you a choice:

  1. *Manual Memory Management (C/Zig/Rust):* Fast, but you spend 50% of your time fighting the compiler or debugging segfaults.
  2. *Garbage Collection (Java/Python/Go):* Easy, but you suffer unpredictable latency spikes ("Stop the World") and high RAM overhead.

*CHEAT chooses Option 3: Arena-Based Memory with Page Swizzling.*

This document explains exactly how we achieve "Safety like Java" with "Speed like C," and how we solve the "Escape Problem" that usually makes Arena allocators difficult to use.

## 1. The Baseline: The Simple (Dumb) Arena

In CHEAT, every function call gets its own Arena. Think of an Arena as a dedicated Notebook for that specific function call.

How it works:

  1. Allocation: When you create a variable (VAR x = ...), CHEAT simply writes it on the next blank line of the notebook. This is the fastest possible way to allocate memory (incrementing a pointer).
  2. Deallocation: When the function ends, we don't erase line-by-line. We just throw the notebook in the incinerator.

### Visualizing the "Dumb" Arena

```
Function: main()
[ Arena A (Active) ]
+--------------------------------------+
| 0x00: [ VAR x = 10                 ] |
| 0x08: [ VAR y = 20                 ] |
| 0x16: [ <FREE SPACE STARTS HERE>   ] |
| ...                                  |
+--------------------------------------+
```


 * *The Benefit:* Allocation is O(1). Deallocation is O(1). Zero fragmentation.
 * *The Problem:* What happens when you want to return data?

### 2. The Trap: The "Escape Problem"

If a child function allocates data in its own notebook, that data is destroyed when the child returns.

*The Scenario:*

```
FN makeUser() -> User ->
  VAR name = "Alice";       -- Allocated in makeUser's Arena
  RETURN %User{ name: name };
END
```

The "Dumb" Execution (Runtime Crash)

  1. `main()` calls `makeUser()`.
  2. `makeUser()` writes "Alice" in **Arena B**.
  3. `makeUser()` returns a struct pointing to 0x1234 in **Arena B**.
  4. `makeUser()` finishes. **Arena B is wiped.**
  5. `main()` tries to read the name. **Segfault / Garbage Data.**

```
       [ Arena A (Main) ]                   [ Arena B (makeUser) ]
      +------------------+                 +-----------------------+
      | VAR user = ?     | <--- POINTER ---| "Alice"               |
      +------------------+                 +-----------------------+
                                                      ^
                                                      |
                                          (This arena is about to explode)
```

### The "Slow" Fix (Deep Copy)

We could pause execution and copy "Alice" from Arena B to Arena A.

 * Small Data: Fine.
 * Big Data (10MB Image): Terrible. This kills performance.

## 3. The CHEAT Solution A: Destination Passing (RVO)

For known return types (Structs, Fixed Arrays), CHEAT uses Destination Passing Style.

*The Trick*

  * `Main` knows `makeUser` is going to return a `User` struct.
  * So, `Main` reserves a slot in **Arena A** before calling `makeUser`.
  * It effectively tells the child: **"Don't write the answer in your notebook. Write it directly in mine."**

### Visualizing RVO

```
       [ Arena A (Main) ]                   [ Arena B (makeUser) ]
      +------------------+                 +-----------------------+
      | SLOT FOR RESULT  | <--- WRITE! ----| (Logic happens here)  |
      +------------------+                 +-----------------------+
```

 1. `makeUser` calculates the result.
 2. Instead of allocating the result in **Arena B**, it writes directly to the pointer provided by **Arena A**.
 3. Arena B is wiped.
 4. The result is safe in Arena A. **Zero Copying**.

## 4. The CHEAT Solution B: Page Handoffs ("The Loose Leaf")

 * RVO works for fixed sizes.
 * But what if makeUser generates a **Dynamic String** or **List of unknown size**??
 * It can't write into A because it doesn't know how much space to ask for.

CHEAT Arenas are not single blocks of memory. They are Linked Lists of Pages (usually 4KB or 64KB blocks).

**The Trick**

When the compiler sees a large dynamic object being returned, it allocates that object on a Fresh Page (a loose leaf paper), separate from the standard scratchpad.

When the function returns, we don't copy the data. We simply **change the owner of the page.**

### Visualizing Page Swizzling

**Before Return:**

```
[ Arena A List ]        [ Arena B List ]
    Page 1                  Page 1 (Scratchpad) -> [ Page 2 (The Result) ]
```

**After Return (The Handoff):**

```
[ Arena A List ]        [ Arena B List ]
    Page 1    --------> [ Page 2 (The Result) ]    Page 1 (Incinerated)
       ^
       |
  (Link Updated)
```

 * **Cost:** Two pointer swaps => O(1).
 * **Result:** A 1GB array moves from Child to Parent instantly without copying a byte.

### 5. Solving Recursion: The INSIDE Keyword

The standard Arena model (Birth -> Death) struggles with recursive structures like Trees or Linked Lists.

#### The Struct Problem

Consider this recursive struct:

```
STRUCT BinaryTreeNode {
  val: Int,
  left: BinaryTreeNode,
  right: BinaryTreeNode
}
```

If you recursively call a builder function normally:

```
FN buildTree(depth) -> BinaryTreeNode ->
  -- ... logic ...
  VAR left = buildTree(depth - 1);  -- Allocates in Child Arena B
  VAR right = buildTree(depth - 1); -- Allocates in Child Arena C
  RETURN %BinaryTreeNode{...}
END
```

Each call creates a New Arena (New Page). The Tree nodes are scattered across memory pages. To return the tree, the runtime has to detach all those pages and link them to the parent. This works, but it causes Page Fragmentation and poor CPU cache locality.

**Visualizing the Fragmentation:**

```
[Page A (Root)] --> [Page B (Left Node)]
                --> [Page C (Right Node)]
```

#### The Solution: INSIDE (Allocator Passing)

The INSIDE keyword flattens the hierarchy. It tells the function: **"Use MY arena for all your allocations."**

```
-- "Run this logic, but write the results in my notebook"
VAR tree = INSIDE buildTree(5);
```

**Visualizing `INSIDE`**

```
Function: buildTree() called INSIDE Main

[ Main's Arena ]
+-------------------------------------------------------+
| Node (Root)                                           |
|   -> Node (L)                                         |
|      -> Node (LL)                                     |
|      -> Node (LR)                                     |
|   -> Node (R)                                         |
| ...                                                   |
+-------------------------------------------------------+
(All nodes are contiguous in memory. Cache locality is perfect.)
```

 * **The Result:** All nodes are written sequentially in memory (contiguous).
 * The CPU can walk the tree incredibly fast because it's all in the same memory block.
 * When Main finishes, the entire Tree vanishes instantly.

## Summary of the User Contract

 * **Do Nothing:** For 99% of cases, write normal code.
   * The Compiler uses Destination Passing or Page Handoffs to ensure your data escapes safely and instantly.
 * **Use `INSIDE`:** If you are building complex recursive structures (Trees/Graphs) and want them to be tightly packed in memory for performance.
 * **Use Atomics (^):** If you need data to survive outside the function hierarchy (e.g., shared across threads). These are reference-counted and live in a global heap.

**CHEAT doesn't break the laws of physics. It just manages the paperwork so you don't have to.**
