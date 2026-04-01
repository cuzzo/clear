// Dynamic Spawn Benchmark — Rust / Tokio
//
// Spawns 10K Tokio tasks, each does CPU-bound work (10K LCG iterations).
// Measures task spawn overhead + parallel execution.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::time::Instant;
use tokio::task::JoinSet;

const N_TASKS: usize = 10_000;
const ITERATIONS: usize = 10_000;

fn do_work(seed: i64) -> i64 {
    let mut x = seed;
    for _ in 0..ITERATIONS {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    }
    x
}

#[tokio::main]
async fn main() {
    let t0 = Instant::now();

    let mut set = JoinSet::new();
    for i in 0..N_TASKS {
        set.spawn(async move { do_work(i as i64) });
    }

    let mut total: i64 = 0;
    while let Some(result) = set.join_next().await {
        total = total.wrapping_add(result.unwrap());
    }

    let elapsed = t0.elapsed().as_secs_f64();
    let checksum = ((total.wrapping_rem(1_000_000_000)) + 1_000_000_000) % 1_000_000_000;
    println!("Checksum: {}", checksum);
    println!("Tasks: {}", N_TASKS);
    println!("Iterations: {}", ITERATIONS);
    println!("Time: {:.4} s", elapsed);
}
