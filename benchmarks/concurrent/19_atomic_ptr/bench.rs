// AtomicPtr (M3) benchmark — Rust (arc-swap).
//
// Same producer-consumer config swap workload as the CLEAR + Go bench:
// 1 writer publishes a Counter via ArcSwap<Counter>; N readers each
// load the snapshot reads_per times and verify the structural
// invariant `b == a * 2`. Compares the M3 @indirect:atomic surface
// against arc-swap's `ArcSwap::rcu` (the canonical Rust idiom for
// lock-free atomic-pointer publish).
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use arc_swap::ArcSwap;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const N_READERS: usize = 16;
const READS_PER: usize = 50_000;
const WRITES: usize = 5_000;

#[derive(Clone)]
struct Counter {
    a: i64,
    b: i64,
}

fn main() {
    let p = Arc::new(ArcSwap::from_pointee(Counter { a: 0, b: 0 }));

    let t0 = Instant::now();

    let mut handles = Vec::new();

    // Readers
    for _ in 0..N_READERS {
        let p = p.clone();
        handles.push(thread::spawn(move || {
            let mut violations: i64 = 0;
            for _ in 0..READS_PER {
                let snap = p.load();
                if snap.b != snap.a * 2 {
                    violations += 1;
                }
            }
            violations
        }));
    }

    // Writer: rcu-style. arc-swap's rcu does load + closure(snapshot)
    // + CAS-publish + retry until success (matches AtomicPtr.update's
    // unbounded-retry semantics).
    let writer = {
        let p = p.clone();
        thread::spawn(move || {
            for _ in 0..WRITES {
                p.rcu(|old| {
                    let next_a = old.a + 1;
                    Counter { a: next_a, b: next_a * 2 }
                });
            }
        })
    };

    let mut violations: i64 = 0;
    for h in handles {
        violations += h.join().unwrap();
    }
    writer.join().unwrap();

    let elapsed = t0.elapsed().as_secs_f64();

    let final_snap = p.load();
    println!("Counter: a={} b={} (violations: {})", final_snap.a, final_snap.b, violations);
    println!("BENCH_RESULT: {} ms", (elapsed * 1000.0) as i64);
    println!("Time: {:.4} s", elapsed);
}
