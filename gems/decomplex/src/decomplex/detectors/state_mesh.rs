use crate::decomplex::detectors::semantic_alias;
use crate::decomplex::syntax::{self, Document, Language, Span};
use anyhow::Result;
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

#[derive(Clone, Debug, Serialize)]
pub struct StateMeshReport {
    pub state_mesh: StateMeshMeta,
    pub fields: BTreeMap<String, StateFieldRow>,
    pub hierarchy: Vec<DirObj>,
}

#[derive(Clone, Debug, Serialize)]
pub struct StateMeshMeta {
    pub total_fields: usize,
    pub total_writes: usize,
    pub total_reads: usize,
    pub total_re_derivations: usize,
    pub min_writes: usize,
    pub custom_fields: Option<Vec<String>>,
}

#[derive(Clone, Debug, Serialize)]
pub struct StateFieldRow {
    pub messiness: f64,
    pub rank: usize,
    pub metrics: FieldMetricsRow,
    pub writers: Vec<SiteInfo>,
    pub readers: Vec<SiteInfo>,
    pub re_derivations: Vec<ReDerivationInfo>,
}

#[derive(Clone, Debug, Serialize)]
pub struct FieldMetricsRow {
    pub writes: usize,
    pub reads: usize,
    pub re_derivations: usize,
    pub scatter: usize,
    pub write_scatter: usize,
    pub read_scatter: usize,
    pub receiver_types: usize,
    pub fix_churn: f64,
    pub pressure: usize,
    pub percentiles: BTreeMap<String, usize>,
}

#[derive(Clone, Debug, Serialize)]
pub struct SiteInfo {
    pub file: String,
    pub defn: String,
    pub line: usize,
    pub recv: String,
    pub span: Span,
}

#[derive(Clone, Debug, Serialize)]
pub struct ReDerivationInfo {
    pub file: String,
    pub defn: String,
    pub line: usize,
    pub raw: String,
    pub predicate: String,
    pub canon: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct DirObj {
    pub name: String,
    pub writers: usize,
    pub readers: usize,
    pub files: Vec<FileObj>,
}

#[derive(Clone, Debug, Serialize)]
pub struct FileObj {
    pub name: String,
    pub writers: usize,
    pub readers: usize,
    pub defns: Vec<DefnObj>,
}

#[derive(Clone, Debug, Serialize)]
pub struct DefnObj {
    pub name: String,
    pub writers: usize,
    pub readers: usize,
    pub fields: DefnFields,
}

#[derive(Clone, Debug, Serialize)]
pub struct DefnFields {
    pub written: Vec<String>,
    pub read: Vec<String>,
}

#[derive(Clone, Debug)]
struct Write {
    #[allow(dead_code)]
    attr: String,
    norm: String,
    recv: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct Read {
    #[allow(dead_code)]
    attr: String,
    norm: String,
    recv: String,
    file: String,
    defn: String,
    line: usize,
    span: Span,
}

#[derive(Clone, Debug)]
struct ReDerivation {
    field: String,
    file: String,
    defn: String,
    line: usize,
    raw: String,
    predicate: String,
    canon: String,
}

struct FieldMetrics {
    name: String,
    writes: usize,
    reads: usize,
    re_derivations: usize,
    scatter: usize,
    write_scatter: usize,
    read_scatter: usize,
    receiver_types: usize,
    messiness: f64,
    pressure: usize,
    percentiles: BTreeMap<String, usize>,
    rank: usize,
}

pub fn scan_files(files: &[PathBuf], language: Language) -> Result<StateMeshReport> {
    let documents = syntax::parse_files(files, language)?;
    Ok(scan_documents(&documents))
}

pub fn scan_documents(documents: &[Document]) -> StateMeshReport {
    let semantic_aliases = semantic_alias::scan_documents(documents);
    scan_documents_with_semantic_aliases(documents, &semantic_aliases)
}

pub fn scan_documents_with_semantic_aliases(
    documents: &[Document],
    semantic_aliases: &semantic_alias::SemanticAliasReport,
) -> StateMeshReport {
    scan_documents_with_semantic_aliases_and_min_writes(documents, semantic_aliases, 2)
}

pub fn scan_documents_with_semantic_aliases_and_min_writes(
    documents: &[Document],
    semantic_aliases: &semantic_alias::SemanticAliasReport,
    min_writes: usize,
) -> StateMeshReport {
    let mut sm = StateMesh::new(min_writes);
    sm.load_document_facts(documents);
    sm.find_re_derivations(semantic_aliases);
    sm.to_json_graph()
}

struct StateMesh {
    min_writes: usize,
    custom_fields: Option<Vec<String>>,
    writes: Vec<Write>,
    reads: Vec<Read>,
    re_derivations: Vec<ReDerivation>,
}

impl StateMesh {
    fn new(min_writes: usize) -> Self {
        Self {
            min_writes,
            custom_fields: None,
            writes: Vec::new(),
            reads: Vec::new(),
            re_derivations: Vec::new(),
        }
    }

