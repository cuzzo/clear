# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**CLEAR** is a memory-safe programming language that combines the ease of Ruby/Python with Rust-like safety. It features arena-based memory management (no garbage collector), ownership semantics, and separates **Types** from **Capabilities**.

## Build & Test Commands

```bash
# --- clear CLI (preferred) ---
./clear build foo.cht                # Default: Zig backend, ~2s, safety checks, 64KB stacks
./clear build foo.cht -o bin/app     # Custom output path
./clear build foo.cht --stack-check  # Build + verify stack usage per function via objdump
./clear build foo.cht --optimized    # LLVM backend, -O ReleaseFast (~22s, 16KB stacks)
./clear build foo.cht --safe         # LLVM backend, -O ReleaseSafe (~28s, safety + optimization)
./clear run foo.cht                  # Build + execute
./clear run foo.cht -- --port 8080   # Pass args to program
./clear test foo.cht                 # Test single file with leak detection
./clear test transpile-tests/        # Test all .cht files in directory (130 tests)
./clear profile foo.cht              # Build + run with heap/CPU profiling
./clear doctor foo.profile/          # Analyze profile data, print optimization advice

# --- Full test suites ---
bundle install                       # Install Ruby dependencies
bundle exec prspec spec/              # Run all Ruby specs in parallel (~1s, excludes integration)
bundle exec prspec spec/ --tag integration  # Run integration tests (builds binaries, ~3-4 min)

# Package integration test
cd transpile-tests/module-integration && zig build test

# FFI integration test
cd transpile-tests/ffi-integration && zig build test

# Example tests (run before committing)
./clear test examples/testing/basic_test.cht
./clear test examples/testing/stub_ufcs.cht
```

### Build Modes

| Flag | Backend | Time | Safety | Stacks | Use |
|------|---------|------|--------|--------|-----|
| (default) | Zig x86 | ~2s | Bounds/overflow | 64KB | Development |
| `--optimized` | LLVM | ~22s | None | 16KB | Benchmarks, deployment |
| `--safe` | LLVM | ~28s | Bounds/overflow | 16KB | Debugging optimized builds |

**NOTE**: The default build does NOT have stack-smash protection (`__morestack`). That
requires the LLVM backend with the custom machine pass (not yet integrated into `clear`).
Zig's safety checks (bounds, overflow, null) ARE enabled in the default build. The 64KB
fiber stacks compensate for the larger stack frames that safety instrumentation produces.

### Test Suites

Run **all four** after making changes to the compiler:
- **Ruby unit specs**: `bundle exec prspec spec/` (parallel, ~1s, excludes integration)
- **transpile-tests**: `./clear test transpile-tests/` (130 tests)
- **module-integration**: `cd transpile-tests/module-integration && zig build test`
- **ffi-integration**: `cd transpile-tests/ffi-integration && zig build test`

Run **integration specs** after changes to the CLI or stack verifier:
- **Ruby integration specs**: `bundle exec prspec spec/ --tag integration` (~3-4 min, builds binaries)

## Benchmarks

```bash
# Benchmark runner modes
ruby benchmarks/runner.rb --smoke benchmarks/server/02_json_api/      # CLEAR only, fast (~5s)
ruby benchmarks/runner.rb --fast benchmarks/sequential/04_hashmap/    # All langs, reduced (~30s)
ruby benchmarks/runner.rb benchmarks/sequential/04_hashmap/           # Normal (default)
ruby benchmarks/runner.rb --release benchmarks/sequential/04_hashmap/ # Exhaustive (5x load)
ruby benchmarks/runner.rb --sequential                                 # Sequential benchmarks
ruby benchmarks/runner.rb --concurrent                                 # Concurrent benchmarks
ruby benchmarks/runner.rb --server                                     # Server benchmarks
ruby benchmarks/runner.rb --all                                        # All benchmarks
ruby benchmarks/runner.rb --smoke --all                                # Smoke test all benchmarks
ruby benchmarks/runner.rb --cores=2 benchmarks/concurrent/09_kvstore/ # Control core count
```

