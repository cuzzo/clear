# decomplex — design

## Why this exists

CLEAR (a memory-safe compiler) is plagued by three specific
pathologies, all of which have caused real memory-safety bugs
(catalogued as #1/#2/#9):

1. **Redundant state that drifts.** A value is derived from another and
   stored; both are then used; they desync. The codebase even
   *documents* such a pairing — `node.storage = :heap` must be
   accompanied by `ti.provenance = :heap` (CLAUDE.md, invariant #16,
   cases `:heap_ptr_return` / `:assign_escape`). A site that sets one
   without the other is a latent UAF.
2. **Re-derived decisions that should be fixed state.** The same
   predicate (`frame?` ≡ `provenance == :frame` ≡ `storage == :frame`)
   is recomputed at many use sites instead of computed once and
   stamped. This is the direct violation of the project's
   single-source-of-truth contract.
3. **Similar paths, one missing a step.** The same N-step decision /
   action sequence appears in many places; one place omits step *k*.
   Bugs #1 (hoist ordering), #2 (missing `mark_per_iter`), #9 (missing
   wrapped-children descent) are each exactly this.

Coverage and mutation testing find these only *after* a shape reaches
the code. decomplex finds them *structurally, from the decision text
itself*, with no test run — and it independently rediscovered the
branch-coverage P0 cluster, confirming the two approaches converge.

## Goal

Mechanize what CLAUDE.md's authority-boundary table enforces by hand:
a decision should be **named once and read everywhere**. Report, as a
ranked **candidate list** (Engler's discipline — FP is acceptable,
verdicts are not), the places where the codebase re-derives, copies,
or half-applies a decision.

Non-goals: it does not prove correctness of reified-but-wrong logic
(that is mutation/fuzz); it does not replace a type checker; its
output is triaged by a human, never auto-applied.

## Detector catalogue

Status: [x] shipped & self-tested, ⊘ dropped. All planned detectors
are now built; polarity canonicalization ships as a shared normalizer
(`Ast.canon_polarity`) applied inside path-condition and semantic
alias rather than as a standalone report.

