import time

t0 = time.monotonic()
total_steps = 0
checksum = 0
seed = 1
while seed <= 2000:
    n = seed
    steps = 0
    while n != 1:
        if (n % 2) == 0:
            n //= 2
        else:
            n = (n * 3) + 1
        steps += 1
    total_steps += steps
    checksum += steps * seed
    seed += 1
total_ms = (time.monotonic() - t0) * 1000
print(f"steps = {total_steps}")
print(f"checksum = {checksum}")
print(f"BENCH_RESULT: {total_ms:.3f} ms")
