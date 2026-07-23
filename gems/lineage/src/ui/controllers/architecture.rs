use super::super::*;

pub(super) fn routes() -> Router<UiServerState> {
    Router::new()
        .route(
            "/api/architecture/owners/:owner_id",
            get(api_architecture_owner_handler),
        )
        .route(
            "/api/architecture/functions/:node_id/neighborhood",
            get(api_architecture_neighborhood_handler),
        )
        .route(
            "/api/architecture/state/:state_id/access",
            get(api_architecture_state_handler),
        )
        .route(
            "/api/architecture/search",
            get(api_architecture_search_handler),
        )
        .route(
            "/architecture/unit/:node_id",
            get(architecture_page_handler),
        )
        .route(
            "/architecture/state/:node_id",
            get(architecture_page_handler),
        )
}

async fn api_architecture_owner_handler(
    State(state): State<UiServerState>,
    AxumPath(owner_id): AxumPath<String>,
) -> Response<Body> {
    architecture_json_response(&state, |storage| owner_inventory(storage, &owner_id))
}

async fn api_architecture_neighborhood_handler(
    State(state): State<UiServerState>,
    AxumPath(node_id): AxumPath<String>,
    Query(query): Query<ArchitecturePageQuery>,
) -> Response<Body> {
    let limit = query.limit.unwrap_or(40).clamp(1, 100);
    architecture_json_response(&state, |storage| {
        node_neighborhood(storage, &node_id, limit)
    })
}

async fn api_architecture_state_handler(
    State(state): State<UiServerState>,
    AxumPath(state_id): AxumPath<String>,
) -> Response<Body> {
    architecture_json_response(&state, |storage| state_access(storage, &state_id))
}

async fn api_architecture_search_handler(
    State(state): State<UiServerState>,
    Query(query): Query<ArchitectureSearchQuery>,
) -> Response<Body> {
    architecture_json_response(&state, |storage| {
        architecture_search(
            storage,
            query.owner.as_deref(),
            query.q.as_deref().unwrap_or_default(),
        )
    })
}

