# CLEAR TODO

## v0.1-pre: Architectural Preview

Milestone: A working CLEAR VM with debugger, that supports a decent chunk of the language (including concurrency).


## v0.1

 - [ ] FREEZE + profiling support
 - [ ] STRUCT/FN DEFAULTS
 - [ ] Deadlock protection
 - [ ] HashMap string interning (as default)

## v0.2

 - [ ] Enable MVCC in the language as a syncronization capability
 - [ ] io_uring for networking
 - [ ] STRICT mode compilation
 - [ ] VM supporting the vast majority of the language, near Python/Ruby non-JIT speed
 - [ ] An RSpec like testing framework as the first standard library module
 - [ ] A statistical benchmarking & profiling framework like Go/Rust
 - [ ] `./clear doctor` to automatically fix most syntax, conversion, affine errors and profiling recomendations if you choose
 - [ ] Demand-based processes - don't spin up the max allowed threads unless there's demand
 - [ ] Ability to write custom Control Plane strategies

Milestone: *Basic* SQL/CLEAR database

## v0.3

 - [ ] Implement lock-free ringbuffer as a syncronization capability (with backpressure)
 - [ ] ARM support
 - [ ] MacOS support
 - [ ] actors as an ownership capability
 - [ ] copyOnWrite
 - [ ] EXTREME STRICT compilation: ADA-levels of safety
 - [ ] Control Plane Capability Migration -> live shift contented, skewed workloads to other strategies
 - [ ] VM supports entire language, gradual typing.

Milestone: CLEAR-DB with native queries and hot-reload

Vision is clear: Gradual Typing (Ruby/Python) -> Typed (Rust) -> STRICT Typed (HFT-level C speed) -> EXTREME STRICT (ADA-level safety)

`./clear doctor ` + profiling on replay can take you ~95% of the way from an untyped correct app to ADA-level safety and HFT-C speed automatically.

## v0.4

 - [ ] Ability to write custom capabilities
 - [ ] Full Ruby/Elixir Standard Library
 - [ ] DISTRIBUTED as a topology
