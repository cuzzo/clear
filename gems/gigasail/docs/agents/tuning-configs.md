# Tuning configs: review gates, metric weighting, and the review MCP surface

Status: **design / not yet built.** This specs: the crate placement of the
review surfaces (§0 — MCP/LSP move to the CLI); a `review:` section for
`giga.yml` (metric weighting, gates, purity, test depth, tags, perf, retention);
two review-oriented MCP tools (`giga_precommit`, `giga_premerge`) and the LLM report
they return; and how the same config later retunes the `giga diff` UI. It is
deliberately **forward-compatible**: several fields (perf, tags, test depth,
class purity, per-span branch coverage) are reserved and specced now so they can
light up later without a schema break, even though only the core review path is
built first. It also ties into the artifact-pruning TODO so pruning never
deletes evidence a review still needs. **§9 is the design rationale for the MCP
surface itself** — the four ways to get an LLM to verify before "done", their
context-token costs (grounded in published agent-behavior research), why agents
miss failures even when they run the tests, and why a mis-wired harness can
launder a failure into a pass. **§10 specs a harness to *measure* the naive vs.
tool token cost + miss rate on this repo**, so the §9 claims are measured, not
asserted.

The goal: let a project declare **which findings matter, how much, and when a
change must be blocked for human/LLM review** — once, in `giga.yml` — and have
that single declaration drive (a) the MCP review report an agent reads, (b) the
diff-UI ranking and line visibility, and (c) the CI gate.

---

## 0. Architecture: where the review surfaces live

**Decision: MCP and LSP are protocol adapters, not UI. They move to the `giga`
CLI crate; `giga-ui` becomes web-only.** Today `giga-ui` bundles three surfaces
— the axum web UI, the LSP (`tower-lsp`), and the MCP server (`rmcp`) — so
running the stdio MCP server links the entire web stack it never uses, and the
crate name mislabels LSP/MCP as "UI".

- **`giga-core` stays a dependency-light library** (rusqlite, tree-sitter,
  git2 — *zero* server deps today). It must never gain `rmcp`/`tower-lsp`/
  `axum`/`tokio`, or every embedder inherits them. The shared query layer
  (`Storage`) already lives here; that is the right amount.
- **Target:**
  ```
  giga-core  (engine + Storage + per-line annotation layer — no server deps)
  giga-ui    (axum web UI only)
  gigasail/giga (CLI)
    ├─ giga mcp   (rmcp)
    ├─ giga lsp   (tower-lsp)
    └─ giga diff/build/sync/review/...
  ```

### Sequencing (a real finding, not a formality)
- **MCP is self-contained** over `giga-core` (`mcp.rs` imports only
  `crate::{storage,hazard,extract,model}`, all re-exported from `giga-core`).
  The root crate already does `pub use giga_core::*`, so **MCP folds into the
  CLI with no logic changes** — add `rmcp`+`tokio`, move the file, add a `giga
  mcp` subcommand. Do this first.
- **LSP is entangled with the web UI.** `lsp.rs` depends on
  `line_annotations()` and the `UiOverlays`/`UiLineAnnotation`/`UiHazard` types,
  which are buried in the 11,986-line, axum-coupled `giga-ui/src/ui/ui.rs`.
  That per-line annotation computation is **pure query logic, not rendering** —
  the web UI, the LSP, and (partly) the MCP `giga_unit_context` tool all need
  it. **Prerequisite for the LSP move: lift the annotation layer
  (`line_annotations` + the `Ui*` annotation structs) out of `ui.rs` into
  `giga-core`.** Then the web UI, LSP, and MCP all consume one giga-core
  annotation API, and LSP folds into the CLI as cleanly as MCP.

This ordering (MCP now → extract annotation layer → LSP) keeps each step
build-green and independently committable.

---

## 1. What exists today (grounding — do not re-derive)

Concrete types this design builds on. See `giga-core/src/diff.rs`,
`db/model.rs`, `db/hazard.rs`, `pipeline.rs`, `giga-ui/src/ui/mcp.rs`.

- **SARIF findings** carry tiers. `SarifFindingSummary` (`diff.rs`): `tier:
  Option<u8>` (1/2/3), `tier_one: bool`, `status` (`"new"`/`"resolved"`/
  `"uncompared"`/`"active"`), `rule_id`, `level`, `category`, `message`,
  `tool`, `source`, `fingerprint`, `proof_boundary: Vec<String>`, `provenance:
  BTreeMap<String,String>`, `start_line`/`end_line`. **`tier` is
  provider-supplied** (parsed from the SARIF `properties.tier` / `risk_tier`),
  not computed by giga.
