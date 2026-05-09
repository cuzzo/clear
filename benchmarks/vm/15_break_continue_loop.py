import time

t0 = time.monotonic()
total = 0
seen = 0
for i in range(300_000):
    if i > 123_456:
        break
    if (i % 17) == 0:
        continue
    seen += 1
    if (i % 5) == 0:
        total += i * 2
    else:
        total += i
score = total + (seen * 11)
total_ms = (time.monotonic() - t0) * 1000
print(f"seen = {seen}")
print(f"score = {score}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
