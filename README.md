# CHEAT

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

## CORE CHEAT PHILOSPHY

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
    * CHEAT *does* ask you think about *WHERE* an object lives.
      * Cache locality is literally 100x faster. If you wrote something cache-locality optimized in Ruby, it would crush a pointer cache miss in C.
      * Therefore, CHEAT is designed around making it as easy as possible to ensure you DON'T cache miss unless you absolutely must.
        * This means you do need to think about if you want something on the STACK (default, fast) or the HEAP (slow, but sometimes required).
13. You should not need to worry about a Global-Interpreter-Lock (GIL).
    * Code *should* be able to run in parallel or concurrently *EFFICIENTLY* by default.
14. Code should be as left-sided as possible.
    * How many hours have *YOU* spent tracking down paren-syntax errors, figuring out which condition you're in, etc???
    * Time spent figuring out *WHERE* you even are logically, is time wasted, that could be spent getting things done.
15. Someone who doesn't know *CHEAT* should be able to look at *CHEAT* code and intuit what it does.
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
  * CHEAT uses Arena-based memory instead of a global Garbage Collector.
  * The "Handoff" Trick: When a function returns a large object (like a String or List), CHEAT does not copy the data.
     * Instead, it performs Return-Value Optimization via Destination Passing.
       * The compiler instructs the function to write the data directly into the Caller's memory.
     * For dynamic data, it uses Page Handoffs: The memory page containing your data is detached from the dying function and stapled to the living Caller.
  * *The Result:* You can return a 1GB video file from a function instantly `O(1)` *without* a generic Heap or "Stop-the-World" jitter of Java or Go.

**2. Implicit "Railway" Error Handling**
  * CHEAT treats errors as data, but handles them via control flow.
  * The `SMOOTH` operator `s>` (aka the `PIPE` or `|>` in Elixir, etc) acts as a guard.
    * It automatically bubbles errors down the chain, to be handled elsewhere, or allows them to be handled inline elegantly.
  * This ensures code reads top-to-bottom & is left-sided (the "Happy Path") -- making it always clear what's desired vs what's the fallback.
  * *The Result:* No if [err != nil]() boilerplate. No [Pyramid of Doom](). No [checkOk]() clutter. No `if .nil?` everywhere.

**3. Register-Based Virtual Machine**
  * CHEAT runs on a custom Register-Based VM *OR* transpiles to Zig and runs natively.
  * This reduces instruction churn compared to traditional stack machines (Java/Python/Ruby/etc) which maps efficiently to hardware.
  * *The Result:* Rapid development, with real-time debugging as easy as Ruby, with guarantees your code won't crash in run-time.

**4. Bi-Modal Type System**
  * CHEAT is dynamic by default (using NaN-boxed values for ease of use) but supports optional "Systems Types" (`u8`, `u64`) and Struct definitions.
  * *The Result:* You can write scripts fast, then optimize hot paths into raw machine instructions, bridging the gap between Python/Ruby and Zig/C.

**5. Deterministic Shared-Memory for Concurrency**
  * Parallelism is achieved via `SPAWN`, which creates isolated execution contexts.
  * `SPAWN`ing a process creates a lightweight, isolated memory arena.
  * Because memory is not shared between threads execpt Atomics (`^`), CHEAT code is lock-free and thread-safe by default.
    * CHEAT avoids the latency spikes of a "Stop-the-World" Garbage Collector by using Reference Counting for Atomics.
       * An Atomic dies the microsecond the last thread stops using it.
    * The Law of Cycles: To make this work without leaks, CHEAT enforces a strict topology: An Atomic cannot hold a reference to another Atomic.
       * This guarantees a Directed Acyclic Graph (DAG) of memory.
       * *The Result:* You get the safety of Java/Go concurrency with the predictable latency of C++.

**6. A Type system that *just works***
  * CHEAT is easy to write for beginners. The Type system is implicit, staying out-of-the-way by powerful Type inference.
  * The compiler takes care of the confusing parts of the type system for you.
  * *The Result:* If you can write code in JavaScript, Lua, Python, or Ruby - you can write blazing fast CHEAT code.

