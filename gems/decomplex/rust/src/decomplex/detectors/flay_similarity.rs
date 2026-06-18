use crate::decomplex::ast::{normalize_text, RawNode, Span};
use crate::decomplex::syntax::{self, Document, FunctionDef, Language, SimilarityFinding};
use anyhow::Result;
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;

const MAX_FUZZY_CHILDREN: usize = 14;
const IDENTIFIER_KINDS: &[&str] = &[
    "identifier",
    "constant",
    "type_identifier",
    "field_identifier",
    "property_identifier",
    "shorthand_property_identifier_pattern",
    "variable_name",
];
const LITERAL_KINDS: &[&str] = &[
    "string",
    "string_content",
    "string_literal",
    "interpreted_string_literal",
    "raw_string_literal",
    "integer",
    "float",
    "int",
    "number",
    "rational",
    "imaginary",
    "character",
    "char_literal",
    "symbol",
    "simple_symbol",
    "true",
    "false",
    "nil",
    "none",
    "null",
];
const SKIP_CANDIDATE_KINDS: &[&str] = &[
    "comment",
    "identifier",
    "constant",
    "type_identifier",
    "field_identifier",
    "property_identifier",
    "parameters",
    "formal_parameters",
    "parameter_list",
    "argument_list",
    "arguments",
    "block_parameters",
    "method_parameters",
    "scope_resolution",
];
const CLONE_CANDIDATE_KINDS: &[&str] = &[
    "array",
    "assignment",
    "assignment_statement",
    "block",
    "case",
    "case_clause",
    "class",
    "class_definition",
    "class_declaration",
    "do_block",
    "enum_declaration",
    "for",
    "for_statement",
    "hash",
    "if",
    "if_statement",
    "match_expression",
    "match_statement",
    "method",
    "method_definition",
    "module",
    "operator_assignment",
    "singleton_method",
    "struct_declaration",
    "switch_case",
    "switch_expression",
    "switch_statement",
    "unless",
    "until",
    "while",
    "while_statement",
];
const BODY_KINDS: &[&str] = &[
    "body",
    "block",
    "body_statement",
    "declaration_list",
    "statement_block",
    "compound_statement",
    "suite",
    "do_block",
];
const CALL_KINDS: &[&str] = &[
    "call",
    "call_expression",
    "method_invocation",
    "invocation_expression",
];

#[derive(Clone, Debug)]
struct MethodSpan {
    name: String,
    first_line: usize,
    last_line: usize,
}

#[derive(Clone, Debug)]
struct Candidate {
    file: String,
    line: usize,
    span: Span,
    method_name: String,
    node_name: String,
    mass: usize,
    fingerprint: String,
    raw: String,
    child_fingerprints: Vec<String>,
    child_masses: Vec<usize>,
}

pub fn scan_files(
    files: &[PathBuf],
    language: Language,
    mass: usize,
    fuzzy: usize,
) -> Result<Vec<SimilarityFinding>> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents, mass, fuzzy))
}

pub fn scan_documents(documents: &[Document], mass: usize, fuzzy: usize) -> Vec<SimilarityFinding> {
    let mut scanner = Scanner::new(mass, fuzzy);
    scanner.scan(documents)
}

struct Scanner {
    mass: usize,
    fuzzy: usize,
    method_spans: HashMap<String, Vec<MethodSpan>>,
    source_lines: HashMap<String, Vec<String>>,
}

impl Scanner {
    fn new(mass: usize, fuzzy: usize) -> Self {
        Self {
            mass,
            fuzzy,
            method_spans: HashMap::new(),
            source_lines: HashMap::new(),
        }
    }

    fn scan(&mut self, documents: &[Document]) -> Vec<SimilarityFinding> {
        let mut candidates = Vec::new();
        for document in documents {
            candidates.extend(self.candidates_for_document(document));
        }
        let mut findings = self.type2_findings(&candidates);
        findings.extend(self.type3_findings(&candidates));
        findings.sort_by(|left, right| {
            (
                clone_type_rank(&left.clone_type),
                std::cmp::Reverse(left.mass),
                left.node.clone(),
                left.at.clone(),
            )
                .cmp(&(
                    clone_type_rank(&right.clone_type),
                    std::cmp::Reverse(right.mass),
                    right.node.clone(),
                    right.at.clone(),
                ))
        });
        self.prune_nested_findings(findings)
    }

