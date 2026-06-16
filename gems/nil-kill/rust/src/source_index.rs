use anyhow::{Context, Result};
use decomplex_rust::decomplex::ast as shared_ast;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::path::{Path, PathBuf};
use tree_sitter::{Language, Node, Parser};

pub fn run(
    root: &Path,
    target_dirs: Vec<String>,
    exclude_dirs: Vec<String>,
    files: Vec<PathBuf>,
    usage_files: Vec<PathBuf>,
) -> Result<Value> {
    let mut parser = Parser::new();
    parser
        .set_language(&ruby_language())
        .context("failed to initialize tree-sitter ruby parser")?;

    let mut global = GlobalState::default();
    let mut indexed = Vec::new();

    for path in files {
        let source = fs::read_to_string(&path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let tree = parser
            .parse(&source, None)
            .with_context(|| format!("tree-sitter produced no tree for {}", path.display()))?;
        let rel = rel_path(root, &path);
        let lines = source.lines().map(ToString::to_string).collect::<Vec<_>>();
        let mut file = SourceFile::new(path, rel, source, lines, tree);
        file.collect_prescan(&mut global);
        indexed.push(file);
    }

    let mut bundle = Bundle::new(target_dirs, exclude_dirs);
    for file in &indexed {
        let indexer = FileIndexer::new(file, &mut global);
        let facts = indexer.index();
        bundle.add_file(file, facts);
    }

    for path in usage_files {
        let source = fs::read_to_string(&path)
            .with_context(|| format!("failed to read {}", path.display()))?;
        let tree = parser
            .parse(&source, None)
            .with_context(|| format!("tree-sitter produced no tree for {}", path.display()))?;
        let rel = rel_path(root, &path);
        let lines = source.lines().map(ToString::to_string).collect::<Vec<_>>();
        let file = SourceFile::new(path, rel, source, lines, tree);
        let mut facts = FileFacts::new();
        collect_return_usage_facts(&file, &mut facts);
        bundle.add_usage_file(facts);
    }

    Ok(bundle.into_value())
}

fn ruby_language() -> Language {
    tree_sitter_ruby::LANGUAGE.into()
}

#[derive(Default)]
struct GlobalState {
    class_like_constants: BTreeSet<String>,
    struct_fields_by_name: BTreeMap<String, Vec<String>>,
    struct_full_by_name: BTreeMap<String, String>,
    method_return_types: BTreeMap<String, BTreeSet<String>>,
    static_return_types: BTreeMap<String, String>,
    static_hash_return_shapes: BTreeMap<String, Value>,
    static_array_element_return_shapes: BTreeMap<String, Value>,
    noreturn_methods: BTreeSet<String>,
}

struct SourceFile {
    abs: PathBuf,
    rel: String,
    source: String,
    lines: Vec<String>,
    tree: tree_sitter::Tree,
    local_names_by_scope: BTreeMap<ScopeKey, BTreeSet<String>>,
}

impl SourceFile {
    fn new(
        abs: PathBuf,
        rel: String,
        source: String,
        lines: Vec<String>,
        tree: tree_sitter::Tree,
    ) -> Self {
        let mut file = Self {
            abs,
            rel,
            source,
            lines,
            tree,
            local_names_by_scope: BTreeMap::new(),
        };
        file.local_names_by_scope = build_local_name_cache(&file);
        file
    }

    fn root_node(&self) -> Node<'_> {
        self.tree.root_node()
    }

    fn collect_prescan(&mut self, global: &mut GlobalState) {
        let mut state = ScopeState::default();
        collect_prescan_node(self, self.root_node(), &mut state, global);
    }
}

type ScopeKey = (usize, usize);

#[derive(Default, Clone)]
struct ScopeState {
    scope: Vec<String>,
    class_name: Option<String>,
}

#[derive(Clone, Default)]
struct Frame {
    current_method: Option<String>,
    current_class: Option<String>,
    current_scope: Vec<String>,
    param_types: BTreeMap<String, Option<String>>,
    local_types: BTreeMap<String, String>,
    non_nil_locals: BTreeSet<String>,
    maybe_nil_locals: BTreeSet<String>,
    local_container_origins: BTreeMap<String, Value>,
    ivar_container_origins: BTreeMap<String, Value>,
    hash_shapes: BTreeMap<String, Value>,
    array_element_shapes: BTreeMap<String, Value>,
}

struct FileFacts {
    methods: Vec<Value>,
    tlet_sites: Vec<Value>,
    dead_nil_checks: Vec<Value>,
    deterministic_guards: Vec<Value>,
    struct_declarations: Vec<Value>,
    struct_field_static: Vec<Value>,
    tuple_arrays: Vec<Value>,
    hash_shapes: Vec<Value>,
    collection_index_lookups: Vec<Value>,
    hash_record_blockers: Vec<Value>,
    hash_record_member_calls: Vec<Value>,
    type_normalizers: Vec<Value>,
    dispatcher_inferences: Vec<Value>,
    return_origins: Vec<Value>,
    param_origins: Vec<Value>,
    return_usage_sites: Vec<Value>,
    return_direct_usage_sites: Vec<Value>,
    hash_record_escape_sites: Vec<Value>,
    hidden_enum_observations: Vec<Value>,
    ivar_protocols: BTreeMap<String, Vec<String>>,
    ivar_param_origins: BTreeMap<String, Vec<String>>,
}

impl FileFacts {
    fn new() -> Self {
        Self {
            methods: Vec::new(),
            tlet_sites: Vec::new(),
            dead_nil_checks: Vec::new(),
            deterministic_guards: Vec::new(),
            struct_declarations: Vec::new(),
            struct_field_static: Vec::new(),
            tuple_arrays: Vec::new(),
            hash_shapes: Vec::new(),
            collection_index_lookups: Vec::new(),
            hash_record_blockers: Vec::new(),
            hash_record_member_calls: Vec::new(),
            type_normalizers: Vec::new(),
            dispatcher_inferences: Vec::new(),
            return_origins: Vec::new(),
            param_origins: Vec::new(),
            return_usage_sites: Vec::new(),
            return_direct_usage_sites: Vec::new(),
            hash_record_escape_sites: Vec::new(),
            hidden_enum_observations: Vec::new(),
            ivar_protocols: BTreeMap::new(),
            ivar_param_origins: BTreeMap::new(),
        }
    }

    fn summary(&self) -> Value {
        json!({
            "candidate_tlet_sites": self.tlet_sites.iter().filter(|site| site.get("tlet") == Some(&Value::Bool(false))).count(),
            "collection_index_lookups": self.collection_index_lookups.len(),
            "dead_nil_checks": self.dead_nil_checks.len(),
            "deterministic_guards": self.deterministic_guards.len(),
            "hash_shapes": self.hash_shapes.len(),
            "methods": self.methods.len(),
            "param_origins": self.param_origins.len(),
            "return_origins": self.return_origins.len(),
            "return_usage_sites": self.return_usage_sites.len(),
            "hash_record_escape_sites": self.hash_record_escape_sites.len(),
            "hidden_enum_observations": self.hidden_enum_observations.len(),
            "structs": self.struct_declarations.len(),
            "tlet_sites": self.tlet_sites.iter().filter(|site| site.get("tlet") == Some(&Value::Bool(true))).count(),
            "tuple_arrays": self.tuple_arrays.len(),
            "type_normalizers": self.type_normalizers.len(),
            "unsigned_methods": self.methods.iter().filter(|m| m.get("has_sig") != Some(&Value::Bool(true))).count(),
        })
    }
}

struct Bundle {
    target_dirs: Vec<String>,
    exclude_dirs: Vec<String>,
    methods: Vec<Value>,
    facts: BTreeMap<String, Value>,
}

impl Bundle {
    fn new(target_dirs: Vec<String>, exclude_dirs: Vec<String>) -> Self {
        let mut facts = BTreeMap::new();
        facts.insert("collect_coverage".to_string(), json!({}));
        facts.insert("collection_index_lookups".to_string(), json!([]));
        facts.insert("collection_runtime".to_string(), json!([]));
        facts.insert("dead_nil_checks".to_string(), json!([]));
        facts.insert("deterministic_guards".to_string(), json!([]));
        facts.insert("dispatcher_inferences".to_string(), json!([]));
        facts.insert("existing_sigs".to_string(), json!([]));
        facts.insert("fallibility_pressure".to_string(), json!([]));
        facts.insert("files".to_string(), json!({}));
        facts.insert("flow_graph".to_string(), Value::Null);
        facts.insert("hash_record_blockers".to_string(), json!([]));
        facts.insert("hash_record_escape_sites".to_string(), json!([]));
        facts.insert("hash_record_member_calls".to_string(), json!([]));
        facts.insert("hash_shapes".to_string(), json!([]));
        facts.insert("hidden_enum_pressure".to_string(), json!([]));
        facts.insert("hidden_enum_observations".to_string(), json!([]));
        facts.insert("ivar_param_origins".to_string(), json!({}));
        facts.insert("ivar_protocols".to_string(), json!({}));
        facts.insert("ivar_runtime".to_string(), json!([]));
        facts.insert("param_origins".to_string(), json!([]));
        facts.insert("return_origins".to_string(), json!([]));
        facts.insert("return_direct_usage_sites".to_string(), json!([]));
        facts.insert("return_usage_sites".to_string(), json!([]));
        facts.insert("runtime_call_edges".to_string(), json!([]));
        facts.insert("struct_declarations".to_string(), json!([]));
        facts.insert("struct_field_static".to_string(), json!([]));
        facts.insert("tlet_sites".to_string(), json!([]));
        facts.insert("tuple_arrays".to_string(), json!([]));
        facts.insert("type_normalizers".to_string(), json!([]));
        facts.insert("unsigned_methods".to_string(), json!([]));
        Self {
            target_dirs,
            exclude_dirs,
            methods: Vec::new(),
            facts,
        }
    }

    fn add_file(&mut self, file: &SourceFile, facts: FileFacts) {
        self.object_fact_mut("files")
            .insert(file.rel.clone(), facts.summary());

        self.extend_fact("tlet_sites", facts.tlet_sites);
        self.extend_fact("dead_nil_checks", facts.dead_nil_checks);
        self.extend_fact("deterministic_guards", facts.deterministic_guards);
        self.extend_fact("struct_declarations", facts.struct_declarations);
        self.extend_fact("struct_field_static", facts.struct_field_static);
        self.extend_fact("tuple_arrays", facts.tuple_arrays);
        self.extend_fact("hash_shapes", facts.hash_shapes);
        self.extend_fact("collection_index_lookups", facts.collection_index_lookups);
        self.extend_fact("hash_record_blockers", facts.hash_record_blockers);
        self.extend_fact("hash_record_member_calls", facts.hash_record_member_calls);
        self.extend_fact("type_normalizers", facts.type_normalizers);
        self.extend_fact("dispatcher_inferences", facts.dispatcher_inferences);
        self.extend_fact("return_origins", facts.return_origins);
        self.extend_fact("param_origins", facts.param_origins);
        self.extend_fact("return_usage_sites", facts.return_usage_sites);
        self.extend_fact("return_direct_usage_sites", facts.return_direct_usage_sites);
        self.extend_fact("hash_record_escape_sites", facts.hash_record_escape_sites);
        self.extend_fact("hidden_enum_observations", facts.hidden_enum_observations);

        for method in facts.methods {
            if method.get("has_sig") == Some(&Value::Bool(true)) {
                self.array_fact_mut("existing_sigs").push(method.clone());
            } else {
                self.array_fact_mut("unsigned_methods").push(method.clone());
            }
            self.methods.push(method_record(file, &method));
        }

        let ivar_protocols = self.object_fact_mut("ivar_protocols");
        for (key, values) in facts.ivar_protocols {
            ivar_protocols.insert(key, json!(values));
        }
        let ivar_param_origins = self.object_fact_mut("ivar_param_origins");
        for (key, values) in facts.ivar_param_origins {
            ivar_param_origins.insert(key, json!(values));
        }
    }

    fn add_usage_file(&mut self, facts: FileFacts) {
        self.extend_fact("return_usage_sites", facts.return_usage_sites);
        self.extend_fact("return_direct_usage_sites", facts.return_direct_usage_sites);
    }

    fn array_fact_mut(&mut self, key: &str) -> &mut Vec<Value> {
        self.facts
            .get_mut(key)
            .and_then(Value::as_array_mut)
            .expect("array fact")
    }

    fn object_fact_mut(&mut self, key: &str) -> &mut Map<String, Value> {
        self.facts
            .get_mut(key)
            .and_then(Value::as_object_mut)
            .expect("object fact")
    }

    fn extend_fact(&mut self, key: &str, values: Vec<Value>) {
        self.array_fact_mut(key).extend(values);
    }

    fn into_value(self) -> Value {
        json!({
            "schema_version": 1,
            "target_dirs": self.target_dirs,
            "target_exclude_dirs": self.exclude_dirs,
            "methods": self.methods,
            "facts": self.facts,
        })
    }
}

fn method_record(file: &SourceFile, source: &Value) -> Value {
    let class_name = source.get("class").and_then(Value::as_str).unwrap_or("");
    let method_name = source.get("method").and_then(Value::as_str).unwrap_or("");
    let kind = source.get("kind").and_then(Value::as_str).unwrap_or("instance");
    let line = source.get("line").and_then(Value::as_i64).unwrap_or(0);
    json!({
        "calls": 0,
        "has_sig": source.get("has_sig").and_then(Value::as_bool).unwrap_or(false),
        "key": [json!(class_name), json!(method_name), json!(kind), json!(file.abs.to_string_lossy().to_string()), json!(line)],
        "ok_calls": 0,
        "param_elem": {},
        "param_elem_shapes": {},
        "param_kv": {},
        "param_kv_shapes": {},
        "param_sites": {},
        "param_sites_ok": {},
        "param_sites_raised": {},
        "param_traces": {},
        "param_traces_ok": {},
        "param_traces_raised": {},
        "params_by_name": {},
        "params_ok": {},
        "params_raised": {},
        "raised": [],
        "raised_calls": 0,
        "return_elem": [],
        "return_elem_shapes": [],
        "return_kv": [[], []],
        "return_kv_shapes": [[], []],
        "returns": [],
        "source": source,
    })
}

struct FileIndexer<'a> {
    file: &'a SourceFile,
    global: &'a mut GlobalState,
    facts: FileFacts,
}

impl<'a> FileIndexer<'a> {
    fn new(file: &'a SourceFile, global: &'a mut GlobalState) -> Self {
        Self {
            file,
            global,
            facts: FileFacts::new(),
        }
    }

    fn index(mut self) -> FileFacts {
        let mut state = ScopeState::default();
        self.walk(self.file.root_node(), &mut state, &mut Frame::default());
        collect_return_usage_facts(self.file, &mut self.facts);
        collect_hash_record_escape_facts(self.file, &mut self.facts);
        self.facts
    }

