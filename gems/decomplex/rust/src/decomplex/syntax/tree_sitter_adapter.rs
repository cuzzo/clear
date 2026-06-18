use super::{
    ComparisonUse, DecisionSite, Document, FunctionDef, Language, PredicateAlias, StateWrite,
};
use crate::decomplex::ast::{line, node_text, normalize_text, span, RawNode};
use anyhow::{Context, Result};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter::{Language as TreeSitterLanguage, Node, Parser};

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

fn language_grammar(language: Language) -> TreeSitterLanguage {
    match language {
        Language::Ruby => tree_sitter_ruby::LANGUAGE.into(),
        Language::Python => tree_sitter_python::LANGUAGE.into(),
        Language::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
        Language::Java => tree_sitter_java::LANGUAGE.into(),
        Language::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        Language::Swift => tree_sitter_swift::LANGUAGE.into(),
        Language::Kotlin => tree_sitter_kotlin_ng::LANGUAGE.into(),
        Language::Go => tree_sitter_go::LANGUAGE.into(),
        Language::Rust => tree_sitter_rust::LANGUAGE.into(),
        Language::Zig => tree_sitter_zig::LANGUAGE.into(),
        Language::Lua => tree_sitter_lua::LANGUAGE.into(),
        Language::C => tree_sitter_c::LANGUAGE.into(),
        Language::Cpp => tree_sitter_cpp::LANGUAGE.into(),
        Language::CSharp => tree_sitter_c_sharp::LANGUAGE.into(),
    }
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
            .set_language(&language_grammar(language))
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
    _language: Language,
    context: &ContextState,
    out: &mut Vec<FunctionDef>,
) {
    let Some(name) = function_name(node, source) else {
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
    _language: Language,
    out: &mut Vec<PredicateAlias>,
) {
    if !matches!(node.kind(), "method" | "function_definition") {
        return;
    }
    let Some(name) = function_name(node, source) else {
        return;
    };
    let Some(body) = method_single_expression_body(node) else {
        return;
    };
    let text = normalize_text(node_text(body, source));
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
    if !comparison_node(node, source) {
        return;
    }
    let raw = normalize_text(node_text(node, source));
    out.push(ComparisonUse {
        canon_source: raw.clone(),
        raw,
        file: file.to_string_lossy().to_string(),
        function: context.current_function(),
        line: line(node),
        span: span(node),
    });
}

fn comparison_node(node: Node<'_>, source: &str) -> bool {
    if matches!(node.kind(), "binary" | "binary_expression") {
        return matches!(
            direct_operator_from_source(node, source).as_str(),
            "==" | "!="
        );
    }
    if node.kind() != "call" {
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
    if generated_lua_compat_prelude(node, source, language) {
        return;
    }

    if boolean_container(node) && boolean_and(node, source) {
        record_conjunction_decision(node, source, file, context, out, seen);
        return;
    }

    if case_node(node) || hidden_case(node) {
        let decision_node = case_source_node(node);
        if ruby_predicate_less_case(decision_node) {
            return;
        }
        let patterns = case_patterns(decision_node, source);
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
                predicate: decision_predicate(decision_node, source),
            },
        );
    }
}

fn generated_lua_compat_prelude(node: Node<'_>, source: &str, language: Language) -> bool {
    if language != Language::Lua {
        return false;
    }
    if line(node) != 1 {
        return false;
    }
    let first_line = source.lines().next().unwrap_or("");
    first_line.contains("_tl_compat") && first_line.contains("compat53.module")
}

fn record_conjunction_decision(
    mut node: Node<'_>,
    source: &str,
    file: &Path,
    context: &ContextState,
    out: &mut Vec<DecisionSite>,
    seen: &mut HashSet<String>,
) {
    let from_wrapper = parenthesized_wrapper(node);
    if from_wrapper
        && node
            .parent()
            .map(|parent| boolean_container(parent) && boolean_and(parent, source))
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
                boolean_container(parent)
                    && boolean_and(parent, source)
                    && span(parent) != span(node)
            })
            .unwrap_or(false)
    {
        return;
    }

    let mut members = flatten_boolean_and(node, source)
        .into_iter()
        .map(|child| decision_member_text(child, source))
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
            predicate: normalize_text(node_text(node, source)),
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

