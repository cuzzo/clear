// Pub-Sub Benchmark -- Rust (std::thread)
//
// 64 subscribers each independently generate and process 100K messages
// with CPU-bound work (2000 LCG iterations per message).
// Total work: 100K * 64 * 2000 = 12.8 billion LCG iterations.
//
// Uses std::thread (not Tokio) since this is pure CPU-bound work with
// no I/O or async. Matches the CLEAR/Go pattern.
//
// Build: rustc -C opt-level=3 bench.rs -o bench_rust
// Run:   ./bench_rust

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Instant;

const N_MESSAGES: u64 = 100_000;
const N_SUBSCRIBERS: usize = 64;
const WORK_PER_MSG: usize = 2_000;

#[inline(never)]
fn process_message(seed: u64) -> u64 {
    let mut x = seed;
    for _ in 0..WORK_PER_MSG {
        x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    }
    x
}

fn subscriber_work(n: u64) -> u64 {
    let mut total: u64 = 0;
    for i in 0..n {
        total = total.wrapping_add(process_message(std::hint::black_box(i)));
    }
    total
}

fn main() {
    let total = Arc::new(AtomicU64::new(0));
    let t0 = Instant::now();

    let handles: Vec<_> = (0..N_SUBSCRIBERS)
        .map(|_| {
            let total = Arc::clone(&total);
            std::thread::spawn(move || {
                let result = subscriber_work(N_MESSAGES);
                total.fetch_add(result, Ordering::Relaxed);
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    let elapsed = t0.elapsed().as_secs_f64();
    let checksum = total.load(Ordering::Relaxed) % 1_000_000_000;
    println!("Checksum: {}", checksum);
    println!("Messages: {}", N_MESSAGES);
    println!("Subscribers: {}", N_SUBSCRIBERS);
    println!("Time: {:.0} ms", elapsed * 1000.0);
}