    fn walk(&mut self, node: Node<'_>, state: &mut ScopeState, frame: &mut Frame) {
        match normalized_kind(node, self.file) {
            NormKind::Class | NormKind::Module => {
                let name = const_name(class_name_node(node), self.file);
                let mut child_state = state.clone();
                if !name.is_empty() {
                    child_state.scope.push(name.clone());
                    child_state.class_name = Some(child_state.scope.join("::"));
                }
                for child in named_children(node) {
                    self.walk(child, &mut child_state, frame);
                }
            }
            NormKind::Def => {
                let method = self.method_source_record(node, state);
                let mut method_frame = Frame::default();
                method_frame.current_method = method.get("method").and_then(Value::as_str).map(ToString::to_string);
                method_frame.current_class = method.get("class").and_then(Value::as_str).map(ToString::to_string);
                method_frame.current_scope = state.scope.clone();
                for param in value_array(method.get("params")) {
                    let name = param.get("name").and_then(Value::as_str).unwrap_or("").to_string();
                    let ty = param.get("type").and_then(Value::as_str).map(ToString::to_string);
                    method_frame.param_types.insert(name.clone(), ty.clone());
                    method_frame.local_container_origins.insert(
                        name.clone(),
                        json!({
                            "kind": "method parameter",
                            "name": name,
                            "type": ty,
                            "path": self.file.rel,
                            "line": line(node),
                        }),
                    );
                    if value_string_array(method.get("non_nil_params")).contains(&name) {
                        method_frame.non_nil_locals.insert(name);
                    }
                }
                if let Some(body) = method_body(node) {
                    self.collect_local_type_facts(body, &mut method_frame);
                }

                let mut source = method.clone();
                let return_origin = self.analyze_return_origin(node, &method, &mut method_frame);
                if let Some(origin) = return_origin {
                    if origin.get("confidence").and_then(Value::as_str) == Some("strong") {
                        if let Some(candidate) = origin.get("candidate_type").and_then(Value::as_str) {
                            if useful_type(candidate) {
                                self.global
                                    .static_return_types
                                    .insert(method["method"].as_str().unwrap_or("").to_string(), candidate.to_string());
                            }
                        }
                    }
                    if let Some(shape) = origin.get("hash_shape") {
                        if !shape.is_null() {
                            self.global.static_hash_return_shapes.insert(
                                method["method"].as_str().unwrap_or("").to_string(),
                                shape.clone(),
                            );
                        }
                    }
                    if let Some(shape) = origin.get("array_element_shape") {
                        if !shape.is_null() {
                            self.global.static_array_element_return_shapes.insert(
                                method["method"].as_str().unwrap_or("").to_string(),
                                shape.clone(),
                            );
                        }
                    }
                    object_insert(&mut source, "return_origin", origin.clone());
                    self.facts.return_origins.push(origin);
                }

                let protocols = self.param_protocols(node, &source, &mut method_frame);
                object_insert(&mut source, "protocols", protocols);
                self.inspect_dispatcher(node, &source);
                if let Some(body) = method_body(node) {
                    self.walk(body, state, &mut method_frame);
                    self.collect_type_normalizers(body, &source, &method_frame);
                    self.collect_hidden_enum_observations(body, &source);
                }
                self.facts.methods.push(source);
            }
            NormKind::If => {
                self.inspect_branch_guard(node, false, frame);
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            NormKind::Unless => {
                self.inspect_branch_guard(node, true, frame);
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            NormKind::Call => {
                if lhs_element_reference_node(node) {
                    return;
                }
                self.inspect_param_origins(node, state, frame);
                self.update_collection_builder_call(node, frame);
                self.inspect_call(node, frame);
                self.inspect_index_lookup(node, state, frame);
                self.inspect_hash_record_blocker(node, state, frame);
                self.inspect_hash_record_member_call(node, state, frame);
                self.inspect_struct_constructor(node, frame);
                self.inspect_class_constructor_fields(node, frame);
                self.inspect_attribute_shape_write(node, frame);
                self.walk_call_children(node, state, frame);
            }
            NormKind::Array => {
                self.inspect_array_literal(node, frame);
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            NormKind::Hash => {
                self.inspect_hash_literal(node, frame);
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            NormKind::KeywordHash => {
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            NormKind::ConstWrite => {
                self.inspect_struct_declaration(node, state);
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            NormKind::LocalWrite => {
                self.update_local_fact(node, frame);
                self.inspect_local_container_origin(node, frame);
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            NormKind::IvarWrite | NormKind::ClassVarWrite | NormKind::GlobalVarWrite => {
                self.inspect_variable_write(node, frame);
                self.inspect_ivar_container_origin(node, frame);
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
            _ => {
                for child in named_children(node) {
                    self.walk(child, state, frame);
                }
            }
        }
    }

    fn method_source_record(&mut self, node: Node<'_>, state: &ScopeState) -> Value {
        let sig = sig_above(&self.file.lines, line(node));
        let method_params = params(node, sig.as_deref(), self.file);
        if let Some(ret) = sig.as_deref().and_then(extract_return_type) {
            self.global
                .method_return_types
                .entry(method_name(node, self.file))
                .or_default()
                .insert(ret);
        }
        let non_nil_params = non_nil_sig_params(sig.as_deref());
        let receiver = method_receiver(node);
        let kind = if receiver
            .map(|receiver| node_text(receiver, self.file) == "self")
            .unwrap_or(false)
        {
            "class"
        } else {
            "instance"
        };
        json!({
            "path": self.file.rel,
            "line": line(node),
            "end_line": end_line(node),
            "class": state.scope.join("::"),
            "method": method_name(node, self.file),
            "kind": kind,
            "has_sig": sig.is_some(),
            "sig": sig,
            "params": method_params,
            "scope": state.scope,
            "non_nil_params": non_nil_params,
            "uses_yield": method_body(node).map(|body| contains_kind(body, "yield")).unwrap_or(false),
            "untraceable_params": untraceable_param_names(node, self.file),
            "protocols": {},
            "noreturn_candidate": false,
        })
    }

    fn analyze_return_origin(
        &mut self,
        node: Node<'_>,
        record: &Value,
        frame: &mut Frame,
    ) -> Option<Value> {
        let body = method_body(node)?;
        let mut explicit = Vec::new();
        collect_explicit_returns(body, &mut explicit);
        let implicit = implicit_return_expression(body);
        let implicit_present = implicit.map(|expr| normalized_kind(expr, self.file) != NormKind::Return).unwrap_or(false);
        let mut expressions = explicit.clone();
        if implicit_present {
            if let Some(expr) = implicit {
                expressions.push(expr);
            }
        }
        let mut sources = Vec::new();
        let mut blockers = BTreeSet::new();
        for expr in &expressions {
            sources.extend(self.return_sources_for(*expr, frame, &mut blockers));
        }
        if expressions.is_empty() || sources.is_empty() {
            blockers.insert("no return expression found".to_string());
        }
        let source_types = sources
            .iter()
            .filter_map(|source| source.get("type").and_then(Value::as_str).map(ToString::to_string))
            .collect::<Vec<_>>();
        let mut candidate = static_sorbet_type(&source_types);
        if candidate == "NilClass"
            && sources.iter().any(|source| {
                matches!(
                    source.get("kind").and_then(Value::as_str),
                    Some("call_untyped" | "unknown")
                )
            })
        {
            candidate = "T.untyped".to_string();
        }
        let useful = useful_type(&candidate);
        let has_untyped_call = sources
            .iter()
            .any(|source| source.get("kind").and_then(Value::as_str) == Some("call_untyped"));
        let confidence = if useful && !weak_type(&candidate) && blockers.is_empty() && !has_untyped_call {
            "strong"
        } else if useful {
            "weak"
        } else {
            "blocked"
        };
        Some(json!({
            "path": record["path"],
            "line": record["line"],
            "end_line": record["end_line"],
            "class": record["class"],
            "method": record["method"],
            "kind": record["kind"],
            "implicit": explicit.is_empty(),
            "return_syntax": return_syntax(explicit.is_empty(), implicit_present),
            "control_shape": return_control_shape(&explicit, implicit, implicit_present, self.file),
            "candidate_type": if useful { candidate } else { "T.untyped".to_string() },
            "confidence": confidence,
            "sources": sources,
            "blockers": blockers.into_iter().collect::<Vec<_>>(),
            "hash_shape": self.hash_shape_for_return_expressions(&expressions, frame),
            "array_element_shape": self.array_element_shape_for_return_expressions(&expressions, frame),
        }))
    }

    fn return_sources_for(
        &mut self,
        node: Node<'_>,
        frame: &mut Frame,
        blockers: &mut BTreeSet<String>,
    ) -> Vec<Value> {
        let kind = normalized_kind(node, self.file);
        let code = node_text(node, self.file);
        let node_line = line(node);
        if kind == NormKind::Return {
            let args = call_arguments(node, self.file);
            if let Some(first) = args.first() {
                return self.return_sources_for(*first, frame, blockers);
            }
            return vec![json!({"kind": "nil", "type": "NilClass", "line": Value::Null, "code": "return"})];
        }
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            if let Some(expr) = implicit_return_expression(node) {
                return self.return_sources_for(expr, frame, blockers);
            }
        }
        if kind == NormKind::IvarRead || kind == NormKind::ClassVarRead || kind == NormKind::GlobalVarRead {
            blockers.insert(format!("untyped instance variable {code} at {}:{node_line}", self.file.rel));
            return vec![json!({"kind": "ivar_read", "line": node_line, "code": code})];
        }
        if kind == NormKind::If || kind == NormKind::Unless {
            let mut out = Vec::new();
            if let Some(cons) = consequent_node(node) {
                if let Some(expr) = implicit_return_expression(cons) {
                    out.extend(self.return_sources_for(expr, frame, blockers));
                }
            }
            if let Some(alt) = alternative_node(node) {
                if let Some(expr) = implicit_return_expression(alt) {
                    out.extend(self.return_sources_for(expr, frame, blockers));
                }
            } else {
                out.push(json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": "implicit else"}));
            }
            return out;
        }
        if kind == NormKind::Case {
            let mut out = Vec::new();
            for child in named_children(node) {
                if normalized_kind(child, self.file) == NormKind::When {
                    if let Some(body) = consequent_node(child) {
                        if let Some(expr) = implicit_return_expression(body) {
                            out.extend(self.return_sources_for(expr, frame, blockers));
                        }
                    }
                }
            }
            if let Some(alt) = alternative_node(node) {
                if let Some(expr) = implicit_return_expression(alt) {
                    out.extend(self.return_sources_for(expr, frame, blockers));
                }
            }
            if out.is_empty() {
                blockers.insert(format!("case return without exhaustive static branch type at {}:{node_line}", self.file.rel));
            }
            return out;
        }
        if kind == NormKind::While || kind == NormKind::Until {
            return vec![json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": code})];
        }
        if kind == NormKind::Call {
            let callee = call_name(node, self.file).unwrap_or_default();
            if assignment_call(node, self.file) {
                if let Some(arg) = assignment_value_expression(node, self.file) {
                    if let Some(arg_type) = self.expression_type(arg, frame) {
                        if useful_type(&arg_type) {
                            return vec![json!({"kind": "assignment", "callee": callee, "type": arg_type, "line": node_line, "code": code})];
                        }
                    }
                    blockers.insert(format!("assignment {callee} has unknown RHS at {}:{node_line}", self.file.rel));
                    return vec![json!({"kind": "unknown", "line": node_line, "code": code, "unknown_reasons": self.unknown_expression_reasons(arg, frame)})];
                }
            }
            if safe_navigation(node) {
                if let Some(ret) = self.known_return_type(&callee, Some(node), frame) {
                    if useful_type(&ret) {
                        return vec![json!({"kind": "safe_call", "callee": callee, "type": nilable_type(&ret), "line": node_line, "code": code, "stdlib": false})];
                    }
                }
                blockers.insert(format!("safe navigation return may be nil at {}:{node_line}", self.file.rel));
                return vec![
                    json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": code}),
                    json!({"kind": "call_untyped", "callee": callee, "line": node_line, "code": code}),
                ];
            }
            if let Some(ret) = self.known_return_type(&callee, Some(node), frame) {
                if useful_type(&ret) {
                    return vec![json!({"kind": "typed_call", "callee": callee, "type": ret, "line": node_line, "code": code, "stdlib": false})];
                }
            }
            if let Some(expr_type) = self.expression_type(node, frame) {
                if useful_type(&expr_type) {
                    return vec![json!({"kind": "static", "callee": callee, "type": expr_type, "line": node_line, "code": code})];
                }
            }
            blockers.insert(format!("untyped callee {callee} at {}:{node_line}", self.file.rel));
            return vec![json!({"kind": "call_untyped", "callee": callee, "line": node_line, "code": code})];
        }
        if matches!(
            kind,
            NormKind::LocalWrite
                | NormKind::IvarWrite
                | NormKind::ClassVarWrite
                | NormKind::GlobalVarWrite
                | NormKind::ConstWrite
        ) {
            if let Some(value) = write_value(node) {
                return self.return_sources_for(value, frame, blockers);
            }
        }
        if let Some(ty) = self.expression_type(node, frame) {
            return vec![json!({"kind": if ty == "NilClass" { "nil" } else { "static" }, "type": ty, "line": node_line, "code": code})];
        }
        blockers.insert(format!(
            "unknown return expression {} at {}:{node_line}",
            debug_node_name(kind),
            self.file.rel
        ));
        vec![json!({"kind": "unknown", "line": node_line, "code": code, "unknown_reasons": self.unknown_expression_reasons(node, frame)})]
    }

    fn collect_local_type_facts(&mut self, node: Node<'_>, frame: &mut Frame) {
        if nested_scope_node(node, self.file) {
            return;
        }
        if normalized_kind(node, self.file) == NormKind::LocalWrite {
            self.update_local_fact(node, frame);
        }
        if normalized_kind(node, self.file) == NormKind::Call {
            self.update_collection_builder_call(node, frame);
        }
        for child in named_children(node) {
            self.collect_local_type_facts(child, frame);
        }
    }

    fn expression_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        let kind = normalized_kind(node, self.file);
        if kind == NormKind::Return {
            let args = call_arguments(node, self.file);
            return args.first().and_then(|arg| self.expression_type(*arg, frame)).or_else(|| Some("NilClass".to_string()));
        }
        if kind == NormKind::Call {
            let name = call_name(node, self.file).unwrap_or_default();
            let receiver_text = call_receiver(node, self.file).map(|receiver| node_text(receiver, self.file));
            let args = call_arguments(node, self.file);
            if receiver_text.as_deref() == Some("T") && name == "let" {
                return args.get(1).map(|arg| node_text(*arg, self.file));
            }
            if receiver_text.as_deref() == Some("T") && name == "must" {
                return args.first().and_then(|arg| self.expression_type(*arg, frame));
            }
            if assignment_call(node, self.file) {
                return assignment_value_expression(node, self.file).and_then(|value| self.expression_type(value, frame));
            }
            if self.hash_shape_for_receiver(node, frame).is_some() {
                return Some("T::Hash[T.untyped, T.untyped]".to_string());
            }
            if self.array_element_shape_for_receiver(Some(node), frame).is_some() {
                return Some("T::Array[T::Hash[T.untyped, T.untyped]]".to_string());
            }
            if let Some(ret) = self.known_return_type(&name, Some(node), frame) {
                if useful_type(&ret) {
                    return Some(ret);
                }
            }
        }
        if kind == NormKind::LocalRead {
            let name = node_text(node, self.file);
            if frame.hash_shapes.contains_key(&name) {
                return Some("T::Hash[T.untyped, T.untyped]".to_string());
            }
            if frame.array_element_shapes.contains_key(&name) {
                return Some("T::Array[T::Hash[T.untyped, T.untyped]]".to_string());
            }
            if let Some(ty) = frame.local_types.get(&name) {
                if useful_type(ty) {
                    return Some(ty.clone());
                }
            }
            return frame.param_types.get(&name).and_then(Clone::clone);
        }
        if kind == NormKind::Parentheses || kind == NormKind::Statements || kind == NormKind::Else {
            return implicit_return_expression(node).and_then(|expr| self.expression_type(expr, frame));
        }
        if kind == NormKind::If || kind == NormKind::Unless {
            let left = consequent_node(node)
                .and_then(implicit_return_expression)
                .and_then(|expr| self.expression_type(expr, frame));
            let right = alternative_node(node)
                .and_then(implicit_return_expression)
                .and_then(|expr| self.expression_type(expr, frame))
                .or_else(|| Some("NilClass".to_string()));
            return Some(static_sorbet_type(&[left, right].into_iter().flatten().collect::<Vec<_>>()));
        }
        if kind == NormKind::While || kind == NormKind::Until {
            return Some("NilClass".to_string());
        }
        if kind == NormKind::Or {
            let children = named_children(node);
            if children.len() >= 2 {
                let left = self.expression_type(children[0], frame);
                let right = self.expression_type(children[1], frame);
                let non_nil = [left, right]
                    .into_iter()
                    .flatten()
                    .filter(|ty| ty != "NilClass")
                    .collect::<Vec<_>>();
                let normalized = non_nil
                    .iter()
                    .map(|ty| strip_nilable_type(ty))
                    .collect::<BTreeSet<_>>();
                if normalized.len() == 1 {
                    let ty = normalized.iter().next().unwrap().clone();
                    if useful_type(&ty) {
                        return Some(ty);
                    }
                }
                if non_nil.len() == 1 && useful_type(&non_nil[0]) {
                    return Some(non_nil[0].clone());
                }
            }
        }
        if self.array_element_shape_for_value(node, frame).is_some() {
            return Some("T::Array[T::Hash[T.untyped, T.untyped]]".to_string());
        }
        self.constant_expression_type(node).or_else(|| literal_type(node, self.file))
    }

    fn known_return_type(
        &mut self,
        method_name: &str,
        node: Option<Node<'_>>,
        frame: &mut Frame,
    ) -> Option<String> {
        if let Some(node) = node {
            if let Some(propagated) = self.propagated_core_return_type(node, frame) {
                if useful_type(&propagated) {
                    return Some(propagated);
                }
            }
        }
        if let Some(ty) = self.global.static_return_types.get(method_name) {
            if useful_type(ty) {
                return Some(ty.clone());
            }
        }
        let types = self
            .global
            .method_return_types
            .get(method_name)
            .map(|set| set.iter().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        if types.len() == 1 && useful_type(&types[0]) {
            return Some(types[0].clone());
        }
        None
    }

    fn propagated_core_return_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        let receiver = call_receiver(node, self.file)?;
        let receiver_type = self.expression_type(receiver, frame);
        let name = call_name(node, self.file)?;
        match name.as_str() {
            "[]" => self.collection_index_return_type(node, receiver_type.as_deref(), frame),
            "each" | "each_pair" | "each_value" | "each_key" => {
                receiver_type.filter(|ty| collection_receiver_type(ty))
            }
            "<<" | "push" | "concat" | "merge!" | "add" => {
                receiver_type.filter(|ty| collection_receiver_type(ty))
            }
            "length" | "size" => {
                if receiver_type.as_deref().is_some_and(|ty| collection_receiver_type(ty) || ty == "String") {
                    Some("Integer".to_string())
                } else {
                    None
                }
            }
            "empty?" | "any?" | "all?" | "none?" | "one?" | "include?" | "key?" | "has_key?" | "value?" | "has_value?" => {
                if receiver_type.as_deref().is_some_and(|ty| collection_receiver_type(ty) || ty == "String") {
                    Some("T::Boolean".to_string())
                } else {
                    None
                }
            }
            "join" => {
                if receiver_type.as_deref().is_some_and(array_receiver_type) {
                    Some("String".to_string())
                } else {
                    None
                }
            }
            "to_s" => Some("String".to_string()),
            "to_i" => Some("Integer".to_string()),
            "to_sym" => Some("Symbol".to_string()),
            "!" | "!=" | "==" | "<" | ">" | "<=" | ">=" | "eql?" | "equal?" | "===" | "frozen?" | "respond_to?" | "kind_of?" | "instance_of?" => {
                Some("T::Boolean".to_string())
            }
            "hash" => Some("Integer".to_string()),
            "inspect" => Some("String".to_string()),
            "freeze" | "dup" | "clone" | "itself" | "tap" => receiver_type.filter(|ty| useful_type(ty)),
            "+" | "-" | "*" | "/" | "%" => match receiver_type.as_deref() {
                Some("Integer" | "Float" | "Rational" | "Complex" | "String") => receiver_type,
                Some(ty) if array_receiver_type(ty) => receiver_type,
                _ => None,
            },
            _ => None,
        }
    }

    fn inspect_param_origins(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let Some(callee) = call_name(node, self.file) else { return };
        let args = call_arguments(node, self.file);
        for (idx, arg) in args.iter().enumerate() {
            if normalized_kind(*arg, self.file) == NormKind::Pair {
                let Some(key) = pair_key(*arg).and_then(|key| hash_key_name(key, self.file)) else {
                    continue;
                };
                if let Some(value) = pair_value(*arg) {
                    let record = self.param_origin_record(node, value, &callee, "keyword", &key, state, frame);
                    self.facts.param_origins.push(record);
                }
            } else {
                let record = self.param_origin_record(
                    node,
                    *arg,
                    &callee,
                    "positional",
                    &idx.to_string(),
                    state,
                    frame,
                );
                self.facts.param_origins.push(record);
            }
        }
    }

    fn param_origin_record(
        &mut self,
        call_node: Node<'_>,
        arg: Node<'_>,
        callee: &str,
        kind: &str,
        slot: &str,
        state: &ScopeState,
        frame: &mut Frame,
    ) -> Value {
        let mut ty = self.expression_type(arg, frame);
        let mut origin_kind = if ty.is_some() { "static" } else { "unknown" }.to_string();
        let mut source_method = None::<String>;
        if normalized_kind(arg, self.file) == NormKind::Call {
            source_method = call_name(arg, self.file);
            if let Some(method) = source_method.as_deref() {
                if let Some(ret) = self.known_return_type(method, Some(arg), frame) {
                    ty = Some(ret);
                    origin_kind = "typed_return".to_string();
                } else if ty.as_deref().is_some_and(useful_type) {
                    origin_kind = "typed_return".to_string();
                } else {
                    origin_kind = "untyped_return".to_string();
                }
            }
        } else if normalized_kind(arg, self.file) == NormKind::LocalRead {
            origin_kind = "local".to_string();
        }
        json!({
            "path": self.file.rel,
            "line": line(call_node),
            "enclosing_scope": state.scope.join("::"),
            "callee": callee,
            "arg_kind": kind,
            "slot": slot,
            "origin_kind": origin_kind,
            "receiver": call_receiver(call_node, self.file).map(|receiver| const_name(Some(receiver), self.file)),
            "source_method": source_method,
            "type": ty,
            "code": node_text(arg, self.file),
            "hash_shape": self.hash_shape_for_value(arg, frame),
            "array_element_shape": self.array_element_shape_for_value(arg, frame),
            "unknown_reasons": if origin_kind == "unknown" { self.unknown_expression_reasons(arg, frame) } else { Vec::<String>::new() },
        })
    }

    fn param_protocols(&mut self, node: Node<'_>, source: &Value, frame: &mut Frame) -> Value {
        let params = value_array(source.get("params"));
        let names = params
            .iter()
            .filter_map(|param| param.get("name").and_then(Value::as_str).map(ToString::to_string))
            .collect::<BTreeSet<_>>();
        let mut protocols = names
            .iter()
            .map(|name| (name.clone(), Protocol::default()))
            .collect::<BTreeMap<_, _>>();
        if let Some(body) = method_body(node) {
            self.collect_protocols(body, &names, &mut protocols, frame);
        }
        let mut out = Map::new();
        for (name, protocol) in protocols {
            out.insert(
                name,
                json!({
                    "methods": protocol.methods.into_iter().collect::<Vec<_>>(),
                    "aliases": protocol.aliases.into_iter().collect::<Vec<_>>(),
                    "gaps": protocol.gaps.into_iter().collect::<Vec<_>>(),
                }),
            );
        }
        Value::Object(out)
    }

    fn collect_protocols(
        &mut self,
        node: Node<'_>,
        names: &BTreeSet<String>,
        protocols: &mut BTreeMap<String, Protocol>,
        frame: &mut Frame,
    ) {
        match normalized_kind(node, self.file) {
            NormKind::Call => {
                if let Some(receiver) = call_receiver(node, self.file) {
                    if normalized_kind(receiver, self.file) == NormKind::LocalRead {
                        let receiver_name = node_text(receiver, self.file);
                        if let Some(protocol) = protocols.get_mut(&receiver_name) {
                            if let Some(name) = call_name(node, self.file) {
                                protocol.methods.insert(name);
                            }
                        }
                    }
                    if normalized_kind(receiver, self.file) == NormKind::IvarRead {
                        if let (Some(class), Some(name)) = (frame.current_class.as_ref(), call_name(node, self.file)) {
                            let key = format!("{class}\0{}", node_text(receiver, self.file));
                            let entry = self.facts.ivar_protocols.entry(key).or_default();
                            if !entry.contains(&name) {
                                entry.push(name);
                                entry.sort();
                            }
                        }
                    }
                }
                for (slot, arg) in call_arguments(node, self.file).iter().enumerate() {
                    if normalized_kind(*arg, self.file) == NormKind::LocalRead {
                        let name = node_text(*arg, self.file);
                        if let Some(protocol) = protocols.get_mut(&name) {
                            let callee = call_name(node, self.file).unwrap_or_default();
                            protocol.gaps.insert(format!(
                                "forwarded to {callee} slot {slot} at {}:{}",
                                self.file.rel,
                                line(node)
                            ));
                        }
                    }
                }
            }
            NormKind::LocalWrite => {
                if let Some(source) = write_value(node).and_then(|value| unwrap_alias_source(value, self.file)) {
                    if names.contains(&source) {
                        if let Some(protocol) = protocols.get_mut(&source) {
                            protocol.aliases.insert(format!(
                                "{} at {}:{}",
                                write_name(node, self.file).unwrap_or_default(),
                                self.file.rel,
                                line(node)
                            ));
                        }
                    }
                }
            }
            NormKind::IvarWrite => {
                if let Some(source) = write_value(node).and_then(|value| unwrap_alias_source(value, self.file)) {
                    if names.contains(&source) {
                        let ivar = write_name(node, self.file).unwrap_or_default();
                        if let Some(protocol) = protocols.get_mut(&source) {
                            protocol.gaps.insert(format!("captured in {ivar} at {}:{}", self.file.rel, line(node)));
                        }
                        if let Some(class) = frame.current_class.as_ref() {
                            let key = format!("{class}\0{ivar}");
                            let entry = self.facts.ivar_param_origins.entry(key).or_default();
                            if !entry.contains(&source) {
                                entry.push(source);
                                entry.sort();
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        for child in named_children(node) {
            self.collect_protocols(child, names, protocols, frame);
        }
    }

    fn inspect_call(&mut self, node: Node<'_>, frame: &mut Frame) {
        let name = call_name(node, self.file).unwrap_or_default();
        let receiver = call_receiver(node, self.file);
        let receiver_text = receiver.map(|receiver| node_text(receiver, self.file));
        if name == "let" && receiver_text.as_deref() == Some("T") {
            let args = call_arguments(node, self.file);
            self.facts.tlet_sites.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "tlet": true,
                "type": args.get(1).map(|arg| node_text(*arg, self.file)),
            }));
        } else if safe_navigation(node) {
            if let Some(receiver) = receiver {
                if self.provably_non_nil(receiver, frame) {
                    self.facts.dead_nil_checks.push(json!({
                        "path": self.file.rel,
                        "line": line(node),
                        "kind": "safe_nav",
                        "code": node_text(node, self.file),
                        "reason": format!("{} is provably non-nil", node_text(receiver, self.file)),
                    }));
                }
            }
        } else if name == "nil?" {
            if let Some(receiver) = receiver {
                if self.provably_non_nil(receiver, frame) {
                    self.facts.dead_nil_checks.push(json!({
                        "path": self.file.rel,
                        "line": line(node),
                        "kind": "nil_check",
                        "code": node_text(node, self.file),
                        "reason": format!("{} is provably non-nil; .nil? is always false", node_text(receiver, self.file)),
                    }));
                }
            }
        }
    }

    fn inspect_array_literal(&mut self, node: Node<'_>, frame: &mut Frame) {
        let elements = array_elements(node);
        if elements.len() < 2 || elements.iter().any(|elem| elem.kind() == "splat_argument") {
            return;
        }
        let types = elements
            .iter()
            .map(|elem| self.expression_type(*elem, frame))
            .collect::<Vec<_>>();
        if types.iter().any(Option::is_none) {
            return;
        }
        let values = types.into_iter().flatten().collect::<Vec<_>>();
        let unique = values.iter().collect::<BTreeSet<_>>();
        if unique.len() < 2 {
            return;
        }
        self.facts.tuple_arrays.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "size": values.len(),
            "types": values,
            "confidence": "high",
            "code": node_text(node, self.file),
        }));
    }

    fn inspect_hash_literal(&mut self, node: Node<'_>, frame: &mut Frame) {
        let pairs = hash_pairs(node);
        if pairs.is_empty() {
            return;
        }
        let mut keys = Vec::new();
        let mut values = Vec::new();
        let mut value_hash_shapes = Map::new();
        let mut value_array_shapes = Map::new();
        for pair in pairs {
            let Some(key_node) = pair_key(pair) else { continue };
            let Some(value_node) = pair_value(pair) else { continue };
            let Some(key) = hash_key_name(key_node, self.file) else { continue };
            keys.push(key.clone());
            values.push(self.expression_type(value_node, frame).map(Value::String).unwrap_or(Value::Null));
            if let Some(shape) = self.hash_shape_for_value(value_node, frame) {
                value_hash_shapes.insert(key.clone(), shape);
            }
            if let Some(shape) = self.array_element_shape_for_value(value_node, frame) {
                value_array_shapes.insert(key, shape);
            }
        }
        if keys.len() < 2 || keys.len() != hash_pairs(node).len() {
            return;
        }
        self.facts.hash_shapes.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "keys": keys,
            "value_types": values,
            "value_hash_shapes": value_hash_shapes,
            "value_array_element_shapes": value_array_shapes,
            "code": node_text(node, self.file),
        }));
    }

    fn inspect_local_container_origin(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        if let Some(value) = write_value(node) {
            if let Some(origin) = self.container_origin_for_value(value, &name, frame) {
                frame.local_container_origins.insert(name, origin);
            } else {
                frame.local_container_origins.remove(&name);
            }
        }
    }

    fn inspect_ivar_container_origin(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        if let Some(value) = write_value(node) {
            if let Some(origin) = self.container_origin_for_value(value, &name, frame) {
                frame.ivar_container_origins.insert(name, origin);
            }
        }
    }

    fn container_origin_for_value(&mut self, value: Node<'_>, name: &str, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(value, self.file) {
            NormKind::Array => {
                let types = array_elements(value)
                    .into_iter()
                    .filter_map(|elem| self.expression_type(elem, frame))
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect::<Vec<_>>();
                Some(json!({"kind": "array literal", "name": name, "path": self.file.rel, "line": line(value), "code": node_text(value, self.file), "array_element_types": types}))
            }
            NormKind::Hash | NormKind::KeywordHash => {
                let mut key_types = BTreeSet::new();
                let mut value_types = BTreeSet::new();
                for pair in hash_pairs(value) {
                    if let Some(key) = pair_key(pair) {
                        if let Some(ty) = self.expression_type(key, frame) {
                            key_types.insert(ty);
                        }
                    }
                    if let Some(val) = pair_value(pair) {
                        if let Some(ty) = self.expression_type(val, frame) {
                            value_types.insert(ty);
                        }
                    }
                }
                Some(json!({"kind": "hash literal", "name": name, "path": self.file.rel, "line": line(value), "code": node_text(value, self.file), "hash_key_types": key_types.into_iter().collect::<Vec<_>>(), "hash_value_types": value_types.into_iter().collect::<Vec<_>>() }))
            }
            NormKind::LocalRead => frame
                .local_container_origins
                .get(&node_text(value, self.file))
                .map(|origin| merge_value(origin, &[("name", json!(name)), ("alias_of", json!(node_text(value, self.file)))])),
            NormKind::IvarRead | NormKind::ClassVarRead | NormKind::GlobalVarRead => frame
                .ivar_container_origins
                .get(&node_text(value, self.file))
                .map(|origin| merge_value(origin, &[("name", json!(name)), ("alias_of", json!(node_text(value, self.file)))])),
            NormKind::Call => Some(json!({
                "kind": "forwarded return",
                "name": name,
                "path": self.file.rel,
                "line": line(value),
                "code": node_text(value, self.file),
                "callee": call_name(value, self.file).unwrap_or_default(),
            })),
            _ => None,
        }
    }

    fn inspect_index_lookup(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let name = call_name(node, self.file).unwrap_or_default();
        if name != "[]" && name != "fetch" {
            return;
        }
        let Some(receiver) = call_receiver(node, self.file) else { return };
        if sorbet_type_index_syntax(&node_text(receiver, self.file)) {
            return;
        }
        let args = call_arguments(node, self.file);
        if args.is_empty() || (name == "fetch" && args.len() > 1) {
            return;
        }
        let receiver_type = self.expression_type(receiver, frame);
        let lookup_type = self.collection_index_return_type(node, receiver_type.as_deref(), frame);
        let index_type = self.expression_type(args[0], frame);
        let origin = self.receiver_collection_origin(receiver, frame);
        self.facts.collection_index_lookups.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "enclosing_scope": state.scope.join("::"),
            "code": node_text(node, self.file),
            "receiver": node_text(receiver, self.file),
            "index": node_text(args[0], self.file),
            "receiver_type": receiver_type,
            "index_type": index_type,
            "lookup_type": lookup_type,
            "status": collection_index_status(receiver_type.as_deref(), lookup_type.as_deref()),
            "origin": origin,
        }));
    }

    fn inspect_hash_record_blocker(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let name = call_name(node, self.file).unwrap_or_default();
        let args = call_arguments(node, self.file);
        if name == "[]" || name == "fetch" {
            if name == "fetch" && args.len() > 1 {
                return;
            }
            if args.is_empty() || hash_key_name(args[0], self.file).is_some() {
                return;
            }
            let origin = self.hash_record_blocker_origin_for_receiver(receiver, frame);
            if !hash_record_blocker_origin(&origin) {
                return;
            }
            self.facts.hash_record_blockers.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "enclosing_scope": state.scope.join("::"),
                "kind": "dynamic_key",
                "code": node_text(node, self.file),
                "receiver": node_text(receiver, self.file),
                "index": args.first().map(|arg| node_text(*arg, self.file)),
                "origin": origin,
                "message": "dynamic hash-record key prevents struct accessor rewrite",
            }));
        } else if matches!(name.as_str(), "[]=" | "merge!" | "update" | "delete" | "clear" | "shift") {
            let origin = self.hash_record_blocker_origin_for_receiver(receiver, frame);
            if !hash_record_blocker_origin(&origin) {
                return;
            }
            self.facts.hash_record_blockers.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "enclosing_scope": state.scope.join("::"),
                "kind": "mutation",
                "code": node_text(node, self.file),
                "receiver": node_text(receiver, self.file),
                "origin": origin,
                "message": "shape-changing hash-record mutation prevents broad struct rewrite",
            }));
        }
    }

    fn inspect_hash_record_member_call(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let receiver_name = call_name(receiver, self.file).unwrap_or_default();
        if receiver_name != "[]" && receiver_name != "fetch" {
            return;
        }
        let args = call_arguments(receiver, self.file);
        if receiver_name == "fetch" && args.len() > 1 {
            return;
        }
        let Some(key) = args.first().and_then(|arg| hash_key_name(*arg, self.file)) else {
            return;
        };
        let Some(inner_receiver) = call_receiver(receiver, self.file) else { return };
        let origin = self.receiver_collection_origin(inner_receiver, frame);
        if !hash_record_blocker_origin(&origin)
            && origin.get("kind").and_then(Value::as_str) != Some("local hash shape")
        {
            return;
        }
        self.facts.hash_record_member_calls.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "enclosing_scope": state.scope.join("::"),
            "field": key,
            "member": call_name(node, self.file).unwrap_or_default(),
            "code": node_text(node, self.file),
            "lookup_code": node_text(receiver, self.file),
            "receiver": node_text(inner_receiver, self.file),
            "origin": origin,
        }));
    }

    fn hash_record_blocker_origin_for_receiver(&mut self, receiver: Node<'_>, frame: &mut Frame) -> Value {
        let origin = self.receiver_collection_origin(receiver, frame);
        if hash_record_blocker_origin(&origin) {
            return origin;
        }
        if normalized_kind(receiver, self.file) == NormKind::LocalRead {
            let name = node_text(receiver, self.file);
            if let Some(shape) = frame.hash_shapes.get(&name) {
                return json!({"kind": "local hash shape", "name": name, "path": self.file.rel, "line": line(receiver), "shape": shape});
            }
        }
        origin
    }

    fn receiver_collection_origin(&mut self, node: Node<'_>, frame: &mut Frame) -> Value {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                if let Some(origin) = frame.local_container_origins.get(&name) {
                    if origin.get("kind").and_then(Value::as_str) == Some("method parameter") {
                        if let Some(shape) = frame.hash_shapes.get(&name) {
                            return merge_value(origin, &[("shape", shape.clone())]);
                        }
                    }
                    return origin.clone();
                }
                if let Some(shape) = frame.hash_shapes.get(&name) {
                    return json!({"kind": "local hash shape", "name": name, "path": self.file.rel, "line": line(node), "shape": shape});
                }
                json!({"kind": "local variable", "name": name})
            }
            NormKind::IvarRead | NormKind::ClassVarRead | NormKind::GlobalVarRead => {
                let name = node_text(node, self.file);
                frame.ivar_container_origins.get(&name).cloned().unwrap_or_else(|| {
                    json!({"kind": "instance variable", "name": name})
                })
            }
            NormKind::Array | NormKind::Hash | NormKind::KeywordHash => self
                .container_origin_for_value(node, "literal", frame)
                .unwrap_or_else(|| json!({"kind": debug_node_name(normalized_kind(node, self.file)), "code": node_text(node, self.file)})),
            NormKind::Call => {
                if let Some(shape) = self.hash_shape_for_receiver(node, frame) {
                    json!({"kind": "local hash shape", "name": node_text(node, self.file), "path": self.file.rel, "line": line(node), "shape": shape})
                } else {
                    json!({"kind": "forwarded return", "callee": call_name(node, self.file).unwrap_or_default(), "path": self.file.rel, "line": line(node), "code": node_text(node, self.file)})
                }
            }
            _ => json!({"kind": debug_node_name(normalized_kind(node, self.file)), "code": node_text(node, self.file)}),
        }
    }

    fn collection_index_return_type(
        &mut self,
        node: Node<'_>,
        receiver_type: Option<&str>,
        frame: &mut Frame,
    ) -> Option<String> {
        let args = call_arguments(node, self.file);
        if args.len() != 1 {
            return None;
        }
        if let Some(shape_type) = self.hash_shape_index_return_type(call_receiver(node, self.file), args[0], frame) {
            if useful_type(&shape_type) {
                return Some(shape_type);
            }
        }
        let info = collection_type_info(receiver_type.unwrap_or(""))?;
        match info.kind.as_str() {
            "array" => {
                let elem = info.element?;
                if elem.is_empty() || elem.contains("T.untyped") {
                    return None;
                }
                if normalized_kind(args[0], self.file) == NormKind::Range {
                    Some(format!("T::Array[{elem}]"))
                } else if self.expression_type(args[0], frame).as_deref() == Some("Integer") {
                    Some(nilable_type(&elem))
                } else {
                    None
                }
            }
            "hash" => {
                let value = info.value?;
                if value.is_empty() || value.contains("T.untyped") {
                    None
                } else {
                    Some(nilable_type(&value))
                }
            }
            _ => None,
        }
    }

    fn hash_shape_index_return_type(
        &mut self,
        receiver: Option<Node<'_>>,
        index: Node<'_>,
        frame: &mut Frame,
    ) -> Option<String> {
        let shape = self.hash_shape_for_receiver(receiver?, frame)?;
        if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
            return None;
        }
        let key = hash_key_name(index, self.file)?;
        let types = shape
            .get("keys")
            .and_then(|keys| keys.get(&key))
            .and_then(Value::as_array)?
            .iter()
            .filter_map(Value::as_str)
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        if types.is_empty() {
            return None;
        }
        let value = static_sorbet_type(&types);
        useful_type(&value).then(|| nilable_type(&value))
    }

    fn update_local_fact(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        let Some(value) = write_value(node) else { return };
        if let Some(shape) = self.hash_shape_for_value(value, frame) {
            frame.hash_shapes.insert(name.clone(), shape);
        } else if normalized_kind(value, self.file) == NormKind::LocalRead {
            let src = node_text(value, self.file);
            if let Some(shape) = frame.hash_shapes.get(&src).cloned() {
                frame.hash_shapes.insert(name.clone(), shape);
            } else {
                frame.hash_shapes.remove(&name);
            }
        } else {
            frame.hash_shapes.remove(&name);
        }
        if let Some(shape) = self.array_element_shape_for_value(value, frame) {
            frame.array_element_shapes.insert(name.clone(), shape);
        } else if normalized_kind(value, self.file) == NormKind::LocalRead {
            let src = node_text(value, self.file);
            if let Some(shape) = frame.array_element_shapes.get(&src).cloned() {
                frame.array_element_shapes.insert(name.clone(), shape);
            } else {
                frame.array_element_shapes.remove(&name);
            }
        } else {
            frame.array_element_shapes.remove(&name);
        }
        if let Some(ty) = self.expression_type(value, frame) {
            if useful_type(&ty) {
                frame.local_types.insert(name.clone(), ty);
            } else {
                frame.local_types.remove(&name);
            }
        } else {
            frame.local_types.remove(&name);
        }
        if self.non_nil_literal(value, frame) && !frame.maybe_nil_locals.contains(&name) {
            frame.non_nil_locals.insert(name);
        } else {
            frame.non_nil_locals.remove(&name);
            frame.maybe_nil_locals.insert(name);
        }
    }

    fn update_collection_builder_call(&mut self, _node: Node<'_>, _frame: &mut Frame) {
        let node = _node;
        let frame = _frame;
        let Some(receiver) = call_receiver(node, self.file) else { return };
        if normalized_kind(receiver, self.file) != NormKind::LocalRead {
            return;
        }
        let receiver_name = node_text(receiver, self.file);
        let name = call_name(node, self.file).unwrap_or_default();
        let args = call_arguments(node, self.file);
        match name.as_str() {
            "<<" | "push" | "add" => {
                if let Some(arg) = args.first() {
                    if let Some(shape) = self.hash_shape_for_value(*arg, frame) {
                        merge_frame_array_shape(frame, &receiver_name, shape);
                    }
                }
            }
            "concat" => {
                if let Some(arg) = args.first() {
                    if let Some(shape) = self.array_element_shape_for_value(*arg, frame) {
                        merge_frame_array_shape(frame, &receiver_name, shape);
                    }
                }
            }
            _ => {}
        }
    }

    fn walk_call_children(&mut self, node: Node<'_>, state: &mut ScopeState, frame: &mut Frame) {
        let block = call_block(node);
        let seed_shape = call_receiver(node, self.file).and_then(|receiver| {
            if normalized_kind(receiver, self.file) == NormKind::LocalRead
                && matches!(
                    call_name(node, self.file).as_deref(),
                    Some("each" | "map" | "filter_map" | "select" | "reject" | "find" | "detect" | "any?" | "all?" | "none?" | "one?")
                )
            {
                frame.array_element_shapes.get(&node_text(receiver, self.file)).cloned()
            } else {
                None
            }
        });
        for child in named_children(node) {
            if Some(child) == block {
                let mut block_frame = frame.clone();
                let block_names = block_param_names(child, self.file);
                if let Some(shape) = seed_shape.clone() {
                    for name in &block_names {
                        block_frame.hash_shapes.insert(name.clone(), shape.clone());
                    }
                }
                self.walk(child, state, &mut block_frame);
                for (name, shape) in block_frame.array_element_shapes {
                    if !block_names.contains(&name) {
                        frame.array_element_shapes.insert(name, shape);
                    }
                }
            } else {
                self.walk(child, state, frame);
            }
        }
    }

    fn inspect_variable_write(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        let Some(value) = write_value(node) else { return };
        if normalized_kind(value, self.file) == NormKind::Call
            && call_name(value, self.file).as_deref() == Some("let")
            && call_receiver(value, self.file).map(|receiver| node_text(receiver, self.file)) == Some("T".to_string())
        {
            return;
        }
        let ty = self.static_expression_type(value, frame);
        if ty.as_deref() == Some("NilClass") {
            return;
        }
        if let Some(ty) = ty {
            self.facts.tlet_sites.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "tlet": false,
                "name": name,
                "candidate_type": ty,
            }));
        }
    }

    fn static_expression_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        self.constant_expression_type(node).or_else(|| literal_type(node, self.file)).or_else(|| {
            if normalized_kind(node, self.file) == NormKind::Call {
                self.expression_type(node, frame)
            } else {
                None
            }
        })
    }

    fn constant_expression_type(&self, node: Node<'_>) -> Option<String> {
        if !matches!(normalized_kind(node, self.file), NormKind::ConstRead | NormKind::ConstPath) {
            return None;
        }
        let name = node_text(node, self.file);
        if name.is_empty() {
            return None;
        }
        let bare = name.trim_start_matches("::").to_string();
        if CORE_CLASS_CONSTANTS.contains(&bare.as_str()) || self.global.class_like_constants.contains(&bare) {
            Some(format!("T.class_of({name})"))
        } else {
            None
        }
    }

    fn hash_shape_for_return_expressions(&mut self, expressions: &[Node<'_>], frame: &mut Frame) -> Value {
        let mut shapes = Vec::new();
        for expr in expressions {
            if self.nil_return_expression(*expr) {
                continue;
            }
            if let Some(shape) = self.hash_shape_for_expression(*expr, frame) {
                shapes.push(shape);
            } else {
                return Value::Null;
            }
        }
        if shapes.is_empty() {
            Value::Null
        } else {
            shapes.into_iter().reduce(merge_hash_record_shapes).unwrap_or(Value::Null)
        }
    }

    fn hash_shape_for_expression(&mut self, expr: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let kind = normalized_kind(expr, self.file);
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            return implicit_return_expression(expr).and_then(|inner| self.hash_shape_for_expression(inner, frame));
        }
        if kind == NormKind::Return {
            return call_arguments(expr, self.file)
                .first()
                .and_then(|arg| self.hash_shape_for_expression(*arg, frame));
        }
        if kind == NormKind::If {
            let left = consequent_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.hash_shape_for_expression(inner, frame));
            let right = alternative_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.hash_shape_for_expression(inner, frame));
            return match (left, right) {
                (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                _ => None,
            };
        }
        self.hash_shape_for_value(expr, frame)
    }

    fn hash_shape_for_value(&mut self, value: Node<'_>, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(value, self.file) {
            NormKind::Hash | NormKind::KeywordHash => {
                let mut keys = Map::new();
                let mut value_hash_shapes = Map::new();
                let mut value_array_shapes = Map::new();
                let mut poisoned = false;
                for pair in hash_pairs(value) {
                    let Some(key_node) = pair_key(pair) else {
                        continue;
                    };
                    let Some(value_node) = pair_value(pair) else {
                        continue;
                    };
                    if let Some(key) = hash_key_name(key_node, self.file) {
                        let ty = self.expression_type(value_node, frame).unwrap_or_else(|| "T.untyped".to_string());
                        let entry = keys.entry(key.clone()).or_insert_with(|| json!([]));
                        if let Some(array) = entry.as_array_mut() {
                            if !array.iter().any(|entry| entry.as_str() == Some(&ty)) {
                                array.push(json!(ty));
                            }
                        }
                        if let Some(nested) = self.hash_shape_for_value(value_node, frame) {
                            value_hash_shapes.insert(key.clone(), nested);
                        }
                        if let Some(nested) = self.array_element_shape_for_value(value_node, frame) {
                            value_array_shapes.insert(key, nested);
                        }
                    } else {
                        poisoned = true;
                    }
                }
                Some(json!({
                    "keys": keys,
                    "value_hash_shapes": value_hash_shapes,
                    "value_array_element_shapes": value_array_shapes,
                    "poisoned": poisoned,
                }))
            }
            NormKind::LocalRead => frame.hash_shapes.get(&node_text(value, self.file)).cloned(),
            NormKind::Call => {
                if assignment_call(value, self.file) {
                    assignment_value_expression(value, self.file).and_then(|arg| self.hash_shape_for_value(arg, frame))
                } else if call_receiver(value, self.file).map(|receiver| node_text(receiver, self.file)) == Some("T".to_string())
                    && matches!(call_name(value, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(value, self.file)
                        .first()
                        .and_then(|arg| self.hash_shape_for_value(*arg, frame))
                } else if call_receiver(value, self.file).is_none() {
                    call_name(value, self.file).and_then(|name| self.global.static_hash_return_shapes.get(&name).cloned())
                } else {
                    None
                }
            }
            NormKind::Or => {
                let children = named_children(value);
                match (children.first(), children.get(1)) {
                    (Some(left), Some(right)) => match (
                        self.hash_shape_for_value(*left, frame),
                        self.hash_shape_for_value(*right, frame),
                    ) {
                        (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                        (Some(l), None) => Some(l),
                        (None, Some(r)) => Some(r),
                        _ => None,
                    },
                    _ => None,
                }
            }
            _ => None,
        }
    }

    fn array_element_shape_for_return_expressions(&mut self, expressions: &[Node<'_>], frame: &mut Frame) -> Value {
        let mut shapes = Vec::new();
        for expr in expressions {
            if self.nil_return_expression(*expr) {
                continue;
            }
            if let Some(shape) = self.array_element_shape_for_expression(*expr, frame) {
                shapes.push(shape);
            } else {
                return Value::Null;
            }
        }
        if shapes.is_empty() {
            Value::Null
        } else {
            shapes.into_iter().reduce(merge_hash_record_shapes).unwrap_or(Value::Null)
        }
    }

    fn array_element_shape_for_expression(&mut self, expr: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let kind = normalized_kind(expr, self.file);
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            return implicit_return_expression(expr).and_then(|inner| self.array_element_shape_for_expression(inner, frame));
        }
        if kind == NormKind::Return {
            return call_arguments(expr, self.file)
                .first()
                .and_then(|arg| self.array_element_shape_for_expression(*arg, frame));
        }
        if kind == NormKind::If {
            let left = consequent_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.array_element_shape_for_expression(inner, frame));
            let right = alternative_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.array_element_shape_for_expression(inner, frame));
            return match (left, right) {
                (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                _ => None,
            };
        }
        self.array_element_shape_for_value(expr, frame)
    }

    fn array_element_shape_for_value(&mut self, value: Node<'_>, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(value, self.file) {
            NormKind::Array => {
                let shapes = array_elements(value)
                    .into_iter()
                    .filter_map(|elem| self.hash_shape_for_value(elem, frame))
                    .collect::<Vec<_>>();
                if shapes.is_empty() {
                    None
                } else {
                    shapes.into_iter().reduce(merge_hash_record_shapes)
                }
            }
            NormKind::LocalRead => frame.array_element_shapes.get(&node_text(value, self.file)).cloned(),
            NormKind::Call => {
                if assignment_call(value, self.file) {
                    assignment_value_expression(value, self.file).and_then(|arg| self.array_element_shape_for_value(arg, frame))
                } else if call_receiver(value, self.file).map(|receiver| node_text(receiver, self.file)) == Some("T".to_string())
                    && matches!(call_name(value, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(value, self.file)
                        .first()
                        .and_then(|arg| self.array_element_shape_for_value(*arg, frame))
                } else if matches!(call_name(value, self.file).as_deref(), Some("select" | "reject" | "compact" | "first" | "last")) {
                    self.array_element_shape_for_receiver(call_receiver(value, self.file), frame)
                } else if call_receiver(value, self.file).is_none() {
                    call_name(value, self.file).and_then(|name| self.global.static_array_element_return_shapes.get(&name).cloned())
                } else {
                    None
                }
            }
            NormKind::Or => {
                let children = named_children(value);
                match (children.first(), children.get(1)) {
                    (Some(left), Some(right)) => match (
                        self.array_element_shape_for_value(*left, frame),
                        self.array_element_shape_for_value(*right, frame),
                    ) {
                        (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                        (Some(l), None) => Some(l),
                        (None, Some(r)) => Some(r),
                        _ => None,
                    },
                    _ => None,
                }
            }
            _ => None,
        }
    }

    fn hash_shape_for_receiver(&mut self, receiver: Node<'_>, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(receiver, self.file) {
            NormKind::LocalRead => frame.hash_shapes.get(&node_text(receiver, self.file)).cloned(),
            NormKind::Hash | NormKind::KeywordHash => self.hash_shape_for_value(receiver, frame),
            NormKind::Call => {
                if call_receiver(receiver, self.file).map(|r| node_text(r, self.file)) == Some("T".to_string())
                    && matches!(call_name(receiver, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(receiver, self.file)
                        .first()
                        .and_then(|arg| self.hash_shape_for_receiver(*arg, frame))
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn array_element_shape_for_receiver(&mut self, receiver: Option<Node<'_>>, frame: &mut Frame) -> Option<Value> {
        let receiver = receiver?;
        match normalized_kind(receiver, self.file) {
            NormKind::LocalRead => frame.array_element_shapes.get(&node_text(receiver, self.file)).cloned(),
            NormKind::Array => self.array_element_shape_for_value(receiver, frame),
            NormKind::Call => {
                if call_receiver(receiver, self.file).map(|r| node_text(r, self.file)) == Some("T".to_string())
                    && matches!(call_name(receiver, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(receiver, self.file)
                        .first()
                        .and_then(|arg| self.array_element_shape_for_receiver(Some(*arg), frame))
                } else if matches!(call_name(receiver, self.file).as_deref(), Some("select" | "reject" | "compact")) {
                    self.array_element_shape_for_receiver(call_receiver(receiver, self.file), frame)
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn inspect_struct_constructor(&mut self, node: Node<'_>, frame: &mut Frame) {
        if call_name(node, self.file).as_deref() != Some("new") {
            return;
        }
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let klass = const_name(Some(receiver), self.file);
        let fields = self
            .global
            .struct_fields_by_name
            .get(&klass)
            .or_else(|| self.global.struct_fields_by_name.get(klass.rsplit("::").next().unwrap_or("")))
            .cloned();
        let Some(fields) = fields else { return };
        let full_class = self
            .global
            .struct_full_by_name
            .get(&klass)
            .or_else(|| self.global.struct_full_by_name.get(klass.rsplit("::").next().unwrap_or("")))
            .cloned()
            .unwrap_or(klass);
        for (idx, arg) in call_arguments(node, self.file).iter().enumerate() {
            if idx >= fields.len()
                || matches!(normalized_kind(*arg, self.file), NormKind::KeywordHash | NormKind::Pair)
            {
                continue;
            }
            let ty = self.expression_type(*arg, frame);
            self.facts.struct_field_static.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "class": full_class,
                "field": fields[idx],
                "type": ty,
                "expression": node_text(*arg, self.file),
            }));
        }
    }

    fn inspect_struct_declaration(&mut self, node: Node<'_>, state: &ScopeState) {
        let Some(value) = write_value(node) else { return };
        if !(struct_new_call(value, self.file) || data_define_call(value, self.file)) {
            return;
        }
        let Some(name) = write_name(node, self.file) else { return };
        let class = if state.scope.is_empty() {
            name
        } else {
            format!("{}::{name}", state.scope.join("::"))
        };
        let fields = struct_fields(value, self.file);
        if fields.is_empty() {
            return;
        }
        self.facts.struct_declarations.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "class": class,
            "fields": fields,
        }));
    }

    fn inspect_class_constructor_fields(&mut self, node: Node<'_>, frame: &mut Frame) {
        if call_name(node, self.file).as_deref() != Some("new") {
            return;
        }
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let klass = const_name(Some(receiver), self.file);
        if klass.is_empty() || klass == "Struct" {
            return;
        }
        for arg in call_arguments(node, self.file) {
            if normalized_kind(arg, self.file) == NormKind::Pair {
                if let Some(value) = pair_value(arg) {
                    let _ = self.expression_type(value, frame);
                }
            }
        }
    }

    fn inspect_attribute_shape_write(&mut self, _node: Node<'_>, _frame: &mut Frame) {}

    fn inspect_dispatcher(&mut self, node: Node<'_>, record: &Value) {
        let params = value_array(record.get("params"));
        let Some(param) = params.first().and_then(|param| param.get("name")).and_then(Value::as_str) else {
            return;
        };
        let mut arms = Vec::new();
        if let Some(body) = method_body(node) {
            collect_dispatch_arms(body, param, self.file, &mut arms);
        }
        let mut grouped = BTreeMap::<String, BTreeSet<String>>::new();
        for (helper, classes) in arms {
            grouped.entry(helper).or_default().extend(classes);
        }
        for (helper, classes) in grouped {
            if classes.is_empty() {
                continue;
            }
            let classes_vec = classes.into_iter().collect::<Vec<_>>();
            let ty = if classes_vec.len() == 1 {
                classes_vec[0].clone()
            } else {
                format!("T.any({})", classes_vec.join(", "))
            };
            self.facts.dispatcher_inferences.push(json!({
                "path": self.file.rel,
                "line": record["line"],
                "class": record["class"],
                "kind": record["kind"],
                "dispatcher": record["method"],
                "helper": helper,
                "type": ty,
                "classes": classes_vec,
            }));
        }
    }

    fn collect_type_normalizers(&mut self, body: Node<'_>, record: &Value, frame: &Frame) {
        let param_names = value_array(record.get("params"))
            .iter()
            .filter_map(|param| param.get("name").and_then(Value::as_str).map(ToString::to_string))
            .collect::<BTreeSet<_>>();
        let mut assigns = BTreeMap::<String, Node<'_>>::new();
        collect_assigns(body, self.file, &mut assigns);
        let mut visitor_frame = frame.clone();
        self.collect_type_normalizers_node(body, record, &param_names, &assigns, &mut visitor_frame);
    }

    fn collect_type_normalizers_node(
        &mut self,
        node: Node<'_>,
        record: &Value,
        param_names: &BTreeSet<String>,
        assigns: &BTreeMap<String, Node<'_>>,
        frame: &mut Frame,
    ) {
        if normalized_kind(node, self.file) == NormKind::Call
            && matches!(call_name(node, self.file).as_deref(), Some("is_a?" | "kind_of?"))
            && call_receiver(node, self.file).is_some()
        {
            let args = call_arguments(node, self.file);
            if args.len() == 1 && node_text(args[0], self.file) == "Type" {
                let (origin_kind, origin_name) =
                    self.classify_origin(call_receiver(node, self.file).unwrap(), param_names, assigns, 0, frame);
                self.facts.type_normalizers.push(json!({
                    "path": self.file.rel,
                    "line": line(node),
                    "class": record["class"],
                    "method": record["method"],
                    "code": node_text(node, self.file).lines().next().unwrap_or("").trim().chars().take(120).collect::<String>(),
                    "origin_kind": origin_kind,
                    "origin_name": origin_name,
                }));
            }
        }
        for child in named_children(node) {
            self.collect_type_normalizers_node(child, record, param_names, assigns, frame);
        }
    }

    fn collect_hidden_enum_observations(&mut self, body: Node<'_>, record: &Value) {
        let params = value_array(record.get("params"))
            .into_iter()
            .filter_map(|param| {
                let name = param.get("name").and_then(Value::as_str)?.to_string();
                Some((name, param))
            })
            .collect::<BTreeMap<_, _>>();
        self.collect_hidden_enum_observations_node(body, record, &params);
    }

    fn collect_hidden_enum_observations_node(
        &mut self,
        node: Node<'_>,
        record: &Value,
        params: &BTreeMap<String, Value>,
    ) {
        match normalized_kind(node, self.file) {
            NormKind::Case => {
                if let Some(slot) = condition_node(node).and_then(|condition| self.hidden_enum_slot_for(condition, record, params)) {
                    let values = case_literal_values(node, self.file);
                    self.record_hidden_enum_observation(slot, values, node, "case");
                }
            }
            NormKind::Call => {
                let name = call_name(node, self.file).unwrap_or_default();
                if matches!(name.as_str(), "==" | "!=" | "===") {
                    let args = call_arguments(node, self.file);
                    if args.len() == 1 {
                        if let Some(slot) = call_receiver(node, self.file).and_then(|receiver| self.hidden_enum_slot_for(receiver, record, params)) {
                            self.record_hidden_enum_observation(slot, hidden_enum_literal_values(args[0], self.file), node, &name);
                        }
                        if let Some(slot) = self.hidden_enum_slot_for(args[0], record, params) {
                            if let Some(receiver) = call_receiver(node, self.file) {
                                self.record_hidden_enum_observation(slot, hidden_enum_literal_values(receiver, self.file), node, &name);
                            }
                        }
                    }
                } else if matches!(name.as_str(), "include?" | "member?" | "key?") {
                    let args = call_arguments(node, self.file);
                    if args.len() == 1 {
                        if let Some(slot) = self.hidden_enum_slot_for(args[0], record, params) {
                            if let Some(receiver) = call_receiver(node, self.file) {
                                self.record_hidden_enum_observation(slot, hidden_enum_literal_values(receiver, self.file), node, &name);
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        for child in named_children(node) {
            self.collect_hidden_enum_observations_node(child, record, params);
        }
    }

    fn hidden_enum_slot_for(
        &self,
        node: Node<'_>,
        record: &Value,
        params: &BTreeMap<String, Value>,
    ) -> Option<Value> {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                let param = params.get(&name)?;
                let key = [
                    "param".to_string(),
                    record["path"].as_str().unwrap_or("").to_string(),
                    record["class"].as_str().unwrap_or("").to_string(),
                    record["kind"].as_str().unwrap_or("instance").to_string(),
                    record["method"].as_str().unwrap_or("").to_string(),
                    record["line"].as_i64().unwrap_or(0).to_string(),
                    name.clone(),
                ].join("\0");
                Some(json!({
                    "key": key,
                    "kind": "param",
                    "path": record["path"],
                    "line": record["line"],
                    "owner": record["class"],
                    "method": record["method"],
                    "method_kind": record["kind"],
                    "slot": name,
                    "type": param.get("type").and_then(Value::as_str).unwrap_or(""),
                }))
            }
            NormKind::IvarRead | NormKind::ClassVarRead => {
                let name = node_text(node, self.file);
                let key = [
                    "state".to_string(),
                    record["path"].as_str().unwrap_or("").to_string(),
                    record["class"].as_str().unwrap_or("").to_string(),
                    name.clone(),
                ].join("\0");
                Some(json!({
                    "key": key,
                    "kind": "state",
                    "path": record["path"],
                    "line": line(node),
                    "owner": record["class"],
                    "method": Value::Null,
                    "method_kind": Value::Null,
                    "slot": name,
                    "type": "",
                }))
            }
            _ => None,
        }
    }

    fn record_hidden_enum_observation(&mut self, slot: Value, values: Vec<Value>, site: Node<'_>, kind: &str) {
        let values = values
            .into_iter()
            .filter(|value| {
                let raw = value.get("value").and_then(Value::as_str).unwrap_or("");
                !raw.is_empty() && raw.len() <= 80
            })
            .collect::<Vec<_>>();
        if values.is_empty() {
            return;
        }
        let mut obs = slot;
        object_insert(&mut obs, "event", json!("decision"));
        object_insert(&mut obs, "values", json!(values));
        object_insert(
            &mut obs,
            "site",
            json!({
                "path": self.file.rel,
                "line": line(site),
                "kind": kind,
                "code": first_line(&node_text(site, self.file)),
            }),
        );
        self.facts.hidden_enum_observations.push(obs);
    }

    fn classify_origin(
        &mut self,
        node: Node<'_>,
        param_names: &BTreeSet<String>,
        assigns: &BTreeMap<String, Node<'_>>,
        depth: usize,
        frame: &mut Frame,
    ) -> (String, Value) {
        match normalized_kind(node, self.file) {
            NormKind::IvarRead => ("ivar".to_string(), json!(node_text(node, self.file))),
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                if param_names.contains(&name) {
                    return ("param".to_string(), json!(name));
                }
                if depth == 0 {
                    if let Some(rhs) = assigns.get(&name) {
                        return self.classify_origin(*rhs, param_names, assigns, depth + 1, frame);
                    }
                }
                ("local".to_string(), Value::Null)
            }
            NormKind::Call => {
                let name = call_name(node, self.file).unwrap_or_default();
                if name == "[]" {
                    let key = call_arguments(node, self.file)
                        .first()
                        .and_then(|key| hash_key_name(*key, self.file))
                        .map(|key| format!(":{key}"));
                    ("hashkey".to_string(), key.map(Value::String).unwrap_or(Value::Null))
                } else if !call_arguments(node, self.file).is_empty() {
                    ("call".to_string(), json!(name))
                } else if call_receiver(node, self.file).is_some() {
                    ("attr".to_string(), json!(name))
                } else {
                    ("call".to_string(), json!(name))
                }
            }
            _ => ("local".to_string(), Value::Null),
        }
    }

    fn inspect_branch_guard(&mut self, _node: Node<'_>, _inverted: bool, _frame: &mut Frame) {}

    fn provably_non_nil(&mut self, node: Node<'_>, frame: &mut Frame) -> bool {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                frame.non_nil_locals.contains(&name) && !frame.maybe_nil_locals.contains(&name)
            }
            NormKind::Call => !safe_navigation(node)
                && call_name(node, self.file)
                    .is_some_and(|name| self.global.method_return_types.get(&name).is_some_and(|types| types.len() == 1 && !types.contains("NilClass"))),
            NormKind::SelfNode => true,
            _ => self.non_nil_literal(node, frame),
        }
    }

    fn non_nil_literal(&mut self, node: Node<'_>, frame: &mut Frame) -> bool {
        self.static_expression_type(node, frame)
            .is_some_and(|ty| ty != "NilClass")
    }

    fn nil_return_expression(&mut self, expr: Node<'_>) -> bool {
        let kind = normalized_kind(expr, self.file);
        if kind == NormKind::Return {
            let args = call_arguments(expr, self.file);
            return args.first().map(|arg| self.nil_return_expression(*arg)).unwrap_or(true);
        }
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            return implicit_return_expression(expr)
                .map(|inner| self.nil_return_expression(inner))
                .unwrap_or(false);
        }
        kind == NormKind::Nil
    }

    fn unknown_expression_reasons(&mut self, node: Node<'_>, frame: &mut Frame) -> Vec<String> {
        let mut reasons = BTreeSet::new();
        self.collect_unknown_expression_reasons(node, frame, &mut reasons);
        reasons.into_iter().collect()
    }

    fn collect_unknown_expression_reasons(
        &mut self,
        node: Node<'_>,
        frame: &mut Frame,
        reasons: &mut BTreeSet<String>,
    ) {
        match normalized_kind(node, self.file) {
            NormKind::IvarRead | NormKind::IvarWrite => {
                reasons.insert(format!("instance variable {}", node_text(node, self.file)));
            }
            NormKind::ClassVarRead | NormKind::ClassVarWrite => {
                reasons.insert(format!("class variable {}", node_text(node, self.file)));
            }
            NormKind::GlobalVarRead | NormKind::GlobalVarWrite => {
                reasons.insert(format!("global variable {}", node_text(node, self.file)));
            }
            NormKind::LocalRead => {
                reasons.insert(format!("local variable {}", node_text(node, self.file)));
            }
            NormKind::ConstRead | NormKind::ConstPath => {
                if let Some(ty) = self.constant_expression_type(node) {
                    reasons.insert(format!("literal/static expression {}", static_expression_reason(&ty)));
                } else {
                    reasons.insert(format!("operation unresolved constant {}", node_text(node, self.file)));
                }
                return;
            }
            NormKind::Array => {
                reasons.insert("struct/array/collection value Array".to_string());
                return;
            }
            NormKind::Hash | NormKind::KeywordHash => {
                reasons.insert("struct/array/collection value Hash".to_string());
                return;
            }
            NormKind::Call => {
                if let Some(ty) = self.expression_type(node, frame) {
                    reasons.insert(format!("literal/static expression {}", static_expression_reason(&ty)));
                    return;
                }
                if let Some(name) = call_name(node, self.file) {
                    if self.known_return_type(&name, Some(node), frame).is_none() {
                        reasons.insert(format!("forwarded return {name}"));
                        if let Some(receiver) = call_receiver(node, self.file) {
                            self.collect_unknown_expression_reasons(receiver, frame, reasons);
                        }
                        return;
                    }
                }
            }
            _ => {
                if let Some(ty) = literal_type(node, self.file) {
                    reasons.insert(format!("literal/static expression {}", static_expression_reason(&ty)));
                    return;
                }
                reasons.insert(format!("operation {}", debug_node_name(normalized_kind(node, self.file))));
            }
        }
        for child in named_children(node) {
            self.collect_unknown_expression_reasons(child, frame, reasons);
        }
    }
}

fn collect_return_usage_facts(file: &SourceFile, facts: &mut FileFacts) {
    collect_return_usage_site_context(
        file.root_node(),
        file,
        "statement",
        None,
        &mut facts.return_usage_sites,
        false,
    );
    collect_return_usage_site_context(
        file.root_node(),
        file,
        "statement",
        None,
        &mut facts.return_direct_usage_sites,
        true,
    );
}

fn collect_return_usage_site_context(
    node: Node<'_>,
    file: &SourceFile,
    context: &str,
    current_method: Option<&str>,
    sites: &mut Vec<Value>,
    direct_usage: bool,
) {
    if node.kind() == "argument_list" {
        let arg_context = if direct_usage { "return" } else { context };
        for child in named_children(node) {
            collect_return_usage_site_context(child, file, arg_context, current_method, sites, direct_usage);
        }
        return;
    }

    match normalized_kind(node, file) {
        NormKind::Def => {
            let name = method_name(node, file);
            if let Some(body) = method_body(node) {
                collect_return_usage_site_context(body, file, "return", Some(name.as_str()), sites, direct_usage);
            }
        }
        NormKind::Program | NormKind::Statements => {
            let body = statement_expressions(node);
            let last = body.len().saturating_sub(1);
            for (idx, child) in body.into_iter().enumerate() {
                let child_context = if idx == last { context } else { "statement" };
                collect_return_usage_site_context(child, file, child_context, current_method, sites, direct_usage);
            }
        }
        NormKind::Return => {
            for child in named_children(node) {
                collect_return_usage_site_context(child, file, "return", current_method, sites, direct_usage);
            }
        }
        NormKind::If | NormKind::Unless => {
            if let Some(condition) = condition_node(node) {
                collect_return_usage_site_context(condition, file, "value", current_method, sites, direct_usage);
            }
            if let Some(consequent) = consequent_node(node) {
                collect_return_usage_site_context(consequent, file, context, current_method, sites, direct_usage);
            }
            if let Some(alternative) = alternative_node(node) {
                collect_return_usage_site_context(alternative, file, context, current_method, sites, direct_usage);
            }
        }
        NormKind::Else => {
            let body = statement_expressions(node);
            let last = body.len().saturating_sub(1);
            for (idx, child) in body.into_iter().enumerate() {
                let child_context = if idx == last { context } else { "statement" };
                collect_return_usage_site_context(child, file, child_context, current_method, sites, direct_usage);
            }
        }
        NormKind::Call => {
            if let Some(name) = call_name(node, file).filter(|name| !name.is_empty()) {
                sites.push(json!({
                    "path": file.rel,
                    "line": line(node),
                    "name": name,
                    "context": context,
                    "current_method": current_method,
                    "code": first_line(&node_text(node, file)),
                }));
            }

            if let Some(receiver) = call_receiver(node, file) {
                collect_return_usage_site_context(receiver, file, "value", current_method, sites, direct_usage);
            }
            let arg_context = if direct_usage { "return" } else { "value" };
            for arg in call_arguments(node, file) {
                collect_return_usage_site_context(arg, file, arg_context, current_method, sites, direct_usage);
            }
            if let Some(block) = call_block(node) {
                collect_return_usage_site_context(block, file, "value", current_method, sites, direct_usage);
            }
        }
        _ => {
            for child in named_children(node) {
                collect_return_usage_site_context(child, file, "value", current_method, sites, direct_usage);
            }
        }
    }
}

fn collect_hash_record_escape_facts(file: &SourceFile, facts: &mut FileFacts) {
    walk_raw(file.root_node(), &mut |node| {
        if normalized_kind(node, file) != NormKind::Hash {
            return;
        }
        let Some(reason) = hash_record_escape_reason(file.root_node(), node, file) else {
            return;
        };
        facts.hash_record_escape_sites.push(json!({
            "path": file.rel,
            "line": line(node),
            "code": node_text(node, file).trim().to_string(),
            "escapes_collection": true,
            "reason": reason,
        }));
    });
}

fn hash_record_escape_reason(root: Node<'_>, hash_node: Node<'_>, file: &SourceFile) -> Option<&'static str> {
    if hash_literal_in_array_literal(hash_node, file) {
        return Some("array_literal");
    }
    if value_in_collection_append_or_index_write(root, hash_node, file) {
        return Some("collection_append_or_index_write");
    }
    let writer = enclosing_local_write_for(hash_node, file)?;
    let name = write_name(writer, file)?;
    escape_uses_of_local(root, &name, file).then_some("local_alias_escape")
}

fn hash_literal_in_array_literal(mut node: Node<'_>, file: &SourceFile) -> bool {
    while let Some(parent) = node.parent() {
        if normalized_kind(parent, file) == NormKind::Array {
            return true;
        }
        node = parent;
    }
    false
}

fn value_in_collection_append_or_index_write(root: Node<'_>, target: Node<'_>, file: &SourceFile) -> bool {
    let mut found = false;
    walk_raw(root, &mut |node| {
        if found {
            return;
        }
        if normalized_kind(node, file) == NormKind::Call
            && call_name(node, file).is_some_and(|name| collection_append_method(&name))
            && call_arguments(node, file).into_iter().any(|arg| arg == target)
        {
            found = true;
            return;
        }
        if matches!(node.kind(), "assignment" | "operator_assignment")
            && assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference")
            && write_value(node) == Some(target)
        {
            found = true;
            return;
        }
        if normalized_kind(node, file) == NormKind::Call
            && call_name(node, file).as_deref() == Some("[]=")
            && call_arguments(node, file).last().copied() == Some(target)
        {
            found = true;
        }
    });
    found
}

fn enclosing_local_write_for<'tree>(hash_node: Node<'tree>, file: &SourceFile) -> Option<Node<'tree>> {
    let parent = hash_node.parent()?;
    if normalized_kind(parent, file) == NormKind::LocalWrite && write_value(parent) == Some(hash_node) {
        Some(parent)
    } else {
        None
    }
}

fn escape_uses_of_local(root: Node<'_>, name: &str, file: &SourceFile) -> bool {
    let mut escapes = false;
    walk_raw(root, &mut |node| {
        if escapes {
            return;
        }
        if normalized_kind(node, file) == NormKind::Call
            && call_arguments(node, file).into_iter().any(|arg| {
                normalized_kind(arg, file) == NormKind::LocalRead && node_text(arg, file) == name
            })
        {
            escapes = true;
            return;
        }
        if normalized_kind(node, file) == NormKind::Array
            && named_children(node).into_iter().any(|child| {
                normalized_kind(child, file) == NormKind::LocalRead && node_text(child, file) == name
            })
        {
            escapes = true;
        }
    });
    escapes
}

fn collection_append_method(name: &str) -> bool {
    matches!(name, "<<" | "push" | "unshift" | "append" | "prepend" | "concat")
}

fn case_literal_values(case_node: Node<'_>, file: &SourceFile) -> Vec<Value> {
    named_children(case_node)
        .into_iter()
        .filter(|child| normalized_kind(*child, file) == NormKind::When)
        .flat_map(|when_node| {
            named_children(when_node)
                .into_iter()
                .take_while(|child| !matches!(child.kind(), "then" | "body_statement" | "block_body"))
                .flat_map(|condition| hidden_enum_literal_values(condition, file))
                .collect::<Vec<_>>()
        })
        .collect()
}

fn hidden_enum_literal_values(node: Node<'_>, file: &SourceFile) -> Vec<Value> {
    match normalized_kind(node, file) {
        NormKind::Symbol => hash_key_name(node, file)
            .map(|name| vec![json!({ "kind": "Symbol", "value": format!(":{name}") })])
            .unwrap_or_default(),
        NormKind::String => {
            if named_children(node).iter().any(|child| child.kind() == "interpolation") {
                Vec::new()
            } else {
                let value = serde_json::to_string(&unquote(&node_text(node, file))).unwrap_or_else(|_| "\"\"".to_string());
                vec![json!({ "kind": "String", "value": value })]
            }
        }
        NormKind::Array => named_children(node)
            .into_iter()
            .flat_map(|child| hidden_enum_literal_values(child, file))
            .collect(),
        NormKind::Parentheses => named_children(node)
            .into_iter()
            .flat_map(|child| hidden_enum_literal_values(child, file))
            .collect(),
        _ => Vec::new(),
    }
}

#[derive(Default)]
struct Protocol {
    methods: BTreeSet<String>,
    aliases: BTreeSet<String>,
    gaps: BTreeSet<String>,
}

fn collect_prescan_node(
    file: &SourceFile,
    node: Node<'_>,
    state: &mut ScopeState,
    global: &mut GlobalState,
) {
    match normalized_kind(node, file) {
        NormKind::Class | NormKind::Module => {
            let name = const_name(class_name_node(node), file);
            let full = if state.scope.is_empty() {
                name.clone()
            } else {
                format!("{}::{name}", state.scope.join("::"))
            };
            if !name.is_empty() {
                global.class_like_constants.insert(full.clone());
                global.class_like_constants.insert(name.clone());
                state.scope.push(name);
                state.class_name = Some(full);
                for child in named_children(node) {
                    collect_prescan_node(file, child, state, global);
                }
                state.scope.pop();
                state.class_name = state.scope.last().cloned();
                return;
            }
        }
        NormKind::ConstWrite => {
            if let Some(value) = write_value(node) {
                if struct_new_call(value, file) || data_define_call(value, file) {
                    let name = write_name(node, file).unwrap_or_default();
                    let klass = if state.scope.is_empty() {
                        name.clone()
                    } else {
                        format!("{}::{name}", state.scope.join("::"))
                    };
                    let fields = struct_fields(value, file);
                    if !fields.is_empty() {
                        global.struct_fields_by_name.insert(klass.clone(), fields.clone());
                        global.struct_full_by_name.insert(klass.clone(), klass.clone());
                        if let Some(short) = klass.rsplit("::").next() {
                            global
                                .struct_fields_by_name
                                .entry(short.to_string())
                                .or_insert_with(|| fields.clone());
                            global
                                .struct_full_by_name
                                .entry(short.to_string())
                                .or_insert_with(|| klass.clone());
                        }
                    }
                    global.class_like_constants.insert(klass);
                    global.class_like_constants.insert(name);
                }
            }
        }
        NormKind::Def => {
            if let Some(sig) = sig_above(&file.lines, line(node)) {
                if let Some(ret) = extract_return_type(&sig) {
                    global
                        .method_return_types
                        .entry(method_name(node, file))
                        .or_default()
                        .insert(ret.clone());
                    if non_nil_return_sig(&sig) {
                        global.noreturn_methods.remove(&method_name(node, file));
                    }
                }
            }
        }
        _ => {}
    }
    for child in named_children(node) {
        collect_prescan_node(file, child, state, global);
    }
}

fn collect_dispatch_arms(
    node: Node<'_>,
    param_name: &str,
    file: &SourceFile,
    arms: &mut Vec<(String, Vec<String>)>,
) {
    if normalized_kind(node, file) == NormKind::Case {
        for child in named_children(node) {
            if normalized_kind(child, file) != NormKind::When {
                continue;
            }
            let helper = dispatch_helper_call(child, param_name, file);
            if let Some(helper) = helper {
                let classes = named_children(child)
                    .into_iter()
                    .filter(|candidate| normalized_kind(*candidate, file) != NormKind::Statements)
                    .filter_map(|candidate| {
                        let name = const_name(Some(candidate), file);
                        (!name.is_empty()).then_some(name)
                    })
                    .collect::<Vec<_>>();
                if !classes.is_empty() {
                    arms.push((helper, classes));
                }
            }
        }
    }
    for child in named_children(node) {
        collect_dispatch_arms(child, param_name, file, arms);
    }
}

fn dispatch_helper_call(when_node: Node<'_>, param_name: &str, file: &SourceFile) -> Option<String> {
    let body = consequent_node(when_node)?;
    let body_exprs = statement_expressions(body);
    if body_exprs.len() != 1 {
        return None;
    }
    let call = body_exprs[0];
    if normalized_kind(call, file) != NormKind::Call || call_receiver(call, file).is_some() {
        return None;
    }
    let args = call_arguments(call, file);
    if args.len() != 1 || normalized_kind(args[0], file) != NormKind::LocalRead || node_text(args[0], file) != param_name {
        return None;
    }
    call_name(call, file)
}

fn collect_explicit_returns<'tree>(node: Node<'tree>, results: &mut Vec<Node<'tree>>) {
    if nested_scope_kind(node.kind()) {
        return;
    }
    if node.kind() == "return" || normalized_kind_by_raw(node) == NormKind::Return {
        let args = raw_return_args(node);
        if let Some(first) = args.first() {
            results.push(*first);
        }
        return;
    }
    for child in named_children(node) {
        collect_explicit_returns(child, results);
    }
}

fn collect_assigns<'tree>(
    node: Node<'tree>,
    file: &SourceFile,
    assigns: &mut BTreeMap<String, Node<'tree>>,
) {
    if normalized_kind(node, file) == NormKind::LocalWrite {
        if let (Some(name), Some(value)) = (write_name(node, file), write_value(node)) {
            assigns.entry(name).or_insert(value);
        }
    }
    for child in named_children(node) {
        collect_assigns(child, file, assigns);
    }
}

