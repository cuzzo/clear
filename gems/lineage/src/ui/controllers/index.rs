use super::super::*;

pub(super) fn routes() -> Router<UiServerState> {
    Router::new()
        .route("/", get(index_handler))
        .route("/index.html", get(index_handler))
        .route("/api/files", get(api_files_handler))
        .route("/api/dashboard", get(api_dashboard_handler))
}

async fn index_handler(
    State(state): State<UiServerState>,
    Query(query): Query<IndexQuery>,
) -> Response<Body> {
    let storage = match Storage::open_existing(state.db.as_ref()) {
        Ok(storage) => storage,
        Err(error) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    let scope = CoverageScope::from_repo(state.repo.as_ref());
    let commit = query
        .commit
        .as_deref()
        .filter(|value| !value.is_empty() && *value != "current");
    let filter = query.q.as_deref().unwrap_or_default();
    let sort = query
        .sort
        .as_deref()
        .map(CoverageSort::parse)
        .unwrap_or(CoverageSort::Path);
    match render_index_page(
        &storage,
        state.repo.as_ref(),
        state.overlays.as_ref(),
        &scope,
        query.path.as_deref(),
        query.dir.as_deref(),
        commit,
        filter,
        sort,
        query.queue.as_deref(),
        query.page.unwrap_or(1),
    ) {
        Ok(body) => Html(body).into_response(),
        Err(error) => error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn api_files_handler(State(state): State<UiServerState>) -> Response<Body> {
    let storage = match Storage::open_existing(state.db.as_ref()) {
        Ok(storage) => storage,
        Err(error) => return error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    let scope = CoverageScope::from_repo(state.repo.as_ref());
    match file_index_with_scope(&storage, &scope, Some(state.repo.as_ref())) {
        Ok(files) => Json(files).into_response(),
        Err(error) => error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

async fn api_dashboard_handler(
    State(state): State<UiServerState>,
    Query(query): Query<DirectoryQuery>,
) -> Response<Body> {
    let storage = match Storage::open_existing(state.db.as_ref()) {
        Ok(storage) => storage,
        Err(error) => return error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    let scope = CoverageScope::from_repo(state.repo.as_ref());
    let directory = query.dir.as_deref().unwrap_or_default();
    match dashboard_summary_for_directory_with_scope_and_repo(
        &storage,
        directory,
        &scope,
        Some(state.repo.as_ref()),
    ) {
        Ok(dashboard) => Json(dashboard).into_response(),
        Err(error) => error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn index_directory_review_and_test_routes_build() {
        let _ = routes();
    }
}
