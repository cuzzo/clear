# The V10 Implementation - A C VM

V9 finished the language. The VM is essentially done — same bytecode shape, same value model, same heap. **V10 keeps everything except the implementation language: the VM gets rewritten in C.**

The compiler frontend (V9's tokenizer / parser / macro expander / compiler) is unchanged. V10 adds:

- `compile.rb` — calls into the V9 pipeline, then serializes the bytecode to a text file (`.puckc`).
- `vm.c` — a single C file (~400 lines) that reads `.puckc` and interprets the same opcodes V9's `vm.rb` does.
- A `Makefile` that builds `vm` and provides `make run-FOO` for `FOO.puck`.

Why bother? The Ruby VM is **20-50x slower than mainstream interpreters** (Python, Ruby, Node) on the same workload. Before rewriting, V10's first job is to understand *exactly why*, with real profiling tools and concrete numbers.

---

## The Numbers First

Running our three benchmarks through `benchmarks/vm/run.sh`:

```text
=== 01_fib (recursive fib(25)) ===
puck-rb    310ms       <- the Ruby VM we just spent 9 versions building
puck-c     153ms       <- this version
ruby         4ms       <- Ruby native, --disable=jit
python3      6ms
node         2ms
clear-zig    1ms       <- the production CLEAR compiler, LLVM optimized

=== 02_loop_sum (sum 0..1M) ===
puck-rb   1356ms
puck-c      37ms
ruby        40ms
python3     58ms
node        25ms
clear-zig    1ms
```

The C VM is roughly **10-50x faster** than the Ruby VM with no bytecode changes — same opcodes, same heap shape, same refcounting. The interpretation strategy is identical; only the host language changes.

Equally important: the C VM is now **competitive with Python and Ruby native** (sometimes faster, sometimes slower). It's not as fast as native code (LLVM-compiled CLEAR is 100-200x faster than even the C VM), but that's a different lesson — bytecode interpretation has its own ceiling.

---

## Why The Ruby VM Was Slow

Before reading vm.c, it's worth knowing what's slow about `vm.rb` and how you'd discover it yourself with off-the-shelf tools. The whole point of profiling is "don't guess — measure." Here are the terms and tools that matter, applied to our VM.

### 1. Interpretation overhead

The deepest layer of cost. The Ruby VM (MRI) is itself an interpreter — it reads Ruby bytecode and executes it. Our `vm.rb` is *another* interpreter, written in Ruby. So when V9's bytecode says `PUSH 1`, the chain is:

```text
puck bytecode PUSH 1
  -> ruby bytecode for `stack.push(code.arg)`
    -> MRI's C-level switch on opcode
      -> CPU instructions
```

Each level adds dispatch overhead. The Ruby-level `case code.op when :PUSH then ...` already executes maybe 30-100 Ruby bytecodes for what should be one machine instruction. **This is the dominant cost.** It's also the cost the C VM eliminates outright — there's only one interpreter now (the C one), not two stacked.

**Tools:** `ruby --dump=insns vm.rb` shows the Ruby bytecode for `vm.rb`. You'll see that each `case` branch alone compiles to dozens of instructions.

**Term to know:** *interpreter dispatch overhead*. Sometimes called the *bytecode dispatch loop* — the `switch (op)` at the heart of any interpreter. A direct-threaded or token-threaded interpreter (Lua) reduces it. A JIT (V8, JSC, YJIT) eliminates it for hot paths.

### 2. Method dispatch and boxing

Every Ruby integer is an object (`Integer`). Every `+` looks up the method `:+` on the left operand at runtime, then calls it. In our case the VM's `math` is:

```ruby
def math(op, stack)
  right = stack.pop
  left = stack.pop
  stack.push(left.send(op, right))
end
```

`left.send(op, right)` is a runtime method lookup followed by a method call followed by a return. **MRI's send is not free.** Even with the fixnum optimization (small ints don't allocate), every send involves cache lookups, argument shuffling, and return-value handling.

C's `+` is one machine instruction. No lookup. No boxing. The C VM's `case OP_MATH:` ends in:

```c
int64_t r = left + right;
```

That's it.

