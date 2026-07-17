use super::{
    branches, loops, ControlFlowFacts, ControlFlowNode, ControlFlowProfile, NodeEffect, Place,
};
use crate::ast::{self, Child, Node};
use crate::syntax::normalized_behavior::NormalizedLanguageBehavior;
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
    /// Storage class comes from the normalized AST node, never the spelling
    /// of the identifier. A dollar-prefixed closure argument can be lexical;
    /// inferring its class from spelling can merge unrelated closures into
    /// one fictional global.
    place_kinds: BTreeMap<String, String>,
    mutations: BTreeSet<String>,
    write_type_hints: BTreeMap<String, String>,
    write_value_hints: BTreeMap<String, String>,
    write_sources: BTreeMap<String, String>,
    write_call_sources: BTreeMap<String, Span>,
    unknown_call: bool,
    complete: bool,
    unknown_reasons: Vec<String>,
}

impl RawEffect {
    fn record_place(&mut self, name: String, kind: &str) {
        self.place_kinds
            .entry(name)
            .or_insert_with(|| kind.to_string());
    }
}

type GraphKey = (String, String, String, usize, usize);

pub(crate) fn extract(
    methods: &[MethodSummary],
    behavior: &dyn NormalizedLanguageBehavior,
    facts: &mut ControlFlowFacts,
) {
    let profile = behavior.cfg_profile();
    let mut raw_by_node = BTreeMap::new();
    let mut all_places = BTreeMap::<GraphKey, BTreeMap<String, String>>::new();
    let mut declaration_spans = BTreeMap::<(GraphKey, String), Span>::new();
    let mut method_spans = BTreeMap::<GraphKey, Span>::new();
    let mut graph_key_by_node = BTreeMap::new();
    let duplicate_functions = methods
        .iter()
        .fold(BTreeMap::new(), |mut counts, method| {
            *counts
                .entry((
                    method.file.as_str(),
                    method.owner.as_str(),
                    method.name.as_str(),
                ))
                .or_insert(0usize) += 1;
            counts
        })
        .into_iter()
        .filter_map(|(identity, count)| (count > 1).then_some(identity))
        .collect::<BTreeSet<_>>();

    for node in &facts.nodes {
        let method = method_for_node(methods, node)
            .expect("every CFG node must map to its normalized method");
        let graph_key = graph_key(node, method, &duplicate_functions);
        graph_key_by_node.insert(node.id.clone(), graph_key.clone());
        method_spans.insert(graph_key.clone(), method.span);
        let mut raw = RawEffect {
            complete: true,
            ..RawEffect::default()
        };

        if node.kind == "entry" {
            raw.writes.extend(method.params.iter().cloned());
            for name in &method.params {
                raw.record_place(name.clone(), "local");
            }
            for (name, type_name) in &method.param_types {
                raw.writes.insert(name.clone());
                raw.record_place(name.clone(), "local");
                if behavior.declared_type_hint_complete(type_name) {
                    raw.write_type_hints
                        .insert(name.clone(), format!("declared:{type_name}"));
                }
            }
        }

        if !matches!(node.kind.as_str(), "entry" | "exit") {
            match find_syntax_node(&method.node, node.span, &node.role) {
                Some(syntax_node) => {
                    let target = effect_target(syntax_node, &node.role, profile);
                    collect(target, &mut raw);
                    let declared_candidates = raw
                        .writes
                        .iter()
                        .chain(raw.reads.iter())
                        .cloned()
                        .collect::<BTreeSet<_>>();
                    for name in declared_candidates {
                        if raw.write_type_hints.contains_key(&name) {
                            continue;
                        }
                        if let Some(type_name) = behavior.declared_local_type(&target.text, &name) {
                            if behavior.declared_type_hint_complete(&type_name) {
                                raw.writes.insert(name.clone());
                                raw.record_place(name.clone(), "local");
                                raw.write_type_hints
                                    .insert(name, format!("declared:{type_name}"));
                            }
                        }
                    }
                    collect_control_bindings(syntax_node, &node.role, &mut raw);
                }
                None => {
                    raw.complete = false;
                    raw.unknown_reasons
                        .push("normalized node span was not found".to_string());
                }
            }
        }

        let places = all_places.entry(graph_key.clone()).or_default();
        places.extend(
            raw.place_kinds
                .iter()
                .map(|(name, kind)| (name.clone(), kind.clone())),
        );
        for name in &raw.writes {
            declaration_spans
                .entry((graph_key.clone(), name.clone()))
                .or_insert(node.span);
        }
        raw_by_node.insert(node.id.clone(), raw);
    }

    let mut place_id_by_name = BTreeMap::new();
    for (graph_key, places) in all_places {
        let (file, owner, function, discriminator_line, discriminator_column) = &graph_key;
        for (name, kind) in places {
            let id = if *discriminator_line == 0 {
                format!("place:{owner}#{function}:{kind}:{name}")
            } else {
                format!(
                    "place:{owner}#{function}@{discriminator_line}:{discriminator_column}:{kind}:{name}"
                )
            };
            let declaration_span = declaration_spans
                .get(&(graph_key.clone(), name.clone()))
                .copied()
                .or_else(|| method_spans.get(&graph_key).copied())
                .unwrap_or([0, 0, 0, 0]);
            place_id_by_name.insert((graph_key.clone(), name.clone()), id.clone());
            facts.places.push(Place {
                id,
                file: file.clone(),
                function: function.clone(),
                owner: owner.clone(),
                kind,
                name,
                declaration_span,
            });
        }
    }

    for node in &facts.nodes {
        let raw = raw_by_node.remove(&node.id).unwrap_or_default();
        let graph_key = graph_key_by_node
            .get(&node.id)
            .expect("every CFG node has a graph identity");
        let id_for = |name: &String| {
            place_id_by_name
                .get(&(graph_key.clone(), name.clone()))
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
            write_value_hints: raw
                .write_value_hints
                .into_iter()
                .map(|(name, value)| (id_for(&name), value))
                .collect(),
            write_sources: raw
                .write_sources
                .into_iter()
                .map(|(target, source)| (id_for(&target), id_for(&source)))
                .collect(),
            write_call_sources: raw
                .write_call_sources
                .into_iter()
                .map(|(target, producer_span)| (id_for(&target), producer_span))
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

fn method_for_node<'a>(
    methods: &'a [MethodSummary],
    node: &ControlFlowNode,
) -> Option<&'a MethodSummary> {
    methods
        .iter()
        .filter(|method| {
            method.file == node.file
                && method.owner == node.owner
                && method.name == node.function
                && span_contains(method.span, node.span)
        })
        .min_by_key(|method| {
            (
                method.span[2].saturating_sub(method.span[0]),
                method.span[3].saturating_sub(method.span[1]),
            )
        })
}

fn span_contains(outer: Span, inner: Span) -> bool {
    (outer[0], outer[1]) <= (inner[0], inner[1]) && (outer[2], outer[3]) >= (inner[2], inner[3])
}

fn graph_key(
    node: &ControlFlowNode,
    method: &MethodSummary,
    duplicate_functions: &BTreeSet<(&str, &str, &str)>,
) -> GraphKey {
    let duplicate = duplicate_functions.contains(&(
        node.file.as_str(),
        node.owner.as_str(),
        node.function.as_str(),
    ));
    let (line, column) = if duplicate {
        (method.span[0], method.span[1])
    } else {
        (0, 0)
    };
    (
        node.file.clone(),
        node.owner.clone(),
        node.function.clone(),
        line,
        column,
    )
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
    if role == "callback_region" && node.r#type == "ITER" {
        return node.children.first().and_then(ast::node).unwrap_or(node);
    }
    node
}

