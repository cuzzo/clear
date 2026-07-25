//! Lossless SCIP call-identity import.
//!
//! The importer performs only relations guaranteed by a SCIP index: selecting
//! the symbol occurrence inside a normalized call and joining its definition
//! occurrence to the innermost emitted project method. Language-owned external
//! symbol parsing is delegated back to the source adapter.

use crate::profile::{summarize_call_resolution, CallRecord, MethodRecord, ProfileOutput};
use crate::syntax;
use anyhow::{Context, Result};
use serde::Deserialize;
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::Path;
use std::process::Command;

#[derive(Clone, Debug, Default, Eq, PartialEq)]
pub struct ImportStats {
    pub eligible_calls: usize,
    pub matched_occurrences: usize,
    pub exact_project_targets: usize,
    pub external_symbols: usize,
    pub modeled_external_symbols: usize,
    pub unmatched_calls: usize,
}

#[derive(Debug, Deserialize)]
struct Index {
    #[serde(default)]
    metadata: Option<Metadata>,
    #[serde(default)]
    documents: Vec<Document>,
}

#[derive(Debug, Deserialize)]
struct Metadata {
    #[serde(default, alias = "textDocumentEncoding")]
    text_document_encoding: TextDocumentEncoding,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(untagged)]
enum TextDocumentEncoding {
    #[default]
    Unspecified,
    Number(u32),
    Name(String),
}

impl TextDocumentEncoding {
    fn is_utf8(&self) -> bool {
        match self {
            Self::Unspecified | Self::Number(0 | 1) => true,
            Self::Name(name) => matches!(
                name.to_ascii_lowercase().as_str(),
                "utf-8" | "utf8" | "utf_8"
            ),
            _ => false,
        }
    }
}

#[derive(Debug, Deserialize)]
struct Document {
    #[serde(alias = "relativePath")]
    relative_path: String,
    #[serde(default)]
    occurrences: Vec<Occurrence>,
    #[serde(default)]
    symbols: Vec<SymbolInformation>,
}

#[derive(Debug, Deserialize)]
struct SymbolInformation {
    symbol: String,
    #[serde(default)]
    relationships: Vec<Relationship>,
}

#[derive(Debug, Deserialize)]
struct Relationship {
    symbol: String,
    #[serde(default, alias = "isImplementation")]
    is_implementation: bool,
}

#[derive(Clone, Debug, Deserialize)]
struct Occurrence {
    /// Canonical SCIP JSON uses a compact `range` array. Older `scip print`
    /// builds also emitted a decoded `TypedRange` object, which we continue
    /// to accept so existing indexes remain usable.
    #[serde(default)]
    range: Vec<usize>,
    #[serde(rename = "TypedRange", default)]
    typed_range: Option<TypedRange>,
    #[serde(default)]
    symbol: String,
    #[serde(default, alias = "symbolRoles")]
    symbol_roles: u32,
}

#[derive(Clone, Debug, Deserialize)]
#[serde(untagged)]
enum TypedRange {
    Single {
        #[serde(rename = "SingleLineRange")]
        value: SingleLineRange,
    },
    Multi {
        #[serde(rename = "MultiLineRange")]
        value: MultiLineRange,
    },
}

#[derive(Clone, Debug, Deserialize)]
struct SingleLineRange {
    #[serde(default)]
    line: usize,
    #[serde(default)]
    start_character: usize,
    #[serde(default)]
    end_character: usize,
}

#[derive(Clone, Debug, Deserialize)]
struct MultiLineRange {
    #[serde(default)]
    start_line: usize,
    #[serde(default)]
    start_character: usize,
    #[serde(default)]
    end_line: usize,
    #[serde(default)]
    end_character: usize,
}

impl TypedRange {
    fn span(&self) -> [usize; 4] {
        match self {
            Self::Single { value } => [
                value.line,
                value.start_character,
                value.line,
                value.end_character,
            ],
            Self::Multi { value } => [
                value.start_line,
                value.start_character,
                value.end_line,
                value.end_character,
            ],
        }
    }
}

