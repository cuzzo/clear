// Rust counterpart to zig/runtime/symbol-intern-benchmark-test.zig.
//
//   rustc -O symbol-intern-benchmark.rs -o /tmp/symbench && /tmp/symbench
//
// Not part of any build; run it by hand when re-checking the numbers in the
// Zig benchmark's header against a Rust baseline.
//
// Same workload, same four synchronization strategies, so the Zig numbers can
// be read against a Rust baseline rather than against nothing. Uses std only
// (no crates.io), modelling the interner the way ustr does: canonical strings
// are leaked, so a handle is a &'static str and equality is pointer equality.

use std::collections::HashSet;
use std::sync::Mutex;
use std::time::Instant;

const HITS_PER_THREAD: usize = 200_000;
const DISTINCT: usize = 1352;
const AVG_LEN: usize = 17;

fn make_names() -> Vec<String> {
    (0..DISTINCT)
        .map(|i| {
            let mut s: String = (0..AVG_LEN)
                .map(|j| (b'a' + ((i + j) % 26) as u8) as char)
                .collect();
            let tail = format!("{:05}", i);
            s.truncate(AVG_LEN - 5);
            s.push_str(&tail);
            s
        })
        .collect()
}

fn intern_raw(set: &mut HashSet<&'static str>, value: &str) -> &'static str {
    if let Some(found) = set.get(value) {
        return found;
    }
    let leaked: &'static str = Box::leak(value.to_string().into_boxed_str());
    set.insert(leaked);
    leaked
}

fn main() {
    let names = make_names();
    let threads: usize = std::thread::available_parallelism()
        .map(|n| n.get().min(8).max(2))
        .unwrap_or(4);

    // 1. Local pool, no lock (the proposal).
    let unlocked_ns = {
        let mut set: HashSet<&'static str> = HashSet::new();
        for n in &names {
            intern_raw(&mut set, n);
        }
        let t = Instant::now();
        for i in 0..HITS_PER_THREAD {
            let got = intern_raw(&mut set, &names[i % names.len()]);
            std::hint::black_box(got.as_ptr());
        }
        t.elapsed().as_nanos() as f64 / HITS_PER_THREAD as f64
    };

    // 2. Local pool behind an uncontended mutex (CLEAR today).
    let locked_ns = {
        let set: Mutex<HashSet<&'static str>> = Mutex::new(HashSet::new());
        {
            let mut g = set.lock().unwrap();
            for n in &names {
                intern_raw(&mut g, n);
            }
        }
        let t = Instant::now();
        for i in 0..HITS_PER_THREAD {
            let mut g = set.lock().unwrap();
            let got = intern_raw(&mut g, &names[i % names.len()]);
            std::hint::black_box(got.as_ptr());
        }
        t.elapsed().as_nanos() as f64 / HITS_PER_THREAD as f64
    };

    // 3+4. One shared pool: 1 thread, then N threads (ustr / rustc).
    let global: &'static Mutex<HashSet<&'static str>> =
        Box::leak(Box::new(Mutex::new(HashSet::new())));
    {
        let mut g = global.lock().unwrap();
        for n in &names {
            intern_raw(&mut g, n);
        }
    }

    let global_1t_ns = {
        let t = Instant::now();
        for i in 0..HITS_PER_THREAD {
            let mut g = global.lock().unwrap();
            let got = intern_raw(&mut g, &names[i % names.len()]);
            std::hint::black_box(got.as_ptr());
        }
        t.elapsed().as_nanos() as f64 / HITS_PER_THREAD as f64
    };

    let global_nt_ns = {
        let names: &'static Vec<String> = Box::leak(Box::new(names.clone()));
        let t = Instant::now();
        let hs: Vec<_> = (0..threads)
            .map(|_| {
                std::thread::spawn(move || {
                    for i in 0..HITS_PER_THREAD {
                        let mut g = global.lock().unwrap();
                        let got = intern_raw(&mut g, &names[i % names.len()]);
                        std::hint::black_box(got.as_ptr());
                    }
                })
            })
            .collect();
        for h in hs {
            h.join().unwrap();
        }
        t.elapsed().as_nanos() as f64 / (HITS_PER_THREAD * threads) as f64
    };

    println!("=== rust: {} hits/thread over {} distinct names ===", HITS_PER_THREAD, DISTINCT);
    println!("local_unlocked (proposed)   {:>7.2} ns/op", unlocked_ns);
    println!("local_locked   (today)      {:>7.2} ns/op", locked_ns);
    println!("global_1t      (rust, 1T)   {:>7.2} ns/op", global_1t_ns);
    println!("global_{}t      (rust, {}T)   {:>7.2} ns/op  [{} threads contending]", threads, threads, global_nt_ns, threads);
    println!("lock overhead (today vs proposed): {:>5.2} ns/op", locked_ns - unlocked_ns);
}