fn collect_control_bindings(node: &Node, role: &str, effect: &mut RawEffect) {
    if role == "for_loop" && node.r#type == "FOR" {
        if let Some(target) = node.children.first().and_then(ast::node) {
            collect(target, effect);
        }
        return;
    }
    collect_nested_bindings(node, effect);
}

fn collect_scope_bindings(scope: Option<&Node>, effect: &mut RawEffect) {
    let Some(scope) = scope else {
        return;
    };
    let args = if scope.r#type == "SCOPE" {
        scope.children.get(1).and_then(ast::node)
    } else if scope.r#type == "ARGS" {
        Some(scope)
    } else {
        None
    };
    if let Some(args) = args {
        collect(args, effect);
    }
}

fn collect_nested_bindings(node: &Node, effect: &mut RawEffect) {
    if matches!(node.r#type.as_str(), "CLASS" | "MODULE" | "DEFN" | "DEFS") {
        return;
    }
    match node.r#type.as_str() {
        "ITER" => collect_scope_bindings(node.children.get(1).and_then(ast::node), effect),
        "LAMBDA" => collect_scope_bindings(node.children.first().and_then(ast::node), effect),
        _ => {}
    }
    for child in node.children.iter().filter_map(ast::node) {
        collect_nested_bindings(child, effect);
    }
}

