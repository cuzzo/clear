use crate::model::{BlobFile, LogicalUnit, UnitKind};
use std::collections::BTreeSet;
use std::collections::HashMap;
use tree_sitter::{Language, Node, Parser};

pub const DEFAULT_CODE_EXTENSIONS: &[&str] = &[
    "rb", "zig", "py", "js", "jsx", "mjs", "cjs", "ts", "tsx", "lua", "c", "h", "cc", "cpp",
    "cxx", "hh", "hpp", "hxx", "cs", "java", "swift", "kt", "kts", "go", "rs", "S",
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
        let mut candidates = ext
            .as_deref()
            .and_then(|extension| tree_sitter_candidates(file, extension, &lines));

        if candidates.as_ref().map(Vec::is_empty).unwrap_or(true) {
            let mut detected = Vec::new();
            for (index, line) in lines.iter().enumerate() {
                if let Some(candidate) = detect_candidate(line, (index + 1) as u32, ext.as_deref()) {
                    detected.push(candidate);
                }
            }
            candidates = Some(detected);
        }

        let candidates = candidates.unwrap_or_default();
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
        Some("zig") => detect_rust_or_zig(trimmed, line_number),
        Some("S") => detect_assembly(trimmed, line_number),
        _ => None,
    }
}

#[derive(Debug, Clone, Copy)]
enum TreeSitterAdapter {
    Rust,
    Zig,
}

impl TreeSitterAdapter {
    fn for_extension(extension: &str) -> Option<Self> {
        match extension {
            "rs" => Some(Self::Rust),
            "zig" => Some(Self::Zig),
            _ => None,
        }
    }

    fn language(self) -> Language {
        match self {
            Self::Rust => tree_sitter_rust::LANGUAGE.into(),
            Self::Zig => tree_sitter_zig::LANGUAGE.into(),
        }
    }

    fn candidate_for_node(
        self,
        node: Node<'_>,
        source: &str,
        lines: &[&str],
    ) -> Option<Candidate> {
        match self {
            Self::Rust => rust_candidate_for_node(node, source, lines),
            Self::Zig => zig_candidate_for_node(node, source, lines),
        }
    }
}

fn tree_sitter_candidates(
    file: &BlobFile,
    extension: &str,
    lines: &[&str],
) -> Option<Vec<Candidate>> {
    let adapter = TreeSitterAdapter::for_extension(extension)?;
    let mut parser = Parser::new();
    parser.set_language(&adapter.language()).ok()?;
    let tree = parser.parse(&file.contents, None)?;
    if tree.root_node().has_error() {
        return None;
    }

    let mut candidates = Vec::new();
    collect_tree_sitter_candidates(tree.root_node(), adapter, &file.contents, lines, &mut candidates);
    Some(candidates)
}

fn collect_tree_sitter_candidates(
    node: Node<'_>,
    adapter: TreeSitterAdapter,
    source: &str,
    lines: &[&str],
    candidates: &mut Vec<Candidate>,
) {
    if let Some(candidate) = adapter.candidate_for_node(node, source, lines) {
        candidates.push(candidate);
    }

    for index in 0..node.named_child_count() {
        if let Some(child) = node.named_child(index) {
            collect_tree_sitter_candidates(child, adapter, source, lines, candidates);
        }
    }
}

fn rust_candidate_for_node(node: Node<'_>, source: &str, lines: &[&str]) -> Option<Candidate> {
    let kind = node.kind();
    match kind {
        "function_item" => {
            let name = field_text(node, "name", source)?;
            let name = rust_method_owner(node, source)
                .map(|owner| format!("{owner}.{name}"))
                .unwrap_or_else(|| name.to_string());
            Some(tree_sitter_candidate(
                node,
                name,
                UnitKind::Function,
                source,
                lines,
            ))
        }
        "mod_item" => tree_sitter_named_candidate(node, UnitKind::Module, source, lines),
        "struct_item" | "enum_item" | "trait_item" | "union_item" | "type_item" => {
            tree_sitter_named_candidate(node, UnitKind::Class, source, lines)
        }
        _ => None,
    }
}

fn zig_candidate_for_node(node: Node<'_>, source: &str, lines: &[&str]) -> Option<Candidate> {
    match node.kind() {
        "function_declaration" => {
            let name = field_text(node, "name", source)?;
            let name = zig_container_owner(node, source)
                .map(|owner| format!("{owner}.{name}"))
                .unwrap_or_else(|| name.to_string());
            Some(tree_sitter_candidate(
                node,
                name,
                UnitKind::Function,
                source,
                lines,
            ))
        }
        "variable_declaration" => zig_container_declaration_candidate(node, source, lines),
        _ => None,
    }
}

fn tree_sitter_named_candidate(
    node: Node<'_>,
    kind: UnitKind,
    source: &str,
    lines: &[&str],
) -> Option<Candidate> {
    let name = field_text(node, "name", source)?;
    Some(tree_sitter_candidate(node, name.to_string(), kind, source, lines))
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
        assert_eq!(units[1].name, "run");
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
        assert_eq!(extractor.extract_units(&go)[0].name, "Run");
        assert_eq!(extractor.extract_units(&zig)[0].name, "run");
    }

    #[test]
    fn extracts_typescript_symbols_with_heuristics() {
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

        assert!(names.contains(&"self.build!"));
        assert!(names.contains(&"value="));
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
}
