use crate::ast::{self, normalize_text, Child, Node, RawNode, Span};
use crate::syntax::adapters::{language_profile, LanguageProfile};
use crate::syntax::raw_tree::{
    child_by_field as raw_child_by_field, named_children as raw_named_children,
};
use crate::syntax::{Document, Language};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct PathConditionReport {
    pub neglected: Vec<NeglectedPathCondition>,
    pub scattered: Vec<ScatteredPathCondition>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct NeglectedPathCondition {
    pub pattern: Vec<String>,
    pub support: usize,
    pub missing: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
    pub action: String,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ScatteredPathCondition {
    pub guards: Vec<String>,
    pub support: usize,
    pub scatter: usize,
    pub rank: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Site {
    guards: Vec<String>,
    action: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<PathConditionReport> {
    let documents = super::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> PathConditionReport {
    let sites = documents
        .iter()
        .flat_map(|document| {
            fact_sites_for_document(document)
                .into_iter()
                .map(|site| Site {
                    guards: site.guards,
                    action: site.action,
                    file: site.file,
                    defn: site.function,
                    line: site.line,
                    span: site.span,
                })
        })
        .collect::<Vec<_>>();
    Report::new(sites).findings()
}

pub(crate) fn fact_sites_for_document(
    document: &Document,
) -> Vec<crate::syntax::PathConditionSite> {
    let mut sites = sites_from_document_facts(document);
    if !document.normalized_root.children.is_empty() {
        sites.extend(normalized_sites_from_document(document));
    } else if sites.is_empty() {
        sites = sites_from_raw_facts(document);
    }
    dedupe_sites(sites)
        .into_iter()
        .map(|site| crate::syntax::PathConditionSite {
            guards: site.guards,
            action: site.action,
            file: site.file,
            function: site.defn,
            line: site.line,
            span: site.span,
        })
        .collect()
}

fn normalized_sites_from_document(document: &Document) -> Vec<Site> {
    let mut pc = PathCondition::new(document.file.clone(), document.lines.clone());
    pc.walk(&document.normalized_root, &Vec::new(), &Vec::new());
    pc.sites
}

fn dedupe_sites(sites: Vec<Site>) -> Vec<Site> {
    let mut seen = BTreeSet::new();
    sites
        .into_iter()
        .filter(|site| {
            seen.insert((
                site.guards.clone(),
                site.action.clone(),
                site.file.clone(),
                site.defn.clone(),
                site.line,
            ))
        })
        .collect()
}

fn sites_from_document_facts(document: &Document) -> Vec<Site> {
    document
        .path_condition_sites
        .iter()
        .map(|site| Site {
            guards: site.guards.clone(),
            action: site.action.clone(),
            file: site.file.clone(),
            defn: site.function.clone(),
            line: site.line,
            span: site.span,
        })
        .collect()
}

fn sites_from_raw_facts(document: &Document) -> Vec<Site> {
    let profile = language_profile(document.language);
    let mut sites = Vec::new();
    for function in &document.function_defs {
        for statement in raw_function_body_statements(profile, &function.body) {
            raw_path_walk(
                document,
                profile,
                statement,
                &function.name,
                &[],
                &mut sites,
            );
        }
    }
    sites
}

fn raw_function_body_node<'a>(
    profile: &dyn LanguageProfile,
    node: &'a RawNode,
) -> Option<&'a RawNode> {
    if let Some(body) = raw_child_by_field(node, "body") {
        return Some(body);
    }
    raw_named_children(node).into_iter().rev().find(|child| {
        profile
            .function_body_node_kinds()
            .contains(&child.kind.as_str())
    })
}

fn raw_function_body_statements<'a>(
    profile: &dyn LanguageProfile,
    node: &'a RawNode,
) -> Vec<&'a RawNode> {
    let Some(body) = raw_function_body_node(profile, node) else {
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
        if raw_branch_node(profile, named[0]) {
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
    if raw_branch_node(profile, body) || raw_assignment_statement(profile, body) || named.is_empty()
    {
        return vec![body];
    }
    named
}

fn raw_path_walk(
    document: &Document,
    profile: &dyn LanguageProfile,
    node: &RawNode,
    function: &str,
    guards: &[String],
    out: &mut Vec<Site>,
) {
    if raw_nested_local_scope(profile, node) {
        return;
    }

    if raw_branch_node(profile, node) {
        let condition = raw_branch_condition(node);
        let atoms = raw_path_condition_atoms(profile, condition);
        let then_atoms = if raw_unless_node(node) {
            raw_negate_guards(&atoms)
        } else {
            atoms.clone()
        };
        let else_atoms = if raw_unless_node(node) {
            atoms
        } else {
            raw_negate_guards(&atoms)
        };
        for (child, branch_guards) in raw_branch_body_nodes(profile, node, &then_atoms, &else_atoms)
        {
            let mut next_guards = guards.to_vec();
            next_guards.extend(branch_guards);
            raw_path_walk(document, profile, child, function, &next_guards, out);
        }
        return;
    }

    if guards.len() >= 2 && raw_path_action_node(profile, node) {
        let mut unique = guards.to_vec();
        unique.sort();
        unique.dedup();
        out.push(Site {
            guards: unique,
            action: profile.normalize_source_text(&node.text),
            file: document.file.clone(),
            defn: function.to_string(),
            line: node.span[0],
            span: node.span,
        });
        return;
    }

    for child in raw_named_children(node) {
        raw_path_walk(document, profile, child, function, guards, out);
    }
}

fn raw_path_condition_atoms(
    profile: &dyn LanguageProfile,
    condition: Option<&RawNode>,
) -> Vec<String> {
    let Some(condition) = condition else {
        return Vec::new();
    };
    if raw_boolean_container(profile, condition) && raw_boolean_and(profile, condition) {
        let mut atoms = raw_flatten_boolean_and(profile, condition)
            .into_iter()
            .map(|child| raw_decision_member_text(profile, &child.text))
            .collect::<Vec<_>>();
        atoms.sort();
        atoms.dedup();
        atoms
    } else {
        vec![raw_decision_member_text(profile, &condition.text)]
    }
}

fn raw_branch_condition(node: &RawNode) -> Option<&RawNode> {
    if raw_modifier_branch(node) {
        return raw_named_children(node).into_iter().last();
    }
    raw_child_by_field(node, "condition")
        .or_else(|| raw_child_by_field(node, "value"))
        .or_else(|| raw_child_by_field(node, "subject"))
        .or_else(|| raw_named_children(node).into_iter().next())
}

fn raw_branch_body_nodes<'a>(
    profile: &dyn LanguageProfile,
    node: &'a RawNode,
    then_guards: &[String],
    else_guards: &[String],
) -> Vec<(&'a RawNode, Vec<String>)> {
    let mut bodies = Vec::new();
    if let Some(body) =
        raw_child_by_field(node, "consequence").or_else(|| raw_child_by_field(node, "body"))
    {
        bodies.push((body, then_guards.to_vec()));
    }
    if let Some(body) = raw_child_by_field(node, "alternative") {
        bodies.push((body, else_guards.to_vec()));
    }
    if bodies.is_empty() {
        let named = raw_named_children(node);
        bodies = if raw_modifier_branch(node) {
            named
                .into_iter()
                .next()
                .map(|body| vec![(body, then_guards.to_vec())])
                .unwrap_or_default()
        } else {
            named
                .into_iter()
                .skip(1)
                .enumerate()
                .map(|(index, body)| {
                    let guards = if index == 0 {
                        then_guards.to_vec()
                    } else {
                        else_guards.to_vec()
                    };
                    (body, guards)
                })
                .collect()
        };
    }
    bodies
        .into_iter()
        .flat_map(|(body, branch_guards)| {
            raw_flatten_branch_body(profile, body)
                .into_iter()
                .map(move |child| (child, branch_guards.clone()))
        })
        .collect()
}

fn raw_modifier_branch(node: &RawNode) -> bool {
    matches!(node.kind.as_str(), "if_modifier" | "unless_modifier")
        || raw_hidden_modifier_branch(node)
}

fn raw_flatten_branch_body<'a>(
    profile: &dyn LanguageProfile,
    body: &'a RawNode,
) -> Vec<&'a RawNode> {
    if raw_simple_action_wrapper(profile, body) {
        return vec![body];
    }
    if raw_path_action_node(profile, body) {
        return vec![body];
    }
    let body_children = raw_named_children(body);
    let children = if profile
        .path_transparent_branch_body_node_kinds()
        .contains(&body.kind.as_str())
    {
        body_children.into_iter().skip(1).collect::<Vec<_>>()
    } else {
        body_children
    };
    let children = children
        .into_iter()
        .flat_map(|child| {
            if profile
                .path_transparent_branch_body_node_kinds()
                .contains(&child.kind.as_str())
            {
                raw_named_children(child)
                    .into_iter()
                    .skip(1)
                    .collect::<Vec<_>>()
            } else {
                vec![child]
            }
        })
        .filter(|child| !raw_comment_node(child))
        .collect::<Vec<_>>();
    if children.is_empty() {
        vec![body]
    } else {
        children
    }
}

