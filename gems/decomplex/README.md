# Decomplex

![Decomplex](docs/assets/decomplex.png)

Decomplex is a set of metrics that help identify complex code and ways
to mitigate it. It is used in the development of the CLEAR compiler and
runtime to have LLMs write quality code at scale with high velocity.

For the model behind the metrics, see
[What even is complexity anyway?](../../docs/retrospective/what-even-is-complexity-anyway.md).
For concrete examples of what Decomplex finds, see the
[Metrics Expo](docs/agents/metrics-expo.md).

## Quick Start

From this repository:

```bash
bundle exec gems/decomplex/exe/decomplex report src --output=gems/decomplex/report.md
```

For a narrower run:

```bash
bundle exec gems/decomplex/exe/decomplex report src/annotator src/ast/type.rb --output=/tmp/decomplex.md
```

For one targeted metric:

```bash
bundle exec gems/decomplex/exe/decomplex wicc src --output=/tmp/wicc.md
bundle exec gems/decomplex/exe/decomplex locality-drag src --output=/tmp/locality-drag.md
bundle exec gems/decomplex/exe/decomplex implicit-control-flow src --output=/tmp/icf.md
```

## Outputs

### Markdown Report

The main output is a Markdown report:

```bash
bundle exec gems/decomplex/exe/decomplex report src --output=report.md
```

The report opens with cross-detector convergence and root-cause
clusters, then lists each detector section by signal tier. See
[report.md](report.md) for a generated example over CLEAR.

### Baseline And Delta

Decomplex can emit a JSON snapshot for later comparison:

```bash
bundle exec gems/decomplex/exe/decomplex report src \
  --output=report.md \
  --emit-json=tmp/decomplex-baseline.json
```

Then compare a later run:

```bash
bundle exec gems/decomplex/exe/decomplex delta tmp/decomplex-baseline.json src
```

The delta path is intended for CI ratchets and PR review: line-only
movement is treated as persisted instead of new debt.

### SARIF

SARIF/code-scanning output is part of the Decomplex launch plan, but it
is not implemented in this branch yet. The intended shape is a SARIF
adapter over the same structured report findings used by Markdown and
delta, so GitHub code scanning can surface high-confidence Decomplex
findings inline.

Track this in [TODO.md](TODO.md).

### CI Integration

The current CI-ready path is:

1. generate a Markdown report artifact;
2. generate a JSON baseline snapshot;
3. run `decomplex delta` on PRs;
4. fail or warn only on new/growing high-confidence findings.

GitHub Actions SARIF upload is planned after SARIF generation lands.
Until then, Decomplex is best used as an artifact plus review comment or
ratchet input.

## Supported Languages Roadmap

Decomplex uses a normalized Tree-sitter syntax facade. Parser support is
not the same thing as equal metric quality: Ruby has the strongest
dogfood coverage today, while other languages are still experimental.

- [x] Ruby: fully supported.
- [ ] Python: experimentally supported.
- [ ] JavaScript: experimentally supported.
- [ ] TypeScript: experimentally supported.
- [ ] Go: experimentally supported.
- [ ] Rust: experimentally supported.
- [ ] Zig: experimentally supported.

## Metrics

The full report currently includes:

- Decision Pressure
- Redundant Nil Guards
- State Heatmap
- State-Based Branch Density
- Temporal Ordering Pressure
- Missing Abstractions
- Reification Misses
- Semantic Predicate Aliases
- Exact Predicate Aliases
- Inconsistent Rename Clones
- Structural Similarity Type-2/Type-3
- Neglected Updates
- Derived-State Staleness
- Neglected Conditions
- Neglected Path Conditions
- Oversized Predicates
- Broken Protocols
- Implicit Control Flow
- Weighted Inlined Cognitive Complexity
- Locality Drag
- Operational Discontinuity
- Function LCOM
- False Simplicity
- Fat Unions

The practical reading order is:

1. Cross-Detector Convergence
2. Root-Cause Clusters
3. Tier 1 metrics
4. Tier 2 metrics
5. Tier 3 metrics only when they overlap with other evidence

## Architecture

Decomplex is deliberately small:

- `Decomplex::Syntax` owns parsing and normalized language facts.
- Each detector is a separate module under `lib/decomplex/`.
- `Decomplex::Report` is the single Markdown aggregation path.
- `Decomplex::Delta` compares structured snapshots.
- Language behavior belongs in syntax/profile adapters, not in detector
  forks.

The long-term plugin direction is similar in spirit to RuboCop custom
cops: users should be able to add project-specific complexity metrics
without editing Decomplex core. That plugin API is planned, not stable
yet. Today, new metrics should be implemented as normal detector modules
with tests and a report section.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for Decomplex-specific notes, and
the repository-level [../../CONTRIBUTING.md](../../CONTRIBUTING.md) for
the broader CLEAR contribution rules.

## Boundaries

Decomplex does not:

- rewrite code;
- prove that a finding is a bug;
- perform whole-program CFG or pointer-alias analysis;
- infer types or nilability;
- replace mutation, fuzz, coverage, or type checks.

It ranks likely review targets. A good finding should make a human say:
"this is where the design pressure is coming from."

## Links

- [Metrics expo](docs/agents/metrics-expo.md)
- [Design notes](docs/agents/design.md)
- [Cross-language notes](docs/agents/cross-language.md)
- [False simplicity](docs/false-simplicity.md)
- [Generated CLEAR report](report.md)
