use crate::decomplex::syntax::{Document, Span};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, VecDeque};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ScopedStateRestorationFinding {
    pub at: String,
    pub file: String,
    pub method: String,
    pub owner: String,
    pub field: String,
    pub classification: String,
    pub confidence: String,
    pub temporary_value: String,
    pub restoration_values: Vec<String>,
    pub bypass_exit: Option<String>,
    pub calls_inside_scope: Vec<String>,
    pub score: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

pub fn scan_documents(documents: &[Document]) -> Vec<ScopedStateRestorationFinding> {
    let mut findings = documents.iter().flat_map(scan_document).collect::<Vec<_>>();
    findings.sort_by(|left, right| {
        right
            .score
            .cmp(&left.score)
            .then_with(|| left.file.cmp(&right.file))
            .then_with(|| left.method.cmp(&right.method))
            .then_with(|| left.field.cmp(&right.field))
    });
    findings
}

fn scan_document(document: &Document) -> Vec<ScopedStateRestorationFinding> {
    let nodes = document
        .control_flow_nodes
        .iter()
        .map(|node| (node.id.clone(), node))
        .collect::<BTreeMap<_, _>>();
    let effects = document
        .node_effects
        .iter()
        .map(|effect| (effect.node_id.clone(), effect))
        .collect::<BTreeMap<_, _>>();
    let mut successors = BTreeMap::<String, Vec<String>>::new();
    for edge in &document.control_flow_edges {
        successors
            .entry(edge.from.clone())
            .or_default()
            .push(edge.to.clone());
    }
    let state_places = document
        .places
        .iter()
        .filter(|place| {
            matches!(
                place.kind.as_str(),
                "instance_field" | "class_field" | "global"
            )
        })
        .collect::<Vec<_>>();
    let mut out = Vec::new();

    for place in state_places {
        let writes = effects
            .values()
            .filter_map(|effect| {
                direct_write_value(&nodes, &effects, &effect.node_id, &place.id)
                    .map(|value| (effect.node_id.clone(), value.clone()))
            })
            .collect::<Vec<_>>();
        for (start_id, temporary_value) in writes {
            if !has_scoped_call_before_restore(
                &start_id,
                &temporary_value,
                &place.id,
                &nodes,
                &effects,
                &successors,
            ) {
                continue;
            }
            let reachable = reachable_nodes(&start_id, &successors);
            let restoration_values = reachable
                .iter()
                .filter_map(|node_id| {
                    direct_write_value(&nodes, &effects, node_id, &place.id)
                        .filter(|value| value.as_str() != temporary_value.as_str())
                })
                .collect::<BTreeSet<_>>();
            if restoration_values.is_empty() {
                continue;
            }

            let mut queue = successors
                .get(&start_id)
                .cloned()
                .unwrap_or_default()
                .into_iter()
                .collect::<VecDeque<_>>();
            let mut seen = BTreeSet::new();
            let mut bypass_exit = None;
            let mut calls_inside_scope = BTreeSet::new();
            let mut restore_nodes = BTreeSet::new();
            while let Some(node_id) = queue.pop_front() {
                if !seen.insert(node_id.clone()) {
                    continue;
                }
                if let Some(value) = direct_write_value(&nodes, &effects, &node_id, &place.id) {
                    if value.as_str() != temporary_value.as_str() {
                        restore_nodes.insert(node_id);
                        continue;
                    }
                }
                if let Some(node) = nodes.get(&node_id) {
                    if node.kind == "exit" {
                        bypass_exit = Some(node.id.clone());
                        continue;
                    }
                    if effects
                        .get(&node_id)
                        .is_some_and(|effect| effect.unknown_call)
                    {
                        calls_inside_scope
                            .insert(format!("{}:{}:{}", node.file, node.function, node.line));
                    }
                }
                queue.extend(successors.get(&node_id).into_iter().flatten().cloned());
            }

            let protected_by_cleanup = restore_nodes.iter().any(|node_id| {
                nodes.get(node_id).is_some_and(|node| {
                    node.role.contains("ensure") || node.role.contains("finally")
                })
            });
            let (classification, confidence, score) = if bypass_exit.is_some() {
                ("restoration_bypass", "high", 10)
            } else if !calls_inside_scope.is_empty() && !protected_by_cleanup {
                ("unprotected_restoration_risk", "medium", 5)
            } else {
                continue;
            };
            let Some(start) = nodes.get(&start_id) else {
                continue;
            };
            let mut sites = vec![format!("{}:{}:{}", start.file, start.function, start.line)];
            let mut spans = BTreeMap::from([(sites[0].clone(), start.span)]);
            for restore_id in &restore_nodes {
                if let Some(node) = nodes.get(restore_id) {
                    let site = format!("{}:{}:{}", node.file, node.function, node.line);
                    spans.insert(site.clone(), node.span);
                    sites.push(site);
                }
            }
            sites.sort();
            sites.dedup();
            out.push(ScopedStateRestorationFinding {
                at: format!("{}:{}:{}", start.file, start.function, start.line),
                file: start.file.clone(),
                method: start.function.clone(),
                owner: start.owner.clone(),
                field: place.name.clone(),
                classification: classification.to_string(),
                confidence: confidence.to_string(),
                temporary_value,
                restoration_values: restoration_values.into_iter().collect(),
                bypass_exit,
                calls_inside_scope: calls_inside_scope.into_iter().collect(),
                score,
                sites,
                spans,
            });
        }
    }
    out
}

fn has_scoped_call_before_restore(
    start_id: &str,
    temporary_value: &str,
    place_id: &str,
    nodes: &BTreeMap<String, &crate::decomplex::syntax::cfg::ControlFlowNode>,
    effects: &BTreeMap<String, &crate::decomplex::syntax::cfg::NodeEffect>,
    successors: &BTreeMap<String, Vec<String>>,
) -> bool {
    let mut queue = successors
        .get(start_id)
        .into_iter()
        .flatten()
        .cloned()
        .map(|node_id| (node_id, false))
        .collect::<VecDeque<_>>();
    let mut seen = BTreeSet::new();
    while let Some((node_id, saw_call)) = queue.pop_front() {
        if !seen.insert((node_id.clone(), saw_call)) {
            continue;
        }
        if let Some(value) = direct_write_value(nodes, effects, &node_id, place_id) {
            if value != temporary_value {
                if saw_call {
                    return true;
                }
                continue;
            }
        }
        let Some(node) = nodes.get(&node_id) else {
            continue;
        };
        let unknown_call = effects
            .get(&node_id)
            .is_some_and(|effect| effect.unknown_call);
        // A call made by a branch/loop condition precedes entry into the
        // apparent scope. Treating it as work protected by the later write
        // reverses common `normal -> temporary -> normal` protocols.
        if unknown_call && matches!(node.kind.as_str(), "branch" | "loop") {
            continue;
        }
        let saw_call = saw_call || unknown_call;
        queue.extend(
            successors
                .get(&node_id)
                .into_iter()
                .flatten()
                .cloned()
                .map(|next| (next, saw_call)),
        );
    }
    false
}

fn direct_write_value(
    nodes: &BTreeMap<String, &crate::decomplex::syntax::cfg::ControlFlowNode>,
    effects: &BTreeMap<String, &crate::decomplex::syntax::cfg::NodeEffect>,
    node_id: &str,
    place_id: &str,
) -> Option<String> {
    // Branch/callback summary nodes aggregate nested effects. A restoration
    // protocol requires a concrete assignment node, not a transitive summary.
    let node = nodes.get(node_id)?;
    if node.role != "linear_statement" {
        return None;
    }
    effects.get(node_id)?.write_value_hints.get(place_id).cloned()
}

fn reachable_nodes(start: &str, successors: &BTreeMap<String, Vec<String>>) -> BTreeSet<String> {
    let mut out = BTreeSet::new();
    let mut queue = successors
        .get(start)
        .cloned()
        .unwrap_or_default()
        .into_iter()
        .collect::<VecDeque<_>>();
    while let Some(node) = queue.pop_front() {
        if out.insert(node.clone()) {
            queue.extend(successors.get(&node).into_iter().flatten().cloned());
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::decomplex::syntax::{self, Language};
    use std::io::Write;

    fn ruby_document(source: &str) -> Document {
        let mut file = tempfile::Builder::new().suffix(".rb").tempfile().unwrap();
        write!(file, "{source}").unwrap();
        syntax::parse_file(file.path().to_path_buf(), Language::Ruby).unwrap()
    }

    #[test]
    fn separates_proven_bypass_from_unprotected_call_risk() {
        let broken = ruby_document(
            "def parse(flag)\n  @mode = true\n  return if flag\n  consume\n  @mode = false\nend\n",
        );
        let findings = scan_documents(&[broken]);
        assert!(findings.iter().any(|finding| {
            finding.classification == "restoration_bypass" && finding.confidence == "high"
        }));

        let risky =
            ruby_document("def parse\n  @mode = true\n  parse_expression\n  @mode = false\nend\n");
        let findings = scan_documents(&[risky]);
        assert!(findings.iter().any(|finding| {
            finding.classification == "unprotected_restoration_risk"
                && finding.confidence == "medium"
        }));
    }

    #[test]
    fn reports_repeated_scopes_without_inverting_the_baseline_value() {
        let document = ruby_document(
            "def parse\n  @mode = true\n  parse_expression\n  @mode = false\n  @mode = true\n  parse_expression\n  @mode = false\nend\n",
        );
        let findings = scan_documents(&[document]);
        assert_eq!(findings.len(), 2, "{findings:#?}");
        assert!(findings
            .iter()
            .all(|finding| finding.temporary_value == "boolean:true"));
    }
}
