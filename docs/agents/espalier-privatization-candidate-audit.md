# Espalier Privatization Candidate Audit

Date: 2026-06-11

Source:

- `gems/espalier/architecture.yml`
- `gems/espalier/report.md`
- `Espalier::PrivacyAnalyzer.candidates`

## Final Result

The broad privatization pass is complete.

The starting Espalier privacy report had 1044 candidates. After reviewing the
candidate set owner by owner and making the methods private where they can and
should be private, the regenerated report has 4 remaining candidates.

Closed candidates: 1040 / 1044.

Remaining candidates are deliberate public API or production facts-query API,
not actionable privatization work:

| Method | Disposition | Reason |
|---|---|---|
| `Type#any?` | Keep public | The static manifest cannot infer variable receiver types, but production code calls this on `Type` values through variable receivers, for example `ti.any?` in escape/ownership/lowering code. |
| `FmtVerifier.verify` | Keep public | This is the single-file public verifier API, paired with `verify_dir` and used directly by verifier specs and callers. |
| `CleanupClassifier::FrozenCleanupFacts#entry_for` | Keep public | This is part of the cleanup facts query surface. MIR pass and specs use raw cleanup facts, including missing-entry sentinel behavior. |
| `CleanupClassifier::FrozenCleanupFacts#live_entry_for_node` | Keep public | This is the node-aware live-query companion to `entry_for_node` / `with_live_entry_for_node`; keeping the facts facade public is intentional. |

## What Changed

The pass made helper/protocol methods private across the compiler surface:

- Annotator domains, phases, and helper modules.
- MIR lowering, FSM/thunk transforms, MIR checking/emission, hoist, pipeline helpers, and ownership dataflow helpers.
- Tooling internals for doctor, pprof conversion, completions, formatter verification, migration suggesters, predicate/method rewriters, and stack verification.
- AST/backend/semantic internals where the methods were implementation details rather than model API.
- Final residual helper cleanup in `Type`, `Scope`, `SymbolEntry`, `CapabilityPlan::CapabilityTransition`, `MIRPassState`, `FieldAccessPlan`, pipeline source shape records, ownership snapshots/ids, and inline allocation metadata.

Specs that intentionally characterize internal helpers now use `send`. Public
behavior specs stayed on public entrypoints where practical.

## Review Notes

The last four Espalier rows are useful analyzer limitations rather than privacy
bugs:

- `Type#any?` is a false positive caused by receiver-type limits in static Ruby
  call extraction.
- `FmtVerifier.verify` is a public command/tool API despite having a same-owner
  caller.
- Cleanup facts objects deliberately expose query methods; making them private
  would force production MIR pass code to reach through `send`, which would make
  the boundary worse.

## Verification

Commands run after the final changes:

- `bundle exec prspec --fail-fast`
  - `5792 examples, 0 failures`
- `bundle exec srb tc`
  - `No errors!`
- `git diff --name-only -- '*.rb' | xargs -r -n1 ruby -c`
  - all changed Ruby files reported `Syntax OK`
- `git diff --check`
  - clean
- `ruby gems/espalier/exe/espalier --format yaml --output gems/espalier/architecture.yml src`
  - clean
- `ruby gems/espalier/exe/espalier --manifest gems/espalier/architecture.yml --format report --output gems/espalier/report.md`
  - clean

## Completion Statement

All Espalier privatization candidates were reviewed. Everything that can and
should be private has been made private. The remaining 4 candidates are
intentional public surface or facts-query API and should be handled by analyzer
tuning, not source privatization.
