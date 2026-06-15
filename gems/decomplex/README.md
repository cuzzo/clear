# Decomplex

![Decomplex](docs/assets/decomplex.png)

Decomplex finds places where code repeats, hides, or half-applies
decisions. It is a static-analysis tool for ranking complexity review:
the output is a candidate list, not a verdict.

It was built inside the CLEAR compiler project to keep a large,
LLM-assisted compiler codebase reviewable. The gem can run outside CLEAR,
but the core design goal is still pragmatic: show the files and methods
where a human review is most likely to pay off.

## What It Finds

Decomplex looks for complexity that ordinary cyclomatic metrics usually
miss:

- repeated guard tuples that should be named once;
- predicates reinvented inline instead of calling the named predicate;
- co-written state where one path writes only half of the pair;
- state-dependent internal call order;
- mutable lifecycle APIs that force callers to know call order;
- helper chains that hide cognitive load behind a small public method;
- locals initialized far before their first meaningful use;
- visible phase breaks inside one function;
- structural Type-2/Type-3 clone pressure;
- code that looks locally simple while hiding IO, mutation, reflection,
  callbacks, dynamic dispatch, or global context.

Start with [docs/agents/metrics-expo.md](docs/agents/metrics-expo.md)
for concrete examples of the metrics.

## Supported Languages

Decomplex now uses a normalized Tree-sitter syntax facade. Ruby has the
most mature profile because it is the original dogfood target. Python,
JavaScript, TypeScript, Go, Rust, and Zig are supported through language
profiles when their Tree-sitter grammars are available.

Parser support is not the same thing as equal signal quality. The
language-neutral metrics work broadly, while language-specific lexicons
and idioms mature per language.

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
