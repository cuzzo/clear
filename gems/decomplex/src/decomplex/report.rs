use crate::decomplex::convergence::{self, Unit};
use crate::decomplex::report_value as rv;
use crate::decomplex::root_cause::{self, Cluster};
use crate::decomplex::{delta, sarif};
use anyhow::{bail, Result};
use serde_json::{json, Value};

#[derive(Clone, Debug)]
pub struct ReportSection {
    pub title: String,
    pub tier: i64,
    pub desc: String,
    pub findings: Vec<Value>,
    convergence_excluded: bool,
}

impl ReportSection {
    pub fn new(title: &str, tier: i64, desc: &str, findings: Vec<Value>) -> Self {
        Self {
            title: title.to_string(),
            tier,
            desc: desc.to_string(),
            findings,
            convergence_excluded: false,
        }
    }

    fn excluded_from_convergence(mut self) -> Self {
        self.convergence_excluded = true;
        self
    }
}

#[derive(Clone, Debug)]
pub struct Report {
    files: Vec<String>,
    sections: Vec<ReportSection>,
    convergence: Vec<Unit>,
    root: Vec<Cluster>,
}

impl Report {
    pub fn from_facts(facts: &Value) -> Result<Self> {
        let files = rv::field_array_strings(facts, "files");
        let Some(detectors) = rv::get(facts, "detectors") else {
            bail!("report facts missing detectors");
        };
        let sections = build_sections(detectors);
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

    pub fn to_markdown(&self) -> String {
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
            self.convergence.len(),
            self.convergence.len()
        ));
        out.push_str(&format!(
            "- [Root-Cause Clusters ({})](#root-cause-clusters-{})\n",
            self.root.len(),
            self.root.len()
        ));
        for section in &self.sections {
            out.push_str(&format!(
                "- [{} ({})](#{}-{})\n",
                section.title,
                section.findings.len(),
                slug(&section.title),
                section.findings.len()
            ));
        }
        out.push_str("- [Run Summary](#run-summary)\n\n");

        self.render_project_prioritization(&mut out);
        self.render_convergence(&mut out);
        self.render_root_cause(&mut out);

        for section in &self.sections {
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
            self.render_section(&mut out, section);
            out.push('\n');
        }

