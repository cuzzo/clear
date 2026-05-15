# decomplex: find duplicated and half-applied decisions in your codebase.

 * decomplex is the easiest way to find where your code re-derives a
   decision that should be fixed state, copies state that then drifts,
   or takes a path in many places but misses a step in one.
 * It is pure static analysis on the stdlib AST. Zero runtime
   dependencies, no Sorbet, no z3, no runtime tracing, no whole-program
   CFG, no points-to.
 * decomplex does not rewrite your code. It surfaces, ranked, the
   places most worth a human's attention.

## What is *scatter*?

You can often resolve one missing abstraction and collapse dozens of
re-derivations of the same decision.

`scatter` is how many distinct `(file, method)` decision units recompute
the *same* guard tuple. A guard tuple checked inline in 14 methods with
0 reifications is a missing named decision; resolving it once removes 14
divergence risks. decomplex ranks findings by `support x scatter` so you
spend effort where one fix has the largest blast radius. (This is the
same prioritise-by-blast-radius idea as nil-kill's *pressure*, applied
to a disjoint target: decisions, not types/nils.)

## How well does it work?

CLEAR's compiler is ~50k dense lines of Ruby across 93 source files.
A full run takes ~11s and produced 10,662 ranked candidates, including:

 * **217 missing abstractions** -- top: a union-schema guard tuple
   recomputed across 14 methods with 0 reifications.
 * **129 reification misses** -- an existing one-line predicate
   reinvented inline (direct invariant-#16 violations).
 * **14 type-3 missed-rename clones** -- a pasted block where one
   identifier was inconsistently renamed (the canonical paste bug).

decomplex independently rediscovered the same P0 cluster a separate
branch-coverage triage had flagged, and surfaced the documented
`storage`/`provenance` co-write desync -- both with no test run. The
analysis is structural: it reads the decision text, not execution.

### The ranked-candidate discipline

Output is a **ranked candidate list, never a verdict** (Engler's
discipline: false positives are the accepted cost of recall). The broad
statistical detectors emit thousands of raw candidates over a large
codebase; the value is the rank-sorted *top* of each list, not the
count. Every entry prints `file:method:line` and the offending text so
triage is a one-line read. LLMs work well with this shape of data.

## How do I use it?

```
# Targeted: the two duplication reports on specific files.
decomplex src/mir/escape_analysis.rb src/mir/control_flow.rb

# Full report (markdown, all 10 detectors), like this gem's report.md:
decomplex report src --output=report.md
```

See [report.md](report.md) for a demo of what the full report looks
like (generated over CLEAR's compiler).

### What it looks for

decomplex targets three pathologies that have each caused real
memory-safety bugs in CLEAR (catalogued #1/#2/#9):

 1. **Redundant state that drifts** -- `b = f(a)`, both used, they
    desync; or `.storage` written without its documented `.provenance`
    pair. (CoUpdate, DerivedState)
 2. **Re-derived decisions that should be fixed state** -- `frame?` vs
    `provenance == :frame` vs `storage == :frame` recomputed at N use
    sites instead of named once. (Missing abstractions, semantic
    predicate alias, reification miss)
 3. **Similar paths, one missing a step** -- the same N-step decision
    or co-call protocol in many places, one place omits step *k*.
    (Neglected condition, neglected path condition, broken protocol,
    type-3 clone)

Ten detectors, each grounded in prior art (PR-Miner, Engler "Bugs as
Deviant Behavior", Chang/Podgurski/Yang neglected conditions, DynaMine
inconsistent-update, CP-Miner, JADET, SLAM/BLAST predicate
abstraction). Full catalogue and citations:
[docs/agents/design.md](docs/agents/design.md).

### Reading the report

The report opens with **Project Prioritization** -- detectors ordered
by candidate volume -- then a section per detector with the top 25
ranked entries, then a **Run Summary**. Start at the top of *Missing
Abstractions* and *Reification Misses*: those are the highest-signal,
lowest-false-positive sections and map directly to the
single-source-of-truth contract.

## What decomplex does NOT do

These are deliberate boundaries, recorded in the design doc:

 * **No code rewriting.** It points; a human fixes. (This is the main
   reason it is ~25x smaller than nil-kill.)
 * **No whole-program CFG, no pointer/points-to aliasing.** All
   detectors are intra-procedural or syntactic. "Predicate aliasing"
   (`frame?` vs `provenance==:frame`) is canonicalization, not
   points-to.
 * **No type inference, no nil analysis, no "hash is secretly a
   struct."** That is nil-kill's domain (branch `nil-kill-prod`);
   decomplex defers to it entirely and ships no overlapping detector.
 * **No soundness claim.** It does not prove reified-but-wrong logic
   correct -- that is what mutation and fuzz testing are for.

## FAQ

**Is a flagged item always a bug?** No. It is a ranked candidate. A
neglected condition may be a deliberate, correct special case; triage
top-down and accept or fix.

**Why not just use Flay/Reek/RuboCop?** Those detect duplicated *code*
or smells; none mines the *frequency of a decision across sites* or
*the one site that deviates from a popular decision*. That cross-site
statistical view is the entire value proposition.

**Will it scale to my codebase?** It is single-pass per detector,
stdlib-AST, zero-dep: ~11s for 50k LOC. It stays this small on purpose.

## Links

 * [Design, detector catalogue, prior art, boundaries](docs/agents/design.md)
 * [Demo report over CLEAR's compiler](report.md)
