# Decomplex CodeQL Replacement Epic

Goal: replace decomplex internals that are reimplementing generic Ruby graph or
AST extraction with CodeQL-backed facts. Keep decomplex's product value:
ranking, convergence, root-cause clustering, report wording, and the
"ranked candidate, not verdict" discipline.

The motivation is practical. We should not maintain hand-rolled RubyVM AST
walkers for questions CodeQL already answers better: field reads/writes, call
sites, method boundaries, decision spans, and eventually data/control-flow
relationships. If CodeQL cannot supply a replacement with acceptable precision,
runtime, or installation ergonomics, stop and record the blocker instead of
porting complexity into a new shape.

## Current Starting Point

The first CodeQL experiment is committed in:

- `tools/codeql_state_flow.rb`
- `tools/codeql/StateFieldAccess.ql`
- `tools/codeql/CallEdges.ql`
- `tools/codeql/README.md`

Validated locally with CodeQL 2.21.4:

- Ruby database creation succeeded.
- `StateFieldAccess.ql` produced a `src/` report with 4542 state-access rows.
- `CallEdges.ql` compiled but was too slow for the default full-repo workflow;
  keep it opt-in until narrowed or replaced by a cheaper query.

Initial CodeQL signal overlaps decomplex/nil-kill pressure:

- `SemanticAnnotator#visit_ReturnNode`: heavy `value`.
- `PipeAnalysis#analyze_concurrent_op`: heavy `left` / `right`.
- `PipelineHost#substitute_placeholders`: heavy `name`.
- `MIRLoweringVariables#lower_var_decl_init`: heavy `value`.
- Broad state channels: `storage`, `sync`, `target`, `expr`, `emit`,
  `result_type`.

## 2026-05-31 StateMesh Spike Result

Implemented:

- `tools/codeql_state_flow.rb` now emits `facts.json` with schema
  `decomplex-codeql-facts/v1`.
- `StateFieldAccess.ql` discovers state fields from setter calls and instance
  variable writes instead of a hand-curated field list.
- `Decomplex::CodeqlFacts` validates and filters CodeQL fact rows.
- `Decomplex::StateMesh.from_codeql_facts` imports CodeQL facts into the
  existing StateMesh metrics/JSON shape.
- `decomplex state-mesh --codeql-facts=PATH` emits a CodeQL-backed graph.
- `decomplex state-mesh --compare-codeql --codeql-facts=PATH FILES...` emits a
  RubyVM-vs-CodeQL extraction comparison.

Current measured comparison on `src/` after rebuilding the CodeQL database:

| extractor | writes | reads | written fields |
| --- | ---: | ---: | ---: |
| RubyVM StateMesh | 2262 | 8529 | 593 |
| CodeQL facts | 2250 | 11538 | 589 |

High-pressure field comparison:

| field | RubyVM w/r | CodeQL w/r | delta w/r |
| --- | ---: | ---: | ---: |
| `name` | 3 / 1106 | 3 / 1084 | 0 / -22 |
| `value` | 12 / 833 | 12 / 834 | 0 / +1 |
| `type` | 11 / 444 | 11 / 494 | 0 / +50 |
| `body` | 25 / 322 | 23 / 320 | -2 / -2 |
| `token` | 2 / 226 | 2 / 228 | 0 / +2 |
| `left` | 3 / 275 | 3 / 269 | 0 / -6 |
| `symbol` | 11 / 161 | 11 / 139 | 0 / -22 |
| `right` | 3 / 237 | 3 / 238 | 0 / +1 |
| `target` | 9 / 194 | 9 / 199 | 0 / +5 |
| `raw` | 4 / 224 | 4 / 226 | 0 / +2 |
| `storage` | 94 / 68 | 90 / 161 | -4 / +93 |
| `sync` | 27 / 111 | 25 / 157 | -2 / +46 |
| `result_type` | 50 / 35 | 50 / 80 | 0 / +45 |
| `layout` | 15 / 34 | 15 / 50 | 0 / +16 |
| `ownership` | 35 / 71 | 32 / 91 | -3 / +20 |

Evaluation:

