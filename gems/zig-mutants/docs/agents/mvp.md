# Zig Mutants Runtime MVP

## Goal

Move `gems/zig-mutants` from a credible proof of architecture to a useful
runtime safety tool. This is still not a full `cargo-mutants` clone. The MVP
should make mutation runs repeatable, scalable in CI, and actionable when a
runtime mutant survives.

## 1. Subject Manifest

Use a checked-in JSON manifest:

```json
{
  "subjects": [
    {
      "source": "zig/lib/safety.zig",
      "test_command": "cd zig && zig build test",
      "timeout_seconds": 120
    }
  ]
}
```

The CLI accepts `--manifest FILE`. Explicit `--source` remains supported for
one-off investigation. Manifest entries carry the source, test command, and
timeout so runtime coverage does not depend on tribal knowledge.

## 2. Parallelism / Sharding

Use process-level sharding first:

```sh
zig-mutants run --manifest gems/zig-mutants/subjects.json --shard 0/8
```

Each shard selects mutants by stable discovery index modulo shard count. This
is the right MVP parallel primitive because CI can run shards concurrently
without shared mutable state or a premature threaded runner.

## 3. Survivor Artifacts

For every `survived` or `timeout` mutant, write:

- `metadata.json`
- `mutant.patch`
- `original.zig`
- `mutated.zig`
- `stdout.txt`
- `stderr.txt`
- `repro.sh`

Artifacts default under the run output directory and can be moved with
`--artifact-dir`. The reproduction script reapplies the mutated file inside the
scratch workspace and reruns the exact test command.

## 4. Function-Level Attribution

Discovery records the smallest enclosing `fn_decl` span for each mutant and
stores that function name in the mutant facts. Facts no longer report only
`method: "*"`. File-level evidence remains available through the `file` field,
but triage should start at `file + method`.

## 5. Runtime-Specific Mutators

Keep this set small and high-signal:

- replace `try expr` with `(expr catch unreachable)`
- replace `lhs catch rhs` with `lhs catch unreachable`
- remove standalone cleanup calls such as `.free`, `.destroy`, `.deinit`, and
  `.release`
- remove standalone `.lock` / `.unlock` calls
- weaken atomic orderings such as `.acquire`, `.release`, `.acq_rel`, and
  `.seq_cst` to `.monotonic`
- replace `return error.X` with `unreachable`
- weaken obvious bounds/check `if` guards to `true`
- keep existing assertion weakening for `std.debug.assert`

These are AST-backed mutations. Text matching is only used inside AST-selected
expression spans or callee names.

## 6. Ratchet Mode

Use reviewed mutant facts as the baseline:

```sh
zig-mutants run \
  --manifest gems/zig-mutants/subjects.json \
  --facts /tmp/current.json \
  --ratchet /path/to/reviewed-baseline.json
```

The ratchet fails only on new `survived` or `timeout` mutant IDs that were not
already alive in the reviewed baseline. This lets the runtime move toward hard
gates without blocking on already-triaged equivalent or intentionally deferred
survivors.

## Completion Criteria

- Manifest runs discover subjects without manual `--source` flags.
- Shards are deterministic and non-overlapping.
- Survivors produce reproduction artifacts.
- Facts include function names.
- Facts include `language: zig` and `mutation_kind: invariant` for Lineage
  runtime-safety ingestion.
- New runtime mutators are covered by unit tests and discover real runtime
  mutants.
- Ratchet mode fails on new survivors and passes when the same survivor is in
  the reviewed baseline.

## 2026-07-19 Incremental execution

The next execution layer is complete:

- `--since REV` and `--diff-file PATCH` select only mutations on added or
  modified new-side lines.
- `zig-v2` structural IDs survive line insertions outside the enclosing
  function. The old `zig:` ID remains an internal ratchet alias so the reviewed
  baseline is not invalidated.
- `--mutation-switching` compiles one source schema and directly records which
  standard Zig tests evaluate each mutation point.
- active runs skip tests outside `T(m)` and use `--build-cache DIR` for a
  persistent content-addressed Zig compiler cache.
- static initialization, missing test roots, concurrent custom runners, and
  schema compilation failures all fall back conservatively.
- mutation discovery excludes `test` declarations; test-body mutants no longer
  pollute subject results or Test Miser kill sets.

This implementation does not use LLVM source coverage, Kcov, or DWARF. See
[incremental-switching.md](./incremental-switching.md) for the Mull/Stryker
design and verification evidence.

## 2026-06-15 Runtime Run

Final command shape:

```sh
zig-mutants run \
  --root /tmp/zig-mutants-minroot \
  --manifest gems/zig-mutants/subjects.json \
  --shard N/8 \
  --facts /tmp/zig-mutants-runtime-final/facts/shard-N.json \
  --out /tmp/zig-mutants-runtime-final/work/shard-N \
  --artifact-dir /tmp/zig-mutants-runtime-final/artifacts/shard-N
```

All eight shards exited `0` after raising the FSM subject timeout to 300s. The
timeout increase was needed because each shard validates the full subject
baseline before applying mutants, and the FSM hammer/loom sequence can exceed
180s when eight baselines run concurrently.

Final aggregate:

- selected mutants: 659
- killed: 334
- survived: 222
- timeout: 19
- unviable: 84

High-confidence fixes made from survivor triage:

- Added focused `StackPool` allocation-failure tests. This killed all five
  production `StackPool.alloc` `try`-removal mutants in
  `zig/runtime/fiber-memory.zig`.
- Added `FsmRunQueue` allocation-failure tests.
- Fixed a real `FsmRunQueue.makeArray` OOM leak by freeing `data` when
  `CircularArray` allocation fails.
- Fixed a real `FsmRunQueue.grow` OOM leak by propagating failure to retain
  the old circular array and freeing the new array on that failure path.
- Added control-plane boundary tests for non-lowering overflow,
  underflow-policy gating, and skew detection at the minimum threshold.

Remaining alive mutants are intentionally ratcheted, not declared good:

- atomic-ordering weakenings in `zig/lib/atomic.zig`, `observable.zig`,
  `control-plane.zig`, and FSM queues need targeted loom/sim-atomic models or
  architecture-specific assertions.
- debug stack-origin tracking in `fiber-memory.zig` is compiled out by
  `debug_stack_origins = false`; production `StackPool` paths are now
  load-bearing.
- allocator/OOM survivors in observable/materialization paths need focused
  allocator-failure harnesses.
- frame arena survivors are mostly accounting, boundary, and debug-mode
  variants; core allocation/rewind behavior remains covered.

Reviewed ratchet baseline:

```text
gems/zig-mutants/baselines/runtime-reviewed.json
```

That baseline contains the 241 current alive mutant IDs with category-level
review reasons. New alive mutant IDs should fail `--ratchet`.