See `benchmarks/README.md` for the full benchmark index and details.

## Profiling

When debugging performance issues, use `clear profile` and `clear doctor`:

```bash
./clear profile foo.cht              # Build with alloc tracking + run with perf/strace
./clear doctor foo.profile/          # Analyze and print actionable advice
```

Doctor output has four sections:
- **Heap**: per-site allocation counts with CLEAR line numbers. Look for hot allocators (charAtCodepoint, intToString, concat) and leak candidates (allocs with 0 frees).
- **CPU**: top functions by sample count. Look for lock functions (`pthread_rwlock_*`, `pthread_mutex_*`) indicating contention, and `memcpy`/`memmove` indicating copy overhead.
- **Syscalls**: top syscalls by time. Look for `futex` (contention), `write` (I/O bound), `mmap` (allocation pressure).
- **Hardware counters**: IPC, cache misses, branch misses. High LLC miss rate (>20%) means working set exceeds cache. High branch misses (>5%) suggest unpredictable control flow.

Common patterns:
- `pthread_rwlock_*` > 10% CPU → switch `@writeLocked` to `@locked` for write-heavy workloads
- `charAtCodepoint` hot in heap profile → replace character-by-character parsing with `indexOf`/`substr`
- `smartAlloc` dominant → frame arena overflowing to heap; reduce per-iteration allocations
- High LLC miss rate + hashmap hot → inherent to random-access data structures; increase shard count or prefetch

See `docs/profiling.md` for a full case study.

## Architecture

The compiler is a 5-pass system written in Ruby:
- **Pass 0: Parsing:** `src/ast/lexer.rb`, `src/ast/parser.rb`. Builds the raw AST.
- **Pass 1: Annotation:** `src/annotator.rb`, `src/ast/type.rb`. Performs type inference, symbol resolution, and capability checks.
- **Pass 2: Dataflow & MIR Lowering:** `src/mir/control_flow.rb`, `src/mir/ownership_graph.rb`, `src/mir/promotion_plan.rb`.
  - Computes `PromotionPlan` (escape promotion) and `CleanupPlan` (cleanup requirements).
  - Performs `Escape Analysis` and forward `OwnershipDataflow` on the CFG.
  - Lowers all `Alloc`/`Dealloc`/`Free`/`Move`/`Promote` events into explicit **MIRNodes** (`MIR::Alloc`, `MIR::Drop`, `MIR::Promote`, `MIR::SuppressCleanup`).
- **Pass 3: MIR Validation:** `src/mir/mir_checker.rb`. Verifies the post-MIR function body for:
  - Memory leaks (including frame arena overflows).
  - Double-frees (missing or incorrect moved guards).
  - Use-after-frees.
  - Allocator consistency (heap vs frame).
- **Pass 4: Transpiling:** `src/backends/transpiler.rb`.
  - **Dumb Transpiler:** Zero on-the-fly decisions. No on-the-fly allocator choices, no on-the-fly deinit/cleanup choices.
  - Purely mechanical emission driven by MIR nodes and AST stamps.
  - At no point outside of `src/ast/std_lib.rb` or `src/ast/type.rb` should there be special logic for intrinsic or standard library functions.

### Pass 1: Annotation / Type Inference
- `src/annotator.rb`, `src/ast/type.rb`, `src/ast/scope.rb`, `src/mir/ownership_graph.rb`
- Type inference, ownership tracking, borrow checking
- Marks AST nodes with `type_info`, `full_type`, `storage`, `provenance`
- Resolves stdlib intrinsics via `src/ast/std_lib.rb`

### Pass 2: Dataflow (Escape Analysis + Ownership Lowering to MIR)
Two sub-passes that lower all allocation/deallocation/move decisions into MIR nodes:

