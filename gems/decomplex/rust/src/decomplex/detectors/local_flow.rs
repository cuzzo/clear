use crate::decomplex::ast::{self, Child, Node, RawNode, Span};
use crate::decomplex::syntax::adapters::{language_profile, LanguageProfile};
use crate::decomplex::syntax::{self, Document, FunctionDef, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct LocalFlowRow {
    pub summaries: Vec<MethodSummary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct MethodSummary {
    pub id: String,
    pub owner: String,
    pub name: String,
    pub file: String,
    pub line: usize,
    pub span: Span,
    #[serde(skip_serializing)]
    pub node: Node,
    #[serde(skip_serializing)]
    pub raw_node: Option<RawNode>,
    pub statements: Vec<Statement>,
    pub boundaries: Vec<Boundary>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Statement {
    pub index: usize,
    pub line: usize,
    pub end_line: usize,
    pub span: Span,
    pub source: String,
    pub reads: BTreeSet<String>,
    pub writes: BTreeSet<String>,
    pub dependencies: Vec<(String, String)>,
    pub co_uses: Vec<(String, String)>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct Boundary {
    pub before_index: usize,
    pub after_index: usize,
    pub line: usize,
    pub kind: String,
    pub text: String,
}

const OWNER_TYPES: &[&str] = &["CLASS", "MODULE"];
const METHOD_TYPES: &[&str] = &["DEFN", "DEFS"];
const SKIP_NESTED_TYPES: &[&str] = &["CLASS", "MODULE", "DEFN", "DEFS", "LAMBDA"];
const LOCAL_READ_TYPES: &[&str] = &["LVAR", "DVAR"];
const LOCAL_WRITE_TYPES: &[&str] = &["LASGN", "DASGN"];
const STATEMENT_CONTAINER_TYPES: &[&str] = &[
    "BLOCK",
    "COMPOUND_STATEMENT",
    "DECLARATION_LIST",
    "FUNCTION_BODY",
    "HASH",
    "STATEMENTS",
];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<MethodSummary>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> Vec<MethodSummary> {
    let mut out = Vec::new();
    for document in documents {
        let normalized = normalized_local_methods(document);
        if document.language != Language::Ruby {
            let raw = raw_local_methods(document);
            let raw_keys: BTreeSet<_> = raw.iter().map(method_summary_key).collect();
            out.extend(raw);
            out.extend(
                normalized
                    .into_iter()
                    .filter(|summary| !raw_keys.contains(&method_summary_key(summary))),
            );
            continue;
        }

        out.extend(normalized);
    }
    out
}

fn normalized_local_methods(document: &Document) -> Vec<MethodSummary> {
    let mut detector = LocalFlow::new(
        document.file.clone(),
        document.lines.clone(),
        document.language,
        method_metadata(document),
    );
    detector.scan(&document.normalized_root)
}

fn method_summary_key(summary: &MethodSummary) -> (String, String, usize) {
    (summary.file.clone(), summary.id.clone(), summary.line)
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct MethodMetadata {
    owner: String,
    name: String,
    params: BTreeSet<String>,
}

fn raw_local_methods(document: &Document) -> Vec<MethodSummary> {
    let profile = language_profile(document.language);
    document
        .function_defs
        .iter()
        .map(|function| raw_method_summary(document, profile, function))
        .collect()
}

fn raw_method_summary(
    document: &Document,
    profile: &dyn LanguageProfile,
    function: &FunctionDef,
) -> MethodSummary {
    let statement_nodes = raw_function_body_statements(&function.body, profile);
    let local_names = raw_local_names(function, &statement_nodes, profile);
    let statements: Vec<_> = statement_nodes
        .iter()
        .enumerate()
        .map(|(index, statement)| raw_statement_summary(statement, index, &local_names, profile))
        .collect();
    let owner = local_flow_owner(&document.file, &function.owner);

    MethodSummary {
        id: format!("{}#{}", owner, function.name),
        owner,
        name: function.name.clone(),
        file: function.file.clone(),
        line: function.line,
        span: function.span,
        node: normalized_node_for_span(&document.normalized_root, function.span)
            .cloned()
            .unwrap_or_else(|| fallback_node_from_raw(&function.body)),
        raw_node: Some(function.body.clone()),
        boundaries: raw_structural_boundaries(document, &statements),
        statements,
    }
}

fn raw_function_body_statements<'a>(
    node: &'a RawNode,
    profile: &dyn LanguageProfile,
) -> Vec<&'a RawNode> {
    let body = raw_function_body_node(node, profile);
    let Some(body) = body else {
        return Vec::new();
    };

    let mut named = raw_named_children(body)
        .into_iter()
        .filter(|child| !raw_comment_node(child))
        .collect::<Vec<_>>();
    if named.len() == 1
        && profile
            .nested_statement_wrapper_node_kinds()
            .contains(&named[0].kind.as_str())
    {
        if raw_branch_node(named[0], profile) {
            return vec![named[0]];
        }
        named = raw_named_children(named[0])
            .into_iter()
            .filter(|child| !raw_comment_node(child))
            .collect();
    }
    if named.is_empty() && body.text.trim().is_empty() {
        return Vec::new();
    }
    if raw_branch_node(body, profile) || raw_assignment_statement(body, profile) || named.is_empty()
    {
        return vec![body];
    }
    named
}

fn raw_function_body_node<'a>(
    node: &'a RawNode,
    profile: &dyn LanguageProfile,
) -> Option<&'a RawNode> {
    raw_named_children(node).into_iter().rev().find(|child| {
        profile
            .function_body_node_kinds()
            .contains(&child.kind.as_str())
    })
}

fn raw_local_names(
    function: &FunctionDef,
    statements: &[&RawNode],
    profile: &dyn LanguageProfile,
) -> BTreeSet<String> {
    let mut names: BTreeSet<String> = function.params.iter().cloned().collect();
    if let Some(receiver) = raw_function_receiver_name(&function.body, profile) {
        names.insert(receiver);
    }
    for statement in statements {
        names.extend(raw_local_writes(statement, profile));
    }
    names
}

fn raw_function_receiver_name(node: &RawNode, profile: &dyn LanguageProfile) -> Option<String> {
    if !profile
        .method_receiver_node_kinds()
        .contains(&node.kind.as_str())
    {
        return None;
    }
    let receiver_params = raw_named_children(node).into_iter().find(|child| {
        profile
            .parameter_list_node_kinds()
            .contains(&child.kind.as_str())
    })?;
    let receiver = raw_named_children(receiver_params)
        .into_iter()
        .find(|child| {
            profile
                .receiver_parameter_node_kinds()
                .contains(&child.kind.as_str())
        })?;
    let name = raw_named_children(receiver).into_iter().find(|child| {
        profile
            .first_argument_receiver_name_node_kinds()
            .contains(&child.kind.as_str())
    })?;
    raw_local_identifier_text(name, profile)
}

fn raw_statement_summary(
    node: &RawNode,
    index: usize,
    local_names: &BTreeSet<String>,
    profile: &dyn LanguageProfile,
) -> Statement {
    let writes = raw_local_writes(node, profile);
    let reads = raw_local_reads(node, local_names, profile);
    Statement {
        index,
        line: node.span[0],
        end_line: node.span[2],
        span: node.span,
        source: profile.normalize_source_text(&node.text),
        dependencies: raw_assignment_dependencies(node, local_names, profile),
        co_uses: co_use_pairs(&reads),
        reads,
        writes,
    }
}

fn raw_local_reads(
    node: &RawNode,
    local_names: &BTreeSet<String>,
    profile: &dyn LanguageProfile,
) -> BTreeSet<String> {
    if raw_nested_local_scope(node, profile) {
        return BTreeSet::new();
    }

    let mut reads = Vec::new();
    raw_walk_local(node, None, node, profile, &mut |child, parent| {
        let Some(name) = raw_local_identifier_text(child, profile) else {
            return;
        };
        if local_names.contains(&name)
            && !raw_local_write_node(child, parent, profile)
            && !raw_assignment_lhs_read_in_tree(node, child, profile)
            && !raw_python_import_name(parent, profile)
            && !raw_python_with_alias_read(child, parent, profile)
            && !raw_declaration_name_in_tree(node, child, profile)
            && !raw_declaration_name(child, parent, profile)
            && !raw_member_name(child, parent, profile)
            && !raw_keyed_element_key(child, parent, profile)
        {
            reads.push(name);
        }
    });
    reads.into_iter().collect()
}

fn raw_local_writes(node: &RawNode, profile: &dyn LanguageProfile) -> BTreeSet<String> {
    if raw_nested_local_scope(node, profile) {
        return BTreeSet::new();
    }

    let source = profile.normalize_source_text(&node.text);
    let textual_writes_allowed = raw_assignment_statement(node, profile)
        || profile
            .local_declaration_node_kinds()
            .contains(&node.kind.as_str());
    let mut writes = if !textual_writes_allowed {
        Vec::new()
    } else if profile.language() == Language::Python {
        python_textual_local_writes(&source)
    } else {
        textual_local_writes(&source)
    };
    if profile.language() == Language::Python {
        writes.extend(raw_python_with_alias_names(node, profile));
    }
    raw_walk_local(node, None, node, profile, &mut |child, parent| {
        if raw_local_write_node(child, parent, profile)
            || raw_declaration_name_in_tree(node, child, profile)
            || raw_assignment_lhs_write_in_tree(node, child, profile)
        {
            if let Some(name) = raw_local_identifier_text(child, profile) {
                writes.push(name);
            }
        }
    });
    writes
        .into_iter()
        .filter_map(|name| {
            let normalized = profile.normalize_local_identifier_text(&name);
            (!normalized.is_empty()).then_some(normalized)
        })
        .collect()
}

fn raw_assignment_dependencies(
    node: &RawNode,
    local_names: &BTreeSet<String>,
    profile: &dyn LanguageProfile,
) -> Vec<(String, String)> {
    let lhs_names = raw_local_writes(node, profile);
    if lhs_names.is_empty() {
        return Vec::new();
    }

    let reads = raw_local_reads(node, local_names, profile);
    let mut deps = Vec::new();
    for lhs in &lhs_names {
        for read in &reads {
            if lhs != read && !lhs_names.contains(read) {
                deps.push((lhs.clone(), read.clone()));
            }
        }
    }
    deps.sort();
    deps.dedup();
    deps
}

fn co_use_pairs(reads: &BTreeSet<String>) -> Vec<(String, String)> {
    let reads = reads.iter().cloned().collect::<Vec<_>>();
    let mut out = Vec::new();
    for i in 0..reads.len() {
        for j in i + 1..reads.len() {
            out.push((reads[i].clone(), reads[j].clone()));
        }
    }
    out
}

fn raw_structural_boundaries(document: &Document, statements: &[Statement]) -> Vec<Boundary> {
    let mut out = Vec::new();
    for i in 0..statements.len().saturating_sub(1) {
        let left = &statements[i];
        let right = &statements[i + 1];
        if let Some(boundary) = raw_source_boundary(document, left.end_line + 1, right.line - 1) {
            out.push(Boundary {
                before_index: left.index,
                after_index: right.index,
                line: boundary.line,
                kind: boundary.kind,
                text: boundary.text,
            });
        }
    }
    out
}

fn raw_source_boundary(
    document: &Document,
    first_line: usize,
    last_line: usize,
) -> Option<RawBoundary> {
    if first_line > last_line {
        return None;
    }

    let mut blank = None;
    for line_number in first_line..=last_line {
        let stripped = document
            .lines
            .get(line_number - 1)
            .map(|line| line.trim())
            .unwrap_or("");
        if stripped.starts_with('#') || stripped.starts_with("//") || stripped.starts_with("--") {
            return Some(RawBoundary {
                line: line_number,
                kind: "comment".to_string(),
                text: stripped.to_string(),
            });
        }
        if stripped.is_empty() && blank.is_none() {
            blank = Some(RawBoundary {
                line: line_number,
                kind: "blank".to_string(),
                text: stripped.to_string(),
            });
        }
    }
    blank
}

fn raw_walk_local<'a>(
    node: &'a RawNode,
    parent: Option<&'a RawNode>,
    root: &'a RawNode,
    profile: &dyn LanguageProfile,
    block: &mut dyn FnMut(&'a RawNode, Option<&'a RawNode>),
) {
    if !std::ptr::eq(node, root) && raw_nested_local_scope(node, profile) {
        return;
    }
    block(node, parent);
    for child in &node.children {
        raw_walk_local(child, Some(node), root, profile, block);
    }
}

