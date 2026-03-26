# Control Plane

CLEAR's runtime control plane adapts LIVE while your program runs. It monitors three aspects of fiber execution and takes corrective action automatically — no restarts, no recompilation, no code changes.

## Events

| Event | Value | User Impact | Detection |
|---|---|---|---|
| **OnOverflow** | Safety | Prevents crashes | Trivial (trap-based) |
| **OnUnderflow** | Density | Saves memory, increases scale | Simple (high-water mark) |
| **OnSkew** | Throughput | Prevents core-idling / bottlenecks | Statistical (CV analysis) |

All three are enabled by default. The control plane is zero-configuration — it works out of the box for every CLEAR program.

## OnOverflow — Auto-Upsize

When a fiber overflows its stack (triggering `__morestack`), the control plane records which task class overflowed and upsizes all future spawns of that class.

**How it works:**
1. Fiber hits its stack limit → `__morestack` fires → segmented stack allocated (program continues)
2. Control plane records: "this function pointer needs a bigger stack"
3. Next time the scheduler spawns a task with that function, it allocates a larger stack tier

**Upsize ladder:** Micro (4KB) → Standard (16KB) → Large (64KB) → XL (256KB)

The first overflow per task class costs one segmented-stack allocation (~microseconds). Every subsequent spawn of that class gets the right size immediately. The ratchet only goes up — no thrashing.

**Why it matters:** Stack overflow on fibers is the #1 failure mode in production fiber runtimes. Auto-upsizing eliminates the "guess the right stack size" problem. Users just spawn tasks and the runtime learns.

## OnUnderflow — Auto-Downsize

When a task consistently uses far less stack than allocated, the control plane downsizes future spawns to save memory.

**How it works:**
1. When a task finishes, the runtime scans the stack for the 0xCC fill pattern to find the high-water mark
2. If usage < 25% of the tier's capacity: increment the 2-tier underflow counter
3. If usage < 50% of the tier's capacity: increment the 1-tier underflow counter
4. When counters cross thresholds, downsize the recommendation

**Thresholds (conservative by design):**
- 2-tier underflow (used < 25%): downsizes by 2 tiers after **10,000** completions
- 1-tier underflow (used < 50%): downsizes by 1 tier after **100,000** completions

Downsizing is conservative because a wrong downsize causes an overflow — which OnOverflow catches, but thrashing wastes cycles. The high thresholds ensure downsizing only happens when the pattern is statistically significant.

**Why it matters:** Long-running servers with many task classes accumulate waste when tasks are oversized. OnUnderflow recovers that memory automatically over time.

## OnSkew — Auto-Fix Key Distribution

When a sharded map has uneven key distribution (one shard handling disproportionate traffic), the control plane enables per-shard locks to allow cross-shard work stealing.

**How it works:**

Every sharded map has per-shard mutexes that are **elided by default** — the locks exist in memory but are never acquired. Each operation increments a per-shard atomic counter. When the control plane checks these counters and finds skew (coefficient of variation > 1.5), it flips `locks_elided` to false. The mutexes activate instantly.

**Cost of always-on readiness:**
- Memory: 8 bytes per shard (one Mutex). 64 shards = 512 bytes — less than 1% of typical map entry data.
- Runtime: one `mov` + predicted branch per operation (~1 CPU cycle). The branch is always predicted because the flag almost never flips.

**Why it matters:** Skew is uniquely dangerous because it's a property of the *data*, not the *code*. Developers can estimate their stack needs (overflow/underflow), but they almost never know their key distribution in advance. In most languages, fixing skew requires re-architecture (actors, consistent hashing, map-reduce). In CLEAR, the runtime flips a switch and enables work-stealing across shards. The program keeps running — it just stops wasting 75% of its CPU.

## Explicit Control

For cases where you know the access pattern upfront, you can force locks on at declaration time:

```clear
MUTABLE counts: HashMap<Int64>:sharded(8) @locked = {};
```

This skips the elision phase — locks are always active from the start. Use this when you want zero detection latency (e.g., you know keys are skewed before the program starts).

## Configuration

The control plane defaults are production-ready. For testing or tuning, policies can be set at runtime:

| Policy | Options | Default |
|---|---|---|
| `on_overflow` | `.upsize`, `.log`, `.ignore` | `.upsize` |
| `on_underflow` | `.downsize`, `.log`, `.ignore` | `.downsize` |
| `on_skew` | `.fix`, `.log`, `.ignore` | `.fix` |

The `.log` option records events without taking action — useful for understanding behavior before deployment. The `.ignore` option disables the policy entirely.
