//! Trusted CI configuration, publication state, and crash recovery.

use crate::{
    latest_run_directory, load_config, load_config_contents, load_run_manifest, publish_run,
    seal_published_run, validate_run_artifacts, ArtifactKind, GitProvider, Storage,
};
use anyhow::{Context, Result};
use std::{
    fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone)]
pub struct CiRequest {
    pub repo: PathBuf,
    pub db: PathBuf,
    pub profile: String,
    pub config_revision: Option<String>,
    pub trust_current_config: bool,
    pub require_complete: bool,
}

#[derive(Debug, Clone)]
pub struct CiResult {
    pub profile: String,
    pub revision: String,
    pub artifact_count: usize,
}

/// Executes the complete CI state machine. The service owns trust selection,
/// clean-tree checks, snapshotting, ingestion, publication, and durable state.
pub fn execute(request: CiRequest) -> Result<CiResult> {
    let git = GitProvider::open(&request.repo)?;
    let config = load_ci_config(
        &request.repo,
        &git,
        request.config_revision.as_deref(),
        request.trust_current_config,
    )?;
    if request.require_complete {
        ensure_profile_declares_complete_artifacts(&config, &request.profile)?;
    }
    let execution = crate::ProfileExecutionSession::begin(&request.repo, &config)?;
    reconcile_pending_publications(&request.repo, &config, &request.db)?;
    crate::application::revision::ensure_profile_clean_worktree(
        &request.repo,
        &config,
        &request.profile,
        Some(&request.db),
    )?;
    let revision = git.resolve_commit("HEAD")?;
    crate::application::revision::ensure_revision_snapshot(&request.db, &request.repo, &revision)?;
    let completed = execution.execute(
        &request.profile,
        &revision,
        crate::ProfileRunKind::CiPublication,
    )?;
    crate::application::revision::ensure_profile_clean_worktree(
        &request.repo,
        &config,
        &request.profile,
        Some(&request.db),
    )?;
    let run = completed.directory.join("manifest.json");
    write_publication_state(&completed.directory, PublicationState::Ingesting)?;
    record_run_state(&request.db, &run, "ingesting")?;
    crate::application::ingest::ingest_run_manifest(&request.db, &request.repo, &run)?;
    write_publication_state(&completed.directory, PublicationState::Ingested)?;
    Storage::open(&request.db)?.refresh_ui_summaries()?;
    write_publication_state(&completed.directory, PublicationState::ReadyToPublish)?;
    publish_run(&request.repo, &config, &completed.directory)?;
    let published = latest_run_directory(&request.repo, &config);
    write_publication_state(&published, PublicationState::Published)?;
    seal_published_run(&published)?;
    record_run_state(&request.db, &published.join("manifest.json"), "published")?;
    Ok(CiResult {
        profile: request.profile,
        revision: completed.manifest.revision,
        artifact_count: completed.manifest.artifacts.len(),
    })
}

pub fn load_ci_config(
    repo: &Path,
    git: &GitProvider,
    requested_revision: Option<&str>,
    trust_current_config: bool,
) -> Result<crate::LineageConfig> {
    if trust_current_config {
        if requested_revision.is_some() {
            anyhow::bail!("--trust-current-config and --config-revision cannot be used together");
        }
        return load_config(repo);
    }
    let revision = match requested_revision {
        Some(revision) => git.resolve_commit(revision)?,
        None => git.resolve_commit("HEAD^").with_context(|| {
            "lineage ci requires --config-revision or --trust-current-config when HEAD has no reviewed parent"
        })?,
    };
    let yaml = git.file_contents_at_commit(&revision, crate::pipeline::CONFIG_FILE_NAME)?;
    let json = git.file_contents_at_commit(&revision, crate::pipeline::CONFIG_JSON_FILE_NAME)?;
    match (yaml, json) {
        (Some(_), Some(_)) => anyhow::bail!(
            "trusted configuration revision {revision} contains both lineage.yml and lineage.json"
        ),
        (Some(contents), None) => load_config_contents(&contents, Some("yml")).with_context(|| {
            format!("parse trusted lineage.yml from configuration revision {revision}")
        }),
        (None, Some(contents)) => load_config_contents(&contents, Some("json")).with_context(|| {
            format!("parse trusted lineage.json from configuration revision {revision}")
        }),
        (None, None) => anyhow::bail!(
            "trusted configuration revision {revision} contains no lineage.yml; use --trust-current-config only after review"
        ),
    }
}

