use crate::decomplex::ast::{self, Child, Node, Span};
use crate::decomplex::detectors::semantic_alias;
use crate::decomplex::syntax::Language;
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
    let mut src_map = BTreeMap::new();
    for file in files {
        let (root, lines) = ast::parse_with_language(file, language)?;
        src_map.insert(file.to_string_lossy().to_string(), (root, lines));
    }

    let mut sm = StateMesh::new(src_map);
    sm.run(language)?;
    Ok(sm.to_json_graph())
}

struct StateMesh {
    src_map: BTreeMap<String, (Node, Vec<String>)>,
    min_writes: usize,
    custom_fields: Option<Vec<String>>,
    writes: Vec<Write>,
    reads: Vec<Read>,
    re_derivations: Vec<ReDerivation>,
}

impl StateMesh {
    fn new(src_map: BTreeMap<String, (Node, Vec<String>)>) -> Self {
        Self {
            src_map,
            min_writes: 2,
            custom_fields: None,
            writes: Vec::new(),
            reads: Vec::new(),
            re_derivations: Vec::new(),
        }
    }

    fn run(&mut self, language: Language) -> Result<()> {
        self.discover_fields();
        if self.known_field_norms().is_empty() {
            return Ok(());
        }

        self.find_reads();
        self.find_re_derivations(language)?;
        Ok(())
    }

    fn discover_fields(&mut self) {
        let files: Vec<_> = self.src_map.keys().cloned().collect();
        for file in files {
            let (root, lines) = self.src_map.get(&file).unwrap();
            let mut writes = Vec::new();
            self.walk_writes(root, lines, &Vec::new(), &file, &mut writes);
            self.writes.extend(writes);
        }
    }

