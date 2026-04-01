// Stream Merge Benchmark — Rust (threads + crossbeam channel)
//
// 8 producer threads each generate 100K values (LCG sequence)
// and send them through a bounded crossbeam channel.
// 1 consumer thread reads from all producers, sums all values.
// Total: 800K values merged from 8 streams.
//
// Uses crossbeam-channel for high-throughput bounded channels —
// the standard choice for producer/consumer patterns in Rust.
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use crossbeam_channel::bounded;
use std::thread;
use std::time::Instant;

const N_PRODUCERS: usize = 8;
const ITEMS_PER_PROD: usize = 100_000;

fn main() {
    let (tx, rx) = bounded::<i64>(64);

    let t0 = Instant::now();

    // Start producers
    for i in 0..N_PRODUCERS {
        let tx = tx.clone();
        thread::spawn(move || {
            let mut x: i64 = (i + 1) as i64;
            for _ in 0..ITEMS_PER_PROD {
                x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                tx.send(x).unwrap();
            }
        });
    }
    drop(tx);

    // Consumer: read all values
    let mut total: i64 = 0;
    while let Ok(val) = rx.recv() {
        total = total.wrapping_add(val);
    }

    let elapsed = t0.elapsed().as_secs_f64();
    println!("Checksum: {}", total.wrapping_rem(1_000_000_000));
    println!("Producers: {}", N_PRODUCERS);
    println!("Items per producer: {}", ITEMS_PER_PROD);
    println!("Time: {:.4} s", elapsed);
}
