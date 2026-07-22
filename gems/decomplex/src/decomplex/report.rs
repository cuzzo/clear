use crate::decomplex::convergence::{self, Unit};
use crate::decomplex::report_value as rv;
use crate::decomplex::root_cause::{self, Cluster};
use crate::decomplex::{delta, sarif};
use anyhow::{bail, Result};
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub struct ReportSection {
    detector_policy: DetectorPolicy,
    evidence_requirement: EvidenceRequirement,
    pub title: String,
    pub tier: i64,
    pub desc: String,
    pub findings: Vec<Value>,
    convergence_excluded: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum EvidenceScope {
    /// Only the source span rendered for this finding is an input.
    ReportedSpans,
    /// The complete enclosing executable function is an input.
    EnclosingFunction,
    /// The complete enclosing type/module/owner is an input.
    Owner,
    /// Every declaration and expression in the source file is an input.
    File,
    /// The detector reasons over absence/aggregation across the selected
    /// project, so an open or recovered corpus cannot support completeness.
    ClosedCorpus,
}

impl EvidenceScope {
    const fn proof_scope(self) -> sarif::ProofScopeKind {
        match self {
            Self::ReportedSpans => sarif::ProofScopeKind::ReportedSpan,
            Self::EnclosingFunction => sarif::ProofScopeKind::Function,
            Self::Owner => sarif::ProofScopeKind::Owner,
            Self::File => sarif::ProofScopeKind::File,
            Self::ClosedCorpus => sarif::ProofScopeKind::Project,
        }
    }

    const fn closed(self) -> bool {
        matches!(self, Self::ClosedCorpus)
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct EvidenceRequirement {
    scope: EvidenceScope,
    call_resolution: bool,
}

impl EvidenceRequirement {
    const REPORTED_SPANS: Self = Self {
        scope: EvidenceScope::ReportedSpans,
        call_resolution: false,
    };

    const fn with_call_resolution(mut self) -> Self {
        self.call_resolution = true;
        self
    }
}

/// Stable detector semantics. Display labels are deliberately not part of this
/// contract: reports may rename a heading without changing proof boundaries.
#[derive(Clone, Copy, Debug)]
struct DetectorPolicy {
    id: &'static str,
    claim_status: sarif::ClaimStatus,
    authority: &'static [&'static str],
}

impl DetectorPolicy {
    const STRUCTURAL: Self = Self {
        id: "decomplex_detector",
        claim_status: sarif::ClaimStatus::Observed,
        authority: &["fact_mine_normalized_ast"],
    };

    const REDUNDANT_NIL_GUARD: Self = Self {
        id: "redundant_nil_guard",
        claim_status: sarif::ClaimStatus::Review,
        authority: &["fact_mine_normalized_ast", "fact_mine_cfg"],
    };
}

impl ReportSection {
    pub fn new(title: &str, tier: i64, desc: &str, findings: Vec<Value>) -> Self {
        Self {
            detector_policy: DetectorPolicy::STRUCTURAL,
            title: title.to_string(),
            tier,
            desc: desc.to_string(),
            findings,
            evidence_requirement: EvidenceRequirement::REPORTED_SPANS,
            convergence_excluded: false,
        }
    }

    fn with_call_resolution(mut self) -> Self {
        self.evidence_requirement = self.evidence_requirement.with_call_resolution();
        self
    }

    fn with_evidence_scope(mut self, scope: EvidenceScope) -> Self {
        self.evidence_requirement.scope = scope;
        self
    }

    fn with_policy(mut self, detector_policy: DetectorPolicy) -> Self {
        self.detector_policy = detector_policy;
        self
    }

    fn excluded_from_convergence(mut self) -> Self {
        self.convergence_excluded = true;
        self
    }
}

#[derive(Clone, Debug)]
pub struct FindingsRollup {
    pub files: Vec<String>,
    pub sections: Vec<ReportSection>,
    pub convergence: Vec<Unit>,
    pub root: Vec<Cluster>,
}

impl FindingsRollup {
    pub fn from_facts(facts: &Value) -> Result<Self> {
        let files = rv::field_array_strings(facts, "files");
        let Some(detectors) = rv::get(facts, "detectors") else {
            bail!("report facts missing detectors");
        };
        let sections = build_sections(detectors, facts);
        validate_spans(&sections)?;
        let convergence_sections = sections
            .iter()
            .filter(|section| !section.convergence_excluded)
            .cloned()
            .collect::<Vec<_>>();
        let convergence = convergence::rollup(&convergence_sections, 2);
        let root = root_cause::cluster(&convergence_sections, 2);
        Ok(Self {
            files,
            sections,
            convergence,
            root,
        })
    }

    pub fn convergence_value(&self) -> Value {
        json!(self.convergence)
    }

    pub fn root_clusters_value(&self) -> Value {
        json!(self.root)
    }
}

pub struct MarkdownEmitter;

impl MarkdownEmitter {
    pub fn render(rollup: &FindingsRollup) -> String {
        let mut out = String::from("# Decomplex Report\n\n");
        out.push_str("> Decision-level duplication and neglected-condition analysis.\n");
        out.push_str("> Every entry is a ranked **candidate** (Engler's discipline),\n");
        out.push_str("> never a verdict -- *POSSIBLE* findings, triaged by a human.\n");
        out.push_str("> Sections are ordered by SIGNAL TIER (1 = lowest false\n");
        out.push_str("> positive), not by volume. Items within a section are\n");
        out.push_str("> frequency-ranked. Triage tier 1, top-of-list, first.\n\n");

        out.push_str("## Table of Contents\n");
        out.push_str("- [Project Prioritization](#project-prioritization)\n");
        out.push_str(&format!(
            "- [Cross-Detector Convergence ({})](#cross-detector-convergence-{})\n",
            rollup.convergence.len(),
            rollup.convergence.len()
        ));
        out.push_str(&format!(
            "- [Root-Cause Clusters ({})](#root-cause-clusters-{})\n",
            rollup.root.len(),
            rollup.root.len()
        ));
        for section in &rollup.sections {
            out.push_str(&format!(
                "- [{} ({})](#{}-{})\n",
                section.title,
                section.findings.len(),
                slug(&section.title),
                section.findings.len()
            ));
        }
        out.push_str("- [Run Summary](#run-summary)\n\n");

        Self::render_project_prioritization(rollup, &mut out);
        Self::render_convergence(rollup, &mut out);
        Self::render_root_cause(rollup, &mut out);

        for section in &rollup.sections {
            out.push_str(&format!(
                "## {} ({})\n",
                section.title,
                section.findings.len()
            ));
            out.push_str(&format!("_{}_\n\n", section.desc));
            if section.findings.is_empty() {
                out.push_str("None.\n\n");
                continue;
            }
            Self::render_section(rollup, &mut out, section);
            out.push('\n');
        }

        out.push_str("## Run Summary\n");
        out.push_str(&format!("- Files analyzed: {}\n", rollup.files.len()));
        out.push_str(&format!(
            "- Detectors: {} (all shipped, self-tested)\n",
            rollup.sections.len()
        ));
        out.push_str(&format!(
            "- Convergence: {} unit(s) flagged by >=2 independent detectors\n",
            rollup.convergence.len()
        ));
        out.push_str(&format!(
            "- Root-cause clusters: {} (one fix collapses each)\n",
            rollup.root.len()
        ));
        let total: usize = rollup
            .sections
            .iter()
            .map(|section| section.findings.len())
            .sum();
        out.push_str(&format!("- Total candidates: {total}\n"));
        out.push_str("- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Type-2/3 similarity uses Tree-sitter structural fingerprints (see docs/agents/design.md)\n");
        out
    }

    fn render_project_prioritization(rollup: &FindingsRollup, out: &mut String) {
        out.push_str("## Project Prioritization\n");
        out.push_str(
            "_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._\n\n",
        );
        let mut ranked = rollup
            .sections
            .iter()
            .enumerate()
            .filter(|(_, section)| !section.findings.is_empty())
            .collect::<Vec<_>>();
        ranked.sort_by(|(left_index, left), (right_index, right)| {
            left.tier
                .cmp(&right.tier)
                .then_with(|| right.findings.len().cmp(&left.findings.len()))
                .then_with(|| left_index.cmp(right_index))
        });
        for (_, section) in ranked {
            out.push_str(&format!(
                "- **[tier {}]** [{} ({})](#{}-{}): {}\n",
                section.tier,
                section.title,
                section.findings.len(),
                slug(&section.title),
                section.findings.len(),
                section.desc
            ));
        }
        if rollup
            .sections
            .iter()
            .all(|section| section.findings.is_empty())
        {
            out.push_str("\nNothing flagged.\n");
        }
        out.push('\n');
    }

    fn render_convergence(rollup: &FindingsRollup, out: &mut String) {
        out.push_str(&format!(
            "## Cross-Detector Convergence ({})\n",
            rollup.convergence.len()
        ));
        out.push_str("_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_\n\n");
        if rollup.convergence.is_empty() {
            out.push_str("None (no unit flagged by >=2 detectors).\n\n");
            return;
        }
        for hit in rollup.convergence.iter().take(25) {
            out.push_str(&format!(
                "- {} -- **{} detectors** [score {}, {} findings]: {}\n",
                nav(&hit.at),
                hit.n_detectors,
                hit.score,
                hit.findings,
                hit.detectors.join(", ")
            ));
        }
        if rollup.convergence.len() > 25 {
            out.push_str(&format!("- ...(+{} more)\n", rollup.convergence.len() - 25));
        }
        let by_file = convergence::by_file(&rollup.convergence);
        if !by_file.is_empty() {
            out.push_str("\n### By file\n");
            for hit in by_file.iter().take(15) {
                out.push_str(&format!(
                    "- `{}` -- {} detectors across {} method(s): {}\n",
                    hit.file,
                    hit.n_detectors,
                    hit.methods,
                    hit.detectors.join(", ")
                ));
            }
        }
        out.push('\n');
    }

    fn render_root_cause(rollup: &FindingsRollup, out: &mut String) {
        out.push_str(&format!("## Root-Cause Clusters ({})\n", rollup.root.len()));
        out.push_str("_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._\n\n");
        if rollup.root.is_empty() {
            out.push_str("None (no entity named by >=2 detectors).\n\n");
            return;
        }
        for hit in rollup.root.iter().take(20) {
            let tag = if hit.fat_union {
                format!("[{} | FAT-UNION]", hit.kind)
            } else {
                format!("[{}]", hit.kind)
            };
            out.push_str(&format!(
                "- **{}** `{}` -- **{} detectors** [score {}] across {} unit(s), {} findings: {}\n  - FIX: {}\n  - {}\n",
                tag,
                hit.token,
                hit.n_detectors,
                hit.score,
                hit.scatter,
                hit.support,
                hit.detectors.join(", "),
                hit.fix,
                hit.sites.iter().take(4).map(|site| nav(site)).collect::<Vec<_>>().join(" ; ")
            ));
        }
        if rollup.root.len() > 20 {
            out.push_str(&format!("- ...(+{} more)\n", rollup.root.len() - 20));
        }
        out.push('\n');
    }

    fn render_section(_rollup: &FindingsRollup, out: &mut String, section: &ReportSection) {
        for finding in section.findings.iter().take(25) {
            out.push_str(&render_finding(&section.title, finding));
        }
        if section.findings.len() > 25 {
            out.push_str(&format!("- ...(+{} more)\n", section.findings.len() - 25));
        }
    }
}

pub struct SarifEmitter;

impl SarifEmitter {
    pub fn render(rollup: &FindingsRollup) -> String {
        serde_json::to_string_pretty(&Self::to_value(rollup, false, false, None)).unwrap()
    }

    pub fn to_value(
        rollup: &FindingsRollup,
        include_snapshot: bool,
        include_finding_payload: bool,
        max_results: Option<usize>,
    ) -> Value {
        let snapshot = delta::snapshot(&rollup.sections, &rollup.root);
        let mut results = Self::sarif_results(rollup, include_finding_payload);
        if let Some(max_results) = max_results {
            results = ranked_sarif_results(results)
                .into_iter()
                .take(max_results)
                .collect();
        }
        let mut properties = json!({
            "format": "decomplex.report.sarif.v1",
            "files": rollup.files,
        });
        if include_snapshot {
            if let Some(object) = properties.as_object_mut() {
                object.insert("decomplex.snapshot".to_string(), snapshot);
            }
        }
        if let Some(object) = properties.as_object_mut() {
            object.insert(
                sarif::PROOF_BOUNDARY_SUMMARY_PROPERTY.to_string(),
                sarif::proof_boundary_summary(&results),
            );
        }
        sarif::document(
            "Decomplex",
            Self::sarif_rules(rollup),
            results,
            Some("https://github.com/cuzzo/clear"),
            properties,
        )
    }

    fn sarif_rules(rollup: &FindingsRollup) -> Vec<Value> {
        rollup
            .sections
            .iter()
            .map(|section| {
                sarif::rule(
                    &sarif_rule_id(&section.title),
                    Some(&section.title),
                    Some(&section.desc),
                    None,
                    if section.tier <= 1 { "warning" } else { "note" },
                    None,
                    json!({ "tier": section.tier }),
                )
            })
            .collect()
    }

    fn sarif_results(rollup: &FindingsRollup, include_finding_payload: bool) -> Vec<Value> {
        let mut out = Vec::new();
        for section in &rollup.sections {
            for finding in &section.findings {
                for location in sarif_locations_for_finding(finding) {
                    let mut properties = json!({
                        "detector": section.title,
                        "tier": section.tier,
                        "method": location.method,
                    });
                    if let Some(object) = properties.as_object_mut() {
                        object.insert(
                            sarif::PROOF_BOUNDARY_PROPERTY.to_string(),
                            finding_proof_boundary(section, finding),
                        );
                    }
                    if include_finding_payload {
                        if let Some(object) = properties.as_object_mut() {
                            object.insert(
                                "decomplex_finding".to_string(),
                                delta::json_safe_finding(&section.title, finding),
                            );
                        }
                    }
                    out.push(sarif::result(
                        &sarif_rule_id(&section.title),
                        &sarif_message(&section.title, finding, &location),
                        location.path.as_deref(),
                        Some(location.line),
                        location.start_column,
                        location.end_line,
                        location.end_column,
                        if section.tier <= 1 { "warning" } else { "note" },
                        properties,
                        json!({ "decomplexFinding": delta::fingerprint(&section.title, finding) }),
                    ));
                }
            }
        }
        out
    }
}

fn finding_proof_boundary(section: &ReportSection, finding: &Value) -> Value {
    rv::get(finding, "proof_boundary")
        .cloned()
        .unwrap_or_else(|| {
            // Only old, externally supplied detector payloads reach this path.
            // Their generic fields are intentionally not reinterpreted at render
            // time: absence of an explicit boundary is an unknown observation.
            sarif::proof_boundary(
                sarif::InputCompleteness::Unknown,
                section.detector_policy.claim_status,
                sarif::CoverageDischarge::NotApplicable,
                section.detector_policy.authority,
                section.detector_policy.id,
                section.evidence_requirement.scope.proof_scope(),
                section.evidence_requirement.scope.closed(),
                Vec::new(),
            )
        })
}

#[derive(Clone, Debug)]
pub struct Report {
    pub rollup: FindingsRollup,
}

impl Report {
    pub fn from_facts(facts: &Value) -> Result<Self> {
        let rollup = FindingsRollup::from_facts(facts)?;
        Ok(Self { rollup })
    }

    pub fn to_markdown(&self) -> String {
        MarkdownEmitter::render(&self.rollup)
    }

    pub fn to_sarif(&self) -> String {
        SarifEmitter::render(&self.rollup)
    }

    pub fn to_snapshot(&self) -> Value {
        delta::snapshot(&self.rollup.sections, &self.rollup.root)
    }

    pub fn to_sarif_value(
        &self,
        include_snapshot: bool,
        include_finding_payload: bool,
        max_results: Option<usize>,
    ) -> Value {
        SarifEmitter::to_value(
            &self.rollup,
            include_snapshot,
            include_finding_payload,
            max_results,
        )
    }

    pub fn convergence_value(&self) -> Value {
        self.rollup.convergence_value()
    }

    pub fn root_clusters_value(&self) -> Value {
        self.rollup.root_clusters_value()
    }
}

#[derive(Clone, Debug)]
struct SarifLocation {
    path: Option<String>,
    method: Option<String>,
    line: i64,
    start_column: Option<i64>,
    end_line: Option<i64>,
    end_column: Option<i64>,
    /// Tree-sitter coordinates retained for evidence matching. SARIF columns
    /// are one-based; parser recovery spans are zero-based.
    source_start_column: Option<i64>,
    source_end_column: Option<i64>,
}

impl SarifLocation {
    fn source_span(&self) -> [i64; 4] {
        [
            self.line,
            self.source_start_column.unwrap_or(i64::MIN),
            self.end_line.unwrap_or(self.line),
            self.source_end_column.unwrap_or(i64::MAX),
        ]
    }
}

fn build_sections(detectors: &Value, facts: &Value) -> Vec<ReportSection> {
    let miner = rv::get(detectors, "miner").unwrap_or(&Value::Null);
    let co_update = rv::get(detectors, "co_update").unwrap_or(&Value::Null);
    let semantic_alias = rv::get(detectors, "semantic_alias").unwrap_or(&Value::Null);
    let path_condition = rv::get(detectors, "path_condition").unwrap_or(&Value::Null);
    let sequence_mine = rv::get(detectors, "sequence_mine").unwrap_or(&Value::Null);
    let fat_union = rv::get(detectors, "fat_union").unwrap_or(&Value::Null);
    let operational = direct_array(detectors, "operational_discontinuity");
    let (operational_high, operational_rest): (Vec<_>, Vec<_>) = operational
        .into_iter()
        .partition(|finding| rv::field(finding, "confidence") == "high");

    let mut sections = vec![
        section("Decision Pressure", 1, "ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)", direct_array(detectors, "decision_pressure")),
        section("Redundant Nil Guards", 1, "nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type", direct_array(detectors, "redundant_nil_guard")).with_policy(DetectorPolicy::REDUNDANT_NIL_GUARD),
        section("State Heatmap", 1, "state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner", direct_array(detectors, "state_heatmap")).with_evidence_scope(EvidenceScope::Owner).excluded_from_convergence(),
        section("Superfluous State", 1, "state fields that could be eliminated entirely (dead state / intra-method pass-through / adjacent-call pass-through / derived cache)", direct_array(detectors, "superfluous_state")).with_evidence_scope(EvidenceScope::ClosedCorpus),
        section("Declared Type Pressure", 2, "normalized declared-type shapes where multiple pressures converge (wide/nested unions, unknown leaves, collection depth, and nilability)", direct_array(detectors, "declared_type_pressure")),
        section("State-Based Branch Density", 1, "branch decisions over mutable/object state -- state + control-flow pressure", direct_array(detectors, "state_branch_density")).with_evidence_scope(EvidenceScope::File),
        section("Temporal Ordering Pressure", 1, "public mutable lifecycle surfaces that create implicit state-machine ordering", direct_array(detectors, "temporal_ordering_pressure")),
        section("Scoped State Restoration", 1, "temporary mutable-state scopes with a proven restoration bypass, or a lower-confidence unprotected call before restoration", direct_array(detectors, "scoped_state_restoration")),
        section("Missing Abstractions", 1, "guard tuple recomputed across >=2 decision units", nested_array(miner, "missing_abstractions")),
        section("Reification Misses", 1, "an existing predicate reinvented inline -- invariant #16", nested_array(semantic_alias, "reification_misses")),
        section("Semantic Predicate Aliases", 1, "one decision, multiple names (receiver/polarity folded)", nested_array(semantic_alias, "alias_clusters")),
        section("Exact Predicate Aliases", 1, "identical one-line predicate body under >=2 names", nested_array(rv::get(detectors, "predicate_alias").unwrap_or(&Value::Null), "alias_clusters")),
        section("Inconsistent Rename Clones", 2, "pasted block with inconsistent identifier mapping -- *POSSIBLE* missed rename bug", direct_array(detectors, "inconsistent_rename_clone")),
        section("Structural Similarity (Type-2/3)", 2, "Tree-sitter structural clone pressure: Type-2 renamed clones and Type-3 fuzzy clones -- refactor pressure, not a verdict", direct_array(detectors, "flay_similarity")),
        section("Neglected Updates", 2, "co-written state, one write missing -- *POSSIBLE* redundant-state desync", nested_array(co_update, "neglected_updates")),
        section("Derived-State Staleness", 2, "b = f(a); a later reassigned, b not recomputed -- *POSSIBLE* bug", direct_array(detectors, "derived_state")),
        section("Neglected Conditions", 2, "dispatch/conjunction minus one element -- *POSSIBLE* bug", nested_array(miner, "neglected_conditions")),
        section("Neglected Path Conditions", 3, "nested-if/&& guard set minus one atom -- *POSSIBLE* bug (noisy)", nested_array(path_condition, "neglected")),
        section("Oversized Predicates", 3, "predicate with >3 condition atoms -- use an existing helper or extract a named predicate", direct_array(detectors, "oversized_predicate")),
        section("Broken Protocols", 3, "co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)", nested_array(sequence_mine, "broken_protocol")).with_evidence_scope(EvidenceScope::ClosedCorpus),
        section("Implicit Control Flow", 2, "state-dependent internal call order exists -- hidden lifecycle/control-flow pressure", nested_array(rv::get(detectors, "implicit_control_flow").unwrap_or(&Value::Null), "ordered_protocols")).with_evidence_scope(EvidenceScope::ClosedCorpus).with_call_resolution(),
        section("Weighted Inlined Cognitive Complexity", 2, "same-owner helper chain hides cognitive load behind a low-looking orchestration method", direct_array(detectors, "weighted_inlined_complexity")).with_evidence_scope(EvidenceScope::EnclosingFunction).with_call_resolution(),
        section("Locality Drag", 2, "local initialized far before first use while unrelated work runs -- move setup closer or extract a private phase", direct_array(detectors, "locality_drag")),
        section("Operational Discontinuity (High Confidence)", 2, "strong blank/comment phase boundary where local variable lifetimes reset -- likely implicit sub-function boundary", operational_high),
        section("Function LCOM", 3, "independent local data-flow components inside one method -- *POSSIBLE* mixed concerns", direct_array(detectors, "function_lcom")).with_evidence_scope(EvidenceScope::EnclosingFunction),
        section("Operational Discontinuity", 3, "blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary", operational_rest),
        section("False Simplicity", 3, "looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/reflection/reopen -- *POSSIBLE* (noisy)", direct_array(detectors, "false_simplicity")).with_evidence_scope(EvidenceScope::EnclosingFunction).with_call_resolution(),
        section("Fat Unions", 3, "case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*", nested_array(fat_union, "fat_unions")),
    ];
    attach_detector_boundaries(&mut sections, facts);
    sections
}

fn attach_detector_boundaries(sections: &mut [ReportSection], facts: &Value) {
    for section in sections {
        for finding in &mut section.findings {
            if !finding.is_object() {
                continue;
            }
            if finding.get("proof_boundary").is_some() {
                continue;
            }
            let (input_completeness, blockers) =
                finding_input_boundary(section.evidence_requirement, finding, facts);
            finding
                .as_object_mut()
                .expect("object checked above")
                .insert(
                    "proof_boundary".to_string(),
                    sarif::proof_boundary(
                        input_completeness,
                        section.detector_policy.claim_status,
                        sarif::CoverageDischarge::NotApplicable,
                        section.detector_policy.authority,
                        section.detector_policy.id,
                        section.evidence_requirement.scope.proof_scope(),
                        section.evidence_requirement.scope.closed(),
                        blockers,
                    ),
                );
        }
    }
}

/// Resolves the boundary from explicit extractor evidence, never from generic
/// presentation fields.  A structural detector needs only the parsed source
/// locations it reports.  Call-sensitive detectors additionally need every
/// enclosing function that supplied call facts to be free of unresolved
/// eligible calls.
fn finding_input_boundary(
    evidence_requirement: EvidenceRequirement,
    finding: &Value,
    facts: &Value,
) -> (sarif::InputCompleteness, Vec<sarif::ProofBlocker>) {
    let by_file = facts
        .pointer("/semantic_evidence/by_file")
        .and_then(Value::as_object);
    let locations = sarif_locations_for_finding(finding);
    if locations.is_empty() {
        return (
            sarif::InputCompleteness::Unknown,
            vec![sarif::ProofBlocker::missing_evidence(None)],
        );
    }
    let mut partial = Vec::new();
    let mut unknown = Vec::new();
    if evidence_requirement.scope == EvidenceScope::ClosedCorpus {
        if facts.pointer("/corpus/complete").and_then(Value::as_bool) != Some(true) {
            unknown.push(sarif::ProofBlocker::open_corpus());
        }
        if let Some(files) = by_file {
            for (path, file) in files {
                if file.get("normalized_ast_complete").and_then(Value::as_bool) != Some(true) {
                    let recoveries = recovery_spans(file, [1, i64::MIN, i64::MAX, i64::MAX]);
                    if recoveries.is_empty() {
                        unknown.push(sarif::ProofBlocker::parser_recovery(path, None));
                    } else {
                        unknown.extend(
                            recoveries
                                .into_iter()
                                .map(|span| sarif::ProofBlocker::parser_recovery(path, Some(span))),
                        );
                    }
                }
            }
        }
    }
    for location in locations {
        let Some(path) = location.path.as_deref() else {
            return (
                sarif::InputCompleteness::Unknown,
                vec![sarif::ProofBlocker::missing_evidence(None)],
            );
        };
        let Some(file) = by_file.and_then(|files| files.get(path)) else {
            return (
                sarif::InputCompleteness::Unknown,
                vec![sarif::ProofBlocker::missing_evidence(Some(
                    path.to_string(),
                ))],
            );
        };
        if evidence_requirement.scope != EvidenceScope::ClosedCorpus {
            match dependency_span(evidence_requirement.scope, file, &location) {
                Some(span) => {
                    let recoveries = recovery_spans(file, span);
                    if !recoveries.is_empty() {
                        unknown.extend(recoveries.into_iter().map(|recovery| {
                            sarif::ProofBlocker::parser_recovery(path, Some(recovery))
                        }));
                    } else if rv::array_from(file.get("parse_recovery_spans")).is_empty()
                        && file.get("normalized_ast_complete").and_then(Value::as_bool)
                            != Some(true)
                    {
                        unknown.push(sarif::ProofBlocker::parser_recovery(path, None));
                    }
                }
                None => unknown.push(sarif::ProofBlocker::missing_evidence(Some(
                    path.to_string(),
                ))),
            }
        }
        if evidence_requirement.call_resolution {
            partial.extend(
                file.get("unresolved_call_function_spans")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter(|span| span_contains_location(span, &location))
                    .filter_map(value_span)
                    .map(|span| sarif::ProofBlocker::call_resolution(path, Some(span))),
            );
        }
    }
    unknown.sort();
    unknown.dedup();
    if !unknown.is_empty() {
        return (sarif::InputCompleteness::Unknown, unknown);
    }
    partial.sort();
    partial.dedup();
    if partial.is_empty() {
        (sarif::InputCompleteness::Complete, partial)
    } else {
        (sarif::InputCompleteness::Partial, partial)
    }
}

fn dependency_span(
    scope: EvidenceScope,
    file: &Value,
    location: &SarifLocation,
) -> Option<[i64; 4]> {
    match scope {
        EvidenceScope::ReportedSpans => Some(location.source_span()),
        EvidenceScope::File => Some([1, i64::MIN, i64::MAX, i64::MAX]),
        EvidenceScope::EnclosingFunction => containing_span(file, "function_spans", location),
        EvidenceScope::Owner => containing_span(file, "owner_spans", location),
        EvidenceScope::ClosedCorpus => Some([1, i64::MIN, i64::MAX, i64::MAX]),
    }
}

fn containing_span(file: &Value, key: &str, location: &SarifLocation) -> Option<[i64; 4]> {
    file.get(key)
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(value_span)
        .filter(|span| span_contains_location_values(*span, location))
        .min_by_key(|span| (span[2] - span[0], span[3] - span[1]))
}

fn value_span(span: &Value) -> Option<[i64; 4]> {
    let values = rv::array_from(Some(span));
    Some([
        values.first()?.as_i64()?,
        values.get(1)?.as_i64()?,
        values.get(2)?.as_i64()?,
        values.get(3)?.as_i64()?,
    ])
}

#[cfg(test)]
fn recovery_affects_span(file: &Value, dependency: [i64; 4]) -> bool {
    !recovery_spans(file, dependency).is_empty()
        || (rv::array_from(file.get("parse_recovery_spans")).is_empty()
            && file.get("normalized_ast_complete").and_then(Value::as_bool) != Some(true))
}

fn recovery_spans(file: &Value, dependency: [i64; 4]) -> Vec<[i64; 4]> {
    rv::array_from(file.get("parse_recovery_spans"))
        .iter()
        .filter_map(value_span)
        .filter(|recovery| spans_overlap(*recovery, dependency))
        .collect()
}

fn spans_overlap(left: [i64; 4], right: [i64; 4]) -> bool {
    (left[0], left[1]) <= (right[2], right[3]) && (right[0], right[1]) <= (left[2], left[3])
}

fn span_contains_location(span: &Value, location: &SarifLocation) -> bool {
    value_span(span).is_some_and(|span| span_contains_location_values(span, location))
}

fn span_contains_location_values(span: [i64; 4], location: &SarifLocation) -> bool {
    let point = (
        location.line,
        location.source_start_column.unwrap_or(i64::MIN),
    );
    (span[0], span[1]) <= point && point <= (span[2], span[3])
}

fn section(title: &str, tier: i64, desc: &str, findings: Vec<Value>) -> ReportSection {
    ReportSection::new(title, tier, desc, findings)
}

fn direct_array(value: &Value, key: &str) -> Vec<Value> {
    rv::array(value, key).to_vec()
}

fn nested_array(value: &Value, key: &str) -> Vec<Value> {
    rv::array(value, key).to_vec()
}

fn validate_spans(sections: &[ReportSection]) -> Result<()> {
    for section in sections
        .iter()
        .filter(|section| !section.convergence_excluded)
    {
        for finding in &section.findings {
            let Some(spans) = rv::get(finding, "spans").and_then(Value::as_object) else {
                continue;
            };
            for (loc, span) in spans {
                if span.is_null() {
                    continue;
                }
                let values = span.as_array();
                let ok = values.is_some_and(|values| {
                    values.len() == 4
                        && values[0].as_i64().is_some()
                        && values[2].as_i64().is_some()
                        && values[0].as_i64() <= values[2].as_i64()
                });
                if !ok {
                    bail!(
                        "decomplex: {} emitted malformed span {} for {}",
                        section.title,
                        span,
                        loc
                    );
                }
            }
        }
    }
    Ok(())
}

pub fn slug(title: &str) -> String {
    title
        .to_lowercase()
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || ch == ' ' {
                ch
            } else {
                '\0'
            }
        })
        .filter(|ch| *ch != '\0')
        .collect::<String>()
        .replace(' ', "-")
}

