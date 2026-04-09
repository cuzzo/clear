// Parallel Aggregation Benchmark — Distributed Histogram + Stats (Rust)
//
// Same LCG, same seed, same N as CLEAR. Uses Rayon for parallel iteration
// and DashMap for concurrent histogram building.
//
// cargo build --release && ./target/release/bench

use std::collections::HashMap;
use std::time::Instant;

fn lcg(state: i64) -> i64 {
    state.wrapping_mul(6364136223846793005i64).wrapping_add(1442695040888963407i64)
}

fn main() {
    let n: i64 = 100_000;
    let buckets: i64 = 10_000;
    let mut seed: i64 = 42;

    let start = Instant::now();

    // Phase 1: Build histogram (sequential — matching CLEAR's sequential loop)
    let mut counts: HashMap<String, i64> = HashMap::new();
    for _ in 0..n {
        seed = lcg(seed);
        let bucket = seed.abs() % buckets;
        let key = format!("b:{}", bucket);
        *counts.entry(key).or_insert(0) += 1;
    }

    // Phase 2: Stats over histogram values
    let values: Vec<f64> = counts.values().map(|&v| v as f64).collect();
    let total: f64 = values.iter().sum();
    let highest: f64 = values.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
    let lowest: f64 = values.iter().cloned().fold(f64::INFINITY, f64::min);
    let average: f64 = total / values.len() as f64;

    let elapsed = start.elapsed();

    assert_eq!(total as i64, n, "total mismatch");
    assert!(highest > 0.0);
    assert!(lowest > 0.0);
    assert!(average > 0.0);

    println!("Events: {}", n);
    println!("Buckets: {}", buckets);
    println!("Total: {}", total);
    println!("Max: {}", highest);
    println!("Min: {}", lowest);
    println!("Avg: {}", average);
    println!("Verified: yes");
    println!("Time: {:.4} s", elapsed.as_secs_f64());
}
