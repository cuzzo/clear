use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use regex::Regex;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StateBranchDensityRow {
    pub at: String,
    pub file: String,
    pub method: String,
    pub decisions: usize,
    pub state_refs: Vec<String>,
    pub predicate: String,
    pub score: usize,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Debug, Clone)]
struct Decision {
    file: String,
    defn: String,
    line: usize,
    span: Span,
    predicate: String,
    state_refs: Vec<String>,
}

const BRANCH_TYPES: &[&str] = &["IF", "UNLESS", "WHILE", "UNTIL"];
const NOISE_MIDS: &[&str] = &[
    "!", "!=", "==", "===", "<", "<=", ">", ">=", "[]", "[]=", "to_s", "inspect", "class",
];

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<Vec<StateBranchDensityRow>> {
    let mut parsed = Vec::new();
    let mut global_immutable_readers: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut global_immutable_reader_types: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    let mut global_type_aliases: BTreeMap<String, String> = BTreeMap::new();

    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        let scanner = StateBranchDensity::new(None, lines.clone(), None, None, None);
        
        for (name, readers) in scanner.immutable_struct_readers(&lines) {
            global_immutable_readers.entry(name).or_default().extend(readers);
        }
        for (name, reader_types) in scanner.immutable_struct_reader_types(&lines) {
            global_immutable_reader_types.entry(name).or_default().extend(reader_types);
        }
        global_type_aliases.extend(scanner.type_aliases(&lines));

        parsed.push((file.to_string_lossy().to_string(), root, lines));
    }

    let mut all_decisions = Vec::new();
    for (file, root, lines) in parsed {
        let mut scanner = StateBranchDensity::new(
            Some(file),
            lines,
            Some(global_immutable_readers.clone()),
            Some(global_immutable_reader_types.clone()),
            Some(global_type_aliases.clone()),
        );
        scanner.walk(&root, &Vec::new());
        all_decisions.extend(scanner.decisions);
    }

    Ok(Report::new(all_decisions).findings())
}

struct StateBranchDensity {
    file: String,
    lines: Vec<String>,
    decisions: Vec<Decision>,
    immutable_readers: BTreeMap<String, BTreeSet<String>>,
    immutable_reader_types: BTreeMap<String, BTreeMap<String, String>>,
    type_aliases: BTreeMap<String, String>,
    method_param_types: BTreeMap<String, BTreeMap<String, String>>,
}

impl StateBranchDensity {
    fn new(
        file: Option<String>,
        lines: Vec<String>,
        immutable_readers: Option<BTreeMap<String, BTreeSet<String>>>,
        immutable_reader_types: Option<BTreeMap<String, BTreeMap<String, String>>>,
        type_aliases: Option<BTreeMap<String, String>>,
    ) -> Self {
        let ir = immutable_readers.unwrap_or_else(|| BTreeMap::new()); // Simplified
        let irt = immutable_reader_types.unwrap_or_else(|| BTreeMap::new());
        let ta = type_aliases.unwrap_or_else(|| BTreeMap::new());
        
        // Re-extract if not provided (matches Ruby's initialize)
        let ir = if ir.is_empty() { 
            let s = Self { 
                file: file.clone().unwrap_or_default(), 
                lines: lines.clone(), 
                decisions: Vec::new(), 
                immutable_readers: BTreeMap::new(),
                immutable_reader_types: BTreeMap::new(),
                type_aliases: BTreeMap::new(),
                method_param_types: BTreeMap::new(),
            };
            s.immutable_struct_readers(&lines)
        } else { ir };

        let irt = if irt.is_empty() {
             let s = Self { 
                file: file.clone().unwrap_or_default(), 
                lines: lines.clone(), 
                decisions: Vec::new(), 
                immutable_readers: BTreeMap::new(),
                immutable_reader_types: BTreeMap::new(),
                type_aliases: BTreeMap::new(),
                method_param_types: BTreeMap::new(),
            };
            s.immutable_struct_reader_types(&lines)
        } else { irt };

        let ta = if ta.is_empty() {
             let s = Self { 
                file: file.clone().unwrap_or_default(), 
                lines: lines.clone(), 
                decisions: Vec::new(), 
                immutable_readers: BTreeMap::new(),
                immutable_reader_types: BTreeMap::new(),
                type_aliases: BTreeMap::new(),
                method_param_types: BTreeMap::new(),
            };
            s.type_aliases(&lines)
        } else { ta };

        let mut s = Self {
            file: file.unwrap_or_default(),
            lines: lines.clone(),
            decisions: Vec::new(),
            immutable_readers: ir,
            immutable_reader_types: irt,
            type_aliases: ta,
            method_param_types: BTreeMap::new(),
        };
        s.method_param_types = s.extract_method_param_types(&lines);
        s
    }

