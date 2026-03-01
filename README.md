# CLEAR

## PROPAGANDA

*Cheating is all you need.*

* Software should be performant, robust, AND resilient.
* It should also be effortless to write and understand.
* It should be able to run anywhere, optimized for distributed parallelism and concurrency.

They told you "Pick one." They lied.

You can have it all, if you're willing to CHEAT.

**Commands like SQL. Pipelines like Bash. Easy like Ruby. Speed like C.**

Being a genius like *antirez* isn't scalable. It's not something everyone can be.

Everyone else can CHEAT.

## WHAT IS CHEAT?

CLEAR is a memory safe language like Rust, with better ergonomics than Swift.

It runs on a Go-like Runtime (the CHEAT runtime) that makes concurrent code as easy, safe, and fast as possible.

## CORE CLEAR PHILOSOPHY

* Code should work.
* Code that is easy to understand, write, AND test is more likely to work.
* Dependencies should be Strictly-Correct, as that *IS* their business logic.
* Applications should *FIRST* be Business-Logic correct, only Strictly-Correct if need be.
* The language and compiler should never get in the way of Business-Logic correctness.
* Making things Strictly-Correct, once Business-Logic correct, should be easy.
* Making things *BLAZING* fast, once Strictly-Correct, should be easy.

## OPINIONS

1. Boiler Plate is bad.
2. Understandable code is king.
   * The easier it is to *UNDERSTAND* code, the more likely it is to arrive at a correct state.
   * Understanding what a function is *supposed* to do should not be bogged down by it's error handling logic.
     * Like test code, error handling code should be separate as much as possible.
     * Read it as an addendum IFF you care.
   * Implicit behavior / magic *can* make things *harder* to understand.
3. You should be able to test anything, and it should be EASY.
   * There should be ZERO test code in production code.
     * Java @visibleForTesting is nice, but it shouldn't be necessary at all.
   * The easier it is to write tests, the more likely you are to actually arrive at working code.
4. Handling Errors should "just work".
   * You should not always have to `checkOk`.
     * We can *assume* okay, and look to the bottom to see what happens when not okay, if we ever care.
   * The easier it is to handle errors, the more likely you are to handle them correctly!
5. If your code compiles in `STRICT` mode, it will not produce a Run-time Error unless the system explicitly encounters a resource boundary, or the program executes an operation whose inputs are logically impossible to resolve correctly.
   * TODO: Investigate Type Coercion Failure claims.
     * Currently not implemented, but on the roadmap.
   * TODO: Investigate claims of all errors being handled *somewhere*.
6. Compiler errors should tell you *exactly* what's wrong, how to fix it, and be easy to understand.
7. Types should be your friend, helping you write working code *faster*, not an enemy that is constantly slowing you down.
8. 90% of your time should be spent writing the code you need, and 10% debugging, handling errors, fighting compilers - not the other way around.
9. Writing efficient code should be the default, and the default should be easy.
   * Writing ineffiecent code should be *obviously* wrong.
10. Anything that *can* be 1-line *should* be!
    * Readability and understandability beat cleverness -- unless direly critical to performance.
    * The constructs and syntax of a language should lend itself to one-liners, as they are often easier to *UNDERSTAND*.
11. Code should be as declaractive as possible.
    * Every function should look like a clean chain of exactly what it *should* be doing.
      * It should not look like a nested mess of *how* it's handling errors and undesirable states.
        * Though it *MUST* have the capability to do that.
12. You should not need to worry about memory management OR a garbage collector.
    * Unless you're a rocket scientist, the right compiler can figure it out better than you can.
    * A good SQL engine beats all but the absolute most elite programmers.
    * A good compiler can also take an easy language and beat all but the most elite programmers (see LuaJIT).
    * CLEAR *does* ask you think about *WHERE* an object lives.
      * Cache locality is literally 100x faster. If you wrote something cache-locality optimized in Ruby, it would crush a pointer cache miss in C.
      * Therefore, CLEAR is designed around making it as easy as possible to ensure you DON'T cache miss unless you absolutely must.
        * This means you do need to think about if you want something on the STACK (default, fast) or the HEAP (slow, but sometimes required).
13. You should not need to worry about a Global-Interpreter-Lock (GIL).
    * Code *should* be able to run in parallel or concurrently *EFFICIENTLY* by default.
14. Code should be as left-sided as possible.
    * How many hours have *YOU* spent tracking down paren-syntax errors, figuring out which condition you're in, etc???
    * Time spent figuring out *WHERE* you even are logically, is time wasted, that could be spent getting things done.
