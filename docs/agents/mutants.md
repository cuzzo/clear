# Mutants Gate

This branch turns mutation testing on for the three test surfaces that carry
compiler correctness:

- Ruby specs: `tools/mutants/ruby_specs.rb`
- transpile-tests: `tools/mutants/transpile_tests.rb`
- fuzz templates: `tools/fuzz/mutants/run.rb`

## Ruby Specs

The direct Ruby gate uses the `mutant` gem with a threshold ratchet, not a
zero-alive requirement. Several important compiler subjects have known alive
mutants today, so requiring 100% would block useful work on pre-existing test
gaps. The gate still fails if a selected subject has no selected tests, drops
below its baseline threshold, or exceeds its timeout budget. Small timeout
budgets are explicit because mutant timeouts can vary under load even when the
coverage signal is stable.

Current subjects:

| subject | spec | baseline |
|---|---|---:|
| `MIR::InlineAllocMetadata*` | `spec/mir_gap_burn_spec.rb` | 92.28% full, 92.02% with this PR's `--since` range |
| `Lexer*` | `spec/lexer_spec.rb` | 76.28% |

CI runs the wrapper with `--since ${{ github.event.pull_request.base.sha }}` so
future PRs mutate only changed methods within the listed subjects. A subject not
touched by the PR is reported as skipped with 0 selected mutations.

Known pitfall: `module_function` modules are not reliable direct mutant subjects
in this codebase. Mutant mutates module instance methods, while specs usually
call the copied singleton methods, producing false alive mutants. Those subjects
should be tested by targeted patch mutants or after the subject shape is changed.

## Transpile Tests

The transpile gate applies targeted compiler mutations and runs the precise
`.cht` file that should fail. It writes the generated Zig file directly under
`zig/` so `@import("runtime/...")` resolves the same way as normal
transpile-tests.

Current active mutant:

| mutant | killed by |
|---|---|
| `lower_if_cond_pending_leak` | `transpile-tests/or_fallback_in_if_condition_hoist.cht` |

Local validation on this branch:

```sh
bundle exec ruby tools/mutants/transpile_tests.rb --all --allow-dirty
```

Result: baseline passed, mutated run failed, mutant killed.

## Fuzz

The fuzz gate keeps the existing targeted patch model and now runs in CI. Active
mutants are only the patches that still map to current architecture:

| mutant | templates | local signal |
|---|---|---|
| `allow_with_alias_return` | `access_gate` | 12 new unexpected passes |
| `lower_if_cond_pending_leak` | `cond_or_fallback` | 1 new failure |
| `cleanup_required_finalizer` | `mir_checker_negative_matrix` | 1 new unexpected pass |

Retired from the active registry: old LoopFrameAnalysis mutants
`escape_struct_field_walker` and `local_frame_decls_frame_predicate`. Their
patches targeted pre-refactor methods that no longer exist. Re-adding those
invariants should be done as new patches against the current
`MIR::LocalBindingAnalysis` / loop-frame fact flow, not by keeping stale patches
in the gate.
