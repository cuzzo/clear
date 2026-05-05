# CLEAR TODO

## v0.1 (Target = May 5)

 - [x] FREEZE + profiling support (detect cache miss problems due to pointer chase, that *might* be solved with FREEZE)
 - [x] Profiling support to auto-detect fast producer / slow consumer (when to add back pressure)
 - [x] STRUCT/FN DEFAULTS
 - [x] Partial Deadlock protection (detect *possible* lock cycles and *possible* true system deadlock at compile time, raise handle-able errors at runtime when encountered, rather than *actually* deadlocking)
 - [x] String@symbol
 - [x] Pipeline support for infinite streams (LIMITed) and unbound finite streams 
 - [x] Migrate to Zig 0.16
 - [x] io_uring for networking
 - [x] Native CONCURRENT support for streaming pipelines
 - [x] `./clear fmt`
 - [x] `./clear fix`
 - [x] Binding metadata for capabilities + `REQUIRES` for overloaded syncronization strategies.
 - [x] Compiler code cleanup with Ruby Gems like Reek, Flog, Flay, CodeCov, etc...
 - [x] Continuous Integration
 - [ ] Syntax maturity cleanup / sweep

Milestone: A working CLEAR VM with debugger, that supports a decent chunk of the language (including concurrency).

## v0.1.5 (Target = May 30)

 - [x] IMMUTABLE Stream Observables (only the stream can mutate the underlying data)
 - [x] Finite State Machines
 - [x] Re-entrant Thunks + Trampolines
 - [x] IMMUTABLE Stream Observables (only the stream can mutate the underlying data)
 - [x] Observable aggregations for streaming pipelines (@shared aggregate results)
 - [x] Enable MVCC in the language as a syncronization capability (in progress - already exists in the runtime)
 - [x] Atomics
 - [x] True Synchronization Polymorphism
 - [ ] COPY/CLONE/SPLIT overloading (via SHARE - in progress)
 - [ ] True Polymorphic return
 - [ ] Design by Contract v1: `WITH GURADED x ... AS y { } ON GuardFail`

 ## v0.2 (Target = July 15)
 - [ ] Zig 0.16.0 style streaming IO (in progress)
 - [ ] Typed Holes
 - [ ] Design by Contract v2: PRE { } and POST { } conditions
 - [ ] LEND keyword (attach lifetimes to functions / execution boundaries you LEND to)
 - [ ] Cancelable fibers
 - [ ] Built-in support for fiber RACEs
 - [ ] STRICT mode compilation
 - [ ] VM supporting the vast majority of the language, near Python/Ruby non-JIT speed
 - [ ] VM can automatically generate and run LOOM / VOPR tests for concurrent code
 - [ ] An RSpec like testing framework as the first standard library module
 - [ ] A statistical benchmarking & profiling framework like Go/Rust
 - [ ] `./clear fix` fixes *most* errors that *can* be fixed.
 - [ ] Demand-based processes - don't spin up the max allowed threads unless there's demand (in progress)
 - [ ] HashMap string interning
 - [ ] @sorted for lists, sets, hashmaps.
 - [ ] Automated Property-based Testing for declarative concurrency constructs pt 1.

Milestone: *Basic* SQL/CLEAR database

## v0.3 (Target = Oct 1)

 - [ ] Full Infinite Stream support
 - [ ] Stream Join (declarative, basic)
 - [ ] Generic Observables
 - [ ] Implement lock-free ringbuffer as a syncronization capability (with backpressure)
 - [ ] ARM support
 - [ ] Shared Actors as an ownership capability (not distributed, that comes v0.4 -> these are MSFT Orleans style)
 - [ ] copyOnWrite
 - [ ] Ability to write custom Control Plane strategies
 - [ ] Control Plane Capability Migration -> live shift contented workloads
 - [ ] VM supports entire language, gradual typing.
 - [ ] Automated Property-based Testing for declarative concurrency constructs pt 1.

Milestone: CLEAR-DB with native queries and hot-reload

Vision is clear: Gradual Typing (Ruby/Python) -> Typed (Rust) -> STRICT Typed (HFT-level C speed) -> EXTREME STRICT (ADA-level safety)

`./clear doctor ` + profiling on replay can take you ~95% of the way from an untyped correct app to ADA-level safety and HFT-C speed automatically.

## v0.4 (December 25)

 - [ ] EXTREME STRICT compilation pt 1: en route to ADA-levels of safety (just blocking compilation where required, ensuring the syntax is forward compatible)
 - [ ] MacOS support
 - [ ] Ability to write custom capabilities
 - [ ] Full Ruby/Elixir Standard Library
 - [ ] DISTRIBUTED as a topology
 - [ ] Fiber priorities
 - [ ] Naive fiber memory budgets (only spawned & transfered memory, not shared memory)
 - [ ] Improved fiber fault tolerence
 - [ ] Nearly complete automated Property-based Testing for declarative concurrency constructs

Milestone: CLEAR compiler is self-hosted

## v0.5

 - [ ] EXTREME STRICT compilation pt 2: *most* of ADA's safety
 - [ ] Supervisor to kill killable / cancelable bad fibers
 - [ ] Control Plane Capability Migration -> live shift skewed workloads

## v0.6

 - [ ] Persistence / durability (for shared and distributed data)
