use crate::model::{BlobFile, LogicalUnit, UnitKind};
use std::collections::BTreeSet;
use std::collections::HashMap;
use tree_sitter::{Language, Node, Parser};
use streaming_iterator::StreamingIterator;

pub const DEFAULT_CODE_EXTENSIONS: &[&str] = &[
    "rb", "zig", "py", "js", "jsx", "mjs", "cjs", "ts", "tsx", "lua", "c", "h", "cc", "cpp",
    "cxx", "hh", "hpp", "hxx", "cs", "java", "swift", "kt", "kts", "go", "rs", "php", "S",
];
const DEFAULT_IGNORED_COMPONENTS: &[&str] = &[
    ".git",
    ".zig-cache",
    ".clear-cache",
    ".clear-transpile-cache",
    "coverage",
    "node_modules",
    "target",
    "tmp",
    "vendor",
    "zig-out",
];
const DEFAULT_TEST_COMPONENTS: &[&str] = &[
    "__tests__",
    "bench",
    "benches",
    "benchmarks",
    "fuzz",
    "fuzzers",
    "fuzzing",
    "spec",
    "test",
    "testdata",
    "tests",
    "testing",
];

pub trait BoundaryExtractor {
    fn supports_path(&self, path: &str) -> bool;
    fn extract_units(&self, file: &BlobFile) -> Vec<LogicalUnit>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SourceFilter {
    extensions: BTreeSet<String>,
    ignored_components: BTreeSet<String>,
}

impl SourceFilter {
    pub fn code_defaults() -> Self {
        Self {
            extensions: DEFAULT_CODE_EXTENSIONS
                .iter()
                .map(|ext| ext.to_string())
                .collect(),
            ignored_components: DEFAULT_IGNORED_COMPONENTS
                .iter()
                .map(|component| component.to_string())
                .collect(),
        }
    }

    pub fn with_extensions<I, S>(extensions: I) -> Self
    where
        I: IntoIterator<Item = S>,
        S: Into<String>,
    {
        Self {
            extensions: extensions.into_iter().map(Into::into).collect(),
            ignored_components: DEFAULT_IGNORED_COMPONENTS
                .iter()
                .map(|component| component.to_string())
                .collect(),
        }
    }

    pub fn supports_path(&self, path: &str) -> bool {
        if self.ignored_path(path) {
            return false;
        }

        extension(path)
            .map(|ext| self.extensions.contains(&normalize_extension(&ext)))
            .unwrap_or(false)
    }

    fn ignored_path(&self, path: &str) -> bool {
        path.split('/').any(|component| {
            self.ignored_components.contains(component) || component.ends_with(".profile")
        })
    }
}

pub fn is_test_source_path(path: &str) -> bool {
    let path = normalize_path_for_role(path);
    if path.is_empty() {
        return false;
    }

    let components = path.split('/').collect::<Vec<_>>();
    if components.iter().any(|component| {
        DEFAULT_TEST_COMPONENTS.contains(component)
            || component.ends_with("-tests")
            || component.ends_with("_tests")
    }) {
        return true;
    }

    let basename = components.last().copied().unwrap_or("");
    if basename == "conftest.py" {
        return true;
    }
    if basename.starts_with("test_") && basename.ends_with(".py") {
        return true;
    }
    if basename.contains(".spec.") || basename.contains(".test.") {
        return true;
    }

    let stem = basename
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(basename);
    stem.ends_with("_spec")
        || stem.ends_with("_test")
        || stem.ends_with("-test")
        || stem.ends_with(".spec")
        || stem.ends_with(".test")
}

pub fn is_production_source_path(path: &str) -> bool {
    !is_test_source_path(path)
}

fn normalize_path_for_role(path: &str) -> String {
    path.replace('\\', "/")
        .trim_start_matches("./")
        .to_ascii_lowercase()
}

impl Default for SourceFilter {
    fn default() -> Self {
        Self::code_defaults()
    }
}

#[derive(Debug, Clone, Default)]
pub struct HeuristicExtractor {
    filter: SourceFilter,
}

impl HeuristicExtractor {
    pub fn new(filter: SourceFilter) -> Self {
        Self { filter }
    }
}

#[derive(Debug, Clone)]
struct Candidate {
    name: String,
    kind: UnitKind,
    signature: String,
    line: u32,
    end_line: Option<u32>,
}

impl BoundaryExtractor for HeuristicExtractor {
    fn supports_path(&self, path: &str) -> bool {
        self.filter.supports_path(path)
    }

    fn extract_units(&self, file: &BlobFile) -> Vec<LogicalUnit> {
        if !self.supports_path(&file.path) {
            return Vec::new();
        }

        let ext = extension(&file.path).map(|value| normalize_extension(&value));
        let lines: Vec<&str> = file.contents.lines().collect();
        let candidates = match ext.as_deref() {
            Some(extension) if TreeSitterAdapter::for_extension(extension).is_some() => {
                tree_sitter_candidates(file, extension, &lines).unwrap_or_default()
            }
            _ => heuristic_candidates(&lines, ext.as_deref()),
        };
        candidates
            .iter()
            .enumerate()
            .scan(HashMap::new(), |seen, (index, candidate)| {
                let key = (candidate.kind, candidate.name.clone());
                let ordinal = seen.entry(key).or_insert(0_u32);
                *ordinal += 1;
                Some((index, candidate, *ordinal))
            })
            .map(|(index, candidate, ordinal)| {
                let next_line = candidate.end_line.unwrap_or_else(|| {
                    candidates
                        .get(index + 1)
                        .map(|next| next.line.saturating_sub(1))
                        .unwrap_or(lines.len() as u32)
                });
                let start = candidate.line.saturating_sub(1) as usize;
                let end = next_line.max(candidate.line).min(lines.len() as u32) as usize;
                let body = lines[start..end].join("\n");

                LogicalUnit::new(
                    candidate.name.clone(),
                    candidate.kind,
                    file.path.clone(),
                    ordinal,
                    candidate.line,
                    next_line,
                    candidate.signature.clone(),
                    &body,
                )
            })
            .collect()
    }
}

fn detect_candidate(line: &str, line_number: u32, extension: Option<&str>) -> Option<Candidate> {
    let trimmed = line.trim_start();
    if trimmed.is_empty() || trimmed.starts_with('#') || trimmed.starts_with("//") {
        return None;
    }

    match extension {
        Some("rb") | Some("py") => detect_ruby_python(trimmed, line_number),
        Some("js") | Some("jsx") | Some("mjs") | Some("cjs") | Some("ts") | Some("tsx") => {
            detect_javascript_typescript(trimmed, line_number)
        }
        Some("lua") => detect_lua(trimmed, line_number),
        Some("c") | Some("h") | Some("cc") | Some("cpp") | Some("cxx") | Some("hh")
        | Some("hpp") | Some("hxx") => detect_c_family(trimmed, line_number),
        Some("cs") | Some("java") => detect_csharp_java(trimmed, line_number),
        Some("swift") => detect_swift(trimmed, line_number),
        Some("kt") | Some("kts") => detect_kotlin(trimmed, line_number),
        Some("go") => detect_go(trimmed, line_number),
        Some("rs") | Some("zig") => detect_rust_or_zig(trimmed, line_number),
        Some("php") => detect_php(trimmed, line_number),
        Some("S") => detect_assembly(trimmed, line_number),
        _ => None,
    }
}

fn heuristic_candidates(lines: &[&str], extension: Option<&str>) -> Vec<Candidate> {
    let mut detected = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if let Some(candidate) = detect_candidate(line, (index + 1) as u32, extension) {
            detected.push(candidate);
        }
    }
    detected
}

#[derive(Debug, Clone, Copy)]
enum TreeSitterAdapter {
    C,
    Cpp,
    CSharp,
    Go,
    Java,
    JavaScript,
    Kotlin,
    Lua,
    Php,
    Python,
    Ruby,
    Rust,
    Swift,
    Tsx,
    TypeScript,
    Zig,
}

impl TreeSitterAdapter {
    fn for_extension(extension: &str) -> Option<Self> {
        match extension {
            "c" | "h" => Some(Self::C),
            "cc" | "cpp" | "cxx" | "hh" | "hpp" | "hxx" => Some(Self::Cpp),
            "cs" => Some(Self::CSharp),
            "go" => Some(Self::Go),
            "java" => Some(Self::Java),
            "js" | "jsx" | "mjs" | "cjs" => Some(Self::JavaScript),
            "kt" | "kts" => Some(Self::Kotlin),
            "lua" => Some(Self::Lua),
            "php" => Some(Self::Php),
            "py" | "pyi" => Some(Self::Python),
            "rb" => Some(Self::Ruby),
            "rs" => Some(Self::Rust),
            "swift" => Some(Self::Swift),
            "tsx" => Some(Self::Tsx),
            "ts" => Some(Self::TypeScript),
            "zig" => Some(Self::Zig),
            _ => None,
        }
    }

