use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::adapters::false_simplicity_lexicon::{
    false_simplicity_lexicon, FalseSimplicityLexicon,
};
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
struct Hit {
    kind: String,
    detail: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct ClassRec {
    name: String,
    file: String,
    line: usize,
    core: bool,
    span: Span,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<FalseSimplicityRow>> {
    let mut hits = Vec::new();
    let mut classrecs = Vec::new();
    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let mut detector =
            FalseSimplicity::new(file.to_string_lossy().to_string(), lines, language);
        detector.walk(&root, &[], &[]);
        hits.extend(detector.hits);
        classrecs.extend(detector.classrecs);
    }
    Ok(Report::new(hits, classrecs).findings())
}

struct FalseSimplicity {
    file: String,
    lines: Vec<String>,
    language: Language,
    lexicon: FalseSimplicityLexicon,
    hits: Vec<Hit>,
    classrecs: Vec<ClassRec>,
}

impl FalseSimplicity {
    fn new(file: String, lines: Vec<String>, language: Language) -> Self {
        Self {
            file,
            lines,
            language,
            lexicon: false_simplicity_lexicon(language),
            hits: Vec::new(),
            classrecs: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defs: &[String], cls: &[String]) {
        match node.r#type.as_str() {
            "CLASS" | "MODULE" => {
                self.walk_class(node, defs, cls);
                return;
            }
            "SCLASS" => {
                if self.language == Language::Ruby {
                    if let Some(recv) = node.children.first().and_then(ast::node) {
                        if recv.r#type != "SELF" {
                            self.emit(
                                "metaprogramming",
                                &format!("class << {}", ast::slice(recv, &self.lines)),
                                self.defn_name(defs),
                                node,
                            );
                        }
                    }
                }
            }
            "DEFN" | "DEFS" => {
                let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
                let name = ast::child_to_string(node.children.get(name_index));
                if self.language == Language::Ruby {
                    if let Some(name) = name.as_deref() {
                        if matches!(name, "method_missing" | "respond_to_missing?") {
                            self.emit(
                                "metaprogramming",
                                &format!("def {name}"),
                                self.defn_name(defs),
                                node,
                            );
                        }
                    }
                }
                let mut next_defs = defs.to_vec();
                if let Some(name) = name {
                    next_defs.push(name);
                }
                for child in node.children.iter().filter_map(ast::node) {
                    self.walk(child, &next_defs, cls);
                }
                return;
            }
            "CALL" | "FCALL" | "VCALL" | "OPCALL" => self.classify_call(node, defs),
            "ATTRASGN" => {
                if let Some(mid) = ast::child_to_string(node.children.get(1)) {
                    self.emit("hidden_mutation", &mid, self.defn_name(defs), node);
                }
            }
            "OP_ASGN1" | "OP_ASGN2" => {
                self.emit("hidden_mutation", "op-assign", self.defn_name(defs), node);
            }
            "GVAR" | "GASGN" => {
                if self.language == Language::Ruby {
                    if let Some(name) = ast::child_to_string(node.children.first()) {
                        self.emit("context_dependency", &name, self.defn_name(defs), node);
                    }
                }
            }
            "XSTR" | "DXSTR" => {
                if self.language == Language::Ruby {
                    self.emit("hidden_io", "backtick", self.defn_name(defs), node);
                }
            }
            "YIELD" => {
                if self.language == Language::Ruby {
                    self.emit("dynamic_dispatch", "yield", self.defn_name(defs), node);
                }
            }
            "ITER" => {
                if let Some(call) = node.children.first().and_then(ast::node) {
                    if let Some(mid) = self.callee_mid(call) {
                        if self.callback(&mid) && !self.lexicon.meta_mids.contains(&mid.as_str()) {
                            self.emit("callback_inversion", &mid, self.defn_name(defs), node);
                        }
                    }
                }
            }
            _ => {}
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, defs, cls);
        }
    }

    fn walk_class(&mut self, node: &Node, defs: &[String], cls: &[String]) {
        let Some(cpath) = node.children.first().and_then(ast::node) else {
            return;
        };
        let body = if node.r#type == "CLASS" {
            node.children.get(2).and_then(ast::node)
        } else {
            node.children.get(1).and_then(ast::node)
        };
        let simple = self.const_simple(cpath);
        let based = cpath.r#type == "COLON2"
            && !matches!(cpath.children.first(), None | Some(Child::Nil))
            && !cpath.text.starts_with("::");
        let mut name_parts = cls.to_vec();
        name_parts.push(self.const_text(cpath));
        let fqn = name_parts.join("::");
        if body.is_some_and(|body| self.has_def(body)) {
            let core =
                cls.is_empty() && !based && self.lexicon.core_consts.contains(&simple.as_str());
            self.classrecs.push(ClassRec {
                name: fqn.clone(),
                file: self.file.clone(),
                line: node.first_lineno,
                core,
                span: self.span(node),
            });
            if core {
                self.emit("monkeypatch", &simple, &simple, node);
            }
        }
        let mut next_cls = cls.to_vec();
        next_cls.push(self.const_text(cpath));
        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, defs, &next_cls);
        }
    }

    fn classify_call(&mut self, call: &Node, defs: &[String]) {
        let (recv, mid) = match call.r#type.as_str() {
            "CALL" | "OPCALL" => (
                call.children.first().and_then(ast::node),
                ast::child_to_string(call.children.get(1)),
            ),
            _ => (None, ast::child_to_string(call.children.first())),
        };
        let Some(mid) = mid else {
            return;
        };

        if self.block_pass(call)
            && self.callback(&mid)
            && !self.lexicon.meta_mids.contains(&mid.as_str())
        {
            self.emit("callback_inversion", &mid, self.defn_name(defs), call);
            return;
        }
        if self.lexicon.meta_mids.contains(&mid.as_str()) {
            self.emit("metaprogramming", &mid, self.defn_name(defs), call);
            return;
        }
        if self.lexicon.dispatch_mids.contains(&mid.as_str()) {
            self.emit("dynamic_dispatch", &mid, self.defn_name(defs), call);
            return;
        }

        if mid == "call" {
            if let Some(recv) = recv {
                if self.method_obj(recv) {
                    self.emit(
                        "dynamic_dispatch",
                        "method(...).call",
                        self.defn_name(defs),
                        call,
                    );
                    return;
                }
                if self.var_recv(recv) {
                    self.emit(
                        "dynamic_dispatch",
                        &format!("{}.call", ast::slice(recv, &self.lines)),
                        self.defn_name(defs),
                        call,
                    );
                    return;
                }
            }
        }

        if let Some(cp) = recv.and_then(|recv| self.const_recv(recv)) {
            let base = cp
                .trim_start_matches("::")
                .split("::")
                .next()
                .unwrap_or("")
                .to_string();
            if base == "Dir" && self.lexicon.dir_context.contains(&mid.as_str()) {
                self.emit(
                    "context_dependency",
                    &format!("Dir.{mid}"),
                    self.defn_name(defs),
                    call,
                );
                return;
            }
            if self.lexicon.io_consts.contains(&base.as_str())
                || (self.language == Language::Ruby && cp.starts_with("Net::"))
            {
                self.emit(
                    "hidden_io",
                    &format!("{cp}.{mid}"),
                    self.defn_name(defs),
                    call,
                );
                return;
            }
            if self.language == Language::Ruby {
                if base == "URI" && mid == "open" {
                    self.emit("hidden_io", "URI.open", self.defn_name(defs), call);
                    return;
                }
                if cp == "ENV" {
                    self.emit("context_dependency", "ENV", self.defn_name(defs), call);
                    return;
                }
            }
            if self.context_pair(&base, &mid) {
                self.emit(
                    "context_dependency",
                    &format!("{base}.{mid}"),
                    self.defn_name(defs),
                    call,
                );
                return;
            }
        }

        if recv.is_none() {
            if self.lexicon.io_bare.contains(&mid.as_str()) {
                self.emit("hidden_io", &mid, self.defn_name(defs), call);
                return;
            }
            if self.lexicon.context_bare.contains(&mid.as_str()) {
                self.emit("context_dependency", &mid, self.defn_name(defs), call);
                return;
            }
        }

        if mid.len() > 1 && mid.ends_with('!') && !matches!(mid.as_str(), "!=" | "!~") {
            self.emit("hidden_mutation", &mid, self.defn_name(defs), call);
            return;
        }
        if call.r#type == "OPCALL" && mid == "<<" {
            self.emit("hidden_mutation", "<<", self.defn_name(defs), call);
        }
    }

    fn emit(&mut self, kind: &str, detail: &str, defn: &str, node: &Node) {
        self.hits.push(Hit {
            kind: kind.to_string(),
            detail: detail.to_string(),
            file: self.file.clone(),
            defn: defn.to_string(),
            line: node.first_lineno,
            span: self.span(node),
        });
    }

    fn defn_name<'a>(&self, defs: &'a [String]) -> &'a str {
        defs.last().map(String::as_str).unwrap_or("(top-level)")
    }

    fn span(&self, node: &Node) -> Span {
        [
            node.first_lineno,
            node.first_column,
            node.last_lineno,
            node.last_column,
        ]
    }

    fn callback(&self, mid: &str) -> bool {
        self.lexicon.callback_set.contains(&mid)
            || ["with_", "around_", "on_", "before_", "after_"]
                .iter()
                .any(|prefix| mid.starts_with(prefix))
            || mid.ends_with("_hook")
    }

    fn callee_mid(&self, call: &Node) -> Option<String> {
        match call.r#type.as_str() {
            "CALL" | "OPCALL" => ast::child_to_string(call.children.get(1)),
            "FCALL" | "VCALL" => ast::child_to_string(call.children.first()),
            _ => None,
        }
    }

    fn block_pass(&self, call: &Node) -> bool {
        let args = match call.r#type.as_str() {
            "CALL" | "OPCALL" => call.children.get(2),
            "FCALL" => call.children.get(1),
            _ => None,
        };
        let Some(args) = args.and_then(ast::node) else {
            return false;
        };
        args.r#type == "BLOCK_PASS"
            || (args.r#type == "LIST"
                && args
                    .children
                    .iter()
                    .filter_map(ast::node)
                    .any(|child| child.r#type == "BLOCK_PASS"))
    }

    fn method_obj(&self, recv: &Node) -> bool {
        let mid = match recv.r#type.as_str() {
            "CALL" => ast::child_to_string(recv.children.get(1)),
            "FCALL" => ast::child_to_string(recv.children.first()),
            _ => None,
        };
        mid.is_some_and(|mid| self.lexicon.method_obj_mids.contains(&mid.as_str()))
    }

    fn var_recv(&self, recv: &Node) -> bool {
        matches!(
            recv.r#type.as_str(),
            "VCALL" | "LVAR" | "DVAR" | "IVAR" | "CVAR" | "GVAR"
        )
    }

    fn const_recv(&self, recv: &Node) -> Option<String> {
        if matches!(recv.r#type.as_str(), "CONST" | "COLON2" | "COLON3") {
            Some(self.const_text(recv))
        } else {
            None
        }
    }

    fn const_text(&self, node: &Node) -> String {
        match node.r#type.as_str() {
            "CONST" => ast::child_to_string(node.children.first()).unwrap_or_default(),
            "COLON3" => format!(
                "::{}",
                ast::child_to_string(node.children.first()).unwrap_or_default()
            ),
            "COLON2" => {
                let name = ast::child_to_string(node.children.get(1)).unwrap_or_default();
                if node.text.starts_with("::") {
                    format!("::{name}")
                } else if let Some(base) = node.children.first().and_then(ast::node) {
                    format!("{}::{name}", self.const_text(base))
                } else {
                    name
                }
            }
            _ => ast::slice(node, &self.lines),
        }
    }

    fn const_simple(&self, node: &Node) -> String {
        match node.r#type.as_str() {
            "CONST" | "COLON3" => ast::child_to_string(node.children.first()).unwrap_or_default(),
            "COLON2" => ast::child_to_string(node.children.get(1)).unwrap_or_default(),
            _ => self.const_text(node),
        }
    }

    fn has_def(&self, node: &Node) -> bool {
        let _ = self.language;
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            return true;
        }
        if matches!(node.r#type.as_str(), "CLASS" | "MODULE") {
            return false;
        }
        node.children
            .iter()
            .filter_map(ast::node)
            .any(|child| self.has_def(child))
    }

    fn context_pair(&self, base: &str, mid: &str) -> bool {
        self.lexicon
            .context_pairs
            .iter()
            .any(|(key, mids)| *key == base && mids.contains(&mid))
    }
}