- **The diff already labels findings `new` vs `resolved`** by comparing base↔head
  SARIF (`diff.rs` ~800-855). "SARIFs added between two commits" == findings with
  `status == "new"`. This is the entire data source for `review`.
- **Hazards are a separate model**, not SARIF. `HazardSite{path, line,
  hazard_type, required_evidence, source}`. **No tier.** Their severity axis is
  `required_evidence` (`loom`/`hammer`/`vopr`/…). Persisted in `unit_hazards`
  with `is_active` and a verified/evidence-present join. "Uncovered hazard" ==
  active hazard whose `required_evidence` family has no covering evidence.
- **Coverage** is `VerificationSlices{covered_and_killed, covered,
  partially_covered, not_covered, unknown}` (line counts). **Branch coverage is
  measured but collapsed** into `is_partial` + a per-line `coverage_percent`
  (`db/quality.rs`); the branch-arm concept surfaces separately as
  `is_dark_arm` SARIF findings. There is **no first-class numeric
  `branch_coverage` per unit yet.**
- **Mutation is per-unit**: `logical_units.current_mutant_cov`,
  `current_mutant_killed_tests`, `current_mutant_verified_tests`,
  `current_distinct_tests`; per-line via `MutationKillObservation` (presence ==
  killed at that line).
- **Purity has no typed field anywhere.** The only signals: espalier emits
  read/write **effect edges** (`reads`/`writes` in `espalier.architecture.v1`,
  already ingested and surfaced as `DiffGroup.added_state = ["read:x",
  "write:y"]`), and a derived SARIF note (`espalier.function`: "read-only
  function" / "impure function"). A function with **no `write:` state edges and
  no side-effecting hazard** is derivably pure.
- **Risk ranking is a hardcoded formula** (`diff.rs apply_tier_one_hazards`):
  `score = not_covered + 0.5·partially_covered + 2·added_complexity +
  8·tier_one_hazards`. This is the single hook the UI/CI ranking uses.
- **MCP has no diff/review tool.** The five tools (`giga_file_risk`,
  `giga_unit_context`, `giga_verification_gaps`, `giga_change_history`,
  `giga_find_definition`) are file/unit-scoped. Review is UI-only today.
- **Run retention already exists**: `ArtifactStoreConfig{retain_runs,
  stale_run_age_seconds, compression}`. Pruning is the natural home for the
  branch-aware retention this doc's reviews depend on.

**What must be built** (called out again in §7): a `review:` config section on
`LineageConfig`; two review MCP tools; branch coverage as a numeric axis; a
derived purity signal; and swapping the hardcoded risk weights for the
configured ones.

---

## 2. The review flow

Two workflow questions, two MCP tools, one shared report builder. This matches
the existing "one tool per question, not per table" philosophy (`mcp.md`).

### `giga_precommit` — "What did I just change that needs review?"
- **Default range: `HEAD~1..HEAD`** (or `HEAD..WORKTREE` when the tree is dirty).
- Input: `{ base?: string, head?: string }`. Omitted → the default above.
- Answers the everyday "review my last commit" question.

### `giga_premerge` — "What does merging this branch introduce?"
- **Range: `merge-base(head, target)..head`**, i.e. every commit the branch adds
  on top of where it forked. `git merge_base` already backs `default_diff_base`
  (`db/git.rs`), so `giga premerge` and a `branch..master` review are the same
  computation with `base = merge-base`.
- Input: `{ target?: string = "master", head?: string = current branch }`.

Both build the same `DiffPlan` the UI uses (via `build_structured_diff`), then
run the **review evaluator** (§4) over it: collect `status == "new"` SARIF
findings + active hazards + per-unit coverage/mutation posture, apply the
`review:` config (visibility/weight/gates), and emit the report (§5).

`review` shows the delta of *one step*; `pre-merge` shows the delta of the
*whole branch*. Nothing else differs in the *diff* — but they run **different
verification depths**:

- **`giga_precommit` runs the fast set** — the `ci`/unit tests + coverage, quick
  static analyzers. It is the tight inner-loop check an agent runs after each
  commit, so it must stay seconds-fast (see `review.tests.fast`, §3g).
- **`giga_premerge` runs the exhaustive set** — the full suite, mutation, and
  **benchmarks / performance tests** (`review.tests.exhaustive` +
  `review.perf`, §3g/§3h). It is the gate before a branch merges, so it can
  afford minutes. Only pre-merge surfaces **performance regressions**.

The verification depth is config, not code: each tool names a test set that maps
to giga.yml profiles, so a project decides what "fast" and "exhaustive" mean.

---

## 3. `review:` config schema (`giga.yml`)

A new top-level `review:` key on `LineageConfig` (add the field; all config
structs are `#[serde(deny_unknown_fields)]`, so it must be declared). Every
subsection has reasonable defaults so an empty/absent `review:` behaves sanely
(show everything, weight by the current formula, gate only on uncovered T1 and
unverified hazards).

```yaml
review:
  # ── 3a. Per-metric visibility & ranking weight ─────────────────────────────
  # Keys match a SARIF rule_id, a bare tier ("T1"/"T2"/"T3"), a hazard
  # required_evidence family ("hazard:loom"), or "dark_arm". Most specific wins
  # (rule_id > tier). `policy`: show | deprioritize | ignore.
  metrics:
    "T3":
      policy: deprioritize        # visible, but zero weight in ranking + gates
      weight: 0.0
    "espalier.complexity":
      policy: deprioritize
      threshold: 0.7              # only engages when the finding's metric >= 0.7
      weight: 0.0                 # below-threshold instances are dropped entirely
    "test-miser.redundant":
      policy: ignore              # never shown, never counted, never gates

  # ── 3b. Ranking weights (replace the hardcoded risk formula) ───────────────
  # Omitted keys keep today's defaults. These feed both the diff-UI file ranking
  # and the per-finding `weight` an LLM sees in the review report.
  weights:
    not_covered: 1.0
    partially_covered: 0.5
    added_complexity: 2.0
    tier_one_finding: 8.0
    tier_two_finding: 3.0
    tier_three_finding: 0.0       # T3 present but weightless by default
    unverified_hazard: 8.0
    uncovered_mutant: 4.0

  # ── 3c. Purity classification + per-bucket coverage requirements ───────────
  purity:
    source: effects               # effects (architecture write-edges) | sarif
                                  # (espalier.function note) | off
    pure:
      line_coverage: 0.95
      branch_coverage: 0.75
      mutation_kill_rate: 0.80    # optional; omit ⇒ not required
    stateful:
      line_coverage: 1.00
      branch_coverage: 1.00
      # mutation not required for stateful by default (see §4 hazard note)

  # ── 3d. Gates: conditions that escalate a change to CRITICAL review ────────
  # Evaluated per changed unit / per finding on ADDED lines only. A gate that
  # fires sets the report verdict to `critical` and lists itself in
  # gates_triggered. `severity`: critical | warn.
  gates:
    - id: uncovered-tier1
      when: { tier: 1, on: added, coverage: uncovered }
      severity: critical

    - id: unverified-hazard
      when: { hazard: any, verified: false }
      severity: critical

    # A hazard whose covering test ran mutation but no mutant was killed is
    # unproven. Skip evidence families that legitimately don't run mutants
    # (a Hammer/Loom/VOPR test asserts scheduling/invariants, not mutant kills).
    - id: unkilled-hazard-mutant
      when: { hazard: any, verified: true, mutant_killed: false }
      unless_evidence: [hammer, loom, vopr]
      severity: critical

    - id: stateful-undercovered
      when: { purity: stateful }
      require: { line_coverage: 1.00, branch_coverage: 1.00 }
      severity: critical

    - id: pure-undercovered
      when: { purity: pure }
      require: { line_coverage: 0.95, branch_coverage: 0.75, mutation_kill_rate: 0.80 }
      severity: critical

  # ── 3e. Report shaping ─────────────────────────────────────────────────────
  report:
    include_resolved: false       # also surface findings this change fixed
    max_findings_per_tier: 25     # cap; overflow reported as a count
    group_by: tier                # tier | file | unit

  # ── 3f. Retention needed by reviews (ties into the pruning TODO) ───────────
  # Evidence for any commit reachable as a review base must survive pruning.
  retain:
    review_window: 20             # keep evidence for the last N commits on a line
    keep_branch_bases: true       # never prune a merge-base a pre-merge would use

  # ── 3g. Test depth per tool ────────────────────────────────────────────────
  # Named test sets mapped to giga.yml profiles. `giga_precommit` runs `fast`;
  # `giga_premerge` runs `exhaustive`. A set names profiles whose producers
  # already exist (§ pipeline: ci/analyse), so this only *selects* depth.
  tests:
    fast: [ci]                    # unit tests + coverage; seconds
    exhaustive: [ci, mutation, bench]   # full suite + mutation + benchmarks

  # ── 3h. Performance testing & regression (pre-merge only, for now) ─────────
  # A perf producer emits per-benchmark numbers; the evaluator compares head vs
  # base and flags regressions beyond tolerance. Not built now — the config and
  # report field are reserved so it can light up later without a schema break.
  perf:
    enabled: false
    regression_tolerance: 0.05    # >5% slower than base = regression
    gate: warn                    # warn | critical when a regression is found
    # producer emits { benchmark, ns_per_op, allocs } per name; base comes from
    # the merge-base's stored perf artifact.

  # ── 3i. Semantic tags on functions/classes ─────────────────────────────────
  # Tags let a project mark units that deserve extra scrutiny or that the diff
  # summary should call out (e.g. revenue paths, security-critical entrypoints).
  # Sources compose: manual annotations in source, path globs, or a SARIF rule.
  # Tags feed gates (§3d `when: { tag: critical }`), ranking weight, and the
  # `giga diff` summary. Reserved now; wired incrementally.
  tags:
    critical:
      match: { paths: ["internal/auth/**", "internal/billing/**"] }
      weight_bonus: 4.0           # added to a tagged unit's ranking score
      gate: critical              # any finding on a `critical` unit escalates
    revenue:
      match: { annotation: "giga:revenue" }   # e.g. a `// giga:revenue` marker
      # revenue-generating paths: highlighted in the summary; perf-sensitive
      summary: true

### Defaults when `review:` is absent
- `metrics`: everything `show`.
- `weights`: today's hardcoded formula (T2/T3 weightless, T1/hazard = 8).
- `purity.source: effects`; pure/stateful thresholds as above.
- `gates`: `uncovered-tier1` + `unverified-hazard` only.
- `report`: `group_by: tier`, `max_findings_per_tier: 25`.

---

## 4. The review evaluator (semantics)

Pure function over a `DiffPlan` + the `review:` config → a `ReviewReport`
(§5). No new scanning; it reads the plan the diff already produces.

1. **Collect candidates** on added lines: `status == "new"` SARIF findings
   (grouped by `tier`), active hazards (`unit_hazards.is_active`), per-unit
   coverage/mutation posture.
2. **Apply metric policy** (§3a) to each finding:
   - `ignore` → dropped from the report, totals, and ranking.
   - `deprioritize` → kept and shown, but `weight = 0`; excluded from the tier
     totals used by gates and from the file-ranking sum. The LLM is told it is
     deprioritized so it can still note it without treating it as blocking.
   - `threshold` → a finding whose metric value is below the threshold is
     dropped entirely (as if `ignore` for that instance).
3. **Classify purity** per unit (§3c source), for **functions and classes**:
   - **Function**, `effects`: **no `write:` state edge** (from the architecture
     graph) **and no side-effecting active hazard** ⇒ `pure`; otherwise
     `stateful`. Unknown when no architecture graph is ingested.
   - **Class**, `effects`: a class is `pure` iff **none of its methods write
     state** (no `write:` edge sourced from any member) **and it declares no
     mutable field** — i.e. the class is derivably immutable/stateless.
     Otherwise `stateful`. This reuses the same `write:` edges, rolled up over
     the class's members (the architecture graph already links members to their
     owner node).
   - `sarif`: presence of an `espalier.function` "impure function" note ⇒
     `stateful`; "read-only function" ⇒ `pure` (class-level would need an
     analogous `espalier.class` note — not emitted today; prefer `effects`).
   - `off`: purity gates are skipped.
   Purity gates (§3d) apply the class bucket to method-less/aggregate units and
   the function bucket to individual methods.