**7. True parallelism**
  * CHEAT can Auto-Squish your structs (Structure-of-Arrays transformation).
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
  * CHEAT solves this with the INSIDE keyword (e.g., VAR x = INSIDE buildTree()).
  * This allows a child function to borrow the *Parent's Arena* for allocation.
  * *The Result:* You can build complex, pointer-heavy recursive data structures that exist contiguously in memory and are freed instantly when the root owner exits.

## WHO IS CHEAT *NOT* FOR

CHEAT is opinionated. The specific optimizations that make it fast and safe for 99% of Business Logic make it extremely hostile to 1% of Architectural patterns.

1. You are building a Pointer-Heavy Engine (like a Graph Database).
  * CHEAT prevents Memory Leaks by forbidding reference cycles in Atomics (Atomic A -> B, B -> A).
  * If your architecture relies on a "Soup of Mutable Objects" where everything references everything else, CHEAT will fight you.
  * *The Alternative:* Architect your data using IDs and centralized lookups (like a relational database), or use Rust/C++ for manual pointer management.

2. You need to model Inherently Unsafe / Cyclic Relationships
  * If your architecture relies on Rust-style "Weak Pointers" to manage reference cycles (A -> B -> A)
     * OR if you need recursive fine-grained locking, and you are strictly managing memory and deadlock risks manually.
  * CHEAT guarantees safety by forbidding these patterns entirely! They're rare!
  * *The Alternative:* If you absolutely need a doubly-linked list or a cyclic graph with individual node locking, that is "Engine Code," not "Business Logic." Write that specific component in Zig (where you can manage the unsafe pointers yourself) and import it into CHEAT as a safe handle.

## WHY CHEAT

If you already know Logic (Javascript/Python), the only thing stopping you from writing System-Level code is Memory.

 * In Ruby/Python/JavaScript, Memory is "Magic."
 * In C, it's an incomprehensible arcana.
 * In CHEAT, Memory is "Physics."

Here are the 7 Rules of Physics in CHEAT that don't exist in the simplest languages like Ruby.

### 1. Physics of change: `MUTABLE` vs `IMMUTABLE` (Default)

In Ruby or Python, you can change the value of any variable by default (the behave as `MUTABLE`).

```ruby
name = "Bob"
name = "Alice"
```

If you didn't know, in Ruby, you can make it `IMMUTABLE`:

```ruby
name = "Bob"
name.freeze
name = "Alice"             -- RUN-TIME ERROR!
```

In CHEAT, there are no run-time errors!

You can only change the value of `MUTABLE` variables.

```ruby
VAR name = "Bob";
SET name = "Alice";         -- COMPILER ERROR! `x` is immutable.
```

 * `VAR x` = **READ** Only.
 * `MUTABLE x` = **READ/WRITE**.

**The "Gotcha":** If you want to modify a variable, it must be `MUTABLE`.

```ruby
MUTABLE name = "Bob";
SET name = "Alice";         -- OK
```

 * If you want to pass an object to a function that modifies it, that function must accept `MUTABLE`.
 * All functions that mutate/change something *must* end in a `!`.

Let's look at Strings:

```ruby
x = "MISSISSIPPI"
x.gsub!("I", "S")            -- OK: "MSSSSSSSPPS"
```

```ruby
VAR x = "MISSISSPPI";
x.gsub!("I", "S");           -- COMPILER ERROR! `x` is immutable.

MUTABLE x = "MISSISSPPI";
x.gsub!("I", "S");           -- OK: "MSSSSSSSPPS"
```

### 2. Physics of SHAPE (or size pt 1): TYPES

In Ruby and other *easier* languages, variables do not have types.

```ruby
name = "Bob"
name = 1                     -- OK
```

But this presents a laundry list of run-time errors. And run-time errors are NOT OKAY!