struct Report {
    hits: Vec<Hit>,
}

impl Report {
    fn new(mut hits: Vec<Hit>, classrecs: Vec<ClassRec>) -> Self {
        let mut grouped: Vec<(String, Vec<ClassRec>)> = Vec::new();
        for rec in classrecs {
            if let Some((_, recs)) = grouped.iter_mut().find(|(name, _)| name == &rec.name) {
                recs.push(rec);
            } else {
                grouped.push((rec.name.clone(), vec![rec]));
            }
        }
        for (_name, recs) in grouped {
            if recs.first().is_some_and(|rec| rec.core) {
                continue;
            }
            let file_count = recs
                .iter()
                .map(|rec| rec.file.clone())
                .collect::<BTreeSet<_>>()
                .len();
            if file_count < 2 {
                continue;
            }
            for rec in recs {
                hits.push(Hit {
                    kind: "monkeypatch".to_string(),
                    detail: format!("reopen {}", rec.name),
                    file: rec.file.clone(),
                    defn: rec.name.clone(),
                    line: rec.line,
                    span: rec.span,
                });
            }
        }
        Self { hits }
    }

    fn findings(&self) -> Vec<FalseSimplicityRow> {
        let mut groups: Vec<((String, String), Vec<&Hit>)> = Vec::new();
        for hit in &self.hits {
            let key = (hit.kind.clone(), hit.detail.clone());
            if let Some((_, hits)) = groups.iter_mut().find(|(existing, _)| existing == &key) {
                hits.push(hit);
            } else {
                groups.push((key, vec![hit]));
            }
        }

        let mut out = Vec::new();
        for ((kind, detail), hits) in groups {
            let units = hits
                .iter()
                .map(|hit| (hit.file.clone(), hit.defn.clone()))
                .collect::<BTreeSet<_>>();
            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for hit in &hits {
                let loc = format!("{}:{}:{}", hit.file, hit.defn, hit.line);
                if !sites.contains(&loc) {
                    sites.push(loc.clone());
                }
                spans.entry(loc).or_insert(hit.span);
            }
            out.push(FalseSimplicityRow {
                kind,
                detail,
                support: hits.len(),
                scatter: units.len(),
                at: sites.first().cloned().unwrap_or_default(),
                sites,
                spans,
            });
        }
        out.sort_by(|a, b| {
            b.scatter
                .cmp(&a.scatter)
                .then_with(|| b.support.cmp(&a.support))
                .then_with(|| a.kind.cmp(&b.kind))
                .then_with(|| a.detail.cmp(&b.detail))
        });
        out
    }
}
