// Atomic Counter Benchmark — Rust
//
// 8 OS threads each perform 1M AtomicI64::fetch_add ops on a shared
// counter (wrapped in Arc<AtomicI64>). Total expected: 8M.
//
// Rust's fetch_add(_, Relaxed) is the apples-to-apples match for
// CLEAR's atomic increment (.monotonic ordering). Go's atomic.AddInt64
// is stronger (seq-cst on x86) but presented in the same bench for the
// language-level comparison.
//
// Build: cargo build --release  (or: rustc -O bench.rs -o bench_rust)
// Run:   ./target/release/bench_rust  (or: ./bench_rust)

use std::sync::atomic::{AtomicI64, Ordering};
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const N_WORKERS: usize = 8;
const ITERATIONS: usize = 1_000_000;

fn main() {
    let counter = Arc::new(AtomicI64::new(0));
    let t0 = Instant::now();

    let handles: Vec<_> = (0..N_WORKERS)
        .map(|_| {
            let c = Arc::clone(&counter);
            thread::spawn(move || {
                for _ in 0..ITERATIONS {
                    c.fetch_add(1, Ordering::Relaxed);
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }

    let elapsed = t0.elapsed().as_millis();
    let total = counter.load(Ordering::SeqCst);

    println!(
        "Counter: {} (expected {})",
        total,
        (N_WORKERS as i64) * (ITERATIONS as i64)
    );
    println!("BENCH_RESULT: {} ms", elapsed);
    println!("Time: {} ms", elapsed);
}
