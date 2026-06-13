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
| total `src/` subjects | 133 |
| hard gates | 106 |
| advisory gates | 27 |
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
| `IntrinsicRegistry*` | 55.58% | current implementation no longer supports the stale 98.97% hard-gate claim |
| `Pprof*` | 69.94% | just below the 70% hard-gate floor |
| `LSP::Analyzer*` | 61.88% | below the 70% hard-gate floor |
| `FsmTransform::Emit*` | 51.13% on this branch | improved from a stale 1.33% baseline but still advisory |

## Transpile Tests

The transpile gate applies targeted compiler mutations and runs the precise
`.cht` file that should fail. It writes the generated Zig file directly under
`zig/` so `@import("runtime/...")` resolves the same way as normal
transpile-tests.

Current active mutant:

| mutant | killed by |
|---|---|
| `lower_if_cond_pending_leak` | `transpile-tests/or_fallback_in_if_condition_hoist.cht` |

Current local validation:

```sh
bundle exec ruby tools/mutants/transpile_tests.rb --all --allow-dirty --out /tmp/clear-transpile-mutants-final
```

Result: baseline passed, mutated run failed, mutant killed.

## Fuzz

The fuzz gate keeps the targeted patch-fixture model. Patch files under
`tools/fuzz/mutants/patches/` are intentional mutation fixtures, not scratch
patches. Each one disables one compiler safety rule, runs the relevant fuzz
template before and after the mutation, and requires the mutated compiler to
produce the configured failure delta while the baseline remains clean.

Active mutants:

| mutant | templates | required signal |
|---|---|---|
| `allow_with_alias_return` | `access_gate` | unexpected pass |
| `escape_struct_field_walker` | `nested_loop_escape` | fail |
| `lower_if_cond_pending_leak` | `cond_or_fallback` | fail |
| `cleanup_required_finalizer` | `mir_checker_negative_matrix` | unexpected pass |
| `loop_frame_scope_stamp` | `loop_local_method_temp` | mir-error |

Current local validation:

```sh
bundle exec ruby tools/fuzz/mutants/run.rb --all --allow-dirty --out /tmp/clear-fuzz-mutants-final
```

Result: all five mutants were killed. Every baseline fuzz run reported zero
failures, leaks, MIR errors, and unexpected passes.

## Validation

Additional validation on this branch:

- `bundle exec prspec spec/`: 5,839 examples, 0 failures.
- `bundle exec prspec spec/ --tag integration`: 237 examples, 0 failures.
- `bundle exec srb tc`: no errors.
- Mutation tooling syntax check: all `tools/mutants/**/*.rb` and
  `tools/fuzz/mutants/**/*.rb` parsed successfully.
