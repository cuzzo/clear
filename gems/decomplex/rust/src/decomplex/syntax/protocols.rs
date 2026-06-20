use super::adapters::base::protocol_method_name;
use super::raw_tree;
use super::{Document, FunctionDef, ProtocolCall, ProtocolMethodEffect, ProtocolMethodPath};
use crate::decomplex::ast::{normalize_text, RawNode};
use std::collections::BTreeSet;

#[derive(Clone)]
pub(crate) struct ProtocolPath {
    pub(crate) calls: Vec<ProtocolCall>,
    pub(crate) terminal: bool,
}

pub(crate) struct RawCallTarget {
    pub(crate) receiver: String,
    pub(crate) message: String,
    pub(crate) arguments: Vec<String>,
}

pub(crate) struct RawCallShape {
    pub(crate) call_kind: &'static str,
    pub(crate) receiver_field: &'static str,
    pub(crate) message_field: &'static str,
    pub(crate) arguments_field: &'static str,
    pub(crate) default_receiver: &'static str,
    pub(crate) argument_list_kind: &'static str,
    pub(crate) message_kinds: &'static [&'static str],
}

pub(crate) struct RawProtocolShape {
    pub(crate) assignment_kinds: &'static [&'static str],
    pub(crate) operator_assignment_kinds: &'static [&'static str],
    pub(crate) local_binding_lhs_kinds: &'static [&'static str],
    pub(crate) local_binding_container_kinds: &'static [&'static str],
    pub(crate) local_binding_name_kinds: &'static [&'static str],
    pub(crate) direct_state_read_kinds: &'static [&'static str],
    pub(crate) nested_boundary_kinds: &'static [&'static str],
    pub(crate) nested_boundary_wrapper_kinds: &'static [&'static str],
    pub(crate) nested_boundary_first_child_kinds: &'static [&'static str],
    pub(crate) method_body_wrapper_kinds: &'static [&'static str],
    pub(crate) method_body_kind: &'static str,
    pub(crate) branch_kinds: &'static [&'static str],
    pub(crate) branch_wrapper_kinds: &'static [&'static str],
    pub(crate) branch_wrapper_first_child_kinds: &'static [&'static str],
    pub(crate) modifier_branch_kinds: &'static [&'static str],
    pub(crate) then_body_kinds: &'static [&'static str],
    pub(crate) else_body_kinds: &'static [&'static str],
    pub(crate) case_kinds: &'static [&'static str],
    pub(crate) case_wrapper_kinds: &'static [&'static str],
    pub(crate) case_wrapper_first_child_kinds: &'static [&'static str],
    pub(crate) case_subject_skip_kinds: &'static [&'static str],
    pub(crate) case_branch_body_kinds: &'static [&'static str],
    pub(crate) statement_body_kinds: &'static [&'static str],
    pub(crate) path_call_kinds: &'static [&'static str],
    pub(crate) path_call_child_kinds: &'static [&'static str],
    pub(crate) ignored_child_kinds: &'static [&'static str],
    pub(crate) terminal_kinds: &'static [&'static str],
}

