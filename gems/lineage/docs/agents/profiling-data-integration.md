# Profiling-data integration (profile-hotness/v1)

How runtime profiles become path-attributed hotness in `lineage.db`, per
language, and what is known not to work.

## Pipeline

```
profiler capture -> tools/pprof_to_hotness.rb -> lineage ingest-hotness -> UI
```

`ruby tools/profile_hotness.rb --target NAME [--ingest --db lineage.db]`
packages capture + convert + ingest per sub-project of this repository;
`--list` shows targets.

## Capture recipes per language

| Languages | Capture | Converter input | Paths |
| --- | --- | --- | --- |
| Ruby | stackprof (`tools/stackprof_compile.rb` for the compiler; `tools/stackprof_shim.rb` via `RUBYOPT` for anything else), then `stackprof --json` | `--stackprof` | native |
| Go | `go test -run . -cpuprofile cpu.out`, then `go tool pprof -top -lines` | `--pprof-top` | native |
| Rust, Zig, C, C++ (any ELF) | `perf record -g -- CMD`, then `perf script -F comm,ip,sym,srcline` | `--perf-script` | needs DWARF (below) |

Tiers: critical >= 5% cumulative share, warm >= 0.5%, cold otherwise.
Ingest each workload under its own `--source`; consumers take the maximum
tier across sources. `--path-prefix` drops harness/vendor frames.

## DWARF requirement for perf-based languages

`perf script` only emits `file:line` when the binary carries debug info:

- **Rust**: build with `cargo build --profile profiling` (defined in
  `gems/fact-mine/Cargo.toml` as release + `debug = 1`). A plain release
  build has no DWARF and its frames arrive symbol-only or unsymbolized.
- **Zig / C / C++**: do not strip (`-fstrip`, `strip(1)`); Zig keeps debug
  info by default in all release modes. On large Zig binaries binutils
  `addr2line` is pathologically slow, so `profile_hotness.rb` caps
  srcline symbolization at 180s and falls back to symbols only; the
  ingest-time resolver then attributes frames from the unit inventory
  (verified: `lib.parking-lot.ParkingMutex.lock ->
  zig/lib/parking-lot.zig`). Installing `llvm-addr2line` lifts this
  limitation.

## Ingest-time symbol resolution

Profiler frames without a usable path are resolved by `ingest-hotness`
against the logical-unit inventory already in the database (no parsing -
run `lineage build` first). Tiers, recorded in `unit_hotness.resolution`:

1. `exact` / `declared` - the profile's own repo-relative path.
2. `basename` - DWARF basename corroborated against a unique project path
   defining that method tail.
3. `owner-tail` - owner + method tails match a unique unit (Go receivers,
   Zig types, JVM/C# classes), with module-path corroboration for
   `::`-qualified symbols.
4. `tail-unique` - the method tail is defined exactly once in the project
   and is not on the generic-name stoplist.

Anything below the bar stays `unresolved` - counted in tier dashboards but
never attributed to a file. `ingest-hotness` prints
`resolved_exact/resolved_symbol/unresolved` so per-language resolution
rates are measurable.

## Known gaps

- **Inlined frames do not exist in profiles.** Optimized Rust/Zig/C++
  inlines hot callees; their samples attribute to callers. No resolver can
  recover absent frames (DWARF inline tables via `perf --inline` help
  partially).
- **Out-of-project frames stay unresolved by design** (libc, language
  runtimes, external crates). On a real fact-mine capture, ~60% of frames
  are external - that is correct behavior, not a resolution failure.
- **External symbols colliding with project tails** can still mis-resolve
  through the owner-tail tier when the owner word also appears in a
  project path; module-path corroboration removes most but not all
  (measured: 1 residual in 698 on the fact-mine capture).
- **Overload sets and generic instantiations collapse** onto one unit -
  acceptable for hotness, wrong for per-signature attribution.
- **File-scoped C statics with generic names** (`parse`, `init`) are
  unresolvable without DWARF srclines; the stoplist keeps them unresolved
  rather than guessed.
- **Zig srclines are effectively unavailable without `llvm-addr2line`**;
  Zig entries rely on symbol resolution (owner-qualified Zig symbols
  resolve well, anonymous instantiations collapse to their template).
- **Interpreted languages must use their native profilers** (stackprof,
  py-spy); perf sees only VM frames. Python/JS/C# converter inputs
  (speedscope, `.cpuprofile`) are designed but not yet implemented.
