// Backpressure Benchmark — Rust / Tokio
//
// Producer sends 100,000 items through a bounded mpsc channel (capacity 64).
// 8 Tokio tasks consume items (CPU work: 500 LCG iterations each).
// Producer blocks (awaits) when the channel is full — real backpressure.
//
// Tests: bounded channel throughput, async producer blocking,
// Tokio task scheduling under sustained load.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::mpsc;

const TOTAL_ITEMS: u64 = 100_000;
const CHAN_CAP: usize = 64;
const WORK_PER_ITEM: usize = 5_000;

fn process_item(val: u64) -> u64 {
    let mut x = val;
    for _ in 0..WORK_PER_ITEM {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    }
    x
}

#[tokio::main]
async fn main() {
    let (tx, rx) = mpsc::channel::<u64>(CHAN_CAP);
    let total = Arc::new(AtomicU64::new(0));

    let t0 = Instant::now();

    // Start consumers (share the receiver via Arc<Mutex>)
    let n_consumers = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8);
    let mut consumer_handles = Vec::new();
    let rx = Arc::new(tokio::sync::Mutex::new(rx));
    for _ in 0..n_consumers {
        let rx = Arc::clone(&rx);
        let total = Arc::clone(&total);
        consumer_handles.push(tokio::spawn(async move {
            loop {
                let val = {
                    let mut guard = rx.lock().await;
                    guard.recv().await
                };
                match val {
                    Some(v) => {
                        let result = process_item(v);
                        total.fetch_add(result, Ordering::Relaxed);
                    }
                    None => break,
                }
            }
        }));
    }

    // Producer: send items (blocks when channel full)
    for i in 0..TOTAL_ITEMS {
        tx.send(i).await.unwrap();
    }
    drop(tx); // Close channel

    // Wait for consumers
    for h in consumer_handles {
        h.await.unwrap();
    }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Checksum: {}", total.load(Ordering::Relaxed) % 1_000_000_000);
    println!("Items: {}", TOTAL_ITEMS);
    println!("Workers: {}", n_consumers);
    println!("Time: {:.4} s", elapsed);
}