fn raw_unless_node(node: &RawNode) -> bool {
    node.kind.contains("unless")
        || node
            .children
            .first()
            .map(|child| !child.named && (child.kind == "unless" || child.text == "unless"))
            .unwrap_or(false)
        || raw_modifier_keyword(node)
            .map(|keyword| keyword == "unless")
            .unwrap_or(false)
}

fn raw_negate_guards(guards: &[String]) -> Vec<String> {
    guards
        .iter()
        .map(|guard| {
            guard
                .strip_prefix('!')
                .map(str::to_string)
                .unwrap_or_else(|| format!("!{guard}"))
        })
        .collect()
}

fn raw_path_action_node(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
    if raw_branch_node(profile, node) {
        return false;
    }
    raw_simple_action_wrapper(profile, node)
        || raw_assignment_statement(profile, node)
        || profile
            .path_action_node_kinds()
            .contains(&node.kind.as_str())
}

fn raw_simple_action_wrapper(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
    if !profile
        .simple_action_wrapper_node_kinds()
        .contains(&node.kind.as_str())
    {
        return false;
    }
    let text = normalize_text(&node.text);
    if text.contains('{') || text.contains('}') {
        return false;
    }
    let text = text.strip_suffix(';').unwrap_or(&text).trim();
    let Some(open) = text.find('(') else {
        return false;
    };
    text.ends_with(')')
        && text[..open]
            .chars()
            .all(|ch| ch == '_' || ch == '.' || ch.is_ascii_alphanumeric())
}

