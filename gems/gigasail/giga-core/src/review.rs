//! The review evaluator: turns a `DiffPlan` + the `review:` config into a
//! `ReviewReport` (verdict + gates + ranked findings). One evaluator, shared by
//! the MCP tools, CI, and the diff UI (the single-source-of-truth invariant in
//! docs/agents/tuning-configs.md §9). Pure logic — no I/O, no server deps.
//!
//! This is the first slice: SARIF findings by tier, coverage/mutation posture,
//! effect-derived purity, per-metric visibility/weight, configurable ranking
//! weights, and the gates that evaluate off data already in the plan
//! (`uncovered-tier1`, purity coverage gates). Reserved config (perf, tags,
//! test depth, hazard gates, branch-coverage requirements) parses and is
//! carried, but is not yet evaluated — each is flagged where it is skipped.

use crate::diff::{DiffPlan, LineVerification, SarifFindingSummary};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

// ─────────────────────────────── config ────────────────────────────────────

/// The `review:` section of `giga.yml`. Every subsection defaults, so an absent
/// `review:` behaves sanely (show everything, default weights, gate only on
/// uncovered T1). Reserved fields (`tests`, `perf`, `tags`, `retain`) parse for
/// forward-compatibility but are not yet consumed by the evaluator.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct ReviewConfig {
    #[serde(default)]
    pub metrics: BTreeMap<String, MetricPolicy>,
    #[serde(default)]
    pub weights: RiskWeights,
    #[serde(default)]
    pub purity: PurityConfig,
    #[serde(default)]
    pub gates: Vec<Gate>,
    #[serde(default)]
    pub report: ReportConfig,
    /// Which test producers run at each review stage (precommit / premerge) and
    /// whether mutation testing runs there. See `stage_tests`.
    #[serde(default)]
    pub tests: TestDepthConfig,
    /// A project graph: which files belong to each package, which packages it
    /// depends on, and the test producers to run for it. A change runs the
    /// affected packages (changed + everything that transitively depends on
    /// them). This is the "run these tests when these files change" model — not
    /// a build system (see tuning-configs.md §12–§13).
    #[serde(default)]
    pub packages: BTreeMap<String, Package>,
    /// Opt-in pre-test check gates. When true, `giga test` runs each affected
    /// package's `checks` (lint/format gates) before its producers and stops
    /// early if any fail. Off by default — checks only run when turned on (here
    /// or via `giga test --checks`). See tuning-configs.md §14.
    #[serde(default)]
    pub checks_enabled: bool,
    // Reserved (parsed, not yet evaluated) — see tuning-configs.md §3f–§3i.
    #[serde(default)]
    pub retain: Option<serde_json::Value>,
    #[serde(default)]
    pub perf: Option<serde_json::Value>,
    #[serde(default)]
    pub tags: BTreeMap<String, serde_json::Value>,
}

/// One node in the project graph.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct Package {
    /// Globs identifying this package's files (`gems/fact-mine/**`). A trailing
    /// `/**` matches the directory subtree; other entries match exactly.
    #[serde(default)]
    pub paths: Vec<String>,
    /// Packages this one depends on. A change to a dependency runs this package
    /// too (reverse-transitive closure).
    #[serde(default)]
    pub depends_on: Vec<String>,
    /// Test producers to run when this package is affected (precommit + premerge).
    #[serde(default)]
    pub producers: Vec<String>,
    /// Additional producers to run only at premerge (e.g. fuzz suites).
    #[serde(default)]
    pub premerge: Vec<String>,
    /// Pre-test check gates for this package (lint/format). Each entry is either
    /// a `contrib:<category>:<lang>` reference to a bundled recommended script,
    /// or a repo-relative script path. Only run when checks are enabled.
    #[serde(default)]
    pub checks: Vec<String>,
}

impl ReviewConfig {
    /// The producers to run for a set of changed paths at a stage: the union
    /// over every affected package (a package whose files changed, plus every
    /// package that transitively depends on it). Empty when no `packages` graph
    /// is configured — callers then fall back to the stage's profiles.
    pub fn affected_producers(&self, changed_paths: &[String], mode: ReviewMode) -> Vec<String> {
        let mut producers: BTreeSet<String> = BTreeSet::new();
        for name in self.affected_packages(changed_paths) {
            if let Some(pkg) = self.packages.get(name) {
                producers.extend(pkg.producers.iter().cloned());
                if mode == ReviewMode::Premerge {
                    producers.extend(pkg.premerge.iter().cloned());
                }
            }
        }
        producers.into_iter().collect()
    }

