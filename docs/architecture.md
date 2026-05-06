# Architecture

**1. Arena-Based Memory & Isolation**
  * CLEAR leverages affine types and Arena-based memory to give you near High-Frequency Trading standards of allocation with zero thought.
  * Due to optimizing broadly for a fiber-runtime, there are cases when the stack could be better leveraged, but CLEAR chooses not to for large stack objects (to keep fiber stacks small, until most fibers are transformed seemlessly into Finite State Machines by v0.4).

**2. Deterministic Shared-Memory and a Declarative Concurrency Model**
  * Parallelism is achieved via `BG/DO/CONCURRENT`, which creates isolated execution contexts.
    * Rather than telling the code *how* to achieve fast speeds, you simply tell write the code that expresses your intent - the *what*.
    * CLEAR provides one-line capability optimizations. Changing your app from an Arc/RwLock strategy suffering from syncronization bottle-necks to a shared-nothing architecture which can compete with Dragonfly DB can be a one-line change.
  * Spawning a process creates a lightweight, isolated fiber / memory arena (or Finite State Machine in the near future).

**3. Implicit "Railway" Error Handling**
  * CLEAR treats errors as data, but handles them via control flow.
  * The `SMOOTH` operator `|>` (aka the `PIPE` or `|> ` in Elixir, etc) acts as a guard.
    * It automatically bubbles errors down the chain, to be handled elsewhere, or allows them to be handled inline elegantly.
  * This ensures code reads top-to-bottom & is left-sided (the "Happy Path") -- making it always clear what's desired vs what's the fallback.
  * *The Result:* No if [err != nil]() boilerplate. No [Pyramid of Doom](). No [checkOk]() clutter. No `if .nil?` everywhere.


**4. A Type system that *just works***
  * CLEAR is easy to write for beginners. The Type system is implicit, staying out-of-the-way by powerful Type inference.
  * The compiler takes care of the confusing parts of the type system for you.
  * *The Result:* If you can write code in JavaScript, Lua, Python, or Ruby - you can write blazing fast CLEAR code.

**5. Fortress Architecture**
  * All `PUBLIC` functions must return a single type with a suitable default - or explicitly error
  * All `PUBLIC` structs must have a suitable default - or explicitly an error
    * A `PUBLIC` function obviously cannot take a non-`PUBLIC` struct as an input.
  * *The Result:* Guarantees that only *YOUR* code can cause run-time errors (or none if in `STRICT` mode).
    * You can auto-gen tests for PUBLIC functions for all permutations of POSSIBLE unexpected inputs.
      * This allows you to spot problems easily and arrive at robust, working code quickly.