| Detector | Plague | Prior art | Status |
|---|---|---|---|
| **case/when dispatch scatter** — identical arm-set recomputed across ≥2 defs, ranked support×scatter | 2 | PR-Miner (Li & Zhou, FSE'05) | [x] |
| **conjunction scatter** — identical `&&` operand-set across ≥2 defs | 2 | PR-Miner | [x] |
| **neglected condition** — a site that is a high-support dispatch/conjunction minus one element | 3 | "Finding What's Not There", Chang/Podgurski/Yang, ISSTA'07 | [x] |
| **co-update / neglected update** — attributes co-written in ≥N methods; a method writes one without the other | 1 | DynaMine (Livshits/Zimmermann, FSE'05); "inconsistent updates" Lu et al. | [x] |
| **predicate-alias cluster** — one-line boolean methods with identical body under ≥2 names | 2 | predicate abstraction, SLAM/BLAST | [x] |
| **reification miss** — an inline expression equal to an existing predicate's body, not calling it | 2 | constructive predicate abstraction | [x] |
| **predicate-alias (semantic)** — `frame?` ≡ `provenance==:frame` via definitional unfolding + co-variation, not exact text | 2 | alias analysis; equivalence by definitional substitution | [x] |
| **path-condition normal form** — `if x; if y; if z` ≡ `if x && y && z`; mine guarded program points, not syntactic ifs | 2,3 | symbolic execution; Chang'07 graph-minor implicants | [x] |
| **guarded-pair / sequence mining** — "after AllocMark, a Cleanup must follow on every path"; the one site that breaks it | 3 | Engler "Bugs as Deviant Behavior" SOSP'01; PR-Miner; JADET (Wasylkowski'07); GrouMiner | [x] |
| **polarity canonicalization** — `if x..else` / `unless x` / `if !x` folded before mining | 1,2,3 | normalization pre-pass in all spec miners | [x] |
| **derived-state def-use** — `b = f(a)`, both feed decisions; flag when only one is refreshed | 1 | program slicing; DynaMine | [x] |
| **Type-3 clone + divergence** — pasted block, one variable inconsistently renamed/dropped | 3 | CP-Miner (Li et al. OSDI'04); DECKARD; CCFinder | [x] |
| **false simplicity** — local syntax understating non-local behaviour: hidden dispatch/mutation/context/IO, callback inversion, metaprogramming, monkeypatch/reopen; one category, support×scatter | 2,3 | Engler "Bugs as Deviant Behavior" (the #8 protocol pair is Broken Protocols above); shallow triggers vs RuboCop/Reek catalogued in [false-simplicity.md](../false-simplicity.md) | [x] |
| **fat union (product-vs-sum)** — `case <disc> when ClassA…` whose arms read mostly variant-invariant members (or members used outside the dispatch); the common core should be a struct + a small union. Measures+ranks the cohesion evidence; **extraction routes to nil-kill** | 1,2 | Fowler "Replace Conditional with Polymorphism"; sum-vs-product / data-clump; nil-kill owns the rewrite | [x] |
| ~~data-clump → value object~~ — **DROPPED**, owned by `nil-kill` (see below) | 1,2 | — | ⊘ |

## Existing systems and why they do not cover this

### Ruby ecosystem (what is already in this repo's toolchain)

- **Flay** — structural code clones at the *node-sequence* level. Sees
  duplicated *code*, not duplicated *decisions*: it will not tell you
  that `{FuncCall, MethodCall}` dispatch is open-coded in 5 methods, or
  that `.storage` is written without `.provenance`.
- **Reek** — smell heuristics (DataClump, FeatureEnvy, ControlCouple).
  Closest is DataClump, but it keys on *parameter lists*, not on
  *fields co-occurring in guards/writes*, and emits no scatter ranking
  or neglected-instance pointer.
- **Flog** — per-method complexity (ABC-like). A count, not a
  structural-duplication or missing-decision signal.
- **RuboCop** — style + a few correctness cops; pattern-based, single
  file, no cross-site frequency mining. Its `Style/Send` (off by
  default), `Style/GlobalVars`, `Rails/Output`, `Security/Open`, etc.
  cover only scattered, binary, differently-framed slivers of the
  false-simplicity category — not one blast-radius-ranked category;
  the gap is catalogued in [false-simplicity.md](../false-simplicity.md).
- **debride** — dead-method detection. Orthogonal (finds *unused*, not
  *duplicated/half-applied*).
- **RubyCritic** — aggregates the above; inherits their blind spot.
- **Pronto / Reek-style PR bots** — delivery, not new analysis.

None of these mine *frequency of a decision across sites* or *the
one site that deviates from a popular decision* — the entire value
proposition here.

### Other languages / research

- **Engler et al., "Bugs as Deviant Behavior"** (SOSP 2001) — the
  seminal idea: code implies beliefs; a belief held at 40 sites and
  violated at 1 is a ranked bug. Our neglected-condition / neglected-
  update detectors are this idea, scoped to dispatch and co-write.
- **PR-Miner** (Li & Zhou, FSE 2005) — frequent-itemset mining over
  program elements; closure of co-occurring elements = an implicit
  rule; violations flagged. Our scatter mining is this.
- **"Finding What's Not There"** (Chang, Podgurski, Yang, ISSTA 2007)
  — neglected conditions via frequent-subgraph implicants. Our
  Hamming-1 detector is the cheap exact case; the graph-minor version
  is the planned path-condition work.
- **DynaMine** (Livshits & Zimmermann, FSE 2005) and Lu et al.
  inconsistent-update studies — co-changed/co-written entities; a
  site updating one without the co-set is a probable bug. Our
  co-update detector.
- **CP-Miner** (Li et al., OSDI 2004) — copy-paste with inconsistent
  identifier renaming, the canonical LLM-pattern-completion bug;
  planned (Type-3 clone + divergence).
- **JADET / Tikanga / GrouMiner** — object-usage and temporal
  API-protocol mining ("must call B after A"); the planned
  guarded-pair/sequence detector, which maps directly onto this
  codebase's MIR pairing invariants (AllocMark↔Cleanup,
  MoveMark-before-move, FrameSave/Restore per loop iteration).
- **SLAM / BLAST predicate abstraction** — canonicalize predicates to
  an equivalence representative before reasoning; the planned semantic
  predicate-alias work, the enabler that makes plague-2 detection see
  through `frame?` vs `provenance == :frame`.
- **Csmith / EMI** — generative differential testing; complementary,
  not overlapping (they find miscompiles given inputs; decomplex finds
  design defects given source).

## Relationship to nil-kill (no overlap by construction)

`gems/nil-kill` (branch `nil-kill-prod`) is a **type-inference and
nilability-elimination** system: Sorbet + z3 static analysis plus
runtime tracing, ranked by *pressure* (resolve one source → N
downstream `&.` / guards / signatures collapse). nil-kill reasons
about **types and nils**; decomplex reasons about **duplicated and
half-applied decisions**. They are complementary, and the boundary is
deliberate:

- **nil-kill owns "a hash/array is secretly a struct/tuple."** Its
  Latent Schema Recovery / Hash-Record Promotion already does this
  decisively — runtime-assisted, pressure-ranked, with producer/
  consumer rewrites and safety blockers. decomplex therefore **does
  not** ship a data-clump → value-object detector; a weaker static-
  only reimplementation would be wasted effort and divergent tooling.
  When decomplex's mining points at "these fields always co-occur,"
  the action is *run nil-kill*, not extend decomplex.
- **Shared philosophy, different objects.** Both rank by blast radius
  (nil-kill *pressure*, decomplex *scatter*). This is intentional
  alignment, not duplication: pressure ranks type/nil sources by how
  many guards vanish; scatter ranks *decisions* by how many methods
  recompute them. A missing-abstraction's value in decomplex *is* its
  scatter (resolve once → N re-derivations collapse) — the same
  prioritisation idea applied to a disjoint target.
- **No shared dependency.** nil-kill pulls Sorbet + z3 + a runtime
  tracer. decomplex stays stdlib-AST-only on purpose (principle 1);
  it must never inherit that weight. If a third tool appears, factor
  a shared AST/site-extraction layer then — not before.
- **Everything else is decomplex-unique.** Neglected condition,
  co-update / inconsistent-update, predicate-alias, reification-miss,
  guarded-pair sequence, path-condition, type-3 clone: none exist in
  nil-kill.

## Why no whole-program CFG or pointer aliasing

This is a deliberate boundary, not an unbuilt feature.

"Aliasing" splits in two. **Pointer/memory aliasing** (do `x` and `y`
reference the same object) is the undecidable-in-practice points-to
problem needing interprocedural CFG + Andersen/Steensgaard — decomplex
**never** needs it. **Decision/predicate aliasing** (`frame?` ≡
`provenance == :frame`) is solved by *canonicalization* over a
predicate-definition graph — definitional substitution, not points-to.
That is the only aliasing decomplex needs, and it is bounded and
dependency-free.

No detector on the roadmap needs an interprocedural CFG. The heaviest
planned machinery is (a) a *guard stack* accumulated during AST descent
for the path-condition normal form (~30 lines, not a CFG), (b) a call
graph restricted to one-line boolean predicates for semantic alias,
(c) *intra-procedural* reaching-defs for derived-state. All bounded,
all single-method or single-purpose, none whole-program.

Three reasons this is correct, not a compromise:

1. **Engler's thesis, reconfirmed here.** Lightweight, unsound,
   statistical intra-procedural mining beats heavyweight sound
   analysis on bug-finding ROI. decomplex rediscovered the
   branch-coverage P0 cluster *and* the `.storage`/`.provenance`
   desync with zero CFG and zero alias — the exact target bugs, by
   set arithmetic.
2. **The sound version exists at the right layer already.** "Every
   AllocMark has a Cleanup on every path" is a whole-program-flow
   property, and `MIRChecker`'s 7 invariants already enforce it on the
   compiled language's MIR. decomplex targets the *Ruby compiler
   source*, where the defect is re-derivation / half-application of a
   decision — a statistical-duplication problem, not a dataflow one.
   A CFG here would reimplement MIRChecker at the wrong level.
3. **The discipline keeps it shippable.** When a detector seems to
   "need whole-program alias to avoid false positives," that is the
   signal to accept the FP and rank (principle 2), or defer to a tool
   that already owns that machinery (Sorbet / nil-kill) — never to
   grow a points-to engine inside a zero-dep AST tool.

## Design principles

1. **Zero runtime deps.** stdlib `RubyVM::AbstractSyntaxTree` only.
   The tool that audits the compiler must not drag a dependency tree.
2. **Ranked candidates, never verdicts.** Every report sorts by
   support/scatter and prints the receiver/location so triage is a
   one-line read. FP is the accepted cost of recall (Engler).
3. **Additive.** Each detector is a separate module + report; adding
   one never destabilises another. v0 stays frozen as v0.1+ lands.
4. **Exact before semantic.** Ship the exact-match form (low FP, no
   alias machinery), prove the pipeline, then layer canonicalization.
   This is why predicate-alias currently reports 0 on the three
   lowering files: `frame?` etc. are *defined* in `src/ast/type.rb`,
   and the inline forms are syntactically different — an honest scope
   limit, reported as 0 rather than faked. It is the concrete driver
   for the semantic-alias and path-condition v1 work.
5. **Self-tested.** A bug detector with bugs is worse than none;
   every detector has `test/*_test.rb` with a positive, a negative,
   and a no-false-positive case.

## Validated findings (on src/mir/{escape_analysis,control_flow,mir_lowering}.rb)

- Missing abstraction, top hit: `{AST::FuncCall, AST::MethodCall}`
  dispatch recomputed across 5 distinct methods — the same cluster the
  branch-coverage triage flagged P0, found with no coverage run.
- Neglected condition: `promote_outer_field_assigns!` dispatches
  `{GetField, GetIndex}` while `{GetField, GetIndex, Identifier}`
  appears 3× elsewhere — `AST::Identifier` neglected in a
  heap-promotion path (bug-#1/#2/#9 signature).
- Neglected update, support 8: `.provenance` / `.storage` co-written
  in 8 methods; `lower_var_decl` and `lower_bind_expr` write `.storage`
  without `.provenance` at *declaration* sites — exactly where
  invariant #16 requires both. Candidate desync surface, surfaced
  algorithmically.