fn raw_nested_local_scope(node: &RawNode, profile: &dyn LanguageProfile) -> bool {
    profile.function_node_kinds().contains(&node.kind.as_str()) || raw_owner_node(node, profile)
}

fn raw_owner_node(node: &RawNode, profile: &dyn LanguageProfile) -> bool {
    profile
        .class_owner_node_kinds()
        .contains(&node.kind.as_str())
        || profile
            .module_owner_node_kinds()
            .contains(&node.kind.as_str())
        || profile
            .generic_owner_node_kinds()
            .contains(&node.kind.as_str())
        || profile
            .impl_owner_node_kinds()
            .contains(&node.kind.as_str())
        || profile
            .struct_owner_node_kinds()
            .contains(&node.kind.as_str())
}

fn raw_local_identifier_text(node: &RawNode, profile: &dyn LanguageProfile) -> Option<String> {
    if profile
        .identifier_node_kinds()
        .contains(&node.kind.as_str())
    {
        let text = profile.normalize_local_identifier_text(&node.text);
        return (!text.is_empty()).then_some(text);
    }
    if profile
        .local_identifier_wrapper_node_kinds()
        .contains(&node.kind.as_str())
        && node.named
        && raw_named_children(node).is_empty()
        && simple_identifier(&node.text)
    {
        let text = profile.normalize_local_identifier_text(&node.text);
        return (!text.is_empty()).then_some(text);
    }
    None
}