impl Occurrence {
    fn span(&self) -> Option<[usize; 4]> {
        match self.range.as_slice() {
            [line, start_character, end_character] => {
                Some([*line, *start_character, *line, *end_character])
            }
            [start_line, start_character, end_line, end_character] => {
                Some([*start_line, *start_character, *end_line, *end_character])
            }
            [] => self.typed_range.as_ref().map(TypedRange::span),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
struct SelectedOccurrences<'a> {
    primary: &'a Occurrence,
    alternatives: Vec<&'a Occurrence>,
}

#[derive(Clone, Debug)]
struct Definition {
    method_id: Option<String>,
}

pub fn apply_json_file(output: &mut ProfileOutput, index_path: &Path) -> Result<ImportStats> {
    let json = if index_path
        .extension()
        .and_then(|extension| extension.to_str())
        == Some("scip")
    {
        let binary = std::env::var("SCIP_BINARY").unwrap_or_else(|_| "scip".to_string());
        let result = Command::new(&binary)
            .args(["print", "--json"])
            .arg(index_path)
            .output()
            .with_context(|| format!("failed to execute {binary} print --json"))?;
        if !result.status.success() {
            anyhow::bail!(
                "{binary} print --json failed for {}: {}",
                index_path.display(),
                String::from_utf8_lossy(&result.stderr)
            );
        }
        String::from_utf8(result.stdout).context("SCIP JSON output was not UTF-8")?
    } else {
        fs::read_to_string(index_path)
            .with_context(|| format!("failed to read SCIP JSON index {}", index_path.display()))?
    };
    apply_json(output, &json)
        .with_context(|| format!("failed to import SCIP JSON index {}", index_path.display()))
}

pub fn apply_json(output: &mut ProfileOutput, json: &str) -> Result<ImportStats> {
    let index: Index = serde_json::from_str(json)?;
    if index
        .metadata
        .as_ref()
        .is_some_and(|metadata| !metadata.text_document_encoding.is_utf8())
    {
        anyhow::bail!(
            "SCIP index uses non-UTF-8 text_document_encoding; column conversion is required"
        );
    }
    assign_method_symbols(&mut output.methods, &index.documents);
    let methods_by_path = methods_by_document(&output.methods, &index.documents);
    let definitions = definitions_by_symbol(&index.documents, &methods_by_path);
    let implementation_targets = implementation_targets(&index.documents, &definitions);
    let method_languages = output
        .methods
        .iter()
        .map(|method| (method.id.clone(), method.language.clone()))
        .collect::<BTreeMap<_, _>>();
    let mut stats = ImportStats::default();

    for call in &mut output.calls {
        let Some(language) = method_languages.get(&call.source) else {
            continue;
        };
        stats.eligible_calls += 1;
        let Some(document) = select_document_for_path(&call.path, &index.documents) else {
            stats.unmatched_calls += 1;
            continue;
        };
        let source = fs::read_to_string(&call.path).unwrap_or_default();
        let Some(selected) = select_call_occurrences(call, document, &source, language) else {
            stats.unmatched_calls += 1;
            continue;
        };

        let occurrence = selected.primary;
        let selected_symbols = selected
            .alternatives
            .iter()
            .map(|candidate| candidate.symbol.as_str())
            .collect::<BTreeSet<_>>();

        let target_ids = selected
            .alternatives
            .iter()
            .flat_map(|candidate| {
                let key = definition_key(&document.relative_path, &candidate.symbol);
                definitions.get(&key).into_iter().flatten()
            })
            .filter_map(|definition| definition.method_id.as_deref())
            .collect::<BTreeSet<_>>();
        let candidate_costs = selected
            .alternatives
            .iter()
            .filter_map(|candidate| {
                syntax::external_symbol_call_complexity(language, &candidate.symbol, &call.message)
            })
            .collect::<Vec<_>>();
        let converged_cost = (selected_symbols.len() == 1
            || (candidate_costs.len() == selected_symbols.len()
                && candidate_costs
                    .windows(2)
                    .all(|pair| equivalent_external_cost(&pair[0], &pair[1]))))
        .then(|| candidate_costs.into_iter().next())
        .flatten();

        stats.matched_occurrences += 1;
        call.semantic_symbol = Some(occurrence.symbol.clone());
        call.target_provenance = Some("scip".to_string());
        call.candidate_targets.clear();
        call.candidate_reason = None;

        if target_ids.len() == 1 {
            let target = target_ids.into_iter().next().unwrap().to_string();
            call.kind = "resolved_call".to_string();
            call.target = Some(target);
            call.external_symbol_scope = None;
            call.complexity_missing_kind = None;
            call.known_time_complexity = None;
            call.known_space_complexity = None;
            call.unresolved_reason = None;
            call.resolution_missing_proof = None;
            call.empty_domain_cause = None;
            stats.exact_project_targets += 1;
        } else if !target_ids.is_empty() {
            // A compiler index may legitimately map one source selector to
            // multiple overloads, or one symbol to multiple in-project
            // definitions (for example macro/configuration surfaces). Those
            // are closed project candidates, never evidence of a dependency.
            call.target = None;
            call.kind = "unresolved_call".to_string();
            call.external_symbol_scope = Some("project".to_string());
            call.complexity_missing_kind = None;
            call.known_time_complexity = None;
            call.known_space_complexity = None;
            call.complexity_provenance = None;
            call.complexity_bound_quality = None;
            call.complexity_candidates.clear();
            call.complexity_assumptions.clear();
            call.candidate_targets = target_ids.into_iter().map(str::to_string).collect();
            call.candidate_reason = Some("scip_project_candidate_set".to_string());
            call.unresolved_reason =
                Some("scip_closed_project_candidate_set_requires_summary".to_string());
            call.resolution_missing_proof = Some("closed_candidate_cost_join_required".to_string());
            call.empty_domain_cause = None;
        } else {
            // SCIP proved an external/excluded symbol. A prior heuristic
            // project target must not outrank compiler identity.
            call.target = None;
            call.kind = "external_call".to_string();
            let metadata = syntax::external_symbol_metadata(language, &occurrence.symbol);
            call.external_symbol_scope = Some(metadata.scope.to_string());
            call.complexity_missing_kind = Some(metadata.missing_cost_kind);
            let parametric_cost = metadata.parametric_cost;
            stats.external_symbols += 1;
            if selected_symbols.len() > 1 {
                call.complexity_candidates = selected_symbols
                    .iter()
                    .map(|symbol| (*symbol).to_string())
                    .collect();
            }
            if let Some(complexity) = converged_cost.or_else(|| {
                syntax::external_symbol_call_complexity(language, &occurrence.symbol, &call.message)
            }) {
                call.known_time_complexity = Some(complexity.time.to_string());
                call.known_space_complexity = Some(complexity.space.to_string());
                call.complexity_provenance = Some(complexity.provenance.to_string());
                call.complexity_bound_quality = Some(complexity.bound_quality.to_string());
                call.complexity_candidates = complexity.candidates;
                if selected_symbols.len() > 1 {
                    call.complexity_candidates
                        .extend(selected_symbols.iter().map(|symbol| (*symbol).to_string()));
                    call.complexity_candidates.sort();
                    call.complexity_candidates.dedup();
                }
                call.complexity_assumptions = complexity.assumption.into_iter().collect();
                call.unresolved_reason = None;
                call.resolution_missing_proof = None;
                call.empty_domain_cause = None;
                call.complexity_missing_kind = None;
                stats.modeled_external_symbols += 1;
            } else if let Some(parametric_cost) = parametric_cost {
                let (time, space) = syntax::parametric_call_complexity(&parametric_cost)
                    .ok_or_else(|| {
                        anyhow::anyhow!(
                            "unsupported parametric external cost {parametric_cost} for {}",
                            occurrence.symbol
                        )
                    })?;
                call.known_time_complexity = Some(time.to_string());
                call.known_space_complexity = Some(space.to_string());
                call.complexity_provenance = Some("parametric_external_contract".to_string());
                call.complexity_bound_quality =
                    Some(format!("upper_bound_parametric_{parametric_cost}"));
                call.complexity_missing_kind = None;
                call.unresolved_reason = None;
                call.resolution_missing_proof = None;
                call.empty_domain_cause = None;
                stats.modeled_external_symbols += 1;
            } else if let Some(candidates) = implementation_targets.get(&occurrence.symbol) {
                // A compiler-provided closed implementation set is stronger
                // than a generic callback placeholder. Preserve the entire
                // set so Espalier can take the conservative maximum after it
                // has analyzed the candidate bodies.
                call.candidate_targets = candidates.iter().cloned().collect();
                call.candidate_reason = Some("scip_implementation_set".to_string());
                call.unresolved_reason =
                    Some("scip_closed_implementation_set_requires_summary".to_string());
                call.resolution_missing_proof =
                    Some("closed_candidate_cost_join_required".to_string());
                call.empty_domain_cause = None;
            } else if compiler_proven_project_interface_call(
                &output.owners,
                language,
                &occurrence.symbol,
            ) {
                let (time, space) = syntax::parametric_call_complexity("callback_once").unwrap();
                call.callback_receiver = true;
                call.external_symbol_scope = Some("project_interface".to_string());
                call.known_time_complexity = Some(time.to_string());
                call.known_space_complexity = Some(space.to_string());
                call.complexity_provenance = Some("compiler_proven_interface_contract".to_string());
                call.complexity_bound_quality =
                    Some("upper_bound_parametric_callback_once".to_string());
                call.complexity_missing_kind = None;
                call.unresolved_reason = None;
                call.resolution_missing_proof = None;
                call.empty_domain_cause = None;
                stats.modeled_external_symbols += 1;
            } else if call.known_time_complexity.is_some() || call.known_space_complexity.is_some()
            {
                // A pre-existing model was already gated by FactMine's
                // language-owned receiver proof. SCIP confirms external
                // identity but need not replace that independently sound cost.
                call.unresolved_reason = None;
                call.resolution_missing_proof = None;
                call.empty_domain_cause = None;
                call.complexity_missing_kind = None;
                stats.modeled_external_symbols += 1;
            } else {
                call.unresolved_reason = Some("scip_external_symbol_unmodeled".to_string());
                call.resolution_missing_proof =
                    Some("dependency_or_stdlib_symbol_known_cost_unavailable".to_string());
                call.empty_domain_cause = Some("external_declaration".to_string());
            }
        }
    }

    reconcile_non_recursive_overload_calls(output);

    let raw_parser_call_sites = output.call_resolution_coverage.raw_parser_call_sites;
    let raw_calls_not_normalized = output.call_resolution_coverage.raw_calls_not_normalized;
    let raw_calls_not_normalized_inside_function = output
        .call_resolution_coverage
        .raw_calls_not_normalized_inside_function;
    let raw_calls_not_normalized_outside_function = output
        .call_resolution_coverage
        .raw_calls_not_normalized_outside_function;
    let raw_calls_not_normalized_by_kind = output
        .call_resolution_coverage
        .raw_calls_not_normalized_by_kind
        .clone();
    let raw_call_normalization_gap_samples = output
        .call_resolution_coverage
        .raw_call_normalization_gap_samples
        .clone();
    let normalized_calls_without_raw_span = output
        .call_resolution_coverage
        .normalized_calls_without_raw_span;
    output.call_resolution_coverage =
        summarize_call_resolution(&output.owners, &output.methods, &output.calls);
    output.call_resolution_coverage.raw_parser_call_sites = raw_parser_call_sites;
    output.call_resolution_coverage.raw_calls_not_normalized = raw_calls_not_normalized;
    output
        .call_resolution_coverage
        .raw_calls_not_normalized_inside_function = raw_calls_not_normalized_inside_function;
    output
        .call_resolution_coverage
        .raw_calls_not_normalized_outside_function = raw_calls_not_normalized_outside_function;
    output
        .call_resolution_coverage
        .raw_calls_not_normalized_by_kind = raw_calls_not_normalized_by_kind;
    output
        .call_resolution_coverage
        .raw_call_normalization_gap_samples = raw_call_normalization_gap_samples;
    output
        .call_resolution_coverage
        .normalized_calls_without_raw_span = normalized_calls_without_raw_span;
    // SCIP can replace a same-file heuristic target with the exact semantic
    // identity of a function-valued field. Re-run the shared merged-field
    // contract after that replacement so cross-file callable declarations are
    // not lost merely because the compiler correctly rejected the heuristic.
    crate::profile::reapply_declared_callback_costs(output);
    Ok(stats)
}

fn compiler_proven_project_interface_call(
    owners: &[crate::profile::OwnerRecord],
    language: &str,
    symbol: &str,
) -> bool {
    let Some(symbol_owner) = syntax::external_symbol_owner(language, symbol) else {
        return false;
    };
    let suffix = format!(".{symbol_owner}");
    let exact = owners.iter().filter(|owner| {
        owner.language == language
            && owner.kind == "interface"
            && (owner.symbol.as_deref() == Some(symbol_owner.as_str())
                || owner
                    .symbol
                    .as_deref()
                    .is_some_and(|candidate| candidate.ends_with(&suffix)))
    });
    if exact.count() == 1 {
        return true;
    }

    // Some producers encode an import path rather than the source package
    // name (`github.com/acme/tool/v2` versus `package tool`). The final type
    // descriptor remains compiler-proven. Accept it only when it selects one
    // normalized project interface; duplicate short names remain ambiguous.
    let unqualified = symbol_owner.rsplit('.').next().unwrap_or(&symbol_owner);
    owners
        .iter()
        .filter(|owner| {
            owner.language == language && owner.kind == "interface" && owner.name == unqualified
        })
        .count()
        == 1
}

fn equivalent_external_cost(
    left: &crate::syntax::ExternalCallComplexity,
    right: &crate::syntax::ExternalCallComplexity,
) -> bool {
    left.time == right.time
        && left.space == right.space
        && left.provenance == right.provenance
        && left.bound_quality == right.bound_quality
        && left.candidates == right.candidates
        && left.assumption == right.assumption
}

fn implementation_targets(
    documents: &[Document],
    definitions: &BTreeMap<String, Vec<Definition>>,
) -> BTreeMap<String, BTreeSet<String>> {
    let mut implementation_symbols = BTreeMap::<String, BTreeSet<String>>::new();
    for information in documents.iter().flat_map(|document| &document.symbols) {
        for relationship in &information.relationships {
            if relationship.is_implementation {
                implementation_symbols
                    .entry(relationship.symbol.clone())
                    .or_default()
                    .insert(information.symbol.clone());
            }
        }
    }
    implementation_symbols
        .into_iter()
        .filter_map(|(declaration, implementations)| {
            let targets = implementations
                .iter()
                .flat_map(|symbol| definitions.get(symbol).into_iter().flatten())
                .filter_map(|definition| definition.method_id.clone())
                .collect::<BTreeSet<_>>();
            (!targets.is_empty()).then_some((declaration, targets))
        })
        .collect()
}

fn assign_method_symbols(methods: &mut [MethodRecord], documents: &[Document]) {
    let methods_by_path = methods_by_document(methods, documents);
    let covered_method_ids = methods_by_path
        .values()
        .flatten()
        .map(|method| method.id.clone())
        .collect::<BTreeSet<_>>();
    let mut symbols = BTreeMap::<String, BTreeSet<String>>::new();
    for document in documents {
        let source = methods_by_path
            .get(&document.relative_path)
            .and_then(|rows| rows.first())
            .and_then(|method| fs::read_to_string(&method.path).ok())
            .unwrap_or_default();
        for occurrence in document
            .occurrences
            .iter()
            .filter(|occurrence| occurrence.symbol_roles & 1 == 1)
        {
            let Some(span) = occurrence.span() else {
                continue;
            };
            let one_based = [span[0] + 1, span[1], span[2] + 1, span[3]];
            if let Some(method) = methods_by_path
                .get(&document.relative_path)
                .into_iter()
                .flatten()
                .filter(|method| method.span.is_some_and(|outer| contains(outer, one_based)))
                .min_by_key(|method| method_span_size(method))
            {
                let declaration = occurrence_text(&source, span);
                if !callable_symbol(&occurrence.symbol)
                    && declaration != method.name
                    && declaration != method.dispatch_name
                {
                    continue;
                }
                symbols
                    .entry(method.id.clone())
                    .or_default()
                    .insert(occurrence.symbol.clone());
            }
        }
    }
    drop(methods_by_path);
    for method in methods {
        // Multiple --scip-index inputs are applied sequentially. An index may
        // update only declarations in documents it actually covers; clearing
        // every other symbol here would erase the preceding repository.
        if !covered_method_ids.contains(&method.id) {
            continue;
        }
        method.semantic_symbol = symbols
            .remove(&method.id)
            .filter(|candidates| candidates.len() == 1)
            .and_then(|candidates| candidates.into_iter().next());
    }
}

/// Syntax-only recursion extraction deliberately runs before corpus call
/// resolution. At that point a bare same-spelled call can only be treated as
/// potentially recursive. Once SCIP has supplied exact method IDs, remove the
/// false positive when every such call is resolved and every target is a
/// different overload. Genuine self-recursion and partially resolved groups
/// remain untouched.
fn reconcile_non_recursive_overload_calls(output: &mut ProfileOutput) {
    let mut method_ids = BTreeMap::<(String, String, String, usize), Vec<String>>::new();
    for method in &output.methods {
        method_ids
            .entry((
                method.path.clone(),
                method.owner.clone(),
                method.name.clone(),
                method.line,
            ))
            .or_default()
            .push(method.id.clone());
    }

    let calls_by_source = output
        .calls
        .iter()
        .filter(|call| {
            call.implicit_receiver
                || matches!(call.receiver.as_str(), "self" | "this")
                || call.receiver.is_empty()
        })
        .fold(
            BTreeMap::<String, Vec<&CallRecord>>::new(),
            |mut rows, call| {
                rows.entry(call.source.clone()).or_default().push(call);
                rows
            },
        );

    for fact in &mut output.complexity_facts {
        if fact.recursion.calls == 0 {
            continue;
        }
        let key = (
            fact.path.clone(),
            fact.owner.clone(),
            fact.function.clone(),
            fact.line,
        );
        let Some(ids) = method_ids.get(&key) else {
            continue;
        };
        if ids.len() != 1 {
            continue;
        }
        let source = &ids[0];
        let candidates = calls_by_source
            .get(source)
            .into_iter()
            .flatten()
            .filter(|call| call.message == fact.function)
            .collect::<Vec<_>>();
        if candidates.len() != fact.recursion.calls
            || candidates.iter().any(|call| call.target.is_none())
            || candidates
                .iter()
                .any(|call| call.target.as_deref() == Some(source.as_str()))
        {
            continue;
        }

        fact.recursion = Default::default();
    }
}

fn methods_by_document<'a>(
    methods: &'a [MethodRecord],
    documents: &[Document],
) -> BTreeMap<String, Vec<&'a MethodRecord>> {
    let mut by_document = documents
        .iter()
        .map(|document| (document.relative_path.clone(), Vec::new()))
        .collect::<BTreeMap<_, Vec<&MethodRecord>>>();
    for method in methods {
        if let Some(document) = select_document_for_path(&method.path, documents) {
            by_document
                .entry(document.relative_path.clone())
                .or_default()
                .push(method);
        }
    }
    by_document
}

