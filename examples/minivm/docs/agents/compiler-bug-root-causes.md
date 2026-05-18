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

### A1. `IfStatement#else_branch` AST-invariant violation by PipelineRewriter

- **First fix was a band-aid (corrected).** Initially I widened
  `ControlFlow.scan_direct`'s sig to `T.nilable` so it would accept
  the nil it was receiving. That treats the symptom and **adds a
  nil path** — exactly what CLAUDE.md / `decomplex` forbid. The
  user correctly rejected it ("adding nil is not acceptable; that
  is almost certainly a bug"). `origin/decomplex` was checked: it
  carries the **identical** strict `scan_direct` sig — it would NOT
  have fixed this; a static type-tightening sweep can't see a
  runtime nil-flow.
- **Real root cause:** the parser upholds an invariant —
  `IfStatement#else_branch` is **always an `Array`** (`[]` for an
  absent ELSE; parser.rb:2009/2036/2052). `PipelineRewriter`
  violated it at **9 sites**, constructing
  `AST::IfStatement.new(..., nil)`. `scan_direct` then *correctly*
  received a contract-violating nil. (`MatchStatement#default_case`
  is, by contrast, `[ASTNode] or nil` **by AST design**
  (ast.rb:1171) — a sanctioned optional, not a violation.)
- **Systemic gap:** an AST invariant the parser guarantees but a
  rewrite pass silently broke, with **zero coverage** asserting the
  invariant at the rewrite boundary — so the contradiction sat
  latent until a body-shape reached `scan_direct` without a loop
  boundary in between.
- **Architecturally-correct fix (DONE):**
  1. `pipeline_rewriter.rb`: all 9 `IfStatement.new(...,nil)` →
     `(...,[])` — restore the parser invariant at the source.
  2. `control_flow.rb`: `scan_direct` sig reverted to **strictly
     non-nil** `T::Array`; the dead `return unless body.is_a?(Array)`
     band-aid removed; the ONE genuinely-optional recurse site
     guarded `... if s.default_case` (mirrors ast.rb's own
     `bodies << default_case if default_case`). No nil ever reaches
     `scan_direct`.
- **Regression-locked (proven):** `spec/loop_frame_analysis_spec.rb`
  Group G asserts the invariant directly (no `IfStatement` in a
  pipeline-rewritten tree has a nil `else_branch`) — **proven to
  fail** if a single `nil` is reintroduced — plus end-to-end
  IF-no-ELSE / PARTIAL-MATCH-no-DEFAULT and a `scan_direct(nil) ->
  TypeError` test that **encodes the strict contract** (nil is a
  bug, not a no-op). Exhaustively verified: prspec **4802/0**,
  transpile-tests **554/554** (0 leaks), fuzz matrix **141/141**,
  register allowlist **245/245**.
- **Missing fuzz coverage (answer to "what fuzz would have caught
  this?"):** the stable matrix
  (`access_gate, execution_boundary, stream_into_boundary,
  loop_carry_collection, mutable_collection_param`) has **no
  template emitting pipeline ops** (WHERE/FIND/AVG/ANY/ALL/skip/
  limit — the shapes that drive PipelineRewriter's synthesized
  IfStatements) at **direct (non-loop-nested) body scope** in
  escape/loop-frame-analyzed functions. `scan_direct` STOPs at loop
  boundaries, so pipeline ops nested in generated loops never reach
  it — which is why 554 transpile-tests + the fuzz matrix were all
  green pre-fix. A `pipeline_direct_scope` template would add that
  cross-product. **But** the structurally-correct guard is the
  invariant test above (assert at the rewrite boundary), which
  catches the root cause regardless of which downstream consumer
  trips on it — strictly better than fuzzing for one consumer's
  symptom. Recommended: add the fuzz template *and* keep the
  invariant assertion as the primary guard.
- **Class prevention:** audited `control_flow.rb` — `scan_direct`
  was the lone sig-vs-internal-guard instance. The durable guards
  are (a) the invariant spec, (b) the strict non-nil sig now
  enforcing the contract at every call site.

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
