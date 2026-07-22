# SARIF proof-boundary contract (v3)

Consumers of FactMine-derived facts publish this contract on individual SARIF
results. It separates three questions that must not share a scalar tier: are
the inputs complete, how strong is the finding's claim, and can line coverage
discharge that claim?

## Result property

Every participating result has a `fact_mine.proof_boundary` property:

```json
{
  "schema": "fact-mine.proof-boundary.v3",
  "input_completeness": "complete | partial | unknown",
  "claim_status": "proven | observed | review",
  "coverage_discharge": "satisfiable | unsatisfiable | not_applicable | unknown",
  "authority": ["fact_mine_normalized_ast"],
  "claim_kind": "redundant_nil_guard",
  "scope": {"kind": "function", "closed": false},
  "blockers": [{"kind": "parser_recovery", "path": "lib/example.rb", "span": [12, 0, 12, 0]}]
}
```

- `input_completeness` is `complete` or `partial` only when an upstream fact
  explicitly supplies that information; otherwise it is `unknown`.
- `claim_status` says whether the reported conclusion is proven, observed, or
  intentionally left for review. An observed AST pattern is not a proof.
- `coverage_discharge` says whether coverage could satisfy the concern. It is
  independent of both proof and input completeness.
- `claim_kind` identifies the detector conclusion independently of its proof
  extent. `scope.kind` is one of `reported_span`, `function`, `owner`, `file`,
  `project`, `closed_build_target`, or `local`; `closed` says whether the
  selected extent was proven closed.
- `blockers` are typed (`parser_recovery`, `call_resolution`,
  `missing_evidence`, `open_corpus`, `unsupported_language`, or `unknown`) and
  retain a source `path` and four-element Tree-sitter `span` when available.

## Run summary

The run-level `fact_mine.proof_boundary_summary` has the same `schema` and:

```json
{
  "result_count": 12,
  "results_with_boundary": 10,
  "input_completeness": {"complete": 4, "partial": 2, "unknown": 4},
  "claim_status": {"proven": 1, "observed": 7, "review": 2},
  "coverage_discharge": {"satisfiable": 3, "unsatisfiable": 2, "not_applicable": 5, "unknown": 0}
}
```

`results_with_boundary` is the denominator for rates calculated from any one
dimension; consumers must never combine `review` with `partial`, or infer
`complete` from a missing field.

Current producers are Decomplex, Espalier, NilKill, and SlopCop. Consumers
must preserve these properties when re-emitting SARIF rather than replacing
them with a global scan-completeness flag.

## Ownership and conformance

The machine-readable contract is
`gems/hazard-contract/proof-boundary.v3.schema.json`; matching valid and
invalid vectors, including representative Decomplex, Espalier, NilKill, and
SlopCop producer values, live in
`gems/hazard-contract/fixtures/proof-boundary.v3.json`. The hazard-contract
test compiles the versioned JSON Schema and validates those vectors, so the
fixture is a conformance check rather than documentation alone.
Ruby producers use `FactMine::ProofBoundary` rather than copying validation or
summary logic. Rust producers use typed enums, so invalid values cannot escape
in release builds.

A detector creates the boundary with the finding it emits. SARIF only
serializes it. Complete inputs do not imply a proven claim: only an explicit
detector proof may use `claim_status: proven`.
