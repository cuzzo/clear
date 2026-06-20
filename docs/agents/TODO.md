# Launch Checklist: CLEAR v0.1 & Generalized Gems

## Phase 1: The "Secret Sauce" Launch (Weeks 1-6)

### 1. Lineage (The Backbone)
- [ ] Finalize Rust `lineage` crate with VCS Trait support (Git/JJ/Hg).
- [ ] Implement Sentry/Stack-trace ingestion with verification anchors.
- [ ] Implement Coverage-Delta ingestion (Aggregates only).
- [ ] Build the Local UI Server (Rust/Axum + React/Monaco) with gutters.

### 2. Boobytrap & SlopCop (The Integrity Wall)
- [ ] Generalize SlopCop regexes into language-neutral providers.
- [ ] Implement Systems-Test Coverage detection (Atomics -> Loom, etc.) for Zig.
- [ ] Add `--format sarif` output for native GitHub Check Annotations.
- [ ] Update Boobytrap to use Lineage SQLite DB for function-level history.

### 3. Nil-Kill & Auto-Type (The Repair Engine)
- [ ] Complete the extraction of `auto-type` from `nil-kill`.
- [ ] Implement the `auto-type` Provider Registry (Template/LLM/AST tiers).
- [ ] Abstract Nil-Kill Z3 evidence extraction into language providers.
- [ ] Launch "Hidden Enum Discovery" as a flagship AI-refactoring feature.

## Phase 2: CLEAR v0.1 Architectural Preview (Weeks 7-8)

### 4. Compiler Hardening
- [ ] **Must Build:** Promote the "Memory Brains" (`Type`, `CleanupClassifier`, `EscapeAnalysis`) to Hard-Gated mutation status.
- [ ] Ensure 100% of safety invariants in `CLAUDE.md` are killed by transpile-mutants.
- [ ] Conduct a final parity run: Tree-sitter-Ruby vs. Prism-Ruby facts.

### 5. Launch Artifacts
- [ ] Finalize the "Language Tour" featuring the MiniVM (`_bc_runner.cht`) as proof of logic.
- [ ] Release the 3-week "Decomplex Expansion" narrative (Ruby -> Python -> Universal).

## Phase 3: CLEAR v0.2 Self-Hosted Release (Weeks 9-10+)

### 6. The Great Migration
- [ ] Execute the "Narrowing the Funnel" refactor: move Ruby source to "Spiritual CLEAR".
- [ ] Run the S2S Script (Ruby-to-CLEAR) on the Kernel (AST/Type/Annotator).
- [ ] Achieve first successful self-compiled "Hello World".
- [ ] Achieve full self-hosting of the MIR Lowering and Checker passes.

## Phase 4: Enterprise & Scalability

- [ ] Port the Lineage UI to a standalone **Tauri** Desktop Application.
- [ ] Design the "Cloud Fact-Store" for aggregate team risk (hosting-safe).
- [ ] Finalize per-seat license model for the "Systems Integrity Platform".
