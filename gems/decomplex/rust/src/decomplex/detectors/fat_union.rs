use crate::decomplex::syntax::{self, DispatchSite, Document, Language, Span};
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
