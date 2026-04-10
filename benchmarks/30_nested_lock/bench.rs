// Nested Lock Benchmark -- Rust
//
// Bank transfer workload: N accounts, M workers doing random transfers.
// Each transfer:
//   1. Read-locks a shared bank (RwLock) to access the accounts array
//   2. Locks two accounts (ordered by index to prevent deadlock)
//   3. Transfers $1
// Measures throughput and contention overhead of nested lock acquisition.
//
// Build: rustc -C opt-level=3 bench.rs -o bench_rust

use std::sync::{Arc, Mutex, RwLock};
use std::thread;
use std::time::Instant;

const NUM_ACCOUNTS: usize = 64;
const OPS_PER_WORKER: usize = 500_000;

struct Account {
    balance: i64,
}

struct Bank {
    accounts: Vec<Mutex<Account>>,
}

// Simple LCG for deterministic, per-worker random numbers.
struct LCG {
    state: u64,
}

impl LCG {
    fn new(seed: u64) -> Self {
        LCG { state: seed }
    }
    fn next(&mut self) -> u64 {
        self.state = self.state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.state >> 33
    }
}

fn num_cpus() -> usize {
    thread::available_parallelism().map(|n| n.get()).unwrap_or(1)
}

fn main() {
    let n_cpu = num_cpus();
    let n_workers = if n_cpu >= 2 { n_cpu } else { 2 };

    let bank = Arc::new(RwLock::new(Bank {
        accounts: (0..NUM_ACCOUNTS)
            .map(|_| Mutex::new(Account { balance: 1000 }))
            .collect(),
    }));

    let t0 = Instant::now();

    let mut handles = Vec::new();
    for w in 0..n_workers {
        let bank = Arc::clone(&bank);
        handles.push(thread::spawn(move || {
            let mut rng = LCG::new(w as u64 * 7 + 13);
            for _ in 0..OPS_PER_WORKER {
                let a = (rng.next() as usize) % NUM_ACCOUNTS;
                let mut b = (rng.next() as usize) % NUM_ACCOUNTS;
                if a == b {
                    b = (a + 1) % NUM_ACCOUNTS;
                }

                // Read-lock bank to access accounts array
                let bank_guard = bank.read().unwrap();

                // Lock in index order to prevent deadlock
                let (lo, hi) = if a < b { (a, b) } else { (b, a) };
                let mut guard_lo = bank_guard.accounts[lo].lock().unwrap();
                let mut guard_hi = bank_guard.accounts[hi].lock().unwrap();

                if guard_lo.balance > 0 {
                    guard_lo.balance -= 1;
                    guard_hi.balance += 1;
                }

                drop(guard_hi);
                drop(guard_lo);
                drop(bank_guard);
            }
        }));
    }

    for h in handles {
        h.join().unwrap();
    }

    let elapsed = t0.elapsed().as_millis() as i64;

    let bank_guard = bank.read().unwrap();
    let mut total: i64 = 0;
    for acct in bank_guard.accounts.iter() {
        total += acct.lock().unwrap().balance;
    }
    let expected = (NUM_ACCOUNTS as i64) * 1000;
    let total_ops = (n_workers as i64) * OPS_PER_WORKER as i64;

    println!("Workers:        {}", n_workers);
    println!("Accounts:       {}", NUM_ACCOUNTS);
    println!("Ops per worker: {}", OPS_PER_WORKER);
    println!("Total ops:      {}", total_ops);
    println!("Total time:     {} ms", elapsed);
    println!("Ops/sec:        {}", total_ops * 1000 / elapsed);
    println!("Balance:        {} (expected {})", total, expected);
}