pub fn nav(loc: &str) -> String {
    let parts = loc.split(':').collect::<Vec<_>>();
    if parts.len() < 3 {
        return loc.to_string();
    }
    let line = parts[parts.len() - 1];
    let method = parts[parts.len() - 2];
    let file = parts[..parts.len() - 2].join(":");
    format!("`{file}:{line}` ({method})")
}

fn render_finding(title: &str, h: &Value) -> String {
    match title {
        "Decision Pressure" => format!(
            "- `{}` -- ELIMINABLE guard-pressure **{}** across {} method(s) -> tighten contract / nil-kill: DELETE{}\n  - {}\n",
            rv::field(h, "contract"),
            rv::field(h, "decisions"),
            rv::field(h, "methods"),
            if rv::positive(h, "essential") {
                format!("  (+{} essential dispatch on this contract -- legitimate; leave unless Fat-Union/Missing-Abstractions says re-derived)", rv::field(h, "essential"))
            } else {
                String::new()
            },
            rv::array(h, "sites").iter().take(4).map(|site| nav(&rv::string(Some(site)))).collect::<Vec<_>>().join(" ; ")
        ),
        "Redundant Nil Guards" => format!(
            "- {} -- redundant nil guard on `{}`: `{}`\n  - proof: {}\n",
            nav(&rv::field(h, "at")),
            rv::field(h, "local"),
            rv::field(h, "guard"),
            rv::field(h, "proof")
        ),
        "Superfluous State" => format!(
            "- field `{}` -- classification: `{}` (confidence={}, score={:.3}, writers={}, readers={}, ctorset={})\n  - writes: {}\n  - reads: {}\n  - confidence reason: {}\n",
            rv::field(h, "field"),
            rv::field(h, "classification"),
            rv::field(h, "confidence"),
            rv::get(h, "score").and_then(|v| v.as_f64()).unwrap_or(0.0),
            rv::field_usize(h, "writer_method_count"),
            rv::field_usize(h, "reader_method_count"),
            rv::field_bool(h, "ctorset"),
            rv::array(h, "write_sites").iter().map(|site| nav(&rv::string(Some(site)))).collect::<Vec<_>>().join(" ; "),
            rv::array(h, "read_sites").iter().map(|site| nav(&rv::string(Some(site)))).collect::<Vec<_>>().join(" ; "),
            rv::field(h, "confidence_reason")
        ),
        "Declared Type Pressure" => format!(
            "- {} `{}` slot `{}` -- score={} signals=`{}` union={} unknown={} collection_depth={}\n",
            nav(&rv::field(h, "at")), rv::field(h, "declaration_kind"), rv::field(h, "slot"),
            rv::field(h, "score"), rv::join_field(h, "signals", " | "), rv::field(h, "union_width"),
            rv::field(h, "unknown_leaves"), rv::field(h, "collection_depth")
        ),
        "Missing Abstractions" => format!(
            "- **[{}]** support={} scatter={} rank={}\n  - tuple: `{}`\n  - {}\n",
            rv::field(h, "kind"),
            rv::field(h, "support"),
            rv::field(h, "scatter"),
            rv::field(h, "rank"),
            rv::join_field(h, "members", " | "),
            rv::array(h, "sites").iter().take(6).map(|site| nav(&rv::string(Some(site)))).collect::<Vec<_>>().join(" ; ")
        ),
        "State Heatmap" => render_state_heatmap_item(h),
        "State-Based Branch Density" => format!(
            "- {} -- **{}** state-based branch decision(s), refs=`{}` score={}\n  - example predicate: `{}`\n",
            nav(&rv::field(h, "at")),
            rv::field(h, "decisions"),
            rv::array(h, "state_refs").iter().take(8).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(" | "),
            rv::field(h, "score"),
            rv::field(h, "predicate")
        ),
        "Temporal Ordering Pressure" => format!(
            "- `{}` ({}) -- implicit lifecycle score **{}** (public={}, state methods={}, writers={}, fields={}, shared={}, flows={}, states={})\n  - shared fields: `{}`\n  - surface: {}\n",
            rv::field(h, "owner"),
            nav(&rv::field(h, "at")),
            rv::field(h, "score"),
            rv::field(h, "public_methods"),
            rv::field(h, "state_methods"),
            rv::field(h, "writers"),
            rv::array_len(h, "state_fields"),
            rv::array_len(h, "shared_fields"),
            rv::field(h, "orderings"),
            rv::field(h, "state_space"),
            rv::array(h, "shared_fields").iter().take(8).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(" | "),
            rv::array(h, "sites").iter().take(6).map(|site| nav(&rv::string(Some(site)))).collect::<Vec<_>>().join(" ; ")
        ),
        "Scoped State Restoration" => format!(
            "- {} -- `{}` on `{}` (confidence={}, score={}) temporary=`{}` restore=`{}`\n  - calls inside scope: {}\n",
            nav(&rv::field(h, "at")), rv::field(h, "classification"), rv::field(h, "field"),
            rv::field(h, "confidence"), rv::field(h, "score"), rv::field(h, "temporary_value"),
            rv::join_field(h, "restoration_values", " | "), rv::join_field(h, "calls_inside_scope", " ; ")
        ),
        "Neglected Conditions" | "Neglected Path Conditions" => {
            let pattern = rv::get(h, "pattern").or_else(|| rv::get(h, "guards"));
            format!(
                "- *POSSIBLE* (support={}) {} -- MISSING `{}` from `{}`\n",
                rv::field(h, "support"),
                nav(&rv::field(h, "at")),
                rv::field(h, "missing"),
                rv::array_strings(pattern).join(" | ")
            )
        }
        "Oversized Predicates" => format!(
            "- *POSSIBLE* {} -- {} condition atoms in `{}`\n  - atoms: `{}`\n",
            nav(&rv::field(h, "at")),
            rv::field(h, "count"),
            rv::field(h, "predicate"),
            rv::array(h, "atoms").iter().take(8).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(" | ")
        ),
        "Neglected Updates" => format!(
            "- *POSSIBLE* (support={}) {} writes `.{}` but NOT `.{}` (recv `{}`)\n",
            rv::field(h, "support"),
            nav(&rv::field(h, "at")),
            rv::field(h, "has"),
            rv::field(h, "missing"),
            rv::field(h, "recv")
        ),
        "Semantic Predicate Aliases" | "Exact Predicate Aliases" => format!(
            "- `{}` == `{}`\n  - {}\n",
            rv::join_field(h, "names", " = "),
            if rv::get(h, "canon").is_some() { rv::field(h, "canon") } else { rv::field(h, "body") },
            rv::array(h, "sites").iter().map(|site| nav(&rv::string(Some(site)))).collect::<Vec<_>>().join(" ; ")
        ),
        "Reification Misses" => format!(
            "- predicate `{}` reinvented inline at {} (`{}`)\n",
            rv::field(h, "predicate"),
            nav(&rv::field(h, "at")),
            rv::field(h, "raw")
        ),
        "Broken Protocols" => format!(
            "- *POSSIBLE* conf={} support={} {} does `{}` without `{}`\n",
            rv::field(h, "confidence"),
            rv::field(h, "support"),
            nav(&rv::field(h, "at")),
            rv::field(h, "has"),
            rv::field(h, "missing")
        ),
        "Implicit Control Flow" => render_implicit_control_flow_item(h),
        "Weighted Inlined Cognitive Complexity" => render_weighted_inlined_complexity_item(h),
        "Locality Drag" => render_locality_drag_item(h),
        "Function LCOM" => render_function_lcom_item(h),
        "Operational Discontinuity" | "Operational Discontinuity (High Confidence)" => {
            render_operational_discontinuity_item(h)
        }
        "False Simplicity" => format!(
            "- *POSSIBLE* [{}] scatter={} support={} `{}` -- {}{}\n",
            rv::field(h, "kind"),
            rv::field(h, "scatter"),
            rv::field(h, "support"),
            rv::field(h, "detail"),
            nav(&rv::field(h, "at")),
            if rv::array_len(h, "sites") > 1 {
                format!(" (+{} more)", rv::array_len(h, "sites") - 1)
            } else {
                String::new()
            }
        ),
        "Fat Unions" => format!(
            "- *POSSIBLE*{} union `{}` -- **{} common** vs {} variant member(s), scatter={} -- {}\n  - common: `{}` -> hoist to a struct, keep a SMALL union for `{}` (-> nil-kill)\n",
            if rv::field_bool(h, "degenerate") { " [DEGENERATE: no variance]" } else { "" },
            rv::join_field(h, "variant_set", " | "),
            rv::array_len(h, "common"),
            rv::array_len(h, "variant"),
            rv::field(h, "scatter"),
            nav(&rv::field(h, "at")),
            rv::array(h, "common").iter().take(8).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(", "),
            rv::array(h, "variant").iter().take(6).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(", ")
        ),
        "Derived-State Staleness" => format!(
            "- *POSSIBLE* {}: `{}` derived from `{}` (line {}); `{}` reassigned line {}, `{}` not recomputed\n",
            nav(&rv::field(h, "at")),
            rv::field(h, "derived"),
            rv::field(h, "source"),
            rv::field(h, "derived_at"),
            rv::field(h, "source"),
            rv::field(h, "source_reassigned_at"),
            rv::field(h, "derived")
        ),
        "Inconsistent Rename Clones" => format!(
            "- *POSSIBLE* {} clone of {}: ref var `{}` spelled {} here\n",
            nav(&rv::field(h, "at")),
            nav(&rv::field(h, "ref_at")),
            rv::field(h, "ref_name"),
            rv::ruby_inspect_array(rv::get(h, "divergent"))
        ),
        "Structural Similarity (Type-2/3)" => format!(
            "- *POSSIBLE* [{}] mass={} node=`{}` {}{}\n",
            rv::field(h, "clone_type"),
            rv::field(h, "mass"),
            rv::field(h, "node"),
            rv::array(h, "sites").iter().take(4).map(|site| nav(&rv::string(Some(site)))).collect::<Vec<_>>().join(" ; "),
            if rv::array_len(h, "sites") > 4 {
                format!(" (+{} more)", rv::array_len(h, "sites") - 4)
            } else {
                String::new()
            }
        ),
        _ => String::new(),
    }
}

