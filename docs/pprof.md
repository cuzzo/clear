# pprof integration

`clear profile` emits its runtime profile data in pprof's gzipped
protobuf format alongside the existing text dumps, so you can use
the standard `pprof` tool for flamegraphs, call graphs, and source
views.

## Install

| Tool | When you need it | Install |
|---|---|---|
| `pprof` | Always (the viewer) | `go install github.com/google/pprof@latest` |
| `perf_to_profile` | If you want CPU flamegraphs from `perf.data` | `go install github.com/google/perf_data_converter/src/cmd/perf_to_profile@latest` |
| `graphviz` | If you use `pprof -svg` / `pprof -dot` | `apt install graphviz` / `brew install graphviz` |

The web UI (`pprof -http=:8080`) and `pprof -top` text view do not
need graphviz.

## Use

```sh
clear profile foo.cht
# -> writes foo.profile/heap.pb.gz, lock.pb.gz, mvcc.pb.gz
#    (and cpu.pb.gz if perf_to_profile is on PATH)

pprof -http=:8080 ./foo foo.profile/heap.pb.gz
pprof -top -alloc_space  foo.profile/heap.pb.gz
pprof -top -inuse_space  foo.profile/heap.pb.gz
pprof -top -delay        foo.profile/lock.pb.gz
pprof -base before/heap.pb.gz after/heap.pb.gz   # regression diff
```

## What's in each file

### `heap.pb.gz`

Sample columns: `alloc_objects` / `alloc_space` / `inuse_objects` /
`inuse_space`. Each call site is one sample with its hex address as
a label (`pprof -tags heap.pb.gz`).

### `lock.pb.gz`

Sample columns: `contentions` / `delay` / `hold` / `acquisitions`.
Read+write contention sums into `contentions`; `delay` is the total
wait (read+write); `hold` is total exclusive hold time.

### `mvcc.pb.gz`

Sample columns: `reads` / `commits` / `retries` / `cow_bytes`.
`cow_bytes = struct_size * (commits + retries)` — the byte volume
moved by copy-on-write commits, the most direct cost signal for
`@shared:versioned` cells.

### `cpu.pb.gz`

Standard CPU profile from `perf.data`, converted by
`perf_to_profile`. Sample columns are whatever Go's pprof shows
(`samples` / `cpu` ns).

## CLEAR source mapping

The transpiler emits `// CLR:N` markers in `transpiled.zig`. Our
converter walks those back to the user's `.cht` line and stamps it
onto each pprof Location, so `pprof -list <fn>` shows CLEAR source
lines (not Zig).

## Sampling

Stack traces for **alloc-profile** are captured on every alloc by
default. For workloads where the per-alloc unwind cost matters,
`--sample=N` records every Nth event and scales the captured values
by N so doctor / pprof see estimated totals:

```sh
clear profile foo.cht --sample=100
```

Header records the chosen `sample_n` so consumers can rescale or
flag the approximation.

## Stack traces for lock and mvcc profiles

`--sync-callstacks` (off by default) turns on per-record stack
capture in lock-profile and mvcc-profile, so pprof's tree/flame
views and per-caller attribution work for these profiles too:

```sh
clear profile foo.cht --sync-callstacks            # auto-bumps --sample to 100
clear profile foo.cht --sync-callstacks --sample=1  # full capture, full cost
```

Off by default because the FP walk costs ~100-500ns per record.
Uncontended mutex acquire is ~10-20ns and MVCC commit fast paths
are ~20-50ns, so the trace can dominate the operation it's measuring.
When the flag is set without an explicit `--sample`, we auto-default
to `--sample=100` to keep the cost manageable.

With `--sync-callstacks` on, each (lock, caller-trace) pair becomes
its own row in lock-profile, and same for (cell, caller-trace) in
mvcc-profile. Doctor aggregates rows back to one-per-lock for its
existing diagnoses; pprof tree views show the per-caller breakdown.

## Doctor flags built on this data

`clear doctor` consumes the same profile dirs and grew three new
flags that draw on the multi-frame trace data:

```sh
clear doctor foo.profile/ --cumulative           # rank functions by cum bytes
clear doctor foo.profile/ --focus=intToString    # filter to traces that touch this function
clear doctor foo.profile/ --ignore=intToString   # drop traces that touch this function
clear doctor foo.profile/ --peek=processRequest  # callers + callees of one function
clear doctor old.profile/ --diff new.profile/    # perf-regression diff between two runs
```

`--cumulative` aggregates bytes/allocs across every frame in each
trace, so a function high in the call stack accrues its callees'
costs. `--focus=REGEX` keeps only sites whose trace touches a function
matching the pattern. `--diff` reports per-function deltas in
allocation, lock contention, and MVCC retries, with directional arrows
and "newly contended" / "retries eliminated" annotations.

## Notes

- We do not emit a Mapping message for the binary, so `pprof` prints
  "Main binary filename not available" and skips its own symbolization.
  Function names still appear because we resolve via `addr2line` at
  conversion time.
- alloc-profile captures stacks unconditionally (multi-frame v2,
  comma-separated leaf-first in `alloc.txt`).
- lock-profile (v3) and mvcc-profile (v2) capture stacks only when
  `--sync-callstacks` is on. The 12th column of `locks.txt` and the
  8th column of `mvcc.txt` carry `-` (off) or comma-separated leaf-
  first addrs (on). Tab-separated to allow commas in the trace field.
