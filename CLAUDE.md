# CLAUDE.md

## Project Overview

**CLEAR** is a memory-safe language compiling to Zig. Ruby compiler, arena memory (no GC), ownership semantics, separates **Types** from **Capabilities**.

## MiniVM Rules

Active MiniVM: `examples/minivm/bc_emitter.rb` + `examples/minivm/_bc_runner.cht`.

**NEVER parse Zig code strings in the MiniVM.** `MIR::InlineZig` and `MIR::RawZig` are Zig backend artifacts. The bc_emitter must use the AST fallback (`compile_ast_stmt` / `compile_ast_expr`); never inspect `.code`. If no AST is available, raise `Unimplemented`.

## Build & Test

```bash
./clear build foo.cht                # Default Zig backend (~2s, safety on, 64KB stacks)
./clear build foo.cht --optimized    # LLVM, ReleaseFast (~22s, 16KB stacks)
./clear build foo.cht --safe         # LLVM, ReleaseSafe (~28s)
./clear build foo.cht --stack-check  # Verify per-fn stack usage via objdump
./clear run foo.cht [-- args]
./clear test <file|dir>              # Test with leak detection
./clear profile foo.cht              # Heap/CPU/syscall profiling
./clear doctor foo.profile/          # Analyze profile, print advice
```

Default build has Zig safety checks (bounds/overflow/null) but no `__morestack` (that needs the LLVM backend with the custom machine pass, not yet wired). The 64KB fiber stacks compensate for safety-instrumented frames.

**Test suites (run after compiler changes):**
- `bundle exec prspec spec/` — Ruby specs, parallel, ~1s
- `./clear test transpile-tests/` — all .cht transpile tests
- `cd transpile-tests/module-integration && zig build test` — package integration
- `cd transpile-tests/ffi-integration && zig build test` — FFI integration
- `ruby tools/fuzz/run.rb --matrix --skip-quarantined --out /tmp/clear-fuzz-ci --clean` — full fuzz matrix minus quarantine (run last). Quarantined templates (tools/fuzz/quarantine.txt) have a known bug; `--only-quarantined` runs just those.
- `bundle exec prspec spec/ --tag integration` — CLI/stack-verifier integration (~3-4 min)

**Benchmarks:** `ruby benchmarks/runner.rb [--smoke|--fast|--release] [path | --sequential | --concurrent | --server | --all]`. See `benchmarks/README.md`.

**Coverage / quality:** SimpleCov + Flog + Reek + Flay aggregated by RubyCritic. Pipeline: run specs, then `COVERAGE=1 ./clear test transpile-tests/`, then `bundle exec ruby spec/collate_coverage.rb`, then `bundle exec rubycritic src/`. Standalone: `bundle exec reek|flog|flay|debride src/`. For `debride`, always pass every dir that requires src/ (`src/ examples/minivm/ transpile-tests/`) — omitting one yields false positives.

**Profiling:** see `docs/profiling.md`. `clear doctor` reports Heap (per-site allocs w/ line numbers), CPU (lock fns, memcpy), Syscalls (futex/write/mmap), Hardware counters (IPC, cache, branch). Patterns: `pthread_rwlock_*` >10% → swap `@writeLocked` for `@locked`; `charAtCodepoint` hot → use `indexOf`/`substr`; `smartAlloc` dominant → frame arena overflowing.

## Architecture

5-pass Ruby compiler. Each pass owns a category of facts and stamps them on the AST. Downstream passes READ stamps; they do NOT re-derive.

| Pass | File(s) | Stamps |
|---|---|---|
| 0. Parse | `src/ast/lexer.rb`, `src/ast/parser.rb` | raw AST |
| 1. Annotate | `src/annotator.rb`, `src/ast/type.rb`, `src/ast/scope.rb`, `src/mir/ownership_graph.rb` | `type_info`, `full_type`, `was_moved`, `container_borrow`, `matched_stdlib_def`, `param[:takes]` |
| 2a. Escape analysis | `src/mir/escape_analysis.rb` | `storage`, `provenance` on declarations |
| 2b. Cleanup + MIR | `src/mir/promotion_plan.rb`, `src/mir/control_flow.rb`, `src/mir/mir_lowering.rb` | `bindings[name] = entry`; inline MIR nodes |
| 3. Check | `src/mir/mir_checker.rb` | (verify only — see 7 invariants below) |
| 4. Emit | `src/backends/transpiler.rb`, `src/mir/mir_emitter.rb` | Zig source |