fn method_body(node: Node<'_>) -> Option<Node<'_>> {
    named_children(node)
        .into_iter()
        .find(|child| matches!(child.kind(), "body_statement" | "block_body"))
        .or_else(|| node.child_by_field_name("body"))
        .or_else(|| {
        named_children(node)
            .into_iter()
            .rev()
            .find(|child| !matches!(child.kind(), "method_parameters" | "identifier" | "self"))
    })
}

fn method_receiver(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("object").or_else(|| {
        let children = all_children(node);
        let dot = children.iter().position(|child| !child.is_named() && node_text_raw(*child) == ".");
        dot.and_then(|idx| idx.checked_sub(1)).map(|idx| children[idx])
    })
}

fn method_name(node: Node<'_>, file: &SourceFile) -> String {
    node.child_by_field_name("name")
        .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "identifier"))
        .map(|child| node_text(child, file))
        .unwrap_or_default()
}

fn params(node: Node<'_>, sig: Option<&str>, file: &SourceFile) -> Vec<Value> {
    let sig_types = extract_param_entries(sig.unwrap_or(""))
        .into_iter()
        .collect::<BTreeMap<_, _>>();
    let Some(parameters) = node.child_by_field_name("parameters") else {
        return Vec::new();
    };
    named_children(parameters)
        .into_iter()
        .filter_map(|param| {
            if matches!(param.kind(), "splat_parameter" | "hash_splat_parameter" | "block_parameter") {
                return None;
            }
            let name = parameter_name(param, file)?;
            Some(json!({
                "name": name,
                "nil_default": parameter_value(param).is_some_and(|value| normalized_kind(value, file) == NormKind::Nil),
                "type": sig_types.get(&name).cloned(),
            }))
        })
        .collect()
}

