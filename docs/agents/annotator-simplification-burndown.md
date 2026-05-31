# Annotator Simplification Burndown

Scope: evaluate three simplification tracks independently:

1. Type contract cleanup.
2. Hash record replacement / reification.
3. Decomplex hotspot cleanup.

Each item gets its own baseline, change, after snapshot, and commit. The
evaluation for each item must say one of:

- **Worth it**: metrics improved or the code became materially simpler with no
  regression.
- **Continue**: the first slice moved in the right direction but needs another
  slice to pay for itself.
- **Scrap**: metrics moved the wrong way, the code got more complex, or the
  change only moved complexity around.

Bug fixes override the metrics. If fixing a real bug worsens a simplification
metric, keep the bug fix and record the tradeoff.

## Baseline Snapshot

Generated May 31, 2026 from the current working tree before this burndown.
Nil-kill was run with `--allow-stale-runtime` because the stored runtime
evidence predates the current source; use nil-kill as directional static/type
pressure until fresh evidence is collected.

Commands:

```bash
ruby gems/decomplex/exe/decomplex report src --output=/tmp/decomplex-burndown-before.md
ruby gems/slopcop/exe/slopcop report --output=/tmp/slopcop-burndown-before.md
ruby gems/boobytrap/exe/boobytrap report --output=/tmp/boobytrap-burndown-before.md
NIL_KILL_TARGETS=src bundle exec tools/nil-kill report --allow-stale-runtime --hygiene > /tmp/nil-kill-burndown-before.md
```

Metrics:

- SlopCop: 4051 dark arms, 1184 genuine gaps, 1162 type_norm arms, 899 diagnostic arms.
- Decomplex: 1349 cross-detector convergence units, 297 decision-pressure findings, 190 missing-abstraction findings.
- Boobytrap: top hotspot remains `src/mir/mir_lowering.rb` at 0.1498; annotator entries start at `src/annotator/helpers/function_analysis.rb` rank 29, hotspot 0.0092, 79/438 uncovered branches.
- Nil-kill: 3578 methods indexed, 194 missing sigs, 3384 existing sigs, 1250 candidate `T.let` sites.
- Nil-kill type pressure: param inputs 1293 untyped / 348 nilable; returns 340 untyped / 459 nilable; fields 1184 untyped / 142 nilable; collections 747 untyped / 319 nilable.

## Item 1: Type Contract Cleanup

Candidate signals:

- Nil-kill union decomplexity points at `.type`, `full_type!()`, and `.return_type` guards.
- Decomplex decision pressure still reports broad guard pressure around `.value`, `.symbol`, `.target`, `.emit`, `.full_type!`, `.name`, `.type`, and `.current_fn_ctx`.

Plan:

- Prefer narrowing an existing seam over deleting individual branches.
- Remove only guards that are already guaranteed by a typed writer or authoritative accessor.
- Snapshot reports after the slice and decide whether the contract cleanup should continue.

Status: continue.

Slice 1:

- Change: narrowed `FunctionSignature#return_type=` and
  `FunctionContext#return_type=` to the actual accepted contract, and removed
  one redundant `Type`/non-`Type` branch at call result stamping.
- Validation: `bundle exec srb tc`; `bundle exec prspec
  spec/annotator_gap_burndown_spec.rb spec/first_class_function_spec.rb
  spec/mir_lowering_spec.rb`.
- After metrics:
  - SlopCop: 4051 -> 4035 dark arms; 1162 -> 1139 type_norm arms; 1184 -> 1188 genuine gaps.
  - Decomplex: 1349 convergence units unchanged; 297 decision-pressure unchanged; 190 missing-abstraction unchanged. `resolve_call` dropped out of the top excerpt captured by the baseline comparison.
  - Boobytrap: unchanged for annotator `function_analysis.rb` at rank 29, 79/438 uncovered branches.
  - Nil-kill hygiene summary unchanged.
