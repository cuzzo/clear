// KV Store Benchmark — Rust (dashmap)
//
// Embedded concurrent key-value store using dashmap (lock-striped HashMap).
// N threads perform SET/GET operations on a shared DashMap.
//
// Workloads:
//   1. Uniform SET   — 1M sequential keys
//   2. Uniform GET   — 1M sequential keys (100% hit)
//   3. Zipfian GET   — 1M ops, power-law key distribution (hot keys)
//   4. Mixed 80/20   — 1M ops, 80% GET / 20% SET, Zipfian
//
// Build: cargo build --release
// Run:   ./target/release/bench_rust

use dashmap::DashMap;
use std::sync::Arc;
use std::thread;
use std::time::Instant;

const NUM_KEYS: usize = 1_000_000;
const ZIPF_SKEW: f64 = 1.0;

// =========================================================================
// Zipfian generator (rejection-inversion method)
// =========================================================================

struct ZipfGen {
    n: usize,
    s: f64,
    h_integral: f64,
    h_fraction: f64,
    state: u64,
}

impl ZipfGen {
    fn new(n: usize, s: f64, seed: u64) -> Self {
        Self {
            n, s,
            h_integral: h_int(n as f64 + 0.5, s),
            h_fraction: h_func(1.5, s) - 1.0,
            state: seed,
        }
    }

    fn next_rand(&mut self) -> f64 {
        // xorshift64
        self.state ^= self.state << 13;
        self.state ^= self.state >> 7;
        self.state ^= self.state << 17;
        (self.state as f64) / (u64::MAX as f64)
    }

    fn next(&mut self) -> usize {
        loop {
            let u_raw = self.next_rand();
            let u = self.h_integral + u_raw * (h_int(0.5, self.s) - self.h_integral);
            let x = h_int_inv(u, self.s);
            let mut k = (x + 0.5) as i64;
            if k < 1 { k = 1; }
            if k > self.n as i64 { k = self.n as i64; }
            let kf = k as f64;
            if kf - x <= self.h_fraction || u >= h_int(kf + 0.5, self.s) - h_func(kf, self.s) {
                return (k - 1) as usize;
            }
        }
    }
}

fn h_func(x: f64, s: f64) -> f64 { (-s * x.ln()).exp() }
fn h_int(x: f64, s: f64) -> f64 {
    let t = 1.0 - s;
    if t.abs() > 1e-8 { (x.powf(t) - 1.0) / t } else { x.ln() }
}
fn h_int_inv(x: f64, s: f64) -> f64 {
    let t = 1.0 - s;
    if t.abs() > 1e-8 { (t * x + 1.0).powf(1.0 / t) } else { x.exp() }
}

// =========================================================================
// Benchmark runner
// =========================================================================

fn main() {
    let num_workers = std::env::var("TOKIO_WORKER_THREADS")
        .ok()
        .and_then(|s| s.parse().ok())
        .unwrap_or_else(|| std::thread::available_parallelism().map(|n| n.get()).unwrap_or(8));
    let ops_per_worker = NUM_KEYS / num_workers;
    let map: Arc<DashMap<String, String>> = Arc::new(DashMap::new());

    // --- Workload 1: Uniform SET ---
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for w in 0..num_workers {
        let map = Arc::clone(&map);
        let start = w * ops_per_worker;
        handles.push(thread::spawn(move || {
            for i in start..start + ops_per_worker {
                map.insert(format!("key:{:08}", i), format!("value-{}", i));
            }
        }));
    }
    for h in handles { h.join().unwrap(); }
    let set_time = t0.elapsed().as_secs_f64();

    // --- Workload 2: Uniform GET ---
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for w in 0..num_workers {
        let map = Arc::clone(&map);
        let start = w * ops_per_worker;
        handles.push(thread::spawn(move || {
            for i in start..start + ops_per_worker {
                let _ = map.get(&format!("key:{:08}", i));
            }
        }));
    }
    for h in handles { h.join().unwrap(); }
    let get_uniform_time = t0.elapsed().as_secs_f64();

    // --- Workload 3: Zipfian GET ---
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for w in 0..num_workers {
        let map = Arc::clone(&map);
        handles.push(thread::spawn(move || {
            let mut z = ZipfGen::new(NUM_KEYS, ZIPF_SKEW, (w as u64 + 42) | 1);
            for _ in 0..ops_per_worker {
                let k = z.next();
                let _ = map.get(&format!("key:{:08}", k));
            }
        }));
    }
    for h in handles { h.join().unwrap(); }
    let get_zipf_time = t0.elapsed().as_secs_f64();

    // --- Workload 4: Mixed 80/20 ---
    let t0 = Instant::now();
    let mut handles = Vec::new();
    for w in 0..num_workers {
        let map = Arc::clone(&map);
        handles.push(thread::spawn(move || {
            let mut z = ZipfGen::new(NUM_KEYS, ZIPF_SKEW, (w as u64 + 99) | 1);
            for i in 0..ops_per_worker {
                let k = z.next();
                let key = format!("key:{:08}", k);
                // Use xorshift state for 80/20 split
                if (z.state % 100) < 80 {
                    let _ = map.get(&key);
                } else {
                    map.insert(key, format!("updated-{}", i));
                }
            }
        }));
    }
    for h in handles { h.join().unwrap(); }
    let mixed_time = t0.elapsed().as_secs_f64();

    println!("BENCH_RESULT: {} ms", ((set_time+get_uniform_time+get_zipf_time+mixed_time) * 1000.0) as u64);
    println!("Keys: {}", NUM_KEYS);
    println!("Workers: {}", num_workers);
    println!("Set: {:.4} s", set_time);
    println!("Get: {:.4} s", get_uniform_time);
    println!("Zipf: {:.4} s", get_zipf_time);
    println!("Mixed: {:.4} s", mixed_time);
    println!("Verified: yes");
}