fn untraceable_param_names(node: Node<'_>, file: &SourceFile) -> Vec<String> {
    let Some(parameters) = node.child_by_field_name("parameters") else {
        return Vec::new();
    };
    named_children(parameters)
        .into_iter()
        .filter(|param| matches!(param.kind(), "splat_parameter" | "hash_splat_parameter" | "block_parameter"))
        .filter_map(|param| parameter_name(param, file))
        .collect()
}

fn parameter_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    node.child_by_field_name("name")
        .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "identifier"))
        .or_else(|| (node.kind() == "identifier").then_some(node))
        .map(|child| node_text(child, file))
}

fn parameter_value(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("value").or_else(|| {
        let name = node.child_by_field_name("name");
        named_children(node)
            .into_iter()
            .find(|child| Some(*child) != name && child.kind() != "identifier")
    })
}

fn sig_above(lines: &[String], line: usize) -> Option<String> {
    if line < 2 {
        return None;
    }
    let mut idx = line as isize - 2;
    while idx >= 0 && lines.get(idx as usize).map(|line| line.trim().is_empty()).unwrap_or(false) {
        idx -= 1;
    }
    if idx < 0 {
        return None;
    }
    let stripped = lines[idx as usize].trim();
    if contains_sig_brace(stripped) {
        return Some(stripped.to_string());
    }
    if stripped == "end" {
        let floor = (idx - 40).max(0);
        let mut start = idx;
        while start >= floor {
            let current = lines[start as usize].as_str();
            if current.contains("sig do") {
                return Some(lines[start as usize..=idx as usize].join("\n"));
            }
            if current.trim_start().starts_with("def ")
                || current.trim_start().starts_with("class ")
                || current.trim_start().starts_with("module ")
            {
                break;
            }
            start -= 1;
        }
    }
    None
}

