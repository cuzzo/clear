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

pub fn scan_files(files: &[PathBuf], _language: Language) -> Result<Vec<DecisionPressureRow>> {
    let mut guard = Vec::new();
    let mut dispatch = Vec::new();

    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut detector = DecisionPressure::new(file.to_string_lossy().to_string(), lines);
        detector.walk(&root, &Vec::new(), &BTreeMap::new());
        guard.extend(detector.guard_hits);
        dispatch.extend(detector.dispatch_hits);
    }

    Ok(Report::new(guard, dispatch).ranked())
}

struct DecisionPressure {
    file: String,
    lines: Vec<String>,
    guard_hits: Vec<Hit>,
    dispatch_hits: Vec<Hit>,
}

impl DecisionPressure {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            guard_hits: Vec::new(),
            dispatch_hits: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String], asgmap: &BTreeMap<String, Node>) {
        let mut next_defstack = defstack.to_vec();
        let mut next_asgmap = asgmap.clone();

        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
            next_asgmap = self.build_asgmap(node);
        }

        self.record_decision(node, &next_defstack, &next_asgmap);
        self.record_rescue_nil(node, &next_defstack, &next_asgmap);
        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack, &next_asgmap);
        }
    }

    fn build_asgmap(&self, defn_node: &Node) -> BTreeMap<String, Node> {
        let mut map = BTreeMap::new();
        let mut stack = ast::body_stmts(defn_node);
        stack.reverse();

        while let Some(node) = stack.pop() {
            if node.r#type == "LASGN" {
                if let Some(Child::String(name)) = node.children.get(0) {
                    if let Some(src) = node.children.get(1).and_then(ast::node) {
                        if !map.contains_key(name) && self.simple_source(src) {
                            map.insert(name.clone(), src.clone());
                        }
                    }
                }
            }
            for child in node.children.iter().filter_map(ast::node).rev() {
                stack.push(child);
            }
        }
        map
    }

    fn simple_source(&self, n: &Node) -> bool {
        match n.r#type.as_str() {
            "IVAR" => true,
            "CALL" | "QCALL" => {
                let recv = n.children.get(0).and_then(ast::node);
                let mid = n.children.get(1).and_then(|c| match c { Child::Symbol(s) => Some(s), _ => None });
                let args = n.children.get(2);
                recv.is_some() && (args.is_none() || matches!(args, Some(Child::Nil)) || mid.map(|s| s.as_str()) == Some("[]"))
            }
            _ => false,
        }
    }

    fn hit(&self, contract: String, defstack: &[String], node: &Node) -> Hit {
        Hit {
            contract,
            file: self.file.clone(),
            defn: defstack.last().cloned().unwrap_or_else(|| "(top-level)".to_string()),
            line: node.first_lineno,
            span: [node.first_lineno, node.first_column, node.last_lineno, node.last_column],
        }
    }

    fn record_decision(&mut self, node: &Node, defstack: &[String], asgmap: &BTreeMap<String, Node>) {
        if !matches!(node.r#type.as_str(), "CALL" | "QCALL") {
            return;
        }

        let recv = node.children.get(0).and_then(ast::node);
        let mid = node.children.get(1).and_then(|c| match c { Child::Symbol(s) => Some(s), _ => None });
        let _args = node.children.get(2);

        let Some(recv) = recv else { return };
        let Some(mid) = mid else { return };

        let guard = (node.r#type == "CALL" && GUARD_MIDS.contains(&mid.as_str())) || node.r#type == "QCALL";
        if guard {
            if let Some(c) = self.contract_of(recv, asgmap, 0) {
                self.guard_hits.push(self.hit(c, defstack, node));
            }
            return;
        }

        if node.r#type == "CALL" && mid.ends_with('?') {
            if let Some(c) = self.contract_of(recv, asgmap, 0) {
                self.dispatch_hits.push(self.hit(c, defstack, node));
            }
        }
    }

    fn record_rescue_nil(&mut self, node: &Node, defstack: &[String], asgmap: &BTreeMap<String, Node>) {
        if node.r#type != "RESCUE" {
            return;
        }

        let body = node.children.get(0).and_then(ast::node);
        let resb = node.children.get(1).and_then(ast::node);

        let Some(resb) = resb else { return };
        if resb.r#type != "RESBODY" { return };
        if !matches!(resb.children.get(0), None | Some(Child::Nil)) { return };

        let handler = resb.children.get(1);
        let nil_handler = matches!(handler, None | Some(Child::Nil)) || handler.and_then(ast::node).map(|n| n.r#type == "NIL").unwrap_or(false);
        if !nil_handler { return };

        let Some(body) = body else { return };
        if !matches!(body.r#type.as_str(), "CALL" | "QCALL") { return };

        if let Some(c) = self.contract_of(body, asgmap, 0) {
            self.guard_hits.push(self.hit(c, defstack, node));
        }
    }

    fn contract_of(&self, n: &Node, asgmap: &BTreeMap<String, Node>, depth: usize) -> Option<String> {
        if depth >= 8 { return None; }

        match n.r#type.as_str() {
            "LVAR" | "DVAR" => {
                if let Some(Child::String(nm)) = n.children.first() {
                    if let Some(src) = asgmap.get(nm) {
                        return self.contract_of(src, asgmap, depth + 1);
                    } else {
                        return Some("~local".to_string());
                    }
                }
                None
            }
            "IVAR" => {
                if let Some(Child::String(attr)) = n.children.first() {
                    return Some(attr.clone());
                }
                None
            }
            "CALL" | "QCALL" => {
                let recv = n.children.get(0).and_then(ast::node);
                let mid = n.children.get(1).and_then(|c| match c { Child::Symbol(s) => Some(s), _ => None })?;
                let args = n.children.get(2);

                if mid == "[]" {
                    let key = if let Some(Child::Node(node)) = args {
                        node.children.iter().filter(|c| !matches!(c, Child::Nil)).next()
                    } else {
                        None
                    };
                    let kt = match key {
                        Some(Child::Node(k)) => ast::slice(k, &self.lines),
                        _ => "nil".to_string(), // Simplified key.inspect
                    };
                    Some(format!("[{}]", kt))
                } else if (args.is_none() || matches!(args, Some(Child::Nil))) && recv.is_some() && !TRANSIENT_NOARG_MIDS.contains(&mid.as_str()) {
                    Some(format!(".{}", mid))
                } else {
                    None
                }
            }
            "VCALL" => {
                if let Some(Child::Symbol(name)) = n.children.first() {
                    return Some(format!(".{}", name));
                }
                None
            }
            _ => None
        }
    }
}

