# Rust-Grade Annotator Findings

This note captures the annotator architecture findings from the June 10, 2026
review of `src/README.md`, `src/annotator/README.md`, and `src/annotator`.

Metric snapshots for the remediation pass live under:

- `tmp/agent-metrics/rust-grade-annotator/`

## Metric Baseline

Command:

```sh
bundle exec ruby gems/decomplex/exe/decomplex report src \
  --output=tmp/agent-metrics/rust-grade-annotator/decomplex-baseline.md \
  --emit-json=tmp/agent-metrics/rust-grade-annotator/decomplex-baseline.json
```

Baseline total: `5804`.

Baseline section counts: Cross-Detector Convergence `1761`,
Root-Cause Clusters `477`, Decision Pressure `269`, State Heatmap `557`,
State-Based Branch Density `1595`, Missing Abstractions `173`,
Reification Misses `6`, Neglected Updates `647`, Derived-State Staleness
`137`, Neglected Path Conditions `1355`, Broken Protocols `374`, False
Simplicity `1055`.

## Findings

1. **Auto finalization is not authoritative.** The Auto pass updates declaration
   syntax fields without restamping the semantic facts used by later phases:
   `full_type`, symbols, function signatures, and scope entries can remain
   `Auto`.

2. **The annotation boundary is too weak.** `mark_annotation_complete!` does
   not walk the whole AST to enforce the documented post-annotation contract:
   evaluatable nodes must have concrete, non-`Untyped`, non-`Auto` types before
   MIR.

3. **Invalid binary expressions are accepted.** `Type.binary_op` falls back to
   plausible result types for incompatible operands instead of producing a
   semantic rejection.

4. **Duplicate declarations silently overwrite.** Function and type namespaces
   are last-writer-wins maps. A compiler with this ambition needs deterministic
   duplicate diagnostics or an explicit overload-set design.

5. **Annotator session state leaks across programs.** A reusable
   `SemanticAnnotator` instance keeps root scope, function registry, summaries,
   and related facts between `annotate!` calls.

6. **Type resolution mutates shared `Type` objects.** `Scope#resolve_full_type`
   overlays symbol facts onto the stored `SymbolEntry#type`, so a read can
   mutate shared type state.

7. **Module metadata and capability/effect boundaries are still too mutable.**
   Import resolution shares schema/signature objects directly or shallowly, and
   capability/effect helpers still expose raw hash-shaped facts at semantic
   boundaries.

## Completion Criteria

- Every production change is in `# typed: strict` code and avoids new
  `T.untyped`.
- Every behavior change has focused specs.
- Added/changed production branches are covered above 80%.
- A decomplex baseline is captured before production edits.
- Decomplex is measured after each remediation task and must stay flat or
  improve. If it moves materially in the wrong direction, the task records why
  and whether a local simplification can correct it without unrelated churn.

## Task Checkpoints

### Auto Finalization And Annotation Boundary

Status: complete.

Changed production files:

- `src/annotator/phases/auto_finalization.rb`
- `src/annotator/phases/annotation_boundary.rb`
- `src/annotator/annotator.rb`
- `src/annotator/domains/errors.rb`
- `src/annotator/domains/variables.rb`

Verification:

- `bundle exec prspec spec/gradual_typing_spec.rb spec/annotator_phase_completion_spec.rb`
- `bundle exec srb tc`
- `COVERAGE=1 COVERAGE_DIR=tmp/agent-metrics/rust-grade-annotator/coverage-auto bundle exec prspec spec/gradual_typing_spec.rb spec/annotator_phase_completion_spec.rb`

Focused branch coverage from the task coverage run:

- `src/annotator/phases/auto_finalization.rb`: `94.4%` branch
- `src/annotator/phases/annotation_boundary.rb`: `83.3%` branch

Decomplex checkpoint:

- Baseline: `5804`
- After task: `5821`
- Assessment: aggregate moved up by `17` findings (`0.29%`). The increase is
  localized to the new Auto restamp and boundary enforcement code. A local
  wrapper-removal simplification was attempted; it did not improve the
  aggregate. No unrelated code was changed to offset the metric.

### Binary Operator Compatibility

Status: complete.

Changed production files:

- `src/ast/type.rb`
- `src/annotator/phases/auto_finalization.rb`
- `src/annotator/domains/expressions.rb`

Verification:

- `bundle exec prspec spec/binary_operator_type_check_spec.rb spec/gradual_typing_spec.rb spec/annotator_phase_completion_spec.rb`
- `bundle exec srb tc`
- `COVERAGE=1 COVERAGE_DIR=tmp/agent-metrics/rust-grade-annotator/coverage-binary bundle exec prspec spec/binary_operator_type_check_spec.rb spec/gradual_typing_spec.rb spec/annotator_phase_completion_spec.rb`

Focused branch coverage from the task coverage run:

- `src/ast/type.rb` operator region (`480..640`): `82.0%` branch
- `src/annotator/phases/auto_finalization.rb`: `96.2%` branch

Decomplex checkpoint:

- Previous task: `5821`
- After task: `5824`
- Assessment: aggregate moved up by `3` findings (`0.05%`). A local
  compatibility-predicate refactor reduced the increase from `4` to `3`.
  Remaining movement is localized to the stricter operator helper branches;
  no unrelated code was changed to offset the metric.

### Duplicate Declarations

Status: complete.

Changed production files:

- `src/annotator/function_registry.rb`
- `src/annotator/phases/signature_registration.rb`
- `src/annotator/phases/type_registration.rb`