fn render_state_heatmap_item(item: &Value) -> String {
    let mut out = format!(
        "- `{}` -- messiness **{}** (writes={}, reads={}, re-derived={}, scatter={}, receiver patterns={})\n",
        rv::field(item, "field"),
        rv::field(item, "messiness"),
        rv::field(item, "writes"),
        rv::field(item, "reads"),
        rv::field(item, "re_derivations"),
        rv::field(item, "scatter"),
        rv::field(item, "receiver_types")
    );
    let writers = rv::array(item, "top_writers")
        .iter()
        .map(|site| nav(&rv::string(Some(site))))
        .collect::<Vec<_>>();
    let readers = rv::array(item, "top_readers")
        .iter()
        .map(|site| nav(&rv::string(Some(site))))
        .collect::<Vec<_>>();
    if !writers.is_empty() {
        out.push_str(&format!("  - writers: {}\n", writers.join(" ; ")));
    }
    if !readers.is_empty() {
        out.push_str(&format!("  - readers: {}\n", readers.join(" ; ")));
    }
    out
}

fn render_implicit_control_flow_item(item: &Value) -> String {
    if rv::kind_is(item, "kind", "order_drift") {
        return format!(
            "- *POSSIBLE* [order_drift] conf={} support={} {} observed `{}` against protocol `{}` ({} state=`{}`)\n",
            rv::field(item, "confidence"),
            rv::field(item, "support"),
            nav(&rv::field(item, "at")),
            rv::join_field(item, "observed", " -> "),
            rv::join_field(item, "protocol", " -> "),
            rv::join_field(item, "dependency", "|"),
            rv::join_field(item, "states", " | ")
        );
    }
    let sites = rv::array(item, "sites")
        .iter()
        .take(4)
        .map(|site| nav(&rv::string(Some(site))))
        .collect::<Vec<_>>()
        .join(" ; ");
    let more = if rv::array_len(item, "sites") > 4 {
        format!(" (+{} more)", rv::array_len(item, "sites") - 4)
    } else {
        String::new()
    };
    format!(
        "- *POSSIBLE* [protocol_pressure] support={} `{}` ({} state=`{}`) -- {}\n  - sites: {}{}\n",
        rv::field(item, "support"),
        rv::join_field(item, "protocol", " -> "),
        rv::join_field(item, "dependency", "|"),
        rv::join_field(item, "states", " | "),
        nav(&rv::field(item, "at")),
        sites,
        more
    )
}

