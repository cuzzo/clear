# Runtime

## Overview

The runtime is built around cooperative Green Fibers rather than scheduling application code directly on OS threads.

At a very high level, the runtime has a few critical parts:

### 0. Bootstrap (`zig/runtime/runtime-footer.zig`)

 * This is the generated entrypoint glue for compiled CLEAR programs.
 * It sets up the allocator, global EBR context (for MVCC, not currently in use), stack pool, worker schedulers, and submits `clearMain` as the first task.

### 1. Runtime Context (`zig/runtime/runtime.zig`)

 * This is the per-fiber runtime object.
 * It owns the frame allocator, heap allocator, error context, and other execution-local runtime state.
 * Generated CLEAR code receives a `*Runtime` and performs most runtime-sensitive work through it.

### 2. Fibers & Stacks (`zig/runtime/fiber-core.zig`, `zig/runtime/fiber-memory.zig`)

 * This is the machinery for user-space Green Fibers.
 * It implements stack allocation, stack pooling, segmented stack growth, and low-level context switching.
 * This is what allows CLEAR to run many tasks without requiring one OS thread per task.

Like Go, CLEAR has stack-smash protection built-in. But the prevention mechanism is different.


### 3. Scheduler (`zig/runtime/scheduler.zig`, `zig/runtime/queues.zig`, `zig/runtime/spsc.zig`)

 * This is the **cooperative** scheduler.
 * It maintains runnable tasks, sleeping tasks, pinned tasks, and cross-scheduler messages.
 * It context-switches between Green Fiber stacks to run tasks cooperatively.
 * It uses SPSC channels for cross-scheduler communication and work stealing for load balancing.


## Stack Overflow Detection

The fiber runtime uses **segmented stacks**: a Machine Function Pass injects a stack-limit check at the very start of every function, *before* the prologue.  If the check fails, `__morestack` (in `switch.S`) allocates a new segment and the function retries on fresh stack space.

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

## Getting Started:

Running Tests:

```
zig build test
```

Running Benchmarks:

```
zig build benchmark -Doptimize=ReleaseFast
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

## Generate ASM

```bash
zig build-obj proof.zig -O ReleaseSmall -fno-emit-bin -femit-asm
# Manually edit proof.s

zig cc -c switch.S -o switch.o && zig cc -c proof.s -o proof.o && zig build-exe proof.o switch.o && ./proof
```
