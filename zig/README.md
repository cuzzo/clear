## Stack Overflow Detection

The fiber runtime uses **segmented stacks**: a Machine Function Pass injects
a stack-limit check at the very start of every function, *before* the
prologue.  If the check fails, `__morestack` (in `switch.S`) allocates a
new segment and the function retries on fresh stack space.

### Step 1: Build the LLVM Machine Pass plugin

```bash
rm -rf fiber-stack-check/pass/build
cmake -B fiber-stack-check/pass/build -S fiber-stack-check/pass
cmake --build fiber-stack-check/pass/build
```

### Step 2: Run the pass test

```bash
bash fiber-stack-check/test-pass.sh
```

### Step 3: Full pipeline (BC → instrumented object)

```bash
# Emit LLVM bitcode from Zig
zig test fiber-overflow-test.zig switch.S onRoot.S \
    --library c \
    -femit-llvm-bc=fiber-overflow-test.bc \
    -fno-emit-bin

# Lower to MIR (stop after prologue/epilogue insertion)
llc-18 fiber-overflow-test.bc \
    -stop-after=prologepilog \
    -o fiber-overflow-test.mir

# Run the Machine Pass (inserts __morestack before prologue)
llc-18 \
    --load=fiber-stack-check/pass/build/libFiberStackCheck.so \
    --run-pass=fiber-stack-check \
    fiber-overflow-test.mir \
    -o fiber-overflow-test-instrumented.mir

# Finish code generation (resume after prologepilog)
llc-18 fiber-overflow-test-instrumented.mir \
    --start-after=prologepilog \
    -o fiber-overflow-test.o \
    -filetype=obj

# Link and run
zig build-exe fiber-overflow-test.o switch.S onRoot.S \
    --library c --name fiber-test-runner
./fiber-test-runner
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


## Generate ASM

```bash
zig build-obj proof.zig -O ReleaseSmall -fno-emit-bin -femit-asm
# Manually edit proof.s

zig cc -c switch.S -o switch.o && zig cc -c proof.s -o proof.o && zig build-exe proof.o switch.o && ./proof
```
