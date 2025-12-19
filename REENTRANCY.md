# REENTRANCY ATE MY BABY

## WITH blocks are non-rentrant

While you have a `WITH` block open on an object, no other `WITH` block for that same object can start.

  * This applies to other threads, but crucially, it also applies to your own recursive functions or callbacks.
  * This restriction gives you *near* Rust-level determinism for mutable access to shared objects, at a fraction of the cognitive overhead.

### The Mental Model: Database Transactions

Think of a `WITH` block like a database transaction:

  * You are the sole owner of the object’s mutable state for the duration of the block.
  * Nothing else can touch that object until the block finishes.

**The Rule:** You cannot create a "loop" of mutation where a function modifying an object calls itself (or another function) that tries to modify that same object again.

### The "Infinite Mirror" Pattern (Forbidden)

Imagine you have a Player object:

 * You enter a `WITH` block to damage & heal the player.
 * Inside that block, you trigger an event `damage!()` and then `heal!()`.
 * If `heal!()` tries to open a new `WITH` Player block to heal the **shared object**:
   * The compiler will tell you to do that in another transaction.

```ruby
WITH sharedPayer AS MUT player {
  damage!(player);               -- OKAY
  heal!(player);                 -- OKAY
  heal!(sharedPlayer);           -- Compiler Error!
  -- `heal!`  mutates `sharedPlayer` inside a new WITH block
  -- run `heal`  outside this WITH block
}
```

 * CHEAT is designed so that your functions *should* take the **real thing**, not the **shared thing**.
 * In practice, this makes your life eaiser.
   * See note at bottom for rare cases when you do want a function taht takes the **shared thing**.

### The "Nested Updates" Pattern (Forbidden)

You cannot nest `WITH` blocks for the same object, even if they seem safe.

```ruby
WITH sharedConfig AS MUT config {
  config.mode = "debug"
  WITH sharedConfig AS MUT c2 {
     -- ERROR: You have the real `sharedConfig` as `config`.
     -- You can't start another transaction with `sharedConfig`.
     -- Use `config` directly.
     c2.retries = 3
  }
}
```

### Why the hell not?!

Re-entrancy bugs are the root of all evil.

#### The Problem (Sheer Chaos):

In most languages:

 * If Function A is reading a list,
 * And Function B changes that list,
 * The list ends up corrupted (or the program crashes).

Tracking this down in a concurrent context is a nightmare because it depends on the **invisible** "call stack.”

```ruby
FN printLastBaby(sharedBabies) ->
  -- LINE 1: Sanity Check
  IF sharedBabies.length > 0 THEN

    -- <--- THE INVISIBLE JUMP --->
    -- Meanwhile, another thread, minding its own business
    -- Being perfectly, logically sound in isolation
    -- kills you

    Logger.log("Accessing list...");

    -- LINE 2: Access the item
    -- CRASH! Index Out of Bounds.
    print(sharedBabies.last);
  END
END


-- The other, innocent thread:
FN eatLastBaby(sharedBabies) ->
  IF sharedBabies.length > 0 THEN
    sharedBabies.pop();
  END
END
```

 * In most langagues, you cannot trust from one line of code to the next.
 * Both of these functions are logically sound.
 * They work in isolation.
 * You won't find a bug in a unit test.
 * But you will find a very difficult-to-fix production bug.


#### The Actor Model Solution (Share Nothing, Copy Everything):

This is safe, and sanity preserving, but comes with a tax.

 * It's **mandatory** for *distributed* workloads (where memory cannot be shared).
 * But for *local* workloads, it effectively treats your screaming-fast RAM bus like a slow network cable.

It also becomes remarkably unintuitive for complex data, quickly:

 * **The "Tangled" Data Problem:** If your data is interconnected (like a graph, a tree, or a game world):
 * You can't just "follow a pointer."
 * You have to send a message, wait for a reply, and handle the asynchronous latency.
 * Simple reads become complex protocols.
 * Making things overly complex is CHEAT's sworn enemy.

It is also much easier said than done well:

 * **The "God Actor" Trap:** The most common mistake is creating one actor to manage a large resource (like a `GameManager` or `Cache`).
 * **The Result:** You have accidentally reinvented the Global Lock! Every thread lines up in that one actor's mailbox, serializing your entire program and killing your parallelism.

Go falls into this bucket if you use channels, or the next even worse bucket - when that's too complicated - and you don't.

#### The Safe Java/C/Swift/Kotlin Solution (Lock Everything):

 * This is unsafe by default (requires correct implementation to avoid *Deadly Embrace*)
 * And also slow.

If you're constantly locked, you get the benefits of shared memory, but lose the benefits of parallel processing (the big win).

In fact, you ironically scale in the **wrong** direction:

  * As you increase cores, you **get slower** not faster!

> Amdahl’s Law: the speedup of a program is limited by the serial part of the task. If threads are constantly waiting on locks (contention), adding more CPU cores won't make the program faster; it might even make it slower due to context switching overhead.

 * In practice, this is more complicated and typically scales worse than the Actor Model.
 * Objects are small, RAM is abundant.
 * CPU cores are harder to come by - if you've locked them all!

#### The Rust Solution (Brain Burn):

Rust takes a radically different approach: it moves the pain from the **machine** to the **developer**.

 * **The "Magic" Trick:** It enforces memory safety and concurrency checks at *compile time*.
 * **The Reward:** You get the raw performance of Shared Memory (no copying) without the danger of Data Races.

