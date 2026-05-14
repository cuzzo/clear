# CLEAR TODO

## v0.1-pre (Target = May 10)

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
 - [x] Syntax maturity cleanup / sweep
 - [ ] Comment Cleansing

## v0.1 (Target = May 30)

 - [x] IMMUTABLE Stream Observables (only the stream can mutate the underlying data)
 - [x] Finite State Machines
 - [x] Re-entrant Thunks + Trampolines
 - [x] IMMUTABLE Stream Observables (only the stream can mutate the underlying data)
 - [x] Observable aggregations for streaming pipelines (@shared aggregate results)
 - [x] Enable MVCC in the language as a syncronization capability (in progress - already exists in the runtime)
 - [x] Atomics
 - [x] True Synchronization Polymorphism
 - [x] COPY/CLONE/SPLIT overloading (via SHARE - in progress)
 - [x] True Polymorphic return
 - [x] Design by Contract v1: `WITH GURADED x ... AS y { } ON GuardFail`, `PRE { }` and `POST { }` *RUNTIME* 
 - [x] Typed Holes
 - [ ] LEND keyword (attach lifetimes to functions / execution boundaries you LEND to)
 - [ ] Examples: mal v5, brnfk, are we fast yet, 1brc, NN
 - [ ] Typed Transpiler: ~90% of slots & returns, in prep for self-hosting, to test-bed plans for Property Based Testing 
 - [ ] Loom Coverage Detection and *near* 100% coverage of Atomic Operations
 - [ ] VOPR Coverage Detection and *near* 100% coverage of non-deterministic operations
 - [ ] Formal Verification for Gated Acccess, Execution Boundary Crossing, Escape Analysis, FSM Transformation (tracker: `docs/agents/fv-hardening-todo.md`)

Milestone: A working CLEAR VM with debugger & time travel, that supports a decent chunk of the language (including concurrency).

 ## v0.2 (Target = July 15)
 - [ ] Zig 0.16.0 style streaming IO (in progress)
 - [ ] Design by Contract v2: PRE { } Comptime
 - [ ] Implicit Logical TOCTAU made impossible via `@derivative` on `@shared` values and `@allowStale` to allow possible TOCTAU only *EXPLICITLY*.
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
 - [ ] Gradual / Hidden COPY/CLONE sinking in --gradual / --vm / --easy mode.
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

## Self-host preparation (`src/` Ruby cleanup)

Source signal: 70 .rb files / ~57k LOC in `src/`. Anti-pattern census from grep + `reek` + `debride`:

  - 1409 `is_a?` checks (141 `is_a?(Hash)` = hash-as-struct; 99 `is_a?(Array)` = array-as-tuple; 67 mixed `is_a?(String)`/`is_a?(Symbol)`)
  - 635 `respond_to?` (duck-typing escape hatches; 289 surface as reek `ManualDispatch`)
  - 228 `.nil?` checks (164 surface as reek `NilCheck`)
  - 64 reek `DataClump` clusters (top: PipelineHost/PipelineGenerator with `(list_node, smooth_node)` through 18 methods, Formatter::Emitter `(start, toks)` through 17, etc.)
  - 91 `ControlParameter` + 54 `BooleanParameter` (flag args switching behavior)
  - 313 `Struct.new` already in use → good baseline

Each P0 item is mechanical and self-verifying via existing tests; doing them BEFORE typing lands keeps the typing pass cheap. Each P1 item depends on at least one P0 item.