fn method_single_expression_body(node: Node<'_>) -> Option<Node<'_>> {
    let mut cursor = node.walk();
    if node.children(&mut cursor).any(|child| child.kind() == "=") {
        let named = named_children(node);
        return named.last().copied();
    }

    let body = node.child_by_field_name("body").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "body_statement")
    })?;
    let statements: Vec<Node<'_>> = named_children(body)
        .into_iter()
        .filter(|child| !matches!(child.kind(), "comment" | "heredoc_body"))
        .collect();
    if statements.len() == 1 {
        statements.first().copied()
    } else {
        None
    }
}

fn push_owner_context(
    node: Node<'_>,
    source: &str,
    context: &ContextState,
    language: Language,
) -> ContextState {
    let Some(owner) = owner_name_from_declaration(node, source)
        .or_else(|| receiver_convention_owner_name(node, source, language))
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
    let Some(function) = function_name(node, source) else {
        return context;
    };
    let owner = context.current_owner();
    context.function = Some(function);
    context.owner = Some(owner);
    context.receiver = function_receiver_name(node, source, language);
    context
}

fn record_state_write(
    node: Node<'_>,
    source: &str,
    file: &Path,
    _language: Language,
    context: &ContextState,
    out: &mut Vec<StateWrite>,
    seen: &mut HashSet<String>,
) {
    if node.kind() == "operator_assignment" || node.kind() == "augmented_assignment" {
        return;
    }

    let Some(assignment) = assignment_target(node) else {
        return;
    };
    let Some(target) = state_target(assignment.lhs, source) else {
        return;
    };
    let target = normalize_target_receiver(target, context);
    if target.field == "[]" || target.field.starts_with('$') {
        return;
    }

    let file_name = file.to_string_lossy().to_string();
    let owner = context.current_owner();
    let function = context.current_function();
    let line = line(assignment.source);
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
        span: span(assignment.source),
        owner,
    });
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct AssignmentTarget<'tree> {
    lhs: Node<'tree>,
    source: Node<'tree>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct Target {
    receiver: String,
    field: String,
}

