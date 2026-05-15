# v11 - Minimal x86_64 JIT

v11 is v10's C VM plus ~300 lines of JIT. Procedures that are pure integer
arithmetic - no heap, no SYSCALL, no floats - are compiled to native x86_64
machine code at program load time. Procedures that touch anything else are
left interpreted. There is no IR, no register allocator, no inline cache,
and no deoptimisation logic.

## The result

`bench/fib.puck` calls `fib(35)` once and prints elapsed milliseconds.

| Build                                 | fib(35) |
| ------------------------------------- | ------- |
| v10 C interpreter                     | 9664 ms |
| v11 with JIT disabled (`PUCK_JIT=0`)  | 9708 ms |
| v11 with JIT (default)                |   80 ms |

That's **121x** for one of the most punishing micro-benchmarks an
interpreter can face. The JIT'd procedure for `fib` is ~140 bytes of
machine code; the rest of the program (the LOOP+SYSCALL driver that
calls `fib`) still runs in the interpreter.

```
make
make run-bench/fib
PUCK_JIT=0 ./vm bench/fib.puckc        # interpreter only
PUCK_JIT_TRACE=1 ./vm bench/fib.puckc  # report what got JITed
```

## What gets JITed, and why so much falls out

A procedure is JIT-eligible iff:

1. Its bytecode uses only `PUSH`, `LOAD`, `STORE`, `MATH`, `COMPARE`,
   `JUMP`, `JUMP_IF_FALSE`, `RETURN`, `CALL`. Anything heap-touching
   (`ALLOC*`, `ARRAY_*`, `LOAD_REF`, `STORE_REF`) or any `SYSCALL`
   disqualifies it.
2. It has 6 or fewer plain (non-VAR) parameters.
3. Every `CALL` target is also JIT-eligible. Propagated to fixpoint.

For `core-test.puck` this picks 7 of 32 procedures: `abs`, `min`, `max`,
`is_digit`, `is_letter`, `is_whitespace`, `is_alpha_num`. Everything that
touches a string or calls a syscall stays interpreted, and that's correct
- the JIT only knows about `V_INT`, not the heap-ref tag the interpreter
uses for strings/arrays.

## How small the emitter actually is

The whole JIT is `jit.c` plus a 5-line bridge in `vm.c`'s `OP_CALL` handler.
The emitter is a switch over bytecode ops; each case writes a fixed byte
sequence. Three things make this possible:

**One value tag.** Eligibility excludes V_REF and floats, so the JIT never
needs to inspect a value's tag, box/unbox, or call into GC. All values are
just int64s.

**The x86 stack IS the value stack.** A Puck `LOAD slot` is one machine
instruction: `push qword [rbp+disp32]`. `PUSH 42` is `movabs rax, 42` then
`push rax`. There is no software stack pointer to maintain - the JITed
function lives entirely inside the C calling convention.

**Self-recursive CALL with absolute addressing.** `fib` calling `fib`
emits `movabs rax, <addr>; call rax`. The first time we emit a CALL we
don't yet know the callee's machine-code address, so we leave a 0
placeholder and patch it after every procedure has been emitted. This
makes forward and self references symmetric - one mechanism, zero
distinction in the emitter.

## File layout

```
v11/
  vm_types.h     -- shared Procedure / ByteCode / Value definitions
  jit.h          -- one public function: jit_compile_program(Program*)
  jit.c          -- the ~300-line emitter
  vm.c           -- v10's vm.c, with vm_types.h included and a ~25-line
                    JIT bridge in the OP_CALL handler
  Makefile       -- builds vm from vm.c + jit.c
  bench/fib.puck -- the benchmark
```

## Platform support

v11 targets **x86_64 Linux** only. Everything else short-circuits to a
no-op `jit_compile_program` and the interpreter handles every procedure.

- **Intel macOS** would add support in ~5 LOC: define `MAP_ANONYMOUS`
  (macOS calls it `MAP_ANON`) and relax the `#ifdef`. The System V
  calling convention is the same as Linux, and `mprotect` works.
- **Windows x86_64** would add support in ~10-15 LOC: swap
  `mmap`/`mprotect` for `VirtualAlloc`/`VirtualProtect`, and replace
  the System V arg-reg list (`rdi, rsi, rdx, rcx, r8, r9`) with the
  Windows x64 list (`rcx, rdx, r8, r9`, then stack) in the prologue's
  arg-spill loop.
- **Apple Silicon / ARM64** is a different ISA and would need its own
  encoder. Out of scope.

Both Linux deltas are small enough that any motivated reader can do
them in an afternoon - but they're kept out of the codebase to keep the
emitter `#ifdef`-free.

## How the JIT'd code for fib looks

Pseudocode for what we emit (prologue, two cases, recursive calls, return):

