# StateMesh — visualize the most important state and how messy it is

## Why this exists

CLEAR's compiler has a documented single-source-of-truth contract: a
decision is computed once, stamped on an AST node or SymbolEntry, and
every downstream pass reads the stamp. In practice, the decision is
re-derived at N use sites, or co-written state drifts (`.storage`
without `.provenance`), or state is written by one pass and read by
another with no guard that the writer has run.

The existing decomplex detectors find fragments of this:
- **CoUpdate** finds attr writes and flags missing co-writes
- **Missing Abstractions** finds re-derived guard tuples
- **DerivedState** finds `b = f(a); a = ...; use b` staleness
- **Convergence** cross-references all detectors

But none of them answers the question that keeps causing real bugs:
**which piece of state is the most tangled?** Which field has the
highest ratio of readers to writers, the most scatter, the most
re-derivations, in the files with the highest fix-churn?

**StateMesh** answers: "Here is every state field, ranked by how messy
it is. Start with this one."

## What is *messiness*

```
messiness = (writes + reads + re_derivations) x scatter x fix_churn
```

A state field that is:
- **written** in many places (multiple passes stamp it → co-write drift risk)
- **read** in many places (wide blast radius when the stamping convention changes)
- **re-derived** instead of read (violations of the single-source-of-truth contract)  
- **scattered** across many methods (no single owner → ownership ambiguity)
- **in files with high fix-churn** (boobytrap signal: this area keeps needed fixing)

...is the highest-probability place for the next memory-safety bug.

## Goal

For every attr/ivar that carries program state (as opposed to local
scratch or option parsing), produce a ranked table of **messiness**
with per-field drill-down showing every write site, read site, and
re-derivation site. Equip triage to see, in one view, "here is the
state that has no owner, is re-derived in 14 methods, and lives in the
most-fixed files."

Non-goals: it does not claim a field is *incorrectly* designed (the
messiest field may be fine — low false-positive is a goal, but verdicts
are not). It does not auto-fix anything.

## How it works

### Phase 1: Discover state fields

Scan every (file, method) for ATTRASGN (`obj.attr = val`) and IASGN
(`@attr = val`). Group by normalized attr name (strip receiver, keep
the symbolic field: `.storage`, `@provenance`, `.takes`, etc.).
Output: candidate state fields with at least N writes (default 2).

A field with exactly one write across the entire codebase is not
"state" — it is either a one-shot initialization or a local variable
in disguise. Threshold excludes these. (The `--custom-fields` override
exists for manual audits.)

Alternatively, the caller supplies `--fields=storage,sync,provenance`
to analyze specific fields regardless of write frequency.

### Phase 2: Find all write sites

Reuse decomplex's CoUpdate `walk` method (already finds every
ATTRASGN and IASGN). For each discovered/requested field, collect:

```
{ file, defn, line, span, receiver_pattern }
```

The receiver pattern (`sym.`, `node.`, `self.`, `entry.`) is tracked
so the report can distinguish "this field is written on different
object types in different passes" — itself a messiness signal.

### Phase 3: Find all read sites