    fn candidates_for_document(&mut self, document: &Document) -> Vec<Candidate> {
        self.source_lines
            .insert(document.file.clone(), document.lines.clone());
        self.method_spans.insert(
            document.file.clone(),
            collect_method_spans(&document.function_defs),
        );

        let mut out = Vec::new();
        let mut seen = HashSet::new();
        for function in &document.function_defs {
            if let Some(candidate) =
                self.candidate_for(&document.file, &function.body, Some("defn"))
            {
                self.add_candidate(&mut out, &mut seen, candidate);
            }
        }

        let mut nodes = Vec::new();
        document.root.walk(&mut nodes);
        for node in nodes {
            if candidate_node(node) {
                if let Some(candidate) = self.candidate_for(&document.file, node, None) {
                    self.add_candidate(&mut out, &mut seen, candidate);
                }
            }
        }
        out
    }

    fn add_candidate(
        &self,
        out: &mut Vec<Candidate>,
        seen: &mut HashSet<String>,
        candidate: Candidate,
    ) {
        if candidate.mass < self.effective_mass_floor() || typed_struct_schema_text(&candidate.raw)
        {
            return;
        }
        let key = format!(
            "{}\0{}\0{:?}\0{}\0{}",
            candidate.file,
            candidate.line,
            candidate.span,
            candidate.node_name,
            candidate.fingerprint
        );
        if seen.insert(key) {
            out.push(candidate);
        }
    }

    fn candidate_for(
        &self,
        file: &str,
        node: &RawNode,
        node_name: Option<&str>,
    ) -> Option<Candidate> {
        let (node_fingerprint, mass) = fingerprint(node, &mut HashSet::new());
        if node_fingerprint.is_empty() {
            return None;
        }
        let line = node.line();
        let method = self.method_span_for(file, line);
        let children = fuzzy_children_for(node);
        let mut child_fingerprints = Vec::new();
        let mut child_masses = Vec::new();
        for child in children {
            let (child_fp, child_mass) = fingerprint(child, &mut HashSet::new());
            if !child_fp.is_empty() && child_mass > 0 {
                child_fingerprints.push(child_fp);
                child_masses.push(child_mass);
            }
        }
        let candidate = Candidate {
            file: file.to_string(),
            line,
            span: node.span,
            method_name: method.name,
            node_name: node_name
                .map(ToString::to_string)
                .unwrap_or_else(|| flay_node_name(node).to_string()),
            mass,
            fingerprint: node_fingerprint,
            raw: normalize_text(&node.text),
            child_fingerprints,
            child_masses,
        };
        Some(candidate)
    }

    fn type2_findings(&self, candidates: &[Candidate]) -> Vec<SimilarityFinding> {
        let mut groups: HashMap<&str, Vec<Candidate>> = HashMap::new();
        for candidate in candidates {
            groups
                .entry(candidate.fingerprint.as_str())
                .or_default()
                .push(candidate.clone());
        }
        let mut out = Vec::new();
        for cluster in groups.values() {
            let cluster = uniq_sites(cluster.clone());
            if cluster.len() < 2 {
                continue;
            }
            let raw_count = cluster
                .iter()
                .map(|candidate| candidate.raw.as_str())
                .collect::<HashSet<_>>()
                .len();
            if raw_count < 2 || self.typed_struct_schema_cluster(&cluster) {
                continue;
            }
            let mass = cluster
                .iter()
                .map(|candidate| candidate.mass)
                .min()
                .unwrap_or(0);
            out.push(self.finding_for(&cluster, "type2", mass));
        }
        out
    }

