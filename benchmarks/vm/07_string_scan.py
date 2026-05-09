import time

line = "SET:12345:payload"
t0 = time.monotonic()
total = 0
for _ in range(50000):
    if line.startswith("SET:") and "payload" in line:
        total += len(line[4:9])
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