fn contains_sig_brace(line: &str) -> bool {
    line.contains("sig") && line.contains('{')
}

fn extract_param_entries(sig: &str) -> Vec<(String, String)> {
    let Some(params) = extract_call_args(sig, "params") else {
        return Vec::new();
    };
    split_top_level(&params)
        .into_iter()
        .filter_map(|entry| {
            let (name, ty) = entry.split_once(':')?;
            Some((name.trim().to_string(), ty.trim().to_string()))
        })
        .collect()
}

fn extract_return_type(sig: &str) -> Option<String> {
    extract_call_args(sig, "returns")
}

fn extract_call_args(source: &str, name: &str) -> Option<String> {
    let marker = format!("{name}(");
    let idx = source.find(&marker)?;
    let start = idx + marker.len();
    let mut depth = 1i32;
    for (offset, ch) in source[start..].char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(source[start..start + offset].to_string());
                }
            }
            _ => {}
        }
    }
    None
}

fn split_top_level(source: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut start = 0usize;
    let mut depth = 0i32;
    for (idx, ch) in source.char_indices() {
        match ch {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                let part = source[start..idx].trim();
                if !part.is_empty() {
                    parts.push(part.to_string());
                }
                start = idx + 1;
            }
            _ => {}
        }
    }
    let tail = source[start..].trim();
    if !tail.is_empty() {
        parts.push(tail.to_string());
    }
    parts
}