pub(crate) trait RawProtocolAdapter {
    fn method_body_statements<'a>(&self, body: &'a RawNode) -> Vec<&'a RawNode>;

    fn local_bindings(&self, node: &RawNode) -> Vec<String>;

    fn nested_boundary(&self, node: &RawNode) -> bool;

    fn assignment_parts<'a>(&self, node: &'a RawNode)
        -> Option<(&'a RawNode, Option<&'a RawNode>)>;

    fn operator_assignment_parts<'a>(
        &self,
        node: &'a RawNode,
    ) -> Option<(&'a RawNode, Option<&'a RawNode>)>;

    fn state_target(&self, node: &RawNode, local_names: &BTreeSet<String>) -> Option<String>;

    fn direct_state_read(&self, node: &RawNode) -> Option<String>;

    fn collect_call_state(
        &self,
        node: &RawNode,
        local_names: &BTreeSet<String>,
        reads: &mut BTreeSet<String>,
        writes: &mut BTreeSet<String>,
    );

    fn bare_state_reader(
        &self,
        node: &RawNode,
        parent: Option<&RawNode>,
        local_names: &BTreeSet<String>,
    ) -> Option<String>;

    fn branch_node(&self, node: &RawNode) -> bool;

    fn case_node(&self, node: &RawNode) -> bool;

    fn path_condition<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode>;

    fn then_body<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode>;

    fn else_body<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode>;

    fn case_subject<'a>(&self, node: &'a RawNode) -> Option<&'a RawNode>;

    fn case_branch_bodies<'a>(&self, node: &'a RawNode) -> Vec<&'a RawNode>;

    fn statement_body<'a>(&self, node: &'a RawNode) -> Option<Vec<&'a RawNode>>;

    fn path_child_nodes<'a>(&self, node: &'a RawNode) -> Vec<&'a RawNode>;

    fn internal_call(&self, node: &RawNode, local_names: &BTreeSet<String>) -> Option<String>;

    fn terminal_node(&self, node: &RawNode) -> bool;
}

pub(crate) fn method_effects<A: RawProtocolAdapter>(
    document: &Document,
    adapter: &A,
) -> Vec<ProtocolMethodEffect> {
    document
        .function_defs
        .iter()
        .map(|function_def| {
            let (reads, writes) = method_access(adapter, function_def);
            ProtocolMethodEffect {
                file: function_def.file.clone(),
                owner: function_def.owner.clone(),
                name: protocol_method_name(&function_def.name),
                line: function_def.line,
                reads,
                writes,
            }
        })
        .collect()
}

pub(crate) fn call_paths<A: RawProtocolAdapter>(
    document: &Document,
    adapter: &A,
) -> Vec<ProtocolMethodPath> {
    document
        .function_defs
        .iter()
        .flat_map(|function_def| {
            let statements = adapter.method_body_statements(&function_def.body);
            let local_names = local_names(adapter, function_def, &statements);
            paths_for_statements(adapter, &statements, &local_names)
                .into_iter()
                .map(|path| ProtocolMethodPath {
                    file: function_def.file.clone(),
                    owner: function_def.owner.clone(),
                    name: protocol_method_name(&function_def.name),
                    line: function_def.line,
                    calls: path.calls,
                })
                .collect::<Vec<_>>()
        })
        .collect()
}

pub(crate) fn raw_call_target(node: &RawNode, shape: &RawCallShape) -> Option<RawCallTarget> {
    if node.kind != shape.call_kind {
        return None;
    }
    let receiver = raw_tree::child_by_field(node, shape.receiver_field)
        .map(|child| normalize_text(&child.text));
    let method = raw_tree::child_by_field(node, shape.message_field)
        .map(|child| child.text.clone())
        .or_else(|| {
            raw_tree::named_children(node)
                .first()
                .filter(|child| shape.message_kinds.contains(&child.kind.as_str()))
                .map(|child| child.text.clone())
        })?;
    Some(RawCallTarget {
        receiver: receiver.unwrap_or_else(|| shape.default_receiver.to_string()),
        message: method,
        arguments: raw_argument_texts(node, shape.arguments_field, shape.argument_list_kind),
    })
}

pub(crate) fn raw_argument_texts(
    node: &RawNode,
    arguments_field: &str,
    argument_list_kind: &str,
) -> Vec<String> {
    let Some(args) = raw_tree::child_by_field(node, arguments_field).or_else(|| {
        raw_tree::named_children(node)
            .into_iter()
            .find(|child| child.kind == argument_list_kind)
    }) else {
        return Vec::new();
    };
    let values = raw_tree::named_children(args)
        .into_iter()
        .map(|child| normalize_text(&child.text))
        .filter(|text| !text.is_empty())
        .collect::<Vec<_>>();
    if !values.is_empty() {
        return values;
    }
    let text = args
        .text
        .trim()
        .trim_start_matches('(')
        .trim_end_matches(')')
        .to_string();
    text.split(',')
        .map(normalize_text)
        .filter(|item| !item.is_empty())
        .collect()
}

