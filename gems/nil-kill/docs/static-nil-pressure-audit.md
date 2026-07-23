# Static Nil-Pressure Precision Audit

Date: 2026-07-22

This is a manual precision check for the static nil-pressure slice. It uses
ordinary repository sources rather than purpose-built nullable fixtures.

## Inputs

- `gems/boobytrap/src/main.go` — production Go CLI source.
- `benchmarks/sequential/03_alloc_throughput/bench.c` — C benchmark source.
- `zig/fiber-stack-check/pass/FiberInstrument.cpp` — C++ compiler-pass source.

## Reproduction

Build FactMine from the checked-out source, then extract and pass its public
facts directly to NilKill:

```sh
cargo build --release --manifest-path gems/fact-mine/Cargo.toml
gems/fact-mine/target/release/fact-mine-rust profile nil-kill \
  --output=/tmp/static-nil-pressure-real-repo-audit.json \
  gems/boobytrap/src/main.go \
  benchmarks/sequential/03_alloc_throughput/bench.c \
  zig/fiber-stack-check/pass/FiberInstrument.cpp
jq '{methods, facts: del(.methods)}' \
  /tmp/static-nil-pressure-real-repo-audit.json \
  > /tmp/static-nil-pressure-real-repo-audit-input.json
cargo run --quiet --manifest-path gems/nil-kill/Cargo.toml -- \
  /tmp/static-nil-pressure-real-repo-audit-input.json \
  /tmp/static-nil-pressure-real-repo-actions.json
```

## Result

FactMine exported 1,051 nullable states, 370 nullable operations, 103
refinements, and 32 summaries. It emitted no hidden-enum observations for
these non-Ruby sources.

The Go input produced 347 potential operations and the C++ input produced 23.
Every one was incomplete or had an unknown state; the C input produced no
operation fact. Consequently there were zero complete, proven-nullable
operations. NilKill emitted zero `report_static_nil_pressure` actions and zero
`report_static_primitive_domain` actions.

This is the expected precision behavior: unresolved operations remain public
facts for diagnostics and future enrichment, but they cannot become causal
pressure or a claim that a source is safe. The audit does not establish that
the inspected programs contain no null defects; it establishes that the static
report does not manufacture a finding without a complete proven-null path.
