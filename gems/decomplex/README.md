# Decomplex

![Decomplex](docs/assets/decomplex.png)

Decomplex is a cross-language static analyzer that helps you identify
the source of complexity in your codebase and eliminate it.

Linters and Code Smell detectors help you identify surface level issues.
Decomplex does a much deeper analysis to find the structural issues
causing problems *throughout* your codebase. In plain terms, Linters
help you fix individual lines. Decomplex helps you fix your entire
codebase systemically.

- See [Metrics Expo](docs/agents/metrics-expo.md) for concrete examples
  of what Decomplex measures.
- See [What Is Complexity Anyway?](https://cuzzo.github.io/clear/blog/what-even-is-complexity-anyway/)
  for a better understanding of what makes code "complex".

## Getting Started

If you want to contribute, see [CONTRIBUTING.md](CONTRIBUTING.md).

### Prerequisites

- Ruby 3.x
- Bundler
- Tree-sitter grammars for any language you want to analyze

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

Decomplex can output metrics in SARIF format like a linter, a json dump
for an LLM, or a Markdown document for easy human review.

> [!NOTE]
> Decomplex also integrates with [Lineage](../lineage/README.md),
> CLEAR's experimental UI to review LLM-assisted code at scale.

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

Decomplex can generate SARIF 2.1.0 for GitHub code scanning:

```bash
bundle exec gems/decomplex/exe/decomplex report src \
  --output=report.md \
  --sarif=tmp/decomplex.sarif
```

SARIF is generated from the same structured report findings used by
Markdown and delta, so downstream tools do not re-run or re-derive
detectors.

## CI Integration

The current CI-ready path is:

1. generate a Markdown report artifact;
2. generate a JSON baseline snapshot;
3. run `decomplex delta` on PRs;
4. fail or warn only on new/growing high-confidence findings.

> [!NOTE]
> See
> [CLEAR's GitHub Config](https://github.com/cuzzo/clear/blob/lineage-complexity-ui/.github/workflows/ci.yml#:~:text=generalized-gems-sarif%3A)
> for how to include it as Pull Request review helper, or part of your
> Continuous Integration workflow.

## Supported Languages Roadmap

Decomplex uses [Tree-Sitter](https://github.com/tree-sitter/tree-sitter)
to support multiple languages. Ruby support has been battle tested to
develop the CLEAR compiler. Zig support is currently being used for the
CLEAR runtime. Other languages are currently experimental.

- [x] Ruby: fully supported.
- [ ] Python: experimentally supported.
- [ ] JavaScript: experimentally supported.
- [ ] TypeScript: experimentally supported.
- [ ] Go: experimentally supported.
- [ ] Rust: experimentally supported.
- [ ] Zig: experimentally supported.

## Boundaries

Decomplex does not:

- rewrite code;
- prove that a finding is a bug;
- perform whole-program CFG or pointer-alias analysis;
- infer types or nilability;
- replace mutation, fuzz, coverage, or type checks.

It ranks likely review targets. A good finding should make a human say:
"this is where the design pressure is coming from."

Decomplex does not detect lint issues or code smells, as packages for
that already exist in every language.

## Links

- [CLEAR compiler](../../README.md)
- [SlopCop](../slopcop/README.md): categorizes uncovered branches and
  ranks the true test gaps.
- [Nil-kill](../nil-kill/README.md): traces nil and type pressure back
  to its source.
