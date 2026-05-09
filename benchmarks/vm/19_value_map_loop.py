import time

t0 = time.perf_counter()
m = {}
for i in range(50_000):
    if (i % 2) == 0:
        m[f"k_{i}"] = i * 1.5
    else:
        m[f"k_{i}"] = f"v_{i}"

insert_ms = (time.perf_counter() - t0) * 1000
t1 = time.perf_counter()

num_count = 0
str_count = 0
for j in range(50_000):
    v = m[f"k_{j}"]
    if isinstance(v, float):
        num_count += 1
    elif isinstance(v, str):
        str_count += 1

read_ms = (time.perf_counter() - t1) * 1000
total_ms = insert_ms + read_ms
print(f"nums={num_count} strs={str_count}")
print(f"Insert: {int(insert_ms)} ms | Read: {int(read_ms)} ms")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
