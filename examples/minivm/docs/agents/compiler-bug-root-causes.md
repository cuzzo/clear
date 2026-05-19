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

### A2. R2 fiber blocker = OPEN BG-capture compiler-bug family (vm-bugs.md)

- **Earlier "INLINE_ALLOC_MISMATCH escape gap" framing: superseded
  by evidence.** A minimal faithful probe (post compiler-fix:
  `EFFECTS REENTRANT` + a dead-guarded `BG { @service ->
  runRegisterBytecode!(COPY ops, COPY opcodes, ...) }`) does **not**
  reach `INLINE_ALLOC_MISMATCH` — it fails **earlier** in generated
  Zig: `expected '*array_list.Aligned(i64,null)', found
  '*const []i64'` for `COPY ops` (a slice param) captured into the
  BG fiber. The `INLINE_ALLOC_MISMATCH` seen in the original full-R2
  attempt was a *later* symptom along the same path.
- **Actual root:** the **OPEN BG-capture / dangling-pointer
  compiler-bug family** that `docs/agents/vm-bugs.md` was opened to
  track — Bug #4 (`COPY` at BG capture site → wrong `*const`-vs-`*T`
  Zig) and Bugs #2/#3/#6 (a borrow/slice escaping into an async BG
  fiber with no ownership-transfer marker; checker has nothing to
  fire on; codegen mismatch or UAF). These are **shared-compiler
  correctness bugs**, OPEN, with their own gap analysis in
  vm-bugs.md ("Fix priorities").
- **Systemic gap:** the lowering emits **no MIR marker** for a
  borrow/slice captured into a `BG` fiber, so MIRChecker's 7
  invariants are structurally blind to it (vm-bugs.md "Gap
  analysis"). The fix is in the **lowering** (emit a capture/
  ownership marker, or refuse the unsafe capture) — not the checker,
  not a vm.cht workaround.
- **Architecturally-correct response:** R2-R6 (stack-VM fiber
  replication) is **blocked behind the vm-bugs.md BG-capture family
  + P0** (guest frame-arena + giant-function FSM/heap-resident).
  These compiler fixes land first, architecturally, per the
  vm-bugs.md fix-priorities — **explicitly not** flattening VM
  structs, **not** a Condition-7 band-aid, **not** working around
  it in `vm.cht`. Cross-referenced in
  `stack-vm-fiber-replication.md` ("Faithful re-reproduction").

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

---

## Post-mortem: nested-@list-field append allocator (2026-05-18)

**Bug.** A `root[i].field.append(x)` where `root` is a loop-spanning
`@list` heap-promoted by a non-tight loop's per-iteration arena
rewind: the nested-field append resolved its allocator from the
leaf `GetField`/`GetIndex` receiver (no storage stamp -> `:frame`)
while `mir_checker` attributed the op to the heap root via
`extract_root_var_name` -> INLINE_ALLOC_MISMATCH. (Full root cause
in `docs/agents/vm-bugs.md`.)

**Why it went unnoticed until now.** Three independent coverage
gaps, each of which alone would have caught it:

1. **The fuzz template existed but was partially implemented.**
   `tools/fuzz/templates/loop_carry_collection.rb` is *exactly* the
   template for "collection carried across a rewinding loop." But
   its only axes were `elem ∈ {int,string}` (FLAT element types)
   and loop `depth`. It had **no nested-collection-field carrier
   axis** and **no frame-allocating-body axis**. The bug needs
   BOTH: a carrier whose element has a nested `@list` AND a loop
   body that frame-allocates (so `mark_per_iter` fires and the
   root is heap-promoted). The template generated neither, so the
   whole stable matrix was green while the bug was live. (This is
   the recurring "is it just only partially implemented?" failure
   mode -- a template named for the right scenario that samples a
   strict sub-region of it.)

2. **No unit/spec coverage for allocator-root agreement.**
   `mir_checker_spec.rb` / `loop_frame_analysis_spec.rb` /
   `allocation_strategy_spec.rb` test promotion and the checker
   invariants, but none asserts the *contract* that
   `resolve_alloc_sym`'s receiver root and `mir_checker`'s
   `extract_root_var_name` attribution resolve to the SAME root.
   The two functions independently walk receivers; nothing pinned
   them together. A nested-field-append-on-heap-root unit case
   would have failed immediately.