fn collect(node: &Node, effect: &mut RawEffect) {
    if NESTED_SCOPE_TYPES.contains(&node.r#type.as_str()) {
        return;
    }
    if WRITE_TYPES.contains(&node.r#type.as_str()) {
        if let Some(name) = node_name(node) {
            effect.writes.insert(name.clone());
            effect.record_place(name.clone(), place_kind_for_node(&node.r#type));
            if !matches!(node.r#type.as_str(), "LASGN" | "DASGN") {
                effect.mutations.insert(name.clone());
            }
            if let Some(rhs) = node.children.iter().skip(1).find_map(ast::node) {
                if let Some(hint) = value_type_hint(rhs) {
                    effect.write_type_hints.insert(name.clone(), hint.to_string());
                    if let Some(value) = literal_value_hint(rhs) {
                        effect.write_value_hints.insert(name, value);
                    }
                } else if let Some(source) = direct_read_name(rhs) {
                    effect.write_sources.insert(name, source);
                } else if let Some(producer_span) = direct_call_result_span(rhs) {
                    effect.write_call_sources.insert(name, producer_span);
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
            effect.reads.insert(name.clone());
            effect.record_place(name, place_kind_for_node(&node.r#type));
        }
    }
    if CALL_TYPES.contains(&node.r#type.as_str()) {
        effect.unknown_call = true;
    }
    for child in node.children.iter().filter_map(ast::node) {
        collect(child, effect);
    }
}

fn literal_value_hint(node: &Node) -> Option<String> {
    match node.r#type.as_str() {
        "NIL" => Some("nil".to_string()),
        "TRUE" => Some("boolean:true".to_string()),
        "FALSE" => Some("boolean:false".to_string()),
        "LIT" => match node.children.first() {
            Some(Child::Bool(value)) => Some(format!("boolean:{value}")),
            Some(Child::Integer(value)) => Some(format!("integer:{value}")),
            Some(Child::Symbol(value)) => Some(format!("symbol:{value}")),
            _ => None,
        },
        _ => None,
    }
}

/// Return a direct normalized call expression through transparent grouping
/// only. Operations, containers, and member projections are not type-
/// preserving assignment edges.
fn direct_call_result_span(node: &Node) -> Option<Span> {
    match node.r#type.as_str() {
        "PAREN" | "BEGIN" | "EXPRESSION_LIST" => {
            let mut children = node.children.iter().filter_map(ast::node);
            let only = children.next()?;
            (children.next().is_none())
                .then(|| direct_call_result_span(only))
                .flatten()
        }
        "CALL" | "QCALL" | "FCALL" | "VCALL" => Some([
            node.first_lineno,
            node.first_column,
            node.last_lineno,
            node.last_column,
        ]),
        _ => None,
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
        "PAREN" | "BEGIN" => {
            let mut children = node.children.iter().filter_map(ast::node);
            let only = children.next()?;
            if children.next().is_none() {
                value_type_hint(only)
            } else {
                None
            }
        }
        _ => None,
    }
}

fn direct_read_name(node: &Node) -> Option<String> {
    if READ_TYPES.contains(&node.r#type.as_str()) {
        return node_name(node);
    }
    if matches!(node.r#type.as_str(), "PAREN" | "BEGIN") {
        let mut children = node.children.iter().filter_map(ast::node);
        let only = children.next()?;
        if children.next().is_none() {
            return direct_read_name(only);
        }
    }
    None
}

fn node_name(node: &Node) -> Option<String> {
    match node.children.first() {
        Some(Child::String(name)) | Some(Child::Symbol(name)) if !name.is_empty() => {
            Some(name.clone())
        }
        _ => None,
    }
}

fn place_kind_for_node(node_type: &str) -> &'static str {
    match node_type {
        "IVAR" | "IASGN" => "instance_field",
        "CVAR" | "CVASGN" => "class_field",
        "GVAR" | "GASGN" => "global",
        _ => "local",
    }
}

fn find_by_span(node: &Node, span: Span, prefer_innermost: bool) -> Option<&Node> {
    if prefer_innermost {
        if let Some(match_) = node
            .children
            .iter()
            .filter_map(ast::node)
            .find_map(|child| find_by_span(child, span, true))
        {
            return Some(match_);
        }
    }
    if [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ] == span
    {
        return Some(node);
    }
    if prefer_innermost {
        None
    } else {
        node.children
            .iter()
            .filter_map(ast::node)
            .find_map(|child| find_by_span(child, span, false))
    }
}

fn find_syntax_node<'a>(node: &'a Node, span: Span, role: &str) -> Option<&'a Node> {
    let preferred_kind = match role {
        "iterator_loop" => Some("ITER"),
        "for_loop" => Some("FOR"),
        "while_loop" => Some("WHILE"),
        "until_loop" => Some("UNTIL"),
        "case_dispatch" => Some("CASE"),
        "callback_region" => Some("ITER"),
        _ => None,
    };
    preferred_kind
        .and_then(|kind| find_by_span_and_kind(node, span, kind))
        .or_else(|| find_by_span(node, span, role == "linear_statement"))
}

fn find_by_span_and_kind<'a>(node: &'a Node, span: Span, kind: &str) -> Option<&'a Node> {
    if node.r#type == kind
        && [
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
        .find_map(|child| find_by_span_and_kind(child, span, kind))
}
