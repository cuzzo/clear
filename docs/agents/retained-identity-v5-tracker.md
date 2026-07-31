# Retained Identity v5 - Implementation Tracker

Design: `docs/agents/retained-identity-design.md` (v5, "Declaration-Sited
Cost, Callee-Sited Correctness"). Supersedes v4. Every item cites the design
section it satisfies. Legend: `todo` | `in-progress` | `done` | `blocked(<reason>)`.

Core model: the DECLARATION picks the carrier/cost (plain, `@multiowned`,
`@shared`); the CALLEE picks the correctness model at each fan-out
(`COPY_OR_CLONE` preserves the caller's carrier; `COPY` needs a local or
`UNIQUE` value). No normalization to Rc; the carrier is preserved through
annotation, MIR, and Zig. One authoritative ownership plan + one lifecycle
plan (design "Lowering requirements").

## Burn-down (execute in order; each unit is test-first, gated, committed)

### Phase 0 - migration audit

| ID | Item | Design | Status |
| --- | --- | --- | --- |
| V5-0 | Migration audit (see progress log) | Lowering requirements | done |

### Phase 1 - surface syntax

| ID | Item | Design | Status |
| --- | --- | --- | --- |
| V5-1a | Lexer: COPY_OR_CLONE + UNIQUE keywords added (SHARED/COPY/CLONE already existed); lexer spec 52/0, full spec 7249/0. Generated lexer.clear regeneration deferred to V5-6a. | Decision | done |
| V5-1b | Parser: UNIQUE prefix -> :unique; existing SHARED T (polymorphic_shared type) derives :shared; default :polymorphic. carrier_contract on Capture+Param. Parser spec 4/4; share spec preserved; golden regenerated; full spec 7253/0. | Parameter contracts | done |
| V5-1c | Parser + AST: COPY_OR_CLONE -> AST::CopyOrCloneNode (prefix rule + action); minimal annotator visit stamps operand type (op decided at placement, V5-3a); registered in walker router. Parse spec 6/6, walker-coverage green, full spec 7255/0. | Operation table | done |

### Phase 2 - carrier contract + consuming-use/liveness (annotator)

| ID | Item | Design | Status |
| --- | --- | --- | --- |
| V5-2a | carrier_contract on SymbolEntry lifecycle (prop + accessor), written once at param binding from Param.carrier_contract. Spec proves :polymorphic/:unique reach the resolved symbol. Full spec 7257/0, sorbet clean. | Parameter contracts | done |
| V5-2b | Consuming-use + liveness ARE the existing authoritative move/ownership tracking (OwnershipGraph use-after-move) - no new syntactic walk (resolves Issue 4). COPY_OR_CLONE at a consuming site already suppresses the source move so the fix compiles. | Static rules; Why provenance | done |
| V5-2c | DONE. Rules 3 (fanout->COPY_OR_CLONE), 4 (COPY_OR_CLONE on plain local), 5 (COPY_OR_CLONE on UNIQUE), 6 (COPY on carrier-polymorphic param OR its direct alias). carrier_polymorphic flag on SymbolEntry (set for unconstrained TAKES, propagated across direct aliases per "Why provenance is limited"). Diagnostics COPY_OR_CLONE_ON_KNOWN_CARRIER, COPY_ON_POLYMORPHIC_PARAM. Rules 7/8 (copyable) are Phase 3b. Specs 6/6, full 7265/0. | Static rules; Diagnostics | done |

### Phase 3 - ownership plan (carrier-preserving, single writer)

| ID | Item | Design | Status |
| --- | --- | --- | --- |
| V5-3a | DONE. Decision core (OwnershipEdgePlanner, 7 ops) + WIRING: finish_previsited_keep! stamps KeepNode.carrier_op via the planner (the ONE writer) from the source carrier (rc_retain/arc_retain/payload_copy), or :deferred_specialization for a carrier-polymorphic param source (resolved Phase 4); non-Rc/Arc retained carriers (@split/promise) stay on the existing lowering path. v4 kept-identity placement UNTOUCHED. Specs: 10 planner cost + 3 stamp-on-annotated-program. Gates prspec 7280/0, sorbet clean, transpile 618/618 0 leaks. COPY-node op stamping + shared_to_unique is V5-3b. | Lowering requirements; Operation table | done |
| V5-3b | `COPY` semantics: payload copy for local/UNIQUE; shared->unique boundary copy only at a UNIQUE param edge; reject non-copyable (rule 7). `COPY_OR_CLONE` requires copyable payload when instantiated plain (rule 8). Specs. | Parameter contracts; Static rules 7,8 | todo |
| V5-3c | DONE (verify+pin). The existing polymorphic_shared (SHARED T) machinery already satisfies the v5 SHARED contract HARD constraints: rejects plain in DEFAULT+STRICT (ARG_NEEDS_SHARED), accepts @shared/Arc, auto-retains multiple consuming uses (no per-use KEEP), and does NOT silently make @multiowned thread-safe (it requires an explicit @shared, so single-thread Rc is never promoted to cross-thread Arc). 5 specs pin these. OPEN DESIGN DECISION: accepting @multiowned into SHARED (design "Shared identity" fuller reading) requires the separate thread-safety-requirement axis - deferred (see progress log). | Shared identity | done |

### Phase 4 - lowering + carrier specialization (replaces v4 one-Rc-ABI)

| ID | Item | Design | Status |
| --- | --- | --- | --- |
| V5-4a/b | PARTIAL. lower_clone consumes KeepNode.carrier_op; concrete rc_retain/arc_retain emit exactly one carrier-appropriate retain no copy (codegen specs). KEEP-on-plain reaches lowering ONLY as the carrier-polymorphic case (:deferred_specialization) -> fails CLOSED with a clear "carrier specialization (Phase 4b)" message. Design note for the Zig-comptime specialization approach recorded. CRUX carrier specialization OPEN (see progress log + design note) - large, memory-safety-critical, needs the anytype/comptime ABI. | Lowering requirements | in-progress |
| V5-4b | MIR consumes the plan and emits exactly the selected op; cleanup + transfer marks come from the authoritative lifecycle plan (not synthesized at the edge). | Lowering requirements | todo |
| V5-4c | DONE (verified). Declaration-sited field auto-wrap (plain T -> @multiowned field) works via the kept-param store path, proven by goldens 622/627 (green in transpile 618/618). The direct anonymous-constructor-into-field shape is unsupported on the v4 baseline too (not a v5 regression). v5 will re-express this via the v5 mechanism when v4 is retired (Phase 6b). | Decision; user example | done |

### Phase 5 - test matrices

| ID | Item | Design | Status |
| --- | --- | --- | --- |
| V5-5a | PARTIAL (working cases). New goldens 630 (@multiowned KEEP retain), 631 (@shared KEEP retain), 632 (shared->unique COPY at UNIQUE boundary), 633 (last-use move no retain), 634 (SHARED registration, multi-consumer auto-retain). All leak-free (transpile 623/623 0 leaks). BLOCKED case (carrier-polymorphic-plain KEEP, e.g. User/Cache/queue plain) awaits carrier specialization. | Required tests / Transpile | in-progress |
| V5-5b | PARTIAL. carrier_ownership_matrix fuzz template (10 cells): 5 positives leak-checked (@multiowned/@shared KEEP, shared->unique COPY, last-use move, SHARED multi-consume), 5 negatives with diagnostic_code_required (KEEP_ON_KNOWN_CARRIER, COPY_ON_POLYMORPHIC_PARAM, COPY_RETAINED_NEEDS_UNIQUE, CARRIER_POLYMORPHIC_FANOUT, ARG_NEEDS_SHARED). Isolated run 10/10 0 unexpected-pass. Ledger updated. OMITS carrier-polymorphic-plain KEEP (blocked, logged). Swap/drop mutation gate is Phase 6 (after specialization). | Required tests / Fuzz | in-progress |
| V5-5c | PARTIAL. Codegen assertions for the working cases: @multiowned KEEP=1 rcRetain no copy, @shared KEEP=1 arcRetain, shared->unique COPY=payload dupe, last-use move=no retain (keep_carrier_lowering_spec 5 examples). MUTATION KILL: carrier_copy_polymorphic mutant (disables COPY_ON_POLYMORPHIC_PARAM) KILLED by carrier_ownership_matrix (unexpected_pass delta 1). Full carrier-op codegen for the polymorphic case awaits specialization. | Required tests / Codegen | in-progress |

### Phase 6 - acceptance + v4 retirement

| ID | Item | Design | Status |
| --- | --- | --- | --- |
| V5-6a | Verify all 6 acceptance criteria + non-goals (no ALWAYS_COPY/@willCopy, no per-use Rc/Arc spelling, no runtime dispatch, no implicit copy in DEFAULT/STRICT). Regenerate the self-hosted lexer; full corpus oracle 79/79; full fuzz matrix; sorbet; transpile 0 leaks. | Acceptance criteria | todo |
| V5-6b | Retire the v4 machinery marked REPLACE in V5-0 (Rc-normalizing ABI, born-as-Rc type mutation, KeptEdgeLiveness) once v5 subsumes it; remove dead code, keep tests that still prove valid behavior. | Non-goals | todo |

## Progress log

### V5-0 migration audit (2026-07-22) - DONE

Label per v4 artifact against the v5 carrier-preserving model:

| v4 artifact | file | verdict | rationale |
| --- | --- | --- | --- |
| `KeepAnalysis.propagate_kept_identity!` fixpoint | semantic/keep_analysis.rb | EVOLVE | keep the transitive fixpoint (a param passed to a consuming position is itself consuming), broaden from "@multiowned field store" to ALL consuming uses (rule 10) + fan-out/liveness. |
| `KeptIdentityContract {family, sink}` | ast/param.rb | EVOLVE | repurpose to the param CARRIER CONTRACT axis `{contract: :polymorphic\|:unique\|:shared}`; keep `sink` for diagnostics. v4 `family` was the destination family; v5 needs the param contract. |
| `CallEdgeOwnershipPlan {op, family}` (5 ops) | ast/param.rb | EVOLVE | grow to the 7 v5 ops {payload_move, rc_handle_move, arc_handle_move, payload_copy, rc_retain, arc_retain, shared_to_unique_copy}. CRITICAL: v4 `move_payload_wrap` wrapped a plain payload INTO Rc (the normalization the design rejects) -> becomes `payload_move` (no wrap). |
| `apply_kept_identity_placement!` single writer | semantic/escape_analysis.rb | EVOLVE | keep the single-writer-stamps-plan architecture; replace the decision logic with carrier-preserving 7-op selection (source carrier + contract + liveness + explicit op). |
| `KeptEdgeLiveness` syntactic last-use | semantic/escape_analysis.rb | REPLACE | design "one authoritative lifecycle plan" + round-5 Issue 4: consume OwnershipGraph/lifecycle, not a second syntactic walk. |
| `promote_kept_binding!` born-as-Rc mutation + restamp | semantic/escape_analysis.rb | REPLACE | v5 preserves the carrier; a plain param stays plain (moves/copies). No born-as-Rc for plain params. Declaration-sited `@multiowned` LOCALS keep their normal Rc via the capability path (unchanged). Also resolves round-5 Issue 1. |
| one-Rc-ABI kept-param slots + `lower_kept_identity_arg` | mir/lowering/functions.rb | REPLACE | `Rc(T)`/`?Rc(T)` param ABI erases the carrier. Replace with carrier-preserving ABI + specialization (V5-4a). |
| `KEPT_IDENTITY_NEEDS_MODEL` | ast/diagnostic_registry.rb | REPLACE | v5 does not ask for a declaration model on a param; it asks for `COPY_OR_CLONE` at the first fan-out (rule 3). New diagnostic. |
| `KEPT_FN_VALUE_ABI` | ast/diagnostic_registry.rb | REUSE (fail-closed) | keep rejecting a carrier-polymorphic fn as a plain fn value until specialization covers fn values. |
| `KEPT_IDENTITY_FAMILY_MISMATCH` | ast/diagnostic_registry.rb | REUSE | @shared(Arc) into @multiowned(Rc) field is still cross-family-unsound; keep the safety check. |
| `GENERIC_IDENTITY_FIELD_UNSUPPORTED` | ast/diagnostic_registry.rb | REUSE | generic identity field still unsupported. |
| field-store auto-wrap (plain T -> @multiowned field) | annotator/domains/lifetimes.rb keep_param_identity! | EVOLVE (V5-4c) | keep "storing plain T into an @multiowned/@shared field wraps for you" (declaration-sited cost, user example). |

Sequencing consequence: Phases 1-3 build the v5 surface + analysis + plan
ALONGSIDE v4 (v4 still compiles the suite green). Phase 4 flips lowering to
carrier-preserving and Phase 6b retires the REPLACE items. This keeps every
gate green per unit rather than a big-bang cutover.

### Units V5-1a onward

(append per unit as it lands)

### KEEP rename+merge (2026-07-22, user directive)

Unified the fan-out primitive under KEEP: renamed COPY_OR_CLONE -> KEEP
and merged CLONE (the narrow Rc/Arc-retain case) into KEEP. KEEP is the
carrier-preserving fan-out: retain for a retained carrier (@multiowned/
@shared/@split/@shared-promise), payload copy for a plain carrier
(lowering in Phase 4), carrier-polymorphic for a polymorphic param.
- Lexer/parser: KEEP keyword -> AST::KeepNode; COPY_OR_CLONE and CLONE
  keywords removed. One node (KeepNode), one visit (visit_KeepNode).
- Annotator: reject_keep_on_known_carrier! (rules 4/5, skips non-escaping
  WITH aliases which the scoped-escape guard owns), finish_previsited_keep!
  (KEEP_WITH_SCOPED; NO bad-target -- KEEP allows a plain carrier via copy,
  so CLONE_BAD_TARGET was removed).
- Diagnostics: CLONE_WITH_SCOPED -> KEEP_WITH_SCOPED; CLONE_BAD_TARGET
  removed; COPY_OR_CLONE_ON_KNOWN_CARRIER -> KEEP_ON_KNOWN_CARRIER;
  WRAP_CONSUMER_WITH_CLONE/COPY_OR_CLONE -> WRAP_CONSUMER_WITH_KEEP.
- Auto-materialization now inserts KEEP (was CLONE) for retained sources;
  it already auto-inserts the wrapper in EASY/DEFAULT and only REQUIRES the
  explicit keyword in STRICT -- i.e. KEEP is already optional in EASY/DEFAULT
  per the user's goal. (Making it optional in STRICT too is a follow-up.)
- Rule-6 scope fix: COPY_ON_POLYMORPHIC_PARAM fires only on a DIRECT param
  reference (not `COPY items[0]`), and carrier_polymorphic is set only for
  retained-capable param types (excludes collections/strings/primitives),
  fixing 5 transpile regressions (121/125/156/175/530).
- Migrated transpile-tests/examples/benchmarks/fuzz/specs CLONE->KEEP.

Gates: prspec 7265/0, sorbet clean, transpile 618/618 0 leaks.
FOLLOW-UP: make KEEP optional in STRICT (auto-insert instead of requiring),
and the carrier-preserving KEEP-on-plain lowering (payload copy) in Phase 4.

### V5-2d KEEP optional in STRICT (2026-07-22) - DONE

The implicit-ownership materialization required an explicit keyword in
STRICT for BOTH retain and copy. Now KEEP (a refcount retain of a
retained carrier: any_rc/split) is optional in EVERY mode -- the
declaration already chose the cost -- so STRICT auto-inserts the KEEP
wrapper. A COPY (payload deep-copy of a plain value) STILL requires the
explicit keyword in STRICT, preserving design acceptance #5 (no implicit
payload copy / heap allocation in DEFAULT/STRICT). Spec: STRICT implicit
retain of @multiowned compiles; STRICT implicit plain copy still errors.
Gates: prspec 7267/0, sorbet clean.

