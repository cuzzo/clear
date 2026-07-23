//! Manifest validation and run-atomic evidence ingestion.

pub use crate::ingest_service::{
    ingest_direct_artifact, validate_direct_artifact, DirectArtifactIngest, DirectArtifactKind,
    DirectIngestResult,
};

use crate::{
    ingest_coverage_json_with_options, ingest_mutant_facts_json_with_options, ingest_sarif_paths,
    load_run_manifest, read_manifest_artifact, repository_identity, validate_run_artifacts,
    ArtifactKind, CoverageIngestOptions, EvidenceArtifactScope, EvidenceScopeFingerprint,
    GitProvider, HeuristicExtractor, LanguageNormalizer, MutantIngestOptions, RepoPathNormalizer,
    RunStatus, Storage,
};
use anyhow::{Context, Result};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RunIngestResult {
    pub revision: String,
    pub artifact_count: usize,
}

pub fn ingest_run_manifest(
    db: &std::path::Path,
    repo: &std::path::Path,
    manifest_path: &std::path::Path,
) -> Result<RunIngestResult> {
    let manifest = validate_run_manifest_for_ingestion(repo, manifest_path)?;
    ingest_validated_run_manifest(db, repo, manifest_path, manifest)
}

pub fn validate_run_manifest_for_ingestion(
    repo: &std::path::Path,
    manifest_path: &std::path::Path,
) -> Result<crate::pipeline::RunManifest> {
    let manifest = load_run_manifest(manifest_path)?;
    let git = GitProvider::open(repo)?;
    validate_manifest_provenance(repo, &git, &manifest)?;
    validate_manifest_artifact_batches(&manifest)?;
    let run_directory = manifest_path
        .parent()
        .context("run manifest has no parent directory")?;
    // Validate the complete content-addressed run before opening a database
    // transaction. In particular, a SARIF document that the importer would
    // ignore must never be recorded as complete evidence.
    validate_run_artifacts(run_directory, &manifest)?;
    for artifact in &manifest.artifacts {
        let _ = artifact_evidence_scope(artifact, &manifest.revision)?;
    }
    Ok(manifest)
}

fn ingest_validated_run_manifest(
    db: &std::path::Path,
    repo: &std::path::Path,
    manifest_path: &std::path::Path,
    manifest: crate::pipeline::RunManifest,
) -> Result<RunIngestResult> {
    let git = GitProvider::open(repo)?;
    let run_directory = manifest_path
        .parent()
        .context("run manifest has no parent directory")?;
    let storage = Storage::open(db)?;
    let extractor = HeuristicExtractor::default();
    let normalizer = RepoPathNormalizer::new(repo);
    let sarif_directory = std::env::temp_dir().join(format!(
        "gigasail-sarif-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .context("system time precedes Unix epoch")?
            .as_nanos()
    ));
    fs::create_dir_all(&sarif_directory)?;
    let mut sarif_inputs = BTreeMap::<String, Vec<PathBuf>>::new();
    let mut sarif_scopes = BTreeMap::<String, Vec<(EvidenceScopeFingerprint, bool)>>::new();
    storage.begin_transaction()?;
    let result = (|| -> Result<()> {
        for (index, artifact) in manifest.artifacts.iter().enumerate() {
            let payload = read_manifest_artifact(run_directory, artifact)?;
            let evidence_scope = artifact_evidence_scope(artifact, &manifest.revision)?;
            match artifact.kind {
                ArtifactKind::Auxiliary => {
                    // Auxiliary artifacts are immutable run provenance and
                    // producer hand-off inputs, not database evidence.
                }
                ArtifactKind::Coverage => {
                    let payload =
                        normalize_manifest_coverage_paths(&payload, &artifact.format, &normalizer)?;
                    let stats = ingest_coverage_json_with_options(
                        &storage,
                        std::str::from_utf8(&payload)?,
                        &artifact.format,
                        &manifest.revision,
                        None,
                        true,
                        &CoverageIngestOptions {
                            line_source: artifact.producer.clone(),
                            evidence_scope: evidence_scope.clone(),
                            complete: artifact.complete,
                        },
                    )?;
                    if artifact.complete && stats.skipped_files > 0 {
                        anyhow::bail!(
                            "complete coverage artifact from producer {:?} skipped {} file(s)",
                            artifact.producer,
                            stats.skipped_files
                        );
                    }
                }
                ArtifactKind::Mutants => {
                    let stats = ingest_mutant_facts_json_with_options(
                        &storage,
                        &normalizer,
                        &git,
                        &extractor,
                        std::str::from_utf8(&payload)?,
                        &manifest.revision,
                        None,
                        evidence_scope
                            .clone()
                            .as_ref()
                            .map(|scope| scope.test_set.as_str())
                            .unwrap_or("unit"),
                        &MutantIngestOptions {
                            mutation_corpus: evidence_scope
                                .as_ref()
                                .map(|scope| scope.mutant_corpus.clone())
                                .unwrap_or_default(),
                            evidence_scope,
                            complete: artifact.complete,
                        },
                    )?;
                    if artifact.complete && (stats.skipped_files > 0 || stats.skipped_facts > 0) {
                        anyhow::bail!(
                            "complete mutation artifact from producer {:?} skipped {} file(s) and {} fact(s)",
                            artifact.producer,
                            stats.skipped_files,
                            stats.skipped_facts
                        );
                    }
                }
                ArtifactKind::Sarif => {
                    // Keep temporary names independent of external manifest
                    // text. The producer identifier is a provenance key, not a
                    // filesystem path component.
                    let unpacked = sarif_directory.join(format!("sarif-{index}.json"));
                    fs::create_dir_all(
                        unpacked.parent().expect("unpacked artifact parent exists"),
                    )?;
                    fs::write(&unpacked, payload)?;
                    sarif_inputs
                        .entry(artifact.producer.clone())
                        .or_default()
                        .push(unpacked);
                    if let Some(scope) = evidence_scope {
                        sarif_scopes
                            .entry(artifact.producer.clone())
                            .or_default()
                            .push((scope, artifact.complete));
                    }
                }
            }
        }
        for (source, inputs) in sarif_inputs {
            let stats = ingest_sarif_paths(
                &storage,
                repo,
                &inputs,
                &source,
                &manifest.revision,
                None,
                true,
            )?;
            let requested_complete = sarif_scopes
                .get(&source)
                .and_then(|scopes| scopes.first())
                .is_some_and(|(_, complete)| *complete);
            if requested_complete && (stats.skipped_files > 0 || stats.skipped_results > 0) {
                anyhow::bail!(
                    "complete SARIF artifact source {source:?} skipped {} file(s) and {} result(s)",
                    stats.skipped_files,
                    stats.skipped_results
                );
            }
            if let Some((scope, complete)) = sarif_scopes
                .remove(&source)
                .unwrap_or_default()
                .into_iter()
                .next()
            {
                storage.record_evidence_artifact_scope(&EvidenceArtifactScope {
                    family: "sarif".into(),
                    source: source.clone(),
                    scope,
                    complete,
                    expected_lines: Default::default(),
                })?;
            }
        }
        storage.record_ci_run(
            &run_key(manifest_path)?,
            &manifest,
            "ingested",
            unix_time_ms()?,
        )?;
        Ok(())
    })();
    let cleanup_result = fs::remove_dir_all(&sarif_directory);
    match result {
        Ok(()) => storage.commit_transaction()?,
        Err(error) => {
            let _ = storage.rollback_transaction();
            return Err(error);
        }
    }
    cleanup_result.with_context(|| {
        format!(
            "remove temporary SARIF directory {}",
            sarif_directory.display()
        )
    })?;
    Ok(RunIngestResult {
        revision: manifest.revision,
        artifact_count: manifest.artifacts.len(),
    })
}

