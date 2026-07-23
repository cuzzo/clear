use super::{
    normalized_behavior, parser_grammar::grammar_for_language, passes, Document, Language,
    SymbolScope,
};
use crate::ast::normalize_tree_with_call_origins;
use anyhow::{Context, Result};
use sha2::{Digest, Sha256};
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
    let raw_call_sites =
        crate::ast::raw_call_sites(parsed.tree.root_node(), &parsed.source, language);
    let parse_recovery_spans = parse_recovery_spans(parsed.tree.root_node());
    let parse_recovered = !parse_recovery_spans.is_empty();
    let (normalized_root, parser_call_origins) =
        normalize_tree_with_call_origins(parsed.tree.root_node(), &parsed.source, language);
    let (mut namespace, mut explicit_imports) =
        crate::ast::symbol_scope(parsed.tree.root_node(), &parsed.source, language);
    let declaration_namespaces =
        crate::ast::declaration_namespaces(parsed.tree.root_node(), &parsed.source, language);
    let preprocessor_callables =
        crate::ast::preprocessor_callable_names(parsed.tree.root_node(), &parsed.source, language);
    if language == Language::Go && !namespace.is_empty() {
        let directory = parsed
            .file
            .parent()
            .unwrap_or_else(|| std::path::Path::new("."))
            .to_string_lossy();
        namespace = format!("{directory}::{namespace}");
    }
    if language == Language::Python {
        namespace = python_module_namespace(&parsed.file);
        for (_, target) in &mut explicit_imports {
            *target = canonical_python_import(&parsed.file, &namespace, target);
        }
    }
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
    if language == Language::Go {
        // Go function literals can normalize to a synthetic wrapper with the
        // span of `return func`, rather than the comma-ok declaration. Keep
        // source ownership in the Go adapter, which has the unmodified parser
        // tree and can provide an exact node span without text recovery.
        super::go::attach_raw_presence_correlation_spans(
            parsed.tree.root_node(),
            &parsed.source,
            &mut facts.presence_correlation_seeds,
        );
    }
    let normalization_call_origins = parser_call_origins
        .into_iter()
        .map(
            |(raw_call_span, normalized_call_span)| super::CallRawOriginProjection {
                raw_call_span,
                normalized_call_span,
            },
        )
        .collect::<Vec<_>>();
    let parser_origins_by_normalized = normalization_call_origins
        .iter()
        .map(|origin| (origin.normalized_call_span, origin.raw_call_span))
        .collect::<std::collections::BTreeMap<_, _>>();
    let call_raw_origin_projections = facts
        .call_node_projections
        .iter()
        .filter_map(|projection| {
            parser_origins_by_normalized
                .get(&projection.normalized_node_span)
                .map(|raw| super::CallRawOriginProjection {
                    raw_call_span: *raw,
                    normalized_call_span: projection.emitted_call_span,
                })
        })
        .collect();
    facts.hazard_sites = crate::syntax::hazards::extract_hazards(
        &parsed.file.to_string_lossy(),
        parsed.tree.root_node(),
        &parsed.source,
        language,
    );
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

    let mut document = Document {
        file: parsed.file.to_string_lossy().to_string(),
        language,
        source_digest: format!("sha256:{:x}", Sha256::digest(parsed.source.as_bytes())),
        parse_recovered,
        parse_recovery_spans,
        raw_call_sites,
        symbol_scope: SymbolScope {
            canonical: matches!(
                language,
                Language::Java | Language::Go | Language::CSharp | Language::Cpp | Language::Python
            ),
            unqualified_types_use_current_namespace:
                crate::ast::unqualified_types_use_current_namespace(language),
            namespace,
            explicit_imports: explicit_imports.into_iter().collect(),
            preprocessor_callables: preprocessor_callables.into_iter().collect(),
            declaration_namespaces: declaration_namespaces.into_iter().collect(),
        },
        function_defs: facts.function_defs,
        owner_defs: facts.owner_defs,
        call_sites: facts.call_sites,
        normalization_call_origins,
        call_raw_origin_projections,
        call_receiver_projections: facts.call_receiver_projections,
        state_declarations: facts.state_declarations,
        state_reads: facts.state_reads,
        state_writes: facts.state_writes,
        chained_self_reads: facts.chained_self_reads,
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
        control_flow_nodes: metadata.control_flow.nodes,
        control_flow_edges: metadata.control_flow.edges,
        control_flow_metrics: metadata.control_flow_metrics,
        places: metadata.control_flow.places,
        node_effects: metadata.control_flow.effects,
        reachability: metadata.control_flow.reachability,
        dominators: metadata.control_flow.dominators,
        reaching_definitions: metadata.control_flow.reaching_definitions,
        def_use: metadata.control_flow.def_use,
        liveness: metadata.control_flow.liveness,
        flow_types: metadata.control_flow.flow_types,
        protocol_method_effects: metadata.protocol_method_effects,
        protocol_call_paths: metadata.protocol_call_paths,
        clone_candidates: metadata.clone_candidates,
        redundant_nil_guards: metadata.redundant_nil_guards,
        nullable_refinements: metadata.nullable_refinements,
        nullable_states: metadata.nullable_states,
        nullable_summaries: metadata.nullable_summaries,
        nullable_operations: metadata.nullable_operations,
        presence_correlations: metadata.presence_correlations,
        immutable_struct_readers: metadata.syntax.immutable_struct_readers,
        immutable_struct_reader_types: metadata.syntax.immutable_struct_reader_types,
        type_aliases: metadata.syntax.type_aliases,
        type_alias_lines: metadata.syntax.type_alias_lines,
        method_param_types: metadata.syntax.method_param_types,
        method_local_types: metadata.syntax.method_local_types,
        state_param_origins: Vec::new(),
        hazard_sites: facts.hazard_sites,
        imports: Vec::new(),
    };
    let mut import_facts = crate::syntax::imports::symbol_imports(
        &document
            .symbol_scope
            .explicit_imports
            .iter()
            .map(|(alias, target)| (alias.clone(), target.clone()))
            .collect::<Vec<_>>(),
        language,
    );
    import_facts.extend(crate::syntax::imports::extract_file_imports(
        parsed.tree.root_node(),
        &parsed.source,
        language,
    ));
    document.imports = import_facts;
    crate::syntax::hazards::detect_and_append_callback_hazards(&mut document);
    profile_parse_phase(
        profile,
        file_label,
        "parse_file_total",
        total_started.elapsed(),
    );
    Ok(document)
}

