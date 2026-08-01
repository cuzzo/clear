//! Turning what the collector saw into the rows the rest of the pipeline reads.
//!
//! The input is one document a traced program wrote when it exited: its own
//! tables, plus the facts only that process could know -- which gem each file
//! came from, what the interpreter's version was. None of the shaping needs a
//! VM, which is why it happens here.
//!
//! The Ruby this replaces read every field twice, `row["types"] || row[:types]`,
//! because the same rows arrived string-keyed from JSONL and symbol-keyed from
//! a parse. Deserializing once removes the question.

use anyhow::{Context, Result};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// The document a traced program wrote.
#[derive(Debug, Deserialize)]
pub struct CollectorDocument {
    pub pid: i64,
    #[serde(default)]
    pub run_id: String,
    #[serde(default)]
    pub root: String,
    #[serde(default)]
    pub targets: Vec<String>,
    #[serde(default)]
    pub ruby_version: String,
    #[serde(default)]
    pub records: Vec<CallRecord>,
    #[serde(default)]
    pub domains: Vec<Value>,
    #[serde(default)]
    pub executed_callsites: Vec<Value>,
    #[serde(default)]
    pub function_entries: Vec<Value>,
    #[serde(default)]
    pub state_values: Vec<Value>,
    #[serde(default)]
    pub method_edges: Vec<Value>,
    #[serde(default)]
    pub collections: Vec<Value>,
    #[serde(default)]
    pub structs: Vec<Value>,
    #[serde(default)]
    pub tuples: Vec<Value>,
    #[serde(default)]
    pub tlets: Vec<Value>,
    #[serde(default)]
    pub gem_specs: Vec<(String, String, String)>,
    #[serde(default)]
    pub default_gem_specs: Vec<(String, String, String)>,
    #[serde(default)]
    pub coverage: Option<Map<String, Value>>,
}

#[derive(Debug, Deserialize)]
pub struct CallRecord {
    pub caller: Value,
    pub callee: Map<String, Value>,
    pub callsite: Callsite,
    #[serde(default)]
    pub receiver_types: Vec<String>,
    #[serde(default)]
    pub receiver_domain_indices: Vec<usize>,
    #[serde(default)]
    pub result_types: Vec<String>,
    #[serde(default)]
    pub result_domain_indices: Vec<usize>,
    #[serde(default)]
    pub result_truths: Vec<Value>,
    pub count: i64,
}

#[derive(Debug, Deserialize)]
pub struct Callsite {
    pub path: String,
    pub line: i64,
    pub selector: String,
}

/// The six fields a value domain carries into a row, in the order the rows
/// name them.
const DOMAIN_FIELDS: [&str; 6] = ["types", "singletons", "elements", "keys", "values", "shapes"];

/// "<abs path>\x01<line>\x01<selector>" => the anchor symbols the plan wants
/// there. One observed event can satisfy several requests, so the collector
/// reports coordinates and the fan-out happens here.
pub fn anchors_by_key(plan: Option<&Value>, root: &Path) -> BTreeMap<String, Vec<String>> {
    let mut anchors: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let Some(requests) = plan
        .and_then(|plan| plan.get("runtime_evidence"))
        .and_then(|evidence| evidence.get("requests"))
        .and_then(Value::as_array)
    else {
        return anchors;
    };
    for request in requests {
        let Some(anchor) = request.get("anchor").filter(|value| value.is_object()) else {
            continue;
        };
        let range = request
            .get("execution_range")
            .filter(|value| value.is_object())
            .or_else(|| anchor.get("range").filter(|value| value.is_object()));
        let Some(range) = range else { continue };

        let path = root
            .join(anchor["relative_path"].as_str().unwrap_or_default())
            .to_string_lossy()
            .to_string();
        let selector = anchor["display_name"].as_str().unwrap_or_default();
        let symbol = anchor["symbol"].as_str().unwrap_or_default().to_string();
        let start = range["start_line"].as_i64().unwrap_or_default();
        let end = range["end_line"].as_i64().unwrap_or_default();
        for line in start..=end {
            let symbols = anchors.entry(format!("{path}\u{1}{}\u{1}{selector}", line + 1)).or_default();
            if !symbols.contains(&symbol) {
                symbols.push(symbol.clone());
            }
        }
    }
    anchors
}

pub struct Export<'a> {
    document: &'a CollectorDocument,
    anchors: &'a BTreeMap<String, Vec<String>>,
    nonproduction: BTreeSet<String>,
    project_name: String,
    project_version: String,
}

