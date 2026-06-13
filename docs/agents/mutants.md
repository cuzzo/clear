# Mutants Gate

This branch turns mutation testing on for the three test surfaces that carry
compiler correctness:

- Ruby specs: `tools/mutants/ruby_specs.rb`
- transpile-tests: `tools/mutants/transpile_tests.rb`
- fuzz templates: `tools/fuzz/mutants/run.rb`

## Ruby Specs

The Ruby gate uses `mutant --zombie run` with a threshold ratchet. It does not
require zero alive mutants yet; several important compiler subjects still have
known test gaps. The gate fails when a hard-gated subject selected by `--since`
cannot produce a summary, has no selected tests, drops below its baseline, or
exceeds its timeout budget. Advisory subjects still run and report coverage, but
do not block CI until they are promoted.

The subject matrix lives in `tools/mutants/src_subjects.yml`.

Current matrix:

| group | count |
|---|---:|
| total `src/` subjects | 157 |
| hard gates | 139 |
| advisory gates | 18 |
| `MIRLowering#method` subjects | 89 |

Important implementation details:

- Method subjects use exact expressions such as `MIRLowering#lower`; class and
  module subjects use `Subject*`.
- The runner uses zombie mode because this project defines `AST::Node` as a
  Sorbet type alias, which collides with the `ast` gem's printer in plain mutant
  mode after project code loads.
- Utility modules that were written with `module_function`/`extend self` were
  converted to explicit singleton methods so mutant mutates the methods the specs
  actually call.
- Spec `require_relative` lines that load `src/` or `tools/` files are guarded
  so RSpec does not reload the original source over mutant's patched code.

Current local validation:

```sh
MUTANT_JOBS=32 bundle exec ruby tools/mutants/ruby_specs.rb --since HEAD --out /tmp/clear-ruby-mutants-full-2
```

Result: exit 0. Hard-gated changed subjects passed; untouched subjects skipped;
advisory subjects reported current ratchet coverage.

Notable current advisory weak spots:

| subject | current ratchet | reason |
|---|---:|---|
| `Type*` | 24.86% | broad value-object facade; exact high-risk methods should be promoted separately |
| `CleanupClassifier*` | 31.97% | broad classifier module; exact cleanup methods need stronger focused gates |
| `EscapeAnalysis*` | 32.58% | broad analysis module; key entrypoints are already hard-gated |
| `PipelineRewriter*` | 33.01% | broad rewriter surface; needs focused method gates before hard promotion |
| `MIREmitter*` | 39.56% | broad emitter surface; `MIREmitter#emit` is hard-gated at 99.73% |
| `FsmWrapperEmitter*` | 49.13% | broad emitter surface; `FsmWrapperEmitter.render` is hard-gated at 100% |
| `FsmTransform::Emit*` | 1.33% | broad module subject is too coarse; focused emit methods are hard-gated |

## Transpile Tests

The transpile gate applies targeted compiler mutations and runs the precise
`.cht` file that should fail. It writes the generated Zig file directly under
`zig/` so `@import("runtime/...")` resolves the same way as normal
transpile-tests.

Current active mutants:

| mutant | killed by |
|---|---|
| `lower_if_cond_pending_leak` | `transpile-tests/or_fallback_in_if_condition_hoist.cht` |
| `escape_struct_field_walker` | `transpile-tests/200_escape_callee_string_to_list.cht` |
| `loop_frame_scope_stamp` | `transpile-tests/while_loop_with_local_split_no_rewind.cht` |
| `union_match_drops_payload_capture` | `transpile-tests/174_union_match_struct_fields.cht` |
| `fsm_suspend_returns_done` | `transpile-tests/256_sleep_int_literal.cht` |

Current local validation:

```sh
bundle exec ruby tools/mutants/transpile_tests.rb --all --allow-dirty --out /tmp/clear-transpile-mutants-a-level-3
```

Result: all five mutants were killed. Every baseline transpile-test passed; every
mutated run failed. This is a useful integration mutation gate, but it is not
yet A-level corpus mutation coverage because the active registry is still small
and hand-targeted.

## Fuzz

The fuzz gate keeps the targeted patch-fixture model. Patch files under
`tools/fuzz/mutants/patches/` are intentional mutation fixtures, not scratch
patches. Each one disables one compiler safety rule, runs the relevant fuzz
template before and after the mutation, and requires the mutated compiler to
produce the configured failure delta while the baseline remains clean.

