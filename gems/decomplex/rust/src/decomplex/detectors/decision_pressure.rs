use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

const GUARD_MIDS: &[&str] = &["is_a?", "kind_of?", "instance_of?", "nil?", "respond_to?"];
const TRANSIENT_NOARG_MIDS: &[&str] = &["pop", "shift"];

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct DecisionPressureRow {
    pub contract: String,
    pub decisions: usize,
    pub essential: usize,
    pub methods: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug)]
struct Hit {
    contract: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct Scanner {
    file: String,
    lines: Vec<String>,
    guard_hits: Vec<Hit>,
    dispatch_hits: Vec<Hit>,
}

type AssignmentMap = Vec<(String, Node)>;

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<Vec<DecisionPressureRow>> {
    let mut guard = Vec::new();
    let mut dispatch = Vec::new();

    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut scanner = Scanner::new(file.to_string_lossy().to_string(), lines);
        scanner.walk(&root, &[], &Vec::new());
        guard.extend(scanner.guard_hits);
        dispatch.extend(scanner.dispatch_hits);
    }

    Ok(ranked(&guard, &dispatch))
}

impl Scanner {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            guard_hits: Vec::new(),
            dispatch_hits: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String], asgmap: &AssignmentMap) {
        let mut next_defstack = defstack.to_vec();
        let mut next_asgmap = asgmap.clone();

        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(name) = child_to_string(node.children.get(name_index)) {
                next_defstack.push(name);
            }
            next_asgmap = self.build_asgmap(node);
        }

        self.record_decision(node, &next_defstack, &next_asgmap);
        self.record_rescue_nil(node, &next_defstack, &next_asgmap);
        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack, &next_asgmap);
        }
    }

    fn build_asgmap(&self, defn_node: &Node) -> AssignmentMap {
        let mut map = Vec::new();
        let mut stack = ast::body_stmts(defn_node);

        while let Some(node) = stack.pop() {
            if node.r#type == "LASGN" {
                let name = child_to_string(node.children.first());
                let source = node.children.get(1).and_then(ast::node);
                if let (Some(name), Some(source)) = (name, source) {
                    if !map.iter().any(|(existing, _)| existing == &name)
                        && self.simple_source(source)
                    {
                        map.push((name, source.clone()));
                    }
                }
            }
            for child in node.children.iter().filter_map(ast::node) {
                stack.push(child);
            }
        }

        map
    }

    fn simple_source(&self, node: &Node) -> bool {
        match node.r#type.as_str() {
            "IVAR" => true,
            "CALL" | "QCALL" => {
                let receiver = node.children.first().and_then(ast::node);
                let method = child_to_string(node.children.get(1));
                let args_nil = child_nil(node.children.get(2));
                receiver.is_some()
                    && (args_nil || method.as_deref() == Some("[]"))
            }
            _ => false,
        }
    }

    fn record_decision(
        &mut self,
        node: &Node,
        defstack: &[String],
        asgmap: &AssignmentMap,
    ) {
        if !matches!(node.r#type.as_str(), "CALL" | "QCALL") {
            return;
        }

        let Some(receiver) = node.children.first().and_then(ast::node) else {
            return;
        };
        let Some(method) = child_to_string(node.children.get(1)) else {
            return;
        };

        let guard = (node.r#type == "CALL" && GUARD_MIDS.contains(&method.as_str()))
            || node.r#type == "QCALL";
        if guard {
            if let Some(contract) = self.contract_of(receiver, asgmap, 0) {
                self.guard_hits.push(self.hit(contract, defstack, node));
            }
            return;
        }

        if node.r#type == "CALL" && method.ends_with('?') {
            if let Some(contract) = self.contract_of(receiver, asgmap, 0) {
                self.dispatch_hits.push(self.hit(contract, defstack, node));
            }
        }
    }

    fn record_rescue_nil(
        &mut self,
        node: &Node,
        defstack: &[String],
        asgmap: &AssignmentMap,
    ) {
        if node.r#type != "RESCUE" {
            return;
        }

        let Some(body) = node.children.first().and_then(ast::node) else {
            return;
        };
        let Some(resbody) = node.children.get(1).and_then(ast::node) else {
            return;
        };
        if resbody.r#type != "RESBODY" || !child_nil(resbody.children.first()) {
            return;
        }

        let handler = resbody.children.get(1);
        let nil_handler = child_nil(handler)
            || handler
                .and_then(ast::node)
                .map(|node| node.r#type == "NIL")
                .unwrap_or(false);
        if !nil_handler || !matches!(body.r#type.as_str(), "CALL" | "QCALL") {
            return;
        }

        if let Some(contract) = self.contract_of(body, asgmap, 0) {
            self.guard_hits.push(self.hit(contract, defstack, node));
        }
    }

    fn hit(&self, contract: String, defstack: &[String], node: &Node) -> Hit {
        Hit {
            contract,
            file: self.file.clone(),
            defn: defstack
                .last()
                .cloned()
                .unwrap_or_else(|| "(top-level)".to_string()),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
        }
    }

    fn contract_of(
        &self,
        node: &Node,
        asgmap: &AssignmentMap,
        depth: usize,
    ) -> Option<String> {
        if depth >= 8 {
            return None;
        }

        match node.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name = child_to_string(node.children.first())?;
                if let Some((_, source)) = asgmap
                    .iter()
                    .find(|(candidate, _)| candidate == &name)
                {
                    self.contract_of(source, asgmap, depth + 1)
                } else {
                    Some("~local".to_string())
                }
            }
            "IVAR" => child_to_string(node.children.first()),
            "CALL" | "QCALL" => {
                let receiver = node.children.first().and_then(ast::node);
                let method = child_to_string(node.children.get(1))?;
                let args = node.children.get(2).and_then(ast::node);

                if method == "[]" {
                    let key = args.and_then(|args| first_non_nil_child(&args.children));
                    let text = key
                        .map(|child| child_slice(child, &self.lines))
                        .unwrap_or_else(|| "nil".to_string());
                    Some(format!("[{text}]"))
                } else if args.is_none()
                    && receiver.is_some()
                    && !TRANSIENT_NOARG_MIDS.contains(&method.as_str())
                {
                    Some(format!(".{method}"))
                } else {
                    None
                }
            }
            "VCALL" => child_to_string(node.children.first()).map(|name| format!(".{name}")),
            _ => None,
        }
    }
}

