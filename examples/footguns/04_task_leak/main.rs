// Footgun: Task Leak — Rust
//
// Rust's thread::spawn returns a JoinHandle. Dropping the handle
// detaches the thread — it runs to completion but is no longer
// reachable for joining. If the thread blocks indefinitely, it leaks.
// This is safe in Rust's memory sense (no UB), but it is a resource
// leak with the same operational consequences as in C or Go.
//
// Rust does not prevent task leaks. The type system only ensures
// memory safety, not liveness. thread::spawn is "fire and forget"
// if you drop the JoinHandle.

use std::sync::{Arc, Condvar, Mutex};
use std::thread;

fn spawn_blocked() -> thread::JoinHandle<()> {
    // This condvar is never notified; the thread blocks forever.
    let pair = Arc::new((Mutex::new(false), Condvar::new()));
    let pair2 = Arc::clone(&pair);

    thread::spawn(move || {
        let (lock, cvar) = &*pair2;
        let mut ready = lock.lock().unwrap();
        while !*ready {
            ready = cvar.wait(ready).unwrap(); // blocks forever
        }
        println!("notified (never reached)");
    })
}

fn handle_request(id: u32) {
    let handle = spawn_blocked();
    drop(handle); // detaches the thread — it leaks
    println!("request {} handled (thread leaked)", id);
}

fn main() {
    for i in 0..5 {
        handle_request(i);
    }
    println!("main exiting with 5 leaked threads");
    // OS reclaims on process exit, but in a daemon this accumulates.
}

// Compile and run:  rustc main.rs -o task_leak && ./task_leak
//
// Rust's async ecosystem has the same problem:
//   tokio::spawn(async { /* blocks forever */ });
//   // JoinHandle dropped → task is detached → leaks
//
// Fix (threads): retain and join the JoinHandle, or use a thread pool
// with a shutdown mechanism (e.g. crossbeam::thread::scope).
//
// Fix (async): use structured concurrency via tokio::task::JoinSet
// or async-std's task groups, which cancel children on drop.