fn raw_assignment_statement(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
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

fn raw_branch_node(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
    profile.branch_node_kinds().contains(&node.kind.as_str())
        || raw_hidden_modifier_branch(node)
        || raw_keyword_branch_wrapper(node)
}

fn raw_keyword_branch_wrapper(node: &RawNode) -> bool {
    matches!(
        node.kind.as_str(),
        "body_statement" | "block" | "statements" | "statement_list" | "expression_statement"
    ) && node
        .children
        .first()
        .map(|child| !child.named && matches!(child.kind.as_str(), "if" | "unless"))
        .unwrap_or(false)
}

fn raw_hidden_modifier_branch(node: &RawNode) -> bool {
    raw_modifier_keyword(node).is_some()
}

fn raw_modifier_keyword<'a>(node: &'a RawNode) -> Option<&'a str> {
    if !matches!(
        node.kind.as_str(),
        "body_statement" | "block" | "statements" | "statement_list" | "expression_statement"
    ) {
        return None;
    }
    let mut seen_named = false;
    for child in &node.children {
        seen_named |= child.named;
        if seen_named && !child.named && matches!(child.kind.as_str(), "if" | "unless") {
            return Some(child.kind.as_str());
        }
    }
    None
}

fn raw_nested_local_scope(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
    profile.function_node_kinds().contains(&node.kind.as_str())
        || profile
            .class_owner_node_kinds()
            .contains(&node.kind.as_str())
        || profile
            .module_owner_node_kinds()
            .contains(&node.kind.as_str())
        || profile
            .generic_owner_node_kinds()
            .contains(&node.kind.as_str())
        || profile
            .struct_owner_node_kinds()
            .contains(&node.kind.as_str())
}

fn raw_boolean_container(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
    if profile
        .boolean_container_node_kinds()
        .contains(&node.kind.as_str())
    {
        return true;
    }
    if raw_parenthesized_wrapper(profile, node) {
        return raw_named_children(node)
            .into_iter()
            .next()
            .map(|child| raw_boolean_container(profile, child))
            .unwrap_or(false);
    }
    false
}

fn raw_boolean_and(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
    if raw_parenthesized_wrapper(profile, node) {
        return raw_named_children(node)
            .into_iter()
            .next()
            .map(|child| raw_boolean_and(profile, child))
            .unwrap_or(false);
    }
    raw_direct_operator(node)
        .map(|operator| profile.boolean_and_operators().contains(&operator.as_str()))
        .unwrap_or(false)
}

