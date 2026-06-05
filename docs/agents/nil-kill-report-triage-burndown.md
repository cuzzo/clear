# Nil-Kill Report Triage Burndown

Date: 2026-06-04
Branch: `src-hardening`

## Inputs

- Current nil-kill report: `tmp/nil-kill-current-report.md`
- Current decomplex report: `tmp/decomplex-baseline-current.md`
- Current decomplex snapshot: `tmp/decomplex-baseline-current.json`
- Current untyped baseline: `bundle exec ruby tools/typing_baseline.rb src`

Nil-kill freshness note: the runtime evidence was collected from the same
worktree content that was later committed as `94916dcea`. The evidence store
records the pre-commit HEAD (`0f9d418de`), so `infer`/`report` required
`--allow-stale-runtime`. This is a commit-marker mismatch, not a content
mismatch.

## Baseline

Nil-kill type hygiene:

| Metric | Count |
|---|---:|
| Param untyped slots | 1025 |
| Return untyped slots | 243 |
| Struct/class field & ivar untyped slots | 1025 |
| Array/set/hashmap untyped slots | 500 |

Static source count:

| Metric | Count |
|---|---:|
| `TOTAL.untyped` in `src/` | 2401 |
| `params.untyped` | 1588 |
| `returns.untyped` | 524 |
| `structs_ivars.untyped` | 20 |
| `collections.untyped` | 561 |

Decomplex:

| Metric | Count |
|---|---:|
| Cross-detector convergence units | 1420 |
| Root-cause clusters | 355 |
| Total candidates | 5838 |

## Triage Strategy

Priority order:

1. Deterministic guard collapses that are statically or contract proven.
   These are high-confidence signs of stale defensive code, weak contracts,
   and repeated implicit invariants.
2. Hash-record and tuple-like array candidates with high read pressure.
   These point to structural data traveling as anonymous hashes/tuples.
3. Cross-detector convergence items in `src/` that overlap nil-kill pressure.
   These are likely architecture seams, not local style problems.
4. Broad union/no-evidence typing actions. These are useful but lower priority
   unless they collapse real control-flow or record pressure.

## Burndown Checklist

- [x] P0. Collapse static-proven `is_a?` / `nil?` guards where the local type is already concrete.
  - First batch: annotator domain helpers and function/generic helpers.
  - Resolved in `src/annotator/domains/errors.rb`, `src/annotator/domains/expressions.rb`,
    `src/annotator/domains/lifetimes.rb`, `src/annotator/domains/variables.rb`,
    `src/annotator/helpers/auto_inference.rb`, `src/annotator/helpers/capabilities.rb`,
    `src/annotator/helpers/effects.rb`, `src/annotator/helpers/function_analysis.rb`,
    `src/annotator/helpers/generic_analysis.rb`, `src/annotator/domains/member_access.rb`,
    `src/ast/parser.rb`, and `src/ast/type.rb`.
  - Removed redundant `Type` guards, literal-dead `return if false`, unreachable nil guards,
    and broad copyability/schema rescue paths that hid real type/schema failures.
  - Acceptance: targeted specs passed, changed-line coverage verified at 0 uncovered executable lines.
- [x] P0. Collapse contract-proven singleton parameter guards by tightening signatures.
  - Start with `AutoUnifier`, `GenericAnalysis`, `Capabilities`, and `FiberCtxBuilder`.
  - Completed for the current safe subset in `GenericAnalysis`, `Capabilities`, parser/type helpers,
    function/lifetime analysis, and return-type display paths.
  - Left broader `AutoUnifier` and `FiberCtxBuilder` candidates untouched because they were outside
    the top report pressure currently being changed and would be better batched with local tests.
  - Acceptance: `T.untyped` count stayed flat; decomplex total candidates and convergence moved down.
- [ ] P1. Replace high-pressure anonymous `BodyRecord` hash flows with named records where the ownership boundary is clear.
  - Candidate clusters: branch/body records in annotator/MIR, union requirement records.
  - Triage result: high-value, but not a narrow safe edit. The top branch/body record spans parser,
    annotator, MIR lowering, MIR checker, MIR emitter, and existing specs that assert hash access.
    It should be converted as a dedicated API migration, not partially papered over here.
  - Acceptance for that future batch: fewer hash-record pressure rows; no new untyped slots.