    fn type3_findings(&self, candidates: &[Candidate]) -> Vec<SimilarityFinding> {
        if self.fuzzy == 0 {
            return Vec::new();
        }
        let mut groups: HashMap<String, Vec<(Candidate, usize)>> = HashMap::new();
        for candidate in candidates {
            for (signature, signature_mass) in self.fuzzy_signatures(candidate) {
                if signature_mass >= self.effective_mass_floor() {
                    groups
                        .entry(signature)
                        .or_default()
                        .push((candidate.clone(), signature_mass));
                }
            }
        }

        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for rows in groups.values() {
            let cluster = uniq_sites(
                rows.iter()
                    .map(|(candidate, _)| candidate.clone())
                    .collect(),
            );
            if cluster.len() < 2 {
                continue;
            }
            let fingerprint_count = cluster
                .iter()
                .map(|candidate| candidate.fingerprint.as_str())
                .collect::<HashSet<_>>()
                .len();
            if fingerprint_count < 2 || self.typed_struct_schema_cluster(&cluster) {
                continue;
            }
            let mut key = cluster
                .iter()
                .map(|candidate| {
                    format!(
                        "{}\0{}\0{}",
                        candidate.file, candidate.line, candidate.node_name
                    )
                })
                .collect::<Vec<_>>();
            key.sort();
            let key = key.join("\0");
            if !seen.insert(key) {
                continue;
            }
            let mass = rows
                .iter()
                .map(|(_, signature_mass)| *signature_mass)
                .max()
                .unwrap_or(0);
            out.push(self.finding_for(&cluster, "type3", mass));
        }
        out
    }

    fn finding_for(
        &self,
        cluster: &[Candidate],
        clone_type: &str,
        mass: usize,
    ) -> SimilarityFinding {
        let mut sites = cluster.iter().map(site_for).collect::<Vec<_>>();
        sites.sort();
        SimilarityFinding {
            at: sites.first().cloned().unwrap_or_default(),
            sites,
            spans: self.spans_for(cluster),
            clone_type: clone_type.to_string(),
            node: most_common_node(cluster),
            mass,
            locations: {
                let mut locations = cluster
                    .iter()
                    .map(|candidate| format!("{}:{}", candidate.file, candidate.line))
                    .collect::<Vec<_>>();
                locations.sort();
                locations
            },
        }
    }

    fn spans_for(&self, cluster: &[Candidate]) -> BTreeMap<String, Span> {
        let mut spans = BTreeMap::new();
        for candidate in cluster {
            let value = if candidate.node_name == "defn" {
                let method = self.method_span_for(&candidate.file, candidate.line);
                [method.first_line, 0, method.last_line, 1]
            } else {
                candidate.span
            };
            spans.insert(site_for(candidate), value);
        }
        spans
    }

    fn prune_nested_findings(&self, findings: Vec<SimilarityFinding>) -> Vec<SimilarityFinding> {
        let mut kept = Vec::new();
        for finding in findings {
            if kept.iter().any(|larger| nested_finding(&finding, larger)) {
                continue;
            }
            kept.push(finding);
        }
        kept
    }

    fn fuzzy_signatures(&self, candidate: &Candidate) -> Vec<(String, usize)> {
        let children = &candidate.child_fingerprints;
        if children.len() < 2 || children.len() > MAX_FUZZY_CHILDREN {
            return Vec::new();
        }
        let max_delete = self.fuzzy.min(children.len() - 1);
        let mut signatures = Vec::new();
        for delete_count in 0..=max_delete {
            for deleted in combinations(children.len(), delete_count) {
                let deleted = deleted.into_iter().collect::<HashSet<_>>();
                let mut kept = Vec::new();
                let mut mass = 0;
                for (index, fingerprint) in children.iter().enumerate() {
                    if deleted.contains(&index) {
                        continue;
                    }
                    kept.push(fingerprint.as_str());
                    mass += candidate.child_masses[index];
                }
                signatures.push((format!("{}({})", candidate.node_name, kept.join("|")), mass));
            }
        }
        signatures
    }

