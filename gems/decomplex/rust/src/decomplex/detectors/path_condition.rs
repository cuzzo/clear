use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PathConditionReport {
    pub neglected: Vec<NeglectedPathCondition>,
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

#[derive(Clone, Debug)]
struct Site {
    guards: Vec<String>,
    action: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<PathConditionReport> {
    let mut sites = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut pc = PathCondition::new(file.to_string_lossy().to_string(), lines);
        pc.walk(&root, &Vec::new(), &Vec::new());
        sites.extend(pc.sites);
    }
    Ok(Report::new(sites).findings())
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
                let cond = node.children.get(0).and_then(ast::node);
                let a = node.children.get(1).and_then(ast::node);
                let b = node.children.get(2).and_then(ast::node);

                let atoms = self.cond_atoms(cond);
                let then_g = if node.r#type == "IF" { atoms.clone() } else { self.negate(&atoms) };
                let else_g = if node.r#type == "IF" { self.negate(&atoms) } else { atoms.clone() };

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

                if let Some(cond_node) = cond {
                    self.walk(cond_node, &next_defstack, guards);
                }
                return;
            }
            "CALL" | "FCALL" | "VCALL" | "ATTRASGN" | "LASGN" | "IASGN" | "OPCALL" => {
                if guards.len() >= 2 {
                    self.record(node, &next_defstack, guards);
                }
            }
            _ => {}
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack, guards);
        }
    }

    fn cond_atoms(&self, cond: Option<&Node>) -> Vec<Vec<String>> {
        let Some(cond) = cond else { return Vec::new() };
        ast::flatten_and(cond).into_iter().map(|a| {
            let t = ast::slice(a, &self.lines);
            let (text, neg) = ast::canon_polarity(&t);
            vec![text, if neg { "true".to_string() } else { "false".to_string() }]
        }).collect()
    }

    fn negate(&self, atoms: &[Vec<String>]) -> Vec<Vec<String>> {
        atoms.iter().map(|a| {
            let t = &a[0];
            let n = a[1] == "true";
            vec![t.clone(), if !n { "true".to_string() } else { "false".to_string() }]
        }).collect()
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
        let action = if slice.len() > 80 { slice[..80].to_string() } else { slice };

        self.sites.push(Site {
            guards: members,
            action,
            file: self.file.clone(),
            defn: defstack.last().cloned().unwrap_or_else(|| "(top-level)".to_string()),
            line: node.first_lineno,
            span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
        });
    }
}

struct Report {
    sites: Vec<Site>,
    groups: BTreeMap<Vec<String>, Vec<Site>>,
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
        
        let ordered_groups = keys.into_iter().map(|k| {
            let v = groups.remove(&k).unwrap();
            (k, v)
        }).collect();

        Self {
            sites,
            groups: ordered_groups,
        }
    }

    fn findings(&self) -> PathConditionReport {
        PathConditionReport {
            neglected: self.neglected(3),
        }
    }

    fn neglected(&self, min_support: usize) -> Vec<NeglectedPathCondition> {
        let popular: Vec<_> = self.groups.iter()
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
                    if s.guards == *gs {
                        continue;
                    }

                    let at = format!("{}:{}:{}", s.file, s.defn, s.line);
                    let missing = diff_gs_s.into_iter().next().unwrap();

                    // dedupe manually
                    let key = (gs.clone(), sup.clone(), missing.clone(), at.clone());
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
