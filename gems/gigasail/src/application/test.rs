//! `giga test`: run the test producers a project already declares in giga.yml,
//! selected by review stage and flags, then ingest the evidence. It is a thin
//! orchestrator over the existing profile/producer machinery - it does NOT
//! reinvent a build system. Producers are ordinary shell commands ("run these
//! tests"); mutation can fan out to test-miser; a project that uses Bazel simply
//! puts `bazel test ...` in a producer's argv. See docs/agents/tuning-configs.md
//! §12 for the model and the Bazel-delegation plan.

use crate::git::GitProvider;
use crate::pipeline::{ArtifactKind, ProfileExecutionSession, ProfileRunKind, VerificationProfile};
use crate::review::ReviewMode;
use anyhow::{bail, Result};
use std::path::PathBuf;

pub struct TestRequest {
    pub repo: PathBuf,
    pub db: PathBuf,
    /// `--unit` / `--integration` / `--fuzz`: restrict to producers with a
    /// matching `evidence_scope.test_set` tag. Empty = every tag in the stage.
    pub tags: Vec<String>,
    /// `--mutants`: include mutation producers even if the stage default is off.
    pub mutants: bool,
    /// `--no-cov`: skip coverage-only producers (mutation producers still run).
    pub no_cov: bool,
    /// Which stage's profile set to draw from (precommit = fast, premerge = full).
    pub stage: ReviewMode,
    /// Explicit changed-path set (from `--changed`), bypassing the git diff.
    pub changed_override: Option<Vec<String>>,
    /// `--checks`/`--no-checks`: force pre-test check gates on/off. `None` uses
    /// the config default (`review.checks_enabled`).
    pub run_checks: Option<bool>,
    pub trust_current_config: bool,
    /// Print the resolved producer plan without running anything.
    pub dry_run: bool,
}

pub struct TestResult {
    pub producers: Vec<String>,
    /// Pre-test check gates that ran (or would run, in dry-run) before producers.
    pub checks: Vec<String>,
    pub mutation_forced: bool,
    pub revision: Option<String>,
    pub artifact_count: usize,
    pub dry_run: bool,
}

/// Resolve the producer set for the request from the giga.yml `review.tests`
/// stage config plus the flag overrides.
fn resolve_producers(
    config: &crate::LineageConfig,
    req: &TestRequest,
    changed_paths: Option<&[String]>,
) -> (Vec<String>, bool) {
    let stage = config.review.stage_tests(req.stage);
    let want_mutants = stage.mutation || req.mutants;
    // With a project graph + a known change set, run only the affected packages'
    // producers ("run these tests when these files change"). Otherwise fall back
    // to the stage's profiles (run everything the stage declares).
    let affected = changed_paths
        .map(|paths| config.review.affected_producers(paths, req.stage))
        .unwrap_or_default();
    let mut names: Vec<String> = if !affected.is_empty() {
        affected
    } else if !config.review.packages.is_empty() && changed_paths.is_some() {
        // A graph is configured and we know the changes, but nothing matched:
        // nothing to run.
        Vec::new()
    } else {
        stage
            .profiles
            .iter()
            .filter_map(|p| config.profiles.get(p))
            .flat_map(|prof| prof.producers.iter().cloned())
            .collect()
    };
    // Mutation producers aren't tied to a stage's profile list, so when mutation
    // is wanted (stage default or `--mutants`) pull in every producer that emits
    // a mutants artifact, wherever it is declared.
    if want_mutants {
        for (name, producer) in &config.producers {
            if producer
                .produces
                .iter()
                .any(|a| a.kind == ArtifactKind::Mutants)
            {
                names.push(name.clone());
            }
        }
    }
    names.sort();
    names.dedup();
    names.retain(|name| {
        let Some(producer) = config.producers.get(name) else {
            return false;
        };
        let has_cov = producer
            .produces
            .iter()
            .any(|a| a.kind == ArtifactKind::Coverage);
        let has_mut = producer
            .produces
            .iter()
            .any(|a| a.kind == ArtifactKind::Mutants);
        // `--mutants`/stage gates mutation producers; `--no-cov` drops pure
        // coverage producers (a producer that emits both is kept if mutants run).
        if has_mut && !want_mutants {
            return false;
        }
        if req.no_cov && has_cov && !has_mut {
            return false;
        }
        // Tag filter: keep producers whose evidence_scope.test_set matches.
        if !req.tags.is_empty() {
            let matches_tag = producer.produces.iter().any(|a| {
                a.evidence_scope
                    .as_ref()
                    .is_some_and(|s| req.tags.iter().any(|t| *t == s.test_set))
            });
            if !matches_tag {
                return false;
            }
        }
        true
    });
    (names, want_mutants && !stage.mutation)
}

