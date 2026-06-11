# Decomplex Implicit Control Flow Metric

## Goal

Detect hidden lifecycle protocols where internal method calls must happen in a particular order because the earlier call mutates state used by the later call.

This is not a generic `x(); y(); z();` detector. Repeated call order only matters when the ordered calls have overlapping state effects.

## Signal Definition

The detector should mine ordered internal call pairs from path-aware method bodies after resolving each call to a callee effect summary.

A pair `x -> y` is considered meaningful when at least one of these overlaps exists:

- `write_read`: `x` writes state that `y` reads.
- `write_write`: `x` and `y` both write the same state.
- `read_write`: `x` reads state that `y` writes. This is weaker, but can expose check-then-update protocols.

Pairs that only touch unrelated state are ignored. Pure calls are ignored.

## Current Implementation

`Decomplex::ImplicitControlFlow` keeps the path extraction from the ordered-protocol prototype, but changes the mining unit:

- Build method effect summaries for direct state reads/writes.
- Resolve internal `self`/bare calls to same-owner methods, with a unique global fallback for mixin-style helper calls.
- Filter call paths down to effect-bearing calls.
- Mine adjacent state-dependent pairs from that effect-bearing sequence.
- Report the pair as protocol pressure even when it appears only once.
- Keep order drift as a secondary helper: a high-support pair observed reversed elsewhere is stronger bug evidence, but drift is not required for the main metric.

The old `OrderedProtocolMine` constant remains as an alias for compatibility, but the report section is now `Implicit Control Flow`.

## Calibration Notes

On `src/**/*.rb`, the state-dependent miner currently finds repeated protocols such as:

- `with_new_scope -> current_scope` over `scope_stack`
- parser `current -> consume` / `consume -> current` over `pos`
- `promote_to_expr_if! -> promote_to_expr_match!` over `symbol?`

The report should list these protocols directly. A reversed order can be surfaced separately, but the existence of the hidden protocol is already the design pressure.

## Remaining Design Work

- Improve effect summaries for parameter object mutation if we want AST-node state protocols such as `stamp_type!`/`full_type!` to participate safely.
- Consider importing Espalier visibility and reverse call graph data so protocol steps exposed publicly can be flagged as wrapper candidates.
