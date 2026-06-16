use crate::decomplex::ast::Span;
use crate::decomplex::syntax::{self, Document, Language, StateWrite};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoUpdateReport {
    pub co_written_pairs: Vec<CoWrittenPair>,
    pub neglected_updates: Vec<NeglectedUpdate>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct CoWrittenPair {
    pub pair: [String; 2],
    pub sites: Vec<String>,
    pub support: usize,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NeglectedUpdate {
    pub at: String,
    pub has: String,
    pub missing: String,
    pub pair: [String; 2],
    pub recv: String,
    pub spans: BTreeMap<String, Span>,
    pub support: usize,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<CoUpdateReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents, 3))
}

pub fn state_writes_for_files(files: &[PathBuf], language: Language) -> Result<Vec<StateWrite>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(documents
        .iter()
        .flat_map(|document| document.state_writes.clone())
        .collect())
}

pub fn scan_documents(documents: &[Document], min_support: usize) -> CoUpdateReport {
    let writes = documents
        .iter()
        .flat_map(|document| document.state_writes.clone())
        .collect::<Vec<_>>();
    let pairs = co_written_pairs(&writes, min_support);
    let neglected = neglected_updates(&writes, &pairs);
    CoUpdateReport {
        co_written_pairs: pairs,
        neglected_updates: neglected,
    }
}

fn co_written_pairs(writes: &[StateWrite], min_support: usize) -> Vec<CoWrittenPair> {
    let by_unit = writes_by_unit(writes);
    let mut counts: Vec<([String; 2], Vec<[String; 2]>)> = Vec::new();
    for ((file, function), unit_writes) in by_unit {
        let attrs = unit_writes
            .iter()
            .map(|write| write.field.clone())
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        for left in 0..attrs.len() {
            for right in (left + 1)..attrs.len() {
                let pair = [attrs[left].clone(), attrs[right].clone()];
                if let Some((_, units)) = counts.iter_mut().find(|(existing, _)| *existing == pair) {
                    units.push([file.clone(), function.clone()]);
                } else {
                    counts.push((pair, vec![[file.clone(), function.clone()]]));
                }
            }
        }
    }

    let mut out = counts
        .into_iter()
        .filter_map(|(pair, units)| {
            if units.len() < min_support {
                return None;
            }
            let support = units.len();
            Some(CoWrittenPair {
                pair,
                sites: units
                    .into_iter()
                    .map(|unit| format!("{}:{}", unit[0], unit[1]))
                    .collect(),
                support,
            })
        })
        .collect::<Vec<_>>();
    out.sort_by(|left, right| right.support.cmp(&left.support));
    out
}

fn neglected_updates(writes: &[StateWrite], pairs: &[CoWrittenPair]) -> Vec<NeglectedUpdate> {
    let by_unit = writes_by_unit(writes);
    let mut out = Vec::new();
    for ((file, function), unit_writes) in by_unit {
        let attrs = unit_writes
            .iter()
            .map(|write| write.field.as_str())
            .collect::<BTreeSet<_>>();
        for pair in pairs {
            let left = pair.pair[0].as_str();
            let right = pair.pair[1].as_str();
            let maybe = if attrs.contains(left) && !attrs.contains(right) {
                Some((left, right))
            } else if attrs.contains(right) && !attrs.contains(left) {
                Some((right, left))
            } else {
                None
            };
            let Some((has, missing)) = maybe else {
                continue;
            };
            let Some(write) = unit_writes.iter().find(|write| write.field == has) else {
                continue;
            };
            let at = format!("{file}:{function}:{}", write.line);
            let mut spans = BTreeMap::new();
            spans.insert(at.clone(), write.span);
            out.push(NeglectedUpdate {
                at,
                has: has.to_string(),
                missing: missing.to_string(),
                pair: pair.pair.clone(),
                recv: write.receiver.clone(),
                spans,
                support: pair.support,
            });
        }
    }
    out.sort_by(|left, right| right.support.cmp(&left.support));
    out
}

fn writes_by_unit(writes: &[StateWrite]) -> Vec<((String, String), Vec<StateWrite>)> {
    let mut by_unit: Vec<((String, String), Vec<StateWrite>)> = Vec::new();
    for write in writes {
        let key = (write.file.clone(), write.function.clone());
        if let Some((_, unit_writes)) = by_unit.iter_mut().find(|(existing, _)| *existing == key) {
            unit_writes.push(write.clone());
        } else {
            by_unit.push((key, vec![write.clone()]));
        }
    }
    by_unit
}

#[cfg(test)]
mod tests {
    use super::*;

    fn write(file: &str, function: &str, attr: &str, line: usize) -> StateWrite {
        StateWrite {
            field: attr.to_string(),
            receiver: "node".to_string(),
            file: file.to_string(),
            function: function.to_string(),
            line,
            span: [line, 0, line, 1],
            owner: "Box".to_string(),
        }
    }

    #[test]
    fn reports_frequent_pairs_and_neglected_updates() {
        let writes = vec![
            write("a.rb", "one", "storage", 1),
            write("a.rb", "one", "provenance", 2),
            write("a.rb", "two", "storage", 3),
            write("a.rb", "two", "provenance", 4),
            write("b.rb", "three", "storage", 5),
            write("b.rb", "three", "provenance", 6),
            write("c.rb", "broken", "storage", 7),
        ];
        let pairs = co_written_pairs(&writes, 3);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].pair, ["provenance".to_string(), "storage".to_string()]);
        assert_eq!(pairs[0].support, 3);

        let neglected = neglected_updates(&writes, &pairs);
        assert_eq!(neglected.len(), 1);
        assert_eq!(neglected[0].missing, "provenance");
        assert_eq!(neglected[0].at, "c.rb:broken:7");
    }
}