impl<'a> Export<'a> {
    pub fn new(
        document: &'a CollectorDocument,
        anchors: &'a BTreeMap<String, Vec<String>>,
        nonproduction: BTreeSet<String>,
        project_name: String,
        project_version: String,
    ) -> Self {
        Self { document, anchors, nonproduction, project_name, project_version }
    }

    /// The same set of files the traced program used to write itself.
    pub fn write(&self, runtime_dir: &Path) -> Result<()> {
        let pid = self.document.pid;
        let files: Vec<(&str, Vec<Value>)> = vec![
            ("runtime-calls", self.call_rows()),
            ("methods", self.method_rows()),
            ("method-edges", self.method_edge_rows()),
            ("executed-callsites", self.executed_callsite_rows()),
            ("exact-anchor-executions", self.exact_anchor_rows()),
            ("function-entries", self.function_entry_rows()),
            ("state-values", self.state_rows()),
            ("ivars", self.ivar_rows()),
            ("structs", self.document.structs.clone()),
            ("tuples", self.document.tuples.clone()),
            // A reader whose result is a collection was derived into this file
            // too and then overwritten by these rows before anything read it,
            // so only what the mutation hook observed is kept.
            ("collections", self.collection_rows()),
            ("tlets", self.tlet_rows()),
        ];
        for (name, rows) in files {
            write_jsonl(&runtime_dir.join(format!("{name}-{pid}.jsonl")), &rows)?;
        }
        self.write_coverage(runtime_dir)
    }

    // ------------------------------------------------------------ packages

    fn ruby_package(&self) -> Value {
        json!({
            "package_manager": "ruby",
            "package": "ruby",
            "version": self.document.ruby_version,
        })
    }

    fn workspace_package(&self) -> Value {
        json!({
            "package_manager": "workspace",
            "package": self.project_name,
            "version": self.project_version,
        })
    }

    fn under(root: &str, absolute: &str) -> bool {
        absolute == root || absolute.starts_with(&format!("{root}/"))
    }

    /// Which gem owns a file is a fact only the traced VM held, and it wrote
    /// its gem table down. What that makes the file is decided here.
    fn package(&self, path: Option<&str>, native: bool) -> Value {
        if native {
            return self.ruby_package();
        }
        // TracePoint uses pseudo-paths such as `<internal:warning>` for
        // Ruby-core implementations written outside the workspace. Expanding
        // those would incorrectly label `Kernel#warn` and peers as project code.
        let raw = path.unwrap_or_default();
        if raw.is_empty() || raw.starts_with("<internal:") {
            return self.ruby_package();
        }
        let absolute = expand(raw, &self.document.root);
        if self.document.targets.iter().any(|target| Self::under(target, &absolute)) {
            return self.workspace_package();
        }
        let found = self
            .document
            .gem_specs
            .iter()
            .find(|(_, _, root)| Self::under(root, &absolute))
            .or_else(|| {
                self.document
                    .default_gem_specs
                    .iter()
                    .find(|(_, _, root)| Self::under(root, &absolute))
            });
        if let Some((name, version, _)) = found {
            let stdlib = self.document.default_gem_specs.iter().any(|(known, _, _)| known == name);
            return json!({
                // Ruby ships a growing portion of its standard library as
                // default gems. Bundler may activate a newer vendored copy, but
                // that does not turn StringIO, JSON, etc. into third-party APIs.
                "package_manager": if stdlib { "ruby" } else { "rubygems" },
                "package": name,
                "version": version,
            });
        }
        if Self::under(&self.document.root, &absolute) {
            // Trace targets are intentionally narrower than the workspace: a
            // project may call a sibling tool without instrumenting its source.
            // It is still a workspace declaration, not a Ruby core method.
            return self.workspace_package();
        }
        self.ruby_package()
    }

    fn callee_facts(&self, path: Option<&str>, native: bool) -> Map<String, Value> {
        let mut facts = Map::new();
        let nonproduction = path.is_some_and(|path| {
            self.nonproduction.contains(&expand(path, &self.document.root))
        });
        facts.insert(
            "source_role".to_string(),
            if nonproduction { json!("nonproduction") } else { Value::Null },
        );
        if let Value::Object(package) = self.package(path, native) {
            facts.extend(package);
        }
        facts
    }

    // ------------------------------------------------------------- domains

    fn symbols_for(&self, path: &str, line: i64, selector: &str) -> &[String] {
        self.anchors
            .get(&format!("{path}\u{1}{line}\u{1}{selector}"))
            .map_or(&[][..], Vec::as_slice)
    }