### V5-3c SHARED contract (2026-07-22) - DONE (verify+pin) + open decision

Probed the existing polymorphic_shared (`SHARED T`) machinery: it ALREADY
satisfies the v5 SHARED contract's hard constraints (design "Shared
identity"):
- (a) rejects a plain value in DEFAULT and STRICT (ARG_NEEDS_SHARED);
- (b-partial) accepts an @shared (Arc) source;
- (c) auto-retains multiple consuming uses of a SHARED param with no
  per-use KEEP;
- (d) does NOT silently make @multiowned thread-safe -- it requires an
  explicit @shared, so a single-thread Rc is never promoted to a
  cross-thread Arc.
5 specs (shared_contract_spec.rb) pin these. No production change needed.

OPEN DESIGN DECISION (surface to user): the design's fuller reading of
(b) is that SHARED should ALSO accept @multiowned ("if both @multiowned
and @shared satisfy SHARED, a separate thread-safety requirement must
distinguish single-thread Rc from cross-thread Arc"). The current
machinery requires @shared specifically. Accepting @multiowned safely
REQUIRES first building that separate thread-safety-requirement axis
(so constraint (d) is not violated). That axis is a distinct feature
(REQUIRES CROSS_THREAD / @shared-only sink marking) and a user-facing
design decision: is the conservative @shared-only SHARED acceptable for
v5, or must @multiowned acceptance + the thread-safety axis land now?
Recorded as deferred; does not block Phase 4.

### Phase 4 design note: carrier specialization (the KEEP-on-plain crux)

Probe result: KEEP-on-plain reaches lowering ONLY for a carrier-polymorphic
parameter source (KeepNode.carrier_op == :deferred_specialization). KEEP on
a concrete plain local is rejected by rule 4; KEEP on a concrete
@multiowned/@shared works via the existing rcRetain/arcRetain path. So
"KEEP-on-plain lowering" IS the carrier-specialization problem.

The body of `foo(TAKES u: User)` with `sink(KEEP u); sink(u)` is generic over
u's carrier. Each caller supplies a concrete carrier (plain / @multiowned /
@shared) and the body must emit the carrier-appropriate op (payload copy /
rc retain / arc retain) with NO runtime tag or copy-vs-retain branch (design
"Lowering requirements"). This requires compile-time specialization.

