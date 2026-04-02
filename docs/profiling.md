# Profiling

## Quick Start

```bash
./clear profile myapp.cht
./clear doctor myapp.profile/
```

`clear profile` builds with allocation tracking enabled (zero overhead in normal builds), runs the program, and collects:
- **Heap profile**: allocation counts and bytes per call site
- **CPU profile**: `perf record` sampling (when available)

`clear doctor` reads the profile data and prints actionable optimization advice with CLEAR source line numbers.

## Example

```bash
$ ./clear profile examples/scheme/interpreter.cht
Built: interpreter (ReleaseFast + alloc profiling)
Profiling: perf record -g -o .../perf.data -- env CLEAR_ALLOC_PROFILE=.../alloc.txt ./interpreter
All 21 Mal interpreter tests PASSED!

$ ./clear doctor examples/scheme/interpreter.profile/

=== Allocation Profile (3,683 allocs) ===

Top sites by bytes:
  1. evalList (line 341)          8.9 KB  (73 allocs, 124 bytes avg)  ** LEAK **
  2. readListEnv (line 211)       7.9 KB  (55 allocs, 146 bytes avg)  ** LEAK **
  3. clearMain (line 472)         673 B   (507 allocs, 1 bytes avg)   ** LEAK **

=== CPU Profile ===
  37.82%  [kernel]
  10.27%  _IO_flush_all
   8.41%  eval
   7.14%  memset
```

## How It Works

### Heap Profiling

Built into the runtime allocator VTable. Every `alloc` call in Zig passes `@returnAddress()` (the caller's return address) as a parameter. The profiler records this address, the allocation count, and bytes per site in a fixed-size hash table (1024 sites, no heap allocations inside the profiler).

Controlled by a comptime flag (`CLEAR_PROFILE`). When not set, the profiling code is eliminated at compile time - zero overhead in production.

### CPU Profiling

Uses Linux `perf record` for sampling-based CPU profiling. Requires `perf_event_paranoid <= 2`:

```bash
sudo sysctl kernel.perf_event_paranoid=2  # temporary, resets on reboot
```

### Source Mapping

`clear doctor` maps Zig addresses back to CLEAR source lines using:
1. `addr2line` to resolve addresses to Zig file:line
2. `// CLR:N` comments in the transpiled Zig to map back to CLEAR line numbers

The transpiled Zig source is saved in the `.profile/` directory for this purpose.

## Environment Variables

| Variable | Set by | Purpose |
|---|---|---|
| `CLEAR_ALLOC_PROFILE` | `clear profile` | Output path for allocation data |
| `CLEAR_THREADS` | User | Number of scheduler threads |
