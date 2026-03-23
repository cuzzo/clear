// HashMap Benchmark — Rust Baseline
//
// WHY RUST IS FAST HERE:
//   std::collections::HashMap uses Siphash-1-3 (DoS-resistant, ~4 ns/hash).
//   The bucket array grows geometrically — O(log N) heap allocations for 1M
//   inserts, not 1M. No per-key malloc: String owns its buffer.
//
// DIFFERENCE vs C:
//   - Rust allocates a String per key (heap-copies the key bytes), but the
//     allocator is jemalloc or the system allocator — much faster than GPA
//     for small allocations.
//   - No GPA bookkeeping lock contention.
//
// DIFFERENCE vs CLEAR @map:
//   - Rust's HashMap bucket array is heap-managed but uses the system
//     allocator directly (not GPA with bookkeeping). Keys are owned Strings
//     (single allocation each), equivalent to CLEAR's key_copy, but without
//     GPA overhead.
//   - Siphash is slower than FNV-1a for short keys, so Rust loses some
//     raw throughput to C here.

use std::collections::HashMap;
use std::time::Instant;

const N: usize = 1_000_000;

fn main() {
    // Pre-generate keys once.
    let keys: Vec<String> = (0..N).map(|i| i.to_string()).collect();

    let mut map: HashMap<&str, f64> = HashMap::with_capacity(N);

    // ---- INSERT ----
    let t0 = Instant::now();
    for (i, k) in keys.iter().enumerate() {
        map.insert(k.as_str(), i as f64);
    }
    let ins_ms = t0.elapsed().as_secs_f64() * 1000.0;

    // ---- LOOKUP ----
    let t0 = Instant::now();
    let mut sum: f64 = 0.0;
    for k in &keys {
        sum += map.get(k.as_str()).copied().unwrap_or(0.0);
    }
    let lkp_ms = t0.elapsed().as_secs_f64() * 1000.0;

    assert!(sum > 0.0);
    println!("sum = {:.0}", sum);
    println!(
        "Insert: {:.1} ms | Lookup: {:.1} ms | Total: {:.1} ms",
        ins_ms,
        lkp_ms,
        ins_ms + lkp_ms
    );
}