New walker, counterpart to CoUpdate's write walker. Walks every CALL
node. If the call is to a method whose name matches the field and is
not `attr=` (i.e., it's `.storage`, not `.storage=`), record it as a
read:

```
{ file, defn, line, span, receiver_pattern }
```

Skips receiverless VCALL (local variables that happen to match).
Skips calls inside `attr=`-style receivers (reading `.storage` on the
RHS of `.storage = rhs` is noise, not a consumer).

### Phase 4: Find re-derivation sites

The hardest phase. A re-derivation is code that should have read the
field but instead recomputed the information from other sources.

**v0 approach (syntactic):** For each state field, scan for
predicates/guards that produce the same information. Example: if
`.storage` is the canonical "are you heap" signal, then a guard
`ti.heap_provenance?` or `ti.any_sync?` or `!ti.frame?` appearing in
a method that *also* could have read `.storage` is a re-derivation
candidate.

This is the same logic as decomplex's **Reification Misses** detector
(an inline expression equal to an existing predicate's body, not
calling it). Reification Misses already finds `ti.heap?` used inline
instead of `sym.storage == :heap`. The StateMesh detector consumes
Reification Misses where the reified predicate corresponds to a state
field.

**v1 approach (semantic):** After CoUpdate has mapped "these attrs
are written together," measure the DEF-USE distance: how many use
sites BETWEEN the last write and a later read? If the answer is "zero,
the read happens right after the write" → the writer is single-source
in practice. If the answer is "14 other reads in between" → the field
has stale-read risk. This is an intra-procedural reaching-def
computation — intentional v1 boundary, documented below.

**Output:** re-derivation sites per field, counted in the messiness
score but surfaced separately so triage can assess false-positive
rate.

### Phase 5: Compute messiness

For each field:

| Metric | Source |
|---|---|
| `writes` | Phase 2 count |
| `reads` | Phase 3 count |
| `re_derivations` | Phase 4 count |
| `scatter` | distinct `(file, defn)` across write+read+re-derive |
| `write_scatter` | distinct `(file, defn)` for writes only |
| `read_scatter` | distinct `(file, defn)` for reads only |
| `receiver_types` | distinct receiver patterns |
| `fix_churn` | boobytrap score aggregated over all touching files |
| `messiness` | `(writes + reads + re_derivations) * scatter * fix_churn` |
| `pressure` | downstream-consumer count (Phase 3 readers that themselves produce state — recursive) |

**Ranking:** descending by messiness. If boobytrap data is
unavailable, fix_churn = 1 and the ranking degrades to `writes+reads
+ re_derivations) * scatter.

### Phase 6: Render report

One section in the decomplex markdown report. Per-field:

```
## `.storage` — messiness 892 (rank 1/47)

| metric | value | percentile |
|---|---|---|
| writes | 12 | 95th |
| reads | 34 | 99th |
| re-derivations | 8 | 90th |
| scatter | 22 methods | 97th |
| fix_churn | 0.83 | 91st |
| pressure | 47 transitive reads | 98th |

### Top write sites
1. `src/escape_analysis.rb:142` (`stamp_heap!`) — `sym.storage = :heap`
2. `src/annotator.rb:891` — `entry.storage = :shared`
...

### Top read sites
1. `src/cleanup_classifier.rb:312` — `sym.storage == :heap`
2. `src/mir_lowering.rb:411` — `decl_sym&.storage || sym.storage`
...

### Re-derivation sites (not using the field)
1. `src/cleanup_classifier.rb:88` — `ti.heap_provenance?` (should read `.storage`)
...
```

The report includes the **State Heatmap** — a ranked table of every
field with enough signal, so the triager reads one page and knows
exactly where to look.

## Prior art / existing coverage

| What | Who | Gap |
|---|---|---|
| CoUpdate (attr writes) | CoUpdate detector, decomplex | Writes only. No reads, no re-derivations, no scatter ranking |
| DerivedState (`b = f(a)` staleness) | DerivedState detector, decomplex | Intra-procedural only. State field agnostic |
| Reification Misses | Reification Misses detector, decomplex | Finds inline predicates — but NOT joined to the state field they should replace |
| Missing Abstractions | Missing Abstractions detector, decomplex | Finds re-derived guard tuples — but NOT joined to state fields |
| Fix-churn | boobytrap | File-level only. Not state-field-attributed |
| Convergence | Convergence, decomplex | Cross-detector agreement at (file, method) level — closest existing aggregate, but lacks a state-field axis |
| nil-kill FlowGraph | nil-kill | Tracks value flow for types — could be repurposed for general state-flow, but is nil-kill-specific and expensive (runtime + static) |
| nil-kill pressure | nil-kill | Blast-radius propagation per source — the same idea, but for nil/type sources. StateMesh pressure is the same concept applied to state fields |

## Boundaries / honest caveats

### False positive sources (all ranked, all documented)

1. **Initialization patterns.** `@storage = :frame` in a constructor or
   `attr_accessor :storage` that is set-once and read-many has many
   reads but zero re-derivation risk. StateMesh flags it with high
   messiness because it *looks* like a hot field. Triaging by the
   report's per-site drill-down reveals the pattern: all writes are
   in `initialize` or `reset`. A future heuristic ("one writer, many
   readers → low messiness") could suppress this; v0 keeps it visible
   with a `pattern: initialization` tag.

2. **Accessor passthrough.** `attr_reader :storage` generates one
   read site at every call to `.storage` on the owning object. Many
   of these may be in unrelated callers. The scatter metric overcounts
   — a field that is a public API returns through 100 callers is not
   "messy," it is "used." v0 counts this honestly and documents the
   overcount.

3. **Re-derivation is hard to detect syntactically.** If `.storage`
   is the canonical signal, then `!ti.frame?` is a re-derivation —
   but so might be `ti.needs_cleanup?` depending on context. v0's
   syntactic approach flags candidates; triage confirms or rejects
   them. The ranking surfaces the *worst* offenders even with some
   noise; a noisy field at rank 1 that is "actually fine" is still
   informative (a high-access public field should not be ranked #1
   by messiness — if it is, there is a design problem).

### Boundaries

- **Intra-procedural only.** Phase 1-3 (write/read site extraction)
  is whole-program (walks all files). Phase 4 re-derivation is
  intra-method (same as Reification Misses). Phase 5 fix_churn is
  file-level only. Phase 5 pressure (transitive readers) is
  one-hop transitive — it does not compute a full program slice.

- **No points-to / alias resolution.** `node.storage =` and
  `entry.symbol.storage =` are both writes to `.storage` — they
  group together. Distinguishing "which object's storage" is
  receiver-pattern matching only, not alias analysis. The report
  surfaces the receiver patterns for human triage.

- **No data-race detection.** The "messiest" field may be read and
  written in the same thread during different compiler passes, which
  is safe. StateMesh does not claim concurrency safety.

- **No cross-file temporal ordering.** If `src/annotator.rb` writes
  `.storage` and `src/lowering.rb` reads it, StateMesh finds both
  sites but does NOT verify the pass ordering. The MIRChecker is the
  one that enforces temporal invariants (7 invariants); StateMesh
  only measures tangling.

- **Re-derivation detection is v0 syntactic.** The v0 heuristic
  (equal-predicate text matching) is noisy. The v1 semantic approach
  (reaching-def distance between write and read) is strictly more
  precise. Documented as v0/v1 so the reader knows what they are
  getting.

- **Not a type analysis.** StateMesh does not reason about types,
  nilability, or shape. nil-kill owns that axis; StateMesh takes
  its fix_churn overlay from boobytrap and its re-derivation signal
  from decomplex's existing Reification Misses / Missing Abstractions
  — it is a *consumer* of both, never a re-deriver.

## Implementation sketch

### New file: `gems/decomplex/lib/decomplex/state_mesh.rb`

```ruby
module Decomplex
  class StateMesh
    Read  = Struct.new(:attr, :recv, :file, :defn, :line, :span, keyword_init: true)
    Write = Struct.new(:attr, :recv, :file, :defn, :line, :span, keyword_init: true)

    def self.scan(files, custom_fields: nil, boobytrap_scores: nil)
      new(files, custom_fields, boobytrap_scores).scan
    end

    def scan
      # Phase 1: collect all ATTRASGN + IASGN writes (reuse CoUpdate walk)
      # Phase 2: collect all CALL reads (new walker)
      # Phase 3: collect re-derivations (consume ReificationMisses + MissingAbstractions)
      # Phase 4: group by field, compute metrics
      # Phase 5: rank by messiness
    end
  end
end
```

### Extension to `Report` (existing `report.rb`)

Add a new section to `SECTIONS`:

```ruby
["State Heatmap", :@state_mesh, 1,
 "state fields ranked by messiness (writes x reads x scatter x fix_churn) -- " \
 "the single-owner contract visualized"]
```

### Runtime budget

- Phase 1-2: single pass over all files, comparable to CoUpdate (~5s
  over CLEAR's 50k LOC).
- Phase 3: consumes pre-computed ReificationMisses + MissingAbstractions
  findings (already loaded in `Report#run`). Cost: negligible.
- Phase 4: aggregation over grouped arrays (~0.1s).
- Total: negligible addition to the ~11s decomplex runtime.