    /// The pre-test check refs for a set of changed paths: the union of `checks`
    /// over every affected package. Same affected-package set as
    /// `affected_producers`; checks do not vary by stage.
    pub fn affected_checks(&self, changed_paths: &[String]) -> Vec<String> {
        let mut checks: Vec<String> = Vec::new();
        for name in self.affected_packages(changed_paths) {
            if let Some(pkg) = self.packages.get(name) {
                for c in &pkg.checks {
                    if !checks.contains(c) {
                        checks.push(c.clone());
                    }
                }
            }
        }
        checks
    }

    /// The set of packages affected by a change: every package whose files
    /// changed, plus every package that transitively depends on one of those
    /// (reverse-transitive closure). Empty when no `packages` graph is
    /// configured. Ordering is deterministic (BTreeSet over package names).
    fn affected_packages(&self, changed_paths: &[String]) -> BTreeSet<&str> {
        let mut affected: BTreeSet<&str> = BTreeSet::new();
        if self.packages.is_empty() {
            return affected;
        }
        // Directly-changed packages.
        for (name, pkg) in &self.packages {
            if changed_paths
                .iter()
                .any(|p| pkg.paths.iter().any(|glob| path_matches(glob, p)))
            {
                affected.insert(name.as_str());
            }
        }
        // Reverse edges: dependency -> dependent. Close over them so a change to
        // a dependency pulls in its dependents.
        let mut queue: Vec<&str> = affected.iter().copied().collect();
        while let Some(dep) = queue.pop() {
            for (name, pkg) in &self.packages {
                if pkg.depends_on.iter().any(|d| d == dep) && affected.insert(name.as_str()) {
                    queue.push(name.as_str());
                }
            }
        }
        affected
    }
}

/// A minimal glob: a trailing `/**` matches the directory subtree; otherwise an
/// exact path match. Sufficient for package-root globs like `gems/fact-mine/**`.
fn path_matches(glob: &str, path: &str) -> bool {
    if let Some(prefix) = glob.strip_suffix("/**") {
        path == prefix || path.starts_with(&format!("{prefix}/"))
    } else {
        path == glob
    }
}

/// Per-stage test selection. `giga_precommit` runs the fast set (no mutation by
/// default); `giga_premerge` runs the exhaustive set (mutation on by default).
/// Turning mutation off at a stage forfeits the "covered but not killed"
/// signal — a test that executes a line without asserting anything about it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TestDepthConfig {
    #[serde(default = "precommit_default")]
    pub precommit: StageTests,
    #[serde(default = "premerge_default")]
    pub premerge: StageTests,
}

impl Default for TestDepthConfig {
    fn default() -> Self {
        Self {
            precommit: precommit_default(),
            premerge: premerge_default(),
        }
    }
}

/// The producers (by giga.yml profile) and whether mutation runs, for one stage.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct StageTests {
    /// giga.yml profiles whose producers run at this stage. A profile groups
    /// producers by `test_type` tag (unit / integration / fuzz), so a stage can
    /// mix "run unit + integration coverage" without naming each producer.
    #[serde(default)]
    pub profiles: Vec<String>,
    /// Whether mutation testing (test-miser / the mutant runner) runs here.
    #[serde(default)]
    pub mutation: bool,
}

fn precommit_default() -> StageTests {
    StageTests {
        profiles: vec!["ci".into()],
        mutation: false,
    }
}
fn premerge_default() -> StageTests {
    StageTests {
        profiles: vec!["ci".into(), "analyse".into()],
        mutation: true,
    }
}

/// The resolved test run for a stage, after applying the mutation-requirement
/// coupling. `mutation_forced` is true when a gate/purity kill-rate requirement
/// turned mutation on despite the stage default being off — surfaced so the
/// runner (and the agent) can see *why* mutants are running at precommit.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ResolvedStage {
    pub profiles: Vec<String>,
    pub mutation: bool,
    pub mutation_forced: bool,
}