pub(crate) fn assignment_parts<'a, F>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
    flat_assignment: F,
) -> Option<(&'a RawNode, Option<&'a RawNode>)>
where
    F: Fn(&RawNode) -> bool,
{
    if !shape.assignment_kinds.contains(&node.kind.as_str()) && !flat_assignment(node) {
        return None;
    }
    let children = raw_tree::named_children(node);
    let lhs = children.first().copied()?;
    Some((lhs, children.get(1).copied()))
}

pub(crate) fn operator_assignment_parts<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
) -> Option<(&'a RawNode, Option<&'a RawNode>)> {
    if !shape
        .operator_assignment_kinds
        .contains(&node.kind.as_str())
    {
        return None;
    }
    let children = raw_tree::named_children(node);
    let lhs = children.first().copied()?;
    Some((lhs, children.get(1).copied()))
}

pub(crate) fn local_bindings<F>(
    node: &RawNode,
    shape: &RawProtocolShape,
    simple_name: F,
    flat_assignment: fn(&RawNode) -> bool,
) -> Vec<String>
where
    F: Fn(&str) -> bool,
{
    let mut local_names = Vec::new();
    if shape.assignment_kinds.contains(&node.kind.as_str())
        || shape
            .operator_assignment_kinds
            .contains(&node.kind.as_str())
        || flat_assignment(node)
    {
        if let Some(lhs) = raw_tree::named_children(node).first() {
            if shape.local_binding_lhs_kinds.contains(&lhs.kind.as_str()) && simple_name(&lhs.text)
            {
                local_names.push(lhs.text.clone());
            }
        }
    }
    if shape
        .local_binding_container_kinds
        .contains(&node.kind.as_str())
    {
        for child in raw_tree::named_children(node) {
            if shape
                .local_binding_name_kinds
                .contains(&child.kind.as_str())
                && simple_name(&child.text)
            {
                local_names.push(child.text.clone());
            }
        }
    }
    local_names
}

pub(crate) fn function_body_statements<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
    hidden_method_definition: fn(&RawNode) -> bool,
    flat_assignment: fn(&RawNode) -> bool,
    hidden_modifier_branch: fn(&RawNode) -> bool,
    heredoc_body: fn(&[&RawNode]) -> bool,
) -> Vec<&'a RawNode> {
    let Some(body) = method_body_wrapper(node, shape, hidden_method_definition) else {
        return Vec::new();
    };
    let named = raw_tree::named_children(body)
        .into_iter()
        .filter(|child| !shape.ignored_child_kinds.contains(&child.kind.as_str()))
        .collect::<Vec<_>>();
    if named.is_empty() && body.text.trim().is_empty() {
        return Vec::new();
    }
    if branch_node(body, shape, hidden_modifier_branch)
        || case_node(body, shape)
        || flat_assignment(body)
    {
        return vec![body];
    }
    if named.is_empty() || heredoc_body(&named) {
        return vec![body];
    }
    named
}

pub(crate) fn method_body_wrapper<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
    hidden_method_definition: fn(&RawNode) -> bool,
) -> Option<&'a RawNode> {
    if shape
        .method_body_wrapper_kinds
        .contains(&node.kind.as_str())
    {
        return raw_tree::named_children(node)
            .into_iter()
            .rev()
            .find(|child| child.kind == shape.method_body_kind);
    }
    if node.kind == shape.method_body_kind {
        if hidden_method_definition(node) {
            raw_tree::named_children(node)
                .into_iter()
                .rev()
                .find(|child| child.kind == shape.method_body_kind)
        } else {
            Some(node)
        }
    } else {
        None
    }
}

pub(crate) fn nested_boundary(node: &RawNode, shape: &RawProtocolShape) -> bool {
    shape.nested_boundary_kinds.contains(&node.kind.as_str())
        || (shape
            .nested_boundary_wrapper_kinds
            .contains(&node.kind.as_str())
            && raw_tree::first_child_kind(node)
                .as_deref()
                .map(|kind| shape.nested_boundary_first_child_kinds.contains(&kind))
                .unwrap_or(false))
}

