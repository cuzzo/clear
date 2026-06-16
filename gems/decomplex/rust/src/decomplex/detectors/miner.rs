use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, DecisionSite, Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MinerReport {
    pub missing_abstractions: Vec<MissingAbstraction>,
    pub neglected_conditions: Vec<NeglectedCondition>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MissingAbstraction {
    pub kind: String,
    pub members: Vec<String>,
    pub support: usize,
    pub scatter: usize,
    pub rank: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NeglectedCondition {
    pub pattern: Vec<String>,
    pub support: usize,
    pub missing: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Group {
    kind: String,
    members: Vec<String>,
    sites: Vec<DecisionSite>,
    order: usize,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<MinerReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents, 2, 3))
}

pub fn scan_documents(
    documents: &[Document],
    min_scatter: usize,
    min_neglected_support: usize,
) -> MinerReport {
    let sites = documents
        .iter()
        .flat_map(|document| document.decision_sites.clone())
        .collect::<Vec<_>>();
    MinerReport {
        missing_abstractions: missing_abstractions(&sites, min_scatter),
        neglected_conditions: neglected_conditions(&sites, min_neglected_support),
    }
}

fn missing_abstractions(sites: &[DecisionSite], min_scatter: usize) -> Vec<MissingAbstraction> {
    let mut out = groups(sites)
        .into_iter()
        .filter_map(|group| {
            let scatter = group
                .sites
                .iter()
                .map(|site| (site.file.clone(), site.function.clone()))
                .collect::<BTreeSet<_>>()
                .len();
            if scatter < min_scatter {
                return None;
            }
            let spans = group
                .sites
                .iter()
                .map(|site| (loc(site), site.span))
                .collect::<BTreeMap<_, _>>();
            Some((
                group.order,
                MissingAbstraction {
                    kind: group.kind,
                    members: group.members,
                    support: group.sites.len(),
                    scatter,
                    rank: group.sites.len() * scatter,
                    sites: group.sites.iter().map(loc).collect(),
                    spans,
                },
            ))
        })
        .collect::<Vec<_>>();
    out.sort_by(|left, right| right.1.rank.cmp(&left.1.rank).then(left.0.cmp(&right.0)));
    out.into_iter().map(|(_, finding)| finding).collect()
}

fn neglected_conditions(sites: &[DecisionSite], min_support: usize) -> Vec<NeglectedCondition> {
    let popular = groups(sites)
        .into_iter()
        .filter(|group| group.sites.len() >= min_support)
        .map(|group| (group.kind, group.members, group.sites.len()))
        .collect::<Vec<_>>();
    let mut out = Vec::new();
    let mut seen = BTreeSet::new();
    for site in sites {
        for (kind, members, support) in &popular {
            if kind != &site.kind {
                continue;
            }
            let missing = difference(members, &site.members);
            let extra = difference(&site.members, members);
            if missing.len() != 1 || !extra.is_empty() || &site.members == members {
                continue;
            }
            let at = loc(site);
            let mut spans = BTreeMap::new();
            spans.insert(at.clone(), site.span);
            let finding = NeglectedCondition {
                pattern: members.clone(),
                support: *support,
                missing: missing[0].clone(),
                at,
                spans,
            };
            let key = serde_json::to_string(&finding).unwrap_or_default();
            if seen.insert(key) {
                out.push(finding);
            }
        }
    }
    out.sort_by(|left, right| right.support.cmp(&left.support));
    out
}

fn groups(sites: &[DecisionSite]) -> Vec<Group> {
    let mut groups = Vec::new();
    let mut seen_sites = BTreeSet::new();
    for site in sites {
        let site_key = format!(
            "{}\0{}\0{}\0{}\0{}",
            site.file,
            site.function,
            site.line,
            site.kind,
            site.members.join("\0")
        );
        if !seen_sites.insert(site_key) {
            continue;
        }
        if let Some(group) = groups
            .iter_mut()
            .find(|group: &&mut Group| group.kind == site.kind && group.members == site.members)
        {
            group.sites.push(site.clone());
        } else {
            groups.push(Group {
                kind: site.kind.clone(),
                members: site.members.clone(),
                sites: vec![site.clone()],
                order: groups.len(),
            });
        }
    }
    groups
}

fn difference(left: &[String], right: &[String]) -> Vec<String> {
    left.iter()
        .filter(|candidate| !right.contains(candidate))
        .cloned()
        .collect()
}

fn loc(site: &DecisionSite) -> String {
    format!("{}:{}:{}", site.file, site.function, site.line)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn site(function: &str, line: usize, members: &[&str]) -> DecisionSite {
        DecisionSite {
            kind: "conjunction".to_string(),
            members: members.iter().map(|member| member.to_string()).collect(),
            file: "a.rb".to_string(),
            function: function.to_string(),
            line,
            span: [line, 0, line, 1],
            predicate: members.join(" && "),
        }
    }

    #[test]
    fn reports_missing_abstractions_and_neglected_conditions() {
        let sites = vec![
            site("one", 1, &["a", "b", "c"]),
            site("two", 2, &["a", "b", "c"]),
            site("three", 3, &["a", "b", "c"]),
            site("broken", 4, &["a", "b"]),
        ];
        let missing = missing_abstractions(&sites, 2);
        assert_eq!(missing.len(), 1);
        assert_eq!(missing[0].support, 3);
        assert_eq!(missing[0].scatter, 3);

        let neglected = neglected_conditions(&sites, 3);
        assert_eq!(neglected.len(), 1);
        assert_eq!(neglected[0].missing, "c");
        assert_eq!(neglected[0].at, "a.rb:broken:4");
    }
}