- Evaluation: **Continue**. The contract cleanup removed type-normalization pressure, but the small slice did not move nil-kill totals and converted/shifted a few SlopCop arms into genuine gaps. Continue only where a seam deletes repeated guards across multiple readers; do not do one-off sig tightening as a standalone win.

## Item 2: Hash Record Replacement / Reification

Candidate signals:

- Nil-kill reports 226 hash-record struct candidates.
- Annotator local pressure includes predicate context records, capability records, sync-policy selector records, union-field request records, and pipe option records.

Plan:

- Start with a small local hash shape that has clear ownership and no cross-file serialization contract.
- Replace raw `[:key]` consumers with a typed value object.
- Do not reify parser/AST public hashes unless the replacement can be carried through all consumers.

Status: scrap.

Attempted slice:

- Change tried: reified the local predicate context and predicate call-site
  hashes in `CapabilityHelper` into strict value objects.
- Validation before scrapping: `bundle exec srb tc`; `bundle exec prspec
  spec/with_guard_spec.rb spec/with_pre_spec.rb spec/with_post_spec.rb
  spec/predicate_impurity_spec.rb spec/annotator_gap_burndown_spec.rb`.
- After metrics for the attempted slice:
  - SlopCop: 4035 -> 4008 dark arms; 1139 -> 1125 type_norm arms; 1188 -> 1186 genuine gaps.
  - Decomplex: 1349 -> 1350 convergence units; 297 -> 298 decision-pressure findings; 190 missing-abstraction unchanged.
  - Nil-kill hygiene unchanged; full stale-runtime report still showed the same hash-record headline counts, so the target did not produce a measurable nil-kill win.
  - Boobytrap unchanged.
- Evaluation: **Scrap**. This was a bad trade: roughly a page of strict-mode value-object boilerplate for a small SlopCop improvement, no nil-kill movement, and worse decomplex totals. The right hash-record work needs to target a higher-pressure shape whose reification removes more code than it adds, not a small local predicate context.
- Result: code slice reverted before commit; only this evaluation remains.

## Item 3: Decomplex Hotspot Cleanup

Candidate signals:

- `src/annotator/annotator.rb:5427` `handle_assign_move`: 7 detectors, score 13, 54 findings.
- `src/annotator/annotator.rb:4710` `visit_WithBlock`: 6 detectors, score 11, 88 findings.
- `src/annotator/helpers/pipe_analysis.rb:1527` `analyze_concurrent_op`: 6 detectors, score 11, 70 findings.
- `src/annotator/annotator.rb:1978` `visit_WhileBindLoop`: 6 detectors, score 11, 38 findings.
- `src/annotator/helpers/function_analysis.rb:182` `resolve_call`: 5 detectors, score 10, 108 findings.

Plan:

- Pick the hotspot where a bounded extraction deletes repeated decision logic.
- Avoid large architectural rewrites unless the first slice proves the metric and readability payoff.
- Snapshot reports after the slice and decide whether to continue or stop.

Status: continue.

Slice 1:

- Change: split `handle_assign_move` into scoped-alias rejection,
  path/index move handling, ownership-graph declaration, borrowed-index
  rejection, and identifier move handling. No behavior change intended.
- Validation: `bundle exec srb tc`; `bundle exec prspec
  spec/annotator_gap_burndown_spec.rb spec/move_semantics_spec.rb
  spec/use_after_move_spec.rb spec/affine_ownership_spec.rb
  spec/borrowed_escape_spec.rb`.
- After metrics:
  - SlopCop: 4035 -> 3989 dark arms; 1139 -> 1116 type_norm arms; 1188 -> 1181 genuine gaps.
  - Decomplex: `handle_assign_move` dropped out of the top convergence list, but total convergence moved 1349 -> 1353. Decision-pressure and missing-abstraction totals were unchanged.
  - Nil-kill hygiene unchanged.
  - Boobytrap hotspot count unchanged.
- Evaluation: **Continue**. This improved SlopCop and removed the specific top annotator hotspot from the headline list, but the extraction increased total decomplex convergence by creating smaller protocol-shaped helpers. Keep the slice because the targeted hotspot is materially easier to read; next work should collapse the new ownership-graph declaration protocol instead of doing more pure extraction.

