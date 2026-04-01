// Direct comparison: Rust DashMap vs single RwLock
// Same workloads as the Zig bench_compare, to isolate lock/map implementation quality.

use dashmap::DashMap;
use std::sync::{Arc, RwLock};
use std::collections::HashMap;
use std::thread;
use std::time::Instant;

const N_KEYS: usize = 1_000_000;

// ---- Zipf ----
fn h_func(x: f64, s: f64) -> f64 { (-s * x.ln()).exp() }
fn h_int(x: f64, s: f64) -> f64 {
    let t = 1.0 - s;
    if t.abs() > 1e-8 { (x.powf(t) - 1.0) / t } else { x.ln() }
}
fn h_int_inv(x: f64, s: f64) -> f64 {
    let t = 1.0 - s;
    if t.abs() > 1e-8 { (t * x + 1.0).powf(1.0 / t) } else { x.exp() }
}
fn zipf_next(state: &mut i64, n: i64, s: f64, h_integral: f64, h_fraction: f64) -> i64 {
    let h_int_half = h_int(0.5, s);
    loop {
        *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        let mut u_bits = *state;
        if u_bits < 0 { u_bits = -u_bits; }
        let mut u = (u_bits % 1_000_000_000) as f64 / 1_000_000_000.0;
        u = h_integral + u * (h_int_half - h_integral);
        let x = h_int_inv(u, s);
        let mut k = (x + 0.5) as i64;
        if k < 1 { k = 1; }
        if k > n { k = n; }
        let kf = k as f64;
        if kf - x <= h_fraction { return k - 1; }
        if u >= h_int(kf + 0.5, s) - h_func(kf, s) { return k - 1; }
    }
}

fn main() {
    let keys: Arc<Vec<String>> = Arc::new((0..N_KEYS).map(|i| format!("key:{}", i)).collect());

    println!("\n=== Rust Map Strategy Comparison (1M keys) ===\n");

    let worker_counts = [1, 2, 4, 8, 16, 32];
    let s = 1.0f64;
    let h_integral = h_int(N_KEYS as f64 + 0.5, s);
    let h_fraction = h_func(1.5, s) - 1.0;

    // Strategy 1: Single RwLock<HashMap>
    println!("Strategy 1: Single RwLock<HashMap>");
    for &n_workers in &worker_counts {
        let map = Arc::new(RwLock::new(HashMap::new()));
        {
            let mut m = map.write().unwrap();
            for i in 0..N_KEYS {
                m.insert(keys[i].clone(), keys[i].clone());
            }
        }
        let chunk = N_KEYS / n_workers;

        // Zipf GET
        let t0 = Instant::now();
        let handles: Vec<_> = (0..n_workers).map(|wi| {
            let map = Arc::clone(&map);
            let keys = Arc::clone(&keys);
            thread::spawn(move || {
                let mut state = (wi as i64) + 42;
                let mut hits = 0usize;
                for _ in 0..chunk {
                    let k = zipf_next(&mut state, N_KEYS as i64, s, h_integral, h_fraction) as usize;
                    state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    let m = map.read().unwrap();
                    if m.get(&keys[k]).is_some() { hits += 1; }
                }
                hits
            })
        }).collect();
        let _: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let zipf_ms = t0.elapsed().as_millis();

        // Mixed 80/20
        let t0 = Instant::now();
        let handles: Vec<_> = (0..n_workers).map(|wi| {
            let map = Arc::clone(&map);
            let keys = Arc::clone(&keys);
            thread::spawn(move || {
                let mut state = (wi as i64) + 99;
                let mut hits = 0usize;
                for _ in 0..chunk {
                    let k = zipf_next(&mut state, N_KEYS as i64, s, h_integral, h_fraction) as usize;
                    state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    let mut decision = state % 100;
                    if decision < 0 { decision = -decision; }
                    if decision < 80 {
                        let m = map.read().unwrap();
                        if m.get(&keys[k]).is_some() { hits += 1; }
                    } else {
                        let mut m = map.write().unwrap();
                        m.insert(keys[k].clone(), keys[k].clone());
                    }
                }
                hits
            })
        }).collect();
        let _: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let mixed_ms = t0.elapsed().as_millis();

        println!("  single-lock({:>2}w)   zipf={:>5}ms  mixed={:>5}ms", n_workers, zipf_ms, mixed_ms);
    }

    // Strategy 2: DashMap (sharded RwLock)
    println!("\nStrategy 2: DashMap (sharded RwLock, {} shards)", num_cpus::get() * 4);
    for &n_workers in &worker_counts {
        let map: Arc<DashMap<String, String>> = Arc::new(DashMap::new());
        for i in 0..N_KEYS {
            map.insert(keys[i].clone(), keys[i].clone());
        }
        let chunk = N_KEYS / n_workers;

        // Zipf GET
        let t0 = Instant::now();
        let handles: Vec<_> = (0..n_workers).map(|wi| {
            let map = Arc::clone(&map);
            let keys = Arc::clone(&keys);
            thread::spawn(move || {
                let mut state = (wi as i64) + 42;
                let mut hits = 0usize;
                for _ in 0..chunk {
                    let k = zipf_next(&mut state, N_KEYS as i64, s, h_integral, h_fraction) as usize;
                    state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    if map.get(&keys[k]).is_some() { hits += 1; }
                }
                hits
            })
        }).collect();
        let _: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let zipf_ms = t0.elapsed().as_millis();

        // Mixed 80/20
        let t0 = Instant::now();
        let handles: Vec<_> = (0..n_workers).map(|wi| {
            let map = Arc::clone(&map);
            let keys = Arc::clone(&keys);
            thread::spawn(move || {
                let mut state = (wi as i64) + 99;
                let mut hits = 0usize;
                for _ in 0..chunk {
                    let k = zipf_next(&mut state, N_KEYS as i64, s, h_integral, h_fraction) as usize;
                    state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                    let mut decision = state % 100;
                    if decision < 0 { decision = -decision; }
                    if decision < 80 {
                        if map.get(&keys[k]).is_some() { hits += 1; }
                    } else {
                        map.insert(keys[k].clone(), keys[k].clone());
                    }
                }
                hits
            })
        }).collect();
        let _: Vec<_> = handles.into_iter().map(|h| h.join().unwrap()).collect();
        let mixed_ms = t0.elapsed().as_millis();

        println!("  dashmap({:>2}w)       zipf={:>5}ms  mixed={:>5}ms", n_workers, zipf_ms, mixed_ms);
    }

    println!();
}
