## Stack Overflow Detection

### Step 1: Build LLVM Pass

```bash
rm -rf fiber-stack-check/pass/build
cmake -B fiber-stack-check/pass/build -S fiber-stack-check/pass
cmake --build fiber-stack-check/pass/build
```

### Step 2: Build the LLVM IR:

```bash
zig test fiber-overflow-test.zig switch.S onRoot.S     --library c     -femit-llvm-bc=fiber-overflow-test.bc     -fno-emit-bin
```

### Step 3: Run the Plugin:

```bash
opt -load-pass-plugin=fiber-stack-check/pass/build/libFiberStackCheck.so \
    -passes="fiber-stack-check" \
    fiber-overflow-test.bc \
    -o fiber-overflow-test-instrumented.bc
```

### Step 4: Run the exe:

```bash
zig build-exe fiber-overflow-test-instrumented.bc switch.S onRoot.S --library c --name fiber-test-runner
```


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

```bash
zig test queues-test.zig -fsanitize-thread -lc
```

```bash
./scheduler-fuzz-test.sh
```


## Unwinding

```bash
zig test unwind-test.zig unwind.S -lc -lunwind   -O Debug   -fno-strip   -rdynamic   --eh-frame-hdr
```