pub(crate) fn branch_node(
    node: &RawNode,
    shape: &RawProtocolShape,
    hidden_modifier_branch: fn(&RawNode) -> bool,
) -> bool {
    shape.branch_kinds.contains(&node.kind.as_str())
        || (shape.branch_wrapper_kinds.contains(&node.kind.as_str())
            && raw_tree::first_child_kind(node)
                .as_deref()
                .map(|kind| shape.branch_wrapper_first_child_kinds.contains(&kind))
                .unwrap_or(false))
        || hidden_modifier_branch(node)
}

pub(crate) fn case_node(node: &RawNode, shape: &RawProtocolShape) -> bool {
    shape.case_kinds.contains(&node.kind.as_str())
        || (shape.case_wrapper_kinds.contains(&node.kind.as_str())
            && raw_tree::first_child_kind(node)
                .as_deref()
                .map(|kind| shape.case_wrapper_first_child_kinds.contains(&kind))
                .unwrap_or(false))
}

pub(crate) fn path_condition<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
    hidden_modifier_branch: fn(&RawNode) -> bool,
) -> Option<&'a RawNode> {
    if shape.modifier_branch_kinds.contains(&node.kind.as_str()) || hidden_modifier_branch(node) {
        raw_tree::named_children(node).into_iter().last()
    } else {
        raw_tree::named_children(node).into_iter().next()
    }
}

pub(crate) fn then_body<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
    hidden_modifier_branch: fn(&RawNode) -> bool,
) -> Option<&'a RawNode> {
    if shape.modifier_branch_kinds.contains(&node.kind.as_str()) || hidden_modifier_branch(node) {
        raw_tree::named_children(node).into_iter().next()
    } else {
        raw_tree::named_children(node)
            .into_iter()
            .find(|child| shape.then_body_kinds.contains(&child.kind.as_str()))
            .or_else(|| raw_tree::named_children(node).into_iter().nth(1))
    }
}

pub(crate) fn else_body<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
    hidden_modifier_branch: fn(&RawNode) -> bool,
) -> Option<&'a RawNode> {
    if shape.modifier_branch_kinds.contains(&node.kind.as_str()) || hidden_modifier_branch(node) {
        return None;
    }
    raw_tree::named_children(node)
        .into_iter()
        .find(|child| shape.else_body_kinds.contains(&child.kind.as_str()))
        .or_else(|| raw_tree::named_children(node).into_iter().nth(2))
}

pub(crate) fn case_subject<'a>(node: &'a RawNode, shape: &RawProtocolShape) -> Option<&'a RawNode> {
    raw_tree::named_children(node)
        .first()
        .filter(|first| !shape.case_subject_skip_kinds.contains(&first.kind.as_str()))
        .copied()
}

pub(crate) fn case_branch_bodies<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
) -> Vec<&'a RawNode> {
    raw_tree::named_children(node)
        .into_iter()
        .filter(|child| shape.case_branch_body_kinds.contains(&child.kind.as_str()))
        .collect()
}

pub(crate) fn statement_body<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
) -> Option<Vec<&'a RawNode>> {
    shape
        .statement_body_kinds
        .contains(&node.kind.as_str())
        .then(|| {
            raw_tree::named_children(node)
                .into_iter()
                .filter(|child| !shape.ignored_child_kinds.contains(&child.kind.as_str()))
                .collect()
        })
}

pub(crate) fn path_child_nodes<'a>(
    node: &'a RawNode,
    shape: &RawProtocolShape,
) -> Vec<&'a RawNode> {
    if nested_boundary(node, shape) {
        return Vec::new();
    }
    if shape.path_call_kinds.contains(&node.kind.as_str()) {
        return raw_tree::named_children(node)
            .into_iter()
            .filter(|child| shape.path_call_child_kinds.contains(&child.kind.as_str()))
            .collect();
    }
    if shape.assignment_kinds.contains(&node.kind.as_str())
        || shape
            .operator_assignment_kinds
            .contains(&node.kind.as_str())
    {
        return raw_tree::named_children(node).into_iter().skip(1).collect();
    }
    raw_tree::named_children(node)
        .into_iter()
        .filter(|child| !shape.ignored_child_kinds.contains(&child.kind.as_str()))
        .collect()
}

