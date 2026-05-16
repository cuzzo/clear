# CLEAR for Scripters

If you already know Logic (JavaScript/Python), the only thing stopping you from writing System-Level code is Memory.

 * In Ruby/Python/JavaScript, Memory is "Magic."
 * In C, it's an incomprehensible arcana.
 * In CLEAR, Memory is "Physics."

Here are the 9 Rules of Physics in CLEAR.

### 1. Physics of change: `MUTABLE` vs `IMMUTABLE` (Default)

In Ruby or Python, you can change the value of any variable by default (they behave as `MUTABLE`).

```ruby
name = "Bob"
name = "Alice"
```

In CLEAR, binding a name for the first time creates an **immutable** variable. Reassigning it is a compiler error.

```ruby
name = "Bob";
name = "Alice";             # COMPILER ERROR! `name` is immutable.
```

 * `x = value` = **READ** Only (immutable, no keyword needed).
 * `MUTABLE x = value` = **READ/WRITE**.

**The "Gotcha":** If you want to modify a variable, it must be `MUTABLE`.

```ruby
MUTABLE name = "Bob";
name = "Alice";             # OK
```

### 2. Physics of SHAPE: TYPES

In CLEAR, variables have types to ensure safety and speed.

```ruby
MUTABLE name = "Bob";
name = 1;                   # COMPILER ERROR: `name` is a String, cannot assign a Float64.
```

### 3. Physics of Size: FIXED vs. DYNAMIC

In CLEAR, you choose the physics you need.

 * **FIXED** Size: Optimized for speed and cache locality.
 * **DYNAMIC** Size: Grows indefinitely, but requires the Warehouse (HEAP).

### 4. The Two Worlds: STACK vs. HEAP

#### The STACK (Default)

Think of this as your **Backpack**.

 * Pros: Instant access (L1 Cache). *Blazing* fast.
 * Cons: Itty-bitty space. Fixed size.
 * Behavior: When you finish a task (Function returns), you dump your backpack into the incinerator. Everything inside is gone. *POOF*.

#### The HEAP

Think of this as a **Warehouse**.

 * Pros: (nearly) Unlimited space. Can grow/shrink.
 * Cons: You have to drive there to get stuff (Slower).

#### How to Choose

In CLEAR, the compiler and runtime handle the physics of where data lives for you in 99% of cases. You don't need to use a sigil to choose between stack and heap.

 * `x = [1, 2]` → CLEAR decides the most efficient location.
 * `list = [1, 2, 3]` → This list is optimized for performance and safety.

If you need to explicitly force an object onto the heap (e.g., for recursive structures or large buffers), you can use the `indirect` capability (similar to `Box` in Rust).

```CLEAR
# Recursive structures use 'indirect' to avoid infinite size on stack
STRUCT Node {
  value: Int64,
  left: ?Node @indirect,
  left: ?Node @indirect
}
```

The "Gotcha": If you try to `.push!` or `.pop!` to a fixed-size array, the compiler will yell at you. It’s not being mean; it’s telling you that physics forbids it.

```ruby
x = [1, 2, 3];
# ... do something, now I need to add to `x`, what do I do?
x.append!(4);                  # COMPILER ERROR! `x` is immutable.
```

### 5. Physics of Capability: Capabilities vs Types

In CLEAR, we separate **Types** from **Capabilities**.

*   **Types** describe *what* the data is (e.g., `User`, `Account`).
*   **Capabilities** describe *how* you access it (e.g., `shared`, `multiowned`, `alwaysMutable`).

**The Rule:** Functions take **Types**, not **Capabilities**.

### The CLEAR Model

 * **Ownership:** Rc = `multiowned`, Arc = `shared`
 * **Synchronization:** RwLock = `shared:writeLocked`, Mutex = `shared:locked`
   * **coming soon** -> Mvcc = `shared:versioned`, `:actor` uses Object Actor Pattern combined with compiler aware SHARDING
 * **Interior Mutability:** Cell, RefCell -> combined = `alwaysMutable`
   * Automatically acts like Cell for data under 16 bytes
   * `alwaysMutable` must be unwrapped before individually passing into a function as an argument, like any other capability
 * **Existence:** Option, Result => not a capability -> a tense:
   * `T?` = Optional `T`
   * Unwrapped like in Rust and Zig with `.?`
 * **Future:**: Something that will arrive later
    * `~T` = Future `T`
    * `~T[]` = Future `T`s (like a Stream).