pub fn execute(req: TestRequest) -> Result<TestResult> {
    let git = GitProvider::open(&req.repo)?;
    let config = crate::application::ci::load_ci_config(&req.repo, &git, None, req.trust_current_config)?;
    // Change detection: with a project graph, diff the stage's base against the
    // working tree to find which packages (hence producers) are affected. Shared
    // with `giga affected` so the base selection has one definition.
    let changed = crate::application::affected::changed_paths(
        &git,
        &config,
        req.stage,
        req.changed_override.as_deref(),
    );
    let (producers, mutation_forced) = resolve_producers(&config, &req, changed.as_deref());
    if producers.is_empty() {
        bail!(
            "no test producers matched (stage={:?}, tags={:?}, mutants={}, no_cov={}). \
             Check `review.tests` and the producer `kind`/`evidence_scope.test_set` in giga.yml.",
            req.stage,
            req.tags,
            req.mutants,
            req.no_cov
        );
    }
    // Pre-test check gates: when enabled, the affected packages' `checks`
    // (lint/format) run before producers and stop the run early on failure.
    let checks_on = req.run_checks.unwrap_or(config.review.checks_enabled);
    let checks = match (checks_on, &changed) {
        (true, Some(paths)) => config.review.affected_checks(paths),
        _ => Vec::new(),
    };
    if req.dry_run {
        return Ok(TestResult {
            producers,
            checks,
            mutation_forced,
            revision: None,
            artifact_count: 0,
            dry_run: true,
        });
    }
    if !checks.is_empty() {
        let changed_paths = changed.as_deref().unwrap_or(&[]);
        crate::application::checks::run(&req.repo, &checks, changed_paths)?;
    }

    // Run the selected producers as a synthetic profile, then ingest. Tests run
    // against the current checkout (a dirty worktree is fine - you test your
    // working changes), so we deliberately do not require a clean tree here.
    let mut config = config;
    let profile_name = "__giga_test";
    config.profiles.insert(
        profile_name.to_string(),
        VerificationProfile {
            producers: producers.clone(),
            required_evidence: Default::default(),
        },
    );
    let execution = ProfileExecutionSession::begin(&req.repo, &config)?;
    let revision = git.resolve_commit("HEAD")?;
    crate::application::revision::ensure_revision_snapshot(&req.db, &req.repo, &revision)?;
    let completed = execution.execute(profile_name, &revision, ProfileRunKind::StandaloneAnalysis)?;
    let run = completed.directory.join("manifest.json");
    crate::application::ingest::ingest_run_manifest(&req.db, &req.repo, &run)?;
    crate::storage::Storage::open(&req.db)?.refresh_ui_summaries()?;
    Ok(TestResult {
        producers,
        checks,
        mutation_forced,
        revision: Some(completed.manifest.revision),
        artifact_count: completed.manifest.artifacts.len(),
        dry_run: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config() -> crate::LineageConfig {
        crate::pipeline::load_config_contents(
            "version: 1\n\
             profiles:\n\
             \x20 ci: { producers: [rspec-unit] }\n\
             \x20 mutation: { producers: [ruby-mutants] }\n\
             producers:\n\
             \x20 rspec-unit:\n\
             \x20   executor: command\n\
             \x20   argv: [sh, -c, 'true']\n\
             \x20   produces:\n\
             \x20     - { kind: coverage, format: simplecov, path: c.json, evidence_scope: {selection: full, test_set: unit} }\n\
             \x20 ruby-mutants:\n\
             \x20   executor: command\n\
             \x20   argv: [sh, -c, 'true']\n\
             \x20   produces:\n\
             \x20     - { kind: mutants, format: mutant-facts, path: m.json, evidence_scope: {selection: full, test_set: unit} }\n\
             review:\n\
             \x20 tests:\n\
             \x20   precommit: { profiles: [ci], mutation: false }\n\
             \x20   premerge:  { profiles: [ci, mutation], mutation: true }\n",
            Some("yaml"),
        )
        .unwrap()
    }

    fn req(stage: ReviewMode, mutants: bool, no_cov: bool, tags: &[&str]) -> TestRequest {
        TestRequest {
            repo: ".".into(),
            db: ".giga/gigasail.db".into(),
            tags: tags.iter().map(|t| t.to_string()).collect(),
            mutants,
            no_cov,
            stage,
            changed_override: None,
            run_checks: None,
            trust_current_config: true,
            dry_run: true,
        }
    }

    #[test]
    fn stage_and_flags_select_the_right_producers() {
        let c = config();
        // precommit: fast unit coverage, no mutants.
        let (p, forced) = resolve_producers(&c, &req(ReviewMode::Precommit, false, false, &[]), None);
        assert_eq!(p, ["rspec-unit"]);
        assert!(!forced);
        // --mutants pulls the mutation producer in even at precommit.
        let (p, forced) = resolve_producers(&c, &req(ReviewMode::Precommit, true, false, &[]), None);
        assert_eq!(p, ["rspec-unit", "ruby-mutants"]);
        assert!(forced);
        // premerge runs both by default (mutation not "forced" - it's the default).
        let (p, forced) = resolve_producers(&c, &req(ReviewMode::Premerge, false, false, &[]), None);
        assert_eq!(p, ["rspec-unit", "ruby-mutants"]);
        assert!(!forced);
        // --no-cov drops the coverage-only producer.
        let (p, _) = resolve_producers(&c, &req(ReviewMode::Premerge, false, true, &[]), None);
        assert_eq!(p, ["ruby-mutants"]);
    }
}