fn raw_local_write_node(
    node: &RawNode,
    parent: Option<&RawNode>,
    profile: &dyn LanguageProfile,
) -> bool {
    if raw_local_identifier_text(node, profile).is_none() || raw_member_name(node, parent, profile)
    {
        return false;
    }
    if raw_call_name(node, parent, profile) {
        return false;
    }
    if raw_declaration_name(node, parent, profile) {
        return true;
    }
    let Some(parent) = parent else {
        return false;
    };
    if profile
        .update_statement_node_kinds()
        .contains(&parent.kind.as_str())
        && raw_named_children(parent)
            .first()
            .map(|target| std::ptr::eq(*target, node))
            .unwrap_or(false)
    {
        return true;
    }
    if profile
        .assignment_node_kinds()
        .contains(&parent.kind.as_str())
    {
        if let Some(lhs) = raw_named_children(parent).first() {
            if raw_contains_node(lhs, node) {
                return true;
            }
        }
    }
    if profile.language() == Language::Python {
        if parent.kind == "keyword_argument" {
            return false;
        }
        if raw_python_loop_target(node, parent)
            || raw_python_named_expression_lhs(node, parent)
            || raw_python_typed_assignment_lhs(node, parent)
            || raw_python_annotation_lhs(node, parent)
        {
            return true;
        }
    }
    raw_assignment_lhs(node, parent, profile)
}

fn raw_python_loop_target(node: &RawNode, parent: &RawNode) -> bool {
    if raw_previous_sibling(node, parent)
        .map(|sibling| sibling.text.as_str() == "for")
        .unwrap_or(false)
        && raw_next_sibling(node, parent)
            .map(|sibling| sibling.text.as_str() != ":")
            .unwrap_or(false)
    {
        return true;
    }

    let mut seen_for = false;
    let mut current = raw_previous_sibling(node, parent);
    while let Some(sibling) = current {
        match sibling.text.as_str() {
            "in" | ":" => return false,
            "for" => {
                seen_for = true;
                break;
            }
            _ => current = raw_previous_sibling(sibling, parent),
        }
    }
    if !seen_for {
        return false;
    }

    current = raw_next_sibling(node, parent);
    while let Some(sibling) = current {
        match sibling.text.as_str() {
            "in" => return true,
            ":" => return false,
            _ => current = raw_next_sibling(sibling, parent),
        }
    }
    false
}

fn raw_python_typed_assignment_lhs(node: &RawNode, parent: &RawNode) -> bool {
    let Some(colon) = raw_next_sibling(node, parent) else {
        return false;
    };
    if colon.text != ":" {
        return false;
    }
    let Some(type_node) = raw_next_sibling(colon, parent) else {
        return false;
    };
    if type_node.kind != "type" {
        return false;
    }
    raw_next_sibling(type_node, parent)
        .map(|sibling| sibling.text.as_str() == "=")
        .unwrap_or(false)
}

fn raw_python_named_expression_lhs(node: &RawNode, parent: &RawNode) -> bool {
    parent.kind == "named_expression"
        && raw_named_children(parent)
            .first()
            .map(|lhs| std::ptr::eq(*lhs, node))
            .unwrap_or(false)
        && raw_next_sibling(node, parent)
            .map(|sibling| sibling.text.as_str() == ":=")
            .unwrap_or(false)
}

fn raw_python_annotation_lhs(node: &RawNode, parent: &RawNode) -> bool {
    let Some(colon) = raw_next_sibling(node, parent) else {
        return false;
    };
    if colon.text != ":" {
        return false;
    }
    let Some(type_node) = raw_next_sibling(colon, parent) else {
        return false;
    };
    if type_node.kind != "type" {
        return false;
    }
    !raw_next_sibling(type_node, parent)
        .map(|sibling| sibling.text.as_str() == "=")
        .unwrap_or(false)
}

fn raw_python_with_alias_names(node: &RawNode, profile: &dyn LanguageProfile) -> Vec<String> {
    let mut names = Vec::new();
    raw_walk_local(node, None, node, profile, &mut |child, _parent| {
        if child.kind == "as_pattern_target" && simple_identifier(&child.text) {
            names.push(child.text.clone());
        }
    });
    names
}

fn raw_python_import_name(parent: Option<&RawNode>, profile: &dyn LanguageProfile) -> bool {
    profile.language() == Language::Python
        && parent
            .map(|parent| parent.kind.as_str() == "dotted_name")
            .unwrap_or(false)
}

fn raw_python_with_alias_read(
    node: &RawNode,
    parent: Option<&RawNode>,
    profile: &dyn LanguageProfile,
) -> bool {
    profile.language() == Language::Python
        && (node.kind == "as_pattern_target"
            || parent
                .map(|parent| parent.kind.as_str() == "as_pattern_target")
                .unwrap_or(false))
}

fn python_textual_local_writes(source: &str) -> Vec<String> {
    match split_assignment(source) {
        Some((_lhs, ":=")) => Vec::new(),
        _ => textual_local_writes(source),
    }
}

fn raw_declaration_name(
    node: &RawNode,
    parent: Option<&RawNode>,
    profile: &dyn LanguageProfile,
) -> bool {
    parent
        .map(|parent| {
            raw_local_declaration_name_nodes(parent, profile)
                .into_iter()
                .any(|name| std::ptr::eq(name, node) || raw_contains_node(name, node))
        })
        .unwrap_or(false)
}

fn raw_declaration_name_in_tree(
    root: &RawNode,
    target: &RawNode,
    profile: &dyn LanguageProfile,
) -> bool {
    raw_local_declaration_name_nodes(root, profile)
        .into_iter()
        .any(|name| std::ptr::eq(name, target) || raw_contains_node(name, target))
        || root
            .children
            .iter()
            .any(|child| raw_declaration_name_in_tree(child, target, profile))
}

fn raw_local_declaration_name_node<'a>(
    node: &'a RawNode,
    profile: &dyn LanguageProfile,
) -> Option<&'a RawNode> {
    raw_local_declaration_name_nodes(node, profile)
        .into_iter()
        .next()
}

fn raw_local_declaration_name_nodes<'a>(
    node: &'a RawNode,
    profile: &dyn LanguageProfile,
) -> Vec<&'a RawNode> {
    if !profile
        .local_declaration_node_kinds()
        .contains(&node.kind.as_str())
    {
        return Vec::new();
    }

    if profile
        .short_variable_declaration_node_kinds()
        .contains(&node.kind.as_str())
    {
        if let Some(left) = raw_named_children(node).into_iter().find(|child| {
            profile
                .variable_declaration_node_kinds()
                .contains(&child.kind.as_str())
        }) {
            let identifiers = raw_named_children(left)
                .into_iter()
                .filter(|child| raw_local_identifier_text(child, profile).is_some())
                .collect::<Vec<_>>();
            if !identifiers.is_empty() {
                return identifiers;
            }
            if simple_identifier(&left.text) {
                return vec![left];
            }
        }
        return Vec::new();
    }

    let variables = raw_variable_declaration_nodes(node, profile);
    if !variables.is_empty() {
        let names = variables
            .into_iter()
            .flat_map(|variable| raw_variable_declaration_name_nodes(variable, profile))
            .collect::<Vec<_>>();
        if !names.is_empty() {
            return names;
        }
    }

    if let Some(declaration_assignment) = raw_named_children(node).into_iter().find(|child| {
        profile
            .declaration_assignment_node_kinds()
            .contains(&child.kind.as_str())
    }) {
        if let Some(lhs) = raw_named_children(declaration_assignment).first().copied() {
            return raw_first_identifier(lhs, profile)
                .or(Some(lhs))
                .into_iter()
                .collect();
        }
    }

    raw_named_children(node)
        .into_iter()
        .find(|child| {
            profile
                .local_identifier_wrapper_node_kinds()
                .contains(&child.kind.as_str())
        })
        .or_else(|| raw_first_identifier(node, profile))
        .into_iter()
        .collect()
}

