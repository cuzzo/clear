# Contributing to CLEAR

## Welcome & Philosophy

The goal of CLEAR is:

  * To be the *simplest* Typed language,
  * While being *more* safe than Rust,
  * And nearly as fast as perfect C

CLEAR aims to maximize local reasoning and minimize global complexity:

  1. This is the definition of simple.
  2. This allows for compiler optimizations not possible in other languages.
  3. This *should* allow LLMs to write efficient, correct code more easily than any other language.

CLEAR is focused on describing intent, and the compiler transforming that into the perfect execution model for your architecture (like SQL does):

  * Server architectures are getting increasingly complicated.
  * Application code should not need major re-architectures to leverage better future hardware.

## Architectural Overview

### Compiler (src/)

At an extremely high level, the compiler has 7 passes:

 1. Lexer (Tokenize the program)
 2. Parser (Transform tokens into an Abstract Syntax Tree)
 3. Annotator (Hydrate tokens with type info, ensure proper program structure)
 4. Desugaring (Transform Pipelines, String Concatenation, etc)
 5. Control Flow Graphing (Transform the AST into a CFG, ensure Affine Ownership / memory safety)
 6. MIR Lowering (Transform the CFG into a Mid-level Representation that can be translated into *SAFE* Zig)
 7. Transpilation (Turn the MIR into working Zig code)

### Runtime (zig/)

 At an extremely high level, the runtime is broken up into:
 
  1. The library (zig/lib) which has all the data structures we need for concurrency.
  2. The Runtime / Green Fiber Scheduler (zig/runtime).

The Scheduler currently only works on Linux:

  * It uses `io_uring` for Network and File IO.
  * It maintains queues of runnable tasks.
  * It context-switches between green-fiber stacks to run tasks *COOPERATIVELY*.
  * It uses SPSC channels for cross-scheduler communication and work stealing for load balancing.

CLEAR automatically inserts cooperative yields into generated code (like Go), to reduce a number p99 latency issues like Head-of-Line blocking.

## Local Development Setup

See [Getting Started](README.md#building--testing).

## The Test Trinity

### 1. Ruby Specs (`rspec`)
### 2. Integration Tests (`./clear test transpile-tests/`)
### 3. Benchmarks (`ruby benchmarks/runner.rb --all`)

## Roadmap & Milestones

### v0.1 - Bootstrap & Stability

The primary focus of the v0.1 release is to demonstrate that CLEAR "works" by any sane definition of the word.

It is easier said than done to formally verify that for a concurrent runtime model.

 * Ability to turn on Deadlock prevention on synchronization (liveness safety)
 * `FREEZE`: the ability to take any object and re-organize all its heap memory to be contiguous
   * As well as profile support to detect when freezing is optimal for your workloads.
 * DEFAULTS: The ability to set default fields on structs, and to RETURN DEFAULT if a struct is defaultable.

### v0.2 - The Vision

The primary focus of the v0.2 release is to demonstrate the power of the language's design.

CLEAR should be able to have unmatched Profile-Guided Optimization to allow anyone (especially LLMs) to write nearly perfect, concurrent code easily.

The key focus will revolve around `clear profile <myApp.cht>`, which will identify common bottlenecks regarding concurrency and scheduling, and suggest options to fix them.

 * LLMs should be able to automate this in a virtuous feedback cycle.

Further language/runtime features will include:

 * MVCC & LockFree Ring Buffers synchronization capabilities for one-line-ish changes to optimize for read-heavy and write-heavy workloads.
   * The CHEAT Runtime already has support for MVCC.
   * But testing it thoroughly enough to include in the language is too much effort to include in the v0.1 release.
 * Runtime as a library: to improve build times
 * io_uring networking
 * CI integration
 * STRICT mode compilation
   * Non-silent effects: the compiler currently tracks EFFECTS silently.  In strict mode, it will require these to be annotated explicitly: `clear fix ...` will handle it automatically.
 * An RSpec like testing framework
   * The goal of CLEAR is to make code easier to test than in any language in the same performance class.
   * CLEAR already supports much of what you need.
 * A benchmarking framework
   * Modeled upon Go/Rust frameworks.
   * CLEAR already has the basic framework for this, but it needs expansion.

### v0.3 - Usability

The primary focus of v0.3 will be in practicality of using CLEAR non-experimentally.

It will focus mainly on the standard library (based on Ruby/Elixir) and ARM support.

Other items include:

 * NUMA-awareness to scale past 64 cores better than Go.
 * Transforming pipelines to GPU kernels + auto-squish for structs.
 * Control Plane enhancements
   * Ideally to safely migrate sharded/skewed loads to shared on the fly
 * Actors as an ownership capability alternative to `shared` (Arc), `sharded` (no default Rust equivalent), and `multiOwned` (Rc).

## What We Are NOT Accepting (The "Hard No" List)

 * Standard Library Additions
 * Example programs that don't sufficiently showcase something not already covered.
 * Re-architectures:
   * Migrations to MPSC/MPMC: CLEAR intends to be strictly SPSC at the architecture level.
   * Migrations away from Cooperative Scheduling: CLEAR aims to enable distribution as a topology as user friendly as BEAM.
 * Micro-performance improvements with large change sets
   * If CLEAR allocates an additional frameAlloc somewhere (2ns), and the fix includes 100+ lines of code - it will likely not get approved at this time.

## Commit Standards & Semantic Versioning

 * Bug fixes must include a test that proves the code was broken and is now fixed.
 * New features must include tests that prove they work at every level:
   * spec/
   * transpile-tests/
   * zig/ (if applicable)
   * In addition, any new syntax must include adequate error messaging for the user.
 * Performance fixes must include a performance benchmark that demonstrates prior poor performance and how it has been increased.
   * There are a number of known performance issues on both single-core compared to perfect C, and in wait-heavy workloads compared to Go.

## LLM Code

 * The foundation of CLEAR was developed by hand
 * But a substantial portion of it has been developed by LLMs
 * LLM code will continue to be accepted gladly, so long as it meets the commit standards.

## FINAL NOTE

 * Please reach out *before* adding any major feature.
 * I likely have a doc that lays out how it is supposed to be designed.