15. Someone who doesn't know *CLEAR* should be able to look at *CLEAR* code and intuit what it does.
16. Publicly-Exported APIs *SHOULD* have style-enforcements.
    * At a minimum, if you're making a library, anyone should be able to understand the API.
    * All `PUBLIC` functions *MUST* either *explicitly* `RAISE` an error OR handle all errors.
      * All `PUBLIC` structs *MUST* either have a suitable default or `!!` suffix.
        * All `PUBLIC` Union Types *MUST* be projectable for ease of use.
17. Internal-code can be *Chill*-Correct.
    * No interpretting errors because you have an unnused variable.
    * No forbidding your code to run for a test because you didn't follow a covention, etc.
    * Your code can fail because of `your` problems, but not becuase of your dependencies problems.
      * `STRICT` mode compilation eliminates *Chill*-Correct and can guarantee you won't encounter virtually all preventable run-time errors.

## Architecture

**1. Arena-Based Memory & Isolation**
  * CLEAR uses Arena-based memory instead of a global Garbage Collector.
  * The "Handoff" Trick: When a function returns a large object (like a String or List), CLEAR does not copy the data.
     * Instead, it performs Return-Value Optimization via Destination Passing.
       * The compiler instructs the function to write the data directly into the Caller's memory.
     * For dynamic data, it uses Page Handoffs: The memory page containing your data is detached from the dying function and stapled to the living Caller.
  * *The Result:* You can return a 1GB video file from a function instantly `O(1)` *without* a generic Heap or "Stop-the-World" jitter of Java or Go.

**2. Implicit "Railway" Error Handling**
  * CLEAR treats errors as data, but handles them via control flow.
  * The `SMOOTH` operator `s>` (aka the `PIPE` or `||> ` in Elixir, etc) acts as a guard.
    * It automatically bubbles errors down the chain, to be handled elsewhere, or allows them to be handled inline elegantly.
  * This ensures code reads top-to-bottom & is left-sided (the "Happy Path") -- making it always clear what's desired vs what's the fallback.
  * *The Result:* No if [err != nil]() boilerplate. No [Pyramid of Doom](). No [checkOk]() clutter. No `if .nil?` everywhere.

**3. Register-Based Virtual Machine**
  * CLEAR runs on a custom Register-Based VM *OR* transpiles to Zig and runs natively.
  * This reduces instruction churn compared to traditional stack machines (Java/Python/Ruby/etc) which maps efficiently to hardware.
  * *The Result:* Rapid development, with real-time debugging as easy as Ruby, with guarantees your code won't crash in run-time.

**4. Bi-Modal Type System**
  * CLEAR is dynamic by default (using NaN-boxed values for ease of use) but supports optional "Systems Types" (`u8`, `u64`) and Struct definitions.
  * *The Result:* You can write scripts fast, then optimize hot paths into raw machine instructions, bridging the gap between Python/Ruby and Zig/C.

**5. Deterministic Shared-Memory for Concurrency**
  * Parallelism is achieved via `SPAWN`, which creates isolated execution contexts.
  * `SPAWN`ing a process creates a lightweight, isolated memory arena.
  * Because memory is not shared between threads execpt `shared:atomic` capabilities, CLEAR code is lock-free and thread-safe by default.
    * CLEAR avoids the latency spikes of a "Stop-the-World" Garbage Collector by using Reference Counting for `shared` objects.
       * A `shared` object dies the microsecond the last thread stops using it.
    * The Law of Cycles: To make this work without leaks, CLEAR enforces a strict topology: A `shared` object cannot hold a reference to another `shared` object.
       * This guarantees a Directed Acyclic Graph (DAG) of memory.
       * *The Result:* You get the safety of Java/Go concurrency with the predictable latency of C++.

**6. A Type system that *just works***
  * CLEAR is easy to write for beginners. The Type system is implicit, staying out-of-the-way by powerful Type inference.
  * The compiler takes care of the confusing parts of the type system for you.
  * *The Result:* If you can write code in JavaScript, Lua, Python, or Ruby - you can write blazing fast CLEAR code.

**7. True parallelism**
  * CLEAR can Auto-Squish your structs (Structure-of-Arrays transformation).
  * This allows efficient processing on GPUs in parallel (if compiling to a target).
  * If your struct can't be auto-squished given the code as currently written, you get a compiler error.
  * *The Result:* Either decorate it with @SLOW, or re-write so the data can be squished and screaming fast.

