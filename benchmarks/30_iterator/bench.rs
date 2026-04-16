// Iterator Benchmark — Rust Baseline
//
// Compares iterator-based sum vs indexed loop over a Vec.
// 1000 outer iterations × 10000 Int64 elements.
// Total: 10M element reads.

use std::time::Instant;

const N: usize = 10000;
const ITERS: usize = 1000;

struct SliceIter<'a> {
    data: &'a [i64],
    pos: usize,
}

impl<'a> SliceIter<'a> {
    fn new(data: &'a [i64]) -> Self { Self { data, pos: 0 } }
    #[inline(never)]
    fn has_next(&self) -> bool { self.pos < self.data.len() }
    #[inline(never)]
    fn current(&self) -> i64 { self.data[self.pos] }
    #[inline(never)]
    fn advance(&mut self) { self.pos += 1; }
}

fn main() {
    let data: Vec<i64> = (0..N as i64).map(|i| i.wrapping_mul(7).wrapping_add(13)).collect();

    // Benchmark 1: borrowed iterator
    let t0 = Instant::now();
    let mut result1: i64 = 0;
    for _ in 0..ITERS {
        let mut it = SliceIter::new(&data);
        while it.has_next() {
            result1 = result1.wrapping_add(it.current());
            it.advance();
        }
    }
    let iter_ms = t0.elapsed().as_secs_f64() * 1000.0;

    // Benchmark 2: raw indexed loop
    let t2 = Instant::now();
    let mut result2: i64 = 0;
    for _ in 0..ITERS {
        for i in 0..N {
            result2 = result2.wrapping_add(data[i]);
        }
    }
    let raw_ms = t2.elapsed().as_secs_f64() * 1000.0;

    assert_eq!(result1, result2);
    // BENCH_RESULT = iterator time (primary metric)
    println!("BENCH_RESULT: {:.0} ms", iter_ms);
    println!("Iterator benchmark ({} elements x {} iters)", N, ITERS);
    println!("  Iterator: {:.0} ms", iter_ms);
    println!("  Raw loop: {:.0} ms", raw_ms);
}
