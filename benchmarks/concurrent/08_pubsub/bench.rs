// Pub-Sub Benchmark — Rust (crossbeam)
//
// 1 publisher thread fans out 100K messages to 64 subscribers.
// Each subscriber has its own bounded crossbeam channel (cap 64).
// Publisher sends to all 64 channels sequentially per message.
// Each subscriber processes every message (2000 LCG iterations).
// Total work: 100K * 64 * 2000 = 12.8 billion LCG iterations.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use crossbeam_channel::bounded;
use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const N_MESSAGES: i64 = 10_000;
const N_SUBSCRIBERS: usize = 64;
const WORK_PER_MSG: usize = 2_000;
const CHAN_CAP: usize = 64;

fn process_message(seed: i64) -> i64 {
    let mut x = seed;
    for _ in 0..WORK_PER_MSG {
        x = x.wrapping_mul(6364136223846793005_i64)
             .wrapping_add(1442695040888963407_i64);
    }
    x
}

fn main() {
    let mut txs = Vec::with_capacity(N_SUBSCRIBERS);
    let mut rxs = Vec::with_capacity(N_SUBSCRIBERS);
    for _ in 0..N_SUBSCRIBERS {
        let (tx, rx) = bounded::<i64>(CHAN_CAP);
        txs.push(tx);
        rxs.push(rx);
    }

    let total = Arc::new(AtomicI64::new(0));
    let t0 = Instant::now();

    // Start subscribers
    let handles: Vec<_> = rxs.into_iter().map(|rx| {
        let total = Arc::clone(&total);
        thread::spawn(move || {
            let mut sum: i64 = 0;
            for seed in rx {
                sum = sum.wrapping_add(process_message(seed));
            }
            total.fetch_add(sum, Ordering::Relaxed);
        })
    }).collect();

    // Publisher: fan-out each message to all subscribers
    for i in 0..N_MESSAGES {
        for tx in &txs {
            tx.send(i).unwrap();
        }
    }
    drop(txs); // close all channels

    for h in handles { h.join().unwrap(); }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Checksum: {}", total.load(Ordering::Relaxed) % 1_000_000_000);
    println!("Messages: {}", N_MESSAGES);
    println!("Subscribers: {}", N_SUBSCRIBERS);
    println!("BENCH_RESULT: {} ms", (elapsed * 1000.0) as u64);
    println!("Time: {:.0} ms", elapsed * 1000.0);
}
