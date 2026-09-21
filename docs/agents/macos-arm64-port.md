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

## Known defect: stack-trace capture on a fiber stack wedges

`compiler/spec/semantic_equivalence_integration_spec.rb` HANGS on macOS, hard:
the generated `zig test semantic-mutant.zig` binary sits at **0.0% CPU
forever**. `sample` shows why -- a `Stream.spawnNew` allocation reaches Zig's
DebugAllocator, which captures a stack trace on every allocation, and the
Mach-O self-unwinder faults partway up:

```
Stream.spawnNew -> Allocator.create -> DebugAllocator.alloc
  -> collectStackTrace -> captureCurrentStackTrace -> StackIterator.next
  -> SelfInfo.MachO.unwindFrameInner -> Dwarf.SelfUnwinder.nextInner
  -> _sigtramp -> debug.handleSegfaultPosix
```

The unwinder segfaults, the segfault handler re-enters the unwinder, and the
process wedges.

Adding `.cfi_startproc`/`.cfi_endproc` to the aarch64 bodies -- which had none,
unlike their x86-64 siblings -- does **NOT** fix it: the hang reproduces with
the identical stack. That CFI is in the tree as correctness hygiene, not as a
fix. A simple allocating program under `--debug-allocator` does NOT reproduce
it either way, so the trigger is narrower than "any allocation": the walk has
to cross a fiber frame.

Until this is understood, macOS is usable for building and running ordinary
programs but NOT for the debug allocator or anything that captures a stack
trace from a fiber.

## Known defect: `zig translate-c` spins

Four `zig translate-c` processes ran at 100% CPU with a flat 32 MB RSS for 72
minutes under parallel specs, though one alone finishes in ~3m19s. This makes
the c-ffi specs unrunnable on macOS.

## Running the Ruby suite on macOS

Exclude both, or it will not finish:

```bash
bundle exec prspec $(ls compiler/spec/*_spec.rb \
  | grep -v c_ffi_ | grep -v semantic_equivalence_integration)
```

## zig can take the machine down; it is capped

A single zig process reached **77.5 GB** on a 96 GB Mac and forced two physical
resets. Darwin does not enforce `RLIMIT_AS` -- `ulimit -v` is rejected outright
and a test process allocated 10 GB straight through it -- so the cap is an
external watchdog. `tools/mem-guard` polls a command's process tree and kills
it; `tools/zig-guard` resolves the real zig and delegates; `clear` routes its
`ZIG` constant through the guard, covering every spawn site. Default cap is a
quarter of RAM, tuned by `CLEAR_ZIG_MAX_RSS_MB` (`0` disables).
