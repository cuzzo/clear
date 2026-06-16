# Decomplex Native Scaling Notes

## Current Strategy

The Rust port parallelizes at the `Document` boundary:

```text
scan_files -> syntax::parse_files -> scan_documents
```

`syntax::parse_files` parses and normalizes files in parallel, while detectors still consume a deterministic `Vec<Document>` in input order. This is intentional. It keeps the Rust code close to the Ruby architecture so detectors and language normalizers can be ported file-for-file instead of redesigned around detector-specific map/reduce pipelines.

Parallelism is controlled with:

- `--jobs=N` on `decomplex detector ... --engine=rust`
- `--jobs=N` on the native `decomplex-rust` command
- `DECOMPLEX_RUST_JOBS`
- `DECOMPLEX_JOBS`

## Measured Scaling

Measured on `src/` with 162 Ruby files, using the release native binary.

| Detector | Jobs | Elapsed | Speedup | Efficiency |
|---|---:|---:|---:|---:|
| `co-update` | 1 | 2.125s | 1.00x | 100.0% |
| `co-update` | 2 | 1.217s | 1.75x | 87.3% |
| `co-update` | 4 | 0.732s | 2.90x | 72.6% |
| `co-update` | 8 | 0.491s | 4.33x | 54.1% |
| `co-update` | 16 | 0.424s | 5.01x | 31.3% |
| `co-update` | 32 | 0.446s | 4.77x | 14.9% |
| `predicate-alias` | 1 | 2.097s | 1.00x | 100.0% |
| `predicate-alias` | 2 | 1.220s | 1.72x | 86.0% |
| `predicate-alias` | 4 | 0.716s | 2.93x | 73.2% |
| `predicate-alias` | 8 | 0.486s | 4.32x | 53.9% |
| `predicate-alias` | 16 | 0.383s | 5.47x | 34.2% |
| `predicate-alias` | 32 | 0.462s | 4.54x | 14.2% |
| `structural-similarity` | 1 | 4.265s | 1.00x | 100.0% |
| `structural-similarity` | 2 | 3.480s | 1.23x | 61.3% |
| `structural-similarity` | 4 | 3.010s | 1.42x | 35.4% |
| `structural-similarity` | 8 | 2.756s | 1.55x | 19.3% |
| `structural-similarity` | 16 | 2.740s | 1.56x | 9.7% |
| `structural-similarity` | 32 | 2.761s | 1.54x | 4.8% |

## Interpretation

The current implementation does not scale well to 32 jobs on this workload.

`co-update` and `predicate-alias` are parse-heavy enough to benefit substantially from parallel document construction, peaking around 16 jobs. `structural-similarity` has more serial detector aggregation after parsing, so it barely improves beyond 4-8 jobs.

For now, the best practical default is `--jobs=8` or `--jobs=16`, not `--jobs=32`.

## Why Not Deeper Parallelism Yet?

The immediate goal is a sustainable Ruby-to-Rust migration:

1. Port Ruby `Syntax`/`Document` shape to Rust.
2. Port each detector as a direct `scan_documents` translation.
3. Port each language normalizer into the shared `Document` abstraction.

Detector-specific map/reduce aggregation could improve some metrics later, but it would also force architectural drift while the port is still incomplete. The current boundary gives useful speedups without making future detector and language migrations harder.

Once all detectors and language normalizers are ported, deeper parallel aggregation can be added selectively where profiling shows a decisive win.