It is the **only** solution that effectively "cheats" the trade-off:

 * **Fearless Concurrency:** The compiler mathematically proves your code is free of data races. If it compiles, it is safe.
 * **Zero Runtime Cost:** You don't pay for Garbage Collection (Java/Go), message copying (Actors), or global lock contention.

But the entry fee is steep:

 * It forces you to fight the "Borrow Checker" and understand "Lifetimes."
 * It *will* make you rewrite your architecture just to satisfy the compiler.
 * **The Economics:** You pay with *development time* up front so you get slightly more *CPU cycles* and use slightly less RAM forever.

#### The CHEAT Code (Transactions):

CHEAT solves this by simply saying "One at a time."

  * By banning re-entrancy, we guarantee that when you are inside a `WITH` block:
  * You become the god of those mutable objects.
  * **No one else, nowhere else** - not other threads, and not even your own recursive functions - can touch them.

You get *almost* all of Rust's benefits, for *slightly* worse CPU cycles, and *slightly* more RAM:

  * And if you're wrong about data access patterns or they change:
  * You don't need to re-write large portions of your app
  * If your initial optimization strategy turns out to be wrong:
  * You can easily try another one by changing a line, instead of re-writing an entire library

Rust is for:

  * People who can get everything right *ahead of time*.

CHEAT is for:

  * Everyone else.

> Premature optimization is the root of all evil - Donald Knuth

  * 90% of code is on the COLD path (rarely used)
  * 10% of code is on the HOT path (most of execution)

**The Verdict:**

 * Rust makes you spend your brain cells **prematurely** optimizing the **COLD path**.
 * CHEAT lets you spend your brain cells **post-maturely** optimizing the **HOT path**.
 * Everything else makes you spend your brain cells fixing non-determinism and thread/memory safe bugs.

### CHEAT’s One Re-Entrant Blind-spot

If it was as simple as CHEAT to be perfect, Rust likely would have chosen this path.

Rust wants to run on embedded devices with 12kb of RAM. People want Rust’s safety guarantees to write concurrent systems without blowing their brains out.

CHEAT says, we’ll give you the guarantees you want, and use minimal RAM and CPU cycles to do it.

 * Rust was designed for perfection - at any cognitive cost.
 * CHEAT is designed to maximize the perfection / cognitive cost curve.
 * Rust optimizes for memory consumption and CPU instruction count.
 * CHEAT optimizes for ROI on brain power & time (the truly scarce resources).

Unless you’re writing code to run on a toaster, CHEAT *might* be the trade you want.

Simplicity comes with trade-offs. Plain and simple.

#### The "Blind Spot" In CHEAT:

You can still write a logic bug inside your function (e.g., mutating a list while iterating over it). Rust prevents this; CHEAT does not.

 * Copying something, deleting the original, then storing the copy elsewhere - all inside a `WITH` block.

On rare occasions, you *might* want to do this. Rust's rules are annoying.

 * But in fairness, *most* times, it's probably a bug.
 * Mea culpa, Rust, you win here.

CHEAT has [iterator invalidation](https://wiki.c2.com/?IteratorInvalidationProblem), which *practically* covers *most* of this blind-spot. But not all of it!

 * It's annoying.
 * It will tell you to use `filter!` or `map!` instead of `each` and `mutate`.
 * But it will prevent the vast majority of these blind-spot bugs from occurring.

#### The Payoff: CHEAT solves the Global Problem.

Think of the re-entrancy problem like this:

 * In CHEAT, **you** can still write a bug in **your** function.
 * **Someone else, somewhere else can't!**
 * Your function will never have undefined behavior because someone else wrote a completely unrelated function.

**The Result:** This takes a *globalized problem* (impossible to debug concurrency issues) and turns it into a *localized problem* (easy to debug logic issues).

 * You only end up with bugs you can easily catch and fix in unit tests.
 * You do not end up with non-reproducible nightmares that are nearly impossible to test, debug, or fix - which plague every language beside Rust and Actor Model paradigms.

Think of it further:

 * It is scalable to write a single function that works.
 * It is *not-scalable* to write an entire application that works when anything can break anything, anywhere, any time.

Rust optimizes for **soundness** over:

  * Ergonomics
  * Learning curve
  * Understandability
  * Development time
  * Refactoring cost
  * API flexibility

Because of this, Rust can boldly claim:

 * We eliminate all **unsound mutation** bugs at the compiler-level. Period.

CHEAT optimizes for organization sanity.

 * You *can* write a **soundness mutation** bug,
 * But you've really got to go out of your way,
 * And even if you do, a junior-level developer should be able to find, debug, test, and fix it.

### A final note on non-rentrancy

CHEAT does **not** re-introduce Rust’s function coloring and type virality under a different name.

 * Most times, you want a function to take the real object, not a shared version.
 * This is what CHEAT is designed around.

You should shared memory **when and only when** you’re using it **directly**.

  * Occasionally, you want a function that takes a shared object.
  * Rarely, you want a function that takes both.

In those rare cases, CHEAT has you covered with a decorator (i.e syntax sugar to create a separate function wrapped in a `WITH` block for you):

```ruby
@SHARED(Fetcher=Cache.get)
FN levelUp!(MUT p: Player, xp_gain: Int) ->
  p.xp += xp_gain;
  IF p.xp > 100 THEN
    p.level += 1;
  END
END
```

