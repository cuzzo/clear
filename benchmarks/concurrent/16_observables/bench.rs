//! Concurrent observable stream-sum benchmark — Rust.
//! Mirrors bench.clear: producer stream -> consumer sum -> join.

use std::sync::mpsc;
use std::thread;
use std::time::Instant;

const N_WRITES: usize = 2_000_000;

fn expected_sum() -> i64 {
    let n = N_WRITES as i64;
    (n * (n - 1)) / 2
}

fn main() {
    let (tx, rx) = mpsc::sync_channel::<i64>(64);

    let t0 = Instant::now();
    let consumer = thread::spawn(move || -> i64 {
        let mut sum = 0i64;
        for value in rx {
            sum += value;
        }
        sum
    });
    let producer = {
        thread::spawn(move || {
            for i in 0..N_WRITES {
                tx.send(i as i64).unwrap();
            }
        })
    };
    producer.join().unwrap();
    let final_value = consumer.join().unwrap();
    let elapsed = t0.elapsed();

    let expected = expected_sum();
    let checksum = final_value + (N_WRITES as i64) * 131;
    let expected_checksum = expected + (N_WRITES as i64) * 131;
    if final_value != expected {
        panic!("final {} != expected {}", final_value, expected);
    }
    if checksum != expected_checksum {
        panic!("checksum {} != expected {}", checksum, expected_checksum);
    }
    println!(
        "Rust observable stream sum: {} (sum 0..N-1) in {:.6} ms",
        final_value,
        elapsed.as_secs_f64() * 1000.0
    );
    println!(
        "BENCH_INFO: Rust stream_sum final={} checksum={} n={}",
        final_value, checksum, N_WRITES
    );
    println!("BENCH_RESULT: {:.6} ms", elapsed.as_secs_f64() * 1000.0);
}