- Worth keeping as a CodeQL facts export and dual-run comparison path.
- Not yet worth deleting the RubyVM StateMesh walker. Write extraction is close
  enough to be useful; read extraction is broader because CodeQL sees explicit
  zero-argument receiver calls that the current RubyVM walker misses or treats
  differently. That improves recall but adds noise for generic state names like
  `length`, `size`, `params`, `object`, and `index`.
- The best immediate follow-up is CoUpdate write extraction. This spike shows
  CodeQL can extract write sites with near-parity and stable spans, which is the
  exact part CoUpdate needs. StateMesh read replacement should wait until
  receiver text/type filtering is better.
- Runtime is acceptable after database creation: cached query compilation was
  reused and query evaluation completed in tens of seconds. Database creation is
  still too expensive to put in default decomplex runs.

## Replacement Principle

Use CodeQL for extraction and graph/path facts.

Keep decomplex for:

- detector-specific ranking,
- cross-detector convergence,
- root-cause clustering,
- report synthesis,
- false-positive discipline,
- project-independent policy wording.

Target shape:

```text
CodeQL facts
  -> decomplex fact adapters
  -> existing detector ranking/report code
```

Avoid:

- rewriting every detector in QL,
- making CodeQL mandatory before the replacement is proven,
- changing report semantics while swapping extraction backends,
- adding a second source of truth that silently diverges from existing reports.

## Candidate Replacements

### 1. StateMesh Extraction

Current file:

- `gems/decomplex/lib/decomplex/state_mesh.rb`

Current custom work:

- discovers fields from `ATTRASGN` / `IASGN`,
- walks write sites,
- walks read sites,
- computes receiver scatter and field messiness,
- emits a JSON graph.

Replace with CodeQL:

- field writes,
- field reads,
- method/file/module labels,
- source spans,
- receiver text if available.

Keep in Ruby:

- messiness metrics,
- hierarchical JSON graph,
- field ranking,
- re-derivation join.

Acceptance criteria:

- CodeQL-backed StateMesh matches or improves writer/reader counts for the
  known high-pressure fields: `storage`, `full_type`, `sync`, `layout`,
  `ownership`, `target`, `value`, `result_type`.
- Report remains deterministic.
- Runtime after DB creation is acceptable for local use.
- The old RubyVM read/write walker can be deleted.

Stop if:

- CodeQL cannot distinguish attr reads from arbitrary method calls with enough
  precision.
- CodeQL spans are not stable enough for SlopCop/decomplex joins.
- Full-repo query time is materially worse than the Ruby walker after caching.

Status: partially proven. Keep CodeQL as an optional backend and comparison
tool. Do not delete the RubyVM StateMesh reader yet.

### 2. CoUpdate Write Extraction

Current file:

- `gems/decomplex/lib/decomplex/co_update.rb`

Current custom work:

- walks `ATTRASGN` / `IASGN`,
- normalizes field names,
- groups co-written fields by `(file, method)`,
- ranks omitted pair members.

Replace with CodeQL:

- write-site extraction only.

Keep in Ruby:

- co-written pair mining,
- neglected update ranking,
- receiver display,
- support thresholds.

Acceptance criteria:

- Same or better write-site extraction than `CoUpdate.scan`.
- No loss of line/span precision.
- Existing co-update tests can run against both backends during migration.

Stop if:

- CodeQL write extraction misses common Ruby setter forms used in this repo.
- Indexed writes (`[]=`) cannot be excluded cleanly.

Status: useful as an optional backend. Implemented
`Decomplex::CoUpdate.from_codeql_facts`, reusing the existing CoUpdate pair and
neglected-update ranking over CodeQL write facts.

Measured on `src/`:

| extractor | writes | unique attrs | co-written pairs | neglected updates |
| --- | ---: | ---: | ---: | ---: |
| RubyVM CoUpdate | 2262 | 702 | 162 | 1988 |
| CodeQL facts | 2250 | 589 | 211 | 2810 |

Evaluation:

- Worth keeping. The CodeQL write count is close to RubyVM StateMesh/CoUpdate
  extraction and the top co-written pairs line up: `call_graph+fn_nodes`,
  `ownership+sync`, `layout+sync`, `link_source+ownership`, and
  `current_bindings+guarded_cleanup_names`.
