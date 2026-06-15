# Zig Mutants Design

## Goal

Build a Zig-native mutation-testing package for the Zig runtime/lib layer. The
goal is the same as Rust's `cargo-mutants`: a unit test is load-bearing when a
small plausible source mutation makes the test fail, not merely because the test
covers the code.

## Rust Gold Standard

`cargo-mutants` is the model:

- It discovers mutants from parsed Rust source, not regex text scans.
- It runs a clean baseline before any mutant.
- It applies mutants in copied build directories, not the developer worktree.
- It classifies killed/survived/timeout/unviable outcomes.
- It writes durable output that can be consumed by later tooling.

For Zig, the matching design is a Zig package using `std.zig.Ast`. A Ruby token
scanner would be too brittle and would diverge from the Rust architecture we
want to emulate.

## Implemented MVP

Location:

- `gems/zig-mutants/build.zig`
- `gems/zig-mutants/src/lib.zig`
- `gems/zig-mutants/src/main.zig`

Commands:

```sh
cd gems/zig-mutants
zig build test
zig build run -- list --source ../../zig/lib/safety.zig
zig build run -- list --source ../../zig/lib/safety.zig --json
zig build run -- list --root ../.. --manifest subjects.json --json
zig build run -- run \
  --root ../.. \
  --manifest subjects.json \
  --facts /tmp/zig-mutants.json \
  --out /tmp/zig-mutants-work \
  --artifact-dir /tmp/zig-mutants-artifacts \
  --shard 0/8 \
  --ratchet /path/to/reviewed-baseline.json
```

The MVP uses process-level sharding for CI parallelism. In-process worker pools,
automatic package discovery, allowlists, and type-directed function-body
replacement remain deferred until real survivor data proves they are needed.

## Discovery

Discovery uses `std.zig.Ast.parse` and AST node/token spans. It does not scan
comments or strings manually.

Implemented mutators:

- boolean literal flip: `true`/`false`
- comparison flip: `==`, `!=`, `<`, `<=`, `>`, `>=`
- logical flip: `and`/`or`
- `if` condition negation
- `while` condition negation
- `std.debug.assert(expr)` weakening to `std.debug.assert(true)`
- `defer` / `errdefer` removal by replacing the statement with `{};`
- `try expr` replacement with `(expr catch unreachable)`
- `lhs catch rhs` replacement with `lhs catch unreachable`
- standalone cleanup call removal for `.free`, `.destroy`, `.deinit`, and
  `.release`
- standalone `.lock` / `.unlock` removal
- atomic ordering weakening to `.monotonic`
- `return error.X` replacement with `unreachable`
- obvious bounds/check `if` guard weakening to `true`

Every mutant records:

- stable ID
- source path
- enclosing function/method name
- kind
- line/column
- byte span
- original text
- replacement text

Stable ID format:

```text
zig:<path>:<line>:<column>:<kind>:<sha16>
```

## Runner

The runner:

1. Resolves subjects from explicit `--source` flags or a JSON `--manifest`.
2. Copies `--root` to `--out` with a tar-based scratch copy.
3. Runs each subject's unmutated test command as the baseline.
4. Applies one selected mutant at a time in the scratch copy.
5. Skips mutants outside the selected `--shard INDEX/COUNT`.
6. Runs a parse viability check.
7. Runs the subject's test command.
8. Writes survivor/timeout artifacts.
9. Restores the original file after each mutant.
10. Emits optional `mutant-facts/v1` JSON.
11. Optionally enforces `--ratchet BASELINE_FACTS` against new alive mutants.

Outcome taxonomy:

| outcome | meaning |
|---|---|
| `killed` | mutated test command failed |
| `survived` | mutated test command passed |
| `timeout` | command exceeded timeout |
| `unviable` | mutation did not parse enough to test |
| `skipped` | selected out by `--max-mutants` or future allowlists |

## Facts Schema

The facts file intentionally matches existing Boobytrap/SlopCop mutation
evidence:

```json
{
  "schema": "mutant-facts/v1",
  "source": "gems/zig-mutants",
  "language": "zig",
  "mutation_kind": "invariant",
  "subjects": [
    {
      "file": "zig/lib/safety.zig",
      "method": "enter",
      "kill_rate": 100.0,
      "gate_status": "advisory",
      "mutation_kind": "invariant",
      "mutations": 1,
      "killed": 1,
      "alive": 0,
      "timeouts": 0,
      "unviable": 0,
      "skipped": 0
    }
  ],
  "mutants": [
    {
      "id": "zig:zig/lib/safety.zig:28:12:comparison_flip:...",
      "file": "zig/lib/safety.zig",
      "method": "enter",
      "kind": "comparison_flip",
      "outcome": "killed",
      "line": 28,
      "column": 12,
      "exit_code": 1,
      "artifact": "/tmp/zig-mutants-artifacts/..."
    }
  ]
}
```

Subjects are grouped by `file + method`. Mutants outside a named function, such
as test blocks or top-level comptime expressions, use `method: "*"`.

## Deferred Work

Do not do these until the MVP has real survivor data:

- automatic package/import/test-target discovery
- in-process parallel worker directories
- allowlist/equivalence database
- type-directed function-body replacement
- integer literal perturbation
- broader allocator-choice mutation beyond cleanup call removal
- hard CI gate beyond survivor-ID ratcheting

## Runtime Ratchet Status

As of 2026-06-15, the runtime/lib subject manifest lives at:

```text
gems/zig-mutants/subjects.json
```

The reviewed runtime ratchet baseline lives at:

```text
gems/zig-mutants/baselines/runtime-reviewed.json
```

The final 8-shard run over `zig/lib` and `zig/runtime` selected 659 mutants:

- 334 killed
- 222 survived
- 19 timeout
- 84 unviable

High-confidence survivor triage produced two production fixes in
`FsmRunQueue` OOM cleanup and added load-bearing allocation-failure coverage
for `StackPool` and `FsmRunQueue`. Remaining alive mutants are retained in the
ratchet baseline with review reasons. Most are atomic-ordering weakenings,
disabled debug stack-origin code, observable allocator/OOM paths, and frame
arena boundary/debug-accounting variants.

## Acceptance Criteria

Current MVP is acceptable when:

- `zig build test` passes in `gems/zig-mutants`
- `list` discovers AST-backed mutants on real `zig/lib` or `zig/runtime` files
- `list --json` emits valid JSON on stdout
- `run` kills at least one mutant in a tiny fixture
- `run --facts` emits parseable `mutant-facts/v1` JSON
- `run --ratchet` fails only on new alive mutant IDs
- survivor artifacts include a reproduction script and command output
- the implementation never mutates the developer worktree
