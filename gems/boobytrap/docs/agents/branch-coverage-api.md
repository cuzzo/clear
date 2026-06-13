# Language-Neutral Branch Coverage API

Boobytrap owns coverage normalization for both Boobytrap and SlopCop.
Ruby SimpleCov branch tuples, kcov line coverage, and non-Ruby branch
providers should all enter through `Boobytrap::CoverageData`.

## Coverage Levels

- `coverage`: native SimpleCov/Ruby branch tuples.
- `native_branch`: exact branch-arm hit counts from the Nil-Kill branch
  coverage JSON API.
- `kcov`: line hits projected onto Tree-sitter branch arms.
- `tree_sitter_static`: static branch arms when no coverage exists.

`native_branch` is the non-Ruby equivalent of Ruby branch coverage: a
provider reports hits for concrete Tree-sitter branch arms instead of
asking SlopCop or Boobytrap to infer arms from line hits.

SlopCop's dark-arm report and Boobytrap's file branch gaps,
method-level `dark branches`, and state-branch overlays all consume this
same normalized arm coverage. Language support should be added here
rather than by branching inside those reports.

Coverage-backed non-Ruby files automatically use Tree-sitter arm
matching when the language grammar is configured. The global
`DECOMPLEX_PARSER=tree_sitter` switch is still used for static fallback
analysis when no coverage file is present.

## Branch Catalog

Providers should first read a static branch catalog:

```ruby
catalog = Boobytrap::CoverageData.branch_catalog(["src/worker.zig"], root: repo)
```

The catalog shape is:

```json
{
  "schema_version": 1,
  "format": "nil-kill.branch-catalog",
  "root": "/repo",
  "files": [
    {
      "path": "src/worker.zig",
      "language": "zig",
      "digest": "sha256:...",
      "arms": [
        {
          "branch_id": "zig\\u0000src/worker.zig\\u00002:4:6:5\\u0000if",
          "arm_id": "zig\\u0000src/worker.zig\\u00002:4:6:5\\u0000if\\u0000then\\u00002:15:4:5",
          "kind": "if",
          "label": "then",
          "decision_line": 2,
          "decision_span": [2, 4, 6, 5],
          "arm_line": 2,
          "arm_span": [2, 15, 4, 5]
        }
      ]
    }
  ]
}
```

## Coverage Input

A provider emits the same file/arm records with `format` changed to
`nil-kill.branch-coverage` and each arm assigned a hit count:

```json
{
  "schema_version": 1,
  "format": "nil-kill.branch-coverage",
  "root": "/repo",
  "files": [
    {
      "path": "src/worker.zig",
      "language": "zig",
      "lines": { "2": 1, "3": 1, "5": 0 },
      "arms": [
        {
          "arm_id": "zig\\u0000src/worker.zig\\u00002:4:6:5\\u0000if\\u0000then\\u00002:15:4:5",
          "kind": "if",
          "label": "then",
          "decision_span": [2, 4, 6, 5],
          "arm_span": [2, 15, 4, 5],
          "hits": 1
        }
      ]
    }
  ]
}
```

`lines` is optional, but providers should include it when available.
Boobytrap uses line hits for method-level coverage and combines those
with native arm hits for the `dark branches` count.

If a provider cannot consume the catalog, it may omit `arm_id` and match
by `kind`, `label`, `decision_span`, and `arm_span`.

## Zig Status

Zig now works through this API when a runner can emit exact arm hits.
The implemented tests generate a Zig Tree-sitter branch catalog, mark one
arm covered and one arm dark, then verify:

- Boobytrap file branch gaps use the native arm counts.
- Boobytrap method gaps report the dark Zig branch.
- SlopCop classifies the uncovered Zig arm as a `native_branch` dark arm.

The CLI smoke test also renders a Zig SlopCop report with
`Branch source: native_branch=1` and a Boobytrap report with
`branch gap: 1/2` plus `dark branches: 1`, with `DECOMPLEX_PARSER`
unset.

This does not create a Zig runtime instrumentation tool. It defines the
small contract that such a tool needs to emit.

## Adding Python

Python should be straightforward because `coverage.py --branch` already
collects branch/arcs. A Python provider would:

1. Generate the Tree-sitter branch catalog for the target files.
2. Run tests with `coverage.py --branch`.
3. Map coverage arcs to catalog arms.
4. Emit `nil-kill.branch-coverage` JSON.

The hard part is arc-to-arm mapping, not SlopCop or Boobytrap
integration. Once the JSON is emitted, both gems use it through the same
normalization layer as Zig.