fn assignment_target(node: Node<'_>) -> Option<AssignmentTarget<'_>> {
    match node.kind() {
        "assignment" | "assignment_expression" | "assignment_statement" => {
            let lhs = node
                .child_by_field_name("left")
                .or_else(|| first_named_child(node))?;
            Some(AssignmentTarget { lhs, source: node })
        }
        "instance_variable" | "global_variable" if assignment_lhs_node(node) => {
            Some(AssignmentTarget {
                lhs: node,
                source: node.parent().unwrap_or(node),
            })
        }
        _ => None,
    }
}

fn assignment_lhs_node(node: Node<'_>) -> bool {
    if previous_sibling_raw_text(node).as_deref() == Some(":") {
        return false;
    }
    matches!(
        next_sibling_raw_text(node).as_deref(),
        Some("=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&&=" | "||=")
    )
}

fn state_target(lhs: Node<'_>, source: &str) -> Option<Target> {
    if previous_sibling_text(lhs, source).as_deref() == Some(":") {
        return None;
    }

    match lhs.kind() {
        "call" => {
            let receiver = lhs.child_by_field_name("receiver")?;
            let method = lhs.child_by_field_name("method")?;
            Some(Target {
                receiver: normalize_text(node_text(receiver, source)),
                field: strip_assignment_suffix(node_text(method, source)),
            })
        }
        "field"
        | "field_access"
        | "selector_expression"
        | "member_expression"
        | "member_access_expression"
        | "attribute"
        | "field_expression"
        | "navigation_expression"
        | "directly_assignable_expression"
        | "expression_list" => {
            let object = lhs
                .child_by_field_name("object")
                .or_else(|| lhs.child_by_field_name("receiver"))
                .or_else(|| lhs.child_by_field_name("expression"))
                .or_else(|| lhs.child_by_field_name("operand"))
                .or_else(|| lhs.child_by_field_name("value"))
                .or_else(|| lhs.child_by_field_name("argument"))
                .or_else(|| first_named_child_except(lhs, "navigation_suffix"))?;
            let field = lhs
                .child_by_field_name("field")
                .or_else(|| lhs.child_by_field_name("property"))
                .or_else(|| lhs.child_by_field_name("name"))
                .or_else(|| lhs.child_by_field_name("suffix"))
                .or_else(|| first_named_child_with_kind(lhs, "navigation_suffix"))
                .or_else(|| last_named_child(lhs))?;
            let field_text = member_field_text(field, source)?;
            Some(Target {
                receiver: normalize_text(node_text(object, source)),
                field: strip_assignment_suffix(&field_text),
            })
        }
        "instance_variable" | "global_variable" => Some(Target {
            receiver: "self".to_string(),
            field: node_text(lhs, source).to_string(),
        }),
        _ => None,
    }
}

fn function_name(node: Node<'_>, source: &str) -> Option<String> {
    match node.kind() {
        "method"
        | "function_definition"
        | "function_declaration"
        | "method_definition"
        | "function_item" => node
            .child_by_field_name("name")
            .map(|name| node_text(name, source).to_string())
            .or_else(|| declarator_name(node.child_by_field_name("declarator"), source))
            .or_else(|| {
                first_named_text(
                    node,
                    source,
                    &["identifier", "constant", "property_identifier"],
                )
            }),
        "singleton_method" => {
            let name = node
                .child_by_field_name("name")
                .map(|name| node_text(name, source).to_string())
                .or_else(|| {
                    named_children(node)
                        .into_iter()
                        .rev()
                        .find(|child| {
                            matches!(
                                child.kind(),
                                "identifier" | "field_identifier" | "property_identifier"
                            )
                        })
                        .map(|child| node_text(child, source).to_string())
                })?;
            Some(format!("self.{name}"))
        }
        "method_declaration" => node
            .child_by_field_name("name")
            .map(|name| node_text(name, source).to_string())
            .or_else(|| first_named_text(node, source, &["field_identifier", "identifier"])),
        "body_statement" if first_child_kind(node) == Some("def") => {
            hidden_ruby_method_name(node, source)
        }
        "argument_list" if first_child_kind(node) == Some("def") => inline_def_name(node, source),
        _ => None,
    }
}

fn declarator_name(node: Option<Node<'_>>, source: &str) -> Option<String> {
    let mut pending = vec![node?];
    let mut seen = HashSet::new();
    while let Some(current) = pending.pop() {
        let key = format!("{:?}\0{}", span(current), current.kind());
        if !seen.insert(key) {
            continue;
        }
        if matches!(
            current.kind(),
            "identifier" | "simple_identifier" | "field_identifier" | "property_identifier"
        ) {
            return Some(node_text(current, source).to_string());
        }
        let mut children = named_children(current);
        children.reverse();
        pending.extend(children);
    }
    None
}

fn owner_name_from_declaration(node: Node<'_>, source: &str) -> Option<String> {
    if node.kind() == "body_statement" && matches!(first_child_kind(node), Some("class" | "module"))
    {
        return first_named_text(node, source, &["constant", "identifier", "type_identifier"]);
    }

    match node.kind() {
        "class" | "module" | "class_definition" | "class_declaration" | "class_specifier" => node
            .child_by_field_name("name")
            .map(|name| node_text(name, source).to_string())
            .or_else(|| {
                first_named_text(node, source, &["constant", "identifier", "type_identifier"])
            }),
        "impl_item" | "impl_block" => impl_owner_name(node, source),
        "struct_item" | "struct_spec" | "struct_specifier" | "type_spec" | "type_declaration" => {
            node.child_by_field_name("name")
                .map(|name| node_text(name, source).to_string())
                .or_else(|| first_named_text(node, source, &["type_identifier", "identifier"]))
        }
        _ => None,
    }
}

fn impl_owner_name(node: Node<'_>, source: &str) -> Option<String> {
    let r#type = node.child_by_field_name("type").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| child.kind().contains("type") || child.kind().contains("identifier"))
    })?;
    Some(normalize_type_owner(node_text(r#type, source)))
}

fn normalize_type_owner(text: &str) -> String {
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

fn hidden_ruby_method_name(node: Node<'_>, source: &str) -> Option<String> {
    let children = named_children(node);
    let receiver_index = children
        .iter()
        .position(|child| matches!(child.kind(), "self" | "constant"));
    let search: Vec<Node<'_>> = if let Some(index) = receiver_index {
        children.into_iter().skip(index + 1).collect()
    } else {
        children
    };
    let name = search
        .into_iter()
        .find(|child| {
            matches!(
                child.kind(),
                "identifier" | "field_identifier" | "property_identifier"
            )
        })
        .map(|child| node_text(child, source).to_string())?;
    if receiver_index.is_some() {
        Some(format!("self.{name}"))
    } else {
        Some(name)
    }
}

fn inline_def_name(node: Node<'_>, source: &str) -> Option<String> {
    hidden_ruby_method_name(node, source)
}

fn file_owner(file: &Path) -> String {
    file.file_stem()
        .and_then(|stem| stem.to_str())
        .filter(|stem| !stem.is_empty())
        .unwrap_or("(file)")
        .to_string()
}

fn first_named_text(node: Node<'_>, source: &str, kinds: &[&str]) -> Option<String> {
    named_children(node)
        .into_iter()
        .find(|child| kinds.iter().any(|kind| *kind == child.kind()))
        .map(|child| node_text(child, source).to_string())
}

fn first_named_child(node: Node<'_>) -> Option<Node<'_>> {
    let mut cursor = node.walk();
    let child = node.named_children(&mut cursor).next();
    child
}

fn last_named_child(node: Node<'_>) -> Option<Node<'_>> {
    named_children(node).into_iter().last()
}

fn first_named_child_except<'tree>(node: Node<'tree>, excluded_kind: &str) -> Option<Node<'tree>> {
    named_children(node)
        .into_iter()
        .find(|child| child.kind() != excluded_kind)
}

fn first_named_child_with_kind<'tree>(node: Node<'tree>, kind: &str) -> Option<Node<'tree>> {
    named_children(node)
        .into_iter()
        .find(|child| child.kind() == kind)
}

