use super::super::*;
use crate::{build_structured_diff, DiffRequest};
use axum::response::Redirect;

pub(super) fn routes() -> Router<UiServerState> {
    Router::new()
        .route("/diff", get(diff_page_handler))
        .route("/api/diff/plan", get(api_diff_plan_handler))
        .route("/api/diff/file", get(api_diff_file_handler))
}

#[derive(Debug, Deserialize)]
struct DiffQuery {
    base: Option<String>,
    head: Option<String>,
    coverage_source: Option<String>,
    sarif_source: Option<String>,
    selection: Option<String>,
    mutant_corpus: Option<String>,
    test_set: Option<String>,
    page: Option<usize>,
    path: Option<String>,
}

#[derive(Debug, Deserialize)]
struct DiffPageQuery {
    base: Option<String>,
    head: Option<String>,
    presentation: Option<String>,
    layout: Option<String>,
    path: Option<String>,
    focus: Option<String>,
    group: Option<String>,
    coverage_source: Option<String>,
    sarif_source: Option<String>,
    selection: Option<String>,
    mutant_corpus: Option<String>,
    test_set: Option<String>,
    page: Option<usize>,
}

#[derive(Debug, Deserialize)]
struct DiffFileQuery {
    base: Option<String>,
    head: Option<String>,
    path: Option<String>,
    coverage_source: Option<String>,
    sarif_source: Option<String>,
    selection: Option<String>,
    mutant_corpus: Option<String>,
    test_set: Option<String>,
}

#[derive(Debug, Serialize)]
struct ApiEnvelope<T> {
    api_version: &'static str,
    data: T,
}

async fn diff_page_handler(
    State(state): State<UiServerState>,
    Query(query): Query<DiffPageQuery>,
) -> Response<Body> {
    let result = GitProvider::open(state.repo.as_ref())
        .and_then(|repo| repo.diff_revisions(query.base.as_deref(), query.head.as_deref()));
    match result {
        Ok((base, head)) if requires_canonical_redirect(&query, &base, &head) => {
            Redirect::temporary(&canonical_diff_location(&query, &base, &head)).into_response()
        }
        Ok(_) => super::assets::diff_index_response(),
        Err(error) => error_json(StatusCode::BAD_REQUEST, error),
    }
}

async fn api_diff_plan_handler(
    State(state): State<UiServerState>,
    Query(query): Query<DiffQuery>,
) -> Response<Body> {
    let request = diff_request(
        query.base.clone(),
        query.head.clone(),
        query.coverage_source.clone(),
        query.sarif_source.clone(),
        query.selection.clone(),
        query.mutant_corpus.clone(),
        query.test_set.clone(),
    );
    let result = build_ui_diff(&state, &request);
    match result {
        Ok(mut plan) => {
            crate::diff::retain_plan_sources_for_page(&mut plan, query.page, query.path.as_deref());
            Json(ApiEnvelope {
                api_version: crate::diff::DIFF_API_VERSION,
                data: plan,
            })
            .into_response()
        }
        Err(error) => error_json(StatusCode::BAD_REQUEST, error),
    }
}

fn diff_request(
    base_revision: Option<String>,
    head_revision: Option<String>,
    coverage_source: Option<String>,
    sarif_source: Option<String>,
    selection: Option<String>,
    mutant_corpus: Option<String>,
    test_set: Option<String>,
) -> DiffRequest {
    DiffRequest {
        base_revision,
        head_revision,
        coverage_source,
        sarif_source,
        selection,
        mutant_corpus,
        test_set,
    }
}

fn build_ui_diff(
    state: &UiServerState,
    request: &DiffRequest,
) -> anyhow::Result<crate::diff::DiffPlan> {
    let provider = GitProvider::open(state.repo.as_ref())?;
    let storage = state
        .db
        .exists()
        .then(|| crate::storage::Storage::open_existing(state.db.as_ref()))
        .transpose()?;
    build_structured_diff(&provider, storage.as_ref(), request)
}

