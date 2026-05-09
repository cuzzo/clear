import time

t0 = time.monotonic()
hits = 0
skips = 0
i = 0
while i < 200_000:
    d = i % 11
    if d != 0 and (100 // d) > 9:
        hits += 1
    if d == 0 or (100 // d) < 4:
        skips += 1
    i += 1
score = (hits * 3) + (skips * 7)
total_ms = (time.monotonic() - t0) * 1000
print(f"hits = {hits}")
print(f"skips = {skips}")
print(f"score = {score}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
