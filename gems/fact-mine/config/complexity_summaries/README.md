# Analyzed complexity summaries

These generated artifacts contain complete Espalier time-and-space bounds keyed
by exact SCIP declaration symbols. FactMine applies bundled summaries after
SCIP ingestion. A symbol includes its package and version, so an artifact for
Go 1.22 cannot silently enrich Go 1.23 calls.

`go-stdlib.go1.22.2.json.gz` was built from the installed Go 1.22.2
implementation sources with scip-go 0.2.7. Its source surface is:

```text
syscall os time flag bytes bufio encoding/json encoding/xml sort strings
io/fs strconv math regexp fmt
```

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
profile SHA-256 and exported symbol count; FactMine validates both the envelope
and every bound at startup. Add a focused exact-version join test whenever a
new bundle is registered in `external_summary.rs`.