**Single-source-of-truth contract:** if you find yourself writing `if node.is_a?(...)` in lowering or emitting to make a *semantic* decision (not a syntactic dispatch), you are re-deriving. Read the stamp instead.

### MIR Pipeline Roles

- **MIRLowering (`mir_lowering.rb`)** makes ALL memory decisions. Cleanup node TYPE encodes the contract:
  - `MIR::Cleanup(name, entry)` → `defer [if (!name_moved)] cleanup(name)`. Use when current scope owns for full lifetime.
  - `MIR::ErrCleanup(name, entry)` → `errdefer cleanup(name)`. Use when ownership transfers out on success: TAKES args, struct/union field temps, return-value hoisted temps.
  - `MIR::MoveMark(name)` → `name_moved = true;`. Must precede the move (GIVE, TAKES consumption, return). Never use flags to distinguish defer vs errdefer — the node type IS the policy.
  - `MIR::AllocMark` → checker marker, no emitted code.
  - Every heap alloc has an `AllocMark` + `Cleanup`/`ErrCleanup`. Frame values that escape promote at declaration (never frame-then-promote). Loops with frame allocs emit `FrameSave`/`FrameRestore` per iteration.
- **MIRChecker (`mir_checker.rb`)** verifies, never decides. 7 invariants:
  1. Every `AllocMark` has a matching `Cleanup`/`ErrCleanup` (LEAK).
  2. Every `Cleanup`/`ErrCleanup` has a matching `AllocMark` (ORPHAN).
  3. Allocator on the AllocMark matches the cleanup (ALLOC_MISMATCH).
  4. Heap-returning call in statement position is bound to a variable (HPT_LEAK).
  5. InlineZig/RawZig with CheatLib ownership effects declares `stdlib_def`.
  6. InlineZig allocator symbols match container's AllocMark (INLINE_ALLOC_MISMATCH).
  7. Loop bodies with frame allocs have per-iteration `restoreLoopMark` defer.

  Each new check added to the checker is a signal that the lowering made the decision wrong. Fix the lowering. Never add flag inspection, position analysis, name-pattern heuristics, or return-value cross-referencing.
- **MIREmitter (`mir_emitter.rb`)** is a pure template. NO type inspection, NO allocator choice, NO position-aware emit. The emitter runs AFTER the checker; any decision it makes is unverified.

### Memory Safety Invariants

These MUST hold. Verify before every commit.

1. **Single allocator per binding** — fixed at declaration, never changed. (ALLOC_MISMATCH)
2. **Every alloc has a cleanup on every path** — error paths, early returns, break/continue all included. (LEAK)
3. **No cleanup without alloc.** (ORPHAN)
4. **Moved values are never cleaned up** — `_moved` guard via `MIR::MoveMark`.
5. **Frame values never escape** — promote to heap AT DECLARATION, never frame-then-promote. (FRAME_ESCAPE)
6. **Loops with frame allocs have per-iteration mark/rewind.** (FRAME_OVERFLOW)
7. **Transpiler makes zero memory decisions** — mechanical emission from MIR + stamps.
8. **All stdlib behavior is registry-driven** — only `src/ast/std_lib.rb` and `src/ast/type.rb` may hold type-specific memory logic.
9. **Error paths preserve allocator identity** — no `catch original_value` returning from a different allocator.
10. **Union cleanup uses the union's allocator** (follows from INV-1).
11. **All CheatLib calls go through registries** (STD_LIB, BUILTIN_OPS, POOL/SET/MAP_METHODS, INDEX_OPS). Only exception: marker calls (cleanup, promote, promoteDeep, rcCreate, Locked.init), verified at the marker level. Check: `grep 'MIR::Call.new("CheatLib.'` should return only marker implementations.
12. **RawZig/InlineZig are unsafe escape hatches** — the checker can't see inside. Always set `ownership_contract` (RawZig) / `stdlib_def` (InlineZig) when allocating or transferring ownership. Prefer BUILTIN_OPS over raw strings. Pure expressions (casts, ranges, field access, `@intCast`, etc.) are safe without annotation. NEVER alloc/free inside without a matching outside MIR::AllocMark + Cleanup; NEVER move ownership in without MoveMark + guarded Cleanup; NEVER return a frame value without EscapePromote.
13. **Single source of truth for "callee takes":** `arg.was_moved` (set by annotator when `param[:takes] || GIVE`). Lowering does NOT re-derive from `CopyNode`/`MoveNode` syntax. COPY into a borrow-position param is NOT a take.
14. **Cleanup contracts are inherited, never synthesized at the destination.** Every consuming site (TAKES param, field store, container store, return) uses the source's cleanup recipe via the same `entry(...)` builders locals use (`classify_collection`, `classify_struct_cleanup_fields`, …). `walk_takes_params` must NOT have a parallel dispatch table.
15. **Container shape dispatches via runtime polymorphism** — `@list`/`@pool`/`@set`/HashMap length/index/iter emit `CheatLib.len`/`getAt`/`setAt` or `MIR::ItemsAccess(safe: true)`. Comptime `@hasField` resolves shape with zero cost. Lowering does NOT branch on `is_param`/`is_field_access` to pick shape.
16. **Storage and provenance live on declarations** — `EscapeAnalysis` is the single writer. Use sites READ; they do NOT re-classify.
17. **FSM emission is ONE general transform.** Every FSM-eligible BG body lowers through one universal CPS transform (segment-split at suspend points, liveness across suspends, state-machine emit). NEVER add a per-shape `emit_fsm_*_bg_code` function, NEVER add shape-detection branching to the classifier, NEVER copy the transform "with a tweak". The classifier asks one question: "FSM-eligible?". New body shapes extend the suspend-op table or control-flow visitor.

