# FRVO — Frame Return Value Optimization

> **Status**: Discussion document for future implementation. Not yet implemented.

## The Vision

CLEAR's allocation story is: "you get perfect allocation without thinking about it." The compiler assigns every value to the cheapest safe allocator — stack for small values, frame arena for function-scoped data, heap only when necessary.

FRVO extends this to function returns: **allocate the return value directly in the caller's frame, avoiding the promote-to-heap round trip entirely.**

This would make CLEAR's allocation story genuinely unique. Most languages either:
- Always heap-allocate returned objects (Go, Java, Python)
- Rely on escape analysis that's partial and unpredictable (JVM, Go)
- Require manual placement (C++, Rust)
- Use NRVO which avoids copies but doesn't control the allocator (C++, Zig)

FRVO would mean: a function that builds a string, list, map, or struct returns it with **zero heap allocation** if the caller's frame outlives the callee.

## Current State

Today, frame-allocated data that escapes a function return is promoted to heap:

```
Callee frame:  [result data here]
                    ↓ promote (memcpy to heap)
Heap:          [result data copy]
                    ↓ return slice/pointer to heap copy
Caller:        receives heap-backed data
                    ↓ defer free at scope exit
```

Cost: one heap allocation + memcpy + one deferred free per return.

## What FRVO Would Do

```
Caller frame:  [... caller's data ...]
                    ↓ callee allocates directly here
Caller frame:  [... caller's data ... result data ...]
                    ↓ return (no copy needed)
Caller:        receives frame-backed data (zero-cost cleanup on frame rewind)
```

Cost: zero heap allocations, zero copies, zero deferred frees.

## How It Could Work

### Mechanism: Pass the caller's frame allocator to the callee

Instead of the callee using its own `rt.frameAlloc()`, it uses the caller's:

```zig
// Today:
fn makeString(rt: *Runtime) ![]const u8 {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);
    const result = try CheatLib.concat(rt.frameAlloc(), "hello", " world");
    return try rt.heapAlloc().dupe(u8, result);  // heap promote
}

// With FRVO:
fn makeString(rt: *Runtime, caller_alloc: std.mem.Allocator) ![]const u8 {
    const frame_mark = rt.saveFrameMark();
    defer rt.restoreFrameMark(frame_mark);
    // Result allocated in CALLER's frame — survives callee's frame rewind
    return try CheatLib.concat(caller_alloc, "hello", " world");
}
```

The caller passes its own `frameAlloc()` for the return value. The callee uses its own `frameAlloc()` for temporaries (which are rewound on exit) but the *result* goes into the caller's frame.

### What the compiler needs to decide

For each function call that returns escapable data:
1. **Can the return value live in the caller's frame?** Yes if the caller's scope outlives the return value's usage.
2. **Which allocations are "the result" vs "temporaries"?** The final value passed to `return` is the result; everything else is a temporary.

### Approach 1: Dual-allocator (explicit)

Pass two allocators to frame-using functions:
- `rt.frameAlloc()` — for temporaries (callee-owned, rewound on exit)
- `caller_alloc` — for the return value (caller-owned, survives)

The transpiler already knows which allocations feed into the return value (the `collection_return` / `escaped_return` analysis). It would route those allocations to `caller_alloc` instead of `rt.frameAlloc()`.

**Complexity**: Medium. Requires threading `caller_alloc` through all return-value-producing call chains. Most functions would ignore it (they don't return escapable data).

### Approach 2: Frame mark nesting (implicit)

Don't rewind the callee's frame mark if the return value is in it:

```zig
fn makeString(rt: *Runtime) ![]const u8 {
    // No saveFrameMark / restoreFrameMark — caller owns our frame region
    return try CheatLib.concat(rt.frameAlloc(), "hello", " world");
}
```

The callee allocates in the shared frame. The caller's frame rewind (at the caller's scope exit) frees everything — both the caller's data and the callee's return value.

**Problem**: Temporaries leak into the caller's frame. If the callee does 100 temporary allocations to produce a 10-byte result, the caller's frame holds all 110 bytes until its own scope exit.

**Mitigation**: Save/restore frame mark around temporaries, but NOT around the final result:

```zig
fn makeString(rt: *Runtime) ![]const u8 {
    const temp_mark = rt.saveFrameMark();
    // ... temporaries here ...
    rt.restoreFrameMark(temp_mark);
    // Allocate result AFTER restoring temps — it stays in the caller's frame
    return try CheatLib.concat(rt.frameAlloc(), prefix, suffix);
}
```

**Complexity**: High. The transpiler needs to split function bodies into "temporary" and "result" phases, which is essentially a form of liveness analysis.

### Approach 3: Selective FRVO (pragmatic)

Only apply FRVO to "leaf" string/collection operations — functions that do one allocation and return it. These are the common case:

```clear
-- ILLUSTRATIVE
FN greet(name: String) RETURNS String ->
    RETURN "Hello " + name;     -- single concat → FRVO candidate
END

FN buildReport(data: String) RETURNS Report ->
    -- Multiple temporaries → too complex for FRVO, use heap promote
    lines = split(data, "\n");
    header = lines[0];
    body = join(lines, " ");
    RETURN Report{ header: header, body: body };
END
```

**Complexity**: Low. The compiler checks: does the function do exactly one frame allocation that feeds directly into the return? If yes, skip the frame mark save/restore entirely (the caller owns the frame). If no, fall back to heap promotion.

## Risk Assessment

| Risk | Severity | Mitigation |
|---|---|---|
| **Frame overflow** | Medium | More data lives longer in the frame; may need larger arenas or overflow-to-heap |
| **Lifetime bugs** | High | FRVO data must not outlive the caller's frame; needs careful lifetime tracking |
| **Interaction with BG captures** | High | If a BG block captures an FRVO'd value, it's in the caller's frame — needs promotion |
| **Recursive functions** | Medium | Deep recursion with FRVO accumulates in the frame; may overflow |
| **Test coverage** | Medium | Every FRVO path needs tests for correctness; the existing escape promotion tests would need updating |

## Effort Estimate

| Approach | Effort | Risk | Benefit |
|---|---|---|---|
| Approach 1 (dual-allocator) | 2-3 days | Medium | Full FRVO for all cases |
| Approach 2 (frame nesting) | 3-5 days | High | Full FRVO but complex temp management |
| Approach 3 (selective) | 1-2 days | Low | Covers 60-70% of cases (simple functions) |

## Recommendation

Start with **Approach 3** (selective FRVO). It covers the common case (simple string/collection returns), has low risk, and can be validated against the existing 112 transpile-tests. If it proves valuable, extend to Approach 1 for the remaining cases.

The key insight: most functions that return frame-allocated data do so via a single final operation (one concat, one split, one list build). Approach 3 catches all of these with minimal compiler changes.

## What FRVO Would NOT Help

- Functions that return heap-allocated data (@sharded maps, @pool, Rc/Arc)
- Functions where the return value is computed through many intermediate steps
- Cross-fiber returns (BG blocks) — these always need heap promotion
- Recursive fanout (parallel du style) — each fiber has its own frame

## Measuring Success

Before implementing, instrument the current heap promotions:
```clear
-- Count how many string/collection returns use heap promotion
-- Compare with: how many COULD use FRVO (single-allocation leaf functions)
```

If > 50% of returns are FRVO candidates, the optimization is worth pursuing. If most returns are complex multi-step computations, the benefit is limited.
