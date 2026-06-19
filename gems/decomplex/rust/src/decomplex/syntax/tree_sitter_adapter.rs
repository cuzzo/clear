use super::{
    adapters::{language_profile, LanguageProfile},
    ComparisonUse, DecisionSite, Document, FunctionDef, Language, PredicateAlias, StateWrite,
};
use crate::decomplex::ast::{line, node_text, normalize_text, span, RawNode};
use anyhow::{Context, Result};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter::{Node, Parser};

pub fn parse_file(file: PathBuf, language: Language) -> Result<Document> {
    let parsed = ParsedDocument::parse(file, language)?;
    let mut function_defs = Vec::new();
    let mut state_writes = Vec::new();
    let mut decision_sites = Vec::new();
    let mut predicate_aliases = Vec::new();
    let mut comparison_uses = Vec::new();
    let mut seen_writes = HashSet::new();
    let mut seen_decisions = HashSet::new();
    let context = ContextState::new(file_owner(&parsed.file));

    collect_facts(
        parsed.tree.root_node(),
        &parsed.source,
        &parsed.file,
        language,
        &context,
        &mut function_defs,
        &mut state_writes,
        &mut decision_sites,
        &mut predicate_aliases,
        &mut comparison_uses,
        &mut seen_writes,
        &mut seen_decisions,
    );

    Ok(Document {
        file: parsed.file.to_string_lossy().to_string(),
        language,
        source: parsed.source.clone(),
        lines: parsed.source.lines().map(ToString::to_string).collect(),
        root: RawNode::from_tree_sitter(parsed.tree.root_node(), &parsed.source),
        function_defs,
        state_writes,
        decision_sites,
        predicate_aliases,
        comparison_uses,
    })
}

struct ParsedDocument {
    file: PathBuf,
    source: String,
    tree: tree_sitter::Tree,
}

