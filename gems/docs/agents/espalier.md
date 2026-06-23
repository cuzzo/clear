# Espalier Architecture and Plan

## Current State & Problem
- **Origin Issue**: Nil-kill haphazardly migrated its static analysis fact-mining into Espalier.
- **Goal**: Espalier needs to serve as the *model* for the clean architecture that SlopCop and BoobyTrap will follow.

## Architecture Guidelines
- **Data Source**: Espalier must get its facts strictly from the **Fact-Mine Rust** version.
- **No AST Parsing**: Espalier must perform ZERO parsing of un-normalized AST data. It operates purely on the facts provided by Fact-Mine.
- **Zero Legacy Dependencies**: Since the Ruby Fact-Mine and Decomplex code will be deleted, Espalier must have ZERO dependencies on that code.
- **Extensibility**: Espalier can add specific logic to the Rust Fact-Mine where needed to extract the facts it requires.

## Plan & Priorities
1. **Fact-Mine Migration**: Fully migrate Espalier to use Fact-Mine Rust.
2. **Hardening & Testing**:
   - Get all skipped tests to pass.
   - Target: >95% line coverage.
   - Strategy: Predominantly use INTEGRATION tests. Only use unit tests where strictly needed.
3. **Architectural Sweep (Post-Migration)**:
   - Once Espalier is working, use it as a model to fix obvious architectural issues across the codebase (e.g., objects communicating with objects they shouldn't, removing inappropriate public APIs).