fn named_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.named_children(&mut cursor).collect()
}

fn first_child_kind(node: Node<'_>) -> Option<&str> {
    let mut cursor = node.walk();
    let kind = node.children(&mut cursor).next().map(|child| child.kind());
    kind
}

fn previous_sibling_text(node: Node<'_>, source: &str) -> Option<String> {
    node.prev_sibling()
        .map(|sibling| node_text(sibling, source).to_string())
}

fn previous_sibling_raw_text(node: Node<'_>) -> Option<String> {
    node.prev_sibling()
        .map(|sibling| sibling.kind().to_string())
}

fn next_sibling_raw_text(node: Node<'_>) -> Option<String> {
    node.next_sibling()
        .map(|sibling| sibling.kind().to_string())
}

fn member_field_text(field: Node<'_>, source: &str) -> Option<String> {
    if field.kind() == "navigation_suffix" {
        let suffix = field
            .child_by_field_name("suffix")
            .or_else(|| {
                named_children(field).into_iter().find(|child| {
                    matches!(
                        child.kind(),
                        "identifier"
                            | "simple_identifier"
                            | "field_identifier"
                            | "property_identifier"
                    )
                })
            })
            .or_else(|| last_named_child(field))?;
        let text = node_text(suffix, source)
            .trim_start_matches(['.', '?'])
            .trim_start_matches("->");
        return (!text.is_empty()).then(|| text.to_string());
    }

    Some(
        node_text(field, source)
            .trim_start_matches(['.', '?'])
            .trim_start_matches("->")
            .to_string(),
    )
}

fn strip_assignment_suffix(text: &str) -> String {
    text.strip_suffix('=').unwrap_or(text).to_string()
}

fn case_node(node: Node<'_>) -> bool {
    matches!(
        node.kind(),
        "case"
            | "when_expression"
            | "switch_statement"
            | "switch_expression"
            | "match_statement"
            | "match_expression"
    )
}

fn hidden_case(node: Node<'_>) -> bool {
    matches!(
        node.kind(),
        "body_statement" | "block_body" | "argument_list"
    ) && first_child_kind(node) == Some("case")
}

