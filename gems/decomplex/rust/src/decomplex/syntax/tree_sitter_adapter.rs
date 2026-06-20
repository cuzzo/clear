use super::{
    adapters::{
        false_simplicity_lexicon::{false_simplicity_lexicon, FalseSimplicityLexicon},
        language_profile, LanguageProfile,
    },
    BranchArm, BranchDecision, CallSite, ComparisonUse, DecisionSite, DispatchSite, Document,
    FunctionDef, Language, OwnerDef, PredicateAlias, SemanticEffectSite, StateDeclaration,
    StateRead, StateWrite,
};
use crate::decomplex::ast::{line, node_text, normalize_text, normalize_tree, span, RawNode};
use crate::decomplex::syntax::complexity::local_complexity_scores;
use anyhow::{Context, Result};
use std::borrow::Cow;
use std::collections::{BTreeMap, BTreeSet, HashSet};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tree_sitter::{Node, Parser};

pub fn parse_file(file: PathBuf, language: Language) -> Result<Document> {
    parse_file_with_options(
        file,
        language,
        ParseOptions {
            normalized_root: true,
        },
    )
}

pub(crate) fn parse_file_for_report(file: PathBuf, language: Language) -> Result<Document> {
    parse_file_with_options(
        file,
        language,
        ParseOptions {
            normalized_root: language_profile(language).report_requires_normalized_root(),
        },
    )
}

#[derive(Clone, Copy)]
struct ParseOptions {
    normalized_root: bool,
}

fn parse_file_with_options(
    file: PathBuf,
    language: Language,
    options: ParseOptions,
) -> Result<Document> {
    let profile = rust_profile_enabled();
    let total_started = Instant::now();
    let file_label = file.to_string_lossy().to_string();
    let parsed_started = Instant::now();
    let parsed = ParsedDocument::parse(file, language)?;
    profile_parse_phase(
        profile,
        &file_label,
        "read_tree_sitter",
        parsed_started.elapsed(),
    );
    let mut function_defs = Vec::new();
    let mut owner_defs = Vec::new();
    let mut call_sites = Vec::new();
    let mut state_declarations = Vec::new();
    let mut state_reads = Vec::new();
    let mut state_writes = Vec::new();
    let mut decision_sites = Vec::new();
    let mut branch_decisions = Vec::new();
    let mut branch_arms = Vec::new();
    let mut dispatch_sites = Vec::new();
    let mut predicate_aliases = Vec::new();
    let mut comparison_uses = Vec::new();
    let mut seen_writes = HashSet::new();
    let mut seen_reads = HashSet::new();
    let mut seen_calls = HashSet::new();
    let mut seen_decisions = HashSet::new();
    let mut context = ContextState::new(file_owner(&parsed.file));
    if language == Language::Ruby {
        let started = Instant::now();
        context.immutable_readers = ruby_immutable_struct_readers(&parsed.source);
        profile_parse_phase(
            profile,
            &file_label,
            "ruby_immutable_readers",
            started.elapsed(),
        );
    }

    let started = Instant::now();
    collect_facts(
        parsed.tree.root_node(),
        &parsed.source,
        &parsed.file,
        language,
        &context,
        &mut function_defs,
        &mut owner_defs,
        &mut call_sites,
        &mut state_declarations,
        &mut state_reads,
        &mut state_writes,
        &mut decision_sites,
        &mut branch_decisions,
        &mut branch_arms,
        &mut predicate_aliases,
        &mut comparison_uses,
        &mut seen_writes,
        &mut seen_reads,
        &mut seen_calls,
        &mut seen_decisions,
    );
    profile_parse_phase(profile, &file_label, "collect_facts", started.elapsed());
    let started = Instant::now();
    collect_implicit_state_accesses(
        parsed.tree.root_node(),
        &parsed.source,
        &parsed.file,
        language,
        &context,
        &function_defs,
        &state_declarations,
        &mut state_reads,
        &mut state_writes,
        &mut seen_reads,
        &mut seen_writes,
    );
    profile_parse_phase(
        profile,
        &file_label,
        "collect_implicit_state_accesses",
        started.elapsed(),
    );
    let started = Instant::now();
    language_profile(language).after_collect_facts(&mut function_defs, &call_sites);
    profile_parse_phase(
        profile,
        &file_label,
        "after_collect_facts",
        started.elapsed(),
    );
    let started = Instant::now();
    collect_dispatch_sites(
        parsed.tree.root_node(),
        &parsed.source,
        &parsed.file,
        language,
        &context,
        &call_sites,
        &mut dispatch_sites,
    );
    profile_parse_phase(
        profile,
        &file_label,
        "collect_dispatch_sites",
        started.elapsed(),
    );
    let started = Instant::now();
    collect_equality_dispatch_sites(&comparison_uses, &call_sites, &mut dispatch_sites);
    profile_parse_phase(
        profile,
        &file_label,
        "collect_equality_dispatch_sites",
        started.elapsed(),
    );
    let profile = language_profile(language);
    let started = Instant::now();
    let mut semantic_effect_sites = semantic_effect_sites_from_calls(language, &call_sites);
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "semantic_effects_from_calls",
        started.elapsed(),
    );
    let started = Instant::now();
    semantic_effect_sites.extend(profile.structural_semantic_effect_sites(
        parsed.tree.root_node(),
        &parsed.source,
        &parsed.file,
        &function_defs,
        &state_reads,
        &state_writes,
    ));
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "structural_semantic_effects",
        started.elapsed(),
    );
    let started = Instant::now();
    dedup_semantic_effect_sites(&mut semantic_effect_sites);
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "dedup_semantic_effects",
        started.elapsed(),
    );
    let started = Instant::now();
    let local_complexity_scores =
        local_complexity_scores(&parsed.file.to_string_lossy(), &function_defs);
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "local_complexity_scores",
        started.elapsed(),
    );

    let started = Instant::now();
    let lines = parsed.source.lines().map(ToString::to_string).collect();
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "lines",
        started.elapsed(),
    );
    let started = Instant::now();
    let root = RawNode::from_tree_sitter(parsed.tree.root_node(), &parsed.source);
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "raw_root",
        started.elapsed(),
    );
    let started = Instant::now();
    let normalized_root = if options.normalized_root {
        normalize_tree(parsed.tree.root_node(), &parsed.source, language)
    } else {
        empty_normalized_root()
    };
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "normalized_root",
        started.elapsed(),
    );

    let document = Document {
        file: parsed.file.to_string_lossy().to_string(),
        language,
        source: String::new(),
        lines,
        root,
        normalized_root,
        function_defs,
        owner_defs,
        call_sites,
        state_declarations,
        state_reads,
        state_writes,
        decision_sites,
        branch_decisions,
        branch_arms,
        dispatch_sites,
        semantic_effect_sites,
        local_complexity_scores,
        predicate_aliases,
        comparison_uses,
        path_condition_sites: Vec::new(),
        protocol_method_effects: Vec::new(),
        protocol_call_paths: Vec::new(),
    };
    profile_parse_phase(
        rust_profile_enabled(),
        &file_label,
        "parse_file_total",
        total_started.elapsed(),
    );
    Ok(document)
}

