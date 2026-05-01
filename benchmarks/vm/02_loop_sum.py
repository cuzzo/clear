import time
t0 = time.monotonic()
total = 0
for i in range(1000000):
    total = total + i
print(f"sum = {total}")
print(f"BENCH_RESULT: {int((time.monotonic() - t0) * 1000)} ms")