    fn typed_struct_schema_cluster(&self, cluster: &[Candidate]) -> bool {
        cluster.iter().all(|candidate| {
            self.typed_struct_schema_line(&candidate.file, candidate.line)
                || typed_struct_schema_text(&candidate.raw)
        })
    }

    fn typed_struct_schema_line(&self, file: &str, line_no: usize) -> bool {
        self.source_lines
            .get(file)
            .and_then(|lines| lines.get(line_no.saturating_sub(1)))
            .map(|line| {
                let stripped = line.trim_start();
                stripped.starts_with("const :") || stripped.starts_with("prop :")
            })
            .unwrap_or(false)
    }

    fn method_span_for(&self, file: &str, line_no: usize) -> MethodSpan {
        self.method_spans
            .get(file)
            .and_then(|spans| {
                spans
                    .iter()
                    .find(|span| span.first_line <= line_no && line_no <= span.last_line)
            })
            .cloned()
            .unwrap_or_else(|| MethodSpan {
                name: "(top-level)".to_string(),
                first_line: line_no,
                last_line: line_no,
            })
    }

    fn effective_mass_floor(&self) -> usize {
        self.mass
            .max(((self.mass as f64) * 23.0 / 8.0).ceil() as usize)
    }
}

fn collect_method_spans(functions: &[FunctionDef]) -> Vec<MethodSpan> {
    let mut spans = functions
        .iter()
        .map(|function| MethodSpan {
            name: function.name.clone(),
            first_line: function.span[0],
            last_line: function.span[2],
        })
        .collect::<Vec<_>>();
    spans.sort_by_key(|method| (method.first_line, std::cmp::Reverse(method.last_line)));
    spans
}

fn candidate_node(node: &RawNode) -> bool {
    node.named
        && !SKIP_CANDIDATE_KINDS.contains(&node.kind.as_str())
        && CLONE_CANDIDATE_KINDS.contains(&node.kind.as_str())
        && !typed_struct_schema_text(&node.text)
        && !node.named_children().is_empty()
}

fn fuzzy_children_for(node: &RawNode) -> Vec<&RawNode> {
    let source_node = body_node(node).unwrap_or(node);
    let mut children = source_node.named_children();
    if children.is_empty() {
        children = node.named_children();
    }
    children
        .into_iter()
        .filter(|child| {
            !SKIP_CANDIDATE_KINDS.contains(&child.kind.as_str())
                && !typed_struct_schema_text(&child.text)
        })
        .collect()
}

fn body_node(node: &RawNode) -> Option<&RawNode> {
    node.children
        .iter()
        .find(|child| BODY_KINDS.contains(&child.kind.as_str()))
}

fn fingerprint(node: &RawNode, active: &mut HashSet<String>) -> (String, usize) {
    let key = node_key(node);
    if active.contains(&key) || node.kind == "comment" {
        return (String::new(), 0);
    }
    active.insert(key.clone());
    let out = if matches!(
        node.kind.as_str(),
        "predefined_type" | "abstract_pointer_declarator" | "storage_class_specifier" | "ERROR"
    ) {
        let token = terminal_token(node);
        if token.is_empty() {
            (String::new(), 0)
        } else {
            (token, 1)
        }
    } else if CALL_KINDS.contains(&node.kind.as_str()) && call_message(node).is_some() {
        fingerprint_call(node, active)
    } else if node.children.is_empty() {
        let token = terminal_token(node);
        if token.is_empty() {
            (String::new(), 0)
        } else {
            (token, 1)
        }
    } else {
        let mut child_parts = Vec::new();
        let mut mass = 1;
        for child in &node.children {
            let (child_fp, child_mass) = fingerprint(child, active);
            if child_fp.is_empty() {
                continue;
            }
            child_parts.push(child_fp);
            mass += child_mass;
        }
        if child_parts.is_empty() {
            (terminal_token(node), 1)
        } else {
            (format!("{}({})", node.kind, child_parts.join(" ")), mass)
        }
    };
    active.remove(&key);
    out
}

