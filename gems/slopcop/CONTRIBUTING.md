# Contributing To SlopCop

Start with the repository-level [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
This file only covers SlopCop-specific architecture and contribution
rules.

## Architecture

SlopCop is a coverage-gap analyzer built around a few boundaries:

- `lib/slopcop/classifier.rb` classifies uncovered branch arms.
- `lib/slopcop/rollup.rb` aggregates per-file findings and ranks
  genuine gaps.
- `lib/slopcop/report.rb` renders the main Markdown/JSON report.
- `lib/slopcop/sarif.rb` renders report findings for GitHub code
  scanning.
- `lib/slopcop/dark_arm_overlay.rb` emits Lineage source overlays.
- `lib/slopcop/constraints/` owns hazard-specific coverage constraints,
  currently for Zig systems coverage.

SlopCop owns gap categorization. It consumes sibling tools read-only:
Boobytrap for churn, Decomplex for structural deviance and spurious
decision filtering, and Nil-kill evidence where available.

## Adding A Category

Add or change a category only when it changes review behavior. A good
category should explain whether an uncovered arm is a real test target,
a diagnostic path, a defensive branch, a type-contract smell, or a
refactor target.

Required pieces:

- classifier behavior in `SlopCop::Classifier`;
- rollup/report behavior if the category changes ranking or output;
- focused tests under `test/`;
- a short note in `docs/agents/design.md` if the user-facing meaning
  changes.

Do not bake CLEAR-specific helper names into the gem. Project-specific
external boundary methods and diagnostic helpers must stay caller
supplied through CLI options or configuration.

## Coverage Inputs

Coverage parsing and branch-arm normalization belong in Boobytrap.
SlopCop should consume Boobytrap-normalized coverage data rather than
reimplementing coverage parsers.

When adding support for a new coverage source, first ask whether it
belongs in Boobytrap. SlopCop should only need enough adapter logic to
consume the normalized arm/line evidence.

## Constraint Providers

Constraint providers live under `lib/slopcop/constraints/`. A provider
should:

- define stable SARIF rule IDs;
- consume diff and coverage evidence through the shared constraint
  boundary;
- stay advisory by default unless the caller supplies `--strict`;
- include tests for positive findings and accepted evidence.

## Testing

Prefer small fixtures that exercise real coverage shapes when possible.
For report and SARIF changes, test the structured output instead of only
checking rendered Markdown text.
