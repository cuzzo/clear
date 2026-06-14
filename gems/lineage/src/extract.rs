use crate::model::{BlobFile, LogicalUnit, UnitKind};
use std::collections::BTreeSet;
use std::collections::HashMap;

pub const DEFAULT_CODE_EXTENSIONS: &[&str] = &["rb", "zig", "py", "js", "lua", "c", "go", "S"];
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
}

impl BoundaryExtractor for HeuristicExtractor {
    fn supports_path(&self, path: &str) -> bool {
        self.filter.supports_path(path)
    }

    fn extract_units(&self, file: &BlobFile) -> Vec<LogicalUnit> {
        if !self.supports_path(&file.path) {
            return Vec::new();
        }

        let lines: Vec<&str> = file.contents.lines().collect();
        let mut candidates = Vec::new();
        let ext = extension(&file.path).map(|value| normalize_extension(&value));
        for (index, line) in lines.iter().enumerate() {
            if let Some(candidate) = detect_candidate(line, (index + 1) as u32, ext.as_deref()) {
                candidates.push(candidate);
            }
        }

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
                let next_line = candidates
                    .get(index + 1)
                    .map(|next| next.line.saturating_sub(1))
                    .unwrap_or(lines.len() as u32);
                let start = candidate.line.saturating_sub(1) as usize;
                let end = next_line.min(lines.len() as u32) as usize;
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
        Some("js") => detect_javascript(trimmed, line_number),
        Some("lua") => detect_lua(trimmed, line_number),
        Some("c") => detect_c(trimmed, line_number),
        Some("go") => detect_go(trimmed, line_number),
        Some("zig") => detect_rust_or_zig(trimmed, line_number),
        Some("S") => detect_assembly(trimmed, line_number),
        _ => None,
    }
}

fn detect_ruby_python(line: &str, line_number: u32) -> Option<Candidate> {
    if let Some(rest) = line.strip_prefix("def ") {
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

fn detect_javascript(line: &str, line_number: u32) -> Option<Candidate> {
    let line = line
        .strip_prefix("export default ")
        .unwrap_or(line)
        .strip_prefix("export ")
        .unwrap_or(line)
        .strip_prefix("async ")
        .unwrap_or(line);

    if let Some(rest) = line.strip_prefix("function ") {
        return named_candidate(rest, UnitKind::Function, line, line_number);
    }
    if let Some(rest) = line.strip_prefix("class ") {
        return named_candidate(rest, UnitKind::Class, line, line_number);
    }
    None
}

fn detect_lua(line: &str, line_number: u32) -> Option<Candidate> {
    let rest = line
        .strip_prefix("local function ")
        .or_else(|| line.strip_prefix("function "))?;
    named_candidate(rest, UnitKind::Function, line, line_number)
}

fn detect_c(line: &str, line_number: u32) -> Option<Candidate> {
    if line.ends_with(';') || !line.contains('(') || !line.contains(')') || !line.contains('{') {
        return None;
    }

    let before_paren = line.split_once('(')?.0.trim_end();
    let name = before_paren.split_whitespace().last()?;
    if matches!(name, "if" | "for" | "while" | "switch" | "return" | "sizeof") {
        return None;
    }

    Some(Candidate {
        name: name.trim_start_matches('*').to_string(),
        kind: UnitKind::Function,
        signature: line.trim().to_string(),
        line: line_number,
    })
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
    fn source_filter_is_a_code_whitelist() {
        let filter = SourceFilter::default();

        assert!(filter.supports_path("gems/x/lib/a.rb"));
        assert!(filter.supports_path("zig/main.zig"));
        assert!(filter.supports_path("src/vm.S"));
        assert!(filter.supports_path("src/main.c"));
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