struct Report {
    guard: Vec<Hit>,
    dispatch: Vec<Hit>,
}

impl Report {
    fn new(guard: Vec<Hit>, dispatch: Vec<Hit>) -> Self {
        Self { guard, dispatch }
    }

    fn ranked(&self) -> Vec<DecisionPressureRow> {
        let mut ess = BTreeMap::new();
        for h in &self.dispatch {
            *ess.entry(&h.contract).or_insert(0) += 1;
        }

        let mut rows_map: BTreeMap<String, Vec<&Hit>> = BTreeMap::new();
        for h in &self.guard {
            rows_map.entry(h.contract.clone()).or_default().push(h);
        }

        let rows: Vec<_> = rows_map.into_iter().map(|(contract, hs)| {
            let mut methods_set = BTreeSet::new();
            for h in &hs {
                methods_set.insert((&h.file, &h.defn));
            }
            let sites = hs.iter().map(|h| loc(h)).collect();
            let spans = hs.iter().map(|h| (loc(h), h.span)).collect();
            let essential = ess.get(&contract).cloned().unwrap_or(0);
            DecisionPressureRow {
                contract,
                decisions: hs.len(),
                essential,
                methods: methods_set.len(),
                sites,
                spans,
            }
        }).collect();

        let mut named: Vec<_> = rows.iter().filter(|r| r.contract != "~local").cloned().collect();
        named.sort_by(|a, b| b.decisions.cmp(&a.decisions).then_with(|| b.methods.cmp(&a.methods)));
        
        let local: Vec<_> = rows.into_iter().filter(|r| r.contract == "~local").collect();
        named.into_iter().chain(local).collect()
    }
}

fn loc(h: &Hit) -> String {
    format!("{}:{}:{}", h.file, h.defn, h.line)
}