fn fingerprint_call(node: &RawNode, active: &mut HashSet<String>) -> (String, usize) {
    let message = call_message(node).unwrap_or_default();
    let mut child_parts = Vec::new();
    let mut mass = 1;
    for child in &node.children {
        let (child_fp, child_mass) = fingerprint(child, active);
        if child_fp.is_empty() {
            continue;
        }
        child_parts.push(child_fp);
        mass += child_mass;
    }
    (
        format!("{}<{}>({})", node.kind, message, child_parts.join(" ")),
        mass,
    )
}

fn call_message(node: &RawNode) -> Option<String> {
    if !node
        .children
        .iter()
        .any(|child| matches!(child.kind.as_str(), "argument_list" | "arguments"))
    {
        return None;
    }
    let argument_start = node
        .children
        .iter()
        .find(|child| matches!(child.kind.as_str(), "argument_list" | "arguments"))
        .map(|child| (child.span[0], child.span[1]));
    let named_before_args = node
        .named_children()
        .into_iter()
        .filter(|child| {
            argument_start
                .map(|start| (child.span[0], child.span[1]) < start)
                .unwrap_or(true)
        })
        .collect::<Vec<_>>();
    named_before_args
        .last()
        .and_then(|callee| callee_message(callee))
}

fn callee_message(node: &RawNode) -> Option<String> {
    if IDENTIFIER_KINDS.contains(&node.kind.as_str()) {
        return Some(node.text.clone());
    }
    node.named_children()
        .into_iter()
        .rev()
        .find(|child| IDENTIFIER_KINDS.contains(&child.kind.as_str()))
        .map(|child| child.text.clone())
}

fn terminal_token(node: &RawNode) -> String {
    let kind = node.kind.as_str();
    if IDENTIFIER_KINDS.contains(&kind) {
        return "id".to_string();
    }
    if LITERAL_KINDS.contains(&kind) {
        return literal_token(kind).to_string();
    }
    let text = normalize_text(&node.text);
    if text.is_empty() {
        return String::new();
    }
    if identifier_text(&text) {
        return "id".to_string();
    }
    if literal_text(&text) {
        return "lit".to_string();
    }
    format!("{kind}:{text}")
}

fn literal_token(kind: &str) -> &str {
    match kind {
        "true" | "false" => "bool",
        "nil" | "none" | "null" => "nil",
        _ => "lit",
    }
}

fn identifier_text(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|char| {
            char == '_' || char == '!' || char == '?' || char == '=' || char.is_ascii_alphanumeric()
        })
}

fn literal_text(text: &str) -> bool {
    if symbol_literal_text(text)
        || quoted_literal_text(text, '"')
        || quoted_literal_text(text, '\'')
    {
        return true;
    }
    text.parse::<f64>().is_ok()
}

fn symbol_literal_text(text: &str) -> bool {
    let mut chars = text.chars();
    if chars.next() != Some(':') {
        return false;
    }
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|char| char == '_' || char.is_ascii_alphanumeric())
}

fn quoted_literal_text(text: &str, quote: char) -> bool {
    text.len() >= 2 && text.starts_with(quote) && text.ends_with(quote)
}

fn flay_node_name(node: &RawNode) -> &str {
    match node.kind.as_str() {
        "method"
        | "function_definition"
        | "function_declaration"
        | "method_definition"
        | "function_item" => "defn",
        "singleton_method" => "defs",
        other => other,
    }
}

fn uniq_sites(candidates: Vec<Candidate>) -> Vec<Candidate> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for candidate in candidates {
        let key = format!(
            "{}\0{}\0{}",
            candidate.file, candidate.line, candidate.node_name
        );
        if seen.insert(key) {
            out.push(candidate);
        }
    }
    out
}

fn most_common_node(cluster: &[Candidate]) -> String {
    let mut order = Vec::new();
    let mut tally: HashMap<&str, usize> = HashMap::new();
    for candidate in cluster {
        if !tally.contains_key(candidate.node_name.as_str()) {
            order.push(candidate.node_name.as_str());
        }
        *tally.entry(candidate.node_name.as_str()).or_default() += 1;
    }
    let mut best = "";
    let mut best_count = 0;
    for node in order {
        let count = tally.get(node).copied().unwrap_or(0);
        if count > best_count {
            best = node;
            best_count = count;
        }
    }
    best.to_string()
}

