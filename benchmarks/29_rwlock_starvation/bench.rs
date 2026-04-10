// RwLock Writer Starvation Benchmark -- Rust
//
// Tests writer fairness of Rust's std::sync::RwLock under heavy read contention.
// Rust uses a custom futex-based RwLock (not pthread_rwlock_t). Writer-preferring
// on all platforms: new readers block once a writer is waiting. No starvation.
//
// Setup:
//   - N reader threads each hold read lock for ~busy_work(100), loop 2M times
//   - 1 writer thread acquires write lock, loop 1K times
//   - Measure: writer completion time, avg/max writer wait per acquire
//
// Build: rustc -C opt-level=3 bench.rs -o bench_rust

use std::sync::{Arc, RwLock};
use std::sync::atomic::{AtomicI64, Ordering};
use std::thread;
use std::time::Instant;

const READ_ITERS: i64 = 2_000_000;
const WRITE_ITERS: i64 = 1_000;
const WORK_PER_OP: i64 = 100;

fn busy_work(n: i64) -> i64 {
    let mut acc: i64 = 0;
    for i in 0..n {
        acc = acc.wrapping_add(i);
    }
    acc
}

fn num_cpus() -> usize {
    thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}

fn main() {
    let n_cpu = num_cpus();
    let n_readers = if n_cpu > 1 { n_cpu - 1 } else { 1 };

    let data = Arc::new(RwLock::new(0i64));
    let sink = Arc::new(AtomicI64::new(0));

    let t0 = Instant::now();

    // Spawn readers
    let mut handles = Vec::new();
    for _ in 0..n_readers {
        let d = Arc::clone(&data);
        let s = Arc::clone(&sink);
        handles.push(thread::spawn(move || {
            for _ in 0..READ_ITERS {
                let guard = d.read().unwrap();
                let _v = *guard;
                s.fetch_add(busy_work(WORK_PER_OP), Ordering::Relaxed);
                drop(guard);
            }
        }));
    }

    // Spawn writer
    let d = Arc::clone(&data);
    let s = Arc::clone(&sink);
    let writer = thread::spawn(move || {
        let mut max_wait_ns: u64 = 0;
        let mut total_wait_ns: u64 = 0;
        for _ in 0..WRITE_ITERS {
            let wt0 = Instant::now();
            let mut guard = d.write().unwrap();
            let waited = wt0.elapsed().as_nanos() as u64;
            if waited > max_wait_ns {
                max_wait_ns = waited;
            }
            total_wait_ns += waited;
            *guard += 1;
            s.fetch_add(busy_work(WORK_PER_OP), Ordering::Relaxed);
            drop(guard);
        }
        let writer_done = t0.elapsed().as_millis();
        (writer_done, total_wait_ns / WRITE_ITERS as u64, max_wait_ns)
    });

    for h in handles {
        h.join().unwrap();
    }
    let (writer_done_ms, avg_wait_ns, max_wait_ns) = writer.join().unwrap();
    let elapsed = t0.elapsed().as_millis();

    let final_val = *data.read().unwrap();

    println!("Readers:        {}", n_readers);
    println!("Read iters:     {} per reader", READ_ITERS);
    println!("Write iters:    {}", WRITE_ITERS);
    println!("Total time:     {} ms", elapsed);
    println!("Writer done:    {} ms", writer_done_ms);
    println!("Avg write wait: {} us", avg_wait_ns / 1000);
    println!("Max write wait: {} us", max_wait_ns / 1000);
    println!("Final value:    {}", final_val);
    println!("Sink:           {}", sink.load(Ordering::Relaxed));
}
