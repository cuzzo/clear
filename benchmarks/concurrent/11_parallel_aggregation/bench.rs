// Parallel Aggregation Benchmark — Rust / Rayon
//
// Same LCG, same seed, same N and bucket count as CLEAR.
//
// Phase 1: Rayon parallel fold + reduce for histogram.
//   Each thread builds a local HashMap, reduce merges them.
//   Zero locks, zero contention — same model as CLEAR's SHARD pipeline,
//   but requires explicit fold/reduce (~10 lines vs 1 line).
//
// Phase 2: Rayon parallel reduce for sum/max/min/avg.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use rayon::prelude::*;
use std::collections::HashMap;
use std::time::Instant;

const N: i64 = 1_000_000;
const BUCKETS: i64 = 1_000;

fn lcg(state: i64) -> i64 {
    state.wrapping_mul(6364136223846793005_i64)
         .wrapping_add(1442695040888963407_i64)
}

fn main() {
    // Pre-compute seeds (LCG is sequential)
    let mut seeds = Vec::with_capacity(N as usize);
    let mut seed: i64 = 42;
    for _ in 0..N {
        seed = lcg(seed);
        seeds.push(seed);
    }

    // Phase 1: Parallel fold + reduce histogram
    let t0 = Instant::now();
    let counts: HashMap<i64, i64> = seeds
        .par_iter()
        .fold(
            || HashMap::with_capacity(BUCKETS as usize),
            |mut acc, &s| {
                *acc.entry(s.abs() % BUCKETS).or_insert(0) += 1;
                acc
            },
        )
        .reduce(
            || HashMap::new(),
            |mut a, b| {
                for (k, v) in b {
                    *a.entry(k).or_insert(0) += v;
                }
                a
            },
        );
    let hist_time = t0.elapsed();

    // Phase 2: Parallel stats
    let t1 = Instant::now();
    let values: Vec<f64> = counts.values().map(|&v| v as f64).collect();
    let total: f64 = values.par_iter().sum();
    let highest: f64 = values.par_iter().cloned()
        .reduce(|| f64::NEG_INFINITY, |a, b| if a > b { a } else { b });
    let lowest: f64 = values.par_iter().cloned()
        .reduce(|| f64::INFINITY, |a, b| if a < b { a } else { b });
    let average = total / values.len() as f64;
    let stats_time = t1.elapsed();

    assert_eq!(total as i64, N, "total mismatch");

    println!("Events: {}", N);
    println!("Buckets: {}", BUCKETS);
    println!("Shard histogram: {:.0} ms", hist_time.as_secs_f64() * 1000.0);
    println!("Aggregation: {:.0} ms", stats_time.as_secs_f64() * 1000.0);
    println!("Total: {}", total);
    println!("Max: {}", highest);
    println!("Min: {}", lowest);
    println!("Avg: {:.2}", average);
    println!("Verified: yes");
    println!("BENCH_RESULT: {} ms", hist_time.as_millis() + stats_time.as_millis());
}
