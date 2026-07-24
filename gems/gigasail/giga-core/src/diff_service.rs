//! Read-only structured-diff assembly shared by the UI and command line.
//!
//! `DiffPlan` deliberately stays render-independent. This module owns the
//! repository and evidence-ledger joins required to turn a revision request
//! into the same structured plan for every presentation surface.

use crate::diff::{
    apply_exact_sarif_findings, apply_head_only_sarif_findings, apply_partial_coverage,
    apply_partial_mutation_kills, apply_partial_sarif_findings, apply_scoped_coverage,
    apply_scoped_mutation_kills, DiffPlan, EvidenceScopeFingerprint,
};
use crate::{GitProvider, Storage};
use anyhow::Result;

/// Read-only revision and evidence selection for one structured diff.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DiffRequest {
    pub base_revision: Option<String>,
    pub head_revision: Option<String>,
    pub coverage_source: Option<String>,
    pub sarif_source: Option<String>,
    pub selection: Option<String>,
    pub mutant_corpus: Option<String>,
    pub test_set: Option<String>,
}

/// Builds the revision-pinned plan consumed by both the React UI and CLI.
///
/// Passing no storage is intentional: Git-derived structure remains useful
/// when a repository has not yet ingested dynamic evidence.
pub fn build_structured_diff(
    provider: &GitProvider,
    storage: Option<&Storage>,
    request: &DiffRequest,
) -> Result<DiffPlan> {
    let (base, head) = provider.diff_revisions(
        request.base_revision.as_deref(),
        request.head_revision.as_deref(),
    )?;
    let mut plan = provider.diff_plan(&base, &head)?;
    bind_requested_evidence_scope(&mut plan, request)?;
    if let Some(storage) = storage {
        apply_known_coverage(storage, &mut plan, request.coverage_source.as_deref())?;
        apply_known_mutation_kills(storage, &mut plan)?;
        apply_known_sarif(storage, &mut plan, request.sarif_source.as_deref())?;
        apply_known_architecture(storage, &mut plan)?;
        apply_test_summaries(storage, &mut plan)?;
    }
    Ok(plan)
}

/// Compute the "Tests" section: for each changed test file, aggregate the base-
/// and head-commit test inventories (from `test_exposure_events`) and diff them
/// per `language:test_set`. Scoped to tests whose own file changed in this diff -
/// tests without a known definition file are excluded (can't attribute them).
fn apply_test_summaries(storage: &Storage, plan: &mut DiffPlan) -> Result<()> {
    use crate::diff::SourceRole;
    use std::collections::{BTreeMap, BTreeSet};
    let changed_test_files: BTreeSet<String> = plan
        .files
        .iter()
        .filter(|f| f.role == SourceRole::Test)
        .map(|f| f.path.clone())
        .collect();
    if changed_test_files.is_empty() {
        return Ok(());
    }
    let base_full = storage.test_inventory_for_commit(&plan.scope.base_oid)?;
    let head_full = storage.test_inventory_for_commit(&plan.scope.head_oid)?;
    let base_present = !base_full.is_empty();
    let scope = |rows: Vec<crate::test_summary::TestInventoryRow>| {
        rows.into_iter()
            .filter(|r| changed_test_files.contains(&r.test_path))
            .collect::<Vec<_>>()
    };
    let base = scope(base_full);
    let head = scope(head_full);
    // Lines the diff added inside each changed test file — a test whose span
    // contains one of these is "changed".
    let mut changed_lines: BTreeMap<String, BTreeSet<u32>> = BTreeMap::new();
    for file in &plan.files {
        if file.role == SourceRole::Test {
            changed_lines.insert(file.path.clone(), file.added_line_numbers());
        }
    }
    plan.test_summaries =
        crate::test_summary::test_summaries(&base, &head, &changed_lines, base_present);
    Ok(())
}

