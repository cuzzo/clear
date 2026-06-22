// Profile extraction: mirrors FactMine::EspalierProfile (Ruby) in Rust.
// Produces enriched static facts from a Document for Espalier or NilKill.

use crate::syntax::{self, Document};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};

/// Which fact-set to produce.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Profile {
    /// Core facts for Espalier: methods, fields, type definitions, shapes, etc.
    Espalier,
    /// All facts including nil-kill-specific inference data.
    NilKill,
}

/// The enriched output matching what Ruby's EspalierProfile::Builder.build returns.
#[derive(Clone, Debug, Serialize)]
pub struct ProfileOutput {
    pub methods: Vec<MethodRecord>,
    pub fields: Vec<FieldRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub struct_declarations: Vec<StructDeclaration>,
    pub state_types: BTreeMap<String, String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub state_type_records: Vec<StateTypeRecord>,
    pub state_protocols: BTreeMap<String, Vec<String>>,
    pub state_param_origins: BTreeMap<String, Vec<String>>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub state_protocol_records: Vec<StateProtocolRecord>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub state_param_origin_records: Vec<StateParamOriginRecord>,
    pub signatures: BTreeMap<String, String>,
    pub type_definitions: Vec<TypeDefinition>,
    pub hash_shapes: Vec<HashShape>,
    pub array_shapes: Vec<ArrayShape>,
    /// Edges from an owner to another owner via typed state fields.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub state_type_edges: Vec<StateTypeEdge>,
    // NilKill-only fields
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub collection_index_lookups: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hash_record_blockers: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tlet_sites: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dead_nil_checks: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub deterministic_guards: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub return_origins: Vec<serde_json::Value>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub noreturn_methods: Vec<serde_json::Value>,
}

#[derive(Clone, Debug, Serialize)]
pub struct StateTypeEdge {
    pub source: String,
    pub target: String,
    pub label: String,
    pub kind: String,
    #[serde(default)]
    pub weight: usize,
}

#[derive(Clone, Debug, Serialize)]
pub struct MethodRecord {
    pub key: Vec<String>,
    pub owner: String,
    pub name: String,
    pub kind: String,
    pub path: String,
    pub line: usize,
    pub span: Option<[usize; 4]>,
    pub language: String,
    pub signature: String,
    pub params: Vec<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub untraceable_params: Vec<String>,
    pub source: serde_json::Value,
}