const PUBLICATION_STATE_FILE: &str = ".publication-state";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PublicationState {
    Ingesting,
    Ingested,
    ReadyToPublish,
    Published,
}

impl PublicationState {
    fn as_str(self) -> &'static str {
        match self {
            Self::Ingesting => "ingesting",
            Self::Ingested => "ingested",
            Self::ReadyToPublish => "ready_to_publish",
            Self::Published => "published",
        }
    }

    fn parse(value: &str) -> Result<Self> {
        match value.trim() {
            "ingesting" => Ok(Self::Ingesting),
            "ingested" => Ok(Self::Ingested),
            "ready_to_publish" => Ok(Self::ReadyToPublish),
            "published" => Ok(Self::Published),
            other => anyhow::bail!("invalid Lineage publication state {other:?}"),
        }
    }
}

pub fn write_publication_state(run_directory: &Path, state: PublicationState) -> Result<()> {
    use std::io::Write;

    let state_path = run_directory.join(PUBLICATION_STATE_FILE);
    let temporary = run_directory.join(format!(
        ".{PUBLICATION_STATE_FILE}.{}-{}.tmp",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .context("system time precedes Unix epoch")?
            .as_nanos()
    ));
    let result = (|| -> Result<()> {
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)?;
        file.write_all(format!("{}\n", state.as_str()).as_bytes())?;
        file.sync_all()?;
        fs::rename(&temporary, &state_path)?;
        #[cfg(unix)]
        fs::File::open(run_directory)?.sync_all()?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.with_context(|| {
        format!(
            "write Lineage publication state in {}",
            run_directory.display()
        )
    })
}

pub fn run_key(manifest_path: &Path) -> Result<String> {
    let directory = manifest_path
        .parent()
        .context("run manifest has no directory")?;
    directory
        .file_name()
        .and_then(|name| name.to_str())
        .map(|name| {
            name.trim_start_matches(".staging-")
                .trim_start_matches("pending-")
                .trim_start_matches("analysis-")
                .trim_start_matches("published-")
                .trim_start_matches("failed-")
                .to_string()
        })
        .context("run directory has no valid name")
}

fn unix_time_ms() -> Result<u128> {
    Ok(std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .context("system time precedes Unix epoch")?
        .as_millis())
}

pub fn record_run_state(db: &Path, manifest_path: &Path, state: &str) -> Result<()> {
    let manifest = load_run_manifest(manifest_path)?;
    Storage::open(db)?.record_ci_run(&run_key(manifest_path)?, &manifest, state, unix_time_ms()?)
}

pub fn publication_state(run_directory: &Path) -> Result<PublicationState> {
    let path = run_directory.join(PUBLICATION_STATE_FILE);
    let contents = fs::read_to_string(&path)
        .with_context(|| format!("read Lineage publication state {}", path.display()))?;
    PublicationState::parse(&contents)
}

/// Recovers unfinished publication after a crash. A `ready_to_publish` state
/// may be in either `pending-*` or `published-*`: the latter means the crash
/// occurred after the durable directory rename but before `latest` changed.
pub fn reconcile_pending_publications(
    repo: &Path,
    config: &crate::LineageConfig,
    db: &Path,
) -> Result<()> {
    let runs = repo.join(&config.artifacts.directory).join("runs");
    if !runs.exists() {
        return Ok(());
    }
    let mut recoverable = fs::read_dir(&runs)?
        .filter_map(std::result::Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("pending-") || name.starts_with("published-"))
        })
        .collect::<Vec<_>>();
    recoverable.sort();
    for run in recoverable {
        let is_published = run
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with("published-"));
        let state = match publication_state(&run) {
            Ok(state) => state,
            Err(error)
                if !is_published
                    && error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|io| io.kind() == std::io::ErrorKind::NotFound) =>
            {
                // A producer can finish and finalize its immutable staged
                // payload before the post-run clean-tree validation fails.
                // No publication state means ingestion was never authorized;
                // retain the forensic payload as a failed run instead of
                // making every later CI invocation unrecoverable.
                let name = run
                    .file_name()
                    .and_then(|name| name.to_str())
                    .context("pending Lineage run has no name")?;
                let failed = runs.join(format!("failed-{}", name.trim_start_matches("pending-")));
                fs::rename(&run, &failed).with_context(|| {
                    format!("quarantine incomplete Lineage run {}", run.display())
                })?;
                continue;
            }
            Err(error) => {
                return Err(error).with_context(|| {
                    format!(
                        "recoverable Lineage run {} has no publication state",
                        run.display()
                    )
                })
            }
        };
        match state {
            PublicationState::Ingesting => {
                if is_published {
                    anyhow::bail!("published Lineage run {} is still ingesting", run.display());
                }
                crate::application::ingest::ingest_run_manifest(
                    db,
                    repo,
                    &run.join("manifest.json"),
                )?;
                write_publication_state(&run, PublicationState::Ingested)?;
                Storage::open(db)?.refresh_ui_summaries()?;
                write_publication_state(&run, PublicationState::ReadyToPublish)?;
                publish_run(repo, config, &run)?;
                write_publication_state(
                    &latest_run_directory(repo, config),
                    PublicationState::Published,
                )?;
                seal_published_run(&latest_run_directory(repo, config))?;
                record_run_state(
                    db,
                    &latest_run_directory(repo, config).join("manifest.json"),
                    "published",
                )?;
            }
            PublicationState::Ingested => {
                if is_published {
                    anyhow::bail!("published Lineage run {} is only ingested", run.display());
                }
                Storage::open(db)?.refresh_ui_summaries()?;
                write_publication_state(&run, PublicationState::ReadyToPublish)?;
                publish_run(repo, config, &run)?;
                write_publication_state(
                    &latest_run_directory(repo, config),
                    PublicationState::Published,
                )?;
                seal_published_run(&latest_run_directory(repo, config))?;
                record_run_state(
                    db,
                    &latest_run_directory(repo, config).join("manifest.json"),
                    "published",
                )?;
            }
            PublicationState::ReadyToPublish => {
                publish_run(repo, config, &run)?;
                write_publication_state(
                    &latest_run_directory(repo, config),
                    PublicationState::Published,
                )?;
                seal_published_run(&latest_run_directory(repo, config))?;
                record_run_state(
                    db,
                    &latest_run_directory(repo, config).join("manifest.json"),
                    "published",
                )?;
            }
            PublicationState::Published => {
                if !is_published {
                    anyhow::bail!(
                        "pending Lineage run {} is incorrectly marked published",
                        run.display()
                    );
                }
                let manifest = load_run_manifest(&run.join("manifest.json"))?;
                validate_run_artifacts(&run, &manifest)?;
                publish_run(repo, config, &run)?;
                record_run_state(db, &run.join("manifest.json"), "published")?;
            }
        }
    }
    Ok(())
}

