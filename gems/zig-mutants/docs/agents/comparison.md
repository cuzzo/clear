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
- checked-in runtime subject manifest
- process-level sharding
- survivor reproduction artifacts
- function-level attribution
- survivor-ID ratcheting

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
- attributes facts by source file and enclosing function where Zig AST spans
  allow it
- has a small runtime-focused operator set
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
- `try` / `catch` weakening
- cleanup and lock call removal
- atomic ordering weakening
- error-return and bounds-guard weakening
- process-level sharding
- survivor artifacts
- runtime subject manifest
- ratchet mode for reviewed alive mutants
- optional `mutant-facts/v1` output

## Current Gaps

The most important remaining operational gaps are:

- in-process worker pools
- import graph or test-target narrowing
- allowlist support for reviewed equivalent mutants
- richer HTML or terminal reports

The most important semantic gaps are:

- no type-directed function-body replacement
- no awareness of Zig comptime equivalence
- no broad allocator-choice mutation beyond cleanup call removal
- no integer literal perturbation

## Recommendation

This is now good enough to run repeatedly against the CLEAR Zig runtime as an
advisory safety signal. The next investment should be driven by survivor
quality, not by trying to match `cargo-mutants` feature-for-feature.

Do not invest heavily yet in broad mutator families or deep semantic analysis.
If the Zig community eventually produces a mature cargo-mutants equivalent, we
should consider adopting it. Until then, this package gives CLEAR an
AST-backed, runtime-focused mutation-testing baseline without turning into a
major project.
