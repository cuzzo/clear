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

## Representation Invariants

There is a strict boundary between VM internals and guest CLEAR values.

The VM may use whatever representation is best for its own machinery:

- register files may be `Int64[]`, `Float64[]`, or other dense typed arrays
- frame metadata may be arrays/lists of offsets, return addresses, and slot counts
- struct and union layout may be fixed slots or typed field arrays
- constant pools, dispatch tables, and object tables may use VM-specific layouts

Those are implementation details of the VM. A CLEAR `STRUCT` is not a `HashMap`, and the VM
does not need to model it as one.

Guest CLEAR runtime types must keep CLEAR runtime semantics:

- `HashMap`, `@list`, `@pool`, `@set`, strings, owned values, and promoted values must use
  the same runtime behavior as compiled CLEAR code
- `@shared`, `@local`, `@locked`, `@writeLocked`, and other capability-bearing values must
  preserve the same synchronization, ownership, allocator, and cleanup semantics
- `BG`, `DO`, `CONCURRENT`, `NEXT`, streams, `WITH`, and related concurrency constructs must
  call through the same actual runtime constructs that compiled CLEAR code uses

The VM must not replace a guest `HashMap` or guest `[]@list` with a faster shadow
implementation just because it is convenient for the interpreter. If a guest operation would
exercise a CLEAR runtime structure in compiled code, the VM path must exercise that same
runtime contract. If that support does not exist yet, the correct behavior is pending /
`NOT_SUPPORTED`, not a semantically different shortcut.

## Active Path: Bytecode VM

The active execution path is the bytecode compiler + `_bc_runner.clear`.

`bc_emitter.rb` compiles a verified `MIR::Program` (post-MIRChecker) to bytecode.
`_bc_runner.clear` is the CLEAR program that implements `exec!` -- the bytecode interpreter.

All collection types (HashMap, @set, @list) in `_bc_runner.clear` use the native CLEAR
`CheatLib.*` implementations via the same API surface as user programs.

## Running Tests

Run the VM test suite:

```bash
ruby examples/minivm/run_tests.rb
```

Run the stack/register golden harness:

```bash
ruby examples/minivm/run_tests.rb --golden
```

Check or update bytecode snapshots:

```bash
ruby examples/minivm/update_vm_golden.rb --check
ruby examples/minivm/update_vm_golden.rb --target stack
```

Run a single CLEAR program on the MiniVM:

```bash
ruby examples/minivm/clear run path/to/file.clear
```

Run a single program through a specific bytecode VM target:

```bash
ruby examples/minivm/bc_run.rb examples/minivm/fib21.clear --run --vm=stack
ruby examples/minivm/bc_run.rb examples/minivm/fib21.clear --run --vm=register
```

Run the register transpile-test allowlist:

```bash
./clear test --vm=register
```

Compare stack/register bytecode compile and run behavior over the register
allowlist:

```bash
ruby examples/minivm/bench_vm.rb --run
```

Compare the VM benchmark corpus. The benchmark allowlist covers the current
register-supported `benchmarks/vm` corpus. Benchmark execution uses optimized
VM runners by default and reports process wall time, program-emitted
`BENCH_RESULT` timing, and sibling Ruby/Python/Lua timings when available:

```bash
./clear bench --vm=register
```

For direct stack/register timing outside the harness, set `BC_OPT=1` so
`bc_run.rb` uses the optimized `vm_opt` / `_bc_runner_opt` runners. Unset
`BC_OPT` runs the debug VM binaries and is not a valid performance comparison.

Run the full VM benchmark corpus, including register-pending cases:

```bash
./clear bench --vm=register --all-vm-bench
```

## Register VM Optimization Backlog

The register VM optimization path is intentionally staged so performance work
does not obscure semantics or drift from the runtime invariants above.

Already in place:

- register bytecode emits typed register operations instead of stack operations
- the register runner is a CLEAR VM in `vm.clear`, not a Ruby interpreter
- register opcodes are predecoded into the dense `RegisterOp` enum
- dispatch uses a full `MATCH` on `RegisterOp`, which the optimized compiler can
  lower to a jump table
- Ruby-side opcode metadata is centralized in `register_opcode_layout.rb` and
  validated against the `RegisterOp` enum before register VM tests/runs
- the pipeline has explicit optimizer and allocator/rewriter stages

Known near-term optimizations:

- profile the benchmark corpus by opcode frequency, bytecode size, register
  pressure, allocation counts, and per-case slowdown vs Lua/Ruby/Python
- use `TIGHT WHILE` / `TIGHT FOR` in VM hot loops where scheduler fairness and
  per-iteration arena restoration are not required
- strengthen peepholes: remove self-moves, remove jumps to the next instruction,
  thread jump-to-jump chains, fold branch targets, and later fold constant
  compare/branch shapes when constants are available to the pass
- improve register allocation/rewrite: use liveness to reduce frame sizes,
  avoid high register indexes, reduce move pressure, and verify rewritten
  bytecode stays equivalent with golden snapshots
- compact bytecode storage. A direct `Int64[]` -> `Int32[]` swap is not enough
  because CLEAR list indexes and register offsets are currently `Int64`-shaped;
  a useful version should be a packed instruction/operand format that avoids
  adding casts to every operand read

Deferred optimizations:

- superinstructions for hot opcode pairs/triples such as loop increment +
  compare + branch, list/hashmap numeric loops, and native string call patterns