**2a. Promotion Planning** (`src/mir/promotion_plan.rb: PromotionClassifier`)
- Identifies frame-allocated variables that escape via return
- Plans frame-to-heap promotions (list, string_map, generic, fields)

**2b. Cleanup Planning** (`src/mir/promotion_plan.rb: CleanupClassifier`, `src/mir/control_flow.rb: OwnershipDataflow, MIRPass`)
- Classifies every binding needing cleanup (kind, allocator, moved-guard)
- Forward dataflow on CFG refines moved-guards (removes unnecessary guards, eliminates cleanup for always-moved vars)
- HPT hoisting: heap-returning sub-expressions lifted into VarDecls
- Inserts MIR nodes into AST: `MIR::Alloc`, `MIR::Drop`, `MIR::Promote`, `MIR::Return`, `MIR::SuppressCleanup`, `MIR::ReassignCleanup`, `MIR::FieldCleanup`

### Pass 3: Validate MIR Nodes (Static Leak Checker)
- `src/mir/mir_checker.rb`
- Verifies: no memory leaks (every Alloc has a Drop), no double-free (moved guards correct), no use-after-free (frame escapes promoted), no frame overflow (loops have per-iteration rewind)
- Cross-references MIR events with OwnershipDataflow results
- Safety net: catches unhoisted heap calls, orphan MIR nodes, allocator mismatches

### Pass 4: Transpiling
- `src/backends/transpiler.rb`, `src/mir/ownership_generator.rb` (generates Zig code)
- Dumb: no on-the-fly allocator choices, no on-the-fly deinit/cleanup choices
- MIR::Drop -> `emit_cleanup_from_entry` (mechanical Zig template from pre-computed entry)
- MIR::Promote -> promotion code or pending flag for next statement
- MIR::SuppressCleanup -> `var_moved = true;`
- MIR::Alloc/Return/ReassignCleanup/FieldCleanup -> no code emitted (verification only)

### Architectural Rules
- At no point outside of `src/ast/std_lib.rb` or `src/ast/type.rb` should there be special logic for intrinsic / standard library functions. All stdlib behavior is registry-driven.
- All alloc/dealloc/move decisions must flow through MIR nodes. The transpiler must never make allocator choices.
- Never allocate on the frame and then unconditionally promote to the heap. If a value is ALWAYS promoted, allocate directly on the heap at declaration time. Escape analysis in Pass 1 must propagate provenance back to declarations so finalize_decl_storage! makes the correct choice upfront.
- See `mir-bugs.md` for known MIR violations. See `alloc-bugs.md` for frame-then-always-promote gaps. See `memory-safety.md` for the full plan.

### Adding a New Escape Scenario

**How do you know you need to?** A new language feature introduces an escape scenario if it creates a situation where a frame-allocated value must survive past its declaring frame. Ask: can the new feature cause a frame-allocated list, string, map, pool, or struct to be read after the frame that allocated it has been rewound? If yes, it is an escape scenario.

