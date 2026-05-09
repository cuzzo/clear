import time


class Value:
    def __init__(self, tag, payload=None):
        self.tag = tag
        self.payload = payload


def make_value(i):
    r = i % 3
    if r == 0:
        return Value("a", i)
    if r == 1:
        return Value("b", i * 2)
    return Value("c")


t0 = time.monotonic()
total = 0
for i in range(100000):
    v = make_value(i)
    match v.tag:
        case "a":
            total += v.payload
        case "b":
            total -= v.payload
        case _:
            total += 1
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
