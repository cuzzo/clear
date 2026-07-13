# Puck

Puck is a deliberately small Algol/Oberon-shaped teaching language. The point
of this directory is not the language itself - it's the eleven-version
incremental tutorial that shows how to build one. By the end you have:

- a Ruby pipeline (tokenizer → parser → macro expander → bytecode compiler →
  stack-machine VM) built up across V1-V9,
- a C VM that runs the same bytecode 100-200x faster (V10),
- a minimal x86_64 JIT that adds another ~100x on int-heavy procs (V11),
- a self-hosted Puck-in-Puck compiler that emits `.puckc` for the C VM, and
- a tiny standard library written in Puck on top of all of that.

Start with [tutorial.md](tutorial.md). The eleven version directories
([v1](v1/README.md) through [v11](v11/README.md)) each add one focused
capability with its own README and runnable example.

## The version chain

| Version | What it adds | Lines added |
|---|---|---|
| [V1](v1/README.md) | Minimal tokenizer / parser / compiler / VM. Prints `42`. | ~80 |
| [V2](v2/README.md) | Procedure definition and call. Split into four files. | ~160 cum. |
| [V3](v3/README.md) | `IF` / `THEN` / `ELSE`, conditional printing. | ~230 cum. |
| [V4](v4/README.md) | Math, comparisons, `LOOP` / `EXIT`. FizzBuzz runs. | ~260 cum. |
| [V5](v5/README.md) | Strings as scalar heap refs + refcounting. | ~280 cum. |
| [V6](v6/README.md) | `MODULE` wrapper + a `core.puck` standard library. | ~325 cum. |
| [V7](v7/README.md) | `MACRO` definitions / expansion. `WHILE`, `FOR`, records become library code. | ~400 cum. |
| [V8](v8/README.md) | `VAR` pass-by-reference + general arrays. | ~480 cum. |
| [V9](v9/README.md) | Strings *are* arrays of codepoints. Real SYSCALLs (stdin / file I/O / time / exit / argv). | ~550 cum. |
| [V10](v10/README.md) | Same bytecode reimplemented in C. ~100-200x speedup. | +400 (C) |
| [V11](v11/README.md) | Minimal x86_64 JIT for int-only procs. ~120x more on fib(35). | +~380 (C) |

## What ships alongside the versions

These are not new tutorial chapters - they are application code written on
top of V9's frontend and runnable by V9 / V10 / V11 without modification:

- [`v9/core.puck`](v9/core.puck) - the standard library: string ops, integer/string
  conversion, char predicates, file I/O wrappers, growable lists, an
  open-addressed hash table, `assert` / `check` test helpers. Auto-required
  by every Puck program so the surface language always has it.
- [`v9/compiler.puck`](v9/compiler.puck) - a Puck-in-Puck compiler. Tokenizes,
  parses, and emits the same `.puckc` text format that V10's C VM consumes.
  Build it once via V9, then it itself runs as a `.puckc` under V10 / V11.
- [`v9/core-test.puck`](v9/core-test.puck) - a 78-case test suite for `core.puck`,
  written using `check_int` / `check_string` / `check` from `core.puck`.

## How to run things

The Ruby V9 VM runs `.puck` source directly:

```bash
ruby examples/puck/v9/vm.rb examples/puck/samples/fib.puck
```

The C V10 / V11 VMs read pre-compiled `.puckc`:

```bash
# v10: same bytecode, just a faster interpreter
cd examples/puck/v10 && make && make run-example

# v11: same as v10 plus a JIT
cd examples/puck/v11 && make && make run-bench/fib
```

For a guided walk through what the compiler does to a program at each
pipeline stage, the interactive runner shows side-by-side source / tokens
/ AST / bytecode / VM state (Ruby pipeline only, so V1-V9):

```bash
ruby examples/puck/run.rb v9 examples/puck/samples/fib.puck
```

The same runner has a `compile.rb` cousin
([`examples/puck/compile.rb`](compile.rb)) that snapshots the pipeline
without stepping through execution.

## Sample programs

[`samples/fib.puck`](samples/fib.puck) and [`v11/bench/fib.puck`](v11/bench/fib.puck)
are the canonical demos; the per-version directories ship their own narrative
examples (V1's prints `42`, V4 does FizzBuzz, V7 walks through macro
expansion, and so on).

## The CLEAR-side reference (separate from the tutorial)

Alongside V1-V11 there is a `puck.clear` written in CLEAR (this repo's
in-progress production language) that prototypes a Puck-shaped parser
directly. It exists for CLEAR-language work and is not part of the
incremental tutorial - read the version directories for that.