**Concrete triggers:**
- New syntax that returns a value to the caller (any new `RETURN`-like construct)
- New syntax that captures a value into a longer-lived context (any new closure, fiber, or async primitive)
- New syntax that stores a value into a heap-allocated container (any new field assignment or collection mutation)
- A new function attribute that implies the return value is heap-owned (like `RETURNS %T`)
- A new inter-function propagation path (e.g., a new higher-order function that forwards its argument's return value)

**What to do:**

1. Write a failing transpile-test or spec that demonstrates the UAF/leak before your fix.
2. Add the escape condition to `EscapeAnalysis` (`src/mir/escape_analysis.rb`), Phase E2:
   - Add a detection query in the per-declaration scan (one `when` branch or guard).
   - Write the correct mutations: `node.storage = :heap`, and `ti.provenance = :heap` unless the type_info is a shared struct Type (see cases `:heap_ptr_return` and `:assign_escape` for the exception pattern).
   - Return any bookkeeping sets (e.g., `bg_upgraded`) needed by downstream passes.
3. If the new scenario involves a new category of heap-returning function (like `heap_carry_return`), add the detection to Phase E1 (`compute_heap_return_fns!`) and the call-site tagging to Phase E3.
4. Do NOT add a new `upgrade_*` method to `MIRPass`. That pattern is being eliminated (tasks #27-#32). Adding a new upgrade method re-introduces the accumulation problem.
5. Do NOT add a new invariant to `MIRChecker`. The checker's 7 invariants are fixed. If the checker fires unexpectedly after your change, the escape analysis missed a case -- fix it in `EscapeAnalysis`, not in the checker.
6. Run `bundle exec prspec spec/` and `./clear test transpile-tests/`. Both must pass at 0 failures.

### MIR Pipeline: What Goes Where (Zero UAF / Double-Free)

The MIR pipeline has three strict roles. Violating the role boundaries is what causes UAF, double-free, and leaks.

**Role 1 -- MIRLowering (`src/mir/mir_lowering.rb`): Makes ALL decisions.**

Everything that determines memory correctness is decided here and encoded in MIR node types and pre-computed fields. The checker and emitter never re-derive these decisions.

What MUST be done in MIRLowering before the checker can guarantee safety:

- **Every heap allocation** must be paired with a `MIR::AllocMark` and either a `MIR::Cleanup` or `MIR::ErrCleanup`. No naked allocations. Use `hoist_alloc` for sub-expression allocations.
- **Cleanup node type encodes the lifetime contract** -- this is the structural rule that makes the checker simple:
  - `MIR::Cleanup` = freed on BOTH success and error paths (regular `defer`). Use when the current scope owns the binding for its full lifetime.
  - `MIR::ErrCleanup` = freed ONLY on error (`errdefer`). Use when ownership transfers out on success: TAKES args, struct/union field temps, return value temps.
  - NEVER use flags or tags to distinguish these. The node type IS the policy.
- **Return value hoisted temps** must use `MIR::ErrCleanup` (caller owns on success). Borrow-position arg temps (not TAKES) must use regular `MIR::Cleanup` (freed locally after the call).
- **Moved values** (`GIVE`, TAKES consumption, return) must have `MIR::MoveMark` before the move so the guarded `defer` in `Cleanup` does not double-free. Never emit MoveMark after the move.
- **Frame values that escape** must be promoted to heap AT DECLARATION TIME (before any use). Never allocate on the frame and promote later; that is a concurrent-use window.
- **Loop bodies that frame-allocate** must emit `FrameSave`/`FrameRestore` (restoreLoopMark) per iteration. No naked frame allocs in loops without rewind.

**Role 2 -- MIRChecker (`src/mir/mir_checker.rb`): Verifies the decisions, nothing else.**

The checker enforces exactly 7 invariants and MUST NOT grow beyond them. Each new check added to the checker is a signal that the lowering made a decision incorrectly and is asking the checker to compensate. That is wrong. Fix the lowering.

The 7 invariants:
1. Every `AllocMark` has a matching `Cleanup` or `ErrCleanup` (no leak).
2. Every `Cleanup`/`ErrCleanup` has a matching `AllocMark` (no orphan cleanup).
3. AllocMark allocator matches Cleanup/ErrCleanup allocator (no allocator mismatch).
4. Heap-returning call in statement position is bound to a variable (HPT_LEAK).
5. InlineZig/RawZig with CheatLib ownership effects declares `stdlib_def` (not opaque).
6. InlineZig allocator symbols match container's AllocMark (no frame-in-heap).
7. Loop bodies with frame allocs have per-iteration restoreLoopMark defer.

NEVER add:
- Flag inspection (`node.some_flag`) -- use node type distinction instead.
- "Consuming position" analysis -- the lowering must emit `ErrCleanup` structurally.
- Heuristic pattern matching on names or types -- the lowering must tag via MIR nodes.
- Cross-referencing return values with cleanup nodes -- the lowering handles this.

**Role 3 -- MIREmitter (`src/mir/mir_emitter.rb`): Pure template engine, zero decisions.**

The emitter maps each MIR node to a fixed Zig text fragment. It makes NO ownership decisions, inspects NO types, and chooses NO allocators. Every choice was made by the lowering and is encoded in the node type or its pre-computed fields.

- `MIR::Cleanup(name, entry)` -> `defer [if (!name_moved)] cleanup(name)` (always)
- `MIR::ErrCleanup(name, entry)` -> `errdefer cleanup(name)` (always, no guard)
- `MIR::MoveMark(name)` -> `name_moved = true;` (always)
- `MIR::AllocMark` -> (no code; checker marker only)

NEVER add logic to the emitter that:
- Decides whether to emit `defer` vs `errdefer` based on context.
- Inspects the caller's type or position to determine cleanup behavior.
- Makes allocation choices (which allocator, whether to allocate).

The moment the emitter makes a decision not already secured by the MIRChecker, the system is unsafe -- the emitter runs AFTER the checker, so its decisions are unverified.

### Memory Safety Invariants

These invariants MUST remain true. Verify them before every commit.

1. **Single allocator per binding.** Every binding has exactly one allocator for its entire lifetime, determined at declaration time, never changed. No runtime promotion that mutates allocator identity. (Enforced by: ALLOC_MISMATCH check in StaticLeakChecker)
2. **Every allocation has a cleanup path.** Every MIR::Alloc must have a matching MIR::Drop on every control flow path -- including error paths, early returns, and break/continue. (Enforced by: LEAK check + OwnershipDataflow)
3. **No cleanup without allocation.** Every MIR::Drop must have a matching MIR::Alloc or TAKES parameter. No orphan cleanups. (Enforced by: ORPHAN check)
4. **Moved values are never cleaned up.** If a value is moved (GIVE, return, TAKES consumption), its cleanup is suppressed via _moved guard. The receiver takes ownership. (Enforced by: GUARD + GUARD_NO_SUPPRESS checks)
5. **Frame values never escape their scope.** Frame-allocated values must not be returned, captured by BG blocks, or stored in heap containers. If escape is detected, allocation must be upgraded to heap BEFORE the value is created. (Enforced by: FRAME_ESCAPE check)
6. **Loops don't overflow the frame arena.** Every loop body that allocates from the frame arena must have per-iteration mark/rewind. (Enforced by: FRAME_OVERFLOW check)
7. **The transpiler makes zero memory decisions.** It emits code mechanically from MIR nodes and pre-computed metadata. It never inspects types to choose allocators, never decides whether to deinit, never special-cases intrinsic functions. (Enforced by: code review)
8. **All stdlib behavior is registry-driven.** Intrinsic function allocation, cleanup, and method dispatch are defined in std_lib.rb and type.rb. No other file may contain type-specific memory logic. (Enforced by: code review)
9. **Error paths preserve allocator identity.** If an operation can fail (try/catch), the error path must not change the allocator identity of any live value. No `catch` fallbacks that return data from a different allocator. (Enforced by: no `catch original_value` patterns in runtime)
10. **Union variant cleanup uses the union's allocator.** When cleaning up a union, the allocator passed to cleanup() must match the allocator used to create the variant's payload. Guaranteed by INV-1 (single allocator). (Enforced by: INV-1 + comptime cleanup dispatch)
11. **All CheatLib calls go through registries.** Every `CheatLib.*` function call must be emitted via STD_LIB, BUILTIN_OPS, or collection method registries (POOL_METHODS, SET_METHODS, MAP_METHODS, INDEX_OPS) so the MIR checker can verify ownership. The only exception is Category C calls (cleanup, promote, promoteDeep, rcCreate, Locked.init) which implement MIR markers and are verified at the marker level. (Enforced by: `grep 'MIR::Call.new("CheatLib.'` returns only marker implementation code)
12. **RawZig and InlineZig are unsafe escape hatches.** The MIR checker CANNOT see inside raw/inline Zig code. These nodes bypass all ownership verification. Misuse causes silent memory bugs:
    - **NEVER** allocate heap memory inside RawZig/InlineZig without a matching MIR::AllocMark + MIR::Cleanup outside it (causes leak).
    - **NEVER** free/deinit a binding inside RawZig/InlineZig that has a Cleanup outside it (causes double-free).
    - **NEVER** move ownership of a binding into RawZig/InlineZig without a MIR::MoveMark + guarded Cleanup (causes double-free or leak).
    - **NEVER** return a frame-allocated value from RawZig/InlineZig without MIR::EscapePromote (causes use-after-free).
    - **ALWAYS** set `ownership_contract` on RawZig and `stdlib_def` on InlineZig that call functions which allocate or transfer ownership.
    - **ALWAYS** use BUILTIN_OPS registry for CheatLib calls instead of raw InlineZig strings.
    - Pure expressions (casts, ranges, field access, Zig builtins like `@intCast`) are safe without annotations.

## Language Semantics

CLEAR distinguishes between **Types** (what data is) and **Capabilities** (how it's accessed).

### Key Sigils
- `$` = Pipeline binding / test LET lazy binding / interpolation
- `!` = Mutation suffix
- `s>` = SMOOTH operator (safe pipeline with error propagation)
- `_` = Placeholder
- `!!` = Explicit panic

### Ownership & Capabilities
- `multiowned` (Rc), `shared` (Arc), `alwaysMutable` (RefCell), `indirect` (Box).
- Functions take **Types**, not Capabilities.
- Capabilities are unwrapped at the call site using `WITH` blocks.
- `GIVE` - Transfer ownership to callee.
- `TAKES` - Function receives ownership.
- **Zero implicit copies.** All copies of non-Copy types must be explicit. Rc/Arc increment refcounts (not copies). Primitives, strings, enums are Copy. Unions with heap variants (`@indirect`, `[]T` slices, collections) are non-Copy.
- **Borrow state lives in the OwnershipGraph.** All borrow/lifetime decisions are resolved via the OG, not by inspecting specific AST node types. The OG is the single source of truth for ownership state.
- **TODO:** Lambda `USE` captures are borrows by default. Add `USE TAKES y` syntax for move captures (like Rust's `move ||`).

## Design Principles

- **Immutability:** Default. `x = value` declares an immutable binding; `MUTABLE x = value` declares a mutable one. Reassignment uses `x = value` (no keyword) and only works on mutable variables.
- **Arena Memory:** Variables live for their function scope; large objects escape via RVO or page handoffs.
- **Local Reasoning:** `WITH RESTRICT` ensures that mutable "poisoning" is always visible and scoped.
- **Fortress Architecture:** Public APIs must be strictly defined and handle all errors.

## Contributing

### Before committing:

Verify the Memory Safety Invariants (INV-1 through INV-10 above) are not violated by your changes. Specifically:
- If you added or changed an allocation: does it have a matching cleanup on every path? (INV-2)
- If you added a new type or collection: is its cleanup driven by MIR nodes, not transpiler heuristics? (INV-7, INV-8)
- If you changed escape analysis or storage decisions: does every escaping value get heap-allocated at declaration, not frame-then-promoted? (INV-1, INV-5)
- If you changed error handling: does the error path preserve allocator identity? No `catch` fallbacks returning data from a different allocator? (INV-9)
- Run `bundle exec prspec spec/` and `./clear test transpile-tests/` to verify no regressions.

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

If you ever find a limitation in the language that you have to work around, stop, identify the problem, and suggest how the language needs to be improved to fix this limitation focing work arounds.

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
