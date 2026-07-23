//! Transactional direct-artifact ingestion, shared by CLI and future callers.

use crate::{
    ingest_coverage_json_with_options, ingest_mutant_facts_json_with_options, ingest_sarif_paths,
    parse_coverage_input, CoverageIngestOptions, CoverageIngestStats, EvidenceArtifactScope,
    EvidenceScopeFingerprint, GitProvider, HeuristicExtractor, MutantIngestOptions,
    MutantIngestStats, RepoPathNormalizer, SarifIngestStats, Storage,
};
use anyhow::{Context, Result};
use std::{fs, path::Path};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DirectArtifactKind {
    Coverage,
    Mutants,
    Sarif,
}

pub struct DirectArtifactIngest<'a> {
    pub kind: DirectArtifactKind,
    pub db: &'a Path,
    pub repo: &'a Path,
    pub input: &'a Path,
    pub format: &'a str,
    pub commit: &'a str,
    pub source: Option<String>,
    pub timestamp: Option<i64>,
    pub selection: Option<String>,
    pub mutant_corpus: Option<String>,
    pub test_set: Option<String>,
    pub complete: bool,
    pub replace: bool,
}

#[derive(Debug)]
pub enum DirectIngestResult {
    Coverage(CoverageIngestStats),
    Mutants(MutantIngestStats),
    Sarif(SarifIngestStats),
}

/// Parses the input before the caller indexes a selected revision. This keeps
/// malformed direct input from creating a database snapshot as a side effect.
pub fn validate_direct_artifact(
    kind: DirectArtifactKind,
    input: &Path,
    format: &str,
) -> Result<()> {
    match kind {
        DirectArtifactKind::Coverage => {
            let payload = fs::read_to_string(input)?;
            let _ = parse_coverage_input(&payload, format)?;
        }
        DirectArtifactKind::Mutants => {
            if format != "mutant-facts" {
                anyhow::bail!("mutants direct ingestion requires --format mutant-facts");
            }
            let payload = fs::read_to_string(input)?;
            let _ = crate::parse_mutant_facts(&payload)?;
        }
        DirectArtifactKind::Sarif => {
            if format != "sarif" {
                anyhow::bail!("SARIF direct ingestion requires --format sarif");
            }
            crate::pipeline::validate_sarif_document(&fs::read(input)?)?;
        }
    }
    Ok(())
}

/// Imports one direct artifact in one SQLite transaction. A complete artifact
/// that cannot be represented is rejected and leaves no partial evidence.
pub fn ingest_direct_artifact(request: DirectArtifactIngest<'_>) -> Result<DirectIngestResult> {
    let scope = direct_evidence_scope(
        request.kind,
        request.commit,
        request.selection,
        request.mutant_corpus.clone(),
        request.test_set,
        request.complete,
    )?;
    let storage = Storage::open(request.db)?;
    storage.begin_transaction()?;
    let result = (|| -> Result<DirectIngestResult> {
        let result = match request.kind {
            DirectArtifactKind::Coverage => {
                let payload = fs::read_to_string(request.input)?;
                let source = request.source.unwrap_or_else(|| "coverage".into());
                let stats = ingest_coverage_json_with_options(
                    &storage,
                    &payload,
                    request.format,
                    request.commit,
                    request.timestamp,
                    request.replace,
                    &CoverageIngestOptions {
                        line_source: source,
                        evidence_scope: scope,
                        complete: request.complete,
                    },
                )?;
                if request.complete && stats.skipped_files > 0 {
                    anyhow::bail!(
                        "complete coverage import skipped {} file(s)",
                        stats.skipped_files
                    );
                }
                DirectIngestResult::Coverage(stats)
            }
            DirectArtifactKind::Mutants => {
                if request.format != "mutant-facts" {
                    anyhow::bail!("mutants direct ingestion requires --format mutant-facts");
                }
                let payload = fs::read_to_string(request.input)?;
                let git = GitProvider::open(request.repo)?;
                let normalizer = RepoPathNormalizer::new(request.repo);
                let test_set = scope
                    .as_ref()
                    .map(|scope| scope.test_set.clone())
                    .unwrap_or_else(|| "unit".into());
                let stats = ingest_mutant_facts_json_with_options(
                    &storage,
                    &normalizer,
                    &git,
                    &HeuristicExtractor::default(),
                    &payload,
                    request.commit,
                    request.timestamp,
                    &test_set,
                    &MutantIngestOptions {
                        mutation_corpus: request.mutant_corpus.unwrap_or_default(),
                        evidence_scope: scope,
                        complete: request.complete,
                    },
                )?;
                if request.complete && (stats.skipped_files > 0 || stats.skipped_facts > 0) {
                    anyhow::bail!(
                        "complete mutation import skipped {} file(s) and {} fact(s)",
                        stats.skipped_files,
                        stats.skipped_facts
                    );
                }
                DirectIngestResult::Mutants(stats)
            }
            DirectArtifactKind::Sarif => {
                if request.format != "sarif" {
                    anyhow::bail!("SARIF direct ingestion requires --format sarif");
                }
                let payload = fs::read(request.input)?;
                crate::pipeline::validate_sarif_document(&payload)?;
                let source = request.source.unwrap_or_else(|| "sarif".into());
                let stats = ingest_sarif_paths(
                    &storage,
                    request.repo,
                    &[request.input.to_path_buf()],
                    &source,
                    request.commit,
                    request.timestamp,
                    request.replace,
                )?;
                if request.complete && (stats.skipped_files > 0 || stats.skipped_results > 0) {
                    anyhow::bail!(
                        "complete SARIF import skipped {} file(s) and {} result(s)",
                        stats.skipped_files,
                        stats.skipped_results
                    );
                }
                if let Some(scope) = scope {
                    storage.record_evidence_artifact_scope(&EvidenceArtifactScope {
                        family: "sarif".into(),
                        source,
                        scope,
                        complete: request.complete,
                        expected_lines: Default::default(),
                    })?;
                }
                DirectIngestResult::Sarif(stats)
            }
        };
        Ok(result)
    })();
    match result {
        Ok(result) => {
            storage.commit_transaction()?;
            Ok(result)
        }
        Err(error) => {
            let _ = storage.rollback_transaction();
            Err(error)
        }
    }
}

fn direct_evidence_scope(
    kind: DirectArtifactKind,
    commit: &str,
    selection: Option<String>,
    mutant_corpus: Option<String>,
    test_set: Option<String>,
    complete: bool,
) -> Result<Option<EvidenceScopeFingerprint>> {
    match (selection, test_set) {
        (None, None) => {
            if complete {
                anyhow::bail!("--complete requires --selection and --test-set");
            }
            if mutant_corpus.is_some() {
                anyhow::bail!("--mutant-corpus requires --selection and --test-set");
            }
            Ok(None)
        }
        (Some(selection), Some(test_set)) => {
            let mutant_corpus = match kind {
                DirectArtifactKind::Mutants => mutant_corpus
                    .filter(|value| !value.trim().is_empty())
                    .context("mutation evidence with a scope requires --mutant-corpus")?,
                DirectArtifactKind::Coverage | DirectArtifactKind::Sarif => {
                    mutant_corpus.unwrap_or_else(|| "not-applicable".into())
                }
            };
            Ok(Some(EvidenceScopeFingerprint {
                revision: commit.into(),
                selection,
                mutant_corpus,
                test_set,
            }))
        }
        _ => anyhow::bail!("--selection and --test-set must be supplied together"),
    }
}
