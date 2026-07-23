use crate::ast::{self, Child, Node, Span};
use crate::syntax::{Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PathConditionReport {
    pub neglected: Vec<NeglectedPathCondition>,
    pub scattered: Vec<ScatteredPathCondition>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NeglectedPathCondition {
    pub pattern: Vec<String>,
    pub support: usize,
    pub missing: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
    pub action: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ScatteredPathCondition {
    pub guards: Vec<String>,
    pub support: usize,
    pub scatter: usize,
    pub rank: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Site {
    guards: Vec<String>,
    action: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<PathConditionReport> {
    let documents = super::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> PathConditionReport {
    let sites = documents
        .iter()
        .flat_map(|document| {
            fact_sites_for_document(document)
                .into_iter()
                .map(|site| Site {
                    guards: site.guards,
                    action: site.action,
                    file: site.file,
                    defn: site.function,
                    line: site.line,
                    span: site.span,
                })
        })
        .collect::<Vec<_>>();
    Report::new(sites).findings()
}

pub(crate) fn fact_sites_for_document(
    document: &Document,
) -> Vec<crate::syntax::PathConditionSite> {
    document.path_condition_sites.clone()
}

pub(crate) fn normalized_fact_sites(
    file: &str,
    lines: &[String],
    normalized_root: &Node,
) -> Vec<crate::syntax::PathConditionSite> {
    let mut pc = PathCondition::new(file.to_string(), lines.to_vec());
    pc.walk(normalized_root, &Vec::new(), &Vec::new());
    dedupe_sites(pc.sites)
        .into_iter()
        .map(|site| crate::syntax::PathConditionSite {
            guards: site.guards,
            action: site.action,
            file: site.file,
            function: site.defn,
            line: site.line,
            span: site.span,
        })
        .collect()
}

fn dedupe_sites(sites: Vec<Site>) -> Vec<Site> {
    let mut seen = BTreeSet::new();
    sites
        .into_iter()
        .filter(|site| {
            seen.insert((
                site.guards.clone(),
                site.action.clone(),
                site.file.clone(),
                site.defn.clone(),
                site.line,
            ))
        })
        .collect()
}

struct PathCondition {
    file: String,
    lines: Vec<String>,
    sites: Vec<Site>,
}

impl PathCondition {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            sites: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String], guards: &[Vec<String>]) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        match node.r#type.as_str() {
            "IF" | "UNLESS" => {
                let cond = node.children.first().and_then(ast::node);
                let a = node.children.get(1).and_then(ast::node);
                let b = node.children.get(2).and_then(ast::node);

                let atoms = self.cond_atoms(cond);
                let then_g = if node.r#type == "IF" {
                    atoms.clone()
                } else {
                    self.negate(&atoms)
                };
                let else_g = if node.r#type == "IF" {
                    self.negate(&atoms)
                } else {
                    atoms.clone()
                };

                if let Some(a_node) = a {
                    let mut next_guards = guards.to_vec();
                    next_guards.extend(then_g);
                    self.walk(a_node, &next_defstack, &next_guards);
                }
                if let Some(b_node) = b {
                    let mut next_guards = guards.to_vec();
                    next_guards.extend(else_g);
                    self.walk(b_node, &next_defstack, &next_guards);
                }

                return;
            }
            "CALL" | "FCALL" | "VCALL" | "ATTRASGN" | "LASGN" | "IASGN" | "OPCALL"
                if guards.len() >= 2 =>
            {
                self.record(node, &next_defstack, guards);
            }
            _ => {}
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack, guards);
        }
    }

    fn cond_atoms(&self, cond: Option<&Node>) -> Vec<Vec<String>> {
        let Some(cond) = cond else { return Vec::new() };
        ast::flatten_and(cond)
            .into_iter()
            .map(|a| {
                let t = ast::slice(a, &self.lines);
                let (text, neg) = ast::canon_polarity(&t);
                vec![
                    text,
                    if neg {
                        "true".to_string()
                    } else {
                        "false".to_string()
                    },
                ]
            })
            .collect()
    }

    fn negate(&self, atoms: &[Vec<String>]) -> Vec<Vec<String>> {
        atoms
            .iter()
            .map(|a| {
                let t = &a[0];
                let n = a[1] == "true";
                vec![
                    t.clone(),
                    if !n {
                        "true".to_string()
                    } else {
                        "false".to_string()
                    },
                ]
            })
            .collect()
    }

    fn record(&mut self, node: &Node, defstack: &[String], guards: &[Vec<String>]) {
        let mut members_set = BTreeSet::new();
        for g in guards {
            let prefix = if g[1] == "true" { "!" } else { "" };
            members_set.insert(format!("{}{}", prefix, g[0]));
        }
        let members: Vec<_> = members_set.into_iter().collect();

        if members.len() < 2 {
            return;
        }

        let slice = ast::slice(node, &self.lines);
        // `slice` is UTF-8 source text. Do not use a byte index here: a
        // perfectly ordinary non-ASCII token can straddle byte 80 and panic
        // while we are merely preparing a diagnostic excerpt.
        let action = truncate_action(&slice, 80);

        self.sites.push(Site {
            guards: members,
            action,
            file: self.file.clone(),
            defn: defstack
                .last()
                .cloned()
                .unwrap_or_else(|| "(top-level)".to_string()),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
        });
    }
}

