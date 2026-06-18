# Decomplex Rust Migration Plan: The "Finding Parity" Strategy

This document outlines the roadmap for porting the `decomplex` analyzer from Ruby to Rust. The primary goal is a 10-50x performance increase and single-binary distribution, achieved through deterministic "Finding Parity" validation.

## 1. Migration Strategy: "Piecewise Transformation"

We will not attempt an "All-at-Once" migration. Instead, we will follow a **Bottom-Up, Detector-by-Detector** approach. This allows us to verify the foundational infrastructure (Normalizer) before committing to the full port.

### Phase 1: The Foundation (Infrastructure)
- **Goal:** Establish the Rust project and the universal vocabulary.
- **Tasks:**
  - Create `Cargo.toml` with `tree-sitter`, `serde`, and `rayon` dependencies.
  - Define the `NodeKind` enum (Universal Vocabulary).
  - Implement the `TreeSitterNormalizer` in Rust (starting with Ruby support).
- **Verification:** Write a tool to export normalized Rust ASTs to JSON and verify they match the Ruby `decomplex/syntax` output.

### Phase 2: The Pilot (Single Detector)
- **Goal:** Prove the logic-porting pattern.
- **Target:** **`DecisionPressure`**.
- **Reason:** It is a high-value, representative detector that relies heavily on the normalizer and local-method state walking.
- **Verification:** **JSON Finding Parity.**
  - `ruby bin/decomplex --detector decision_pressure > ruby.json`
  - `cargo run -- --detector decision_pressure > rust.json`
  - `diff ruby.json rust.json` must be empty.

### Phase 3: The Expansion (Batch Porting)
- **Goal:** Port the remaining ~20 detectors.
- **Batches:**
  - **Batch 1 (Structural):** `FatUnion`, `FalseSimplicity`, `CoUpdate`.
  - **Batch 2 (Metrics):** `LocalityDrag`, `Cohesion`, `DecisionScatter`.
  - **Batch 3 (Mining):** `SequenceMine`, `OrderedProtocolMine`.

### Phase 4: Orchestration & UI
- **Goal:** Replace the Ruby entry point.
- **Tasks:**
  - Implement the `Convergence` and `RootCause` clustering algorithms in Rust.
  - Integrate the `Lineage` SQLite export (enabling the "Refactoring Cockpit" UI to be served by a single binary).
  - Implement `Rayon` parallel file walking.

## 2. Technical Decisions

| Choice | Rust Implementation |
| :--- | :--- |
| **Parsing** | Native `tree-sitter` crate (no FFI boilerplate). |
| **Logic** | Trait-based dispatch (`trait Detector`). |
| **Validation** | Bit-for-bit JSON parity against the Ruby Oracle. |
| **Concurrency** | `Rayon` for O(N) scaling across files. |

## 3. Why this path?

1. **The Ruby Oracle:** We have a 100% correct, verified implementation in Ruby. We don't have to "think" about what a bug looks like; we just have to match the Ruby output.
2. **Solo-Dev Velocity:** Porting a 200-line Ruby detector to Rust is a 30-minute LLM task once the normalizer is ready.
3. **Correctness:** Using JSON diffing eliminates the risk of silent behavioral drift during the port.

## 4. Next Step
Initialize the Rust project in `gems/decomplex/rust` and implement the `NodeKind` enum.
