# CLEAR MiniVM

`examples/minivm` is a self-hosted CLEAR VM/compiler playground. It is useful both as:

- a deep integration test for CLEAR language/runtime features
- a prototype for the production VM work planned after `v0.1`

## Current State

The MiniVM currently has two execution paths:

- tree-walker interpreter
- bytecode VM with a bytecode-first runner and fallback logic

The important point is that these paths are **not at the same maturity level**.

## What To Treat As The Real Test Surface

The primary correctness target is:

```bash
./examples/minivm/clear test examples/minivm/interpreter_test.cht
```

That file is the actively maintained regression suite for:

- core evaluation
- bytecode execution
- typed arrays
- FFI bridges
- struct-field bytecode ops
- cross-module `REQUIRE` behavior

If that passes, the MiniVM is in its expected working state.

## Historical Compliance Runner

There is also a historical compliance runner:

```bash
ruby examples/minivm/run_tests.rb --historical
```

That script exercises a broad subset of `transpile-tests/` through:

- `scheme_transpiler.rb --run`
- bytecode-first execution
- S-expression fallback

This runner is useful for exploration, but it is **not** the authoritative bar for current MiniVM correctness. Some entries in its old `KNOWN_PASSING` list are aspirational or stale relative to the current implementation work.

Use it as:

- a smoke/discovery tool
- a way to find promising next compatibility targets
- not as the single source of truth for whether MiniVM is "working"

## Recommended Commands

Primary regression check:

```bash
./examples/minivm/clear test examples/minivm/interpreter_test.cht
```

Run a single CLEAR program on the MiniVM:

```bash
ruby examples/minivm/clear run path/to/file.cht
```

Emit Scheme S-expressions:

```bash
ruby examples/minivm/scheme_transpiler.rb path/to/file.cht
```

Try the broader historical compliance set:

```bash
ruby examples/minivm/run_tests.rb --historical
```

## Notes

- `scheme_transpiler.rb --run` is intended to use bytecode first and fall back when needed.
- The fallback/parser path is still an active area of stabilization.
- If you are debugging recent MiniVM work, prefer starting from `interpreter_test.cht` before expanding to the historical compliance runner.
