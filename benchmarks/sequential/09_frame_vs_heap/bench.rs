// Benchmark: Frame vs Heap Escape — Rust Baseline
//
// Variant A (bump):  bumpalo::format! into a Bump arena, reset each iteration.
//                    Analogous to CLEAR's frame allocation: bump pointer advance
//                    on alloc, O(1) reset (rewind) at end of each iteration.
//                    No individual frees — the whole arena resets at once.
//
// Variant B (heap):  format! -> String, dropped at end of each iteration.
//                    Analogous to CLEAR's heap-promoted (escape) path:
//                    one allocator call per string, one free per drop.
//
// Build: cargo build --release
// Run:   ./bench_rust

use bumpalo::Bump;
use std::time::Instant;

const N: usize = 1_000_000;

fn read_memory() -> (i64, i64) {
    use std::io::{BufRead, BufReader};
    let f = match std::fs::File::open("/proc/self/status") {
        Ok(f) => f,
        Err(_) => return (0, 0),
    };
    let mut hwm_kb = 0i64;
    let mut rss_kb = 0i64;
    for line in BufReader::new(f).lines().flatten() {
        if line.starts_with("VmHWM:") {
            hwm_kb = line.split_whitespace().nth(1)
                .and_then(|s| s.parse().ok()).unwrap_or(0);
        } else if line.starts_with("VmRSS:") {
            rss_kb = line.split_whitespace().nth(1)
                .and_then(|s| s.parse().ok()).unwrap_or(0);
        }
    }
    (hwm_kb, rss_kb)
}

fn bench_bump(n: usize) -> i64 {
    let mut bump = Bump::new();
    let mut total = 0i64;
    for i in 0..n {
        let len = {
            let s = bumpalo::format!(in &bump, "item-{}-value", i);
            s.len() as i64
        }; // s dropped here, releasing the borrow on bump
        total += len;
        bump.reset();
    }
    total
}

fn bench_heap(n: usize) -> i64 {
    let mut total = 0i64;
    for i in 0..n {
        let s = format!("item-{}-value", i);
        total += s.len() as i64;
    }
    total
}

fn main() {
    // Warm up
    bench_bump(1000);
    bench_heap(1000);

    let t0 = Instant::now();
    let bump_total = bench_bump(N);
    let bump_ms = t0.elapsed().as_millis() as i64;
    let (_, bump_rss) = read_memory();

    let t1 = Instant::now();
    let heap_total = bench_heap(N);
    let heap_ms = t1.elapsed().as_millis() as i64;
    let (hwm_kb, _) = read_memory();

    assert_eq!(bump_total, heap_total, "both variants must produce same result");

    println!("BENCH_RESULT: {} ms", bump_ms);
    println!("Frame vs Heap Escape ({} iterations) — Rust baseline", N);
    println!("  Bump (bumpalo):  {} ms  RSS {} KB", bump_ms, bump_rss);
    println!("  Heap (String):   {} ms", heap_ms);
    println!("  Heap overhead:   {} ms  ({}% slower)",
        heap_ms - bump_ms,
        if bump_ms > 0 { (heap_ms * 100 / bump_ms) - 100 } else { 0 });
    println!("  Peak RSS (VmHWM): {} KB", hwm_kb);
}