fn non_nil_sig_params(sig: Option<&str>) -> Vec<String> {
    let Some(sig) = sig else { return Vec::new() };
    let Some(params) = extract_call_args(sig, "params") else {
        return Vec::new();
    };
    split_top_level(&params)
        .into_iter()
        .filter_map(|entry| {
            let (name, ty) = entry.split_once(':')?;
            let ty = ty.trim();
            (!ty.contains("T.nilable") && ty != "T.untyped" && ty != "NilClass").then(|| name.trim().to_string())
        })
        .collect()
}

fn non_nil_return_sig(sig: &str) -> bool {
    extract_return_type(sig).is_some_and(|ty| {
        !ty.contains("T.nilable") && ty != "T.untyped" && ty != "NilClass"
    })
}

fn call_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    match node.kind() {
        "element_reference" => Some("[]".to_string()),
        "assignment" | "operator_assignment" if assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference") => {
            Some("[]=".to_string())
        }
        "binary" => all_children(node)
            .into_iter()
            .find(|child| !child.is_named() && !matches!(node_text_raw(*child).as_str(), "(" | ")"))
            .map(node_text_raw),
        "unary" => all_children(node)
            .into_iter()
            .find(|child| !child.is_named())
            .map(node_text_raw),
        "identifier" => Some(node_text(node, file)),
        "return" => Some("return".to_string()),
        "call" | "command" | "method_call" | "body_statement" | "block_body" | "then" => node
            .child_by_field_name("method")
            .or_else(|| method_after_dot(node))
            .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "identifier"))
            .map(|child| node_text(child, file))
            .or_else(|| {
                let text = node_text(node, file);
                identifier_like(&text).then_some(text)
            }),
        _ => None,
    }
}