fn render_weighted_inlined_complexity_item(item: &Value) -> String {
    format!(
        "- *POSSIBLE* {} -- inlined={} (local={}, hidden={}, depth={})\n  - chain: `{}`\n  - single-caller helpers: `{}`\n  - reason: {}\n",
        nav(&rv::field(item, "at")),
        rv::field(item, "inlined"),
        rv::field(item, "local"),
        rv::field(item, "hidden"),
        rv::field(item, "depth"),
        rv::join_field(item, "call_chain", " -> "),
        rv::array(item, "single_caller_callees").iter().take(8).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(" | "),
        rv::field(item, "reason")
    )
}

fn render_locality_drag_item(item: &Value) -> String {
    let mut out = format!(
        "- *POSSIBLE* {} -- `{}` dormant until line {} score={} (gap={} lines, unrelated={}, boundaries={}, local={})\n  - reason: {}\n",
        nav(&rv::field(item, "at")),
        rv::field(item, "variable"),
        rv::field(item, "used_at"),
        rv::field(item, "score"),
        rv::field(item, "gap_lines"),
        rv::field(item, "unrelated_statements"),
        rv::field(item, "boundary_crossings"),
        rv::field(item, "local_complexity"),
        rv::field(item, "reason")
    );
    if rv::positive(item, "setup_statements") {
        out.push_str(&format!(
            "  - ignored setup initializers: {}\n",
            rv::field(item, "setup_statements")
        ));
    }
    if rv::array_len(item, "definition_deps") > 0 {
        out.push_str(&format!(
            "  - definition deps: `{}`\n",
            rv::array(item, "definition_deps")
                .iter()
                .take(6)
                .map(|v| rv::string(Some(v)))
                .collect::<Vec<_>>()
                .join(" | ")
        ));
    }
    if rv::array_len(item, "use_reads") > 0 {
        out.push_str(&format!(
            "  - first-use reads: `{}`\n",
            rv::array(item, "use_reads")
                .iter()
                .take(8)
                .map(|v| rv::string(Some(v)))
                .collect::<Vec<_>>()
                .join(" | ")
        ));
    }
    for boundary in rv::array(item, "boundaries").iter().take(2) {
        out.push_str(&format!(
            "  - crosses line {} {}\n",
            rv::field(boundary, "line"),
            rv::field(boundary, "marker")
        ));
    }
    for example in rv::array(item, "examples").iter().take(2) {
        out.push_str(&format!(
            "  - unrelated line {}: `{}`\n",
            rv::field(example, "line"),
            rv::field(example, "source")
        ));
    }
    out
}

