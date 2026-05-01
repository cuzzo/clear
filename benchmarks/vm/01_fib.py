import time
def fib(n):
    if n <= 1: return n
    return fib(n-1) + fib(n-2)
t0 = time.monotonic()
r = fib(25)
print(f"fib(25) = {r}")
print(f"BENCH_RESULT: {int((time.monotonic() - t0) * 1000)} ms")