fn raw_variable_declaration_nodes<'a>(
    node: &'a RawNode,
    profile: &dyn LanguageProfile,
) -> Vec<&'a RawNode> {
    let mut out = Vec::new();
    raw_collect_variable_declaration_nodes(node, profile, &mut out);
    out
}

fn raw_collect_variable_declaration_nodes<'a>(
    node: &'a RawNode,
    profile: &dyn LanguageProfile,
    out: &mut Vec<&'a RawNode>,
) {
    if profile
        .variable_declaration_node_kinds()
        .contains(&node.kind.as_str())
    {
        out.push(node);
        return;
    }
    for child in raw_named_children(node) {
        raw_collect_variable_declaration_nodes(child, profile, out);
    }
}

fn raw_variable_declaration_name_nodes<'a>(
    variable: &'a RawNode,
    profile: &dyn LanguageProfile,
) -> Vec<&'a RawNode> {
    if simple_identifier(&variable.text) {
        return vec![variable];
    }

    if profile
        .multi_name_variable_declaration_node_kinds()
        .contains(&variable.kind.as_str())
    {
        let names = raw_named_children(variable)
            .into_iter()
            .take_while(|child| raw_local_identifier_text(child, profile).is_some())
            .collect::<Vec<_>>();
        if !names.is_empty() {
            return names;
        }
    }

    raw_first_identifier(variable, profile)
        .into_iter()
        .collect()
}

fn raw_first_identifier<'a>(
    node: &'a RawNode,
    profile: &dyn LanguageProfile,
) -> Option<&'a RawNode> {
    if raw_local_identifier_text(node, profile).is_some() {
        return Some(node);
    }
    node.children
        .iter()
        .find_map(|child| raw_first_identifier(child, profile))
}

fn raw_assignment_lhs(node: &RawNode, parent: &RawNode, profile: &dyn LanguageProfile) -> bool {
    if raw_previous_sibling(node, parent)
        .map(|sibling| sibling.text.as_str() == ":")
        .unwrap_or(false)
    {
        return false;
    }
    raw_next_sibling(node, parent)
        .map(|sibling| {
            !sibling.named
                && profile
                    .assignment_operator_tokens()
                    .contains(&sibling.text.as_str())
        })
        .unwrap_or(false)
}

fn raw_assignment_lhs_read_in_tree(
    root: &RawNode,
    target: &RawNode,
    profile: &dyn LanguageProfile,
) -> bool {
    if profile
        .deferred_statement_node_kinds()
        .contains(&root.kind.as_str())
    {
        return false;
    }
    if profile
        .assignment_node_kinds()
        .contains(&root.kind.as_str())
    {
        if let Some(lhs) = raw_named_children(root).first() {
            if raw_assignment_lhs_read_target(lhs, target, profile) {
                return true;
            }
        }
    }
    root.children
        .iter()
        .any(|child| raw_assignment_lhs_read_in_tree(child, target, profile))
}

fn raw_assignment_lhs_write_in_tree(
    root: &RawNode,
    target: &RawNode,
    profile: &dyn LanguageProfile,
) -> bool {
    if profile
        .deferred_statement_node_kinds()
        .contains(&root.kind.as_str())
    {
        return false;
    }
    if profile
        .assignment_node_kinds()
        .contains(&root.kind.as_str())
    {
        if let Some(lhs) = raw_named_children(root).first() {
            if raw_assignment_lhs_write_target(lhs, target, profile) {
                return true;
            }
        }
    }
    root.children
        .iter()
        .any(|child| raw_assignment_lhs_write_in_tree(child, target, profile))
}

fn raw_assignment_lhs_read_target(
    lhs: &RawNode,
    target: &RawNode,
    profile: &dyn LanguageProfile,
) -> bool {
    if raw_indexed_lhs_node(lhs, profile) {
        return raw_contains_node(lhs, target);
    }
    if raw_field_like_node(lhs, profile) {
        return profile.suppress_field_receiver_lhs_reads()
            && raw_member_receiver_target(lhs, target, profile);
    }
    if let Some(lhs_name) = raw_local_identifier_text(lhs, profile) {
        return std::ptr::eq(lhs, target)
            || (raw_contains_node(lhs, target)
                && raw_local_identifier_text(target, profile)
                    .map(|target_name| target_name == lhs_name)
                    .unwrap_or(false));
    }
    if profile
        .expression_list_node_kinds()
        .contains(&lhs.kind.as_str())
    {
        if raw_named_children(lhs).is_empty() && raw_local_identifier_text(lhs, profile).is_some() {
            return std::ptr::eq(lhs, target);
        }
        return raw_named_children(lhs)
            .into_iter()
            .any(|child| raw_assignment_lhs_read_target(child, target, profile));
    }
    raw_contains_node(lhs, target)
}

fn raw_assignment_lhs_write_target(
    lhs: &RawNode,
    target: &RawNode,
    profile: &dyn LanguageProfile,
) -> bool {
    if raw_indexed_lhs_node(lhs, profile) {
        return raw_named_children(lhs)
            .first()
            .map(|object| raw_assignment_lhs_write_target(object, target, profile))
            .unwrap_or(false);
    }
    if raw_field_like_node(lhs, profile) {
        return raw_member_receiver_target(lhs, target, profile);
    }
    if let Some(lhs_name) = raw_local_identifier_text(lhs, profile) {
        return std::ptr::eq(lhs, target)
            || (raw_contains_node(lhs, target)
                && raw_local_identifier_text(target, profile)
                    .map(|target_name| target_name == lhs_name)
                    .unwrap_or(false));
    }
    if profile
        .expression_list_node_kinds()
        .contains(&lhs.kind.as_str())
    {
        if raw_named_children(lhs).is_empty() && raw_local_identifier_text(lhs, profile).is_some() {
            return std::ptr::eq(lhs, target);
        }
        return raw_named_children(lhs)
            .into_iter()
            .any(|child| raw_assignment_lhs_write_target(child, target, profile));
    }
    raw_contains_node(lhs, target)
}

fn raw_indexed_lhs_node(node: &RawNode, profile: &dyn LanguageProfile) -> bool {
    profile
        .indexed_lhs_node_kinds()
        .contains(&node.kind.as_str())
        || (profile
            .indexed_lhs_bracket_wrapper_node_kinds()
            .contains(&node.kind.as_str())
            && node
                .children
                .iter()
                .any(|child| !child.named && child.text == "["))
}

fn raw_field_like_node(node: &RawNode, profile: &dyn LanguageProfile) -> bool {
    profile
        .field_like_node_kinds()
        .contains(&node.kind.as_str())
        || (profile
            .field_like_dot_wrapper_node_kinds()
            .contains(&node.kind.as_str())
            && node
                .children
                .iter()
                .any(|child| !child.named && child.text == "."))
}

fn raw_member_receiver_target(
    node: &RawNode,
    target: &RawNode,
    profile: &dyn LanguageProfile,
) -> bool {
    let Some(receiver) = raw_named_children(node).first().copied() else {
        return false;
    };
    if raw_local_identifier_text(receiver, profile).is_some() {
        return std::ptr::eq(receiver, target);
    }
    if raw_indexed_lhs_node(receiver, profile) {
        return raw_named_children(receiver)
            .first()
            .map(|object| raw_member_receiver_target(object, target, profile))
            .unwrap_or(false);
    }
    if raw_field_like_node(receiver, profile) {
        return raw_member_receiver_target(receiver, target, profile);
    }
    if raw_named_children(receiver)
        .into_iter()
        .any(|child| raw_member_receiver_target(child, target, profile))
    {
        return true;
    }
    false
}

