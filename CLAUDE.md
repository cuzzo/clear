# CLAUDE.md

This file provides guidance to Claude Code when working with code in this repository.

## Project Overview

**CLEAR** is a memory-safe programming language that combines the ease of Ruby/Python with Rust-like safety. It features arena-based memory management (no garbage collector), ownership semantics, and separates **Types** from **Capabilities**.

## Build & Test Commands

```bash
# --- clear CLI (preferred) ---
./clear build foo.cht                # Build a CLEAR program -> ./foo
./clear build foo.cht -o bin/app     # Custom output path
./clear build foo.cht --safe         # With bounds/overflow checks
./clear run foo.cht                  # Build + execute
./clear run foo.cht -- --port 8080   # Pass args to program
./clear test foo.cht                 # Test with leak detection (all 129 tests pass)

# --- Full test suites ---
bundle install                       # Install Ruby dependencies
bundle exec rspec                    # Run all Ruby specs (1343 examples)

# Transpile-tests: generate + run all Zig integration tests
ruby transpile-tests/gen.rb                              # Generates zig/all-tests.zig
cd zig && zig test all-tests.zig -lc switch.S onRoot.S   # Run all 130 tests

# Package integration test
cd transpile-tests/module-integration && zig build test

# FFI integration test
cd transpile-tests/ffi-integration && zig build test
```

Run **all three** test suites after making changes to the compiler:
- **Ruby specs**: `bundle exec rspec` (1343 examples)
- **transpile-tests**: 130 .cht files testing language features end-to-end
- **module-integration**: `REQUIRE "pkg:name"`, cross-package symbol resolution
- **ffi-integration**: `EXTERN FN`/`EXTERN STRUCT` declarations, native Zig call sites

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

## Ignored Directories

- `vm/` — Obsolete bytecode VM from the toy implementation. Not part of the current compiler. Ignore entirely.

## Architecture

The compiler is a 3-pass system written in Ruby:
1.  **Parsing:** `src/lexer.rb`, `src/parser.rb`
2.  **Semantic Analysis:** `src/annotator.rb`, `src/type.rb`, `src/scope.rb`, `src/ownership_tracker.rb`
3.  **Code Generation:** `src/transpiler.rb` (generates Zig code)

## Language Semantics

CLEAR distinguishes between **Types** (what data is) and **Capabilities** (how it's accessed).

### Key Sigils
- `&` = Borrow/reference
- `@` = Pipeline binding
- `!` = Mutation suffix
- `s>` = SMOOTH operator (safe pipeline with error propagation)
- `!!` = Explicit panic

### Ownership & Capabilities
- `multiowned` (Rc), `shared` (Arc), `alwaysMutable` (RefCell), `indirect` (Box).
- Functions take **Types**, not Capabilities.
- Capabilities are unwrapped at the call site using `WITH` blocks.
- `GIVE` - Transfer ownership to callee.
- `TAKES` - Function receives ownership.

## Design Principles

- **Immutability:** Default. `x = value` declares an immutable binding; `MUTABLE x = value` declares a mutable one. Reassignment uses `x = value` (no keyword) and only works on mutable variables.
- **Arena Memory:** Variables live for their function scope; large objects escape via RVO or page handoffs.
- **Local Reasoning:** `WITH RESTRICT` ensures that mutable "poisoning" is always visible and scoped.
- **Fortress Architecture:** Public APIs must be strictly defined and handle all errors.

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
