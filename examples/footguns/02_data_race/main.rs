// Footgun: Data Race — Rust
//
// Rust makes data races a compile-time error via the Send + Sync traits.
// A &mut T cannot be sent to another thread while any other reference
// exists. Sharing mutable state across threads requires Arc<Mutex<T>>
// (or Arc<Atomic*>), which the type system enforces — not just lints.

use std::sync::{Arc, Mutex};
use std::thread;

const ITERS: u64 = 1_000_000;

fn main() {
    // -----------------------------------------------------------------
    // The broken version — does not compile:
    //
    //   let mut counter = 0u64;
    //   let t1 = thread::spawn(|| { counter += 1; });
    //   //  ^^^ error[E0373]: closure may outlive the current function
    //   //      but it borrows `counter`, which is owned by the current function
    //   //  note: `counter` is borrowed here
    //   let t2 = thread::spawn(|| { counter += 1; });
    //   t1.join().unwrap();
    //   t2.join().unwrap();
    //
    // Even with move closures, two &mut would alias — also rejected:
    //
    //   let t1 = thread::spawn(move || { counter += 1; });
    //   let t2 = thread::spawn(move || { counter += 1; });
    //   //  ^^^ error[E0382]: use of moved value: `counter`
    // -----------------------------------------------------------------

    // The correct version — Arc<Mutex<T>> is the only way:
    let counter = Arc::new(Mutex::new(0u64));

    let c1 = Arc::clone(&counter);
    let t1 = thread::spawn(move || {
        for _ in 0..ITERS {
            *c1.lock().unwrap() += 1;
        }
    });

    let c2 = Arc::clone(&counter);
    let t2 = thread::spawn(move || {
        for _ in 0..ITERS {
            *c2.lock().unwrap() += 1;
        }
    });

    t1.join().unwrap();
    t2.join().unwrap();

    println!("counter = {} (expected {})", counter.lock().unwrap(), 2 * ITERS);
}

// Compile and run:  rustc main.rs -o race && ./race
// Result: always prints 2000000 — the type system forced correct code.
