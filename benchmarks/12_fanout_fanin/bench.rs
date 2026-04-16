// Fan-Out / Fan-In Benchmark — Rust / Rayon
//
// 10,000 items processed in parallel via Rayon's work-stealing thread pool.
// Each item runs 100K LCG iterations (CPU-bound), results summed.
//
// Rayon is the idiomatic Rust choice for CPU-bound parallel work.
// Tokio (async I/O executor) is the wrong tool here — running synchronous
// CPU loops inside async tasks blocks the executor's threads.
//
// Rayon uses a work-stealing thread pool sized to num_cpu, matching
// CLEAR's CONCURRENT(parallel: TRUE) worker pool model.  Neither pays
// per-item spawn cost; both amortize thread overhead across the work queue.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::time::Instant;
use rayon::prelude::*;

const N_WORKERS: usize = 10_000;
const ITERATIONS: usize = 100_000;

fn do_work(seed: u64) -> u64 {
    let mut x = seed;
    for _ in 0..ITERATIONS {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    }
    x
}

fn main() {
    let t0 = Instant::now();

    let total: u64 = (0..N_WORKERS as u64)
        .into_par_iter()
        .map(do_work)
        .reduce(|| 0u64, |a, b| a.wrapping_add(b));

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Checksum: {}", total % 1_000_000_000);
    println!("Workers: {}", N_WORKERS);
    println!("Iterations: {}", ITERATIONS);
    println!("Time: {:.4} s", elapsed);
}