**Term to know:** *boxed values* vs *unboxed values*. Every Ruby Integer is boxed (an object with a class pointer, eligible for GC). The C VM uses unboxed `int64_t` directly.

### 3. Garbage collection and refcounting

The Ruby VM tracks heap values with `HeapValue` structs. Each `retain` and `release` is a Ruby method call on a Ruby struct. The struct itself is a Ruby object — so it's also subject to MRI's GC tracing.

```ruby
def release(value)
  return unless value.is_a?(HeapRef)   # type check, branch
  @heap[value.id].refs -= 1            # array bounds check, attribute read, attribute write
  if @heap[value.id].refs.zero?        # another array read
    @heap[value.id].value.each { ... } # block invocation per element
    @heap[value.id] = nil              # mark slot empty
  end
end
```

Every line is one or more Ruby bytecode ops. Per release. Per element. For a benchmark that does millions of release calls, this adds up.

**Tool:** `stackprof` will show you `HeapRef#==`, `Array#[]`, and `HeapValue#refs` near the top. **Term to know:** *write barrier overhead* — every mutation through Ruby's API has costs the language hides. C lets you write directly and pay only for what you write.

### 4. Pointer chasing

`HeapRef`, `HeapValue`, and the heap array itself are all Ruby objects on the heap. Following `@heap[ref.id].value[i]` is three pointer dereferences (Array → HeapValue → its instance vars → the inner array → its element).

C's struct lays out fields inline. `heap[ref.value].cells[i]` is one indexed access into a flat array; on a modern CPU the prefetcher loves it.

**Term to know:** *cache locality*. Adjacent things in memory get loaded together. Scattered things miss the cache and stall.

**Tool:** `perf stat -e cache-references,cache-misses,L1-dcache-loads,L1-dcache-load-misses ruby vm.rb` — counts L1 cache misses. Ruby is full of them.

### 5. Branch prediction

The Ruby VM's `case code.op when :PUSH ... when :LOAD ...` is interpreted by MRI as a chain of `===` comparisons. The branch pattern depends on what bytecode you happen to be running, which from the CPU's perspective is essentially random. Modern CPUs *predict* branches before resolving them; mispredictions cost 15-20 cycles.

The C VM's `switch (c->op)` gets compiled to a *jump table* — a single indirect jump, no chain of conditionals.

**Tool:** `perf stat -e branches,branch-misses` shows the misprediction rate.

### 6. Allocation pressure

Every `Value.new`, every `HeapRef.new`, every `Array.new` is an allocation that MRI's GC eventually has to scan. Even short-lived intermediates count.

**Tool:** `GC.stat` before and after the workload shows total allocations. `ruby --jit-verbose=2` (or YJIT logging) shows where the JIT gave up because of bailouts caused by allocation.

C alloca/stack frames are essentially free. Heap allocation in our C VM is `malloc` + slot reuse via a freelist — bounded and explicit.

### 7. No JIT (in our build)

We deliberately run with `--disable=jit` in the benchmark for fairness — both `puck-rb` and the reference `ruby` rows use the same flag. With YJIT on, MRI compiles hot Ruby methods to machine code at runtime; the gap to the C VM narrows considerably but doesn't close.

**Term to know:** *tracing JIT* vs *method JIT*. YJIT is a method JIT. V8's TurboFan is a method JIT with speculation; LuaJIT is a tracing JIT. Tracing JITs are particularly good for loops like our `bench_loop` because they specialize the loop body to the observed types.

---

## Profiling The Real Thing

Don't trust this list — run it yourself. With our benchmarks:

