# Contributing To Boobytrap

Start with the repository-level [../../CONTRIBUTING.md](../../CONTRIBUTING.md).
This file only covers Boobytrap-specific architecture and contribution
rules.

## Architecture

Boobytrap is a defect-risk hotspot analyzer built around a small set of
boundaries:

- `lib/boobytrap/bugspots.rb` extracts and scores time-decayed fix
  history from git.
- `lib/boobytrap/coverage_data.rb` normalizes coverage inputs.
- `lib/boobytrap/coverage_gap.rb` computes branch and line coverage
  gaps.
- `lib/boobytrap/hotspot.rb` combines fix history with coverage gaps.
- `lib/boobytrap/method_gap.rb` ranks method-level coverage risk.
- `lib/boobytrap/lineage_risk.rb`,
  `lib/boobytrap/test_exposure_facts.rb`, and
  `lib/boobytrap/mutation_facts.rb` consume optional empirical evidence.
- `lib/boobytrap/report.rb` owns report assembly.

Keep scoring logic testable without a real repository when possible.
Git I/O, coverage parsing, ranking math, and Markdown rendering should
stay separate enough that each can be tested directly.

## Adding Evidence

Add evidence only when it improves prioritization. Boobytrap should tell
reviewers where bug risk is concentrated, not become a general static
analysis tool.

Required pieces:

- parser/adapter logic for the evidence source;
- a clear ranking effect in `Report`, `Hotspot`, or method risk;
- focused tests under `test/`;
- README updates if the input is user-facing.

If the evidence explains structural complexity, it probably belongs in
Decomplex. If it classifies uncovered branch arms, it probably belongs
in SlopCop. If it tracks nil/type pressure, it belongs in Nil-kill.

## Testing

Use focused Ruby tests under `gems/boobytrap/test`. Prefer small
synthetic git repositories for end-to-end history behavior and pure unit
tests for scoring math.