fn site_for(candidate: &Candidate) -> String {
    format!(
        "{}:{}:{}",
        candidate.file, candidate.method_name, candidate.line
    )
}

fn nested_finding(inner: &SimilarityFinding, outer: &SimilarityFinding) -> bool {
    if outer.mass <= inner.mass {
        return false;
    }
    inner.spans.iter().all(|(site, span)| {
        let file = site_file(site);
        outer.spans.iter().any(|(outer_site, outer_span)| {
            site_file(outer_site) == file && contains_span(*outer_span, *span)
        })
    })
}

fn contains_span(outer: Span, inner: Span) -> bool {
    let outer_start = (outer[0], outer[1]);
    let outer_end = (outer[2], outer[3]);
    let inner_start = (inner[0], inner[1]);
    let inner_end = (inner[2], inner[3]);
    outer_start <= inner_start && outer_end >= inner_end
}

fn site_file(site: &str) -> String {
    let mut parts = site.split(':').collect::<Vec<_>>();
    if parts.len() >= 2 {
        parts.truncate(parts.len() - 2);
    }
    parts.join(":")
}

fn typed_struct_schema_text(text: &str) -> bool {
    text.contains("< T::Struct")
        || text.contains("<T::Struct")
        || text.lines().all(|line| {
            let stripped = line.trim();
            stripped.is_empty() || stripped.starts_with("const :") || stripped.starts_with("prop :")
        })
}

fn clone_type_rank(clone_type: &str) -> usize {
    if clone_type == "type2" {
        0
    } else {
        1
    }
}

fn node_key(node: &RawNode) -> String {
    format!(
        "{}\0{}\0{}\0{}\0{}\0{}",
        node.kind,
        node.span[0],
        node.span[1],
        node.span[2],
        node.span[3],
        node.text.len()
    )
}

fn combinations(size: usize, count: usize) -> Vec<Vec<usize>> {
    fn step(
        start: usize,
        size: usize,
        count: usize,
        current: &mut Vec<usize>,
        out: &mut Vec<Vec<usize>>,
    ) {
        if current.len() == count {
            out.push(current.clone());
            return;
        }
        for index in start..size {
            current.push(index);
            step(index + 1, size, count, current, out);
            current.pop();
        }
    }
    let mut out = Vec::new();
    step(0, size, count, &mut Vec::new(), &mut out);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    fn scan(source: &str, mass: usize, fuzzy: usize) -> Vec<SimilarityFinding> {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        scan_files(&[file.path().to_path_buf()], Language::Ruby, mass, fuzzy).expect("scan")
    }

    fn document(source: &str) -> Document {
        let mut file = NamedTempFile::new().expect("tempfile");
        file.write_all(source.as_bytes()).expect("write source");
        syntax::parse_file(file.path().to_path_buf(), Language::Ruby).expect("document")
    }

    #[test]
    fn detects_type2_similarity_for_renamed_ruby_methods() {
        let out = scan(
            r#"
def a(node)
  return false unless node.respond_to?(:type)
  node.type == :heap || node.type == :frame
end

def b(entry)
  return false unless entry.respond_to?(:kind)
  entry.kind == :heap || entry.kind == :frame
end
"#,
            8,
            1,
        );
        assert!(out
            .iter()
            .any(|finding| finding.clone_type == "type2" && finding.node == "defn"));
    }

    #[test]
    fn detects_type3_similarity_for_missing_child() {
        let out = scan(
            r#"
def a(node)
  alpha(node.left)
  beta(node.right)
  gamma(node.name)
  delta(node.type)
end

def b(entry)
  alpha(entry.left)
  beta(entry.right)
  delta(entry.type)
end
"#,
            4,
            1,
        );
        assert!(out.iter().any(|finding| finding.clone_type == "type3"));
    }

    #[test]
    fn singleton_method_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def self.release(ctx_id, lock_index, lock_ref, unlock_method)
  [
    MIR::Set.new(
      MIR::FieldGet.new(MIR::Ident.new("__ctx_#{ctx_id}"), "__lock_held_#{lock_index}"),
      MIR::Lit.new("false"),
      false,
    ),
    MIR::ExprStmt.new(
      MIR::MethodCall.new(MIR::Ident.new(lock_ref), unlock_method, [], false),
      false,
    ),
  ]
end
"#,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) = fingerprint(&function.body, &mut HashSet::new());
        assert_eq!(mass, 128);
    }

    #[test]
    fn unless_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def check(attrs, tok)
  unless attrs
    has_at = T.must(tok).value.start_with?('@')
    candidates = has_at ? BG_SIGILS.keys : BG_SIGILS.keys.map { |k| k.sub(/^@/, '') }
    emit_typo_suggestion!(
      tok, T.must(tok).value, candidates,
      "Unknown BG prefix #{T.must(tok).value.inspect}",
      "closest BG body sigil",
      category: :type, cascade: true
    )
  end
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "unless" && node.named)
            .expect("unless");
        let (_fingerprint, mass) = fingerprint(node, &mut HashSet::new());
        assert_eq!(mass, 126);
    }

    #[test]
    fn struct_assignment_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
