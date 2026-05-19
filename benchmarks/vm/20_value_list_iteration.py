import time

t0 = time.perf_counter()
items = []
for i in range(100_000):
    m3 = i % 3
    if m3 == 0:
        items.append(f"tag_{i}")
    elif m3 == 1:
        items.append(float(i))
    else:
        items.append(None)

push_ms = (time.perf_counter() - t0) * 1000
t1 = time.perf_counter()

num_count = 0
num_sum = 0.0
str_count = 0
nil_count = 0
for e in items:
    if isinstance(e, float):
        num_count += 1
        num_sum += e
    elif isinstance(e, str):
        str_count += 1
    else:
        nil_count += 1

iter_ms = (time.perf_counter() - t1) * 1000
total_ms = push_ms + iter_ms
print(f"nums={num_count} strs={str_count}")
print(f"nils={nil_count}")
print(f"Push: {int(push_ms)} ms | Iter: {int(iter_ms)} ms")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