/// A repository may contain both `lru.go` and `simplelru/lru.go`. Both are
/// suffixes of an absolute source path, but only the longest matching SCIP
/// document is its identity. Equal-specificity matches remain ambiguous.
fn select_document_for_path<'a>(path: &str, documents: &'a [Document]) -> Option<&'a Document> {
    let matches = documents
        .iter()
        .filter(|document| path_ends_with(path, &document.relative_path))
        .collect::<Vec<_>>();
    let specificity = matches
        .iter()
        .map(|document| document.relative_path.replace('\\', "/").len())
        .max()?;
    let best = matches
        .into_iter()
        .filter(|document| document.relative_path.replace('\\', "/").len() == specificity)
        .collect::<Vec<_>>();
    (best.len() == 1).then(|| best[0])
}

fn definitions_by_symbol(
    documents: &[Document],
    methods_by_path: &BTreeMap<String, Vec<&MethodRecord>>,
) -> BTreeMap<String, Vec<Definition>> {
    let mut definitions = BTreeMap::<String, Vec<Definition>>::new();
    for document in documents {
        for occurrence in document
            .occurrences
            .iter()
            .filter(|occurrence| occurrence.symbol_roles & 1 == 1)
        {
            let Some(span) = occurrence.span() else {
                continue;
            };
            let one_based = [span[0] + 1, span[1], span[2] + 1, span[3]];
            let method_id = methods_by_path
                .get(&document.relative_path)
                .into_iter()
                .flatten()
                .filter(|method| method.span.is_some_and(|outer| contains(outer, one_based)))
                .min_by_key(|method| method_span_size(method))
                .map(|method| method.id.clone());
            definitions
                .entry(definition_key(&document.relative_path, &occurrence.symbol))
                .or_default()
                .push(Definition { method_id });
        }
    }
    definitions
}

fn select_call_occurrences<'a>(
    call: &CallRecord,
    document: &'a Document,
    source: &str,
    language: &str,
) -> Option<SelectedOccurrences<'a>> {
    let call_span = [
        call.span[0].saturating_sub(1),
        call.span[1],
        call.span[2].saturating_sub(1),
        call.span[3],
    ];
    let message = bare_message(&call.message);
    let argument_start = first_argument_start(source, call_span);
    let contained = document
        .occurrences
        .iter()
        .filter(|occurrence| occurrence.symbol_roles & 1 == 0)
        .filter(|occurrence| {
            occurrence
                .span()
                .is_some_and(|span| contains(call_span, span))
        })
        .collect::<Vec<_>>();
    let mut exact = contained
        .iter()
        .copied()
        .filter(|occurrence| {
            occurrence
                .span()
                .is_some_and(|span| occurrence_text(source, span) == message)
        })
        .collect::<Vec<_>>();
    exact.sort_by_key(|occurrence| occurrence.span());
    if let Some(receiver_span) = call.receiver_call_span.map(|span| {
        [
            span[0].saturating_sub(1),
            span[1],
            span[2].saturating_sub(1),
            span[3],
        ]
    }) {
        let outside_receiver = exact
            .iter()
            .copied()
            .filter(|occurrence| {
                occurrence
                    .span()
                    .is_some_and(|span| !contains(receiver_span, span))
            })
            .collect::<Vec<_>>();
        if language == "java" {
            if let Some(selected) = first_semantic_occurrence(&outside_receiver) {
                return selected_occurrences(&[selected]);
            }
        } else if !outside_receiver.is_empty() {
            return selected_occurrences(&outside_receiver);
        }
    }
    // A normalized call span covers its arguments, so a nested call may
    // contribute another same-spelled SCIP occurrence.  The outer callee is
    // the unique occurrence before the call's first argument delimiter.  This
    // is syntax-position evidence, independent of the producer language, and
    // avoids rejecting `pkg.New(value.New())` merely because both declarations
    // are semantically distinct.
    if let Some(argument_start) = argument_start {
        let callee_occurrences = exact
            .iter()
            .copied()
            .filter(|occurrence| {
                occurrence
                    .span()
                    .is_some_and(|span| (span[2], span[3]) <= argument_start)
            })
            .collect::<Vec<_>>();
        if callee_occurrences.len() == 1 {
            return selected_occurrences(&callee_occurrences);
        }
    }
    let outer_selector = exact
        .iter()
        .copied()
        .filter(|occurrence| {
            occurrence
                .span()
                .is_some_and(|span| occurrence_is_outer_selector(source, call_span, span))
        })
        .collect::<Vec<_>>();
    if !outer_selector.is_empty() {
        let preferred = if call.preprocessor_callable {
            let macros = outer_selector
                .iter()
                .copied()
                .filter(|occurrence| occurrence.symbol.ends_with('!'))
                .collect::<Vec<_>>();
            (!macros.is_empty()).then_some(macros)
        } else {
            None
        };
        return selected_occurrences(preferred.as_deref().unwrap_or(&outer_selector));
    }
    let callable = exact
        .iter()
        .copied()
        .filter(|occurrence| {
            callable_symbol(&occurrence.symbol) || occurrence.symbol.starts_with("local ")
        })
        .collect::<Vec<_>>();
    if language == "java" {
        if let Some(selected) = first_semantic_occurrence(&callable) {
            return selected_occurrences(&[selected]);
        }
    }
    let property_accesses = exact
        .iter()
        .copied()
        .filter(|occurrence| {
            semantic_symbol(&occurrence.symbol)
                && syntax::scip_noncall_access_is_callable(language, &occurrence.symbol)
        })
        .collect::<Vec<_>>();
    if !property_accesses.is_empty() {
        return selected_occurrences(&property_accesses);
    }
    // Never borrow the identity of a nested call when SCIP has no occurrence
    // spelling the normalized outer message. This is common for conversions
    // and other syntax-only constructs (`int(inner())`, casts, wrappers).
    let selected = unambiguous_identity_occurrence(&callable)?;
    selected_occurrences(&[selected])
}

