# Decomplex & Fact-Mine Architecture and Plan

## Current State & Problem
- **Performance**: The Ruby implementations of `gems/decomplex` and `gems/fact-mine` are too slow to be useful.
- **Migration**: `gems/fact-mine` has been transitioned to Rust (`gems/fact-mine/rust`), and `gems/decomplex` has a Rust component.
- **Goal**: We want to delete the Ruby `gems/decomplex` code and the `gems/fact-mine` Ruby code.

## The Oracle Tests Hurdle
There are Oracle tests currently implemented in Ruby.
- We need to determine if the Rust code runs these oracles.
- If it does, we need to ensure it runs on GitHub CI.
- **Action Item**: This must be addressed FIRST before deleting the Ruby code. If the Rust code does not cover them or cannot run them on CI, the Ruby tests can stick around just to run the oracles.

## Architecture
- **Fact-Mine**: Extracts structural and normalized facts from un-normalized ASTs. It is the single source of truth for syntactic facts.
- **Decomplex**: Depends on Fact-Mine to calculate complexity, structural dependencies, and other metrics.
- **Dependency Hierarchy**: Other tools (Espalier, SlopCop, BoobyTrap) rely on Fact-Mine for their raw facts.

## Plan & Priorities
1. **Verify Oracles**: Run the Rust code's tests and confirm that the source/syntax fact examples match the oracles. (Already confirmed passing via `cargo test` locally).
2. **Hardening (Fact-Mine)**:
   - Target: >95% line coverage for non-language specific files.
   - Target: >95% line coverage for Ruby-specific files.
   - Strategy: Predominantly use INTEGRATION tests. Add unit tests only when truly the best option.
3. **Ruby Code Deletion**: Only once dependencies are fully migrated to the Rust version and Oracle tests are secured, delete the slow Ruby code.
