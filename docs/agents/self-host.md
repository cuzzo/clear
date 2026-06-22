# Self-Hosting Plan: The "Boiling Frog" Transpilation

This document outlines a phased bootstrapping approach to self-hosting the CLEAR compiler. Rather than a single "big bang" transpilation, we build the transpiler incrementally to handle the specific Ruby features used in each compiler pass.

## Core Strategy

1.  **Surgical Ruby Refactoring (Phase 0)**: Eliminate dynamic hazards (e.g., `send`, `instance_variable_get`) in the Ruby source to simplify the transpiler and ensure idiomatic CLEAR output.
2.  **Phase-Locked Development**: Build the transpiler logic required for Pass N, then transpile Pass N.
3.  **Surgical Manual Intervention**: Complex Ruby idioms (e.g., dynamic regex generation in the Lexer, or complex metaprogramming in the Annotator) are manually converted during each pass.
4.  **Fact-Driven Memory Safety**: Use `decomplex` to detect aliasing and ownership facts in the Ruby source to drive correct CLEAR capability selection (GIVE vs. Borrow vs. Shared).

## Phase Estimates

| Phase | Component | Ruby LOC | Transpiler LOC (Cumulative) | Manual Work |
| :--- | :--- | :---: | :---: | :---: |
| **P0** | **Source Refactor** | N/A | 0 | 0% |
| **P1** | **Lexer** | 360 | 1,000 | 0% |
| **P2** | **Parser & AST** | 18,500 | 3,000 | 5% |
| **P3** | **Type Inference (Annotator)** | 11,000 | 5,000 | 10% |
| **P4** | **Cap & Effect Tracking** | 11,200 | 6,500 | 15% |
| **P5** | **Escape Analysis** | 4,100 | 7,500 | 15% |
| **P6** | **AST/MIR Re-writing** | 1,500 | 8,500 | 10% |
| **P7** | **Thunk Conversion** | 3,300 | 9,500 | 20% |
| **P8** | **FSM Conversion** | 7,500 | 10,500 | 25% |
| **P9** | **MIR Lowering** | 22,000 | 11,500 | 15% |
| **P10** | **MIR Safety Verification** | 3,000 | 12,000 | 5% |
| **P11** | **Zig Emission** | 4,200 | 12,500 | 5% |
| **P12** | **Test Suite (spec/)** | 100,000+ | 16,000 | 15% |

### Phase Details

#### P0: Surgical Refactor
- **Goal**: Remove dynamic Ruby features that are difficult to transpile.
- **Actions**: Replace `send` with explicit interfaces; replace `instance_variable_get` with getters; simplify RSpec mocks to use structural doubles.
- **Benefit**: Reduces transpiler complexity by ~2,000 LOC and ensures the output follows CLEAR "Fortress Architecture" principles.

#### P1-P2: Frontend (Lexer & Parser)
- **Ruby Surface**: String scanning, recursive descent, large case/match blocks, AST node instantiation.
- **Transpiler Goal**: Map Ruby `StringScanner` to CLEAR `Scanner`, and `case` to CLEAR `MATCH`.
- **Manual Work**: Complex regex-driven tokenization rules that don't map 1:1 to Zig's regex engine.

#### P3-P4: Semantic Analysis (Annotator)
- **Ruby Surface**: Symbol tables, recursive tree walks, Sorbet `sig` blocks, `T::Hash`, `T::Set`.
- **Transpiler Goal**: Robust mapping of Sorbet types to CLEAR types; mapping Ruby `Hash/Set` to CLEAR `@map/@set`.
- **Manual Work**: Deeply nested type-inference edge cases and circular dependency resolution in the declaration index.

#### P5-P8: Middle-End (Semantic & Transforms)
- **Ruby Surface**: Flow-sensitive analysis, graph traversal, tree-to-tree transformations (Rewriters), closure/thunk generation.
- **Transpiler Goal**: Implementing a "Data-Flow Bridge" in `decomplex` to detect aliasing hazards.
- **Manual Work**: FSM conversion logic is the most complex Ruby in the codebase, requiring careful manual verification of the generated state machines.

#### P9-P11: Backend (Lowering & Emission)
- **Ruby Surface**: Explicit memory decision logic, cleanup classification, Zig template strings.
- **Transpiler Goal**: High-fidelity mapping of Ruby logic to CLEAR's ownership markers (`Cleanup`, `MoveMark`).
- **Manual Work**: Very low; these passes are already designed with "CLEAR-like" semantics (mechanical and fact-driven).

#### P12: Test Suite (spec/)
- **Ruby Surface**: RSpec DSL (`expect`, `it`, `describe`), dynamic doubles, `send` for white-box testing.
- **Transpiler Goal**: Map RSpec DSL to CLEAR `TEST` and `ASSERT` blocks.
- **Manual Work**: High (~15%) due to the highly dynamic nature of Ruby test mocking.

## Success Criteria

A phase is considered complete when:
1.  The CLEAR-transpiled version of Pass N passes all unit tests when driven by the Ruby versions of Passes 0..(N-1).
2.  Decomplex reports 0 "Encapsulation Breaches" in the generated CLEAR code.
3.  The binary size and performance of the self-hosted pass are within 20% of the Ruby baseline (targeting 2-5x faster eventually).