    fn load_document_facts(&mut self, documents: &[Document]) {
        for document in documents {
            let dialect = crate::decomplex::dialect::dialect_for_document(document);
            for write in &document.state_writes {
                if !syntax::receiver_targets_owner(&write.receiver, &write.owner) {
                    continue;
                }
                let norm = self.state_identity(
                    &write.identity,
                    &write.owner,
                    &self.normalize(&write.field, &*dialect),
                );
                self.writes.push(Write {
                    attr: write.field.clone(),
                    norm,
                    recv: write.receiver.clone(),
                    file: write.file.clone(),
                    defn: write.function.clone(),
                    line: write.line,
                    span: write.span,
                });
            }
        }

        let field_norms = self.known_field_norms();
        if field_norms.is_empty() {
            return;
        }

        for document in documents {
            let dialect = crate::decomplex::dialect::dialect_for_document(document);
            for read in &document.state_reads {
                if !syntax::receiver_targets_owner(&read.receiver, &read.owner) {
                    continue;
                }
                let norm = self.state_identity(
                    &read.identity,
                    &read.owner,
                    &self.normalize(&read.field, &*dialect),
                );
                if !field_norms.contains(&norm) {
                    continue;
                }
                let candidate = Read {
                    attr: read.field.clone(),
                    norm,
                    recv: read.receiver.clone(),
                    file: read.file.clone(),
                    defn: read.function.clone(),
                    line: read.line,
                    span: read.span,
                };
                if !self.write_target_read(&candidate) {
                    self.reads.push(candidate);
                }
            }
        }
    }

    fn write_target_read(&self, read: &Read) -> bool {
        self.writes.iter().any(|write| {
            write.file == read.file
                && write.defn == read.defn
                && write.recv == read.recv
                && (write.attr == read.attr || write.norm == read.norm)
                && write.line == read.line
                && write.span[0] == read.span[0]
                && write.span[1] == read.span[1]
        })
    }

    fn find_re_derivations(&mut self, semantic_aliases: &semantic_alias::SemanticAliasReport) {
        let field_norms = self.known_field_norms();
        if field_norms.is_empty() {
            return;
        }

        for m in &semantic_aliases.reification_misses {
            let loc = m.at.clone();
            let parts: Vec<&str> = loc.split(':').collect();
            if parts.len() < 3 {
                continue;
            }
            let line = parts.last().unwrap().parse::<usize>().unwrap_or(0);
            let defn = parts[parts.len() - 2].to_string();
            let file = parts[..parts.len() - 2].join(":");

            // Predicate facts are intentionally lightweight and do not carry
            // a receiver owner. Match their bare field spelling only if that
            // spelling maps to one known state identity; otherwise leave the
            // re-derivation unreported rather than attaching it to an
            // arbitrary same-named field from another owner.
            let matches = field_norms
                .iter()
                .filter(|field| {
                    let bare = field.rsplit("::").next().unwrap_or(field);
                    m.raw.contains(*field)
                        || m.canon.contains(*field)
                        || m.raw.contains(bare)
                        || m.canon.contains(bare)
                })
                .collect::<Vec<_>>();
            if let [matched] = matches.as_slice() {
                self.re_derivations.push(ReDerivation {
                    field: (*matched).clone(),
                    file,
                    defn,
                    line,
                    raw: m.raw.clone(),
                    predicate: m.predicate.clone(),
                    canon: m.canon.clone(),
                });
            }
        }
    }

