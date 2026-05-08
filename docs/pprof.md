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

Stack traces are captured on every alloc by default. For workloads
where the per-alloc unwind cost matters, `--sample=N` records every
Nth event and scales the captured values by N so doctor / pprof see
estimated totals:

```sh
clear profile foo.cht --sample=100
```

Header records the chosen `sample_n` so consumers can rescale or
flag the approximation.

## Notes

- We do not emit a Mapping message for the binary, so `pprof` prints
  "Main binary filename not available" and skips its own symbolization.
  Function names still appear because we resolve via `addr2line` at
  conversion time.
- alloc-profile is multi-frame as of v2 (`std.debug.captureCurrentStackTrace`
  in the runtime, leaf-first comma-separated addrs in `alloc.txt`).
  lock-profile and mvcc-profile are still single-frame; they will
  follow the same shape in a future change.
