# Profiling Plan: Allocation Tracking for `./clear profile` and `./clear doctor`

## Problem

jemalloc heap profiling (`MALLOC_CONF=prof:true`) crashes CLEAR binaries.
jemalloc's profiler calls `backtrace()` / `_Unwind_Backtrace` on every
sampled allocation to capture the call stack. This unwinder walks the stack
using frame pointers or DWARF info. On CLEAR's fiber stacks (custom mmap'd
memory with non-standard frame layouts), the unwinder hits garbage and
segfaults.

This is not fixable without making fiber stacks unwindable, which would
require either frame pointer chains in the fiber context switch assembly or
full DWARF CFI annotations for the custom stacks. Neither is practical.

tcmalloc and mimalloc have the same problem -- all heap profilers that
attribute allocations to call sites need to unwind the stack.

## Solution

Build allocation tracking directly into the CLEAR runtime's allocator
VTable. The Zig allocator interface already passes `@returnAddress()` (the
immediate caller's address) to every `alloc` and `free` call. We capture
this without any stack unwinding.

The key insight: `@returnAddress()` is a single register read (the return
address is already on the stack / in the link register). It gives us the
immediate caller -- which in CLEAR's generated code is the runtime helper
that triggered the allocation (e.g., `numericMapPut`, `intToString`,
`concat`). This is the actionable information; full call stacks add little
value because CLEAR's call chains are shallow.

### What we get vs jemalloc

| Feature | jemalloc prof | @returnAddress tracking |
|---------|--------------|------------------------|
| Allocation count per site | Yes | Yes |
| Bytes per site | Yes | Yes |
| Live vs freed (leak detection) | Yes | Yes (with free tracking) |
| Full call stacks | Yes | No (immediate caller only) |
| Size distribution | Yes | Yes (with histograms) |
| Temporal snapshots | Yes | Yes (with periodic dumps) |
| Works on fiber stacks | **No** | **Yes** |
| Overhead | ~5% | ~1-2% |

### Where to instrument

The allocator VTable in `runtime.zig` (line 113-126) already receives
`ret_addr: usize` on every allocation:

```zig
fn smartAlloc(ctx: *anyopaque, n: usize, ptr_align: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    // ret_addr is @returnAddress() from the call site -- FREE instrumentation point
    ...
}
```

The heap allocator (`heap_allocator`, typically c_allocator/jemalloc) does
NOT pass through the VTable -- it's used directly. To track heap
allocations, we wrap it in a profiling allocator that forwards to the
underlying allocator and records the `ret_addr`.

Two instrumentation points:
1. `smartAlloc` / `smartFree` (frame allocator -- arena-backed, high volume)
2. `heapAlloc()` wrapper (heap allocator -- GPA/jemalloc, lower volume but leak-relevant)

## Implementation: 4 commits

### Commit 1: Allocation site tracker (tier 1 -- cumulative counts)

**New file: `zig/alloc-profile.zig` (~80 lines)**

```zig
const MAX_SITES = 512;

const Site = struct {
    addr: usize = 0,
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
};

var sites: [MAX_SITES]Site = [_]Site{.{}} ** MAX_SITES;
var site_count: usize = 0;

pub fn recordAlloc(ret_addr: usize, size: usize) void { ... }
pub fn dump(path: []const u8) void { ... }
```

Fixed-size hash table (open addressing, linear probe on `ret_addr`).
`recordAlloc` is called from the allocator VTable. `dump` writes a text
file at process exit:

```
# alloc-profile v1
# addr alloc_count alloc_bytes
0x4a23f0 1000000 48000000
0x4b1200 2 8388608
```

**Changes to `zig/runtime.zig` (~10 lines)**

- In `smartAlloc`: call `alloc_profile.recordAlloc(ret_addr, n)`
- Add a `deinit` or `atexit` hook to call `alloc_profile.dump(path)`
- Controlled by a comptime flag or an env var (`CLEAR_PROFILE=1`)

**Changes to `clear` CLI (~5 lines)**

- `./clear profile` sets `CLEAR_PROFILE=<profile_dir>/alloc.txt`
- `./clear run` does not set it (zero overhead in normal builds)

**Output**: `<name>.profile/alloc.txt`

**What this catches**: "intToString accounts for 80% of allocations" --
enough for `./clear doctor` to say "hot allocation site, consider
pre-allocation or buffering."

---

### Commit 2: Free tracking (tier 2 -- live vs freed, leak detection)

**Extend `zig/alloc-profile.zig` (~70 more lines)**

Add a pointer-to-site map for tracking frees:

```zig
const MAX_LIVE = 65536;

const LiveEntry = struct {
    ptr: usize = 0,
    site: u16 = 0,  // index into sites[]
    size: u32 = 0,
};

var live: [MAX_LIVE]LiveEntry = ...;
var live_count: usize = 0;
```

New fields per site:
```zig
const Site = struct {
    addr: usize = 0,
    alloc_count: u64 = 0,
    alloc_bytes: u64 = 0,
    free_count: u64 = 0,
    free_bytes: u64 = 0,
};
```

`recordFree(ptr)`: look up `ptr` in the live map, decrement the
corresponding site's live count, remove from live map.

**Changes to `zig/runtime.zig`**

- In `smartFree`: call `alloc_profile.recordFree(ptr)`
- Wrap `heapAlloc()` return with a profiling allocator that also records
  heap allocs/frees

**Output format extends to**:
```
# alloc-profile v2
# addr alloc_count alloc_bytes free_count free_bytes live_bytes
0x4a23f0 1000000 48000000 999990 47999520 480
0x4b1200 2 8388608 0 0 8388608
```

**What this catches**: site `0x4b1200` allocated 8MB and freed 0 -- leak
candidate. `./clear doctor` can flag this.

**Concern**: the live map is fixed-size (64K entries). Programs with >64K
simultaneous live allocations will overflow. Options:
- Ignore overflow (stop tracking frees for new allocs, cumulative still correct)
- Use a heap-allocated hash map (but then we're allocating inside the
  allocator -- need a separate backing allocator)
- 64K entries at 16 bytes each = 1MB. Acceptable.

---

### Commit 3: Size histograms (tier 3a -- allocation patterns)

**Extend Site struct (~30 more lines)**

```zig
const NBUCKETS = 8;

const Site = struct {
    // ... existing fields ...
    // Size histogram: bucket[i] = count of allocs in [2^(i+5), 2^(i+6))
    // Bucket 0: 0-63 bytes
    // Bucket 1: 64-255 bytes
    // ...
    // Bucket 7: 16KB+
    size_buckets: [NBUCKETS]u64 = [_]u64{0} ** NBUCKETS,
};
```

Bucket assignment: `@clz(@as(u64, size)) >> 1` or similar log2 mapping.

**Output format extends to**:
```
# alloc-profile v3
# addr alloc_count alloc_bytes free_count free_bytes live_bytes hist_0_63 hist_64_255 ...
0x4a23f0 1000000 48000000 999990 47999520 480 0 1000000 0 0 0 0 0 0
```

**What this catches**: "intToString makes 1M allocations all in the 64-255
byte bucket -- this is a classic small-allocation hotspot. Consider string
buffering or arena pre-allocation."

---

### Commit 4: Temporal snapshots (tier 3b -- growth curves)

**Extend `zig/alloc-profile.zig` (~50 more lines)**

Add periodic snapshot dumping, triggered by allocation count:

```zig
const SNAPSHOT_INTERVAL = 100_000; // every 100K allocations
var total_allocs: u64 = 0;
var snapshot_count: u32 = 0;

pub fn recordAlloc(ret_addr: usize, size: usize) void {
    // ... existing tracking ...
    total_allocs += 1;
    if (total_allocs % SNAPSHOT_INTERVAL == 0) {
        dumpSnapshot();
    }
}
```

Each snapshot writes `alloc.N.txt` (N = snapshot number) with the current
live state. The final dump on exit is `alloc.final.txt`.

**Output**: `<name>.profile/alloc.0.txt`, `alloc.1.txt`, ..., `alloc.final.txt`

**What `./clear doctor` does with this**:
- Compare live_bytes between snapshots: growing = leak, stable = normal, sawtooth = arena working correctly
- Identify which sites are growing: "site 0x4b1200 grew from 0 to 8MB between snapshot 2 and 5"
- Final report: "LEAK: numericMapPut at runtime-header.zig:2648 -- 8MB allocated, 0 freed. Live bytes grew monotonically across all snapshots."

## Address resolution

The alloc profile contains raw addresses (0x4a23f0). `./clear doctor`
resolves them to source file:line using:

```bash
addr2line -e <binary> -f 0x4a23f0
# Output: numericMapPut
#         runtime-header.zig:2648
```

Or using Zig's debug info directly (`std.debug.getSelfDebugInfo()`).

For mapping Zig source lines back to CLEAR source, the transpiler would
need to emit source location comments (future work -- not required for the
initial profiler).

## Files touched

| File | Commit | Changes |
|------|--------|---------|
| `zig/alloc-profile.zig` | 1-4 | New file, grows each commit |
| `zig/runtime.zig` | 1-2 | Instrument smartAlloc/smartFree, wrap heapAlloc |
| `clear` | 1 | Set CLEAR_PROFILE env var in profile command |
| `docs/profiling.md` | 4 | Update with alloc profile output docs |

## What `./clear doctor` will produce (future)

```
=== Allocation Profile ===

Top allocation sites by total bytes:
  1. numericMapPut (runtime-header.zig:2648)     48.0 MB  (1,000,000 allocs, 48 bytes avg)
  2. hashMap.ensureCapacity (runtime-header.zig:305)  8.0 MB  (2 allocs, 4.0 MB avg)  ** LEAK **
  3. intToString (runtime-header.zig:450)          2.1 MB  (100,000 allocs, 22 bytes avg)

Leak candidates (allocated but never freed):
  - hashMap.ensureCapacity: 8.0 MB live, 0 frees -- monotonic growth across 5 snapshots

Size distribution hotspots:
  - intToString: 100% in 0-63 byte bucket -- consider string arena or buffer reuse

=== CPU Profile (perf) ===
  [parsed from perf report --stdio output]
  ...
```
