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
 - [ ] Continuous Integration

Milestone: A working CLEAR VM with debugger, that supports a decent chunk of the language (including concurrency).

## v0.1.5 (Target = May 30)

 - [x] IMMUTABLE Stream Observables (only the stream can mutate the underlying data; design in `docs/agents/observables.md`)
    - [x] Lockdown 1/2/3 — already landed on master (commit `8cd91f04`); verified by `spec/borrowed_escape_spec.rb`
    - [x] Phase 1 — Runtime (Zig): AtomicSum/Max/Min/Count/Any/All/Avg/Find/Reduce, StreamSet(T) for DISTINCT, Observable<T>
    - [x] Phase 2 — Compiler (Ruby): @observable Type flag, terminal inference, WITH VIEW + WITH MATERIALIZED VIEW
    - [x] Tests + benchmarks: 60 zig tests, concurrent reader stress, compiler specs, AtomicSum 2.9x faster than @locked Int64
    - Phase 3a (standalone Observable types) deferred to v0.3
    - Observable Maps deferred until streaming-map support exists
 - [x] Finite State Machines for non-conditional, non-reeentrant, and non-nested looping fibers (FSM Phase A + B1 + B2 landed)
 - [x] Re-entrant Thunks (to avoid unbounded recursive growth, auto insert max_depth, auto-insert co-operative yields)
    - [x] Phase 1.1 — Parser: `EFFECTS REENTRANT[:VARIANT]` on FN definitions (commit 4584ff7e)
    - [x] Phase 1.2 — Parser: `REQUIRES x: NON_REENTRANT` constraint clauses (commit ae585446)
    - [x] Phase 1.3 — Annotator: ReentranceBridge unifies `@reentrant` + `EFFECTS REENTRANT` into `fn_node.reentrance_kind` (commit 0da44eb0)
    - [x] Phase 1.4 — `clear fix`: `@reentrant` → `EFFECTS REENTRANT` (commit a66f5b26)
    - [x] Phase 1.5 — `clear fix`: add `REQUIRES <name>: NON_REENTRANT` for unconstrained fn-typed params (commit d9f69cbc)
    - [x] Phase 2 — Warn on unconstrained fn parameters; offer two fixes (REQUIRES NON_REENTRANT auto / EFFECTS REENTRANT interactive) (commit af355b60)
    - [x] Phase 3 — `EFFECTS REENTRANT:TAIL_CALL` strictness: whole-body walker, every self-call MUST be tail-position, error names `:THUNK` fallback (commit cc561d24)
    - [x] Phase 4 — `src/mir/thunk_transform/` pass (THUNK lowering)
        - [x] Phase 4a — Scaffolding: thunk_transform/ skeleton + self-recursion validation (commit a540fa80)
        - [x] Phase 4b — Tail-recursive :THUNK piggybacks on existing TailCall MIR (commit f911fc4b)
        - [x] Phase 4c — Detect simple-recurrence shape (factorial-style); Zig codegen in 4d (commit 84bd6efa)
        - [x] Phase 4d — Zig codegen for simple-recurrence; factorial works end-to-end (commit 08175849)
        - [x] Phase 4e — Cooperative yield via rt.checkYield in trampoline; deep recursion (1000-level) verified (commit 8d039bf5)
        - [x] Phase 4f — Detect mutual recursion + precise error; tagged-union codegen deferred to 4f.1 (commit dd4200ba)
        - [x] Phase 4f.1 — Tagged-union frame codegen for mutual recursion (transpile-tests 298)
        - [x] Phase 4f.2 — `EFFECTS REENTRANT:NOT_LOGICAL` + runtime StackGuard wiring + fixable mutual-recursion error (return type `T` -> `!T`; `System UnexpectedRecursion`)
        - [x] Phase 4f.3 — `EFFECTS REENTRANT:MAX_DEPTH(N)` + per-fn depth counter + fixable third option (return type `T` -> `!T`; `System MaxDepthExceeded` above N; transpile-test 301)
        - [x] Phase 4g — Per-variant stack-sizing dispatch + explicit `@service` requirement (transpile-test 302)
    - [~] Phase 4.1 — `@thunk(N)` call-site override: PARSER RESERVES the syntax (commit landed); runtime semantics (per-call-site monomorphization of the callee + recursive-call rewriting inside the clone) deferred to v0.3 alongside the broader monomorphization pass. Annotator emits "not yet implemented" diagnostic.
    - [~] Phase 4.2 — `@maxDepth(N)` call-site override: same status as 4.1, same monomorphization-pass dependency. Both share one parser path (CallSiteOverride node).
    - [x] Phase 5 — Service-stack reduction
        - [x] Phase 5a — `:THUNK` and `:TAIL_CALL` no longer force `:service` (Phase 4g) + `clear fix` audit nudges plain `EFFECTS REENTRANT` toward bounded variants when shape allows
        - [x] Phase 5b — benchmarks/clear-only/{thunk_recursion,tail_call_loop}: THUNK vs `@service` reentrant (RSS gap), TAIL_CALL vs hand-written loop (~28% gap on hash accumulator)
 - [x] IMMUTABLE Stream Observables (only the stream can mutate the underlying data)
 - [x] Observable aggregations for streaming pipelines (@shared aggregate results)
 - [x] Enable MVCC in the language as a syncronization capability (in progress - already exists in the runtime)
 - [x] Atomics
 - [x] True Synchronization Polymorphism
 - [ ] COPY/CLONE/SPLIT overloading
 - [ ] Design by Contract v1: `WITH GURADED x ... AS y { } ON GuardFail`

 ## v0.2 (Target = July 15)
 - [ ] Zig 0.16.0 style streaming IO (in progress)
 - [ ] Typed Holes
 - [ ] Design by Contract v2: PRE { } and POST { } conditions
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

Milestone: *Basic* SQL/CLEAR database

 - [ ] `@canSmash` on BG/DO blocks: parser recognizes the sigil but compiler errors with "not yet supported, use `@service`" (runtime stack-hysteresis exists; compiler wiring deferred to v0.3) -- spec/can_smash_deferred_spec.rb

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
