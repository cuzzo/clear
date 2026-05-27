# SlopCop: catches the slop your tests miss.

A flat "673/2732 uncovered" is unactionable. **SlopCop** categorizes
every dark branch arm and gives you the one thing you want: **the top
true gaps to test, ranked by fix-churn.**

It is a **general engine** — it categorizes uncovered branches and
ranks the genuine ones by consumed boobytrap churn. It ships **no
project lexicon**; the only project-specific input (your
external/boundary method names) is caller-supplied via `--ffi`.

## The report

1. **Top True Gaps** — every genuine reachable gap, repo-relative +
   linked, ranked by the file's boobytrap churn score. This is the
   list: "test these, in this order."
2. **Category Summary** — the rest of the dark arms, so you can see
   why most are *not* test targets:

| category | meaning |
|---|---|
| `type_norm` | type/nil guard — likely dead if the contract were strictly typed |
| `dead` | decision never executes in coverage — audit as missing test, or dead code only if static reachability agrees |
| `defensive` | inert / invariant-pinned — accept, exclude from denominator |
| `spurious` | decomplex: redundant/cloned/re-derived decision — refactor or delete, not a test target |
| `ffi` | a caller-declared external/boundary call — needs an integration test |
| `diagnostic` | error/raise path — reachable only by invalid input |
| `genuine` | the real reachable gap — **test it** (ranked by churn × decomplex structural deviance) |

## Usage

```
slopcop report --repo=. --coverage=coverage/.resultset.json \
             --output=report.md \
             --files=src/a.rb,src/b.rb \
             --ffi=my_extern_call,my_boundary_method
```

Needs `coverage/.resultset.json` (SimpleCov `enable_coverage :branch`)
and a git repo (for the boobytrap churn overlay). See
[report.md](report.md) for a demo.

## Boundary

SlopCop **owns** gap-categorization. It **consumes** (read-only,
re-derives nothing): the sibling `boobytrap` gem for churn (it does
not compute churn itself); an optional nil-kill verdict for the
`type_norm` bucket; and optional `decomplex` for the `spurious`
filter (redundant decision → refactor, not test) plus the
structural-deviance amplifier on `genuine` gaps. The **apex** of the
ranked list is the convergence: a gap that is *uncovered AND
historically churned (boobytrap) AND structurally deviant
(decomplex)* — untested, in a bug-prone path, and structurally
suspect. All consumption degrades cleanly if a sibling is absent — and
**loudly**: an unavailable/errored decomplex shows a banner, never a
silent churn-only report that looks healthy. The `decomplex` join is
**span-precise** (an arm is attributed only if its line falls inside
the flagged decision's extent), `(file, method)` fallback marked `†`.
Asymmetric by design: a hard `spurious` exclude requires span
precision; a coarse duplication signal never deletes a gap — the arm
stays testable, flagged `⚠dup?` to verify. Deviance is floored at the
method value so precision never demotes an arm. A ranked candidate,
not a verdict.

Flay Type-2/Type-3 clone pressure flows through decomplex, not through
SlopCop directly. SlopCop only correlates decomplex's published spans
with dark arms.

## Not a verdict

Categories are ranked candidates (Engler discipline). v0 precision
caveats — `diagnostic` is over-greedy, `type_norm` under-counted (no
intra-procedural local→accessor resolution yet) — are documented in
[docs/agents/design.md](docs/agents/design.md). The Top-True-Gaps
ranking is the sound, validated part.

## Links

 * [Design, categories, boundary, caveats](docs/agents/design.md)
 * [Demo report](report.md)