- [ ] P1. Reify tuple-like arrays that represent stable return protocols.
  - Candidates: `parse_comma_seq`, effect-point tuples, hoist normalized expr results.
  - Triage result: high-volume and real, especially `parse_comma_seq`, but the parser return-shape
    migration is broad enough to deserve its own batch. No partial tuple wrapper was introduced.
  - Acceptance for that future batch: tuple pressure decreases; changed parser/hoist lines covered.
- [ ] P2. Triage top cross-detector convergence items that overlap nil-kill pressure.
  - Candidates: `MIRLoweringVariables#lower_assignment`, `CleanupClassifier#stamp_binding_default_scope!`,
    `FunctionAnalysis#resolve_call`, `MIRLoweringControlFlow#for_each_plan`.
  - Acceptance: decomplex convergence/candidate counts flat/down.

## Measurement Rules

- Before each batch, run the narrow affected specs.
- After each batch, run:
  - `bundle exec ruby tools/typing_baseline.rb src`
  - `ruby gems/decomplex/exe/decomplex report src --emit-json=tmp/decomplex-after-current.json --output=tmp/decomplex-after-current.md`
- Final acceptance:
  - decomplex total candidates, convergence, or root-cause clusters move down or stay flat
  - `TOTAL.untyped` and category untyped counts move down or stay flat
  - all changed/new `src/` lines have targeted test coverage

## Batch 1 Results

Deterministic guard/rescue cleanup:

| Metric | Baseline | After Batch 1 | Direction |
|---|---:|---:|---|
| Decomplex convergence units | 1420 | 1411 | down |
| Decomplex root-cause clusters | 355 | 352 | down |
| Decomplex total candidates | 5838 | 5819 | down |
| `TOTAL.untyped` in `src/` | 2401 | 2401 | flat |
| `params.untyped` | 1588 | 1588 | flat |
| `returns.untyped` | 524 | 524 | flat |
| `structs_ivars.untyped` | 20 | 20 | flat |
| `collections.untyped` | 561 | 561 | flat |

Copyability/schema invariant:

- `lookup_type_schema` is allowed to return `nil` for a missing schema. It should not be wrapped in
  `rescue nil`; exceptions from schema lookup are bugs and must stay visible.
- `implicitly_copyable?` should be called only on a concrete `Type`. In paths that receive optional
  type evidence, the caller must guard or use the existing `full_type!` contract instead of rescuing
  and treating failures as copyable.
- The prior `rescue true` / `rescue nil` patterns were removed because they could silently convert
  annotator/type-contract defects into "copyable" decisions.

Verification:

- `bundle exec rspec spec/annotator_gap_burndown_spec.rb spec/generics_spec.rb spec/capabilities_spec.rb spec/effects_spec.rb spec/with_post_spec.rb spec/lifetimes_spec.rb spec/lifetime_unified_spec.rb spec/type_zig_type_gap_spec.rb spec/ast_coverage_burndown_spec.rb spec/transpiler_spec.rb`
- `bundle exec rspec spec/annotator_gap_burndown_spec.rb spec/generics_spec.rb spec/lifetimes_spec.rb spec/lifetime_unified_spec.rb spec/type_zig_type_gap_spec.rb spec/ast_coverage_burndown_spec.rb spec/transpiler_spec.rb`
- `bundle exec rspec spec/annotator_gap_burndown_spec.rb spec/gradual_typing_spec.rb spec/annotator_spec.rb`
- `COVERAGE=1 COVERAGE_DIR=tmp/coverage-nil-kill-burndown bundle exec rspec spec/annotator_gap_burndown_spec.rb spec/generics_spec.rb spec/capabilities_spec.rb spec/effects_spec.rb spec/with_post_spec.rb spec/lifetimes_spec.rb spec/lifetime_unified_spec.rb spec/type_zig_type_gap_spec.rb spec/ast_coverage_burndown_spec.rb spec/transpiler_spec.rb spec/copy_spec.rb spec/error_emission_coverage_spec.rb spec/affine_ownership_spec.rb spec/gradual_typing_spec.rb spec/annotator_spec.rb`
- Changed-line coverage check: 47 covered executable changed/addition lines, 3 non-executable
  changed lines, 0 uncovered executable lines.
- `bundle exec srb tc` was also run; it still reports the pre-existing `compose_capability_wrap`
  Sorbet error in `src/mir/lowering/literals.rb`, outside this batch.
