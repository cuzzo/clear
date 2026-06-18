struct RustFileIndexer<'a> {
    file: &'a SourceFile,
    facts: FileFacts,
}

#[derive(Clone)]
struct RustParam {
    name: String,
    ty: String,
    is_self: bool,
}

#[derive(Clone)]
struct RustField {
    name: String,
    ty: String,
    line: usize,
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum RustScopeKind {
    Module,
    Impl,
    Trait,
}

#[derive(Clone)]
struct RustScope {
    name: String,
    kind: RustScopeKind,
}

impl<'a> RustFileIndexer<'a> {
    fn new(file: &'a SourceFile) -> Self {
        Self {
            file,
            facts: FileFacts::new(),
        }
    }

    fn index(mut self) -> FileFacts {
        let mut scope = Vec::new();
        self.walk(self.file.root_node(), &mut scope);
        self.facts
    }

    fn walk(&mut self, node: Node<'a>, scope: &mut Vec<RustScope>) {
        match node.kind() {
            "mod_item" => {
                if let Some(name) = rust_node_name(node, self.file) {
                    scope.push(RustScope {
                        name,
                        kind: RustScopeKind::Module,
                    });
                    self.walk_children(node, scope);
                    scope.pop();
                } else {
                    self.walk_children(node, scope);
                }
            }
            "impl_item" => {
                if let Some(owner) = rust_impl_owner(node, self.file) {
                    scope.push(RustScope {
                        name: owner,
                        kind: RustScopeKind::Impl,
                    });
                    self.walk_children(node, scope);
                    scope.pop();
                } else {
                    self.walk_children(node, scope);
                }
            }
            "trait_item" => {
                if let Some(name) = rust_node_name(node, self.file) {
                    scope.push(RustScope {
                        name,
                        kind: RustScopeKind::Trait,
                    });
                    self.walk_children(node, scope);
                    scope.pop();
                } else {
                    self.walk_children(node, scope);
                }
            }
            "function_item" | "function_signature_item" => {
                self.record_function(node, scope);
                self.walk_children(node, scope);
            }
            "struct_item" => {
                self.record_struct(node, scope);
                self.walk_children(node, scope);
            }
            _ => self.walk_children(node, scope),
        }
    }

    fn walk_children(&mut self, node: Node<'a>, scope: &mut Vec<RustScope>) {
        for child in named_children(node) {
            self.walk(child, scope);
        }
    }

    fn record_function(&mut self, node: Node<'_>, scope: &[RustScope]) {
        let Some(name) = rust_node_name(node, self.file) else {
            return;
        };
        let params = rust_params(node, self.file);
        let return_type = rust_return_type(node, self.file).unwrap_or_else(|| "()".to_string());
        let scope_names = rust_scope_names(scope);
        let owner = scope_names.join("::");
        let kind = rust_function_kind(&params, scope);
        let signature = rust_signature(node, self.file);
        let line_no = line(node);
        let mut protocols = Map::new();
        let mut non_nil_params = Vec::new();

        for param in params.iter().filter(|param| !param.is_self) {
            non_nil_params.push(param.name.clone());
            protocols.insert(
                param.name.clone(),
                json!({
                    "methods": [],
                    "aliases": [],
                    "gaps": [],
                }),
            );
            self.facts.param_origins.push(json!({
                "kind": "method parameter",
                "path": self.file.rel,
                "line": line_no,
                "class": owner,
                "method": name,
                "name": param.name,
                "type": param.ty,
            }));
        }

        let source = json!({
            "language": "rust",
            "path": self.file.rel,
            "line": line_no,
            "end_line": end_line(node),
            "class": owner,
            "method": name,
            "kind": kind,
            "has_sig": true,
            "sig": signature,
            "params": params.iter().map(|param| json!({
                "name": param.name,
                "nil_default": false,
                "type": param.ty,
            })).collect::<Vec<_>>(),
            "scope": scope_names,
            "non_nil_params": non_nil_params,
            "uses_yield": false,
            "untraceable_params": [],
            "protocols": protocols,
            "noreturn_candidate": return_type == "!",
            "return_origin": {
                "path": self.file.rel,
                "line": line_no,
                "end_line": end_line(node),
                "class": owner,
                "method": name,
                "kind": kind,
                "implicit": true,
                "return_syntax": "signature",
                "control_shape": "branchless",
                "candidate_type": return_type,
                "confidence": "strong",
                "sources": [{
                    "kind": "static",
                    "type": return_type,
                    "line": line_no,
                    "code": signature,
                }],
                "blockers": [],
                "hash_shape": Value::Null,
                "array_element_shape": Value::Null,
            },
        });

        if let Some(origin) = source.get("return_origin") {
            self.facts.return_origins.push(origin.clone());
        }
        self.facts.methods.push(source);
    }