- CodeQL normalizes ivar writes and setter writes to the same field label
  (`@fn_nodes` becomes `fn_nodes`). That is probably better for architecture
  work, but it changes report labels and increases candidate counts. Keep this
  backend optional until triage confirms the extra neglected-update candidates
  are signal rather than noise.
- This is the strongest candidate so far for deleting RubyVM extraction code,
  but only after adding a report mode or comparison gate that makes the label
  normalization explicit.

### 3. DecisionPressure Guard Extraction

Current file:

- `gems/decomplex/lib/decomplex/decision_pressure.rb`

Current custom work:

- finds nil/type/`respond_to?`/safe-nav guards,
- resolves local aliases within a method,
- separates eliminable guard pressure from essential dispatch,
- ranks root contracts.

Replace with CodeQL:

- guard call extraction,
- safe-navigation extraction,
- method boundary labels,
- simple local-def-use mapping if CodeQL can provide it reliably.

Keep in Ruby:

- eliminable vs essential policy,
- root contract normalization,
- pressure ranking,
- report wording.

Acceptance criteria:

- CodeQL backend reproduces the top root contracts from the current report:
  `.value`, `.symbol`, `.target`, `.emit`, `.full_type!`, `.name`, `.left`,
  `.expr`, `.right`, `.type`.
- Alias resolution is at least as good as the current intra-method first-simple
  assignment map.
- It does not inflate pressure by counting pure reads as decisions.

Stop if:

- CodeQL cannot cheaply expose the guard receiver/root contract.
- QL implementation starts duplicating decomplex's existing detector logic
  line-for-line.

### 4. SiteExtractor Decision Spans

Current file:

- `gems/decomplex/lib/decomplex/site_extractor.rb`

Current custom work:

- extracts `case` dispatch member sets,
- extracts flattened `&&` conjunction member sets,
- records spans consumed by SlopCop.

Replace with CodeQL:

- decision span extraction,
- case/conjunction member extraction where QL is straightforward.

Keep in Ruby:

- member-set ranking,
- missing-abstraction grouping,
- span join policy.

Acceptance criteria:

- SlopCop `decomplex` span precision does not regress.
- Member sets are stable across Ruby versions.
- The QL query is simpler than the current Ruby walker.

Stop if:

- CodeQL query complexity exceeds the Ruby implementation.
- Span semantics differ enough to destabilize SlopCop rankings.

### 5. Sequence / Protocol Extraction

Current files:

- `gems/decomplex/lib/decomplex/sequence_mine.rb`
- `gems/decomplex/lib/decomplex/path_condition.rb`
- `gems/decomplex/lib/decomplex/derived_state.rb`

Possible CodeQL wins:

- call sequence extraction,
- dataflow from derived value to stale use,
- path-condition relationships,
- control-flow parent/guard relationships.

This is second-wave work. Do not start here until StateMesh and CoUpdate prove
that CodeQL is a better extraction backend in this codebase.

## Non-Replacement Areas

Do not replace these with CodeQL unless a separate proof says otherwise:

- `gems/decomplex/lib/decomplex/convergence.rb`
- `gems/decomplex/lib/decomplex/root_cause.rb`
- `gems/decomplex/lib/decomplex/report.rb`
- `gems/decomplex/lib/decomplex/delta.rb`
- detector ranking and prioritization
- report markdown and wording

These are decomplex's value layer, not generic extraction.

## Implementation Plan

### Phase 0: CodeQL Availability and Ergonomics

- Add documentation for installing CodeQL or setting `CODEQL=/path/to/codeql`.
- Keep generated DBs and CSVs under `tmp/`.
- Make CodeQL optional while the migration is experimental.
- Add a clear error when CodeQL is missing.

Decision: already partially done by `tools/codeql_state_flow.rb`.

### Phase 1: Fact Export Contract

Create a stable fact format for decomplex to consume:

```json
{
  "schema": "decomplex-codeql-facts/v1",
  "generated_at": "...",
  "source_root": "...",
  "state_accesses": [
    {
      "file": "src/...",
      "module": "SemanticAnnotator",
      "method": "visit_ReturnNode",
      "field": "value",
      "access_kind": "reader_call",
      "line": 2096,
      "span": [2096, 12, 2096, 22],
      "source": "node.value"
    }
  ]
}
```

