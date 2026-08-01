//! Evidence-aware diff preparation application service.
//!
//! This module owns configuration-driven evidence selection and optional
//! analysis overlays.  It deliberately returns a render-independent plan so
//! the CLI, UI, and JSON consumers cannot diverge on diff semantics.

use crate::{
    build_structured_diff, latest_run_directory, load_config, load_run_manifest,
    validate_run_artifacts, ArtifactKind, DiffPlan, DiffRequest as CoreDiffRequest, GitProvider,
    RunStatus, Storage,
};
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone)]
pub struct DiffCommandRequest {
    pub repo: PathBuf,
    pub db: PathBuf,
    pub base: Option<String>,
    pub head: Option<String>,
    pub full: bool,
    pub coverage_source: Option<String>,
    pub sarif_source: Option<String>,
    pub selection: Option<String>,
    pub mutant_corpus: Option<String>,
    pub test_set: Option<String>,
    pub analyse: bool,
    pub trust_current_config: bool,
    pub require_profile: Option<String>,
    pub require_complete: bool,
}

#[derive(Debug, Clone)]
pub struct DiffResult {
    pub plan: DiffPlan,
    /// Supplemental profile-wide evidence accounting for `--full`. This is
    /// separate from `DiffPlan` because not every configured artifact can be
    /// attached to a changed source line.
    pub configured_evidence_report: Option<String>,
}

pub fn prepare(mut request: DiffCommandRequest) -> Result<DiffResult> {
    let provider = GitProvider::open(&request.repo)?;
    let analysis_overlay = if request.analyse {
        crate::application::analyse::build_analysis_overlay(
            &request.repo,
            &provider,
            request.head.as_deref(),
            request.trust_current_config,
        )?
    } else {
        Vec::new()
    };
    if let Some(profile) = request.require_profile.as_deref() {
        ensure_required_profile(
            &request.repo,
            &request.db,
            &provider,
            request.head.as_deref(),
            profile,
            request.require_complete,
        )?;
    } else if request.require_complete {
        anyhow::bail!("--require-complete requires --require-profile");
    }
    resolve_diff_run_scope(&provider, &mut request)?;
    let configured_evidence_report = request
        .full
        .then(|| configured_evidence_report(&request.repo, &provider, &request))
        .transpose()?;
    let storage = request
        .db
        .exists()
        .then(|| Storage::open_existing(&request.db))
        .transpose()?;
    let mut plan = build_structured_diff(
        &provider,
        storage.as_ref(),
        &CoreDiffRequest {
            base_revision: request.base,
            head_revision: request.head,
            coverage_source: request.coverage_source,
            sarif_source: request.sarif_source,
            selection: request.selection,
            mutant_corpus: request.mutant_corpus,
            test_set: request.test_set,
        },
    )?;
    if !analysis_overlay.is_empty() {
        crate::diff::apply_head_only_sarif_findings(&mut plan, &analysis_overlay);
    }
    Ok(DiffResult {
        plan,
        configured_evidence_report,
    })
}

/// `DiffPlan` contains evidence that can be joined to changed source lines.
/// `--full` additionally reports every profile family, including evidence with
/// no source-line representation.
fn configured_evidence_report(
    repo: &Path,
    provider: &GitProvider,
    request: &DiffCommandRequest,
) -> Result<String> {
    let config_path = repo.join(crate::pipeline::CONFIG_FILE_NAME);
    let json_path = repo.join(crate::pipeline::CONFIG_JSON_FILE_NAME);
    if !config_path.exists() && !json_path.exists() {
        return Ok("Configured evidence: unconfigured (no giga.yml)\n".into());
    }
    let config = load_config(repo)?;
    let profile_name = request
        .require_profile
        .as_deref()
        .or_else(|| config.profiles.contains_key("ci").then_some("ci"));
    let Some(profile_name) = profile_name else {
        return Ok("Configured evidence: unconfigured (no selected profile)\n".into());
    };
    let profile = config
        .profiles
        .get(profile_name)
        .context("selected Gigasail profile is missing")?;
    let manifest_path = latest_run_directory(repo, &config).join("manifest.json");
    let manifest = manifest_path
        .exists()
        .then(|| load_run_manifest(&manifest_path))
        .transpose()?;
    let requested_head = request
        .head
        .as_deref()
        .filter(|head| *head != crate::git::WORKTREE_REVISION)
        .map(|head| provider.resolve_commit(head))
        .transpose()?;
    let working_tree =
        request.head.is_none() || request.head.as_deref() == Some(crate::git::WORKTREE_REVISION);
    let mut output = format!("Configured evidence ({profile_name}):\n");
    for required in &profile.required_evidence {
        let state = match manifest.as_ref() {
            None => "missing",
            Some(manifest) if manifest.status != RunStatus::Succeeded => "failed",
            Some(_) if working_tree => "stale",
            Some(manifest)
                if requested_head
                    .as_ref()
                    .is_some_and(|head| manifest.revision != *head) =>
            {
                "stale"
            }
            Some(manifest) => match manifest
                .artifacts
                .iter()
                .filter(|artifact| artifact.kind == *required)
                .map(|artifact| artifact.complete)
                .reduce(|left, right| left && right)
            {
                Some(true) => "exact",
                Some(false) => "partial",
                None => "missing",
            },
        };
        use std::fmt::Write;
        let _ = writeln!(output, "  {state:<9} {required:?}");
    }
    Ok(output)
}