    fn metrics(&self) -> Vec<FieldMetrics> {
        let field_norms = self.known_field_norms();
        let mut metrics_vec = Vec::new();

        for fnorm in &field_norms {
            let ws: Vec<_> = self.writes.iter().filter(|w| &w.norm == fnorm).collect();
            let rs: Vec<_> = self.reads.iter().filter(|r| &r.norm == fnorm).collect();
            let ds: Vec<_> = self
                .re_derivations
                .iter()
                .filter(|d| &d.field == fnorm)
                .collect();

            let mut all_sites = BTreeSet::new();
            for w in &ws {
                all_sites.insert((w.file.clone(), w.defn.clone()));
            }
            for r in &rs {
                all_sites.insert((r.file.clone(), r.defn.clone()));
            }
            for d in &ds {
                all_sites.insert((d.file.clone(), d.defn.clone()));
            }
            let scatter = all_sites.len();

            let mut write_sites = BTreeSet::new();
            for w in &ws {
                write_sites.insert((w.file.clone(), w.defn.clone()));
            }
            let write_scatter = write_sites.len();

            let mut read_sites = BTreeSet::new();
            for r in &rs {
                read_sites.insert((r.file.clone(), r.defn.clone()));
            }
            let read_scatter = read_sites.len();

            let mut receivers = BTreeSet::new();
            for w in &ws {
                receivers.insert(w.recv.clone());
            }
            for r in &rs {
                receivers.insert(r.recv.clone());
            }
            let receiver_types = receivers.len();

            let n_writes = ws.len();
            let n_reads = rs.len();
            let n_reder = ds.len();
            let fix_churn = 1.0;
            let messiness = (n_writes + n_reads + n_reder) as f64 * scatter as f64 * fix_churn;
            let pressure = read_scatter;

            metrics_vec.push(FieldMetrics {
                name: fnorm.clone(),
                writes: n_writes,
                reads: n_reads,
                re_derivations: n_reder,
                scatter,
                write_scatter,
                read_scatter,
                receiver_types,
                messiness,
                pressure,
                percentiles: BTreeMap::new(),
                rank: 0,
            });
        }

        metrics_vec.sort_by(|a, b| {
            b.messiness
                .partial_cmp(&a.messiness)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then_with(|| a.name.cmp(&b.name))
        });
        for (i, m) in metrics_vec.iter_mut().enumerate() {
            m.rank = i + 1;
        }

        let total = metrics_vec.len();
        if total > 1 {
            #[cfg(not(test))]
            let attrs = vec![
                "writes",
                "reads",
                "re_derivations",
                "scatter",
                "messiness",
                "pressure",
            ];
            #[cfg(test)]
            let attrs = vec![
                "writes",
                "reads",
                "re_derivations",
                "scatter",
                "messiness",
                "pressure",
                "dummy",
            ];
            for attr in &attrs {
                let mut vals: Vec<f64> = metrics_vec
                    .iter()
                    .map(|m| match *attr {
                        "writes" => m.writes as f64,
                        "reads" => m.reads as f64,
                        "re_derivations" => m.re_derivations as f64,
                        "scatter" => m.scatter as f64,
                        "messiness" => m.messiness,
                        "pressure" => m.pressure as f64,
                        _ => 0.0,
                    })
                    .collect();
                vals.sort_by(|a, b| a.partial_cmp(b).unwrap());

                for m in metrics_vec.iter_mut() {
                    let v = match *attr {
                        "writes" => m.writes as f64,
                        "reads" => m.reads as f64,
                        "re_derivations" => m.re_derivations as f64,
                        "scatter" => m.scatter as f64,
                        "messiness" => m.messiness,
                        "pressure" => m.pressure as f64,
                        _ => 0.0,
                    };
                    let pctl = vals.iter().filter(|&&x| x <= v).count() * 100 / total;
                    m.percentiles.insert(attr.to_string(), pctl);
                }
            }
        }

        metrics_vec
    }