3. **The integration corpus never combined the ingredients.**
   `transpile-tests/` had loop-carried collections and had
   structs-with-`@list`-fields, but never a struct-with-nested-
   `@list` carried across a *non-tight, frame-allocating* loop with
   a *nested-field* mutation. `vm.cht` is the first program in the
   tree that does (its handle tables) -- and only when de-TIGHT'd,
   which nothing tested because the dispatch loop was always TIGHT.

**What made it finally surface.** Measuring the perf cost of
de-TIGHT-ing the register-VM dispatch loop (a user-requested
benchmark guardrail) -- i.e. a *deliberate* poke at the exact
axis (non-tight + frame-alloc body + nested-`@list` carrier) none
of the three coverage layers sampled.

### Extent (bounded, measured -- not "hundreds")

Probed pre-fix: a struct-with-nested-`@list` carrier with a
nested-field append, heap-promoted via **RETURNS** (`e1`) and via
**assign-escape** (`e2`), both **compile clean** pre-fix -- they do
NOT reproduce. Only the **loop-rewind** promotion creates the
heap-AllocMark / frame-op divergence. The *bug instance* is bounded
to one promotion path; it is not hundreds of latent instances.

### The systemic fix (the actual "hundreds" answer)

The instance is bounded, but the *mechanism* -- two passes
(`resolve_alloc_sym`, `extract_root_var_name`) independently
walking a receiver to its root and able to disagree -- is the open
class. A single `||` clause would fix the loop instance and leave
the class open (every future receiver shape added to one walker but
not the other re-opens it). Instead the two walkers were
**collapsed onto one canonical `root_receiver_node`**; the checker's
attribution and the allocator resolution derive from the same
function by construction and **cannot drift**. This closes the
class, not just the instance (project rule, cf. `9c63099d` "one
canonical walker, not N drifting").

**Durable guardrails added this session.**
- **Architectural:** `root_receiver_node` -- single canonical
  receiver-root resolver; `extract_root_var_name` and
  `receiver_root_heap?` both delegate. Resolver/checker root
  divergence is now structurally impossible for *any* receiver
  shape, not just GetField/GetIndex.
- **Unit (generalizing guard):**
  `spec/nested_field_append_allocator_spec.rb` asserts the contract
  via the checker ("op alloc == root AllocMark alloc; zero
  INLINE_ALLOC_MISMATCH") and asserts the path is genuinely
  exercised so it cannot pass vacuously. Verified load-bearing
  (fails pre-fix). Catches the *class* regardless of promotion path
  or receiver shape -- it does not hardcode `:heap` or the loop.
- **Fuzz:** `loop_carry_collection.rb` gained
  `carrier ∈ {flat,nested}` and `body ∈ {plain,frame_alloc}` axes;
  nested+frame_alloc cells are positive and fail pre-fix.
- **Integration:** `transpile-tests/528_nested_list_loop_rewind.cht`
  -- concrete leak-checked regression with a runtime assertion.

**Sibling-template audit (done, not deferred).**
`mutable_collection_param` has the *same* flat-`T[]@list`-only,
no-nested-carrier blind spot (with an `outer_loop` context that
could host it); `stream_into_boundary` / `access_gate` /
`execution_boundary` only use flat `STRUCT Counter { value: Int64 }`
carriers. These are real *template-hygiene* blind spots but hold
**no latent instance of this bug class**: the canonical-walker
unification makes the divergence impossible regardless of template
coverage, and the unit spec guards the contract independently of
any template. Exhaustively adding a nested-carrier axis to every
sibling is template polish, not a correctness gap -- logged here
rather than done, to avoid scope creep masquerading as rigor.

**Systemic lesson.** A named template's axes should span its
scenario's *triggering structure*, not just its surface. But the
durable fix for a "two passes can disagree" class is to make them
one pass plus a guard that asserts the *contract* (not a specific
value) -- not to enumerate every triggering combination across
every template.
