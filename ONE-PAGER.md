# CLEAR: The High-Performance Language for Humans

## WHY CLEAR?
CLEAR is designed for systems where performance is a requirement, not a luxury, but where developer velocity and safety are paramount.

The goal is simple: **Be more correct than Rust, nearly as fast as hand-tuned C, with a language less complex than Go or TypeScript.**

## HOW?
CLEAR makes the common case zero-cost and the uncommon case explicit. You pay for complexity only when you use it.

*   **Costs Visible Where You Decide, Invisible Where You Use**: Performance trade-offs (like `shared` vs `multiowned`) are visible at the *definition* of a resource, but elided at the *usage*. This allows for massive architectural refactors (e.g., moving from single-threaded to multi-threaded) with zero "function coloring" or ripple effects.
*   **No Garbage Collector**: CLEAR uses Arena-based memory and deterministic reference counting. You get the predictable, jitter-free performance of Rust with the ergonomics of a managed language.
*   **Scoped Mutability, Not Lifetime Annotations**: Mutable shared access is scoped to explicit `WITH` blocks. No lifetime annotations, no borrow checker fights — shared mutability is a local reasoning task, not a global one.
*   **Capability System**: CLEAR separates **Types** (what data is) from **Capabilities** (how it's accessed). Functions take Types, not Capabilities, ensuring your business logic remains decoupled from your synchronization strategy.
*   **Railway Error Handling**: Error handling is a first-class control flow construct, not an after-thought. The "Happy Path" remains clear, while failure cases are handled via elegant `OR` and `CATCH` semantics.
*   **Native Interop via Zig**: CLEAR compiles to Zig, which compiles to native code via LLVM. Full access to the C standard library, native C ABI exports, and zero-overhead FFI — no bindings, no wrappers.

## WHAT DOES CLEAR LOOK LIKE?
CLEAR excels at high-throughput data processing. Here is a pipeline that handles back-pressure, manages complex errors, and leverages shared-nothing architecture:

```clear
-- Shared-nothing pool with Sharded Structure-of-Arrays for lock-free, cache-optimal access
MUTABLE sensors: Sensor[]@pool:sharded(64):soa = load_sensors();

-- Pipeline with parallel execution and dynamic control plane monitoring
results = sensors
  s> CONCURRENT(workers: 16, parallel: TRUE) SELECT
       process_reading(_) OR PRUNE    -- Drop failed readings
  s> WHERE _.intensity > 0.8
  s> LIMIT 1000;

-- The Control Plane automatically handles 'OnSkew'
-- If one shard becomes a bottleneck, the runtime detects the statistical
-- imbalance and enables work-stealing across shards automatically.
-- Note: IFF skew is detected, shared-nothing optimizations are sacrificed
-- to re-enable parallel processing of the skewed data.
```

## PERFORMANCE
In predictable workloads, as demonstrated in the included benchmarks, CLEAR outperforms Go and Rust/Tokio by 2-3x with considerably less, clearer code.

This is a v0.1 release. In unpredictable real-world workloads, CLEAR will not yet match this level of advantage — but there is substantial room for improvement by v1. We believe CLEAR will eventually outperform Go in nearly all cases: no garbage collector, nearly half the memory footprint, more predictable response times, and zero chance of data races.

## THE IMPLICATIONS
CLEAR's foundational principle is to **minimize global complexity and maximize local reasoning.**

1.  **Deep Optimization**: By enforcing local reasoning, the compiler can perform aggressive optimizations (like `Auto-Squishing` structs into SoA) that are often impossible in languages with pointer-aliasing or global side-effects.
2.  **Runtime Control Plane**: The runtime adapts to live data patterns that are unpredictable at compile-time. Stack overflow auto-upsizes future tasks. Memory waste auto-downsizes. Key skew auto-enables work-stealing. All three operate live, with zero restarts. See [docs/control-plane.md](docs/control-plane.md).
3.  **AI-Native**: CLEAR's local reasoning makes it unusually amenable to AI-assisted development and automated optimization.