fn call_receiver<'tree>(node: Node<'tree>, _file: &SourceFile) -> Option<Node<'tree>> {
    match node.kind() {
        "element_reference" => node.child_by_field_name("object").or_else(|| named_children(node).first().copied()),
        "assignment" | "operator_assignment" => assignment_lhs(node).and_then(|lhs| {
            lhs.child_by_field_name("object")
                .or_else(|| named_children(lhs).first().copied())
        }),
        "binary" => named_children(node).first().copied(),
        "unary" | "identifier" => None,
        _ => node.child_by_field_name("receiver").or_else(|| receiver_before_dot(node)),
    }
}

fn call_arguments<'tree>(node: Node<'tree>, file: &SourceFile) -> Vec<Node<'tree>> {
    match node.kind() {
        "element_reference" => named_children(node).into_iter().skip(1).collect(),
        "assignment" | "operator_assignment" if assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference") => {
            let mut out = assignment_lhs(node)
                .map(|lhs| named_children(lhs).into_iter().skip(1).collect::<Vec<_>>())
                .unwrap_or_default();
            if let Some(value) = write_value(node) {
                out.push(value);
            }
            out
        }
        "binary" => named_children(node).into_iter().skip(1).take(1).collect(),
        "return" => raw_return_args(node),
        _ => {
            if let Some(args) = node
                .child_by_field_name("arguments")
                .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "argument_list"))
            {
                return named_children(args);
            }
            named_children(node)
                .into_iter()
                .filter(|child| {
                    !matches!(
                        child.kind(),
                        "identifier" | "block" | "do_block" | "method_parameters" | "body_statement"
                    ) && Some(*child) != call_receiver(node, file)
                })
                .collect()
        }
    }
}

fn call_block(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("block").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "block" | "do_block"))
    })
}

fn block_param_names(block: Node<'_>, file: &SourceFile) -> Vec<String> {
    let Some(params) = block.child_by_field_name("parameters").or_else(|| {
        named_children(block)
            .into_iter()
            .find(|child| child.kind() == "block_parameters")
    }) else {
        return Vec::new();
    };
    named_children(params)
        .into_iter()
        .filter_map(|param| parameter_name(param, file))
        .collect()
}

fn raw_return_args(node: Node<'_>) -> Vec<Node<'_>> {
    named_children(node)
}

fn receiver_before_dot(node: Node<'_>) -> Option<Node<'_>> {
    let children = all_children(node);
    let idx = children
        .iter()
        .position(|child| !child.is_named() && matches!(node_text_raw(*child).as_str(), "." | "&."))?;
    children[..idx].iter().rev().find(|child| child.is_named()).copied()
}

fn method_after_dot(node: Node<'_>) -> Option<Node<'_>> {
    let children = all_children(node);
    let idx = children
        .iter()
        .position(|child| !child.is_named() && matches!(node_text_raw(*child).as_str(), "." | "&."))?;
    children[idx + 1..]
        .iter()
        .find(|child| child.is_named() && child.kind() == "identifier")
        .copied()
}

fn safe_navigation(node: Node<'_>) -> bool {
    all_children(node)
        .iter()
        .any(|child| !child.is_named() && node_text_raw(*child) == "&.")
}

fn assignment_lhs(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("left").or_else(|| named_children(node).first().copied())
}

fn write_value(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("right")
        .or_else(|| node.child_by_field_name("value"))
        .or_else(|| named_children(node).get(1).copied())
}

fn write_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    assignment_lhs(node).map(|target| node_text(target, file))
}

fn assignment_call(node: Node<'_>, file: &SourceFile) -> bool {
    setter_call(node, file) || index_assignment_call(node, file)
}

fn setter_call(node: Node<'_>, file: &SourceFile) -> bool {
    if normalized_kind(node, file) != NormKind::Call {
        return false;
    }
    let Some(name) = call_name(node, file) else { return false };
    name.ends_with('=') && !matches!(name.as_str(), "==" | "!=" | "<=" | ">=" | "===") && call_arguments(node, file).len() == 1
}

fn index_assignment_call(node: Node<'_>, file: &SourceFile) -> bool {
    normalized_kind(node, file) == NormKind::Call
        && call_name(node, file).as_deref() == Some("[]=")
        && call_arguments(node, file).len() >= 2
}

fn assignment_value_expression<'tree>(node: Node<'tree>, file: &SourceFile) -> Option<Node<'tree>> {
    call_arguments(node, file).last().copied()
}

fn implicit_return_expression(node: Node<'_>) -> Option<Node<'_>> {
    match node.kind() {
        "body_statement" | "block_body" | "then" if hidden_or_body_statement(node) => Some(node),
        "program" | "body_statement" | "block_body" | "then" => statement_expressions(node).last().copied(),
        "begin" | "else" | "parenthesized_statements" | "parenthesized_expression" => {
            statement_expressions(node).last().copied()
        }
        _ => Some(node),
    }
}

fn statement_expressions(node: Node<'_>) -> Vec<Node<'_>> {
    named_children(node)
        .into_iter()
        .filter(|child| !matches!(child.kind(), "rescue" | "ensure"))
        .collect()
}

fn hidden_or_body_statement(node: Node<'_>) -> bool {
    matches!(node.kind(), "body_statement" | "block_body" | "then")
        && (all_children(node)
            .iter()
            .any(|child| !child.is_named() && matches!(node_text_raw(*child).as_str(), "||" | "or"))
            || named_children(node).into_iter().any(|child| {
                child.kind() == "binary"
                    && binary_operator(child).is_some_and(|op| matches!(op.as_str(), "||" | "or"))
            }))
}

fn return_syntax(explicit_empty: bool, implicit_present: bool) -> &'static str {
    if !explicit_empty && implicit_present {
        "mixed"
    } else if !explicit_empty {
        "explicit"
    } else {
        "implicit"
    }
}

fn return_control_shape(
    explicit: &[Node<'_>],
    implicit: Option<Node<'_>>,
    implicit_present: bool,
    file: &SourceFile,
) -> &'static str {
    if explicit.len() > 1 || (!explicit.is_empty() && implicit_present) {
        return "branching";
    }
    if explicit.iter().any(|expr| branching_return_expression(*expr, file)) {
        return "branching";
    }
    if implicit_present && implicit.is_some_and(|expr| branching_return_expression(expr, file)) {
        return "branching";
    }
    "branchless"
}

fn branching_return_expression(node: Node<'_>, file: &SourceFile) -> bool {
    if matches!(
        normalized_kind(node, file),
        NormKind::If | NormKind::Case | NormKind::Rescue
    ) {
        return true;
    }
    named_children(node)
        .into_iter()
        .any(|child| branching_return_expression(child, file))
}

fn condition_node(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("condition")
        .or_else(|| named_children(node).first().copied())
}

fn consequent_node(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("consequence")
        .or_else(|| node.child_by_field_name("body"))
        .or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| matches!(child.kind(), "then" | "body_statement" | "block_body"))
        })
}

fn alternative_node(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("alternative")
        .or_else(|| node.child_by_field_name("else"))
        .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "else"))
}

fn pair_key(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("key").or_else(|| named_children(node).first().copied())
}

fn pair_value(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("value")
        .or_else(|| named_children(node).get(1).copied())
}

fn hash_pairs(node: Node<'_>) -> Vec<Node<'_>> {
    named_children(node)
        .into_iter()
        .filter(|child| child.kind() == "pair")
        .collect()
}

fn array_elements(node: Node<'_>) -> Vec<Node<'_>> {
    named_children(node)
}

fn hash_key_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    match normalized_kind(node, file) {
        NormKind::Symbol => {
            let text = node_text(node, file);
            Some(
                text.trim()
                    .trim_start_matches(':')
                    .trim_end_matches(':')
                    .to_string(),
            )
        }
        NormKind::String => Some(unquote(&node_text(node, file))),
        _ => None,
    }
}

fn struct_new_call(node: Node<'_>, file: &SourceFile) -> bool {
    normalized_kind(node, file) == NormKind::Call
        && call_name(node, file).as_deref() == Some("new")
        && call_receiver(node, file).map(|receiver| node_text(receiver, file)) == Some("Struct".to_string())
}

fn data_define_call(node: Node<'_>, file: &SourceFile) -> bool {
    normalized_kind(node, file) == NormKind::Call
        && call_name(node, file).as_deref() == Some("define")
        && call_receiver(node, file).map(|receiver| node_text(receiver, file)) == Some("Data".to_string())
}

fn struct_fields(node: Node<'_>, file: &SourceFile) -> Vec<String> {
    call_arguments(node, file)
        .into_iter()
        .filter(|arg| normalized_kind(*arg, file) == NormKind::Symbol)
        .filter_map(|arg| hash_key_name(arg, file))
        .collect()
}

fn class_name_node(node: Node<'_>) -> Option<Node<'_>> {
    named_children(node)
        .into_iter()
        .find(|child| matches!(child.kind(), "constant" | "scope_resolution"))
        .or_else(|| node.child_by_field_name("name"))
}

fn const_name(node: Option<Node<'_>>, file: &SourceFile) -> String {
    node.map(|node| node_text(node, file)).unwrap_or_default()
}

fn literal_type(node: Node<'_>, file: &SourceFile) -> Option<String> {
    match normalized_kind(node, file) {
        NormKind::String => Some("String".to_string()),
        NormKind::Symbol => Some("Symbol".to_string()),
        NormKind::Integer => Some("Integer".to_string()),
        NormKind::Float => Some("Float".to_string()),
        NormKind::True | NormKind::False => Some("T::Boolean".to_string()),
        NormKind::Nil => Some("NilClass".to_string()),
        NormKind::Range => Some("Range".to_string()),
        NormKind::InterpolatedString => Some("String".to_string()),
        NormKind::Array => Some("T::Array[T.untyped]".to_string()),
        NormKind::Hash | NormKind::KeywordHash => Some("T::Hash[T.untyped, T.untyped]".to_string()),
        NormKind::Call if call_name(node, file).as_deref() == Some("new") => {
            call_receiver(node, file).map(|receiver| node_text(receiver, file))
        }
        _ => None,
    }
}

fn collection_index_status(receiver_type: Option<&str>, lookup_type: Option<&str>) -> &'static str {
    if lookup_type.is_some_and(|ty| useful_type(ty) && !weak_type(ty)) {
        return "typed lookup";
    }
    let text = receiver_type.unwrap_or("");
    if text.is_empty() {
        return "unknown receiver type";
    }
    if text.contains("T.untyped") {
        return "weak collection receiver";
    }
    if text.starts_with("Array") || text.starts_with("Hash") || text.starts_with("T::Array") || text.starts_with("T::Hash") {
        return "typed collection receiver";
    }
    "non-collection or unresolved receiver"
}

fn sorbet_type_index_syntax(text: &str) -> bool {
    matches!(text, "Array" | "Hash" | "Set" | "Enumerable" | "T::Array" | "T::Hash" | "T::Set" | "T::Enumerable")
        || text.starts_with("T::")
}

fn hash_record_blocker_origin(origin: &Value) -> bool {
    matches!(
        origin.get("kind").and_then(Value::as_str),
        Some("hash literal" | "method parameter" | "forwarded return" | "instance variable" | "local hash shape")
    )
}

fn collection_type_info(type_text: &str) -> Option<CollectionInfo> {
    let raw = strip_nilable_type(type_text.trim());
    if raw.is_empty() {
        return None;
    }
    parse_collection_type(&raw)
}

struct CollectionInfo {
    kind: String,
    element: Option<String>,
    value: Option<String>,
}

fn parse_collection_type(raw: &str) -> Option<CollectionInfo> {
    for (prefix, kind) in [
        ("T::Array", "array"),
        ("Array", "array"),
        ("T::Hash", "hash"),
        ("Hash", "hash"),
        ("T::Set", "set"),
        ("Set", "set"),
    ] {
        if raw == prefix {
            return Some(CollectionInfo {
                kind: kind.to_string(),
                element: None,
                value: None,
            });
        }
        let bracket = format!("{prefix}[");
        if raw.starts_with(&bracket) && raw.ends_with(']') {
            let inner = &raw[bracket.len()..raw.len() - 1];
            let parts = split_top_level(inner);
            return Some(CollectionInfo {
                kind: kind.to_string(),
                element: parts.first().cloned(),
                value: parts.get(1).cloned(),
            });
        }
    }
    None
}

fn array_receiver_type(type_text: &str) -> bool {
    type_text.starts_with("Array") || type_text.starts_with("T::Array")
}

fn collection_receiver_type(type_text: &str) -> bool {
    array_receiver_type(type_text)
        || type_text.starts_with("Hash")
        || type_text.starts_with("T::Hash")
        || type_text.starts_with("Set")
        || type_text.starts_with("T::Set")
}

fn nilable_type(type_text: &str) -> String {
    if type_text == "NilClass" || type_text.starts_with("T.nilable(") {
        type_text.to_string()
    } else {
        format!("T.nilable({type_text})")
    }
}

fn static_sorbet_type(types: &[String]) -> String {
    let mut has_nil = false;
    let mut others = BTreeSet::new();
    for ty in types.iter().filter(|ty| !ty.is_empty()) {
        if ty == "NilClass" {
            has_nil = true;
        } else if ty.starts_with("T.nilable(") && ty.ends_with(')') {
            has_nil = true;
            others.insert(strip_nilable_type(ty));
        } else {
            others.insert(normalize_static_sorbet_type(ty));
        }
    }
    if others.contains("T.noreturn") {
        if others.len() == 1 {
            return if has_nil { "NilClass".to_string() } else { "T.noreturn".to_string() };
        }
        others.remove("T.noreturn");
    }
    if others.is_empty() && has_nil {
        return "NilClass".to_string();
    }
    if others.is_empty() {
        return "T.untyped".to_string();
    }
    let base = if others
        .iter()
        .all(|ty| matches!(ty.as_str(), "TrueClass" | "FalseClass" | "T::Boolean"))
    {
        "T::Boolean".to_string()
    } else if others.len() == 1 {
        others.into_iter().next().unwrap()
    } else {
        "T.untyped".to_string()
    };
    if base == "T.untyped" {
        return base;
    }
    if has_nil {
        format!("T.nilable({base})")
    } else {
        base
    }
}

fn normalize_static_sorbet_type(type_text: &str) -> String {
    match type_text {
        "Array" => "T::Array[T.untyped]".to_string(),
        "Hash" => "T::Hash[T.untyped, T.untyped]".to_string(),
        "Set" => "T::Set[T.untyped]".to_string(),
        _ => type_text.to_string(),
    }
}

fn useful_type(type_text: &str) -> bool {
    !type_text.is_empty() && type_text != "T.untyped"
}

fn weak_type(type_text: &str) -> bool {
    type_text.contains("T.untyped")
        || type_text.contains("[T.untyped")
        || type_text.contains(", T.untyped")
}

fn strip_nilable_type(type_text: &str) -> String {
    let text = type_text.trim();
    if text.starts_with("T.nilable(") && text.ends_with(')') {
        extract_call_args(text, "T.nilable").unwrap_or_else(|| text.to_string())
    } else {
        text.to_string()
    }
}

fn static_expression_reason(type_text: &str) -> String {
    if type_text.starts_with("T.class_of(") && type_text.ends_with(')') {
        format!(
            "class constant {}",
            type_text.trim_start_matches("T.class_of(").trim_end_matches(')')
        )
    } else {
        type_text.to_string()
    }
}

fn merge_hash_record_shapes(left: Value, right: Value) -> Value {
    let mut out = json!({"keys": {}, "value_hash_shapes": {}, "value_array_element_shapes": {}, "poisoned": false});
    let poisoned = left.get("poisoned").and_then(Value::as_bool).unwrap_or(false)
        || right.get("poisoned").and_then(Value::as_bool).unwrap_or(false);
    object_insert(&mut out, "poisoned", json!(poisoned));
    for shape in [&left, &right] {
        if let Some(keys) = shape.get("keys").and_then(Value::as_object) {
            for (key, values) in keys {
                let existing = out
                    .get_mut("keys")
                    .and_then(Value::as_object_mut)
                    .unwrap()
                    .entry(key.clone())
                    .or_insert_with(|| json!([]));
                if let Some(array) = existing.as_array_mut() {
                    for value in values.as_array().into_iter().flatten() {
                        if !array.contains(value) {
                            array.push(value.clone());
                        }
                    }
                }
            }
        }
        for map_name in ["value_hash_shapes", "value_array_element_shapes"] {
            if let Some(map) = shape.get(map_name).and_then(Value::as_object) {
                for (key, nested) in map {
                    out.get_mut(map_name)
                        .and_then(Value::as_object_mut)
                        .unwrap()
                        .insert(key.clone(), nested.clone());
                }
            }
        }
    }
    out
}

fn merge_frame_array_shape(frame: &mut Frame, name: &str, shape: Value) {
    if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
        return;
    }
    let merged = frame
        .array_element_shapes
        .get(name)
        .cloned()
        .map(|current| merge_hash_record_shapes(current, shape.clone()))
        .unwrap_or(shape);
    frame.array_element_shapes.insert(name.to_string(), merged);
}

