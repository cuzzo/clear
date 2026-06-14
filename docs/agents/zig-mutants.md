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
zig build run -- run \
  --root ../.. \
  --source zig/lib/safety.zig \
  --test-command "cd zig && zig build test" \
  --facts /tmp/zig-mutants.json \
  --out /tmp/zig-mutants-work \
  --max-mutants 25
```

The MVP is sequential and intentionally narrow. Parallel workers, manifests,
package discovery, allowlists, and type-directed function-body replacement are
deferred until this core proves useful.

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

Every mutant records:

- stable ID
- source path
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

1. Discovers mutants from one or more `--source` files.
2. Copies `--root` to `--out` with a tar-based scratch copy.
3. Runs the unmutated `--test-command` as the baseline.
4. Applies one mutant at a time in the scratch copy.
5. Runs a parse viability check.
6. Runs the test command.
7. Restores the original file after each mutant.
8. Emits optional `mutant-facts/v1` JSON.

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
  "subjects": [
    {
      "file": "zig/lib/safety.zig",
      "method": "*",
      "kill_rate": 100.0,
      "gate_status": "advisory",
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
      "kind": "comparison_flip",
      "outcome": "killed",
      "line": 28,
      "column": 12,
      "exit_code": 1
    }
  ]
}
```

The MVP uses `method: "*"` because source-file-level evidence is the reliable
first increment. Function attribution should be added later using AST scope
tracking.

## Deferred Work

Do not do these until the MVP has real survivor data:

- automatic package/import/test-target discovery
- parallel worker directories
- sharding
- allowlist/equivalence database
- type-directed function-body replacement
- integer literal perturbation
- removing `try`
- mutating allocator choices, atomic memory orderings, or lock APIs
- hard CI gate

## Acceptance Criteria

Current MVP is acceptable when:

- `zig build test` passes in `gems/zig-mutants`
- `list` discovers AST-backed mutants on real `zig/lib` or `zig/runtime` files
- `list --json` emits valid JSON on stdout
- `run` kills at least one mutant in a tiny fixture
- `run --facts` emits parseable `mutant-facts/v1` JSON
- the implementation never mutates the developer worktree
