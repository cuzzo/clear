# Decomplex Architecture

Decomplex is the detector and report layer that consumes source facts produced
by FactMine. FactMine owns parsing, language adapters, normalization,
stateless fact extraction, stateful fact enrichment, and public fact
projection. That architecture is documented in
[`gems/fact-mine/docs/architecture.md`](../../fact-mine/docs/architecture.md).

This document describes the Decomplex side of the pipeline: source selection,
fact loading, detector responsibilities, report shaping, and the invariants
that keep detectors language-neutral.

## Pipeline Summary

### 0. Source Selection

Input files are mapped to a language by extension or explicit language option.

Responsibility:

- decide which grammar/profile applies
- preserve deterministic file order
- reject unsupported source

Not responsible:

- fact extraction
- detector decisions
- report shaping

Ruby implementation:

- `Decomplex::Syntax.language_for`
- `Decomplex::Syntax.supported_source?`

Rust implementation:

- `Language::for_extension`
- CLI language options and parse targets

### 1. Fact Document Hydration

Stored facts are converted into the Ruby or Rust document representation.

Responsibility:

- deserialize syntax facts
- provide stable fact readers
- preserve exact fact shape for detector parity

Not responsible:

- raw parsing
- recomputing facts from source
- detector-specific fallback extraction

Ruby implementation:

- `syntax/fact_document.rb`

Rust implementation:

- `Document` deserialization in `syntax.rs`
- `detector-facts` CLI input

### 2. Detectors

Detectors consume facts only.

Responsibility:

- rank, group, and report smells/findings
- consume `Document` fact sections and detector options
- stay language-agnostic unless the detector explicitly consumes language-neutral lexicon categories

Not responsible:

- Tree-sitter traversal
- normalized AST traversal
- concrete language branches
- syntax adapter calls

Examples:

- state mesh
- path condition
- false simplicity
- flay similarity
- local flow
- redundant nil guard

Architecture invariant:

- Detectors must not import Tree-sitter, inspect raw syntax nodes, read adapter internals, or branch on concrete languages.

### 3. Report, Root Cause, SARIF

Report passes consume detector outputs and facts.

Responsibility:

- post-process detector findings
- render Markdown, JSON, SARIF
- combine detector facts for user-facing explanations

Not responsible:

- syntax extraction
- language-specific source analysis

## FactMine Boundary

Decomplex does not own syntax normalization or source-fact extraction. Those
responsibilities live in FactMine:

- normalized AST vocabulary
- language syntax files, AST adapters, and normalization behavior hooks
- stateless normalized extraction
- stateful normalized enrichment
- semantic effects, protocols, clone similarity, nil guards, local flow,
  path conditions, and local complexity fact generation
- `FactDocument` hydration

See [`gems/fact-mine/docs/architecture.md`](../../fact-mine/docs/architecture.md)
for the detailed pass list and language-specific boundaries.

## Detector Rules

All Decomplex detectors must consume fact sections only.

Allowed detector inputs:

- `function_defs`
- `owner_defs`
- `call_sites`
- `state_reads`
- `state_writes`
- `decision_sites`
- `branch_decisions`
- `branch_arms`
- `dispatch_sites`
- `semantic_effect_sites`
- `protocol_method_effects`
- `protocol_call_paths`
- `clone_candidates`
- `redundant_nil_guard_findings`
- `local_methods`
- `local_complexity_scores`
- metadata facts such as immutable readers, type aliases, and method parameter
  types

Forbidden detector inputs:

- raw Tree-sitter nodes
- normalized AST nodes
- `document.normalized_root`
- language syntax adapters
- raw source scans for language-specific constructs
- concrete language branches such as `if language == :ruby`

If a detector needs a new syntax-derived input, add a FactMine fact or metadata
section first. Do not mine syntax inside the detector.

## Target Architecture Rule

If code parses source, normalizes syntax, or computes source facts, it belongs
in FactMine.

If code ranks, groups, correlates, or reports already-collected facts, it
belongs in Decomplex.

The review question for every Decomplex change should be:

Can this detector operate entirely on `FactDocument` facts?

If no, the missing source fact belongs in FactMine before detector work
continues.
