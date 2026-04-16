// Backpressure Benchmark — Rust / crossbeam
//
// Producer sends 100,000 items through a bounded channel (capacity 64).
// N_CPU consumer threads process each item (CPU work: 5,000 LCG iterations).
// Producer blocks when the channel is full — real backpressure.
//
// crossbeam::channel::bounded is the idiomatic Rust bounded work queue.
// Native threads are correct here: work is CPU-bound, not I/O-bound.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use crossbeam_channel::bounded;

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

fn main() {
    let n_consumers = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(8);

    let (tx, rx) = bounded::<u64>(CHAN_CAP);
    let total = Arc::new(AtomicU64::new(0));

    let t0 = Instant::now();

    // Start consumers
    let handles: Vec<_> = (0..n_consumers).map(|_| {
        let rx = rx.clone();
        let total = Arc::clone(&total);
        std::thread::spawn(move || {
            for val in rx {
                total.fetch_add(process_item(val), Ordering::Relaxed);
            }
        })
    }).collect();

    // Producer: send items (blocks when channel full)
    for i in 0..TOTAL_ITEMS {
        tx.send(i).unwrap();
    }
    drop(tx); // Close channel — consumers drain and exit

    for h in handles { h.join().unwrap(); }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Checksum: {}", total.load(Ordering::Relaxed) % 1_000_000_000);
    println!("Items: {}", TOTAL_ITEMS);
    println!("Workers: {}", n_consumers);
    println!("Time: {:.4} s", elapsed);
}
