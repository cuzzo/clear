# prick: pricks holes in your codebase.

A flat "673/2732 uncovered" is unactionable. **prick** categorizes
every dark branch arm and gives you the one thing you want: **the top
true gaps to test, ranked by fix-churn.**

It is a **general engine** — it categorizes uncovered branches and
ranks the genuine ones by consumed fix-cache churn. It ships **no
project lexicon**; the only project-specific input (your
external/boundary method names) is caller-supplied via `--ffi`.

## The report

1. **Top True Gaps** — every genuine reachable gap, repo-relative +
   linked, ranked by the file's fix-cache churn score. This is the
   list: "test these, in this order."
2. **Category Summary** — the rest of the dark arms, so you can see
   why most are *not* test targets:

| category | meaning |
|---|---|
| `type_norm` | type/nil guard — likely dead if the contract were strictly typed |
| `dead` | decision never executes — audit as dead code |
| `defensive` | inert / invariant-pinned — accept, exclude from denominator |
| `ffi` | a caller-declared external/boundary call — needs an integration test |
| `diagnostic` | error/raise path — reachable only by invalid input |
| `genuine` | the real reachable gap — **test it** (these are ranked above) |

## Usage

```
prick report --repo=. --coverage=coverage/.resultset.json \
             --output=report.md \
             --files=src/a.rb,src/b.rb \
             --ffi=my_extern_call,my_boundary_method
```

Needs `coverage/.resultset.json` (SimpleCov `enable_coverage :branch`)
and a git repo (for the fix-cache churn overlay). See
[report.md](report.md) for a demo.

## Boundary

prick **owns** gap-categorization. It **consumes** the sibling
`fix-cache` gem for churn (it does not compute churn itself) and an
optional nil-kill verdict for the `type_norm` bucket. It re-derives
nothing.

## Not a verdict

Categories are ranked candidates (Engler discipline). v0 precision
caveats — `diagnostic` is over-greedy, `type_norm` under-counted (no
intra-procedural local→accessor resolution yet) — are documented in
[docs/agents/design.md](docs/agents/design.md). The Top-True-Gaps
ranking is the sound, validated part.

## Links

 * [Design, categories, boundary, caveats](docs/agents/design.md)
 * [Demo report](report.md)
