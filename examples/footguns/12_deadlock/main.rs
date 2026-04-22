// Footgun: Deadlock — Rust
//
// Rust's std::sync::Mutex blocks the thread forever on deadlock. The borrow
// checker guarantees memory safety (no use-after-free, no data races) but
// says nothing about lock ordering. A deadlock cycle compiles without error.
//
// Additionally, Rust's Mutex poisons itself when a thread panics while
// holding it. Subsequent lock() calls return Err(PoisonError). This is a
// different failure mode from Go/C (not a hang, but an error) — but it
// still requires the programmer to handle it.
//
// The `parking_lot` crate (widely used in production) adds optional deadlock
// detection as a feature flag. std does not.

use std::sync::{Arc, Mutex};
use std::thread;

// BROKEN: AB / BA lock order — deadlock. Not called from main.
#[allow(dead_code)]
fn broken() {
    let mu_a = Arc::new(Mutex::new(0i32));
    let mu_b = Arc::new(Mutex::new(0i32));

    let (a1, b1) = (Arc::clone(&mu_a), Arc::clone(&mu_b));
    let t1 = thread::spawn(move || {
        let _ga = a1.lock().unwrap();
        thread::sleep(std::time::Duration::from_millis(1));
        let _gb = b1.lock().unwrap(); // blocks: t2 holds b — DEADLOCK
        println!("t1: never reached");
    });

    let (a2, b2) = (Arc::clone(&mu_a), Arc::clone(&mu_b));
    let t2 = thread::spawn(move || {
        let _gb = b2.lock().unwrap();
        thread::sleep(std::time::Duration::from_millis(1));
        let _ga = a2.lock().unwrap(); // blocks: t1 holds a — DEADLOCK
        println!("t2: never reached");
    });

    t1.join().unwrap(); // hangs here
    t2.join().unwrap();
}

// CORRECT: consistent lock order — always A before B.
fn correct() {
    let mu_a = Arc::new(Mutex::new(0i32));
    let mu_b = Arc::new(Mutex::new(0i32));

    let mut handles = vec![];
    for i in 0..2 {
        let (a, b) = (Arc::clone(&mu_a), Arc::clone(&mu_b));
        handles.push(thread::spawn(move || {
            let _ga = a.lock().unwrap(); // always A first
            let _gb = b.lock().unwrap(); // then B
            println!("thread {}: holds both locks", i);
            // guards dropped here in reverse order (B, then A)
        }));
    }
    for h in handles { h.join().unwrap(); }
}

// CORRECT: scoped locks — release before acquiring the next.
// Only valid when atomicity across both locks is not required.
fn sequential() {
    let mu_a = Arc::new(Mutex::new(100i32));
    let mu_b = Arc::new(Mutex::new(200i32));

    let (a, b) = (Arc::clone(&mu_a), Arc::clone(&mu_b));
    thread::spawn(move || {
        let amount = {
            let mut ga = a.lock().unwrap();
            let v = *ga / 2;
            *ga -= v;
            v
        }; // mu_a released here

        let mut gb = b.lock().unwrap();
        *gb += amount;
        // mu_b released here
    }).join().unwrap();

    println!("a={}, b={}", mu_a.lock().unwrap(), mu_b.lock().unwrap());
}

fn main() {
    println!("--- consistent lock order ---");
    correct();

    println!("--- sequential (no simultaneous holds) ---");
    sequential();

    // broken(); // do not call — hangs
    println!("--- broken not run (would deadlock) ---");
}

// Compile: rustc main.rs -o deadlock_rs && ./deadlock_rs
//
// Key insight: Rust's safety guarantees stop at memory safety. Lock ordering,
// deadlock prevention, and liveness are the programmer's responsibility.
// The `parking_lot` crate's `deadlock` feature adds runtime cycle detection
// via a background thread that periodically checks for blocked owners.
// std::sync has no equivalent.
