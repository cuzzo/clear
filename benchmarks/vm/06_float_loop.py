import time

t0 = time.monotonic()
x = 1.0
for _ in range(100000):
    x = (x + 1.25) * 1.000001 - 0.25
total_ms = (time.monotonic() - t0) * 1000
print(f"x = {int(x)}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
