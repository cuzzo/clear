# Register VM

The register VM (`examples/minivm/vm.cht` + `examples/minivm/register_*.rb`)
is a parallel CLEAR-hosted VM to the stack VM (`bc-vm.md`). Same goal — a
debugger and visualization platform that runs CLEAR programs through the
real Zig runtime — but built around a register-based bytecode and a
linear-scan allocator instead of a stack machine.

For the user-facing "how to add an opcode" recipe, see
`examples/minivm/README.md`. This document records the design decisions,
the metadata schemas, and the known follow-ups so future work knows what
to preserve.

For the current performance standing vs Lua/Ruby/Python and the ranked
list of remaining optimizations, see `register-vm-performance.md`.

## Why two VMs

Register VMs are easier to instrument for time-travel and visualization
because every register write is a clean `(slot, before, after)` event;
stack VMs amortize across pushes and pops in ways that are harder to
attribute back to source. We took the register-VM detour specifically to
build the visualization metadata pipeline (per-instruction line+column,
binding lifetime, container allocations, type-tagged values) on a smaller
opcode surface, then port the schema to the stack VM later.

The two VMs share:

- The CLEAR frontend (parser, annotator, MIR lowering)
- The Zig runtime (`zig/runtime/`)
- The CheatLib collections, strings, allocator stack
- The diagnostic registry / fixable-errors infrastructure

The register VM has its own bytecode, its own runner binary
(`examples/minivm/vm`), its own optimizer + register allocator pipeline
(`examples/minivm/register_pipeline.rb`).

## Metadata schemas

Every piece of metadata the visualization layer (or LSP) might want is
plumbed through the register VM. Touch these schemas only when extending —
the file format is versioned by field count and the runtime accepts older
shapes for cross-version cleanliness.

### Per-instruction parallel arrays (`bc_run.rb` writes; `vm.cht` reads)

| File | Contents | Width |
|------|----------|-------|
| `_register_ops.rbc`     | Packed bytecode (RBC1 magic + variable-width entries) | varies |
| `_register_lines.bin`   | Source line per opcode/operand position (operand positions = 0) | u32 LE |
| `_register_columns.bin` | Source column per opcode/operand position (operand positions = 0) | u32 LE |
| `_register_consts.txt`  | Constant pool (one per line: `I:N` / `F:N` / `S:len:bytes`) | text |
| `_register_source_paths.txt` | File-id -> source path (one per line) | text |
| `_register_breakpoints.txt`  | Newline-separated instruction-start IPs (set via `BC_PAUSE_ON`) | text |
| `_register_names.txt`   | Per-binding metadata (8 columns; see below) | text |

Lines and columns are kept as parallel arrays rather than packed because
they're consulted by IP. The other text formats are read-once at startup.

### Names table format

```
<funcEntryIp>:<sourceLine>:<sourceColumn>:<endSourceLine>:<kind>:<phys>:<name>:<typeName>
```

