# MIR Post-Annotation Typing Tracker

Goal: after annotation and `PreMirTypeCheck`, MIR code must treat `full_type` /
`type_info` as present. A nil or untyped type at this point is an invariant
failure, not a normal branch.

## Work Items

- [x] Add an authoritative strict type accessor for post-annotation MIR code.
- [x] Replace branch-added nilable `full_type` / `type_info` probes in MIR
  decision functions with the strict accessor.
- [x] Keep generic AST walkers loose, but split typed decision helpers so they
  accept concrete AST/MIR/value types instead of propagating `T.untyped`.
- [x] Remove impossible nil guards from cleanup classification.
- [x] Ensure MIR hoist temps carry real type info on `AllocMark` / cleanup
  metadata; no `nil` type slot for typed AST-origin values.
- [x] Replace branch-added ad hoc hashes/tuples with typed structs where data
  crosses MIR helper boundaries.
- [x] Make `schema_lookup` non-nil inside MIR decision functions; optional only
  at outer construction boundaries.
- [x] Audit `OwnershipGraph` type slots and split genuinely untyped synthetic
  nodes from typed ownership nodes if needed.
- [x] Audit modified FSM/thunk transform files for branch-added untyped/nilable
  public helper seams.
- [x] Rerun Sorbet, Ruby integration specs, transpile tests, and fuzz gates.

## Current Result

- `Type.from_node!` is the post-annotation MIR accessor: missing or `:Untyped`
  type data is an invariant failure.
- SOA pipeline placeholder rewriting stamps synthetic field slices before MIR
  lowering, so `GetIndex` lowering remains a simple typed decision.
- Collection shape checks now route through `collection?`, `collection_value?`,
  `associative_collection?`, and `linear_collection?` where the behavior is
  shape-generic. Remaining explicit branches are dispatch-specific.
- Verification rerun: Sorbet, non-integration unit specs, integration specs,
  transpile tests, non-quarantined fuzz, and quarantined fuzz.

## Immediate Hotspots

- `src/mir/cleanup_classifier.rb`: field pre-cleanup, IF/WHILE-bind capture
  typing, struct-literal field borrowing checks.
- `src/mir/escape_graph.rb`: `type_of`, call-return provenance probes, and
  recursive cleanup shape predicates.
- `src/mir/hoist.rb`: AST hoist temp typing and MIR hoist cleanup typing.
- `src/mir/mir_lowering.rb`: equality helper type probes, return payload
  checks, sink materialization, direct indexing helpers, Rc retain checks.
- `src/mir/mir_pass.rb`, `src/mir/control_flow.rb`, `src/mir/ownership_graph.rb`:
  branch-added maps and type slots that currently use `T.untyped` /
  `T.nilable(Type)`.