fn selected_occurrences<'a>(rows: &[&'a Occurrence]) -> Option<SelectedOccurrences<'a>> {
    let semantic = rows
        .iter()
        .copied()
        .filter(|occurrence| semantic_symbol(&occurrence.symbol))
        .collect::<Vec<_>>();
    let alternatives = if semantic.is_empty() {
        rows.to_vec()
    } else {
        semantic
    };
    let primary = *alternatives.first()?;
    Some(SelectedOccurrences {
        primary,
        alternatives,
    })
}

/// A normalized call span may contain several nested calls and repeated
/// selector spellings. Select the occurrence whose following argument list
/// closes at the end of this call span. This is grammar-independent source
/// position evidence and avoids reconstructing a language-specific receiver.
fn occurrence_is_outer_selector(
    source: &str,
    call_span: [usize; 4],
    occurrence_span: [usize; 4],
) -> bool {
    if occurrence_span[0] != occurrence_span[2] {
        return false;
    }
    let lines = source.lines().collect::<Vec<_>>();
    let Some(occurrence_end) = source_offset(&lines, occurrence_span[2], occurrence_span[3]) else {
        return false;
    };
    let Some(call_end) = source_offset(&lines, call_span[2], call_span[3]) else {
        return false;
    };
    let bytes = source.as_bytes();
    let mut open = occurrence_end;
    while open < call_end && bytes.get(open).is_some_and(u8::is_ascii_whitespace) {
        open += 1;
    }
    if bytes.get(open) == Some(&b'<') {
        let mut template_depth = 0usize;
        let mut close = None;
        for (offset, byte) in bytes[open..call_end].iter().copied().enumerate() {
            if byte == b'<' {
                template_depth += 1;
            } else if byte == b'>' {
                template_depth = template_depth.saturating_sub(1);
                if template_depth == 0 {
                    close = Some(open + offset + 1);
                    break;
                }
            }
        }
        let Some(template_end) = close else {
            return false;
        };
        open = template_end;
        while open < call_end && bytes.get(open).is_some_and(u8::is_ascii_whitespace) {
            open += 1;
        }
    }
    if bytes.get(open) != Some(&b'(') {
        return false;
    }
    let mut depth = 0usize;
    let mut quote = None;
    let mut escaped = false;
    for (offset, byte) in bytes[open..call_end].iter().copied().enumerate() {
        if let Some(active) = quote {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == active {
                quote = None;
            }
            continue;
        }
        if matches!(byte, b'\'' | b'"' | b'`') {
            quote = Some(byte);
            continue;
        }
        if byte == b'(' {
            depth += 1;
        } else if byte == b')' {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                let close = open + offset + 1;
                return bytes[close..call_end].iter().all(u8::is_ascii_whitespace);
            }
        }
    }
    false
}

fn source_offset(lines: &[&str], line: usize, column: usize) -> Option<usize> {
    let current = *lines.get(line)?;
    (column <= current.len())
        .then(|| lines[..line].iter().map(|row| row.len() + 1).sum::<usize>() + column)
}

fn first_argument_start(source: &str, call_span: [usize; 4]) -> Option<(usize, usize)> {
    if let Some(line_index) = (call_span[0]..=call_span[2]).next() {
        let line = source.lines().nth(line_index)?;
        let start = if line_index == call_span[0] {
            call_span[1]
        } else {
            0
        };
        let end = if line_index == call_span[2] {
            call_span[3].min(line.len())
        } else {
            line.len()
        };
        let offset = line.get(start..end)?.find('(')?;
        return Some((line_index, start + offset));
    }
    None
}

fn first_semantic_occurrence<'a>(rows: &[&'a Occurrence]) -> Option<&'a Occurrence> {
    rows.iter()
        .copied()
        .filter(|occurrence| semantic_symbol(&occurrence.symbol))
        .min_by_key(|occurrence| occurrence.span())
}

fn unambiguous_identity_occurrence<'a>(rows: &[&'a Occurrence]) -> Option<&'a Occurrence> {
    let semantic = rows
        .iter()
        .copied()
        .filter(|occurrence| semantic_symbol(&occurrence.symbol))
        .collect::<Vec<_>>();
    let preferred = if semantic.is_empty() { rows } else { &semantic };
    let symbols = preferred
        .iter()
        .map(|occurrence| occurrence.symbol.as_str())
        .collect::<BTreeSet<_>>();
    (symbols.len() == 1).then(|| preferred[0])
}

fn callable_symbol(symbol: &str) -> bool {
    symbol.ends_with(").") || symbol.contains("`<init>`")
}

fn semantic_symbol(symbol: &str) -> bool {
    !symbol.is_empty() && !symbol.starts_with("local ")
}

fn bare_message(message: &str) -> &str {
    crate::syntax::normalized_behavior::balanced_selector_name(message)
}

fn occurrence_text(source: &str, span: [usize; 4]) -> &str {
    if span[0] != span[2] {
        return "";
    }
    source
        .lines()
        .nth(span[0])
        .and_then(|line| line.get(span[1]..span[3]))
        .unwrap_or("")
}

fn definition_key(document: &str, symbol: &str) -> String {
    if symbol.starts_with("local ") {
        format!("{document}\0{symbol}")
    } else {
        symbol.to_string()
    }
}

fn path_ends_with(path: &str, relative: &str) -> bool {
    let path = path.replace('\\', "/");
    let relative = relative.replace('\\', "/");
    path == relative || path.ends_with(&format!("/{relative}"))
}

fn contains(outer: [usize; 4], inner: [usize; 4]) -> bool {
    (outer[0], outer[1]) <= (inner[0], inner[1]) && (inner[2], inner[3]) <= (outer[2], outer[3])
}

fn method_span_size(method: &&MethodRecord) -> (usize, usize) {
    let span = method.span.unwrap_or([0, 0, usize::MAX, usize::MAX]);
    (span[2].saturating_sub(span[0]), span[3].abs_diff(span[1]))
}

#[cfg(test)]
#[allow(clippy::field_reassign_with_default)] // Fixtures build semantic records incrementally for readability.
mod tests {
    use super::*;
    use crate::profile::{CallRecord, MethodRecord, OwnerRecord};
    use serde_json::json;
    use tempfile::tempdir;

    fn method(id: &str, path: &str, name: &str, span: [usize; 4]) -> MethodRecord {
        MethodRecord {
            id: id.into(),
            semantic_symbol: None,
            owner_id: "owner:Demo".into(),
            key: vec!["Demo".into(), name.into()],
            owner: "Demo".into(),
            symbol_owner: None,
            lexical_symbol: None,
            name: name.into(),
            dispatch_name: name.into(),
            kind: "method".into(),
            path: path.into(),
            line: span[0],
            span: Some(span),
            language: "java".into(),
            signature: String::new(),
            visibility: "public".into(),
            local_complexity: 0.0,
            complexity_signals: BTreeMap::new(),
            params: Vec::new(),
            callback_params: Vec::new(),
            raw_source: String::new(),
            normalized_source: String::new(),
            untraceable_params: Vec::new(),
            source: json!({}),
        }
    }

    fn call(source: &str, path: &str, message: &str, span: [usize; 4]) -> CallRecord {
        CallRecord {
            id: format!("call:{source}:{message}"),
            source: source.into(),
            target: None,
            semantic_symbol: None,
            external_symbol_scope: None,
            complexity_missing_kind: None,
            target_provenance: None,
            candidate_targets: Vec::new(),
            candidate_reason: None,
            kind: "unresolved_call".into(),
            owner: "Demo".into(),
            function: "caller".into(),
            receiver: "value".into(),
            receiver_kind: "value".into(),
            receiver_binding_kind: "local".into(),
            symbol_namespace: None,
            lexical_symbol: None,
            lexical_symbol_origin: None,
            receiver_call_span: None,
            receiver_definition_call_spans: Vec::new(),
            receiver_symbol: None,
            receiver_type: None,
            receiver_type_origin: None,
            receiver_symbol_origin: None,
            implicit_receiver: false,
            state_receiver: false,
            callback_receiver: false,
            preprocessor_callable: false,
            dispatch_boundary: None,
            constructor_target: None,
            known_time_complexity: None,
            known_space_complexity: None,
            complexity_provenance: None,
            complexity_bound_quality: None,
            complexity_candidates: Vec::new(),
            complexity_assumptions: Vec::new(),
            message: message.into(),
            argument_count: 0,
            path: path.into(),
            line: span[0],
            span,
            conditional: false,
            confidence: "unknown".into(),
            unresolved_reason: Some("receiver_requires_corpus_resolution".into()),
            resolution_missing_proof: None,
            empty_domain_cause: None,
        }
    }

    #[test]
    fn go_project_interface_symbols_are_parametric_dispatch_contracts() {
        let owner = OwnerRecord {
            id: "logger".into(),
            name: "Logger".into(),
            kind: "interface".into(),
            language: "go".into(),
            path: "/project/ants.go".into(),
            line: 1,
            span: [1, 0, 3, 1],
            confidence: "high".into(),
            symbol: Some("/project.ants.Logger".into()),
            supertypes: Vec::new(),
        };
        let symbol =
            "scip-go gomod example.test/ants/v2 v1.0.0 `example.test/ants/v2`/Logger#Printf.";

        assert!(compiler_proven_project_interface_call(
            &[owner],
            "go",
            symbol
        ));
    }

    fn occurrence(range: [usize; 3], symbol: &str, roles: u32) -> serde_json::Value {
        json!({
            "TypedRange": {"SingleLineRange": {
                "line": range[0], "start_character": range[1], "end_character": range[2]
            }},
            "symbol": symbol,
            "symbol_roles": roles
        })
    }

    fn canonical_occurrence(range: [usize; 3], symbol: &str, roles: u32) -> serde_json::Value {
        json!({
            "range": range,
            "TypedRange": null,
            "symbol": symbol,
            "symbol_roles": roles
        })
    }

