// Stream Merge Benchmark — Rust / Tokio
//
// 8 producer tasks each generate 10K values (LCG sequence)
// and send them through a bounded mpsc channel.
// 1 consumer task reads from all producers, sums all values.
// Total: 80K values merged from 8 streams.
//
// Tests: mpsc channel throughput, task yield/resume, fan-in merge.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::time::Instant;
use tokio::sync::mpsc;

const N_PRODUCERS: usize = 8;
const ITEMS_PER_PROD: usize = 100_000;

#[tokio::main]
async fn main() {
    let (tx, mut rx) = mpsc::channel::<i64>(64);

    let t0 = Instant::now();

    // Start producers
    for i in 0..N_PRODUCERS {
        let tx = tx.clone();
        tokio::spawn(async move {
            let mut x: i64 = (i + 1) as i64;
            for _ in 0..ITEMS_PER_PROD {
                x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                tx.send(x).await.unwrap();
            }
        });
    }
    drop(tx); // Close sender side

    // Consumer: read all values
    let mut total: i64 = 0;
    while let Some(val) = rx.recv().await {
        total = total.wrapping_add(val);
    }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Checksum: {}", total.wrapping_rem(1_000_000_000));
    println!("Producers: {}", N_PRODUCERS);
    println!("Items per producer: {}", ITEMS_PER_PROD);
    println!("Time: {:.4} s", elapsed);
}