DeferStmt = Struct.new(:body) do
  extend T::Sig
  include Stmt
  sig { params(body: DeferBodyInput).void }
  def initialize(body)
    MIR.validate_defer_body!(body, "MIR::DeferStmt")
    super(body)
  end

  sig { returns(T::Array[BodySlot]) }
  def body_slots
    body.is_a?(Array) ? [body_slot(:body, body, ->(new_body) { self.body = new_body })] : []
  end
  sig { returns(T::Array[Emittable]) }
  def child_exprs = body.is_a?(Array) ? [] : compact_child_exprs([body])
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "assignment" && node.named)
            .expect("assignment");
        let (_fingerprint, mass) = fingerprint(node, &mut HashSet::new());
        assert_eq!(mass, 178);
    }

    #[test]
    fn body_slots_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
SwitchStmt = Struct.new(:subject, :arms, :default_body) do
  extend T::Sig
  include Stmt
  sig { returns(T::Array[Emittable]) }
  def child_exprs
    compact_child_exprs([subject, *(arms || []).flat_map(&:patterns)])
  end
  sig { returns(T::Array[BodySlot]) }
  def body_slots
    slots = T.let([], T::Array[BodySlot])
    arms&.each_with_index do |arm, index|
      slots << body_slot(:"arms_#{index}", arm.body, ->(new_body) { arm.body = new_body })
    end
    slots << body_slot(:default_body, default_body, ->(new_body) { self.default_body = new_body }) if default_body
    slots
  end
end
"#,
        );
        let function = doc
            .function_defs
            .iter()
            .find(|function| function.name == "body_slots")
            .expect("body_slots");
        let (_fingerprint, mass) = fingerprint(&function.body, &mut HashSet::new());
        assert_eq!(mass, 110);
    }

    #[test]
    fn if_bind_do_block_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
IfBind = Struct.new(:token, :bindings, :then_branch, :else_branch) do
  extend T::Sig
  include Locatable

  sig { params(args: T.untyped).void }
  def initialize(*args)
    super
    self[:bindings] = [] if self[:bindings].nil?
  end

  sig { params(val: T::Array[AST::Binding]).void }
  def bindings=(val)
    self[:bindings] = val
  end
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "do_block" && node.named)
            .expect("do_block");
        let (_fingerprint, mass) = fingerprint(node, &mut HashSet::new());
        assert_eq!(mass, 110);
    }

    #[test]
    fn control_flow_argument_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def self.find_package_source(pkg_name, start_dir:)
  dir = File.expand_path(start_dir)
  loop do
    candidate = File.join(dir, "packages", pkg_name, "src", "lib.cht")
    return candidate if File.exist?(candidate)

    parent = File.dirname(dir)
    break if parent == dir

    dir = parent
  end
  nil
