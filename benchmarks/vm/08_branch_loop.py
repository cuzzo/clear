import time

t0 = time.monotonic()
total = 0
for i in range(200000):
    r = i % 5
    if r == 0:
        total += i
    elif r == 1:
        total -= i
    elif r == 2:
        total += i * 2
    else:
        total += 1
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