**8. Fortress Architecture**
  * All `PUBLIC` functions must return a single type with a suitable default - or explicitly error
  * All `PUBLIC` structs must have a suitable default - or explicitly an error
    * A `PUBLIC` function obviously cannot take a non-`PUBLIC` struct as an input.
  * *The Result:* Guarantees that only *YOUR* code can cause run-time errors (or none if in `STRICT` mode).
    * You can auto-gen tests for PUBLIC functions for all permutations of POSSIBLE unexpected inputs.
      * This allows you to spot problems easily and arrive at robust, working code quickly.

**9. Scoped Inlining (INSIDE) for Graphs**
  * Traditional Arena languages struggle with recursive structures (Trees/Graphs) because children die when the function returns.
  * CLEAR solves this with the INSIDE keyword (e.g., VAR x = INSIDE buildTree()).
  * This allows a child function to borrow the *Parent's Arena* for allocation.
  * *The Result:* You can build complex, pointer-heavy recursive data structures that exist contiguously in memory and are freed instantly when the root owner exits.

## WHO IS CLEAR *NOT* FOR

CLEAR is opinionated. The specific optimizations that make it fast and safe for 99% of Business Logic make it extremely hostile to 1% of Architectural patterns.

1. You are building a Pointer-Heavy Engine (like a Graph Database).
  * CLEAR prevents Memory Leaks by forbidding reference cycles in `shared` objects (Shared A -> B, B -> A).
  * If your architecture relies on a "Soup of Mutable Objects" where everything references everything else, CLEAR will fight you.
  * *The Alternative:* Architect your data using IDs and centralized lookups (like a relational database), or use Rust/C++ for manual pointer management.

2. You need to model Inherently Unsafe / Cyclic Relationships
  * If your architecture relies on Rust-style "Weak Pointers" to manage reference cycles (A -> B -> A)
     * OR if you need recursive fine-grained locking, and you are strictly managing memory and deadlock risks manually.
  * CLEAR guarantees safety by forbidding these patterns entirely! They're rare!
  * *The Alternative:* If you absolutely need a doubly-linked list or a cyclic graph with individual node locking, that is "Engine Code," not "Business Logic." Write that specific component in Zig (where you can manage the unsafe pointers yourself) and import it into CLEAR as a safe handle.

## WHY CLEAR

If you already know Logic (Javascript/Python), the only thing stopping you from writing System-Level code is Memory.

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

In CLEAR, you can only change the value of `MUTABLE` variables.

```ruby
VAR name = "Bob";
SET name = "Alice";         -- COMPILER ERROR! `name` is immutable.
```

 * `VAR x` = **READ** Only.
 * `MUTABLE x` = **READ/WRITE**.

**The "Gotcha":** If you want to modify a variable, it must be `MUTABLE`.

```ruby
MUTABLE name = "Bob";
SET name = "Alice";         -- OK
```

### 2. Physics of SHAPE: TYPES

In CLEAR, variables have types to ensure safety and speed.

```ruby
MUTABLE name = "Bob";
SET name = 1;                -- COMPILER ERROR: `name` is a String, cannot assign a Number.
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

 * `VAR x = [1,2]` → CLEAR decides the most efficient location.
 * `VAR list = [1, 2, 3]` → This list is optimized for performance and safety.

If you need to explicitly force an object onto the heap (e.g., for recursive structures or large buffers), you can use the `indirect` capability (similar to `Box` in Rust).

```CLEAR
-- Recursive structures use 'indirect' to avoid infinite size on stack
STRUCT Node {
  value: Int64,
  left: indirect Node,
  left: indirect Node
}
```

The "Gotcha": If you try to `.push!` or `.pop!` to a fixed-size array, the compiler will yell at you. It’s not being mean; it’s telling you that physics forbids it.

```ruby
VAR x = [1, 2, 3];
-- ... do something, now I need to add to `x`, what do I do?
x.append!(4);                  -- COMPILER ERROR! `x` is immutable.
```

### 5. Physics of Capability: Capabilities vs Types

In CLEAR, we separate **Types** from **Capabilities**.

*   **Types** describe *what* the data is (e.g., `User`, `Account`).
*   **Capabilities** describe *how* you access it (e.g., `shared`, `multiowned`, `alwaysMutable`).

**The Rule:** Functions take **Types**, not **Capabilities**.

### The CLEAR Model

**Ownership:** Rc = `multiowned`, Arc = `shared`
**Synchronization:** Mvcc = `shared:read`, RwLock = `shared:writeLocked`, Mutex = `shared:locked`
**Future** -> `:actor` uses Object Actor Pattern combined with compiler aware SHARDING
**Interior Mutability:** Cell, RefCell -> combined = `alwaysMutable`
* Automatically acts like Cell for data under 16 bytes
* `alwaysMutable` must be unwrapped before individually passing into a function as an argument, like any other capability
**Existence:** Option, Result => not a capability -> a tense:
* `T?` = Optional T
* Unwrapped like in Rust and Zig with `.?`

```CLEAR
affUser = User.new();         -- creates `affine User` (default)
a = affUser;                  -- OKAY, affine MOVE, affUser is dead
b = affUser;                  -- Compiler error, affUser is dead

