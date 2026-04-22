// Footgun: TOCTOU — Rust
//
// Rust prevents data races at the type level, but TOCTOU is a logical
// race, not a memory-safety violation. Arc<Mutex<T>> correctly serializes
// individual lock acquisitions, but if you release the lock between check
// and act, the invariant you checked is no longer guaranteed to hold.
//
// The borrow checker has no concept of "this decision was made under a
// now-released lock". Both the broken and correct versions compile.

use std::sync::{Arc, Mutex};
use std::thread;

struct Account {
    balance: i64,
}

// BROKEN: two separate lock() calls — window between check and act.
fn withdraw_broken(acct: Arc<Mutex<Account>>, amount: i64) -> bool {
    let ok = {
        let guard = acct.lock().unwrap();
        guard.balance >= amount
    }; // MutexGuard dropped here — lock released, window opens

    // Another thread can modify balance here.

    if ok {
        let mut guard = acct.lock().unwrap();
        guard.balance -= amount; // acting on a stale check
    }
    ok
}

// CORRECT: single lock() spanning both check and act.
fn withdraw_correct(acct: Arc<Mutex<Account>>, amount: i64) -> bool {
    let mut guard = acct.lock().unwrap();
    if guard.balance < amount {
        return false;
    }
    guard.balance -= amount; // check and act are atomic
    true
} // guard dropped here — lock released after act

fn main() {
    let acct = Arc::new(Mutex::new(Account { balance: 100 }));

    // Five threads each try to withdraw 80 — broken version.
    let handles: Vec<_> = (0..5)
        .map(|_| {
            let a = Arc::clone(&acct);
            thread::spawn(move || withdraw_broken(a, 80))
        })
        .collect();

    let successes: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap() as usize)
        .sum();

    let balance = acct.lock().unwrap().balance;
    println!("broken:  {} withdrawals succeeded, balance = {}", successes, balance);
    // May print: 2 withdrawals succeeded, balance = -60

    // Reset and run correct version.
    acct.lock().unwrap().balance = 100;
    let handles: Vec<_> = (0..5)
        .map(|_| {
            let a = Arc::clone(&acct);
            thread::spawn(move || withdraw_correct(a, 80))
        })
        .collect();

    let successes: usize = handles
        .into_iter()
        .map(|h| h.join().unwrap() as usize)
        .sum();

    let balance = acct.lock().unwrap().balance;
    println!("correct: {} withdrawal  succeeded, balance = {}", successes, balance);
    // Always: 1 withdrawal succeeded, balance = 20
}

// Compile: rustc main.rs -o toctou && ./toctou
//
// Note: -race / TSan will NOT flag withdraw_broken because both accesses
// are individually locked. The bug is logical, not a data race.
