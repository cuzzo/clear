import time
t0 = time.monotonic()
m = {}
for i in range(100000):
    m[i] = i * 2
insert_ms = (time.monotonic() - t0) * 1000
t1 = time.monotonic()
total = 0
for j in range(100000):
    total += m.get(j, 0)
lookup_ms = (time.monotonic() - t1) * 1000
total_ms = int(insert_ms + lookup_ms)
print(f"total = {total}")
print(f"Insert: {int(insert_ms)} ms | Lookup: {int(lookup_ms)} ms")
print(f"BENCH_RESULT: {total_ms} ms")
