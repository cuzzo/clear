# Puck V10

V10 keeps everything from V9 except the implementation language: the VM is rewritten in C.

- `compile.rb` — calls the V9 pipeline, then serializes the bytecode to a plain-text `.puckc` file (string table + procedure table + ops).
- `vm.c` — ~400 lines of C. Same opcodes, same value model (integers + refcounted heap arrays), same heap shape. Tagged `Value` struct, fixed-size memory frames, freelist for heap reuse, `switch` dispatch on the op enum. No JIT, no threading, no inline caching — the lesson is "just write the interpreter in a lower-level language."
- `Makefile` — `make vm` builds the binary; `make run-FOO` compiles `FOO.puck` and runs it through the VM.

V10's README focuses on **profiling tools and terms** — `perf`, `stackprof`, `cachegrind`, `valgrind --tool=callgrind`, plus the language ideas (interpreter dispatch overhead, boxing, GC pressure, cache locality, branch misprediction, JIT) that explain why the Ruby VM is 20-50x slower than mainstream interpreters on the same bytecode.

On the three V9 benchmarks, the C VM is **10-50x faster** than the Ruby VM with no algorithmic changes; the bytecode is byte-identical. It's competitive with Python and Ruby native — sometimes faster, sometimes slower. Native-compiled CLEAR (LLVM) is still 100-200x faster than the C VM, but that's a different lesson: bytecode interpretation has its own ceiling.

After V10 the tutorial sequence ends. `core.puck` (V9 stdlib) and `compiler.puck` (a self-hosted compiler in Puck) ship as plain files in the repo, not as new versions.