```ruby
name = "Bob"
name = 1
name.gsub!("o", "b")         -- RUN-TIME ERROR: missing method `gsub` on `name`.
```

In CHEAT, this is a compile time error (2x):

```ruby
MUTABLE name = "Bob";
SET name = 1;                -- COMPILER ERROR: `name` is a String[], cannot assign to the Number `1`.
```

```
MUTABLE name = 1;
name.gsub!("o", "b")         -- COMPILER ERROR: missing method: `name` is a Number, and Number does not have a method `gsub`.
```

This pushes run-time errors to compile time errors so you can fix them BEFORE testing your code. Additionally, it allows your code to execute *much* faster. You'll see why after the next lesson.

### 3. Physics of Size pt 2: FIXED vs. DYNAMIC

In Ruby, lists are DYNAMIC by default. A list can hold 1 item or 1 million items, and Ruby handles the messy details in the background.

 * The Cost: This magic makes Ruby slow.

In CHEAT, you choose the physics you need.

 * **FIXED** Size: Like a U.S. phone number (always 10 digits).
 * **DYNAMIC** Size: Like a chat log (grows indefinitely).

Why the distinction? Because of where the data lives.

### 4. The Two Worlds: STACK vs. HEAP

In Ruby, everything floats in a magic cloud (the HEAP).

 * The Problem: The HEAP is typically 100x slower than the Stack.
 * The Solution: CHEAT lets you use the fast lane.

#### The STACK (Default)

Think of this as your **Backpack**.

 * Pros: Instant access (L1 Cache). *Blazing* fast.
 * Cons: Itty-bitty space. Fixed size.
 * Behavior: When you finish a task (Function returns), you dump your backpack into the incinerator. Everything inside is gone. *POOF*.

#### The HEAP (The `%` Sigil)

Think of this as a **Warehouse**.

 * Pros: (nearly) Unlimited space. Can grow/shrink.
 * Cons: You have to drive there to get stuff (Slower).
 * The Rule: If you don't know how big it will get, OR if you know it IS big, it belongs on the HEAP.

#### How to Choose

You tell the compiler which world to store your variables with the `%` sigil.

 * `VAR x = [1,2]` → In your Backpack. Fast. Cannot grow, must be small.
 * `VAR x = %[1,2]` → In the Warehouse. Slower. Can grow, can be huge.

#### The Why

Because the STACK is physically just a block of memory mapped to your function, it cannot grow (efficiently). You cannot shove an elephant into a backpack that is already full.

 * No `%` (STACK): The size is fixed at birth.
   * `VAR list = [1, 2, 3]` → This list will be length 3 forever.
 * With `%` (HEAP): The Warehouse has forklifts. It can expand.
   * `VAR list = %[1, 2, 3]` → This list can grow to 1,000,000 items.

The "Gotcha": If you try to `.push!` or `.pop!` to a STACK array (fixed-size), the compiler will yell at you.

  * It’s not being mean; it’s telling you that physics forbids it.

```ruby
VAR x = [1, 2, 3];
-- ... do something, now I need to add to `x`, what do I do?
x.append!(4);                  -- COMPILER ERROR! `x` is immutable.
```

You can make the list Dynamic on the HEAP (not recommended):

```ruby
MUTABLE x = %[1, 2, 3];
-- ...
x.append!(4);                  -- OK
```

For this example, this is needlessly slow. You can also specify the size (to bigger than its birth size) AND keep it *fast* on the STACK.

 * See the full WALKTHROUGH for more details.

If variables were un-typed, it would be impossible to guarantee no run-time errors, and you wouldn't be able to put hardly anything on the STACK.

 * CHEAT thinks it's pretty easy to be aware of 3 properties for data
   * If you are, we believe you'll arive at working code *much* faster.
   * As a by-product, that code will also be *easier* to understand *AND* run *much* faster, too.

### 4. The Physics of Sight (SCOPES)