fn empty_normalized_root() -> crate::decomplex::ast::Node {
    crate::decomplex::ast::Node {
        r#type: "ROOT".to_string(),
        children: Vec::new(),
        first_lineno: 1,
        first_column: 0,
        last_lineno: 1,
        last_column: 0,
        text: String::new(),
    }
}

fn rust_profile_enabled() -> bool {
    std::env::var_os("DECOMPLEX_RUST_PROFILE").is_some()
}

fn profile_parse_phase(enabled: bool, file: &str, phase: &str, elapsed: Duration) {
    if enabled {
        eprintln!(
            "decomplex-rust-parse-profile\t{}\t{}\t{:.6}",
            phase,
            file,
            elapsed.as_secs_f64()
        );
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
    locals: BTreeSet<String>,
    param_types: BTreeMap<String, String>,
    immutable_readers: BTreeMap<String, BTreeSet<String>>,
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
            locals: BTreeSet::new(),
            param_types: BTreeMap::new(),
            immutable_readers: BTreeMap::new(),
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
    owner_defs: &mut Vec<OwnerDef>,
    call_sites: &mut Vec<CallSite>,
    state_declarations: &mut Vec<StateDeclaration>,
    state_reads: &mut Vec<StateRead>,
    state_writes: &mut Vec<StateWrite>,
    decision_sites: &mut Vec<DecisionSite>,
    branch_decisions: &mut Vec<BranchDecision>,
    branch_arms: &mut Vec<BranchArm>,
    predicate_aliases: &mut Vec<PredicateAlias>,
    comparison_uses: &mut Vec<ComparisonUse>,
    seen_writes: &mut HashSet<String>,
    seen_reads: &mut HashSet<String>,
    seen_calls: &mut HashSet<String>,
    seen_decisions: &mut HashSet<String>,
) {
    let next_context = node_context(node, source, language, context);
    let next_context = next_context.as_ref();
    record_function_def(node, source, file, language, next_context, function_defs);
    record_owner_def(node, source, file, language, next_context, owner_defs);
    record_call_site(
        node,
        source,
        file,
        language,
        next_context,
        call_sites,
        seen_calls,
    );
    record_state_declaration(
        node,
        source,
        file,
        language,
        next_context,
        state_declarations,
    );
    record_state_read(
        node,
        source,
        file,
        language,
        next_context,
        state_reads,
        seen_reads,
    );
    record_state_write(
        node,
        source,
        file,
        language,
        next_context,
        state_writes,
        seen_writes,
    );
    record_decision_site(
        node,
        source,
        file,
        language,
        next_context,
        decision_sites,
        seen_decisions,
    );
    record_branch_decision(node, source, file, language, next_context, branch_decisions);
    record_branch_arm(node, source, file, language, next_context, branch_arms);
    record_predicate_alias(
        node,
        source,
        file,
        language,
        next_context,
        predicate_aliases,
    );
    record_comparison_use(node, source, file, language, next_context, comparison_uses);

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_facts(
            child,
            source,
            file,
            language,
            next_context,
            function_defs,
            owner_defs,
            call_sites,
            state_declarations,
            state_reads,
            state_writes,
            decision_sites,
            branch_decisions,
            branch_arms,
            predicate_aliases,
            comparison_uses,
            seen_writes,
            seen_reads,
            seen_calls,
            seen_decisions,
        );
    }
}

const GENERIC_SYSTEM_IO_BARE: &[&str] =
    &["print", "println", "eprintln", "printf", "puts", "panic"];

fn semantic_effect_sites_from_calls(
    language: Language,
    call_sites: &[CallSite],
) -> Vec<SemanticEffectSite> {
    let lexicon = false_simplicity_lexicon(language);
    call_sites
        .iter()
        .filter_map(|call| semantic_effect_site_for_call(call, &lexicon))
        .collect()
}

