use crate::decomplex::convergence;
use crate::decomplex::report::ReportSection;
use crate::decomplex::report_value as rv;
use regex::Regex;
use serde_json::Value;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::sync::OnceLock;

const TUPLE_FIELDS: &[&str] = &["members", "guards", "pattern"];
const NAME_ARRAY_FIELDS: &[&str] = &["pair", "names"];
const NAME_STR_FIELDS: &[&str] = &[
    "field",
    "derived",
    "source",
    "contract",
    "canon",
    "predicate",
    "detail",
    "ref_name",
    "has",
    "missing",
];
const STOPWORDS: &[&str] = &[
    "nil", "true", "false", "self", "end", "do", "if", "then", "else", "self_", "it", "new",
    "to_s", "call", "each", "map",
];
const FAT_UNION_FIX: &str = "fat union -- decompose product-vs-sum: hoist the common fields to a struct, keep a SMALL union for the variant part (extraction is value-object work -> nil-kill owns it)";

#[derive(Clone, Debug, Eq, PartialEq, Hash)]
pub struct Entity {
    pub kind: String,
    pub token: String,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Cluster {
    pub kind: String,
    pub token: String,
    pub detectors: Vec<String>,
    pub n_detectors: usize,
    pub support: usize,
    pub scatter: usize,
    pub score: i64,
    pub fat_union: bool,
    pub fix: String,
    pub sites: Vec<String>,
}

#[derive(Clone, Debug)]
struct Accumulator {
    dets: BTreeMap<String, bool>,
    findings: Vec<Value>,
    tiers: BTreeMap<String, i64>,
}

pub fn cluster(sections: &[ReportSection], min_detectors: usize) -> Vec<Cluster> {
    let mut acc: HashMap<Entity, Accumulator> = HashMap::new();
    for section in sections {
        for finding in &section.findings {
            for entity in entities(finding) {
                let row = acc.entry(entity).or_insert_with(|| Accumulator {
                    dets: BTreeMap::new(),
                    findings: Vec::new(),
                    tiers: BTreeMap::new(),
                });
                row.dets.insert(section.title.clone(), true);
                row.tiers.insert(section.title.clone(), section.tier);
                row.findings.push(finding.clone());
            }
        }
    }

    let mut clusters = acc
        .into_iter()
        .filter_map(|(entity, row)| {
            if row.dets.len() < min_detectors {
                return None;
            }
            let detectors = row.dets.keys().cloned().collect::<Vec<_>>();
            let mut units = row
                .findings
                .iter()
                .flat_map(finding_units)
                .collect::<Vec<_>>();
            units.sort();
            units.dedup();
            let score = row
                .tiers
                .values()
                .map(|tier| convergence::tier_weight(*tier))
                .sum();
            let fat_union = fat_union(&entity.kind, &entity.token, &row.findings);
            let mut sites = row
                .findings
                .iter()
                .flat_map(convergence::locations)
                .collect::<Vec<_>>();
            let mut seen_sites = HashSet::new();
            sites.retain(|site| seen_sites.insert(site.clone()));
            sites.truncate(8);
            Some(Cluster {
                kind: entity.kind.clone(),
                token: entity.token.clone(),
                n_detectors: detectors.len(),
                support: row.findings.len(),
                scatter: units.len(),
                score,
                fat_union,
                fix: if fat_union {
                    FAT_UNION_FIX.to_string()
                } else {
                    fix_shape(&detectors, &entity.kind)
                },
                detectors,
                sites,
            })
        })
        .collect::<Vec<_>>();
    clusters.sort_by(|left, right| {
        right
            .n_detectors
            .cmp(&left.n_detectors)
            .then_with(|| right.score.cmp(&left.score))
            .then_with(|| right.scatter.cmp(&left.scatter))
            .then_with(|| left.kind.cmp(&right.kind))
            .then_with(|| left.token.cmp(&right.token))
    });
    clusters
}

pub fn entities(finding: &Value) -> Vec<Entity> {
    let mut out = Vec::new();
    for key in TUPLE_FIELDS {
        let values = rv::array(finding, key);
        if values.len() < 2 {
            continue;
        }
        let mut members = values
            .iter()
            .map(|value| rv::string(Some(value)))
            .collect::<Vec<_>>();
        members.sort();
        out.push(Entity {
            kind: "tuple".to_string(),
            token: truncate_chars(&members.join(" | "), 160),
        });
    }
    for key in NAME_ARRAY_FIELDS {
        for value in rv::array(finding, key) {
            for token in tokens(&rv::string(Some(value))) {
                out.push(Entity {
                    kind: "name".to_string(),
                    token,
                });
            }
        }
    }
    for key in NAME_STR_FIELDS {
        if let Some(value) = rv::get(finding, key) {
            for token in tokens(&rv::string(Some(value))) {
                out.push(Entity {
                    kind: "name".to_string(),
                    token,
                });
            }
        }
    }
    let mut seen = HashSet::new();
    out.retain(|entity| seen.insert((entity.kind.clone(), entity.token.clone())));
    out
}

pub fn tokens(value: &str) -> Vec<String> {
    static TOKEN_RE: OnceLock<Regex> = OnceLock::new();
    let re = TOKEN_RE.get_or_init(|| Regex::new(r"[A-Za-z_][A-Za-z0-9_]*[?!=]?").unwrap());
    let mut out = re
        .find_iter(value)
        .filter_map(|mat| {
            let token = mat.as_str().trim_end_matches(['?', '!', '=']).to_string();
            if token.len() < 2 || STOPWORDS.contains(&token.as_str()) {
                None
            } else {
                Some(token)
            }
        })
        .collect::<Vec<_>>();
    out.sort();
    out.dedup();
    out
}

pub fn finding_units(finding: &Value) -> Vec<(String, String)> {
    convergence::locations(finding)
        .into_iter()
        .filter_map(|loc| {
            let (file, method, _) = convergence::parse_loc(&loc);
            match (file, method) {
                (Some(file), Some(method)) => Some((file, method)),
                _ => None,
            }
        })
        .collect()
}

fn fat_union(kind: &str, token: &str, findings: &[Value]) -> bool {
    static CONST_RE: OnceLock<Regex> = OnceLock::new();
    let re = CONST_RE.get_or_init(|| Regex::new(r"\A(::)?[A-Z]\w*(::[A-Z]\w*)*\z").unwrap());
    if kind != "tuple" {
        return false;
    }
    if !findings
        .iter()
        .any(|finding| rv::kind_is(finding, "kind", "case_dispatch"))
    {
        return false;
    }
    let members = token.split(" | ").collect::<Vec<_>>();
    members.len() >= 2 && members.iter().all(|member| re.is_match(member))
}

fn fix_shape(detectors: &[String], kind: &str) -> String {
    let detectors = detectors.iter().map(String::as_str).collect::<HashSet<_>>();
    let shapes: &[(&[&str], &str, &str)] = &[
        (
            &["Neglected Updates", "Derived-State Staleness"],
            "name",
            "single-source this state (one stamp, or recompute on write) -- the invariant-#16 desync shape",
        ),
        (
            &["Broken Protocols"],
            "any",
            "pair the protocol (RAII / ensure); the unpaired site is the deviant",
        ),
        (
            &[
                "Missing Abstractions",
                "Reification Misses",
                "Semantic Predicate Aliases",
                "Exact Predicate Aliases",
            ],
            "any",
            "reify ONE named predicate/decision and call it everywhere",
        ),
        (
            &["Missing Abstractions", "Neglected Conditions", "Neglected Path Conditions"],
            "tuple",
            "extract the decision; if it dispatches a closed set, consider product-vs-sum (fat-union -> nil-kill)",
        ),
        (
            &["Decision Pressure"],
            "any",
            "tighten the contract once; the scattered defensive guards collapse (cross-proc -> nil-kill)",
        ),
    ];
    for (titles, want_kind, label) in shapes {
        if *want_kind != "any" && *want_kind != kind {
            continue;
        }
        if titles.iter().any(|title| detectors.contains(title)) {
            return (*label).to_string();
        }
    }
    "converging structural debt -- resolve once at the named entity".to_string()
}

fn truncate_chars(value: &str, max: usize) -> String {
    value.chars().take(max).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn equivalent_state_tokens_collapse_to_same_name() {
        assert_eq!(tokens("@storage="), vec!["storage"]);
        assert_eq!(tokens(".storage"), vec!["storage"]);
    }

    #[test]
    fn tuple_fields_share_the_same_token() {
        let left = entities(&json!({"members": ["b", "a"]}));
        let right = entities(&json!({"guards": ["a", "b"]}));
        assert_eq!(left, right);
    }
}
