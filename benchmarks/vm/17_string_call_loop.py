import time

def pick_label(i):
    r = i % 4
    if r == 0:
        return "alpha"
    if r == 1:
        return "beta"
    if r == 2:
        return "gamma"
    return "delta"

def label_score(label):
    if label == "alpha":
        return 11
    if label == "beta":
        return 17
    if label == "gamma":
        return 23
    return 31

def nested_score(i):
    return label_score(pick_label(i))

t0 = time.monotonic()
total = 0
for i in range(120000):
    total += nested_score(i)
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