fn raw_member_name(
    node: &RawNode,
    parent: Option<&RawNode>,
    profile: &dyn LanguageProfile,
) -> bool {
    let Some(parent) = parent else {
        return false;
    };
    if !raw_field_like_node(parent, profile) {
        return false;
    }
    raw_named_children(parent)
        .last()
        .map(|field| std::ptr::eq(*field, node))
        .unwrap_or(false)
}

fn raw_call_name(node: &RawNode, parent: Option<&RawNode>, profile: &dyn LanguageProfile) -> bool {
    let Some(parent) = parent else {
        return false;
    };
    if raw_field_like_node(parent, profile) {
        return false;
    }
    profile.call_node_kinds().contains(&parent.kind.as_str())
        && raw_named_children(parent)
            .first()
            .map(|callee| std::ptr::eq(*callee, node))
            .unwrap_or(false)
}

fn raw_keyed_element_key(
    node: &RawNode,
    parent: Option<&RawNode>,
    profile: &dyn LanguageProfile,
) -> bool {
    let Some(parent) = parent else {
        return false;
    };
    if !profile
        .keyed_element_node_kinds()
        .contains(&parent.kind.as_str())
    {
        return false;
    }
    raw_named_children(parent)
        .first()
        .map(|key| std::ptr::eq(*key, node))
        .unwrap_or(false)
        || raw_next_sibling(node, parent)
            .map(|sibling| !sibling.named && sibling.text == ":")
            .unwrap_or(false)
}

fn raw_assignment_statement(node: &RawNode, profile: &dyn LanguageProfile) -> bool {
    profile
        .assignment_node_kinds()
        .contains(&node.kind.as_str())
        || node.children.iter().any(|child| {
            !child.named
                && profile
                    .assignment_operator_tokens()
                    .contains(&child.text.as_str())
        })
}

fn raw_branch_node(node: &RawNode, profile: &dyn LanguageProfile) -> bool {
    profile.branch_node_kinds().contains(&node.kind.as_str())
}

fn raw_comment_node(node: &RawNode) -> bool {
    node.kind.to_ascii_lowercase().contains("comment")
}

fn raw_named_children(node: &RawNode) -> Vec<&RawNode> {
    node.children.iter().filter(|child| child.named).collect()
}

fn raw_next_sibling<'a>(node: &RawNode, parent: &'a RawNode) -> Option<&'a RawNode> {
    let index = parent
        .children
        .iter()
        .position(|child| std::ptr::eq(child, node))?;
    parent.children.get(index + 1)
}

fn raw_previous_sibling<'a>(node: &RawNode, parent: &'a RawNode) -> Option<&'a RawNode> {
    let index = parent
        .children
        .iter()
        .position(|child| std::ptr::eq(child, node))?;
    index
        .checked_sub(1)
        .and_then(|previous| parent.children.get(previous))
}

fn raw_contains_node(root: &RawNode, target: &RawNode) -> bool {
    std::ptr::eq(root, target)
        || root
            .children
            .iter()
            .any(|child| raw_contains_node(child, target))
}

fn normalized_node_for_span(root: &Node, span: Span) -> Option<&Node> {
    if [
        root.first_lineno,
        root.first_column,
        root.last_lineno,
        root.last_column,
    ] == span
    {
        return Some(root);
    }
    root.children
        .iter()
        .filter_map(ast::node)
        .find_map(|child| normalized_node_for_span(child, span))
}

fn fallback_node_from_raw(raw: &RawNode) -> Node {
    Node {
        r#type: "DEFN".to_string(),
        children: raw
            .children
            .iter()
            .filter(|child| child.named)
            .map(|child| Child::Node(Box::new(fallback_node_from_raw(child))))
            .collect(),
        first_lineno: raw.span[0],
        first_column: raw.span[1],
        last_lineno: raw.span[2],
        last_column: raw.span[3],
        text: raw.text.clone(),
    }
}

struct LocalFlow {
    file: String,
    lines: Vec<String>,
    language: Language,
    methods_by_span: BTreeMap<Span, MethodMetadata>,
}

impl LocalFlow {
    fn new(
        file: String,
        lines: Vec<String>,
        language: Language,
        methods_by_span: BTreeMap<Span, MethodMetadata>,
    ) -> Self {
        Self {
            file,
            lines,
            language,
            methods_by_span,
        }
    }

    fn scan(&mut self, root: &Node) -> Vec<MethodSummary> {
        let mut out = Vec::new();
        self.collect_methods(root, &Vec::new(), &mut out);
        out
    }

    fn collect_methods(&self, node: &Node, owners: &[String], out: &mut Vec<MethodSummary>) {
        if OWNER_TYPES.contains(&node.r#type.as_str()) {
            let owner = self.full_owner_name(owners, node);
            for method in self.owner_methods(node) {
                out.push(self.method_summary(method, Some(&owner)));
            }
            let mut next_owners = owners.to_vec();
            next_owners.push(self.owner_segment(node));
            self.collect_nested_owners(node, &next_owners, out);
        } else if METHOD_TYPES.contains(&node.r#type.as_str()) && owners.is_empty() {
            out.push(self.method_summary(node, None));
        } else {
            for child in node.children.iter().filter_map(ast::node) {
                self.collect_methods(child, owners, out);
            }
        }
    }

    fn collect_nested_owners(&self, node: &Node, owners: &[String], out: &mut Vec<MethodSummary>) {
        if METHOD_TYPES.contains(&node.r#type.as_str()) {
            return;
        }

        for child in node.children.iter().filter_map(ast::node) {
            if OWNER_TYPES.contains(&child.r#type.as_str()) {
                self.collect_methods(child, owners, out);
            } else {
                self.collect_nested_owners(child, owners, out);
            }
        }
    }

