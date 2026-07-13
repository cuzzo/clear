use super::{branches, loops, ControlFlowFacts, ControlFlowProfile, NodeEffect, Place};
use crate::ast::{self, Child, Node};
use crate::syntax::{local_flow::MethodSummary, Span};
use std::collections::{BTreeMap, BTreeSet};

const READ_TYPES: &[&str] = &["LVAR", "DVAR", "IVAR", "CVAR", "GVAR"];
const WRITE_TYPES: &[&str] = &["LASGN", "DASGN", "IASGN", "CVASGN", "GASGN"];
const CALL_TYPES: &[&str] = &[
    "CALL", "FCALL", "VCALL", "OPCALL", "QCALL", "ATTRASGN", "SUPER", "ZSUPER", "YIELD",
];
const NESTED_SCOPE_TYPES: &[&str] = &["CLASS", "MODULE", "DEFN", "DEFS", "LAMBDA"];

#[derive(Default)]
struct RawEffect {
    reads: BTreeSet<String>,
    writes: BTreeSet<String>,
    mutations: BTreeSet<String>,
    write_type_hints: BTreeMap<String, String>,
    unknown_call: bool,
    complete: bool,
    unknown_reasons: Vec<String>,
}

pub(crate) fn extract(
    methods: &[MethodSummary],
    profile: &ControlFlowProfile,
    facts: &mut ControlFlowFacts,
) {
    let mut raw_by_node = BTreeMap::new();
    let mut all_names = BTreeMap::<(String, String, String), BTreeSet<String>>::new();
    let mut declaration_spans = BTreeMap::<(String, String, String, String), Span>::new();

    for node in &facts.nodes {
        let method = methods.iter().find(|method| {
            method.file == node.file
                && method.function_identity_matches(&node.owner, &node.function)
        });
        let mut raw = RawEffect {
            complete: true,
            ..RawEffect::default()
        };

        if !matches!(node.kind.as_str(), "entry" | "exit") {
            match method.and_then(|method| find_by_span(&method.node, node.span)) {
                Some(syntax_node) => {
                    let target = effect_target(syntax_node, &node.role, profile);
                    collect(target, &mut raw);
                }
                None => {
                    raw.complete = false;
                    raw.unknown_reasons
                        .push("normalized node span was not found".to_string());
                }
            }
        }

        if node.role == "linear_statement" {
            if let Some(method) = method {
                if let Some(statement) = method
                    .statements
                    .iter()
                    .find(|statement| statement.span == node.span)
                {
                    raw.reads.extend(statement.reads.iter().cloned());
                    raw.writes.extend(statement.writes.iter().cloned());
                }
            }
        }

        let function_key = (node.file.clone(), node.owner.clone(), node.function.clone());
        let names = all_names.entry(function_key).or_default();
        names.extend(raw.reads.iter().cloned());
        names.extend(raw.writes.iter().cloned());
        for name in &raw.writes {
            declaration_spans
                .entry((
                    node.file.clone(),
                    node.owner.clone(),
                    node.function.clone(),
                    name.clone(),
                ))
                .or_insert(node.span);
        }
        raw_by_node.insert(node.id.clone(), raw);
    }

    let mut place_id_by_name = BTreeMap::new();
    for ((file, owner, function), names) in all_names {
        for name in names {
            let kind = place_kind(&name);
            let id = format!("place:{owner}#{function}:{kind}:{name}");
            let declaration_span = declaration_spans
                .get(&(file.clone(), owner.clone(), function.clone(), name.clone()))
                .copied()
                .or_else(|| {
                    methods
                        .iter()
                        .find(|method| {
                            method.file == file
                                && method.function_identity_matches(&owner, &function)
                        })
                        .map(|method| method.span)
                })
                .unwrap_or([0, 0, 0, 0]);
            place_id_by_name.insert(
                (file.clone(), owner.clone(), function.clone(), name.clone()),
                id.clone(),
            );
            facts.places.push(Place {
                id,
                file: file.clone(),
                function: function.clone(),
                owner: owner.clone(),
                kind: kind.to_string(),
                name,
                declaration_span,
            });
        }
    }

    for node in &facts.nodes {
        let raw = raw_by_node.remove(&node.id).unwrap_or_default();
        let id_for = |name: &String| {
            place_id_by_name
                .get(&(
                    node.file.clone(),
                    node.owner.clone(),
                    node.function.clone(),
                    name.clone(),
                ))
                .cloned()
                .unwrap_or_else(|| {
                    format!("place:{}#{}:unknown:{}", node.owner, node.function, name)
                })
        };
        facts.effects.push(NodeEffect {
            node_id: node.id.clone(),
            file: node.file.clone(),
            function: node.function.clone(),
            owner: node.owner.clone(),
            reads: raw.reads.iter().map(id_for).collect(),
            writes: raw.writes.iter().map(id_for).collect(),
            mutations: raw.mutations.iter().map(id_for).collect(),
            write_type_hints: raw
                .write_type_hints
                .into_iter()
                .map(|(name, hint)| (id_for(&name), hint))
                .collect(),
            unknown_call: raw.unknown_call,
            complete: raw.complete,
            unknown_reasons: raw.unknown_reasons,
        });
    }

    facts.places.sort();
    facts
        .effects
        .sort_by(|left, right| left.node_id.cmp(&right.node_id));
}