fn render_function_lcom_item(item: &Value) -> String {
    let mode = if rv::kind_is(item, "mode", "late_join") {
        "late_join"
    } else {
        "disjoint"
    };
    let mut out = format!(
        "- *POSSIBLE* [{}] {} -- score={} components={}, locals={}, statements={}\n",
        mode,
        nav(&rv::field(item, "at")),
        rv::field(item, "score"),
        rv::field(item, "components"),
        rv::field(item, "locals"),
        rv::field(item, "statements")
    );
    for (index, vars) in rv::array(item, "component_vars").iter().take(4).enumerate() {
        let lines = rv::array(item, "component_lines").get(index);
        let var_text = rv::array_from(Some(vars))
            .iter()
            .take(8)
            .map(|value| rv::string(Some(value)))
            .collect::<Vec<_>>()
            .join(" | ");
        out.push_str(&format!("  - component {}: `{}`", index + 1, var_text));
        if let Some(lines) = lines {
            let line_values = rv::array_from(Some(lines));
            if let (Some(first), Some(last)) = (line_values.first(), line_values.last()) {
                out.push_str(&format!(
                    " (lines {}-{})",
                    rv::string(Some(first)),
                    rv::string(Some(last))
                ));
            }
        }
        out.push('\n');
    }
    out
}

fn render_operational_discontinuity_item(item: &Value) -> String {
    let reasons = rv::join_field(item, "confidence_reasons", ", ");
    let confidence = if rv::get(item, "confidence").is_some() {
        rv::field(item, "confidence")
    } else {
        "review".to_string()
    };
    let mut out = format!(
        "- *POSSIBLE* {} -- score={} reset_boundaries={}, dead={}, new={}, confidence={}",
        nav(&rv::field(item, "at")),
        rv::field(item, "score"),
        rv::field(item, "resets"),
        rv::field(item, "dead_total"),
        rv::field(item, "new_total"),
        confidence
    );
    if !reasons.is_empty() {
        out.push_str(&format!(" ({reasons})"));
    }
    out.push('\n');
    for reset in rv::array(item, "reset_points").iter().take(3) {
        let marker = if rv::field(reset, "text").is_empty() {
            rv::field(reset, "kind")
        } else {
            rv::field(reset, "text")
        };
        out.push_str(&format!(
            "  - line {} {}: dead `{}` -> new `{}`",
            rv::field(reset, "line"),
            marker,
            rv::array(reset, "dead")
                .iter()
                .take(6)
                .map(|v| rv::string(Some(v)))
                .collect::<Vec<_>>()
                .join(" | "),
            rv::array(reset, "new")
                .iter()
                .take(6)
                .map(|v| rv::string(Some(v)))
                .collect::<Vec<_>>()
                .join(" | ")
        ));
        if rv::array_len(reset, "continuing") > 0 {
            out.push_str(&format!(
                " (continuing `{}`)",
                rv::join_field(reset, "continuing", " | ")
            ));
        }
        out.push('\n');
    }
    out
}

fn sarif_rule_id(title: &str) -> String {
    format!("decomplex.{}", sarif::slug(title))
}

fn ranked_sarif_results(mut results: Vec<Value>) -> Vec<Value> {
    results.sort_by(|left, right| {
        let left_location = first_physical_location(left);
        let right_location = first_physical_location(right);
        tier_property(left)
            .cmp(&tier_property(right))
            .then_with(|| rv::field(left, "ruleId").cmp(&rv::field(right, "ruleId")))
            .then_with(|| {
                rv::get(left, "message")
                    .and_then(|message| rv::get(message, "text"))
                    .map(|value| rv::string(Some(value)))
                    .unwrap_or_default()
                    .cmp(
                        &rv::get(right, "message")
                            .and_then(|message| rv::get(message, "text"))
                            .map(|value| rv::string(Some(value)))
                            .unwrap_or_default(),
                    )
            })
            .then_with(|| {
                left_location
                    .as_ref()
                    .and_then(|location| location.get("artifactLocation"))
                    .and_then(|artifact| artifact.get("uri"))
                    .map(|value| rv::string(Some(value)))
                    .unwrap_or_default()
                    .cmp(
                        &right_location
                            .as_ref()
                            .and_then(|location| location.get("artifactLocation"))
                            .and_then(|artifact| artifact.get("uri"))
                            .map(|value| rv::string(Some(value)))
                            .unwrap_or_default(),
                    )
            })
            .then_with(|| start_line(left_location).cmp(&start_line(right_location)))
    });
    results
}

fn tier_property(result: &Value) -> i64 {
    rv::get(result, "properties")
        .map(|properties| rv::field_i64(properties, "tier"))
        .unwrap_or(0)
}

fn first_physical_location(result: &Value) -> Option<&Value> {
    rv::array(result, "locations")
        .first()
        .and_then(|location| rv::get(location, "physicalLocation"))
}

fn start_line(location: Option<&Value>) -> i64 {
    location
        .and_then(|location| rv::get(location, "region"))
        .map(|region| rv::field_i64(region, "startLine"))
        .unwrap_or(0)
}

fn sarif_message(title: &str, finding: &Value, location: &SarifLocation) -> String {
    let detail = sarif_message_detail(title, finding);
    if !detail.is_empty() {
        return format!("{title}: {detail}");
    }
    let subject = location
        .method
        .clone()
        .filter(|value| !value.is_empty())
        .or_else(|| {
            first_non_empty_field(
                finding,
                &[
                    "method", "name", "field", "contract", "owner", "token", "kind",
                ],
            )
        });
    [Some(title.to_string()), subject]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(": ")
}

fn first_non_empty_field(finding: &Value, keys: &[&str]) -> Option<String> {
    keys.iter()
        .map(|key| rv::field(finding, key))
        .find(|value| !value.is_empty())
}