    fn method_summary(&self, node: &Node, owner_hint: Option<&str>) -> MethodSummary {
        let node_span = [
            node.first_lineno,
            node.first_column,
            node.last_lineno,
            node.last_column,
        ];
        let metadata = self.methods_by_span.get(&node_span);
        let owner = metadata
            .map(|item| item.owner.as_str())
            .or(owner_hint)
            .unwrap_or("(top-level)");
        let name = metadata
            .map(|item| item.name.clone())
            .unwrap_or_else(|| self.method_name(node));
        let statement_nodes = ast::body_stmts(node)
            .into_iter()
            .filter(|statement| !comment_statement(statement))
            .collect::<Vec<_>>();
        let local_names = self.local_names(&statement_nodes, metadata);
        let statements: Vec<_> = statement_nodes
            .iter()
            .enumerate()
            .map(|(index, stmt)| self.statement_summary(stmt, index, &local_names))
            .collect();
        MethodSummary {
            id: format!("{}#{}", owner, name),
            owner: owner.to_string(),
            name,
            file: self.file.clone(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            node: node.clone(),
            raw_node: None,
            boundaries: self.structural_boundaries(&statements),
            statements,
        }
    }

    fn statement_summary(
        &self,
        node: &Node,
        index: usize,
        local_names: &BTreeSet<String>,
    ) -> Statement {
        let source = ast::slice(node, &self.lines);
        let writes = self.local_writes(node);
        let reads = self.local_reads(node, local_names, &writes);
        Statement {
            index,
            line: node.first_lineno,
            end_line: node.last_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            source,
            dependencies: self.assignment_dependencies(node, local_names),
            co_uses: self.co_use_edges(node, local_names),
            reads,
            writes,
        }
    }

    fn local_names(
        &self,
        statements: &[&Node],
        metadata: Option<&MethodMetadata>,
    ) -> BTreeSet<String> {
        let mut names = metadata.map(|item| item.params.clone()).unwrap_or_default();
        for statement in statements {
            names.extend(self.local_writes(statement));
        }
        names
    }

    fn structural_boundaries(&self, statements: &[Statement]) -> Vec<Boundary> {
        let mut out = Vec::new();
        for i in 0..statements.len().saturating_sub(1) {
            let left = &statements[i];
            let right = &statements[i + 1];
            if let Some(boundary) = self.source_boundary(left.end_line + 1, right.line - 1) {
                out.push(Boundary {
                    before_index: left.index,
                    after_index: right.index,
                    line: boundary.line,
                    kind: boundary.kind,
                    text: boundary.text,
                });
            }
        }
        out
    }

    fn source_boundary(&self, first_line: usize, last_line: usize) -> Option<RawBoundary> {
        if first_line > last_line {
            return None;
        }

        let mut blank = None;
        for line_number in first_line..=last_line {
            let text = self
                .lines
                .get(line_number - 1)
                .map(|s| s.as_str())
                .unwrap_or("");
            let stripped = text.trim();
            if stripped.starts_with('#') || stripped.starts_with("//") || stripped.starts_with("--")
            {
                return Some(RawBoundary {
                    line: line_number,
                    kind: "comment".to_string(),
                    text: stripped.to_string(),
                });
            }
            if stripped.is_empty() && blank.is_none() {
                blank = Some(RawBoundary {
                    line: line_number,
                    kind: "blank".to_string(),
                    text: stripped.to_string(),
                });
            }
        }
        blank
    }

    fn owner_methods<'a>(&self, owner_node: &'a Node) -> Vec<&'a Node> {
        let Some(body) = self.owner_body(owner_node) else {
            return Vec::new();
        };

        let stmts = if statement_container(body) {
            body.children
                .iter()
                .filter_map(ast::node)
                .collect::<Vec<_>>()
        } else {
            vec![body]
        };

        stmts
            .into_iter()
            .flat_map(|stmt| {
                if METHOD_TYPES.contains(&stmt.r#type.as_str()) {
                    vec![stmt]
                } else if self.visibility_call(stmt) {
                    self.inline_methods(stmt)
                } else {
                    vec![]
                }
            })
            .collect()
    }

    fn inline_methods<'a>(&self, stmt: &'a Node) -> Vec<&'a Node> {
        let Some(args) = stmt.children.get(1).and_then(ast::node) else {
            return Vec::new();
        };
        args.children
            .iter()
            .filter_map(ast::node)
            .filter(|arg| METHOD_TYPES.contains(&arg.r#type.as_str()))
            .collect()
    }

    fn owner_body<'a>(&self, owner_node: &'a Node) -> Option<&'a Node> {
        let scope_index = if owner_node.r#type == "CLASS" { 2 } else { 1 };
        let scope = owner_node.children.get(scope_index).and_then(ast::node)?;
        if scope.r#type != "SCOPE" {
            return None;
        }
        scope.children.get(2).and_then(ast::node)
    }

    fn visibility_call(&self, node: &Node) -> bool {
        if node.r#type == "FCALL" {
            if let Some(Child::Symbol(name)) = node.children.first() {
                return matches!(name.as_str(), "public" | "protected" | "private");
            }
        }
        false
    }

    fn method_name(&self, node: &Node) -> String {
        if node.r#type == "DEFS" {
            let receiver = node.children.get(0).and_then(ast::node);
            let prefix = if let Some(r) = receiver {
                if r.r#type == "SELF" {
                    "self".to_string()
                } else {
                    ast::slice(r, &self.lines)
                }
            } else {
                "?".to_string()
            };
            format!(
                "{}.{}",
                prefix,
                node.children
                    .get(1)
                    .and_then(|c| match c {
                        Child::Symbol(s) => Some(s),
                        _ => None,
                    })
                    .unwrap_or(&"?".to_string())
            )
        } else {
            node.children
                .first()
                .and_then(|c| match c {
                    Child::Symbol(s) => Some(s.clone()),
                    _ => None,
                })
                .unwrap_or_else(|| "?".to_string())
        }
    }

    fn full_owner_name(&self, owners: &[String], node: &Node) -> String {
        let mut next = owners.to_vec();
        next.push(self.owner_segment(node));
        next.join("::")
    }

    fn owner_segment(&self, node: &Node) -> String {
        let text = ast::slice(
            node.children.first().and_then(ast::node).unwrap_or(node),
            &self.lines,
        );
        if text.is_empty() {
            "(anonymous)".to_string()
        } else {
            text
        }
    }

    fn local_reads(
        &self,
        node: &Node,
        local_names: &BTreeSet<String>,
        writes: &BTreeSet<String>,
    ) -> BTreeSet<String> {
        let mut reads = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_READ_TYPES.contains(&child.r#type.as_str()) {
                if let Some(name) = local_read_name(child) {
                    if local_names.contains(&name) {
                        reads.push(name);
                    }
                }
            }
        });
        reads.extend(textual_local_reads(
            &ast::slice(node, &self.lines),
            local_names,
            writes,
        ));
        reads.into_iter().collect()
    }

    fn local_writes(&self, node: &Node) -> BTreeSet<String> {
        let mut writes = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_WRITE_TYPES.contains(&child.r#type.as_str()) {
                if let Some(Child::String(name)) = child.children.first() {
                    writes.push(name.clone());
                }
            }
        });
        writes.extend(textual_local_writes(&ast::slice(node, &self.lines)));
        writes.into_iter().collect()
    }

    fn assignment_dependencies(
        &self,
        node: &Node,
        local_names: &BTreeSet<String>,
    ) -> Vec<(String, String)> {
        let mut deps = Vec::new();
        self.walk_local(node, &mut |child| {
            if LOCAL_WRITE_TYPES.contains(&child.r#type.as_str()) {
                if let Some(Child::String(lhs)) = child.children.first() {
                    if let Some(rhs) = child.children.get(1).and_then(ast::node) {
                        let rhs_writes = self.local_writes(rhs);
                        for read in self.local_reads(rhs, local_names, &rhs_writes) {
                            if lhs != &read {
                                deps.push((lhs.clone(), read));
                            }
                        }
                    }
                }
            }
        });
        let lhs_names = self.local_writes(node);
        if !lhs_names.is_empty() {
            let reads = self.local_reads(node, local_names, &lhs_names);
            for lhs in lhs_names {
                for read in &reads {
                    if &lhs != read {
                        deps.push((lhs.clone(), read.clone()));
                    }
                }
            }
        }
        deps.sort();
        deps.dedup();
        deps
    }

    fn co_use_edges(&self, node: &Node, local_names: &BTreeSet<String>) -> Vec<(String, String)> {
        let writes = self.local_writes(node);
        let reads: Vec<_> = self
            .local_reads(node, local_names, &writes)
            .into_iter()
            .collect();
        let mut out = Vec::new();
        for i in 0..reads.len() {
            for j in i + 1..reads.len() {
                out.push((reads[i].clone(), reads[j].clone()));
            }
        }
        out
    }

    fn walk_local(&self, node: &Node, blk: &mut dyn FnMut(&Node)) {
        if SKIP_NESTED_TYPES.contains(&node.r#type.as_str()) {
            return;
        }
        blk(node);
        for child in node.children.iter().filter_map(ast::node) {
            self.walk_local(child, blk);
        }
    }
}

