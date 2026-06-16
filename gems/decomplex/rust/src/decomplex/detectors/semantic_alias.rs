use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::syntax::Language;
use anyhow::Result;
use serde::Serialize;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SemanticAliasReport {
    pub alias_clusters: Vec<SemanticAliasCluster>,
    pub reification_misses: Vec<ReificationMiss>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct SemanticAliasCluster {
    pub canon: String,
    pub names: Vec<String>,
    pub sites: Vec<String>,
    pub spans: BTreeMap<String, Span>,
}

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct ReificationMiss {
    pub predicate: String,
    pub canon: String,
    pub at: String,
    pub spans: BTreeMap<String, Span>,
    pub raw: String,
}

#[derive(Clone, Debug)]
struct Pred {
    name: String,
    canon: String,
    file: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct Use {
    canon: String,
    file: String,
    defn: String,
    line: usize,
    raw: String,
    span: Span,
}

#[derive(Clone, Debug)]
struct Scanner {
    file: String,
    lines: Vec<String>,
    preds: Vec<Pred>,
    uses: Vec<Use>,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<SemanticAliasReport> {
    let _ = language;
    let mut preds = Vec::new();
    let mut uses = Vec::new();
    for file in files {
        let (root, lines) = ast::parse(file)?;
        let mut scanner = Scanner::new(file.to_string_lossy().to_string(), lines);
        scanner.walk(&root, &[]);
        preds.extend(scanner.preds);
        uses.extend(scanner.uses);
    }
    Ok(SemanticAliasReport {
        alias_clusters: alias_clusters(&preds),
        reification_misses: reification_misses(&preds, &uses),
    })
}

impl Scanner {
    fn new(file: String, lines: Vec<String>) -> Self {
        Self {
            file,
            lines,
            preds: Vec::new(),
            uses: Vec::new(),
        }
    }

    fn walk(&mut self, node: &Node, defstack: &[String]) {
        let next_defstack = ast::def_push(node, defstack);
        if node.r#type == "DEFN" {
            self.record_pred(node);
        }
        if matches!(node.r#type.as_str(), "CALL" | "OPCALL") && comparison(node) {
            let raw = ast::slice(node, &self.lines);
            self.uses.push(Use {
                canon: canon(&raw),
                file: self.file.clone(),
                defn: next_defstack
                    .last()
                    .cloned()
                    .unwrap_or_else(|| "(top-level)".to_string()),
                line: node.first_lineno,
                raw,
                span: [
                    node.first_lineno,
                    node.first_column,
                    node.last_lineno,
                    node.last_column,
                ],
            });
        }
        for child in node.children.iter().filter_map(ast::node) {
            self.walk(child, &next_defstack);
        }
    }

    fn record_pred(&mut self, node: &Node) {
        let Some(name) = child_to_string(node.children.first()) else {
            return;
        };
        if !name.ends_with('?') {
            return;
        }
        let statements = ast::body_stmts(node);
        if statements.len() != 1 {
            return;
        }
        self.preds.push(Pred {
            name,
            canon: canon(&ast::slice(statements[0], &self.lines)),
            file: self.file.clone(),
            line: node.first_lineno,
            span: [
                node.first_lineno,
                node.first_column,
                node.last_lineno,
                node.last_column,
            ],
        });
    }
}

fn alias_clusters(preds: &[Pred]) -> Vec<SemanticAliasCluster> {
    let mut by_canon: Vec<(&str, Vec<&Pred>)> = Vec::new();
    for pred in preds {
        if let Some((_, rows)) = by_canon
            .iter_mut()
            .find(|(existing, _)| *existing == pred.canon.as_str())
        {
            rows.push(pred);
        } else {
            by_canon.push((pred.canon.as_str(), vec![pred]));
        }
    }

    let mut out = by_canon
        .into_iter()
        .filter_map(|(canon, rows)| {
            let mut names = Vec::new();
            for pred in &rows {
                if !names.contains(&pred.name) {
                    names.push(pred.name.clone());
                }
            }
            if names.len() < 2 {
                return None;
            }
            let sites = rows
                .iter()
                .map(|pred| format!("{}:{}:{}", pred.file, pred.name, pred.line))
                .collect::<Vec<_>>();
            let spans = rows
                .iter()
                .map(|pred| (format!("{}:{}:{}", pred.file, pred.name, pred.line), pred.span))
                .collect::<BTreeMap<_, _>>();
            Some(SemanticAliasCluster {
                canon: canon.to_string(),
                names,
                sites,
                spans,
            })
        })
        .collect::<Vec<_>>();
    out.sort_by(|left, right| right.names.len().cmp(&left.names.len()));
    out
}

fn reification_misses(preds: &[Pred], uses: &[Use]) -> Vec<ReificationMiss> {
    let mut out = Vec::new();
    for usage in uses {
        let usage_canon = usage.canon.clone();
        let Some(pred) = preds.iter().find(|candidate| candidate.canon == usage_canon) else {
            continue;
        };
        let usage_function = semantic_function_name(&usage.defn);
        if usage_function.ends_with('?')
            && preds
                .iter()
                .any(|candidate| candidate.canon == usage_canon && candidate.name == usage_function)
        {
            continue;
        }
        let at = format!("{}:{}:{}", usage.file, usage_function, usage.line);
        let mut spans = BTreeMap::new();
        spans.insert(at.clone(), usage.span);
        out.push(ReificationMiss {
            predicate: pred.name.clone(),
            canon: usage_canon,
            at,
            spans,
            raw: usage.raw.clone(),
        });
    }
    out.sort_by(|left, right| left.predicate.cmp(&right.predicate));
    out
}

fn canon(text: &str) -> String {
    let (mut value, _) = ast::canon_polarity(text);
    value = value.strip_prefix("self.").unwrap_or(&value).to_string();
    value = value.strip_prefix('@').unwrap_or(&value).to_string();
    value = strip_single_receiver_hop(&value);
    value.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn strip_single_receiver_hop(text: &str) -> String {
    let Some(dot) = text.find('.') else {
        return text.to_string();
    };
    let receiver = &text[..dot];
    if receiver.is_empty() || !identifier_like(receiver) {
        return text.to_string();
    }
    let rest = &text[dot + 1..];
    let Some(attr_len) = leading_identifier_len(rest) else {
        return text.to_string();
    };
    let after_attr = rest[attr_len..].trim_start();
    if !(after_attr.starts_with("==") || after_attr.starts_with("!=") || after_attr.starts_with('.')) {
        return text.to_string();
    }
    rest.to_string()
}

fn leading_identifier_len(text: &str) -> Option<usize> {
    let mut chars = text.char_indices();
    let (_, first) = chars.next()?;
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return None;
    }
    let mut end = first.len_utf8();
    for (index, ch) in chars {
        if ch == '_' || ch.is_ascii_alphanumeric() {
            end = index + ch.len_utf8();
        } else {
            break;
        }
    }
    Some(end)
}

fn identifier_like(text: &str) -> bool {
    let mut chars = text.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    if !(first == '_' || first.is_ascii_alphabetic()) {
        return false;
    }
    chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn semantic_function_name(name: &str) -> String {
    name.strip_prefix("self.").unwrap_or(name).to_string()
}

fn comparison(node: &Node) -> bool {
    let Some(method) = child_to_string(node.children.get(1)) else {
        return false;
    };
    matches!(method.as_str(), "==" | "!=" | "nil?")
}

fn child_to_string(child: Option<&Child>) -> Option<String> {
    match child {
        Some(Child::String(value)) | Some(Child::Symbol(value)) => Some(value.clone()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pred(name: &str, body: &str, line: usize) -> Pred {
        Pred {
            name: name.to_string(),
            canon: canon(body),
            file: "a.rb".to_string(),
            line,
            span: [line, 0, line, 1],
        }
    }

    fn use_at(function: &str, raw: &str, line: usize) -> Use {
        Use {
            canon: canon(raw),
            raw: raw.to_string(),
            file: "a.rb".to_string(),
            defn: function.to_string(),
            line,
            span: [line, 0, line, 1],
        }
    }

    #[test]
    fn canonicalizes_receiver_forms() {
        assert_eq!(canon("node.provenance == :frame"), "provenance == :frame");
        assert_eq!(canon("@provenance == :frame"), "provenance == :frame");
        assert_eq!(canon("self.provenance == :frame"), "provenance == :frame");
        assert_eq!(canon("!x.heap?"), "x.heap?");
        assert_eq!(canon("stmt.expr? && ok"), "stmt.expr? && ok");
    }

    #[test]
    fn reports_aliases_and_reification_misses() {
        let preds = vec![
            pred("frame?", "@provenance == :frame", 1),
            pred("is_frame?", "provenance == :frame", 2),
            pred("heap?", "@provenance == :heap", 3),
        ];
        let uses = vec![use_at("somewhere", "node.provenance == :frame", 10)];
        let report = SemanticAliasReport {
            alias_clusters: alias_clusters(&preds),
            reification_misses: reification_misses(&preds, &uses),
        };
        assert_eq!(report.alias_clusters.len(), 1);
        assert_eq!(report.alias_clusters[0].names, vec!["frame?", "is_frame?"]);
        assert_eq!(report.reification_misses.len(), 1);
        assert_eq!(report.reification_misses[0].predicate, "frame?");
    }
}