## Progress Log

- Item 1 slice 1 committed separately. Continue only with broader seam cleanup.
- Item 2 attempted and scrapped. Do not reify small local hashes unless the
  replacement removes more branches/guards than the strict object costs.
- Item 3 slice 1 committed separately. Target hotspot improved, but follow-up
  should reduce the new ownership-graph helper protocol.

## Closeout

Validation:

- `bundle exec srb tc`
- `bundle exec prspec spec/` -- 4990 examples, 0 failures, 1 expected pending.

Total metric differential from the pre-work snapshot:

- SlopCop: 4051 -> 3989 dark arms (-62); 1162 -> 1116 type_norm arms (-46);
  899 -> 892 diagnostic arms (-7); 1184 -> 1181 genuine gaps (-3).
- Decomplex: 1349 -> 1353 cross-detector convergence units (+4); 297
  decision-pressure findings unchanged; 190 missing-abstraction findings
  unchanged. The targeted `handle_assign_move` hotspot dropped out of the top
  convergence list, but the aggregate score worsened.
- Boobytrap: 79 hotspots unchanged; top hotspot still `src/mir/mir_lowering.rb`
  at 0.1498; annotator `function_analysis.rb` unchanged at rank 29, 79/438
  uncovered branches.
- Nil-kill: hygiene summary unchanged across methods indexed, missing sigs,
  existing sigs, `T.let` candidates, untyped inputs/returns/fields, collection
  pressure, HIGH, and REVIEW counts.

Overall evaluation:

- Type contract cleanup was worthwhile only as seam work. It reduced type_norm
  pressure, but tiny one-off sig tightening is not enough to justify more
  isolated slices.
- Hash record reification was not worthwhile in the attempted local predicate
  shape and was scrapped before code commit.
- Decomplex hotspot cleanup was locally worthwhile for readability and SlopCop,
  but not a global decomplex win yet. More pure extraction would be the wrong
  next move; the follow-up has to collapse the ownership-graph declaration
  protocol or target a different hotspot with a clearer deletion path.

No real compiler bug was found in this pass.

## Follow-up: Cross-Tool State/Hotspot Items

Added May 31, 2026 after comparing CodeQL state-flow output with nil-kill,
decomplex, SlopCop, and Boobytrap. Each item below must be evaluated
independently with before/after metrics and one of: **Worth it**,
**Continue**, or **Scrap**. Real bugs found during any item are fixed even if
metrics move the wrong way.

### State Contract Items

- [ ] `.value` contract cleanup
  - Signals: nil-kill union decomplexity; decomplex decision pressure; CodeQL
    field pressure; `SemanticAnnotator#visit_ReturnNode`.
  - Goal: tighten producers/accessors so repeated value guards can be deleted.
- [ ] `.type` contract cleanup
  - Signals: nil-kill top union decomplexity; decomplex decision pressure;
    CodeQL field pressure.
  - Goal: narrow the overloaded type contract or isolate the true union.
- [ ] `.return_type` contract cleanup
  - Signals: nil-kill union decomplexity; decomplex decision pressure.
  - Goal: remove nil/type guards by making function return-type state explicit.
- [ ] `.full_type!` contract cleanup
  - Signals: nil-kill union decomplexity; decomplex decision pressure;
    PipelineHost pressure.
  - Goal: make the bang contract trustworthy at callers or move checks to the
    producer boundary.
- [ ] `.target` contract cleanup
  - Signals: decomplex decision pressure; CodeQL field pressure.
  - Goal: replace repeated target nil/type guards with an explicit target
    shape/helper.
- [ ] `.emit` contract cleanup
  - Signals: decomplex decision pressure; static-call annotator pressure.
  - Goal: single-source emit metadata rather than checking it ad hoc.