Start with state accesses only. Add calls/control/dataflow later.

### Phase 2: Dual-Run StateMesh

- Add `Decomplex::CodeqlFacts` reader.
- Add a `StateMesh` backend option:
  - `backend: :rubyvm` existing behavior,
  - `backend: :codeql` fact-backed behavior.
- Run both on `src/`.
- Add comparison output:
  - fields present only in RubyVM,
  - fields present only in CodeQL,
  - count deltas by field/access kind,
  - top ranking deltas.

Do not delete the RubyVM backend until comparison is stable.

### Phase 3: Replace StateMesh Extraction

After Phase 2 passes:

- make CodeQL the default StateMesh extraction backend when facts are present,
- keep RubyVM fallback only if CodeQL is unavailable,
- delete duplicated read/write extraction code once CI/local ergonomics are
  acceptable.

### Phase 4: CoUpdate Write Extraction

- Reuse the same CodeQL state-access facts.
- Feed `setter_call` / `ivar_write` rows into `CoUpdate::Report`.
- Dual-run and compare neglected-update rankings.
- Delete custom write walker only after rankings are stable.

### Phase 5: DecisionPressure Experiment

- Add a QL query for guard sites and receiver roots.
- Compare top root-contract rankings against current `DecisionPressure`.
- Only replace if QL is simpler and produces equal/better signal.

This phase has a higher stop risk than StateMesh/CoUpdate.

### Phase 6: SlopCop Join Improvement

If CodeQL spans are stable:

- expose CodeQL-backed decision spans to decomplex reports,
- let SlopCop consume the same spans through the existing decomplex verdict
  interface,
- measure whether `precise` attribution rises and `method-coarse` fallback
  falls.

## Measurement

For each phase, snapshot:

```bash
ruby gems/decomplex/exe/decomplex report src --output=/tmp/decomplex-before-codeql-phaseN.md
ruby gems/slopcop/exe/slopcop report --output=/tmp/slopcop-before-codeql-phaseN.md
ruby tools/codeql_state_flow.rb --top 80
```

After the change:

```bash
ruby gems/decomplex/exe/decomplex report src --output=/tmp/decomplex-after-codeql-phaseN.md
ruby gems/slopcop/exe/slopcop report --output=/tmp/slopcop-after-codeql-phaseN.md
ruby tools/codeql_state_flow.rb --top 80
```

Compare:

- decomplex aggregate counts,
- top convergence changes,
- StateMesh/CoUpdate rank stability,
- SlopCop span precision vs method-coarse attribution,
- runtime with and without cached CodeQL DB.

## Stop Conditions

Stop the epic and report back if any of these are true:

- CodeQL facts cannot match the current detector's precision for a target
  backend.
- CodeQL queries require reimplementing most detector logic in QL.
- Query runtime is not acceptable after DB creation and query caching.
- Source spans are unstable or do not join cleanly with coverage/decomplex
  locations.
- CodeQL cannot be made optional during the transition.
- The replacement makes reports harder to interpret or less deterministic.

## Expected Payoff

High confidence:

- StateMesh and CoUpdate extraction should become smaller and less brittle.
- The CodeQL state-field graph should give better source-path facts for
  architecture work.

Medium confidence:

- DecisionPressure guard extraction may improve, especially around local
  aliasing and safe navigation.

Low confidence:

- Full call-edge extraction as currently written is too slow on the full repo.
  Treat call edges as opt-in until a narrower QL query proves useful.

## First Concrete Task

Implement Phase 1 and Phase 2 for `StateMesh` only:

1. Extend `tools/codeql_state_flow.rb` to emit a normalized JSON fact file with
   line/span data.
2. Add `Decomplex::CodeqlFacts`.
3. Add a StateMesh dual-run comparison command.
4. Compare against the existing RubyVM StateMesh on `src/`.
5. Decide:
   - replace,
   - continue with query fixes,
   - or stop because CodeQL is unsuitable for this target.