fn merge_value(base: &Value, entries: &[(&str, Value)]) -> Value {
    let mut out = base.clone();
    for (key, value) in entries {
        object_insert(&mut out, key, value.clone());
    }
    out
}

fn object_insert(value: &mut Value, key: &str, entry: Value) {
    if let Some(obj) = value.as_object_mut() {
        obj.insert(key.to_string(), entry);
    }
}

fn value_array(value: Option<&Value>) -> Vec<Value> {
    value.and_then(Value::as_array).cloned().unwrap_or_default()
}

fn value_string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|array| {
            array
                .iter()
                .filter_map(Value::as_str)
                .map(ToString::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn unwrap_alias_source(node: Node<'_>, file: &SourceFile) -> Option<String> {
    if normalized_kind(node, file) == NormKind::LocalRead {
        return Some(node_text(node, file));
    }
    if normalized_kind(node, file) == NormKind::Call
        && call_receiver(node, file).map(|receiver| node_text(receiver, file)) == Some("T".to_string())
        && matches!(call_name(node, file).as_deref(), Some("must" | "cast" | "let"))
    {
        return call_arguments(node, file)
            .first()
            .and_then(|arg| unwrap_alias_source(*arg, file));
    }
    None
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NormKind {
    Program,
    Statements,
    Class,
    Module,
    Def,
    Parameters,
    Block,
    Call,
    Array,
    Hash,
    KeywordHash,
    Pair,
    String,
    InterpolatedString,
    Symbol,
    Integer,
    Float,
    True,
    False,
    Nil,
    Range,
    Return,
    Yield,
    If,
    Unless,
    While,
    Until,
    Case,
    When,
    Else,
    Begin,
    Rescue,
    Parentheses,
    SelfNode,
    ConstRead,
    ConstPath,
    ConstWrite,
    LocalRead,
    LocalWrite,
    IvarRead,
    IvarWrite,
    ClassVarRead,
    ClassVarWrite,
    GlobalVarRead,
    GlobalVarWrite,
    Or,
    HiddenOr,
    Other,
}

fn normalized_kind(node: Node<'_>, file: &SourceFile) -> NormKind {
    match node.kind() {
        "program" => NormKind::Program,
        "body_statement" | "block_body" | "then" => body_statement_kind(node, file),
        "class" => NormKind::Class,
        "module" => NormKind::Module,
        "method" | "singleton_method" => NormKind::Def,
        "method_parameters" => NormKind::Parameters,
        "block" | "do_block" => NormKind::Block,
        "assignment" | "operator_assignment" => assignment_kind(node),
        "call" | "command" | "method_call" => NormKind::Call,
        "element_reference" | "binary" | "unary" => {
            if node.kind() == "binary" && binary_operator(node).is_some_and(|op| matches!(op.as_str(), "||" | "or")) {
                NormKind::Or
            } else {
                NormKind::Call
            }
        }
        "array" => NormKind::Array,
        "hash" => NormKind::Hash,
        "pair" => NormKind::Pair,
        "argument_list" if looks_like_keyword_hash(node) => NormKind::KeywordHash,
        "string" => {
            if named_children(node).iter().any(|child| child.kind() == "interpolation") {
                NormKind::InterpolatedString
            } else {
                NormKind::String
            }
        }
        "simple_symbol" | "hash_key_symbol" | "symbol" => NormKind::Symbol,
        "integer" => NormKind::Integer,
        "float" => NormKind::Float,
        "true" => NormKind::True,
        "false" => NormKind::False,
        "nil" => NormKind::Nil,
        "range" => NormKind::Range,
        "return" => NormKind::Return,
        "yield" => NormKind::Yield,
        "if" => NormKind::If,
        "unless" => NormKind::Unless,
        "while" => NormKind::While,
        "until" => NormKind::Until,
        "case" => NormKind::Case,
        "when" => NormKind::When,
        "else" => NormKind::Else,
        "begin" => NormKind::Begin,
        "rescue" | "rescue_modifier" => NormKind::Rescue,
        "parenthesized_statements" | "parenthesized_expression" => NormKind::Parentheses,
        "self" => NormKind::SelfNode,
        "constant" => NormKind::ConstRead,
        "scope_resolution" => NormKind::ConstPath,
        "instance_variable" => {
            if assignment_lhs_node(node) {
                NormKind::IvarWrite
            } else {
                NormKind::IvarRead
            }
        }
        "class_variable" => {
            if assignment_lhs_node(node) {
                NormKind::ClassVarWrite
            } else {
                NormKind::ClassVarRead
            }
        }
        "global_variable" => {
            if assignment_lhs_node(node) {
                NormKind::GlobalVarWrite
            } else {
                NormKind::GlobalVarRead
            }
        }
        "identifier" => {
            if identifier_is_local(node, file) {
                NormKind::LocalRead
            } else {
                NormKind::Call
            }
        }
        _ => NormKind::Other,
    }
}

fn normalized_kind_by_raw(node: Node<'_>) -> NormKind {
    match node.kind() {
        "return" => NormKind::Return,
        _ => NormKind::Other,
    }
}

fn body_statement_kind(node: Node<'_>, _file: &SourceFile) -> NormKind {
    if hidden_or_body_statement(node) {
        return NormKind::HiddenOr;
    }
    let first = all_children(node).first().copied();
    match first.map(|child| child.kind()) {
        Some("def") => NormKind::Def,
        Some("class") => NormKind::Class,
        Some("module") => NormKind::Module,
        Some("return") => NormKind::Return,
        Some("if") => NormKind::If,
        Some("unless") => NormKind::Unless,
        Some("while") => NormKind::While,
        Some("until") => NormKind::Until,
        Some("case") => NormKind::Case,
        Some("begin") => NormKind::Begin,
        _ => {
            NormKind::Statements
        }
    }
}

fn assignment_kind(node: Node<'_>) -> NormKind {
    let lhs = assignment_lhs(node);
    match lhs.map(|lhs| lhs.kind()) {
        Some("element_reference") | Some("call") => NormKind::Call,
        Some("identifier") => NormKind::LocalWrite,
        Some("instance_variable") => NormKind::IvarWrite,
        Some("class_variable") => NormKind::ClassVarWrite,
        Some("global_variable") => NormKind::GlobalVarWrite,
        Some("constant") | Some("scope_resolution") => NormKind::ConstWrite,
        _ => NormKind::Other,
    }
}

fn assignment_lhs_node(node: Node<'_>) -> bool {
    matches!(
        next_sibling_raw_text(node).as_deref(),
        Some("=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&&=" | "||=")
    )
}

fn identifier_is_local(node: Node<'_>, file: &SourceFile) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.child_by_field_name("name") == Some(node) {
        return false;
    }
    let text = node_text(node, file);
    let mut scope = Some(parent);
    while let Some(current) = scope {
        if matches!(
            current.kind(),
            "method" | "singleton_method" | "block" | "do_block" | "lambda" | "program"
        ) && file
            .local_names_by_scope
            .get(&scope_key(current))
            .is_some_and(|names| names.contains(&text))
        {
            return true;
        }
        scope = current.parent();
    }
    false
}

fn build_local_name_cache(file: &SourceFile) -> BTreeMap<ScopeKey, BTreeSet<String>> {
    let mut names_by_scope = BTreeMap::new();
    collect_local_name_cache(file.root_node(), file, &mut names_by_scope);
    names_by_scope
}

fn collect_local_name_cache(
    node: Node<'_>,
    file: &SourceFile,
    names_by_scope: &mut BTreeMap<ScopeKey, BTreeSet<String>>,
) {
    if matches!(
        node.kind(),
        "method" | "singleton_method" | "block" | "do_block" | "lambda" | "program"
    ) {
        let mut names = BTreeSet::new();
        collect_scope_parameters(node, file, &mut names);
        collect_scope_assignments(node, file, &mut names);
        names_by_scope.insert(scope_key(node), names);
    }

    for child in named_children(node) {
        collect_local_name_cache(child, file, names_by_scope);
    }
}

fn collect_scope_parameters(scope: Node<'_>, file: &SourceFile, names: &mut BTreeSet<String>) {
    if matches!(scope.kind(), "method" | "singleton_method" | "block" | "do_block" | "lambda") {
        if let Some(params) = scope.child_by_field_name("parameters") {
            for param in named_children(params).into_iter().filter_map(|param| {
                param
                    .child_by_field_name("name")
                    .or_else(|| named_children(param).into_iter().find(|child| child.kind() == "identifier"))
                    .or_else(|| (param.kind() == "identifier").then_some(param))
            }) {
                names.insert(node_text(param, file));
            }
        }
    }
}

fn collect_scope_assignments(scope: Node<'_>, file: &SourceFile, names: &mut BTreeSet<String>) {
    walk_raw(scope, &mut |node| {
        if node != scope && matches!(node.kind(), "method" | "singleton_method" | "class" | "module") {
            return;
        }
        if matches!(node.kind(), "assignment" | "operator_assignment") {
            if let Some(lhs) = assignment_lhs(node).filter(|lhs| lhs.kind() == "identifier") {
                names.insert(node_text(lhs, file));
            }
        }
    });
}

fn scope_key(node: Node<'_>) -> ScopeKey {
    (node.start_byte(), node.end_byte())
}

fn lhs_element_reference_node(node: Node<'_>) -> bool {
    node.kind() == "element_reference"
        && node.parent().is_some_and(|parent| {
            matches!(parent.kind(), "assignment" | "operator_assignment")
                && assignment_lhs(parent) == Some(node)
        })
}

fn looks_like_keyword_hash(node: Node<'_>) -> bool {
    !named_children(node).is_empty()
        && named_children(node)
            .into_iter()
            .all(|child| child.kind() == "pair")
}

fn nested_scope_node(node: Node<'_>, file: &SourceFile) -> bool {
    matches!(
        normalized_kind(node, file),
        NormKind::Def | NormKind::Class | NormKind::Module
    )
}

fn nested_scope_kind(kind: &str) -> bool {
    matches!(kind, "method" | "singleton_method" | "class" | "module")
}

fn binary_operator(node: Node<'_>) -> Option<String> {
    all_children(node)
        .into_iter()
        .find(|child| !child.is_named() && !matches!(node_text_raw(*child).as_str(), "(" | ")"))
        .map(node_text_raw)
}

fn contains_kind(node: Node<'_>, kind: &str) -> bool {
    node.kind() == kind || named_children(node).into_iter().any(|child| contains_kind(child, kind))
}

fn walk_raw(node: Node<'_>, f: &mut impl FnMut(Node<'_>)) {
    f(node);
    for child in named_children(node) {
        walk_raw(child, f);
    }
}

fn line(node: Node<'_>) -> usize {
    shared_ast::line(node)
}

fn end_line(node: Node<'_>) -> usize {
    node.end_position().row + 1
}

fn named_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.named_children(&mut cursor).collect()
}

fn all_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.children(&mut cursor).collect()
}

fn node_text(node: Node<'_>, file: &SourceFile) -> String {
    shared_ast::node_text(node, &file.source).to_string()
}

fn node_text_raw(node: Node<'_>) -> String {
    node.kind().to_string()
}

fn next_sibling_raw_text(node: Node<'_>) -> Option<String> {
    let mut sibling = node.next_sibling();
    while let Some(candidate) = sibling {
        if !candidate.is_named() {
            return Some(node_text_raw(candidate));
        }
        sibling = candidate.next_sibling();
    }
    None
}

fn identifier_like(text: &str) -> bool {
    let mut chars = text.chars();
    matches!(chars.next(), Some('a'..='z' | '_'))
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '!' | '?' | '='))
}

fn unquote(text: &str) -> String {
    text.trim()
        .trim_start_matches('"')
        .trim_start_matches('\'')
        .trim_end_matches('"')
        .trim_end_matches('\'')
        .to_string()
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").trim().chars().take(160).collect()
}

fn rel_path(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .trim_start_matches("./")
        .to_string()
}

fn debug_node_name(kind: NormKind) -> &'static str {
    match kind {
        NormKind::Program => "ProgramNode",
        NormKind::Statements => "StatementsNode",
        NormKind::Class => "ClassNode",
        NormKind::Module => "ModuleNode",
        NormKind::Def => "DefNode",
        NormKind::Parameters => "ParametersNode",
        NormKind::Block => "BlockNode",
        NormKind::Call => "CallNode",
        NormKind::Array => "ArrayNode",
        NormKind::Hash | NormKind::KeywordHash => "HashNode",
        NormKind::Pair => "AssocNode",
        NormKind::String => "StringNode",
        NormKind::InterpolatedString => "InterpolatedStringNode",
        NormKind::Symbol => "SymbolNode",
        NormKind::Integer => "IntegerNode",
        NormKind::Float => "FloatNode",
        NormKind::True => "TrueNode",
        NormKind::False => "FalseNode",
        NormKind::Nil => "NilNode",
        NormKind::Range => "RangeNode",
        NormKind::Return => "ReturnNode",
        NormKind::Yield => "YieldNode",
        NormKind::If => "IfNode",
        NormKind::Unless => "UnlessNode",
        NormKind::While => "WhileNode",
        NormKind::Until => "UntilNode",
        NormKind::Case => "CaseNode",
        NormKind::When => "WhenNode",
        NormKind::Else => "ElseNode",
        NormKind::Begin => "BeginNode",
        NormKind::Rescue => "RescueNode",
        NormKind::Parentheses => "ParenthesesNode",
        NormKind::SelfNode => "SelfNode",
        NormKind::ConstRead => "ConstantReadNode",
        NormKind::ConstPath => "ConstantPathNode",
        NormKind::ConstWrite => "ConstantWriteNode",
        NormKind::LocalRead => "LocalVariableReadNode",
        NormKind::LocalWrite => "LocalVariableWriteNode",
        NormKind::IvarRead => "InstanceVariableReadNode",
        NormKind::IvarWrite => "InstanceVariableWriteNode",
        NormKind::ClassVarRead => "ClassVariableReadNode",
        NormKind::ClassVarWrite => "ClassVariableWriteNode",
        NormKind::GlobalVarRead => "GlobalVariableReadNode",
        NormKind::GlobalVarWrite => "GlobalVariableWriteNode",
        NormKind::Or => "HiddenOrNode",
        NormKind::HiddenOr => "HiddenOrNode",
        NormKind::Other => "Node",
    }
}

const CORE_CLASS_CONSTANTS: &[&str] = &[
    "Array",
    "BasicObject",
    "Class",
    "Complex",
    "Encoding",
    "Enumerator",
    "Exception",
    "FalseClass",
    "Fiber",
    "Float",
    "Hash",
    "Integer",
    "Module",
    "NilClass",
    "Numeric",
    "Object",
    "Proc",
    "Range",
    "Rational",
    "Regexp",
    "String",
    "Struct",
    "Symbol",
    "Thread",
    "Time",
    "TrueClass",
];