/// Attach newly-added collaboration targets and state accesses to each changed
/// group, sourced from the architecture graph ingested for the head commit. A
/// fact counts as *new* when its call/access site lands on an added line inside
/// the group's span. No graph ingested -> groups keep their empty defaults.
fn apply_known_architecture(storage: &Storage, plan: &mut DiffPlan) -> Result<()> {
    let sites =
        crate::architecture::architecture_fact_sites_for_commit(storage, &plan.scope.head_oid)?;
    if sites.is_empty() {
        return Ok(());
    }
    let mut by_path: std::collections::HashMap<&str, Vec<&_>> = std::collections::HashMap::new();
    for site in &sites {
        by_path.entry(site.path.as_str()).or_default().push(site);
    }
    use crate::architecture::FactKind;
    for file in &mut plan.files {
        let Some(file_sites) = by_path.get(file.path.as_str()) else {
            continue;
        };
        let added = file.added_line_numbers();
        // File-level imports: any import site on an added line.
        let mut imports = std::collections::BTreeSet::new();
        for site in file_sites {
            if site.kind == FactKind::Import && added.contains(&site.line) {
                imports.insert(site.label.clone());
            }
        }
        file.added_imports = imports.into_iter().collect();
        // Unit-level calls and state: sites on an added line inside a group span.
        for group in &mut file.groups {
            let mut deps = std::collections::BTreeSet::new();
            let mut state = std::collections::BTreeSet::new();
            for site in file_sites {
                if site.line < group.start_line
                    || site.line > group.end_line
                    || !added.contains(&site.line)
                {
                    continue;
                }
                match site.kind {
                    FactKind::Call => {
                        deps.insert(site.label.clone());
                    }
                    FactKind::State => {
                        state.insert(site.label.clone());
                    }
                    FactKind::Import => {}
                }
            }
            group.added_dependencies = deps.into_iter().collect();
            group.added_state = state.into_iter().collect();
        }
    }
    Ok(())
}

fn bind_requested_evidence_scope(plan: &mut DiffPlan, request: &DiffRequest) -> Result<()> {
    let supplied = [
        request.selection.as_ref(),
        request.mutant_corpus.as_ref(),
        request.test_set.as_ref(),
    ];
    if supplied.iter().any(|item| item.is_some()) && !supplied.iter().all(|item| item.is_some()) {
        anyhow::bail!("selection, mutant corpus, and test set must be supplied together");
    }
    let (Some(selection), Some(mutant_corpus), Some(test_set)) =
        (supplied[0], supplied[1], supplied[2])
    else {
        return Ok(());
    };
    if selection.trim().is_empty() || mutant_corpus.trim().is_empty() || test_set.trim().is_empty()
    {
        anyhow::bail!("selection, mutant corpus, and test set cannot be empty");
    }
    plan.scope.evidence_scope = EvidenceScopeFingerprint {
        revision: plan.scope.head_oid.clone(),
        selection: selection.clone(),
        mutant_corpus: mutant_corpus.clone(),
        test_set: test_set.clone(),
    };
    Ok(())
}

fn apply_known_coverage(
    storage: &Storage,
    plan: &mut DiffPlan,
    source: Option<&str>,
) -> Result<()> {
    let paths = changed_paths(plan);
    let source = source.unwrap_or("coverage");
    if let Some(artifact) =
        storage.scoped_coverage_artifact_common(source, &plan.scope.evidence_scope, &paths)?
    {
        apply_scoped_coverage(plan, &artifact);
        return Ok(());
    }
    let rows = storage.coverage_observations_for_commit_paths(&plan.scope.head_oid, &paths)?;
    apply_partial_coverage(plan, &rows);
    Ok(())
}

fn apply_known_mutation_kills(storage: &Storage, plan: &mut DiffPlan) -> Result<()> {
    let paths = changed_paths(plan);
    if let Some(artifact) = storage.scoped_mutation_artifact(&plan.scope.evidence_scope, &paths)? {
        apply_scoped_mutation_kills(plan, &artifact);
        return Ok(());
    }
    let rows = storage.mutation_kill_observations_for_commit_paths(&plan.scope.head_oid, &paths)?;
    apply_partial_mutation_kills(plan, &rows);
    Ok(())
}