This is now A- quality for the current compiler phase: it covers parser/
annotator policy, escape analysis, MIR ownership verification, lifetime facts,
lowering order, FSM suspension, union payload binding, and runtime/codegen move
guard emission. It is still not A+ because it is a curated invariant registry,
not native language-level mutation over every `.cht` program.

Active mutants:

| mutant | templates | required signal |
|---|---|---|
| `allow_with_alias_return` | `access_gate` | unexpected pass |
| `escape_struct_field_walker` | `nested_loop_escape` | fail |
| `lower_if_cond_pending_leak` | `cond_or_fallback` | fail |
| `cleanup_required_finalizer` | `mir_checker_negative_matrix` | unexpected pass |
| `loop_frame_scope_stamp` | `loop_local_method_temp` | mir-error |
| `mir_checker_linear_use_after_transfer` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_inline_alloc_mismatch` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_aggregate_child_alloc` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_cleanup_source_owns` | `mir_checker_negative_matrix` | unexpected pass |
| `mir_checker_call_contracts` | `mir_checker_negative_matrix` | unexpected pass |
| `hold_lock_across_yield_policy` | `diagnostic_policy_matrix` | unexpected pass |
| `fn_type_reentrant_constraint` | `diagnostic_policy_matrix` | unexpected pass |
| `tight_loop_admission_policy` | `diagnostic_policy_matrix` | unexpected pass |
| `move_mark_emission` | `call_ownership_contract_matrix`, `takes_move_modality`, `cleanup_control_matrix` | fail |
| `capture_promise_handle_by_value` | `promise_handle_capture` | mir-error |
| `bg_lifetime_all_captures_independent` | `lifetimed_return` | unexpected pass |
| `union_match_drops_payload_capture` | `union_lowering_cleanup_matrix` | fail |
| `fsm_suspend_returns_done` | `fsm_suspension_matrix` | fail |

Current local validation:

```sh
bundle exec ruby tools/fuzz/mutants/run.rb --all --out /tmp/clear-fuzz-mutants-a-level-4
```

Result: all eighteen mutants were killed. Every baseline fuzz run reported zero
failures, leaks, MIR errors, and unexpected passes.

## Transpile Tests To A-Level

The current transpile mutant gate is useful but still C+/B- quality: it proves
five hand-picked compiler patch mutants against five `.cht` files. That is too
small to validate the transpile corpus as a whole.

The easiest credible path to A-level is native CLEAR-source mutation tooling:

1. Add a `clear mutant` runner that operates on `.cht` source programs.
2. Start with deterministic source/AST mutation operators:
   - boolean and comparison operator flips;
   - arithmetic operator flips;
   - branch condition negation;
   - assertion literal/value perturbation;
   - `OR` fallback/raise action swaps;
   - ownership marker changes around `COPY`, `GIVE`, `TAKES`, and bare args;
   - effect/reentrancy annotation changes;
   - sync/storage qualifier perturbations;
   - type annotation weakening/removal where syntax remains valid.
3. For each transpile-test file, generate a small bounded mutant set, run the
   existing transpile-test path, and require each non-equivalent mutant to fail
   by compile error, assertion failure, runtime failure, leak, or MIR error.
4. Record equivalent mutants explicitly with file/operator/reason; do not hide
   them in broad baseline percentages.

Native CLEAR mutation would not eliminate the need to mutation-test
`transpile-tests/`; it would make that mutation test meaningful. The
`transpile-tests/` corpus remains the integration oracle. Native mutation also
does not replace compiler-internal patch mutants for fuzz, because source-level
mutants cannot prove that a specific MIRChecker rule, escape-analysis invariant,
or emitter marker is load-bearing. The two layers should coexist:

- CLEAR-source mutants: prove corpus assertions and expected failures are
  load-bearing.
- Compiler patch mutants: prove internal compiler safety checks are
  load-bearing.

## Validation

Additional validation on this branch:

- `bundle exec prspec spec/`: 5,839 examples, 0 failures.
- `bundle exec prspec spec/ --tag integration`: 237 examples, 0 failures.
- `bundle exec srb tc`: no errors.
- Mutation tooling syntax check: all `tools/mutants/**/*.rb` and
  `tools/fuzz/mutants/**/*.rb` parsed successfully.
