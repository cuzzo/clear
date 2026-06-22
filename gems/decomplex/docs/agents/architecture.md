# Decomplex Agent Architecture

Decomplex is the detector/report layer. It consumes facts produced by FactMine.
It does not parse source, normalize syntax, inspect raw syntax, inspect
normalized syntax, or call language adapters.

The FactMine compiler architecture is documented in
`gems/fact-mine/docs/agents/architecture.md`. That document owns parsing,
normalization, fact extraction, stateful fact enrichment, and language-specific
boundaries.

## Decomplex Pipeline

1. Select files and language options.
2. Load or request FactMine documents.
3. Run detectors over fact sections.
4. Correlate detector results for reports/root-cause/SARIF.
5. Render output.

Decomplex begins after FactMine pass 6, public fact projection. It has no
authorization to participate in FactMine passes 1 through 5:

- source selection
- concrete parse
- normalized AST construction
- stateless normalized extraction
- stateful normalized enrichment

Those passes and their responsibilities are owned by
`gems/fact-mine/docs/agents/architecture.md`.

## Detector Responsibilities

Allowed:

- consume `Document` fact sections
- rank, group, and correlate findings
- use language-neutral fact categories and detector options

Forbidden:

- parse source
- scan raw source for concrete language constructs
- inspect raw Tree-sitter nodes
- inspect normalized AST nodes
- access adapter internals
- branch on concrete languages
- recompute missing source facts
- call language behavior hooks
- compensate for missing FactMine sections with detector-local syntax logic

If a detector needs syntax-derived information, add a FactMine fact first.

## Fact Inputs

Allowed detector inputs include:

- functions
- owners
- calls
- state declarations
- state reads/writes
- decisions
- branch decisions and branch arms
- dispatch sites
- semantic effects
- local flow summaries
- local complexity scores
- path conditions
- redundant nil guards
- protocol method effects and call paths
- clone candidates
- immutable reader/type metadata
- predicate aliases and comparison uses

Forbidden detector inputs include:

- source text regexes for language behavior
- raw syntax nodes
- normalized syntax nodes
- language syntax adapters
- parser profiles
- language-specific lexicons
- parser or normalization phase metadata that is not projected as public facts

## Movement Rule

If code extracts or normalizes syntax, move it to FactMine.

If code ranks or reports existing facts, keep it in Decomplex.

When fixing architecture, move code to the correct layer first. Passing tests
come after the boundary is correct.