fn semantic_effect_site_for_call(
    call: &CallSite,
    lexicon: &FalseSimplicityLexicon,
) -> Option<SemanticEffectSite> {
    let message = call.message.as_str();
    let (kind, detail) = if effect_callback_call(call, message, lexicon) {
        ("callback_inversion", message.to_string())
    } else if lexicon.meta_mids.contains(&message) {
        ("metaprogramming", message.to_string())
    } else if lexicon.dispatch_mids.contains(&message) {
        ("dynamic_dispatch", message.to_string())
    } else if message == "call" && !call.receiver.is_empty() {
        if method_object_receiver(&call.receiver, lexicon) {
            ("dynamic_dispatch", "method(...).call".to_string())
        } else if variable_receiver(&call.receiver) {
            ("dynamic_dispatch", format!("{}.call", call.receiver))
        } else {
            return None;
        }
    } else if let Some((kind, detail)) = const_effect_kind_detail(call, message, lexicon) {
        (kind, detail)
    } else if call.receiver == "self"
        && (lexicon.io_bare.contains(&message) || GENERIC_SYSTEM_IO_BARE.contains(&message))
    {
        ("hidden_io", message.to_string())
    } else if call.receiver == "self" && lexicon.context_bare.contains(&message) {
        ("context_dependency", message.to_string())
    } else if message.len() > 1 && message.ends_with('!') && !matches!(message, "!=" | "!~") {
        ("hidden_mutation", message.to_string())
    } else {
        return None;
    };

    Some(SemanticEffectSite {
        kind: kind.to_string(),
        detail,
        file: call.file.clone(),
        function: call.function.clone(),
        line: call.line,
        span: call.span,
    })
}

fn const_effect_kind_detail(
    call: &CallSite,
    message: &str,
    lexicon: &FalseSimplicityLexicon,
) -> Option<(&'static str, String)> {
    let receiver = call.receiver.as_str();
    if receiver.is_empty() || receiver == "self" {
        return None;
    }
    let base = receiver
        .trim_start_matches("::")
        .split("::")
        .next()
        .unwrap_or("");
    if base == "Dir" && lexicon.dir_context.contains(&message) {
        return Some(("context_dependency", format!("Dir.{message}")));
    }
    if lexicon.io_consts.contains(&base) || receiver.starts_with("Net::") {
        return Some((
            "hidden_io",
            format!("{}.{}", receiver.trim_start_matches("::"), message),
        ));
    }
    if receiver == "ENV" {
        return Some(("context_dependency", "ENV".to_string()));
    }
    if lexicon
        .context_pairs
        .iter()
        .any(|(name, mids)| *name == base && mids.contains(&message))
    {
        return Some(("context_dependency", format!("{base}.{message}")));
    }
    None
}

fn effect_callback_call(call: &CallSite, message: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    (call.block || call.arguments.iter().any(|arg| arg.starts_with('&')))
        && effect_callback_name(message, lexicon)
        && !lexicon.meta_mids.contains(&message)
}

fn effect_callback_name(message: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    lexicon.callback_set.contains(&message)
        || message.starts_with("with_")
        || message.starts_with("around_")
        || message.starts_with("on_")
        || message.starts_with("before_")
        || message.starts_with("after_")
        || message.ends_with("_hook")
}

fn method_object_receiver(receiver: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    lexicon
        .method_obj_mids
        .iter()
        .any(|name| receiver.contains(name))
}

fn variable_receiver(receiver: &str) -> bool {
    let mut chars = receiver.chars();
    matches!(chars.next(), Some(first) if first == '@' || first == '$' || first == '_' || first.is_ascii_lowercase())
        && chars.all(|ch| ch == '_' || ch == '!' || ch == '?' || ch.is_ascii_alphanumeric())
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
    let next_context = node_context(node, source, language, context);
    let next_context = next_context.as_ref();
    record_dispatch_site(node, source, file, language, next_context, call_sites, out);

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_dispatch_sites(child, source, file, language, next_context, call_sites, out);
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

fn record_owner_def(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<OwnerDef>,
) {
    let profile = language_profile(language);
    if profile
        .owner_def_name_from_declaration(node, source)
        .is_none()
    {
        return;
    }
    let owner = OwnerDef {
        file: file.to_string_lossy().to_string(),
        name: context.current_owner(),
        kind: profile.owner_kind(node),
        line: line(node),
        span: span(node),
    };
    let key = (owner.file.clone(), owner.name.clone(), owner.kind.clone());
    if out.iter().any(|existing| {
        (
            existing.file.clone(),
            existing.name.clone(),
            existing.kind.clone(),
        ) == key
    }) {
        return;
    }
    out.push(owner);
}

fn record_predicate_alias(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
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
        owner: context.current_owner(),
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
    if assignment_like_predicate_body(&text) {
        return None;
    }
    if predicate_like_body(&text) {
        Some(text)
    } else {
        None
    }
}

fn assignment_like_predicate_body(text: &str) -> bool {
    text.contains("||=")
        || text.contains("&&=")
        || text.contains("+=")
        || text.contains("-=")
        || text.contains("*=")
        || text.contains("/=")
        || text.contains("%=")
        || text
            .chars()
            .collect::<Vec<_>>()
            .windows(3)
            .any(|window| matches!(window, [left, '=', right] if !matches!(left, '=' | '!' | '<' | '>') && *right != '='))
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
        canon_source: normalize_comparison_source(&raw),
        raw,
        file: file.to_string_lossy().to_string(),
        function: context.current_function(),
        line: line(node),
        span: span(node),
        enclosing_span: decision_enclosing_span(profile, node),
    });
}