#[derive(Clone, Debug, Serialize)]
pub struct FieldRecord {
    pub id: String,
    pub language: String,
    pub path: String,
    pub owner: String,
    pub name: String,
    pub line: usize,
    pub span: Option<[usize; 4]>,
    pub declared_type: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub type_references: Vec<serde_json::Value>,
    pub static_origin: String,
    pub source: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct StateTypeRecord {
    pub language: String,
    pub path: String,
    pub owner: String,
    pub field: String,
    pub declared_type: String,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub type_references: Vec<serde_json::Value>,
    pub line: usize,
    pub span: Option<[usize; 4]>,
    pub key: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct StateProtocolRecord {
    pub language: String,
    pub path: String,
    pub owner: String,
    pub function: String,
    pub field: String,
    pub protocol: String,
    pub line: usize,
    pub span: Option<[usize; 4]>,
    pub key: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct StateParamOriginRecord {
    pub language: String,
    pub path: String,
    pub owner: String,
    pub function: String,
    pub field: String,
    pub param: String,
    pub line: usize,
    pub span: Option<[usize; 4]>,
    pub key: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct TypeDefinition {
    pub id: String,
    pub language: String,
    pub type_system: String,
    pub kind: String,
    pub path: String,
    pub owner: String,
    pub name: String,
    pub line: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub signature: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub return_type: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub params: Vec<BTreeMap<String, String>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub declared_type: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub source: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct HashShape {
    pub path: String,
    pub line: usize,
    pub keys: Vec<String>,
    pub value_types: Vec<String>,
    pub code: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value_hash_shapes: Option<BTreeMap<String, serde_json::Value>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub value_array_element_shapes: Option<BTreeMap<String, serde_json::Value>>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ArrayShape {
    pub path: String,
    pub line: usize,
    pub tuple_types: Vec<String>,
    pub size: usize,
    pub code: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct StructDeclaration {
    pub path: String,
    pub class: String,
    pub fields: Vec<String>,
    #[serde(default)]
    pub field_types: BTreeMap<String, String>,
    pub line: usize,
}

// ---------------------------------------------------------------------------
// Extraction
// ---------------------------------------------------------------------------

/// Extract enriched facts from a set of documents.
pub fn extract(document: &Document, profile: Profile) -> ProfileOutput {
    let language = document.language.as_str().to_string();
    let path = document.file.clone();
    let nil_kill = profile == Profile::NilKill;

    // Read source lines once for signature extraction (matches Ruby approach)
    let lines = std::fs::read_to_string(&path)
        .unwrap_or_default()
        .lines()
        .map(|l| l.to_string())
        .collect::<Vec<_>>();

    let methods = extract_methods(&lines, document, &language, &path);
    let fields = extract_fields(document, &language, &path);
    let (state_types, state_type_records) = extract_state_types(document, &language, &path);
    let (state_protocols, state_protocol_records) =
        extract_state_protocols(document, &language, &path);
    let (state_param_origins, state_param_origin_records) =
        extract_state_param_origins(document, &language, &path);
    let signatures = extract_signatures(&lines, document);
    let type_definitions = extract_type_definitions(&lines, document, &language, &path);
    let hash_shapes = Vec::new(); // TODO Phase 2c
    let array_shapes = Vec::new(); // TODO Phase 2c
    let struct_declarations = extract_struct_declarations(document, &language, &path);
    let state_type_edges = extract_state_type_edges(document, &language, &path);

    ProfileOutput {
        methods,
        fields,
        struct_declarations,
        state_types,
        state_type_records,
        state_protocols,
        state_param_origins,
        state_protocol_records,
        state_param_origin_records,
        signatures,
        type_definitions,
        hash_shapes,
        array_shapes,
        state_type_edges,
        collection_index_lookups: if nil_kill { Vec::new() } else { Vec::new() },
        hash_record_blockers: Vec::new(),
        tlet_sites: if nil_kill { Vec::new() } else { Vec::new() },
        dead_nil_checks: if nil_kill { Vec::new() } else { Vec::new() },
        deterministic_guards: if nil_kill { Vec::new() } else { Vec::new() },
        return_origins: if nil_kill { Vec::new() } else { Vec::new() },
        noreturn_methods: if nil_kill { Vec::new() } else { Vec::new() },
    }
}

/// Merge outputs from multiple files into one (like Ruby's per-file accumulation).
pub fn merge(outputs: Vec<ProfileOutput>, profile: Profile) -> ProfileOutput {
    let nil_kill = profile == Profile::NilKill;
    let mut methods = Vec::new();
    let mut fields = Vec::new();
    let mut struct_declarations = Vec::new();
    let mut state_types = BTreeMap::new();
    let mut state_type_records = Vec::new();
    let mut state_protocols: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut state_param_origins_out: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut state_protocol_records = Vec::new();
    let mut state_param_origin_records = Vec::new();
    let mut signatures = BTreeMap::new();
    let mut type_definitions = Vec::new();
    let mut hash_shapes = Vec::new();
    let mut array_shapes = Vec::new();
    let mut state_type_edges = Vec::new();
    let mut collection_index_lookups = Vec::new();
    let mut hash_record_blockers = Vec::new();
    let mut tlet_sites = Vec::new();
    let mut dead_nil_checks = Vec::new();
    let mut deterministic_guards = Vec::new();
    let mut return_origins = Vec::new();
    let mut noreturn_methods = Vec::new();

    for output in outputs {
        methods.extend(output.methods);
        fields.extend(output.fields);
        struct_declarations.extend(output.struct_declarations);
        state_types.extend(output.state_types);
        state_type_records.extend(output.state_type_records);
        for (key, values) in output.state_protocols {
            state_protocols
                .entry(key)
                .or_default()
                .extend(values);
        }
        for (key, values) in output.state_param_origins {
            state_param_origins_out
                .entry(key)
                .or_default()
                .extend(values);
        }
        state_protocol_records.extend(output.state_protocol_records);
        state_param_origin_records.extend(output.state_param_origin_records);
        signatures.extend(output.signatures);
        type_definitions.extend(output.type_definitions);
        hash_shapes.extend(output.hash_shapes);
        array_shapes.extend(output.array_shapes);
        state_type_edges.extend(output.state_type_edges);
        if nil_kill {
            collection_index_lookups.extend(output.collection_index_lookups);
            hash_record_blockers.extend(output.hash_record_blockers);
            tlet_sites.extend(output.tlet_sites);
            dead_nil_checks.extend(output.dead_nil_checks);
            deterministic_guards.extend(output.deterministic_guards);
            return_origins.extend(output.return_origins);
            noreturn_methods.extend(output.noreturn_methods);
        }
    }

    let state_protocols: BTreeMap<String, Vec<String>> = state_protocols
        .into_iter()
        .map(|(k, v)| (k, v.into_iter().collect()))
        .collect();
    let state_param_origins: BTreeMap<String, Vec<String>> = state_param_origins_out
        .into_iter()
        .map(|(k, v)| (k, v.into_iter().collect()))
        .collect();

    ProfileOutput {
        methods,
        fields,
        struct_declarations,
        state_types,
        state_type_records,
        state_protocols,
        state_param_origins,
        state_protocol_records,
        state_param_origin_records,
        signatures,
        type_definitions,
        hash_shapes,
        array_shapes,
        state_type_edges,
        collection_index_lookups,
        hash_record_blockers,
        tlet_sites,
        dead_nil_checks,
        deterministic_guards,
        return_origins,
        noreturn_methods,
    }
}

fn extract_methods(lines: &[String], document: &Document, language: &str, path: &str) -> Vec<MethodRecord> {
    document
        .function_defs
        .iter()
        .map(|fn_def| {
            let owner = fn_def.owner.clone();
            let name = fn_def.name.clone();
            let kind = method_kind(fn_def, &owner);
            let signature = method_signature(lines, fn_def, language);
            let source = method_source(&signature, language);

            MethodRecord {
                key: vec![owner.clone(), name.clone(), kind.clone()],
                owner,
                name,
                kind,
                path: path.to_string(),
                line: fn_def.line,
                span: Some(fn_def.span),
                language: language.to_string(),
                signature,
                params: fn_def.params.clone(),
                untraceable_params: Vec::new(),
                source,
            }
        })
        .collect()
}

fn method_kind(fn_def: &syntax::FunctionDef, owner: &str) -> String {
    if fn_def.name == "initialize" || fn_def.name.starts_with("self.") {
        "class".to_string()
    } else if !owner.is_empty() {
        "instance".to_string()
    } else {
        "top".to_string()
    }
}

fn method_signature(
    lines: &[String],
    fn_def: &syntax::FunctionDef,
    language: &str,
) -> String {
    let sig = fn_def.signature.trim().to_string();
    if !sig.is_empty() {
        return sig;
    }

    match language {
        "ruby" => {
            let sig = ruby_signature_before_line(lines, fn_def.line);
            if sig.starts_with("sig ") {
                return sig;
            }
            String::new()
        }
        "python" | "typescript" | "javascript" => {
            source_signature_for(lines, fn_def)
        }
        _ => {
            let params = fn_def.params.join(", ");
            if params.is_empty() {
                fn_def.name.clone()
            } else {
                format!("{} ({})", fn_def.name, params)
            }
        }
    }
}

/// Ruby: scan backwards from the def line to find a `sig { ... }` block.
fn ruby_signature_before_line(lines: &[String], line: usize) -> String {
    let mut idx = line.saturating_sub(2);
    if idx >= lines.len() {
        return String::new();
    }
    // Skip blank lines going backward
    while idx > 0 && lines[idx].trim().is_empty() {
        idx = idx.saturating_sub(1);
    }
    if lines[idx].trim().starts_with("sig ") {
        return lines[idx].trim().to_string();
    }
    let mut start = idx;
    loop {
        if start == 0 {
            break;
        }
        let text = lines[start].trim();
        if text.starts_with("sig ") {
            // Join lines from start to idx
            let joined: String = lines[start..=idx]
                .iter()
                .map(|l| l.trim())
                .collect::<Vec<_>>()
                .join(" ");
            // Normalize whitespace
            let normalized: String = joined
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            return normalized;
        }
        if text.starts_with("def ") || text.starts_with("class ") || text.starts_with("module ") {
            return String::new();
        }
        start = start.saturating_sub(1);
    }
    String::new()
}

/// Python/TypeScript: the raw def line IS the signature.
fn source_signature_for(lines: &[String], fn_def: &syntax::FunctionDef) -> String {
    let idx = fn_def.line.saturating_sub(1);
    if idx >= lines.len() {
        return String::new();
    }
    lines[idx].trim().to_string()
}

fn method_source(signature: &str, language: &str) -> serde_json::Value {
    if signature.is_empty() {
        return serde_json::Value::Object(Default::default());
    }
    let mut source = serde_json::Map::new();
    if language == "ruby" && signature.starts_with("sig ") {
        source.insert(
            "sig".to_string(),
            serde_json::Value::String(signature.to_string()),
        );
        source.insert(
            "signature".to_string(),
            serde_json::Value::String(signature.to_string()),
        );
        source.insert(
            "type_system".to_string(),
            serde_json::Value::String("sorbet".to_string()),
        );
        source.insert(
            "source".to_string(),
            serde_json::Value::String("annotation".to_string()),
        );
    } else {
        source.insert(
            "signature".to_string(),
            serde_json::Value::String(signature.to_string()),
        );
        source.insert(
            "type_system".to_string(),
            serde_json::Value::String(language_type_system(language).to_string()),
        );
    }
    serde_json::Value::Object(source)
}

fn language_type_system(language: &str) -> &str {
    match language {
        "ruby" => "sorbet",
        "python" => "python-typing",
        "typescript" => "typescript",
        "javascript" => "typescript",
        "go" => "go-types",
        "rust" => "rust-types",
        "java" => "java-types",
        "kotlin" => "kotlin-types",
        "swift" => "swift-types",
        "csharp" => "csharp-types",
        _ => "native",
    }
}

// ---------------------------------------------------------------------------
// Fields
// ---------------------------------------------------------------------------

fn extract_fields(document: &Document, language: &str, path: &str) -> Vec<FieldRecord> {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut out = Vec::new();

    for state in &document.state_declarations {
        let name = state.field.clone();
        let id = field_id(language, path, &state.owner, &name);
        if seen.contains(&id) {
            continue;
        }
        seen.insert(id.clone());
        out.push(FieldRecord {
            id,
            language: language.to_string(),
            path: path.to_string(),
            owner: state.owner.clone(),
            name,
            line: state.line,
            span: Some(state.span),
            declared_type: state.r#type.clone(),
            type_references: Vec::new(),
            static_origin: "state_declaration".to_string(),
            source: "syntax".to_string(),
        });
    }

    // Add state_writes not already covered by declarations
    let valid_owners: BTreeSet<String> = document
        .owner_defs
        .iter()
        .map(|o| o.name.clone())
        .chain(
            document
                .function_defs
                .iter()
                .map(|f| f.owner.clone())
                .filter(|o| !o.is_empty()),
        )
        .chain(
            document
                .state_declarations
                .iter()
                .map(|s| s.owner.clone()),
        )
        .collect();

    for write in &document.state_writes {
        let name = write.field.clone();
        let id = field_id(language, path, &write.owner, &name);
        if seen.contains(&id) {
            continue;
        }
        if !valid_owners.is_empty() && !valid_owners.contains(&write.owner) && !write.owner.is_empty() {
            continue;
        }
        seen.insert(id.clone());
        out.push(FieldRecord {
            id,
            language: language.to_string(),
            path: path.to_string(),
            owner: write.owner.clone(),
            name,
            line: write.line,
            span: Some(write.span),
            declared_type: None,
            type_references: Vec::new(),
            static_origin: "state_write".to_string(),
            source: "syntax".to_string(),
        });
    }

    out
}

fn field_id(language: &str, path: &str, owner: &str, name: &str) -> String {
    [language, path, owner, "field", name].join("\u{0}")
}

// ---------------------------------------------------------------------------
// State types
// ---------------------------------------------------------------------------

fn extract_state_types(
    document: &Document,
    language: &str,
    path: &str,
) -> (BTreeMap<String, String>, Vec<StateTypeRecord>) {
    let mut types = BTreeMap::new();
    let mut records = Vec::new();

    for state in &document.state_declarations {
        let type_text = match &state.r#type {
            Some(t) if !t.is_empty() => t.clone(),
            _ => continue,
        };
        let name = state.field.clone();
        let key = state_key(&state.owner, &name);
        types.insert(key.clone(), type_text.clone());

        records.push(StateTypeRecord {
            language: language.to_string(),
            path: path.to_string(),
            owner: state.owner.clone(),
            field: name,
            declared_type: type_text,
            type_references: Vec::new(),
            line: state.line,
            span: Some(state.span),
            key,
        });
    }

    (types, records)
}

// ---------------------------------------------------------------------------
// State protocols
// ---------------------------------------------------------------------------

fn extract_state_protocols(
    document: &Document,
    language: &str,
    path: &str,
) -> (BTreeMap<String, Vec<String>>, Vec<StateProtocolRecord>) {
    let mut protocols: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut records = Vec::new();

    for call in &document.call_sites {
        let receiver = &call.receiver;
        // Determine which state field this receiver resolves to
        let state_field = receiver_state_field(receiver, document);
        let Some(field) = state_field else {
            continue;
        };

        let key = state_key(&call.owner, &field);
        protocols
            .entry(key.clone())
            .or_default()
            .insert(call.message.clone());

        records.push(StateProtocolRecord {
            language: language.to_string(),
            path: path.to_string(),
            owner: call.owner.clone(),
            function: call.function.clone(),
            field,
            protocol: call.message.clone(),
            line: call.line,
            span: Some(call.span),
            key,
        });
    }

    let protocols: BTreeMap<String, Vec<String>> = protocols
        .into_iter()
        .map(|(k, v)| (k, v.into_iter().collect()))
        .collect();

    (protocols, records)
}

fn receiver_state_field(receiver: &str, document: &Document) -> Option<String> {
    if receiver.is_empty() || receiver == ".literal" {
        return None;
    }

    // Self-receiver: resolve to a declared state field
    if receiver == "self" || receiver == "this" {
        if let Some(first) = document.state_declarations.first() {
            return Some(first.field.clone());
        }
        return None;
    }

    // @ivar style
    if receiver.starts_with('@') {
        let field = receiver.split('.').next().unwrap_or(receiver);
        return Some(field.to_string());
    }

    // self.field or this.field style
    for prefix in &["self.", "this."] {
        if let Some(field) = receiver.strip_prefix(*prefix) {
            return Some(field.to_string());
        }
    }

    None
}

// ---------------------------------------------------------------------------
// State param origins
// ---------------------------------------------------------------------------

fn extract_state_param_origins(
    document: &Document,
    language: &str,
    path: &str,
) -> (
    BTreeMap<String, Vec<String>>,
    Vec<StateParamOriginRecord>,
) {
    let mut origins: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut records = Vec::new();

    for origin in &document.state_param_origins {
        let key = state_key(&origin.owner, &origin.field);
        origins
            .entry(key.clone())
            .or_default()
            .insert(origin.param.clone());

        records.push(StateParamOriginRecord {
            language: language.to_string(),
            path: path.to_string(),
            owner: origin.owner.clone(),
            function: origin.function.clone(),
            field: origin.field.clone(),
            param: origin.param.clone(),
            line: origin.line,
            span: Some(origin.span),
            key,
        });
    }

    let origins: BTreeMap<String, Vec<String>> = origins
        .into_iter()
        .map(|(k, v)| (k, v.into_iter().collect()))
        .collect();

    (origins, records)
}

// ---------------------------------------------------------------------------
// Signatures
// ---------------------------------------------------------------------------

fn extract_signatures(lines: &[String], document: &Document) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let language = document.language.as_str();
    for fn_def in &document.function_defs {
        let sig = method_signature(lines, fn_def, language);
        if !sig.is_empty() {
            let key = format!("{}\u{0}{}", fn_def.owner, fn_def.name);
            out.insert(key, sig);
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Type definitions
// ---------------------------------------------------------------------------

fn extract_type_definitions(
    lines: &[String],
    document: &Document,
    language: &str,
    path: &str,
) -> Vec<TypeDefinition> {
    let mut out = Vec::new();

    // Method signatures from function_defs with source-level sig extraction
    for fn_def in &document.function_defs {
        let sig = method_signature(lines, fn_def, language);
        if sig.is_empty() {
            continue;
        }

        // Only emit type definitions for languages that have typed signatures
        let (return_type, params) = parse_typed_signature(&sig, language);
        if return_type.is_none() && params.is_empty() {
            continue;
        }

        let ts = language_type_system(language);
        out.push(TypeDefinition {
            id: [
                language,
                path,
                &fn_def.owner,
                "method_signature",
                &fn_def.name,
                &fn_def.line.to_string(),
                ts,
            ]
            .join("\u{0}"),
            language: language.to_string(),
            type_system: ts.to_string(),
            kind: "method_signature".to_string(),
            path: path.to_string(),
            owner: fn_def.owner.clone(),
            name: fn_def.name.clone(),
            line: fn_def.line,
            signature: Some(sig),
            return_type,
            params,
            declared_type: None,
            target: None,
            source: None,
        });
    }

    // Type aliases from Document type_aliases map
    for (name, target) in &document.type_aliases {
        let ts = language_type_system(language);
        out.push(TypeDefinition {
            id: [language, path, "", "type_alias", name, "1", ts]
                .join("\u{0}"),
            language: language.to_string(),
            type_system: ts.to_string(),
            kind: "type_alias".to_string(),
            path: path.to_string(),
            owner: String::new(),
            name: name.clone(),
            line: 0,
            signature: None,
            return_type: None,
            params: Vec::new(),
            declared_type: None,
            target: Some(target.clone()),
            source: Some("syntax".to_string()),
        });
    }

    // State field type definitions
    for state in &document.state_declarations {
        let type_text = match &state.r#type {
            Some(t) if !t.is_empty() => t.clone(),
            _ => continue,
        };
        let ts = language_type_system(language);
        out.push(TypeDefinition {
            id: [
                language,
                path,
                &state.owner,
                "state_field",
                &state.field,
                &state.line.to_string(),
                ts,
            ]
            .join("\u{0}"),
            language: language.to_string(),
            type_system: ts.to_string(),
            kind: "state_field".to_string(),
            path: path.to_string(),
            owner: state.owner.clone(),
            name: state.field.clone(),
            line: state.line,
            signature: None,
            return_type: None,
            params: Vec::new(),
            declared_type: Some(type_text),
            target: None,
            source: Some("syntax".to_string()),
        });
    }

    // Method param types from Document method_param_types
    for (fn_key, param_types) in &document.method_param_types {
        let (owner, name) = split_method_key(fn_key);
        let ts = language_type_system(language);
        let params: Vec<BTreeMap<String, String>> = param_types
            .iter()
            .map(|(pname, ptype)| {
                let mut map = BTreeMap::new();
                map.insert("name".to_string(), pname.clone());
                map.insert("type".to_string(), ptype.clone());
                map
            })
            .collect();

        if !params.is_empty() {
            out.push(TypeDefinition {
                id: [
                    language,
                    path,
                    &owner,
                    "method_signature",
                    &name,
                    "0",
                    ts,
                ]
                .join("\u{0}"),
                language: language.to_string(),
                type_system: ts.to_string(),
                kind: "method_signature".to_string(),
                path: path.to_string(),
                owner,
                name,
                line: 0,
                signature: None,
                return_type: None,
                params,
                declared_type: None,
                target: None,
                source: Some("method_param_types".to_string()),
            });
        }
    }

    out
}

fn parse_typed_signature(
    sig: &str,
    language: &str,
) -> (Option<String>, Vec<BTreeMap<String, String>>) {
    match language {
        "ruby" => parse_sorbet_signature(sig),
        "python" => parse_python_signature(sig),
        "typescript" | "javascript" => parse_typescript_signature(sig),
        _ => (None, Vec::new()),
    }
}

/// Sorbet sig: sig { params(name: Type).returns(ReturnType) }
fn parse_sorbet_signature(
    sig: &str,
) -> (Option<String>, Vec<BTreeMap<String, String>>) {
    let sig = sig.trim();
    if !sig.starts_with("sig ") {
        return (None, Vec::new());
    }

    let return_type = sorbet_extract(sig, ".returns(");
    let params = sorbet_extract_params(sig);
    (return_type, params)
}

fn sorbet_extract(sig: &str, marker: &str) -> Option<String> {
    let start = sig.find(marker)?;
    let inner = &sig[start + marker.len()..];
    let mut depth = 1u32;
    let mut end = 0usize;
    for (i, c) in inner.char_indices() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    end = i;
                    break;
                }
            }
            _ => {}
        }
    }
    if end > 0 {
        Some(inner[..end].trim().to_string())
    } else {
        None
    }
}

fn sorbet_extract_params(sig: &str) -> Vec<BTreeMap<String, String>> {
    let params_str = match sorbet_extract(sig, ".params(") {
        Some(p) => p,
        None => return Vec::new(),
    };
    let mut out = Vec::new();
    for entry in split_top_level_params(&params_str) {
        if let Some((name, type_part)) = entry.split_once(':') {
            let mut map = BTreeMap::new();
            map.insert("name".to_string(), name.trim().to_string());
            map.insert("type".to_string(), type_part.trim().to_string());
            out.push(map);
        }
    }
    out
}

fn split_top_level_params(params: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut depth = 0u32;
    let mut start = 0usize;
    for (i, c) in params.char_indices() {
        match c {
            '(' | '<' | '[' | '{' => depth += 1,
            ')' | '>' | ']' | '}' => depth = depth.saturating_sub(1),
            ',' if depth == 0 => {
                out.push(params[start..i].to_string());
                start = i + 1;
            }
            _ => {}
        }
    }
    let remainder = params[start..].trim().to_string();
    if !remainder.is_empty() {
        out.push(remainder);
    }
    out
}

fn parse_python_signature(
    sig: &str,
) -> (Option<String>, Vec<BTreeMap<String, String>>) {
    let sig = sig.trim();
    let paren_open = match sig.find('(') {
        Some(p) => p,
        None => return (None, Vec::new()),
    };
    let paren_close = match sig.rfind(')') {
        Some(p) => p,
        None => return (None, Vec::new()),
    };
    let params_str = &sig[paren_open + 1..paren_close];
    let return_type = sig[paren_close + 1..]
        .trim()
        .strip_prefix("->")
        .map(|s| s.trim().to_string());

    let params: Vec<BTreeMap<String, String>> = params_str
        .split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            if entry.is_empty() || entry == "self" || entry == "cls" {
                return None;
            }
            let (name, type_part) = if let Some((name, rest)) = entry.split_once(':') {
                let name = name.trim().trim_end_matches('=');
                (name.to_string(), rest.trim().to_string())
            } else {
                return None;
            };
            if type_part.is_empty() {
                return None;
            }
            let mut map = BTreeMap::new();
            map.insert("name".to_string(), name);
            map.insert("type".to_string(), type_part);
            Some(map)
        })
        .collect();

    (return_type, params)
}

fn parse_typescript_signature(
    sig: &str,
) -> (Option<String>, Vec<BTreeMap<String, String>>) {
    let sig = sig.trim();
    let paren_open = match sig.find('(') {
        Some(p) => p,
        None => return (None, Vec::new()),
    };
    let paren_close = match sig.rfind(')') {
        Some(p) => p,
        None => return (None, Vec::new()),
    };
    let params_str = &sig[paren_open + 1..paren_close];
    let return_type = sig[paren_close + 1..]
        .trim()
        .strip_prefix(':')
        .map(|s| s.trim().trim_end_matches(';').to_string());

    let params: Vec<BTreeMap<String, String>> = params_str
        .split(',')
        .filter_map(|entry| {
            let entry = entry.trim();
            if entry.is_empty() {
                return None;
            }
            let entry = entry.trim_start_matches("...");
            let (name, type_part) = if let Some((name, rest)) = entry.split_once(':') {
                let name = name.trim().trim_end_matches('?');
                (name.to_string(), rest.trim().to_string())
            } else {
                return None;
            };
            if type_part.is_empty() {
                return None;
            }
            let mut map = BTreeMap::new();
            map.insert("name".to_string(), name);
            map.insert("type".to_string(), type_part);
            Some(map)
        })
        .collect();

    (return_type, params)
}

// ---------------------------------------------------------------------------
// Struct declarations
// ---------------------------------------------------------------------------

fn extract_struct_declarations(
    document: &Document,
    _language: &str,
    path: &str,
) -> Vec<StructDeclaration> {
    document
        .immutable_struct_readers
        .iter()
        .map(|(class_name, fields)| {
            let field_types = document
                .immutable_struct_reader_types
                .get(class_name)
                .cloned()
                .unwrap_or_default();
            StructDeclaration {
                path: path.to_string(),
                class: class_name.clone(),
                fields: fields.clone(),
                field_types,
                line: 0,
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// State type edges
// ---------------------------------------------------------------------------

fn extract_state_type_edges(
    document: &Document,
    _language: &str,
    _path: &str,
) -> Vec<StateTypeEdge> {
    let mut edges = Vec::new();
    let owner_names: BTreeSet<String> = document
        .owner_defs
        .iter()
        .map(|o| o.name.clone())
        .collect();

    for state in &document.state_declarations {
        let type_text = match &state.r#type {
            Some(t) if !t.is_empty() => t.as_str(),
            _ => continue,
        };
        // Find owner references in the type text (qualified names)
        for candidate in type_reference_candidates(type_text) {
            if owner_names.contains(&candidate) {
                edges.push(StateTypeEdge {
                    source: state.owner.clone(),
                    target: candidate.clone(),
                    label: format!("state {}", state.field),
                    kind: "state_type".to_string(),
                    weight: 1,
                });
            } else {
                // Try simple name matching
                let simple = candidate
                    .split("::")
                    .last()
                    .unwrap_or(&candidate)
                    .to_string();
                if owner_names.contains(&simple) && simple != candidate {
                    edges.push(StateTypeEdge {
                        source: state.owner.clone(),
                        target: simple,
                        label: format!("state {}", state.field),
                        kind: "state_type".to_string(),
                        weight: 1,
                    });
                }
            }
        }
    }

    // Deduplicate
    edges.sort_by(|a, b| {
        a.source
            .cmp(&b.source)
            .then_with(|| a.target.cmp(&b.target))
            .then_with(|| a.label.cmp(&b.label))
    });
    edges.dedup_by(|a, b| a.source == b.source && a.target == b.target && a.label == b.label);

    edges
}

/// Extract potential owner reference names from a type string.
fn type_reference_candidates(type_text: &str) -> Vec<String> {
    let mut out = Vec::new();
    for word in type_text.split(|c: char| !c.is_alphanumeric() && c != ':' && c != '_' && c != '$') {
        let word = word.trim_matches(|c: char| c == '<' || c == '>' || c == '[' || c == ']' || c == ',' || c == '?');
        if word.is_empty() {
            continue;
        }
        // Filter out builtins and lowercase names
        if word.chars().next().map_or(false, |c| c.is_uppercase() || c == '_') {
            out.push(word.to_string());
        }
    }
    out
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn state_key(owner: &str, field: &str) -> String {
    format!("{}\u{0}{}", owner, field)
}

fn split_method_key(key: &str) -> (String, String) {
    let parts: Vec<&str> = key.split('\u{0}').collect();
    if parts.len() >= 2 {
        (parts[0].to_string(), parts[1].to_string())
    } else {
        (String::new(), key.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::syntax::Language;

    fn test_document() -> Document {
        Document {
            file: "test.rb".to_string(),
            language: Language::Ruby,
            function_defs: vec![syntax::FunctionDef {
                file: "test.rb".to_string(),
                name: "hello".to_string(),
                owner: "Greeter".to_string(),
                line: 1,
                span: [1, 0, 1, 10],
                body: crate::ast::RawNode {
                    kind: "method".to_string(),
                    text: "def hello(name)".to_string(),
                    span: [1, 0, 1, 10],
                    named: true,
                    field_name: None,
                    children: vec![],
                },
                visibility: Some("public".to_string()),
                params: vec!["name".to_string()],
                signature: "def hello(name)".to_string(),
            }],
            owner_defs: vec![syntax::OwnerDef {
                file: "test.rb".to_string(),
                name: "Greeter".to_string(),
                kind: "class".to_string(),
                line: 1,
                span: [1, 0, 1, 16],
            }],
            state_declarations: vec![syntax::StateDeclaration {
                field: "@name".to_string(),
                owner: "Greeter".to_string(),
                r#type: Some("String".to_string()),
                file: "test.rb".to_string(),
                line: 2,
                span: [2, 0, 2, 14],
            }],
            state_param_origins: vec![syntax::StateParamOrigin {
                field: "@name".to_string(),
                receiver: "self".to_string(),
                owner: "Greeter".to_string(),
                param: "name".to_string(),
                file: "test.rb".to_string(),
                function: "initialize".to_string(),
                line: 2,
                span: [2, 0, 2, 14],
            }],
            call_sites: vec![],
            state_reads: vec![],
            state_writes: vec![],
            decision_sites: vec![],
            branch_decisions: vec![],
            branch_arms: vec![],
            dispatch_sites: vec![],
            semantic_effect_sites: vec![],
            local_complexity_scores: Default::default(),
            local_methods: vec![],
            predicate_aliases: vec![],
            comparison_uses: vec![],
            path_condition_sites: vec![],
            protocol_method_effects: vec![],
            protocol_call_paths: vec![],
            clone_candidates: vec![],
            redundant_nil_guards: vec![],
            immutable_struct_readers: Default::default(),
            immutable_struct_reader_types: Default::default(),
            type_aliases: Default::default(),
            method_param_types: Default::default(),
        }
    }

    #[test]
    fn extracts_methods() {
        let doc = test_document();
        let output = extract(&doc, Profile::Espalier);
        assert_eq!(output.methods.len(), 1);
        let method = &output.methods[0];
        assert_eq!(method.name, "hello");
        assert_eq!(method.owner, "Greeter");
        assert_eq!(method.kind, "instance");
        assert_eq!(method.signature, "def hello(name)");
    }

    #[test]
    fn extracts_fields() {
        let doc = test_document();
        let output = extract(&doc, Profile::Espalier);
        assert_eq!(output.fields.len(), 1);
        assert_eq!(output.fields[0].name, "@name");
    }

    #[test]
    fn extracts_state_types() {
        let doc = test_document();
        let output = extract(&doc, Profile::Espalier);
        assert_eq!(output.state_types.len(), 1);
        assert_eq!(
            output.state_types.get("Greeter\u{0}@name").map(|s| s.as_str()),
            Some("String")
        );
    }

    #[test]
    fn nil_kill_profile_still_returns_core_facts() {
        let doc = test_document();
        let output = extract(&doc, Profile::NilKill);
        assert_eq!(output.methods.len(), 1);
        assert_eq!(output.fields.len(), 1);
    }
}