impl ParsedDocument {
    fn parse(file: PathBuf, language: Language) -> Result<Self> {
        let source = fs::read_to_string(&file)
            .with_context(|| format!("failed to read {}", file.display()))?;
        let mut parser = Parser::new();
        parser
            .set_language(&language_profile(language).grammar())
            .with_context(|| "failed to initialize tree-sitter parser")?;
        let tree = parser
            .parse(&source, None)
            .with_context(|| format!("tree-sitter produced no tree for {}", file.display()))?;
        Ok(Self { file, source, tree })
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct ContextState {
    file_owner: String,
    owner: Option<String>,
    function: Option<String>,
    pub receiver: Option<String>,
}

impl ContextState {
    fn new(file_owner: String) -> Self {
        Self {
            file_owner,
            owner: None,
            function: None,
            receiver: None,
        }
    }

    fn current_owner(&self) -> String {
        self.owner
            .clone()
            .unwrap_or_else(|| self.file_owner.clone())
    }

    fn current_function(&self) -> String {
        self.function
            .clone()
            .unwrap_or_else(|| "(top-level)".to_string())
    }
}

fn collect_facts(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    function_defs: &mut Vec<FunctionDef>,
    state_writes: &mut Vec<StateWrite>,
    decision_sites: &mut Vec<DecisionSite>,
    predicate_aliases: &mut Vec<PredicateAlias>,
    comparison_uses: &mut Vec<ComparisonUse>,
    seen_writes: &mut HashSet<String>,
    seen_decisions: &mut HashSet<String>,
) {
    let next_context = push_function_context(
        node,
        push_owner_context(node, source, context, language),
        source,
        language,
    );
    record_function_def(node, source, file, language, &next_context, function_defs);
    record_state_write(
        node,
        source,
        file,
        language,
        &next_context,
        state_writes,
        seen_writes,
    );
    record_decision_site(
        node,
        source,
        file,
        language,
        &next_context,
        decision_sites,
        seen_decisions,
    );
    record_predicate_alias(node, source, file, language, predicate_aliases);
    record_comparison_use(node, source, file, language, &next_context, comparison_uses);

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_facts(
            child,
            source,
            file,
            language,
            &next_context,
            function_defs,
            state_writes,
            decision_sites,
            predicate_aliases,
            comparison_uses,
            seen_writes,
            seen_decisions,
        );
    }
}

fn record_function_def(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<FunctionDef>,
) {
    let Some(name) = language_profile(language).function_name(node, source) else {
        return;
    };
    let function = FunctionDef {
        file: file.to_string_lossy().to_string(),
        name,
        owner: context.current_owner(),
        line: line(node),
        span: span(node),
        body: RawNode::from_tree_sitter(node, source),
    };
    let key = (
        function.file.clone(),
        function.owner.clone(),
        function.name.clone(),
        function.line,
    );
    if out.iter().any(|existing| {
        (
            existing.file.clone(),
            existing.owner.clone(),
            existing.name.clone(),
            existing.line,
        ) == key
    }) {
        return;
    }
    out.push(function);
}

fn record_predicate_alias(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    out: &mut Vec<PredicateAlias>,
) {
    let profile = language_profile(language);
    let Some(name) = profile.function_name(node, source) else {
        return;
    };
    let Some(body) = profile.single_expression_body(node) else {
        return;
    };
    let text = profile.normalize_source_text(node_text(body, source));
    if text.is_empty() || text == "nil" || text.len() > 200 {
        return;
    }
    let file_name = file.to_string_lossy().to_string();
    out.push(PredicateAlias {
        name: name.clone(),
        body: text,
        file: file_name,
        defn: name,
        line: line(node),
        span: span(node),
    });
}

fn record_comparison_use(
    node: Node<'_>,
    source: &str,
    file: &Path,
    _language: Language,
    context: &ContextState,
    out: &mut Vec<ComparisonUse>,
) {
    if !comparison_node(language_profile(_language), node, source) {
        return;
    }
    let raw = language_profile(_language).normalize_source_text(node_text(node, source));
    out.push(ComparisonUse {
        canon_source: raw.clone(),
        raw,
        file: file.to_string_lossy().to_string(),
        function: context.current_function(),
        line: line(node),
        span: span(node),
    });
}

fn comparison_node(profile: &dyn LanguageProfile, node: Node<'_>, source: &str) -> bool {
    if profile.comparison_node_kinds().contains(&node.kind()) {
        return profile
            .comparison_operators()
            .contains(&direct_operator_from_source(node, source).as_str());
    }
    if !profile.call_node_kinds().contains(&node.kind()) {
        return false;
    }
    node.child_by_field_name("method")
        .map(|method| node_text(method, source) == "nil?")
        .unwrap_or(false)
}

fn record_decision_site(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<DecisionSite>,
    seen: &mut HashSet<String>,
) {
    let profile = language_profile(language);
    if profile.generated_prelude(node, source) {
        return;
    }

    if profile.boolean_container(node) && boolean_and(profile, node, source) {
        record_conjunction_decision(profile, node, source, file, context, out, seen);
        return;
    }

    if case_node(profile, node) || profile.hidden_case(node) {
        let decision_node = profile.case_source_node(node);
        if profile.predicate_less_case(decision_node) {
            return;
        }
        let patterns = case_patterns(decision_node, source, profile);
        if patterns.len() < 2 {
            return;
        }
        push_decision_site(
            out,
            seen,
            DecisionSite {
                kind: "case_dispatch".to_string(),
                members: patterns,
                file: file.to_string_lossy().to_string(),
                function: context.current_function(),
                line: line(decision_node),
                span: span(decision_node),
                predicate: profile.normalize_source_text(&decision_predicate(
                    profile,
                    decision_node,
                    source,
                )),
            },
        );
    }
}

fn record_conjunction_decision(
    profile: &dyn LanguageProfile,
    mut node: Node<'_>,
    source: &str,
    file: &Path,
    context: &ContextState,
    out: &mut Vec<DecisionSite>,
    seen: &mut HashSet<String>,
) {
    let from_wrapper = profile.parenthesized_wrapper(node);
    if from_wrapper
        && node
            .parent()
            .map(|parent| profile.boolean_container(parent) && boolean_and(profile, parent, source))
            .unwrap_or(false)
    {
        return;
    }

    if from_wrapper {
        if let Some(child) = first_named_child(node) {
            node = child;
        }
    }

    if !from_wrapper
        && node
            .parent()
            .map(|parent| {
                profile.boolean_container(parent)
                    && boolean_and(profile, parent, source)
                    && span(parent) != span(node)
            })
            .unwrap_or(false)
    {
        return;
    }

    let mut members = flatten_boolean_and(profile, node, source)
        .into_iter()
        .map(|child| profile.normalize_source_text(&decision_member_text(child, source)))
        .collect::<Vec<_>>();
    members.sort();
    members.dedup();
    if members.len() < 2 {
        return;
    }

    push_decision_site(
        out,
        seen,
        DecisionSite {
            kind: "conjunction".to_string(),
            members,
            file: file.to_string_lossy().to_string(),
            function: context.current_function(),
            line: conjunction_span(node)[0],
            span: conjunction_span(node),
            predicate: profile.normalize_source_text(node_text(node, source)),
        },
    );
}

fn push_decision_site(out: &mut Vec<DecisionSite>, seen: &mut HashSet<String>, site: DecisionSite) {
    let key = format!(
        "{}\0{}\0{}\0{}\0{:?}\0{}",
        site.file,
        site.function,
        site.kind,
        site.line,
        site.span,
        site.members.join("\0")
    );
    if seen.insert(key) {
        out.push(site);
    }
}

fn push_owner_context(
    node: Node<'_>,
    source: &str,
    context: &ContextState,
    language: Language,
) -> ContextState {
    let profile = language_profile(language);
    let Some(owner) = profile
        .owner_name_from_declaration(node, source)
        .or_else(|| profile.receiver_convention_owner_name(node, source))
    else {
        return context.clone();
    };
    let parent_owner = context.owner.clone();
    let full_owner = if let Some(parent) = parent_owner {
        if parent != owner && !owner.contains("::") {
            format!("{parent}::{owner}")
        } else {
            owner
        }
    } else {
        owner
    };
    let mut next = context.clone();
    next.owner = Some(full_owner);
    next
}

fn push_function_context(
    node: Node<'_>,
    mut context: ContextState,
    source: &str,
    language: Language,
) -> ContextState {
    let profile = language_profile(language);
    let Some(function) = profile.function_name(node, source) else {
        return context;
    };
    let owner = context.current_owner();
    context.function = Some(function);
    context.owner = Some(owner);
    context.receiver = profile.function_receiver_name(node, source);
    context
}

fn record_state_write(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<StateWrite>,
    seen: &mut HashSet<String>,
) {
    let profile = language_profile(language);
    if profile.skip_state_write_node(node) {
        return;
    }

    let Some(assignment) = profile.assignment_target(node) else {
        return;
    };
    let Some(target) = profile.state_target(assignment.lhs, source) else {
        return;
    };
    let target = normalize_target_receiver(target, context);
    if profile.skip_state_write_target(&target) {
        return;
    }

    let file_name = file.to_string_lossy().to_string();
    let owner = context.current_owner();
    let function = context.current_function();
    let source_node = profile.state_write_source_node(node, &assignment);
    let line = line(source_node);
    let key = format!(
        "{}\0{}\0{}\0{}\0{}\0{}",
        file_name, owner, function, line, target.receiver, target.field
    );
    if !seen.insert(key) {
        return;
    }

    out.push(StateWrite {
        field: target.field,
        receiver: target.receiver,
        file: file_name,
        function,
        line,
        span: span(source_node),
        owner,
    });
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct AssignmentTarget<'tree> {
    pub(crate) lhs: Node<'tree>,
    pub(crate) source: Node<'tree>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct Target {
    pub(crate) receiver: String,
    pub(crate) field: String,
}

pub(crate) fn normalize_type_owner(text: &str) -> String {
    let value = text.trim();
    let value = value.trim_start_matches(['&', '*']);
    let value = value
        .replace("const", "")
        .replace("mut", "")
        .replace("var", "");
    let value = value.trim();
    let value = value.split(['(', '{', '<', ' ']).next().unwrap_or("");
    value.split('.').last().unwrap_or("").to_string()
}

fn file_owner(file: &Path) -> String {
    file.file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("(file)")
        .to_string()
}

pub(crate) fn first_named_text(node: Node<'_>, source: &str, kinds: &[&str]) -> Option<String> {
    named_children(node)
        .into_iter()
        .find(|child| kinds.iter().any(|kind| *kind == child.kind()))
        .map(|child| node_text(child, source).to_string())
}

pub(crate) fn first_named_child(node: Node<'_>) -> Option<Node<'_>> {
    let mut cursor = node.walk();
    let child = node.named_children(&mut cursor).next();
    child
}

pub(crate) fn first_named_child_except<'tree>(
    node: Node<'tree>,
    excluded_kind: &str,
) -> Option<Node<'tree>> {
    named_children(node)
        .into_iter()
        .find(|child| child.kind() != excluded_kind)
}

