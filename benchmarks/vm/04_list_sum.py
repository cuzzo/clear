import time

t0 = time.monotonic()
values = []
for i in range(10000):
    values.append(i * 2)
append_ms = (time.monotonic() - t0) * 1000
t1 = time.monotonic()
total = 0
for j in range(len(values)):
    total += values[j]
sum_ms = (time.monotonic() - t1) * 1000
total_ms = append_ms + sum_ms
print(f"total = {total}")
print(f"Append: {append_ms:.3f} ms | Sum: {sum_ms:.3f} ms")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
