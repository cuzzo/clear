# CLEAR MiniVM

`examples/minivm` is a self-hosted CLEAR VM/compiler playground. Its primary purpose is:

- **Debugging CLEAR programs** by running them through a VM that uses the exact same Zig runtime
  as native CLEAR binaries (same CheatLib collections, same String ops, same pool/arena semantics).
- **Auto-generating loom tests** from CLEAR programs.

## Core Design Principle

The VM must use the same underlying Zig runtime primitives as the native compiler, accessed
through the VM layer. It is pointless -- and actively harmful -- for the VM to re-implement
pieces of the Zig runtime. A second implementation diverges from the real behavior and makes
debugging unreliable.

Any operation not yet supported in the bytecode path should error `NOT_SUPPORTED`, not fall
back to a shadow implementation.

## Active Path: Bytecode VM

The active execution path is the bytecode compiler + `_bc_runner.cht`.

`bc_emitter.rb` compiles a verified `MIR::Program` (post-MIRChecker) to bytecode.
`_bc_runner.cht` is the CLEAR program that implements `exec!` -- the bytecode interpreter.

All collection types (HashMap, @set, @list) in `_bc_runner.cht` use the native CLEAR
`CheatLib.*` implementations via the same API surface as user programs.

## Running Tests

Run the VM test suite:

```bash
ruby examples/minivm/run_tests.rb
```

Run a single CLEAR program on the MiniVM:

```bash
ruby examples/minivm/clear run path/to/file.cht
```