    /// Types the collector named directly, merged with the domains it recorded
    /// by index. `production_only` drops what a test double contributed, which
    /// call evidence must not export as a target.
    fn domain_for(&self, types: &[String], indices: &[usize], production_only: bool) -> Value {
        let mut domain: BTreeMap<&str, Vec<Value>> =
            DOMAIN_FIELDS.iter().map(|field| (*field, Vec::new())).collect();
        merge_domain_field(
            &mut domain,
            "types",
            &types.iter().map(|name| json!(name)).collect::<Vec<_>>(),
        );
        for index in indices {
            let Some(observed) = self.document.domains.get(*index) else { continue };
            if production_only && observed["nonproduction"].as_bool().unwrap_or(false) {
                continue;
            }
            for field in DOMAIN_FIELDS {
                if let Some(values) = observed.get(field).and_then(Value::as_array) {
                    merge_domain_field(&mut domain, field, values);
                }
            }
        }
        let mut out = Map::new();
        for field in DOMAIN_FIELDS {
            out.insert(field.to_string(), json!(domain[field]));
        }
        Value::Object(out)
    }

    // ---------------------------------------------------------------- rows

    fn definition_path(path: Option<&str>) -> Option<&str> {
        let path = path?;
        if path.starts_with('<') || path.contains("/gems/nil-kill/lib/") {
            return None;
        }
        Some(path)
    }

    fn call_rows(&self) -> Vec<Value> {
        let mut rows = Vec::new();
        for record in &self.document.records {
            let path = Self::definition_path(record.callee["path"].as_str());
            let native = record.callee["native"].as_bool().unwrap_or(false) && path.is_none();
            let symbols = self.symbols_for(
                &record.callsite.path,
                record.callsite.line,
                &record.callsite.selector,
            );
            // A known definition site outranks the C-implementation flag for
            // package attribution: a generated accessor on a workspace class is
            // workspace code, not CRuby, even though the VM reported it native.
            let mut callee = record.callee.clone();
            callee.insert("path".to_string(), path.map_or(Value::Null, |path| json!(path)));
            if path.is_none() {
                callee.insert("line".to_string(), Value::Null);
            }
            callee.extend(self.callee_facts(path, native));

            let receiver = self.domain_for(
                &record.receiver_types,
                &record.receiver_domain_indices,
                true,
            );
            let result =
                self.domain_for(&record.result_types, &record.result_domain_indices, true);

            let anchors: Vec<Value> = if symbols.is_empty() {
                vec![Value::Null]
            } else {
                symbols.iter().map(|symbol| json!(symbol)).collect()
            };
            for anchor_symbol in anchors {
                rows.push(json!({
                    "schema_version": 1,
                    "event": "runtime_call",
                    "language": "ruby",
                    "run_id": self.document.run_id,
                    "caller": record.caller,
                    "callsite": {
                        "path": record.callsite.path,
                        "line": record.callsite.line,
                        "anchor_symbol": anchor_symbol,
                    },
                    "callee": callee,
                    "receiver_domain": receiver,
                    "result_domain": result,
                    "result_truths": record.result_truths,
                    "count": record.count,
                }));
            }
        }
        rows
    }

    fn executed_callsite_rows(&self) -> Vec<Value> {
        let mut rows = self.document.executed_callsites.clone();
        rows.sort_by_key(tuple_sort_key);
        rows.iter()
            .map(|row| {
                json!({"path": row[0], "line": row[1], "selector": row[2], "count": row[3]})
            })
            .collect()
    }

    fn exact_anchor_rows(&self) -> Vec<Value> {
        let mut tally: BTreeMap<&str, i64> = BTreeMap::new();
        for row in &self.document.executed_callsites {
            let (path, line, selector) = (
                row[0].as_str().unwrap_or_default(),
                row[1].as_i64().unwrap_or_default(),
                row[2].as_str().unwrap_or_default(),
            );
            let count = row[3].as_i64().unwrap_or_default();
            for symbol in self.symbols_for(path, line, selector) {
                *tally.entry(symbol.as_str()).or_default() += count;
            }
        }
        tally.into_iter().map(|(symbol, count)| json!({"symbol": symbol, "count": count})).collect()
    }

    fn function_entry_rows(&self) -> Vec<Value> {
        let mut rows = self.document.function_entries.clone();
        rows.sort_by_key(tuple_sort_key);
        rows.iter()
            .map(|row| {
                json!({
                    "path": row[0], "owner": row[1], "name": row[2],
                    "kind": "instance", "line": row[3], "count": row[4],
                })
            })
            .collect()
    }