trait MethodIdentity {
    fn function_identity_matches(&self, owner: &str, function: &str) -> bool;
}

impl MethodIdentity for MethodSummary {
    fn function_identity_matches(&self, owner: &str, function: &str) -> bool {
        self.owner == owner && self.name == function
    }
}

fn effect_target<'a>(node: &'a Node, role: &str, profile: &ControlFlowProfile) -> &'a Node {
    if role.ends_with("_condition") {
        if let Some(branch) = branches::from_node(node) {
            return branch.condition.unwrap_or(node);
        }
    }
    if role.contains("loop") {
        if let Some(cfg_loop) = loops::from_node(node, profile) {
            return cfg_loop.condition.unwrap_or(node);
        }
    }
    if role == "case_dispatch" && node.r#type == "CASE" {
        return node.children.first().and_then(ast::node).unwrap_or(node);
    }
    node
}

fn collect(node: &Node, effect: &mut RawEffect) {
    if NESTED_SCOPE_TYPES.contains(&node.r#type.as_str()) {
        return;
    }
    if WRITE_TYPES.contains(&node.r#type.as_str()) {
        if let Some(name) = node_name(node) {
            effect.writes.insert(name.clone());
            if !matches!(node.r#type.as_str(), "LASGN" | "DASGN") {
                effect.mutations.insert(name.clone());
            }
            if let Some(rhs) = node.children.iter().skip(1).find_map(ast::node) {
                if let Some(hint) = value_type_hint(rhs) {
                    effect.write_type_hints.insert(name, hint.to_string());
                }
                collect(rhs, effect);
            }
        } else {
            effect.complete = false;
            effect
                .unknown_reasons
                .push(format!("{} target has no normalized name", node.r#type));
        }
        return;
    }
    if READ_TYPES.contains(&node.r#type.as_str()) {
        if let Some(name) = node_name(node) {
            effect.reads.insert(name);
        }
    }
    if CALL_TYPES.contains(&node.r#type.as_str()) {
        effect.unknown_call = true;
    }
    for child in node.children.iter().filter_map(ast::node) {
        collect(child, effect);
    }
}

fn value_type_hint(node: &Node) -> Option<&'static str> {
    match node.r#type.as_str() {
        "NIL" => Some("nil"),
        "STR" | "STRING" | "DSTR" => Some("string"),
        "ARRAY" | "LIST" => Some("array"),
        "HASH" | "DICTIONARY" => Some("hash"),
        "TRUE" | "FALSE" => Some("boolean"),
        "LIT" => match node.children.first() {
            Some(Child::Integer(_)) => Some("integer"),
            Some(Child::Bool(_)) => Some("boolean"),
            Some(Child::Symbol(_)) => Some("symbol"),
            _ => None,
        },
        _ => None,
    }
}

fn node_name(node: &Node) -> Option<String> {
    match node.children.first() {
        Some(Child::String(name)) | Some(Child::Symbol(name)) if !name.is_empty() => {
            Some(name.clone())
        }
        _ => None,
    }
}

fn place_kind(name: &str) -> &'static str {
    if name.starts_with("@@") {
        "class_field"
    } else if name.starts_with('@') {
        "instance_field"
    } else if name.starts_with('$') {
        "global"
    } else {
        "local"
    }
}

fn find_by_span(node: &Node, span: Span) -> Option<&Node> {
    if [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ] == span
    {
        return Some(node);
    }
    node.children
        .iter()
        .filter_map(ast::node)
        .find_map(|child| find_by_span(child, span))
}
