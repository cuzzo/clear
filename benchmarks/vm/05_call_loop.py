import time


def mix(x):
    return (x * 3) + 1


t0 = time.monotonic()
total = 0
for i in range(100000):
    total += mix(i)
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