fn ranked(guard_hits: &[Hit], dispatch_hits: &[Hit]) -> Vec<DecisionPressureRow> {
    let mut essential = Vec::<(String, usize)>::new();
    for hit in dispatch_hits {
        if let Some((_, count)) = essential
            .iter_mut()
            .find(|(contract, _)| contract == &hit.contract)
        {
            *count += 1;
        } else {
            essential.push((hit.contract.clone(), 1));
        }
    }

    let mut groups = Vec::<(String, Vec<&Hit>)>::new();
    for hit in guard_hits {
        if let Some((_, hits)) = groups
            .iter_mut()
            .find(|(contract, _)| contract == &hit.contract)
        {
            hits.push(hit);
        } else {
            groups.push((hit.contract.clone(), vec![hit]));
        }
    }

    let rows = groups
        .into_iter()
        .map(|(contract, hits)| {
            let methods = hits
                .iter()
                .map(|hit| (hit.file.clone(), hit.defn.clone()))
                .collect::<BTreeSet<_>>()
                .len();
            let sites = hits.iter().map(|hit| loc(hit)).collect::<Vec<_>>();
            let spans = hits
                .iter()
                .map(|hit| (loc(hit), hit.span))
                .collect::<BTreeMap<_, _>>();
            let essential_count = essential
                .iter()
                .find(|(candidate, _)| candidate == &contract)
                .map(|(_, count)| *count)
                .unwrap_or(0);
            DecisionPressureRow {
                contract,
                decisions: hits.len(),
                essential: essential_count,
                methods,
                sites,
                spans,
            }
        })
        .collect::<Vec<_>>();

    let mut named = rows
        .iter()
        .filter(|row| row.contract != "~local")
        .cloned()
        .collect::<Vec<_>>();
    named.sort_by(|left, right| {
        right
            .decisions
            .cmp(&left.decisions)
            .then(right.methods.cmp(&left.methods))
    });
    let local = rows
        .into_iter()
        .filter(|row| row.contract == "~local")
        .collect::<Vec<_>>();
    named.into_iter().chain(local).collect()
}

fn child_to_string(child: Option<&Child>) -> Option<String> {
    match child {
        Some(Child::String(value)) | Some(Child::Symbol(value)) => Some(value.clone()),
        _ => None,
    }
}

fn child_nil(child: Option<&Child>) -> bool {
    matches!(child, None | Some(Child::Nil))
}

fn first_non_nil_child(children: &[Child]) -> Option<&Child> {
    children.iter().find(|child| !matches!(child, Child::Nil))
}

fn child_slice(child: &Child, lines: &[String]) -> String {
    match child {
        Child::Node(node) => ast::slice(node, lines),
        Child::Symbol(value) => value.clone(),
        Child::String(value) => format!("{value:?}"),
        Child::Nil => "nil".to_string(),
    }
}