### Adding a new escape scenario

A new feature is an escape scenario if a frame-allocated value could be read after its declaring frame is rewound: new return-like construct, new capture (closure/fiber/async), new heap-container store, new function attribute implying heap-owned return, or new higher-order propagation.

1. Write a failing transpile-test or spec demonstrating UAF/leak first.
2. Add detection in `src/mir/escape_analysis.rb` Phase E2. Set `node.storage = :heap` and `ti.provenance = :heap` (exception: shared struct Type — see cases `:heap_ptr_return` and `:assign_escape`).
3. New category of heap-returning function? Add detection to Phase E1 (`compute_heap_return_fns!`) and call-site tagging to Phase E3.
4. Do NOT add a new `upgrade_*` method to `MIRPass`. Do NOT add a new invariant to `MIRChecker`. Fix `EscapeAnalysis` instead.

Reference docs: `mir-bugs.md` (known MIR violations), `alloc-bugs.md` (frame-then-promote gaps), `memory-safety.md` (full plan).

## Language Semantics

**Sigils:** `$` pipeline/interp, `!` mutation, `|>` SMOOTH (safe pipeline w/ error prop), `_` placeholder, `!!` explicit panic.

**Ownership / capabilities — bindings, not types.** Two sigil groups:
- **Group 1 (sync / ownership wrappers):** `@locked`, `@writeLocked`, `@shared` (Arc), `@multiowned` (Rc), `@local`. Stored on `SymbolEntry#sync` and `#storage`. Composed via `MIR::CapWrap`.
- **Group 2 (data shape):** `@pool`, `@list`, `@set`, `@map`, `@sharded`, `@striped`. Stored on `Type`.

Chains: `pool: Env[N]@pool:shared:locked` = Pool<Env> wrapped in Arc<RwLock<…>>. `Type#bare_data_type` strips Group 1 for `ContainerInit`.

**Ownership transfer:** `GIVE` (caller → callee), `TAKES` (callee receives). Zero implicit copies. Rc/Arc bump refcounts (not copies). Primitives, strings, enums are Copy. Unions with heap variants (`@indirect`, `[]T` slices, collections) are non-Copy. Borrow state lives in `OwnershipGraph`; it is the single source of truth — do not inspect AST node types for borrow decisions.

**`WITH` blocks** unwrap capabilities at the call site. `WITH ... AS alias { ... }` aliases are non-escaping — `RETURN alias` / `alias.field` rejected; `RETURN COPY alias` allowed (COPY breaks the borrow).

**`REQUIRES p: LOCKED`** constrains a param's sync family without committing to an implementation. Body uses `WITH EXCLUSIVE c { … }` and works for `@locked` or `@writeLocked` callers; `@local` callers rejected.

**`WITH MATCH c WHEN @locked -> ... WHEN @local -> ...`** for per-modality paths.

