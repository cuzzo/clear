#!/usr/bin/env python3
"""Benchmark: tight integer loop summing 0..9_999_999."""
import time

N = 10_000_000
ITERS = 3

# Verify
s = 0
for i in range(N):
    s += i
assert s == N * (N - 1) // 2, f"bad sum: {s}"
print(f"sum(0..{N-1}) = {s}")

start = time.monotonic()
for _ in range(ITERS):
    s = 0
    for i in range(N):
        s += i
elapsed = time.monotonic() - start

print(f"Python: {ITERS} iterations in {elapsed*1000:.0f}ms")
print(f"  {elapsed*1000/ITERS:.2f}ms per iteration")
