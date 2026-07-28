# Analyzed complexity summaries

These generated artifacts contain complete Espalier time-and-space bounds keyed
by exact SCIP declaration symbols. FactMine applies bundled summaries after
SCIP ingestion. Bundled artifacts additionally require the exact SCIP indexer
name and version recorded by the consumer index. This protects symbol schemes
that do not put the toolchain revision directly in every symbol.

The current producer writes the v3 envelope. V3 retains all v2 provenance and
adds exact semantic-environment claims plus an optional generated symbol-bridge
digest. FactMine still reads existing v1/v2 artifacts. Explicitly supplied v3
summaries fail on a missing or mismatched claim; bundled summaries remain
inactive until both their indexer and environment match.

`go-stdlib.go1.22.2.json.gz` was built from the installed Go 1.22.2
implementation sources with scip-go 0.2.7. Its source surface is:

```text
syscall os time flag bytes bufio encoding/json encoding/xml sort strings
io/fs strconv math regexp fmt
```

The bundle contains 322 exact symbols whose time and space bounds are proven
from analyzed bodies, exact analyzed targets, CFG/DFG structure, or
compiler-provided closed candidate sets. A function is intentionally omitted
when its apparent completeness depends on a reviewed/manual receiver registry,
an external-latency or modeled-world contract, an unknown cardinality relation,
or an unresolved call-evidence gap. Those omissions remain eligible for the
manual incomplete-data fallback.

Rebuild it through the shared manifest producer:

```bash
bundle exec ruby gems/espalier/exe/espalier stdlib-map \
  --manifest gems/fact-mine/config/stdlib_maps/go-1.22.2.yml
```

The gzip header is deterministic. The v2 envelope records the complete input
profile SHA-256, proof policy, source-proven method count, and exported symbol
count; FactMine validates the schema and every bound at startup. Add a focused
exact-version join test whenever a new bundle is registered in
`external_summary.rs`.

`rust-stdlib.rustc1.96.0.json.gz` was built from the installed Rust 1.96.0
`core`, `alloc`, and `std` implementation sources at compiler commit
`ac68faa20c58`, indexed by rust-analyzer from the same build. It contains 1,543
source-proven exact symbols. rust-analyzer identifies those crates by their
source repository URL rather than a release number, so FactMine applies the
bundle only when the consumer SCIP metadata reports the exact compatible
`rust-analyzer 1.96.0 (ac68faa 2026-05-25)` build.

The source pass also models Rust's implicit function-exit destruction. In
particular, `core::mem::drop<T>` is omitted instead of being exported as O(1):
its empty source body hides a destructor selected by `T`. Conflicting duplicate
symbols emitted by rust-analyzer for two test-only declarations are omitted
rather than selected by order.

Rebuild it through the same producer:

```bash
bundle exec ruby gems/espalier/exe/espalier stdlib-map \
  --manifest gems/fact-mine/config/stdlib_maps/rust-1.96.0.yml
```

`java-stdlib.jdk21.0.12.json.gz` contains 2,598 exact symbols from
`java.lang` and `java.util` in the pinned Adoptium JDK 21.0.12+8 source.
scip-java indexes the source in a patch-module Maven project. The generic
producer first verifies its exact producer symbols, then relocates the Maven
project prefix to the `semanticdb maven jdk 21` identity emitted in user
projects. A complete disagreement with the existing Java fallback remains a
hard error; this process found and corrected the former `Objects.hash`
auxiliary-space overestimate.

```bash
bundle exec ruby gems/espalier/exe/espalier stdlib-map \
  --manifest gems/fact-mine/config/stdlib_maps/java-21.0.12.yml
```

`python-stdlib.cpython3.11.9.json.gz` contains 200 exact symbols from 43
selected pure-Python CPython 3.11.9 implementation files. The source selection
is staged into an isolated index workspace because scip-python 0.6.6 crashes
while indexing an unrelated `signal.py`; staging is a generic manifest feature,
not Python behavior in the shared producer.

```bash
bundle exec ruby gems/espalier/exe/espalier stdlib-map \
  --manifest gems/fact-mine/config/stdlib_maps/python-3.11.9.yml
```

FactMine discovers all `.json.gz` files in this directory at build time.
Adding a generated bundle therefore requires no language-specific registration
code. `../stdlib_maps/support.yml` records the fail-closed status of maintained
SCIP languages whose source bodies or consumer version identity are currently
insufficient for safe publication.
