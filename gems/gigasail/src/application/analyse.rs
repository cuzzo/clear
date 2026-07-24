//! Trusted and embedded analysis application service.

use crate::{
    load_config, read_manifest_artifact, ArtifactKind, GitProvider, ProfileExecutionSession,
    ProfileRunKind, Storage,
};
use anyhow::{Context, Result};
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone)]
pub struct AnalyseRequest {
    pub repo: PathBuf,
    pub db: PathBuf,
    pub profile: String,
    pub ingest: bool,
    pub trust_current_config: bool,
}

#[derive(Debug, Clone)]
pub struct AnalyseResult {
    pub profile: String,
    pub revision: String,
    pub artifact_count: usize,
    pub ingested: bool,
    pub run_directory: PathBuf,
}

/// Runs an explicitly selected analysis profile. The CLI only prints this
/// typed result; configuration trust, workspace serialization, staging, and
/// optional ingestion remain library policy.
pub fn execute(request: AnalyseRequest) -> Result<AnalyseResult> {
    let config = analysis_config(
        &request.repo,
        &request.profile,
        request.trust_current_config,
    )?;
    let git = GitProvider::open(&request.repo)?;
    let revision = if request.ingest {
        crate::application::revision::ensure_profile_clean_worktree(
            &request.repo,
            &config,
            &request.profile,
            Some(&request.db),
        )?;
        git.resolve_commit("HEAD")?
    } else {
        crate::git::WORKTREE_REVISION.into()
    };
    let execution = ProfileExecutionSession::begin(&request.repo, &config)?;
    let completed = execution.execute(
        &request.profile,
        &revision,
        ProfileRunKind::StandaloneAnalysis,
    )?;
    if request.ingest {
        crate::application::revision::ensure_profile_clean_worktree(
            &request.repo,
            &config,
            &request.profile,
            Some(&request.db),
        )?;
        crate::application::revision::ensure_revision_snapshot(
            &request.db,
            &request.repo,
            &revision,
        )?;
        crate::application::ingest::ingest_run_manifest(
            &request.db,
            &request.repo,
            &completed.directory.join("manifest.json"),
        )?;
        Storage::open(&request.db)?.refresh_ui_summaries()?;
        crate::seal_published_run(&completed.directory)?;
    }
    Ok(AnalyseResult {
        profile: request.profile,
        revision,
        artifact_count: completed.manifest.artifacts.len(),
        ingested: request.ingest,
        run_directory: completed.directory,
    })
}

pub fn build_analysis_overlay(
    repo: &Path,
    provider: &GitProvider,
    requested_head: Option<&str>,
    trust_current_config: bool,
) -> Result<Vec<crate::diff::SarifObservation>> {
    let config = analysis_config(repo, "analyse", trust_current_config)?;
    let revision = if let Some(head) =
        requested_head.filter(|head| *head != crate::git::WORKTREE_REVISION)
    {
        let resolved = provider.resolve_commit(head)?;
        if resolved != provider.resolve_commit("HEAD")? {
            anyhow::bail!(
                "diff --analyse can only execute the current checkout; checkout {resolved} before analysing a historical revision"
            );
        }
        crate::application::revision::ensure_profile_clean_worktree(
            repo, &config, "analyse", None,
        )?;
        resolved
    } else {
        crate::git::WORKTREE_REVISION.into()
    };
    let execution = ProfileExecutionSession::begin(repo, &config)?;
    let run = execution.execute("analyse", &revision, ProfileRunKind::StandaloneAnalysis)?;
    let observations = sarif_observations_from_run(repo, &run.directory, &run.manifest);
    let cleanup = fs::remove_dir_all(&run.directory)
        .with_context(|| format!("remove ephemeral analysis run {}", run.directory.display()));
    match (observations, cleanup) {
        (Ok(observations), Ok(())) => Ok(observations),
        (Err(error), Ok(())) => Err(error),
        (Ok(_), Err(error)) => Err(error),
        (Err(error), Err(cleanup_error)) => Err(error.context(format!(
            "also failed to clean analysis run: {cleanup_error:#}"
        ))),
    }
}