pub(crate) fn terminal_node(node: &RawNode, shape: &RawProtocolShape) -> bool {
    shape.terminal_kinds.contains(&node.kind.as_str())
}

fn method_access<A: RawProtocolAdapter>(
    adapter: &A,
    function_def: &FunctionDef,
) -> (Vec<String>, Vec<String>) {
    let statements = adapter.method_body_statements(&function_def.body);
    let local_names = local_names(adapter, function_def, &statements);
    let mut reads = BTreeSet::new();
    let mut writes = BTreeSet::new();
    collect_state_access(
        adapter,
        &function_def.body,
        None,
        &local_names,
        &mut reads,
        &mut writes,
        true,
    );
    (reads.into_iter().collect(), writes.into_iter().collect())
}

fn local_names<A: RawProtocolAdapter>(
    adapter: &A,
    function_def: &FunctionDef,
    statements: &[&RawNode],
) -> BTreeSet<String> {
    let mut local_names = BTreeSet::new();
    local_names.extend(function_def.params.iter().cloned());
    for statement in statements {
        collect_local_names(adapter, statement, &mut local_names, true);
    }
    local_names
}

fn collect_local_names<A: RawProtocolAdapter>(
    adapter: &A,
    node: &RawNode,
    local_names: &mut BTreeSet<String>,
    root: bool,
) {
    if !root && adapter.nested_boundary(node) {
        return;
    }
    local_names.extend(adapter.local_bindings(node));
    for child in &node.children {
        collect_local_names(adapter, child, local_names, false);
    }
}

fn collect_state_access<A: RawProtocolAdapter>(
    adapter: &A,
    node: &RawNode,
    parent: Option<&RawNode>,
    local_names: &BTreeSet<String>,
    reads: &mut BTreeSet<String>,
    writes: &mut BTreeSet<String>,
    root: bool,
) {
    if !root && adapter.nested_boundary(node) {
        return;
    }

    if let Some((lhs, rhs)) = adapter.assignment_parts(node) {
        record_write(adapter, lhs, writes, local_names);
        if let Some(rhs) = rhs {
            collect_state_access(adapter, rhs, Some(node), local_names, reads, writes, false);
        }
        return;
    }

    if let Some((lhs, rhs)) = adapter.operator_assignment_parts(node) {
        if let Some(state) = adapter.state_target(lhs, local_names) {
            reads.insert(state.clone());
            writes.insert(state);
        }
        if let Some(rhs) = rhs {
            collect_state_access(adapter, rhs, Some(node), local_names, reads, writes, false);
        }
        return;
    }

    if let Some(read) = adapter.direct_state_read(node) {
        reads.insert(read);
    }
    adapter.collect_call_state(node, local_names, reads, writes);
    if let Some(read) = adapter.bare_state_reader(node, parent, local_names) {
        reads.insert(read);
    }

    for child in &node.children {
        collect_state_access(
            adapter,
            child,
            Some(node),
            local_names,
            reads,
            writes,
            false,
        );
    }
}

fn record_write<A: RawProtocolAdapter>(
    adapter: &A,
    lhs: &RawNode,
    writes: &mut BTreeSet<String>,
    local_names: &BTreeSet<String>,
) {
    if let Some(state) = adapter.state_target(lhs, local_names) {
        writes.insert(state);
    }
}

fn paths_for_statements<A: RawProtocolAdapter>(
    adapter: &A,
    statements: &[&RawNode],
    local_names: &BTreeSet<String>,
) -> Vec<ProtocolPath> {
    let mut paths = vec![empty_path()];
    for statement in statements {
        let statement_paths = paths_for(adapter, statement, local_names);
        paths = combine_path_lists(&paths, &statement_paths);
    }
    paths
}