    fn record_struct(&mut self, node: Node<'_>, scope: &[RustScope]) {
        let Some(name) = rust_node_name(node, self.file) else {
            return;
        };
        let scope_names = rust_scope_names(scope);
        let owner = if scope_names.is_empty() {
            name
        } else {
            format!("{}::{}", scope_names.join("::"), name)
        };
        let fields = rust_struct_fields(node, self.file);
        self.facts.struct_declarations.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "class": owner,
            "fields": fields.iter().map(|field| field.name.clone()).collect::<Vec<_>>(),
            "code": rust_signature(node, self.file),
        }));
        for field in fields {
            self.facts.struct_field_static.push(json!({
                "path": self.file.rel,
                "line": field.line,
                "class": owner,
                "field": field.name,
                "type": field.ty,
                "expression": rust_signature(node, self.file),
            }));
        }
    }
}

fn rust_scope_names(scope: &[RustScope]) -> Vec<String> {
    scope.iter().map(|entry| entry.name.clone()).collect()
}

fn rust_function_kind(params: &[RustParam], scope: &[RustScope]) -> &'static str {
    if !scope
        .iter()
        .any(|entry| matches!(entry.kind, RustScopeKind::Impl | RustScopeKind::Trait))
    {
        "function"
    } else if params.iter().any(|param| param.is_self) {
        "instance"
    } else {
        "class"
    }
}

fn rust_node_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    node.child_by_field_name("name")
        .or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| matches!(child.kind(), "identifier" | "type_identifier"))
        })
        .map(|child| rust_clean_identifier(&node_text(child, file)))
        .filter(|name| !name.is_empty())
}

fn rust_impl_owner(node: Node<'_>, file: &SourceFile) -> Option<String> {
    if let Some(ty) = node.child_by_field_name("type") {
        let owner = rust_clean_owner(&node_text(ty, file));
        if !owner.is_empty() {
            return Some(owner);
        }
    }

    let text = node_text(node, file);
    let header = text.split('{').next().unwrap_or(text.as_str()).trim();
    let mut rest = header.strip_prefix("impl")?.trim();
    rest = rust_strip_leading_generics(rest);
    let owner = if let Some((_, ty)) = rest.rsplit_once(" for ") {
        rust_clean_owner(ty)
    } else {
        rust_clean_owner(rest)
    };
    (!owner.is_empty()).then_some(owner)
}

fn rust_strip_leading_generics(text: &str) -> &str {
    let trimmed = text.trim_start();
    if !trimmed.starts_with('<') {
        return trimmed;
    }

    let mut depth = 0usize;
    for (idx, ch) in trimmed.char_indices() {
        match ch {
            '<' => depth += 1,
            '>' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return trimmed[idx + ch.len_utf8()..].trim_start();
                }
            }
            _ => {}
        }
    }
    trimmed
}

fn rust_clean_owner(text: &str) -> String {
    let without_where = text.split(" where ").next().unwrap_or(text).trim();
    rust_collapse_whitespace(without_where.trim_end_matches(';').trim())
}

