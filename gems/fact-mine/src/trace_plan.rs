//! Turning static facts into the instrumentation plan the collector reads.
//!
//! FactMine already decides what the source says: which methods exist, what
//! their signatures promise, which call sites produce values worth watching.
//! This module answers the one remaining question -- what the runtime still has
//! to observe -- and writes it where the C extension can find it.
//!
//! The shape is a set of flat lookup tables keyed by NUL-joined tuples. That is
//! deliberate: the collector consults them from inside a TracePoint handler,
//! where the only affordable operation is a hash lookup on data the VM already
//! has (a path, a line, a class and method name).
//!
//! Ported from nil-kill's `trace_plan.rb`. Its output is the contract, so the
//! tests compare against what that file produces on the real corpora.

use crate::sorbet_sig;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

/// Tables are keyed by NUL-joined tuples so the collector can build a lookup
/// key by concatenation, without parsing, inside a trace handler.
const SEP: char = '\0';

fn key(parts: &[&str]) -> String {
    parts.join(&SEP.to_string())
}

fn text(value: Option<&Value>) -> String {
    value.and_then(Value::as_str).unwrap_or("").to_string()
}

fn integer(value: Option<&Value>) -> i64 {
    value
        .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        .unwrap_or(0)
}

fn array(value: Option<&Value>) -> &[Value] {
    value.and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

fn absolute(path: &str, root: &Path) -> String {
    let candidate = Path::new(path);
    if candidate.is_absolute() {
        candidate.to_string_lossy().into_owned()
    } else {
        root.join(candidate).to_string_lossy().into_owned()
    }
}

/// A signature that promises nothing back has no return worth sampling.
fn void_signature(signature: &str) -> bool {
    signature
        .match_indices("void")
        .any(|(idx, _)| {
            let before = signature[..idx].chars().next_back();
            let after = signature[idx + 4..].chars().next();
            let boundary = |c: Option<char>| !c.is_some_and(|c| c.is_alphanumeric() || c == '_');
            boundary(before) && boundary(after)
        })
}

/// The narrow slice of static facts the collector is allowed to see. It
/// deliberately excludes CFG/DFG, protocol, shape, alias, call-graph and
/// pressure facts: the collector receives opaque source anchors that FactMine
/// selected, never the reasoning behind them.
const FACT_KEYS: [&str; 7] = [
    "tlet_sites",
    "struct_declarations",
    "state_type_records",
    "type_definitions",
    "runtime_call_sites",
    "runtime_result_call_sites",
    "runtime_collection_receiver_sites",
];

/// Reshape raw `profile trace-plan` output into what [`TracePlan::build`] reads.
///
/// A struct declaration may name its class unqualified (`Point` for
/// `Geometry::Point`), while the runtime looks the class up by its qualified
/// name. Both spellings are kept: the unqualified one stays sampled, and the
/// qualified one carries the enforceable field types, so a lookup tries the
/// qualified class first and falls back to suffixes.
pub fn reshape_static_facts(raw: &Value, root: &Path) -> Value {
    let mut facts = Map::new();
    for key in FACT_KEYS {
        facts.insert(key.to_string(), raw.get(key).cloned().unwrap_or(Value::Null));
    }
    let declarations = array(raw.get("struct_declarations")).to_vec();
    let mut resolved = declarations.clone();
    resolve_struct_declaration_classes(
        &mut resolved,
        array(raw.get("type_definitions")),
        array(raw.get("methods")),
        root,
    );
    // The unqualified entry keeps no field types, so it stays conservative.
    let mut both: Vec<Value> = declarations
        .into_iter()
        .map(|mut decl| {
            if let Some(object) = decl.as_object_mut() {
                object.insert("field_types".to_string(), json!({}));
            }
            decl
        })
        .collect();
    both.extend(resolved);
    facts.insert("struct_declarations".to_string(), Value::Array(both));

    json!({
        "methods": raw.get("methods").cloned().unwrap_or_else(|| json!([])),
        "fields": raw.get("fields").cloned().unwrap_or_else(|| json!([])),
        "facts": Value::Object(facts),
    })
}

/// Rewrite each unqualified declaration class to its fully-qualified name when
/// the file says unambiguously what that is.
fn resolve_struct_declaration_classes(
    declarations: &mut [Value],
    type_definitions: &[Value],
    methods: &[Value],
    root: &Path,
) {
    let normalize = |path: &str| -> String {
        if path.is_empty() {
            String::new()
        } else {
            absolute(path, root)
        }
    };

    let mut qualified: BTreeMap<(String, String), String> = BTreeMap::new();
    let mut by_path: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for definition in type_definitions {
        let owner = text(definition.get("owner"));
        if owner.is_empty() {
            continue;
        }
        let path = normalize(&text(definition.get("path")));
        let kind = text(definition.get("kind"));
        if kind == "state_field" || kind == "method_signature" {
            let unqualified = owner.rsplit("::").next().unwrap_or(&owner).to_string();
            qualified.insert((path.clone(), unqualified), owner.clone());
        }
        by_path.entry(path).or_default().insert(owner);
    }
    for method in methods {
        let owner = text(method.get("owner"));
        if owner.is_empty() {
            continue;
        }
        by_path
            .entry(normalize(&text(method.get("path"))))
            .or_default()
            .insert(owner);
    }

    for declaration in declarations {
        let name = text(declaration.get("class"));
        if name.contains("::") {
            continue;
        }
        let path = normalize(&text(declaration.get("path")));
        let resolved = qualified.get(&(path.clone(), name.clone())).cloned().or_else(|| {
            // Nothing declared it here by name, so accept a suffix match only
            // when exactly one owner in this file could be meant.
            let suffix = format!("::{name}");
            let mut candidates = by_path
                .get(&path)
                .into_iter()
                .flatten()
                .filter(|owner| owner.ends_with(&suffix));
            let first = candidates.next()?;
            candidates.next().is_none().then(|| first.clone())
        });
        if let Some(resolved) = resolved {
            if let Some(object) = declaration.as_object_mut() {
                object.insert("class".to_string(), Value::String(resolved));
            }
        }
    }
}

/// What the runtime must watch, accumulated as facts arrive.
#[derive(Default)]
pub struct TracePlan {
    methods: BTreeMap<String, Value>,
    tlets: BTreeMap<String, Value>,
    struct_fields: BTreeMap<String, bool>,
    state_write_site_owners: BTreeMap<String, String>,
    runtime_call_sites: BTreeMap<String, SiteDemand>,
    runtime_result_call_sites: BTreeMap<String, SiteDemand>,
    runtime_collection_receiver_sites: BTreeMap<String, SiteDemand>,
    runtime_native_activation_sites: BTreeMap<String, SiteDemand>,
}

/// A site either wants every call on its line, or only named selectors.
/// "Everything" wins permanently once claimed -- a narrower later demand must
/// not shrink it.
#[derive(Debug, Clone, PartialEq, Eq)]
enum SiteDemand {
    Everything,
    Selectors(BTreeSet<String>),
}

impl SiteDemand {
    fn to_value(&self) -> Value {
        match self {
            SiteDemand::Everything => Value::Bool(true),
            SiteDemand::Selectors(names) => {
                Value::Array(names.iter().map(|n| Value::String(n.clone())).collect())
            }
        }
    }
}

fn demand(index: &mut BTreeMap<String, SiteDemand>, key: String, selector: &str) {
    match index.get_mut(&key) {
        Some(SiteDemand::Everything) => {}
        Some(SiteDemand::Selectors(names)) => {
            if selector.is_empty() {
                index.insert(key, SiteDemand::Everything);
            } else {
                names.insert(selector.to_string());
            }
        }
        None => {
            let value = if selector.is_empty() {
                SiteDemand::Everything
            } else {
                SiteDemand::Selectors(BTreeSet::from([selector.to_string()]))
            };
            index.insert(key, value);
        }
    }
}

impl TracePlan {
    pub fn new() -> Self {
        Self::default()
    }

    /// Build from `profile trace-plan` output plus the runtime evidence plan.
    pub fn build(static_facts: &Value, root: &Path) -> Self {
        let mut plan = Self::new();
        for method in array(static_facts.get("methods")) {
            plan.add_static_method(method, root);
        }
        let facts = static_facts.get("facts").cloned().unwrap_or_else(|| json!({}));

        // A T.let at a line supplies the declared type for a field written
        // there, so these are collected before the fields that consult them.
        let mut tlet_types: BTreeMap<(String, i64), String> = BTreeMap::new();
        for site in array(facts.get("tlet_sites")) {
            plan.add_tlet(site, root);
            tlet_types.insert(
                (
                    absolute(&text(site.get("path")), root),
                    integer(site.get("line")),
                ),
                text(site.get("type")),
            );
        }
        for decl in array(facts.get("struct_declarations")) {
            plan.add_struct_decl(decl);
        }
        for site in array(facts.get("runtime_call_sites")) {
            plan.add_runtime_value_site(SiteKind::Call, site, root);
        }
        for site in array(facts.get("runtime_result_call_sites")) {
            plan.add_runtime_value_site(SiteKind::Result, site, root);
        }
        for site in array(facts.get("runtime_collection_receiver_sites")) {
            plan.add_runtime_value_site(SiteKind::CollectionReceiver, site, root);
        }
        for field in array(static_facts.get("fields")) {
            plan.add_static_field(field, &tlet_types, root);
        }
        for field in array(facts.get("state_type_records")) {
            plan.add_static_state_type(field);
        }
        // Flow-derived state records are conservative and may report T.untyped
        // for a field whose declaration is already strong. The declaration is
        // the enforceable contract, so it is applied last and suppresses the
        // redundant sampling.
        for definition in array(facts.get("type_definitions")) {
            plan.add_static_type_definition(definition);
        }
        plan
    }

    fn add_static_method(&mut self, method: &Value, root: &Path) {
        let signature = text(method.get("signature"));
        let param_types: BTreeMap<String, String> =
            sorbet_sig::param_entries(&signature).into_iter().collect();
        let untraceable: BTreeSet<String> = array(method.get("untraceable_params"))
            .iter()
            .map(|v| text(Some(v)))
            .collect();

        let mut params = Map::new();
        for name in array(method.get("params")) {
            let name = text(Some(name));
            if untraceable.contains(&name) {
                continue;
            }
            let declared = param_types.get(&name).map(String::as_str).unwrap_or("");
            params.insert(name, Value::Bool(!sorbet_sig::strong_trace_type(declared)));
        }
        let return_type = sorbet_sig::return_type(&signature).unwrap_or("");
        let sample_return =
            !void_signature(&signature) && !sorbet_sig::strong_trace_type(return_type);
        let sample_method = params.values().any(|v| v == &Value::Bool(true)) || sample_return;

        let name = text(method.get("name"));
        let name = name.strip_prefix("self.").unwrap_or(&name).to_string();
        let entry_key = key(&[
            &text(method.get("owner")),
            &name,
            &method_kind(method),
            &absolute(&text(method.get("path")), root),
            &integer(method.get("line")).to_string(),
        ]);
        self.methods.insert(
            entry_key,
            json!({
                "frame": sample_method,
                "params": Value::Object(params),
                "return": sample_return,
                "sample": sample_method,
            }),
        );
    }

    fn add_tlet(&mut self, site: &Value, root: &Path) {
        if !site.get("tlet").and_then(Value::as_bool).unwrap_or(false) {
            return;
        }
        if sorbet_sig::strong_trace_type(&text(site.get("type"))) {
            return;
        }
        let entry = key(&[
            &absolute(&text(site.get("path")), root),
            &integer(site.get("line")).to_string(),
        ]);
        self.tlets.insert(entry, Value::Bool(true));
    }

    /// FactMine has already chosen these semantic source ranges. TracePoint
    /// reports a line rather than an AST, so the span is expanded into opaque
    /// per-line lookup keys. No syntax or flow interpretation happens here.
    fn add_runtime_value_site(&mut self, kind: SiteKind, site: &Value, root: &Path) {
        let path = text(site.get("path"));
        let span = array(site.get("span"));
        if path.is_empty() || span.len() != 4 {
            return;
        }
        let activation = array(site.get("activation_span"));
        let activation = if activation.len() == 4 { activation } else { span };
        let activation_line = integer(activation.first())
            .min(integer(activation.get(2)));
        let selector = text(site.get("selector"));
        let first = integer(span.first()).min(integer(span.get(2)));
        let last = integer(span.first()).max(integer(span.get(2)));
        let absolute_path = absolute(&path, root);

        // FactMine may select an enclosing line to arm a native call before a
        // multiline expression begins; Ruby then emits later :line events
        // inside that expression. Repeating the selector window on every
        // capture-span line keeps those events from disarming the capture.
        let mut activation_lines = vec![activation_line];
        activation_lines.extend(first..=last);
        activation_lines.dedup();
        for line in activation_lines {
            demand(
                &mut self.runtime_native_activation_sites,
                key(&[&absolute_path, &line.to_string()]),
                &selector,
            );
        }

        let index = match kind {
            SiteKind::Call => &mut self.runtime_call_sites,
            SiteKind::Result => &mut self.runtime_result_call_sites,
            SiteKind::CollectionReceiver => &mut self.runtime_collection_receiver_sites,
        };
        for line in first..=last {
            demand(index, key(&[&absolute_path, &line.to_string()]), &selector);
        }
    }

    fn add_struct_decl(&mut self, decl: &Value) {
        let field_types = decl.get("field_types").and_then(Value::as_object);
        for field in array(decl.get("fields")) {
            let field = text(Some(field));
            let declared = field_types
                .and_then(|types| types.get(&field))
                .map(|v| text(Some(v)))
                .unwrap_or_default();
            self.struct_fields.insert(
                key(&[&text(decl.get("class")), &field]),
                declared.is_empty() || !sorbet_sig::strong_trace_type(&declared),
            );
        }
    }

    fn add_static_state_type(&mut self, field: &Value) {
        let owner = text(field.get("owner"));
        let name = text(field.get("field"));
        let name = name.strip_prefix('@').unwrap_or(&name).to_string();
        let declared = text(field.get("declared_type"));
        if owner.is_empty() || name.is_empty() || declared.is_empty() {
            return;
        }
        self.struct_fields.insert(
            key(&[&owner, &name]),
            !sorbet_sig::strong_trace_type(&declared),
        );
    }

    fn add_static_type_definition(&mut self, definition: &Value) {
        if text(definition.get("kind")) != "state_field" {
            return;
        }
        let owner = text(definition.get("owner"));
        let name = text(definition.get("name"));
        let name = name.strip_prefix('@').unwrap_or(&name).to_string();
        let declared = text(definition.get("declared_type"));
        if owner.is_empty() || name.is_empty() || declared.is_empty() {
            return;
        }
        self.struct_fields.insert(
            key(&[&owner, &name]),
            !sorbet_sig::strong_trace_type(&declared),
        );
    }

    fn add_static_field(
        &mut self,
        field: &Value,
        tlet_types: &BTreeMap<(String, i64), String>,
        root: &Path,
    ) {
        let owner = text(field.get("owner"));
        let raw_name = if field.get("name").is_some() {
            text(field.get("name"))
        } else {
            text(field.get("field"))
        };
        let name = raw_name.strip_prefix('@').unwrap_or(&raw_name).to_string();
        let path = absolute(&text(field.get("path")), root);
        let line = integer(field.get("line"));
        if !owner.is_empty() && !name.is_empty() {
            self.state_write_site_owners.insert(
                key(&[&path, &line.to_string(), &name]),
                key(&[&owner, &name]),
            );
        }
        let mut declared = text(field.get("declared_type"));
        if declared.is_empty() {
            declared = tlet_types
                .get(&(path, line))
                .cloned()
                .unwrap_or_default();
        }
        if owner.is_empty() || name.is_empty() || declared.is_empty() {
            return;
        }
        self.struct_fields.insert(
            key(&[&owner, &name]),
            !sorbet_sig::strong_trace_type(&declared),
        );
    }

    /// Exact source sites let the collector skip a state slot whose final
    /// enforceable contract is strong. A site with no known owner is absent
    /// rather than false, and therefore stays sampled.
    fn state_write_sites(&self) -> Map<String, Value> {
        self.state_write_site_owners
            .iter()
            .map(|(site, owner)| {
                (
                    site.clone(),
                    Value::Bool(*self.struct_fields.get(owner).unwrap_or(&true)),
                )
            })
            .collect()
    }

    /// The document the collector reads. `generated_at` is supplied rather than
    /// read from the clock so the output is reproducible and testable.
    pub fn document(
        &self,
        generated_at: &str,
        target_dirs: &[String],
        target_exclude_dirs: &[String],
        runtime_evidence: Value,
    ) -> Value {
        let sites = |index: &BTreeMap<String, SiteDemand>| -> Value {
            Value::Object(
                index
                    .iter()
                    .map(|(key, demand)| (key.clone(), demand.to_value()))
                    .collect(),
            )
        };
        let mut dirs = target_dirs.to_vec();
        dirs.sort();
        let mut excludes = target_exclude_dirs.to_vec();
        excludes.sort();
        json!({
            "version": 1,
            "generated_at": generated_at,
            "target_dirs": dirs,
            "target_exclude_dirs": excludes,
            "methods": Value::Object(self.methods.clone().into_iter().collect()),
            "tlets": Value::Object(self.tlets.clone().into_iter().collect()),
            "struct_fields": Value::Object(
                self.struct_fields
                    .iter()
                    .map(|(k, v)| (k.clone(), Value::Bool(*v)))
                    .collect()
            ),
            "state_write_sites": Value::Object(self.state_write_sites()),
            "runtime_call_sites": sites(&self.runtime_call_sites),
            "runtime_result_call_sites": sites(&self.runtime_result_call_sites),
            "runtime_collection_receiver_sites": sites(&self.runtime_collection_receiver_sites),
            "runtime_native_activation_sites": sites(&self.runtime_native_activation_sites),
            // Public FactMine <-> collector contract. Everything else in this
            // document is private instrumentation control.
            "runtime_evidence": runtime_evidence,
        })
    }
}

#[derive(Clone, Copy)]
enum SiteKind {
    Call,
    Result,
    CollectionReceiver,
}

/// A name spelled `self.x` is a class method whatever the record claims, and a
/// callable with no owner is a bare function.
fn method_kind(method: &Value) -> String {
    let raw = text(method.get("kind"));
    let name = text(method.get("name"));
    if name.starts_with("self.") || raw == "class" || raw == "class_method" {
        return "class".to_string();
    }
    if raw == "function" || text(method.get("owner")).is_empty() {
        return "function".to_string();
    }
    "instance".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> &'static Path {
        Path::new("/repo")
    }

    fn plan_from(facts: Value) -> Value {
        TracePlan::build(&facts, root()).document("t", &[], &[], Value::Null)
    }

    #[test]
    fn a_parameter_the_signature_already_pins_is_not_sampled() {
        let plan = plan_from(json!({
            "methods": [{
                "owner": "Foo", "name": "bar", "kind": "instance",
                "path": "lib/foo.rb", "line": 3,
                "params": ["a", "b"],
                "signature": "sig { params(a: String, b: T.untyped).returns(Integer) }"
            }]
        }));
        let entry = &plan["methods"]["Foo\u{0}bar\u{0}instance\u{0}/repo/lib/foo.rb\u{0}3"];
        assert_eq!(entry["params"]["a"], json!(false), "String is enough");
        assert_eq!(entry["params"]["b"], json!(true), "T.untyped must be watched");
        assert_eq!(entry["return"], json!(false), "Integer is enough");
        assert_eq!(entry["sample"], json!(true), "one weak param is enough to sample");
        assert_eq!(entry["frame"], json!(true));
    }

    #[test]
    fn a_method_that_promises_nothing_weak_is_not_sampled_at_all() {
        let plan = plan_from(json!({
            "methods": [{
                "owner": "Foo", "name": "bar", "kind": "instance",
                "path": "lib/foo.rb", "line": 1,
                "params": ["a"],
                "signature": "sig { params(a: String).returns(Integer) }"
            }]
        }));
        let entry = &plan["methods"]["Foo\u{0}bar\u{0}instance\u{0}/repo/lib/foo.rb\u{0}1"];
        assert_eq!(entry["sample"], json!(false));
        assert_eq!(entry["frame"], json!(false));
    }

    #[test]
    fn a_void_signature_has_no_return_to_sample() {
        let plan = plan_from(json!({
            "methods": [{
                "owner": "Foo", "name": "bar", "kind": "instance",
                "path": "lib/foo.rb", "line": 1, "params": [],
                "signature": "sig { params(a: String).void }"
            }]
        }));
        let entry = &plan["methods"]["Foo\u{0}bar\u{0}instance\u{0}/repo/lib/foo.rb\u{0}1"];
        assert_eq!(entry["return"], json!(false));
        assert_eq!(entry["sample"], json!(false));
    }

    #[test]
    fn an_untraceable_parameter_is_dropped_rather_than_sampled() {
        let plan = plan_from(json!({
            "methods": [{
                "owner": "Foo", "name": "bar", "kind": "instance",
                "path": "lib/foo.rb", "line": 1,
                "params": ["blk", "a"],
                "untraceable_params": ["blk"],
                "signature": "sig { params(a: T.untyped).void }"
            }]
        }));
        let entry = &plan["methods"]["Foo\u{0}bar\u{0}instance\u{0}/repo/lib/foo.rb\u{0}1"];
        assert!(entry["params"].get("blk").is_none());
        assert_eq!(entry["params"]["a"], json!(true));
    }

    #[test]
    fn a_self_prefixed_name_is_a_class_method_and_loses_the_prefix() {
        let plan = plan_from(json!({
            "methods": [{
                "owner": "Foo", "name": "self.build", "kind": "instance",
                "path": "lib/foo.rb", "line": 2, "params": [], "signature": ""
            }]
        }));
        assert!(plan["methods"]
            .get("Foo\u{0}build\u{0}class\u{0}/repo/lib/foo.rb\u{0}2")
            .is_some());
    }

    #[test]
    fn a_callable_without_an_owner_is_a_function() {
        let plan = plan_from(json!({
            "methods": [{
                "owner": "", "name": "helper", "kind": "",
                "path": "lib/foo.rb", "line": 5, "params": [], "signature": ""
            }]
        }));
        assert!(plan["methods"]
            .get("\u{0}helper\u{0}function\u{0}/repo/lib/foo.rb\u{0}5")
            .is_some());
    }

    #[test]
    fn a_span_arms_every_line_it_covers() {
        let plan = plan_from(json!({
            "facts": { "runtime_call_sites": [
                { "path": "lib/a.rb", "span": [4, 0, 6, 9], "selector": "map" }
            ]}
        }));
        for line in 4..=6 {
            assert_eq!(
                plan["runtime_call_sites"][format!("/repo/lib/a.rb\u{0}{line}")],
                json!(["map"]),
                "line {line}"
            );
        }
        assert!(plan["runtime_call_sites"]
            .get("/repo/lib/a.rb\u{0}7")
            .is_none());
    }

    #[test]
    fn an_empty_selector_claims_the_whole_line_and_a_later_one_cannot_narrow_it() {
        let plan = plan_from(json!({
            "facts": { "runtime_call_sites": [
                { "path": "lib/a.rb", "span": [4, 0, 4, 9], "selector": "" },
                { "path": "lib/a.rb", "span": [4, 0, 4, 9], "selector": "map" }
            ]}
        }));
        assert_eq!(plan["runtime_call_sites"]["/repo/lib/a.rb\u{0}4"], json!(true));
    }

    #[test]
    fn selectors_on_one_line_accumulate_and_are_sorted() {
        let plan = plan_from(json!({
            "facts": { "runtime_call_sites": [
                { "path": "lib/a.rb", "span": [4, 0, 4, 9], "selector": "map" },
                { "path": "lib/a.rb", "span": [4, 0, 4, 9], "selector": "each" }
            ]}
        }));
        assert_eq!(
            plan["runtime_call_sites"]["/repo/lib/a.rb\u{0}4"],
            json!(["each", "map"])
        );
    }

    #[test]
    fn an_activation_span_arms_the_line_that_starts_the_expression() {
        let plan = plan_from(json!({
            "facts": { "runtime_call_sites": [
                {
                    "path": "lib/a.rb", "span": [6, 0, 6, 9],
                    "activation_span": [4, 0, 4, 2], "selector": "map"
                }
            ]}
        }));
        assert_eq!(
            plan["runtime_native_activation_sites"]["/repo/lib/a.rb\u{0}4"],
            json!(["map"]),
            "the enclosing line is armed"
        );
        assert!(
            plan["runtime_call_sites"].get("/repo/lib/a.rb\u{0}4").is_none(),
            "but the capture itself stays on its own span"
        );
    }

    #[test]
    fn a_site_without_a_four_element_span_is_ignored() {
        let plan = plan_from(json!({
            "facts": { "runtime_call_sites": [
                { "path": "lib/a.rb", "span": [4, 0], "selector": "map" },
                { "path": "", "span": [4, 0, 4, 9], "selector": "map" }
            ]}
        }));
        assert_eq!(plan["runtime_call_sites"], json!({}));
    }

    #[test]
    fn the_three_site_kinds_stay_in_their_own_tables() {
        let plan = plan_from(json!({
            "facts": {
                "runtime_call_sites": [{ "path": "a.rb", "span": [1,0,1,1], "selector": "x" }],
                "runtime_result_call_sites": [{ "path": "a.rb", "span": [2,0,2,1], "selector": "y" }],
                "runtime_collection_receiver_sites": [{ "path": "a.rb", "span": [3,0,3,1], "selector": "z" }]
            }
        }));
        assert_eq!(plan["runtime_call_sites"]["/repo/a.rb\u{0}1"], json!(["x"]));
        assert_eq!(plan["runtime_result_call_sites"]["/repo/a.rb\u{0}2"], json!(["y"]));
        assert_eq!(
            plan["runtime_collection_receiver_sites"]["/repo/a.rb\u{0}3"],
            json!(["z"])
        );
    }

    #[test]
    fn a_struct_field_is_sampled_unless_its_declaration_is_strong() {
        let plan = plan_from(json!({
            "facts": { "struct_declarations": [{
                "class": "Point",
                "fields": ["x", "y", "z"],
                "field_types": { "x": "Integer", "y": "T.untyped" }
            }]}
        }));
        assert_eq!(plan["struct_fields"]["Point\u{0}x"], json!(false));
        assert_eq!(plan["struct_fields"]["Point\u{0}y"], json!(true));
        assert_eq!(plan["struct_fields"]["Point\u{0}z"], json!(true), "undeclared");
    }

    #[test]
    fn a_field_takes_its_type_from_a_t_let_on_the_same_line() {
        let plan = plan_from(json!({
            "fields": [{ "owner": "Foo", "name": "@bar", "path": "lib/foo.rb", "line": 7 }],
            "facts": { "tlet_sites": [
                { "path": "lib/foo.rb", "line": 7, "type": "String", "tlet": true }
            ]}
        }));
        assert_eq!(plan["struct_fields"]["Foo\u{0}bar"], json!(false));
    }

    #[test]
    fn a_strong_t_let_is_not_recorded_as_needing_a_sample() {
        let plan = plan_from(json!({
            "facts": { "tlet_sites": [
                { "path": "a.rb", "line": 1, "type": "String", "tlet": true },
                { "path": "a.rb", "line": 2, "type": "T.untyped", "tlet": true },
                { "path": "a.rb", "line": 3, "type": "T.untyped", "tlet": false }
            ]}
        }));
        assert!(plan["tlets"].get("/repo/a.rb\u{0}1").is_none());
        assert_eq!(plan["tlets"]["/repo/a.rb\u{0}2"], json!(true));
        assert!(plan["tlets"].get("/repo/a.rb\u{0}3").is_none(), "not a T.let");
    }

    #[test]
    fn a_declaration_applied_last_suppresses_a_conservative_flow_record() {
        // state_type_records and type_definitions both name Foo#bar; the
        // declaration is the enforceable contract and must win.
        let plan = plan_from(json!({
            "facts": {
                "state_type_records": [
                    { "owner": "Foo", "field": "@bar", "declared_type": "T.untyped" }
                ],
                "type_definitions": [
                    { "kind": "state_field", "owner": "Foo", "name": "@bar", "declared_type": "String" }
                ]
            }
        }));
        assert_eq!(plan["struct_fields"]["Foo\u{0}bar"], json!(false));
    }

    #[test]
    fn a_type_definition_that_is_not_a_state_field_is_ignored() {
        let plan = plan_from(json!({
            "facts": { "type_definitions": [
                { "kind": "method", "owner": "Foo", "name": "@bar", "declared_type": "String" }
            ]}
        }));
        assert_eq!(plan["struct_fields"], json!({}));
    }

    #[test]
    fn a_write_site_reports_whether_its_owning_slot_is_sampled() {
        let plan = plan_from(json!({
            "fields": [
                { "owner": "Foo", "name": "@strong", "path": "a.rb", "line": 1,
                  "declared_type": "String" },
                { "owner": "Foo", "name": "@weak", "path": "a.rb", "line": 2,
                  "declared_type": "T.untyped" }
            ]
        }));
        assert_eq!(plan["state_write_sites"]["/repo/a.rb\u{0}1\u{0}strong"], json!(false));
        assert_eq!(plan["state_write_sites"]["/repo/a.rb\u{0}2\u{0}weak"], json!(true));
    }

    #[test]
    fn a_write_site_whose_owner_is_unknown_stays_sampled() {
        // No declared type anywhere, so struct_fields never learns the slot.
        let plan = plan_from(json!({
            "fields": [{ "owner": "Foo", "name": "@mystery", "path": "a.rb", "line": 4 }]
        }));
        assert_eq!(plan["state_write_sites"]["/repo/a.rb\u{0}4\u{0}mystery"], json!(true));
        assert!(plan["struct_fields"].get("Foo\u{0}mystery").is_none());
    }

    #[test]
    fn an_absolute_path_in_the_facts_is_left_alone() {
        let plan = plan_from(json!({
            "facts": { "tlet_sites": [
                { "path": "/elsewhere/a.rb", "line": 1, "type": "T.untyped", "tlet": true }
            ]}
        }));
        assert_eq!(plan["tlets"]["/elsewhere/a.rb\u{0}1"], json!(true));
    }

    #[test]
    fn the_document_sorts_target_dirs_and_passes_the_evidence_plan_through() {
        let plan = TracePlan::new().document(
            "2026-01-01T00:00:00Z",
            &["/b".to_string(), "/a".to_string()],
            &["/z".to_string()],
            json!({ "plan_digest": "abc" }),
        );
        assert_eq!(plan["version"], json!(1));
        assert_eq!(plan["generated_at"], json!("2026-01-01T00:00:00Z"));
        assert_eq!(plan["target_dirs"], json!(["/a", "/b"]));
        assert_eq!(plan["target_exclude_dirs"], json!(["/z"]));
        assert_eq!(plan["runtime_evidence"]["plan_digest"], json!("abc"));
    }


    // --- reshaping raw facts --------------------------------------------------

    #[test]
    fn an_unqualified_declaration_gains_the_name_its_file_declares() {
        let raw = json!({
            "struct_declarations": [
                { "class": "Point", "path": "lib/geo.rb", "fields": ["x"],
                  "field_types": { "x": "Integer" } }
            ],
            "type_definitions": [
                { "kind": "state_field", "owner": "Geometry::Point", "path": "lib/geo.rb",
                  "name": "@x", "declared_type": "Integer" }
            ]
        });
        let reshaped = reshape_static_facts(&raw, root());
        let declarations = array(reshaped["facts"].get("struct_declarations"));
        assert_eq!(declarations.len(), 2, "both spellings are kept");
        assert_eq!(declarations[0]["class"], json!("Point"));
        assert_eq!(
            declarations[0]["field_types"],
            json!({}),
            "the unqualified entry stays conservative"
        );
        assert_eq!(declarations[1]["class"], json!("Geometry::Point"));
        assert_eq!(declarations[1]["field_types"]["x"], json!("Integer"));

        // And the conservative entry must not undo the qualified one.
        let plan = TracePlan::build(&reshaped, root()).document("t", &[], &[], Value::Null);
        assert_eq!(plan["struct_fields"]["Point\u{0}x"], json!(true));
        assert_eq!(plan["struct_fields"]["Geometry::Point\u{0}x"], json!(false));
    }

    #[test]
    fn an_ambiguous_suffix_is_left_unqualified() {
        let raw = json!({
            "struct_declarations": [{ "class": "Point", "path": "lib/geo.rb", "fields": [] }],
            "type_definitions": [
                { "kind": "method", "owner": "A::Point", "path": "lib/geo.rb" },
                { "kind": "method", "owner": "B::Point", "path": "lib/geo.rb" }
            ]
        });
        let reshaped = reshape_static_facts(&raw, root());
        let declarations = array(reshaped["facts"].get("struct_declarations"));
        assert_eq!(declarations[1]["class"], json!("Point"), "two candidates, so neither");
    }

    #[test]
    fn a_lone_suffix_match_resolves_even_without_a_declaring_kind() {
        let raw = json!({
            "struct_declarations": [{ "class": "Point", "path": "lib/geo.rb", "fields": [] }],
            "methods": [{ "owner": "Geometry::Point", "path": "lib/geo.rb" }]
        });
        let reshaped = reshape_static_facts(&raw, root());
        assert_eq!(
            array(reshaped["facts"].get("struct_declarations"))[1]["class"],
            json!("Geometry::Point")
        );
    }

    #[test]
    fn an_already_qualified_declaration_is_left_alone() {
        let raw = json!({
            "struct_declarations": [{ "class": "Other::Point", "path": "lib/geo.rb", "fields": [] }],
            "type_definitions": [
                { "kind": "state_field", "owner": "Geometry::Point", "path": "lib/geo.rb" }
            ]
        });
        let reshaped = reshape_static_facts(&raw, root());
        assert_eq!(
            array(reshaped["facts"].get("struct_declarations"))[1]["class"],
            json!("Other::Point")
        );
    }

    #[test]
    fn a_declaration_in_another_file_does_not_qualify_this_one() {
        let raw = json!({
            "struct_declarations": [{ "class": "Point", "path": "lib/a.rb", "fields": [] }],
            "type_definitions": [
                { "kind": "state_field", "owner": "Geometry::Point", "path": "lib/b.rb" }
            ]
        });
        let reshaped = reshape_static_facts(&raw, root());
        assert_eq!(
            array(reshaped["facts"].get("struct_declarations"))[1]["class"],
            json!("Point")
        );
    }

    #[test]
    fn reshaping_forwards_only_the_facts_the_collector_may_see() {
        let raw = json!({
            "methods": [{ "owner": "A" }],
            "fields": [{ "owner": "A" }],
            "tlet_sites": [{ "path": "a.rb" }],
            "call_graph": [{ "secret": true }],
            "pressure_facts": [{ "secret": true }]
        });
        let reshaped = reshape_static_facts(&raw, root());
        let facts = reshaped["facts"].as_object().expect("facts");
        assert!(facts.contains_key("tlet_sites"));
        assert!(!facts.contains_key("call_graph"), "CFG/DFG facts stay out");
        assert!(!facts.contains_key("pressure_facts"));
        assert_eq!(facts.len(), FACT_KEYS.len());
        assert_eq!(reshaped["methods"], raw["methods"]);
        assert_eq!(reshaped["fields"], raw["fields"]);
    }

    #[test]
    fn void_is_matched_as_a_word_not_a_substring() {
        assert!(void_signature("sig { void }"));
        assert!(void_signature("sig { params(a: X).void }"));
        assert!(!void_signature("sig { returns(Avoidance) }"));
        assert!(!void_signature("sig { returns(T::Array[Void_]) }"));
    }
}