fn paths_for<A: RawProtocolAdapter>(
    adapter: &A,
    node: &RawNode,
    local_names: &BTreeSet<String>,
) -> Vec<ProtocolPath> {
    if adapter.nested_boundary(node) {
        return vec![empty_path()];
    }
    if adapter.branch_node(node) {
        return branch_paths(adapter, node, local_names);
    }
    if adapter.case_node(node) {
        return case_paths(adapter, node, local_names);
    }

    let children = adapter.path_child_nodes(node);
    let child_paths = children.iter().fold(vec![empty_path()], |paths, child| {
        combine_path_lists(&paths, &paths_for(adapter, child, local_names))
    });
    let Some(mid) = adapter.internal_call(node, local_names) else {
        return terminalize(adapter, node, child_paths);
    };
    let call_path = ProtocolPath {
        calls: vec![raw_call(mid, node)],
        terminal: false,
    };
    terminalize(
        adapter,
        node,
        combine_path_lists(&[call_path], &child_paths),
    )
}

fn terminalize<A: RawProtocolAdapter>(
    adapter: &A,
    node: &RawNode,
    paths: Vec<ProtocolPath>,
) -> Vec<ProtocolPath> {
    if adapter.terminal_node(node) {
        paths
            .into_iter()
            .map(|path| ProtocolPath {
                calls: path.calls,
                terminal: true,
            })
            .collect()
    } else {
        paths
    }
}

fn branch_paths<A: RawProtocolAdapter>(
    adapter: &A,
    node: &RawNode,
    local_names: &BTreeSet<String>,
) -> Vec<ProtocolPath> {
    let condition_paths = adapter
        .path_condition(node)
        .map(|condition| paths_for(adapter, condition, local_names))
        .unwrap_or_else(|| vec![empty_path()]);
    let then_paths = body_paths(adapter, adapter.then_body(node), local_names);
    let else_paths = adapter
        .else_body(node)
        .map(|body| body_paths(adapter, Some(body), local_names))
        .unwrap_or_else(|| vec![empty_path()]);
    let alternatives = then_paths.into_iter().chain(else_paths).collect::<Vec<_>>();
    combine_path_lists(&condition_paths, &alternatives)
}

fn case_paths<A: RawProtocolAdapter>(
    adapter: &A,
    node: &RawNode,
    local_names: &BTreeSet<String>,
) -> Vec<ProtocolPath> {
    let subject_paths = adapter
        .case_subject(node)
        .map(|subject| paths_for(adapter, subject, local_names))
        .unwrap_or_else(|| vec![empty_path()]);
    let branch_paths = adapter
        .case_branch_bodies(node)
        .into_iter()
        .flat_map(|child| body_paths(adapter, Some(child), local_names))
        .collect::<Vec<_>>();
    let alternatives = if branch_paths.is_empty() {
        vec![empty_path()]
    } else {
        branch_paths
    };
    combine_path_lists(&subject_paths, &alternatives)
}

fn body_paths<A: RawProtocolAdapter>(
    adapter: &A,
    node: Option<&RawNode>,
    local_names: &BTreeSet<String>,
) -> Vec<ProtocolPath> {
    let Some(node) = node else {
        return vec![empty_path()];
    };
    if let Some(statements) = adapter.statement_body(node) {
        return paths_for_statements(adapter, &statements, local_names);
    }
    paths_for(adapter, node, local_names)
}

fn raw_call(mid: String, node: &RawNode) -> ProtocolCall {
    ProtocolCall {
        mid,
        file: String::new(),
        owner: String::new(),
        defn: String::new(),
        line: node.span[0],
        span: node.span,
    }
}

fn combine_path_lists(
    left_paths: &[ProtocolPath],
    right_paths: &[ProtocolPath],
) -> Vec<ProtocolPath> {
    let mut out = Vec::new();
    for left in left_paths {
        if left.terminal {
            out.push(left.clone());
            continue;
        }
        for right in right_paths {
            let mut calls = left.calls.clone();
            calls.extend(right.calls.clone());
            out.push(ProtocolPath {
                calls,
                terminal: right.terminal,
            });
        }
    }
    out.into_iter().take(64).collect()
}

fn empty_path() -> ProtocolPath {
    ProtocolPath {
        calls: Vec::new(),
        terminal: false,
    }
}