/// Returns only embedded, allowlisted analysis unless the caller explicitly
/// authorizes execution of checkout configuration. This distinction matters:
/// a repository's `giga.yml` is arbitrary code when it contains command
/// producers, while the built-in provider is linked into this binary.
pub fn analysis_config(
    repo: &Path,
    profile: &str,
    trust_current_config: bool,
) -> Result<crate::LineageConfig> {
    let yaml = repo.join(crate::pipeline::CONFIG_FILE_NAME);
    let json = repo.join(crate::pipeline::CONFIG_JSON_FILE_NAME);
    if trust_current_config {
        if !yaml.exists() && !json.exists() {
            if profile == "analyse" {
                return builtin_analysis_config();
            }
            anyhow::bail!(
                "analysis profile {profile:?} is not built in and no giga.yml was found"
            );
        }
        let config = load_config(repo)?;
        if !config.profiles.contains_key(profile) {
            anyhow::bail!("unknown Gigasail analysis profile {profile:?}");
        }
        return Ok(config);
    }
    if profile != "analyse" {
        anyhow::bail!(
            "analysis profile {profile:?} is repository configuration; pass --trust-current-config after review"
        );
    }
    builtin_analysis_config()
}

fn builtin_analysis_config() -> Result<crate::LineageConfig> {
    use crate::pipeline::{
        validate_config, EvidenceProducer, ProducerExecutor, VerificationProfile,
    };
    let producer_names = vec!["fact-mine".to_string()];
    let producers = BTreeMap::from([(
        "fact-mine".to_string(),
        EvidenceProducer {
            executor: ProducerExecutor::Gigasail,
            argv: vec!["fact-mine-native".to_string()],
            working_directory: None,
            timeout_seconds: 60,
            max_output_bytes: 8 * 1024 * 1024,
            environment: BTreeMap::new(),
            produces: vec![crate::pipeline::ProducedArtifact {
                kind: ArtifactKind::Sarif,
                format: "sarif".to_string(),
                path: PathBuf::from(".giga/artifacts/fact-mine.sarif"),
                scope: Some("static".to_string()),
                complete: false,
                evidence_scope: None,
            }],
        },
    )]);
    validate_config(crate::LineageConfig {
        version: 1,
        artifacts: Default::default(),
        profiles: BTreeMap::from([(
            "analyse".to_string(),
            VerificationProfile {
                producers: producer_names,
                required_evidence: Default::default(),
            },
        )]),
        producers,
    })
}

fn sarif_observations_from_run(
    repo: &Path,
    run_directory: &Path,
    manifest: &crate::RunManifest,
) -> Result<Vec<crate::diff::SarifObservation>> {
    let mut observations = Vec::new();
    for artifact in manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.kind == ArtifactKind::Sarif)
    {
        let document: serde_json::Value =
            serde_json::from_slice(&read_manifest_artifact(run_directory, artifact)?)?;
        for finding in crate::normalize_sarif_document(repo, &document)? {
            let tier = finding
                .provenance
                .get("tier")
                .or_else(|| finding.provenance.get("risk_tier"))
                .and_then(|value| value.parse::<u8>().ok());
            observations.push(crate::diff::SarifObservation {
                path: finding.path,
                finding: crate::diff::SarifFindingSummary {
                    source: artifact.producer.clone(),
                    tool: finding.tool_name,
                    rule_id: finding.rule_id,
                    level: finding.level,
                    category: finding.category,
                    message: finding.message,
                    fingerprint: finding.fingerprint,
                    tier,
                    tier_one: tier == Some(1),
                    status: finding.status,
                    provenance: finding.provenance,
                    proof_boundary: finding.proof_boundary,
                    start_line: finding.start_line,
                    end_line: finding.end_line.unwrap_or(finding.start_line),
                },
            });
        }
    }
    Ok(observations)
}
