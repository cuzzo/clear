## Benchmarking

```bash
zig run sbr-benchmark-test.zig -O ReleaseFast -lc
```

* `-lc` links the c library (for malloc)
* `-O ReleaseFast` is required, otherwise you're comparing non-realistic results.
   * People only care about final optimized binary speed, `-O ReleaseFast` is needed to get that.