fn normalize_comparison_source(source: &str) -> String {
    let mut text = source.trim().to_string();
    if let Some(stripped) = text.strip_prefix('!') {
        text = stripped.trim().to_string();
    }
    if let Some(stripped) = text.strip_prefix("self.") {
        text = stripped.to_string();
    }
    if let Some(stripped) = text.strip_prefix('@') {
        text = stripped.to_string();
    }
    if let Some(dot_index) = text.find('.') {
        let receiver = &text[..dot_index];
        let rest = &text[dot_index + 1..];
        if simple_identifier(receiver)
            && (rest.contains(" == ") || rest.contains(" != ") || rest.contains('.'))
        {
            text = rest.to_string();
        }
    }
    normalize_text(&text)
}

fn simple_identifier(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn comparison_node(profile: &dyn LanguageProfile, node: Node<'_>, source: &str) -> bool {
    if profile.comparison_node_kinds().contains(&node.kind()) {
        let operator = direct_operator_from_source(node, source);
        return profile.comparison_operators().contains(&operator.as_str());
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

fn record_branch_decision(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<BranchDecision>,
) {
    let profile = language_profile(language);
    if !branch_decision_node(profile, node, source) {
        return;
    }
    if hidden_case_wrapper_for_real_case(profile, node) {
        return;
    }
    if branch_decision_wrapper_for_real_branch(profile, node, source) {
        return;
    }
    if nested_block_branch_decision(profile, node) {
        return;
    }
    let Some(condition) = branch_condition_node(profile, node) else {
        return;
    };
    let mut refs = BTreeSet::new();
    collect_branch_state_refs(profile, condition, source, context, &mut refs);
    if refs.is_empty() {
        return;
    }
    out.push(BranchDecision {
        file: file.to_string_lossy().to_string(),
        function: context.current_function(),
        line: line(node),
        span: span(node),
        predicate: profile.normalize_source_text(node_text(condition, source)),
        state_refs: refs.into_iter().collect(),
    });
}

fn record_branch_arm(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<BranchArm>,
) {
    let profile = language_profile(language);
    if profile.generated_prelude(node, source)
        || branch_decision_wrapper_for_real_branch(profile, node, source)
    {
        return;
    }
    if if_arm_node(profile, node, source) {
        record_if_arms(profile, node, source, file, context, out);
        return;
    }
    if case_node(profile, node) || profile.hidden_case(node) {
        let decision_node = profile.case_source_node(node);
        record_case_arms(profile, decision_node, source, file, context, out);
    }
}

fn if_arm_node(profile: &dyn LanguageProfile, node: Node<'_>, source: &str) -> bool {
    if case_node(profile, node) || profile.hidden_case(node) {
        return false;
    }
    profile.branch_node_kinds().contains(&node.kind())
        || profile.control_context(node, source).as_deref() == Some("conditional")
}

fn record_if_arms(
    profile: &dyn LanguageProfile,
    node: Node<'_>,
    source: &str,
    file: &Path,
    context: &ContextState,
    out: &mut Vec<BranchArm>,
) {
    let predicate = profile.normalize_source_text(&decision_predicate(profile, node, source));
    let decision_span = span(node);
    let decision_line = line(node);
    let named = named_children(node);
    let consequence = node
        .child_by_field_name("consequence")
        .or_else(|| node.child_by_field_name("body"))
        .or_else(|| named.get(1).copied());
    let alternative =
        node.child_by_field_name("alternative")
            .or_else(|| {
                named.iter().copied().find(|child| {
                    child.kind().contains("else") || child.kind().contains("alternative")
                })
            })
            .or_else(|| {
                named
                    .get(2)
                    .copied()
                    .filter(|candidate| consequence != Some(*candidate))
            });

    for (arm, member) in [(consequence, "then"), (alternative, "else")] {
        let Some(arm) = arm else {
            continue;
        };
        out.push(BranchArm {
            file: file.to_string_lossy().to_string(),
            function: context.current_function(),
            kind: "if".to_string(),
            line: line(arm),
            span: span(arm),
            decision_line,
            decision_span,
            predicate: predicate.clone(),
            member: member.to_string(),
            body: profile.normalize_source_text(node_text(arm, source)),
        });
    }
}

fn record_case_arms(
    profile: &dyn LanguageProfile,
    node: Node<'_>,
    source: &str,
    file: &Path,
    context: &ContextState,
    out: &mut Vec<BranchArm>,
) {
    let predicate = profile.normalize_source_text(&decision_predicate(profile, node, source));
    let decision_span = span(node);
    let decision_line = line(node);
    for arm in case_arms(profile, node) {
        let pattern = case_arm_patterns(arm, source, profile)
            .into_iter()
            .find(|pattern| !default_case_pattern(profile, pattern))
            .unwrap_or_default();
        if pattern.is_empty() {
            continue;
        }
        out.push(BranchArm {
            file: file.to_string_lossy().to_string(),
            function: context.current_function(),
            kind: "case".to_string(),
            line: line(arm),
            span: span(arm),
            decision_line,
            decision_span,
            predicate: predicate.clone(),
            member: pattern.clone(),
            body: case_arm_body(profile, arm, source, &pattern),
        });
    }
}

fn case_arm_body(
    profile: &dyn LanguageProfile,
    arm: Node<'_>,
    source: &str,
    pattern: &str,
) -> String {
    let body = named_children(arm)
        .into_iter()
        .filter(|child| {
            !profile.case_pattern_node_kinds().contains(&child.kind())
                && !matches!(child.kind(), "then" | "else")
        })
        .last()
        .map(|child| node_text(child, source))
        .unwrap_or_else(|| node_text(arm, source));
    let mut text = profile.normalize_source_text(body);
    for prefix in [format!("when {pattern} then "), format!("when {pattern} ")] {
        if let Some(stripped) = text.strip_prefix(&prefix) {
            text = stripped.to_string();
            break;
        }
    }
    text
}

fn branch_decision_node(profile: &dyn LanguageProfile, node: Node<'_>, source: &str) -> bool {
    profile.branch_node_kinds().contains(&node.kind())
        || profile.hidden_case(node)
        || profile.control_context(node, source).as_deref() == Some("conditional")
}

fn branch_decision_wrapper_for_real_branch(
    profile: &dyn LanguageProfile,
    node: Node<'_>,
    source: &str,
) -> bool {
    if profile.branch_node_kinds().contains(&node.kind()) || profile.hidden_case(node) {
        return false;
    }
    if profile.control_context(node, source).as_deref() != Some("conditional") {
        return false;
    }
    first_named_child(node)
        .map(|child| branch_decision_node(profile, child, source))
        .unwrap_or(false)
}

fn hidden_case_wrapper_for_real_case(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    profile.hidden_case(node) && profile.hidden_case_source_node(node).is_some()
}

fn nested_block_branch_decision(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    let mut current = node.parent();
    while let Some(parent) = current {
        if profile.function_node_kinds().contains(&parent.kind())
            || profile.class_owner_node_kinds().contains(&parent.kind())
            || profile.module_owner_node_kinds().contains(&parent.kind())
        {
            return false;
        }
        if profile
            .branch_nested_scope_node_kinds()
            .contains(&parent.kind())
        {
            return true;
        }
        current = parent.parent();
    }
    false
}

fn branch_condition_node<'tree>(
    _profile: &dyn LanguageProfile,
    node: Node<'tree>,
) -> Option<Node<'tree>> {
    node.child_by_field_name("condition")
        .or_else(|| node.child_by_field_name("value"))
        .or_else(|| node.child_by_field_name("subject"))
        .or_else(|| first_named_child(node))
}

fn collect_branch_state_refs(
    profile: &dyn LanguageProfile,
    node: Node<'_>,
    source: &str,
    context: &ContextState,
    out: &mut BTreeSet<String>,
) {
    if let Some(target) = profile.state_read_target(node, source) {
        let field = if profile.language() == Language::Ruby {
            target.field.clone()
        } else {
            normalized_state_ref_field(&target.field)
        };
        let receiver = target.receiver.trim_start_matches('$');
        if namespace_receiver(receiver) || constant_like_state_ref(receiver, &field) {
            // Constants and type namespaces are not mutable object state.
        } else if branch_local_ref(node, source, receiver, &field, context) {
            // Function-local bindings are not object state, even when a
            // language permits bare predicate-style method calls.
        } else if profile.language() == Language::Ruby
            && ruby_immutable_param_state_read(receiver, &field, context)
        {
            // Sorbet T::Struct readers on typed params are immutable data reads,
            // not mutable object state.
        } else if receiver.is_empty() || receiver == "self" {
            out.insert(field);
        } else {
            out.insert(format!("{receiver}.{field}"));
        }
    }

    let mut cursor = node.walk();
    for child in node.named_children(&mut cursor) {
        if profile
            .branch_nested_scope_node_kinds()
            .contains(&child.kind())
        {
            continue;
        }
        collect_branch_state_refs(profile, child, source, context, out);
    }
}

fn dedup_semantic_effect_sites(sites: &mut Vec<SemanticEffectSite>) {
    let mut seen = HashSet::new();
    sites.retain(|site| {
        seen.insert((
            site.kind.clone(),
            site.detail.clone(),
            site.file.clone(),
            site.function.clone(),
            site.line,
            site.span,
        ))
    });
}

fn branch_local_ref(
    node: Node<'_>,
    source: &str,
    receiver: &str,
    field: &str,
    context: &ContextState,
) -> bool {
    (receiver.is_empty() || matches!(receiver, "self" | "this"))
        && context.locals.contains(field)
        && normalize_text(node_text(node, source)) == field
}

fn ruby_immutable_param_state_read(receiver: &str, field: &str, context: &ContextState) -> bool {
    if receiver.is_empty() || matches!(receiver, "self" | "this") {
        return false;
    }
    let Some(param) = receiver.split('.').next() else {
        return false;
    };
    let Some(type_name) = context.param_types.get(param) else {
        return false;
    };
    let field = field.trim_end_matches('?');
    ruby_immutable_reader(type_name, field, &context.immutable_readers)
}

fn ruby_immutable_reader(
    type_name: &str,
    field: &str,
    readers: &BTreeMap<String, BTreeSet<String>>,
) -> bool {
    let short = type_name.split("::").last().unwrap_or(type_name);
    readers
        .get(type_name)
        .or_else(|| readers.get(short))
        .map(|fields| fields.contains(field))
        .unwrap_or(false)
}

fn ruby_immutable_struct_readers(source: &str) -> BTreeMap<String, BTreeSet<String>> {
    let mut readers: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut class_stack = Vec::new();
    for line in source.lines() {
        let stripped = line.trim();
        if let Some(name) = stripped
            .strip_prefix("class ")
            .and_then(|rest| rest.split_once("< T::Struct").map(|(name, _)| name.trim()))
            .filter(|name| ruby_constant_path(name))
        {
            class_stack.push(name.to_string());
            continue;
        }
        if let Some(owner) = class_stack.last() {
            if let Some(field) = stripped
                .strip_prefix("const :")
                .and_then(|rest| {
                    rest.split(|ch: char| !ch.is_ascii_alphanumeric() && ch != '_')
                        .next()
                })
                .filter(|field| !field.is_empty())
            {
                readers
                    .entry(owner.clone())
                    .or_default()
                    .insert(field.to_string());
                continue;
            }
        }
        if !class_stack.is_empty() && stripped.trim_end_matches(';') == "end" {
            class_stack.pop();
        }
    }
    readers
}

fn ruby_sig_param_types(source: &str, function_line: usize) -> BTreeMap<String, String> {
    let lines = source.lines().collect::<Vec<_>>();
    let mut sig_lines = Vec::new();
    let mut cursor = function_line.saturating_sub(2);
    while let Some(line) = lines.get(cursor) {
        let stripped = line.trim();
        if stripped.is_empty() {
            if sig_lines.is_empty() {
                break;
            }
        } else if sig_lines.is_empty() && !stripped.starts_with("sig") {
            break;
        }
        sig_lines.push(*line);
        if stripped.starts_with("sig") {
            break;
        }
        if cursor == 0 || sig_lines.len() >= 8 {
            break;
        }
        cursor -= 1;
    }
    sig_lines.reverse();
    let sig = sig_lines.join("\n");
    let Some(params_start) = sig.find("params(").map(|index| index + "params(".len()) else {
        return BTreeMap::new();
    };
    let rest = &sig[params_start..];
    let Some(params_end) = rest.find(')') else {
        return BTreeMap::new();
    };
    rest[..params_end]
        .split(',')
        .filter_map(|part| {
            let (name, type_name) = part.split_once(':')?;
            let name = name.trim();
            let type_name = type_name.trim();
            (ruby_identifier(name) && ruby_constant_path(type_name))
                .then(|| (name.to_string(), type_name.to_string()))
        })
        .collect()
}

fn ruby_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(ch) if ch == '_' || ch.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn ruby_constant_path(value: &str) -> bool {
    value.split("::").all(|part| {
        let mut chars = part.chars();
        matches!(chars.next(), Some(ch) if ch.is_ascii_uppercase())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    })
}

fn declared_state_index(declarations: &[StateDeclaration]) -> BTreeMap<String, BTreeSet<String>> {
    let mut index: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for declaration in declarations {
        index
            .entry(declaration.owner.clone())
            .or_default()
            .insert(declaration.field.clone());
    }
    index
}

fn function_param_index(
    function_defs: &[FunctionDef],
) -> BTreeMap<(String, String), BTreeSet<String>> {
    let mut index: BTreeMap<(String, String), BTreeSet<String>> = BTreeMap::new();
    for function in function_defs {
        index
            .entry((function.owner.clone(), function.name.clone()))
            .or_default()
            .extend(function.params.iter().cloned());
    }
    index
}

fn local_declaration_index(
    root: Node<'_>,
    source: &str,
    language: Language,
    context: &ContextState,
) -> BTreeMap<(String, String), BTreeSet<String>> {
    let mut index = BTreeMap::new();
    local_declaration_index_for_node(root, source, language, context, &mut index);
    index
}

fn local_declaration_index_for_node(
    node: Node<'_>,
    source: &str,
    language: Language,
    context: &ContextState,
    out: &mut BTreeMap<(String, String), BTreeSet<String>>,
) {
    let next_context = node_context(node, source, language, context);
    let next_context = next_context.as_ref();
    let profile = language_profile(language);
    if local_variable_declarator(profile, node) {
        let owner = next_context.current_owner();
        let function = next_context.current_function();
        if function != "(top-level)" {
            if let Some(name) = local_name_node(profile, node, source) {
                out.entry((owner, function))
                    .or_default()
                    .insert(node_text(name, source).to_string());
            }
        }
    }

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        local_declaration_index_for_node(child, source, language, next_context, out);
    }
}

