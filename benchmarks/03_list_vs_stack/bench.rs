// List vs. Stack Benchmark — Rust Baseline
//
// WHY RUST IS FAST:
//   Vec::with_capacity(N) does ONE heap allocation upfront. After that,
//   push() is a bounds-checked write with zero allocator calls.
//   The sum loop is a tight iterator that LLVM can auto-vectorize.
//
//   Rust does pay one malloc per outer iteration (unlike C's zero),
//   but the allocator is the system default (very fast for fixed sizes).
//
// This sits between C (pure stack, zero alloc) and CLEAR (GPA + try-per-push).

use std::time::Instant;

const N: usize = 1000;

fn main() {
    let start = Instant::now();

    let mut total: f64 = 0.0;
    for _ in 0..N {
        let mut v: Vec<f64> = Vec::with_capacity(N);
        for i in 0..N {
            v.push(i as f64);
        }
        total += v.iter().sum::<f64>();
    }

    assert!(total > 0.0);

    let duration = start.elapsed();
    println!("total = {:.0}", total);
    println!("Time: {:.4} seconds", duration.as_secs_f64());
}