- [ ] `storage` contract cleanup
  - Signals: decomplex root cluster; CodeQL field pressure; prior fact-flow
    work.
  - Goal: collapse storage/sync/layout/ownership redundant-state drift.
- [ ] `sync` contract cleanup
  - Signals: decomplex root cluster; CodeQL field pressure.
  - Goal: centralize sync derivation or stamping.
- [ ] `layout` contract cleanup
  - Signals: decomplex root cluster; CodeQL field pressure.
  - Goal: remove duplicated layout checks/stamps.
- [ ] `ownership` contract cleanup
  - Signals: decomplex root cluster; CodeQL field pressure.
  - Goal: make ownership state authoritative at writer boundaries.
- [ ] `result_type` contract cleanup
  - Signals: decomplex root cluster; CodeQL field pressure; MIR lowering
    pressure.
  - Goal: remove repeated result-type derivation guards.

### File/Method Hotspot Items

- [ ] `src/mir/mir_lowering.rb`
  - Signals: Boobytrap #1; SlopCop top gaps.
  - Goal: only a bounded helper/contract cleanup; avoid broad file churn.
- [ ] `PipelineHost#substitute_placeholders`
  - File: `src/backends/pipeline_host.rb`.
  - Signals: Boobytrap #3 file; SlopCop cluster; decomplex and CodeQL state
    pressure.
  - Goal: collapse placeholder classification/substitution branches.
- [ ] `MIRLoweringExpressions#lower_smooth`
  - File: `src/mir/lowering/expressions.rb`.
  - Signals: SlopCop cluster; decomplex convergence.
  - Goal: extract or delete repeated smooth/range-shape decisions.
- [ ] `MIRLoweringVariables#build_var_decl_nodes`
  - File: `src/mir/lowering/variables.rb`.
  - Signals: decomplex top convergence; SlopCop cluster.
  - Goal: collapse repeated declaration-shape/result-node assembly.
- [ ] `Parser#parse_type_annotation`
  - File: `src/ast/parser.rb`.
  - Signals: decomplex parser hotspot; SlopCop cluster.
  - Goal: only proceed if there is a clean grammar/state abstraction; otherwise
    record as risky and skip code churn.

#### Parser#parse_type_annotation Slice 1

- Change tried: extracted array suffix parsing from `parse_type_annotation`
  into `parse_array_type_suffix`, `parse_first_array_dimension`, and
  `parse_additional_array_dimension`.
- Validation: `ruby -c src/ast/parser.rb`; `bundle exec prspec
  spec/atomic_parser_spec.rb spec/versioned_parser_spec.rb
  spec/concurrency_spec.rb:1547`.
- Metrics:
  - SlopCop: 3719 -> 3728 dark arms; 1075 -> 1081 genuine gaps; type_norm
    unchanged at 1034; diagnostic 880 -> 887.
  - Decomplex: 1358 -> 1359 convergence units; decision pressure unchanged at
    298; missing abstractions unchanged at 187.
  - Boobytrap: parser unchanged at rank 17, 180/1069 uncovered.
- Evaluation: **Scrap**. This made the parser superficially tidier but added
  helper surface, worsened SlopCop and decomplex, and did not reduce the parser
  hotspot. Reverted. Parser work should wait for a real grammar/state
  abstraction, not local branch extraction.

#### `src/mir/mir_lowering.rb` Slice 1

- Change: deleted the trivial `filter_zig_blocks` wrapper and moved its one
  internal caller and direct spec to the existing `keep_zig_const_blocks`
  helper.
- Validation: `ruby -c src/mir/mir_lowering.rb`; `bundle exec prspec
  spec/mir_lowering_spec.rb:641`.
- Metrics:
  - SlopCop: 3719 -> 3724 dark arms; genuine gaps unchanged at 1075;
    type_norm 1034 -> 1035; diagnostic 880 -> 886.
  - Decomplex: unchanged at 1358 convergence units, 298 decision-pressure
    findings, and 187 missing-abstraction findings.
