import time

t0 = time.monotonic()
m = {}
for i in range(60000):
    m[i] = i * 3

total = 0
hits = 0
for j in range(60000):
    if j in m:
        hits += 1
        total += m.get(j, 0)
    if (j % 4) == 0:
        m.pop(j, None)

survivors = 0
for k in range(60000):
    if k in m:
        survivors += 1

count = len(m)
score = total + (hits * 7) + (survivors * 11) + count
total_ms = (time.monotonic() - t0) * 1000
print(f"count = {count}")
print(f"score = {score}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
