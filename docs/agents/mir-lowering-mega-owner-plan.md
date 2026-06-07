# MIR Lowering Mega-Owner Plan

This is the implementation record for
`1. MIR Lowering Is A Mega-Owner And Implicit State Machine` in
`docs/agents/remaining-architectural-issues.md`.

The objective was to stop treating `MIRLowering` as one broad mutable compiler
phase owner. The refactor moved state into typed phase owners, turned several
stateful helpers into typed plan builders, removed dynamic lowerer reflection,
and made downstream consumers use explicit typed APIs.

## Acceptance Criteria

- Decomplex is checked after each implementation phase.
- SlopCop and nil-kill are regenerated at the end against the pre-refactor
  baseline.
- New and changed code is strongly typed. Untyped slots must stay flat or go
  down.
- Downstream inputs and consumers are upgraded to strong typed contracts where
  the refactor exposes a better type boundary.
- New and changed lines have 100% coverage. Changed branches target 80% or
  better coverage.
- Final metrics should show a decisive reduction in state-owner pressure,
  temporal ordering pressure, dark arms, genuine gaps, untyped slots, and
  hash-record pressure. Some noisy detector movement is expected when broad
  behavior is split into typed helpers.

## Baseline

Captured before implementation on branch `src-hardening`.

- Decomplex report: `/tmp/mir-owner-baseline-decomplex.md`
- Decomplex JSON: `/tmp/mir-owner-baseline-decomplex.json`
- SlopCop report: `/tmp/mir-owner-baseline-slopcop.md`
- Nil-kill baseline: `/tmp/pipeline-host-final-nil-kill.md`

Key baseline signals:

- Decomplex total candidates: `7300`
- `MIRLowering` temporal ordering pressure:
  - public methods: `161`
  - state methods: `35`
  - writers: `13`
  - fields: `57`
  - shared fields: `20`
  - implicit states: `2^57`
  - score: `13196`
- `src/mir/mir_lowering.rb`: `13` detectors across `110` methods.
- SlopCop dark arms: `3287`
- SlopCop genuine gaps: `1342`
- Nil-kill untyped params/returns/fields/collections:
  `981 / 228 / 1017 / 0`
- Nil-kill hash-record struct candidates: `184` candidates,
  `285` pressure records.

## Completed Phases

### Phase 1: Typed Schema Owner

Status: complete.

- [x] Added `MIRLoweringSchemas` for struct, union, enum, and schema lookup
  behavior.
- [x] Replaced direct `@struct_schemas`, `@union_schemas`, `@enum_schemas`,
  and `@schema_lookup` use in MIR lowering with typed reader methods.
- [x] Removed stale `instance_variable_get(:@schema_lookup)` consumers.
- [x] Added focused tests for schema registration, lookup, and downstream
  cleanup lookup behavior.

Result:

- Decomplex total moved `7300 -> 6704` at the first full checkpoint after the
  schema and early state extraction work.
- Direct schema ivars no longer belong to the mega-owner.

### Phase 2: Typed Counter Owner

Status: complete.

- [x] Added `MIRLoweringCounters` with typed next-id methods for temporaries,
  block expressions, safe navigation, externs, lambdas, streams, loops, and
  for-loop helpers.
- [x] Replaced `@tmp_counter`, `@block_expr_counter`, `@safe_nav_counter`,
  `@extern_counter`, `@lambda_counter`, `@stream_lit_counter`,
  `@do_block_counter`, `@bg_block_counter`, `@stream_gen_counter`,
  `@loop_mark_counter`, and `@for_counter`.
- [x] Updated tests to assert behavior through public lowering results or typed
  helper APIs.

Result:

- `MIRLowering` fields dropped from `57` to the mid-40s during this phase.
- `MIRLowering` writer count dropped from `13` to `6`.
- Generated-name lifecycles no longer participate in the broad lowerer state
  machine.

### Phase 3: Function-Scoped Lowering State

Status: complete.

- [x] Added `MIRLoweringFunctions::FunctionState` for current bindings,
  binding types, pending statements, declaration allocation, expected type,
  sink type, function context, rename maps, and cleanup-name state.
- [x] Replaced direct reads and writes of `@current_*`, pending statement,
  declaration allocation, and function-local cleanup state with typed state
  owner APIs.