4. **Evaluate gates** (§3d). A `when` selects units/findings; `require` checks
   coverage/branch/mutation thresholds (branch coverage needs §7 item 3). Any
   fired `critical` gate ⇒ `verdict = critical`; only `warn` gates ⇒
   `verdict = needs_review`; none ⇒ `pass`.
5. **Rank** files/units by the configured weights (§3b), replacing the
   hardcoded formula. Deprioritized/ignored findings contribute 0.

**Hazard/mutation nuance (the user's key case):** a hazard's proof is its
`required_evidence` family, not a mutant. `unkilled-hazard-mutant` only fires
for families that *do* run mutants; `hammer`/`loom`/`vopr` are exempt via
`unless_evidence`, because a scheduling/invariant test has no mutant to kill.

---

## 5. MCP review report format

Design principles (from how LLM review agents consume tool output): **verdict
first**, deterministic ordering, bounded size, every finding *actionable*, and
the analyzer's own limits (`proof_boundary`) surfaced so the model knows what
was *not* checked. Findings are grouped by tier and capped; overflow is a count,
never a silent truncation. Deprioritized findings are segregated so they don't
compete for the model's attention.

```jsonc
{
  "mode": "review",                       // "review" | "pre-merge"
  "range": { "base": "<sha>", "head": "<sha>", "commits": 3 },
  "verdict": "critical",                  // pass | needs_review | critical
  "gates_triggered": [
    { "id": "uncovered-tier1", "severity": "critical", "count": 2,
      "reason": "2 new T1 findings on uncovered added lines" },
    { "id": "stateful-undercovered", "severity": "critical", "count": 1,
      "reason": "GitAnalyzer#Detect: branch coverage 0.62 < 1.00 (stateful)" }
  ],
  "summary": {
    "added_lines": 1678, "changed_units": 42,
    "findings": { "t1": 3, "t2": 12, "t3": 40, "hazards_open": 2 },
    "coverage": { "line": 0.87, "branch": 0.61, "mutation_kill": 0.55 },
    "deprioritized": 40, "ignored": 6
  },
  "findings": [                           // ranked; T1 first; capped per tier
    { "tier": 1, "rule_id": "espalier.nil-deref", "tool": "nil-kill",
      "file": "internal/repo/git.go", "line": 142,
      "unit": "GitAnalyzer#Detect", "purity": "stateful",
      "message": "possible nil dereference of `cmd`",
      "status": "new", "weight": 8.0,
      "coverage": "uncovered", "mutant": "n/a",
      "proof_boundary": ["interprocedural aliasing not modeled"],
      "action": "Add a test covering line 142; a new T1 on an uncovered line blocks merge." }
  ],
  "units_below_gate": [
    { "unit": "GitAnalyzer#Detect", "purity": "stateful",
      "line_coverage": 1.00, "branch_coverage": 0.62,
      "required": { "line": 1.00, "branch": 1.00 }, "gate": "stateful-undercovered" }
  ],
  "deprioritized": { "count": 40, "note": "T3 shown with 0 weight per giga.yml review.metrics" },
  "new_dependencies": ["GitAnalyzer#populateFileSizes"],   // from the architecture graph
  "new_state": ["write:count"],

  // ── reserved / depth-dependent fields (present when the data exists) ──
  "tests": { "set": "fast", "passed": 128, "failed": 0, "skipped": 3 },
  "tags": [ { "unit": "internal/billing/Charge", "tag": "revenue" } ],
  "perf": {                                // giga_premerge only
    "regressions": [
      { "benchmark": "ParseLedger", "base_ns": 1200, "head_ns": 1470,
        "delta": 0.225, "tolerance": 0.05, "gate": "warn" }
    ]
  }
}
```

`giga_precommit` omits `perf` (fast set, no benchmarks) and reports
`tests.set: "fast"`. `giga_premerge` includes `perf` and `tests.set:
"exhaustive"`. A field that has no data yet is simply absent — the shape is
forward-compatible, so tags/perf/tests can light up without a schema break.

- **`verdict` + `gates_triggered`** are the first thing the agent reads: a CI
  gate and an LLM instruction in one. `critical` == block.
- **`weight`** lets the agent rank its own attention identically to the UI.
- **`coverage`/`mutant`** per finding tell the agent whether the risky line is
  even tested — the single most useful signal for "should I write a test".
- **`proof_boundary`** prevents false confidence: the agent knows what the
  analyzer could not prove.
- **Deprioritized/ignored** are counts, not walls of text — the agent spends
  tokens on what gates.

`giga_premerge` returns the identical shape with `mode: "pre-merge"` and the
merge-base range.

---

## 6. UI impact (later)

The same `review:` config retunes `giga diff` with **zero new UI concepts** —
it only changes weights and visibility of what already renders:

- **Ranking** (`RiskSummary.score`): the hardcoded formula becomes
  `review.weights`. Files/units re-sort by the project's weighting. A
  deprioritized tier contributes 0, so a T3-heavy file stops out-ranking a
  T1-bearing one.
- **`policy: ignore`** — the finding is absent everywhere: not on the line
  gutter, not in the per-file/tier totals (`¤×N T1×N …`), not in ranking.
- **`policy: deprioritize`** — the finding still renders on the line (dimmed)
  and in a separate "deprioritized" count, but adds 0 to totals and ranking.
  This is the user's "show it but give it 0 weight" mode.
- **`threshold`** — a metric finding below threshold is treated as `ignore` for
  that instance (not shown, not counted).
- **Gates** surface as a banner on the `[SUMMARY]` funnel ("CRITICAL: 2 gates —
  uncovered-tier1, stateful-undercovered") and a `units_below_gate` filter in
  the tree, reusing the existing risk-sort machinery.
- **Tags** (§3i) render on the summary and beside tagged units (`revenue`,
  `critical`), and their `weight_bonus` re-ranks. When revenue/criticality data
  exists it belongs on the summary, exactly like the language/coverage funnel.
- **Performance** (when `review.perf` is on): the summary shows a perf line and
  flags regressions from the pre-merge run, next to the coverage/hazard lines.
- **Partially-covered spans** — today the CLI only shows a per-line covered/
  uncovered gutter; the web UI shows the *exact partially-covered spans*. Once
  branch coverage is uncollapsed (§7 item 3) the CLI diff can highlight the
  same partial spans inline (the yellow `-` bar already exists per line; this
  extends it to the sub-line arm ranges the web UI renders).

Because the MCP report, the CI gate, and the UI all read the *same* evaluator
(§4), a finding the user chose not to see in the UI is also absent from the
LLM's feedback and from the merge gate — one config, one behavior everywhere.

---

## 7. Data gaps to build (honest list)

1. **`review:` config section** on `LineageConfig` + validation (weights ≥ 0,
   known gate `when` keys, `unless_evidence` families). `deny_unknown_fields`
   means the struct must exist before any `review:` key is accepted.
2. **Two MCP tools** (`giga_precommit`, `giga_premerge`) wrapping the §4 evaluator;
   register in `tool_defs()`/`call_tool` (`mcp.rs`). Reuse `build_structured_diff`.
3. **Uncollapse branch coverage into a per-unit AND per-span axis.** Today
   branch data only sets `is_partial` + a per-line `coverage_percent`
   (`db/quality.rs`) — the arm detail is thrown away. Persist
   `covered_branches/total_branches` per unit (for the gates) **and the
   partially-covered sub-line spans** (for display). The web UI already renders
   exact partial spans; storing them lets the CLI diff do the same (§6) instead
   of a whole-line yellow bar. This is the one genuinely new *metric* plumbing.
4. **Derived purity signal for functions and classes.** No typed field exists.
   Compute `pure` in the evaluator from data already in the plan: a function is
   pure with no `write:` state edge + no side-effecting hazard; a class is pure
   when no member writes state and it declares no mutable field (§4). Consider
   persisting purity on `logical_units` later so the LSP/UI/summary can show it
   without recomputation.
5. **Config-driven risk weights.** Replace the constants in
   `apply_tier_one_hazards` with `review.weights` (fall back to today's values).
6. **Semantic tags** (§3i): a `unit_tags` store keyed by logical-unit id
   (rename-stable), populated from annotations / path globs / SARIF rules;
   consumed by gates, ranking `weight_bonus`, and the summary. This is where
   "which functions are critical / revenue-generating" lives, and it must ride
   the same rename-stable identity as hazards so a tag follows a moved function.
7. **Test-depth selection** (§3g): `giga_precommit` → `fast`, `giga_premerge` →
   `exhaustive`; wire the tool to run the named profiles and fold pass/fail into
   the report. The profiles already exist; this only selects and reports them.
8. **Performance harness** (§3h): a perf producer (`kind: perf`?) emitting
   per-benchmark numbers, a base-vs-head comparator, and the `perf` report
   block + summary line. Pre-merge only. Reserved in config now so it slots in
   without a schema break.
9. **Crate move** (§0): fold MCP into the `giga` CLI now (clean); lift the
   `line_annotations`/`Ui*` annotation layer from the axum-coupled `ui.rs` into
   `giga-core`; then fold LSP into the CLI. `giga-ui` ends web-only.
10. **Branch-aware retention** (the `TODO.md` item). Reviews read evidence for
    *both* endpoints of a range; `review.retain` (§3f) must be honored by the
    pruner so a `pre-merge` never loses its merge-base's evidence. Pruning
    remains safe only when an artifact is (a) sequential/superseded on the same
    line, (b) not in the `review_window`, and (c) not an incremental-processing
    input — exactly the TODO's three conditions.

---

## 8. Relationship to the pruning TODO

`TODO.md` asks to prune stale reports without deleting anything MCP might use.
This doc pins down *what MCP uses*: a `review`/`pre-merge` needs the SARIF,
coverage, mutation, and architecture evidence for **every commit reachable as a
review base** — the last `review_window` commits on the current line, plus any
branch merge-base. `review.retain` (§3f) is the declaration the pruner consults;
until it exists, the pruner must be conservative (keep evidence for HEAD and its
first parent at minimum, plus anything the incremental `engine_state` reads).

---

## 9. Getting an LLM to actually verify before "done" — four strategies and their cost

Computing whether a change is safe is the easy half (§4). The hard half is
getting an agent to *consult that verdict and honor it* instead of declaring
victory. Two failure modes dominate:

- **Skip-and-assert** — the agent never runs verification and writes "all tests
  pass / fully covered."
- **See-red-and-rationalize** — it runs the check, sees a FAIL/`critical`, and
  reframes it as out-of-scope / pre-existing / acceptable, then ships.

**No mechanism eliminates the second failure.** An LLM can always read a red
result and lie about it. The realistic goal is to make the honest path the
*cheap* path, make a red result *hard to reinterpret*, and keep a backstop the
agent cannot talk past.

There is also a cost that is easy to forget: **MCP tool schemas and skill
instructions occupy context on every turn.** A tool's name + description +
parameter schema sits in the tool list whether or not it is called; a skill's
teaching text is resident whenever it is loaded. "Add a tool" is a *fixed
per-turn token tax* paid across the whole session. So the real design question
is *net* context: does a tool save more — by keeping verbose verification output
out of the window — than its schema costs by sitting in the tool list?

### The four strategies

| Strategy | LLM effort | Token / context cost | Reliability | Residual failure |
|---|---|---|---|---|
| **1. YOLO** (no tests, no gate) | none | ~0 | ~0% | everything ships unverified |
| **2. Tests exist, hope it runs them / rely on CI** | high, self-directed: discover the command, run it, parse a large log | **huge & variable** — a raw suite/coverage dump is 5k–50k tokens into the window; or a slow out-of-band CI round-trip | low–medium | declares done before running, or before CI finishes; CI catches it late and out of band |
| **3. Plain-English gates in AGENTS.md** (or link CI config) | medium: read prose, self-enforce | **persistent** — gate text sits in context every turn; linking CI trades that for a fetch+parse of the CI YAML | medium | advisory only; interpretation drifts ("this change is trivial, skipping") |
| **4. MCP review tool** (deterministic verdict) | one tool call; the tool runs the gate | **small fixed schema tax + a bounded verdict** (verdict-first, capped) — the verbose work happens *outside* the window | highest | can still see `critical` and lie — but it is now a single unambiguous field, and auditable |

### Why the MCP tool wins the *net* context math

Strategy 2's real cost is not running the tests — it is that the agent must pull
the entire test/coverage/SARIF output *into its context* to interpret it, and
that output is large and unbounded. Strategy 4 inverts this: the evaluator (§4)
runs the suite and reduces ~50k tokens of raw output to a ~500–2k-token verdict
(`verdict`, `gates_triggered`, top-N findings with actions — §5). The agent pays
a small fixed schema tax for the tool but avoids the large variable dump. **On
any non-trivial change the tool is strictly cheaper *and* more reliable.**

This is exactly why the MCP surface must stay **small and terse**:

- **Few tools.** Each schema is resident every turn; many near-identical tools
  measurably degrade tool-selection accuracy (see `mcp.md`'s "5 tools, not 17").
  Two review tools (`giga_precommit`, `giga_premerge`) — **not** one per metric.
- **Verdict-first, bounded responses.** Never return raw logs; return the
  conclusion and capped, actionable findings (§5). Overflow is a *count*, not a
  wall of text.
- **Config in `giga.yml`, not in context.** The gates live in a file the *tool*
  reads (§3), not in AGENTS.md prose the *agent* must keep resident. This moves
  strategy 3's persistent token cost off the context budget entirely — the
  English gate is paid once, on disk, by the evaluator, not on every turn.

### Recommended layering (defense in depth, one source of truth)

No single strategy suffices; combine them so each covers the others' failure:

1. **MCP review tool** — the in-loop, cheap, hard-to-fake check the agent runs
   after each commit (`giga_precommit`) and before merge (`giga_premerge`). Fast
   feedback, bounded context.
2. **A one-line AGENTS.md pointer** — *not* the gates, just: "before declaring
   done, call `giga_precommit`; a `critical` verdict blocks." A few resident tokens
   telling the agent the tool exists and is mandatory. The *rules* stay in
   `giga.yml`.
3. **CI runs the identical evaluator** — the non-bypassable backstop. Because CI
   and the MCP tool share one evaluator and one `giga.yml`, the agent cannot
   declare done past a red CI, and a human sees the same verdict the agent saw.
   This is what bounds the irreducible "saw-red-and-lied" case: the lie is caught
   out of band and is auditable against the same machine verdict.

**The single-evaluator invariant is the crux:** MCP, CI, and the diff UI must
all read the same `review:` config and the same evaluator (§4). One source of
truth means the agent's in-loop check, the merge gate, and the human's view can
never disagree — so an agent that games the in-loop check still hits an
identical wall at CI. Design the surface to make the honest path the cheapest
one, and let CI make the dishonest path fail loudly.

### Why agents miss failures *even when they run the tests* (grounded, not folklore)

Strategy 2 fails more subtly than "the agent is lazy." Published behavior:

- **Tool output already eats the context budget.** In a typical terminal-agent
  session, tool outputs (file reads, command output, search hits) consume
  ~70–80% of the window — before the model reasons at all. A raw test/coverage
  dump lands on top of that.
- **Large output is silently truncated — and truncation drops the *middle*.**
  A documented case: an agent ran a coverage suite, got 419 KB of output
  truncated at 235 KB, tried to `grep` the results, re-ran the whole suite, and
  truncated again — spending **6–9× longer understanding the output than the
  tests took to run**. Truncation strategies frequently remove the *critical
  error lines in the middle*, so the agent's `grep FAIL` / last-N-lines scan can
  return clean while a real failure sits in the excised section.
- **Per-task token use is wildly variable** (up to ~30× on the *same* task), and
  accuracy peaks at an *intermediate* token budget — dumping more raw log is not
  just costly, it *lowers* success.

So the anecdote — "they run the tests, grep for FAIL/ERROR, and miss a clear
failure because they only read the tail" — is the *normal* outcome of piping an
unbounded log through a truncating context window, not an aberration. A
verdict-first tool (§5) is the direct fix the same literature recommends
(Memory-Pointer / structured-output patterns: keep the blob out of the window,
pass a short pointer/summary).

### The harness must actually fail (or the verdict is a lie the tool faithfully repeats)

A verdict tool is only as honest as the exit codes it reads. **Real example in
this repo:** `clear test <dir>` printed `MEMORY LEAKS: N` in red but its exit
was `exit(failed_names.any? ? 1 : 0)` — leaks were excluded, so the process
**exited 0 on a detected leak**. Every layer downstream inherited the lie: an
agent (or CI, or a human checking `$?`) was told the suite was clean, and an
agent that *only* scanned the tail would not even see the red `MEMORY LEAKS`
line. (Fixed: the exit now includes `leak_tests.any?`.) The lesson for the
review evaluator: **do not trust a producer's exit code alone** — key
conditions (leaks, sanitizer output, zero-assertion tests) must be asserted by
the evaluator from structured evidence, so a mis-wired harness cannot launder a
failure into a pass. This is why gates (§3d) are evaluated over ingested
facts, not over "did the test command exit 0".

---

## 10. Measuring the cost: a test-behavior harness

Before committing to a surface, measure the thing we claim to improve: **how
many tokens an agent spends verifying a change the naive way, versus through a
`giga_precommit`/`giga_premerge` verdict.** The research above gives priors
(agentic coding uses ~3500× the tokens of single-round reasoning; output
dominates; runs vary up to ~30×) but not *our* numbers on *our* repos.

**Harness shape (deterministic, offline-replayable):**

1. **A fixed task set** — N real changes on this repo with known verdicts (some
   clean, some with an uncovered T1, a leak, a perf regression, a resolved
   finding). Include the `clear test` leak case as a regression fixture.
2. **Two arms per task, same model + same prompt seed:**
   - *Naive*: the agent has only shell; it must run tests/coverage itself and
     decide. Record total input+output tokens, wall-clock, and **whether it
     reached the correct verdict** (caught/missed the leak, the T1, etc.).
   - *Tool*: the agent has `giga_precommit`/`giga_premerge`. Record the same.
3. **Metrics to report together** (per the cost-analysis literature, cost is
   only comparable when reported jointly): total tokens, input/output split,
   cache-hit rate, wall-clock, and the **miss rate** (false "looks clean"). A
   cheaper arm that misses failures is worse, not better — plot cost *and*
   correctness.
4. **Attribute the tool's fixed tax honestly:** count the tool schema's resident
   tokens (paid every turn) against the raw-log tokens it avoids, so the *net*
   claim in §9 is measured, not asserted.

**What good looks like:** the tool arm should show a large drop in output/
context tokens (the raw-log dump is replaced by a bounded verdict) *and* a lower
miss rate (the verdict names the leak/T1 the naive tail-scan skipped). If the
tool arm is not both cheaper and more correct on this set, the surface is wrong
— shrink the response, or fix the gate, before shipping it.

This harness also becomes a **regression guard on the MCP surface itself**: if a
future change bloats a response or drops a gate, the token/miss numbers move.

Sources for §9–§10:
[token consumption in agentic coding](https://digitaleconomy.stanford.edu/publication/how-do-ai-agents-spend-your-money-analyzing-and-predicting-token-consumption-in-agentic-coding-tasks/),
[tools talk too much / byte caps](https://dev.to/teppana88/your-ai-coding-agents-are-slow-because-your-tools-talk-too-much-24h6),
[Codex truncates critical error lines](https://github.com/openai/codex/issues/9502),
[large tool output overflows the window](https://github.com/openai/codex/issues/4398),
[context-window overflow / Memory-Pointer pattern](https://dev.to/aws/ai-context-window-overflow-memory-pointer-fix-3akc).