/// SimpleCov records absolute filenames. Convert those filenames at the
/// manifest boundary, where the selected project root is known, before the
/// generic coverage parser applies its intentionally repository-agnostic
/// normalization. This keeps nested projects (`--repo gems/test-miser`) from
/// being recorded under their enclosing monorepo prefix.
pub fn normalize_manifest_coverage_paths(
    payload: &[u8],
    format: &str,
    normalizer: &dyn LanguageNormalizer,
) -> Result<Vec<u8>> {
    if format != "simplecov" {
        return Ok(payload.to_vec());
    }
    let mut document: serde_json::Value = serde_json::from_slice(payload)
        .context("parse SimpleCov artifact while normalizing project-relative paths")?;
    let Some(resultsets) = document.as_object_mut() else {
        anyhow::bail!("SimpleCov artifact must be a JSON object");
    };
    for resultset in resultsets.values_mut() {
        let Some(coverage) = resultset
            .get_mut("coverage")
            .and_then(serde_json::Value::as_object_mut)
        else {
            continue;
        };
        let mut normalized = serde_json::Map::new();
        for (path, value) in std::mem::take(coverage) {
            let path = normalizer.normalize_path(&path);
            if normalized.insert(path.clone(), value).is_some() {
                anyhow::bail!(
                    "SimpleCov artifact contains multiple paths that normalize to {path:?}"
                );
            }
        }
        *coverage = normalized;
    }
    serde_json::to_vec(&document).context("serialize normalized SimpleCov artifact")
}