In JavasSript, functions can see variables outside of them (Closures are implicit). Figuring out what a variable can see is a dark art.

```ruby
x = 10;
function add() {
  return x + 5;
}
x = 8;
add(x);                         // WTF?
```

In CHEAT, functions are simple!

A function can ONLY see what is explicitly passed into it:

```ruby
VAR x = 10;
FN add() ->
  RETURN x + 5;                 -- COMPILER ERROR: I don't know what 'x' is.
END
```

Let's say you want to create a function that always takes some variable, and you don't want to always pass it in. You do this with `UpValues` with the `USE` keyword:

```ruby
VAR x = 10;
FN add(n) USE (x) ->
  RETURN n + x;                 -- OK
END

add(5);                         -- 15
add(x);                         -- 20;
add(x);                         -- 20;
```

The first example with JavaScript is particularly confusing because the value is changed after the function is defined. It's not clear what the function will do.

In CHEAT, you cannot pass a `MUTABLE` as an UpValue:

```ruby
MUTABLE x = 10
FN add(n) USE (x) ->            -- COMPILER ERROR, UpValues cannot be mutable.
-- ...
```

 * There is a type of object that can be used for this, but this is rarely needed.
   * See the WALKTHROUGH for more details.

### 5. Physics of Time: The ARENA (Lifetimes)

In JavaScript/Python/Ruby, variables live as long as someone is looking at them (Reference Counting/GC). But there are *many* problems with this.

 * In C, variables live until you shoot yourself in the foot.
 * In Rust, variables live in accordance with (nearly) incomprehensible laws.

In CHEAT, variable lifetimes are arguably the simplest of all! They follow a simple birth/death cycle:

 * They live as long as the Function they were born in.

#### The ARENA Rule:

When a function starts, it opens a clean ARENA (A bank of memory).

 * Any variable you create (VAR x, VAR y) lives in this ARENA.
 * When the function hits END (or RETURN), the entire ARENA is wiped. *POOF*.

You don't need to free memory. It happens automatically when the function ends.

 * Zig makes this *nearly* as easy with `defer`, but you have to call it every time you create something on the HEAP.
 * CHEAT makes this easy and just does it automatically, because you *almost* always want to do it.

### 6. Cheating Death: The `GIVE` Keyword

If everything dies when the function ends, how do you return a result?! That's a pretty important thing for a function to do!

When you're returning a fixed-size object (STACK), this is easy.

 * The calling function knows what it will get back, and it knows how big it is.
 * It gives the called function a magic tunnel to write that data directly into its backpack.

But this magic tunnel doesn't work for HEAP objects, they're special. The called function CANNOT write these directly into your backpack (STACK) - they're on the HEAP for a reason.

You have to `GIVE` heap objects to the caller.

 * The Problem: If you have a box in the Warehouse (HEAP Object), and your function ends. The box is incinerated. There's nothing left to GIVE/RETURN.
 * The Fix: `GIVE` that HEAP object to the caller, save it from death.

```ruby
FN makeUser() -> %User
  VAR u = %User{name: "Neo"}; -- Created in my Arena
  RETURN GIVE u;              -- I surrender ownership. It lives on in another function.
END
```

### 7. Cheating Death pt 2: The `TAKES` Keyword

There's always a GIVE and TAKE!

In 99% of cases, when you pass a variable to a function, you are just letting that function Borrow it.

 * You let `print(user)` look at the user.
 * You let `update!(user)` modify the user.
 * But **YOU** still own the user. When your function ends, the user is incinerated.

99% of the time, this is what you want and fine. But what if you want to put that User into a List or a Tree that lives longer than you?

If you just let the List "borrow" the User, and then your function ends... *POOF.* The User is incinerated. The List is now holding a pointer to ash. This is the notorious Dangling Pointer / Use-after-Free / Segfault problem.

**The Solution:** The receiving function must explicitely say: "I am TAKING responsibility for this memory."

