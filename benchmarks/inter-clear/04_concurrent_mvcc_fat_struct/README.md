# 17a — MVCC vs RwLock: fat struct + multi-field reads

Scenario A from the MVCC scenario taxonomy. Reads an 8-field `Sample`
struct (64 bytes, one cache line) inside the critical section — the
read CS sums all 8 fields. This amortizes the lock-acquire / EBR-pin
cost across more useful work than `03_concurrent_mvcc_vs_rwlock` (which has a
~1ns Int64 read).

## Workload
- 32 readers x 80k iters; each iter takes ONE acquire and reads 8 fields.
- 4 writers x 1k field-bumps (sparse).

## Why MVCC pulls ahead here
- RwLock readers serialize against any writer for the entire
  multi-field critical section.
- MVCC readers grab a snapshot pointer + EBR pin, then walk an
  immutable cache-resident snapshot — never block on writers.

## Expected
3-5x MVCC win on 32 cores. Below that suggests the WITH-block
lowering or the EBR pin is leaving cycles on the table.

Run via:

    ruby benchmarks/runner.rb --release benchmarks/inter-clear/04_concurrent_mvcc_fat_struct/

The runner surfaces `BENCH_INFO:` lines that show RwLock vs MVCC
times and the speedup ratio.