fn architecture_json_response(
    state: &UiServerState,
    operation: impl FnOnce(&Storage) -> Result<Value>,
) -> Response<Body> {
    let storage = match Storage::open_existing(state.db.as_ref()) {
        Ok(storage) => storage,
        Err(error) => return error_json(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    match operation(&storage) {
        Ok(mut value) => {
            annotate_architecture_freshness(&mut value, state.repo.as_ref());
            Json(value).into_response()
        }
        Err(error) => error_json(StatusCode::NOT_FOUND, error),
    }
}

async fn architecture_page_handler(
    State(state): State<UiServerState>,
    AxumPath(node_id): AxumPath<String>,
    Query(query): Query<ArchitecturePageQuery>,
) -> Response<Body> {
    let storage = match Storage::open_existing(state.db.as_ref()) {
        Ok(storage) => storage,
        Err(error) => return error_response(StatusCode::INTERNAL_SERVER_ERROR, error),
    };
    let mut neighborhood =
        match node_neighborhood(&storage, &node_id, query.limit.unwrap_or(40).clamp(1, 100)) {
            Ok(value) => value,
            Err(error) => return error_response(StatusCode::NOT_FOUND, error),
        };
    annotate_architecture_freshness(&mut neighborhood, state.repo.as_ref());
    let selected = &neighborhood["selected"];
    let owner_id = selected
        .get("owner_id")
        .and_then(Value::as_str)
        .unwrap_or(&node_id);
    let inventory = owner_inventory(&storage, owner_id)
        .unwrap_or_else(|_| json!({"owner": selected, "members": []}));
    Html(render_architecture_page(
        &inventory,
        &neighborhood,
        query.lens.as_deref().unwrap_or("combined"),
    ))
    .into_response()
}

fn annotate_architecture_freshness(value: &mut Value, repo: &Path) {
    let current = Repository::open(repo).ok().and_then(|repository| {
        repository
            .head()
            .ok()
            .and_then(|head| head.target())
            .map(|oid| oid.to_string())
    });
    let artifact_commit = value
        .pointer("/artifact/commit")
        .and_then(Value::as_str)
        .unwrap_or("");
    let stale = current
        .as_deref()
        .is_some_and(|commit| !artifact_commit.is_empty() && commit != artifact_commit);
    if let Some(artifact) = value.get_mut("artifact") {
        artifact["current_commit"] = json!(current);
        artifact["stale"] = json!(stale);
    }
}

fn render_architecture_page(inventory: &Value, neighborhood: &Value, lens: &str) -> String {
    let owner = &inventory["owner"];
    let selected = &neighborhood["selected"];
    let owner_name = owner
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("Architecture");
    let selected_name = selected.get("name").and_then(Value::as_str).unwrap_or("");
    let members = inventory
        .get("members")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let mut edges = neighborhood
        .get("edges")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let omitted = neighborhood
        .get("omitted_relationships")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let all_edges = edges
        .iter()
        .chain(omitted.iter())
        .cloned()
        .collect::<Vec<_>>();
    edges.retain(|edge| architecture_edge_in_lens(edge, lens));
    let nodes = neighborhood
        .get("nodes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    let commit = neighborhood
        .pointer("/artifact/commit")
        .and_then(Value::as_str)
        .unwrap_or("");

    let mut out = String::new();
    out.push_str("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    out.push_str("<title>");
    out.push_str(&html_escape(owner_name));
    out.push_str(" architecture</title><link rel=\"stylesheet\" href=\"/assets/app.css\">");
    out.push_str("</head><body class=\"architecture-page\"><main class=\"architecture-shell\">");
    out.push_str("<header class=\"architecture-header\"><div><a href=\"/\">← Lineage</a><h1>");
    out.push_str(&html_escape(owner_name));
    out.push_str("</h1><p>");
    out.push_str(&html_escape(
        owner.get("path").and_then(Value::as_str).unwrap_or(""),
    ));
    out.push_str("</p></div><div><strong>Focused: ");
    out.push_str(&html_escape(selected_name));
    out.push_str("</strong><small>artifact ");
    out.push_str(&html_escape(&short_hash(commit)));
    out.push_str("</small></div></header>");
    if neighborhood
        .pointer("/artifact/stale")
        .and_then(Value::as_bool)
        == Some(true)
    {
        out.push_str("<div class=\"architecture-stale\" role=\"status\"><strong>Architecture artifact is stale.</strong> Regenerate it for the currently viewed commit.</div>");
    }
    out.push_str("<nav class=\"architecture-lenses\" aria-label=\"Architecture lens\">");
    for candidate in ["combined", "calls", "state", "risk"] {
        out.push_str("<a href=\"?lens=");
        out.push_str(candidate);
        out.push_str("\" class=\"");
        if candidate == lens {
            out.push_str("active");
        }
        out.push_str("\">");
        out.push_str(&html_escape(&capitalize(candidate)));
        out.push_str("</a>");
    }
    out.push_str("</nav><div class=\"architecture-workspace\"><aside class=\"architecture-members\"><label>Members<input type=\"search\" placeholder=\"Search members…\" data-architecture-search></label>");
    for member in &members {
        let id = member.get("id").and_then(Value::as_str).unwrap_or("");
        let kind = member.get("kind").and_then(Value::as_str).unwrap_or("");
        let route = if kind == "state" { "state" } else { "unit" };
        let band = member
            .pointer("/pressure/band")
            .and_then(Value::as_str)
            .unwrap_or("ordinary");
        let score = member
            .pointer("/pressure/score")
            .and_then(Value::as_f64)
            .unwrap_or(0.0);
        out.push_str("<a class=\"architecture-member architecture-band-");
        out.push_str(&html_escape(band));
        if id == selected.get("id").and_then(Value::as_str).unwrap_or("") {
            out.push_str(" selected");
        }
        out.push_str("\" data-member-name=\"");
        out.push_str(&html_escape(
            member.get("name").and_then(Value::as_str).unwrap_or(""),
        ));
        out.push_str("\" href=\"/architecture/");
        out.push_str(route);
        out.push('/');
        out.push_str(&percent_encode(id));
        out.push_str("?lens=");
        out.push_str(&percent_encode(lens));
        out.push_str("\">");
        out.push_str("<span><small>");
        out.push_str(&html_escape(kind));
        out.push_str("</small>");
        out.push_str(&html_escape(
            member.get("name").and_then(Value::as_str).unwrap_or(""),
        ));
        out.push_str("</span>");
        out.push_str("<b>");
        out.push_str(&format!("{score:.0}"));
        out.push_str("</b></a>");
    }
    out.push_str("</aside><section class=\"architecture-focus\"><div class=\"architecture-graph-toolbar\"><strong>Focused neighborhood</strong><button type=\"button\" data-architecture-fit>Fit</button></div>");
    out.push_str(&render_architecture_svg(selected, &nodes, &edges));
    out.push_str("<section class=\"architecture-evidence\"><h2>Why this is highlighted</h2>");
    let pressure = members
        .iter()
        .find(|member| member.get("id") == selected.get("id"))
        .and_then(|member| member.get("pressure"));
    if let Some(pressure) = pressure {
        out.push_str("<p><strong>");
        out.push_str(&format!(
            "{:.1} architecture pressure",
            pressure.get("score").and_then(Value::as_f64).unwrap_or(0.0)
        ));
        out.push_str("</strong></p><pre>");
        out.push_str(&html_escape(
            &serde_json::to_string_pretty(&pressure["explanation"]).unwrap_or_default(),
        ));
        out.push_str("</pre>");
    } else {
        out.push_str("<p>Pressure is not scored for this node.</p>");
    }
    out.push_str("</section><section class=\"architecture-relationships\"><h2>All known relationships</h2><input type=\"search\" placeholder=\"Filter relationships…\" aria-label=\"Filter relationships\" data-relationship-search><table><thead><tr><th>Kind</th><th>From</th><th>To</th><th>Confidence</th><th>Evidence</th></tr></thead><tbody>");
    let node_names = nodes
        .iter()
        .filter_map(|node| Some((node.get("id")?.as_str()?, node.get("name")?.as_str()?)))
        .collect::<HashMap<_, _>>();
    for edge in &all_edges {
        let source = edge.get("source").and_then(Value::as_str).unwrap_or("");
        let target = edge.get("target").and_then(Value::as_str).unwrap_or("");
        out.push_str("<tr data-relationship-row><td>");
        out.push_str(&html_escape(
            edge.get("kind").and_then(Value::as_str).unwrap_or(""),
        ));
        out.push_str("</td><td>");
        out.push_str(&html_escape(
            node_names.get(source).copied().unwrap_or(source),
        ));
        out.push_str("</td><td>");
        out.push_str(&html_escape(
            node_names.get(target).copied().unwrap_or(target),
        ));
        out.push_str("</td><td>");
        out.push_str(&html_escape(
            edge.get("confidence").and_then(Value::as_str).unwrap_or(""),
        ));
        out.push_str("</td><td>");
        if let Some(span) = edge
            .get("spans")
            .and_then(Value::as_array)
            .and_then(|spans| spans.first())
        {
            let path = span.get("path").and_then(Value::as_str).unwrap_or("");
            let line = span.get("start_line").and_then(Value::as_i64).unwrap_or(1);
            out.push_str("<a href=\"/?path=");
            out.push_str(&percent_encode(path));
            out.push_str("#L");
            out.push_str(&line.to_string());
            out.push_str("\">");
            out.push_str(&html_escape(path));
            out.push(':');
            out.push_str(&line.to_string());
            out.push_str("</a>");
        }
        out.push_str("</td></tr>");
    }
    out.push_str("</tbody></table></section></section></div></main><script src=\"/assets/app.js\"></script></body></html>");
    out
}

fn architecture_edge_in_lens(edge: &Value, lens: &str) -> bool {
    let kind = edge.get("kind").and_then(Value::as_str).unwrap_or("");
    match lens {
        "calls" => kind.contains("call") || kind == "delegation",
        "state" => matches!(kind, "reads" | "writes"),
        _ => true,
    }
}

fn render_architecture_svg(selected: &Value, nodes: &[Value], edges: &[Value]) -> String {
    let selected_id = selected.get("id").and_then(Value::as_str).unwrap_or("");
    let inbound = edges
        .iter()
        .filter_map(|edge| {
            (edge.get("target").and_then(Value::as_str) == Some(selected_id))
                .then(|| edge.get("source").and_then(Value::as_str))
                .flatten()
        })
        .collect::<Vec<_>>();
    let outbound = edges
        .iter()
        .filter_map(|edge| {
            (edge.get("source").and_then(Value::as_str) == Some(selected_id))
                .then(|| edge.get("target").and_then(Value::as_str))
                .flatten()
        })
        .collect::<Vec<_>>();
    let mut positions = HashMap::<&str, (i32, i32)>::new();
    positions.insert(selected_id, (400, 180));
    for (index, id) in inbound.iter().enumerate() {
        positions.insert(id, (100, 60 + index as i32 * 90));
    }
    for (index, id) in outbound.iter().enumerate() {
        positions.insert(id, (700, 60 + index as i32 * 90));
    }
    let height = (inbound.len().max(outbound.len()).max(2) * 90 + 70).max(320);
    let mut out = format!("<div class=\"architecture-graph-viewport\"><svg class=\"architecture-graph\" viewBox=\"0 0 800 {height}\" role=\"img\" aria-label=\"Focused architecture relationships\">");
    out.push_str("<defs><marker id=\"architecture-arrow\" markerWidth=\"8\" markerHeight=\"8\" refX=\"7\" refY=\"3\" orient=\"auto\"><path d=\"M0,0 L0,6 L8,3 z\"></path></marker></defs>");
    for edge in edges {
        let source = edge.get("source").and_then(Value::as_str).unwrap_or("");
        let target = edge.get("target").and_then(Value::as_str).unwrap_or("");
        let (Some((sx, sy)), Some((tx, ty))) = (positions.get(source), positions.get(target))
        else {
            continue;
        };
        let dashed = edge.get("confidence").and_then(Value::as_str) != Some("high")
            || edge.get("conditional").and_then(Value::as_bool) == Some(true);
        out.push_str("<path class=\"architecture-edge");
        if dashed {
            out.push_str(" partial");
        }
        out.push_str("\" d=\"M");
        out.push_str(&(sx + 85).to_string());
        out.push(',');
        out.push_str(&sy.to_string());
        out.push_str(" L");
        out.push_str(&(tx - 85).to_string());
        out.push(',');
        out.push_str(&ty.to_string());
        out.push_str("\" marker-end=\"url(#architecture-arrow)\"><title>");
        out.push_str(&html_escape(
            edge.get("kind")
                .and_then(Value::as_str)
                .unwrap_or("relationship"),
        ));
        out.push_str("</title></path>");
    }
    for node in nodes {
        let id = node.get("id").and_then(Value::as_str).unwrap_or("");
        let Some((x, y)) = positions.get(id) else {
            continue;
        };
        let kind = node.get("kind").and_then(Value::as_str).unwrap_or("");
        let route = if kind == "state" { "state" } else { "unit" };
        if kind != "aggregate" {
            out.push_str("<a href=\"/architecture/");
            out.push_str(route);
            out.push('/');
            out.push_str(&percent_encode(id));
            out.push_str("\">");
        }
        out.push_str("<g class=\"architecture-node ");
        out.push_str(&html_escape(kind));
        if id == selected_id {
            out.push_str(" selected");
        }
        out.push_str("\" tabindex=\"0\"><rect x=\"");
        out.push_str(&(x - 85).to_string());
        out.push_str("\" y=\"");
        out.push_str(&(y - 26).to_string());
        out.push_str("\" width=\"170\" height=\"52\" rx=\"8\"></rect><text x=\"");
        out.push_str(&x.to_string());
        out.push_str("\" y=\"");
        out.push_str(&(y + 5).to_string());
        out.push_str("\" text-anchor=\"middle\">");
        out.push_str(&html_escape(
            node.get("name").and_then(Value::as_str).unwrap_or(id),
        ));
        out.push_str("</text></g>");
        if kind != "aggregate" {
            out.push_str("</a>");
        }
    }
    out.push_str("</svg></div>");
    out
}

fn capitalize(value: &str) -> String {
    let mut chars = value.chars();
    chars
        .next()
        .map(|first| first.to_uppercase().collect::<String>() + chars.as_str())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn architecture_routes_build() {
        let _ = routes();
    }
}