fn apply_known_sarif(storage: &Storage, plan: &mut DiffPlan, source: Option<&str>) -> Result<()> {
    let paths = changed_paths(plan);
    if let Some(source) = source {
        if let Some(rows) =
            storage.scoped_sarif_observations_common(source, &plan.scope.evidence_scope, &paths)?
        {
            let base_scope = EvidenceScopeFingerprint {
                revision: plan.scope.base_oid.clone(),
                selection: plan.scope.evidence_scope.selection.clone(),
                mutant_corpus: "not-applicable".into(),
                test_set: plan.scope.evidence_scope.test_set.clone(),
            };
            let base_paths = plan
                .files
                .iter()
                .map(|file| {
                    file.previous_path
                        .clone()
                        .unwrap_or_else(|| file.path.clone())
                })
                .collect::<Vec<_>>();
            if let Some(base_rows) =
                storage.scoped_sarif_observations_common(source, &base_scope, &base_paths)?
            {
                apply_exact_sarif_findings(plan, &rows, &base_rows);
            } else {
                apply_head_only_sarif_findings(plan, &rows);
            }
            return Ok(());
        }
        if storage.has_scoped_sarif_source(source)? {
            plan.evidence.sarif = crate::diff::EvidenceState::Stale;
            plan.evidence.hazards = crate::diff::EvidenceState::Stale;
            return Ok(());
        }
    }
    let rows = storage.sarif_observations_for_commit_paths(&plan.scope.head_oid, &paths)?;
    apply_partial_sarif_findings(plan, &rows);
    Ok(())
}

fn changed_paths(plan: &DiffPlan) -> Vec<String> {
    plan.files.iter().map(|file| file.path.clone()).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn builds_a_revision_pinned_plan_without_a_database() {
        let directory = tempdir().unwrap();
        let repository = git2::Repository::init(directory.path()).unwrap();
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        let path = directory.path().join("app.rb");
        std::fs::write(&path, "puts :base\n").unwrap();
        let base = commit_file(&repository, &signature, None);
        std::fs::write(&path, "puts :head\n").unwrap();
        let head = commit_file(&repository, &signature, Some(base));
        let provider = GitProvider::open(directory.path()).unwrap();

        let plan = build_structured_diff(
            &provider,
            None,
            &DiffRequest {
                base_revision: Some(base.to_string()),
                head_revision: Some(head.to_string()),
                selection: Some("production".into()),
                mutant_corpus: Some("mutants".into()),
                test_set: Some("suite".into()),
                ..DiffRequest::default()
            },
        )
        .unwrap();

        assert_eq!(plan.scope.base_oid, base.to_string());
        assert_eq!(plan.scope.head_oid, head.to_string());
        assert_eq!(plan.scope.evidence_scope.revision, head.to_string());
        assert_eq!(plan.scope.evidence_scope.selection, "production");
        assert_eq!(plan.files.len(), 1);
        assert_eq!(plan.files[0].path, "app.rb");
        assert_eq!(plan.evidence.coverage, crate::diff::EvidenceState::Missing);
    }

    fn commit_file(
        repository: &git2::Repository,
        signature: &git2::Signature<'_>,
        parent: Option<git2::Oid>,
    ) -> git2::Oid {
        let mut index = repository.index().unwrap();
        index.add_path(std::path::Path::new("app.rb")).unwrap();
        let tree = repository.find_tree(index.write_tree().unwrap()).unwrap();
        let parent_commit = parent.map(|oid| repository.find_commit(oid).unwrap());
        let parents = parent_commit.iter().collect::<Vec<_>>();
        repository
            .commit(
                Some("HEAD"),
                signature,
                signature,
                "change app",
                &tree,
                &parents,
            )
            .unwrap()
    }
}
