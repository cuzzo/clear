#!/usr/bin/env python3
"""Benchmark: create array of 10000 integers, filter evens, sum them."""
import time

N = 10_000
ITERS = 100

# Warmup + verify
nums = list(range(N))
total = sum(n for n in nums if n % 2 == 0)
print(f"Sum of evens 0..{N-1}: {total}")
assert total == 24_995_000

start = time.monotonic()
for _ in range(ITERS):
    nums = list(range(N))
    s = 0
    for n in nums:
        if n % 2 == 0:
            s += n
elapsed = time.monotonic() - start

print(f"Python: {ITERS} iterations in {elapsed*1000:.0f}ms")
print(f"  {elapsed*1000/ITERS:.2f}ms per iteration")