fn local_read_name(node: &Node) -> Option<String> {
    match node.children.first() {
        Some(Child::String(name)) | Some(Child::Symbol(name)) => Some(name.clone()),
        Some(Child::Nil) => Some(String::new()),
        _ => None,
    }
}

fn textual_local_writes(source: &str) -> Vec<String> {
    let Some((lhs, operator)) = split_assignment(source) else {
        return Vec::new();
    };
    if lhs.contains('.')
        || lhs.contains("->")
        || lhs.contains('[')
        || lhs.contains('(')
        || lhs.contains(')')
    {
        return Vec::new();
    }

    let identifiers = identifiers_with_positions(lhs)
        .into_iter()
        .map(|identifier| identifier.name)
        .filter(|name| !local_keyword(name))
        .collect::<Vec<_>>();
    if identifiers.is_empty() {
        return Vec::new();
    }

    if operator == ":=" || declaration_like_lhs(lhs) || identifiers.len() == 1 {
        return identifiers
            .into_iter()
            .filter(|name| simple_identifier(name))
            .collect();
    }

    Vec::new()
}

fn textual_local_reads(
    source: &str,
    local_names: &BTreeSet<String>,
    writes: &BTreeSet<String>,
) -> Vec<String> {
    if plain_string_literal_source(source) {
        return Vec::new();
    }

    identifiers_with_positions(source)
        .into_iter()
        .filter(|identifier| local_names.contains(&identifier.name))
        .filter(|identifier| !writes.contains(&identifier.name))
        .filter(|identifier| !member_name(source, identifier.start))
        .filter(|identifier| !call_name(source, identifier.end))
        .map(|identifier| identifier.name)
        .collect()
}

