# Tuning configs: review gates, metric weighting, and the review MCP surface

Status: **design / not yet built.** This specs a `review:` section for `giga.yml`,
two new review-oriented MCP tools, the report format they return to an LLM, and
how the same config later retunes the `giga diff` UI. It also ties into the
artifact-pruning TODO so pruning never deletes evidence a review still needs.

The goal: let a project declare **which findings matter, how much, and when a
change must be blocked for human/LLM review** — once, in `giga.yml` — and have
that single declaration drive (a) the MCP review report an agent reads, (b) the
diff-UI ranking and line visibility, and (c) the CI gate.

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

### `giga_review` — "What did I just change that needs review?"
- **Default range: `HEAD~1..HEAD`** (or `HEAD..WORKTREE` when the tree is dirty).
- Input: `{ base?: string, head?: string }`. Omitted → the default above.
- Answers the everyday "review my last commit" question.

### `giga_premerge` — "What does merging this branch introduce?"
- **Range: `merge-base(head, target)..head`**, i.e. every commit the branch adds
  on top of where it forked. `git merge_base` already backs `default_diff_base`
  (`db/git.rs`), so `giga review branch..master` and pre-merge are the same
  computation with `base = merge-base`.
- Input: `{ target?: string = "master", head?: string = current branch }`.

Both build the same `DiffPlan` the UI uses (via `build_structured_diff`), then
run the **review evaluator** (§4) over it: collect `status == "new"` SARIF
findings + active hazards + per-unit coverage/mutation posture, apply the
`review:` config (visibility/weight/gates), and emit the report (§5).

`review` shows the delta of *one step*; `pre-merge` shows the delta of the
*whole branch*. Nothing else differs — same report, same gates.

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
```

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
3. **Classify purity** per unit (§3c source):
   - `effects`: a unit with **no `write:` `added_state`** (from the architecture
     graph) **and no side-effecting active hazard** ⇒ `pure`; otherwise
     `stateful`. Unknown when no architecture graph is ingested.
   - `sarif`: presence of an `espalier.function` "impure function" note ⇒
     `stateful`; "read-only function" ⇒ `pure`.
   - `off`: purity gates are skipped.
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
  "new_state": ["write:count"]
}
```

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

Because the MCP report, the CI gate, and the UI all read the *same* evaluator
(§4), a finding the user chose not to see in the UI is also absent from the
LLM's feedback and from the merge gate — one config, one behavior everywhere.

---

## 7. Data gaps to build (honest list)

1. **`review:` config section** on `LineageConfig` + validation (weights ≥ 0,
   known gate `when` keys, `unless_evidence` families). `deny_unknown_fields`
   means the struct must exist before any `review:` key is accepted.
2. **Two MCP tools** (`giga_review`, `giga_premerge`) wrapping the §4 evaluator;
   register in `tool_defs()`/`call_tool` (`mcp.rs`). Reuse `build_structured_diff`.
3. **Branch coverage as a numeric per-unit axis.** Today branch data only sets
   `is_partial` + `coverage_percent` (`db/quality.rs`); the `branch_coverage`
   gates need a real `covered_branches/total_branches` rollup per unit. This is
   the one genuinely new metric plumbing.
4. **Derived purity signal.** No typed field exists. Cheapest: compute
   `pure = (no write: added_state) && (no side-effecting active hazard)` in the
   evaluator from data already in the plan; optionally consume the
   `espalier.function` SARIF note. Consider persisting it on `logical_units`
   later so the LSP/UI can show it too.
5. **Config-driven risk weights.** Replace the constants in
   `apply_tier_one_hazards` with `review.weights` (fall back to today's values).
6. **Branch-aware retention** (the `TODO.md` item). Reviews read evidence for
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