impl ReviewConfig {
    /// Whether any active gate or purity bucket demands a mutant kill rate.
    /// If so, mutation MUST run wherever those gates apply — otherwise the
    /// verdict is permanently `critical` ("no mutants killed") no matter how
    /// good the tests are, and an agent can never satisfy it.
    pub fn requires_mutation(&self) -> bool {
        let gate_kill = self.gates.iter().any(|g| {
            g.require
                .as_ref()
                .and_then(|r| r.mutation_kill_rate)
                .is_some()
        });
        gate_kill
            || self.purity.pure.mutation_kill_rate.is_some()
            || self.purity.stateful.mutation_kill_rate.is_some()
    }

    /// The test run for a stage. Mutation is on when the stage default asks for
    /// it OR a kill-rate requirement forces it (`mutation_forced`).
    pub fn stage_tests(&self, mode: ReviewMode) -> ResolvedStage {
        let base = match mode {
            ReviewMode::Precommit => &self.tests.precommit,
            ReviewMode::Premerge => &self.tests.premerge,
        };
        let forced = !base.mutation && self.requires_mutation();
        ResolvedStage {
            profiles: base.profiles.clone(),
            mutation: base.mutation || forced,
            mutation_forced: forced,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MetricPolicy {
    pub policy: Visibility,
    /// Ranking weight when shown/deprioritized. `deprioritize` implies 0.
    #[serde(default)]
    pub weight: Option<f64>,
    /// A finding whose metric value is below this is dropped entirely.
    #[serde(default)]
    pub threshold: Option<f64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Visibility {
    Show,
    Deprioritize,
    Ignore,
}

/// Ranking weights that replace the hardcoded risk formula. Defaults reproduce
/// today's `apply_tier_one_hazards` behavior (T2/T3 weightless, T1/hazard = 8).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RiskWeights {
    #[serde(default = "one")]
    pub not_covered: f64,
    #[serde(default = "half")]
    pub partially_covered: f64,
    #[serde(default = "two")]
    pub added_complexity: f64,
    #[serde(default = "eight")]
    pub tier_one_finding: f64,
    #[serde(default = "three")]
    pub tier_two_finding: f64,
    #[serde(default = "zero")]
    pub tier_three_finding: f64,
    #[serde(default = "eight")]
    pub unverified_hazard: f64,
    #[serde(default = "four")]
    pub uncovered_mutant: f64,
}

impl Default for RiskWeights {
    fn default() -> Self {
        Self {
            not_covered: 1.0,
            partially_covered: 0.5,
            added_complexity: 2.0,
            tier_one_finding: 8.0,
            tier_two_finding: 3.0,
            tier_three_finding: 0.0,
            unverified_hazard: 8.0,
            uncovered_mutant: 4.0,
        }
    }
}

impl RiskWeights {
    fn tier_weight(&self, tier: Option<u8>) -> f64 {
        match tier {
            Some(1) => self.tier_one_finding,
            Some(2) => self.tier_two_finding,
            Some(3) => self.tier_three_finding,
            _ => 0.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct PurityConfig {
    #[serde(default)]
    pub source: PuritySource,
    #[serde(default)]
    pub pure: CoverageRequire,
    #[serde(default)]
    pub stateful: CoverageRequire,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum PuritySource {
    #[default]
    Effects,
    Sarif,
    Off,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct CoverageRequire {
    #[serde(default)]
    pub line_coverage: Option<f64>,
    #[serde(default)]
    pub branch_coverage: Option<f64>,
    #[serde(default)]
    pub mutation_kill_rate: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Gate {
    pub id: String,
    pub when: GateWhen,
    #[serde(default)]
    pub require: Option<CoverageRequire>,
    #[serde(default)]
    pub unless_evidence: Vec<String>,
    #[serde(default = "critical_severity")]
    pub severity: Severity,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(deny_unknown_fields)]
pub struct GateWhen {
    #[serde(default)]
    pub tier: Option<u8>,
    #[serde(default)]
    pub coverage: Option<String>,
    #[serde(default)]
    pub hazard: Option<String>,
    #[serde(default)]
    pub verified: Option<bool>,
    #[serde(default)]
    pub mutant_killed: Option<bool>,
    #[serde(default)]
    pub purity: Option<String>,
    #[serde(default)]
    pub tag: Option<String>,
    #[serde(default)]
    pub on: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Critical,
    Warn,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ReportConfig {
    #[serde(default)]
    pub include_resolved: bool,
    #[serde(default = "default_max_findings")]
    pub max_findings_per_tier: usize,
    #[serde(default = "default_group_by")]
    pub group_by: String,
}

impl Default for ReportConfig {
    fn default() -> Self {
        Self {
            include_resolved: false,
            max_findings_per_tier: 25,
            group_by: "tier".into(),
        }
    }
}

fn zero() -> f64 {
    0.0
}
fn half() -> f64 {
    0.5
}
fn one() -> f64 {
    1.0
}
fn two() -> f64 {
    2.0
}
fn three() -> f64 {
    3.0
}
fn four() -> f64 {
    4.0
}
fn eight() -> f64 {
    8.0
}
fn critical_severity() -> Severity {
    Severity::Critical
}
fn default_max_findings() -> usize {
    25
}
fn default_group_by() -> String {
    "tier".into()
}

/// The default gate set when `review.gates` is empty: block on a new,
/// on-added-lines, uncovered T1 finding.
pub fn default_gates() -> Vec<Gate> {
    vec![Gate {
        id: "uncovered-tier1".into(),
        when: GateWhen {
            tier: Some(1),
            coverage: Some("uncovered".into()),
            on: Some("added".into()),
            ..GateWhen::default()
        },
        require: None,
        unless_evidence: Vec::new(),
        severity: Severity::Critical,
    }]
}

// ─────────────────────────────── report ────────────────────────────────────

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReviewMode {
    Precommit,
    Premerge,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Verdict {
    Pass,
    NeedsReview,
    Critical,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReviewReport {
    pub mode: ReviewMode,
    pub range: ReviewRange,
    pub verdict: Verdict,
    pub gates_triggered: Vec<GateHit>,
    pub summary: ReviewSummary,
    /// The test depth resolved for this stage (which profiles, whether mutation
    /// ran, and whether a kill-rate requirement forced it on).
    pub tests: ResolvedStage,
    pub findings: Vec<ReviewFinding>,
    pub deprioritized: usize,
    pub ignored: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReviewRange {
    pub base: String,
    pub head: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GateHit {
    pub id: String,
    pub severity: Severity,
    pub count: usize,
    pub reason: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReviewSummary {
    pub findings: TierCounts,
    pub coverage: CoveragePosture,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize)]
pub struct TierCounts {
    pub t1: usize,
    pub t2: usize,
    pub t3: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct CoveragePosture {
    pub line: f64,
    pub mutation_kill: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ReviewFinding {
    pub tier: Option<u8>,
    pub rule_id: String,
    pub tool: String,
    pub file: String,
    pub line: u32,
    pub message: String,
    pub coverage: String,
    pub weight: f64,
    pub deprioritized: bool,
    pub proof_boundary: Vec<String>,
}

// ─────────────────────────────── evaluator ──────────────────────────────────

/// A normalized new-SARIF candidate, decoupled from the plan so the policy/gate
/// logic is unit-testable without constructing a full `DiffPlan`.
#[derive(Debug, Clone)]
struct Candidate {
    file: String,
    finding: SarifFindingSummary,
    /// Per-line coverage of the finding's line (from the diff's line annotations).
    coverage: LineVerification,
    /// Whether the finding's line is an added line in the diff.
    on_added: bool,
}

pub fn evaluate(plan: &DiffPlan, config: &ReviewConfig, mode: ReviewMode) -> ReviewReport {
    let candidates = collect_candidates(plan);
    let gates = if config.gates.is_empty() {
        default_gates()
    } else {
        config.gates.clone()
    };

    let mut findings = Vec::new();
    let mut counts = TierCounts::default();
    let mut deprioritized = 0usize;
    let mut ignored = 0usize;

    for cand in &candidates {
        match classify(config, cand) {
            Decision::Ignore => ignored += 1,
            Decision::Keep { weight, deprio } => {
                if deprio {
                    deprioritized += 1;
                } else {
                    match cand.finding.tier {
                        Some(1) => counts.t1 += 1,
                        Some(2) => counts.t2 += 1,
                        Some(3) => counts.t3 += 1,
                        _ => {}
                    }
                }
                findings.push(ReviewFinding {
                    tier: cand.finding.tier,
                    rule_id: cand.finding.rule_id.clone(),
                    tool: cand.finding.tool.clone(),
                    file: cand.file.clone(),
                    line: cand.finding.start_line,
                    message: cand.finding.message.clone(),
                    coverage: coverage_label(cand.coverage).into(),
                    weight,
                    deprioritized: deprio,
                    proof_boundary: cand.finding.proof_boundary.clone(),
                });
            }
        }
    }

    // Ranked: highest weight first, then T1 before T2/T3, then by location.
    findings.sort_by(|a, b| {
        b.weight
            .total_cmp(&a.weight)
            .then(a.tier.unwrap_or(9).cmp(&b.tier.unwrap_or(9)))
            .then(a.file.cmp(&b.file))
            .then(a.line.cmp(&b.line))
    });
    cap_per_tier(&mut findings, config.report.max_findings_per_tier);

    let gates_triggered = evaluate_gates(&gates, &candidates, config);
    let verdict = verdict_from(&gates_triggered);

    ReviewReport {
        mode,
        range: ReviewRange {
            base: plan.scope.base_oid.clone(),
            head: plan.scope.head_oid.clone(),
        },
        verdict,
        gates_triggered,
        summary: ReviewSummary {
            findings: counts,
            coverage: coverage_posture(plan),
        },
        tests: config.stage_tests(mode),
        findings,
        deprioritized,
        ignored,
    }
}

enum Decision {
    Ignore,
    Keep { weight: f64, deprio: bool },
}

/// Apply the per-metric policy (§3a) + ranking weight (§3b) to one candidate.
/// Only `new` findings are review candidates; `resolved`/others are dropped.
fn classify(config: &ReviewConfig, cand: &Candidate) -> Decision {
    if cand.finding.status != "new" {
        return Decision::Ignore;
    }
    let policy = metric_policy(config, &cand.finding);
    let base_weight = config.weights.tier_weight(cand.finding.tier);
    match policy {
        Some(p) => match p.policy {
            Visibility::Ignore => Decision::Ignore,
            Visibility::Deprioritize => Decision::Keep {
                weight: p.weight.unwrap_or(0.0),
                deprio: true,
            },
            Visibility::Show => Decision::Keep {
                weight: p.weight.unwrap_or(base_weight),
                deprio: false,
            },
        },
        None => Decision::Keep {
            weight: base_weight,
            deprio: false,
        },
    }
}

/// Most-specific policy wins: an exact `rule_id` key over a bare `T<tier>` key.
fn metric_policy<'a>(
    config: &'a ReviewConfig,
    finding: &SarifFindingSummary,
) -> Option<&'a MetricPolicy> {
    config.metrics.get(&finding.rule_id).or_else(|| {
        finding
            .tier
            .and_then(|t| config.metrics.get(&format!("T{t}")))
    })
}

fn collect_candidates(plan: &DiffPlan) -> Vec<Candidate> {
    let mut out = Vec::new();
    for file in &plan.files {
        let added = file.added_line_numbers();
        let cov: BTreeMap<u32, LineVerification> = file
            .line_annotations
            .iter()
            .map(|a| (a.line, a.verification))
            .collect();
        // A file's findings live both directly and on its groups; dedupe by
        // (rule_id, line) so a finding attached at both levels counts once.
        let mut seen = BTreeSet::new();
        let group_findings = file.groups.iter().flat_map(|g| g.sarif_findings.iter());
        for finding in file.sarif_findings.iter().chain(group_findings) {
            if !seen.insert((finding.rule_id.clone(), finding.start_line)) {
                continue;
            }
            out.push(Candidate {
                file: file.path.clone(),
                coverage: cov
                    .get(&finding.start_line)
                    .copied()
                    .unwrap_or(LineVerification::Unknown),
                on_added: added.contains(&finding.start_line),
                finding: finding.clone(),
            });
        }
    }
    out
}

/// Evaluate the gates that operate off plan data today: tier + coverage +
/// on-added selectors. Hazard, purity-`require`, and branch-coverage gates are
/// reserved (their inputs are not in the plan yet) and are skipped here — see
/// tuning-configs.md §7 items 3–4.
fn evaluate_gates(gates: &[Gate], candidates: &[Candidate], _config: &ReviewConfig) -> Vec<GateHit> {
    let mut hits = Vec::new();
    for gate in gates {
        // Only finding-selector gates are wired in this slice.
        if gate.when.hazard.is_some()
            || gate.when.purity.is_some()
            || gate.when.tag.is_some()
            || gate.require.is_some()
        {
            continue;
        }
        let matched: Vec<&Candidate> = candidates
            .iter()
            .filter(|c| c.finding.status == "new")
            .filter(|c| gate.when.tier.is_none() || gate.when.tier == c.finding.tier)
            .filter(|c| {
                gate.when.on.as_deref() != Some("added") || c.on_added
            })
            .filter(|c| match gate.when.coverage.as_deref() {
                Some("uncovered") => matches!(c.coverage, LineVerification::NotCovered),
                Some("partial") => matches!(c.coverage, LineVerification::PartiallyCovered),
                Some(_) | None => true,
            })
            .collect();
        if !matched.is_empty() {
            hits.push(GateHit {
                id: gate.id.clone(),
                severity: gate.severity,
                count: matched.len(),
                reason: format!("{} finding(s) matched gate {}", matched.len(), gate.id),
            });
        }
    }
    hits
}

fn verdict_from(gates: &[GateHit]) -> Verdict {
    if gates.iter().any(|g| g.severity == Severity::Critical) {
        Verdict::Critical
    } else if gates.is_empty() {
        Verdict::Pass
    } else {
        Verdict::NeedsReview
    }
}

fn coverage_posture(plan: &DiffPlan) -> CoveragePosture {
    let mut covered_killed = 0usize;
    let mut measured = 0usize;
    let mut killed = 0usize;
    for file in &plan.files {
        let v = &file.verification;
        covered_killed += v.covered_and_killed + v.covered;
        killed += v.covered_and_killed;
        measured += v.covered_and_killed + v.covered + v.partially_covered + v.not_covered;
    }
    let ratio = |n: usize| if measured == 0 { 0.0 } else { n as f64 / measured as f64 };
    CoveragePosture {
        line: ratio(covered_killed),
        mutation_kill: ratio(killed),
    }
}

fn coverage_label(v: LineVerification) -> &'static str {
    match v {
        LineVerification::CoveredAndKilled => "covered+killed",
        LineVerification::Covered => "covered",
        LineVerification::PartiallyCovered => "partial",
        LineVerification::NotCovered => "uncovered",
        LineVerification::Unknown => "unknown",
    }
}

fn cap_per_tier(findings: &mut Vec<ReviewFinding>, max: usize) {
    if max == 0 {
        return;
    }
    let mut per: BTreeMap<Option<u8>, usize> = BTreeMap::new();
    findings.retain(|f| {
        let n = per.entry(f.tier).or_insert(0);
        *n += 1;
        *n <= max
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cfg(yaml: &str) -> ReviewConfig {
        serde_yaml::from_str(yaml).expect("parse review config")
    }

    fn finding(rule: &str, tier: u8, status: &str) -> SarifFindingSummary {
        SarifFindingSummary {
            source: "espalier".into(),
            tool: "nil-kill".into(),
            rule_id: rule.into(),
            level: "warning".into(),
            category: "safety".into(),
            message: "m".into(),
            fingerprint: "fp".into(),
            tier: Some(tier),
            tier_one: tier == 1,
            status: status.into(),
            provenance: Default::default(),
            proof_boundary: Vec::new(),
            start_line: 10,
            end_line: 10,
        }
    }

    fn cand(rule: &str, tier: u8, status: &str, cov: LineVerification, added: bool) -> Candidate {
        Candidate {
            file: "a.go".into(),
            finding: finding(rule, tier, status),
            coverage: cov,
            on_added: added,
        }
    }

    #[test]
    fn defaults_parse_and_reproduce_the_hardcoded_weights() {
        let c = ReviewConfig::default();
        assert_eq!(c.weights.tier_one_finding, 8.0);
        assert_eq!(c.weights.tier_two_finding, 3.0);
        assert_eq!(c.weights.tier_three_finding, 0.0);
        // An empty config gates only on uncovered T1.
        assert_eq!(default_gates()[0].id, "uncovered-tier1");
    }

    #[test]
    fn full_review_block_parses_with_reserved_fields() {
        let c = cfg(r#"
metrics:
  "T3": { policy: deprioritize, weight: 0.0 }
  "test-miser.redundant": { policy: ignore }
weights:
  tier_two_finding: 5.0
purity:
  source: effects
  stateful: { line_coverage: 1.0, branch_coverage: 1.0 }
gates:
  - id: uncovered-tier1
    when: { tier: 1, on: added, coverage: uncovered }
    severity: critical
perf: { enabled: false }
tags:
  critical: { match: { paths: ["internal/auth/**"] } }
"#);
        assert_eq!(c.weights.tier_two_finding, 5.0);
        assert_eq!(c.metrics["T3"].policy, Visibility::Deprioritize);
        assert_eq!(c.metrics["test-miser.redundant"].policy, Visibility::Ignore);
        assert!(c.perf.is_some());
        assert!(c.tags.contains_key("critical"));
    }

    #[test]
    fn metric_policy_ignore_deprioritize_and_specificity() {
        let c = cfg(r#"
metrics:
  "T3": { policy: deprioritize, weight: 0.0 }
  "espalier.nil": { policy: ignore }
"#);
        // rule_id key wins over the tier key.
        assert!(matches!(
            classify(&c, &cand("espalier.nil", 1, "new", LineVerification::NotCovered, true)),
            Decision::Ignore
        ));
        // A bare T3 is deprioritized (kept, weight 0).
        match classify(&c, &cand("other", 3, "new", LineVerification::Covered, true)) {
            Decision::Keep { weight, deprio } => {
                assert_eq!(weight, 0.0);
                assert!(deprio);
            }
            _ => panic!("expected kept+deprioritized"),
        }
        // Resolved findings are never candidates.
        assert!(matches!(
            classify(&c, &cand("other", 1, "resolved", LineVerification::NotCovered, true)),
            Decision::Ignore
        ));
    }

    #[test]
    fn uncovered_tier1_gate_fires_and_sets_critical() {
        let c = ReviewConfig::default();
        let gates = default_gates();
        // A new T1 on an uncovered added line → gate fires → critical.
        let hits = evaluate_gates(
            &gates,
            &[cand("r", 1, "new", LineVerification::NotCovered, true)],
            &c,
        );
        assert_eq!(hits.len(), 1);
        assert_eq!(verdict_from(&hits), Verdict::Critical);

        // A covered T1 does not fire.
        let hits = evaluate_gates(
            &gates,
            &[cand("r", 1, "new", LineVerification::Covered, true)],
            &c,
        );
        assert!(hits.is_empty());
        assert_eq!(verdict_from(&hits), Verdict::Pass);

        // An uncovered T1 that is NOT on an added line does not fire.
        let hits = evaluate_gates(
            &gates,
            &[cand("r", 1, "new", LineVerification::NotCovered, false)],
            &c,
        );
        assert!(hits.is_empty());
    }

    #[test]
    fn stage_defaults_precommit_skips_mutation_premerge_runs_it() {
        let c = ReviewConfig::default();
        let pre = c.stage_tests(ReviewMode::Precommit);
        assert!(!pre.mutation && !pre.mutation_forced);
        assert_eq!(pre.profiles, ["ci"]);
        let merge = c.stage_tests(ReviewMode::Premerge);
        assert!(merge.mutation && !merge.mutation_forced);
    }

    #[test]
    fn a_kill_rate_requirement_forces_mutation_at_precommit() {
        // A gate that requires a mutant kill rate must pull mutation into the
        // precommit run, or the verdict is stuck critical ("no mutants killed").
        let c = cfg(r#"
gates:
  - id: pure-kill
    when: { purity: pure }
    require: { mutation_kill_rate: 0.8 }
    severity: critical
"#);
        assert!(c.requires_mutation());
        let pre = c.stage_tests(ReviewMode::Precommit);
        assert!(pre.mutation, "mutation forced on at precommit");
        assert!(pre.mutation_forced, "and flagged as forced, not defaulted");
    }

    #[test]
    fn purity_kill_rate_also_forces_mutation() {
        let c = cfg(r#"
purity:
  pure: { line_coverage: 0.95, mutation_kill_rate: 0.8 }
"#);
        assert!(c.requires_mutation());
        assert!(c.stage_tests(ReviewMode::Precommit).mutation_forced);
    }

    #[test]
    fn custom_stage_config_parses_and_overrides_defaults() {
        let c = cfg(r#"
tests:
  precommit: { profiles: [unit], mutation: false }
  premerge:  { profiles: [unit, integration, fuzz], mutation: true }
"#);
        assert_eq!(c.tests.precommit.profiles, ["unit"]);
        assert_eq!(c.tests.premerge.profiles, ["unit", "integration", "fuzz"]);
        assert!(c.tests.premerge.mutation);
    }

    #[test]
    fn affected_producers_follows_the_reverse_dependency_closure() {
        let c = cfg(r#"
packages:
  fact-mine:  { paths: ["gems/fact-mine/**"], producers: [fact-mine-test] }
  giga-core:  { paths: ["gems/gigasail/giga-core/**"], producers: [giga-core-test] }
  boobytrap:  { paths: ["gems/boobytrap/**"], producers: [boobytrap-test], depends_on: [giga-core, fact-mine] }
  slopcop:    { paths: ["gems/slopcop/**"], producers: [slopcop-test], depends_on: [boobytrap] }
  compiler:   { paths: ["compiler/ruby/**"], producers: [compiler-spec, transpile], premerge: [fuzz-compiler] }
  zig:        { paths: ["zig/**"], producers: [zig-test, transpile], premerge: [fuzz-zig] }
"#);
        // A fact-mine change reaches boobytrap (deps on it) and slopcop (deps on boobytrap).
        let p = c.affected_producers(&["gems/fact-mine/src/x.rs".into()], ReviewMode::Precommit);
        assert_eq!(p, ["boobytrap-test", "fact-mine-test", "slopcop-test"]);
        // giga-core -> boobytrap -> slopcop too.
        let p = c.affected_producers(&["gems/gigasail/giga-core/src/diff.rs".into()], ReviewMode::Precommit);
        assert_eq!(p, ["boobytrap-test", "giga-core-test", "slopcop-test"]);
        // A compiler change: precommit runs spec+transpile; premerge adds fuzz.
        let pre = c.affected_producers(&["compiler/ruby/ast/parser.rb".into()], ReviewMode::Precommit);
        assert_eq!(pre, ["compiler-spec", "transpile"]);
        let merge = c.affected_producers(&["compiler/ruby/ast/parser.rb".into()], ReviewMode::Premerge);
        assert_eq!(merge, ["compiler-spec", "fuzz-compiler", "transpile"]);
        // A zig change doesn't drag in the compiler graph.
        let p = c.affected_producers(&["zig/runtime/switch.zig".into()], ReviewMode::Precommit);
        assert_eq!(p, ["transpile", "zig-test"]);
        // No packages -> empty (callers fall back to stage profiles).
        assert!(ReviewConfig::default()
            .affected_producers(&["x".into()], ReviewMode::Precommit)
            .is_empty());
    }

    #[test]
    fn affected_checks_unions_over_the_reverse_dependency_closure() {
        let c = cfg(r#"
checks_enabled: true
packages:
  fact-mine:  { paths: ["gems/fact-mine/**"], checks: ["contrib:lint:rust"] }
  slopcop:    { paths: ["gems/slopcop/**"], checks: ["contrib:lint:ruby"], depends_on: [fact-mine] }
  compiler:   { paths: ["compiler/ruby/**"], checks: ["contrib:lint:ruby", "tools/custom.rb"] }
"#);
        assert!(c.checks_enabled);
        // A fact-mine change pulls slopcop's checks in too (dedup keeps one ruby lint).
        let checks = c.affected_checks(&["gems/fact-mine/src/x.rs".into()]);
        assert_eq!(checks, ["contrib:lint:rust", "contrib:lint:ruby"]);
        // A compiler change runs only the compiler's checks.
        let checks = c.affected_checks(&["compiler/ruby/ast/parser.rb".into()]);
        assert_eq!(checks, ["contrib:lint:ruby", "tools/custom.rb"]);
        // No match / no packages -> no checks.
        assert!(c.affected_checks(&["docs/README.md".into()]).is_empty());
        assert!(ReviewConfig::default().affected_checks(&["x".into()]).is_empty());
    }

    #[test]
    fn hazard_and_require_gates_are_reserved_not_evaluated() {
        let c = ReviewConfig::default();
        let gates = vec![Gate {
            id: "unverified-hazard".into(),
            when: GateWhen {
                hazard: Some("any".into()),
                verified: Some(false),
                ..GateWhen::default()
            },
            require: None,
            unless_evidence: Vec::new(),
            severity: Severity::Critical,
        }];
        // Skipped in this slice → no hits (documented reservation).
        assert!(evaluate_gates(&gates, &[cand("r", 1, "new", LineVerification::NotCovered, true)], &c).is_empty());
    }
}