- [x] Made function entry and exit explicit through `activate!`.
- [x] Propagated the stronger function-state boundary through downstream
  lowering modules.

Result:

- The original `MIRLowering` temporal-ordering entry disappeared from the final
  repo-wide Decomplex report.
- Function-local mutable state is now scoped and named instead of implicit on
  the mega-owner.

### Phase 4: Ownership Scanner

Status: complete.

- [x] Moved `collect_moved_arg_roots`, `walk_ast_for_moved_args`, and
  `transfer_binding_name` into `MIRLoweringOwnershipScanner`.
- [x] Returned typed moved-root data instead of depending on broad lowerer
  mutation.
- [x] Updated ownership consumers to ask the scanner for facts explicitly.
- [x] Added direct coverage for nested calls, arrays, hashes, field access,
  method calls, and non-ownership-bearing values through MIR gap and lowering
  specs.

Result:

- The highest-pressure ownership scan behavior no longer has direct access to
  broad lowerer lifecycle state.

### Phase 5: Plan-Returning Lowering Helpers

Status: complete.

- [x] Extracted typed hash literal lowering plans from `lower_hash_lit`.
- [x] Extracted typed assignment plans from `lower_assignment`.
- [x] Extracted typed branch and match facts from `lower_match` and if-chain
  lowering.
- [x] Added allocator and cleanup predicates (`CleanupEntry#heap?`,
  `CleanupEntry#frame?`, `MIR::Placement.explicit_heap?`,
  `MIR::Placement.explicit_frame?`) so call sites no longer repeat raw state
  comparisons.
- [x] Propagated strong types through consumers and signatures.

Result:

- Reification misses dropped from `26` to `6`.
- Neglected updates dropped from `1156` to `685`.
- Neglected path conditions dropped from `1663` to `1581`.

### Phase 6: Delete Legacy Broad-State Protocols

Status: complete.

- [x] Removed production dynamic lowerer reflection in migrated MIR lowering
  and FSM transform code.
- [x] Removed dynamic `@extern_method` stamping and used the typed
  `extern_call` flag.
- [x] Removed slice `@exclusive` reflection by making slice exclusivity an AST
  constructor field.
- [x] Removed dead `@ast_fn` metadata stamping from imported BC helper
  functions.
- [x] Replaced FSM transform lowerer ivar access with
  `with_fsm_segment_lowering_context` and typed result-transfer accessors.
- [x] Replaced recursive-splitter hidden context ivars with explicit context
  threading and a typed `Builder::Finalized` result.

Result:

- `MIRLowering` no longer appears in Temporal Ordering Pressure.
- Production `src/mir/lowering`, `src/mir/mir_lowering.rb`,
  `src/mir/fsm_transform/emit.rb`, and
  `src/mir/fsm_transform/recursive_splitter.rb` no longer use migrated
  lowerer `instance_variable_get` or `instance_variable_set` paths.

## Decomplex Checkpoints

The final checkpoint was generated with:

```sh
bundle exec ruby gems/decomplex/exe/decomplex report src \
  --output=/tmp/mir-owner-final-decomplex.md \
  --emit-json=/tmp/mir-owner-final-decomplex.json
```

| Metric | Baseline | Final | Delta |
| --- | ---: | ---: | ---: |
| Total candidates | 7300 | 6773 | -527 |
| Cross-detector convergence | 1821 | 1803 | -18 |
| Root-cause clusters | 496 | 494 | -2 |
| Decision Pressure | 296 | 288 | -8 |
| State Heatmap | 596 | 582 | -14 |
| State-Based Branch Density | 1583 | 1587 | +4 |
| Temporal Ordering Pressure | 14 | 14 | 0 |
| Missing Abstractions | 193 | 191 | -2 |
| Reification Misses | 26 | 6 | -20 |
| Semantic Predicate Aliases | 5 | 5 | 0 |
| Exact Predicate Aliases | 14 | 14 | 0 |
| Inconsistent Rename Clones | 71 | 71 | 0 |
| Flay Similarity | 48 | 50 | +2 |
| Neglected Updates | 1156 | 685 | -471 |
| Derived-State Staleness | 143 | 143 | 0 |
| Neglected Conditions | 11 | 11 | 0 |
| Neglected Path Conditions | 1663 | 1581 | -82 |
| Oversized Predicates | 9 | 9 | 0 |
| Broken Protocols | 559 | 576 | +17 |
| False Simplicity | 902 | 949 | +47 |
| Fat Unions | 11 | 11 | 0 |

