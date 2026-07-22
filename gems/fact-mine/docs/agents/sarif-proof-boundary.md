# SARIF proof-boundary contract (v1)

Consumers of FactMine-derived facts publish this contract on individual SARIF
results. It answers a deliberately narrow question: what is the weakest proof
boundary of the facts used to produce this finding? It is not a claim that an
entire repository scan is complete or incomplete.

## Result property

Every participating result has a `fact_mine.proof_boundary` property:

```json
{
  "schema": "fact-mine.proof-boundary.v1",
  "tier": "complete | partial | review",
  "authority": ["fact_mine_normalized_ast"],
  "scope": "detector_local",
  "blockers": []
}
```

- `complete` means every fact required for the stated `scope` was available.
  It does not imply a whole-program proof.
- `partial` means a required fact was absent or unresolved. `blockers` names
  the missing information.
- `review` means the result is intentionally visible but line coverage or the
  available static evidence cannot discharge the underlying concern.
- `authority` identifies the fact producers actually used; `scope` prevents a
  local observation from being mistaken for a global semantic guarantee.

## Run summary

The run-level `fact_mine.proof_boundary_summary` has the same `schema` and:

```json
{
  "result_count": 12,
  "results_with_boundary": 10,
  "tiers": {"complete": 7, "partial": 2, "review": 1},
  "partial_or_review_results": 3,
  "partial_or_review_percent": 30.0
}
```

The denominator for `partial_or_review_percent` is
`results_with_boundary`, never every result in the scan. This keeps unrelated
SARIF producers and unannotated legacy results from silently becoming unknown.

Current producers are Decomplex, Espalier, NilKill, and SlopCop. Consumers
must preserve these properties when re-emitting SARIF rather than replacing
them with a global scan-completeness flag.