    fn walk(&mut self, node: &Node, defstack: &[String]) {
        let mut next_defstack = defstack.to_vec();
        if matches!(node.r#type.as_str(), "DEFN" | "DEFS") {
            let name_index = if node.r#type == "DEFS" { 1 } else { 0 };
            if let Some(Child::Symbol(name)) = node.children.get(name_index) {
                next_defstack.push(name.clone());
            }
        }

        self.record_branch(node, &next_defstack);
        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn record_branch(&mut self, node: &Node, defstack: &[String]) {
        let cond = match node.r#type.as_str() {
            t if BRANCH_TYPES.contains(&t) => node.children.first().and_then(ast::node),
            "CASE" => node.children.first().and_then(ast::node),
            _ => None,
        };
        let Some(cond) = cond else { return };

        let defn = defstack.last().map(|s| s.as_str()).unwrap_or("(top-level)");
        let refs = self.state_refs(cond, defn);
        if refs.is_empty() {
            return;
        }

        self.decisions.push(Decision {
            file: self.file.clone(),
            defn: defn.to_string(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
            predicate: ast::slice(cond, &self.lines),
            state_refs: refs.into_iter().collect::<BTreeSet<_>>().into_iter().collect(),
        });
    }

    fn state_refs(&self, node: &Node, defn: &str) -> Vec<String> {
        let mut refs = Vec::new();
        self.collect_state_refs(node, &mut refs, defn);
        refs
    }

    fn collect_state_refs(&self, node: &Node, refs: &mut Vec<String>, defn: &str) {
        match node.r#type.as_str() {
            "IVAR" | "GVAR" => {
                if let Some(Child::String(name)) = node.children.first() {
                    refs.push(name.clone());
                }
            }
            "CALL" | "QCALL" | "OPCALL" => {
                let recv = node.children.get(0).and_then(ast::node);
                let mid = node.children.get(1).and_then(|c| match c {
                    Child::Symbol(s) => Some(s),
                    _ => None,
                });
                let args = node.children.get(2);
                if let (Some(recv), Some(mid)) = (recv, mid) {
                    if self.state_attr_read(recv, mid, args, defn) {
                        refs.push(format!("{}.{}", ast::slice(recv, &self.lines), mid));
                    }
                }
            }
            _ => {}
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.collect_state_refs(child, refs, defn);
        }
    }

    fn state_attr_read(&self, recv: &Node, mid: &str, args: Option<&Child>, defn: &str) -> bool {
        if NOISE_MIDS.contains(&mid) {
            return false;
        }
        if !self.empty_arg_list(args) {
            return false;
        }
        if self.immutable_struct_const_read(recv, mid, defn) {
            return false;
        }
        true
    }

    fn immutable_struct_const_read(&self, recv: &Node, mid: &str, defn: &str) -> bool {
        let Some(owner_type) = self.immutable_receiver_type(recv, defn) else {
            return false;
        };
        self.immutable_reader(&owner_type, mid)
    }