fn rust_signature(node: Node<'_>, file: &SourceFile) -> String {
    let text = node_text(node, file);
    let end = text.find('{').or_else(|| text.find(';')).unwrap_or(text.len());
    rust_collapse_whitespace(text[..end].trim())
}

fn rust_return_type(node: Node<'_>, file: &SourceFile) -> Option<String> {
    if let Some(ret) = node.child_by_field_name("return_type") {
        let ty = rust_clean_return_type(&node_text(ret, file));
        if !ty.is_empty() {
            return Some(ty);
        }
    }

    let signature = rust_signature(node, file);
    let (_, tail) = signature.rsplit_once("->")?;
    let ty = rust_clean_return_type(tail);
    (!ty.is_empty()).then_some(ty)
}

fn rust_clean_return_type(text: &str) -> String {
    let without_arrow = text.trim().strip_prefix("->").unwrap_or(text.trim()).trim();
    rust_collapse_whitespace(without_arrow.split(" where ").next().unwrap_or(without_arrow).trim())
}

fn rust_params(node: Node<'_>, file: &SourceFile) -> Vec<RustParam> {
    let Some(params_node) = node.child_by_field_name("parameters").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| child.kind() == "parameters")
    }) else {
        return Vec::new();
    };
    let text = node_text(params_node, file);
    let inner = text.trim().trim_start_matches('(').trim_end_matches(')');
    split_top_level_commas(inner)
        .into_iter()
        .filter_map(|part| rust_param_from_text(&part))
        .collect()
}

fn rust_param_from_text(text: &str) -> Option<RustParam> {
    let cleaned = rust_strip_outer_attributes(text.trim()).trim().trim_end_matches(',').trim();
    if cleaned.is_empty() {
        return None;
    }

    if rust_self_param(cleaned) {
        return Some(RustParam {
            name: "self".to_string(),
            ty: rust_self_type(cleaned),
            is_self: true,
        });
    }

    if let Some((pattern, ty)) = split_top_level_colon(cleaned) {
        let name = rust_param_name(pattern);
        return Some(RustParam {
            name,
            ty: rust_collapse_whitespace(ty.trim()),
            is_self: false,
        });
    }

    Some(RustParam {
        name: rust_param_name(cleaned),
        ty: "T.untyped".to_string(),
        is_self: false,
    })
}

fn rust_strip_outer_attributes(mut text: &str) -> &str {
    loop {
        let trimmed = text.trim_start();
        if !trimmed.starts_with("#[") {
            return trimmed;
        }
        let Some(end) = trimmed.find(']') else {
            return trimmed;
        };
        text = &trimmed[end + 1..];
    }
}

fn rust_self_param(text: &str) -> bool {
    let normalized = text
        .replace("& '", "&'")
        .replace("& mut", "&mut")
        .replace("mut ", "")
        .replace("ref ", "");
    !normalized.contains(':') && normalized.split_whitespace().any(|part| {
        matches!(
            part.trim_matches(|ch: char| matches!(ch, '&' | '*')),
            "self" | "&self" | "&mutself"
        ) || part.ends_with("self")
    })
}

fn rust_self_type(text: &str) -> String {
    if text.contains("&mut") {
        "&mut Self".to_string()
    } else if text.contains('&') {
        "&Self".to_string()
    } else {
        "Self".to_string()
    }
}

fn rust_param_name(text: &str) -> String {
    let mut cleaned = text.trim();
    cleaned = cleaned.trim_start_matches('&').trim_start_matches('*').trim();
    for prefix in ["mut ", "ref "] {
        if let Some(stripped) = cleaned.strip_prefix(prefix) {
            cleaned = stripped.trim();
        }
    }
    let last = cleaned
        .split(|ch: char| ch.is_whitespace() || matches!(ch, '@' | '&' | '*'))
        .filter(|part| !part.is_empty())
        .last()
        .unwrap_or(cleaned);
    rust_clean_identifier(last)
}

fn rust_clean_identifier(text: &str) -> String {
    text.trim()
        .trim_start_matches("r#")
        .trim_matches(|ch: char| !ch.is_alphanumeric() && ch != '_')
        .to_string()
}

