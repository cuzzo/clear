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