fn raw_flatten_boolean_and<'a>(
    profile: &dyn LanguageProfile,
    node: &'a RawNode,
) -> Vec<&'a RawNode> {
    if !(raw_boolean_container(profile, node) && raw_boolean_and(profile, node)) {
        return vec![node];
    }
    if raw_parenthesized_wrapper(profile, node) {
        return raw_named_children(node)
            .into_iter()
            .next()
            .map(|child| raw_flatten_boolean_and(profile, child))
            .unwrap_or_else(|| vec![node]);
    }
    raw_named_children(node)
        .into_iter()
        .flat_map(|child| raw_flatten_boolean_and(profile, child))
        .collect()
}

fn raw_parenthesized_wrapper(profile: &dyn LanguageProfile, node: &RawNode) -> bool {
    profile
        .parenthesized_wrapper_node_kinds()
        .contains(&node.kind.as_str())
        && raw_named_children(node).len() == 1
}

fn raw_decision_member_text(profile: &dyn LanguageProfile, text: &str) -> String {
    profile.normalize_source_text(&strip_enclosing_parentheses(text))
}

fn strip_enclosing_parentheses(text: &str) -> String {
    let mut value = text.trim().to_string();
    loop {
        if !(value.starts_with('(') && value.ends_with(')')) {
            break value;
        }
        if !enclosing_parentheses_wrap_all(&value) {
            break value;
        }
        value = value[1..value.len() - 1].trim().to_string();
    }
}

fn enclosing_parentheses_wrap_all(text: &str) -> bool {
    let mut depth = 0isize;
    for (index, ch) in text.chars().enumerate() {
        if ch == '(' {
            depth += 1;
        } else if ch == ')' {
            depth -= 1;
        }
        if depth == 0 && index < text.len() - 1 {
            return false;
        }
        if depth < 0 {
            return false;
        }
    }
    depth == 0
}

fn raw_direct_operator(node: &RawNode) -> Option<String> {
    node.children
        .iter()
        .find(|child| {
            let text = child.text.trim();
            !child.named && !matches!(text, "(" | ")")
        })
        .map(|child| normalize_text(&child.text))
}

fn raw_comment_node(node: &RawNode) -> bool {
    node.kind.contains("comment")
}

struct PathCondition {
    file: String,
    lines: Vec<String>,
    sites: Vec<Site>,
}

impl PathCondition {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            sites: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String], guards: &[Vec<String>]) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        match node.r#type.as_str() {
            "IF" | "UNLESS" => {
                let cond = node.children.get(0).and_then(ast::node);
                let a = node.children.get(1).and_then(ast::node);
                let b = node.children.get(2).and_then(ast::node);

                let atoms = self.cond_atoms(cond);
                let then_g = if node.r#type == "IF" {
                    atoms.clone()
                } else {
                    self.negate(&atoms)
                };
                let else_g = if node.r#type == "IF" {
                    self.negate(&atoms)
                } else {
                    atoms.clone()
                };

                if let Some(a_node) = a {
                    let mut next_guards = guards.to_vec();
                    next_guards.extend(then_g);
                    self.walk(a_node, &next_defstack, &next_guards);
                }
                if let Some(b_node) = b {
                    let mut next_guards = guards.to_vec();
                    next_guards.extend(else_g);
                    self.walk(b_node, &next_defstack, &next_guards);
                }

                return;
            }
            "CALL" | "FCALL" | "VCALL" | "ATTRASGN" | "LASGN" | "IASGN" | "OPCALL" => {
                if guards.len() >= 2 {
                    self.record(node, &next_defstack, guards);
                }
            }
            _ => {}
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack, guards);
        }
    }

    fn cond_atoms(&self, cond: Option<&Node>) -> Vec<Vec<String>> {
        let Some(cond) = cond else { return Vec::new() };
        ast::flatten_and(cond)
            .into_iter()
            .map(|a| {
                let t = ast::slice(a, &self.lines);
                let (text, neg) = ast::canon_polarity(&t);
                vec![
                    text,
                    if neg {
                        "true".to_string()
                    } else {
                        "false".to_string()
                    },
                ]
            })
            .collect()
    }

    fn negate(&self, atoms: &[Vec<String>]) -> Vec<Vec<String>> {
        atoms
            .iter()
            .map(|a| {
                let t = &a[0];
                let n = a[1] == "true";
                vec![
                    t.clone(),
                    if !n {
                        "true".to_string()
                    } else {
                        "false".to_string()
                    },
                ]
            })
            .collect()
    }

    fn record(&mut self, node: &Node, defstack: &[String], guards: &[Vec<String>]) {
        let mut members_set = BTreeSet::new();
        for g in guards {
            let prefix = if g[1] == "true" { "!" } else { "" };
            members_set.insert(format!("{}{}", prefix, g[0]));
        }
        let members: Vec<_> = members_set.into_iter().collect();

        if members.len() < 2 {
            return;
        }

        let slice = ast::slice(node, &self.lines);
        let action = if slice.len() > 80 {
            slice[..80].to_string()
        } else {
            slice
        };

        self.sites.push(Site {
            guards: members,
            action,
            file: self.file.clone(),
            defn: defstack
                .last()
                .cloned()
                .unwrap_or_else(|| "(top-level)".to_string()),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
        });
    }
}