fn sarif_message_detail(title: &str, finding: &Value) -> String {
    match title {
        "Decision Pressure" => format!(
            "`{}` creates {} eliminable guard decision(s) across {} method(s)",
            rv::field(finding, "contract"),
            rv::field(finding, "decisions"),
            rv::field(finding, "methods")
        ),
        "Redundant Nil Guards" => format!(
            "`{}` is nil-guarded by `{}` after proof `{}`",
            rv::field(finding, "local"),
            rv::field(finding, "guard"),
            rv::field(finding, "proof")
        ),
        "Declared Type Pressure" => format!(
            "`{}` has converging declaration pressure: {}",
            rv::field(finding, "slot"), rv::join_field(finding, "signals", " | ")
        ),
        "Scoped State Restoration" => format!(
            "state `{}` has {} (confidence={})",
            rv::field(finding, "field"), rv::field(finding, "classification"), rv::field(finding, "confidence")
        ),
        "Superfluous State" => {
            let reason = rv::field(finding, "confidence_reason");
            format!(
                "state `{}` has {} (confidence={}{})",
                rv::field(finding, "field"),
                rv::field(finding, "classification"),
                rv::field(finding, "confidence"),
                if reason.is_empty() { String::new() } else { format!(": {reason}") }
            )
        }
        "State Heatmap" => format!(
            "state `{}` has pressure={}, messiness={} (writes={}, reads={}, re-derived={}, scatter={}); writers {}; readers {}",
            rv::field(finding, "field"),
            rv::field(finding, "pressure"),
            rv::field(finding, "messiness"),
            rv::field(finding, "writes"),
            rv::field(finding, "reads"),
            rv::field(finding, "re_derivations"),
            rv::field(finding, "scatter"),
            rv::array(finding, "top_writers").iter().take(3).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(" | "),
            rv::array(finding, "top_readers").iter().take(3).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(" | ")
        ),
        "Missing Abstractions" => format!(
            "guard tuple `{}` repeats in {} site(s) with scatter={}",
            rv::join_field(finding, "members", " | "),
            rv::field(finding, "support"),
            rv::field(finding, "scatter")
        ),
        "State-Based Branch Density" => format!(
            "{} state-based branch decision(s) over `{}`; example predicate `{}`",
            rv::field(finding, "decisions"),
            rv::array(finding, "state_refs").iter().take(8).map(|v| rv::string(Some(v))).collect::<Vec<_>>().join(" | "),
            rv::field(finding, "predicate")
        ),
        "Temporal Ordering Pressure" => format!(
            "`{}` exposes mutable lifecycle pressure score={} (public={}, state_methods={}, writers={})",
            rv::field(finding, "owner"),
            rv::field(finding, "score"),
            rv::field(finding, "public_methods"),
            rv::field(finding, "state_methods"),
            rv::field(finding, "writers")
        ),
        "Neglected Conditions" | "Neglected Path Conditions" => {
            let pattern = rv::get(finding, "pattern").or_else(|| rv::get(finding, "guards"));
            format!(
                "missing condition `{}` from `{}` (support={})",
                rv::field(finding, "missing"),
                rv::array_strings(pattern).join(" | "),
                rv::field(finding, "support")
            )
        }
        "Oversized Predicates" => format!(
            "{} condition atoms in predicate `{}`",
            rv::field(finding, "count"),
            rv::field(finding, "predicate")
        ),
        "Neglected Updates" => format!(
            "writes `.{}` but not co-written `.{}` on receiver `{}` (support={})",
            rv::field(finding, "has"),
            rv::field(finding, "missing"),
            rv::field(finding, "recv"),
            rv::field(finding, "support")
        ),
        "Semantic Predicate Aliases" | "Exact Predicate Aliases" => format!(
            "predicate aliases `{}` for `{}`",
            rv::join_field(finding, "names", " = "),
            if rv::get(finding, "canon").is_some() {
                rv::field(finding, "canon")
            } else {
                rv::field(finding, "body")
            }
        ),
        "Reification Misses" => format!(
            "predicate `{}` is reinvented inline as `{}`",
            rv::field(finding, "predicate"),
            rv::field(finding, "raw")
        ),
        "Broken Protocols" => format!(
            "does `{}` without co-called `{}` (support={}, confidence={})",
            rv::field(finding, "has"),
            rv::field(finding, "missing"),
            rv::field(finding, "support"),
            rv::field(finding, "confidence")
        ),
        "Implicit Control Flow" => sarif_implicit_control_flow_detail(finding),
        "Weighted Inlined Cognitive Complexity" => format!(
            "inlined={} (local={}, hidden={}, depth={}); chain `{}`",
            rv::field(finding, "inlined"),
            rv::field(finding, "local"),
            rv::field(finding, "hidden"),
            rv::field(finding, "depth"),
            rv::join_field(finding, "call_chain", " -> ")
        ),
        "Locality Drag" => format!(
            "`{}` is initialized at line {} but first used at line {} after {} unrelated statement(s)",
            rv::field(finding, "variable"),
            rv::field(finding, "defined_at"),
            rv::field(finding, "used_at"),
            rv::field(finding, "unrelated_statements")
        ),
        "Function LCOM" => {
            let mode = if rv::kind_is(finding, "mode", "late_join") {
                "late_join"
            } else {
                "disjoint"
            };
            format!(
                "{} local data-flow: score={}, components={}, locals={}, statements={}",
                mode,
                rv::field(finding, "score"),
                rv::field(finding, "components"),
                rv::field(finding, "locals"),
                rv::field(finding, "statements")
            )
        }
        "Operational Discontinuity" | "Operational Discontinuity (High Confidence)" => format!(
            "score={}, reset_boundaries={}, dead={}, new={}, confidence={}",
            rv::field(finding, "score"),
            rv::field(finding, "resets"),
            rv::field(finding, "dead_total"),
            rv::field(finding, "new_total"),
            if rv::get(finding, "confidence").is_some() {
                rv::field(finding, "confidence")
            } else {
                "review".to_string()
            }
        ),
        "False Simplicity" => format!(
            "[{}] `{}` support={}, scatter={}",
            rv::field(finding, "kind"),
            rv::field(finding, "detail"),
            rv::field(finding, "support"),
            rv::field(finding, "scatter")
        ),
        "Fat Unions" => format!(
            "union `{}` has {} common and {} variant member(s), scatter={}",
            rv::join_field(finding, "variant_set", " | "),
            rv::array_len(finding, "common"),
            rv::array_len(finding, "variant"),
            rv::field(finding, "scatter")
        ),
        "Derived-State Staleness" => format!(
            "`{}` derived from `{}` at line {}; `{}` reassigned at line {} but `{}` is not recomputed",
            rv::field(finding, "derived"),
            rv::field(finding, "source"),
            rv::field(finding, "derived_at"),
            rv::field(finding, "source"),
            rv::field(finding, "source_reassigned_at"),
            rv::field(finding, "derived")
        ),
        "Inconsistent Rename Clones" => format!(
            "clone of {}: reference variable `{}` diverges as {}",
            rv::field(finding, "ref_at"),
            rv::field(finding, "ref_name"),
            rv::ruby_inspect_array(rv::get(finding, "divergent"))
        ),
        "Structural Similarity (Type-2/3)" => format!(
            "[{}] mass={} node=`{}` across {} site(s)",
            rv::field(finding, "clone_type"),
            rv::field(finding, "mass"),
            rv::field(finding, "node"),
            rv::array_len(finding, "sites")
        ),
        _ => String::new(),
    }
}

fn sarif_implicit_control_flow_detail(finding: &Value) -> String {
    let protocol = rv::join_field(finding, "protocol", " -> ");
    let dependency = rv::join_field(finding, "dependency", "|");
    let states = rv::join_field(finding, "states", " | ");
    if rv::kind_is(finding, "kind", "order_drift") {
        return format!(
            "[order_drift] observed `{}` against protocol `{}` ({} state=`{}`)",
            rv::join_field(finding, "observed", " -> "),
            protocol,
            dependency,
            states
        );
    }
    format!(
        "[protocol_pressure] protocol `{}` ({} state=`{}`), support={}",
        protocol,
        dependency,
        states,
        rv::field(finding, "support")
    )
}

fn sarif_locations_for_finding(finding: &Value) -> Vec<SarifLocation> {
    if let Some(spans) = rv::get(finding, "spans").and_then(Value::as_object) {
        if !spans.is_empty() {
            return spans
                .iter()
                .filter_map(|(loc, span)| {
                    let mut parsed = parse_sarif_loc(loc);
                    parsed.path.as_ref()?;
                    let span = rv::array_from(Some(span));
                    parsed.line = span
                        .first()
                        .and_then(Value::as_i64)
                        .filter(|line| *line > 0)
                        .unwrap_or(parsed.line);
                    parsed.start_column = span
                        .get(1)
                        .and_then(Value::as_i64)
                        .map(zero_based_column_to_sarif);
                    parsed.source_start_column = span.get(1).and_then(Value::as_i64);
                    parsed.end_line = span.get(2).and_then(Value::as_i64).filter(|line| *line > 0);
                    parsed.end_column = span
                        .get(3)
                        .and_then(Value::as_i64)
                        .map(zero_based_column_to_sarif);
                    parsed.source_end_column = span.get(3).and_then(Value::as_i64);
                    Some(parsed)
                })
                .collect();
        }
    }

    let mut locs = Vec::new();
    if let Some(value) = rv::get(finding, "at") {
        locs.push(rv::string(Some(value)));
    }
    locs.extend(rv::field_array_strings(finding, "sites"));
    if let Some(value) = rv::get(finding, "ref_at") {
        locs.push(rv::string(Some(value)));
    }
    let mut seen = std::collections::HashSet::new();
    locs.retain(|loc| !loc.is_empty() && seen.insert(loc.clone()));
    locs.into_iter()
        .map(|loc| parse_sarif_loc(&loc))
        .filter(|loc| loc.path.is_some())
        .collect()
}

fn parse_sarif_loc(loc: &str) -> SarifLocation {
    let mut parts = loc.split(':').map(ToOwned::to_owned).collect::<Vec<_>>();
    let line = if parts
        .last()
        .is_some_and(|part| part.chars().all(|ch| ch.is_ascii_digit()))
    {
        parts.pop().and_then(|part| part.parse::<i64>().ok())
    } else {
        None
    };
    let method = if parts.len() >= 2 { parts.pop() } else { None };
    let path = parts.join(":");
    SarifLocation {
        path: (!path.is_empty()).then_some(path),
        method,
        line: line.filter(|line| *line > 0).unwrap_or(1),
        start_column: None,
        end_line: None,
        end_column: None,
        source_start_column: None,
        source_end_column: None,
    }
}