-- This function promises to adopt the 'child'
FN addChild(TAKES child: %Node) ->
  -- I now own 'child'.
  -- When you end, the child must live on, because I will attach it to something that *might* live longer than you.
END

**The Consequence:** If a function TAKES something, you must GIVE it. And once you GIVE it, you can never touch it again.

```ruby
VAR node = %Node{};

addChild(GIVE node);          -- I surrender ownership.

node.print();                 -- COMPILER ERROR: Variable 'node' is dead. You GAVE it away!
```

This is a dramatically simplified version of Rust's notirously difficult lifetypes and borrow checker.

  * If you're confused, don't worry! These last two topics are *rarely* necessary unless you're doing something pretty advanced.

## CONTROVERSIAL CHOICES

### The *SMOOTH* operator

**1. Ergonomics are King**
  * The standard pipe `|>` is an ergonomic nightmare.
    * It requires awkward pinky-stretches and holding Shift for two distinct keystrokes.
  * `s>` is designed for speed.
     * It rolls across the keyboard (Left hand `s` -> Right hand `>`).
     * It is a literal "Cheat code" for typing pipes faster.

**2. Different Behavior = Different Syntax**
  * In other languages, `|>` is a "dumb pipe." It passes data blindly.
  * In CHEAT, the pipe is a logic gate. It unwraps results, checks for errors, and manages control flow.
  * Using `|>` would be a lie. It would imply standard behavior where there is none.
  * `s>` signals intent: This is a **S**afe, **S**mooth, **S**mart pipe.


### DIVISION by 0
  * In order to guarantee your code will not crash at run-time, you *MUST* guarantee you don't divide by zero.
    * CHEAT did not invent the laws of Math.
  * CHEAT makes this as easy and intuitive as possible, using `GUARD` like the common convention for [guard clauses]().


### Frictionless Error Handling
  * **The Problem:** In most languages, you may spend equal or more time guarding against the 0.1% of cases where things break.
  * **The Solution:** CHEAT inverts this. The "Happy Path" is the default. Errors flow downstream automatically—skipping logic that can't handle them—until they hit a `CATCH` or `RECOVER` block.
  * **The Tradeoff:**
      * **Strictness vs. Velocity:** We trade static type checks for **Runtime Velocity**. CHEAT guarantees your program won't crash on an error, WITHOUT forcing you to manually unwrap every single variable.
  * **The Defense:**
      * **Telemetry over Taxonomy:** If you have to create or deal with 50 custom Error classes to use a function, you'll probably have MORE bugs, not less, then if you had one-simple error to handle.
        * CHEAT provides one robust Error object that captures the **Context**, the **Kind**, and the **Data Snapshot** automatically.
      * **Focus on Value:** CHEAT isn't for writing kernel drivers or flight controllers; It's for everything else.
        * CHEAT allows you to write business logic fast, knowing the safety net is baked into the language semantics.


### The "53-Bit" Lie (NaN Boxing)
  * **The Controversy:** By default, every number in CHEAT is a 64-bit Float (Double).
    * This means generic Integers are limited to 53 bits of precision (safe range up to ~9 quadrillion).
  * **The Trade-off:** If you need a raw `Int64` or `u64` for bitwise pointer math, you have to explicitly ask for it. However, CHEAT natively supports value types, so there is no performance cost.
  * **The Defense:**
      * **99% Case:** You are counting loops, array indices, or database IDs. 53 bits handles this effortlessly.
      * **The 1% Case:** If you are doing Cryptography, matrix multiplication, or care about exact 64-bit Integer limits - you can specify a type.

### Death to the Garbage Collector
   * **The Controversy:** CHEAT does not have a general-purpose Garbage Collector. It uses Arena Allocation.
   * **The Trade-off:** You cannot create an object that lives "forever" without thinking about where it lives.
   * **The Defense:**
       * Garbage Collectors are the enemy of consistent frame rates and latency.
       * CHEAT isolates memory by Process (Spawn) or Function Scope. When the task is done, the memory is nuked instantly.
       * Global objects are generally considered an anti-pattern anyway. Good riddance.
       * **The Result:** Your code runs at a predictable speed. There is no "Stop the World" pause while the VM cleans up your mess.