struct Report {
    sites: Vec<Site>,
    groups: Vec<(Vec<String>, Vec<Site>)>,
}

impl Report {
    fn new(sites: Vec<Site>) -> Self {
        let mut keys = Vec::new();
        let mut groups: BTreeMap<Vec<String>, Vec<Site>> = BTreeMap::new();
        for s in &sites {
            if !groups.contains_key(&s.guards) {
                keys.push(s.guards.clone());
            }
            groups.entry(s.guards.clone()).or_default().push(s.clone());
        }

        let ordered_groups = keys
            .into_iter()
            .map(|k| {
                let v = groups.remove(&k).unwrap();
                (k, v)
            })
            .collect();

        Self {
            sites,
            groups: ordered_groups,
        }
    }

    fn findings(&self) -> PathConditionReport {
        PathConditionReport {
            neglected: self.neglected(3),
            scattered: self.scattered(2),
        }
    }

    fn scattered(&self, min_scatter: usize) -> Vec<ScatteredPathCondition> {
        let mut out = Vec::new();
        for (guards, sites) in &self.groups {
            let scatter = sites
                .iter()
                .map(|site| (site.file.clone(), site.defn.clone()))
                .collect::<BTreeSet<_>>()
                .len();
            if scatter < min_scatter {
                continue;
            }

            let locations = sites
                .iter()
                .map(|site| format!("{}:{}:{}", site.file, site.defn, site.line))
                .collect::<Vec<_>>();
            let spans = sites
                .iter()
                .map(|site| {
                    (
                        format!("{}:{}:{}", site.file, site.defn, site.line),
                        site.span,
                    )
                })
                .collect::<BTreeMap<_, _>>();
            out.push(ScatteredPathCondition {
                guards: guards.clone(),
                support: sites.len(),
                scatter,
                rank: sites.len() * scatter,
                sites: locations,
                spans,
            });
        }
        out.sort_by(|a, b| b.rank.cmp(&a.rank).then_with(|| a.guards.cmp(&b.guards)));
        out
    }

    fn neglected(&self, min_support: usize) -> Vec<NeglectedPathCondition> {
        let popular: Vec<_> = self
            .groups
            .iter()
            .filter(|(_, s)| s.len() >= min_support)
            .map(|(g, s)| (g.clone(), s.len()))
            .collect();

        let mut out = Vec::new();
        let mut seen = BTreeSet::new();

        for s in &self.sites {
            for (gs, sup) in &popular {
                let gs_set: BTreeSet<_> = gs.iter().cloned().collect();
                let s_guards_set: BTreeSet<_> = s.guards.iter().cloned().collect();

                let diff_gs_s: BTreeSet<_> = gs_set.difference(&s_guards_set).cloned().collect();
                let diff_s_gs: BTreeSet<_> = s_guards_set.difference(&gs_set).cloned().collect();

                if diff_gs_s.len() == 1 && diff_s_gs.is_empty() {
                    if s.guards == *gs {
                        continue;
                    }

                    let at = format!("{}:{}:{}", s.file, s.defn, s.line);
                    let missing = diff_gs_s.into_iter().next().unwrap();

                    // dedupe manually
                    let key = (gs.clone(), sup.clone(), missing.clone(), at.clone());
                    if seen.insert(key) {
                        let mut spans = BTreeMap::new();
                        spans.insert(at.clone(), s.span);

                        out.push(NeglectedPathCondition {
                            pattern: gs.clone(),
                            support: *sup,
                            missing,
                            at,
                            spans,
                            action: s.action.clone(),
                        });
                    }
                }
            }
        }

        out.sort_by(|a, b| b.support.cmp(&a.support).then_with(|| a.at.cmp(&b.at)));
        out
    }
}
