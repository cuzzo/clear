use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::{self, DispatchSite, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FatUnionReport {
    pub fat_unions: Vec<FatUnionRow>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FatUnionRow {
    pub name: String,
    pub common: Vec<String>,
    pub variant: Vec<String>,
    pub degenerate: bool,
    pub support: usize,
    pub scatter: usize,
    pub variant_set: Vec<String>,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Read {
    name: String,
    span: Span,
}

#[derive(Clone, Debug)]
struct VariantReads {
    reads: Vec<Read>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<FatUnionReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> FatUnionReport {
    let sites = documents
        .iter()
        .flat_map(|document| document.dispatch_sites.iter())
        .collect::<Vec<_>>();
    FatUnionReport {
        fat_unions: fat_unions_from_sites(&sites, 3, 2, 0.6),
    }
}

fn fat_unions_from_sites(
    sites: &[&DispatchSite],
    min_variants: usize,
    min_common: usize,
    ratio: f64,
) -> Vec<FatUnionRow> {
    let mut groups: BTreeMap<Vec<String>, Vec<&DispatchSite>> = BTreeMap::new();
    for site in sites {
        groups
            .entry(site.variant_set.clone())
            .or_default()
            .push(*site);
    }

    let mut rows = Vec::new();
    for (variant_set, group) in groups {
        let variant_count = variant_set.len();
        if variant_count < min_variants {
            continue;
        }

        let mut by_member_variant: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
        let mut outside = BTreeSet::new();
        for site in &group {
            for (variant, members) in &site.arm_members {
                for member in members {
                    by_member_variant
                        .entry(member.clone())
                        .or_default()
                        .insert(variant.clone());
                }
            }
            for member in &site.outside {
                outside.insert(member.clone());
            }
        }

        let mut keys = by_member_variant.keys().cloned().collect::<BTreeSet<_>>();
        keys.extend(outside.iter().cloned());
        let common = keys
            .iter()
            .filter(|member| {
                outside.contains(*member)
                    || by_member_variant
                        .get(*member)
                        .map(|variants| variants.len() >= variant_count)
                        .unwrap_or(false)
            })
            .cloned()
            .collect::<Vec<_>>();
        let variant = keys
            .iter()
            .filter(|member| {
                !outside.contains(*member)
                    && by_member_variant
                        .get(*member)
                        .map(|variants| variants.len() == 1)
                        .unwrap_or(false)
            })
            .cloned()
            .collect::<Vec<_>>();
        let total = common.len() + variant.len();
        if common.len() < min_common || total == 0 || common.len() as f64 / (total as f64) < ratio {
            continue;
        }

        let at = group
            .first()
            .map(|site| format!("{}:{}:{}", site.file, site.function, site.line))
            .unwrap_or_default();
        let mut spans = BTreeMap::new();
        for site in &group {
            spans.insert(
                format!("{}:{}:{}", site.file, site.function, site.line),
                site.span,
            );
        }
        let scatter = group
            .iter()
            .map(|site| (site.file.clone(), site.function.clone()))
            .collect::<BTreeSet<_>>()
            .len();
        rows.push((
            group.len() * common.len(),
            FatUnionRow {
                name: String::new(),
                common,
                variant: variant.clone(),
                degenerate: variant.is_empty(),
                support: group.len(),
                scatter,
                variant_set,
                at,
                spans,
            },
        ));
    }

    rows.sort_by(|a, b| {
        (if a.1.degenerate { 0 } else { 1 })
            .cmp(&(if b.1.degenerate { 0 } else { 1 }))
            .then_with(|| b.0.cmp(&a.0))
    });
    rows.into_iter().map(|(_, row)| row).collect()
}

#[allow(dead_code)]
fn scan_documents_from_normalized_roots(documents: &[Document]) -> FatUnionReport {
    let mut out = Vec::new();
    for document in documents {
        let mut detector = FatUnion::new(document.file.clone(), document.lines.clone());
        detector.walk(&document.normalized_root, &Vec::new());
        out.extend(detector.findings());
    }
    out.sort_by(|a, b| {
        b.common
            .len()
            .cmp(&a.common.len())
            .then_with(|| a.at.cmp(&b.at))
    });
    FatUnionReport { fat_unions: out }
}

struct FatUnion {
    file: String,
    lines: Vec<String>,
    reports: Vec<FatUnionRow>,
}

impl FatUnion {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            reports: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String]) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        if matches!(node.r#type.as_str(), "CASE" | "CASE2") {
            self.analyze_case(node, &next_defstack);
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn analyze_case(&mut self, node: &Node, defstack: &[String]) {
        let (cond, first_when) = if node.r#type == "CASE2" {
            (None, node.children.get(0).and_then(ast::node))
        } else {
            (
                node.children.get(0).and_then(ast::node),
                node.children.get(1).and_then(ast::node),
            )
        };

        let mut variants = BTreeMap::new();
        let mut current_when = first_when;
        while let Some(when_node) = current_when {
            if when_node.r#type != "WHEN" {
                break;
            }
            if let Some(pat) = when_node.children.get(0).and_then(ast::node) {
                if let Some(variant_name) = self.variant_name(pat) {
                    let reads = self.collect_reads(
                        when_node
                            .children
                            .get(1)
                            .and_then(ast::node)
                            .unwrap_or(when_node),
                    );
                    variants.insert(variant_name, VariantReads { reads });
                }
            }
            current_when = when_node.children.get(2).and_then(ast::node);
        }

        if variants.len() < 3 {
            return;
        }

        let mut common = None;
        let mut member_counts: BTreeMap<String, usize> = BTreeMap::new();
        for v in variants.values() {
            let names: BTreeSet<_> = v.reads.iter().map(|r| r.name.clone()).collect();
            for name in &names {
                *member_counts.entry(name.clone()).or_insert(0) += 1;
            }
            match common {
                None => common = Some(names),
                Some(ref mut c) => {
                    *c = c.intersection(&names).cloned().collect();
                }
            }
        }

        let common = common.unwrap_or_default();
        if common.len() < 2 {
            return;
        }
        let variant: BTreeSet<_> = member_counts
            .iter()
            .filter_map(|(name, count)| {
                (*count == 1 && !common.contains(name)).then(|| name.clone())
            })
            .collect();
        let total = common.len() + variant.len();
        if total == 0 || (common.len() as f64 / total as f64) < 0.6 {
            return;
        }

        let subject_name = self.subject_name(cond);
        let defn = defstack.last().map(|s| s.as_str()).unwrap_or("<top>");
        let at = format!("{}:{}:{}", self.file, defn, node.first_lineno);

        let mut spans = BTreeMap::new();
        spans.insert(
            at.clone(),
            [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
        );

        let mut variant_set: Vec<_> = variants.keys().cloned().collect();
        variant_set.sort();
        let mut common_vec: Vec<_> = common.into_iter().collect();
        common_vec.sort();
        let mut variant_vec: Vec<_> = variant.into_iter().collect();
        variant_vec.sort();

        self.reports.push(FatUnionRow {
            name: subject_name,
            common: common_vec,
            variant: variant_vec.clone(),
            degenerate: variant_vec.is_empty(),
            support: 1,
            scatter: 1,
            variant_set,
            at,
            spans,
        });
    }

    fn variant_name(&self, node: &Node) -> Option<String> {
        let n = if node.r#type == "LIST" {
            node.children.iter().filter_map(ast::node).next()?
        } else {
            node
        };
        match n.r#type.as_str() {
            "CONST" | "CONSTANT" | "COLON2" | "COLON3" | "SCOPE_RESOLUTION" => {
                Some(ast::slice(n, &self.lines))
            }
            _ => None,
        }
    }

    fn collect_reads(&self, node: &Node) -> Vec<Read> {
        let mut out = Vec::new();
        self.walk_reads(node, &mut out);
        out
    }

    fn walk_reads(&self, node: &Node, out: &mut Vec<Read>) {
        if matches!(node.r#type.as_str(), "CALL" | "OPCALL") {
            if let Some(Child::Symbol(mid)) = node.children.get(1) {
                out.push(Read {
                    name: mid.clone(),
                    span: [
                        node.first_lineno,
                        node.first_column,
                        node.last_lineno,
                        node.last_column,
                    ],
                });
            }
        } else if matches!(node.r#type.as_str(), "FCALL" | "VCALL") {
            if let Some(Child::Symbol(mid)) = node.children.get(0) {
                out.push(Read {
                    name: mid.clone(),
                    span: [
                        node.first_lineno,
                        node.first_column,
                        node.last_lineno,
                        node.last_column,
                    ],
                });
            }
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.walk_reads(child, out);
        }
    }

    fn subject_name(&self, cond: Option<&Node>) -> String {
        cond.map(|c| ast::slice(c, &self.lines))
            .unwrap_or_else(|| "implicit".to_string())
    }

    fn findings(&self) -> Vec<FatUnionRow> {
        self.reports.clone()
    }
}