pub(crate) fn first_named_child_with_kind<'tree>(
    node: Node<'tree>,
    kind: &str,
) -> Option<Node<'tree>> {
    named_children(node)
        .into_iter()
        .find(|child| child.kind() == kind)
}

pub(crate) fn named_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.named_children(&mut cursor).collect()
}

pub(crate) fn first_child_kind(node: Node<'_>) -> Option<&str> {
    let mut cursor = node.walk();
    let kind = node.children(&mut cursor).next().map(|child| child.kind());
    kind
}

pub(crate) fn previous_sibling_text(node: Node<'_>, source: &str) -> Option<String> {
    node.prev_sibling()
        .map(|sibling| node_text(sibling, source).to_string())
}

pub(crate) fn previous_sibling_raw_text(node: Node<'_>) -> Option<String> {
    node.prev_sibling()
        .map(|sibling| sibling.kind().to_string())
}

pub(crate) fn next_sibling_raw_text(node: Node<'_>) -> Option<String> {
    node.next_sibling()
        .map(|sibling| sibling.kind().to_string())
}

pub(crate) fn strip_assignment_suffix(text: &str) -> String {
    text.strip_suffix('=').unwrap_or(text).to_string()
}

fn case_node(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    profile.case_node_kinds().contains(&node.kind())
}