end
"#,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) = fingerprint(&function.body, &mut HashSet::new());
        assert_eq!(mass, 96);
    }

    #[test]
    fn case_scope_pattern_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def walk_for_local_decls(node, &block)
  return if node.nil?
  case node
  when AST::BindExpr, AST::VarDecl
    yield node if auto?(node.type)
    walk_for_local_decls(node.value, &block)
  when AST::FunctionDef
  when Array
    node.each { |c| walk_for_local_decls(c, &block) }
  when Hash
    node.each_value { |v| walk_for_local_decls(v, &block) }
  else
    if node.respond_to?(:each_pair)
      node.each_pair { |_, v| walk_for_local_decls(v, &block) }
    end
  end
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "case" && node.named)
            .expect("case");
        let (_fingerprint, mass) = fingerprint(node, &mut HashSet::new());
        assert_eq!(mass, 136);
    }

    #[test]
    fn case_simple_pattern_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r#"
def references_alias?(expr, alias_name)
  found = false
  walk = lambda do |n|
    return if found
    case n
    when nil, Symbol, String, Integer, Float, TrueClass, FalseClass
    when Array then n.each { |x| walk.call(x) }
    when AST::Identifier
      found = true if n.name == alias_name
    else
      n.each_pair { |_, v| walk.call(v) } if n.respond_to?(:each_pair)
    end
  end
  walk.call(expr)
  found
end
"#,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "case" && node.named)
            .expect("case");
        let (_fingerprint, mass) = fingerprint(node, &mut HashSet::new());
        assert_eq!(mass, 96);
    }

    #[test]
    fn alias_cluster_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r##"
def alias_clusters
  @preds.group_by(&:body).filter_map do |body, ps|
    names = ps.map(&:name).uniq
    next if names.size < 2

    { body: body, names: names,
      sites: ps.map { |p| "#{p.file}:#{p.name}:#{p.line}" },
      spans: ps.to_h { |p| ["#{p.file}:#{p.name}:#{p.line}", p.span] } }
  end.sort_by { |h| -h[:names].size }
end
"##,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) = fingerprint(&function.body, &mut HashSet::new());
        assert_eq!(mass, 175);
    }

    #[test]
    fn native_module_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r##"
module Decomplex
  module Native
    module CoUpdate
      module_function

      def scan(files)
        paths = Array(files).map(&:to_s)
        validate_ruby_files!(paths)
        JSON.parse(Command.run("co-update", "--language", "ruby", *paths))
      end

      private_class_method def self.validate_ruby_files!(paths)
        bad = paths.reject { |path| File.extname(path) == ".rb" }
        return if bad.empty?

        raise ArgumentError, "--engine=rust currently supports Ruby files only: #{bad.join(', ')}"
      end
    end
  end
end
"##,
        );
        let mut nodes = Vec::new();
        doc.root.walk(&mut nodes);
        let node = nodes
            .into_iter()
            .find(|node| node.kind == "module" && node.named)
            .expect("module");
        let (_fingerprint, mass) = fingerprint(node, &mut HashSet::new());
        assert_eq!(mass, 150);
    }

    #[test]
    fn hidden_method_name_mass_matches_ruby_oracle_shape() {
        let doc = document(
            r##"
def inline_def_name(node)
  return nil unless inline_def_argument_list?(node)

  receiver_index = node.named_children.index { |child| child.kind == "self" || child.kind == "constant" }
  search = receiver_index ? node.named_children[(receiver_index + 1)..] : node.named_children
  name = search&.find { |child| %w[identifier field_identifier property_identifier].include?(child.kind) }&.text
  receiver_index ? "self.#{name}" : name
end
"##,
        );
        let function = doc.function_defs.first().expect("function");
        let (_fingerprint, mass) = fingerprint(&function.body, &mut HashSet::new());
        assert_eq!(mass, 132);
    }
}