fn plain_string_literal_source(source: &str) -> bool {
    let source = source.trim();
    if source.starts_with('f') || source.starts_with('F') {
        return false;
    }
    (source.starts_with("\"\"\"") && source.ends_with("\"\"\""))
        || (source.starts_with("'''") && source.ends_with("'''"))
        || (source.starts_with('"') && source.ends_with('"'))
        || (source.starts_with('\'') && source.ends_with('\''))
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct IdentifierSpan {
    name: String,
    start: usize,
    end: usize,
}

fn identifiers_with_positions(source: &str) -> Vec<IdentifierSpan> {
    let bytes = source.as_bytes();
    let mut out = Vec::new();
    let mut index = 0;
    while index < bytes.len() {
        let start = if bytes[index] == b'$' {
            let next = index + 1;
            if next < bytes.len() && identifier_start(bytes[next]) {
                next
            } else {
                index += 1;
                continue;
            }
        } else if identifier_start(bytes[index]) {
            index
        } else {
            index += 1;
            continue;
        };
        let mut end = start + 1;
        while end < bytes.len() && identifier_part(bytes[end]) {
            end += 1;
        }
        out.push(IdentifierSpan {
            name: source[start..end].to_string(),
            start,
            end,
        });
        index = end;
    }
    out
}

fn identifier_start(byte: u8) -> bool {
    byte == b'_' || byte.is_ascii_alphabetic()
}

fn identifier_part(byte: u8) -> bool {
    byte == b'_' || byte.is_ascii_alphanumeric()
}

fn split_assignment(source: &str) -> Option<(&str, &str)> {
    let bytes = source.as_bytes();
    let mut index = 0;
    while index < bytes.len() {
        if index + 1 < bytes.len() && bytes[index] == b':' && bytes[index + 1] == b'=' {
            return Some((source[..index].trim(), ":="));
        }
        if bytes[index] == b'=' {
            let previous = index.checked_sub(1).and_then(|i| bytes.get(i)).copied();
            let next = bytes.get(index + 1).copied();
            if !matches!(
                previous,
                Some(
                    b'=' | b'!'
                        | b'<'
                        | b'>'
                        | b':'
                        | b'+'
                        | b'-'
                        | b'*'
                        | b'/'
                        | b'%'
                        | b'&'
                        | b'|'
                )
            ) && !matches!(next, Some(b'=' | b'>'))
            {
                return Some((source[..index].trim(), "="));
            }
        }
        index += 1;
    }
    None
}

fn declaration_like_lhs(lhs: &str) -> bool {
    identifiers_with_positions(lhs)
        .first()
        .map(|identifier| {
            matches!(
                identifier.name.as_str(),
                "let"
                    | "const"
                    | "var"
                    | "val"
                    | "auto"
                    | "int"
                    | "long"
                    | "float"
                    | "double"
                    | "bool"
                    | "boolean"
                    | "char"
                    | "String"
                    | "string"
            )
        })
        .unwrap_or(false)
}

fn local_keyword(name: &str) -> bool {
    matches!(
        name,
        "as" | "break"
            | "auto"
            | "boolean"
            | "bool"
            | "case"
            | "char"
            | "class"
            | "const"
            | "continue"
            | "default"
            | "double"
            | "else"
            | "false"
            | "float"
            | "for"
            | "func"
            | "fun"
            | "function"
            | "if"
            | "in"
            | "int"
            | "long"
            | "let"
            | "mut"
            | "nil"
            | "None"
            | "null"
            | "private"
            | "protected"
            | "public"
            | "return"
            | "self"
            | "short"
            | "static"
            | "String"
            | "string"
            | "this"
            | "true"
            | "val"
            | "var"
            | "void"
            | "while"
    )
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn member_name(source: &str, start: usize) -> bool {
    let prefix = source[..start].trim_end();
    prefix.ends_with('.') || prefix.ends_with("->") || prefix.ends_with("::")
}

fn call_name(source: &str, end: usize) -> bool {
    let suffix = source[end..].trim_start();
    suffix.starts_with('(')
}

fn method_metadata(document: &Document) -> BTreeMap<Span, MethodMetadata> {
    document
        .function_defs
        .iter()
        .map(|function| (function.span, metadata_for_function(document, function)))
        .collect()
}

fn metadata_for_function(document: &Document, function: &FunctionDef) -> MethodMetadata {
    let owner = local_flow_owner(&document.file, &function.owner);
    MethodMetadata {
        owner,
        name: function.name.clone(),
        params: function.params.iter().cloned().collect(),
    }
}

fn local_flow_owner(file: &str, owner: &str) -> String {
    let file_owner = file_owner(file);
    if owner == file_owner {
        return "(top-level)".to_string();
    }
    owner
        .strip_prefix(&format!("{file_owner}::"))
        .unwrap_or(owner)
        .to_string()
}

fn file_owner(file: &str) -> String {
    Path::new(file)
        .file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("(file)")
        .to_string()
}

fn statement_container(node: &Node) -> bool {
    STATEMENT_CONTAINER_TYPES.contains(&node.r#type.as_str())
}

fn comment_statement(node: &Node) -> bool {
    node.r#type.to_ascii_lowercase().contains("comment")
        || node.text.trim_start().starts_with("//")
        || node.text.trim_start().starts_with('#')
        || node.text.trim_start().starts_with("--")
}

struct RawBoundary {
    line: usize,
    kind: String,
    text: String,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn summaries(source: &str, language: Language) -> Vec<MethodSummary> {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write");
        scan_files(&[file.path().to_path_buf()], language).expect("scan")
    }

    #[test]
    fn extracts_python_function_local_flow() {
        let summaries = summaries(
            "def mixed(price, tax):\n    subtotal = price + tax\n    total = subtotal\n    return total\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "mixed")
            .expect("mixed summary");

        assert_eq!(summary.owner, "(top-level)");
        assert_eq!(summary.statements.len(), 3);
        assert_eq!(
            summary.statements[0].reads,
            ["price".to_string(), "tax".to_string()]
                .into_iter()
                .collect()
        );
        assert_eq!(
            summary.statements[1].dependencies,
            vec![("total".to_string(), "subtotal".to_string())]
        );
        assert_eq!(
            summary.statements[2].reads,
            ["total".to_string()].into_iter().collect()
        );
    }

    #[test]
    fn handles_non_ascii_source_without_byte_boundary_panics() {
        let summaries = summaries(
            "def mixed(price):\n    marker = \"✓\"\n    total = price\n    return total\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "mixed")
            .expect("mixed summary");

        assert_eq!(summary.statements.len(), 3);
        assert_eq!(
            summary.statements[1].dependencies,
            vec![("total".to_string(), "price".to_string())]
        );
    }

    #[test]
    fn preserves_self_parameter_reads_for_python_attribute_access() {
        let summaries = summaries(
            "class TextSuite:\n    def setup(self):\n        self.console = Console(file=StringIO(), color_system=\"truecolor\")\n        self.text = Text.from_markup(markup)\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.id == "TextSuite#setup")
            .expect("setup summary");

        assert_eq!(
            summary.statements[0].reads,
            ["self".to_string()].into_iter().collect()
        );
        assert!(!summary.statements[0].writes.contains("file"));
        assert_eq!(
            summary.statements[1].reads,
            ["self".to_string()].into_iter().collect()
        );
    }

    #[test]
    fn excludes_keyword_argument_writes_from_outer_assignment_dependencies() {
        let summaries = summaries(
            "def render():\n    pretty = Pretty(snippets.PYTHON_DICT, indent_guides=True)\n    return pretty\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "render")
            .expect("render summary");

        assert_eq!(
            summary.statements[0].writes,
            ["pretty".to_string()].into_iter().collect()
        );
        assert!(summary.statements[0].dependencies.is_empty());
    }

    #[test]
    fn mines_python_loop_and_with_locals_without_keyword_writes() {
        let summaries = summaries(
            "def download(urls, dest_dir):\n    with ThreadPoolExecutor(max_workers=4) as pool:\n        for url in urls:\n            filename = url.split(\"/\")[-1]\n            dest_path = os.path.join(dest_dir, filename)\n            task_id = progress.add_task(\"download\", filename=filename, start=False)\n            pool.submit(copy_url, task_id, url, dest_path)\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "download")
            .expect("download summary");
        let statement = &summary.statements[0];

        assert!(statement.reads.contains("urls"));
        assert!(statement.reads.contains("url"));
        assert!(statement.reads.contains("pool"));
        assert!(statement.writes.contains("url"));
        assert!(statement.writes.contains("pool"));
        assert!(!statement.writes.contains("urls"));
        assert!(!statement.writes.contains("max_workers"));
        assert!(!statement.writes.contains("start"));
    }

    #[test]
    fn does_not_read_python_with_alias_at_declaration_site() {
        let summaries = summaries(
            "def capture(console):\n    with console.capture() as output:\n        console.line()\n    return output\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "capture")
            .expect("capture summary");

        assert!(summary.statements[0].writes.contains("output"));
        assert!(!summary.statements[0].reads.contains("output"));
        assert!(summary.statements[1].reads.contains("output"));
    }

    #[test]
    fn mines_python_named_expression_writes() {
        let summaries = summaries(
            "def scan(text, index):\n    if (character := text[index]):\n        return character\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "scan")
            .expect("scan summary");
        let statement = &summary.statements[0];

        assert!(statement.writes.contains("character"));
        assert!(statement.reads.contains("text"));
        assert!(statement.reads.contains("index"));
        assert!(statement
            .dependencies
            .contains(&("character".to_string(), "text".to_string())));
        assert!(statement
            .dependencies
            .contains(&("character".to_string(), "index".to_string())));
    }

    #[test]
    fn ignores_python_import_path_segments_that_match_locals() {
        let summaries = summaries(
            "def status(status):\n    from .status import Status\n    return status\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "status")
            .expect("status summary");

        assert!(summary.statements[0].reads.is_empty());
        assert_eq!(
            summary.statements[1].reads,
            ["status".to_string()].into_iter().collect()
        );
    }

    #[test]
    fn reads_python_callable_locals_without_marking_call_callee_as_write() {
        let summaries = summaries(
            "def invoke(callback, value):\n    runner = callback\n    return runner(value)\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "invoke")
            .expect("invoke summary");

        assert_eq!(
            summary.statements[1].reads,
            ["runner".to_string(), "value".to_string()]
                .into_iter()
                .collect()
        );
        assert!(summary.statements[1].writes.is_empty());
    }

    #[test]
    fn does_not_read_locals_from_plain_docstring_text() {
        let summaries = summaries(
            "def get_content(user):\n    \"\"\"Extract text from user dict.\"\"\"\n    return user\n",
            Language::Python,
        );
        let summary = summaries
            .iter()
            .find(|summary| summary.name == "get_content")
            .expect("get_content summary");

        assert!(summary.statements[0].reads.is_empty());
        assert_eq!(
            summary.statements[1].reads,
            ["user".to_string()].into_iter().collect()
        );
    }

    #[test]
    fn extracts_java_kotlin_and_swift_local_flow() {
        let cases = [
            (
                Language::Java,
                "class Billing {\n  int mixed(int price, int tax) {\n    int subtotal = price + tax;\n    int total = subtotal;\n    return total;\n  }\n}\n",
            ),
            (
                Language::Kotlin,
                "class Billing {\n  fun mixed(price: Int, tax: Int): Int {\n    val subtotal = price + tax\n    val total = subtotal\n    return total\n  }\n}\n",
            ),
            (
                Language::Swift,
                "class Billing {\n  func mixed(price: Int, tax: Int) -> Int {\n    let subtotal = price + tax\n    let total = subtotal\n    return total\n  }\n}\n",
            ),
        ];

        for (language, source) in cases {
            let summaries = summaries(source, language);
            let summary = summaries
                .iter()
                .find(|summary| summary.name == "mixed")
                .expect("mixed summary");

            assert_eq!(summary.owner, "Billing");
            assert_eq!(summary.statements.len(), 3);
            assert_eq!(
                summary.statements[0].reads,
                ["price".to_string(), "tax".to_string()]
                    .into_iter()
                    .collect()
            );
            assert_eq!(
                summary.statements[1].dependencies,
                vec![("total".to_string(), "subtotal".to_string())]
            );
            assert_eq!(
                summary.statements[2].reads,
                ["total".to_string()].into_iter().collect()
            );
        }
    }
}
