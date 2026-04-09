// False Sharing Benchmark -- Rust
//
// N threads each increment their own counter M times.
// Three configurations:
//   1. PACKED:     adjacent i64s in a Vec (false sharing)
//   2. PADDED:     each counter in a 64-byte aligned struct (no false sharing)
//   3. ARC:        each counter is Arc<Mutex<i64>> (separate heap alloc, no false sharing)
//
// Rust's Arc eliminates false sharing by construction: each Arc is an
// independent heap allocation with its own control block.
//
// Build: rustc -C opt-level=3 bench.rs -o bench_rust

use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Instant;

const TOTAL_WORK: i64 = 40_000_000;

#[repr(C, align(64))]
struct PaddedCounter {
    value: i64,
}

fn num_cpus() -> usize {
    thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}

fn run_packed(n_threads: usize, increments: i64) -> f64 {
    let mut counters = vec![0i64; n_threads];
    let ptr = counters.as_mut_ptr() as usize;

    let t0 = Instant::now();
    let handles: Vec<_> = (0..n_threads)
        .map(|id| {
            let p = ptr;
            thread::spawn(move || {
                let slot = unsafe { &mut *(p as *mut i64).add(id) };
                for _ in 0..increments {
                    *slot += 1;
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
    let elapsed = t0.elapsed().as_secs_f64() * 1000.0;

    let total: i64 = counters.iter().sum();
    assert_eq!(total, n_threads as i64 * increments, "packed total mismatch");
    elapsed
}

fn run_padded(n_threads: usize, increments: i64) -> f64 {
    let mut counters: Vec<PaddedCounter> = (0..n_threads)
        .map(|_| PaddedCounter { value: 0 })
        .collect();
    let ptr = counters.as_mut_ptr() as usize;

    let t0 = Instant::now();
    let handles: Vec<_> = (0..n_threads)
        .map(|id| {
            let p = ptr;
            thread::spawn(move || {
                let slot = unsafe { &mut (*(p as *mut PaddedCounter).add(id)).value };
                for _ in 0..increments {
                    *slot += 1;
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
    let elapsed = t0.elapsed().as_secs_f64() * 1000.0;

    let total: i64 = counters.iter().map(|c| c.value).sum();
    assert_eq!(total, n_threads as i64 * increments, "padded total mismatch");
    elapsed
}

fn run_arc(n_threads: usize, increments: i64) -> f64 {
    let counters: Vec<Arc<Mutex<i64>>> = (0..n_threads)
        .map(|_| Arc::new(Mutex::new(0i64)))
        .collect();

    let t0 = Instant::now();
    let handles: Vec<_> = (0..n_threads)
        .map(|id| {
            let counter = Arc::clone(&counters[id]);
            thread::spawn(move || {
                for _ in 0..increments {
                    *counter.lock().unwrap() += 1;
                }
            })
        })
        .collect();

    for h in handles {
        h.join().unwrap();
    }
    let elapsed = t0.elapsed().as_secs_f64() * 1000.0;

    let total: i64 = counters.iter().map(|c| *c.lock().unwrap()).sum();
    assert_eq!(total, n_threads as i64 * increments, "arc total mismatch");
    elapsed
}

fn main() {
    let n_threads = num_cpus();
    let increments = TOTAL_WORK / n_threads as i64;

    // Warm up
    run_packed(n_threads, increments);
    run_padded(n_threads, increments);
    run_arc(n_threads, increments);

    let packed_ms = run_packed(n_threads, increments);
    let padded_ms = run_padded(n_threads, increments);
    let arc_ms = run_arc(n_threads, increments);

    println!("Threads:     {}", n_threads);
    println!("Increments:  {} per thread", increments);
    println!("Packed:      {:.1} ms  (false sharing)", packed_ms);
    println!("Padded:      {:.1} ms  (no false sharing)", padded_ms);
    println!("Arc<Mutex>:  {:.1} ms  (separate heap allocs)", arc_ms);
    println!("Slowdown:    {:.1}x  (packed / padded)", packed_ms / padded_ms);
}
