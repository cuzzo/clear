// Footgun: Memory Ordering — Rust
//
// Rust exposes the same memory-order hierarchy as C11. Ordering::Relaxed
// on a publish flag compiles, runs correctly on x86, and silently breaks
// on ARM/POWER. The type system enforces that you choose an ordering, but
// it cannot verify that the ordering you chose is correct for the pattern.
//
// This is the canonical footgun: the compiler accepts both versions below.
// The difference is only visible on weakly-ordered hardware or under
// formal memory model analysis (e.g. LKMM, herd7).

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread;

fn broken_publish() {
    let ready = Arc::new(AtomicBool::new(false));
    let message = Arc::new(std::sync::Mutex::new(String::new()));

    let r = Arc::clone(&ready);
    let m = Arc::clone(&message);
    let producer = thread::spawn(move || {
        *m.lock().unwrap() = "hello from producer".to_string();
        // BROKEN: Relaxed does not synchronize with the consumer's load.
        // On ARM/POWER the CPU may reorder this store before the mutex
        // unlock, so the consumer may see ready=true but stale message.
        r.store(true, Ordering::Relaxed);
    });

    let r = Arc::clone(&ready);
    let m = Arc::clone(&message);
    let consumer = thread::spawn(move || {
        // BROKEN: Relaxed load does not establish happens-before with
        // the Relaxed store. No barrier is inserted on weak hardware.
        while !r.load(Ordering::Relaxed) {}
        println!("broken:  '{}'", m.lock().unwrap());
        // May print empty string on ARM/POWER even though ready is true.
    });

    producer.join().unwrap();
    consumer.join().unwrap();
}

fn correct_publish() {
    let ready = Arc::new(AtomicBool::new(false));
    let message = Arc::new(std::sync::Mutex::new(String::new()));

    let r = Arc::clone(&ready);
    let m = Arc::clone(&message);
    let producer = thread::spawn(move || {
        *m.lock().unwrap() = "hello from producer".to_string();
        // Release: all prior stores in this thread are visible to any
        // thread that subsequently performs an Acquire load of `ready`.
        r.store(true, Ordering::Release);
    });

    let r = Arc::clone(&ready);
    let m = Arc::clone(&message);
    let consumer = thread::spawn(move || {
        // Acquire: synchronizes with the Release store.
        // Guaranteed to observe all writes that happened-before the store.
        while !r.load(Ordering::Acquire) {}
        println!("correct: '{}'", m.lock().unwrap());
        // Always: "hello from producer" on all architectures.
    });

    producer.join().unwrap();
    consumer.join().unwrap();
}

fn main() {
    broken_publish();
    correct_publish();
}

// Compile: rustc main.rs -o memord && ./memord
//
// Both compile without warnings. The broken version is correct on x86
// because x86's Total Store Order (TSO) model prevents this reordering.
// On ARM (e.g. Apple M-series, AWS Graviton, Android phones) the broken
// version can observe the flag before the message is visible.
//
// TSan does NOT detect this — the Mutex prevents the data race;
// the ordering bug is at the atomic synchronization level, not the
// access level.
//
// Rule: for publish flags, always use Release (store) + Acquire (load).
// Use Relaxed only for counters where the value is never used to gate
// visibility of other data.
