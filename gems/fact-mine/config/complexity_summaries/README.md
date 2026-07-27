# Analyzed complexity summaries

These generated artifacts contain complete Espalier time-and-space bounds keyed
by exact SCIP declaration symbols. FactMine applies bundled summaries after
SCIP ingestion. Bundled artifacts additionally require the exact SCIP indexer
name and version recorded by the consumer index. This protects symbol schemes
that do not put the toolchain revision directly in every symbol.

`go-stdlib.go1.22.2.json.gz` was built from the installed Go 1.22.2
implementation sources with scip-go 0.2.7. Its source surface is:

```text
syscall os time flag bytes bufio encoding/json encoding/xml sort strings
io/fs strconv math regexp fmt
```

The bundle contains 371 exact symbols whose time and space bounds are proven
from analyzed bodies, exact analyzed targets, CFG/DFG structure, or
compiler-provided closed candidate sets. A function is intentionally omitted
when its apparent completeness depends on a reviewed/manual receiver registry,
an external-latency or modeled-world contract, an unknown cardinality relation,
or an unresolved call-evidence gap. Those omissions remain eligible for the
manual incomplete-data fallback.

Rebuild it by generating a SCIP index for those package patterns, profiling
the non-test `.go` implementation files with FactMine using
`--no-bundled-complexity-summaries`, and running:

```bash
gems/espalier/script/export_complexity_summary.rb \
  --corpus go-stdlib-core-surface \
  --source-revision go1.22.2 \
  --indexer scip-go@0.2.7 \
  go-stdlib.profile.json \
  gems/fact-mine/config/complexity_summaries/go-stdlib.go1.22.2.json.gz
```

The gzip header is deterministic. The v2 envelope records the complete input
profile SHA-256, proof policy, source-proven method count, and exported symbol
count; FactMine validates the schema and every bound at startup. Add a focused
exact-version join test whenever a new bundle is registered in
`external_summary.rs`.

`rust-stdlib.rustc1.96.0.json.gz` was built from the installed Rust 1.96.0
`core`, `alloc`, and `std` implementation sources at compiler commit
`ac68faa20c58`, indexed by rust-analyzer from the same build. It contains 1,697
source-proven exact symbols. rust-analyzer identifies those crates by their
source repository URL rather than a release number, so FactMine applies the
bundle only when the consumer SCIP metadata reports the exact compatible
`rust-analyzer 1.96.0 (ac68faa 2026-05-25)` build.

The source pass also models Rust's implicit function-exit destruction. In
particular, `core::mem::drop<T>` is omitted instead of being exported as O(1):
its empty source body hides a destructor selected by `T`. Conflicting duplicate
symbols emitted by rust-analyzer for two test-only declarations are omitted
rather than selected by order.

Rebuild the Rust bundle by indexing the installed Rust library workspace,
profiling all `.rs` files below `library/core`, `library/alloc`, and
`library/std`, then running:

```bash
gems/espalier/script/export_complexity_summary.rb \
  --corpus rust-stdlib-core-alloc-std \
  --source-revision rustc-1.96.0-ac68faa20c58 \
  --indexer 'rust-analyzer@1.96.0 (ac68faa 2026-05-25)' \
  rust-stdlib.profile.json \
  gems/fact-mine/config/complexity_summaries/rust-stdlib.rustc1.96.0.json.gz
```
