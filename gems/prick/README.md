# prick: not all coverage gaps are equal.

 * A flat "673/2732 uncovered" is unactionable. prick categorizes
   every dark branch arm and tells you which to delete, which to
   accept, which nil-kill should resolve, and which are GENUINE gaps
   where bugs are highly likely.
 * The capstone over decomplex / fix-cache / nil-kill: it OWNS gap
   categorization and CONSUMES fix-cache's churn (and an optional
   nil-kill verdict). It re-derives nothing.

## The categories

| category | what to do |
|---|---|
| `type_norm` | likely removable — confirm with nil-kill (a typed contract kills the cluster) |
| `dead` | decision never executes — audit & delete (complexity down) |
| `defensive` | inert / invariant-pinned — accept, drop from the denominator |
| `ffi` | extern/require/module — a few targeted `.cht` |
| `diagnostic` | raises — one negative unit spec |
| `genuine` | the REAL gap — test it; in churn-hot code = **bug highly likely** |

The headline signal: **`genuine` × fix-churn = "bugs highly likely
HERE"** — the small slice actually worth your time.

## Usage

```
prick report --repo=. --coverage=coverage/.resultset.json \
                  --output=report.md
prick report --files=src/mir/mir_lowering.rb     # specific files
```

Needs `coverage/.resultset.json` (SimpleCov `enable_coverage :branch`)
and a git repo (for the fix-cache churn overlay). See
[report.md](report.md) for a demo over CLEAR's lowering passes.

## What it found on CLEAR

935 dark arms across the 3 lowering passes: only ~29% genuine, ~33%
diagnostic, ~24% type_norm (→ nil-kill), ~7% dead (→ delete). The
"bugs highly likely" #1 is `src/mir/mir_lowering.rb` (187 genuine ×
top churn) — and its top sites are `hoist_alloc` /
`owned_value_temp_needs_cleanup?`, the exact methods that produced
real bugs B1–B4. The synthesis points at real bugs.

## What it is NOT

 * Not a re-implementation. It consumes fix-cache; it does not compute
   churn or type pressure itself.
 * Not a verdict. Categories are ranked candidates (Engler
   discipline). v0 precision caveats — `diagnostic` over-greedy,
   `type_norm` under-counted (no intra-proc local resolution yet) —
   are documented in [docs/agents/design.md](docs/agents/design.md).
   The bug-likely join is the sound, validated part.

## Links

 * [Design, categories, boundary, caveats](docs/agents/design.md)
 * [Demo report](report.md)
