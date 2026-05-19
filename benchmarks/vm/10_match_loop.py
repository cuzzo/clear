import time

t0 = time.monotonic()
total = 0
for i in range(200000):
    match i % 5:
        case 0:
            total += i
        case 1:
            total -= i
        case 2:
            total += i * 2
        case _:
            total += 1
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