fn ensure_required_profile(
    repo: &Path,
    db: &Path,
    provider: &GitProvider,
    requested_head: Option<&str>,
    profile_name: &str,
    require_complete: bool,
) -> Result<()> {
    if requested_head == Some(crate::git::WORKTREE_REVISION) || requested_head.is_none() {
        anyhow::bail!(
            "--require-profile requires an explicit immutable head revision; working-tree evidence is not exact"
        );
    }
    let config = load_config(repo)?;
    if require_complete {
        crate::application::ci::ensure_profile_declares_complete_artifacts(&config, profile_name)?;
    }
    let manifest_path = latest_run_directory(repo, &config).join("manifest.json");
    let manifest = load_run_manifest(&manifest_path).with_context(|| {
        format!("--require-profile {profile_name:?} needs a successful latest Gigasail run")
    })?;
    validate_run_artifacts(
        manifest_path
            .parent()
            .context("latest run has no directory")?,
        &manifest,
    )
    .context("--require-profile found a modified or corrupt published artifact")?;
    let record = Storage::open_existing(db)?
        .ci_run_record(&crate::application::ci::run_key(&manifest_path)?)?
        .context("--require-profile has no durable database run record")?;
    if record.state != "published"
        || record.manifest_hash != crate::run_manifest_hash(&manifest)?
        || record.revision != manifest.revision
        || record.profile != manifest.profile
        || record.repository_identity != manifest.repository_identity
        || record.configuration_hash != manifest.configuration_hash
    {
        anyhow::bail!(
            "--require-profile {profile_name:?} has a stale or modified durable database run record"
        );
    }
    let head = provider.resolve_commit(requested_head.expect("checked above"))?;
    if manifest.status != RunStatus::Succeeded
        || manifest.profile != profile_name
        || manifest.revision != head
        || manifest.tree_fingerprint != head
        || manifest.configuration_hash != crate::pipeline::configuration_fingerprint(&config)?
    {
        anyhow::bail!(
            "--require-profile {profile_name:?} was not satisfied by an exact successful run for {head}"
        );
    }
    if require_complete
        && manifest
            .artifacts
            .iter()
            .any(|artifact| artifact.kind != ArtifactKind::Auxiliary && !artifact.complete)
    {
        anyhow::bail!(
            "--require-profile {profile_name:?} has a successful run, but it contains partial artifacts"
        );
    }
    Ok(())
}

pub fn resolve_diff_run_scope(
    provider: &GitProvider,
    request: &mut DiffCommandRequest,
) -> Result<()> {
    let supplied = [
        request.selection.is_some(),
        request.mutant_corpus.is_some(),
        request.test_set.is_some(),
    ];
    if supplied.iter().any(|present| *present) && !supplied.iter().all(|present| *present) {
        anyhow::bail!("--selection, --mutant-corpus, and --test-set must be supplied together");
    }
    let explicit_scope = supplied.iter().all(|present| *present);
    let config_path = request.repo.join(crate::pipeline::CONFIG_FILE_NAME);
    let json_config_path = request.repo.join(crate::pipeline::CONFIG_JSON_FILE_NAME);
    if !config_path.exists() && !json_config_path.exists() {
        return Ok(());
    }
    let config = load_config(&request.repo)?;
    let manifest_path = latest_run_directory(&request.repo, &config).join("manifest.json");
    if !manifest_path.exists() {
        return Ok(());
    }
    let manifest = load_run_manifest(&manifest_path)?;
    validate_run_artifacts(
        manifest_path
            .parent()
            .context("latest run has no directory")?,
        &manifest,
    )
    .context("latest Gigasail run contains a modified or corrupt artifact")?;
    let head = provider.resolve_commit(request.head.as_deref().unwrap_or("HEAD"))?;
    if manifest.status != RunStatus::Succeeded
        || manifest.revision != head
        || (!manifest.tree_fingerprint.is_empty() && manifest.tree_fingerprint != head)
    {
        return Ok(());
    }
    let scopes = manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.complete)
        .filter_map(|artifact| {
            artifact
                .evidence_scope
                .as_ref()
                .map(|scope| (artifact.kind, scope))
        })
        .collect::<Vec<_>>();
    let Some((_, common_scope)) = scopes.first() else {
        return Ok(());
    };
    if scopes.iter().any(|(_, candidate)| {
        candidate.selection != common_scope.selection || candidate.test_set != common_scope.test_set
    }) {
        anyhow::bail!(
            "latest successful run contains incompatible complete evidence selection or test-set scopes"
        );
    }
    let mutant_corpora = scopes
        .iter()
        .filter(|(kind, _)| *kind == ArtifactKind::Mutants)
        .map(|(_, scope)| scope.mutant_corpus.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if mutant_corpora.len() > 1 {
        anyhow::bail!("latest successful run contains multiple complete mutation corpora; specify an explicit scope");
    }
    let inferred_mutant_corpus = mutant_corpora
        .into_iter()
        .next()
        .unwrap_or("not-applicable");
    if !explicit_scope {
        request.selection = Some(common_scope.selection.clone());
        request.mutant_corpus = Some(inferred_mutant_corpus.into());
        request.test_set = Some(common_scope.test_set.clone());
    }
    let coverage_sources = manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.kind == ArtifactKind::Coverage)
        .map(|artifact| artifact.producer.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if request.coverage_source.is_none() && coverage_sources.len() > 1 {
        anyhow::bail!(
            "latest successful run has multiple coverage producers; specify --coverage-source"
        );
    }
    if request.coverage_source.is_none() {
        request.coverage_source = coverage_sources.into_iter().next().map(str::to_string);
    }
    let sarif_sources = manifest
        .artifacts
        .iter()
        .filter(|artifact| artifact.kind == ArtifactKind::Sarif)
        .map(|artifact| artifact.producer.as_str())
        .collect::<std::collections::BTreeSet<_>>();
    if request.sarif_source.is_none() && sarif_sources.len() == 1 {
        request.sarif_source = sarif_sources.into_iter().next().map(str::to_string);
    }
    Ok(())
}