    fn language(self) -> Language {
        match self {
            Self::C => tree_sitter_c::LANGUAGE.into(),
            Self::Cpp => tree_sitter_cpp::LANGUAGE.into(),
            Self::CSharp => tree_sitter_c_sharp::LANGUAGE.into(),
            Self::Go => tree_sitter_go::LANGUAGE.into(),
            Self::Java => tree_sitter_java::LANGUAGE.into(),
            Self::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
            Self::Kotlin => tree_sitter_kotlin_ng::LANGUAGE.into(),
            Self::Lua => tree_sitter_lua::LANGUAGE.into(),
            Self::Php => tree_sitter_php::LANGUAGE_PHP.into(),
            Self::Python => tree_sitter_python::LANGUAGE.into(),
            Self::Ruby => tree_sitter_ruby::LANGUAGE.into(),
            Self::Rust => tree_sitter_rust::LANGUAGE.into(),
            Self::Swift => tree_sitter_swift::LANGUAGE.into(),
            Self::Tsx => tree_sitter_typescript::LANGUAGE_TSX.into(),
            Self::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
            Self::Zig => tree_sitter_zig::LANGUAGE.into(),
        }
    }
}

const RUBY_QUERY: &str = include_str!("queries/ruby/tags.scm");
const PYTHON_QUERY: &str = include_str!("queries/python/tags.scm");
const JAVASCRIPT_QUERY: &str = include_str!("queries/javascript/tags.scm");
const TYPESCRIPT_QUERY: &str = include_str!("queries/typescript/tags.scm");
const GO_QUERY: &str = include_str!("queries/go/tags.scm");
const C_QUERY: &str = include_str!("queries/c/tags.scm");
const CPP_QUERY: &str = include_str!("queries/cpp/tags.scm");
const CS_QUERY: &str = include_str!("queries/csharp/tags.scm");
const RUST_QUERY: &str = include_str!("queries/rust/tags.scm");
const ZIG_QUERY: &str = include_str!("queries/zig/tags.scm");
const JAVA_QUERY: &str = include_str!("queries/java/tags.scm");
const KOTLIN_QUERY: &str = include_str!("queries/kotlin/tags.scm");
const LUA_QUERY: &str = include_str!("queries/lua/tags.scm");
const PHP_QUERY: &str = include_str!("queries/php/tags.scm");
const SWIFT_QUERY: &str = include_str!("queries/swift/tags.scm");

impl TreeSitterAdapter {
    fn query_str(self) -> &'static str {
        match self {
            Self::Ruby => RUBY_QUERY,
            Self::Python => PYTHON_QUERY,
            Self::JavaScript => JAVASCRIPT_QUERY,
            Self::TypeScript | Self::Tsx => TYPESCRIPT_QUERY,
            Self::Go => GO_QUERY,
            Self::C => C_QUERY,
            Self::Cpp => CPP_QUERY,
            Self::CSharp => CS_QUERY,
            Self::Rust => RUST_QUERY,
            Self::Zig => ZIG_QUERY,
            Self::Java => JAVA_QUERY,
            Self::Kotlin => KOTLIN_QUERY,
            Self::Lua => LUA_QUERY,
            Self::Php => PHP_QUERY,
            Self::Swift => SWIFT_QUERY,
        }
    }
}

fn candidate_from_capture(
    adapter: TreeSitterAdapter,
    node: Node<'_>,
    name: &str,
    kind: UnitKind,
    source: &str,
    lines: &[&str],
) -> Candidate {
    let qualified = match kind {
        UnitKind::Class | UnitKind::Module => {
            let owner_kinds = match adapter {
                TreeSitterAdapter::Ruby => &["class", "module"][..],
                TreeSitterAdapter::Python => &["class_definition"][..],
                TreeSitterAdapter::JavaScript | TreeSitterAdapter::TypeScript | TreeSitterAdapter::Tsx => {
                    &["class_declaration", "abstract_class_declaration"][..]
                }
                TreeSitterAdapter::Go => &["type_spec", "type_alias"][..],
                TreeSitterAdapter::C | TreeSitterAdapter::Cpp => &[][..],
                TreeSitterAdapter::CSharp => &["class_declaration", "struct_declaration", "record_declaration", "namespace_declaration"][..],
                TreeSitterAdapter::Rust => &["struct_item", "enum_item", "trait_item", "union_item", "mod_item"][..],
                TreeSitterAdapter::Zig => &["struct_declaration", "enum_declaration", "union_declaration", "variable_declaration"][..],
                TreeSitterAdapter::Java => &["class_declaration", "interface_declaration", "enum_declaration", "record_declaration"][..],
                TreeSitterAdapter::Kotlin => &["class_declaration", "object_declaration"][..],
                TreeSitterAdapter::Lua => &[][..],
                TreeSitterAdapter::Php => &["class_declaration", "interface_declaration", "trait_declaration", "namespace_definition"][..],
                TreeSitterAdapter::Swift => &["class_declaration", "protocol_declaration"][..],
            };
            qualified_name(node, name, source, owner_kinds)
        }
        UnitKind::Function => {
            match adapter {
                TreeSitterAdapter::Ruby => {
                    let name = if node.kind() == "singleton_method" {
                        let object = field_text(node, "object", source).unwrap_or("self");
                        format!("{}.{}", clean_owner_name(object), name)
                    } else {
                        name.to_string()
                    };
                    qualified_name(node, &name, source, &["class", "module", "method", "singleton_method"])
                }
                TreeSitterAdapter::Python => {
                    qualified_name(node, name, source, &["class_definition", "function_definition"])
                }
                TreeSitterAdapter::JavaScript | TreeSitterAdapter::TypeScript | TreeSitterAdapter::Tsx => {
                    qualified_name(node, name, source, &["class_declaration", "abstract_class_declaration", "function_declaration"])
                }
                TreeSitterAdapter::Go => {
                    if node.kind() == "method_declaration" {
                        go_qualified_method_name(node, name, source)
                    } else {
                        name.to_string()
                    }
                }
                TreeSitterAdapter::C => name.to_string(),
                TreeSitterAdapter::Cpp => {
                    qualified_name(node, name, source, &["class_specifier", "namespace_definition"])
                }
                TreeSitterAdapter::CSharp => {
                    qualified_name(
                        node,
                        name,
                        source,
                        &[
                            "class_declaration",
                            "struct_declaration",
                            "interface_declaration",
                            "record_declaration",
                            "namespace_declaration",
                        ],
                    )
                }
                TreeSitterAdapter::Rust => {
                    rust_method_owner(node, source)
                        .map(|owner| format!("{owner}.{name}"))
                        .unwrap_or_else(|| name.to_string())
                }
                TreeSitterAdapter::Zig => {
                    zig_container_owner(node, source)
                        .map(|owner| format!("{owner}.{name}"))
                        .unwrap_or_else(|| name.to_string())
                }
                TreeSitterAdapter::Java => {
                    qualified_name(
                        node,
                        name,
                        source,
                        &[
                            "class_declaration",
                            "interface_declaration",
                            "enum_declaration",
                            "record_declaration",
                        ],
                    )
                }
                TreeSitterAdapter::Kotlin => {
                    qualified_name(
                        node,
                        name,
                        source,
                        &[
                            "class_declaration",
                            "object_declaration",
                        ],
                    )
                }
                TreeSitterAdapter::Lua => name.to_string(),
                TreeSitterAdapter::Php => {
                    qualified_name(
                        node,
                        name,
                        source,
                        &[
                            "class_declaration",
                            "interface_declaration",
                            "trait_declaration",
                            "namespace_definition",
                        ],
                    )
                }
                TreeSitterAdapter::Swift => {
                    qualified_name(
                        node,
                        name,
                        source,
                        &[
                            "class_declaration",
                            "protocol_declaration",
                        ],
                    )
                }
            }
        }
    };

    tree_sitter_candidate(node, qualified, kind, source, lines)
}