    fn immutable_receiver_type(&self, recv: &Node, defn: &str) -> Option<String> {
        if matches!(recv.r#type.as_str(), "CALL" | "QCALL" | "OPCALL") {
            let recv_recv = recv.children.get(0).and_then(ast::node)?;
            let recv_mid = recv.children.get(1).and_then(|c| match c {
                Child::Symbol(s) => Some(s),
                _ => None,
            })?;
            let recv_args = recv.children.get(2);
            return self.immutable_reader_result_type(recv_recv, recv_mid, recv_args, defn);
        }
        if recv.r#type == "LVAR" {
            let name = match recv.children.first()? {
                Child::String(s) => s,
                _ => return None,
            };
            return self.method_param_types.get(defn)?.get(name).cloned();
        }
        None
    }

    fn immutable_reader(&self, type_name: &str, mid: &str) -> bool {
        let resolved = self.resolve_type_alias(type_name);
        let readers = self.immutable_readers.get(&resolved).or_else(|| {
            resolved.split("::").last().and_then(|last| self.immutable_readers.get(last))
        });
        readers.map(|r| r.contains(mid)).unwrap_or(false)
    }

    fn immutable_reader_result_type(&self, recv: &Node, mid: &str, args: Option<&Child>, defn: &str) -> Option<String> {
        if !self.empty_arg_list(args) {
            return None;
        }
        let owner_type = self.immutable_receiver_type(recv, defn)?;
        let resolved = self.resolve_type_alias(&owner_type);
        let reader_types = self.immutable_reader_types.get(&resolved).or_else(|| {
            resolved.split("::").last().and_then(|last| self.immutable_reader_types.get(last))
        })?;
        reader_types.get(mid).cloned()
    }

    fn empty_arg_list(&self, args: Option<&Child>) -> bool {
        match args {
            None | Some(Child::Nil) => true,
            Some(Child::Node(node)) if node.r#type == "LIST" => {
                node.children.iter().all(|c| matches!(c, Child::Nil))
            }
            _ => false,
        }
    }

    fn immutable_struct_readers(&self, lines: &[String]) -> BTreeMap<String, BTreeSet<String>> {
        let mut readers = BTreeMap::new();
        let mut class_stack = Vec::new();
        let class_struct_re = Regex::new(r"^\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b").unwrap();
        let const_re = Regex::new(r"^\s*const\s+:([A-Za-z_]\w*)\b").unwrap();
        let end_re = Regex::new(r"^\s*end\s*(?:#.*)?$").unwrap();

        for line in lines {
            if let Some(caps) = class_struct_re.captures(line) {
                class_stack.push(caps[1].to_string());
                continue;
            }
            if !class_stack.is_empty() {
                if let Some(caps) = const_re.captures(line) {
                    readers.entry(class_stack.last().unwrap().clone()).or_insert_with(BTreeSet::new).insert(caps[1].to_string());
                    continue;
                }
            }
            if end_re.is_match(line) {
                class_stack.pop();
            }
        }
        readers
    }

    fn immutable_struct_reader_types(&self, lines: &[String]) -> BTreeMap<String, BTreeMap<String, String>> {
        let mut reader_types = BTreeMap::new();
        let mut class_stack = Vec::new();
        let class_struct_re = Regex::new(r"^\s*class\s+([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\s*<\s*T::Struct\b").unwrap();
        let const_type_re = Regex::new(r"^\s*const\s+:([A-Za-z_]\w*)\s*,\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)\b").unwrap();
        let end_re = Regex::new(r"^\s*end\s*(?:#.*)?$").unwrap();

        for line in lines {
            if let Some(caps) = class_struct_re.captures(line) {
                class_stack.push(caps[1].to_string());
                continue;
            }
            if !class_stack.is_empty() {
                if let Some(caps) = const_type_re.captures(line) {
                    reader_types.entry(class_stack.last().unwrap().clone()).or_insert_with(BTreeMap::new).insert(caps[1].to_string(), caps[2].to_string());
                    continue;
                }
            }
            if end_re.is_match(line) {
                class_stack.pop();
            }
        }
        reader_types
    }

    fn type_aliases(&self, lines: &[String]) -> BTreeMap<String, String> {
        let mut aliases = BTreeMap::new();
        let type_alias_re = Regex::new(r"^\s*([A-Z]\w*)\s*=\s*T\.type_alias\s*\{\s*([A-Z]\w*(?:::[A-Z]\w*)*)\s*\}").unwrap();
        let const_alias_re = Regex::new(r"^\s*([A-Z]\w*)\s*=\s*([A-Z]\w*(?:::[A-Z]\w*)*)\b").unwrap();

        for line in lines {
            if let Some(caps) = type_alias_re.captures(line) {
                aliases.insert(caps[1].to_string(), caps[2].to_string());
            } else if let Some(caps) = const_alias_re.captures(line) {
                aliases.insert(caps[1].to_string(), caps[2].to_string());
            }
        }
        aliases
    }

    fn resolve_type_alias(&self, type_name: &str) -> String {
        let mut seen = BTreeSet::new();
        let mut current = type_name.to_string();
        loop {
            if seen.contains(&current) {
                return current;
            }
            seen.insert(current.clone());
            let target = self.type_aliases.get(&current).or_else(|| {
                current.split("::").last().and_then(|last| self.type_aliases.get(last))
            });
            match target {
                Some(t) => current = t.clone(),
                None => return current,
            }
        }
    }

    fn extract_method_param_types(&self, lines: &[String]) -> BTreeMap<String, BTreeMap<String, String>> {
        let mut types_by_method = BTreeMap::new();
        let mut pending_sig = String::new();
        let def_re = Regex::new(r"^\s*def\s+([A-Za-z_]\w*[!?=]?)(?:\s|\(|$)").unwrap();

        for line in lines {
            if self.pending_sig_active(line, &pending_sig) {
                pending_sig.push_str(line);
            }
            if let Some(caps) = def_re.captures(line) {
                types_by_method.insert(caps[1].to_string(), self.sig_param_types(&pending_sig));
                pending_sig.clear();
            }
        }
        types_by_method
    }

    fn pending_sig_active(&self, line: &str, pending_sig: &str) -> bool {
        !pending_sig.is_empty() || line.trim().starts_with("sig")
    }

    fn sig_param_types(&self, sig_source: &str) -> BTreeMap<String, String> {
        let params_re = Regex::new(r"params\s*\((.*?)\)").unwrap();
        let param_pair_re = Regex::new(r"([A-Za-z_]\w*)\s*:\s*([A-Za-z_]\w*(?:::[A-Za-z_]\w*)*)").unwrap();
        let mut params = BTreeMap::new();
        if let Some(p_caps) = params_re.captures(sig_source) {
            for pair in param_pair_re.captures_iter(&p_caps[1]) {
                params.insert(pair[1].to_string(), pair[2].to_string());
            }
        }
        params
    }
}

