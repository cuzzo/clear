use super::super::*;

pub(super) fn routes() -> Router<UiServerState> {
    Router::new()
        .route("/assets/*path", get(asset_handler))
        .route("/favicon.ico", get(favicon_handler))
}

async fn asset_handler(AxumPath(path): AxumPath<String>) -> Response<Body> {
    asset_response(path.trim_start_matches('/'))
}

pub(super) fn diff_index_response() -> Response<Body> {
    asset_response("diff/index.html")
}

fn asset_response(path: &str) -> Response<Body> {
    let embedded_path = embedded_asset_path(path);
    let Some(asset) = EmbeddedUi::get(&embedded_path) else {
        return StatusCode::NOT_FOUND.into_response();
    };
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, asset_content_type(&embedded_path))
        .header(header::CACHE_CONTROL, "no-store")
        .body(Body::from(asset.data.into_owned()))
        .unwrap_or_else(|_| StatusCode::INTERNAL_SERVER_ERROR.into_response())
}

async fn favicon_handler() -> Response<Body> {
    Response::builder()
        .status(StatusCode::NO_CONTENT)
        .header(header::CACHE_CONTROL, "public, max-age=86400")
        .body(Body::empty())
        .unwrap_or_else(|_| StatusCode::NO_CONTENT.into_response())
}

fn embedded_asset_path(path: &str) -> String {
    format!("assets/{}", path.trim_start_matches('/'))
}

fn asset_content_type(path: &str) -> &'static str {
    match Path::new(path)
        .extension()
        .and_then(|extension| extension.to_str())
    {
        Some("css") => "text/css; charset=utf-8",
        Some("js") => "text/javascript; charset=utf-8",
        Some("html") => "text/html; charset=utf-8",
        Some("json") => "application/json",
        Some("svg") => "image/svg+xml",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn embedded_asset_paths_resolve_css_and_js() {
        assert_eq!(embedded_asset_path("app.css"), "assets/app.css");
        assert_eq!(embedded_asset_path("/app.js"), "assets/app.js");
        assert!(EmbeddedUi::get(&embedded_asset_path("app.css")).is_some());
        assert!(EmbeddedUi::get(&embedded_asset_path("app.js")).is_some());
    }
}
