import time


class Acc:
    def __init__(self, a, b):
        self.a = a
        self.b = b


t0 = time.monotonic()
acc = Acc(1, 2)
for i in range(200000):
    acc.a = acc.a + i
    acc.b = acc.b + acc.a
total = acc.a + acc.b
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
