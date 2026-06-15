# Contributing To Decomplex

Start with the repository-level [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
This file only covers Decomplex-specific architecture and contribution
rules.

## Architecture

Decomplex is a static analyzer built around a small set of boundaries:

- `lib/decomplex/syntax.rb` parses source and exposes normalized
  language facts.
- `lib/decomplex/source_filter.rb` owns source collection and excludes.
- Each metric lives in its own detector file under `lib/decomplex/`.
- `lib/decomplex/report.rb` is the main report aggregation path.
- `lib/decomplex/delta.rb` compares structured snapshots across runs.

Detectors should consume normalized syntax facts where possible. Avoid
making every detector know every language's AST quirks.

## Adding A Metric

Add a metric when it detects a real review pressure that existing
metrics do not already cover. A good Decomplex metric should rank where
to look first, not claim a finding is automatically wrong.

Required pieces:

- detector implementation under `lib/decomplex/`;
- focused tests under `test/`;
- report section in `Decomplex::Report::SECTIONS`;
- a short explanation in `docs/agents/metrics-expo.md`;
- a mention in `README.md` if it is user-facing.

Prefer one clear signal over a broad blended score. If a metric is noisy,
mark it tier 3 or make it supporting evidence for convergence/root-cause
clusters.

## Language Support

New language work should go through the syntax/profile boundary:

- file extension support in `Decomplex::Syntax`;
- Tree-sitter grammar loading;
- language lexicons for false simplicity and other profile-specific
  concepts;
- tests that prove at least one generic report path works on that
  language.

Parser support alone is not launch-ready language support. A new
language needs representative examples and findings that make sense in
that ecosystem.

## Plugin Direction

The planned plugin direction is similar to RuboCop custom cops: a
project should eventually be able to register custom complexity metrics
without editing Decomplex core.

That API is not stable yet. For now, add first-party metrics directly as
detector modules. Keep them small, tested, and report-backed so they can
be moved behind a plugin boundary later.