fn parse_recovery_spans(root: tree_sitter::Node<'_>) -> Vec<[usize; 4]> {
    fn visit(node: tree_sitter::Node<'_>, spans: &mut Vec<[usize; 4]>) {
        if node.is_error() || node.is_missing() {
            let start = node.start_position();
            let end = node.end_position();
            spans.push([start.row + 1, start.column, end.row + 1, end.column]);
        }
        let mut cursor = node.walk();
        for child in node.children(&mut cursor) {
            visit(child, spans);
        }
    }

    let mut spans = Vec::new();
    visit(root, &mut spans);
    spans.sort_unstable();
    spans.dedup();
    spans
}

fn python_module_namespace(file: &std::path::Path) -> String {
    let mut package = Vec::new();
    let mut directory = file.parent();
    while let Some(current) = directory {
        if !current.join("__init__.py").is_file() {
            break;
        }
        let Some(name) = current.file_name().and_then(|name| name.to_str()) else {
            break;
        };
        package.push(name.to_string());
        directory = current.parent();
    }
    package.reverse();
    let stem = file
        .file_stem()
        .and_then(|stem| stem.to_str())
        .unwrap_or_default();
    if stem != "__init__" && !stem.is_empty() {
        package.push(stem.to_string());
    }
    package.join(".")
}

fn canonical_python_import(file: &std::path::Path, namespace: &str, target: &str) -> String {
    let dots = target
        .chars()
        .take_while(|character| *character == '.')
        .count();
    if dots == 0 {
        return target.to_string();
    }
    let mut package = namespace.split('.').map(str::to_string).collect::<Vec<_>>();
    if file.file_stem().and_then(|stem| stem.to_str()) != Some("__init__") {
        package.pop();
    }
    for _ in 1..dots {
        package.pop();
    }
    package.extend(
        target[dots..]
            .split('.')
            .filter(|part| !part.is_empty())
            .map(str::to_string),
    );
    package.join(".")
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
            .parse(crate::ast::parse_buffer(&source, language), None)
            .with_context(|| format!("tree-sitter produced no tree for {}", file.display()))?;
        Ok(Self { file, source, tree })
    }
}