**Comptime Arc-unwrap** at WITH lowering uses Zig `@hasField`:
```zig
(if (@hasField(@TypeOf(pool.*), "ctrl")) pool.ctrl.data.* else pool.*)
```
Same body works for `@shared:locked` (Arc<Locked<T>>) and bare T with zero runtime cost.

**Effect lattice** (`:yield`, `:alloc_heap`, `:io`, `:fail`) inferred per fn. Used by hold-lock-across-yield, naked nested-WITH, and reentrant-lock checks.

**Cross-module sync propagation** (priority order):
1. REQUIRES seed (`function_analysis.rb`) — `REQUIRES p: LOCKED` seeds `entry.sync = :locked` at decl.
2. Caller propagation (`propagate_caller_sync!` using `collect_callsites_deep`).
3. Storage axis fallback (`escape_analysis.rb`) — `shared?` / `multiowned?` types default to `:shared` / `:multiowned`.

## Design Principles

- **Immutable by default.** `x = value` declares; `MUTABLE x = value` declares mutable; `x = value` (in scope, mutable) reassigns.
- **Arena memory.** Scope-local; escapes via RVO or page handoff.
- **Local reasoning.** `WITH RESTRICT` scopes mutable poisoning.
- **Fortress APIs.** Public APIs strictly typed; all errors handled.

## TODO