async fn api_diff_file_handler(
    State(state): State<UiServerState>,
    Query(query): Query<DiffFileQuery>,
) -> Response<Body> {
    let Some(path) = query.path.filter(|path| !path.is_empty()) else {
        return invalid_request("path is required");
    };
    let request = diff_request(
        query.base,
        query.head,
        query.coverage_source,
        query.sarif_source,
        query.selection,
        query.mutant_corpus,
        query.test_set,
    );
    let result = build_ui_diff(&state, &request);
    match result {
        Ok(plan) => match plan.files.into_iter().find(|file| file.path == path) {
            Some(file) => Json(ApiEnvelope {
                api_version: crate::diff::DIFF_API_VERSION,
                data: file,
            })
            .into_response(),
            None => StatusCode::NOT_FOUND.into_response(),
        },
        Err(error) => error_json(StatusCode::BAD_REQUEST, error),
    }
}

fn requires_canonical_redirect(query: &DiffPageQuery, base: &str, head: &str) -> bool {
    query.base.as_deref() != Some(base) || query.head.as_deref() != Some(head)
}

fn canonical_diff_location(query: &DiffPageQuery, base: &str, head: &str) -> String {
    let mut output = vec![("base", base.to_string()), ("head", head.to_string())];
    for (name, value) in [
        ("presentation", query.presentation.as_deref()),
        ("layout", query.layout.as_deref()),
        ("path", query.path.as_deref()),
        ("focus", query.focus.as_deref()),
        ("group", query.group.as_deref()),
        ("coverage_source", query.coverage_source.as_deref()),
        ("sarif_source", query.sarif_source.as_deref()),
        ("selection", query.selection.as_deref()),
        ("mutant_corpus", query.mutant_corpus.as_deref()),
        ("test_set", query.test_set.as_deref()),
    ] {
        if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
            output.push((name, value.to_string()));
        }
    }
    if let Some(page) = query.page.filter(|page| *page > 1) {
        output.push(("page", page.to_string()));
    }
    let mut serializer = url::form_urlencoded::Serializer::new(String::new());
    for (name, value) in output {
        serializer.append_pair(name, &value);
    }
    format!("/diff?{}", serializer.finish())
}

