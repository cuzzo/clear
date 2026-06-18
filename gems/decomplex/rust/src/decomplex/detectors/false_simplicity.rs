use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct FalseSimplicityRow {
    pub kind: String,
    pub detail: String,
    pub support: usize,
    pub scatter: usize,
    pub at: String,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Site {
    kind: String,
    detail: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<FalseSimplicityRow>> {
    let mut sites = Vec::new();
    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let mut detector = FalseSimplicity::new(file.to_string_lossy().to_string(), lines);
        detector.walk(&root, &Vec::new());
        sites.extend(detector.sites);
    }
    Ok(Report::new(sites).findings())
}

const DISPATCH_MIDS: &[&str] = &["send", "public_send", "method", "public_method", "__send__"];
const IO_MIDS: &[&str] = &[
    "puts", "print", "p", "open", "read", "write", "sysread", "syswrite",
    "recv", "send", "gets", "read_nonblock", "write_nonblock",
];
const REFLECTION_MIDS: &[&str] = &[
    "instance_eval", "class_eval", "module_eval",
    "instance_exec", "class_exec", "module_exec",
    "define_method", "define_singleton_method",
    "const_get", "const_set", "const_missing",
    "method_missing", "respond_to_missing?",
];

struct FalseSimplicity {
    file: String,
    lines: Vec<String>,
    sites: Vec<Site>,
}

impl FalseSimplicity {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self { file, lines, sites: Vec::new() }
    }

    fn walk(&mut self, node: &Node, defstack: &[String]) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        self.inspect_node(node, &next_defstack);

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn inspect_node(&mut self, node: &Node, defstack: &[String]) {
        match node.r#type.as_str() {
            "CALL" | "OPCALL" | "FCALL" | "VCALL" => {
                let mid = self.call_mid(node);
                if let Some(mid) = mid {
                    if DISPATCH_MIDS.contains(&mid.as_str()) {
                        self.add_site("dynamic_dispatch", &mid, node, defstack);
                    } else if IO_MIDS.contains(&mid.as_str()) && !self.receiver_is_explicit(node) {
                        self.add_site("hidden_io", &mid, node, defstack);
                    } else if REFLECTION_MIDS.contains(&mid.as_str()) {
                        self.add_site("runtime_reflection", &mid, node, defstack);
                    }
                }
            }
            "ATTRASGN" => {
                let mid = self.call_mid(node).unwrap_or_default();
                if mid.ends_with("eval=") {
                    self.add_site("runtime_reflection", &mid, node, defstack);
                }
            }
            "SUPER" | "ZSUPER" => {
                self.add_site("context_dependency", "super", node, defstack);
            }
            "GVAR" | "GASGN" => {
                if let Some(name) = ast::child_to_string(node.children.get(0)) {
                    if !name.starts_with("$PREMATCH") && !name.starts_with("$POSTMATCH") && !name.starts_with("$MATCH") && !name.starts_with("$&") && !name.starts_with("$'") && !name.starts_with("$`") {
                        self.add_site("context_dependency", &name, node, defstack);
                    }
                }
            }
            "CVAR" | "CVDASGN" | "CVDECL" => {
                self.add_site("hidden_mutation", "class_var", node, defstack);
            }
            "CLASS" | "MODULE" => {
                if !defstack.is_empty() {
                    self.add_site("monkeypatch", "nested_reopen", node, defstack);
                }
            }
            "ALIAS" => {
                self.add_site("runtime_reflection", "alias", node, defstack);
            }
            "UNDEF" => {
                self.add_site("runtime_reflection", "undef", node, defstack);
            }
            _ => {}
        }
    }

    fn call_mid(&self, node: &Node) -> Option<String> {
        match node.r#type.as_str() {
            "CALL" | "OPCALL" | "ATTRASGN" => ast::child_to_string(node.children.get(1)),
            "FCALL" | "VCALL" => ast::child_to_string(node.children.get(0)),
            _ => None,
        }
    }

    fn receiver_is_explicit(&self, node: &Node) -> bool {
        if matches!(node.r#type.as_str(), "FCALL" | "VCALL") { return false; }
        if let Some(recv) = node.children.get(0).and_then(ast::node) {
            recv.r#type != "SELF"
        } else {
            false
        }
    }

    fn add_site(&mut self, kind: &str, detail: &str, node: &Node, defstack: &[String]) {
        self.sites.push(Site {
            kind: kind.to_string(),
            detail: detail.to_string(),
            file: self.file.clone(),
            defn: defstack.last().cloned().unwrap_or_else(|| "(top-level)".to_string()),
            line: node.first_lineno,
            span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
        });
    }
}

struct Report {
    sites: Vec<Site>,
}

impl Report {
    fn new(sites: Vec<Site>) -> Self { Self { sites } }

    fn findings(&self) -> Vec<FalseSimplicityRow> {
        let mut groups: BTreeMap<(String, String), Vec<&Site>> = BTreeMap::new();
        for s in &self.sites {
            groups.entry((s.kind.clone(), s.detail.clone())).or_default().push(s);
        }

        let mut out = Vec::new();
        for ((kind, detail), sts) in groups {
            let mut defns = BTreeSet::new();
            for s in &sts { defns.insert((s.file.clone(), s.defn.clone())); }
            let scatter = defns.len();

            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for s in &sts {
                let loc = format!("{}:{}:{}", s.file, s.defn, s.line);
                sites.push(loc.clone());
                spans.insert(loc, s.span);
            }

            out.push(FalseSimplicityRow {
                kind,
                detail,
                support: sts.len(),
                scatter,
                at: sites.first().cloned().unwrap_or_default(),
                sites,
                spans,
            });
        }
        out.sort_by(|a, b| {
            b.scatter.cmp(&a.scatter)
                .then_with(|| b.support.cmp(&a.support))
                .then_with(|| a.kind.cmp(&b.kind))
                .then_with(|| a.detail.cmp(&b.detail))
        });
        out
    }
}
