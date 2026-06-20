use super::{
    adapters::{language_profile, LanguageProfile},
    CallSite, ComparisonUse, DecisionSite, DispatchSite, Document, FunctionDef, Language,
    PredicateAlias, StateRead, StateWrite,
};
use crate::decomplex::ast::{line, node_text, normalize_text, normalize_tree, span, RawNode};
use anyhow::{Context, Result};
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter::{Node, Parser};

pub fn parse_file(file: PathBuf, language: Language) -> Result<Document> {
    let parsed = ParsedDocument::parse(file, language)?;
    let mut function_defs = Vec::new();
    let mut call_sites = Vec::new();
    let mut state_reads = Vec::new();
    let mut state_writes = Vec::new();
    let mut decision_sites = Vec::new();
    let mut dispatch_sites = Vec::new();
    let mut predicate_aliases = Vec::new();
    let mut comparison_uses = Vec::new();
    let mut seen_writes = HashSet::new();
    let mut seen_reads = HashSet::new();
    let mut seen_calls = HashSet::new();
    let mut seen_decisions = HashSet::new();
    let context = ContextState::new(file_owner(&parsed.file));

    collect_facts(
        parsed.tree.root_node(),
        &parsed.source,
        &parsed.file,
        language,
        &context,
        &mut function_defs,
        &mut call_sites,
        &mut state_reads,
        &mut state_writes,
        &mut decision_sites,
        &mut predicate_aliases,
        &mut comparison_uses,
        &mut seen_writes,
        &mut seen_reads,
        &mut seen_calls,
        &mut seen_decisions,
    );
    language_profile(language).after_collect_facts(&mut function_defs, &call_sites);
    collect_dispatch_sites(
        parsed.tree.root_node(),
        &parsed.source,
        &parsed.file,
        language,
        &context,
        &call_sites,
        &mut dispatch_sites,
    );
    collect_equality_dispatch_sites(&comparison_uses, &call_sites, &mut dispatch_sites);

    Ok(Document {
        file: parsed.file.to_string_lossy().to_string(),
        language,
        source: parsed.source.clone(),
        lines: parsed.source.lines().map(ToString::to_string).collect(),
        root: RawNode::from_tree_sitter(parsed.tree.root_node(), &parsed.source),
        normalized_root: normalize_tree(parsed.tree.root_node(), &parsed.source, language),
        function_defs,
        call_sites,
        state_reads,
        state_writes,
        decision_sites,
        dispatch_sites,
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
    function_line: Option<usize>,
    pub receiver: Option<String>,
    controls: Vec<String>,
}

impl ContextState {
    fn new(file_owner: String) -> Self {
        Self {
            file_owner,
            owner: None,
            function: None,
            function_line: None,
            receiver: None,
            controls: Vec::new(),
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

    fn current_control(&self) -> String {
        self.controls
            .last()
            .cloned()
            .unwrap_or_else(|| "always".to_string())
    }

    fn conditional_context(&self) -> bool {
        self.controls
            .iter()
            .any(|control| matches!(control.as_str(), "conditional" | "iterates"))
    }
}

fn collect_facts(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    function_defs: &mut Vec<FunctionDef>,
    call_sites: &mut Vec<CallSite>,
    state_reads: &mut Vec<StateRead>,
    state_writes: &mut Vec<StateWrite>,
    decision_sites: &mut Vec<DecisionSite>,
    predicate_aliases: &mut Vec<PredicateAlias>,
    comparison_uses: &mut Vec<ComparisonUse>,
    seen_writes: &mut HashSet<String>,
    seen_reads: &mut HashSet<String>,
    seen_calls: &mut HashSet<String>,
    seen_decisions: &mut HashSet<String>,
) {
    let next_context = push_control_context(
        node,
        push_function_context(
            node,
            push_owner_context(node, source, context, language),
            source,
            language,
        ),
        source,
        language,
    );
    record_function_def(node, source, file, language, &next_context, function_defs);
    record_call_site(
        node,
        source,
        file,
        language,
        &next_context,
        call_sites,
        seen_calls,
    );
    record_state_read(
        node,
        source,
        file,
        language,
        &next_context,
        state_reads,
        seen_reads,
    );
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
            call_sites,
            state_reads,
            state_writes,
            decision_sites,
            predicate_aliases,
            comparison_uses,
            seen_writes,
            seen_reads,
            seen_calls,
            seen_decisions,
        );
    }
}

fn collect_dispatch_sites(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    call_sites: &[CallSite],
    out: &mut Vec<DispatchSite>,
) {
    let next_context = push_control_context(
        node,
        push_function_context(
            node,
            push_owner_context(node, source, context, language),
            source,
            language,
        ),
        source,
        language,
    );
    record_dispatch_site(node, source, file, language, &next_context, call_sites, out);

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_dispatch_sites(
            child,
            source,
            file,
            language,
            &next_context,
            call_sites,
            out,
        );
    }
}

fn record_dispatch_site(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    call_sites: &[CallSite],
    out: &mut Vec<DispatchSite>,
) {
    let profile = language_profile(language);
    if !(case_node(profile, node) || profile.hidden_case(node)) {
        return;
    }

    let decision_node = profile.case_source_node(node);
    if profile.predicate_less_case(decision_node) {
        return;
    }
    let predicate = strip_enclosing_parentheses(
        &profile.normalize_source_text(&decision_predicate(profile, decision_node, source)),
    );
    if predicate.is_empty() {
        return;
    }

    let mut arm_members: BTreeMap<String, Vec<String>> = BTreeMap::new();
    for arm in case_arms(profile, decision_node) {
        let members = dispatch_members_inside(
            call_sites,
            &predicate,
            &context.current_function(),
            span(arm),
        );
        if members.is_empty() {
            continue;
        }
        for pattern in case_arm_patterns(arm, source, profile) {
            for variant in dispatch_constant_patterns(&pattern) {
                arm_members
                    .entry(variant)
                    .or_default()
                    .extend(members.clone());
            }
        }
    }
    if arm_members.len() < 2 {
        return;
    }
    for members in arm_members.values_mut() {
        members.sort();
        members.dedup();
    }

    let mut variant_set = arm_members.keys().cloned().collect::<Vec<_>>();
    variant_set.sort();
    let outside = dispatch_members_outside(
        call_sites,
        &predicate,
        &context.current_function(),
        span(decision_node),
    );
    let site = DispatchSite {
        variant_set,
        arm_members,
        outside,
        file: file.to_string_lossy().to_string(),
        function: context.current_function(),
        line: line(decision_node),
        span: span(decision_node),
    };
    if out.iter().any(|existing| existing == &site) {
        return;
    }
    out.push(site);
}

fn collect_equality_dispatch_sites(
    comparisons: &[ComparisonUse],
    call_sites: &[CallSite],
    out: &mut Vec<DispatchSite>,
) {
    let mut groups: BTreeMap<(String, String, String), Vec<(&ComparisonUse, String)>> =
        BTreeMap::new();
    for comparison in comparisons {
        let Some((predicate, variant)) = dispatch_equality(&comparison.canon_source) else {
            continue;
        };
        groups
            .entry((
                comparison.file.clone(),
                comparison.function.clone(),
                predicate,
            ))
            .or_default()
            .push((comparison, variant));
    }

    for ((file, function, predicate), entries) in groups {
        let variant_set = entries
            .iter()
            .map(|(_, variant)| variant.clone())
            .collect::<BTreeSet<_>>();
        if variant_set.len() < 2 {
            continue;
        }

        let mut arm_members: BTreeMap<String, Vec<String>> = BTreeMap::new();
        let mut branch_spans = Vec::new();
        for (comparison, variant) in entries {
            branch_spans.push(comparison.enclosing_span);
            let members = dispatch_members_inside(
                call_sites,
                &predicate,
                &function,
                comparison.enclosing_span,
            );
            if members.is_empty() {
                continue;
            }
            arm_members.entry(variant).or_default().extend(members);
        }
        if arm_members.len() < 2 {
            continue;
        }
        for members in arm_members.values_mut() {
            members.sort();
            members.dedup();
        }

        let outside =
            dispatch_members_outside_any(call_sites, &predicate, &function, &branch_spans);
        let mut variant_set = arm_members.keys().cloned().collect::<Vec<_>>();
        variant_set.sort();
        let span = branch_spans
            .into_iter()
            .reduce(union_span)
            .unwrap_or([0, 0, 0, 0]);
        let site = DispatchSite {
            variant_set,
            arm_members,
            outside,
            file,
            function,
            line: span[0],
            span,
        };
        if out.iter().any(|existing| existing == &site) {
            continue;
        }
        out.push(site);
    }
}

fn dispatch_equality(source: &str) -> Option<(String, String)> {
    for operator in ["===", "=="] {
        let Some((left, right)) = source.split_once(operator) else {
            continue;
        };
        let left = strip_enclosing_parentheses(&normalize_text(left));
        let right = strip_enclosing_parentheses(&normalize_text(right));
        let left_variant = dispatch_constant_pattern(&left);
        let right_variant = dispatch_constant_pattern(&right);
        return match (left_variant, right_variant) {
            (true, false) => Some((right, left)),
            (false, true) => Some((left, right)),
            _ => None,
        };
    }
    None
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
        visibility: language_profile(language).function_visibility(node, source),
        params: language_profile(language).function_params(node, source),
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
    let Some(text) = predicate_body_text(profile, node_text(body, source)) else {
        return;
    };
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

fn predicate_body_text(profile: &dyn LanguageProfile, source: &str) -> Option<String> {
    let mut text = profile.normalize_source_text(source);
    if text.starts_with('{') && text.ends_with('}') {
        text = text[1..text.len() - 1].trim().to_string();
    }
    let text = text
        .strip_prefix("return ")
        .unwrap_or(&text)
        .trim_end_matches(';')
        .trim()
        .to_string();
    if text.contains(';') {
        return None;
    }
    if text.is_empty() || text == "nil" || text.len() > 200 {
        return None;
    }
    if predicate_like_body(&text) {
        Some(text)
    } else {
        None
    }
}

fn predicate_like_body(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    matches!(lower.as_str(), "true" | "false")
        || lower.contains("true")
        || lower.contains("false")
        || lower.contains("null")
        || lower.contains("nil")
        || text.contains("==")
        || text.contains("!=")
        || text.contains("&&")
        || text.contains("||")
        || lower.contains(" and ")
        || lower.contains(" or ")
}

fn record_comparison_use(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<ComparisonUse>,
) {
    let profile = language_profile(language);
    if !comparison_node(profile, node, source) {
        return;
    }
    let raw = profile.normalize_source_text(node_text(node, source));
    out.push(ComparisonUse {
        canon_source: raw.clone(),
        raw,
        file: file.to_string_lossy().to_string(),
        function: context.current_function(),
        line: line(node),
        span: span(node),
        enclosing_span: decision_enclosing_span(profile, node),
    });
}

fn comparison_node(profile: &dyn LanguageProfile, node: Node<'_>, source: &str) -> bool {
    if profile.comparison_node_kinds().contains(&node.kind()) {
        let operator = direct_operator_from_source(node, source);
        return profile.comparison_operators().contains(&operator.as_str())
            || profile
                .comparison_operators()
                .iter()
                .any(|operator| node_text(node, source).contains(operator));
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
                enclosing_span: span(decision_node),
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
            enclosing_span: decision_enclosing_span(profile, node),
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
    context.function_line = Some(line(node));
    context.owner = Some(owner);
    context.receiver = profile.function_receiver_name(node, source);
    context
}

fn push_control_context(
    node: Node<'_>,
    mut context: ContextState,
    source: &str,
    language: Language,
) -> ContextState {
    if let Some(control) = language_profile(language).control_context(node, source) {
        context.controls.push(control);
    }
    context
}

fn record_call_site(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<CallSite>,
    seen: &mut HashSet<String>,
) {
    let profile = language_profile(language);
    let Some(mut target) = profile.call_target(node, source) else {
        return;
    };
    normalize_call_receiver(&mut target, context);
    if profile.noise_call(&target) {
        return;
    }

    let source_node = target.source_node.unwrap_or(node);
    if target.receiver == "self"
        && target.message == context.current_function()
        && context.function_line == Some(line(source_node))
    {
        return;
    }
    let file_name = file.to_string_lossy().to_string();
    let owner = context.current_owner();
    let function = context.current_function();
    let mut call_span = target.span.unwrap_or_else(|| span(source_node));
    if target.message.ends_with('?') && call_span[0] == call_span[2] {
        if let Some(line_text) = source.lines().nth(call_span[0].saturating_sub(1)) {
            if line_text.as_bytes().get(call_span[1]).copied() == Some(b'!') {
                call_span[1] += 1;
            }
        }
    }
    let key = format!(
        "{}\0{}\0{}\0{:?}\0{}\0{}",
        file_name, owner, function, call_span, target.receiver, target.message
    );
    if !seen.insert(key) {
        return;
    }

    out.push(CallSite {
        receiver: target.receiver,
        message: target.message,
        file: file_name,
        function,
        owner,
        line: line(source_node),
        span: call_span,
        conditional: context.conditional_context(),
        arguments: target.arguments,
        control: Some(context.current_control()),
        safe_navigation: target.safe_navigation,
        block: target.block || profile.call_has_block(source_node),
    });
}

fn record_state_read(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<StateRead>,
    seen: &mut HashSet<String>,
) {
    let profile = language_profile(language);
    if profile.assignment_lhs_node(node) {
        return;
    }

    let Some(target) = profile.state_read_target(node, source) else {
        return;
    };
    let target = normalize_target_receiver(target, context);
    if namespace_receiver(&target.receiver) {
        return;
    }

    let file_name = file.to_string_lossy().to_string();
    let owner = context.current_owner();
    let function = context.current_function();
    let line = line(node);
    let key = format!(
        "{}\0{}\0{}\0{:?}\0{}\0{}",
        file_name,
        owner,
        function,
        span(node),
        target.receiver,
        target.field
    );
    if !seen.insert(key) {
        return;
    }

    out.push(StateRead {
        field: target.field,
        receiver: target.receiver,
        file: file_name,
        function,
        line,
        span: span(node),
        owner,
    });
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

#[derive(Clone, Debug, Eq, PartialEq)]
pub(crate) struct CallTarget<'tree> {
    pub(crate) receiver: String,
    pub(crate) message: String,
    pub(crate) arguments: Vec<String>,
    pub(crate) source_node: Option<Node<'tree>>,
    pub(crate) span: Option<[usize; 4]>,
    pub(crate) safe_navigation: bool,
    pub(crate) block: bool,
}

impl<'tree> CallTarget<'tree> {
    pub(crate) fn new(receiver: String, message: String, arguments: Vec<String>) -> Self {
        Self {
            receiver,
            message,
            arguments,
            source_node: None,
            span: None,
            safe_navigation: false,
            block: false,
        }
    }
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

fn namespace_receiver(text: &str) -> bool {
    let receiver = text.trim();
    if receiver.starts_with('@') {
        return true;
    }
    if matches!(receiver, "std" | "builtin" | "build_options")
        || receiver.starts_with("std.")
        || receiver.starts_with("builtin.")
        || receiver.starts_with("build_options.")
    {
        return true;
    }

    matches!(receiver.chars().next(), Some(first) if first.is_ascii_uppercase())
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

fn dispatch_members_inside(
    call_sites: &[CallSite],
    predicate: &str,
    function: &str,
    outer: [usize; 4],
) -> Vec<String> {
    let mut members = dispatch_member_calls(call_sites, predicate, function)
        .into_iter()
        .filter(|call| dispatch_inside_span(call.span, outer))
        .map(dispatch_member_name)
        .collect::<Vec<_>>();
    members.sort();
    members.dedup();
    members
}

fn dispatch_members_outside(
    call_sites: &[CallSite],
    predicate: &str,
    function: &str,
    decision_span: [usize; 4],
) -> Vec<String> {
    let mut members = dispatch_member_calls(call_sites, predicate, function)
        .into_iter()
        .filter(|call| !dispatch_inside_span(call.span, decision_span))
        .map(dispatch_member_name)
        .collect::<Vec<_>>();
    members.sort();
    members.dedup();
    members
}

fn dispatch_members_outside_any(
    call_sites: &[CallSite],
    predicate: &str,
    function: &str,
    decision_spans: &[[usize; 4]],
) -> Vec<String> {
    let mut members = dispatch_member_calls(call_sites, predicate, function)
        .into_iter()
        .filter(|call| {
            !decision_spans
                .iter()
                .any(|span| dispatch_inside_span(call.span, *span))
        })
        .map(dispatch_member_name)
        .collect::<Vec<_>>();
    members.sort();
    members.dedup();
    members
}

fn dispatch_member_calls<'a>(
    call_sites: &'a [CallSite],
    predicate: &str,
    function: &str,
) -> Vec<&'a CallSite> {
    call_sites
        .iter()
        .filter(|call| {
            call.function == function && call.receiver == predicate && !call.message.is_empty()
        })
        .collect()
}

fn dispatch_member_name(call: &CallSite) -> String {
    strip_assignment_suffix(&call.message)
}

fn dispatch_constant_patterns(member: &str) -> Vec<String> {
    member
        .split(',')
        .map(|pattern| {
            pattern
                .trim()
                .strip_prefix("case ")
                .unwrap_or(pattern.trim())
        })
        .filter(|pattern| dispatch_constant_pattern(pattern))
        .map(ToString::to_string)
        .collect()
}

fn dispatch_constant_pattern(pattern: &str) -> bool {
    if pattern.is_empty() {
        return false;
    }
    pattern.replace("::", ".").split(['.', '_']).all(|part| {
        let mut chars = part.chars();
        matches!(chars.next(), Some(first) if first.is_ascii_uppercase())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
}

fn dispatch_inside_span(inner: [usize; 4], outer: [usize; 4]) -> bool {
    let starts_after_or_at = inner[0] > outer[0] || (inner[0] == outer[0] && inner[1] >= outer[1]);
    let ends_before_or_at = inner[2] < outer[2] || (inner[2] == outer[2] && inner[3] <= outer[3]);
    starts_after_or_at && ends_before_or_at
}

fn union_span(left: [usize; 4], right: [usize; 4]) -> [usize; 4] {
    let starts_before_or_at = left[0] < right[0] || (left[0] == right[0] && left[1] <= right[1]);
    let ends_after_or_at = left[2] > right[2] || (left[2] == right[2] && left[3] >= right[3]);
    [
        if starts_before_or_at {
            left[0]
        } else {
            right[0]
        },
        if starts_before_or_at {
            left[1]
        } else {
            right[1]
        },
        if ends_after_or_at { left[2] } else { right[2] },
        if ends_after_or_at { left[3] } else { right[3] },
    ]
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

fn decision_enclosing_span(profile: &dyn LanguageProfile, node: Node<'_>) -> [usize; 4] {
    let mut parent = node.parent();
    let mut seen = HashSet::new();
    while let Some(current) = parent {
        let key = format!("{:?}\0{}", span(current), current.kind());
        if !seen.insert(key) {
            break;
        }
        if branch_like_node(profile, current) {
            return span(current);
        }
        parent = current.parent();
    }
    span(node)
}

fn branch_like_node(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    profile.branch_node_kinds().contains(&node.kind())
        || profile.case_node_kinds().contains(&node.kind())
        || matches!(
            node.kind(),
            "if" | "unless"
                | "if_statement"
                | "if_expression"
                | "while"
                | "while_statement"
                | "for_statement"
                | "foreach_statement"
                | "for_expression"
        )
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
    target.receiver = canonical_self_receiver(&target.receiver);
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

fn normalize_call_receiver(target: &mut CallTarget<'_>, context: &ContextState) {
    target.receiver = canonical_self_receiver(&target.receiver);
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
}

fn canonical_self_receiver(receiver: &str) -> String {
    match receiver {
        "self" | "this" | "$this" => "self".to_string(),
        _ if receiver.starts_with("this.") => format!(
            "self.{}",
            receiver.strip_prefix("this.").unwrap_or_default()
        ),
        _ if receiver.starts_with("$this.") => format!(
            "self.{}",
            receiver.strip_prefix("$this.").unwrap_or_default()
        ),
        _ => receiver.to_string(),
    }
}
