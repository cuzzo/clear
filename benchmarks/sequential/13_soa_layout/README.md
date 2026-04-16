# Benchmark 28: SOA Layout

Particle simulation: 100K particles, 100 iterations of position update (`x += vx`, `y += vy`).
Each particle has 64 float64 fields (512 bytes). The update loop touches 4 of 64 fields (6%).

| Layout | Cache utilization | CLEAR syntax |
|--------|------------------|--------------|
| AOS (Array of Structs) | 6% (4 of 64 fields loaded per cache line) | default |
| SOA (Struct of Arrays) | 100% (only hot fields loaded) | `T[N]@soa` |

`BENCH_RESULT` = SOA time for each language.

## Results (100K particles x 100 iters)

| Implementation | SOA (ms) | AOS (ms) | SOA speedup |
|----------------|---------|---------|------------|
| CLEAR `@soa` | ~8ms | - | - |
| C manual SOA | ~9ms | ~55ms | ~6x |
| Rust manual SOA | ~9ms | ~55ms | ~6x |

CLEAR `@soa` is -11% vs C/Rust manual SOA.

## What each does

- **C/Rust AOS**: 64-field struct per particle, adjacent in memory. Hot loop loads full 512-byte cache lines but only uses 32 bytes (x, vx, y, vy).
- **C/Rust SOA**: manually split into separate `x[]`, `vx[]`, `y[]`, `vy[]` arrays (4 fields only). Other fields discarded.
- **CLEAR `@soa`**: all 64 fields stored in SOA layout automatically. Hot loop streams through `x[]`, `vx[]`, `y[]`, `vy[]` contiguously; other field arrays are untouched during the update.

CLEAR keeps all 64 fields (same data as AOS) while achieving the same cache efficiency as C's manually trimmed SOA.

## Key finding

`T[N]@soa` gives SOA cache efficiency with AOS syntax. No manual struct-splitting required.
CLEAR matches C/Rust manual SOA performance while retaining all fields.

## AOS vs SOA penalty (from C/Rust)

6% field utilization causes ~6x AOS slowdown. Each cache line loaded in AOS contains one particle's 64 fields (512 bytes), of which only 32 bytes are used. SOA loads 8 consecutive x-values per cache line, all used.