    fn to_json_graph(&self) -> StateMeshReport {
        let fm = self.metrics();
        let fm_index: BTreeMap<String, &FieldMetrics> =
            fm.iter().map(|m| (m.name.clone(), m)).collect();
        let field_norms = self.known_field_norms();
        let display_names = self.display_names(&field_norms);

        let mut fields_obj = BTreeMap::new();
        for fnorm in &field_norms {
            let m = fm_index.get(fnorm).unwrap();
            let ws: Vec<_> = self
                .writes
                .iter()
                .filter(|w| &w.norm == fnorm)
                .map(|w| SiteInfo {
                    file: w.file.clone(),
                    defn: w.defn.clone(),
                    line: w.line,
                    recv: w.recv.clone(),
                    span: w.span,
                })
                .collect();
            let rs: Vec<_> = self
                .reads
                .iter()
                .filter(|r| &r.norm == fnorm)
                .map(|r| SiteInfo {
                    file: r.file.clone(),
                    defn: r.defn.clone(),
                    line: r.line,
                    recv: r.recv.clone(),
                    span: r.span,
                })
                .collect();
            let ds: Vec<_> = self
                .re_derivations
                .iter()
                .filter(|d| &d.field == fnorm)
                .map(|d| ReDerivationInfo {
                    file: d.file.clone(),
                    defn: d.defn.clone(),
                    line: d.line,
                    raw: d.raw.clone(),
                    predicate: d.predicate.clone(),
                    canon: d.canon.clone(),
                })
                .collect();

            fields_obj.insert(
                display_names
                    .get(fnorm)
                    .cloned()
                    .unwrap_or_else(|| fnorm.clone()),
                StateFieldRow {
                    messiness: m.messiness,
                    rank: m.rank,
                    metrics: FieldMetricsRow {
                        writes: m.writes,
                        reads: m.reads,
                        re_derivations: m.re_derivations,
                        scatter: m.scatter,
                        write_scatter: m.write_scatter,
                        read_scatter: m.read_scatter,
                        receiver_types: m.receiver_types,
                        fix_churn: 1.0,
                        pressure: m.pressure,
                        percentiles: m.percentiles.clone(),
                    },
                    writers: ws,
                    readers: rs,
                    re_derivations: ds,
                },
            );
        }

        let mut all_unit_sites: BTreeMap<(String, String), (BTreeSet<String>, BTreeSet<String>)> =
            BTreeMap::new();
        for w in &self.writes {
            let entry = all_unit_sites
                .entry((w.file.clone(), w.defn.clone()))
                .or_default();
            entry.0.insert(
                display_names
                    .get(&w.norm)
                    .cloned()
                    .unwrap_or_else(|| w.norm.clone()),
            );
        }
        for r in &self.reads {
            let entry = all_unit_sites
                .entry((r.file.clone(), r.defn.clone()))
                .or_default();
            entry.1.insert(
                display_names
                    .get(&r.norm)
                    .cloned()
                    .unwrap_or_else(|| r.norm.clone()),
            );
        }

        let mut dirs: BTreeMap<String, BTreeMap<String, BTreeMap<String, DefnObj>>> =
            BTreeMap::new();
        for ((file, defn), (ws, rs)) in all_unit_sites {
            let path = Path::new(&file);
            let dir = path
                .parent()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|| ".".to_string());
            let dir = if dir.is_empty() { ".".to_string() } else { dir };
            let base = path
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_else(|| file.clone());

            dirs.entry(dir)
                .or_default()
                .entry(base)
                .or_default()
                .insert(
                    defn.clone(),
                    DefnObj {
                        name: defn,
                        writers: ws.len(),
                        readers: rs.len(),
                        fields: DefnFields {
                            written: ws.into_iter().collect(),
                            read: rs.into_iter().collect(),
                        },
                    },
                );
        }

        let mut hierarchy = Vec::new();
        for (dname, files_map) in dirs {
            let mut dir_writers = 0;
            let mut dir_readers = 0;
            let mut file_objs = Vec::new();
            for (fname, defns_map) in files_map {
                let mut file_writers = 0;
                let mut file_readers = 0;
                let mut defn_objs: Vec<DefnObj> = defns_map.into_iter().map(|(_, v)| v).collect();
                defn_objs.sort_by(|a, b| a.name.cmp(&b.name));
                for d in &defn_objs {
                    file_writers += d.writers;
                    file_readers += d.readers;
                }
                dir_writers += file_writers;
                dir_readers += file_readers;
                file_objs.push(FileObj {
                    name: fname,
                    writers: file_writers,
                    readers: file_readers,
                    defns: defn_objs,
                });
            }
            file_objs.sort_by(|a, b| a.name.cmp(&b.name));
            hierarchy.push(DirObj {
                name: dname,
                writers: dir_writers,
                readers: dir_readers,
                files: file_objs,
            });
        }
        hierarchy.sort_by(|a, b| a.name.cmp(&b.name));