| Field | Meaning |
|-------|---------|
| `funcEntryIp`     | First IP of the function the binding lives in. Used by `activeFunctionEntryIp` to scope the snapshot. |
| `sourceLine`      | The CLEAR line where the binding's name becomes live. |
| `sourceColumn`    | The CLEAR column where the binding's name token starts. |
| `endSourceLine`   | The line where the binding goes out of scope (next binding's source_line for the same `(kind, phys)` slot, or `-1` for "until function return"). |
| `kind`            | `i` / `f` / `s` (which register file). |
| `phys`            | Physical register index post-allocation. |
| `name`            | User-facing CLEAR identifier. |
| `typeName`        | "Int64" / "Float64" / "String" / "Bool" / "" (empty when emitter didn't resolve). |

`vm.cht`'s `loadRegisterVarNames!` accepts 5/6/7/8-field rows so traces
captured with older schema versions still parse cleanly.

### TraceEvent (time-travel trace)

```clear
STRUCT TraceEvent {
    step: Int64,
    kind: Int64,
    slot: Int64,
    iBefore: Int64,
    iAfter: Int64,
    fBefore: Float64,
    fAfter: Float64,
    ip: Int64,
}
```

| `kind` | Meaning | Field semantics |
|--------|---------|-----------------|
| 1 | ireg write | `slot=iBase+dst`, `iBefore`/`iAfter` |
| 2 | freg write | `slot=fBase+dst`, `fBefore`/`fAfter` |
| 3 | sreg write | `slot=dst`, `iBefore`/`iAfter` are indices into a parallel `traceStrings: String[]@list` |
| 4 | container alloc | `slot`=container kind tag (1=list, 2=flist, 3=map, 4=nmap), `iBefore`=alloc_id |

String values are split out into `traceStrings` rather than embedded in the
event so the event struct stays uniform Int64-sized, the array stays dense,
and we sidestep the pointer-to-frame-string surprises that were observed
with embedded String fields in the early prototypes.

Recording is opt-in via the `recordingActive` runner-local flag (gated on
debug-active sessions); when off, every record-call is a no-op and the hot
path is unchanged.

## The "five places to touch" rule

A new opcode requires changes in five files. Skipping any of them silently
breaks the new opcode in some configuration:

1. `register_opcode_layout.rb` — opcode code + operand kinds.
2. `register_bc_emitter.rb` — emit case (auto-stamps line+column).
3. `vm.cht::decodeRegisterOpcodes!` — packed-encoding cursor advance.
4. `vm.cht::registerOpArity` — runtime arity for IP-step.
5. `vm.cht`'s dispatch loop — the actual implementation, including the
   inline trace-recording block if the opcode writes a register.

The README (`examples/minivm/README.md`) has the full recipe with code
shapes; this section is just the load-bearing list of touch points.

## Inline trace recording: why not a helper FN

Each register-writing arm carries an inline `IF recordingActive == 1_i64
THEN traceEvents.append(...) END` block. The natural refactor is a helper
FN like `traceIWrite!(traceEvents, ...)`, but that helper crashes today
with a double-free because:

1. The helper FN lives in `register_debugger.cht` (cross-file from `vm.cht`).
2. `register_bc_emitter.rb`'s emitted MIR for the call uses `MUTABLE @list`
   pointer-passing, which the post-`hotfix-list-append-buffer-uaf`
   resolver promotes to `heapAlloc()` for the helper's append.
3. But the caller's `traceEvents` binding stays `:frame` because the
   escape analysis (`src/mir/escape_analysis.rb` Condition 9) only walks
   same-file `fn_nodes`. Cross-file callees aren't visible.
4. Result: the helper allocates the buffer with `heapAlloc()`, the caller
   cleans up with `frameAlloc()`. The frame allocator's `free` is a
   bump-arena no-op, so the heap buffer stays around — until the runner
   exits and glibc detects the double-free during its own teardown.

The fix is to teach `escape_analysis.rb` Condition 9 to walk cross-file
callees by consulting the `FunctionSignature`s populated by the importer
(`src/backends/importer.rb`'s reconstruction). Once that lands, the
helper FNs (already pre-declared in `register_debugger.cht` —
`traceIWrite!` / `traceFWrite!` / `traceSWrite!` / `traceAlloc!`)
become safe to call and the inline blocks collapse to one line per arm.

Until then: keep the inline pattern. It's verbose but uniform, and
adding a new opcode is one copy-paste-and-rename of the existing arms.

## Stack VM port

When the visualization metadata pipeline graduates to the stack VM
(`bc-vm.md`), the schemas above transfer unchanged. The stack VM's
~80 opcodes will need the same per-arm recording block (or the helper
FN if the cross-file escape work has landed by then). The names table
schema, the parallel `_register_lines.bin` / `_register_columns.bin`
shape, and the TraceEvent kind codes are all VM-agnostic — they describe
"a CLEAR program execution," not "a register VM execution."

The single piece that doesn't transfer is the `(kind, phys)` shadowing
math: the stack VM doesn't have physical registers. Bindings there are
stack-slot positions, and the equivalent shadow logic is "the binding
declared most recently for this stack slot." Same shape, different
allocator. The TraceEvent's `slot` field repurposes as stack-slot index.

## Follow-ups

| Work | Cost | Unblocks |
|------|------|----------|
| Cross-file escape analysis (Condition 9 walks imported callees) | small (~20 lines in `escape_analysis.rb`) | Helper-FN refactor of trace recording, much shorter dispatch arms |
| Frame open/close trace events (kind 5/6) | medium (per-kind splits in TraceEvent) | `:rs` correctness across call boundaries |
| Up/down/frame N for the trace cursor | small | Stepping back through earlier frames in the recording |
| `LSP::TraceAdapter` — convert TraceEvent + Span → LSP `Diagnostic` | small (~30 lines, pure Ruby) | Visualization in any LSP-aware editor |
| Stack VM port of the metadata pipeline | medium-large (~250 lines mechanical wiring) | Same debugger feel for the stack VM |

## Language coverage roadmap (2026-05-18)

Transpile-test coverage: **276 / 466 = 59.2%**
(`examples/minivm/register-transpile-allowlist.txt`; `run_tests.rb
--vm=register`). The +27 over the prior 249 were already-passing
tests never given regression coverage, found by bucketing every
non-allowlisted test by failure reason (the sweep below).

### CI status (important)

- The **Register-VM allowlist** CI job is **disabled** (`if: false`
  in `ci.yml`): the register VM compiles `vm.cht` to a native binary
  per run and times out on GitHub-hosted runners. Coverage is
  enforced locally only: `bundle exec ruby
  examples/minivm/run_tests.rb --vm=register`.
- The golden harness's `vm.cht`-binary-executing examples (6 in
  `minivm_golden_harness_spec`, all of `minivm_register_debugger_spec`
  = 19) **skip on CI** (`ENV["CI"]`) for the same timeout reason.
  The in-process Ruby-emitter compile/snapshot tests still run on CI.
- Golden snapshots (`examples/minivm/vm-tests/**/*.{bc,out}`) are
  committed: `.gitignore` `examples/**` had no `*.bc`/`*.out`
  negation, so a fresh checkout (CI) had none and the golden harness
  hard-failed. Negations added; regenerate with
  `update_vm_golden.rb --target all` and commit.

### Empirical failure-bucket map (drive work by this, not prose)

Bucketed all 217 then-non-allowlisted tests by register failure
reason. Highest-impact remaining clusters:

| Cluster | ~Tests | Tracker | Effort |
|---|---|---|---|
| `list of anytype` -- `BG STREAM`/observable pipelines | 27 | #17 | Hard (CPS/coroutine) |
| Non-scalar param types (Int/Float/String/list-helper only) | 9 | #12/#14 | medium |
| `ThunkTrampoline`/`MutualThunkTrampoline` (recursion) | 8 | (new) | medium |
| `Value[]@list` append (struct-lit/.Variant RHS) | 5 | #14 | medium |
| Scalar/nested struct placeholder fields | 5 | #12 | medium |
| `ForStmt` iter shapes beyond ListItems/range/struct_list | 5 | #12/#13 | medium |
| Struct-list-as-struct-field (`orders: ArrayListUnmanaged(T)`) | 5 | #12 | 2 days |
| `DoBlock` parallel branches | 3 | #18 | Hard |
| String/array struct fields ("Int64/Float64 only Tranche 7") | 3 | #12 | medium |
| long tail | ~110 | #12-#18 | large/unscoped |

`101_pipeline_binding` is the canonical #12 hard case: struct-list
struct fields **plus** the full `UNNEST`/`AS $x` pipeline -- not a
single-fix unlock.

### Priority-ordered roadmap (CLI tracker tasks #12-#19)

- **P1** (~36 tests, projects to ~61%): #12 ORDER_BY/INDEX/nested-list
  struct fields (ORDER_BY/INDEX sub-cluster already landed; remaining
  = struct-list-as-field); #13 Pool tail (`pool |> FIND/EACH`,
  SoaPool, pool-as-capture); #14 recursive Value-list/Val[]/Node[].
- **P2** (~20 tests, projects to ~65.5%): #15 CatchWrapper/RAISE/OR
  EXIT error-union runtime (needs new VM opcodes: RAISE, error
  register, error-kind dispatch); #16 Map `.values()`/`.keys()`; #17
  StreamSpawn/observable streams (Hard, CPS -- reuse the FSM universal
  transform, no per-shape emitter); #18 DoBlock (Hard); #19 RawZig
  (OUT OF SCOPE -- CLAUDE.md forbids parsing Zig in the VM).
- Long tail 65.5% -> ~100% (~110 tests) is not itemized.

### "Usable to debug concurrent tasks" scoping

Two orthogonal axes:

1. **Concurrency semantics** -- DONE (R6: real per-cell lock,
   `WITH EXCLUSIVE`, `ON LockTimeout`/`RETRY`, `@shared:locked` cell
   structs, real BG fibers scalar+void, cap-shared-by-id, hammer
   battery). The foundation, ~20-25% of the road.
2. **Deterministic interleaving explorer** -- the headline feature,
   essentially unbuilt; only the observation surface exists
   (`@bg_dispatch_points`/`@shared_events`,
   `run_tests.rb --concurrency-report`). The controllable/replayable
   scheduler + DPOR + deadlock oracle is the critical path and is its
   own multi-week workstream. See
   `examples/minivm/docs/agents/concurrency-and-loom-roadmap.md`.

Language coverage (P1/P2 above) is mostly orthogonal to concurrent
debugging but is the prerequisite for *running* realistic concurrent
programs at all (error handling #15, DoBlock #18, streams #17 are
concurrency-adjacent). Minimum "concurrent-debugger-usable" scope ~=
R6 (done) + #15 + #18 + the interleaving explorer ~= 6-10 weeks,
explorer-dominated.