- Evaluation: **Continue**. This is a small code deletion with no genuine-gap
  win and a slight SlopCop arm regression. Keep only as a local simplification;
  it does not pay for broader MIR-lowering work by itself.

#### `MIRLoweringExpressions#lower_smooth` Slice 1

- Change: deleted a stale unused `inner_zig` derivation and updated the nearby
  comment. The code already hard-coded `i64` at the use site.
- Validation: `ruby -c src/mir/lowering/expressions.rb`; `bundle exec prspec
  spec/pipeline_backend_coverage_spec.rb spec/mir_lowering_spec.rb`.
- Metrics:
  - SlopCop: 3719 -> 3712 dark arms; 1075 -> 1076 genuine gaps; type_norm
    1034 -> 1032; diagnostic 880 -> 881.
  - Decomplex: unchanged at 1358 convergence units, 298 decision-pressure
    findings, and 187 missing-abstraction findings.
- Evaluation: **Continue**. Worth keeping because it removes stale state and
  two type_norm arms, but it is not a meaningful `lower_smooth` simplification.
  Further work needs to address the actual range/smooth shape decisions.

#### `PipelineHost#substitute_placeholders` Slice 1

- Change: fixed the early-return gate so `@soa_rewrite_active` runs
  substitution even when no placeholder, accumulator, join map, SOA-each mode,
  or named binding is active.
- Bug found: `visit_mir` relies on `substitute_placeholders` for SOA rewrite
  active mode. The previous gate could return a `_.field` MIR expression
  unchanged before the branch that rewrites it to `__soa_field[__soa_i]`.
- Validation: `ruby -c src/backends/pipeline_host.rb`; `bundle exec prspec
  spec/pipeline_backend_coverage_spec.rb`.
- Metrics:
  - SlopCop: 3719 -> 3713 dark arms; genuine gaps unchanged at 1075; type_norm
    1034 -> 1036; diagnostic 880 -> 871.
  - Decomplex: unchanged at 1358 convergence units, 298 decision-pressure
    findings, and 187 missing-abstraction findings.
  - Boobytrap: unchanged at rank 3, 217/800 uncovered branches.
- Evaluation: **Worth it**. Metrics do not show a simplification win, but this
  is a real compiler backend bug and the fix is one condition plus one focused
  regression spec.

#### `MIRLoweringVariables#build_var_decl_nodes` Slice 1

- Change: deleted an unreachable inner branch under
  `mir_allocates?(init) && !generic_id`. The same
  `binding_entry.present? && !binding_entry.needs_cleanup?` condition was
  already handled by an earlier `elsif`.
- Validation: `ruby -c src/mir/lowering/variables.rb`; `bundle exec prspec
  spec/mir_lowering_spec.rb spec/annotator_gap_burndown_spec.rb`.
- Metrics:
  - SlopCop: 3719 -> 3711 dark arms; 1075 -> 1077 genuine gaps; type_norm
    1034 -> 1032; diagnostic 880 -> 872.
  - Decomplex: unchanged at 1358 convergence units, 298 decision-pressure
    findings, and 187 missing-abstraction findings.
  - Boobytrap: unchanged at rank 32, 77/450 uncovered branches.
- Evaluation: **Worth it**. This removed impossible control flow with a small
  patch. SlopCop genuine gaps drifted up, but the branch was dead and should
  not remain in a compiler lowering path.

#### State Contract Slice 1: `.type`, `.return_type`, `.full_type!`, `.emit`

- Change:
  - Narrowed the AST `Param#type=`, `VarDecl#type=`, `BindExpr#type=`, and
    `FunctionDef#return_type=` writer signatures to the actual
    `nil | Type | Symbol | String` coercion contract.
  - Kept `full_type!` normalization for test-built/synthetic nodes that expose
    raw Symbol types, but removed the dead missing-type branch. `full_type`
    represents missing annotation with the `:Untyped` sentinel.
  - Reused local `emit` metadata in `visit_StaticCall` and
    `visit_IntrinsicFunc` instead of repeatedly safe-navigating through
    `method_def.emit` / `matched_def.emit`.
