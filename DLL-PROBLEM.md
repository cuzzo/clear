# The Doubly-Linked List Problem:

```
VAR a = %Node{};
VAR b = %Node{};

a.next = GIVE b; -- 'a' now owns 'b'. 'b' variable is dead.
b.prev = a;      -- COMPILER ERROR: 'b' is dead. You GAVE it away!
```

In Ruby (or even C), you can do this easily! No problem.

```
STRUCT Node {
  data: String,
  next: Int64, -- Index in the array (not a pointer)
  prev: Int64  -- Index in the array
}

STRUCT LinkedList {
  arena: Node[], -- The backing store (Dynamic Heap Array)
  head: Int64,
  tail: Int64,
  free: Int64    -- Track deleted slots for reuse
}

FN add(list: LinkedList, val: String) ->
   -- You just push to the array.
   -- You update integers.
   -- Integers don't have borrow-check rules.
   list.arena.push!(Node{ data: val, next: -1, prev: list.tail });
   VAR newIdx = list.arena.len() - 1;

   -- Update old tail to point to new index
   list.arena.set!(list.tail, ...);
END
```

In CHEAT, you'd have to use a list to manage the pointers, like so.

 * This is obviously not ideal.
 * But it's also not a common case to build structures like this.
 * If this *IS* your product/business, CHEAT will probably hinder you rather than help you.
 * If it's not, or a very rare exception, then you will probably reap benefits.

That being said, building DLLs with pointers rather than managing them in a list is bad for cache locality.

 * CHEAT is designed to make optimization for cache locality as EASY as possible (without having to manage literally all memory like C).
 * Even if your product/business depends on this, you *might* benefit from being forced to do it in an efficient way.

In modern computing (post-2010s), the bottleneck is rarely CPU cycles; it is Memory Latency.

 * Fetching a pointer from a random heap location takes ~100 nanoseconds (cache miss).
 * Fetching the next integer in an array takes ~1 nanosecond (cache hit/prefetch).
