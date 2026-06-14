# Zig Mutants Comparison

## Summary

`gems/zig-mutants` is a Zig-native MVP modeled after Rust's `cargo-mutants`.
It is not equivalent to Ruby `mutant` or `cargo-mutants` yet. It implements the
core architecture that matters most:

- parsed-source mutant discovery
- stable mutant IDs
- baseline-first execution
- scratch-copy mutation
- killed/survived/timeout/unviable outcomes
- `mutant-facts/v1` output for existing CLEAR reports

It deliberately does not try to be a full ecosystem-grade mutation-testing
framework in the first pass.

## Compared To Ruby Mutant

Ruby `mutant` is mature and semantic:

- integrates with Ruby's runtime and constant loading
- selects tests via configured integrations such as RSpec
- mutates Ruby AST expressions deeply
- reports equivalent/surviving mutations with rich context
- has years of battle testing around Ruby's dynamic dispatch

`zig-mutants` is narrower:

- mutates Zig source files only
- runs a caller-provided shell test command
- currently attributes facts at file level with `method: "*"`
- has a small operator set
- has no Ruby-style expression/type semantics or test selection

The key difference is maturity. Ruby `mutant` is a production-grade testing
tool; `zig-mutants` is a local CLEAR-side package proving the architecture for
Zig runtime/lib tests.

## Compared To Cargo-Mutants

`cargo-mutants` is the closest architectural model.

Shared design:

- discover mutants from parsed source, not regexes
- run a clean baseline before mutants
- mutate copied build directories, not the developer worktree
- classify killed/survived/timeout/unviable
- prioritize survivors as the action item

Cargo-mutants has much more:

- Cargo package/workspace discovery
- target/test selection
- parallel execution
- sharding/runtime controls
- richer reports/logs/diffs
- allowlists and workflows for equivalent mutants
- more mature mutator families
- CI adoption patterns and ratchets

`zig-mutants` currently has:

- `std.zig.Ast`-backed discovery
- boolean/comparison/logical flips
- `if`/`while` condition negation
- `std.debug.assert` weakening
- `defer`/`errdefer` removal
- sequential scratch-copy execution
- optional `mutant-facts/v1` output

## Current Gaps

The most important missing pieces are operational, not more mutators:

- parallel workers
- sharding
- a manifest of high-value Zig subjects
- durable per-mutant logs/diffs
- function-level attribution
- allowlist support for reviewed equivalent mutants

The most important semantic gaps are:

- no type-directed function-body replacement
- no import graph or test-target narrowing
- no awareness of Zig comptime equivalence
- no mutation of `try`, allocator choices, atomics, or lock APIs

## Recommendation

This is good enough for a side quest unless it starts finding valuable
survivors regularly.

Do next only if we plan to run it repeatedly:

1. Add sharding/parallel workers.
2. Add a small subject manifest for `zig/lib` and `zig/runtime`.
3. Add durable logs/diffs for survivors.

Do not invest heavily yet in broad mutator families or deep semantic analysis.
If the Zig community eventually produces a mature cargo-mutants equivalent, we
should consider adopting it. Until then, this package gives CLEAR a credible,
AST-backed mutation-testing baseline without turning into a major project.
