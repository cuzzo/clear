use super::super::*;

pub(super) fn routes() -> Router<UiServerState> {
    Router::new()
        .route("/api/source", get(api_source_handler))
        .route("/api/definition", get(api_definition_handler))
}

async fn api_source_handler(
    State(state): State<UiServerState>,
    Query(query): Query<SourceQuery>,
) -> Response<Body> {
    let Some(source_path) = query.path.as_deref() else {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({ "error": "missing path" })),
        )
            .into_response();
    };
    let storage = match Storage::open_existing(state.db.as_ref()) {
        Ok(storage) => storage,
        Err(error) => return error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    let commit = query
        .commit
        .as_deref()
        .filter(|value| !value.is_empty() && *value != "current");
    match source_payload_with_overlays(
        &storage,
        state.repo.as_ref(),
        source_path,
        commit,
        state.overlays.as_ref(),
    ) {
        Ok(payload) => Json(payload).into_response(),
        Err(error) => error_json(StatusCode::NOT_FOUND, error),
    }
}

async fn api_definition_handler(
    State(state): State<UiServerState>,
    Query(query): Query<DefinitionQuery>,
) -> Response<Body> {
    let storage = match Storage::open_existing(state.db.as_ref()) {
        Ok(storage) => storage,
        Err(error) => return error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    let commit = query.commit.as_deref().filter(|value| !value.is_empty() && *value != "current");
    match storage.find_definitions(&query.name, commit, query.path.as_deref()) {
        Ok(definitions) => {
            let results: Vec<DefinitionResult> = definitions
                .into_iter()
                .map(|(path, line)| DefinitionResult { path, line })
                .collect();
            Json(results).into_response()
        }
        Err(error) => error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_routes_build() {
        let _ = routes();
    }
}