RECOMMENDED APPROACH - Zig comptime (leverages CLEAR's existing pattern, the
`@hasField(@TypeOf(pool.*), "ctrl")` Arc-unwrap): emit a carrier-polymorphic
param as a Zig `anytype`/comptime-typed parameter; the KEEP lowering emits a
comptime branch `if (@hasField(@TypeOf(u), "ctrl")) <retain> else <copy>`;
Zig monomorphizes foo per concrete arg type at each call. Zero runtime cost,
no tag, compile-time specialization. The param's CLEANUP must likewise be
comptime (release the handle if retained, drop the payload if plain). This
is the "equivalent zero-runtime-cost representation strategy" the design
allows; specialization growth is bounded by Zig's monomorphization (one
instantiation per distinct call carrier tuple), which the design's
"MEASURED, CAPPED" requirement can enforce by counting distinct instantiated
carrier tuples per function.

SCOPE/RISK: this touches the function ABI (anytype params), every call site
(pass concrete carrier), the KEEP lowering, and cleanup - all
memory-safety-critical. It is the largest single v5 unit and cannot land as
one small safe increment. Current state: lower_clone fails CLOSED with a
clear "carrier specialization (Phase 4b, not yet implemented)" message for
the deferred_specialization case, so the boundary is honest (the design's
core example annotates and gives a clear build-time message). Concrete-
carrier KEEP and all v4 behavior remain green.

OPEN DECISION for the user: proceed with the Zig-comptime `anytype`
specialization (a multi-step, carefully-gated effort), or review the
approach first? This is the crux that makes the carrier-polymorphic KEEP
end-to-end functional.
