# Architectural Root-Cause Analysis — Bugs Found This Session

Directive: "Identify where the gaps are that allowed all the bugs
you've found so far. Fix architecturally correctly. Not band-aids."

This separates the findings by **kind** (true CLEAR-compiler bug vs.
register-emitter coverage gap vs. design limitation), names the
**systemic gap** behind each, and states the **architecturally-correct
fix** and honest status. No item is "patched to make one case pass";
where a fix isn't yet justified by a reproduction, that is stated
plainly rather than guessed.

---

## A. CLEAR compiler bugs (src/)

### A1. `ControlFlow.scan_direct` sig contradicted its own contract

- **Bug:** Sorbet `sig` declared `body: T::Array`, but the method
  body opens with `return unless body.is_a?(Array)` and is called
  recursively on `s.else_branch` / `s.default_case` (legitimately
  nil: IF-without-ELSE, PARTIAL-MATCH-without-DEFAULT). Sorbet
  validates params at the call boundary, so it aborted *before* the
  method's own designed guard ran.
- **Systemic gap:** a hand-written `sig` that is stricter than the
  method's intentional, self-documented behavior — and **zero unit
  coverage** of the optional-subtree recursion path, so the
  contradiction sat latent until a reentrant + IF/MATCH shape hit it.
- **Architecturally-correct fix (DONE):** make the sig express the
  real contract (`body: T.nilable(T::Array[...])`); the existing
  `return unless body.is_a?(Array)` IS the intended handling. No new
  logic. **Regression-locked:** `spec/loop_frame_analysis_spec.rb`
  Group G directly exercises `scan_direct(nil)`, IF-without-ELSE,
  and PARTIAL-MATCH-without-DEFAULT; **proven** to fail without the
  fix and pass with it. prspec 4801/0.
- **Class prevention:** audited `control_flow.rb` for the same
  pattern (sig stricter than an internal type/nil guard) — no other
  instance. The durable guard is the new spec, not a grep.

### A2. Reentrant `INLINE_ALLOC_MISMATCH` (UNCONFIRMED — do not fix blind)

- **Observation:** with `runRegisterBytecode!` made `EFFECTS
  REENTRANT` + non-TIGHT + the recursive `BG { ... }` spawn, MIR
  ownership verification reported `INLINE_ALLOC_MISMATCH` on the
  function's own `intListHandles`/`stringListHandles`.
- **Status: NOT minimally reproduced.** Every minimal repro
  (nested-`@list`-in-struct into a heap container, incl. reentrant +
  BG-recursive + indexed in-place mutation) **passes**. The native
  RETURNS-heap escape path provably propagates correctly. So the
  earlier "Condition 7 only promotes string-concats" diagnosis is
  **withdrawn as unproven**.
- **Suspected systemic gap (hypothesis, to verify):** the
  heap-promotion logic in `EscapeAnalysis` is spread across several
  independent conditions (RETURNS / assign-escape / container-mutator
  / concat-into-heap / reentrant-conservative). They are **not
  unified**: the RETURNS path recurses into nested collection fields;
  another path (whatever the giant reentrant body triggers) may not.
- **Architecturally-correct response:** per CLAUDE.md, **reproduce
  before fixing**. Re-apply R2, bisect to the minimal failing
  program, then — if confirmed — the fix is to make heap-promotion
  a single canonical operation that recursively covers nested
  collection fields, applied by ALL conditions, not a new
  per-condition branch. **Explicitly NOT** flattening VM structs
  and **NOT** a Condition-7 band-aid. Tracked in
  `stack-vm-fiber-replication.md` (corrected section).

---

## B. Register-emitter coverage gaps (examples/minivm/, NOT compiler bugs)

The session's many register-VM fixes — TransferMark/FieldCleanupMark
no-op, atomic-receiver `Deref` unwrap, `AddressOf` arg unwrap,
cap-wrapped struct params, WITH-release `DeferStmt` no-op,
`PolymorphicMutate(Flow)`, OR PASS sentinel, value-position
`TryCatch`, `DupeSlice` in `inferred_expr_type`, etc. — are **not**
CLEAR-language bugs. They are the register emitter (built
tranche-by-tranche) not yet handling a MIR shape the lowering
legitimately produces.

- **Systemic gap (real, architectural):** two single-source-of-truth
  violations in `register_bc_emitter.rb`:
  1. **Verification-only marker set is re-listed, not sourced.**
     The authoritative no-op marker set lives in
     `src/mir/mir_emitter.rb:123`
     (`AllocMark/ReturnMark/TransferMark/ReassignMark/
     FieldCleanupMark`). The register emitter hand-maintained a
     *subset*; TransferMark/FieldCleanupMark were missing → a bug.
     Patching them in was a band-aid; the class recurs for any
     marker added upstream.
  2. **No canonical "peel transparent nodes."** `Deref`,
     `AddressOf`, `DeepCopy`, `DupeSlice`, `Cast`-identity are
     value-transparent, but each was handled ad hoc in *some*
     `compile_*_expr` paths and not others (hence the repeated
     "unwrap X here too" fixes across i64/f64/string/value).
- **Architecturally-correct fix (scoped, NOT yet done):**
  1. Derive the register emitter's no-op marker set from the
     authoritative `mir_emitter` list (one constant, shared), so
     "add a verification-only marker" can never desync again.
  2. One `normalize_transparent(node)` applied at the head of the
     expr dispatchers (and stmt dispatch) that peels
     `Deref/AddressOf/DeepCopy/DupeSlice/identity-Cast` uniformly —
     replacing the N scattered per-path `when` arms.
  This is a real refactor of a 6.8k-line file guarded by 245 tests;
  it must be its own verified commit(s), not bundled. Scoped here so
  the architectural debt is explicit instead of hidden behind the
  piecemeal patches already shipped (each of which was individually
  correct + regression-checked, but the *pattern* is the gap).

---

## C. Design limitation (not a bug)

### C1. Guest frame-arena not modeled (vm-bugs.md, OPEN)

The bc VM has no guest frame arena; `frame_peak`/`loop-arena`
tests only ever passed via an incidental `--stack-check` stack-tier
coincidence. Correctly **filed OPEN**, gate **decoupled** (not
band-aided green), faithful-arena fix scoped as P0. This is a
known design limitation, honestly tracked — not a bug that "slipped
through."

---

## Why the bugs were allowed (the meta-gap)

Two recurring themes, both single-source-of-truth violations:

1. **Contracts duplicated instead of derived** (A1: sig vs.
   internal guard; B: marker set re-listed vs. sourced). The fix is
   always "make the duplicate a derivation," never "patch the
   duplicate."
2. **Promotion/normalization spread across conditions instead of
   one canonical pass** (A2 hypothesis: escape promotion; B2:
   transparent-node peel). The fix is unification, never a new
   per-condition branch.

CLAUDE.md already encodes this ("single source of truth", "fix at
the architecturally correct place reducing not adding complexity",
"prove the bug with a test first"). The gap was process adherence
under incremental pressure, not missing principles. Concrete
durable guardrail added this session: the A1 regression spec. The
B and A2 architectural fixes are scoped above as dedicated,
verified workstreams — explicitly not to be band-aided.
