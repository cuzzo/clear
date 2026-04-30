//! Concurrent-readers benchmark — Rust.
//! Mirrors bench_clear.zig: 1 writer + K readers, observe by view().

use std::sync::atomic::{AtomicI64, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

const N_WRITES: usize = 5_000_000;
const READER_COUNTS: &[usize] = &[1, 4, 8];

// ---------------- AtomicI64 (Rust's "@observable" equivalent) ----------------

fn run_atomic(n_readers: usize) {
    let counter = Arc::new(AtomicI64::new(0));
    let stop = Arc::new(AtomicU8::new(0));

    let mut reader_handles = Vec::with_capacity(n_readers);
    for _ in 0..n_readers {
        let counter = Arc::clone(&counter);
        let stop = Arc::clone(&stop);
        reader_handles.push(thread::spawn(move || -> (usize, i64) {
            let mut n: usize = 0;
            let mut sink: i64 = 0;
            while stop.load(Ordering::Acquire) == 0 {
                sink ^= counter.load(Ordering::Acquire); // data-dependent
                n += 1;
            }
            (n, sink)
        }));
    }

    let t0 = Instant::now();
    let writer = {
        let counter = Arc::clone(&counter);
        let stop = Arc::clone(&stop);
        thread::spawn(move || {
            for _ in 0..N_WRITES {
                counter.fetch_add(1, Ordering::Relaxed);
            }
            stop.store(1, Ordering::Release);
        })
    };
    writer.join().unwrap();
    let mut total_reads: usize = 0;
    let mut sink_sum: i64 = 0;
    for h in reader_handles {
        let (n, s) = h.join().unwrap();
        total_reads += n;
        sink_sum ^= s;
    }
    let elapsed = t0.elapsed();

    let ns_per_inc = elapsed.as_nanos() as usize / N_WRITES;
    let reads_per_sec = if elapsed.as_nanos() == 0 { 0 } else {
        (total_reads as u128 * 1_000_000_000 / elapsed.as_nanos()) as usize
    };
    println!(
        "[Rust AtomicI64]     writer={:>3} ns/inc  readers={}  total_reads={}  reads/sec={}",
        ns_per_inc, n_readers, total_reads, reads_per_sec
    );
    if counter.load(Ordering::Acquire) != N_WRITES as i64 {
        println!("  !! counter view {} != expected {}", counter.load(Ordering::Acquire), N_WRITES);
    }
    if sink_sum == 0xdeadbeef { println!("  (sink check)"); }
}

// ---------------- Mutex<i64> (Rust's "@locked Int64" equivalent) ----------------

fn run_locked(n_readers: usize) {
    let counter = Arc::new(Mutex::new(0i64));
    let stop = Arc::new(AtomicU8::new(0));

    let mut reader_handles = Vec::with_capacity(n_readers);
    for _ in 0..n_readers {
        let counter = Arc::clone(&counter);
        let stop = Arc::clone(&stop);
        reader_handles.push(thread::spawn(move || -> (usize, i64) {
            let mut n: usize = 0;
            let mut sink: i64 = 0;
            while stop.load(Ordering::Acquire) == 0 {
                sink ^= *counter.lock().unwrap();
                n += 1;
            }
            (n, sink)
        }));
    }

    let t0 = Instant::now();
    let writer = {
        let counter = Arc::clone(&counter);
        let stop = Arc::clone(&stop);
        thread::spawn(move || {
            for _ in 0..N_WRITES {
                let mut g = counter.lock().unwrap();
                *g += 1;
            }
            stop.store(1, Ordering::Release);
        })
    };
    writer.join().unwrap();
    let mut total_reads: usize = 0;
    let mut sink_sum: i64 = 0;
    for h in reader_handles {
        let (n, s) = h.join().unwrap();
        total_reads += n;
        sink_sum ^= s;
    }
    let elapsed = t0.elapsed();

    let ns_per_inc = elapsed.as_nanos() as usize / N_WRITES;
    let reads_per_sec = if elapsed.as_nanos() == 0 { 0 } else {
        (total_reads as u128 * 1_000_000_000 / elapsed.as_nanos()) as usize
    };
    println!(
        "[Rust Mutex<i64>]    writer={:>3} ns/inc  readers={}  total_reads={}  reads/sec={}",
        ns_per_inc, n_readers, total_reads, reads_per_sec
    );
    let final_v = *counter.lock().unwrap();
    if final_v != N_WRITES as i64 {
        println!("  !! counter view {} != expected {}", final_v, N_WRITES);
    }
    if sink_sum == 0xdeadbeef { println!("  (sink check)"); }
}

fn main() {
    println!("Concurrent observable benchmark — Rust — N={} writes, readers={:?}", N_WRITES, READER_COUNTS);
    for &k in READER_COUNTS {
        run_atomic(k);
    }
    println!();
    for &k in READER_COUNTS {
        run_locked(k);
    }
}