pub fn ensure_profile_declares_complete_artifacts(
    config: &crate::pipeline::LineageConfig,
    profile_name: &str,
) -> Result<()> {
    let profile = config
        .profiles
        .get(profile_name)
        .with_context(|| format!("unknown Lineage profile {profile_name:?}"))?;
    let declared = profile
        .producers
        .iter()
        .flat_map(|name| {
            config.producers[name]
                .produces
                .iter()
                .map(move |artifact| (name, artifact))
        })
        .filter(|(_, artifact)| artifact.kind != ArtifactKind::Auxiliary)
        .collect::<Vec<_>>();
    if declared.is_empty() {
        anyhow::bail!(
            "profile {profile_name:?} cannot satisfy --require-complete because it declares no evidence artifacts"
        );
    }
    let incomplete = declared.iter().find(|(_, artifact)| !artifact.complete);
    if let Some((producer, artifact)) = incomplete {
        anyhow::bail!(
            "profile {profile_name:?} cannot satisfy --require-complete: producer {producer:?} artifact {} is declared partial",
            artifact.path.display()
        );
    }
    for required in &profile.required_evidence {
        if !declared
            .iter()
            .any(|(_, artifact)| artifact.kind == *required)
        {
            anyhow::bail!(
                "profile {profile_name:?} cannot satisfy --require-complete: missing required {required:?} evidence"
            );
        }
    }
    Ok(())
}
