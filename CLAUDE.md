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
bundle exec rspec                    # Run all Ruby specs (1476 examples)

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

Run **all three** after making changes to the compiler:
- **Ruby specs**: `bundle exec rspec` (1343 examples)
- **transpile-tests**: `./clear test transpile-tests/` (130 tests)
- **module-integration**: `cd transpile-tests/module-integration && zig build test`
- **ffi-integration**: `cd transpile-tests/ffi-integration && zig build test`

## Benchmarks

```bash
# Benchmark runner modes
ruby benchmarks/runner.rb --smoke benchmarks/24_json_api/   # CLEAR only, fast (~5s)
ruby benchmarks/runner.rb --fast benchmarks/05_hashmap/     # All langs, reduced (~30s)
ruby benchmarks/runner.rb benchmarks/05_hashmap/            # Normal (default)
ruby benchmarks/runner.rb --release benchmarks/05_hashmap/  # Exhaustive (5x load)
ruby benchmarks/runner.rb --all                             # All benchmarks (01-29)
ruby benchmarks/runner.rb --smoke --all                     # Smoke test all benchmarks
ruby benchmarks/runner.rb --cores=2 benchmarks/17_kvstore/  # Control core count
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
- **Pass 0: Parsing:** `src/lexer.rb`, `src/parser.rb`. Builds the raw AST.
- **Pass 1: Annotation:** `src/annotator.rb`, `src/type.rb`. Performs type inference, symbol resolution, and capability checks.
- **Pass 2: Dataflow & MIR Lowering:** `src/control_flow.rb`, `src/ownership_graph.rb`, `src/promotion_plan.rb`.
  - Computes `PromotionPlan` (escape promotion) and `CleanupPlan` (cleanup requirements).
  - Performs `Escape Analysis` and forward `OwnershipDataflow` on the CFG.
  - Lowers all `Alloc`/`Dealloc`/`Free`/`Move`/`Promote` events into explicit **MIRNodes** (`MIR::Alloc`, `MIR::Drop`, `MIR::Promote`, `MIR::SuppressCleanup`).
- **Pass 3: MIR Validation:** `src/static_leak_checker.rb`. Verifies the post-MIR function body for:
  - Memory leaks (including frame arena overflows).
  - Double-frees (missing or incorrect moved guards).
  - Use-after-frees.
  - Allocator consistency (heap vs frame).
- **Pass 4: Transpiling:** `src/transpiler.rb`.
  - **Dumb Transpiler:** Zero on-the-fly decisions. No on-the-fly allocator choices, no on-the-fly deinit/cleanup choices.
  - Purely mechanical emission driven by MIR nodes and AST stamps.
  - At no point outside of `src/std_lib.rb` or `src/type.rb` should there be special logic for intrinsic or standard library functions.

The transpiler is supposed to be as dumb as possible so that:
1.  We can catch as many bugs as possible at unit test time.
2.  We can support different backends easily besides just Zig.

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