### Explicit State Mutation (`VAR` vs `MUTABLE`)
  * **The Controversy:** You cannot re-assign a variable declared with `VAR`. You must use the `MUTABLE` keyword.
  * **The Trade-off:** It requires four extra keystrokes to create a variable, and four extra to re-assign.
  * **The Defense:** Re-assignment is the root of 50% of debugging time.
      * By forcing you to type `MUTABLE` and `SET`, CHEAT makes mutation visible (and easy to review).
      * If you see a block of code with no `SET`, you know immediately that the state is stable.
      * *The Result:* At code-time the editor knows this and can highlight functions that mutate to the user.


### IMMUTABILITY BY DEFAULT
  * **The Controvery:** It's tricky for beginners. You assign a variable, want to update it later, get a scary compiler error.
  * **The Trade-off:** This is the default for a reason. It's what you want most of the time.


### Different IMPLICIT default `collect` behavior at the end of stream chains
  * **The Controversy:** If you assign a stream to a variable, the compiler *assumes* you want to do it sync and wait til finished to collect
  * **The Catch:** The same statment *WITHOUT* an assignment, will immediately execute the next line without finishing.
  * **The Defense:** CHEAT is supposed to be intuitive, if you assign `VAR x = myList s> reduce( ... )` on the next line, you assume x to be a val, not a stream.
    * If you DON'T explicitly assign, it assumes it can be run in the background.
    * You must either use `AWAIT` at the beginning or ` s> collect` at the end.
    * In the majority of cases, it will either be a background task OR have a callback.
    * A pipeline that ends in ` s> callback(myFn)` should almost always be async.
    * The compiler will *WARN* but not reject if you don't prefix with ASYNC or AWAIT when not assigning
    * If you want to assign to a stream and/or `RETURN` the stream later, you simply prefix with `ASYNC`


## EXAMPLES

### The *SMOOTH* operator

```ruby
VAR bill = users AS @u                      -- AS binds @variables to be used later in SMOOTH operations
  s> UNNEST _.orders
  s> SELECT _.price * @u.discount
  s> REDUCE(0, (acc, x) -> acc + x );

-- The above is equal to the below

VAR bill = users AS @u
  s> flatmap( %(x) -> x.orders )
  s> map( %(x) -> x.price * @u.discount )
  s> reduce(0, %(acc, x) -> acc + x )

-- Though SQL-like commands are substantially faster (built-into the VM/language) and preferred.
```

### Combine with in-line error handling

```ruby
FN myFunc(a, b, c) ->
  val = fetchData(a, b, c) OR RAISE         -- immediately stop, raise the error to the calling function
   s> parseHeader OR EXIT "Invalid Header"  -- immediately stop, handle below
   s> parseBody OR EXIT "Invalid Body"      -- immediately stop, handle below
   s> fetchUser
      s> RECOVER(DefaultUser())             -- handle error in place, and continue
   s> saveToDb(a, b, c, %%)

CATCH ParseError WITH("Invalid Header")  -- ParseError does not acutally exist, that's the string error.type
  -- CATCH sets %e to the as a local Error variable e
  -- All errors have a context ("Invalid Header") set above
  -- All errors also have a `snapshot`
  -- That contains the value piped into the function that caused the error.
  logInvalidHeader(%e.snapshot.header());
  RETURN defaultPage();
CATCH ParseError WITH("Invalid Body")    -- Errors can contain :: namespacing `Network::IOError`, for example
  -- Since we want to handle the same Error `ParseError` in 2 different ways
  -- That is way we set the context above (after the `?` operator)
  --
  -- If we wanted to handle both errors the same
  -- We wouldn't need to set a context
  raise %e -- We EXPLICITLY bubble this up to the user
DEFAULT
  logUnknownError(%e)
  raise %e
END
```

