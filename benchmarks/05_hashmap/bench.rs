// HashMap Benchmark — Rust Baseline
//
// std::collections::HashMap<i64, f64> with 1M inserts + 1M lookups.
// Uses default SipHash-1-3. with_capacity(N) pre-allocates to avoid rehash.

use std::collections::HashMap;
use std::time::Instant;

const N: usize = 1_000_000;

fn main() {
    let mut map: HashMap<i64, f64> = HashMap::with_capacity(N);

    let t0 = Instant::now();
    for i in 0..N as i64 {
        map.insert(i, i as f64);
    }
    let ins_ms = t0.elapsed().as_secs_f64() * 1000.0;

    let t0 = Instant::now();
    let mut sum: f64 = 0.0;
    for i in 0..N as i64 {
        sum += map.get(&i).copied().unwrap_or(0.0);
    }
    let lkp_ms = t0.elapsed().as_secs_f64() * 1000.0;

    assert!(sum > 0.0);

    println!("BENCH_RESULT: {:.0} ms", ins_ms + lkp_ms);
    println!("Insert: {:.1} ms | Lookup: {:.1} ms | Total: {:.1} ms",
             ins_ms, lkp_ms, ins_ms + lkp_ms);
}