fn case_patterns(node: Node<'_>, source: &str, profile: &dyn LanguageProfile) -> Vec<String> {
    let mut out = case_arms(profile, node)
        .into_iter()
        .flat_map(|arm| case_arm_patterns(arm, source, profile))
        .filter(|pattern| !default_case_pattern(profile, pattern))
        .collect::<Vec<_>>();
    out.sort();
    out.dedup();
    out
}

fn case_arms<'tree>(profile: &dyn LanguageProfile, node: Node<'tree>) -> Vec<Node<'tree>> {
    let mut arms = Vec::new();
    let mut stack = named_children(node);
    while let Some(child) = stack.pop() {
        if profile.case_arm_node_kinds().contains(&child.kind()) {
            arms.push(child);
        } else if !profile
            .case_container_stop_node_kinds()
            .contains(&child.kind())
        {
            stack.extend(named_children(child));
        }
    }
    arms.reverse();
    arms
}

fn case_arm_patterns(child: Node<'_>, source: &str, profile: &dyn LanguageProfile) -> Vec<String> {
    if !profile.case_arm_node_kinds().contains(&child.kind()) {
        return Vec::new();
    }
    if node_text(child, source).trim_start().starts_with("else") {
        return Vec::new();
    }

    let patterns = named_children(child)
        .into_iter()
        .filter(|node| profile.case_pattern_node_kinds().contains(&node.kind()))
        .collect::<Vec<_>>();
    if !patterns.is_empty() {
        return profile.case_pattern_texts(&patterns, source);
    }

    let value = child
        .child_by_field_name("value")
        .or_else(|| child.child_by_field_name("pattern"))
        .or_else(|| {
            named_children(child).into_iter().find(|candidate| {
                profile
                    .case_pattern_node_kinds()
                    .contains(&candidate.kind())
            })
        })
        .or_else(|| first_named_child(child));
    value
        .filter(|node| !node.kind().contains("statement") && !node.kind().contains("block"))
        .map(|node| vec![profile.normalize_source_text(node_text(node, source))])
        .unwrap_or_default()
}

fn default_case_pattern(profile: &dyn LanguageProfile, text: &str) -> bool {
    text.is_empty() || profile.default_case_patterns().contains(&text)
}

fn decision_predicate(profile: &dyn LanguageProfile, node: Node<'_>, source: &str) -> String {
    let target = profile.decision_subject(node);
    normalize_text(
        target
            .map(|child| node_text(child, source))
            .unwrap_or_else(|| node_text(node, source)),
    )
}

fn boolean_and(profile: &dyn LanguageProfile, node: Node<'_>, source: &str) -> bool {
    if profile.parenthesized_wrapper(node) {
        return first_named_child(node)
            .map(|child| boolean_and(profile, child, source))
            .unwrap_or(false);
    }
    profile
        .boolean_and_operators()
        .contains(&direct_operator_from_source(node, source).as_str())
}

fn flatten_boolean_and<'tree>(
    profile: &dyn LanguageProfile,
    node: Node<'tree>,
    source: &str,
) -> Vec<Node<'tree>> {
    if !(profile.boolean_container(node) && boolean_and(profile, node, source)) {
        return vec![node];
    }
    if profile.parenthesized_wrapper(node) {
        return first_named_child(node)
            .map(|child| flatten_boolean_and(profile, child, source))
            .unwrap_or_else(|| vec![node]);
    }
    named_children(node)
        .into_iter()
        .flat_map(|child| flatten_boolean_and(profile, child, source))
        .collect()
}

fn conjunction_span(node: Node<'_>) -> [usize; 4] {
    let mut base = span(node);
    if node.kind() == "pattern" && node.start_position().column > 0 {
        base[1] += 1;
    }
    base
}