```CLEAR
affUser = User.new();         # creates `affine User` (default)
a = affUser;                  # OKAY, affine MOVE, affUser is dead
b = affUser;                  # Compiler error, affUser is dead

sharedU = SHARE(User.new());  # turns `affine User` into `shared User` (Arc)
c = sharedU;                  # OKAY, sharedU is not dead
```

#### Why it's superior: Zero Blast Radius Refactoring

In Rust, capabilities like `Arc`, `Rc`, and `Mutex` infect function signatures. Changing from `Rc<User>` to `Arc<User>` forces a massive refactor because every function signature and call site must change.

In CLEAR, if you need thread-safety, you change **one line** at the definition site:

```CLEAR
# Change multiowned (Rc) to shared (Arc)
sharedU = SHARE(User.new());
```

Your functions (which just take `User`) never knew about the capability, so they don't need to change.

#### Synchronization Strategies

For multi-threaded `shared` objects, you choose the strategy:
- `shared:read`: (MVCC) Optimized for massive read scaling.
- `shared:writeLocked`: (`RwLock<Arc<T>>`) Multiple readers OR one writer.
- `shared:locked`: (`Mutex<Arc<T>>`) One thread at a time.

#### Interior Mutability

For complex data, use `alwaysMutable` (`RefCell`). CLEAR handles the lock for you:

```CLEAR
# 99% Case: Compiler handles temporary lock
user.login_count += 1;

# 1% Case: Scoped mutation
WITH user.config {
  _.theme = "Light";
  _.retries = 5;
}
```

### 6. Physics of Sight (SCOPES)

Functions can ONLY see what is explicitly passed into them:

```ruby
x = 10;
FN add() ->
  RETURN x + 5;                 # COMPILER ERROR: I don't know what 'x' is.
END
```

Use `USE` for upvalues:

```ruby
x = 10;
FN add(n) USE (x) ->
  RETURN n + x;                 # OK
END
```

### 7. Physics of Time: The ARENA (Lifetimes)

Variable lifetimes follow a simple birth/death cycle: they live as long as the Function they were born in.

#### The ARENA Rule:

When a function starts, it opens a clean ARENA (A bank of memory). Any variable you create lives in this ARENA. When the function ends, the entire ARENA is wiped. *POOF*.

### 9. Cheating Death: The `TAKES` Keyword

In 99% of cases, when you pass a variable to a function, you are just letting that function **Borrow** it. If a function needs to store that object in a long-lived structure (like a Tree or Global List), it must explicitly **TAKE** responsibility for it.

```ruby
# This function promises to adopt the 'child'
FN addChild!(MUTABLE parent: Node, TAKES child: Node) ->
  parent.list.push!(GIVE child);
END

node = Node{val: 1};
addChild!(root, GIVE node);   # I surrender ownership.
node.print();                 # COMPILER ERROR: Variable 'node' is dead.
```

### 10. Simplified Lifetimes: `WITH RESTRICT`

Rust's borrow checker is hard because its side effects are non-local and implicit. In CLEAR, borrows that "poison" (restrict) a mutable variable are explicitly scoped using `WITH RESTRICT`.

```CLEAR
MUT node = buildTree();
WITH RESTRICT node.child {
  # Inside this block, node.child is immutable (restricted).
  gc = node.grandChild();

  node.child.name = "OK"; # COMPILER ERROR: node.child is RESTRICTed.
}
# Outside the block, node.child is mutable again.
```

**Path-Based Scoping:** CLEAR allows you to restrict only the specific part of a data structure you are using (e.g., `node.child`), leaving the rest of the object mutable. This minimizes "poison" and makes complex architectures easier to reason about.

This ensures that "poisoning" is always visible and local.
