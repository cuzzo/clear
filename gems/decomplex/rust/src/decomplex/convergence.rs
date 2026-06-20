use crate::decomplex::report::ReportSection;
use crate::decomplex::report_value as rv;
use serde::Serialize;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap};

pub const TIER_WEIGHT: &[(i64, i64)] = &[(1, 3), (2, 2), (3, 1)];

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Unit {
    pub file: String,
    pub method: String,
    pub detectors: Vec<String>,
    pub n_detectors: usize,
    pub score: i64,
    pub findings: usize,
    pub at: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FileRollup {
    pub file: String,
    pub detectors: Vec<String>,
    pub n_detectors: usize,
    pub methods: usize,
    pub score: i64,
}

#[derive(Clone, Debug)]
struct Accumulator {
    dets: BTreeMap<String, usize>,
    tiers: BTreeMap<String, i64>,
    findings: usize,
    at: Option<String>,
}

pub fn rollup(sections: &[ReportSection], min_detectors: usize) -> Vec<Unit> {
    let mut acc: HashMap<(String, String), Accumulator> = HashMap::new();
    for section in sections {
        for finding in &section.findings {
            for loc in locations(finding) {
                let (Some(file), Some(method), line) = parse_loc(&loc) else {
                    continue;
                };
                if file.is_empty() || method.is_empty() {
                    continue;
                }
                let unit = acc
                    .entry((file.clone(), method.clone()))
                    .or_insert_with(|| Accumulator {
                        dets: BTreeMap::new(),
                        tiers: BTreeMap::new(),
                        findings: 0,
                        at: None,
                    });
                *unit.dets.entry(section.title.clone()).or_insert(0) += 1;
                unit.tiers.insert(section.title.clone(), section.tier);
                unit.findings += 1;
                if unit.at.is_none() {
                    unit.at = Some(match line {
                        Some(line) => format!("{file}:{method}:{line}"),
                        None => format!("{file}:{method}"),
                    });
                }
            }
        }
    }

    let mut units = acc
        .into_iter()
        .filter_map(|((file, method), data)| {
            if data.dets.len() < min_detectors {
                return None;
            }
            let detectors = data.dets.keys().cloned().collect::<Vec<_>>();
            let score = data.tiers.values().map(|tier| tier_weight(*tier)).sum();
            Some(Unit {
                file,
                method,
                n_detectors: detectors.len(),
                detectors,
                score,
                findings: data.findings,
                at: data.at.unwrap_or_default(),
            })
        })
        .collect::<Vec<_>>();
    units.sort_by(|left, right| {
        right
            .n_detectors
            .cmp(&left.n_detectors)
            .then_with(|| right.score.cmp(&left.score))
            .then_with(|| right.findings.cmp(&left.findings))
            .then_with(|| left.file.cmp(&right.file))
            .then_with(|| left.method.cmp(&right.method))
    });
    units
}

pub fn by_file(units: &[Unit]) -> Vec<FileRollup> {
    let mut grouped: BTreeMap<String, Vec<&Unit>> = BTreeMap::new();
    for unit in units {
        grouped.entry(unit.file.clone()).or_default().push(unit);
    }

    let mut rows = grouped
        .into_iter()
        .filter_map(|(file, units)| {
            let mut detectors = units
                .iter()
                .flat_map(|unit| unit.detectors.iter().cloned())
                .collect::<Vec<_>>();
            detectors.sort();
            detectors.dedup();
            if detectors.len() < 2 {
                return None;
            }
            let score = units.iter().map(|unit| unit.score).sum();
            Some(FileRollup {
                file,
                n_detectors: detectors.len(),
                detectors,
                methods: units.len(),
                score,
            })
        })
        .collect::<Vec<_>>();
    rows.sort_by(|left, right| {
        right
            .n_detectors
            .cmp(&left.n_detectors)
            .then_with(|| right.score.cmp(&left.score))
            .then_with(|| right.methods.cmp(&left.methods))
            .then_with(|| left.file.cmp(&right.file))
    });
    rows
}

pub fn locations(finding: &Value) -> Vec<String> {
    let mut out = Vec::new();
    for key in ["at", "ref_at"] {
        if let Some(Value::String(text)) = rv::get(finding, key) {
            out.push(text.clone());
        }
    }
    if let Some(Value::Array(sites)) = rv::get(finding, "sites") {
        out.extend(
            sites
                .iter()
                .filter_map(|site| site.as_str().map(ToOwned::to_owned)),
        );
    }
    out
}

pub fn parse_loc(loc: &str) -> (Option<String>, Option<String>, Option<String>) {
    let mut parts = loc.split(':').map(ToOwned::to_owned).collect::<Vec<_>>();
    if parts.len() < 2 {
        return (None, None, None);
    }
    let line = if parts
        .last()
        .is_some_and(|part| part.chars().all(|ch| ch.is_ascii_digit()))
    {
        parts.pop()
    } else {
        None
    };
    let method = parts.pop();
    let file = Some(parts.join(":"));
    (file, method, line)
}

pub fn tier_weight(tier: i64) -> i64 {
    TIER_WEIGHT
        .iter()
        .find_map(|(key, value)| (*key == tier).then_some(*value))
        .unwrap_or(1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_loc_splits_from_the_right() {
        assert_eq!(
            parse_loc("dir:a.rb:method:42"),
            (
                Some("dir:a.rb".to_string()),
                Some("method".to_string()),
                Some("42".to_string())
            )
        );
    }

    #[test]
    fn rollup_requires_distinct_detectors() {
        let sections = vec![
            ReportSection::new("A", 1, "", vec![json!({"at": "a.rb:m:1"})]),
            ReportSection::new("B", 2, "", vec![json!({"at": "a.rb:m:2"})]),
        ];
        let rows = rollup(&sections, 2);
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].score, 5);
    }
}