fn tree_sitter_candidates(
    file: &BlobFile,
    extension: &str,
    lines: &[&str],
) -> Option<Vec<Candidate>> {
    let adapter = TreeSitterAdapter::for_extension(extension)?;
    let mut parser = Parser::new();
    if let Err(error) = parser.set_language(&adapter.language()) {
        if std::env::var("LINEAGE_DEBUG_EXTRACT").is_ok() {
            eprintln!(
                "tree-sitter language setup failed in {} ({extension}): {error:?}",
                file.path
            );
        }
        return None;
    }
    let tree = parser.parse(&file.contents, None)?;
    if tree.root_node().has_error() {
        if std::env::var("LINEAGE_DEBUG_EXTRACT").is_ok() {
            eprintln!(
                "tree-sitter parse error in {} ({extension}): {}",
                file.path,
                tree.root_node().to_sexp()
            );
        }
        return None;
    }

    let query_str = adapter.query_str();
    let query = match tree_sitter::Query::new(&adapter.language(), query_str) {
        Ok(q) => q,
        Err(e) => {
            if std::env::var("LINEAGE_DEBUG_EXTRACT").is_ok() {
                eprintln!("Failed to compile query for {extension}: {e:?}");
            }
            return None;
        }
    };

    let mut cursor = tree_sitter::QueryCursor::new();
    let mut candidates = Vec::new();

    let mut matches = cursor.matches(&query, tree.root_node(), file.contents.as_bytes());
    while let Some(m) = matches.next() {
        let mut kind = None;
        let mut name = String::new();
        let mut primary_node = None;

        for capture in m.captures {
            let capture_name = query.capture_names()[capture.index as usize];
            match capture_name {
                "definition.class" => {
                    kind = Some(UnitKind::Class);
                    primary_node = Some(capture.node);
                }
                "definition.function" => {
                    kind = Some(UnitKind::Function);
                    primary_node = Some(capture.node);
                }
                "definition.module" => {
                    kind = Some(UnitKind::Module);
                    primary_node = Some(capture.node);
                }
                "name" => {
                    if let Ok(text) = capture.node.utf8_text(file.contents.as_bytes()) {
                        name = text.trim().to_string();
                    }
                }
                _ => {}
            }
        }

        if let Some(n) = primary_node {
            let k = kind.unwrap_or(UnitKind::Function);
            let resolved_name = if name.is_empty() {
                match adapter {
                    TreeSitterAdapter::C | TreeSitterAdapter::Cpp => {
                        if n.kind() == "function_definition" {
                            c_like_function_name(n, &file.contents).unwrap_or_default()
                        } else if n.kind() == "type_definition" {
                            c_like_typedef_name(n, &file.contents).unwrap_or_default()
                        } else {
                            c_like_type_name(n, &file.contents).unwrap_or_default()
                        }
                    }
                    TreeSitterAdapter::CSharp => {
                        if n.kind() == "constructor_declaration" {
                            nearest_owner_name(n, &file.contents, &["class_declaration", "struct_declaration", "record_declaration"]).unwrap_or_default()
                        } else {
                            String::new()
                        }
                    }
                    _ => String::new(),
                }
            } else {
                name
            };

            if adapter as usize == TreeSitterAdapter::Zig as usize && n.kind() == "variable_declaration" {
                if let Some(cand) = zig_container_declaration_candidate(n, &file.contents, lines) {
                    candidates.push(cand);
                }
                continue;
            }

            if resolved_name.is_empty() {
                continue;
            }

            let cand = candidate_from_capture(adapter, n, &resolved_name, k, &file.contents, lines);
            candidates.push(cand);
        }
    }

    Some(candidates)
}

fn tree_sitter_candidate(
    node: Node<'_>,
    name: String,
    kind: UnitKind,
    source: &str,
    lines: &[&str],
) -> Candidate {
    let start_line = node.start_position().row as u32 + 1;
    let end_line = node.end_position().row as u32 + 1;
    Candidate {
        name,
        kind,
        signature: signature_for_node(node, source, lines),
        line: start_line,
        end_line: Some(end_line.max(start_line)),
    }
}

fn signature_for_node(node: Node<'_>, source: &str, lines: &[&str]) -> String {
    let start_line = node.start_position().row;
    let end_line = node.end_position().row;
    if start_line == end_line {
        return lines
            .get(start_line)
            .map(|line| line.trim().to_string())
            .unwrap_or_default();
    }

    node.utf8_text(source.as_bytes())
        .ok()
        .and_then(|text| text.lines().find(|line| !line.trim().is_empty()))
        .map(|line| line.trim().to_string())
        .unwrap_or_default()
}

fn field_text<'a>(node: Node<'_>, field_name: &str, source: &'a str) -> Option<&'a str> {
    node.child_by_field_name(field_name)?
        .utf8_text(source.as_bytes())
        .ok()
        .map(str::trim)
        .filter(|value| !value.is_empty())
}

fn first_identifier_child<'a>(node: Node<'_>, source: &'a str) -> Option<&'a str> {
    for index in 0..node.named_child_count() {
        let child = node.named_child(index)?;
        if child.kind() == "identifier" || child.kind() == "type_identifier" {
            return child.utf8_text(source.as_bytes()).ok().map(str::trim);
        }
    }
    None
}

fn qualified_name(node: Node<'_>, base: &str, source: &str, owner_kinds: &[&str]) -> String {
    let mut owners = Vec::new();
    let mut current = node;
    while let Some(parent) = current.parent() {
        if owner_kinds.contains(&parent.kind()) {
            if let Some(owner) = owner_name(parent, source) {
                owners.push(owner);
            }
        }
        current = parent;
    }
    owners.reverse();
    owners.push(clean_owner_name(base));
    owners.join(".")
}

fn nearest_owner_name(mut node: Node<'_>, source: &str, owner_kinds: &[&str]) -> Option<String> {
    while let Some(parent) = node.parent() {
        if owner_kinds.contains(&parent.kind()) {
            return owner_name(parent, source);
        }
        node = parent;
    }
    None
}

fn owner_name(node: Node<'_>, source: &str) -> Option<String> {
    match node.kind() {
        "class" | "module" | "class_definition" | "class_declaration" | "abstract_class_declaration"
        | "interface_declaration" | "record_declaration" | "struct_declaration" | "enum_declaration"
        | "namespace_definition" | "namespace_declaration" | "internal_module" | "object_declaration"
        | "trait_declaration" | "protocol_declaration" => {
            field_text(node, "name", source).map(clean_owner_name)
        }
        "function_definition" | "function_declaration" | "method" | "method_definition"
        | "method_declaration" | "singleton_method" => {
            field_text(node, "name", source).map(clean_owner_name)
        }
        "function_item" => field_text(node, "name", source).map(clean_owner_name),
        "type_spec" | "type_alias" => field_text(node, "name", source).map(clean_owner_name),
        "class_specifier" | "struct_specifier" | "union_specifier" | "enum_specifier" => {
            c_like_type_name(node, source)
        }
        _ => None,
    }
}

fn go_qualified_method_name(node: Node<'_>, name: &str, source: &str) -> String {
    let Some(receiver) = node.child_by_field_name("receiver") else {
        return name.to_string();
    };
    let receiver_text = receiver.utf8_text(source.as_bytes()).unwrap_or_default();
    let receiver_type = receiver_text
        .split_whitespace()
        .last()
        .unwrap_or(receiver_text)
        .trim_matches(|ch: char| matches!(ch, '*' | '(' | ')' | '[' | ']'));
    if receiver_type.is_empty() {
        name.to_string()
    } else {
        format!("{receiver_type}.{name}")
    }
}

fn c_like_function_name(node: Node<'_>, source: &str) -> Option<String> {
    let declarator = node.child_by_field_name("declarator")?;
    declarator_name(declarator, source).map(|name| clean_owner_name(&name))
}



fn c_like_typedef_name(node: Node<'_>, source: &str) -> Option<String> {
    node.child_by_field_name("declarator")
        .and_then(|declarator| declarator_name(declarator, source))
        .or_else(|| last_descendant_text(node, source, &["type_identifier", "identifier"]))
        .map(|name| clean_owner_name(&name))
}

fn c_like_type_name(node: Node<'_>, source: &str) -> Option<String> {
    field_text(node, "name", source)
        .map(clean_owner_name)
        .or_else(|| first_descendant_text(node, source, &["type_identifier", "identifier"]).map(|text| clean_owner_name(&text)))
}

fn declarator_name(node: Node<'_>, source: &str) -> Option<String> {
    if let Some(name) = field_text(node, "name", source) {
        return Some(name.to_string());
    }
    if matches!(
        node.kind(),
        "identifier" | "field_identifier" | "type_identifier" | "qualified_identifier" | "scoped_identifier"
    ) {
        return node.utf8_text(source.as_bytes()).ok().map(str::to_string);
    }
    if let Some(child) = node.child_by_field_name("declarator") {
        return declarator_name(child, source);
    }
    first_descendant_text(
        node,
        source,
        &[
            "field_identifier",
            "identifier",
            "qualified_identifier",
            "scoped_identifier",
            "type_identifier",
        ],
    )
}

fn first_descendant_text(node: Node<'_>, source: &str, kinds: &[&str]) -> Option<String> {
    if kinds.contains(&node.kind()) {
        return node.utf8_text(source.as_bytes()).ok().map(str::to_string);
    }
    for index in 0..node.named_child_count() {
        if let Some(child) = node.named_child(index) {
            if let Some(text) = first_descendant_text(child, source, kinds) {
                return Some(text);
            }
        }
    }
    None
}

