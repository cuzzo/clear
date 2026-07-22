use super::super::*;

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
}

#[derive(Debug, Deserialize)]
struct DiffFileQuery {
    base: Option<String>,
    head: Option<String>,
    path: Option<String>,
}

#[derive(Debug, Serialize)]
struct ApiEnvelope<T> {
    api_version: &'static str,
    data: T,
}

async fn diff_page_handler() -> Response<Body> {
    super::assets::diff_index_response()
}

async fn api_diff_plan_handler(
    State(state): State<UiServerState>,
    Query(query): Query<DiffQuery>,
) -> Response<Body> {
    let Some((base, head)) = revisions(query.base, query.head) else {
        return invalid_request("base and head revisions are required");
    };
    match GitProvider::open(state.repo.as_ref()).and_then(|repo| repo.diff_plan(&base, &head)) {
        Ok(mut plan) => {
            apply_known_coverage(&state, &mut plan);
            apply_known_mutation_kills(&state, &mut plan);
            Json(ApiEnvelope {
                api_version: crate::diff::DIFF_API_VERSION,
                data: plan,
            })
            .into_response()
        }
        Err(error) => error_json(StatusCode::BAD_REQUEST, error),
    }
}

fn apply_known_coverage(state: &UiServerState, plan: &mut crate::diff::DiffPlan) {
    if !state.db.exists() {
        return;
    }
    let Ok(storage) = crate::storage::Storage::open_existing(state.db.as_ref()) else {
        return;
    };
    let paths = plan
        .files
        .iter()
        .map(|file| file.path.clone())
        .collect::<Vec<_>>();
    let Ok(rows) = storage.coverage_observations_for_commit_paths(&plan.scope.head_oid, &paths)
    else {
        return;
    };
    crate::diff::apply_partial_coverage(plan, &rows);
}

fn apply_known_mutation_kills(state: &UiServerState, plan: &mut crate::diff::DiffPlan) {
    if !state.db.exists() {
        return;
    }
    let Ok(storage) = crate::storage::Storage::open_existing(state.db.as_ref()) else {
        return;
    };
    let paths = plan
        .files
        .iter()
        .map(|file| file.path.clone())
        .collect::<Vec<_>>();
    let Ok(rows) =
        storage.mutation_kill_observations_for_commit_paths(&plan.scope.head_oid, &paths)
    else {
        return;
    };
    crate::diff::apply_partial_mutation_kills(plan, &rows);
}

async fn api_diff_file_handler(
    State(state): State<UiServerState>,
    Query(query): Query<DiffFileQuery>,
) -> Response<Body> {
    let Some((base, head)) = revisions(query.base, query.head) else {
        return invalid_request("base and head revisions are required");
    };
    let Some(path) = query.path.filter(|path| !path.is_empty()) else {
        return invalid_request("path is required");
    };
    match GitProvider::open(state.repo.as_ref()).and_then(|repo| repo.diff_plan(&base, &head)) {
        Ok(mut plan) => {
            apply_known_coverage(&state, &mut plan);
            apply_known_mutation_kills(&state, &mut plan);
            match plan.files.into_iter().find(|file| file.path == path) {
                Some(file) => Json(ApiEnvelope {
                    api_version: crate::diff::DIFF_API_VERSION,
                    data: file,
                })
                .into_response(),
                None => StatusCode::NOT_FOUND.into_response(),
            }
        }
        Err(error) => error_json(StatusCode::BAD_REQUEST, error),
    }
}

fn revisions(base: Option<String>, head: Option<String>) -> Option<(String, String)> {
    let base = base.filter(|revision| !revision.trim().is_empty())?;
    let head = head.filter(|revision| !revision.trim().is_empty())?;
    Some((base, head))
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
    fn revision_queries_require_two_nonblank_revisions() {
        assert_eq!(
            revisions(Some("base".into()), Some("head".into())),
            Some(("base".into(), "head".into()))
        );
        assert_eq!(revisions(Some(" ".into()), Some("head".into())), None);
        assert_eq!(revisions(Some("base".into()), None), None);
    }

    #[test]
    fn diff_routes_build() {
        let _ = routes();
    }

    fn test_state() -> (tempfile::TempDir, UiServerState, String, String) {
        let dir = tempdir().unwrap();
        let repo = git2::Repository::init(dir.path()).unwrap();
        let signature = git2::Signature::now("Lineage", "lineage@example.test").unwrap();
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
            db: Arc::new(dir.path().join("lineage.db")),
            repo: Arc::new(dir.path().to_path_buf()),
            overlays: Arc::new(UiOverlays::default()),
        };
        (dir, state, base, head)
    }

    #[tokio::test]
    async fn plan_and_file_apis_use_the_same_revision_pinned_plan() {
        let (_dir, state, base, head) = test_state();
        let response = api_diff_plan_handler(
            State(state.clone()),
            Query(DiffQuery {
                base: Some(base.clone()),
                head: Some(head.clone()),
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
            }),
        )
        .await;
        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
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
}