    fn state_rows(&self) -> Vec<Value> {
        self.document
            .state_values
            .iter()
            .map(|row| {
                let mut classes = row[4]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|value| !value.is_null())
                    .cloned()
                    .collect::<Vec<_>>();
                classes.sort_by_key(|value| value.as_str().unwrap_or_default().to_string());
                json!({
                    "path": row[0], "line": row[1], "class": row[2],
                    "name": row[3], "classes": classes, "calls": row[5],
                })
            })
            .collect()
    }

    /// The same observations answer two questions: which classes a member holds
    /// anywhere, and which it holds at one write site.
    fn ivar_rows(&self) -> Vec<Value> {
        let mut tally: Vec<((String, String), (i64, Vec<String>))> = Vec::new();
        for row in self.state_rows() {
            let owner = row["class"].as_str().unwrap_or_default().to_string();
            let name = format!("@{}", row["name"].as_str().unwrap_or_default());
            let calls = row["calls"].as_i64().unwrap_or_default();
            let classes = row["classes"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|value| value.as_str().map(str::to_string))
                .collect::<Vec<_>>();
            match tally.iter_mut().find(|(key, _)| *key == (owner.clone(), name.clone())) {
                Some((_, record)) => {
                    record.0 += calls;
                    for class in classes {
                        if !record.1.contains(&class) {
                            record.1.push(class);
                        }
                    }
                }
                None => tally.push(((owner, name), (calls, classes))),
            }
        }
        tally
            .into_iter()
            .map(|((owner, name), (calls, mut classes))| {
                classes.sort();
                json!({"class": owner, "name": name, "calls": calls, "classes": classes})
            })
            .collect()
    }

    fn collection_rows(&self) -> Vec<Value> {
        self.document
            .collections
            .iter()
            .map(|row| {
                let mut row = row.clone();
                let sites = row["mutation_sites"].as_object().cloned().unwrap_or_default();
                let mut ordered = sites.into_iter().collect::<Vec<_>>();
                ordered.sort_by(|(left_site, left), (right_site, right)| {
                    let by_count = right.as_i64().unwrap_or_default()
                        .cmp(&left.as_i64().unwrap_or_default());
                    by_count.then_with(|| left_site.cmp(right_site))
                });
                row["mutation_sites"] = Value::Object(ordered.into_iter().collect());
                row
            })
            .collect()
    }

    fn tlet_rows(&self) -> Vec<Value> {
        self.document
            .tlets
            .iter()
            .map(|row| {
                json!({
                    "path": row["path"], "line": row["line"],
                    "calls": row["calls"], "classes": row["classes"],
                })
            })
            .collect()
    }

    /// The evidence emitter reads parameter and return domains from
    /// methods-*.jsonl, which the Ruby type tier used to produce. The collector
    /// already observes both -- parameters at analyzed method entry, returns
    /// under the "return" selector -- so this regroups them per function.
    fn method_rows(&self) -> Vec<Value> {
        self.document
            .function_entries
            .iter()
            .map(|entry| {
                let (path, owner, name, line, count) =
                    (&entry[0], &entry[1], &entry[2], &entry[3], &entry[4]);
                let at_site = self.document.records.iter().filter(|record| {
                    json!(record.callsite.path) == *path && json!(record.callsite.line) == *line
                });
                let mut params_by_name = Map::new();
                let mut param_singleton_types = Map::new();
                let mut param_value_shapes = Map::new();
                let mut param_elem = Map::new();
                let mut param_elem_shapes = Map::new();
                let mut param_kv = Map::new();
                let mut param_kv_shapes = Map::new();
                let mut returned = json!({
                    "returns": [], "return_singleton_types": [], "return_value_shapes": [],
                    "return_elem": [], "return_kv": [[], []],
                });
                for record in at_site {
                    if record.callsite.selector == "return" {
                        let domain = self.domain_for(
                            &record.result_types,
                            &record.result_domain_indices,
                            false,
                        );
                        returned = json!({
                            "returns": domain["types"],
                            "return_singleton_types": domain["singletons"],
                            "return_value_shapes": domain["shapes"],
                            "return_elem": domain["elements"],
                            "return_kv": [domain["keys"], domain["values"]],
                        });
                        continue;
                    }
                    let slot = record.callsite.selector.clone();
                    let domain = self.domain_for(
                        &record.receiver_types,
                        &record.receiver_domain_indices,
                        false,
                    );
                    params_by_name.insert(slot.clone(), domain["types"].clone());
                    param_singleton_types.insert(slot.clone(), domain["singletons"].clone());
                    param_value_shapes.insert(slot.clone(), domain["shapes"].clone());
                    param_elem.insert(slot.clone(), domain["elements"].clone());
                    param_elem_shapes.insert(slot.clone(), json!([]));
                    param_kv.insert(
                        slot.clone(),
                        json!([domain["keys"], domain["values"]]),
                    );
                    param_kv_shapes.insert(slot, json!([[], []]));
                }
                json!({
                    "class": owner, "method": name, "kind": "instance",
                    "path": path, "line": line,
                    "calls": count, "ok_calls": count, "raised_calls": 0,
                    "params_by_name": params_by_name,
                    "param_singleton_types": param_singleton_types,
                    "param_value_shapes": param_value_shapes,
                    "param_elem": param_elem,
                    "param_elem_shapes": param_elem_shapes,
                    "param_kv": param_kv,
                    "param_kv_shapes": param_kv_shapes,
                    "params_ok": {}, "params_raised": {}, "param_sites": {},
                    "returns": returned["returns"],
                    "return_singleton_types": returned["return_singleton_types"],
                    "return_value_shapes": returned["return_value_shapes"],
                    "return_elem": returned["return_elem"],
                    "return_elem_shapes": [],
                    "return_kv": returned["return_kv"],
                    "return_kv_shapes": [[], []],
                })
            })
            .collect()
    }

    /// An edge is a fact about the call graph, not evidence about a requested
    /// value, so it is recorded for every call between two analyzed methods
    /// rather than only for callsites the plan demanded.
    fn method_edge_rows(&self) -> Vec<Value> {
        let entries = self
            .document
            .function_entries
            .iter()
            .map(|entry| {
                (
                    site_key(&entry[0], &entry[3]),
                    json!({
                        "class": entry[1], "method": entry[2], "kind": "instance",
                        "path": entry[0], "line": entry[3],
                    }),
                )
            })
            .collect::<BTreeMap<_, _>>();
        self.document
            .method_edges
            .iter()
            .filter_map(|edge| {
                let from = entries.get(&site_key(&edge[0], &edge[1]))?;
                let to = entries.get(&site_key(&edge[2], &edge[3]))?;
                Some(json!({
                    "caller": from, "callee": to,
                    "calls": edge[4], "ok_calls": edge[4], "raised_calls": 0,
                }))
            })
            .collect()
    }

    /// Ruby's line coverage for the traced run, so the report can tell a tracer
    /// miss from a line the workload simply never reached.
    fn write_coverage(&self, runtime_dir: &Path) -> Result<()> {
        let Some(coverage) = &self.document.coverage else { return Ok(()) };

        let mut rows = Vec::new();
        for (path, data) in coverage {
            // Native collection uses oneshot_lines. A shared SimpleCov session
            // may already be running in counted-lines mode, so accept that
            // shape rather than restarting or weakening the external session.
            let oneshot = data.get("oneshot_lines").and_then(Value::as_array);
            let mut covered: Vec<i64> = match oneshot {
                Some(lines) => lines.iter().filter_map(Value::as_i64).collect(),
                None => {
                    let lines = data.get("lines").and_then(Value::as_array).or_else(|| data.as_array());
                    lines
                        .into_iter()
                        .flatten()
                        .enumerate()
                        .filter_map(|(at, hits)| {
                            hits.as_i64().filter(|hits| *hits > 0).map(|_| at as i64 + 1)
                        })
                        .collect()
                }
            };
            covered.sort_unstable();
            covered.dedup();
            if covered.is_empty() {
                continue;
            }
            rows.push(json!({"path": path, "lines": covered}));
        }
        write_jsonl(&runtime_dir.join(format!("coverage-{}.jsonl", self.document.pid)), &rows)?;
        // `loop_sites` has never been written into a plan, so this file has
        // always been empty; it is still written because its absence and its
        // emptiness mean different things to the reader.
        write_jsonl(&runtime_dir.join(format!("loops-{}.jsonl", self.document.pid)), &[])
    }
}