fn decision_member_text(node: Node<'_>, source: &str) -> String {
    normalize_text(&strip_enclosing_parentheses(node_text(node, source)))
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

pub(crate) fn direct_operator(node: Node<'_>) -> String {
    let mut cursor = node.walk();
    let result = node
        .children(&mut cursor)
        .find(|child| !child.is_named() && !matches!(child.kind(), "(" | ")"))
        .map(|child| child.kind().to_string())
        .unwrap_or_default();
    result
}

fn direct_operator_from_source(node: Node<'_>, source: &str) -> String {
    let mut cursor = node.walk();
    let result = node
        .children(&mut cursor)
        .find(|child| !child.is_named() && !matches!(node_text(*child, source), "(" | ")"))
        .map(|child| node_text(child, source).to_string())
        .unwrap_or_default();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn document(source: &str) -> Document {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        parse_file(file.path().to_path_buf(), Language::Ruby).expect("document")
    }

    #[test]
    fn extracts_ruby_attribute_and_instance_writes() {
        let doc = document(
            r#"
class Box
  def a(n)
    n.storage = :heap
    n.provenance = :heap
    @field = 1
    @counter += 1
    n.count += 1
    e[:kind] = 1
  end
  def self.b(x); x.value = 1; end
end
"#,
        );

        let summary: Vec<(&str, &str, &str, &str)> = doc
            .state_writes
            .iter()
            .map(|write| {
                (
                    write.owner.as_str(),
                    write.function.as_str(),
                    write.receiver.as_str(),
                    write.field.as_str(),
                )
            })
            .collect();

        assert_eq!(
            summary,
            vec![
                ("Box", "a", "n", "storage"),
                ("Box", "a", "n", "provenance"),
                ("Box", "a", "self", "@field"),
                ("Box", "a", "self", "@counter"),
                ("Box", "self.b", "x", "value"),
            ]
        );
    }

    #[test]
    fn extracts_nested_owner_names() {
        let doc = document(
            r#"
module Outer
  class Inner
    def set(node)
      node.state = :ready
    end
  end
end
"#,
        );

        assert_eq!(doc.state_writes.len(), 1);
        assert_eq!(doc.state_writes[0].owner, "Outer::Inner");
        assert_eq!(doc.state_writes[0].function, "set");
        assert_eq!(doc.state_writes[0].field, "state");
    }

    #[test]
    fn language_profiles_own_parser_and_receiver_metadata() {
        assert_eq!(language_profile(Language::Ruby).language(), Language::Ruby);
        assert_eq!(language_profile(Language::C).language(), Language::C);
        assert!(language_profile(Language::C).first_argument_receiver());
        assert!(!language_profile(Language::Lua).first_argument_receiver());

        let mut parser = Parser::new();
        parser
            .set_language(&language_profile(Language::Lua).grammar())
            .expect("lua grammar");
    }

    #[test]
    fn lua_profile_owns_generated_prelude_filter() {
        let source = "local _tl_compat; local ok, compat53 = pcall(require, \"compat53.module\")\nfunction real() end\n";
        let mut parser = Parser::new();
        parser
            .set_language(&language_profile(Language::Lua).grammar())
            .expect("lua grammar");
        let tree = parser.parse(source, None).expect("parse lua");
        let node = tree.root_node().named_child(0).expect("first lua node");

        assert!(language_profile(Language::Lua).generated_prelude(node, source));
        assert!(!language_profile(Language::Ruby).generated_prelude(node, source));
    }
}

#[cfg(test)]
mod c_tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_c_assignment() {
        let mut file = NamedTempFile::new().unwrap();
        file.write_all(b"typedef struct Node { int storage; } Node; void node_set(Node* self) { self->storage = 1; }")
            .unwrap();
        let doc = parse_file(file.path().to_path_buf(), Language::C).unwrap();
        assert_eq!(doc.function_defs[0].owner, "Node");
        assert_eq!(doc.state_writes[0].receiver, "self");
        assert_eq!(doc.state_writes[0].field, "storage");
    }
}

fn normalize_target_receiver(mut target: Target, context: &ContextState) -> Target {
    if let Some(current_receiver) = &context.receiver {
        if &target.receiver == current_receiver {
            target.receiver = "self".to_string();
        } else if target
            .receiver
            .starts_with(&format!("{}.", current_receiver))
        {
            target.receiver = format!(
                "self.{}",
                target
                    .receiver
                    .strip_prefix(&format!("{}.", current_receiver))
                    .unwrap()
            );
        }
    }
    target
}