fn truncate_action(slice: &str, max_chars: usize) -> String {
    slice.chars().take(max_chars).collect()
}

struct Report {
    sites: Vec<Site>,
    groups: Vec<(Vec<String>, Vec<Site>)>,
}

impl Report {
    fn new(sites: Vec<Site>) -> Self {
        let mut keys = Vec::new();
        let mut groups: BTreeMap<Vec<String>, Vec<Site>> = BTreeMap::new();
        for s in &sites {
            if !groups.contains_key(&s.guards) {
                keys.push(s.guards.clone());
            }
            groups.entry(s.guards.clone()).or_default().push(s.clone());
        }

        let ordered_groups = keys
            .into_iter()
            .map(|k| {
                let v = groups.remove(&k).unwrap();
                (k, v)
            })
            .collect();

        Self {
            sites,
            groups: ordered_groups,
        }
    }

    fn findings(&self) -> PathConditionReport {
        PathConditionReport {
            neglected: self.neglected(3),
            scattered: self.scattered(2),
        }
    }

    fn scattered(&self, min_scatter: usize) -> Vec<ScatteredPathCondition> {
        let mut out = Vec::new();
        for (guards, sites) in &self.groups {
            let scatter = sites
                .iter()
                .map(|site| (site.file.clone(), site.defn.clone()))
                .collect::<BTreeSet<_>>()
                .len();
            if scatter < min_scatter {
                continue;
            }

            let locations = sites
                .iter()
                .map(|site| format!("{}:{}:{}", site.file, site.defn, site.line))
                .collect::<Vec<_>>();
            let spans = sites
                .iter()
                .map(|site| {
                    (
                        format!("{}:{}:{}", site.file, site.defn, site.line),
                        site.span,
                    )
                })
                .collect::<BTreeMap<_, _>>();
            out.push(ScatteredPathCondition {
                guards: guards.clone(),
                support: sites.len(),
                scatter,
                rank: sites.len() * scatter,
                sites: locations,
                spans,
            });
        }
        out.sort_by(|a, b| b.rank.cmp(&a.rank).then_with(|| a.guards.cmp(&b.guards)));
        out
    }

    fn neglected(&self, min_support: usize) -> Vec<NeglectedPathCondition> {
        let popular: Vec<_> = self
            .groups
            .iter()
            .filter(|(_, s)| s.len() >= min_support)
            .map(|(g, s)| (g.clone(), s.len()))
            .collect();

        let mut out = Vec::new();
        let mut seen = BTreeSet::new();

        for s in &self.sites {
            for (gs, sup) in &popular {
                let gs_set: BTreeSet<_> = gs.iter().cloned().collect();
                let s_guards_set: BTreeSet<_> = s.guards.iter().cloned().collect();

                let diff_gs_s: BTreeSet<_> = gs_set.difference(&s_guards_set).cloned().collect();
                let diff_s_gs: BTreeSet<_> = s_guards_set.difference(&gs_set).cloned().collect();

                if diff_gs_s.len() == 1 && diff_s_gs.is_empty() {
                    let at = format!("{}:{}:{}", s.file, s.defn, s.line);
                    let missing = diff_gs_s.into_iter().next().unwrap();

                    // Do not flag structural pattern match bindings (e.g. `let Some(x) = ...`) as optional neglected checks.
                    if missing.starts_with("let ")
                        || missing.starts_with("!let ")
                        || missing.starts_with("let(")
                        || missing.starts_with("!let(")
                    {
                        continue;
                    }

                    // dedupe manually
                    let key = (gs.clone(), *sup, missing.clone(), at.clone());
                    if seen.insert(key) {
                        let mut spans = BTreeMap::new();
                        spans.insert(at.clone(), s.span);

                        out.push(NeglectedPathCondition {
                            pattern: gs.clone(),
                            support: *sup,
                            missing,
                            at,
                            spans,
                            action: s.action.clone(),
                        });
                    }
                }
            }
        }

        out.sort_by(|a, b| b.support.cmp(&a.support).then_with(|| a.at.cmp(&b.at)));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn truncating_diagnostic_source_never_splits_a_utf8_codepoint() {
        let source = format!("{}€ŠšŽ", "a".repeat(79));
        let action = truncate_action(&source, 80);
        assert_eq!(action.chars().count(), 80);
        assert!(action.ends_with('€'));
        assert!(std::str::from_utf8(action.as_bytes()).is_ok());
    }
}