struct Report {
    decisions: Vec<Decision>,
}

impl Report {
    fn new(decisions: Vec<Decision>) -> Self {
        Self { decisions }
    }

    fn findings(&self) -> Vec<StateBranchDensityRow> {
        let mut groups: BTreeMap<(String, String), Vec<Decision>> = BTreeMap::new();
        for d in &self.decisions {
            groups.entry((d.file.clone(), d.defn.clone())).or_default().push(d.clone());
        }

        let mut rows = Vec::new();
        for ((file, defn), ds) in groups {
            let mut refs = BTreeSet::new();
            for d in &ds {
                for r in &d.state_refs {
                    refs.insert(r.clone());
                }
            }
            let refs: Vec<_> = refs.into_iter().collect();
            let score = ds.len() * refs.len().max(1);

            let mut sites = Vec::new();
            let mut spans = BTreeMap::new();
            for d in &ds {
                let loc = format!("{}:{}:{}", d.file, d.defn, d.line);
                sites.push(loc.clone());
                spans.insert(loc, d.span);
            }

            rows.push(StateBranchDensityRow {
                at: format!("{}:{}:{}", file, defn, ds.first().unwrap().line),
                file,
                method: defn,
                decisions: ds.len(),
                state_refs: refs,
                predicate: ds.first().unwrap().predicate.clone(),
                score,
                sites,
                spans,
            });
        }

        rows.sort_by(|a, b| {
            b.score
                .cmp(&a.score)
                .then_with(|| b.decisions.cmp(&a.decisions))
                .then_with(|| a.file.cmp(&b.file))
                .then_with(|| a.method.cmp(&b.method))
        });
        rows
    }
}