- Lambda `USE` captures are borrows by default. Add `USE TAKES y` for move captures (like Rust's `move ||`).

## Contributing

### Before committing:

Verify the Memory Safety Invariants (INV-1 through INV-10 above) are not violated by your changes. Specifically:
- If you added or changed an allocation: does it have a matching cleanup on every path? (INV-2)
- If you added a new type or collection: is its cleanup driven by MIR nodes, not transpiler heuristics? (INV-7, INV-8)
- If you changed escape analysis or storage decisions: does every escaping value get heap-allocated at declaration, not frame-then-promoted? (INV-1, INV-5)
- If you changed error handling: does the error path preserve allocator identity? No `catch` fallbacks returning data from a different allocator? (INV-9)
- Run `bundle exec prspec spec/`, `./clear test transpile-tests/`, then `ruby tools/fuzz/run.rb --matrix --skip-quarantined --out /tmp/clear-fuzz-ci --clean` to verify no regressions.

### When fixing a bug:

1. Create a test (ideally at a unit stage) to *PROVE* the bug exists before attempting to fix it.
2. Identify the architecturally appropriate place to fix the bug.
   * Ideally fixing bugs leads to *reducing* overall complexity, not adding complexity by applying a band-aid
3. Consider: is this the *ONLY* case for this bug, or does this bug have a broader scope
   * If the bug has a broader scope, expand the tests to show *ALL* cases you can think of for the bug
4. Update the code making minimal changes besides fixing the bug at the architecturally correct place to minimize added complexity.
5. Commit changes to fix bugs as stand-alone bug fixes. Limit including bug fixes as part of other commits.

### When adding a feature:

If you ever encounter a compiler bug, stop everything you're doing, and fix the bug.  See the above section for how to do this appropriately.

If you ever find a limitation in the language that you have to work around, stop, identify the problem, and suggest how the language needs to be improved to fix this limitation forcing workarounds.

## Definition of Done

Before concluding a task and declaring it complete, you must explicitly review and verify the following:

### Transpilation Review Requirements

If the transpiler in src/ is touched, make these checks:

- **Memory Safety Invariants:** Verify that no existing MIRChecker invariants (INV-1 through INV-10) were bypassed or modified.
- **Escape Analysis Completeness:** Confirm that any frame-allocated values that survive their declaring frame are explicitly upgraded to the heap in `EscapeAnalysis`.  If any new escape method is added, it must be considered *EVERYWHERE* that does any escape analysis.
- **Zero Transpiler Band-aids:** Ensure no special logic for intrinsic/standard library functions was added outside of `src/ast/std_lib.rb` or `src/ast/type.rb`.  No new RawZig is allowed.  Add Zig code in zig/ and thoroughly unit test it there.  Do not shoe-horn it into the transpiler.
- **Zero Runtime Overhead:** The transpiler should never add runtime overhead. You need explicit permission to add any runtime overhead. Zig comptime should be used to achieve all abstractions unless explicitly permitted otherwise.

### Concurrency Review Requirements

If the runtime code in zig/ is touched, make these checks:

- **Atomics Introduced:** You must write a **Loom test** to exhaust CPU instruction reordering and memory visibility permutations.
- **Locks, Threads, or FFI Introduced:** You must write a **Hammer test** (oversubscribed threads, saturated queues) and run it with TSan/ASan. For Zig, ensure execution via `std.testing.allocator` to catch leaks.
- **Retries, Timeouts, Network, or Disk I/O Introduced:** You must write a deterministic **VOPR (simulator) test** using a deterministic seed to catch combinatoric failures. Do not write real-time Chaos tests.
- **File Operations / General Concurrency:** Actively search for logic races, starvation, or priority inversion. If found, write a test proving the failure, then implement the fix.
- **Performance:** Code on critical, hot paths must be strictly non-blocking. This definitively prohibits any form of lock acquisition and any global heap allocations (which inherently rely on hidden locks) within these paths.

### Other Review Requirements

- **Changes to Tests:** Make sure there are no hacks in test changes. Any changes to tests should be because there was a bug before, or the code has changed such that the new expectations match a correct state.
- **Deletions to Tests:** No test should be deleted unless 1: the corresponding functionality was deleted and the test is no longer needed, or 2: it was a test-nothing test, or 3: it is redundant with other tests.
- **Test Additions:** Do not test nothing just to cover lines. Make sure that tests actually test that the code works correctly, not just that things "run" and don't fail. Avoid adding redundant tests when an existing test could be modestly expanded to test a new expectation. Avoid abstractions in tests as much as possible. Tests can repeat themselves. Production code should not repeat itself. Avoid adding production changes *specifically* for testing. To the extent possible use test code and mocks to test what you need to test. Production code ideally is readable and has no concerns or special cases for testing.


## Output
- Answer is always line 1. Reasoning comes after, never before.
- No preamble. No "Great question!", "Sure!", "Of course!", "Certainly!", "Absolutely!".
- No hollow closings. No "I hope this helps!", "Let me know if you need anything!".
- No restating the prompt. If the task is clear, execute immediately.
- No explaining what you are about to do. Just do it.
- No unsolicited suggestions. Do exactly what was asked, nothing more.
- Structured output only: bullets, tables, code blocks. Prose only when explicitly requested.

## Token Efficiency
- Compress responses. Every sentence must earn its place.
- No redundant context. Do not repeat information already established in the session.
- No long intros or transitions between sections.
- Short responses are correct unless depth is explicitly requested.

## Typography - ASCII Only
- No em dashes (-) - use hyphens (-)
- No smart/curly quotes - use straight quotes (" ')
- No ellipsis character - use three dots (...)
- No Unicode bullets - use hyphens (-) or asterisks (*)
- No non-breaking spaces

## Sycophancy - Zero Tolerance
- Never validate the user before answering.
- Never say "You're absolutely right!" unless the user made a verifiable correct statement.
- Disagree when wrong. State the correction directly.
- Do not change a correct answer because the user pushes back.

## Accuracy and Speculation Control
- Never speculate about code, files, or APIs you have not read.
- If referencing a file or function: read it first, then answer.
- If unsure: say "I don't know." Never guess confidently.
- Never invent file paths, function names, or API signatures.
- If a user corrects a factual claim: accept it as ground truth for the entire session. Never re-assert the original claim.
- Whenever something doesn't work, you should first assume that your changes broke it. Code is always committed at working states.

## Code Output
- Avoid brittle, narrow solutions. When fixing bugs, always consider: is this the only case? Or does this fix apply more broadly? Is the band-aid solution correct. Prefer architecturally correct fixes, that solve the problem at the root and apply to all cases.
- Return the simplest working solution. No over-engineering.
- No abstractions or helpers for single-use operations.
- No speculative features or future-proofing.
- No docstrings or comments on code that was not changed.
- Inline comments only where logic is non-obvious.
- Read the file before modifying it. Never edit blind.

## Warnings and Disclaimers
- No safety disclaimers unless there is a genuine life-safety or legal risk.
- No "Note that...", "Keep in mind that...", "It's worth mentioning..." soft warnings.
- No "As an AI, I..." framing.

## Session Memory
- Learn user corrections and preferences within the session.
- Apply them silently. Do not re-announce learned behavior.
- If the user corrects a mistake: fix it, remember it, move on.

## Scope Control
- Do not add features beyond what was asked.
- Do not refactor surrounding code when fixing a bug.
- Do not create new files unless strictly necessary.

## Override Rule
User instructions always override this file.
