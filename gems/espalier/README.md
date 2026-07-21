# Espalier

Espalier is an architecture-level static analyzer that helps you find
where your codebase is leaking implementation detail, accumulating
mutable lifecycle state, or forcing classes to know too much about each
other.

Decomplex finds function-level complexity. Nil-kill finds type pressure.
Boobytrap and SlopCop find empirical risk and test gaps. Espalier pulls
those signals up to the class/module layer so a human or LLM can review
architecture directly: state ownership, public API surface area,
delegation meshes, and privatization opportunities.

It is used by the CLEAR compiler to minimize architectural complexity
while moving quickly with LLM-assisted development.

- See [DESIGN.md](DESIGN.md) for the architecture model and extraction
  pipeline.
- See [report.md](report.md) for a generated example over CLEAR.

## Getting Started

If you want to contribute, start with the repository-level
[CONTRIBUTING.md](../../CONTRIBUTING.md), then read [DESIGN.md](DESIGN.md)
for Espalier-specific architecture.

### Prerequisites

- Ruby 3.x
- Bundler
- Tree-sitter grammars for any language you want to analyze
- Optional Decomplex, Nil-kill, Boobytrap, or SlopCop evidence

From this repository:

```bash
bundle exec gems/espalier/exe/espalier \
  --format report \
  --nil-kill=tmp/nil-kill/espalier-evidence.json \
  --output=gems/espalier/report.md \
  src/
```

For a narrower run:

```bash
bundle exec gems/espalier/exe/espalier \
  --format report \
  --output=/tmp/espalier.md \
  src/annotator src/ast/type.rb
```

Generate a reusable manifest first, then render the report:

```bash
bundle exec gems/espalier/exe/espalier \
  --format yaml \
  --output=/tmp/architecture.yml \
  src/

bundle exec gems/espalier/exe/espalier \
  --manifest=/tmp/architecture.yml \
  --format report \
  --output=/tmp/espalier-report.md
```

## Outputs

Espalier can output a compact architecture manifest for tools and LLMs,
or a Markdown report for human architectural review.

### Versioned architecture graph

```bash
bundle exec gems/espalier/exe/espalier \
  --format architecture \
  --output=tmp/espalier-architecture.json \
  src/
```

This output contains stable owner/function/state IDs, first-class call and
state-access edges, confidence, source citations, and explainable function
pressure. It is the structured ingestion contract for Lineage; SARIF, DOT, and
human-readable manifests are not parsed to reconstruct the graph.

### Architecture Report

```bash
bundle exec gems/espalier/exe/espalier src \
  --format report \
  --output=report.md
```

The report opens with project prioritization, then ranks state owner
pressure, encapsulation pressure, owner state cohesion, collaboration
meshes, mediator/reification candidates, coordinator/mutator collisions,
conditional delegation hubs, state lifecycle pressure, privatization
candidates, and cross-tool overlap.

### YAML Manifest

```bash
bundle exec gems/espalier/exe/espalier src \
  --format yaml \
  --output=architecture.yml
```

The manifest records class/module ownership, state slots, function
signatures, visibility, reads/writes, internal call graph facts, and
delegations. It is intentionally more compact than full source so it can
be consumed by review tools and LLMs.

### Markdown Manifest

```bash
bundle exec gems/espalier/exe/espalier src \
  --format markdown \
  --output=/tmp/architecture.md
```

The Markdown manifest is the direct human-readable rendering of the
architecture manifest. Use `--format report` when you want ranked
findings instead of a module-by-module inventory.

## Evidence Inputs

Espalier can run from source alone, but its best findings come from
combining structural facts with sibling-gem evidence:

- `--nil-kill FILE`: concrete signatures, type pressure, and fast
  architecture evidence from Nil-kill.
- `--decomplex FILE`: function-level complexity and protocol pressure.
- `--risk FILE`: Boobytrap/SlopCop churn, coverage, and risk evidence.
- `--manifest FILE`: a previously generated Espalier YAML manifest.
- `--fact-mine FILE`: a previously generated `fact-mine.json` static facts file (also honors `ENV["FACT_MINE_FACTS_FILE"]` environment variable to bypass fact extraction runs).
- `--scip-index FILE`: import compiler-proven call identity from a `.scip` file or `scip print --json` export; repeat for multiple build roots. Binary indexes require `scip` on `PATH` (or `SCIP_BINARY`).

Nil-kill evidence is the most important external input today because it
helps Espalier distinguish broad untyped surfaces from intentional typed
interfaces.

## Ranking Big-O by Runtime Criticality

Espalier's Big-O bounds are static: they say which functions can be
expensive, not which ones dominate real workloads. To rank them by what
actually runs hot, feed a runtime profile through Lineage:

1. Profile a representative workload and convert it to
   `profile-hotness/v1` with `gems/lineage/tools/pprof_to_hotness.rb`
   (parses `pprof -top -lines` output and stackprof JSON; tiers functions
   critical/warm/cold by cumulative share).
2. Ingest Espalier findings and the profile into the same database:
   `lineage ingest-sarif` for the Espalier SARIF, `lineage
   ingest-hotness` for the profile (or `bin/lineage-import
   --hotness=hotness.json` for both in one import).
3. Lineage's "Expensive Operations" view then sorts by Big-O first and by
   profiled share within each tier, so a measured-hot `O(N^2)` outranks an
   unprofiled one; critical functions carry a flame icon in the file-view
   outline and a runtime-profile row in the per-line info popup.

Test-run profiles are unrepresentative (mocked I/O, setup-dominated
stacks) - profile production traffic or the benchmark suite instead. See
the "Runtime profiling (pprof) hotness" section of the Lineage README for
the full contract.

## Supported Languages Roadmap

Espalier uses [Tree-Sitter](https://github.com/tree-sitter/tree-sitter)
through Decomplex's normalized syntax facade. Ruby support has been
battle tested to review the CLEAR compiler. Other languages are
experimental and depend on the maturity of their Tree-sitter structural
facts.

- [x] Ruby: used for CLEAR compiler architecture review.
- [ ] Python: experimentally supported.
- [ ] JavaScript: experimentally supported.
- [ ] TypeScript: experimentally supported.
- [ ] Go: experimentally supported.
- [ ] Rust: experimentally supported.
- [ ] Zig: experimentally supported.

## Boundaries

Espalier does not:

- rewrite code;
- prove that a class should be split;
- prove that a method should be private;
- perform whole-program dynamic dispatch resolution;
- replace Decomplex, Nil-kill, Boobytrap, SlopCop, Lineage, mutation,
  fuzzing, coverage, or type checks.

It ranks likely architectural review targets. A good finding should make
a human say: "this is where public API, mutable state, or collaboration
pressure is probably forcing the rest of the system to know too much."

Espalier does not detect lint issues or code smells, as packages for
that already exist in every language.

## Links

- [CLEAR compiler](../../README.md)
- [Decomplex](../decomplex/README.md): identifies complex state and
  control-flow pressure.
- [Nil-kill](../nil-kill/README.md): traces nil and type pressure back
  to its source.
- [Boobytrap](../boobytrap/README.md): ranks latent bug risk from
  semantic churn and under-tested code.
- [SlopCop](../slopcop/README.md): categorizes uncovered branches and
  ranks the true test gaps.
- [Lineage](../lineage/README.md): renders history and verification
  evidence next to source.