    #[test]
    fn longest_relative_document_path_wins_suffix_collisions() {
        let documents = vec![
            Document {
                relative_path: "lru.go".into(),
                occurrences: Vec::new(),
                symbols: Vec::new(),
            },
            Document {
                relative_path: "simplelru/lru.go".into(),
                occurrences: Vec::new(),
                symbols: Vec::new(),
            },
        ];
        assert_eq!(
            select_document_for_path("/repo/simplelru/lru.go", &documents)
                .map(|document| document.relative_path.as_str()),
            Some("simplelru/lru.go")
        );
        assert_eq!(
            select_document_for_path("/repo/lru.go", &documents)
                .map(|document| document.relative_path.as_str()),
            Some("lru.go")
        );
    }

    #[test]
    fn imports_exact_project_targets_from_all_supported_compiler_indexes() {
        let cases = [
            ("c", "demo.c", "cxx . demo v1$ callee(abc)."),
            ("cpp", "demo.cpp", "cxx . demo v1$ Demo#callee(abc)."),
            ("csharp", "Demo.cs", "scip-dotnet nuget . . Demo/Callee()."),
            (
                "kotlin",
                "Demo.kt",
                "scip-java maven example/demo 1.0.0 demo/callee().",
            ),
            (
                "php",
                "Demo.php",
                "scip-php composer example/demo 1.0.0 callee().",
            ),
            (
                "lua",
                "demo.lua",
                "scip-lua luarocks example-demo workspace demo/L0C0/callee().",
            ),
            ("swift", "Demo.swift", "swift Demo callee()."),
            (
                "typescript",
                "demo.ts",
                "scip-typescript npm demo 1.0.0 src/demo/callee().",
            ),
        ];

        for (language, filename, symbol) in cases {
            let dir = tempdir().unwrap();
            let path = dir.path().join(filename);
            let declaration = "function callee() {}";
            let caller = "function caller() { callee(); }";
            fs::write(&path, format!("{declaration}\n{caller}\n")).unwrap();
            let path = path.to_string_lossy().to_string();
            let declaration_column = declaration.find("callee").unwrap();
            let call_column = caller.find("callee").unwrap();
            let index = json!({"documents": [{
                "relative_path": filename,
                "occurrences": [
                    canonical_occurrence(
                        [0, declaration_column, declaration_column + "callee".len()],
                        symbol,
                        1,
                    ),
                    canonical_occurrence(
                        [1, call_column, call_column + "callee".len()],
                        symbol,
                        8,
                    ),
                ]
            }]});
            let mut callee = method("callee", &path, "callee", [1, 1, 1, declaration.len()]);
            let mut caller_method = method("caller", &path, "caller", [2, 1, 2, caller.len()]);
            callee.language = language.into();
            caller_method.language = language.into();
            let mut output = ProfileOutput::default();
            output.methods = vec![callee, caller_method];
            output.calls.push(call(
                "caller",
                &path,
                "callee",
                [2, call_column, 2, call_column + "callee();".len()],
            ));

            let stats = apply_json(&mut output, &index.to_string()).unwrap();

            assert_eq!(stats.exact_project_targets, 1, "language={language}");
            assert_eq!(
                output.calls[0].target.as_deref(),
                Some("callee"),
                "language={language}"
            );
            assert_eq!(
                output.calls[0].semantic_symbol.as_deref(),
                Some(symbol),
                "language={language}"
            );
        }
    }

    #[test]
    fn language_owned_external_scip_symbols_use_reviewed_cost_registries() {
        let cases = [
            (
                "cpp",
                "cxx . . $ std/vector#size(abc).",
                "size",
                "O(1)",
                "stdlib",
            ),
            (
                "typescript",
                "scip-typescript npm typescript 5.9.3 lib/`lib.es2015.collection.d.ts`/Map#get().",
                "get",
                "O(N)",
                "stdlib",
            ),
            (
                "csharp",
                "scip-dotnet nuget System.Runtime 9.0.0.0 Text/StringBuilder#Append().",
                "Append",
                "O(N)",
                "stdlib",
            ),
            (
                "csharp",
                "scip-dotnet nuget System.Runtime 9.0.0.0 System/Array#Sort().",
                "Sort",
                "O(N log N)",
                "stdlib",
            ),
            (
                "typescript",
                "scip-typescript npm typescript 5.9.3 lib/`lib.es5.d.ts`/Array#push().",
                "push",
                "O(N)",
                "stdlib",
            ),
            (
                "typescript",
                "scip-typescript npm @types/node 22.13.4 `process.d.ts`/`\"process\"`/global/NodeJS/Process#cwd().",
                "cwd",
                "O(N)",
                "stdlib",
            ),
            (
                "lua",
                "scip-lua luarocks lua . table/insert().",
                "insert",
                "O(N)",
                "stdlib",
            ),
        ];

        for (language, symbol, message, expected_time, expected_scope) in cases {
            let dir = tempdir().unwrap();
            let filename = format!(
                "demo.{}",
                if language == "csharp" { "cs" } else { language }
            );
            let path = dir.path().join(&filename);
            let source = format!("function caller() {{ value.{message}(); }}\n");
            fs::write(&path, &source).unwrap();
            let path = path.to_string_lossy().to_string();
            let column = source.find(message).unwrap();
            let index = json!({"documents": [{
                "relative_path": filename,
                "occurrences": [canonical_occurrence(
                    [0, column, column + message.len()], symbol, 8
                )]
            }]});
            let mut caller = method("caller", &path, "caller", [1, 1, 1, source.len()]);
            caller.language = language.into();
            let mut output = ProfileOutput::default();
            output.methods = vec![caller];
            output.calls.push(call(
                "caller",
                &path,
                message,
                [1, column.saturating_sub(6), 1, column + message.len() + 2],
            ));

            apply_json(&mut output, &index.to_string()).unwrap();

            assert_eq!(
                output.calls[0].known_time_complexity.as_deref(),
                Some(expected_time),
                "language={language}"
            );
            assert_eq!(
                output.calls[0].external_symbol_scope.as_deref(),
                Some(expected_scope),
                "language={language}"
            );
        }
    }

