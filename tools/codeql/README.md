# CLEAR CodeQL State Flow Experiment

This is a small CodeQL-backed graph experiment for finding architectural
pressure around mutable compiler state.

It does not replace nil-kill or decomplex:

- nil-kill ranks weak type/evidence contracts.
- decomplex ranks re-derived decisions, missing abstractions, and protocol
  drift.
- CodeQL supplies a Ruby AST/call/control/dataflow substrate that can connect
  those findings into concrete source paths.

## Usage

Install the CodeQL CLI, then run:

```sh
ruby tools/codeql_state_flow.rb --create-db --overwrite-db
ruby tools/codeql_state_flow.rb
```

Outputs land in `tmp/codeql-state-flow/`:

- `state-field-access.csv`
- `call-edges.csv`
- `report.md`

By default the report filters to `src/` rows and skips resolved call edges.
Call-edge resolution is useful but much slower on the full repository:

```sh
ruby tools/codeql_state_flow.rb --call-edges
```

The first query tracks reads/writes/calls for state names that have repeatedly
shown up in nil-kill/decomplex reports:

```text
full_type, storage, provenance, ownership, sync, layout, emit, target, value,
symbol, name, type, left, right, expr, result_type
```

The report is intentionally a first-pass ranking, not a verdict. A good next
step is to join the CSV rows with nil-kill pressure and decomplex convergence
by `(file, method, field)`.
