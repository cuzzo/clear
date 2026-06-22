use super::{
    normalized_behavior, parser_grammar::grammar_for_language, passes, Document, Language,
};
use crate::ast::normalize_tree;
use anyhow::{Context, Result};
use std::fs;
use std::path::PathBuf;
use std::time::{Duration, Instant};
use tree_sitter::Parser;

pub fn parse_file(file: PathBuf, language: Language) -> Result<Document> {
    parse_file_with_options(file, language)
}

pub(crate) fn parse_file_for_report(file: PathBuf, language: Language) -> Result<Document> {
    parse_file_with_options(file, language)
}

fn parse_file_with_options(file: PathBuf, language: Language) -> Result<Document> {
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
    parse_normalized_file(parsed, language, profile, &file_label, total_started)
}

fn parse_normalized_file(
    parsed: ParsedDocument,
    language: Language,
    profile: bool,
    file_label: &str,
    total_started: Instant,
) -> Result<Document> {
    let started = Instant::now();
    let normalized_root = normalize_tree(parsed.tree.root_node(), &parsed.source, language);
    profile_parse_phase(profile, file_label, "normalized_root", started.elapsed());

    let lines = parsed
        .source
        .lines()
        .map(ToString::to_string)
        .collect::<Vec<_>>();
    let behavior = normalized_behavior::behavior(language);

    let started = Instant::now();
    let mut facts =
        passes::StatelessSyntaxPass::normalized(&parsed.file, &lines, &normalized_root, behavior)
            .run();
    let metadata = passes::StatefulSyntaxPass::new(
        &parsed.file,
        &parsed.source,
        &lines,
        &normalized_root,
        behavior,
    )
    .enrich(&mut facts);
    profile_parse_phase(profile, file_label, "normalized_facts", started.elapsed());

    let mut path_condition_sites = facts.path_condition_sites;
    path_condition_sites.extend(metadata.path_condition_sites);

    let document = Document {
        file: parsed.file.to_string_lossy().to_string(),
        language,
        function_defs: facts.function_defs,
        owner_defs: facts.owner_defs,
        call_sites: facts.call_sites,
        state_declarations: facts.state_declarations,
        state_reads: facts.state_reads,
        state_writes: facts.state_writes,
        decision_sites: facts.decision_sites,
        branch_decisions: facts.branch_decisions,
        branch_arms: facts.branch_arms,
        dispatch_sites: facts.dispatch_sites,
        semantic_effect_sites: facts.semantic_effect_sites,
        local_complexity_scores: metadata.local_complexity_scores,
        local_methods: metadata.local_methods,
        predicate_aliases: facts.predicate_aliases,
        comparison_uses: facts.comparison_uses,
        path_condition_sites,
        protocol_method_effects: metadata.protocol_method_effects,
        protocol_call_paths: metadata.protocol_call_paths,
        clone_candidates: metadata.clone_candidates,
        redundant_nil_guards: metadata.redundant_nil_guards,
        immutable_struct_readers: metadata.syntax.immutable_struct_readers,
        immutable_struct_reader_types: metadata.syntax.immutable_struct_reader_types,
        type_aliases: metadata.syntax.type_aliases,
        method_param_types: metadata.syntax.method_param_types,
        state_param_origins: Vec::new(),
    };
    profile_parse_phase(
        profile,
        file_label,
        "parse_file_total",
        total_started.elapsed(),
    );
    Ok(document)
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
            .set_language(&grammar_for_language(language))
            .with_context(|| "failed to initialize tree-sitter parser")?;
        let tree = parser
            .parse(&source, None)
            .with_context(|| format!("tree-sitter produced no tree for {}", file.display()))?;
        Ok(Self { file, source, tree })
    }
}
