# CLEAR TODO

## v0.1 (Target = May 1)

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
 - [ ] `./clear fix`
 - [ ] Binding metadata for capabilities + `REQUIRES` for overloaded syncronization strategies.

Milestone: A working CLEAR VM with debugger, that supports a decent chunk of the language (including concurrency).

## v0.2 (Target = July 15)

 - [ ] IMMUTABLE Stream Observables (only the stream can mutate the underlying data)
 - [ ] Finite State Machines for non-conditional, non-reeentrant, and non-nested looping fibers
 - [ ] Re-entrant Thunks (to avoid unbounded recursive growth, auto insert max_depth, auto-insert co-operative yields)
 - [ ] Cancelable fibers
 - [ ] Built-in support for fiber RACEs
 - [ ] Enable MVCC in the language as a syncronization capability (in progress, already exists in the runtime)
 - [ ] STRICT mode compilation
 - [ ] Observable aggregations for streaming pipelines (@shared aggregate results)
 - [ ] VM supporting the vast majority of the language, near Python/Ruby non-JIT speed
 - [ ] VM can automatically generate and run LOOM tests for concurrent code
 - [ ] An RSpec like testing framework as the first standard library module
 - [ ] A statistical benchmarking & profiling framework like Go/Rust
 - [ ] `./clear fix` fixes *most* errors that *can* be fixed.
 - [ ] Typed Holes
 - [ ] Zig 0.16.0 style streaming IO 
 - [ ] Demand-based processes - don't spin up the max allowed threads unless there's demand (in progress)
 - [ ] HashMap string interning
 - [ ] @sorted for lists, sets, hashmaps.
 - [ ] Automated Property-based Testing for declarative concurrency constructs pt 1.

Milestone: *Basic* SQL/CLEAR database

## v0.3 (Target = Oct 1)

 - [ ] CPS to support conditional & nested-looping Finite State Machine fibers
 - [ ] Full Infinite Stream support
 - [ ] Stream Join (declarative, basic)
 - [ ] Implement lock-free ringbuffer as a syncronization capability (with backpressure)
 - [ ] ARM support
 - [ ] Actors as an ownership capability
 - [ ] copyOnWrite
 - [ ] Ability to write custom Control Plane strategies
 - [ ] Control Plane Capability Migration -> live shift contented workloads
 - [ ] VM supports entire language, gradual typing.
 - [ ] Automated Property-based Testing for declarative concurrency constructs pt 2.

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


## v0.5

 - [ ] EXTREME STRICT compilation pt 2: *most* of ADA's safety
 - [ ] Supervisor to kill killable / cancelable bad fibers
 - [ ] Control Plane Capability Migration -> live shift skewed workloads

## v0.6

 - [ ] Persistence / durability (for shared and distributed data)
