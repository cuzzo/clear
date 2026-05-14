import time
t0 = time.monotonic()
nums = list(range(10000))
total = sum(n for n in nums if n % 2 == 0)
print(f"sum = {total}")
print(f"BENCH_RESULT: {int((time.monotonic() - t0) * 1000)} ms")