sharedU = SHARE(User.new());  -- turns `affine User` into `shared User` (Arc)
c = sharedU;                  -- OKAY, sharedU is not dead
```

#### Why it's superior: Zero Blast Radius Refactoring

In Rust, capabilities like `Arc`, `Rc`, and `Mutex` infect function signatures. Changing from `Rc<User>` to `Arc<User>` forces a massive refactor because every function signature and call site must change.

In CLEAR, if you need thread-safety, you change **one line** at the definition site:

```CLEAR
-- Change multiowned (Rc) to shared (Arc)
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
-- 99% Case: Compiler handles temporary lock
user.login_count += 1;

-- 1% Case: Scoped mutation
WITH user.config {
  _.theme = "Light";
  _.retries = 5;
}
```

### 6. Physics of Sight (SCOPES)

Functions can ONLY see what is explicitly passed into them:

```ruby
VAR x = 10;
FN add() ->
  RETURN x + 5;                 -- COMPILER ERROR: I don't know what 'x' is.
END
```

Use `USE` for upvalues:

```ruby
VAR x = 10;
FN add(n) USE (x) ->
  RETURN n + x;                 -- OK
END
```

### 7. Physics of Time: The ARENA (Lifetimes)

Variable lifetimes follow a simple birth/death cycle: they live as long as the Function they were born in.

#### The ARENA Rule:

When a function starts, it opens a clean ARENA (A bank of memory). Any variable you create lives in this ARENA. When the function ends, the entire ARENA is wiped. *POOF*.

### 8. Cheating Death: The `GIVE` Keyword

When you return an object, you are `GIVING` it to the caller. CLEAR handles the transfer of ownership automatically for simple types. For complex capabilities, you use `GIVE` to satisfy `TAKES`.

```ruby
FN makeUser() -> User
  VAR u = User{name: "Neo"};
  RETURN GIVE u;              -- Ownership moves to the caller.
END
```

### 9. Cheating Death pt 2: The `TAKES` Keyword

In 99% of cases, when you pass a variable to a function, you are just letting that function **Borrow** it. If a function needs to store that object in a long-lived structure (like a Tree or Global List), it must explicitly **TAKE** responsibility for it.

```ruby
-- This function promises to adopt the 'child'
FN addChild!(MUTABLE parent: Node, TAKES child: Node) ->
  parent.list.push!(GIVE child);
END

VAR node = Node.new();
addChild!(root, GIVE node);   -- I surrender ownership.
node.print();                 -- COMPILER ERROR: Variable 'node' is dead.
```

### 10. Simplified Lifetimes: `WITH RESTRICT`

Rust's borrow checker is hard because its side effects are non-local and implicit. In CLEAR, borrows that "poison" (restrict) a mutable variable are explicitly scoped using `WITH RESTRICT`.

```CLEAR
MUT node = buildTree();
WITH RESTRICT node.child {
  -- Inside this block, node.child is immutable (restricted).
  gc = node.grandChild();

  node.child.name = "OK"; -- COMPILER ERROR: node.child is RESTRICTed.
}
-- Outside the block, node.child is mutable again.
```

**Path-Based Scoping:** CLEAR allows you to restrict only the specific part of a data structure you are using (e.g., `node.child`), leaving the rest of the object mutable. This minimizes "poison" and makes complex architectures easier to reason about.

This ensures that "poisoning" is always visible and local.

## EXAMPLES

### The *SMOOTH* operator

```ruby
VAR bill = users AS @u
  s> UNNEST _.orders
  s> SELECT _.price * @u.discount
  s> REDUCE(0, (acc, x) -> acc + x );
```

### Combine with in-line error handling

```ruby
FN myFunc(a, b, c) ->
  val = fetchData(a, b, c) OR RAISE
   s> parseHeader OR EXIT "Invalid Header"
   s> parseBody OR EXIT "Invalid Body"
   s> fetchUser
      s> RECOVER(DefaultUser())
   s> saveToDb(a, b, c, %%)

CATCH ParseError WITH("Invalid Header")
  logInvalidHeader(%e.snapshot.header());
  RETURN defaultPage();
DEFAULT
  logUnknownError(%e)
  raise %e
END
```