- ICALL/FCALL specialization for fixed arity and monomorphic call sites
- true direct threading / CPS dispatch, where bytecode or decoded instructions
  carry direct successor labels instead of always returning through the central
  dispatch point

Direct threading is expected to be a general dispatch win, but it should be
measured after the cheaper representation and peephole work above. If profiling
shows dispatch remains a dominant cost, it becomes the next optimization target.

## Adding a New Opcode

The register VM has four moving parts when adding an opcode. Touch all four
or the new opcode is silently broken in some configuration.

### 1. Opcode layout (`register_opcode_layout.rb`)

Append to `OPCODES` and `OPERANDS_BY_NAME`. The next free `code:` integer
slot is the trailing one (Operand stays last). Operand kinds in `OPERANDS_BY_NAME`
drive register liveness, register-rewrite, and packed-encoding logic — be precise
about `:i_def` / `:i_use` / `:f_def` / `:f_use` / `:s_def` / `:s_use` / `:const`
/ `:target` / `:argc` / etc.

### 2. Bytecode emitter (`register_bc_emitter.rb`)

The emitter walks MIR nodes and calls `emit(opcode, ...operands)`. Add the
emit case in the appropriate `compile_*` path. `emit()` automatically attaches
the current `(source_line, source_column)` from `@current_source_line` /
`@current_source_column`, so new opcodes get position metadata for free.

If the new opcode declares a binding, call `record_var_name(kind, virt, name,
type_name)` with the user-facing CLEAR type ("Int64" / "Float64" / "String" /
"Bool"). The names table picks up the `(source_line, source_column,
end_source_line, type_name)` columns automatically.

### 3. Decoder + arity tables (`vm.clear`)

Three places to extend:

- `decodeRegisterOpcodes!` — one new arm in the per-opcode `MATCH` so the
  packed-encoding decoder advances the cursor past your opcode's operands.
- `registerOpArity` — the runtime arity returned for IP-step calculations.
- The dispatch loop's `MATCH opcode START` body — the actual implementation.

### 4. Dispatch arm + trace recording (`vm.clear`)

Each register-writing arm follows this pattern:

```clear
RegisterOp.IConst ->
    # ICONST dst const_idx
        dst = ops[ip]; ip += 1;
        constIdx = ops[ip]; ip += 1;
        slot = iBase + dst;                          # 1. compute slot
        oldVal = iregs[slot];                        # 2. capture old value
        iregs[slot] = getRegisterConstInt(consts, constIdx);  # 3. write
        IF recordingActive == 1_i64 THEN             # 4. conditional record
            traceEvents.append(TraceEvent{
                step: step, kind: 1_i64, slot: slot,
                iBefore: oldVal, iAfter: iregs[slot],
                fBefore: 0.0, fAfter: 0.0, ip: instructionIp
            });
        END,
```

The pattern is verbose by design — it's inlined rather than hidden behind a
helper FN because a `MUTABLE @list` parameter currently doesn't get its
escape-promotion across file boundaries (`register_debugger.clear` is REQUIREd,
not same-file). Caller's `traceEvents` cleanup uses `frameAlloc` while a
helper's append would use `heapAlloc`, producing a double-free. Once
escape analysis sees cross-file callees (a follow-up to the importer
FunctionSignature reconstruction), the inline block can collapse to:

```clear
traceIWrite!(traceEvents, step, slot, oldVal, iregs[slot], instructionIp,
             recordingActive) OR RAISE;,
```

The helper functions are pre-declared in `register_debugger.clear`
(`traceIWrite!` / `traceFWrite!` / `traceSWrite!` / `traceAlloc!`) so the
migration is one-pass `sed` over the dispatch arms when cross-file escape
analysis lands.

### Kind codes (TraceEvent.kind)

| kind | meaning | event fields used |
|------|---------|-------------------|
| 1    | ireg write | `slot`, `iBefore`, `iAfter`, `ip` |
| 2    | freg write | `slot`, `fBefore`, `fAfter`, `ip` |
| 3    | sreg write | `slot`, `iBefore`/`iAfter` (indices into `traceStrings`), `ip` |
| 4    | container alloc | `slot` (container kind: 1=list, 2=flist, 3=map, 4=nmap), `iBefore` (alloc_id), `ip` |

### Container alloc pattern

If the new opcode allocates a container (LNew / MNew / LFNew / NMNew style),
also bump `traceAllocId` and record a kind-4 event after the allocation:

```clear
IF recordingActive == 1_i64 THEN
    traceAllocId = traceAllocId + 1_i64;
    traceEvents.append(TraceEvent{
        step: step, kind: 4_i64, slot: 1_i64,        # 1 = list
        iBefore: traceAllocId, iAfter: 0_i64,
        fBefore: 0.0, fAfter: 0.0, ip: instructionIp
    });
END,
```

### Tests for new opcodes

- Unit (`spec/minivm_register_pipeline_spec.rb`) — opcode encoding /
  decoding, operand-kind metadata, register def/use sets.
- Integration (`spec/minivm_register_debugger_spec.rb`, tag `:integration`)
  — drive a small CLEAR program that exercises the opcode through the
  runner. The runner build is cached, so a clean test takes ~5s.
- Source-line attribution (`spec/minivm_register_source_lines_spec.rb`) — if
  the new opcode declares bindings, add an assertion that the binding rows
  carry the right `source_line` / `source_column` / `type_name`.