```bash
# Simple wall-clock comparison
time ruby benchmarks/vm/run_puck.rb benchmarks/vm/02_loop_sum.puck
time ruby benchmarks/vm/run_puck.rb benchmarks/vm/02_loop_sum.puck  # again — variance is real

# CPU sampling profile (Linux)
perf record -F 999 -g -- ruby benchmarks/vm/run_puck.rb benchmarks/vm/02_loop_sum.puck
perf report

# Ruby-level profile via stackprof
gem install stackprof
StackProf.run(mode: :cpu, raw: true, out: 'stackprof.dump') { ... }
stackprof stackprof.dump --text                              # leaf time
stackprof stackprof.dump --method 'VM#run_codes'             # per-method drill-down
stackprof stackprof.dump --flamegraph | flamegraph.pl > flame.svg

# Cache + branch counters
perf stat -e instructions,cycles,branches,branch-misses,cache-misses \
  ruby benchmarks/vm/run_puck.rb benchmarks/vm/02_loop_sum.puck

# Allocation tracking
GC.stat[:total_allocated_objects]  # call before and after the workload

# System calls
strace -c ruby benchmarks/vm/run_puck.rb benchmarks/vm/02_loop_sum.puck
```

For the C VM the same tools apply with a different binary path:

```bash
# Build with debug info kept for profiling
make CFLAGS='-O2 -g' vm

perf record -F 999 -g -- ./vm bench.puckc
perf report

# Cache analysis via Valgrind
valgrind --tool=cachegrind ./vm bench.puckc
cg_annotate cachegrind.out.*

# Callgraph via Valgrind
valgrind --tool=callgrind ./vm bench.puckc
callgrind_annotate callgrind.out.*

# Sanitizers (catch UB / leaks / use-after-free)
make vm-debug
./vm-debug bench.puckc
```

---

## The C VM

`vm.c` is one file, around 400 lines. The structure mirrors `v9/vm.rb` one-to-one:

```text
v9/vm.rb                    v10/vm.c
---------------------       ---------------------
class VM                    static Program* program
  run                       int main()
  run_codes                 run_codes()
  HeapValue / HeapRef       HeapEntry, Value (tagged)
  retain / release          retain() / release()
  allocate_codepoints       alloc_codepoints()
  allocate_cells            alloc_cells()
  handle_syscall            handle_syscall()
```

A few deliberate design choices kept it readable:

1. **Tagged values.** `Value` is a 16-byte struct with a tag (`V_INT` or `V_REF`) and a payload. Bulkier than NaN-boxing or pointer tagging, but trivially correct and easy to step through in `gdb`.
2. **Fixed-size memory frames.** Each procedure's memory is a `Value[256]` stack array — no allocation, no growth logic. Wastes some bytes for shallow callers; nobody cares.
3. **Heap with a freelist.** `heap[]` grows on demand. When a refcount hits zero the slot's index goes on a `freelist[]` and is reused on the next allocation. Same eventual layout as the Ruby VM, written without a tracing GC.
4. **One operator switch.** Math and compare both use a small `OpKind` enum (K_ADD, K_EQ, ...). The compiler resolves the source operator (`+`, `==`, ...) and emits the enum value directly. No `send` at runtime.
5. **Switch dispatch.** The main loop is `switch (c->op)`. The C compiler emits a jump table; modern CPUs run it close to one cycle per simple op.

No clever tricks: no computed-goto threading, no bytecode rewriting, no inline caching, no JIT. The whole point is that **just rewriting in a lower-level language**, with no algorithmic changes, gets you 10-50x.

That's the V10 lesson. If you wanted to keep optimizing — direct threading would buy maybe another 2x, inline caching on hot ops another 2x, a real JIT 10-50x more. But each step has diminishing returns; the fattest one is "stop interpreting with an interpreter."

---

## Usage

```bash
# One-shot
cd examples/puck/v10
make run-example                # builds vm + runs example.puck

# Step by step
make vm
ruby compile.rb example.puck example.puckc
./vm example.puckc

# Debug build (sanitizers, no optimization)
make vm-debug
./vm-debug example.puckc
```

The benchmark runner picks this up automatically; `bash benchmarks/vm/run.sh` shows a `puck-c` row alongside `puck-rb` and the language baselines.

---

## What Ships Next

V10 closes the tutorial sequence. The remaining artifacts ship as files in the repo, not as new versions:

- `examples/puck/core.puck` — the V9-version standard library (string ops, int↔string, helpers).
- `examples/puck/compiler.puck` — a self-hosting Puck compiler, written in Puck itself, running on top of either the Ruby VM (V9) or the C VM (V10).

Both will be code-to-read rather than incremental lessons. The language is done; everything from here is application code.
