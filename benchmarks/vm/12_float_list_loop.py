import time

t0 = time.monotonic()
values = []
current = 0.0
for _ in range(5000):
    values.append(current)
    current += 1.5
for j in range(len(values)):
    values[j] = values[j] + 0.25
total = 0.0
for k in range(len(values)):
    total += values[k]
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {int(total)}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
