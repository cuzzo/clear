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

### 0. Lexer (`src/lexer.rb`)

 * This takes text and parses it into valid CLEAR tokens.
 * If you're adding a new syntax feature, you likely need to start here.

### 1. Parser (`src/parser.rb`)

 * This parses tokens and transforms them into Abstract Syntax Tree (AST) nodes.
   * An AST node basically extracts all relevant data from the source text about a particular CLEAR construct (like a function, or while loop).

### 2. Annotator (`src/annotator.rb`)

 * This is the monolithic monster that does everything else besides lower to Zig.
 * It ensures that the data inside the function is valid.
   * For example, in CLEAR, functions that mutate must be suffixed with `!`
   * The annotator is responsible for all these ensurities
 * In addition, it hydrates AST nodes with all data that *can't* be processed in-line by the parser.
   * A `BG` block might need to know if the code inside `EFFECTS` I/O, etc.

### 3. Transpiler (`src/transpiler.rb`)

 * This takes the fully hydrated AST Nodes and simply pretty prints them as valid Zig.
   * The most complicated part here is managing affine lifetimes properly.

### 4. Runtime (`zig/runtime-header.zig`)

  * This is the Zig code that includes all the concurrency constructs that allow you to write easy code that seamlessly runs efficiently on multiple cores.
  * The majority of performance improvements that will be accepted live here.
    * The biggest impacts come from scheduler efficiency.
      * Go's scheduler is a God-like work of art.  Despite the language itself having many efficiency flaws, it is *very* difficult to outperform Go, strictly due to how good it's scheduler is.
      * CLEAR's scheduler is far behind, and improvements here will make the most impact.
      * See [docs/benchmarks.md](docs/benchmarks.md) for a list of known areas for improvement.

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

That being said, there are a list of features planned to implement between the v0.1-pre release and v0.1:

 * TigerBeetle-style VOPR
 * `WINDOW`, `JOIN`, and `TAKE_WHILE` higher-order functions
 * Ability to turn on Deadlock prevention on syncronization (liveness safety)
 * `FREEZE`: the ability to take any object and re-organize all its heap memory to be contiguous
 * Error Kinds: In Zig, an Error is just an integer, but we want to be able to group them by 6 kinds with standard behaviors:
    * Transient (Retry), Input (Fix & Retry), System (Stop), NotFound (Create/Stop), Permission (Auth), Canceled (Abort).
    * In the future, we also need to be able to attach snapshots to errors, but this can wait for v0.2+.
 * DEFAULTS: The ability to set default fields on structs, and to RETURN DEFAULT if a struct is defaultable.

### v0.2 - The Vision

The primary focus of the v0.2 release is to demonstrate the power of the language's design.

CLEAR should be able to have unmatched Profile-Guided Optimization to allow anyone (especially LLMs) to write nearly perfect, concurrent code easily.

The key focus will revolve around `clear profile <myApp.cht>`, which will identify common bottlenecks regarding concurrency and scheduling, and suggest options to fix them.

 * LLMs should be able to automate this in a virtuous feedback cycle.

Further language/runtime features will include:

 * Runtime as a library: to improve build times
 * io_uring networking
 * Automatic Stack Size detection
 * CI integration
 * STRICT mode compilation
   * Non-slient effects: the compiler currently tracks EFFECTS silently.  In strict mode, it will require these to be annotated explicitly: `clear fix ...` will handle it automatically.
 * An RSpec like testing framework
   * The goal of CLEAR is to make code easier to test than in any language in the same performance class
 * A benchmarking framework
   * Modeled upon Go/Rust frameworks.

### v0.3 - Usability

The primary focus of v0.3 will be in practicality of using CLEAR non-experimentally.

It will focus mainly on the standard library (based on Ruby/Elixir) and ARM support.

Other wish-list items are:

 * NUMA-awareness to scale past 64 cores better than Go.
 * Transforming pipelines to GPU kernels + auto-squish for structs.
 * Control Plane enhancements
   * Ideally to safely migrate sharded/skewed loads to shared on the fly

## What We Are NOT Accepting (The "Hard No" List)

 * Standard Library Additions
 * Re-architectures (though one is needed)
   * Migrations to MPSC/MPMC: CLEAR intends to be strictly SPSC at the architecture level.
 * Micro-performance improvements
   * If we are allocating an additional frameAlloc somewhere, and the fix includes 100+ lines of code - it will likely not get approved at this time.
 * Non-trivial runtime changes (zig/)
   * This is temporary until VOPR is implemented.

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
 * Due to rapid development, the core architecture of the annotator is sloppy
   * LLM code will continue to be accepted gladly, and is perhaps best suited to contribute to the code in its current *ai-slop-ish* state.

## FINAL NOTE

 * Please reach out *before* adding any major feature.
 * I likely have a doc that lays out how it is supposed to be designed.

