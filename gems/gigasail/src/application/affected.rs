//! `giga affected`: resolve the project-graph "affected set" for a change and
//! emit it (text or JSON) - the general "given changed files + a declared graph,
//! print the affected work" primitive. CI diffs the base, feeds the paths here,
//! and gates its job matrix on the JSON. Pure graph resolution: no DB, no run.

use crate::git::GitProvider;
use crate::review::ReviewMode;
use anyhow::Result;
use std::path::Path;

#[derive(Debug)]
pub struct Affected {
    pub mode: String,
    pub changed: Vec<String>,
    pub packages: Vec<String>,
    pub producers: Vec<String>,
    pub checks: Vec<String>,
}

/// The changed-path set for a stage: the explicit override, else a git diff of
/// the stage base (`HEAD~1` precommit, `merge-base` premerge) against the
/// working tree. `None` when no package graph is configured (nothing to resolve
/// against). Shared by `giga test` and `giga affected` so the base selection has
/// one definition.
pub fn changed_paths(
    git: &GitProvider,
    config: &crate::LineageConfig,
    stage: ReviewMode,
    changed_override: Option<&[String]>,
) -> Option<Vec<String>> {
    if let Some(explicit) = changed_override {
        return Some(explicit.to_vec());
    }
    if config.review.packages.is_empty() {
        return None;
    }
    let base = match stage {
        ReviewMode::Precommit => "HEAD~1".to_string(),
        ReviewMode::Premerge => git
            .merge_base("HEAD", "master")
            .unwrap_or_else(|_| "HEAD~1".to_string()),
    };
    git.changed_paths(&base).ok()
}

pub fn execute(
    repo: &Path,
    stage: ReviewMode,
    changed_override: Option<Vec<String>>,
    trust_current_config: bool,
) -> Result<Affected> {
    let git = GitProvider::open(repo)?;
    let config = crate::application::ci::load_ci_config(repo, &git, None, trust_current_config)?;
    let changed =
        changed_paths(&git, &config, stage, changed_override.as_deref()).unwrap_or_default();
    Ok(Affected {
        mode: match stage {
            ReviewMode::Precommit => "precommit",
            ReviewMode::Premerge => "premerge",
        }
        .to_string(),
        packages: config.review.affected_package_names(&changed),
        producers: config.review.affected_producers(&changed, stage),
        checks: config.review.affected_checks(&changed),
        changed,
    })
}
