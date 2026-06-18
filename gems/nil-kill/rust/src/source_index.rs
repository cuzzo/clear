use anyhow::{Context, Result};
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
        collect_return_usage_sites(&file, &mut facts);
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
    attribute_hash_shapes: BTreeMap<String, Value>,
    attribute_array_element_shapes: BTreeMap<String, Value>,
    struct_field_hash_shapes: BTreeMap<(String, String), Value>,
    struct_field_array_element_shapes: BTreeMap<(String, String), Value>,
    struct_field_static_types: BTreeMap<(String, String), Vec<String>>,
    inferred_param_hash_shapes: BTreeMap<(String, String, String), Value>,
    inferred_param_array_element_shapes: BTreeMap<(String, String, String), Value>,
    ivar_tlet_names: BTreeSet<String>,
    ivar_tlet_types: BTreeMap<(String, String), String>,
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
        collect_prescan(self, global);
    }
}

type ScopeKey = (usize, usize);
type WalkKey = (usize, usize, String);

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
    collection_builders: BTreeMap<String, CollectionBuilder>,
    non_nil_locals: BTreeSet<String>,
    maybe_nil_locals: BTreeSet<String>,
    local_container_origins: BTreeMap<String, Value>,
    ivar_container_origins: BTreeMap<String, Value>,
    hash_shapes: BTreeMap<String, Value>,
    array_element_shapes: BTreeMap<String, Value>,
    hash_shape_sources: BTreeMap<String, Value>,
    expression_type_stack: BTreeSet<ScopeKey>,
}

#[derive(Clone, Debug, Eq, PartialEq)]
enum CollectionBuilderKind {
    Array,
    Hash,
    Set,
    Unknown,
}

#[derive(Clone, Debug, Eq, PartialEq)]
struct CollectionBuilder {
    kind: CollectionBuilderKind,
    types: BTreeSet<String>,
    key_types: BTreeSet<String>,
    value_types: BTreeSet<String>,
    poisoned: bool,
}

impl CollectionBuilder {
    fn new(kind: CollectionBuilderKind) -> Self {
        Self {
            kind,
            types: BTreeSet::new(),
            key_types: BTreeSet::new(),
            value_types: BTreeSet::new(),
            poisoned: false,
        }
    }
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
    rescue_handlers: Vec<Value>,
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
            rescue_handlers: Vec::new(),
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
        facts.insert("rescue_handlers".to_string(), json!([]));
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
        self.extend_fact("rescue_handlers", facts.rescue_handlers);

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
    method_nodes: Vec<(Node<'a>, Value)>,
    walk_stack: BTreeSet<WalkKey>,
}

impl<'a> FileIndexer<'a> {
    fn new(file: &'a SourceFile, global: &'a mut GlobalState) -> Self {
        Self {
            file,
            global,
            facts: FileFacts::new(),
            method_nodes: Vec::new(),
            walk_stack: BTreeSet::new(),
        }
    }

    fn index(mut self) -> FileFacts {
        let mut state = ScopeState::default();
        self.walk(self.file.root_node(), &mut state, &mut Frame::default());
        if !self.method_nodes.is_empty() {
            self.recompute_return_origins_with_inferred_shapes();
            self.recompute_collection_index_lookups_with_inferred_shapes();
            self.recompute_struct_field_static_with_inferred_locals();
        }
        collect_return_usage_sites(self.file, &mut self.facts);
        collect_hash_record_escape_sites(self.file, &mut self.facts);
        self.facts
    }
}

include!("source_index/traversal.rs");
include!("source_index/return_analysis.rs");
include!("source_index/param_protocols.rs");
include!("source_index/records.rs");
include!("source_index/observations.rs");
include!("source_index/deterministic_guards.rs");
include!("source_index/expression_shapes.rs");
include!("source_index/syntax.rs");