fn case_source_node(node: Node<'_>) -> Node<'_> {
    if !hidden_case(node) {
        return node;
    }
    let mut cursor = node.walk();
    let result = node
        .children(&mut cursor)
        .find(|child| child.kind() == "case")
        .unwrap_or(node);
    result
}

fn ruby_predicate_less_case(node: Node<'_>) -> bool {
    (node.kind() == "case" || hidden_case(node)) && decision_subject(node).is_none()
}

fn case_patterns(node: Node<'_>, source: &str) -> Vec<String> {
    let mut out = case_arms(node)
        .into_iter()
        .flat_map(|arm| case_arm_patterns(arm, source))
        .filter(|pattern| !default_case_pattern(pattern))
        .collect::<Vec<_>>();
    out.sort();
    out.dedup();
    out
}

fn case_arms(node: Node<'_>) -> Vec<Node<'_>> {
    let mut arms = Vec::new();
    let mut stack = named_children(node);
    while let Some(child) = stack.pop() {
        if matches!(
            child.kind(),
            "when"
                | "switch_case"
                | "case_clause"
                | "expression_case"
                | "case_statement"
                | "switch_section"
                | "switch_block_statement_group"
                | "switch_entry"
                | "when_entry"
                | "match_arm"
        ) {
            arms.push(child);
        } else if !matches!(
            child.kind(),
            "method"
                | "function_definition"
                | "function_declaration"
                | "method_definition"
                | "method_declaration"
                | "function_item"
                | "class"
                | "module"
                | "class_definition"
                | "class_declaration"
        ) {
            stack.extend(named_children(child));
        }
    }
    arms.reverse();
    arms
}

fn case_arm_patterns(child: Node<'_>, source: &str) -> Vec<String> {
    match child.kind() {
        "when" | "match_arm" => {
            let mut patterns = named_children(child)
                .into_iter()
                .filter(|node| matches!(node.kind(), "pattern" | "case_pattern" | "match_pattern"))
                .collect::<Vec<_>>();
            if patterns.is_empty() {
                patterns = child
                    .child_by_field_name("pattern")
                    .or_else(|| first_named_child(child))
                    .into_iter()
                    .collect();
            }
            ruby_when_pattern_texts(&patterns, source)
        }
        "switch_case"
        | "case_clause"
        | "expression_case"
        | "case_statement"
        | "switch_section"
        | "switch_block_statement_group"
        | "switch_entry"
        | "when_entry" => {
            if node_text(child, source).trim_start().starts_with("else") {
                return Vec::new();
            }
            let value = child
                .child_by_field_name("value")
                .or_else(|| child.child_by_field_name("pattern"))
                .or_else(|| {
                    named_children(child)
                        .into_iter()
                        .find(|candidate| candidate.kind() == "when_condition")
                })
                .or_else(|| {
                    named_children(child)
                        .into_iter()
                        .find(|candidate| candidate.kind() == "switch_pattern")
                })
                .or_else(|| first_named_child(child));
            value
                .filter(|node| !node.kind().contains("statement") && !node.kind().contains("block"))
                .map(|node| vec![normalize_text(node_text(node, source))])
                .unwrap_or_default()
        }
        _ => Vec::new(),
    }
}

fn ruby_when_pattern_texts(patterns: &[Node<'_>], source: &str) -> Vec<String> {
    if patterns.is_empty() {
        return Vec::new();
    }
    let texts = patterns
        .iter()
        .map(|pattern| normalize_text(node_text(*pattern, source)))
        .collect::<Vec<_>>();
    if !texts.iter().any(|text| text.starts_with('*')) {
        return texts;
    }

    let mut out = Vec::new();
    let mut pending_plain = Vec::new();
    for (index, text) in texts.iter().enumerate() {
        if text.starts_with('*') {
            if !pending_plain.is_empty() {
                out.push(pending_plain.join(", "));
                pending_plain.clear();
            }
            if texts.len() == 1 || index > 0 {
                out.push(text.trim_start_matches('*').to_string());
            } else {
                out.push(text.clone());
            }
        } else {
            pending_plain.push(text.clone());
        }
    }
    if !pending_plain.is_empty() {
        out.push(pending_plain.join(", "));
    }
    out
}

fn default_case_pattern(text: &str) -> bool {
    matches!(text, "" | "_" | "default")
}

fn decision_predicate(node: Node<'_>, source: &str) -> String {
    let target = decision_subject(node);
    normalize_text(
        target
            .map(|child| node_text(child, source))
            .unwrap_or_else(|| node_text(node, source)),
    )
}

fn decision_subject(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("value")
        .or_else(|| node.child_by_field_name("subject"))
        .or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| child.kind() == "when_subject")
        })
        .or_else(|| node.child_by_field_name("condition"))
        .or_else(|| {
            named_children(node).into_iter().find(|child| {
                !matches!(
                    child.kind(),
                    "when"
                        | "switch_case"
                        | "case_clause"
                        | "expression_case"
                        | "case_statement"
                        | "switch_section"
                        | "switch_block_statement_group"
                        | "switch_entry"
                        | "when_entry"
                        | "match_arm"
                        | "else"
                        | "then"
                        | "comment"
                )
            })
        })
}