- Important boundary found: `Locatable#full_type=` still must accept untyped
  input because `stamp_type!` is intentionally generic and can stamp a
  `FunctionSignature` for function-valued expressions. An attempted narrower
  `full_type=` sig failed runtime validation and then Sorbet static checking
  when `stamp_type!` lost its generic return contract. That part was scrapped.
- Validation: `ruby -c src/annotator/annotator.rb`; `ruby -c
  src/ast/ast.rb`; `bundle exec srb tc`; `bundle exec prspec
  spec/annotator_gap_burndown_spec.rb spec/pipeline_backend_coverage_spec.rb
  spec/mir_lowering_spec.rb`.
- Metrics:
  - SlopCop: 3719 -> 3642 dark arms; 1075 -> 1047 genuine gaps; type_norm
    1034 -> 1004; diagnostic 880 -> 868.
  - Decomplex: convergence unchanged at 1358; root clusters unchanged at 328;
    decision pressure unchanged at 298; missing abstractions 187 -> 188.
  - Boobytrap: unchanged for the watched files.
  - Nil-kill hygiene: unchanged. Methods indexed, missing sigs, existing sigs,
    candidate `T.let` sites, and type-soundness rows are identical to baseline.
- Evaluation: **Worth it**. This is the first slice in this burndown with a
  clear SlopCop genuine-gap drop (-28) and type_norm drop (-30) without broad
  code churn. The one decomplex missing-abstraction regression is acceptable
  because the repeated emit metadata access is now explicit and local.

#### `.value` Contract Inspection

- Change: none. The main signal is `visit_ReturnNode`, where the `nil` branch
  is real syntax (`RETURN;`) and the remaining value-shape checks distinguish
  identifiers, fields, and index borrows from WITH-scoped aliases.
- Evaluation: **Scrap** for this pass. Tightening `.value` globally would either
  be an AST redesign or a risky visitor rewrite; no small contract change would
  remove real branches.

#### `.target` Contract Inspection

- Change: none. The target pressure is distributed across field/index/cast
  shapes where nil/type guards encode different AST variants.
- Evaluation: **Scrap** for this pass. A target helper might be useful later,
  but no bounded replacement was obvious from the inspected hotspot code.

#### `storage`, `sync`, `layout`, and `ownership` Contract Inspection

- Change: none. `SymbolEntry` already contains the useful predicates from the
  prior cleanup (`atomic?`, `atomic_ptr?`, `locked?`, `rc_stored?`, storage
  provenance helpers), and the remaining pressure crosses escape analysis,
  cleanup classification, annotator capability checks, and type metadata.
- Evaluation: **Continue** architecturally, but no local slice here. The next
  worthwhile move is a single authoritative state object or writer boundary
  for binding placement/sync/layout/ownership. Replacing individual checks
  would only move complexity around.

#### `result_type` Contract Inspection

- Change: none beyond the `lower_smooth` stale-local deletion above. The
  inspected uses derive result ownership/allocation from concrete MIR/AST nodes,
  not from one loose writer that can be tightened independently.
- Evaluation: **Scrap** for this pass. No standalone cleanup justified a patch.

#### Final Cross-Tool Differential For This Follow-Up

- SlopCop: 3719 -> 3642 dark arms (-77); 1075 -> 1047 genuine gaps (-28);
  1034 -> 1004 type_norm arms (-30); 880 -> 868 diagnostic arms (-12).
- Decomplex: convergence unchanged at 1358; root clusters unchanged at 328;
  decision pressure unchanged at 298; missing abstractions 187 -> 188 (+1).
- Boobytrap: no watched-file movement; `src/mir/mir_lowering.rb` remains the top
  hotspot, `PipelineHost` remains rank 3, and parser/expressions/variables
  ranks are unchanged.
- Nil-kill: hygiene totals unchanged.
- Bugs fixed: `PipelineHost#substitute_placeholders` skipped
  `@soa_rewrite_active` substitution when no placeholder mode was active.
