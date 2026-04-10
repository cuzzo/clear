# Benchmark 30: Nested Lock (Bank Transfer)

Bank transfer workload: 64 accounts, N workers doing random transfers.
Each transfer acquires 3 locks: a read lock on the bank container, then
two mutex locks on accounts (ordered by index to prevent deadlock).

## Setup

- 64 accounts, each protected by a mutex, inside an RwLock-protected bank
- N worker threads/fibers, each doing 500K random transfers
- Each transfer: RLock bank, pick two accounts, Mutex lock both (lower index first), transfer $1
- Verify: total balance conserved after all transfers

## Results (32 workers, Linux x86_64)

| Lang  | Total  | vs Go  | vs Rust |
|-------|--------|--------|---------|
| Rust  | 2.07s  |        |         |
| Go    | 2.11s  |        |         |
| CLEAR | 2.31s  | +9.6%  | +11.5%  |

All three implementations are structurally identical: Arc<RwLock<Bank>> containing
Vec<Mutex<Account>>. The benchmark is apples-to-apples.

## Analysis

CLEAR is within ~10% of Go and Rust. The small overhead comes from:
- Arc refcount increments when extracting account references from the list
- Fiber scheduling overhead vs OS threads (BG @parallel pins to OS threads, but
  there is still a fiber trampoline)

The nested locking pattern works correctly in all three languages. Lock ordering
by account index prevents deadlocks. Total balance is conserved across all runs.

## TODO

- **Implement automatic lock sorting in the compiler.** Multi-binding
  `WITH EXCLUSIVE a AS x, EXCLUSIVE b AS y` currently acquires locks in
  declaration order. The compiler should sort by pointer address at runtime
  to prevent deadlocks automatically, eliminating the need for manual
  index-ordered locking. This is a stated design goal in the manifesto
  (DEADLOCK.md) but not yet implemented.

## Running

```bash
ruby benchmarks/runner.rb --smoke benchmarks/30_nested_lock/   # CLEAR only
ruby benchmarks/runner.rb --fast benchmarks/30_nested_lock/    # All langs
ruby benchmarks/runner.rb benchmarks/30_nested_lock/           # Full run
```
