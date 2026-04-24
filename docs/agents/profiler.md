# `clear profile` / `clear doctor` — profiler architecture

## Pipeline

```
clear profile foo.cht [-- args]
    └─ do_build(profile: true)       # ReleaseFast + CLEAR_PROFILE comptime flag + -fno-strip
    └─ perf record -g -o .profile/perf.data
    └─ CLEAR_ALLOC_PROFILE=.profile/alloc.txt ./foo
    └─ strace -c -o .profile/syscalls.txt ./foo
    └─ perf stat -o .profile/perf-stat.txt ./foo
    └─ cp source.cht .profile/                # for doctor source snippets
    └─ cp transpiled.zig .profile/            # Zig source for addr2line + CLR:N mapping

clear doctor .profile/
    ├─ Heap profile      (alloc.txt + addr2line → CLR:N lines)
    ├─ CPU profile       (perf report — top functions)
    ├─ CLEAR hot lines   (perf srcline → CLR:N mapping → top CLEAR lines)  ← Tier 1
    ├─ Syscalls          (strace -c)
    ├─ Hardware counters (perf stat)
    └─ FREEZE opportunity (LLC miss rate + small-alloc clustering)
```

## Detection tiers

Patterns are graded by the telemetry they need.

### Tier 1 — no new runtime telemetry (current)

Uses data perf / strace / the existing allocator already emit. Adding
a new tier-1 pattern is pure Ruby work in the `clear doctor` analyzer.

| Pattern | Signal |
|---|---|
| CLEAR hot lines | `perf report --sort=srcline` + `// CLR:N` map |
| Pipeline stage imbalance | Hot line contains `s>` |
| Frame-vs-heap attribution | Alloc site count + avg size + `(arena)`/`(heap rc)` tag |
| FREEZE opportunity | LLC miss rate >20% + small-alloc clustering |
| Lock contention (coarse) | `pthread_rwlock_*` in CPU top-10 |

### Tier 2 — new runtime telemetry

Patterns that need the runtime to record new metrics. All are gated
on the `CLEAR_PROFILE` comptime flag (see "zero overhead" below) —
Zig's comptime evaluation erases the telemetry entirely in production
builds.

| Pattern | Telemetry | Status |
|---|---|---|
| Fast producer / slow consumer | `BoundedChannel` pushes/pops/push_blocked/pop_blocked/max_depth, written to `.profile/channels.txt` | **done** |
| Lock hold-time distribution | `pthread_rwlock_*` timestamps on acquire/release | deferred |
| Fiber lifetime distribution | Spawn/exit timestamps | deferred |
| Workstealing balance | Per-scheduler fibers-run counter | deferred |
| Per-lock contention attribution | Per-lock wait-time counter | deferred |

### Tier 3 — extensive telemetry (deferred)

Heavy tracking; runtime cost is non-trivial even in profile mode.
Worth it only when the user opts in explicitly.

| Pattern | Telemetry |
|---|---|
| Rc cycle detection | Retention count tracking per `@multiowned` value |
| Heap fragmentation | Arena free-list size histogram |
| Allocation fingerprinting | Hash alloc contents to detect repeated identical allocs |

## Zero-overhead guarantee for Tier 2/3

`clear profile` passes `profile: true` to `do_build`, which injects
`pub const CLEAR_PROFILE = true;` at the top of the transpiled Zig.
Non-profile builds have no such injection; `CLEAR_PROFILE` defaults
to `false` in the runtime header.

Every Tier 2/3 telemetry site MUST be written as:

```zig
if (CLEAR_PROFILE) {
    // record telemetry
}
```

Zig's comptime-if evaluation erases the branch entirely when
`CLEAR_PROFILE == false`, so `clear build` / `clear build --optimized`
/ `clear build --safe` emit exactly the same machine code they do
today. The only cost to non-profile users is a flag read at compile
time.

DO NOT use a runtime boolean; use a `comptime` branch.

## Adding a new pattern

Tier 1 (no runtime change):
1. Add a new `puts "=== ... ==="` section in `clear doctor` after
   the CPU profile but before Syscalls. Use the existing
   `perf report` / `addr2line` / `// CLR:N` plumbing.
2. Add a smoke-test pattern in `spec/clear_bin_spec.rb` (TODO) that
   runs a known-slow program and asserts the pattern fires.

Tier 2 (new runtime telemetry):
1. Gate the telemetry site on `if (CLEAR_PROFILE) { ... }`.
2. Write the data to `.profile/<pattern>.txt` (or append to
   `alloc.txt`'s format). Follow the existing column convention.
3. Parse and emit in `clear doctor` as a new section.

Tier 3:
Same as Tier 2 but budget for the cost — these patterns are acceptable
to slow `clear profile` runs noticeably, not production builds.

## What NOT to do

- Don't write telemetry that runs unconditionally. Always comptime-gate.
- Don't add a telemetry section to `clear doctor` that silently fails
  when the data file is absent — emit nothing when the signal isn't
  there (the way FREEZE / hot-lines sections already do).
- Don't attribute samples to Zig-source lines without the CLR:N map.
  The output should always speak in CLEAR terms; the user shouldn't
  need to know the transpiled layout.
