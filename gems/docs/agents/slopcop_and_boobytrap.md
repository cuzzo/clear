# SlopCop & BoobyTrap Architecture and Plan

## Current State & Problem
- **Sloppy Dependencies**: `gems/slopcop` and `gems/boobytrap` currently very sloppily use Decomplex & Fact-Mine indirectly.
- **Goal**: They need clearly defined architectures mirroring the model established by Espalier.

## Architecture Guidelines
- **Data Source**: They must require a Fact-Mine file and get their facts directly from **Fact-Mine Rust**.
- **No AST Parsing**: They must perform ZERO parsing of un-normalized AST data.
- **Zero Legacy Dependencies**: They must have ZERO dependencies on the Ruby Fact-Mine and Decomplex code.
- **Utility Migration**: Any further Decomplex code they currently depend on (such as SARIF functionality) must be migrated directly into `gems/slopcop`.

## Plan & Priorities
1. **Wait for Espalier**: Use Espalier as the model for how to correctly consume Fact-Mine Rust facts.
2. **Fact-Mine Migration**: Refactor SlopCop and BoobyTrap to depend directly on Fact-Mine Rust.
3. **Migrate Utilities**: Move SARIF and other needed utilities from Decomplex into SlopCop.
4. **Hardening & Testing**:
   - Ensure all skipped tests pass.
   - Achieve >95% line coverage via INTEGRATION tests.