fn local_variable_declarator(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    profile
        .local_variable_declarator_node_kinds()
        .contains(&node.kind())
        && !inside_kind(node, profile.field_declaration_node_kinds())
}

fn local_name_node<'tree>(
    profile: &dyn LanguageProfile,
    node: Node<'tree>,
    source: &str,
) -> Option<Node<'tree>> {
    node.child_by_field_name("name")
        .or_else(|| profile.declarator_name_node(node, source))
        .or_else(|| {
            named_children(node).into_iter().find(|child| {
                profile.identifier_node_kinds().contains(&child.kind())
                    || profile
                        .field_identifier_node_kinds()
                        .contains(&child.kind())
            })
        })
}

fn implicit_state_identifier(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    profile.identifier_node_kinds().contains(&node.kind())
        || profile.field_identifier_node_kinds().contains(&node.kind())
}

fn identifier_declaration_site(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    if node
        .parent()
        .map(|parent| {
            profile
                .declaration_site_parent_node_kinds()
                .contains(&parent.kind())
        })
        .unwrap_or(false)
    {
        return true;
    }
    inside_kind(node, profile.field_declaration_node_kinds())
}

fn member_message_identifier(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if !profile.field_like_node_kinds().contains(&parent.kind()) {
        return false;
    }
    let field = parent
        .child_by_field_name("field")
        .or_else(|| parent.child_by_field_name("property"))
        .or_else(|| parent.child_by_field_name("name"))
        .or_else(|| named_children(parent).into_iter().last());
    field.map(|field| same_node(field, node)).unwrap_or(false)
}