fn rust_struct_fields(node: Node<'_>, file: &SourceFile) -> Vec<RustField> {
    let mut out = Vec::new();
    rust_collect_struct_fields(node, file, &mut out);
    out
}

fn rust_collect_struct_fields(node: Node<'_>, file: &SourceFile, out: &mut Vec<RustField>) {
    if node.kind() == "field_declaration" {
        if let Some(field) = rust_field_from_text(&node_text(node, file), line(node), out.len()) {
            out.push(field);
        }
        return;
    }

    for child in named_children(node) {
        rust_collect_struct_fields(child, file, out);
    }
}

fn rust_field_from_text(text: &str, line_no: usize, idx: usize) -> Option<RustField> {
    let cleaned = text.trim().trim_end_matches(',').trim();
    if cleaned.is_empty() {
        return None;
    }
    if let Some((name_text, ty_text)) = split_top_level_colon(cleaned) {
        return Some(RustField {
            name: rust_param_name(rust_strip_visibility(name_text)),
            ty: rust_collapse_whitespace(ty_text.trim()),
            line: line_no,
        });
    }

    Some(RustField {
        name: idx.to_string(),
        ty: rust_collapse_whitespace(rust_strip_visibility(cleaned)),
        line: line_no,
    })
}

fn rust_strip_visibility(text: &str) -> &str {
    let trimmed = text.trim();
    if trimmed == "pub" {
        return "";
    }
    if let Some(rest) = trimmed.strip_prefix("pub ") {
        return rest.trim();
    }
    if let Some(rest) = trimmed.strip_prefix("pub(") {
        if let Some(end) = rest.find(')') {
            return rest[end + 1..].trim();
        }
    }
    trimmed
}

fn split_top_level_colon(text: &str) -> Option<(&str, &str)> {
    let mut angle = 0usize;
    let mut paren = 0usize;
    let mut bracket = 0usize;
    let mut brace = 0usize;
    for (idx, ch) in text.char_indices() {
        match ch {
            '<' => angle += 1,
            '>' => angle = angle.saturating_sub(1),
            '(' => paren += 1,
            ')' => paren = paren.saturating_sub(1),
            '[' => bracket += 1,
            ']' => bracket = bracket.saturating_sub(1),
            '{' => brace += 1,
            '}' => brace = brace.saturating_sub(1),
            ':' if angle == 0 && paren == 0 && bracket == 0 && brace == 0 => {
                return Some((&text[..idx], &text[idx + 1..]));
            }
            _ => {}
        }
    }
    None
}

fn split_top_level_commas(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut start = 0usize;
    let mut angle = 0usize;
    let mut paren = 0usize;
    let mut bracket = 0usize;
    let mut brace = 0usize;
    let mut in_string = false;
    let mut escape = false;

    for (idx, ch) in text.char_indices() {
        if escape {
            escape = false;
            continue;
        }
        if in_string {
            match ch {
                '\\' => escape = true,
                '"' => in_string = false,
                _ => {}
            }
            continue;
        }

        match ch {
            '"' => in_string = true,
            '<' => angle += 1,
            '>' => angle = angle.saturating_sub(1),
            '(' => paren += 1,
            ')' => paren = paren.saturating_sub(1),
            '[' => bracket += 1,
            ']' => bracket = bracket.saturating_sub(1),
            '{' => brace += 1,
            '}' => brace = brace.saturating_sub(1),
            ',' if angle == 0 && paren == 0 && bracket == 0 && brace == 0 => {
                out.push(text[start..idx].trim().to_string());
                start = idx + ch.len_utf8();
            }
            _ => {}
        }
    }

    let tail = text[start..].trim();
    if !tail.is_empty() {
        out.push(tail.to_string());
    }
    out
}

fn rust_collapse_whitespace(text: &str) -> String {
    text.split_whitespace().collect::<Vec<_>>().join(" ")
}