fn last_descendant_text(node: Node<'_>, source: &str, kinds: &[&str]) -> Option<String> {
    let mut found = if kinds.contains(&node.kind()) {
        node.utf8_text(source.as_bytes()).ok().map(str::to_string)
    } else {
        None
    };
    for index in 0..node.named_child_count() {
        if let Some(child) = node.named_child(index) {
            if let Some(text) = last_descendant_text(child, source, kinds) {
                found = Some(text);
            }
        }
    }
    found
}

fn rust_method_owner(node: Node<'_>, source: &str) -> Option<String> {
    let impl_node = ancestor_kind(node, "impl_item")?;
    field_text(impl_node, "type", source).map(clean_owner_name)
}

fn zig_container_owner(node: Node<'_>, source: &str) -> Option<String> {
    let container = ancestor_any(
        node,
        &[
            "struct_declaration",
            "enum_declaration",
            "union_declaration",
            "opaque_declaration",
        ],
    )?;
    let parent = container.parent()?;
    if parent.kind() != "variable_declaration" {
        return ancestor_kind(container, "function_declaration")
            .and_then(|function| field_text(function, "name", source))
            .map(clean_owner_name);
    }
    first_identifier_child(parent, source).map(clean_owner_name)
}

fn zig_container_declaration_candidate(
    node: Node<'_>,
    source: &str,
    lines: &[&str],
) -> Option<Candidate> {
    let has_container_child = (0..node.named_child_count()).any(|index| {
        node.named_child(index)
            .map(|child| {
                matches!(
                    child.kind(),
                    "struct_declaration"
                        | "enum_declaration"
                        | "union_declaration"
                        | "opaque_declaration"
                )
            })
            .unwrap_or(false)
    });
    if !has_container_child {
        return None;
    }

    let name = first_identifier_child(node, source)?;
    Some(tree_sitter_candidate(
        node,
        clean_owner_name(name),
        UnitKind::Class,
        source,
        lines,
    ))
}

fn ancestor_kind<'tree>(mut node: Node<'tree>, kind: &str) -> Option<Node<'tree>> {
    while let Some(parent) = node.parent() {
        if parent.kind() == kind {
            return Some(parent);
        }
        node = parent;
    }
    None
}

fn ancestor_any<'tree>(mut node: Node<'tree>, kinds: &[&str]) -> Option<Node<'tree>> {
    while let Some(parent) = node.parent() {
        if kinds.contains(&parent.kind()) {
            return Some(parent);
        }
        node = parent;
    }
    None
}