Interpretation:

- The architectural target was the mega-owner, not a cosmetic method split.
  That target is complete: `MIRLowering` disappeared from temporal ordering
  pressure and its broad state surface was replaced by typed phase owners.
- The decisive wins are total candidates, reification misses, neglected
  updates, neglected path conditions, and state heatmap.
- The remaining regressions are in noisy protocol/simplicity detectors. They
  are expected side effects of introducing typed helper APIs and explicit FSM
  boundaries, but they are tracked for final triage.
- `State-Based Branch Density` rose by `4` globally. The MIR owner refactor
  reduced the hidden state machine, but the newly explicit helper decisions are
  still branch-heavy and should be the next targeted design pressure if this
  area is revisited.

## SlopCop Final Checkpoint

| Metric | Baseline | Final | Delta |
| --- | ---: | ---: | ---: |
| Files | 122 | 123 | +1 |
| Dark arms | 3287 | 3220 | -67 |
| Genuine gaps | 1342 | 1327 | -15 |
| type_norm | 930 | 920 | -10 |
| dead | 74 | 64 | -10 |
| defensive | 49 | 48 | -1 |
| spurious | 84 | 79 | -5 |
| ffi | 0 | 0 | 0 |
| diagnostic | 808 | 782 | -26 |

## Nil-Kill Final Checkpoint

Final collection completed in `1069s` and the report was generated at
`/tmp/mir-owner-final-nil-kill.md`.

| Metric | Baseline | Final | Delta |
| --- | ---: | ---: | ---: |
| Methods indexed | 4520 | 4626 | +106 |
| Runtime-observed methods | 1152 | 1135 | -17 |
| Missing sigs | 91 | 91 | 0 |
| Existing sigs | 4429 | 4535 | +106 |
| Existing/candidate `T.let` sites | 1337 | 1109 | -228 |
| Sorbet errors captured | 0 | 0 | 0 |
| Param inputs strong | 4478 | 4620 | +142 |
| Param inputs weak | 122 | 122 | 0 |
| Param inputs untyped | 981 | 942 | -39 |
| Returns strong | 2898 | 2989 | +91 |
| Returns weak | 32 | 31 | -1 |
| Returns untyped | 228 | 225 | -3 |
| Struct/class fields & ivars strong | 849 | 798 | -51 |
| Struct/class fields & ivars weak | 25 | 23 | -2 |
| Struct/class fields & ivars untyped | 1017 | 860 | -157 |
| Arrays/Sets/Hashmaps strong | 1447 | 1468 | +21 |
| Arrays/Sets/Hashmaps weak | 516 | 500 | -16 |
| Arrays/Sets/Hashmaps untyped | 0 | 0 | 0 |
| Nil Source Fixes | 207 | 206 | -1 |
| Union / `T.any` candidates | 596 | 586 | -10 |
| Hash record candidates / pressure records | 184 / 285 | 183 / 281 | -1 / -4 |

Untyped slots stayed flat or dropped in every category. The weaker collection
surface improved, and hash-record pressure moved down.

## Final Verification Checklist

- [x] Full repo Decomplex regenerated.
- [x] Targeted Ruby specs with coverage.
- [x] Diff coverage bucket summary and source type guardrails.
- [x] Final SlopCop report.
- [x] Final nil-kill collection, inference, and report.
- [x] Final before/after metric table in the assistant report.

Coverage closure:

- `bundle exec srb tc`: no errors.
- `COVERAGE=1 bundle exec rspec`: `5523` examples, `0` failures; global line
  coverage `99.24%`, branch coverage `84.76%`.
- Direct working-tree coverage audit: changed executable source lines
  `1371 / 1371` covered (`100.0%`); changed branch arms `507 / 589` covered
  (`86.08%`).
- New owner files under `src/mir/lowering/` have `100.0%` executable-line
  coverage and contain no `T.untyped` signatures or fields.