fn implicit_assignment_lhs(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    if let Some(parent) = node.parent() {
        if profile.assignment_node_kinds().contains(&parent.kind()) {
            let lhs = parent
                .child_by_field_name("left")
                .or_else(|| first_named_child(parent));
            return lhs.map(|lhs| same_node(lhs, node)).unwrap_or(false);
        }
    }
    profile.assignment_lhs_node(node)
}

fn normalized_state_ref_field(field: &str) -> String {
    field
        .trim_start_matches('@')
        .trim_start_matches('$')
        .to_string()
}

fn constant_like_state_ref(receiver: &str, field: &str) -> bool {
    constant_namespace_receiver(receiver) || (receiver.is_empty() && starts_uppercase(field))
}

fn starts_uppercase(value: &str) -> bool {
    matches!(value.chars().next(), Some(ch) if ch.is_ascii_uppercase())
}

fn constant_namespace_receiver(value: &str) -> bool {
    let text = value.trim().trim_start_matches("::");
    if text.is_empty() || !starts_uppercase(text) {
        return false;
    }
    text.split("::").all(|part| {
        !part.is_empty()
            && part
                .chars()
                .all(|ch| ch == '_' || ch == '.' || ch.is_ascii_alphanumeric())
            && part
                .split('.')
                .all(|segment| !segment.is_empty() && starts_uppercase(segment))
    })
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

fn node_context<'a>(
    node: Node<'_>,
    source: &str,
    language: Language,
    context: &'a ContextState,
) -> Cow<'a, ContextState> {
    let profile = language_profile(language);
    let owner = if possible_owner_context_node(profile, node) {
        profile
            .owner_name_from_declaration(node, source)
            .or_else(|| profile.receiver_convention_owner_name(node, source))
    } else {
        None
    };
    let function = if possible_function_context_node(profile, node) {
        profile.function_name(node, source)
    } else {
        None
    };
    let control = if possible_control_context_node(node) {
        profile.control_context(node, source)
    } else {
        None
    };

    if owner.is_none() && function.is_none() && control.is_none() {
        return Cow::Borrowed(context);
    }

    let mut next = context.clone();
    if let Some(owner) = owner {
        let full_owner = if let Some(parent) = next.owner.clone() {
            if parent != owner && !owner.contains("::") {
                format!("{parent}::{owner}")
            } else {
                owner
            }
        } else {
            owner
        };
        next.owner = Some(full_owner);
    }

    if let Some(function) = function {
        let owner = next.current_owner();
        next.function = Some(function);
        next.function_line = Some(line(node));
        next.owner = Some(owner);
        next.receiver = profile.function_receiver_name(node, source);
        next.locals = profile.function_params(node, source).into_iter().collect();
        next.param_types = if language == Language::Ruby {
            ruby_sig_param_types(source, line(node))
        } else {
            BTreeMap::new()
        };
        if let Some(receiver) = &next.receiver {
            next.locals.insert(receiver.clone());
        }
    }

    if let Some(control) = control {
        next.controls.push(control);
    }

    Cow::Owned(next)
}