    #[test]
    fn imports_exact_overload_definition_id_from_occurrence() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "class Demo {\n void caller(){ pick(1); }\n void pick(int x){}\n void pick(String x){}\n}\n").unwrap();
        let path = path.to_string_lossy().to_string();
        let int_symbol = "scip-java maven p Demo#pick().";
        let string_symbol = "scip-java maven p Demo#pick(+1).";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [
                canonical_occurrence([1, 16, 20], int_symbol, 0),
                canonical_occurrence([2, 6, 10], int_symbol, 1),
                canonical_occurrence([3, 6, 10], string_symbol, 1)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![
            method("caller", &path, "caller", [2, 1, 2, 25]),
            method("pick-int", &path, "pick", [3, 1, 3, 20]),
            method("pick-string", &path, "pick", [4, 1, 4, 23]),
        ];
        output
            .calls
            .push(call("caller", &path, "pick", [2, 16, 2, 23]));

        let stats = apply_json(&mut output, &index.to_string()).unwrap();
        assert_eq!(stats.exact_project_targets, 1);
        assert_eq!(output.calls[0].target.as_deref(), Some("pick-int"));
        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(int_symbol));
        assert_eq!(output.calls[0].target_provenance.as_deref(), Some("scip"));
    }

    #[test]
    fn later_index_preserves_method_symbols_from_earlier_documents() {
        let dir = tempdir().unwrap();
        let first_path = dir.path().join("src/First.java");
        let second_path = dir.path().join("src/Second.java");
        fs::create_dir_all(first_path.parent().unwrap()).unwrap();
        fs::write(&first_path, "class First { void first(){} }\n").unwrap();
        fs::write(&second_path, "class Second { void second(){} }\n").unwrap();
        let first_path = first_path.to_string_lossy().to_string();
        let second_path = second_path.to_string_lossy().to_string();
        let first_symbol = "scip-java maven p First#first().";
        let second_symbol = "scip-java maven p Second#second().";
        let first_index = json!({"documents": [{
            "relative_path": "src/First.java",
            "occurrences": [canonical_occurrence([0, 19, 24], first_symbol, 1)]
        }]});
        let second_index = json!({"documents": [{
            "relative_path": "src/Second.java",
            "occurrences": [canonical_occurrence([0, 20, 26], second_symbol, 1)]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![
            method("first", &first_path, "first", [1, 1, 1, 32]),
            method("second", &second_path, "second", [1, 1, 1, 35]),
        ];

        apply_json(&mut output, &first_index.to_string()).unwrap();
        apply_json(&mut output, &second_index.to_string()).unwrap();

        assert_eq!(
            output.methods[0].semantic_symbol.as_deref(),
            Some(first_symbol)
        );
        assert_eq!(
            output.methods[1].semantic_symbol.as_deref(),
            Some(second_symbol)
        );
    }

    #[test]
    fn missing_outer_occurrence_does_not_steal_nested_call_identity() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "class Demo { void caller(){ wrap(inner()); } }\n").unwrap();
        let path = path.to_string_lossy().to_string();
        let inner_symbol = "scip-java maven p Demo#inner().";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [canonical_occurrence([0, 33, 38], inner_symbol, 0)]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("caller", &path, "caller", [1, 1, 1, 48])];
        output
            .calls
            .push(call("caller", &path, "wrap", [1, 28, 1, 41]));

        let stats = apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(stats.matched_occurrences, 0);
        assert!(output.calls[0].semantic_symbol.is_none());
    }

    #[test]
    fn call_prefix_selects_outer_identity_when_argument_has_same_spelled_call() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("hmac.go");
        fs::write(
            &path,
            "package demo\nfunc verify(){ hasher := hmac.New(m.Hash.New, key) }\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let outer = "scip-go gomod go std `crypto/hmac`/New().";
        let inner = "scip-go gomod go std crypto/Hash#New().";
        let index = json!({"documents": [{
            "relative_path": "hmac.go",
            "occurrences": [
                canonical_occurrence([1, 30, 33], outer, 8),
                canonical_occurrence([1, 41, 44], inner, 8)
            ]
        }]});
        let mut caller = method("verify", &path, "verify", [2, 1, 2, 58]);
        caller.language = "go".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![caller];
        output
            .calls
            .push(call("verify", &path, "New", [2, 25, 2, 50]));

        let stats = apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(stats.matched_occurrences, 1);
        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(outer));
    }

    #[test]
    fn imports_go_method_symbols_without_parenthesized_descriptors() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("claims.go");
        fs::write(
            &path,
            "package demo\ntype Claims interface { GetAudience() }\nfunc verify(c Claims){ c.GetAudience() }\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let symbol = "scip-go gomod demo current demo/Claims#GetAudience.";
        let index = json!({"documents": [{
            "relative_path": "claims.go",
            "occurrences": [
                canonical_occurrence([1, 24, 35], symbol, 1),
                canonical_occurrence([2, 25, 36], symbol, 8)
            ]
        }]});
        let mut declaration = method("audience", &path, "GetAudience", [2, 1, 2, 39]);
        declaration.language = "go".into();
        let mut caller = method("verify", &path, "verify", [3, 1, 3, 42]);
        caller.language = "go".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![declaration, caller];
        output
            .calls
            .push(call("verify", &path, "GetAudience", [3, 23, 3, 38]));

        let stats = apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(stats.exact_project_targets, 1);
        assert_eq!(output.calls[0].target.as_deref(), Some("audience"));
        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(symbol));
        assert_eq!(output.methods[0].semantic_symbol.as_deref(), Some(symbol));
    }

    #[test]
    fn imports_scip_implementation_relationships_as_closed_candidates() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("claims.go");
        fs::write(
            &path,
            "package demo\ntype MapClaims struct{}\nfunc (MapClaims) GetAudience() {}\nfunc verify(c Claims){ c.GetAudience() }\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let interface = "scip-go gomod demo current demo/Claims#GetAudience.";
        let implementation = "scip-go gomod demo current demo/MapClaims#GetAudience().";
        let index = json!({"documents": [{
            "relative_path": "claims.go",
            "occurrences": [
                canonical_occurrence([2, 17, 28], implementation, 1),
                canonical_occurrence([3, 25, 36], interface, 8)
            ],
            "symbols": [{
                "symbol": implementation,
                "relationships": [{"symbol": interface, "is_implementation": true}]
            }]
        }]});
        let mut implementation_method = method("map-audience", &path, "GetAudience", [3, 1, 3, 34]);
        implementation_method.language = "go".into();
        let mut caller = method("verify", &path, "verify", [4, 1, 4, 42]);
        caller.language = "go".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![implementation_method, caller];
        output
            .calls
            .push(call("verify", &path, "GetAudience", [4, 23, 4, 38]));

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target, None);
        assert_eq!(output.calls[0].candidate_targets, ["map-audience"]);
        assert_eq!(
            output.calls[0].candidate_reason.as_deref(),
            Some("scip_implementation_set")
        );
    }

    #[test]
    fn balanced_template_selector_ignores_qualified_template_arguments() {
        assert_eq!(bare_message("plog::detail::operator<<"), "operator");
        assert_eq!(bare_message("Wrapper<T>::target<U>"), "target");
        assert!(occurrence_is_outer_selector(
            "target<Wrapper::Data>()",
            [0, 0, 0, 23],
            [0, 0, 0, 6]
        ));
        let dir = tempdir().unwrap();
        let path = dir.path().join("demo.cpp");
        fs::write(
            &path,
            "void target() {}\nvoid caller() { detail::target<Wrapper::Data>(); }\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let symbol = "cxx . . . detail/target().";
        let index = json!({"documents": [{
            "relative_path": "demo.cpp",
            "occurrences": [
                canonical_occurrence([0, 5, 11], symbol, 1),
                canonical_occurrence([1, 24, 30], symbol, 8)
            ]
        }]});
        let mut target = method("target", &path, "target", [1, 1, 1, 17]);
        target.language = "cpp".into();
        let mut caller = method("caller", &path, "caller", [2, 1, 2, 58]);
        caller.language = "cpp".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![target, caller];
        output.calls.push(call(
            "caller",
            &path,
            "detail::target<Wrapper::Data>",
            [2, 17, 2, 48],
        ));

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target.as_deref(), Some("target"));
        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(symbol));
    }

    #[test]
    fn multiple_scip_symbols_are_preserved_as_project_candidates() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("demo.cpp");
        fs::write(
            &path,
            "void pick(int) {}\nvoid pick(long) {}\nvoid caller() { pick(1); }\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let first = "cxx . . . pick(first).";
        let second = "cxx . . . pick(second).";
        let index = json!({"documents": [{
            "relative_path": "demo.cpp",
            "occurrences": [
                canonical_occurrence([0, 5, 9], first, 1),
                canonical_occurrence([1, 5, 9], second, 1),
                canonical_occurrence([2, 16, 20], first, 8),
                canonical_occurrence([2, 16, 20], second, 8)
            ]
        }]});
        let mut first_method = method("pick-int", &path, "pick", [1, 1, 1, 19]);
        first_method.language = "cpp".into();
        let mut second_method = method("pick-long", &path, "pick", [2, 1, 2, 20]);
        second_method.language = "cpp".into();
        let mut caller = method("caller", &path, "caller", [3, 1, 3, 28]);
        caller.language = "cpp".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![first_method, second_method, caller];
        output
            .calls
            .push(call("caller", &path, "pick", [3, 16, 3, 23]));

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target, None);
        assert_eq!(output.calls[0].kind, "unresolved_call");
        assert_eq!(
            output.calls[0].candidate_targets,
            ["pick-int", "pick-long"],
            "call={:?}",
            output.calls[0]
        );
        assert_eq!(
            output.calls[0].candidate_reason.as_deref(),
            Some("scip_project_candidate_set")
        );
        assert_ne!(
            output.calls[0].external_symbol_scope.as_deref(),
            Some("dependency")
        );
    }

    #[test]
    fn duplicate_project_definitions_are_candidates_not_dependencies() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("demo.cpp");
        fs::write(
            &path,
            "void reset() {}\nvoid reset() {}\nvoid caller() { reset(); }\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let symbol = "cxx . . . reset().";
        let index = json!({"documents": [{
            "relative_path": "demo.cpp",
            "occurrences": [
                canonical_occurrence([0, 5, 10], symbol, 1),
                canonical_occurrence([1, 5, 10], symbol, 1),
                canonical_occurrence([2, 16, 21], symbol, 8)
            ]
        }]});
        let mut first = method("reset-a", &path, "reset", [1, 1, 1, 17]);
        first.language = "cpp".into();
        let mut second = method("reset-b", &path, "reset", [2, 1, 2, 17]);
        second.language = "cpp".into();
        let mut caller = method("caller", &path, "caller", [3, 1, 3, 27]);
        caller.language = "cpp".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![first, second, caller];
        output
            .calls
            .push(call("caller", &path, "reset", [3, 16, 3, 23]));

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target, None);
        assert_eq!(output.calls[0].candidate_targets, ["reset-a", "reset-b"]);
        assert_eq!(
            output.calls[0].candidate_reason.as_deref(),
            Some("scip_project_candidate_set")
        );
        assert_eq!(
            output.calls[0].external_symbol_scope.as_deref(),
            Some("project")
        );
    }

    #[test]
    fn converges_scip_proven_std_overloads_without_discarding_identities() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("demo.cpp");
        fs::write(&path, "void caller() { std::move(value); }\n").unwrap();
        let path = path.to_string_lossy().to_string();
        let first = "cxx . . $ std/move(7316eb2979bdd03c).";
        let second = "cxx . . $ std/move(e35c19a1ba7baa26).";
        let index = json!({"documents": [{
            "relative_path": "demo.cpp",
            "occurrences": [
                canonical_occurrence([0, 21, 25], first, 8),
                canonical_occurrence([0, 21, 25], second, 8)
            ]
        }]});
        let mut caller = method("caller", &path, "caller", [1, 1, 1, 36]);
        caller.language = "cpp".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![caller];
        output
            .calls
            .push(call("caller", &path, "std::move<T>", [1, 17, 1, 32]));

        let stats = apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(stats.matched_occurrences, 1);
        assert_eq!(stats.modeled_external_symbols, 1);
        assert_eq!(
            output.calls[0].known_time_complexity.as_deref(),
            Some("O(1)")
        );
        assert_eq!(
            output.calls[0].known_space_complexity.as_deref(),
            Some("O(1)")
        );
        assert_eq!(
            output.calls[0].complexity_candidates,
            [first.to_string(), second.to_string()]
        );
    }

    #[test]
    fn exact_overload_target_removes_syntax_only_recursion_false_positive() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "class Demo {\n void get(int x){ get(x, false); }\n void get(int x, boolean b){}\n}\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let one_arg_symbol = "scip-java maven p Demo#get().";
        let two_arg_symbol = "scip-java maven p Demo#get(+1).";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [
                occurrence([1, 18, 21], two_arg_symbol, 0),
                occurrence([1, 6, 9], one_arg_symbol, 1),
                occurrence([2, 6, 9], two_arg_symbol, 1)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![
            method("get-one", &path, "get", [2, 1, 2, 35]),
            method("get-two", &path, "get", [3, 1, 3, 31]),
        ];
        let mut overload_call = call("get-one", &path, "get", [2, 18, 2, 31]);
        overload_call.function = "get".into();
        overload_call.receiver = "self".into();
        overload_call.receiver_binding_kind = "implicit".into();
        overload_call.implicit_receiver = true;
        output.calls.push(overload_call);
        output.complexity_facts.push(
            serde_json::from_value(json!({
                "path": path,
                "owner": "Demo",
                "function": "get",
                "line": 2,
                "span": [2, 1, 2, 35],
                "parameters": ["x"],
                "collection_parameters": [],
                "iterations": [],
                "recursion": {
                    "calls": 1,
                    "shrinking_calls": 0,
                    "halving_calls": 0,
                    "visited_guarded_calls": 0,
                    "loop_contained_shrinking_calls": 0,
                    "unknown_progress_calls": 1
                },
                "allocations": [],
                "call_contexts": []
            }))
            .unwrap(),
        );

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target.as_deref(), Some("get-two"));
        assert_eq!(output.complexity_facts[0].recursion, Default::default());
    }

    #[test]
    fn exact_self_target_preserves_genuine_recursion() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "class Demo {\n void walk(int x){ walk(x - 1); }\n}\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let symbol = "scip-java maven p Demo#walk().";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [
                occurrence([1, 19, 23], symbol, 0),
                occurrence([1, 6, 10], symbol, 1)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("walk", &path, "walk", [2, 1, 2, 37])];
        let mut recursive_call = call("walk", &path, "walk", [2, 19, 2, 30]);
        recursive_call.function = "walk".into();
        recursive_call.receiver = "self".into();
        recursive_call.receiver_binding_kind = "implicit".into();
        recursive_call.implicit_receiver = true;
        output.calls.push(recursive_call);
        output.complexity_facts.push(
            serde_json::from_value(json!({
                "path": path,
                "owner": "Demo",
                "function": "walk",
                "line": 2,
                "span": [2, 1, 2, 37],
                "parameters": ["x"],
                "collection_parameters": [],
                "iterations": [],
                "recursion": {
                    "calls": 1,
                    "shrinking_calls": 1,
                    "halving_calls": 0,
                    "visited_guarded_calls": 0,
                    "loop_contained_shrinking_calls": 0,
                    "unknown_progress_calls": 0
                },
                "allocations": [],
                "call_contexts": []
            }))
            .unwrap(),
        );

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target.as_deref(), Some("walk"));
        assert_eq!(output.complexity_facts[0].recursion.calls, 1);
        assert_eq!(output.complexity_facts[0].recursion.shrinking_calls, 1);
    }

    #[test]
    fn imports_exact_and_modeled_world_jdk_costs_with_distinct_quality() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "class Demo { void caller(){ text.length(); list.size(); } }",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let string_symbol = "scip-java maven jdk 21 java/lang/String#length().";
        let list_symbol = "scip-java maven jdk 21 java/util/List#size().";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [
                occurrence([0, 33, 39], string_symbol, 0),
                occurrence([0, 48, 52], list_symbol, 0)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("caller", &path, "caller", [1, 13, 1, 59])];
        output.calls = vec![
            call("caller", &path, "length", [1, 28, 1, 41]),
            call("caller", &path, "size", [1, 43, 1, 54]),
        ];

        let stats = apply_json(&mut output, &index.to_string()).unwrap();
        assert_eq!(stats.external_symbols, 2);
        assert_eq!(stats.modeled_external_symbols, 2);
        assert_eq!(
            output.calls[0].known_time_complexity.as_deref(),
            Some("O(1)")
        );
        assert_eq!(
            output.calls[1].known_time_complexity.as_deref(),
            Some("O(1)")
        );
        assert_eq!(
            output.calls[1].complexity_bound_quality.as_deref(),
            Some("upper_bound_modeled_world")
        );
        assert!(output.calls[1]
            .complexity_candidates
            .iter()
            .any(|candidate| candidate == "LinkedList"));
    }

    #[test]
    fn imports_qualified_static_call_nested_in_constructor_argument() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Util.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "class Util {\n  void check(String format, Object args) {\n    throw new IllegalArgumentException(String.format(format, args));\n  }\n}\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let format_symbol = "scip-java maven jdk 21 java/lang/String#format().";
        let index = json!({"documents": [{
            "relative_path": "src/Util.java",
            "occurrences": [
                occurrence([2, 46, 52], format_symbol, 0),
                occurrence([2, 53, 59], "local 1", 0)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("check", &path, "check", [2, 2, 4, 3])];
        output
            .calls
            .push(call("check", &path, "format", [3, 39, 3, 66]));

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(
            output.calls[0].semantic_symbol.as_deref(),
            Some(format_symbol)
        );
    }

    #[test]
    fn imports_callback_cost_as_a_parametric_contract() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "class Demo {\n  Object run(java.util.function.Function f, Object x) {\n    return f.apply(x);\n  }\n}\n",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let symbol = "scip-java maven jdk 21 java/util/function/Function#apply().";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [occurrence([2, 13, 18], symbol, 0)]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("run", &path, "run", [2, 2, 4, 3])];
        output.calls = vec![call("run", &path, "apply", [3, 11, 3, 21])];

        let stats = apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(stats.modeled_external_symbols, 1);
        assert_eq!(
            output.calls[0].known_time_complexity.as_deref(),
            Some("O(C)")
        );
        assert_eq!(
            output.calls[0].known_space_complexity.as_deref(),
            Some("O(S)")
        );
        assert_eq!(
            output.calls[0].complexity_bound_quality.as_deref(),
            Some("upper_bound_parametric_callback_once")
        );
        assert_eq!(
            output.calls[0].external_symbol_scope.as_deref(),
            Some("stdlib")
        );
        assert_eq!(output.calls[0].complexity_missing_kind, None);
    }

    #[test]
    fn compiler_proven_java_costs_distinguish_exact_and_modeled_world_bounds() {
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/lang/System#arraycopy().",
                "arraycopy"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(N)", "O(1)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/nio/Buffer#clear().",
                "clear"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(1)", "O(1)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/util/Optional#get().",
                "get"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(1)", "O(1)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/lang/String#startsWith().",
                "startsWith"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(N)", "O(1)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/util/List#get().",
                "get"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(N)", "O(1)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/util/Set#add().",
                "add"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(N)", "O(N)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/lang/Enum#name().",
                "name"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(1)", "O(1)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/lang/String#toLowerCase().",
                "toLowerCase"
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(N)", "O(N)"))
        );
        let object_equals = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/util/Objects#equals().",
            "equals",
        )
        .unwrap();
        assert_eq!((object_equals.time, object_equals.space), ("O(N)", "O(1)"));
        assert_eq!(object_equals.bound_quality, "upper_bound_modeled_world");
        assert!(object_equals.assumption.is_some());
        let list = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/util/List#get().",
            "get",
        )
        .unwrap();
        assert_eq!(list.bound_quality, "upper_bound_modeled_world");
        assert!(list
            .candidates
            .iter()
            .any(|candidate| candidate == "LinkedList"));
        assert!(list.assumption.is_some());
        let file = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/io/File#toPath().",
            "toPath",
        )
        .unwrap();
        assert_eq!(file.bound_quality, "upper_bound_external_latency_excluded");
        assert!(file
            .assumption
            .is_some_and(|assumption| assumption.contains("latency is excluded")));
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/lang/String#valueOf(+4).",
                "valueOf",
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(1)", "O(1)"))
        );
        let object_value_of = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/lang/String#valueOf().",
            "valueOf",
        )
        .unwrap();
        assert_eq!(
            (object_value_of.time, object_value_of.space),
            ("O(N)", "O(N)")
        );
        assert_eq!(object_value_of.bound_quality, "upper_bound_modeled_world");
        let format = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/lang/String#format().",
            "format",
        )
        .unwrap();
        assert_eq!((format.time, format.space), ("O(N)", "O(N)"));
        assert_eq!(format.bound_quality, "upper_bound_modeled_world");
        assert!(format.assumption.is_some());
        assert!(!format.candidates.is_empty());
        let stream_filter = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/util/stream/Stream#filter().",
            "filter",
        )
        .unwrap();
        assert_eq!((stream_filter.time, stream_filter.space), ("O(1)", "O(1)"));
        assert_eq!(stream_filter.bound_quality, "upper_bound_exact_target");
        let stream_count = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/util/stream/Stream#count().",
            "count",
        )
        .unwrap();
        assert_eq!((stream_count.time, stream_count.space), ("O(N)", "O(1)"));
        assert_eq!(stream_count.bound_quality, "upper_bound_modeled_world");
        assert!(stream_count.assumption.is_some());
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/util/Objects#hash().",
                "hash",
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(N)", "O(N)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/util/regex/Matcher#matches().",
                "matches",
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(2^N)", "O(N)"))
        );
        assert_eq!(
            syntax::external_symbol_call_complexity(
                "java",
                "scip-java maven jdk 21 java/awt/Color#getHSBColor().",
                "getHSBColor",
            )
            .map(|complexity| (complexity.time, complexity.space)),
            Some(("O(1)", "O(1)"))
        );
        let read_object = syntax::external_symbol_call_complexity(
            "java",
            "scip-java maven jdk 21 java/io/ObjectInputStream#readObject().",
            "readObject",
        )
        .unwrap();
        assert_eq!((read_object.time, read_object.space), ("O(N)", "O(N)"));
        assert_eq!(
            read_object.bound_quality,
            "upper_bound_external_latency_excluded"
        );
        assert_eq!(
            syntax::external_symbol_metadata(
                "java",
                "scip-java maven jdk 21 java/util/function/Function#apply().",
            ),
            syntax::ExternalSymbolMetadata {
                scope: "stdlib",
                missing_cost_kind: "callback_cost_missing".to_string(),
                parametric_cost: Some("callback_once".to_string()),
            }
        );
        assert_eq!(
            syntax::external_symbol_metadata(
                "java",
                "scip-java maven maven/acme/tool 1 acme/Tool#run().",
            )
            .scope,
            "dependency"
        );
    }

    #[test]
    fn ignores_same_name_non_callable_occurrence() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "class Demo { void caller(){ value; } }").unwrap();
        let path = path.to_string_lossy().to_string();
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [occurrence([0, 28, 33], "scip-java maven p Demo#value.", 0)]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("caller", &path, "caller", [1, 13, 1, 38])];
        output.calls = vec![call("caller", &path, "value", [1, 28, 1, 33])];

        let stats = apply_json(&mut output, &index.to_string()).unwrap();
        assert_eq!(stats.unmatched_calls, 1);
        assert_eq!(output.calls[0].semantic_symbol, None);
    }

    #[test]
    fn accepts_repeated_occurrences_when_semantic_identity_is_identical() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "class Demo { void caller(){ value.append(\"a\").append(\"b\"); } }",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let symbol = "scip-java maven jdk 21 java/lang/StringBuilder#append(+1).";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [
                occurrence([0, 34, 40], symbol, 0),
                occurrence([0, 46, 52], symbol, 0)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("caller", &path, "caller", [1, 13, 1, 65])];
        output
            .calls
            .push(call("caller", &path, "append", [1, 29, 1, 58]));

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(symbol));
    }

    #[test]
    fn receiver_call_span_selects_outer_fluent_overload() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(
            &path,
            "class Demo { void caller(){ value.append(1).append(\"b\"); } }",
        )
        .unwrap();
        let path = path.to_string_lossy().to_string();
        let inner = "scip-java maven jdk 21 java/lang/StringBuilder#append().";
        let outer = "scip-java maven jdk 21 java/lang/StringBuilder#append(+1).";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [
                occurrence([0, 34, 40], inner, 0),
                occurrence([0, 44, 50], outer, 0)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("caller", &path, "caller", [1, 13, 1, 62])];
        let mut outer_call = call("caller", &path, "append", [1, 28, 1, 55]);
        outer_call.receiver_call_span = Some([1, 28, 1, 43]);
        output.calls.push(outer_call);

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(outer));
    }

    #[test]
    fn java_source_order_selects_outer_same_spelled_call() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.java");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(&path, "class Demo { void caller(){ pick(pick()); } }").unwrap();
        let path = path.to_string_lossy().to_string();
        let index = json!({"documents": [{
            "relative_path": "src/Demo.java",
            "occurrences": [
                occurrence([0, 28, 32], "scip-java maven p Demo#pick().", 0),
                occurrence([0, 33, 37], "scip-java maven p Demo#pick(+1).", 0)
            ]
        }]});
        let mut output = ProfileOutput::default();
        output.methods = vec![method("caller", &path, "caller", [1, 13, 1, 45])];
        output.calls = vec![call("caller", &path, "pick", [1, 28, 1, 39])];

        let stats = apply_json(&mut output, &index.to_string()).unwrap();
        assert_eq!(stats.matched_occurrences, 1);
        assert_eq!(
            output.calls[0].semantic_symbol.as_deref(),
            Some("scip-java maven p Demo#pick().")
        );
    }

    #[test]
    fn selector_syntax_selects_outer_call_without_receiver_projection() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/demo.ts");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let source = "function caller() { resolve(param.transform).transform(); }\nfunction transform() {}\n";
        fs::write(&path, source).unwrap();
        let path = path.to_string_lossy().to_string();
        let property = "scip-typescript npm demo 1 src/types.ts/Param#transform.";
        let callable = "scip-typescript npm demo 1 src/demo.ts/Transform#transform.";
        let property_column = source.find("transform").unwrap();
        let callable_column =
            source[property_column + 1..].find("transform").unwrap() + property_column + 1;
        let definition_column = source.lines().nth(1).unwrap().find("transform").unwrap();
        let index = json!({"documents": [{
            "relative_path": "src/demo.ts",
            "occurrences": [
                canonical_occurrence([0, property_column, property_column + 9], property, 0),
                canonical_occurrence([0, callable_column, callable_column + 9], callable, 0),
                canonical_occurrence([1, definition_column, definition_column + 9], callable, 1)
            ]
        }]});
        let mut caller = method("caller", &path, "caller", [1, 0, 1, 60]);
        let mut target = method("target", &path, "transform", [2, 0, 2, 23]);
        caller.language = "typescript".into();
        target.language = "typescript".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![caller, target];
        output.calls = vec![call("caller", &path, "transform", [1, 20, 1, 56])];

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target.as_deref(), Some("target"));
        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(callable));
    }

    #[test]
    fn equivalent_external_declarations_converge_on_one_reviewed_cost() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/demo.ts");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let source = "function caller(value: string) { value.split(','); }\n";
        fs::write(&path, source).unwrap();
        let path = path.to_string_lossy().to_string();
        let column = source.find("split").unwrap();
        let es5 = "scip-typescript npm typescript 5.9.3 lib/`lib.es5.d.ts`/String#split().";
        let symbols = "scip-typescript npm typescript 5.9.3 lib/`lib.es2015.symbol.wellknown.d.ts`/String#split().";
        let index = json!({"documents": [{
            "relative_path": "src/demo.ts",
            "occurrences": [
                canonical_occurrence([0, column, column + 5], es5, 0),
                canonical_occurrence([0, column, column + 5], symbols, 0)
            ]
        }]});
        let mut caller = method("caller", &path, "caller", [1, 0, 1, source.len()]);
        caller.language = "typescript".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![caller];
        output.calls = vec![call("caller", &path, "split", [1, 33, 1, 49])];

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(
            output.calls[0].known_time_complexity.as_deref(),
            Some("O(N)")
        );
        assert_eq!(
            output.calls[0].known_space_complexity.as_deref(),
            Some("O(N)")
        );
        assert_eq!(output.calls[0].complexity_candidates.len(), 2);
    }

    #[test]
    fn csharp_property_symbol_maps_to_emitted_getter() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("src/Demo.cs");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let source = "class Demo { string Name { get; } void Caller() { Items.Last().Name; } }\n";
        fs::write(&path, source).unwrap();
        let path = path.to_string_lossy().to_string();
        let declaration_column = source.find("Name").unwrap();
        let call_column = source.rfind("Name").unwrap();
        let symbol = "scip-dotnet nuget . . Demo/Demo#Name.";
        let index = json!({"documents": [{
            "relative_path": "src/Demo.cs",
            "occurrences": [
                canonical_occurrence([0, declaration_column, declaration_column + 4], symbol, 1),
                canonical_occurrence([0, call_column, call_column + 4], symbol, 0)
            ]
        }]});
        let mut getter = method("getter", &path, "Name", [1, 13, 1, 33]);
        let mut caller = method("caller", &path, "Caller", [1, 34, 1, source.len()]);
        getter.language = "csharp".into();
        caller.language = "csharp".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![getter, caller];
        output.calls = vec![call("caller", &path, "Name", [1, 50, 1, call_column + 4])];

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target.as_deref(), Some("getter"));
        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(symbol));
    }

    #[test]
    fn rejects_non_utf8_scip_columns_instead_of_guessing() {
        let mut output = ProfileOutput::default();
        let index = json!({
            "metadata": {"text_document_encoding": 2},
            "documents": []
        });
        let error = apply_json(&mut output, &index.to_string()).unwrap_err();
        assert!(error.to_string().contains("non-UTF-8"));
    }

    #[test]
    fn accepts_protobuf_json_camel_case_fields_and_utf8_name() {
        let mut output = ProfileOutput::default();
        let index = json!({
            "metadata": {"textDocumentEncoding": "UTF-8"},
            "documents": [{
                "relativePath": "Demo.swift",
                "occurrences": [],
                "symbols": [{
                    "symbol": "swift Demo Child#",
                    "relationships": [{
                        "symbol": "swift Demo Parent#",
                        "isImplementation": true
                    }]
                }]
            }]
        });
        assert!(apply_json(&mut output, &index.to_string()).is_ok());
    }

    #[test]
    fn imports_the_available_swift_indexstore_json_shape() {
        let dir = tempdir().unwrap();
        let path = dir.path().join("Sources/Demo.swift");
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        let declaration = "func callee() {}";
        let caller = "func caller() { callee() }";
        fs::write(&path, format!("{declaration}\n{caller}\n")).unwrap();
        let path = path.to_string_lossy().to_string();
        let declaration_column = declaration.find("callee").unwrap();
        let call_column = caller.find("callee").unwrap();
        let symbol = "swift Demo callee().";
        let index = json!({
            "metadata": {"textDocumentEncoding": "UTF-8"},
            "documents": [{
                "relativePath": "Sources/Demo.swift",
                "language": "swift",
                "symbols": [{"symbol": symbol}],
                "occurrences": [
                    {"range": [0, declaration_column, declaration_column + 6], "symbol": symbol, "symbolRoles": 1},
                    {"range": [1, call_column, call_column + 6], "symbol": symbol, "symbolRoles": 8}
                ]
            }]
        });
        let mut callee = method("callee", &path, "callee", [1, 0, 1, declaration.len()]);
        let mut caller_method = method("caller", &path, "caller", [2, 0, 2, caller.len()]);
        callee.language = "swift".into();
        caller_method.language = "swift".into();
        let mut output = ProfileOutput::default();
        output.methods = vec![callee, caller_method];
        output.calls = vec![call(
            "caller",
            &path,
            "callee",
            [2, call_column, 2, call_column + 8],
        )];

        apply_json(&mut output, &index.to_string()).unwrap();

        assert_eq!(output.calls[0].target.as_deref(), Some("callee"));
        assert_eq!(output.calls[0].semantic_symbol.as_deref(), Some(symbol));
    }

    #[test]
    fn accepts_typed_ranges_with_omitted_zero_coordinates() {
        // Protobuf JSON omits scalar fields whose value is zero. SCIP 0.9
        // therefore emits first-line ranges without a `line` member and
        // ranges starting at column zero without `start_character`.
        let occurrence: Occurrence = serde_json::from_value(json!({
            "TypedRange": {"SingleLineRange": {"end_character": 4}},
            "symbol": "swift Demo main()."
        }))
        .unwrap();

        assert_eq!(occurrence.span(), Some([0, 0, 0, 4]));
    }
}