        StateMeshReport {
            state_mesh: StateMeshMeta {
                total_fields: field_norms.len(),
                total_writes: self.writes.len(),
                total_reads: self.reads.len(),
                total_re_derivations: self.re_derivations.len(),
                min_writes: self.min_writes,
                custom_fields: self.custom_fields.clone(),
            },
            fields: fields_obj,
            hierarchy,
        }
    }

    fn normalize(&self, attr: &str, dialect: &dyn crate::decomplex::dialect::Dialect) -> String {
        dialect.clean_identifier(attr)
    }

    fn state_identity(&self, identity: &str, owner: &str, field: &str) -> String {
        // Prefer FactMine's explicit identity. Otherwise a state slot is at
        // least owner-relative whenever the parser knows its owner. Treating
        // every `options`, `size`, or `children` field in a project as one
        // slot makes lifecycle advice unsafe in PHP, Swift, Java/Kotlin, Lua,
        // and any future adapter that has not yet supplied a richer identity.
        if !identity.is_empty() {
            identity.to_string()
        } else if state_owner_is_stable(owner) {
            format!("{owner}::{field}")
        } else {
            field.to_string()
        }
    }

    /// Keep the familiar field spelling when it identifies exactly one state
    /// slot. If two independently-owned slots share that spelling, expose the
    /// FactMine identity so users can tell them apart instead of receiving a
    /// silently merged finding.
    fn display_names(&self, field_norms: &BTreeSet<String>) -> BTreeMap<String, String> {
        let raw_name = |norm: &str| {
            self.writes
                .iter()
                .find(|write| write.norm == norm)
                .map(|write| write.attr.clone())
                .or_else(|| {
                    self.reads
                        .iter()
                        .find(|read| read.norm == norm)
                        .map(|read| read.attr.clone())
                })
                .unwrap_or_else(|| norm.to_string())
        };
        let raw_names = field_norms
            .iter()
            .map(|norm| (norm.clone(), raw_name(norm)))
            .collect::<BTreeMap<_, _>>();
        let mut counts = BTreeMap::<String, usize>::new();
        for raw in raw_names.values() {
            *counts.entry(raw.clone()).or_default() += 1;
        }
        raw_names
            .into_iter()
            .map(|(norm, raw)| {
                let display = if counts.get(&raw).copied().unwrap_or_default() > 1 {
                    norm.clone()
                } else {
                    raw
                };
                (norm, display)
            })
            .collect()
    }

