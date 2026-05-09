import time
from dataclasses import dataclass

@dataclass
class Point:
    x: int
    y: int

@dataclass
class Box:
    p: Point
    weight: int

@dataclass
class Boxed:
    box: Box

@dataclass
class Raw:
    n: int

class Empty:
    pass

EMPTY = Empty()

def make_item(i):
    r = i % 3
    if r == 0:
        return Boxed(Box(Point(i, i * 2), i % 7))
    if r == 1:
        return Raw(i * 5)
    return EMPTY

def score_item(item):
    if isinstance(item, Boxed):
        return item.box.p.x + item.box.p.y + item.box.weight
    if isinstance(item, Raw):
        return item.n - 3
    return 1

t0 = time.monotonic()
total = 0
for i in range(100000):
    total += score_item(make_item(i))
total_ms = (time.monotonic() - t0) * 1000
print(f"total = {total}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