/// A method entry's identity: the file it is in and the line it starts on.
fn site_key(path: &Value, line: &Value) -> (String, i64) {
    (path.as_str().unwrap_or_default().to_string(), line.as_i64().unwrap_or_default())
}

/// Ruby sorted these tuples by `row.map(&:to_s)`, so a line number orders as
/// text and 10 precedes 9.
fn tuple_sort_key(row: &Value) -> Vec<String> {
    row.as_array()
        .into_iter()
        .flatten()
        .map(|value| match value {
            Value::String(text) => text.clone(),
            other => other.to_string(),
        })
        .collect()
}

/// Only rebuild a field when an alternative is genuinely new: domains are
/// stored unique and sorted by the same key, so re-merging an existing one is
/// exactly the identity.
fn merge_domain_field(domain: &mut BTreeMap<&str, Vec<Value>>, field: &str, values: &[Value]) {
    if values.is_empty() {
        return;
    }
    let Some(current) = domain.get_mut(field) else { return };
    let added = values.iter().filter(|value| !current.contains(value)).cloned().collect::<Vec<_>>();
    if added.is_empty() {
        return;
    }
    current.extend(added);
    current.sort_by_cached_key(domain_sort_key);
}

fn domain_sort_key(value: &Value) -> String {
    match value {
        Value::String(text) => text.clone(),
        Value::Object(_) => serde_json::to_string(value).unwrap_or_default(),
        other => other.to_string(),
    }
}

