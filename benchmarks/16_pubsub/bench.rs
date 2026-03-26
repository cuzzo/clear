// Pub-Sub Benchmark — Rust / Tokio
//
// 1 publisher sends 100K messages to 64 subscribers via per-subscriber
// mpsc channels. Each subscriber processes every message with CPU-bound
// work (200 LCG iterations).
// Total work: 100K * 64 * 200 = 1.28 billion LCG iterations.
//
// Uses per-subscriber channels (not broadcast) to guarantee delivery —
// same pattern as Go's buffered channels.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;
use tokio::sync::mpsc;

const N_MESSAGES: u64 = 100_000;
const N_SUBSCRIBERS: usize = 64;
const WORK_PER_MSG: usize = 200;
const CHAN_BUF: usize = 256;

fn process_message(seed: u64) -> u64 {
    let mut x = seed;
    for _ in 0..WORK_PER_MSG {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    }
    x
}

#[tokio::main]
async fn main() {
    let total = Arc::new(AtomicU64::new(0));

    let t0 = Instant::now();

    // Create per-subscriber channels and spawn subscriber tasks
    let mut senders = Vec::with_capacity(N_SUBSCRIBERS);
    let mut handles = Vec::with_capacity(N_SUBSCRIBERS);

    for _ in 0..N_SUBSCRIBERS {
        let (tx, mut rx) = mpsc::channel::<u64>(CHAN_BUF);
        senders.push(tx);
        let total = Arc::clone(&total);
        handles.push(tokio::spawn(async move {
            let mut local_sum: u64 = 0;
            while let Some(msg) = rx.recv().await {
                local_sum = local_sum.wrapping_add(process_message(msg));
            }
            total.fetch_add(local_sum, Ordering::Relaxed);
        }));
    }

    // Publisher: broadcast each message to all subscribers
    for msg in 0..N_MESSAGES {
        for tx in &senders {
            tx.send(msg).await.unwrap();
        }
    }

    // Drop senders to signal completion
    drop(senders);

    // Wait for all subscribers
    for h in handles {
        h.await.unwrap();
    }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Total: {}", total.load(Ordering::Relaxed));
    println!(
        "Messages: {}, Subscribers: {}, Work/msg: {}",
        N_MESSAGES, N_SUBSCRIBERS, WORK_PER_MSG
    );
    println!("Time: {:.4} s", elapsed);
}