```
fib:
    push rbp
    mov  rbp, rsp
    sub  rsp, 8
    mov  [rbp-8], rdi          ; spill n into slot 0

    ; IF n < 2
    push qword [rbp-8]
    movabs rax, 2
    push rax
    pop  rcx
    pop  rax
    cmp  rax, rcx
    setl al
    movzx rax, al
    push rax
    pop  rax
    test rax, rax
    jz   AFTER_THEN

    ; RETURN n
    push qword [rbp-8]
    pop  rax
    leave
    ret

AFTER_THEN:
    ; fib(n-1) + fib(n-2)
    push qword [rbp-8]
    movabs rax, 1
    push rax
    pop  rcx
    pop  rax
    sub  rax, rcx
    push rax
    pop  rdi
    movabs rax, <&fib>          ; patched after all procs emitted
    call rax
    push rax

    push qword [rbp-8]
    movabs rax, 2
    push rax
    pop  rcx
    pop  rax
    sub  rax, rcx
    push rax
    pop  rdi
    movabs rax, <&fib>
    call rax
    push rax

    pop  rcx
    pop  rax
    add  rax, rcx
    push rax
    pop  rax
    leave
    ret
```

That's the whole JIT.

## Knobs

| Env var          | Meaning                                          |
| ---------------- | ------------------------------------------------ |
| `PUCK_JIT=0`     | Disable the JIT; interpret everything.           |
| `PUCK_JIT_TRACE=1` | Log which procs got compiled.                  |

## What's deliberately missing

- **No register allocator.** Stack-machine codegen via `push`/`pop` to
  the x86 stack is correct but slow vs. real allocators. A real JIT
  would keep stack-top in a register and only spill on branch joins.
- **No type feedback / inline caching.** With one value type there's
  nothing to specialise.
- **No deoptimisation.** Eligibility is a load-time yes/no. If we ever
  wanted to extend the JIT to heap-touching procs, we'd need either a
  deopt path (bail to interpreter on a tag mismatch) or full V_REF
  handling in machine code - both larger by an order of magnitude.
- **No tiering.** Every eligible proc is JITed once at load. There's
  no warm-up counter, no recompile, no inlining.

## Future work

Three categories: making the JIT handle every Puck program, making it
run on every platform, and making the code it emits less embarrassing.

### 1. Full-language JIT coverage

The current eligibility filter rejects 25 of 32 procs in core.puck. Each
item below is what it takes to admit a category:

| Capability | What changes | Rough size |
| --- | --- | --- |
| **V_REF (strings / arrays)** | Value becomes a tagged 16-byte struct in machine code (or, more practically, the JIT keeps refs as raw pointers and lets the interpreter own retain/release at the bridge boundary). Tag checks become real instructions; need a `release()` emit before `RETURN`. | ~150 LOC, plus a runtime ABI decision |
| **Heap allocation (ALLOC, ALLOC_CELL, ALLOC_ARRAY)** | Emit a `call` to the C runtime's `alloc_codepoints` / `alloc_cells`. System V already aligns rsp at JIT entry, so this is straightforward. Need to also retain/release across calls so refcounts stay consistent. | ~80 LOC |
| **ARRAY_GET / ARRAY_SET / ARRAY_LEN** | Native code path: `mov rax, [heap + rcx*16]` then index into the cell array. With proper bounds checks, ~30 LOC each. | ~100 LOC |
| **LOAD_REF / STORE_REF (VAR params)** | The local slot now holds a HeapRef whose target is the box's first cell. One extra indirection per access. | ~40 LOC |
| **SYSCALL** | Trampoline: pop args into argv-style buffer, call the interpreter's `handle_syscall`, push the result. Easy if we accept a C call per SYSCALL. | ~30 LOC |
| **PUSH_FLOAT / float math** | xmm0/xmm1 instead of rax/rcx; `addsd`, `subsd`, `cmpsd`, `cvttsd2si`. Doubles every emit case for math. | ~120 LOC |
| **>6 params** | Spill params 7+ from the caller's stack frame (`[rbp+16+8*i]` per System V) into slots in the prologue. CALL emit pushes extras before `call`. | ~25 LOC |
| **Deoptimisation** | Without this, the JIT can't speculate. With it, we can JIT untyped procs assuming V_INT and bail to the interpreter at the first tag mismatch. Needs side tables mapping native PC -> bytecode PC -> live local set. | ~200 LOC, plus testing |

Total full coverage: roughly **+750 LOC on top of the current 380**. Still
smaller than most JITs because there's only one shape of value, one
calling convention, and no type-feedback profiling.

### 2. Platform expansion

| Target | What changes | Rough size |
| --- | --- | --- |
| **Intel macOS** | Alias `MAP_ANONYMOUS` to `MAP_ANON`. Relax the `#ifdef`. System V calling convention and `mprotect` are identical to Linux. | ~5 LOC |
| **FreeBSD / OpenBSD / NetBSD** | Should just work with the Linux code path; relax the `#ifdef`. | ~2 LOC |
| **Windows x86_64** | Swap `mmap`/`mprotect` for `VirtualAlloc`/`VirtualProtect`. Change the prologue's arg-reg spill list to the Windows x64 ABI (rcx/rdx/r8/r9, then stack). Also reserve 32 bytes of shadow space on every CALL. | ~15 LOC |
| **Apple Silicon (ARM64)** | New ISA, new encoder. Mostly a 1-to-1 translation of the snippet table (ARM64 has `ldp/stp`, `ret`, conditional `b.cond`, etc.). Sign of life: emit `add x0, x0, x1` for MATH +. mmap with `MAP_JIT` + `pthread_jit_write_protect_np` for the W^X dance on Apple Silicon. | ~400 LOC |
| **Linux ARM64** | The encoder above, without the Apple W^X dance. | ~350 LOC if Apple is already done |
| **RISC-V 64** | Another full encoder. The ISA is regular enough that this is genuinely smaller than ARM64. | ~300 LOC |