fn expand(path: &str, root: &str) -> String {
    if path.starts_with('/') {
        return path.to_string();
    }
    format!("{root}/{path}")
}

fn write_jsonl(path: &Path, rows: &[Value]) -> Result<()> {
    let mut out = String::new();
    for row in rows {
        out.push_str(&serde_json::to_string(row)?);
        out.push('\n');
    }
    std::fs::write(path, out).with_context(|| format!("failed to write {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn document(root: &str, targets: Vec<&str>, gems: Vec<(&str, &str, &str)>) -> CollectorDocument {
        let gems = gems
            .into_iter()
            .map(|(name, version, path)| {
                (name.to_string(), version.to_string(), path.to_string())
            })
            .collect::<Vec<_>>();
        serde_json::from_value(json!({
            "pid": 1,
            "root": root,
            "targets": targets,
            "ruby_version": "3.2.3",
            "gem_specs": gems,
            "default_gem_specs": [],
        }))
        .expect("document")
    }

    fn export<'a>(
        document: &'a CollectorDocument,
        anchors: &'a BTreeMap<String, Vec<String>>,
    ) -> Export<'a> {
        Export::new(
            document,
            anchors,
            BTreeSet::new(),
            "clear".to_string(),
            "workspace".to_string(),
        )
    }

    /// Trace targets are narrower than the workspace: a project may call a
    /// sibling tool without instrumenting it. That file is still a workspace
    /// declaration, not a Ruby core method.
    #[test]
    fn workspace_source_outside_the_targets_keeps_workspace_identity() {
        let document = document("/w", vec!["/w/src"], vec![]);
        let anchors = BTreeMap::new();
        let export = export(&document, &anchors);

        assert_eq!(
            export.package(Some("/w/tools/vopr_coverage.rb"), false),
            json!({"package_manager": "workspace", "package": "clear", "version": "workspace"})
        );
        // A pseudo-path is a Ruby-core implementation with no workspace source,
        // and expanding it would label `Kernel#warn` project code.
        assert_eq!(
            export.package(Some("<internal:warning>"), false),
            json!({"package_manager": "ruby", "package": "ruby", "version": "3.2.3"})
        );
    }

    /// Ruby ships a growing part of its standard library as default gems.
    /// Bundler may activate a newer vendored copy; that does not turn StringIO
    /// into a third-party API.
    #[test]
    fn a_default_gem_stays_a_versioned_standard_library_package() {
        let mut document = document("/w", vec![], vec![("stringio", "3.2.0", "/g/stringio")]);
        document.default_gem_specs = vec![(
            "stringio".to_string(),
            "3.2.0".to_string(),
            "/g/stringio".to_string(),
        )];
        let anchors = BTreeMap::new();

        assert_eq!(
            export(&document, &anchors).package(Some("/g/stringio/lib/stringio.rb"), false),
            json!({"package_manager": "ruby", "package": "stringio", "version": "3.2.0"})
        );
    }

    /// A gem that is not a default gem is a third-party dependency.
    #[test]
    fn an_ordinary_gem_is_a_rubygems_package() {
        let document = document("/w", vec![], vec![("rack", "3.1.0", "/g/rack")]);
        let anchors = BTreeMap::new();

        assert_eq!(
            export(&document, &anchors).package(Some("/g/rack/lib/rack.rb"), false),
            json!({"package_manager": "rubygems", "package": "rack", "version": "3.1.0"})
        );
    }
}