fn possible_function_context_node(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    profile.function_node_kinds().contains(&node.kind())
        || node.kind() == "singleton_method"
        || matches!(node.kind(), "body_statement" | "argument_list")
            && first_child_kind(node) == Some("def")
}

fn possible_owner_context_node(profile: &dyn LanguageProfile, node: Node<'_>) -> bool {
    profile.class_owner_node_kinds().contains(&node.kind())
        || profile.module_owner_node_kinds().contains(&node.kind())
        || profile.generic_owner_node_kinds().contains(&node.kind())
        || profile.impl_owner_node_kinds().contains(&node.kind())
        || profile.struct_owner_node_kinds().contains(&node.kind())
        || possible_function_context_node(profile, node)
        || profile.first_argument_receiver() && possible_function_context_node(profile, node)
        || node.kind() == "body_statement"
            && matches!(first_child_kind(node), Some("class" | "module"))
}

fn possible_control_context_node(node: Node<'_>) -> bool {
    matches!(
        node.kind(),
        "while"
            | "until"
            | "for"
            | "do_block"
            | "while_statement"
            | "until_statement"
            | "for_statement"
            | "for_in_statement"
            | "enhanced_for_statement"
            | "foreach_statement"
            | "for_range_loop"
            | "for_expression"
            | "loop_expression"
            | "if"
            | "unless"
            | "if_modifier"
            | "unless_modifier"
            | "case"
            | "if_statement"
            | "if_expression"
            | "case_statement"
            | "switch_statement"
            | "switch_expression"
            | "match_statement"
            | "match_expression"
            | "when_expression"
            | "expression_switch_statement"
            | "expression_statement"
            | "labeled_statement"
            | "body_statement"
            | "block"
            | "statements"
            | "statement_list"
    )
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

fn record_state_declaration(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    out: &mut Vec<StateDeclaration>,
) {
    let profile = language_profile(language);
    let Some((field, r#type)) = profile.state_declaration(node, source) else {
        return;
    };
    let declaration = StateDeclaration {
        field,
        owner: context.current_owner(),
        r#type,
        file: file.to_string_lossy().to_string(),
        line: line(node),
        span: span(node),
    };
    let key = (
        declaration.file.clone(),
        declaration.owner.clone(),
        declaration.field.clone(),
    );
    if out.iter().any(|existing| {
        (
            existing.file.clone(),
            existing.owner.clone(),
            existing.field.clone(),
        ) == key
    }) {
        return;
    }
    out.push(declaration);
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
    let Some(target) = profile.state_read_target(node, source) else {
        return;
    };
    if profile.assignment_lhs_node(node) {
        return;
    }
    let target = normalize_target_receiver(target, context);
    if namespace_receiver(&target.receiver)
        || constant_like_state_ref(&target.receiver, &target.field)
    {
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

fn collect_implicit_state_accesses(
    root: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    function_defs: &[FunctionDef],
    state_declarations: &[StateDeclaration],
    state_reads: &mut Vec<StateRead>,
    state_writes: &mut Vec<StateWrite>,
    seen_reads: &mut HashSet<String>,
    seen_writes: &mut HashSet<String>,
) {
    let profile = language_profile(language);
    if !profile.implicit_state_accesses() {
        return;
    }
    let declared = declared_state_index(state_declarations);
    if declared.is_empty() {
        return;
    }
    let locals = local_declaration_index(root, source, language, context);
    let params = function_param_index(function_defs);
    collect_implicit_state_accesses_for_node(
        root,
        source,
        file,
        language,
        context,
        &declared,
        &locals,
        &params,
        state_reads,
        state_writes,
        seen_reads,
        seen_writes,
    );
}

fn collect_implicit_state_accesses_for_node(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    declared: &BTreeMap<String, BTreeSet<String>>,
    locals: &BTreeMap<(String, String), BTreeSet<String>>,
    params: &BTreeMap<(String, String), BTreeSet<String>>,
    state_reads: &mut Vec<StateRead>,
    state_writes: &mut Vec<StateWrite>,
    seen_reads: &mut HashSet<String>,
    seen_writes: &mut HashSet<String>,
) {
    let next_context = node_context(node, source, language, context);
    let next_context = next_context.as_ref();
    record_implicit_state_access(
        node,
        source,
        file,
        language,
        next_context,
        declared,
        locals,
        params,
        state_reads,
        state_writes,
        seen_reads,
        seen_writes,
    );

    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_implicit_state_accesses_for_node(
            child,
            source,
            file,
            language,
            next_context,
            declared,
            locals,
            params,
            state_reads,
            state_writes,
            seen_reads,
            seen_writes,
        );
    }
}

fn record_implicit_state_access(
    node: Node<'_>,
    source: &str,
    file: &Path,
    language: Language,
    context: &ContextState,
    declared: &BTreeMap<String, BTreeSet<String>>,
    locals: &BTreeMap<(String, String), BTreeSet<String>>,
    params: &BTreeMap<(String, String), BTreeSet<String>>,
    state_reads: &mut Vec<StateRead>,
    state_writes: &mut Vec<StateWrite>,
    seen_reads: &mut HashSet<String>,
    seen_writes: &mut HashSet<String>,
) {
    let profile = language_profile(language);
    if !implicit_state_identifier(profile, node) {
        return;
    }
    let owner = context.current_owner();
    let function = context.current_function();
    if function == "(top-level)" {
        return;
    }
    let field = node_text(node, source).to_string();
    if !declared
        .get(&owner)
        .map(|fields| fields.contains(&field))
        .unwrap_or(false)
    {
        return;
    }
    let scope = (owner.clone(), function.clone());
    if params
        .get(&scope)
        .map(|fields| fields.contains(&field))
        .unwrap_or(false)
        || locals
            .get(&scope)
            .map(|fields| fields.contains(&field))
            .unwrap_or(false)
        || identifier_declaration_site(profile, node)
        || member_message_identifier(profile, node)
    {
        return;
    }

    let file_name = file.to_string_lossy().to_string();
    if implicit_assignment_lhs(profile, node) {
        let key = format!(
            "{}\0{}\0{}\0{}\0self\0{}",
            file_name,
            owner,
            function,
            line(node),
            field
        );
        if seen_writes.insert(key) {
            state_writes.push(StateWrite {
                field,
                receiver: "self".to_string(),
                file: file_name,
                function,
                line: line(node),
                span: span(node),
                owner,
            });
        }
    } else {
        let key = format!(
            "{}\0{}\0{}\0{:?}\0self\0{}",
            file_name,
            owner,
            function,
            span(node),
            field
        );
        if seen_reads.insert(key) {
            state_reads.push(StateRead {
                field,
                receiver: "self".to_string(),
                file: file_name,
                function,
                line: line(node),
                span: span(node),
                owner,
            });
        }
    }
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
    let Some(assignment) = profile.assignment_target(node) else {
        return;
    };
    if profile.skip_state_write_node(node) {
        return;
    }
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

    if !starts_uppercase(receiver) {
        return false;
    }
    if receiver.contains('(') {
        return false;
    }
    receiver
        .split(['.', ':'])
        .filter(|part| !part.is_empty())
        .all(starts_uppercase)
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

fn inside_kind(node: Node<'_>, kinds: &[&str]) -> bool {
    let mut parent = node.parent();
    let mut seen = HashSet::new();
    while let Some(current) = parent {
        let key = format!("{:?}\0{}", span(current), current.kind());
        if !seen.insert(key) {
            break;
        }
        if kinds.contains(&current.kind()) {
            return true;
        }
        parent = current.parent();
    }
    false
}

fn same_node(left: Node<'_>, right: Node<'_>) -> bool {
    left.kind() == right.kind() && span(left) == span(right)
}

pub(crate) fn first_child_kind(node: Node<'_>) -> Option<&str> {
    let mut cursor = node.walk();
    let kind = node.children(&mut cursor).next().map(|child| child.kind());
    kind
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
    strip_enclosing_parentheses(&normalize_text(
        target
            .map(|child| node_text(child, source))
            .unwrap_or_else(|| node_text(node, source)),
    ))
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
        _ => receiver.to_string(),
    }
}
