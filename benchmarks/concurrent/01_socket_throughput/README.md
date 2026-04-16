# Benchmark 04: Socket Throughput

TCP loopback read throughput. Writer sends 100,000 × 256-byte messages
(25.6 MB total). Reader loops until all bytes received. Timer covers
only the read loop in all three languages.

Read buffers:
- C: `char buf[4096]` on the stack — zero allocation
- Rust: `[u8; 4096]` on the stack — zero allocation
- CLEAR: ReadPool (bitmask-based slot allocator, zero GPA mallocs in hot path)

## Results

| Language | Time | vs C |
|----------|------|------|
| C (`gcc -O3`) | ~63ms | baseline |
| Rust (`--release`) | ~62ms | ~0% |
| CLEAR (`--optimized`) | ~97ms | +54% |

C and Rust are identical — TCP read throughput on a stack buffer is
purely kernel-bound. CLEAR's gap comes from fiber scheduler overhead:
each `tcpRead` is an async io_uring operation with a yield point, vs
a direct blocking `read()` syscall in C/Rust.