Verification:

- `bundle exec prspec spec/annotator_signature_registration_spec.rb spec/annotator_type_registration_spec.rb spec/annotator_function_registry_spec.rb`
- `bundle exec prspec spec/union_spec.rb`
- `bundle exec srb tc`
- `COVERAGE=1 COVERAGE_DIR=tmp/agent-metrics/rust-grade-annotator/coverage-duplicates bundle exec prspec spec/annotator_signature_registration_spec.rb spec/annotator_type_registration_spec.rb spec/annotator_function_registry_spec.rb`

Focused branch coverage from the task coverage run:

- `src/annotator/phases/signature_registration.rb`: `81.2%` branch
- `src/annotator/phases/type_registration.rb`: `89.2%` branch
- `src/annotator/function_registry.rb`: `100.0%` branch

Decomplex checkpoint:

- Previous task: `5824`
- After task: `5834`
- Assessment: aggregate moved up by `10` findings (`0.17%`). The movement is
  localized to duplicate-declaration rejection guards and helper predicates in
  the touched registration files. The increase is not material relative to the
  baseline, and there is no unrelated code change available without weakening
  the diagnostics or hiding the invariant.

### Annotator Session State

Status: complete.

Changed production files:

- `src/annotator/annotator.rb`

Verification:

- `bundle exec prspec spec/annotator_phase_completion_spec.rb`
- `bundle exec srb tc`
- `COVERAGE=1 COVERAGE_DIR=tmp/agent-metrics/rust-grade-annotator/coverage-session bundle exec prspec spec/annotator_phase_completion_spec.rb`

Focused coverage from the task coverage run:

- `src/annotator/annotator.rb` changed range (`523..570`): `100.0%` line,
  `100.0%` branch (`0/0` branch arms)

Decomplex checkpoint:

- Previous task: `5834`
- After task: `5835`
- Assessment: aggregate moved up by `1` finding (`0.02%`). The reset helper
  centralizes existing constructor state initialization and the added call at
  `annotate!` start prevents stale root-scope and function-registry reuse. No
  unrelated code was changed to offset the metric.

### Shared Type Resolution Mutation

Status: complete.

Changed production files:

- `src/ast/scope.rb`

Verification:

- `bundle exec prspec spec/scope_composition_spec.rb`
- `bundle exec srb tc`
- `COVERAGE=1 COVERAGE_DIR=tmp/agent-metrics/rust-grade-annotator/coverage-scope-type-copy bundle exec prspec spec/scope_composition_spec.rb`

Focused coverage from the task coverage run:

- `src/ast/scope.rb` `resolve_full_type` range (`330..350`): `100.0%`
  line, `100.0%` branch (`0/0` branch arms)

Decomplex checkpoint:

- Previous task: `5835`
- After task: `5835`
- Assessment: aggregate stayed flat. `resolve_full_type` now applies
  storage/sync/layout overlays to a copied `Type`, leaving the stored
  `SymbolEntry#type` unchanged for raw type resolution.

### Import, Effect, And Capability Metadata Boundaries

Status: complete.

Changed production files:

- `src/annotator/phases/import_resolution.rb`
- `src/annotator/helpers/function_signature.rb`
- `src/annotator/helpers/function_return.rb`

Verification:

- `bundle exec prspec spec/annotator_import_resolution_spec.rb spec/annotator_spec.rb:2840`
- `bundle exec prspec spec/architecture_invariants_spec.rb:320 spec/architecture_invariants_spec.rb:358 spec/architecture_invariants_spec.rb:392 spec/annotator_import_resolution_spec.rb`
- `bundle exec srb tc`
- `COVERAGE=1 COVERAGE_DIR=tmp/agent-metrics/rust-grade-annotator/coverage-import-boundary bundle exec prspec spec/annotator_import_resolution_spec.rb spec/annotator_spec.rb:2840`

Focused coverage from the task coverage run:

- `src/annotator/phases/import_resolution.rb` changed range (`12..207`):
  `100.0%` line, `88.2%` branch
- `src/annotator/helpers/function_signature.rb` changed range (`424..476`):
  `100.0%` line, `100.0%` branch (`0/0` branch arms)
- `src/annotator/helpers/function_return.rb` changed range (`75..84`):
  `100.0%` line, `100.0%` branch (`0/0` branch arms)

Decomplex checkpoint:

- Previous task: `5835`
- After task: `5847`
- Assessment: aggregate moved up by `12` findings (`0.21%`). The first
  implementation moved up by `252` findings; refactoring signature import
  copying into `FunctionSignature#import_copy` and removing unreachable
  exhaustiveness arms reduced that material regression to a small local
  increase. Imported signatures now copy mutable effect, requirement,
  parameter, and return metadata; imported schemas now copy their mutable
  method/static-method/field/variant containers. Capability consumers remain
  guarded by the existing typed-plan architecture invariants.

## Final Verification

- `bundle exec prspec spec/`: `5771` examples, `0` failures.
- `bundle exec srb tc`: `No errors`.
- Final changed production coverage from
  `tmp/agent-metrics/rust-grade-annotator/coverage-final/.resultset.json`:
  `417/417` changed source lines (`100.0%`) and `134/140` changed branches
  (`95.7%`).
- Final decomplex snapshot:
  `tmp/agent-metrics/rust-grade-annotator/decomplex-final.json`.
  Baseline `5804`, final `5847`, delta `+43` (`0.74%`). The movement is small
  and localized to the new semantic invariants; no unrelated source was changed
  to offset it.