fn invalid_request(message: &str) -> Response<Body> {
    (
        StatusCode::BAD_REQUEST,
        Json(serde_json::json!({ "error": message })),
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::body::to_bytes;
    use tempfile::tempdir;

    #[test]
    fn canonical_locations_pin_oids_and_preserve_view_options() {
        let query = DiffPageQuery {
            base: Some("HEAD".into()),
            head: None,
            presentation: Some("raw".into()),
            layout: Some("inline".into()),
            path: Some("lib/app.rb".into()),
            focus: Some("residual".into()),
            group: Some("lib/app.rb:function:run:1".into()),
            coverage_source: Some("coverage:ci".into()),
            sarif_source: Some("scanner".into()),
            selection: Some("production".into()),
            mutant_corpus: Some("mutants".into()),
            test_set: Some("suite".into()),
            page: Some(2),
        };
        assert!(requires_canonical_redirect(&query, "a", "b"));
        assert_eq!(
            canonical_diff_location(&query, "a", "b"),
            "/diff?base=a&head=b&presentation=raw&layout=inline&path=lib%2Fapp.rb&focus=residual&group=lib%2Fapp.rb%3Afunction%3Arun%3A1&coverage_source=coverage%3Aci&sarif_source=scanner&selection=production&mutant_corpus=mutants&test_set=suite&page=2"
        );
    }

    #[test]
    fn diff_routes_build() {
        let _ = routes();
    }

    fn test_state() -> (tempfile::TempDir, UiServerState, String, String) {
        let dir = tempdir().unwrap();
        let repo = git2::Repository::init(dir.path()).unwrap();
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        std::fs::write(dir.path().join("app.rb"), "puts :base\n").unwrap();
        let mut index = repo.index().unwrap();
        index.add_path(std::path::Path::new("app.rb")).unwrap();
        let tree = repo.find_tree(index.write_tree().unwrap()).unwrap();
        let base = repo
            .commit(Some("HEAD"), &signature, &signature, "base", &tree, &[])
            .unwrap()
            .to_string();
        std::fs::write(dir.path().join("app.rb"), "puts :head\n").unwrap();
        let mut index = repo.index().unwrap();
        index.add_path(std::path::Path::new("app.rb")).unwrap();
        let tree = repo.find_tree(index.write_tree().unwrap()).unwrap();
        let parent = repo.head().unwrap().peel_to_commit().unwrap();
        let head = repo
            .commit(
                Some("HEAD"),
                &signature,
                &signature,
                "head",
                &tree,
                &[&parent],
            )
            .unwrap()
            .to_string();
        let state = UiServerState {
            db: Arc::new(dir.path().join("gigasail.db")),
            repo: Arc::new(dir.path().to_path_buf()),
            overlays: Arc::new(UiOverlays::default()),
        };
        (dir, state, base, head)
    }

    fn large_test_state() -> (tempfile::TempDir, UiServerState, String, String) {
        let dir = tempdir().unwrap();
        let repo = git2::Repository::init(dir.path()).unwrap();
        let signature = git2::Signature::now("Gigasail", "gigasail@example.test").unwrap();
        let mut index = repo.index().unwrap();
        for number in 0..=crate::diff::DIFF_FILE_PAGE_SIZE {
            let path = format!("app-{number:03}.rb");
            std::fs::write(dir.path().join(&path), "puts :base\n").unwrap();
            index.add_path(std::path::Path::new(&path)).unwrap();
        }
        let tree = repo.find_tree(index.write_tree().unwrap()).unwrap();
        let base = repo
            .commit(Some("HEAD"), &signature, &signature, "base", &tree, &[])
            .unwrap()
            .to_string();
        let mut index = repo.index().unwrap();
        for number in 0..=crate::diff::DIFF_FILE_PAGE_SIZE {
            let path = format!("app-{number:03}.rb");
            std::fs::write(dir.path().join(&path), "puts :head\n").unwrap();
            index.add_path(std::path::Path::new(&path)).unwrap();
        }
        let tree = repo.find_tree(index.write_tree().unwrap()).unwrap();
        let parent = repo.head().unwrap().peel_to_commit().unwrap();
        let head = repo
            .commit(
                Some("HEAD"),
                &signature,
                &signature,
                "head",
                &tree,
                &[&parent],
            )
            .unwrap()
            .to_string();
        let state = UiServerState {
            db: Arc::new(dir.path().join("gigasail.db")),
            repo: Arc::new(dir.path().to_path_buf()),
            overlays: Arc::new(UiOverlays::default()),
        };
        (dir, state, base, head)
    }

    #[tokio::test]
    async fn diff_page_redirects_default_pair_to_head_and_worktree() {
        let (_dir, state, _base, head) = test_state();
        let response = diff_page_handler(
            State(state),
            Query(DiffPageQuery {
                base: None,
                head: None,
                presentation: Some("semantic".into()),
                layout: None,
                path: None,
                focus: None,
                group: None,
                coverage_source: None,
                sarif_source: None,
                selection: None,
                mutant_corpus: None,
                test_set: None,
                page: None,
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::TEMPORARY_REDIRECT);
        assert_eq!(
            response
                .headers()
                .get(axum::http::header::LOCATION)
                .unwrap()
                .to_str()
                .unwrap(),
            format!("/diff?base={head}&head=WORKTREE&presentation=semantic")
        );
    }

    #[tokio::test]
    async fn plan_and_file_apis_use_the_same_revision_pinned_plan() {
        let (_dir, state, base, head) = test_state();
        let response = api_diff_plan_handler(
            State(state.clone()),
            Query(DiffQuery {
                base: Some(base.clone()),
                head: Some(head.clone()),
                coverage_source: None,
                sarif_source: None,
                selection: None,
                mutant_corpus: None,
                test_set: None,
                page: None,
                path: None,
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let response = api_diff_file_handler(
            State(state.clone()),
            Query(DiffFileQuery {
                base: Some(base),
                head: Some(head),
                path: Some("app.rb".into()),
                coverage_source: None,
                sarif_source: None,
                selection: None,
                mutant_corpus: None,
                test_set: None,
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::OK);
        let response = api_diff_file_handler(
            State(state),
            Query(DiffFileQuery {
                base: None,
                head: None,
                path: None,
                coverage_source: None,
                sarif_source: None,
                selection: None,
                mutant_corpus: None,
                test_set: None,
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
    }

    #[tokio::test]
    async fn plan_api_bounds_source_blobs_to_the_requested_file_page() {
        let (_dir, state, base, head) = large_test_state();
        let response = api_diff_plan_handler(
            State(state),
            Query(DiffQuery {
                base: Some(base),
                head: Some(head),
                coverage_source: None,
                sarif_source: None,
                selection: None,
                mutant_corpus: None,
                test_set: None,
                page: Some(2),
                path: None,
            }),
        )
        .await;
        let json: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap())
                .unwrap();
        let files = json
            .pointer("/data/files")
            .and_then(serde_json::Value::as_array)
            .unwrap();
        assert_eq!(files.len(), crate::diff::DIFF_FILE_PAGE_SIZE + 1);
        assert_eq!(
            files
                .iter()
                .filter(|file| file
                    .get("head_source")
                    .is_some_and(|source| !source.is_null()))
                .count(),
            1
        );
    }

    #[tokio::test]
    async fn plan_api_marks_commit_matching_coverage_as_partial_evidence() {
        let (_dir, state, base, head) = test_state();
        let storage = crate::storage::Storage::open(state.db.as_ref()).unwrap();
        storage
            .record_coverage_line_with_source(&head, 1, "app.rb", 1, 1, false, "test")
            .unwrap();

        let response = api_diff_plan_handler(
            State(state),
            Query(DiffQuery {
                base: Some(base),
                head: Some(head),
                coverage_source: None,
                sarif_source: None,
                selection: None,
                mutant_corpus: None,
                test_set: None,
                page: None,
                path: None,
            }),
        )
        .await;
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            json.pointer("/data/evidence/coverage")
                .and_then(|value| value.as_str()),
            Some("partial")
        );
        assert_eq!(
            json.pointer("/data/files/0/verification/covered")
                .and_then(|value| value.as_u64()),
            Some(1)
        );
        assert_eq!(
            json.pointer("/data/files/0/verification/not_covered")
                .and_then(|value| value.as_u64()),
            Some(0)
        );
    }

    #[tokio::test]
    async fn plan_api_uses_complete_requested_coverage_scope_for_negative_evidence() {
        let (_dir, state, base, head) = test_state();
        let storage = crate::storage::Storage::open(state.db.as_ref()).unwrap();
        storage
            .record_coverage_line_with_source(&head, 1, "app.rb", 1, 0, false, "complete")
            .unwrap();
        storage
            .record_evidence_artifact_scope(&crate::storage::EvidenceArtifactScope {
                family: "coverage".into(),
                source: "complete".into(),
                scope: crate::diff::EvidenceScopeFingerprint {
                    revision: head.clone(),
                    selection: "all-production".into(),
                    mutant_corpus: "mutants-1".into(),
                    test_set: "tests-1".into(),
                },
                complete: true,
                expected_lines: [("app.rb".into(), 1)].into_iter().collect(),
            })
            .unwrap();

        let response = api_diff_plan_handler(
            State(state),
            Query(DiffQuery {
                base: Some(base),
                head: Some(head),
                coverage_source: Some("complete".into()),
                sarif_source: None,
                selection: Some("all-production".into()),
                mutant_corpus: Some("mutants-1".into()),
                test_set: Some("tests-1".into()),
                page: None,
                path: None,
            }),
        )
        .await;
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            json.pointer("/data/evidence/coverage")
                .and_then(|value| value.as_str()),
            Some("exact")
        );
        assert_eq!(
            json.pointer("/data/files/0/verification/not_covered")
                .and_then(|value| value.as_u64()),
            Some(1)
        );
    }

    #[tokio::test]
    async fn plan_api_uses_only_complete_scoped_mutation_corpora_as_exact_evidence() {
        let (_dir, state, base, head) = test_state();
        let storage = crate::storage::Storage::open(state.db.as_ref()).unwrap();
        let unit = crate::model::LogicalUnit::new(
            "app",
            crate::model::UnitKind::Function,
            "app.rb",
            1,
            1,
            1,
            "puts :head",
            "puts :head\n",
        );
        storage.upsert_logical_unit(&unit, 1).unwrap();
        storage
            .insert_test_exposure_event(&crate::model::TestExposureEvent {
                unit_id: unit.id,
                commit_hash: head.clone(),
                timestamp: 1,
                path: "app.rb".into(),
                function: Some("app".into()),
                line: Some(1),
                branch_id: None,
                test_id: "mutant:app".into(),
                test_type: "unit".into(),
                mutation_status: Some("killed".into()),
                mutation_kind: Some("stochastic".into()),
                mutation_corpus: "mutants-v1".into(),
                is_mutation_verified: true,
                is_mutation_killed: true,
                is_verified: true,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .record_evidence_artifact_scope(&crate::storage::EvidenceArtifactScope {
                family: "mutation".into(),
                source: "mutants-v1".into(),
                scope: crate::diff::EvidenceScopeFingerprint {
                    revision: head.clone(),
                    selection: "production".into(),
                    mutant_corpus: "mutants-v1".into(),
                    test_set: "suite-v1".into(),
                },
                complete: true,
                expected_lines: [("app.rb".into(), 1)].into_iter().collect(),
            })
            .unwrap();
        storage
            .record_coverage_line_with_source(&head, 1, "app.rb", 1, 1, false, "legacy")
            .unwrap();

        let response = api_diff_plan_handler(
            State(state),
            Query(DiffQuery {
                base: Some(base),
                head: Some(head),
                coverage_source: None,
                sarif_source: None,
                selection: Some("production".into()),
                mutant_corpus: Some("mutants-v1".into()),
                test_set: Some("suite-v1".into()),
                page: None,
                path: None,
            }),
        )
        .await;
        let json: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap())
                .unwrap();
        assert_eq!(
            json.pointer("/data/evidence/mutation")
                .and_then(|value| value.as_str()),
            Some("exact")
        );
        assert_eq!(
            json.pointer("/data/files/0/verification/covered_and_killed")
                .and_then(|value| value.as_u64()),
            Some(1)
        );
    }

    #[tokio::test]
    async fn plan_api_attaches_only_head_matching_sarif_as_partial_evidence() {
        let (_dir, state, base, head) = test_state();
        let storage = crate::storage::Storage::open(state.db.as_ref()).unwrap();
        let artifact_id = storage
            .insert_sarif_artifact(&crate::model::SarifArtifact {
                source: "scanner".into(),
                tool_name: "Scanner".into(),
                run_format: "sarif".into(),
                artifact_path: "scan.sarif#0".into(),
                artifact_sha256: "head".into(),
                commit_hash: head.clone(),
                timestamp: 1,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_sarif_finding(&crate::model::SarifFinding {
                artifact_id,
                finding_key: "head-finding".into(),
                source: "scanner".into(),
                tool_name: "Scanner".into(),
                run_format: "sarif".into(),
                commit_hash: head.clone(),
                timestamp: 1,
                rule_id: "scanner.rule".into(),
                level: "warning".into(),
                message: "head finding".into(),
                path: "app.rb".into(),
                start_line: 1,
                start_column: None,
                end_line: None,
                end_column: None,
                category: "hazard".into(),
                is_dark_arm: false,
                unit_id: None,
                fingerprint: "head-finding".into(),
                properties_json: "{}".into(),
                raw_json: "{}".into(),
            })
            .unwrap();

        let response = api_diff_plan_handler(
            State(state),
            Query(DiffQuery {
                base: Some(base),
                head: Some(head),
                coverage_source: None,
                sarif_source: None,
                selection: None,
                mutant_corpus: None,
                test_set: None,
                page: None,
                path: None,
            }),
        )
        .await;
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        let json: serde_json::Value = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(
            json.pointer("/data/evidence/sarif")
                .and_then(|value| value.as_str()),
            Some("partial")
        );
        assert_eq!(
            json.pointer("/data/files/0/sarif_findings/0/message")
                .and_then(|value| value.as_str()),
            Some("head finding")
        );
        assert_eq!(
            json.pointer("/data/files/0/risk/tier_one_hazards")
                .and_then(|value| value.as_u64()),
            Some(0)
        );
    }

    #[tokio::test]
    async fn plan_api_uses_complete_scoped_sarif_for_new_tier_one_risk() {
        let (_dir, state, base, head) = test_state();
        let storage = crate::storage::Storage::open(state.db.as_ref()).unwrap();
        let artifact_id = storage
            .insert_sarif_artifact(&crate::model::SarifArtifact {
                source: "scanner".into(),
                tool_name: "Scanner".into(),
                run_format: "sarif".into(),
                artifact_path: "scan.sarif#0".into(),
                artifact_sha256: "head".into(),
                commit_hash: head.clone(),
                timestamp: 1,
                payload_json: "{}".into(),
            })
            .unwrap();
        storage
            .insert_sarif_finding(&crate::model::SarifFinding {
                artifact_id,
                finding_key: "new-finding".into(),
                source: "scanner".into(),
                tool_name: "Scanner".into(),
                run_format: "sarif".into(),
                commit_hash: head.clone(),
                timestamp: 1,
                rule_id: "scanner.rule".into(),
                level: "warning".into(),
                message: "new tier one finding".into(),
                path: "app.rb".into(),
                start_line: 1,
                start_column: None,
                end_line: None,
                end_column: None,
                category: "hazard".into(),
                is_dark_arm: false,
                unit_id: None,
                fingerprint: "new-finding".into(),
                properties_json: "{\"tier\":1}".into(),
                raw_json: "{}".into(),
            })
            .unwrap();
        storage
            .record_evidence_artifact_scope(&crate::storage::EvidenceArtifactScope {
                family: "sarif".into(),
                source: "scanner".into(),
                scope: crate::diff::EvidenceScopeFingerprint {
                    revision: head.clone(),
                    selection: "production".into(),
                    mutant_corpus: "mutants".into(),
                    test_set: "suite".into(),
                },
                complete: true,
                expected_lines: Default::default(),
            })
            .unwrap();
        storage
            .record_evidence_artifact_scope(&crate::storage::EvidenceArtifactScope {
                family: "sarif".into(),
                source: "scanner".into(),
                scope: crate::diff::EvidenceScopeFingerprint {
                    revision: base.clone(),
                    selection: "production".into(),
                    mutant_corpus: "mutants".into(),
                    test_set: "suite".into(),
                },
                complete: true,
                expected_lines: Default::default(),
            })
            .unwrap();
        let response = api_diff_plan_handler(
            State(state),
            Query(DiffQuery {
                base: Some(base),
                head: Some(head),
                coverage_source: None,
                sarif_source: Some("scanner".into()),
                selection: Some("production".into()),
                mutant_corpus: Some("mutants".into()),
                test_set: Some("suite".into()),
                page: None,
                path: None,
            }),
        )
        .await;
        let json: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap())
                .unwrap();
        assert_eq!(
            json.pointer("/data/evidence/sarif")
                .and_then(|value| value.as_str()),
            Some("exact")
        );
        assert_eq!(
            json.pointer("/data/files/0/risk/tier_one_hazards")
                .and_then(|value| value.as_u64()),
            Some(1)
        );
        assert_eq!(
            json.pointer("/data/files/0/sarif_findings/0/status")
                .and_then(|value| value.as_str()),
            Some("new")
        );
        assert_eq!(
            json.pointer("/data/files/0/sarif_findings/0/category")
                .and_then(|value| value.as_str()),
            Some("hazard")
        );
        assert_eq!(
            json.pointer("/data/files/0/sarif_findings/0/tier")
                .and_then(|value| value.as_u64()),
            Some(1)
        );
    }

    #[tokio::test]
    async fn plan_api_marks_incompatible_scoped_sarif_as_stale() {
        let (_dir, state, base, head) = test_state();
        let storage = crate::storage::Storage::open(state.db.as_ref()).unwrap();
        storage
            .record_evidence_artifact_scope(&crate::storage::EvidenceArtifactScope {
                family: "sarif".into(),
                source: "scanner".into(),
                scope: crate::diff::EvidenceScopeFingerprint {
                    revision: "another-commit".into(),
                    selection: "production".into(),
                    mutant_corpus: "mutants".into(),
                    test_set: "suite".into(),
                },
                complete: true,
                expected_lines: Default::default(),
            })
            .unwrap();
        let response = api_diff_plan_handler(
            State(state),
            Query(DiffQuery {
                base: Some(base),
                head: Some(head),
                coverage_source: None,
                sarif_source: Some("scanner".into()),
                selection: Some("production".into()),
                mutant_corpus: Some("mutants".into()),
                test_set: Some("suite".into()),
                page: None,
                path: None,
            }),
        )
        .await;
        let json: serde_json::Value =
            serde_json::from_slice(&to_bytes(response.into_body(), usize::MAX).await.unwrap())
                .unwrap();
        assert_eq!(
            json.pointer("/data/evidence/sarif")
                .and_then(|value| value.as_str()),
            Some("stale")
        );
    }
}
