// Dynamic Spawn Benchmark — Rust / Tokio
//
// Spawns 100K Tokio tasks, each does trivial work (return its index).
// Measures pure spawn + collect overhead with minimal CPU work.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::time::Instant;
use tokio::task::JoinSet;

const N_TASKS: usize = 10_000;

#[tokio::main]
async fn main() {
    let t0 = Instant::now();

    let mut set = JoinSet::new();
    for i in 0..N_TASKS {
        set.spawn(async move { (i as i64) * 3 });
    }

    let mut total: i64 = 0;
    while let Some(result) = set.join_next().await {
        total += result.unwrap();
    }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Total: {}", total);
    println!("Tasks: {}", N_TASKS);
    println!("Time: {:.4} s", elapsed);
}