fn validate_manifest_provenance(
    repo: &std::path::Path,
    git: &GitProvider,
    manifest: &crate::pipeline::RunManifest,
) -> Result<()> {
    if manifest.status != RunStatus::Succeeded {
        anyhow::bail!("only successful run manifests can be ingested");
    }
    if manifest.repository_identity.is_empty()
        || manifest.repository_identity != repository_identity(repo)
    {
        anyhow::bail!("run manifest was produced for a different repository");
    }
    let resolved = git.resolve_commit(&manifest.revision)?;
    if resolved != manifest.revision {
        anyhow::bail!("run manifest revision must be an immutable resolved commit hash");
    }
    if manifest.tree_fingerprint.is_empty() || manifest.tree_fingerprint != resolved {
        anyhow::bail!("run manifest tree fingerprint does not match its revision");
    }
    let mut declared = std::collections::BTreeSet::new();
    for producer in &manifest.producers {
        if !crate::pipeline::is_safe_identifier(&producer.name) {
            anyhow::bail!(
                "run manifest contains unsafe producer identifier {:?}",
                producer.name
            );
        }
        if !declared.insert(producer.name.as_str()) {
            anyhow::bail!(
                "run manifest declares producer {:?} more than once",
                producer.name
            );
        }
        if producer.outcome != crate::pipeline::ProducerOutcome::Succeeded {
            anyhow::bail!(
                "artifact manifest references non-successful producer {:?} ({:?})",
                producer.name,
                producer.outcome
            );
        }
    }
    for artifact in &manifest.artifacts {
        if !crate::pipeline::is_safe_identifier(&artifact.producer) {
            anyhow::bail!(
                "run manifest contains unsafe artifact producer {:?}",
                artifact.producer
            );
        }
        if !declared.contains(artifact.producer.as_str()) {
            anyhow::bail!(
                "artifact producer {:?} is not declared by a successful producer run",
                artifact.producer
            );
        }
        if artifact.format.trim().is_empty() {
            anyhow::bail!(
                "artifact from producer {:?} has an empty format",
                artifact.producer
            );
        }
        let format_matches_family = match artifact.kind {
            ArtifactKind::Auxiliary => true,
            ArtifactKind::Coverage => matches!(
                artifact.format.as_str(),
                "boobytrap"
                    | "codecov"
                    | "cobertura"
                    | "generic"
                    | "simplecov"
                    | "sqlcov"
                    | "sql-cov"
            ),
            ArtifactKind::Mutants => artifact.format == "mutant-facts",
            ArtifactKind::Sarif => artifact.format == "sarif",
        };
        if !format_matches_family {
            anyhow::bail!(
                "artifact from producer {:?} declares incompatible {:?} format {:?}",
                artifact.producer,
                artifact.kind,
                artifact.format
            );
        }
    }
    Ok(())
}

fn validate_manifest_artifact_batches(manifest: &crate::pipeline::RunManifest) -> Result<()> {
    let mut batches =
        BTreeMap::<(String, ArtifactKind), Vec<&crate::pipeline::ManifestArtifact>>::new();
    for artifact in &manifest.artifacts {
        batches
            .entry((artifact.producer.clone(), artifact.kind))
            .or_default()
            .push(artifact);
    }
    for ((producer, kind), artifacts) in batches {
        let first = artifacts[0];
        if artifacts.iter().any(|artifact| {
            artifact.complete != first.complete || artifact.evidence_scope != first.evidence_scope
        }) {
            anyhow::bail!(
                "producer {producer:?} has incompatible scope or completeness declarations for {kind:?} artifacts"
            );
        }
        if matches!(kind, ArtifactKind::Coverage | ArtifactKind::Mutants) && artifacts.len() != 1 {
            anyhow::bail!(
                "producer {producer:?} emits {} {kind:?} artifacts; shard merging is not yet supported, configure one merged artifact",
                artifacts.len()
            );
        }
    }
    Ok(())
}

fn artifact_evidence_scope(
    artifact: &crate::pipeline::ManifestArtifact,
    revision: &str,
) -> Result<Option<EvidenceScopeFingerprint>> {
    let scope = artifact.evidence_scope.as_ref();
    if artifact.complete && scope.is_none() {
        anyhow::bail!(
            "complete artifact from producer {:?} lacks evidence_scope",
            artifact.producer
        );
    }
    if let Some(scope) = scope {
        if scope.selection.trim().is_empty()
            || scope.test_set.trim().is_empty()
            || (artifact.kind == ArtifactKind::Mutants
                && (scope.mutant_corpus.trim().is_empty()
                    || scope.mutant_corpus == "not-applicable"))
        {
            anyhow::bail!(
                "artifact from producer {:?} has an invalid evidence_scope",
                artifact.producer
            );
        }
    }
    Ok(scope.map(|scope| EvidenceScopeFingerprint {
        revision: revision.into(),
        selection: scope.selection.clone(),
        mutant_corpus: scope.mutant_corpus.clone(),
        test_set: scope.test_set.clone(),
    }))
}

fn run_key(manifest_path: &Path) -> Result<String> {
    let directory = manifest_path
        .parent()
        .context("run manifest has no parent directory")?;
    let name = directory
        .file_name()
        .and_then(|name| name.to_str())
        .context("run directory name is not UTF-8")?;
    Ok(["pending-", "analysis-", "published-", "failed-"]
        .into_iter()
        .find_map(|prefix| name.strip_prefix(prefix))
        .unwrap_or(name)
        .to_string())
}

fn unix_time_ms() -> Result<u128> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .context("system time precedes Unix epoch")?
        .as_millis())
}