fn loc(hit: &Hit) -> String {
    format!("{}:{}:{}", hit.file, hit.defn, hit.line)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(node_type: &str, children: Vec<Child>) -> Node {
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno: 1,
            first_column: 0,
            last_lineno: 1,
            last_column: 1,
            text: String::new(),
        }
    }

    #[test]
    fn resolves_local_to_accessor_contract() {
        let source = node(
            "CALL",
            vec![
                Child::Node(Box::new(node("LVAR", vec![Child::String("node".to_string())]))),
                Child::Symbol("full_type".to_string()),
                Child::Nil,
            ],
        );
        let scanner = Scanner::new("test.rb".to_string(), Vec::new());
        let local = node("LVAR", vec![Child::String("ti".to_string())]);
        assert_eq!(
            scanner.contract_of(&local, &vec![("ti".to_string(), source)], 0),
            Some(".full_type".to_string())
        );
    }

    #[test]
    fn resolved_transient_local_does_not_fall_back_to_local_contract() {
        let source = node(
            "CALL",
            vec![
                Child::Node(Box::new(node(
                    "LVAR",
                    vec![Child::String("stack".to_string())],
                ))),
                Child::Symbol("pop".to_string()),
                Child::Nil,
            ],
        );
        let scanner = Scanner::new("test.rb".to_string(), Vec::new());
        let local = node("LVAR", vec![Child::String("node".to_string())]);

        assert_eq!(
            scanner.contract_of(&local, &vec![("node".to_string(), source)], 0),
            None
        );
    }

    #[test]
    fn hash_key_contract_uses_key_text() {
        let element = node(
            "CALL",
            vec![
                Child::Node(Box::new(node("LVAR", vec![Child::String("p".to_string())]))),
                Child::Symbol("[]".to_string()),
                Child::Node(Box::new(node(
                    "LIST",
                    vec![Child::Node(Box::new(Node {
                        r#type: "LIT".to_string(),
                        children: vec![Child::Symbol("type".to_string())],
                        first_lineno: 1,
                        first_column: 2,
                        last_lineno: 1,
                        last_column: 7,
                        text: ":type".to_string(),
                    }))],
                ))),
            ],
        );
        let scanner = Scanner::new("test.rb".to_string(), Vec::new());
        assert_eq!(scanner.contract_of(&element, &Vec::new(), 0), Some("[:type]".to_string()));
    }

    #[test]
    fn scan_records_safe_navigation_pressure() {
        let mut file = tempfile::NamedTempFile::new().expect("temp");
        std::io::Write::write_all(
            &mut file,
            b"def scan\n  file&.unlink\nend\n",
        )
        .expect("write");

        let rows = scan_files(&[file.path().to_path_buf()], Language::Ruby).expect("scan");

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].contract, ".file");
        assert_eq!(rows[0].decisions, 1);
    }

    #[test]
    fn scan_records_safe_navigation_pressure_inside_ensure() {
        let mut file = tempfile::NamedTempFile::new().expect("temp");
        std::io::Write::write_all(
            &mut file,
            b"class CoUpdateTest < Minitest::Test\n  def scan(ruby)\n    f = Tempfile.new([\"cu\", \".rb\"])\n    f.write(ruby)\n  ensure\n    f&.unlink\n  end\nend\n",
        )
        .expect("write");

        let rows = scan_files(&[file.path().to_path_buf()], Language::Ruby).expect("scan");

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].contract, "~local");
        assert_eq!(rows[0].decisions, 1);
    }

    #[test]
    fn scan_counts_block_predicate_on_assigned_local_as_essential_context() {
        let mut file = tempfile::NamedTempFile::new().expect("temp");
        std::io::Write::write_all(
            &mut file,
            b"def t\n  pairs = []\n  refute(pairs.any? { |h| h[:pair].include?(\"[]\") })\n  pairs.nil?\nend\n",
        )
        .expect("write");

        let rows = scan_files(&[file.path().to_path_buf()], Language::Ruby).expect("scan");

        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].contract, "~local");
        assert_eq!(rows[0].decisions, 1);
        assert_eq!(rows[0].essential, 1);
    }

    #[test]
    fn scan_records_safe_navigation_pressure_in_ternary_arm() {
        let mut file = tempfile::NamedTempFile::new().expect("temp");
        std::io::Write::write_all(
            &mut file,
            b"def x(node)\n  decl = node.respond_to?(:symbol) ? node.symbol&.reg : nil\nend\n",
        )
        .expect("write");

        let rows = scan_files(&[file.path().to_path_buf()], Language::Ruby).expect("scan");

        assert_eq!(rows.iter().find(|row| row.contract == ".symbol").map(|row| row.decisions), Some(1));
        assert_eq!(rows.iter().find(|row| row.contract == "~local").map(|row| row.decisions), Some(1));
    }

}
