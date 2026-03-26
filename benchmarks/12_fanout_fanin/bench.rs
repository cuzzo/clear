// Fan-Out / Fan-In Benchmark — Rust / Tokio
//
// Spawns N Tokio tasks, each computes a CPU-bound result (iterated LCG),
// then collects all results into a single sum.
//
// Tests: task spawn overhead, JoinSet throughput, fan-in latency.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::time::Instant;
use tokio::task::JoinSet;

const N_WORKERS: usize = 10_000;
const ITERATIONS: usize = 1_000;

fn do_work(seed: u64) -> u64 {
    let mut x = seed;
    for _ in 0..ITERATIONS {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    }
    x
}

#[tokio::main]
async fn main() {
    let t0 = Instant::now();

    // Fan-out: spawn N tasks
    let mut set = JoinSet::new();
    for i in 0..N_WORKERS {
        set.spawn(async move {
            do_work(i as u64)
        });
    }

    // Fan-in: collect results
    let mut total: u64 = 0;
    while let Some(result) = set.join_next().await {
        total = total.wrapping_add(result.unwrap());
    }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Total: {}", total);
    println!("Workers: {}, Iterations: {}", N_WORKERS, ITERATIONS);
    println!("Time: {:.4} s", elapsed);
}