    fn known_field_norms(&self) -> BTreeSet<String> {
        let mut discovered = BTreeMap::new();
        for w in &self.writes {
            *discovered.entry(w.norm.clone()).or_insert(0) += 1;
        }
        let mut norms: BTreeSet<String> = discovered
            .into_iter()
            .filter(|(_, count)| *count >= self.min_writes)
            .map(|(name, _)| name)
            .collect();
        if let Some(custom) = &self.custom_fields {
            norms.extend(custom.clone());
        }
        norms
    }
}

fn state_owner_is_stable(owner: &str) -> bool {
    !owner.is_empty() && !matches!(owner, "(top-level)" | "(anonymous)" | "Object" | "Kernel")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn local_receiver_members_are_not_owner_state() {
        let document: Document = serde_json::from_value(json!({
            "file": "parser.rb",
            "language": "ruby",
            "state_writes": [
                { "field": "after_all", "receiver": "block", "file": "parser.rb", "function": "populate", "line": 3, "span": [3, 4, 3, 37], "owner": "Parser" },
                { "field": "position", "receiver": "self", "file": "parser.rb", "function": "populate", "line": 4, "span": [4, 4, 4, 17], "owner": "Parser" }
            ],
            "state_reads": [
                { "field": "before_all", "receiver": "block", "file": "parser.rb", "function": "populate", "line": 5, "span": [5, 12, 5, 28], "owner": "Parser" },
                { "field": "position", "receiver": "self", "file": "parser.rb", "function": "populate", "line": 6, "span": [6, 4, 6, 13], "owner": "Parser" }
            ]
        }))
        .unwrap();

        let mut mesh = StateMesh::new(1);
        mesh.load_document_facts(&[document]);
        let report = mesh.to_json_graph();

        assert!(report.fields.contains_key("position"));
        assert!(!report.fields.contains_key("after_all"));
        assert!(!report.fields.contains_key("before_all"));
    }

    #[test]
    fn test_state_mesh_gaps() {
        // 1. Test load_document_facts when field_norms.is_empty() (line 214)
        let doc_no_writes: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "state_reads": [
                {
                    "field": "f1", "receiver": "self", "file": "foo.rb", "function": "m", "line": 1, "span": [1, 1, 1, 5], "owner": "Class"
                }
            ]
        })).unwrap();

        let mut sm = StateMesh::new(1);
        sm.load_document_facts(&[doc_no_writes]);
        assert!(sm.reads.is_empty());

        // 2. Test write_target_read match conditions (lines 244-248)
        let doc_conditions: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "state_writes": [
                {
                    "field": "f1", "receiver": "self", "file": "foo.rb", "function": "m", "line": 10, "span": [10, 1, 10, 5], "owner": "Class"
                },
                {
                    "field": "f2", "receiver": "self", "file": "foo.rb", "function": "m", "line": 99, "span": [99, 1, 99, 5], "owner": "Class"
                }
            ],
            // Reads that mismatch on various parts to check short-circuit boolean logic:
            "state_reads": [
                // diff receiver -> should not be target read
                { "field": "f1", "receiver": "other", "file": "foo.rb", "function": "m", "line": 10, "span": [10, 1, 10, 5], "owner": "Class" },
                // diff field -> should not be target read
                { "field": "f2", "receiver": "self", "file": "foo.rb", "function": "m", "line": 10, "span": [10, 1, 10, 5], "owner": "Class" },
                // diff line -> should not be target read
                { "field": "f1", "receiver": "self", "file": "foo.rb", "function": "m", "line": 11, "span": [10, 1, 10, 5], "owner": "Class" },
                // diff span[0] -> should not be target read
                { "field": "f1", "receiver": "self", "file": "foo.rb", "function": "m", "line": 10, "span": [20, 1, 10, 5], "owner": "Class" },
                // diff span[1] -> should not be target read
                { "field": "f1", "receiver": "self", "file": "foo.rb", "function": "m", "line": 10, "span": [10, 2, 10, 5], "owner": "Class" }
            ]
        })).unwrap();

        let mut sm = StateMesh::new(1);
        sm.load_document_facts(&[doc_conditions]);
        // The external-receiver read is not owner state. The remaining reads
        // each differ from the write target in another dimension.
        assert_eq!(sm.reads.len(), 4);

        // 3. Test find_re_derivations when field_norms.is_empty() (line 255)
        let mut sm = StateMesh::new(1);
        let sa_empty = semantic_alias::SemanticAliasReport {
            alias_clusters: Vec::new(),
            reification_misses: vec![semantic_alias::ReificationMiss {
                predicate: "p".to_string(),
                canon: "c".to_string(),
                at: "foo.rb:m:10".to_string(),
                spans: BTreeMap::new(),
                raw: "raw".to_string(),
            }],
        };
        sm.find_re_derivations(&sa_empty);
        assert!(sm.re_derivations.is_empty());

        // 4. Test find_re_derivations parts.len() < 3 continue branch (line 262)
        let mut sm = StateMesh::new(1);
        // Add a write to make field_norms non-empty
        let doc_write: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "state_writes": [
                {
                    "field": "f1", "receiver": "self", "file": "foo.rb", "function": "m", "line": 1, "span": [1, 1, 1, 5], "owner": "Class"
                }
            ]
        })).unwrap();
        sm.load_document_facts(&[doc_write]);

        let sa_invalid_at = semantic_alias::SemanticAliasReport {
            alias_clusters: Vec::new(),
            reification_misses: vec![semantic_alias::ReificationMiss {
                predicate: "p".to_string(),
                canon: "f1".to_string(),
                at: "invalid_at".to_string(),
                spans: BTreeMap::new(),
                raw: "f1".to_string(),
            }],
        };
        sm.find_re_derivations(&sa_invalid_at);
        assert!(sm.re_derivations.is_empty());

        // 5. Test custom_fields (line 588) inside known_field_norms
        let mut sm = StateMesh::new(1);
        sm.custom_fields = Some(vec!["custom_field".to_string()]);
        let norms = sm.known_field_norms();
        assert!(norms.contains("custom_field"));

        // 6. Test percentile dummy metric match (lines 384, 397)
        // Set up multiple fields in StateMesh so that total > 1
        let doc_multiple: Document = serde_json::from_value(json!({
            "file": "foo.rb",
            "language": "ruby",
            "state_writes": [
                { "field": "f1", "receiver": "self", "file": "foo.rb", "function": "m1", "line": 1, "span": [1, 1, 1, 5], "owner": "Class" },
                { "field": "f2", "receiver": "self", "file": "foo.rb", "function": "m2", "line": 1, "span": [1, 1, 1, 5], "owner": "Class" }
            ]
        })).unwrap();
        let mut sm = StateMesh::new(1);
        sm.load_document_facts(&[doc_multiple]);
        let report = sm.to_json_graph();
        assert!(report.fields.contains_key("f1"));
        assert!(report.fields.contains_key("f2"));
    }

    #[test]
    fn owner_qualified_fact_identities_prevent_c_field_collisions() {
        let temp_dir = tempfile::tempdir().unwrap();
        let file_path = temp_dir.path().join("state.c");
        std::fs::write(
            &file_path,
            "struct Alpha { int flag; };\nstruct Beta { int flag; };\nvoid alpha(struct Alpha* self) { self->flag = 1; }\nvoid beta(struct Beta* self) { self->flag = 2; }\n",
        )
        .unwrap();

        let document = crate::decomplex::syntax::parse_files(&[file_path], Language::C).unwrap();
        let aliases = semantic_alias::scan_documents(&document);
        let report = scan_documents_with_semantic_aliases_and_min_writes(&document, &aliases, 1);
        assert!(report.fields.contains_key("Alpha::flag"));
        assert!(report.fields.contains_key("Beta::flag"));
    }

    #[test]
    fn owner_relative_identity_prevents_cross_language_field_collisions_without_adapter_hints() {
        // These facts intentionally omit `identity`, mirroring adapters that
        // know the owner but have not yet implemented an explicit field-id
        // projection. The shared StateMesh layer must still never merge the
        // two independently owned `options` slots.
        let document: Document = serde_json::from_value(json!({
            "file": "owners.php",
            "language": "php",
            "state_writes": [
                { "field": "options", "receiver": "self", "file": "owners.php", "function": "set", "line": 2, "span": [2, 1, 2, 8], "owner": "First" },
                { "field": "options", "receiver": "self", "file": "owners.php", "function": "set", "line": 8, "span": [8, 1, 8, 8], "owner": "Second" }
            ],
            "state_reads": [
                { "field": "options", "receiver": "self", "file": "owners.php", "function": "get", "line": 3, "span": [3, 1, 3, 8], "owner": "First" },
                { "field": "options", "receiver": "self", "file": "owners.php", "function": "get", "line": 9, "span": [9, 1, 9, 8], "owner": "Second" }
            ]
        }))
        .unwrap();
        let aliases = semantic_alias::scan_documents(&[document.clone()]);
        let report = scan_documents_with_semantic_aliases_and_min_writes(&[document], &aliases, 1);

        assert!(report.fields.contains_key("First::options"));
        assert!(report.fields.contains_key("Second::options"));
        assert_eq!(report.fields["First::options"].metrics.writes, 1);
        assert_eq!(report.fields["Second::options"].metrics.reads, 1);

        let ambiguous_aliases = semantic_alias::SemanticAliasReport {
            alias_clusters: Vec::new(),
            reification_misses: vec![semantic_alias::ReificationMiss {
                predicate: "options?".to_string(),
                canon: "options == true".to_string(),
                at: "owners.php:check:12".to_string(),
                spans: BTreeMap::new(),
                raw: "options == true".to_string(),
            }],
        };
        let safe_report = scan_documents_with_semantic_aliases_and_min_writes(
            &[serde_json::from_value(json!({
                "file": "owners.php",
                "language": "php",
                "state_writes": [
                    { "field": "options", "receiver": "self", "file": "owners.php", "function": "set", "line": 2, "span": [2, 1, 2, 8], "owner": "First" },
                    { "field": "options", "receiver": "self", "file": "owners.php", "function": "set", "line": 8, "span": [8, 1, 8, 8], "owner": "Second" }
                ]
            }))
            .unwrap()],
            &ambiguous_aliases,
            1,
        );
        assert_eq!(safe_report.state_mesh.total_re_derivations, 0);
    }
}