        out.push_str("## Run Summary\n");
        out.push_str(&format!("- Files analyzed: {}\n", self.files.len()));
        out.push_str(&format!(
            "- Detectors: {} (all shipped, self-tested)\n",
            self.sections.len()
        ));
        out.push_str(&format!(
            "- Convergence: {} unit(s) flagged by >=2 independent detectors\n",
            self.convergence.len()
        ));
        out.push_str(&format!(
            "- Root-cause clusters: {} (one fix collapses each)\n",
            self.root.len()
        ));
        let total: usize = self
            .sections
            .iter()
            .map(|section| section.findings.len())
            .sum();
        out.push_str(&format!("- Total candidates: {total}\n"));
        out.push_str("- Method: stdlib AST only, intra-procedural, zero deps, no CFG / no points-to; Type-2/3 similarity uses Tree-sitter structural fingerprints (see docs/agents/design.md)\n");
        out
    }

    pub fn to_sarif(&self) -> String {
        serde_json::to_string_pretty(&self.to_sarif_value(true, true, None)).unwrap()
    }

    pub fn convergence_value(&self) -> Value {
        json!(self.convergence)
    }

    pub fn root_clusters_value(&self) -> Value {
        json!(self.root)
    }

    pub fn to_sarif_value(
        &self,
        include_snapshot: bool,
        include_finding_payload: bool,
        max_results: Option<usize>,
    ) -> Value {
        let snapshot = delta::snapshot(&self.sections, &self.root);
        let mut results = self.sarif_results(include_finding_payload);
        if let Some(max_results) = max_results {
            results = ranked_sarif_results(results)
                .into_iter()
                .take(max_results)
                .collect();
        }
        let mut properties = json!({
            "format": "decomplex.report.sarif.v1",
            "files": self.files,
        });
        if include_snapshot {
            if let Some(object) = properties.as_object_mut() {
                object.insert("decomplex.snapshot".to_string(), snapshot);
            }
        }
        sarif::document(
            "Decomplex",
            self.sarif_rules(),
            results,
            Some("https://github.com/cuzzo/clear"),
            properties,
        )
    }

    fn render_project_prioritization(&self, out: &mut String) {
        out.push_str("## Project Prioritization\n");
        out.push_str(
            "_Ordered by signal tier (1 = highest signal / lowest FP), then by volume._\n\n",
        );
        let mut ranked = self
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
        if self
            .sections
            .iter()
            .all(|section| section.findings.is_empty())
        {
            out.push_str("\nNothing flagged.\n");
        }
        out.push('\n');
    }

    fn render_convergence(&self, out: &mut String) {
        out.push_str(&format!(
            "## Cross-Detector Convergence ({})\n",
            self.convergence.len()
        ));
        out.push_str("_(file, method) units flagged by >=2 INDEPENDENT detectors -- the strongest triage signal: agreement outranks any single detector's volume. Tier-weighted (1=3, 2=2, 3=1). **Start here.**_\n\n");
        if self.convergence.is_empty() {
            out.push_str("None (no unit flagged by >=2 detectors).\n\n");
            return;
        }
        for hit in self.convergence.iter().take(25) {
            out.push_str(&format!(
                "- {} -- **{} detectors** [score {}, {} findings]: {}\n",
                nav(&hit.at),
                hit.n_detectors,
                hit.score,
                hit.findings,
                hit.detectors.join(", ")
            ));
        }
        if self.convergence.len() > 25 {
            out.push_str(&format!("- ...(+{} more)\n", self.convergence.len() - 25));
        }
        let by_file = convergence::by_file(&self.convergence);
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

    fn render_root_cause(&self, out: &mut String) {
        out.push_str(&format!("## Root-Cause Clusters ({})\n", self.root.len()));
        out.push_str("_Findings across >=2 INDEPENDENT detectors that name the SAME entity -- 'N findings are really one invariant'. Convergence says where to look; this says **what one fix collapses the cluster**. Ranked candidate, not a verdict._\n\n");
        if self.root.is_empty() {
            out.push_str("None (no entity named by >=2 detectors).\n\n");
            return;
        }
        for hit in self.root.iter().take(20) {
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
        if self.root.len() > 20 {
            out.push_str(&format!("- ...(+{} more)\n", self.root.len() - 20));
        }
        out.push('\n');
    }

    fn render_section(&self, out: &mut String, section: &ReportSection) {
        for finding in section.findings.iter().take(25) {
            out.push_str(&render_finding(&section.title, finding));
        }
        if section.findings.len() > 25 {
            out.push_str(&format!("- ...(+{} more)\n", section.findings.len() - 25));
        }
    }

    fn sarif_rules(&self) -> Vec<Value> {
        self.sections
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

    fn sarif_results(&self, include_finding_payload: bool) -> Vec<Value> {
        let mut out = Vec::new();
        for section in &self.sections {
            for finding in &section.findings {
                for location in sarif_locations_for_finding(finding) {
                    let mut properties = json!({
                        "detector": section.title,
                        "tier": section.tier,
                        "method": location.method,
                    });
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

#[derive(Clone, Debug)]
struct SarifLocation {
    path: Option<String>,
    method: Option<String>,
    line: i64,
    start_column: Option<i64>,
    end_line: Option<i64>,
    end_column: Option<i64>,
}

fn build_sections(detectors: &Value) -> Vec<ReportSection> {
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

    vec![
        section("Decision Pressure", 1, "ELIMINABLE guard-pressure per loose contract (nil/is_a?/respond_to?/safe-nav/rescue-nil) -> tighten the contract once / nil-kill: DELETE. essential dispatch + pure c-uses are split out, NEVER summed (Rapps-Weyuker p-use; McCabe)", direct_array(detectors, "decision_pressure")),
        section("Redundant Nil Guards", 1, "nil checks / safe-nav dominated by an earlier non-nil proof -- delete repeated control flow or tighten the type", direct_array(detectors, "redundant_nil_guard")),
        section("State Heatmap", 1, "state fields ranked by write/read/re-derivation scatter -- tangled mutable state should get one owner", direct_array(detectors, "state_heatmap")).excluded_from_convergence(),
        section("State-Based Branch Density", 1, "branch decisions over mutable/object state -- state + control-flow pressure", direct_array(detectors, "state_branch_density")),
        section("Temporal Ordering Pressure", 1, "public mutable lifecycle surfaces that create implicit state-machine ordering", direct_array(detectors, "temporal_ordering_pressure")),
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
        section("Broken Protocols", 3, "co-called pair, one site does A without B -- *POSSIBLE* bug (noisy)", nested_array(sequence_mine, "broken_protocol")),
        section("Implicit Control Flow", 2, "state-dependent internal call order exists -- hidden lifecycle/control-flow pressure", nested_array(rv::get(detectors, "implicit_control_flow").unwrap_or(&Value::Null), "ordered_protocols")),
        section("Weighted Inlined Cognitive Complexity", 2, "same-owner helper chain hides cognitive load behind a low-looking orchestration method", direct_array(detectors, "weighted_inlined_complexity")),
        section("Locality Drag", 2, "local initialized far before first use while unrelated work runs -- move setup closer or extract a private phase", direct_array(detectors, "locality_drag")),
        section("Operational Discontinuity (High Confidence)", 2, "strong blank/comment phase boundary where local variable lifetimes reset -- likely implicit sub-function boundary", operational_high),
        section("Function LCOM", 3, "independent local data-flow components inside one method -- *POSSIBLE* mixed concerns", direct_array(detectors, "function_lcom")),
        section("Operational Discontinuity", 3, "blank/comment phase boundary where local variable lifetimes reset -- *POSSIBLE* implicit sub-function boundary", operational_rest),
        section("False Simplicity", 3, "looks simple, behaves non-locally: hidden dispatch/mutation/IO/context/reflection/reopen -- *POSSIBLE* (noisy)", direct_array(detectors, "false_simplicity")),
        section("Fat Unions", 3, "case dispatch over class consts whose arms read mostly variant-invariant members -- product-vs-sum decomposition candidate (extraction -> nil-kill) -- *POSSIBLE*", nested_array(fat_union, "fat_unions")),
    ]
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
                    parsed.end_line = span.get(2).and_then(Value::as_i64).filter(|line| *line > 0);
                    parsed.end_column = span
                        .get(3)
                        .and_then(Value::as_i64)
                        .map(zero_based_column_to_sarif);
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
    }
}

fn zero_based_column_to_sarif(value: i64) -> i64 {
    value + 1
}

#[cfg(test)]
mod tests {
    use super::*;

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
}
