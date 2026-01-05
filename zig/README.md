## Benchmarking

```bash
zig run sbr-benchmark-test.zig -O ReleaseFast -lc
```

* `-lc` links the c library (for malloc)
* `-O ReleaseFast` is required, otherwise you're comparing non-realistic results.
   * People only care about final optimized binary speed, `-O ReleaseFast` is needed to get that.

To test against SOTA malloc (jemalloc):

```
LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libjemalloc.so.2 zig run sbr-benchmark-test.zig -O ReleaseFast -lc
```

## Fuzzing

```bash
zig test arena-fuzz-test.zig -femit-bin=fuzz_runner

valgrind --leak-check=full \
         --show-leak-kinds=all \
         --track-origins=yes \
         --verbose \
         --quiet \
         ./fuzz_runner
```

