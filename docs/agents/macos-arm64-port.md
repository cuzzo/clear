# macOS / arm64 port: what works, and what does not

CLEAR builds and runs natively on **arm64 macOS** and on **aarch64-linux** as
of 2026-09-20. It previously built only for x86_64 Linux.

## Build with `--safe` or `--optimized` on macOS

The default self-hosted zig backend grows without bound there -- past 31 GB on
hello world. `tools/mem-guard` caps it; see below.

## What the port fixed

- `switch.S` / `onRoot.S` carry `#if defined(__aarch64__)` blocks that had
  never been assembled: on aarch64 `#` introduces an immediate rather than a
  comment, and `.section .text` is ELF-only. A `SYM()` macro handles Mach-O's
  leading-underscore convention.
- The aarch64 `switch_context_asm` used the WRONG offsets -- `fiber-core.zig`
  packs `x19` at `0x08`, the assembly stored it at `0x10` -- and never saved or
  restored `x29`/`x30`. aarch64's `ret` branches to the link register where
  x86's pops the stack, so the first switch into a fiber returned into the
  `0xCC` Debug stack fill: `Segmentation fault at address 0xcccccccccccccccc`.
  Fibers now seed `.lr` on aarch64.
- `runtime/io-backend.zig` selects the completion ring at comptime: real
  io_uring on Linux, a `poll()`-based `PollRing` over a wake pipe elsewhere
  (Darwin has no eventfd). Not an async backend -- socket submissions report
  `AsyncIoUnsupported`. A kqueue backend drops in behind that interface.

x86_64-linux is provably unaffected: `switch.S` and `onRoot.S` assembled for it
are instruction-for-instruction identical to before, with identical symbol
tables.

## Two macOS defects, both fixed

**A fiber with a null frame pointer sent the stack walker to address 0x8.**
aarch64 walkers follow the frame-pointer chain, reading the saved FP at [fp]
and the saved LR at [fp + 8], so a frame with fp = 0 dereferences 0x8. Fibers
seeded exactly that. Nothing hit it until the walk actually happened, which is
whenever something captures a stack trace -- and Zig's DebugAllocator, which
`zig test` uses as std.testing.allocator, does so on EVERY allocation. The
binary segfaulted and then wedged at 0% CPU in its own signal handler. A fiber
now parks a null frame record { saved_fp = 0, saved_lr = 0 } above its initial
SP and points fp at it, so the walk reads lr = 0 and stops.

Note the misleading part: the same CLEAR source runs clean through
`./clear run --safe`, and ordinary fiber, stream and nested-BG programs all
pass. Only the debug allocator's stack capture triggered it.

**`zig translate-c` spins at 100% CPU forever when its stdout is a PIPE.** Not
the input and not the directory -- the identical command on the identical
fixture in the identical tmpdir finishes in 0.087s from a shell. Measured from
Ruby on the same inputs:

```
system(..., out: File::NULL)   0.06s
system(..., out: <file>)       0.06s, 17675 bytes of correct output
IO.popen(...)  (stdout = pipe) never returns, 99% CPU
```

`c_header_importer` and the semantic-equivalence spec now capture zig's output
through files. If you add a new zig invocation, do the same.

## Adding CFI did not fix the unwinder hang

Worth recording because it looked obvious: the aarch64 assembly had no
`.cfi_startproc`/`.cfi_endproc` while every x86-64 body had them. Adding it did
NOT fix the crash -- it reproduced with an identical stack. The CFI is in the
tree as correctness hygiene; the actual cause was the null frame pointer above.

## zig can take the machine down; it is capped

A single zig process reached **77.5 GB** on a 96 GB Mac and forced two physical
resets. Darwin does not enforce `RLIMIT_AS` -- `ulimit -v` is rejected outright
and a test process allocated 10 GB straight through it -- so the cap is an
external watchdog. `tools/mem-guard` polls a command's process tree and kills
it; `tools/zig-guard` resolves the real zig and delegates; `clear` routes its
`ZIG` constant through the guard, covering every spawn site. Default cap is a
quarter of RAM, tuned by `CLEAR_ZIG_MAX_RSS_MB` (`0` disables).
