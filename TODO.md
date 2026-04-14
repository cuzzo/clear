# CLEAR TODO

## v0.1-pre: Architectural Preview

Milestone: A working CLEAR VM with debugger, that supports a decent chunk of the language (including concurrency).


## v0.1

 - [ ] FREEZE + profiling support
 - [ ] STRUCT/FN DEFAULTS
 - [ ] Partial Deadlock protection (in progress - may cancel)
 - [ ] String@symbol
 - [ ] HashMap string interning as default

## v0.2

 - [ ] Finite State Machines for non-conditional, non-reeentrant, and non-nested looping fibers
 - [ ] Cancelable fibers
 - [ ] Built-in support for fiber RACEs
 - [ ] Enable MVCC in the language as a syncronization capability (in progress)
 - [ ] io_uring for networking (in progress)
 - [ ] STRICT mode compilation
 - [ ] VM supporting the vast majority of the language, near Python/Ruby non-JIT speed
 - [ ] VM can automatically generate and run LOOM tests for concurrent code
 - [ ] An RSpec like testing framework as the first standard library module
 - [ ] A statistical benchmarking & profiling framework like Go/Rust
 - [ ] `./clear doctor` to automatically fix most syntax, conversion, affine errors and profiling recomendations if you choose
 - [ ] Demand-based processes - don't spin up the max allowed threads unless there's demand (in progress)

Milestone: *Basic* SQL/CLEAR database

## v0.3

 - [ ] CPS to support conditional & nested-looping fibers
 - [ ] Implement lock-free ringbuffer as a syncronization capability (with backpressure)
 - [ ] ARM support
 - [ ] Actors as an ownership capability
 - [ ] copyOnWrite
 - [ ] Ability to write custom Control Plane strategies
 - [ ] Control Plane Capability Migration -> live shift contented workloads
 - [ ] VM supports entire language, gradual typing.

Milestone: CLEAR-DB with native queries and hot-reload

Vision is clear: Gradual Typing (Ruby/Python) -> Typed (Rust) -> STRICT Typed (HFT-level C speed) -> EXTREME STRICT (ADA-level safety)

`./clear doctor ` + profiling on replay can take you ~95% of the way from an untyped correct app to ADA-level safety and HFT-C speed automatically.

## v0.4

 - [ ] EXTREME STRICT compilation pt 1: en route to ADA-levels of safety (just blocking compilation where required, ensuring the syntax is forward compatible)
 - [ ] MacOS support
 - [ ] Ability to write custom capabilities
 - [ ] Full Ruby/Elixir Standard Library
 - [ ] DISTRIBUTED as a topology
 - [ ] Fiber priorities
 - [ ] Naive fiber memory budgets (only spawned & transfered memory, not shared memory)
 - [ ] Improved fiber fault tolerence

## v0.5

 - [ ] EXTREME STRICT compilation pt 2: *most* of ADA's safety
 - [ ] Supervisor to kill killable / cancelable bad fibers
 - [ ] Control Plane Capability Migration -> live shift skewed workloads