fn boolean_container(node: Node<'_>) -> bool {
    if matches!(
        node.kind(),
        "binary" | "binary_expression" | "boolean_operator"
    ) {
        return true;
    }
    if parenthesized_wrapper(node) {
        return first_named_child(node)
            .map(boolean_container)
            .unwrap_or(false);
    }
    if !matches!(
        node.kind(),
        "body_statement" | "block_body" | "statement" | "pattern" | "argument_list"
    ) {
        return false;
    }
    if !matches!(direct_operator(node).as_str(), "&&" | "and") {
        return false;
    }
    if named_children(node).len() < 2 {
        return false;
    }
    let mut cursor = node.walk();
    let result = node
        .children(&mut cursor)
        .all(|child| child.is_named() || matches!(child.kind(), "&&" | "and" | "(" | ")"));
    result
}

fn boolean_and(node: Node<'_>, source: &str) -> bool {
    if parenthesized_wrapper(node) {
        return first_named_child(node)
            .map(|child| boolean_and(child, source))
            .unwrap_or(false);
    }
    matches!(
        direct_operator_from_source(node, source).as_str(),
        "&&" | "and"
    )
}

fn flatten_boolean_and<'tree>(node: Node<'tree>, source: &str) -> Vec<Node<'tree>> {
    if !(boolean_container(node) && boolean_and(node, source)) {
        return vec![node];
    }
    if parenthesized_wrapper(node) {
        return first_named_child(node)
            .map(|child| flatten_boolean_and(child, source))
            .unwrap_or_else(|| vec![node]);
    }
    named_children(node)
        .into_iter()
        .flat_map(|child| flatten_boolean_and(child, source))
        .collect()
}

fn parenthesized_wrapper(node: Node<'_>) -> bool {
    matches!(
        node.kind(),
        "parenthesized_statements" | "parenthesized_expression"
    ) && named_children(node).len() == 1
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

fn direct_operator(node: Node<'_>) -> String {
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
}

#[cfg(test)]
mod c_tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_c_assignment() {
        let mut file = NamedTempFile::new().unwrap();
        file.write_all(b"void foo() { handle->loop = 1; }").unwrap();
        let doc = parse_file(file.path().to_path_buf(), Language::C).unwrap();
        assert!(!doc.state_writes.is_empty());
    }
}

fn first_argument_receiver_language(language: Language) -> bool {
    matches!(language, Language::C)
}

fn first_argument_receiver_parameter(node: Node<'_>, source: &str) -> Option<(String, String)> {
    let params = node
        .child_by_field_name("declarator")
        .and_then(|d| d.child_by_field_name("parameters"))
        .or_else(|| node.child_by_field_name("parameters"))
        .or_else(|| first_named_child_with_kind(node, "parameter_list"))
        .or_else(|| {
            node.child_by_field_name("declarator")
                .and_then(|d| first_named_child_with_kind(d, "parameter_list"))
        })?;

    let first = first_named_child_with_kind(params, "parameter_declaration")?;

    let type_node = named_children(first).into_iter().find(|child| {
        matches!(
            child.kind(),
            "type_identifier"
                | "primitive_type"
                | "qualified_identifier"
                | "scoped_type_identifier"
        )
    })?;

    let name_node = named_children(first)
        .into_iter()
        .rev()
        .find(|child| matches!(child.kind(), "identifier" | "field_identifier"))
        .or_else(|| first_named_child(first))?;

    Some((
        node_text(type_node, source).to_string(),
        node_text(name_node, source).to_string(),
    ))
}

fn snake_case_type_name(type_str: &str) -> String {
    let mut parts = type_str.split("::");
    let mut last = parts.last().unwrap_or(type_str).to_string();
    // Simplified snake casing logic
    last.make_ascii_lowercase();
    last
}

fn receiver_convention_owner_name(
    node: Node<'_>,
    source: &str,
    language: Language,
) -> Option<String> {
    if !first_argument_receiver_language(language) || node.kind() != "function_definition" {
        return None;
    }

    let (type_name, _) = first_argument_receiver_parameter(node, source)?;
    let type_name = normalize_type_owner(&type_name);
    let name = function_name(node, source)?;

    if name.starts_with(&snake_case_type_name(&type_name)) {
        Some(type_name)
    } else if type_name.ends_with("_t") && name.starts_with(type_name.strip_suffix("_t").unwrap()) {
        Some(type_name)
    } else {
        None
    }
}

fn function_receiver_name(node: Node<'_>, source: &str, language: Language) -> Option<String> {
    // Only handling C convention for now
    if first_argument_receiver_language(language) && node.kind() == "function_definition" {
        if let Some((_, name)) = first_argument_receiver_parameter(node, source) {
            return Some(name);
        }
    }
    None
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