### P0 — must complete before declaring "ready to type"

 - [ ] Extract top hash-as-struct schemas (target: 141 `is_a?(Hash)` → ~40): `Schema` for the `schema.is_a?(Hash) && schema[:kind] == :union` pattern in promotion_plan.rb / type.rb / annotator.rb / mir_lowering.rb (clustered: 36+25+24+14 sites). **Subsumes String/Symbol normalization:** ~15 of the 65 `is_a?(String|Symbol)` sites are schema mixed-key filters (`k.is_a?(Symbol)` rejecting `:kind`/`:field_defaults` metadata vs String field names) — typed Schema (`kind: Symbol`, `field_names: Array[String]`) kills them at the root. The other ~50 sites are either correct primitive-rejection in AST walkers or syntactic dispatch on `node.name`, NOT normalization.
 - [ ] `PipelineSite`/`PipelineFrame` struct: collapse the `(id, options, rt_name, workers_code, list_node, smooth_node, stream_node, conc_op, lhs)` clump that DataClump-flags 25+ methods across PipelineHost / PipelineGenerator / PipelineRewriter
 - [ ] `Formatter::Emitter::EmitterState` struct: collapse the `(toks, start, out, pc, po, arrow_idx)` clump (17-method DataClump cluster, single-class, smallest blast radius — good warm-up extraction)
 - [ ] Tighten nilable fields where field is always set in practice: top targets `sync` (13), `node` (7), `out` (6), `schema` (5), `entry`/`code`/`expr_type`/`layout`/`mir`/`name`/`ownership`/`path`/`rl`/`rt`/`syn` (3 each); replace `.nil?` guards with construction-time invariants

### P1 — high-leverage, depends on P0

 - [ ] AST dispatch via Ruby 3 pattern matching: convert `if node.is_a?(AST::Identifier) ... elsif node.is_a?(AST::BinaryOp) ...` chains (~600 sites) to `case node in AST::Identifier(...)`. Maps directly to CLEAR union-tag dispatch later.
 - [ ] Array-as-tuple → `Data.define(:kind, :value, :loc)` etc. (99 `is_a?(Array)` sites). Token tuples in lexer/parser, MIR ops with positional payload, multi-return method results.
 - [ ] `MIRPass::WalkState` + `OwnershipDataflow::DataflowStep` struct extractions (`(bindings, result, stmt)` 9× / `(node, state, consumed)` 6× DataClump clusters)
 - [ ] `respond_to?` purge (635 → ~50): each site is one of three things — missing trait (introduce module/interface), wrong type (fix caller), genuine duck-typing on heterogeneous external input (keep, document)
 - [ ] Add Sorbet (or rbs+steep) to Gemfile; bootstrap with `tapioca init`; flip files from `# typed: false` to `# typed: true` per file. Acceptance gate per file: `# typed: strict` before it's a self-host candidate.

### P2 — structural cleanup

 - [ ] Eliminate `ControlParameter` (91) + `BooleanParameter` (54): every flag arg should be a separate method or a sealed enum input
 - [ ] `LongParameterList` audit (135): residual after P0 PipelineSite / EmitterState extractions; remaining are either missing structs or genuinely 5+ orthogonal inputs
 - [ ] Method-return-type uniformity audit: methods that return `value | nil` use Optional; methods that return different value types in different paths split or use sealed union
 - [ ] Custom Rubocop cops as CI signal: `Project/HashAsStruct` (flags `is_a?(Hash)` near `[:key]` access), `Project/UnnecessaryNilCheck` (flags `.nil?` on locals never assigned nil), `Project/SymbolOrString` (flags the 2-arm dispatch). ~50 lines each.
 - [ ] FsmTransform::RecursiveSplitter `(after_idx, builder, lowering)` 12-method DataClump cluster

### P3 — nice-to-have / cosmetic

 - [ ] `UncommunicativeVariableName` cleanup pass (890 reek hits) — names like `n`, `t`, `p` in non-trivial scopes
 - [ ] `TooManyStatements` method splits (993 hits) — only where NOT intrinsic AST/MIR dispatch (those should stay as one method)
 - [ ] `flog` triage: top-30 by score, refactor only the ones that aren't dispatch-shaped (rest are accidentally-flagged intrinsic complexity)
 - [ ] `DuplicateMethodCall` cleanup (3637 reek hits): mostly local-let extractions, low-leverage but reduces noise

### Acceptance criteria for "this file is self-host ready"

A file passes when ALL of:
 - [ ] `# typed: strict` (Sorbet or equivalent rbs)
 - [ ] Zero `is_a?(Hash)` calls
 - [ ] Zero `respond_to?` calls (or each remaining one is documented as genuine external-input duck-typing)
 - [ ] Zero unguarded `.nil?` checks (every survivor is on a typed-nilable field, locally justified)
 - [ ] Reek output for that file shows no `DataClump`, `LongParameterList`, `ControlParameter`, or `BooleanParameter` warnings

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