### 3. Easy wins (orthogonal cleanups)

These don't change what the JIT compiles, just how well:

- **Tail-call optimisation.** When the bytecode is `CALL X; RETURN`, emit
  `add rsp, locals*8; pop rbp; jmp X` instead of `call X; pop rax; leave;
  ret`. Linear-recursive procs (factorial, sum, etc.) get a constant-stack
  loop for free. ~40 LOC in the emitter; biggest user-visible win after
  the JIT itself. Doesn't help fib (both calls are non-tail) but does help
  every Puck program that uses recursion the way Algol-family languages
  encourage.

- **`disp8` for slot access.** When `slot < 16`, the LOAD/STORE encoding
  shrinks from 6 bytes to 3 (`disp32` -> `disp8`). For fib (6 LOADs, 0
  STOREs), that's 18 bytes saved per recursion. Cuts code page footprint
  ~40% on typical procs. ~10 LOC of branching in `emit_load_slot` /
  `emit_store_slot`.

- **Small-int immediates.** `PUSH n` for `|n| < 2^31` currently emits 11
  bytes (`movabs rax, imm64; push rax`). The 5-byte `push imm32` form
  sign-extends to 64 bits, perfect for the common case. ~10 LOC.

- **Peephole pass over emitted bytes.** Common patterns:
  - `push rax; pop rcx` (~22 bytes total) -> `mov rcx, rax` (3 bytes).
    Happens after every MATH/COMPARE that feeds another MATH/COMPARE.
  - `movabs rax, K; push rax; pop rcx` -> `mov rcx, K`. Saves 8 bytes per
    constant arithmetic operand.
  - `setcc al; movzx rax, al; push rax; pop rax; test rax, rax; jz L` ->
    `j<inverted cc> L`. Eliminates the boolean materialisation that
    immediately gets consumed by a JUMP_IF_FALSE. This is the single
    biggest win for IF-heavy code.

  ~80 LOC total. A real register allocator would also subsume these, but
  a peephole pass is the 10x-less-effort version.

- **Per-proc code sizing.** Each proc currently gets a full 4 KB page
  whether it's 50 bytes or 3 KB. For programs with many procs, this is
  wasteful. Either pack multiple small procs onto one page or use a
  bump allocator with one shared executable region. ~30 LOC.

- **`call rel32` for self-recursion.** Self-calls currently go through
  `movabs rax, addr; call rax` (12 bytes) like cross-proc calls. For
  self-calls we know the address relative to the call site at emit time,
  so a 5-byte `call rel32` works. ~15 LOC and ~7 bytes saved per
  recursive call site - useful when one hot proc is its only caller.

### 4. Compiler-side wins (not JIT-related, but adjacent)

- **`read_file` is O(n²).** `compiler.puck`'s file reader uses repeated
  `concat()`, allocating a fresh codepoint array per line. Replace with a
  single growable buffer that doubles on overflow (`list_push` style). ~30
  LOC; dominates wall-clock for any compiler.puck run over more than a few
  hundred lines.

- **String-pool intern is O(n²).** Each new string interns by linearly
  scanning the pool. A hash table - or even a sorted vector with binary
  search - turns this into O(log n). ~50 LOC.

- **Bytecode is plain text.** `.puckc` parses ~3 MB/s because every line
  goes through `sscanf`. A length-prefixed binary format (still a
  one-page spec) would load >100x faster. ~150 LOC each side.

### 5. Things worth knowing about but explicitly out of scope

- **Source-level type *enforcement*.** Puck values are already typed —
  every value carries a runtime tag (V_INT / V_FLOAT / V_REF), every
  bytecode op deterministically produces one tag, and the eligibility
  filter is already a static type analysis over bytecode shape. What's
  missing is an AST pass that rejects type-incoherent *source* like
  `LEN(5)` (currently compiles cleanly and segfaults at runtime when the
  int gets dereferenced as a heap ref). That's a correctness win for
  the language but wouldn't change the JIT — the JIT already infers
  and trusts the same facts from bytecode shape.
- **GC.** Refcounting is fine for the tutorial, but a moving collector
  would force a stack-walking discipline on the JIT (Sigil-rooted
  pointers, safepoints, etc.). Out of scope until/unless the language
  picks up cycles.
- **Multithreading.** The interpreter is single-threaded; the JIT
  inherits that. Real parallelism needs at least a per-thread heap
  and atomic refcounts.