fn zero_based_column_to_sarif(value: i64) -> i64 {
    value + 1
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn nav_splits_location_from_the_right() {
        assert_eq!(nav("a:b.rb:m:10"), "`a:b.rb:10` (m)");
    }

    #[test]
    fn slug_matches_ruby_report_anchor_shape() {
        assert_eq!(
            slug("Structural Similarity (Type-2/3)"),
            "structural-similarity-type23"
        );
    }

    #[test]
    fn test_report_comprehensive() {
        let facts = json!({
            "format": crate::decomplex::report_facts::FORMAT,
            "files": ["file.rb"],
            "detectors": {
                "decision_pressure": [{
                    "contract": "ContractA",
                    "decisions": 5,
                    "methods": 2,
                    "essential": 1,
                    "sites": ["file.rb:m:10"],
                    "spans": {
                        "file.rb:m:10": [10, 5, 12, 15]
                    }
                }],
                "redundant_nil_guard": [{
                    "at": "file.rb:m:10",
                    "local": "x",
                    "guard": "x.nil?",
                    "proof": "x != nil"
                }],
                "state_heatmap": [{
                    "field": "@state",
                    "pressure": 10,
                    "messiness": 8,
                    "writes": 4,
                    "reads": 6,
                    "re_derivations": 1,
                    "scatter": 2,
                    "receiver_types": 3,
                    "top_writers": ["file.rb:m1:20"],
                    "top_readers": ["file.rb:m2:30"]
                }],
                "state_branch_density": [{
                    "at": "file.rb:m:10",
                    "decisions": 3,
                    "state_refs": ["a", "b"],
                    "score": 1.5,
                    "predicate": "a && b"
                }],
                "temporal_ordering_pressure": [{
                    "owner": "ClassA",
                    "at": "file.rb:m:10",
                    "score": 4.0,
                    "public_methods": 5,
                    "state_methods": 3,
                    "writers": 2,
                    "state_fields": ["x", "y"],
                    "shared_fields": ["z"],
                    "orderings": 2,
                    "state_space": 4,
                    "sites": ["file.rb:m:10"]
                }],
                "miner": {
                    "missing_abstractions": [{
                        "kind": "tuple",
                        "support": 3,
                        "scatter": 2,
                        "rank": 4,
                        "members": ["a", "b"],
                        "sites": ["file.rb:m:10"]
                    }],
                    "neglected_conditions": [{
                        "support": 2,
                        "at": "file.rb:m:10",
                        "missing": "cond",
                        "pattern": ["a", "b"]
                    }]
                },
                "semantic_alias": {
                    "reification_misses": [{
                        "predicate": "pred",
                        "at": "file.rb:m:10",
                        "raw": "x == 1"
                    }],
                    "alias_clusters": [{
                        "names": ["a", "b"],
                        "canon": "body",
                        "sites": ["file.rb:m:10"]
                    }]
                },
                "predicate_alias": {
                    "alias_clusters": [{
                        "names": ["a", "b"],
                        "body": "x == 2",
                        "sites": ["file.rb:m:10"]
                    }]
                },
                "inconsistent_rename_clone": [{
                    "at": "file.rb:m:10",
                    "ref_at": "ref.rb:m:5",
                    "ref_name": "x",
                    "divergent": ["y"]
                }],
                "flay_similarity": [{
                    "clone_type": "type-2",
                    "mass": 20,
                    "node": "node_a",
                    "sites": ["file.rb:m:10", "file2.rb:m:20", "file3.rb:m:30", "file4.rb:m:40", "file5.rb:m:50"]
                }],
                "co_update": {
                    "neglected_updates": [{
                        "support": 2,
                        "at": "file.rb:m:10",
                        "has": "a",
                        "missing": "b",
                        "recv": "recv"
                    }]
                },
                "derived_state": [{
                    "at": "file.rb:m:10",
                    "derived": "y",
                    "source": "x",
                    "derived_at": 5,
                    "source_reassigned_at": 15
                }],
                "path_condition": {
                    "neglected": [{
                        "support": 2,
                        "at": "file.rb:m:10",
                        "missing": "cond",
                        "guards": ["a", "b"]
                    }]
                },
                "oversized_predicate": [{
                    "at": "file.rb:m:10",
                    "count": 5,
                    "predicate": "a && b && c && d"
                }],
                "sequence_mine": {
                    "broken": [{
                        "confidence": 0.8,
                        "support": 3,
                        "at": "file.rb:m:10",
                        "has": "a",
                        "missing": "b"
                    }]
                },
                "implicit_control_flow": {
                    "ordered_protocols": [
                        {
                            "kind": "order_drift",
                            "confidence": 0.9,
                            "support": 2,
                            "at": "file.rb:m:10",
                            "observed": ["a", "b"],
                            "protocol": ["a", "b", "c"],
                            "dependency": ["dep"],
                            "states": ["st"]
                        },
                        {
                            "kind": "protocol_pressure",
                            "support": 2,
                            "at": "file.rb:m:10",
                            "protocol": ["a", "b"],
                            "dependency": ["dep"],
                            "states": ["st"],
                            "sites": ["file.rb:m:10", "file2.rb:m:20", "file3.rb:m:30", "file4.rb:m:40", "file5.rb:m:50"]
                        }
                    ]
                },
                "weighted_inlined_complexity": [{
                    "at": "file.rb:m:10",
                    "inlined": 15,
                    "local": 5,
                    "hidden": 10,
                    "depth": 3,
                    "call_chain": ["a", "b"],
                    "single_caller_callees": ["c"],
                    "reason": "heavy chain"
                }],
                "locality_drag": [{
                    "at": "file.rb:m:10",
                    "variable": "v",
                    "used_at": 20,
                    "defined_at": 5,
                    "score": 3.5,
                    "gap_lines": 15,
                    "unrelated_statements": 5,
                    "boundary_crossings": 2,
                    "local_complexity": 3,
                    "reason": "long gap",
                    "setup_statements": 1,
                    "definition_deps": ["d"],
                    "use_reads": ["r"],
                    "boundaries": [{"line": 12, "marker": "cross"}],
                    "examples": [{"line": 15, "source": "x = 1"}]
                }],
                "operational_discontinuity": [
                    {
                        "at": "file.rb:m:10",
                        "score": 4.0,
                        "resets": 2,
                        "dead_total": 3,
                        "new_total": 4,
                        "confidence": "high",
                        "confidence_reasons": ["blank lines"],
                        "reset_points": [{
                            "line": 15,
                            "text": "reset",
                            "dead": ["x"],
                            "new": ["y"],
                            "continuing": ["z"]
                        }]
                    },
                    {
                        "at": "file.rb:m:10",
                        "score": 2.0,
                        "resets": 1,
                        "dead_total": 1,
                        "new_total": 1,
                        "confidence": "low",
                        "reset_points": [{
                            "line": 15,
                            "kind": "comment",
                            "dead": ["x"],
                            "new": ["y"]
                        }]
                    }
                ],
                "function_lcom": [
                    {
                        "mode": "late_join",
                        "at": "file.rb:m:10",
                        "score": 0.8,
                        "components": 2,
                        "locals": 3,
                        "statements": 5,
                        "component_vars": [["x", "y"]],
                        "component_lines": [[10, 15]]
                    },
                    {
                        "mode": "disjoint",
                        "at": "file.rb:m:10",
                        "score": 0.9,
                        "components": 2,
                        "locals": 2,
                        "statements": 4,
                        "component_vars": [["a"]],
                        "component_lines": [[10]]
                    }
                ],
                "false_simplicity": [{
                    "kind": "dispatch",
                    "scatter": 2,
                    "support": 3,
                    "detail": "delegates to x",
                    "at": "file.rb:m:10",
                    "sites": ["file.rb:m:10", "file2.rb:m:20"]
                }],
                "fat_union": {
                    "fat_unions": [{
                        "degenerate": true,
                        "variant_set": ["A", "B"],
                        "common": ["c"],
                        "variant": ["v"],
                        "scatter": 2,
                        "at": "file.rb:m:10"
                    }]
                }
            }
        });

        let report = Report::from_facts(&facts).unwrap();

        let md = report.to_markdown();
        assert!(!md.is_empty());

        let sarif = report.to_sarif();
        assert!(!sarif.is_empty());

        let conv = report.convergence_value();
        assert!(!conv.is_null());

        let root_clusters = report.root_clusters_value();
        assert!(!root_clusters.is_null());

        let sarif_val = report.to_sarif_value(true, true, None);
        assert!(!sarif_val.is_null());
        let run = sarif_val.pointer("/runs/0").unwrap();
        assert!(run
            .pointer("/properties/fact_mine.proof_boundary_summary")
            .is_some());
        let nil_guard = run
            .get("results")
            .and_then(Value::as_array)
            .unwrap()
            .iter()
            .find(|result| {
                result.get("ruleId").and_then(Value::as_str)
                    == Some("decomplex.redundant-nil-guards")
            })
            .unwrap();
        assert_eq!(
            nil_guard.pointer("/properties/fact_mine.proof_boundary/claim_status"),
            Some(&json!("review"))
        );

        let mut legacy_input_facts = facts.clone();
        legacy_input_facts["input_coverage"] = json!({
            "complete": false,
            "reason": "tree-sitter recovered from a syntax error"
        });
        let legacy_input_report = Report::from_facts(&legacy_input_facts).unwrap();
        let legacy_input_sarif = legacy_input_report.to_sarif_value(false, false, None);
        let legacy_count = legacy_input_sarif
            .pointer("/runs/0/results")
            .and_then(Value::as_array)
            .unwrap()
            .len();
        assert_eq!(
            legacy_input_sarif.pointer(
                "/runs/0/properties/fact_mine.proof_boundary_summary/input_completeness/unknown"
            ),
            Some(&json!(legacy_count))
        );

        // Error checking path: missing detectors
        let invalid_facts = json!({
            "format": "invalid",
            "files": []
        });
        assert!(Report::from_facts(&invalid_facts).is_err());
    }

    #[test]
    fn semantic_boundaries_follow_finding_dependencies() {
        let facts = json!({
            "semantic_evidence": {
                "by_file": {
                    "clean.rb": {
                        "normalized_ast_complete": true,
                        "unresolved_call_function_spans": [[10, 0, 20, 0]]
                    },
                    "recovered.rb": {
                        "normalized_ast_complete": false,
                        "unresolved_call_function_spans": []
                    }
                }
            }
        });
        let clean = json!({ "at": "clean.rb:work:5" });
        assert_eq!(
            finding_input_boundary(EvidenceRequirement::REPORTED_SPANS, &clean, &facts).0,
            sarif::InputCompleteness::Complete
        );
        let call_dependent = json!({ "at": "clean.rb:work:12" });
        let (completeness, blockers) = finding_input_boundary(
            EvidenceRequirement::REPORTED_SPANS.with_call_resolution(),
            &call_dependent,
            &facts,
        );
        assert_eq!(completeness, sarif::InputCompleteness::Partial);
        assert_eq!(
            blockers,
            vec![sarif::ProofBlocker::call_resolution(
                "clean.rb",
                Some([10, 0, 20, 0])
            )]
        );
        let recovered = json!({ "at": "recovered.rb:work:3" });
        assert_eq!(
            finding_input_boundary(EvidenceRequirement::REPORTED_SPANS, &recovered, &facts).0,
            sarif::InputCompleteness::Unknown
        );
        let missing = json!({ "at": "missing.rb:work:3" });
        assert_eq!(
            finding_input_boundary(EvidenceRequirement::REPORTED_SPANS, &missing, &facts).0,
            sarif::InputCompleteness::Unknown
        );
    }

    #[test]
    fn parser_recovery_only_downgrades_overlapping_finding_regions() {
        let file = json!({
            "parse_recovery_spans": [[10, 4, 10, 12]]
        });
        let unaffected = SarifLocation {
            path: Some("recovered.rb".to_string()),
            method: None,
            line: 10,
            start_column: Some(20),
            end_line: Some(10),
            end_column: Some(25),
            source_start_column: Some(19),
            source_end_column: Some(24),
        };
        let overlapping = SarifLocation {
            path: Some("recovered.rb".to_string()),
            method: None,
            line: 10,
            start_column: Some(8),
            end_line: Some(10),
            end_column: Some(14),
            source_start_column: Some(7),
            source_end_column: Some(13),
        };

        assert!(!recovery_affects_span(&file, unaffected.source_span()));
        assert!(recovery_affects_span(&file, overlapping.source_span()));
    }

    #[test]
    fn parser_recovery_uses_raw_columns_for_zero_width_missing_nodes() {
        let file = json!({
            "parse_recovery_spans": [[10, 0, 10, 0]]
        });
        let location = SarifLocation {
            path: Some("recovered.rb".to_string()),
            method: None,
            line: 10,
            // SARIF's one-based rendering is deliberately different from
            // the parser coordinate retained below.
            start_column: Some(1),
            end_line: Some(10),
            end_column: Some(1),
            source_start_column: Some(0),
            source_end_column: Some(0),
        };
        assert!(recovery_affects_span(&file, location.source_span()));
    }

    #[test]
    fn recovery_dependencies_follow_detector_scope() {
        let facts = json!({
            "corpus": { "complete": true },
            "semantic_evidence": {
                "by_file": {
                    "recovered.rb": {
                        "normalized_ast_complete": false,
                        "parse_recovery_spans": [[20, 0, 20, 0]],
                        "function_spans": [[1, 0, 30, 0]],
                        "owner_spans": [[1, 0, 40, 0]],
                        "unresolved_call_function_spans": []
                    }
                }
            }
        });
        let finding = json!({ "at": "recovered.rb:work:5" });
        assert_eq!(
            finding_input_boundary(EvidenceRequirement::REPORTED_SPANS, &finding, &facts).0,
            sarif::InputCompleteness::Complete
        );
        for scope in [
            EvidenceScope::EnclosingFunction,
            EvidenceScope::Owner,
            EvidenceScope::ClosedCorpus,
        ] {
            let requirement = EvidenceRequirement {
                scope,
                call_resolution: false,
            };
            assert_eq!(
                finding_input_boundary(requirement, &finding, &facts).0,
                sarif::InputCompleteness::Unknown,
                "scope={scope:?}"
            );
        }
        let (completeness, blockers) = finding_input_boundary(
            EvidenceRequirement {
                scope: EvidenceScope::EnclosingFunction,
                call_resolution: false,
            },
            &finding,
            &facts,
        );
        assert_eq!(completeness, sarif::InputCompleteness::Unknown);
        assert_eq!(
            blockers,
            vec![sarif::ProofBlocker::parser_recovery(
                "recovered.rb",
                Some([20, 0, 20, 0])
            )]
        );
    }

    #[test]
    fn detector_policy_is_independent_of_display_title() {
        let section = ReportSection::new(
            "Renamed nil-check heading",
            1,
            "display text is not detector semantics",
            Vec::new(),
        )
        .with_policy(DetectorPolicy::REDUNDANT_NIL_GUARD);

        let boundary = finding_proof_boundary(&section, &json!({}));
        assert_eq!(
            boundary.get("claim_kind"),
            Some(&json!("redundant_nil_guard"))
        );
        assert_eq!(
            boundary.pointer("/scope/kind"),
            Some(&json!("reported_span"))
        );
        assert_eq!(boundary.get("claim_status"), Some(&json!("review")));
        assert_eq!(
            boundary.get("authority"),
            Some(&json!(["fact_mine_normalized_ast", "fact_mine_cfg"]))
        );
    }

    #[test]
    fn test_report_empty_and_sorting_edges() {
        let empty_facts = json!({
            "format": crate::decomplex::report_facts::FORMAT,
            "files": ["file.rb"],
            "detectors": {
                "decision_pressure": [],
                "redundant_nil_guard": [],
                "state_heatmap": [],
                "state_branch_density": [],
                "temporal_ordering_pressure": [],
                "miner": {
                    "missing_abstractions": [],
                    "neglected_conditions": []
                },
                "semantic_alias": {
                    "reification_misses": [],
                    "alias_clusters": []
                },
                "predicate_alias": {
                    "alias_clusters": []
                },
                "inconsistent_rename_clone": [],
                "flay_similarity": [],
                "co_update": {
                    "neglected_updates": []
                },
                "derived_state": [],
                "path_condition": {
                    "neglected": []
                },
                "oversized_predicate": [],
                "sequence_mine": {
                    "broken": []
                },
                "implicit_control_flow": {
                    "ordered_protocols": []
                },
                "weighted_inlined_complexity": [],
                "locality_drag": [],
                "operational_discontinuity": [],
                "function_lcom": [],
                "false_simplicity": [],
                "fat_union": {
                    "fat_unions": []
                }
            }
        });
        let report = Report::from_facts(&empty_facts).unwrap();
        let md = report.to_markdown();
        assert!(md.contains("Nothing flagged."));
        assert!(md.contains("None (no unit flagged by >=2 detectors)."));
        assert!(md.contains("None (no entity named by >=2 detectors)."));

        let mut decision_pressures = Vec::new();
        for i in 0..30 {
            decision_pressures.push(json!({
                "contract": format!("Contract{}", i),
                "decisions": 5,
                "methods": 2,
                "essential": 0,
                "sites": [format!("file.rb:m{}:10", i)]
            }));
        }
        // Add two findings with same contract (message text) but different files (uris)
        decision_pressures.push(json!({
            "contract": "ContractA",
            "decisions": 5,
            "methods": 2,
            "essential": 1,
            "sites": ["file1.rb:m0:10"]
        }));
        decision_pressures.push(json!({
            "contract": "ContractA",
            "decisions": 5,
            "methods": 2,
            "essential": 1,
            "sites": ["file2.rb:m0:10"]
        }));
        // Add two findings with same contract (message text) and same file (uri) but different lines (startLine)
        decision_pressures.push(json!({
            "contract": "ContractB",
            "decisions": 5,
            "methods": 2,
            "essential": 1,
            "sites": ["file1.rb:m0:10"]
        }));
        decision_pressures.push(json!({
            "contract": "ContractB",
            "decisions": 5,
            "methods": 2,
            "essential": 1,
            "sites": ["file1.rb:m0:20"]
        }));
        // Add case dispatch to trigger fat_union = true
        decision_pressures.push(json!({
            "kind": "case_dispatch",
            "members": ["Foo", "Bar"],
            "sites": ["file.rb:fat:10"]
        }));

        let mut state_branch_densities = Vec::new();
        for i in 0..30 {
            state_branch_densities.push(json!({
                "at": format!("file.rb:m{}:10", i),
                "decisions": 3,
                "state_refs": ["a"],
                "score": 1.5,
                "predicate": "a"
            }));
        }

        let mut missing_abstractions = Vec::new();
        for i in 0..25 {
            missing_abstractions.push(json!({
                "kind": "tuple",
                "support": 3,
                "scatter": 2,
                "rank": 4,
                "members": [format!("token{}", i), "other"],
                "sites": [format!("file.rb:r{}:10", i)]
            }));
        }
        // Add same members tuple to trigger fat_union cluster
        missing_abstractions.push(json!({
            "kind": "tuple",
            "support": 3,
            "scatter": 2,
            "rank": 4,
            "members": ["Foo", "Bar"],
            "sites": ["file.rb:fat:10"]
        }));

        let mut path_conditions = Vec::new();
        for i in 0..25 {
            path_conditions.push(json!({
                "support": 2,
                "at": format!("file.rb:r{}:10", i),
                "missing": "other",
                "guards": [format!("token{}", i), "other"]
            }));
        }

        let fat_union_finding = json!({
            "degenerate": true,
            "variant_set": ["fat_token"],
            "common": [],
            "variant": [],
            "scatter": 2,
            "at": "file.rb:fat:10"
        });

        let bad_spans_facts = json!({
            "format": crate::decomplex::report_facts::FORMAT,
            "files": ["file.rb"],
            "detectors": {
                "decision_pressure": [{
                    "contract": "ContractA",
                    "decisions": 5,
                    "methods": 2,
                    "essential": 1,
                    "sites": ["file.rb:m:10"],
                    "spans": {
                        "file.rb:m:10": null
                    }
                }]
            }
        });
        assert!(Report::from_facts(&bad_spans_facts).is_ok());

        let malformed_spans_facts = json!({
            "format": crate::decomplex::report_facts::FORMAT,
            "files": ["file.rb"],
            "detectors": {
                "decision_pressure": [{
                    "contract": "ContractA",
                    "decisions": 5,
                    "methods": 2,
                    "essential": 1,
                    "sites": ["file.rb:m:10"],
                    "spans": {
                        "file.rb:m:10": [10, 5, 5, 10]
                    }
                }]
            }
        });
        assert!(Report::from_facts(&malformed_spans_facts).is_err());

        let locality_drag_finding = json!({
            "at": "file.rb:m:10",
            "variable": "v",
            "used_at": 20,
            "defined_at": 5,
            "score": 3.5,
            "gap_lines": 15,
            "unrelated_statements": 5,
            "boundary_crossings": 2,
            "local_complexity": 3,
            "reason": "long gap",
            "setup_statements": 0,
            "definition_deps": [],
            "use_reads": [],
            "boundaries": [],
            "examples": []
        });

        let flay_finding = json!({
            "clone_type": "type-2",
            "mass": 20,
            "node": "node_a",
            "sites": ["file.rb:m:10", "file2.rb:m:20"]
        });

        let order_drift_finding = json!({
            "kind": "order_drift",
            "confidence": 0.9,
            "support": 2,
            "at": "file.rb:m:10",
            "observed": ["a"],
            "protocol": ["a"],
            "dependency": [],
            "states": []
        });

        let protocol_pressure_finding = json!({
            "kind": "protocol_pressure",
            "support": 2,
            "at": "file.rb:m:10",
            "protocol": ["a"],
            "dependency": [],
            "states": [],
            "sites": ["file.rb:m:10"]
        });

        let op_discont_finding = json!({
            "at": "file.rb:m:10",
            "score": 4.0,
            "resets": 2,
            "dead_total": 3,
            "new_total": 4,
            "reset_points": []
        });

        let lcom_finding = json!({
            "mode": "disjoint",
            "at": "file.rb:m:10",
            "score": 0.9,
            "components": 2,
            "locals": 2,
            "statements": 4,
            "component_vars": [["a"]]
        });

        let state_heatmap_finding = json!({
            "field": "@state",
            "pressure": 10,
            "messiness": 8,
            "writes": 4,
            "reads": 6,
            "re_derivations": 1,
            "scatter": 2,
            "receiver_types": 3,
            "top_writers": ["file.rb:m1:20"],
            "top_readers": ["file.rb:m2:30"],
            "at": "file.rb:m1:20"
        });

        let comprehensive_facts = json!({
            "format": crate::decomplex::report_facts::FORMAT,
            "files": ["file.rb"],
            "detectors": {
                "decision_pressure": decision_pressures,
                "redundant_nil_guard": [],
                "state_heatmap": [state_heatmap_finding],
                "state_branch_density": state_branch_densities,
                "temporal_ordering_pressure": [],
                "miner": {
                    "missing_abstractions": missing_abstractions,
                    "neglected_conditions": []
                },
                "semantic_alias": {
                    "reification_misses": [],
                    "alias_clusters": []
                },
                "predicate_alias": {
                    "alias_clusters": []
                },
                "inconsistent_rename_clone": [],
                "flay_similarity": [flay_finding],
                "co_update": {
                    "neglected_updates": []
                },
                "derived_state": [],
                "path_condition": {
                    "neglected": path_conditions
                },
                "oversized_predicate": [],
                "sequence_mine": {
                    "broken": []
                },
                "implicit_control_flow": {
                    "ordered_protocols": [order_drift_finding, protocol_pressure_finding]
                },
                "weighted_inlined_complexity": [],
                "locality_drag": [locality_drag_finding],
                "operational_discontinuity": [op_discont_finding],
                "function_lcom": [lcom_finding],
                "false_simplicity": [],
                "fat_union": {
                    "fat_unions": [fat_union_finding]
                }
            }
        });

        let mut rep = Report::from_facts(&comprehensive_facts).unwrap();
        rep.rollup.sections.push(ReportSection::new(
            "Unknown Section Title",
            3,
            "desc",
            vec![
                json!({"at": "file.rb:m:10"}),
                json!({"at": "file.rb:10", "name": "foo"}),
                json!({"at": "file.rb:10"}),
            ],
        ));
        let markdown = rep.to_markdown();
        assert!(markdown.contains("more)"));

        let sarif_val = rep.to_sarif_value(true, true, Some(5));
        assert!(!sarif_val.is_null());

        let sarif_val_none = rep.to_sarif_value(true, true, None);
        assert!(!sarif_val_none.is_null());
    }

    #[test]
    fn test_nav_edges() {
        assert_eq!(nav("file.rb:10"), "file.rb:10");
        assert_eq!(nav("file.rb"), "file.rb");
    }

    #[test]
    fn test_sarif_loc_parsing() {
        let loc = parse_sarif_loc("file.rb:method");
        assert_eq!(loc.path.unwrap(), "file.rb");
        assert_eq!(loc.method.unwrap(), "method");
        assert_eq!(loc.line, 1);
    }

    #[test]
    fn test_sarif_locations_spans_empty() {
        let finding = json!({
            "spans": {}
        });
        let locs = sarif_locations_for_finding(&finding);
        assert!(locs.is_empty());
    }

    #[test]
    fn superfluous_state_sarif_detail_surfaces_confidence_and_reason() {
        let low_confidence = json!({
            "field": "namespace",
            "classification": "dead_state",
            "confidence": "low",
            "confidence_reason": "possible external reader via an unresolved chained receiver: app.rb:describe:8 (via spec.namespace)"
        });
        let detail = sarif_message_detail("Superfluous State", &low_confidence);
        assert!(detail.contains("confidence=low"), "got {detail:?}");
        assert!(
            detail.contains("unresolved chained receiver"),
            "got {detail:?}"
        );

        let high_confidence = json!({
            "field": "unused",
            "classification": "dead_state",
            "confidence": "high",
            "confidence_reason": null
        });
        let detail = sarif_message_detail("Superfluous State", &high_confidence);
        assert_eq!(detail, "state `unused` has dead_state (confidence=high)");
    }
}