    fn walk_writes(
        &self,
        node: &Node,
        lines: &[String],
        defstack: &[String],
        file: &str,
        out: &mut Vec<Write>,
    ) {
        let mut next_defstack = defstack.to_vec();
        match node.r#type.as_str() {
            "CLASS" | "MODULE" | "DEFN" => {
                if let Some(Child::Symbol(name)) = node.children.first() {
                    next_defstack.push(name.clone());
                }
            }
            "DEFS" => {
                if let Some(Child::Symbol(name)) = node.children.get(1) {
                    next_defstack.push(name.clone());
                }
            }
            "ATTRASGN" => {
                if let (Some(recv), Some(Child::Symbol(msg))) = (
                    node.children.get(0).and_then(ast::node),
                    node.children.get(1),
                ) {
                    if msg != "[]=" {
                        let attr = msg.trim_end_matches('=').to_string();
                        let norm = self.normalize(&attr);
                        out.push(Write {
                            attr,
                            norm,
                            recv: self.recv_slice(Some(recv), lines),
                            file: file.to_string(),
                            defn: next_defstack
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
                        });
                    }
                }
            }
            "IASGN" => {
                if let Some(Child::String(attr)) = node.children.first() {
                    let norm = self.normalize(attr);
                    out.push(Write {
                        attr: attr.clone(),
                        norm,
                        recv: "self".to_string(),
                        file: file.to_string(),
                        defn: next_defstack
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
                    });
                }
            }
            _ => {}
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk_writes(child, lines, &next_defstack, file, out);
        }
    }

    fn find_reads(&mut self) {
        let field_norms = self.known_field_norms();
        let files: Vec<_> = self.src_map.keys().cloned().collect();
        for file in files {
            let (root, lines) = self.src_map.get(&file).unwrap();
            let mut reads = Vec::new();
            self.walk_reads(root, lines, &Vec::new(), &file, &field_norms, &mut reads);
            self.reads.extend(reads);
        }
    }

    fn walk_reads(
        &self,
        node: &Node,
        lines: &[String],
        defstack: &[String],
        file: &str,
        field_norms: &BTreeSet<String>,
        out: &mut Vec<Read>,
    ) {
        let mut next_defstack = defstack.to_vec();
        match node.r#type.as_str() {
            "CLASS" | "MODULE" | "DEFN" => {
                if let Some(Child::Symbol(name)) = node.children.first() {
                    next_defstack.push(name.clone());
                }
            }
            "DEFS" => {
                if let Some(Child::Symbol(name)) = node.children.get(1) {
                    next_defstack.push(name.clone());
                }
            }
            "CALL" | "OPCALL" | "FCALL" | "VCALL" => {
                let recv = if node.r#type == "CALL" || node.r#type == "OPCALL" {
                    node.children.get(0).and_then(ast::node)
                } else {
                    None
                };
                let mid = if node.r#type == "CALL" || node.r#type == "OPCALL" {
                    node.children.get(1)
                } else {
                    node.children.get(0)
                };
                let args = if node.r#type == "CALL" || node.r#type == "OPCALL" {
                    node.children.get(2)
                } else {
                    node.children.get(1)
                };

                if let Some(Child::Symbol(name)) = mid {
                    if args.is_none()
                        || matches!(args, Some(Child::Nil))
                        || self.is_empty_list(args)
                    {
                        if field_norms.contains(name) {
                            out.push(Read {
                                attr: name.clone(),
                                norm: name.clone(),
                                recv: self.recv_slice(recv, lines),
                                file: file.to_string(),
                                defn: next_defstack
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
                            });
                        }
                    }
                }
            }
            "IVAR" => {
                if let Some(Child::String(name)) = node.children.first() {
                    let norm = self.normalize(name);
                    if field_norms.contains(&norm) {
                        out.push(Read {
                            attr: name.clone(),
                            norm,
                            recv: "self".to_string(),
                            file: file.to_string(),
                            defn: next_defstack
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
                        });
                    }
                }
            }
            _ => {}
        }

        for child in node.children.iter().filter_map(ast::node) {
            self.walk_reads(child, lines, &next_defstack, file, field_norms, out);
        }
    }

    fn find_re_derivations(&mut self, language: Language) -> Result<()> {
        let field_norms = self.known_field_norms();
        if field_norms.is_empty() {
            return Ok(());
        }

        let files: Vec<_> = self.src_map.keys().map(PathBuf::from).collect();
        let sa = semantic_alias::scan_files(&files, language)?;

        for m in sa.reification_misses {
            let loc = m.at.clone();
            let parts: Vec<&str> = loc.split(':').collect();
            if parts.len() < 3 {
                continue;
            }
            let line = parts.last().unwrap().parse::<usize>().unwrap_or(0);
            let defn = parts[parts.len() - 2].to_string();
            let file = parts[..parts.len() - 2].join(":");

            if let Some(matched) = field_norms
                .iter()
                .find(|fnorm| m.raw.contains(*fnorm) || m.canon.contains(*fnorm))
            {
                self.re_derivations.push(ReDerivation {
                    field: matched.clone(),
                    file,
                    defn,
                    line,
                    raw: m.raw,
                    predicate: m.predicate,
                    canon: m.canon,
                });
            }
        }
        Ok(())
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
            let attrs = [
                "writes",
                "reads",
                "re_derivations",
                "scatter",
                "messiness",
                "pressure",
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
                fnorm.clone(),
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
            entry.0.insert(w.norm.clone());
        }
        for r in &self.reads {
            let entry = all_unit_sites
                .entry((r.file.clone(), r.defn.clone()))
                .or_default();
            entry.1.insert(r.norm.clone());
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

    fn normalize(&self, attr: &str) -> String {
        attr.trim_start_matches('@').to_string()
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

    fn recv_slice(&self, node: Option<&Node>, lines: &[String]) -> String {
        let Some(node) = node else {
            return "?".to_string();
        };
        ast::slice(node, lines)
    }

    fn is_empty_list(&self, args: Option<&Child>) -> bool {
        if let Some(Child::Node(node)) = args {
            if node.r#type == "LIST" {
                return node.children.iter().all(|c| matches!(c, Child::Nil));
            }
        }
        false
    }
}