fn clean_owner_name(name: &str) -> String {
    name.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn detect_ruby_python(line: &str, line_number: u32) -> Option<Candidate> {
    if let Some(rest) = ruby_python_def_rest(line) {
        return named_candidate(rest, UnitKind::Function, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("class ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("module ") {
        return named_candidate(rest, UnitKind::Module, line, line_number);
    }
    None
}

fn ruby_python_def_rest(line: &str) -> Option<&str> {
    if let Some(rest) = line.strip_prefix("def ") {
        return Some(rest);
    }
    let (prefix, rest) = line.split_once(" def ")?;
    let prefix = prefix.trim();
    if matches!(
        prefix,
        "private" | "protected" | "public" | "private_class_method" | "module_function"
    ) {
        Some(rest)
    } else {
        None
    }
}

fn detect_javascript_typescript(line: &str, line_number: u32) -> Option<Candidate> {
    let line = strip_javascript_modifiers(line);

    if let Some(rest) = line.strip_prefix("function ") {
        return named_candidate(rest, UnitKind::Function, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("class ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("interface ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("type ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(name) = javascript_const_callable_name(line) {
        return Some(Candidate {
            name: name.to_string(),
            kind: UnitKind::Function,
            signature: line.trim().to_string(),
            line: line_number,
            end_line: None,
        });
    }
    None
}

fn strip_javascript_modifiers(mut line: &str) -> &str {
    loop {
        let next = line
            .strip_prefix("export default ")
            .or_else(|| line.strip_prefix("export "))
            .or_else(|| line.strip_prefix("declare "))
            .or_else(|| line.strip_prefix("abstract "))
            .or_else(|| line.strip_prefix("async "))
            .unwrap_or(line);
        if next == line {
            return line;
        }
        line = next;
    }
}

fn detect_php(line: &str, line_number: u32) -> Option<Candidate> {
    let line = strip_php_modifiers(line);
    if let Some(rest) = line.strip_prefix("function ") {
        return named_candidate(rest, UnitKind::Function, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("class ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("interface ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("trait ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    None
}

fn strip_php_modifiers(mut line: &str) -> &str {
    loop {
        let next = line
            .strip_prefix("public ")
            .or_else(|| line.strip_prefix("private "))
            .or_else(|| line.strip_prefix("protected "))
            .or_else(|| line.strip_prefix("static "))
            .or_else(|| line.strip_prefix("final "))
            .or_else(|| line.strip_prefix("abstract "))
            .unwrap_or(line);
        if next == line {
            return line;
        }
        line = next;
    }
}


fn javascript_const_callable_name(line: &str) -> Option<&str> {
    let rest = line
        .strip_prefix("const ")
        .or_else(|| line.strip_prefix("let "))
        .or_else(|| line.strip_prefix("var "))?;
    let name = javascript_identifier(rest)?;
    let after_name = rest[name.len()..].trim_start();
    if after_name.starts_with('=') && after_name.contains("=>") {
        return Some(name);
    }
    if after_name.starts_with(':') {
        let type_annotation = after_name.split('=').next().unwrap_or(after_name);
        if type_annotation.contains("=>") || type_annotation.contains('(') {
            return Some(name);
        }
    }
    None
}

fn javascript_identifier(input: &str) -> Option<&str> {
    let input = input.trim_start();
    let end = input
        .char_indices()
        .find_map(|(index, ch)| {
            if ch.is_alphanumeric() || ch == '_' || ch == '$' {
                None
            } else {
                Some(index)
            }
        })
        .unwrap_or(input.len());
    let ident = &input[..end];
    if ident.is_empty() {
        None
    } else {
        Some(ident)
    }
}

fn detect_lua(line: &str, line_number: u32) -> Option<Candidate> {
    let rest = line
        .strip_prefix("local function ")
        .or_else(|| line.strip_prefix("function "))?;
    named_candidate(rest, UnitKind::Function, line, line_number)
}

fn detect_c_family(line: &str, line_number: u32) -> Option<Candidate> {
    if let Some(rest) = c_family_type_rest(line) {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if line.ends_with(';') || !line.contains('(') || !line.contains(')') || !line.contains('{') {
        return None;
    }

    let before_paren = line.split_once('(')?.0.trim_end();
    let name = before_paren.split_whitespace().last()?;
    if matches!(
        name,
        "if" | "for" | "while" | "switch" | "return" | "sizeof" | "catch"
    ) {
        return None;
    }

    Some(Candidate {
        name: name.trim_start_matches('*').to_string(),
        kind: UnitKind::Function,
        signature: line.trim().to_string(),
        line: line_number,
        end_line: None,
    })
}

fn c_family_type_rest(line: &str) -> Option<&str> {
    let line = strip_c_family_modifiers(line);
    line.strip_prefix("class ")
        .or_else(|| line.strip_prefix("struct "))
        .or_else(|| line.strip_prefix("enum "))
        .or_else(|| line.strip_prefix("namespace "))
}

fn strip_c_family_modifiers(mut line: &str) -> &str {
    loop {
        let next = line
            .strip_prefix("template ")
            .or_else(|| line.strip_prefix("export "))
            .or_else(|| line.strip_prefix("public "))
            .or_else(|| line.strip_prefix("private "))
            .or_else(|| line.strip_prefix("protected "))
            .or_else(|| line.strip_prefix("internal "))
            .or_else(|| line.strip_prefix("static "))
            .or_else(|| line.strip_prefix("inline "))
            .or_else(|| line.strip_prefix("constexpr "))
            .or_else(|| line.strip_prefix("sealed "))
            .or_else(|| line.strip_prefix("abstract "))
            .or_else(|| line.strip_prefix("partial "))
            .or_else(|| line.strip_prefix("readonly "))
            .unwrap_or(line);
        if next == line {
            return line;
        }
        line = next;
    }
}

fn detect_csharp_java(line: &str, line_number: u32) -> Option<Candidate> {
    let line = strip_c_family_modifiers(line);
    if let Some(rest) = line
        .strip_prefix("class ")
        .or_else(|| line.strip_prefix("interface "))
        .or_else(|| line.strip_prefix("struct "))
        .or_else(|| line.strip_prefix("enum "))
        .or_else(|| line.strip_prefix("record "))
    {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    detect_c_family(line, line_number)
}

fn detect_swift(line: &str, line_number: u32) -> Option<Candidate> {
    let line = strip_swift_modifiers(line);
    if let Some(rest) = line
        .strip_prefix("class ")
        .or_else(|| line.strip_prefix("struct "))
        .or_else(|| line.strip_prefix("enum "))
        .or_else(|| line.strip_prefix("protocol "))
        .or_else(|| line.strip_prefix("actor "))
    {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("func ") {
        return named_candidate(rest, UnitKind::Function, line, line_number);
    }
    None
}

fn strip_swift_modifiers(mut line: &str) -> &str {
    loop {
        let next = line
            .strip_prefix("public ")
            .or_else(|| line.strip_prefix("private "))
            .or_else(|| line.strip_prefix("fileprivate "))
            .or_else(|| line.strip_prefix("internal "))
            .or_else(|| line.strip_prefix("open "))
            .or_else(|| line.strip_prefix("final "))
            .or_else(|| line.strip_prefix("static "))
            .or_else(|| line.strip_prefix("mutating "))
            .or_else(|| line.strip_prefix("async "))
            .unwrap_or(line);
        if next == line {
            return line;
        }
        line = next;
    }
}

fn detect_kotlin(line: &str, line_number: u32) -> Option<Candidate> {
    let line = strip_kotlin_modifiers(line);
    if let Some(rest) = line
        .strip_prefix("class ")
        .or_else(|| line.strip_prefix("interface "))
        .or_else(|| line.strip_prefix("object "))
        .or_else(|| line.strip_prefix("enum class "))
        .or_else(|| line.strip_prefix("data class "))
        .or_else(|| line.strip_prefix("sealed class "))
    {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("fun ") {
        return named_candidate(rest, UnitKind::Function, line, line_number);
    }
    None
}

fn strip_kotlin_modifiers(mut line: &str) -> &str {
    loop {
        let next = line
            .strip_prefix("public ")
            .or_else(|| line.strip_prefix("private "))
            .or_else(|| line.strip_prefix("protected "))
            .or_else(|| line.strip_prefix("internal "))
            .or_else(|| line.strip_prefix("open "))
            .or_else(|| line.strip_prefix("final "))
            .or_else(|| line.strip_prefix("abstract "))
            .or_else(|| line.strip_prefix("suspend "))
            .or_else(|| line.strip_prefix("inline "))
            .or_else(|| line.strip_prefix("override "))
            .unwrap_or(line);
        if next == line {
            return line;
        }
        line = next;
    }
}

fn detect_go(line: &str, line_number: u32) -> Option<Candidate> {
    let rest = line.strip_prefix("func ")?;
    if rest.starts_with('(') {
        let after_receiver = rest.split_once(')')?.1.trim_start();
        named_candidate(after_receiver, UnitKind::Function, line, line_number)
    } else {
        named_candidate(rest, UnitKind::Function, line, line_number)
    }
}

fn detect_assembly(line: &str, line_number: u32) -> Option<Candidate> {
    let label = line.strip_suffix(':')?;
    if label.is_empty() || label.starts_with('.') || label.contains(char::is_whitespace) {
        return None;
    }

    Some(Candidate {
        name: label.to_string(),
        kind: UnitKind::Function,
        signature: line.trim().to_string(),
        line: line_number,
        end_line: None,
    })
}

fn detect_rust_or_zig(line: &str, line_number: u32) -> Option<Candidate> {
    let mut rest = line;
    for prefix in ["pub ", "pub(crate) ", "pub(super) ", "unsafe ", "async ", "extern "] {
        rest = rest.strip_prefix(prefix).unwrap_or(rest);
    }
    let rest = rest.strip_prefix("fn ")?;
    named_candidate(rest, UnitKind::Function, line, line_number)
}

fn named_candidate(
    rest: &str,
    kind: UnitKind,
    signature: &str,
    line_number: u32,
) -> Option<Candidate> {
    let name = identifier(rest)?;
    Some(Candidate {
        name: name.to_string(),
        kind,
        signature: signature.trim().to_string(),
        line: line_number,
        end_line: None,
    })
}

fn identifier(input: &str) -> Option<&str> {
    let input = input.trim_start();
    let end = input
        .char_indices()
        .find_map(|(index, ch)| {
            if ch.is_alphanumeric()
                || ch == '_'
                || ch == '!'
                || ch == '?'
                || ch == '='
                || ch == '.'
                || ch == ':'
            {
                None
            } else {
                Some(index)
            }
        })
        .unwrap_or(input.len());
    let ident = &input[..end];
    if ident.is_empty() {
        None
    } else {
        Some(ident)
    }
}

fn extension(path: &str) -> Option<String> {
    path.rsplit_once('.').map(|(_, ext)| ext.to_string())
}

fn normalize_extension(ext: &str) -> String {
    if ext == "S" {
        "S".to_string()
    } else {
        ext.to_ascii_lowercase()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extracts_units_from_supported_languages() {
        let file = BlobFile {
            path: "src/demo.rb".into(),
            contents: "class Worker\n  def run(x)\n    x + 1\n  end\nend\n".into(),
        };
        let units = HeuristicExtractor::default().extract_units(&file);

        assert_eq!(units.len(), 2);
        assert_eq!(units[0].name, "Worker");
        assert_eq!(units[0].kind, UnitKind::Class);
        assert_eq!(units[1].name, "Worker.run");
        assert_eq!(units[1].kind, UnitKind::Function);
    }

    #[test]
    fn extracts_go_methods_and_zig_functions() {
        let go = BlobFile {
            path: "worker.go".into(),
            contents: "func (w *Worker) Run(x int) bool { return true }\n".into(),
        };
        let zig = BlobFile {
            path: "worker.zig".into(),
            contents: "pub fn run(x: i32) bool { return true; }\n".into(),
        };

        let extractor = HeuristicExtractor::default();
        assert_eq!(extractor.extract_units(&go)[0].name, "Worker.Run");
        assert_eq!(extractor.extract_units(&zig)[0].name, "run");
    }

    #[test]
    fn extracts_typescript_symbols_with_tree_sitter() {
        let file = BlobFile {
            path: "packages/zod/src/demo.ts".into(),
            contents: r#"
export interface ParseContext {
  async?: boolean;
}

export type Result<T> = { value: T };

export abstract class Parser {
  abstract run(value: unknown): Result<unknown>;
}

export function parse(value: unknown): Result<unknown> {
  return { value };
}

export const safeParse: (value: unknown) => Result<unknown> = (value) => {
  return { value };
};
"#
            .into(),
        };

        let units = HeuristicExtractor::default().extract_units(&file);
        let names: Vec<_> = units
            .iter()
            .map(|unit| (unit.kind, unit.name.as_str()))
            .collect();

        assert!(names.contains(&(UnitKind::Class, "ParseContext")));
        assert!(names.contains(&(UnitKind::Class, "Result")));
        assert!(names.contains(&(UnitKind::Class, "Parser")));
        assert!(names.contains(&(UnitKind::Function, "parse")));
        assert!(names.contains(&(UnitKind::Function, "safeParse")));
    }

    #[test]
    fn extracts_rust_symbols_with_tree_sitter() {
        let file = BlobFile {
            path: "gems/lineage/src/demo.rs".into(),
            contents: r#"
pub mod storage {
    pub struct Store {
        count: usize,
    }

    impl Store {
        pub fn open() -> Self {
            Self { count: 0 }
        }

        fn insert_row(&mut self) {
            self.count += 1;
        }
    }
}

fn helper() {}
"#
            .into(),
        };

        let units = HeuristicExtractor::default().extract_units(&file);
        let names: Vec<_> = units
            .iter()
            .map(|unit| (unit.kind, unit.name.as_str()))
            .collect();

        assert!(names.contains(&(UnitKind::Module, "storage")));
        assert!(names.contains(&(UnitKind::Class, "Store")));
        assert!(names.contains(&(UnitKind::Function, "Store.open")));
        assert!(names.contains(&(UnitKind::Function, "Store.insert_row")));
        assert!(names.contains(&(UnitKind::Function, "helper")));
        assert!(units.iter().any(|unit| unit.name == "Store.open" && unit.start_line == 8));
    }

    #[test]
    fn extracts_zig_containers_and_methods_with_tree_sitter() {
        let file = BlobFile {
            path: "zig/demo.zig".into(),
            contents: r#"
const Worker = struct {
    pub fn run(self: *Worker) void {
        _ = self;
    }
};

pub fn main() void {}
"#
            .into(),
        };

        let units = HeuristicExtractor::default().extract_units(&file);
        let names: Vec<_> = units
            .iter()
            .map(|unit| (unit.kind, unit.name.as_str()))
            .collect();

        assert!(names.contains(&(UnitKind::Class, "Worker")));
        assert!(names.contains(&(UnitKind::Function, "Worker.run")));
        assert!(names.contains(&(UnitKind::Function, "main")));
    }

    #[test]
    fn extracts_zig_methods_from_anonymous_struct_factories() {
        let file = BlobFile {
            path: "zig/factory.zig".into(),
            contents: r#"
pub fn StringMap(comptime Value: type) type {
    return struct {
        pub fn put(self: *@This(), key: []const u8, value: Value) void {
            _ = self;
            _ = key;
            _ = value;
        }
    };
}
"#
            .into(),
        };

        let units = HeuristicExtractor::default().extract_units(&file);
        let names: Vec<_> = units.iter().map(|unit| unit.name.as_str()).collect();

        assert!(names.contains(&"StringMap"));
        assert!(names.contains(&"StringMap.put"));
    }

    #[test]
    fn extracts_ruby_wrapped_class_methods_and_setters() {
        let file = BlobFile {
            path: "src/demo.rb".into(),
            contents: "class Worker\n  private_class_method def self.build!\n    1\n  end\n  def value=(next_value)\n    @value = next_value\n  end\nend\n".into(),
        };

        let units = HeuristicExtractor::default().extract_units(&file);
        let names: Vec<_> = units.iter().map(|unit| unit.name.as_str()).collect();

        assert!(names.contains(&"Worker.self.build!"));
        assert!(names.contains(&"Worker.value="));
    }

    #[test]
    fn tree_sitter_extraction_handles_nested_and_multiline_boundaries() {
        let python = BlobFile {
            path: "src/service.py".into(),
            contents: r#"
class Worker:
    def run(
        self,
        value: int,
    ) -> int:
        def normalize(next_value: int) -> int:
            return next_value + 1
        return normalize(value)
"#
            .into(),
        };
        let typescript = BlobFile {
            path: "src/service.ts".into(),
            contents: r#"
export class Worker {
  async run(
    value: number,
  ): Promise<number> {
    return value + 1;
  }
}
"#
            .into(),
        };

        let extractor = HeuristicExtractor::default();
        let python_names: Vec<_> = extractor
            .extract_units(&python)
            .into_iter()
            .map(|unit| (unit.name, unit.start_line, unit.end_line))
            .collect();
        assert!(python_names.contains(&("Worker".to_string(), 2, 9)));
        assert!(python_names.contains(&("Worker.run".to_string(), 3, 9)));
        assert!(python_names.contains(&("Worker.run.normalize".to_string(), 7, 8)));

        let typescript_names: Vec<_> = extractor
            .extract_units(&typescript)
            .into_iter()
            .map(|unit| (unit.name, unit.start_line, unit.end_line))
            .collect();
        assert!(typescript_names.contains(&("Worker".to_string(), 2, 8)));
        assert!(typescript_names.contains(&("Worker.run".to_string(), 3, 7)));
    }

    #[test]
    fn tree_sitter_extraction_ignores_strings_comments_and_parse_errors() {
        std::env::set_var("LINEAGE_DEBUG_EXTRACT", "1");
        let ruby = BlobFile {
            path: "src/demo.rb".into(),
            contents: "class Real\n  TEXT = \"def fake\\nend\"\n  # def also_fake\n  def run\n  end\nend\n".into(),
        };
        let invalid_go = BlobFile {
            path: "broken.go".into(),
            contents: "func RegexWouldHaveMatched() {\n".into(),
        };

        let extractor = HeuristicExtractor::default();
        let ruby_names: Vec<_> = extractor
            .extract_units(&ruby)
            .into_iter()
            .map(|unit| unit.name)
            .collect();
        assert!(ruby_names.contains(&"Real".to_string()));
        assert!(ruby_names.contains(&"Real.run".to_string()));
        assert!(!ruby_names.contains(&"fake".to_string()));
        assert!(!ruby_names.contains(&"also_fake".to_string()));
        assert!(extractor.extract_units(&invalid_go).is_empty());
        std::env::remove_var("LINEAGE_DEBUG_EXTRACT");
    }

    #[test]
    fn source_filter_is_a_code_whitelist() {
        let filter = SourceFilter::default();

        assert!(filter.supports_path("gems/x/lib/a.rb"));
        assert!(filter.supports_path("zig/main.zig"));
        assert!(filter.supports_path("src/vm.S"));
        assert!(filter.supports_path("src/main.c"));
        assert!(filter.supports_path("src/main.h"));
        assert!(filter.supports_path("src/main.cpp"));
        assert!(filter.supports_path("src/main.hpp"));
        assert!(filter.supports_path("src/Program.cs"));
        assert!(filter.supports_path("src/Main.java"));
        assert!(filter.supports_path("Sources/App.swift"));
        assert!(filter.supports_path("src/main.kt"));
        assert!(filter.supports_path("gems/lineage/src/ui.rs"));
        assert!(filter.supports_path("script/tool.lua"));
        assert!(!filter.supports_path("benchmarks/x/bench.profile/transpiled.zig"));
        assert!(!filter.supports_path("gems/lineage/target/debug/build.rs"));
        assert!(!filter.supports_path("gems/nil-kill/vendor/example.rb"));
        assert!(!filter.supports_path("README.md"));
        assert!(!filter.supports_path("gems/x/x.gemspec"));
        assert!(!filter.supports_path("Cargo.toml"));
        assert!(!filter.supports_path("src/vm.s"));
    }

    #[test]
    fn source_role_classifier_identifies_common_test_paths() {
        assert!(is_test_source_path("spec/affine_ownership_spec.rb"));
        assert!(is_test_source_path("gems/decomplex/test/report_test.rb"));
        assert!(is_test_source_path("gems/auto-type/spec/apply_spec.rb"));
        assert!(is_test_source_path("tests/test_parser.py"));
        assert!(is_test_source_path("src/parser.test.js"));
        assert!(is_test_source_path("zig/runtime/scheduler-test.zig"));
        assert!(is_test_source_path("zig/runtime/testing/vopr.zig"));
        assert!(is_test_source_path("transpile-tests/check.rb"));
        assert!(is_test_source_path("tools/fuzz/driver.rb"));
        assert!(is_test_source_path("src/foo/conftest.py"));
        assert!(is_test_source_path("src/foo-tests/bar.rb"));
        assert!(is_test_source_path("src/foo_tests/bar.rb"));
        assert!(is_test_source_path("src/foo.test.rb"));
        assert!(is_test_source_path("src/foo.spec.rb"));
        assert!(is_test_source_path("src/foo_spec.rb"));
        assert!(is_test_source_path("src/foo-test.rb"));
        assert!(is_test_source_path("src/test_foo.py"));

        assert!(is_production_source_path("src/ast/type.rb"));
        assert!(is_production_source_path("gems/decomplex/lib/decomplex/report.rb"));
        assert!(is_production_source_path("gems/lineage/src/ui.rs"));
        assert!(is_production_source_path("zig/lib/atomic.zig"));
    }

    #[test]
    fn extracts_lua_c_and_assembly_units() {
        let extractor = HeuristicExtractor::default();
        let lua = BlobFile {
            path: "tool.lua".into(),
            contents: "local function run(x)\n  return x\nend\n".into(),
        };
        let c = BlobFile {
            path: "main.c".into(),
            contents: "static int run(int x) { return x + 1; }\n".into(),
        };
        let asm = BlobFile {
            path: "boot.S".into(),
            contents: ".globl boot\nboot:\n  ret\n".into(),
        };

        assert_eq!(extractor.extract_units(&lua)[0].name, "run");
        assert_eq!(extractor.extract_units(&c)[0].name, "run");
        assert_eq!(extractor.extract_units(&asm)[0].name, "boot");
    }

    #[test]
    fn extracts_c_family_and_managed_language_units() {
        let extractor = HeuristicExtractor::default();
        let cpp = BlobFile {
            path: "include/demo.hpp".into(),
            contents: "class Parser {\n};\nstatic int parse_value(int x) { return x; }\n".into(),
        };
        let csharp = BlobFile {
            path: "src/Program.cs".into(),
            contents: "public sealed class Program {}\nprivate static int Run(int x) { return x; }\n".into(),
        };
        let java = BlobFile {
            path: "src/Main.java".into(),
            contents: "public interface Handler {}\npublic int handle(int x) { return x; }\n".into(),
        };
        let swift = BlobFile {
            path: "Sources/App.swift".into(),
            contents: "public struct App {}\npublic func run(_ x: Int) -> Int { x }\n".into(),
        };
        let kotlin = BlobFile {
            path: "src/main.kt".into(),
            contents: "data class Box(val value: Int)\nsuspend fun run(value: Int): Int = value\n".into(),
        };

        let cpp_names: Vec<_> = extractor
            .extract_units(&cpp)
            .into_iter()
            .map(|unit| (unit.kind, unit.name))
            .collect();
        assert!(cpp_names.contains(&(UnitKind::Class, "Parser".to_string())));
        assert!(cpp_names.contains(&(UnitKind::Function, "parse_value".to_string())));

        assert_eq!(extractor.extract_units(&csharp)[0].name, "Program");
        assert_eq!(extractor.extract_units(&java)[0].name, "Handler");
        assert_eq!(extractor.extract_units(&swift)[0].name, "App");
        assert_eq!(extractor.extract_units(&swift)[1].name, "run");
        assert_eq!(extractor.extract_units(&kotlin)[0].name, "Box");
        assert_eq!(extractor.extract_units(&kotlin)[1].name, "run");
    }

    #[test]
    fn gives_same_named_units_distinct_ordinals_and_ids() {
        let file = BlobFile {
            path: "many.zig".into(),
            contents: "fn run() void {}\nfn helper() void {}\nfn run() void {}\n".into(),
        };
        let units = HeuristicExtractor::default().extract_units(&file);
        let runs: Vec<_> = units.iter().filter(|unit| unit.name == "run").collect();

        assert_eq!(runs.len(), 2);
        assert_eq!(runs[0].ordinal, 1);
        assert_eq!(runs[1].ordinal, 2);
        assert_ne!(runs[0].id, runs[1].id);
    }

    #[test]
    fn test_tree_sitter_additional_scenarios() {
        std::env::set_var("LINEAGE_DEBUG_EXTRACT", "1");
        
        // 1. Python type alias
        let py_file = BlobFile {
            path: "demo.py".into(),
            contents: "type TypeAlias = int\n".into(),
        };
        let py_units = HeuristicExtractor::default().extract_units(&py_file);
        assert!(py_units.iter().any(|u| u.name == "TypeAlias"));

        // 2. JavaScript / TS callables
        let js_file = BlobFile {
            path: "demo.js".into(),
            contents: r#"
                const my_arrow = () => { return 1; };
                let my_let = function() {};
                var my_generator = function* () {};
                class MyClass {
                    my_method() {}
                }
                function normal_func() {}
                function* normal_gen() {}
                let my_class_var = class MyClassVar {};
            "#.into(),
        };
        let js_units = HeuristicExtractor::default().extract_units(&js_file);
        let js_names: Vec<_> = js_units.iter().map(|u| u.name.as_str()).collect();
        assert!(js_names.contains(&"my_arrow"));
        assert!(js_names.contains(&"my_let"));
        assert!(js_names.contains(&"my_generator"));
        assert!(js_names.contains(&"MyClass"));
        assert!(js_names.contains(&"MyClass.my_method"));
        assert!(js_names.contains(&"normal_func"));
        assert!(js_names.contains(&"normal_gen"));
        assert!(js_names.contains(&"my_class_var"));

        // 3. TS public fields & constructors
        let ts_file = BlobFile {
            path: "demo.ts".into(),
            contents: r#"
                class Parser {
                    public my_field_arrow = (v) => { return v; };
                    public my_val = 1;
                }
            "#.into(),
        };
        let ts_units = HeuristicExtractor::default().extract_units(&ts_file);
        let ts_names: Vec<_> = ts_units.iter().map(|u| u.name.as_str()).collect();
        assert!(ts_names.contains(&"Parser"));
        assert!(ts_names.contains(&"Parser.my_field_arrow"));

        // 4. Go method receivers (pointers, slices, brackets, etc.)
        let go_file = BlobFile {
            path: "demo.go".into(),
            contents: r#"
                type MyType struct {}
                func (w *MyType) PointerRec() {}
                func (w MyType) ValueRec() {}
                type Alias = int
            "#.into(),
        };
        let go_units = HeuristicExtractor::default().extract_units(&go_file);
        let go_names: Vec<_> = go_units.iter().map(|u| u.name.as_str()).collect();
        assert!(go_names.contains(&"MyType"));
        assert!(go_names.contains(&"MyType.PointerRec"));
        assert!(go_names.contains(&"MyType.ValueRec"));
        assert!(go_names.contains(&"Alias"));

        // 5. C/C++ typedefs, structs, unions, enums, namespaces
        let cpp_file = BlobFile {
            path: "demo.cpp".into(),
            contents: r#"
                namespace MyNamespace {
                    typedef struct { int x; } Point;
                    union Data { int i; float f; };
                    enum Color { RED, GREEN };
                }
            "#.into(),
        };
        let cpp_units = HeuristicExtractor::default().extract_units(&cpp_file);
        let cpp_names: Vec<_> = cpp_units.iter().map(|u| u.name.as_str()).collect();
        assert!(cpp_names.contains(&"MyNamespace"));
        assert!(cpp_names.contains(&"Point"));
        assert!(cpp_names.contains(&"Data"));
        assert!(cpp_names.contains(&"Color"));

        // 6. C# constructor resolution fallback
        let cs_file = BlobFile {
            path: "demo.cs".into(),
            contents: r#"
                namespace MyNs {
                    class Calculator {
                        public Calculator() {}
                    }
                }
            "#.into(),
        };
        let cs_units = HeuristicExtractor::default().extract_units(&cs_file);
        let cs_names: Vec<_> = cs_units.iter().map(|u| u.name.as_str()).collect();
        assert!(cs_names.contains(&"MyNs.Calculator.Calculator"));

        // 7. Rust extra items (enum, trait, union, type)
        let rs_file = BlobFile {
            path: "demo.rs".into(),
            contents: r#"
                enum Option { None, Some }
                trait Show { fn show(&self); }
                union Maybe { x: i32 }
                type Number = i64;
            "#.into(),
        };
        let rs_units = HeuristicExtractor::default().extract_units(&rs_file);
        let rs_names: Vec<_> = rs_units.iter().map(|u| u.name.as_str()).collect();
        assert!(rs_names.contains(&"Option"));
        assert!(rs_names.contains(&"Show"));
        assert!(rs_names.contains(&"Maybe"));
        assert!(rs_names.contains(&"Number"));

        // 8. Zig extra items (enum, union)
        let zig_file = BlobFile {
            path: "demo.zig".into(),
            contents: r#"
                const Direction = enum { north, south };
                const Payload = union { integer: i32, boolean: bool };
            "#.into(),
        };
        let zig_units = HeuristicExtractor::default().extract_units(&zig_file);
        let zig_names: Vec<_> = zig_units.iter().map(|u| u.name.as_str()).collect();
        assert!(zig_names.contains(&"Direction"));
        assert!(zig_names.contains(&"Payload"));

        // 9. Empty tree-sitter candidates output debug printing
        let py_empty = BlobFile {
            path: "empty.py".into(),
            contents: "print('hello')\n".into(),
        };
        let py_empty_units = HeuristicExtractor::default().extract_units(&py_empty);
        assert!(py_empty_units.is_empty());

        // 10. TSX file support
        let tsx_file = BlobFile {
            path: "demo.tsx".into(),
            contents: r#"
                const Component = () => {
                    return <div />;
                };
            "#.into(),
        };
        let tsx_units = HeuristicExtractor::default().extract_units(&tsx_file);
        let tsx_names: Vec<_> = tsx_units.iter().map(|u| u.name.as_str()).collect();
        assert!(tsx_names.contains(&"Component"));

        // 12. Java class, interface, enum, record, constructor, method
        let java_file = BlobFile {
            path: "demo.java".into(),
            contents: r#"
                class MyClass {
                    public MyClass() {}
                    void myMethod() {}
                }
                interface MyInterface {}
                enum MyEnum {}
                record MyRecord(int x) {}
            "#.into(),
        };
        let java_units = HeuristicExtractor::default().extract_units(&java_file);
        let java_names: Vec<_> = java_units.iter().map(|u| u.name.as_str()).collect();
        assert!(java_names.contains(&"MyClass"));
        assert!(java_names.contains(&"MyClass.MyClass"));
        assert!(java_names.contains(&"MyClass.myMethod"));
        assert!(java_names.contains(&"MyInterface"));
        assert!(java_names.contains(&"MyEnum"));
        assert!(java_names.contains(&"MyRecord"));

        // 13. Kotlin class, object, interface, fun
        let kotlin_file = BlobFile {
            path: "demo.kt".into(),
            contents: r#"
                class MyClass {
                    fun myMethod() {}
                }
                object MyObject {}
                interface MyInterface {}
            "#.into(),
        };
        let kotlin_units = HeuristicExtractor::default().extract_units(&kotlin_file);
        let kotlin_names: Vec<_> = kotlin_units.iter().map(|u| u.name.as_str()).collect();
        assert!(kotlin_names.contains(&"MyClass"));
        assert!(kotlin_names.contains(&"MyClass.myMethod"));
        assert!(kotlin_names.contains(&"MyObject"));
        assert!(kotlin_names.contains(&"MyInterface"));

        // 14. Lua local & global functions
        let lua_file = BlobFile {
            path: "demo.lua".into(),
            contents: r#"
                local function myLocal() end
                function myGlobal() end
            "#.into(),
        };
        let lua_units = HeuristicExtractor::default().extract_units(&lua_file);
        let lua_names: Vec<_> = lua_units.iter().map(|u| u.name.as_str()).collect();
        assert!(lua_names.contains(&"myLocal"));
        assert!(lua_names.contains(&"myGlobal"));

        // 15. PHP namespace, class, interface, trait, method, function
        let php_file = BlobFile {
            path: "demo.php".into(),
            contents: r#"
                <?php
                namespace MyNamespace;
                interface MyInterface {}
                trait MyTrait {}
                class MyClass {
                    function myMethod() {}
                }
                function myFunc() {}
            "#.into(),
        };
        let php_units = HeuristicExtractor::default().extract_units(&php_file);
        let php_names: Vec<_> = php_units.iter().map(|u| u.name.as_str()).collect();
        assert!(php_names.contains(&"MyNamespace"));
        assert!(php_names.contains(&"MyInterface"));
        assert!(php_names.contains(&"MyTrait"));
        assert!(php_names.contains(&"MyClass"));
        assert!(php_names.contains(&"MyClass.myMethod"));
        assert!(php_names.contains(&"myFunc"));

        // 16. Swift class, struct, actor, protocol, extension, func, method
        let swift_file = BlobFile {
            path: "demo.swift".into(),
            contents: r#"
                class MyClass {
                    func myMethod() {}
                }
                struct MyStruct {}
                actor MyActor {}
                protocol MyProto {}
                extension MyClass {}
                func myFunc() {}
            "#.into(),
        };
        let swift_units = HeuristicExtractor::default().extract_units(&swift_file);
        let swift_names: Vec<_> = swift_units.iter().map(|u| u.name.as_str()).collect();
        assert!(swift_names.contains(&"MyClass"));
        assert!(swift_names.contains(&"MyClass.myMethod"));
        assert!(swift_names.contains(&"MyStruct"));
        assert!(swift_names.contains(&"MyActor"));
        assert!(swift_names.contains(&"MyProto"));
        assert!(swift_names.contains(&"myFunc"));

        // 11. Unsupported path/extension checks
        let unsupported_file = BlobFile {
            path: "demo.unsupported".into(),
            contents: "def foo\nend\n".into(),
        };
        assert!(HeuristicExtractor::default().extract_units(&unsupported_file).is_empty());
        
        std::env::remove_var("LINEAGE_DEBUG_EXTRACT");
    }

    #[test]
    fn test_heuristic_additional_scenarios() {
        // Ruby/Python def modifiers and declarations in heuristics
        let rb_cand = detect_ruby_python("private def helper", 1).unwrap();
        assert_eq!(rb_cand.name, "helper");
        let rb_class = detect_ruby_python("class Worker", 2).unwrap();
        assert_eq!(rb_class.name, "Worker");
        let rb_module = detect_ruby_python("module Helper", 3).unwrap();
        assert_eq!(rb_module.name, "Helper");

        // JS/TS variable arrow callable heuristics, interface, class, type
        let js_cand = detect_javascript_typescript("const helper = () => {}", 1).unwrap();
        assert_eq!(js_cand.name, "helper");
        let ts_cand = detect_javascript_typescript("let another: () => void = () => {}", 2).unwrap();
        assert_eq!(ts_cand.name, "another");
        let js_class = detect_javascript_typescript("class MyClass", 3).unwrap();
        assert_eq!(js_class.name, "MyClass");
        let ts_interface = detect_javascript_typescript("interface IMyInterface", 4).unwrap();
        assert_eq!(ts_interface.name, "IMyInterface");
        let ts_type = detect_javascript_typescript("type MyType = void", 5).unwrap();
        assert_eq!(ts_type.name, "MyType");
        let ts_cand2 = detect_javascript_typescript("const helper: (x: number) => number = x => x", 6).unwrap();
        assert_eq!(ts_cand2.name, "helper");
        let ts_cand3 = detect_javascript_typescript("let another: (x: number) => void", 7).unwrap();
        assert_eq!(ts_cand3.name, "another");
        let ts_cand4 = detect_javascript_typescript("var my_func: (Option)", 8).unwrap();
        assert_eq!(ts_cand4.name, "my_func");

        // Lua heuristics
        let lua_cand = detect_lua("function global_fn()", 1).unwrap();
        assert_eq!(lua_cand.name, "global_fn");

        // C heuristics - invalid matching control keywords
        let c_cand = detect_c_family("if (x == 1) {", 1);
        assert!(c_cand.is_none());

        // Swift heuristics with extra modifiers and actor/protocol
        let swift_cand1 = detect_swift("protocol Proto", 1).unwrap();
        assert_eq!(swift_cand1.name, "Proto");
        let swift_cand2 = detect_swift("actor Account", 2).unwrap();
        assert_eq!(swift_cand2.name, "Account");
        let swift_cand3 = detect_swift("fileprivate mutating func run()", 3).unwrap();
        assert_eq!(swift_cand3.name, "run");
        let swift_class = detect_swift("class App", 4).unwrap();
        assert_eq!(swift_class.name, "App");
        let swift_struct = detect_swift("struct State", 5).unwrap();
        assert_eq!(swift_struct.name, "State");
        let swift_enum = detect_swift("enum Kind", 6).unwrap();
        assert_eq!(swift_enum.name, "Kind");

        // Kotlin heuristics with object, enum, sealed class, suspend/override fun
        let kt_cand1 = detect_kotlin("object Database", 1).unwrap();
        assert_eq!(kt_cand1.name, "Database");
        let kt_cand2 = detect_kotlin("enum class State", 2).unwrap();
        assert_eq!(kt_cand2.name, "State");
        let kt_cand3 = detect_kotlin("sealed class Result", 3).unwrap();
        assert_eq!(kt_cand3.name, "Result");
        let kt_cand4 = detect_kotlin("internal suspend fun perform()", 4).unwrap();
        assert_eq!(kt_cand4.name, "perform");
        let kt_class = detect_kotlin("class Box", 5).unwrap();
        assert_eq!(kt_class.name, "Box");
        let kt_interface = detect_kotlin("interface Handler", 6).unwrap();
        assert_eq!(kt_interface.name, "Handler");

        // Assembly heuristics - invalid labels & valid label
        let asm_cand1 = detect_assembly(".local_label:", 1);
        assert!(asm_cand1.is_none());
        let asm_cand2 = detect_assembly("label with spaces:", 2);
        assert!(asm_cand2.is_none());
        let asm_cand3 = detect_assembly("label:", 3).unwrap();
        assert_eq!(asm_cand3.name, "label");

        // Rust/Zig heuristics with modifiers
        let rs_cand = detect_rust_or_zig("pub(crate) unsafe extern fn execute()", 1).unwrap();
        assert_eq!(rs_cand.name, "execute");

        // Go heuristics basic receiver
        let go_cand1 = detect_go("func global_fn()", 1).unwrap();
        assert_eq!(go_cand1.name, "global_fn");

        // Csharp heuristics type rest
        let c_class = detect_csharp_java("class Worker", 1).unwrap();
        assert_eq!(c_class.name, "Worker");
        let c_struct = detect_csharp_java("struct Data", 2).unwrap();
        assert_eq!(c_struct.name, "Data");
        let c_enum = detect_csharp_java("enum Color", 3).unwrap();
        assert_eq!(c_enum.name, "Color");
        let cs_record = detect_csharp_java("record Value", 4).unwrap();
        assert_eq!(cs_record.name, "Value");

        // SourceFilter custom constructor
        let custom_filter = SourceFilter::with_extensions(vec!["rs", "zig"]);
        assert!(custom_filter.supports_path("src/lib.rs"));
        assert!(!custom_filter.supports_path("src/lib.py"));

        // is_test_source_path empty check
        assert!(!is_test_source_path(""));

        // detect_candidate empty/comment lines and invalid extensions
        assert!(detect_candidate("", 1, Some("rb")).is_none());
        assert!(detect_candidate("# comment", 1, Some("rb")).is_none());
        assert!(detect_candidate("def foo", 1, None).is_none());
        assert!(detect_candidate("def foo", 1, Some("unsupported")).is_none());
        assert!(detect_candidate("const helper = () => {}", 1, Some("js")).is_some());

        // identifier check
        assert_eq!(identifier("x"), Some("x"));

        // Tree-sitter C declarator fallbacks
        let mut parser = Parser::new();
        parser.set_language(&tree_sitter_c::LANGUAGE.into()).unwrap();
        let _tree = parser.parse("typedef int (*FuncPtr)(int); typedef int IntArray[10];", None).unwrap();
        let candidates = tree_sitter_candidates(
            &BlobFile { path: "demo.c".into(), contents: "typedef int (*FuncPtr)(int); typedef int IntArray[10];".into() },
            "c",
            &["typedef int (*FuncPtr)(int);", "typedef int IntArray[10];"]
        ).unwrap();
        let cand_names: Vec<_> = candidates.iter().map(|c| c.name.as_str()).collect();
        assert!(cand_names.contains(&"FuncPtr"));
        assert!(cand_names.contains(&"IntArray"));
    }
}
