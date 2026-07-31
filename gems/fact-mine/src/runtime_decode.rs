//! Reading what a language runtime observed into the shape evidence expects.
//!
//! A native collector writes what it saw in the terms its own VM uses: a class
//! object's name, a receiver's type, the file a method was defined in. Evidence
//! is written in SCIP's terms: descriptors, package coordinates, source roles,
//! paths relative to the repository. This module is the translation, and it is
//! mechanical -- it renames and regroups, and infers nothing. Flow analysis
//! belongs to FactMine.
//!
//! Ported from nil-kill's `runtime_value_evidence.rb`. Nothing here touches a
//! VM: the input is files the collector already wrote, so the translation does
//! not need to run inside the traced process, and once it does not, the traced
//! process needs no library code beyond the native collector itself.
//!
//! The same split works for any language: only how a type is named and how a
//! container is enumerated are language-specific, and both are decided inside
//! the collector, where the VM is.

use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::{Component, Path, PathBuf};

fn text(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        Some(Value::Bool(b)) => b.to_string(),
        _ => String::new(),
    }
}

fn integer(value: Option<&Value>) -> i64 {
    value
        .and_then(|v| v.as_i64().or_else(|| v.as_str().and_then(|s| s.parse().ok())))
        .unwrap_or(0)
}

fn array(value: Option<&Value>) -> &[Value] {
    value.and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[])
}

fn lexically_absolute(path: &str, root: &Path) -> PathBuf {
    let candidate = Path::new(path);
    let joined = if candidate.is_absolute() {
        candidate.to_path_buf()
    } else {
        root.join(candidate)
    };
    // Resolve `.` and `..` without touching the filesystem: the collector may
    // report a path that no longer exists by the time evidence is read.
    let mut parts: Vec<Component> = Vec::new();
    for component in joined.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                if matches!(parts.last(), Some(Component::Normal(_))) {
                    parts.pop();
                } else {
                    parts.push(component);
                }
            }
            other => parts.push(other),
        }
    }
    parts.iter().collect()
}

/// The repository-relative spelling, or the original text when the path lies
/// outside the repository entirely.
pub fn relative_path(path: &str, root: &Path) -> String {
    if path.is_empty() {
        return String::new();
    }
    let absolute = lexically_absolute(path, root);
    match absolute.strip_prefix(root) {
        Ok(relative) => relative.to_string_lossy().into_owned(),
        Err(_) => path.to_string(),
    }
}

fn inside_root(path: &Path, root: &Path) -> bool {
    path == root || path.starts_with(root)
}

/// A path under a test directory, or named like a test file, is test code
/// whatever mechanism implements it.
fn nonproduction_path(path: &str, root: &Path) -> bool {
    if path.is_empty() {
        return false;
    }
    let absolute = lexically_absolute(path, root);
    let Ok(relative) = absolute.strip_prefix(root) else {
        return false;
    };
    let components: Vec<String> = relative
        .components()
        .map(|c| c.as_os_str().to_string_lossy().into_owned())
        .collect();
    if components
        .iter()
        .any(|part| matches!(part.as_str(), "test" | "tests" | "spec" | "specs"))
    {
        return true;
    }
    components
        .last()
        .is_some_and(|last| last.ends_with("_test.rb") || last.ends_with("_spec.rb"))
}

/// SCIP escapes any word that is not plainly alphanumeric.
pub fn symbol_word(value: &str) -> String {
    if value.is_empty() {
        return ".".to_string();
    }
    if value
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | '+' | '@' | '/' | '-'))
    {
        return value.to_string();
    }
    format!("`{}`", value.replace('`', "``"))
}

/// SCIP's canonical descriptor escaping. Question marks, bangs, equals signs
/// and most Ruby operators are not legal bare names.
pub fn descriptor_name(value: &str) -> String {
    if !value.is_empty()
        && value
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '+' | '$' | '-'))
    {
        return value.to_string();
    }
    format!("`{}`", value.replace('`', "``"))
}

pub fn descriptor_owner(value: &str) -> String {
    value
        .split("::")
        .filter(|part| !part.is_empty())
        .map(descriptor_name)
        .collect::<Vec<_>>()
        .join("/")
}

pub fn runtime_type_symbol(type_name: &str, runtime_version: &str) -> String {
    format!(
        "nil-kill-runtime ruby ruby {runtime_version} {}#",
        descriptor_owner(type_name)
    )
}

pub fn runtime_singleton_symbol(type_name: &str, runtime_version: &str) -> String {
    format!(
        "nil-kill-runtime ruby ruby {runtime_version} {}.",
        descriptor_owner(type_name)
    )
}

fn runtime_symbol(callee: &Value, selector: &str) -> String {
    let word = |key: &str, fallback: &str| {
        let raw = text(callee.get(key));
        symbol_word(if raw.is_empty() { fallback } else { &raw })
    };
    let manager = word("package_manager", "runtime");
    let package = word("package", "ruby");
    let version = word("version", "workspace");
    let owner_raw = {
        let owner = text(callee.get("owner"));
        if owner.is_empty() {
            let receiver = text(callee.get("receiver_type"));
            if receiver.is_empty() { "ruby".to_string() } else { receiver }
        } else {
            owner
        }
    };
    let separator = if text(callee.get("kind")) == "class" { "." } else { "#" };
    format!(
        "nil-kill-runtime {manager} {package} {version} {}{separator}{}().",
        descriptor_owner(&owner_raw),
        descriptor_name(selector)
    )
}

/// Where a call target came from. Provenance dominates mechanism: a C-backed
/// Struct defined in a test is test code, not standard library.
fn target_source_role(callee: &Value, root: &Path) -> String {
    let package = text(callee.get("package"));
    if text(callee.get("source_role")) == "nonproduction" {
        return "NON_PRODUCTION".to_string();
    }
    if matches!(package.as_str(), "minitest" | "mocha" | "rspec-mocks" | "rr") {
        return "NON_PRODUCTION".to_string();
    }
    if nonproduction_path(&text(callee.get("path")), root) {
        return "NON_PRODUCTION".to_string();
    }
    let manager = text(callee.get("package_manager"));
    if manager == "workspace" {
        return "PRODUCTION".to_string();
    }
    if manager == "ruby" {
        return "STANDARD_LIBRARY".to_string();
    }
    if !package.is_empty() {
        return "DEPENDENCY".to_string();
    }
    "UNKNOWN_SOURCE".to_string()
}

fn normalized_range(range: Option<&Value>) -> Option<Value> {
    let range = range?.as_array()?;
    match range.len() {
        4 => Some(Value::Array(range.clone())),
        3 => Some(json!([range[0], range[1], range[0], range[2]])),
        _ => None,
    }
}

fn strings(values: Option<&Value>) -> Vec<String> {
    let mut out: Vec<String> = array(values)
        .iter()
        .map(|v| text(Some(v)))
        .filter(|s| !s.is_empty())
        .collect();
    out.sort();
    out.dedup();
    out
}

/// A shape is either a bare class name or a nested container description.
fn normalize_shape(shape: &Value) -> Option<Value> {
    if let Some(name) = shape.as_str() {
        return Some(json!({ "kind": "class", "name": name }));
    }
    let object = shape.as_object()?;
    let kind = text(object.get("kind"));
    if kind.is_empty() {
        return Some(json!({ "kind": "unknown" }));
    }
    let mut normalized = Map::new();
    normalized.insert("kind".to_string(), Value::String(kind));
    let name = text(object.get("name"));
    if !name.is_empty() {
        normalized.insert("name".to_string(), Value::String(name));
    }
    for key in ["elements", "keys", "values"] {
        let children: Vec<Value> = array(object.get(key))
            .iter()
            .filter_map(normalize_shape)
            .collect();
        if !children.is_empty() {
            normalized.insert(key.to_string(), Value::Array(children));
        }
    }
    let members: Map<String, Value> = object
        .get("members")
        .and_then(Value::as_object)
        .map(|members| {
            members
                .iter()
                .filter_map(|(name, child)| Some((name.clone(), normalize_shape(child)?)))
                .collect()
        })
        .unwrap_or_default();
    if !members.is_empty() {
        normalized.insert("members".to_string(), Value::Object(members));
    }
    Some(Value::Object(normalized))
}

/// `T.untyped` marks absence of identity, not a runtime alternative. Where a
/// shape supplies an exact record identity, it replaces that marker.
fn reconcile_record_slot(domain: &mut Map<String, Value>, slot: &str, shapes: &[Value]) {
    let current = strings(domain.get(slot));
    if !current.iter().any(|s| s == "T.untyped") {
        return;
    }
    let record_names: Vec<String> = shapes
        .iter()
        .filter(|shape| text(shape.get("kind")) == "record")
        .map(|shape| text(shape.get("name")))
        .filter(|name| !name.is_empty())
        .collect();
    if record_names.is_empty() {
        return;
    }
    let mut merged: Vec<String> = current.into_iter().filter(|s| s != "T.untyped").collect();
    for name in record_names {
        if !merged.contains(&name) {
            merged.push(name);
        }
    }
    merged.sort();
    domain.insert(
        slot.to_string(),
        Value::Array(merged.into_iter().map(Value::String).collect()),
    );
}

pub fn domain(
    types: Option<&Value>,
    singletons: Option<&Value>,
    elements: Option<&Value>,
    keys: Option<&Value>,
    values: Option<&Value>,
    shapes: Option<&Value>,
) -> Value {
    let mut normalized_shapes: Vec<Value> = Vec::new();
    for shape in array(shapes) {
        if let Some(shape) = normalize_shape(shape) {
            if !normalized_shapes.contains(&shape) {
                normalized_shapes.push(shape);
            }
        }
    }
    let to_value = |v: Vec<String>| Value::Array(v.into_iter().map(Value::String).collect());
    let mut out = Map::new();
    out.insert("types".to_string(), to_value(strings(types)));
    out.insert("singletons".to_string(), to_value(strings(singletons)));
    out.insert("elements".to_string(), to_value(strings(elements)));
    out.insert("keys".to_string(), to_value(strings(keys)));
    out.insert("values".to_string(), to_value(strings(values)));
    out.insert("shapes".to_string(), Value::Array(normalized_shapes.clone()));

    reconcile_record_slot(&mut out, "types", &normalized_shapes);
    let nested = |key: &str| -> Vec<Value> {
        normalized_shapes
            .iter()
            .flat_map(|shape| array(shape.get(key)).to_vec())
            .collect()
    };
    reconcile_record_slot(&mut out, "elements", &nested("elements"));
    reconcile_record_slot(&mut out, "keys", &nested("keys"));
    reconcile_record_slot(&mut out, "values", &nested("values"));
    Value::Object(out)
}

fn normalized_domain_payload(payload: Option<&Value>) -> Option<Value> {
    let payload = payload?.as_object()?;
    Some(domain(
        payload.get("types"),
        payload.get("singletons"),
        payload.get("elements"),
        payload.get("keys"),
        payload.get("values"),
        payload.get("shapes"),
    ))
}

/// Translate one observed call into the evidence row shape.
pub fn call(event: &Value, root: &Path) -> Value {
    let caller = event.get("caller").cloned().unwrap_or(Value::Null);
    let callsite = event.get("callsite").cloned().unwrap_or(Value::Null);
    let callee = event.get("callee").cloned().unwrap_or(Value::Null);

    let callee_name = text(callee.get("name"));
    // A constructor is observed as `initialize` but is dispatched as `new`.
    let selector = if callee_name == "initialize" { "new".to_string() } else { callee_name.clone() };

    let word = |key: &str, fallback: &str| {
        let raw = text(callee.get(key));
        symbol_word(if raw.is_empty() { fallback } else { &raw })
    };
    let source_role = target_source_role(&callee, root);
    let mut target = Map::new();
    target.insert("symbol".to_string(), Value::String(runtime_symbol(&callee, &selector)));
    target.insert("owner".to_string(), Value::String(text(callee.get("owner"))));
    target.insert("name".to_string(), Value::String(selector.clone()));
    target.insert("kind".to_string(), Value::String(text(callee.get("kind"))));
    target.insert(
        "receiver_type".to_string(),
        Value::String(text(callee.get("receiver_type"))),
    );
    target.insert("source_role".to_string(), Value::String(source_role.clone()));
    target.insert("package_manager".to_string(), Value::String(word("package_manager", "runtime")));
    target.insert("package_name".to_string(), Value::String(word("package", "ruby")));
    target.insert("package_version".to_string(), Value::String(word("version", "workspace")));

    let callee_path = text(callee.get("path"));
    let native = callee.get("native").and_then(Value::as_bool).unwrap_or(false);
    if !native && !callee_path.is_empty() {
        let absolute = lexically_absolute(&callee_path, root);
        if inside_root(&absolute, root) {
            target.insert(
                "definition".to_string(),
                json!({
                    "language": "ruby",
                    "path": relative_path(&callee_path, root),
                    "owner": text(callee.get("owner")),
                    "name": callee_name,
                    "kind": text(callee.get("kind")),
                    "line": integer(callee.get("line")),
                }),
            );
        }
    }

    let mut callsite_row = Map::new();
    callsite_row.insert(
        "path".to_string(),
        Value::String(relative_path(&text(callsite.get("path")), root)),
    );
    callsite_row.insert("line".to_string(), json!(integer(callsite.get("line"))));
    if let Some(range) = normalized_range(callsite.get("range")) {
        callsite_row.insert("range".to_string(), range);
    }
    let selector_text = {
        let raw = text(callsite.get("selector"));
        if raw.is_empty() { text(callee.get("name")) } else { raw }
    };
    callsite_row.insert("selector".to_string(), Value::String(selector_text));
    callsite_row.insert(
        "anchor_symbol".to_string(),
        Value::String(text(callsite.get("anchor_symbol"))),
    );

    // False sorts before true: a call observed both ways reports the falsy
    // witness first, which is the one that matters for nil analysis.
    let mut truths: Vec<bool> = array(event.get("result_truths"))
        .iter()
        .filter_map(Value::as_bool)
        .collect();
    truths.dedup();
    let mut unique: Vec<bool> = Vec::new();
    for truth in truths {
        if !unique.contains(&truth) {
            unique.push(truth);
        }
    }
    unique.sort_by_key(|t| i32::from(*t));

    let mut row = Map::new();
    row.insert("language".to_string(), Value::String("ruby".to_string()));
    row.insert(
        "caller".to_string(),
        json!({
            "language": "ruby",
            "path": relative_path(&text(caller.get("path")), root),
            "owner": text(caller.get("class")),
            "name": text(caller.get("method")),
            "kind": text(caller.get("kind")),
            "line": integer(caller.get("line")),
        }),
    );
    row.insert("callsite".to_string(), Value::Object(callsite_row));
    row.insert("target".to_string(), Value::Object(target));
    if let Some(receiver) = normalized_domain_payload(event.get("receiver_domain")) {
        row.insert("receiver_domain".to_string(), receiver);
    }
    if let Some(result) = normalized_domain_payload(event.get("result_domain")) {
        row.insert("result_domain".to_string(), result);
    }
    row.insert(
        "result_truths".to_string(),
        Value::Array(unique.into_iter().map(Value::Bool).collect()),
    );
    // Receiver and target describe the same dispatch. Giving the receiver a
    // weaker role would let a test double's values contaminate production flow
    // after FactMine correctly filters its NON_PRODUCTION target.
    row.insert(
        "receiver_source_role".to_string(),
        Value::String(if source_role == "NON_PRODUCTION" {
            "NON_PRODUCTION".to_string()
        } else {
            "UNKNOWN_SOURCE".to_string()
        }),
    );
    row.insert("count".to_string(), json!(integer(event.get("count"))));
    Value::Object(row)
}

/// Fuse observations of the same slot, unioning their domains and adding their
/// counts, then order them so the output does not depend on file read order.
pub fn merge_observations(rows: Vec<Value>) -> Vec<Value> {
    let mut grouped: BTreeMap<String, Value> = BTreeMap::new();
    let mut order: Vec<String> = Vec::new();
    for row in rows {
        let group = format!(
            "{}\u{0}{}\u{0}{}\u{0}{}",
            text(row.get("kind")),
            serde_json::to_string(row.get("scope").unwrap_or(&Value::Null)).unwrap_or_default(),
            text(row.get("slot")),
            text(row.get("slot_kind"))
        );
        match grouped.get_mut(&group) {
            None => {
                order.push(group.clone());
                grouped.insert(group, row);
            }
            Some(first) => {
                let addition = integer(row.get("count"));
                for field in ["types", "singletons", "elements", "keys", "values", "shapes"] {
                    let mut merged = array(first.pointer(&format!("/domain/{field}"))).to_vec();
                    for value in array(row.pointer(&format!("/domain/{field}"))) {
                        if !merged.contains(value) {
                            merged.push(value.clone());
                        }
                    }
                    if let Some(domain) = first.get_mut("domain").and_then(Value::as_object_mut) {
                        domain.insert(field.to_string(), Value::Array(merged));
                    }
                }
                let total = integer(first.get("count")) + addition;
                if let Some(object) = first.as_object_mut() {
                    object.insert("count".to_string(), json!(total));
                }
            }
        }
    }
    let mut out: Vec<Value> = order
        .into_iter()
        .filter_map(|group| grouped.remove(&group))
        .collect();
    out.sort_by_key(|row| {
        let scope = row.get("scope").cloned().unwrap_or(Value::Null);
        (
            text(scope.get("language")),
            text(scope.get("path")),
            text(scope.get("owner")),
            text(scope.get("function")),
            integer(scope.get("line")),
            text(row.get("kind")),
            text(row.get("slot")),
        )
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn root() -> &'static Path {
        Path::new("/repo")
    }

    #[test]
    fn a_path_inside_the_repository_is_reported_relative_to_it() {
        assert_eq!(relative_path("/repo/lib/a.rb", root()), "lib/a.rb");
        assert_eq!(relative_path("lib/a.rb", root()), "lib/a.rb");
        assert_eq!(relative_path("", root()), "");
    }

    #[test]
    fn a_path_outside_the_repository_keeps_its_own_spelling() {
        assert_eq!(relative_path("/gems/dep/lib/a.rb", root()), "/gems/dep/lib/a.rb");
    }

    #[test]
    fn test_directories_and_test_filenames_are_both_nonproduction() {
        assert!(nonproduction_path("test/a_test.rb", root()));
        assert!(nonproduction_path("spec/thing_spec.rb", root()));
        assert!(nonproduction_path("lib/nested/foo_test.rb", root()));
        assert!(!nonproduction_path("lib/foo.rb", root()));
        assert!(!nonproduction_path("", root()));
    }

    #[test]
    fn a_test_directory_named_like_one_but_deeper_still_counts() {
        assert!(nonproduction_path("lib/tests/helper.rb", root()));
        assert!(!nonproduction_path("lib/testing/helper.rb", root()));
    }

    #[test]
    fn descriptors_escape_exactly_what_scip_forbids() {
        assert_eq!(descriptor_name("valid_name"), "valid_name");
        assert_eq!(descriptor_name("valid-name+1$"), "valid-name+1$");
        assert_eq!(descriptor_name("empty?"), "`empty?`");
        assert_eq!(descriptor_name("save!"), "`save!`");
        assert_eq!(descriptor_name("=="), "`==`");
        assert_eq!(descriptor_name("[]"), "`[]`");
        assert_eq!(descriptor_name("a`b"), "`a``b`");
        assert_eq!(descriptor_name(""), "``");
    }

    #[test]
    fn a_namespaced_owner_becomes_a_descriptor_path() {
        assert_eq!(descriptor_owner("Foo::Bar::Baz"), "Foo/Bar/Baz");
        assert_eq!(descriptor_owner("::Foo"), "Foo");
        assert_eq!(descriptor_owner("Foo::Bar?"), "Foo/`Bar?`");
    }

    #[test]
    fn symbol_words_allow_more_punctuation_than_descriptors() {
        assert_eq!(symbol_word("rubygems"), "rubygems");
        assert_eq!(symbol_word("1.2.3"), "1.2.3");
        assert_eq!(symbol_word("a/b@c"), "a/b@c");
        assert_eq!(symbol_word(""), ".");
        assert_eq!(symbol_word("with space"), "`with space`");
    }

    #[test]
    fn an_instance_call_and_a_class_call_differ_only_in_their_separator() {
        let instance = json!({ "owner": "Foo", "kind": "instance", "package_manager": "workspace" });
        let class = json!({ "owner": "Foo", "kind": "class", "package_manager": "workspace" });
        assert!(runtime_symbol(&instance, "bar").ends_with("Foo#bar()."));
        assert!(runtime_symbol(&class, "bar").ends_with("Foo.bar()."));
    }

    #[test]
    fn a_callee_without_an_owner_falls_back_to_its_receiver_then_to_ruby() {
        let with_receiver = json!({ "receiver_type": "Bar", "kind": "instance" });
        assert!(runtime_symbol(&with_receiver, "x").ends_with("Bar#x()."));
        let bare = json!({ "kind": "instance" });
        assert!(runtime_symbol(&bare, "x").ends_with("ruby#x()."));
    }

    #[test]
    fn source_role_puts_provenance_ahead_of_mechanism() {
        let cases = [
            (json!({ "source_role": "nonproduction" }), "NON_PRODUCTION"),
            (json!({ "package": "minitest" }), "NON_PRODUCTION"),
            (json!({ "path": "test/a_test.rb", "package_manager": "ruby" }), "NON_PRODUCTION"),
            (json!({ "package_manager": "workspace" }), "PRODUCTION"),
            (json!({ "package_manager": "ruby" }), "STANDARD_LIBRARY"),
            (json!({ "package": "nokogiri" }), "DEPENDENCY"),
            (json!({}), "UNKNOWN_SOURCE"),
        ];
        for (callee, expected) in cases {
            assert_eq!(target_source_role(&callee, root()), expected, "{callee}");
        }
    }

    #[test]
    fn a_constructor_is_observed_as_initialize_but_dispatched_as_new() {
        let event = json!({
            "caller": { "path": "lib/a.rb", "class": "A", "method": "run", "line": 2 },
            "callsite": { "path": "lib/a.rb", "line": 3 },
            "callee": { "name": "initialize", "owner": "B", "kind": "instance",
                        "package_manager": "workspace" },
            "count": 1
        });
        let row = call(&event, root());
        assert_eq!(row["target"]["name"], json!("new"));
        assert!(row["target"]["symbol"].as_str().unwrap().ends_with("B#new()."));
        assert_eq!(row["callsite"]["selector"], json!("initialize"), "the site is as observed");
    }

    #[test]
    fn a_definition_is_recorded_only_for_non_native_code_inside_the_repository() {
        let base = |extra: Value| {
            let mut callee = json!({ "name": "x", "owner": "B", "kind": "instance", "line": 9 });
            for (k, v) in extra.as_object().unwrap() {
                callee[k] = v.clone();
            }
            json!({
                "caller": {}, "callsite": {}, "callee": callee, "count": 1
            })
        };
        let inside = call(&base(json!({ "path": "lib/b.rb" })), root());
        assert_eq!(inside["target"]["definition"]["path"], json!("lib/b.rb"));
        assert_eq!(inside["target"]["definition"]["line"], json!(9));

        let native = call(&base(json!({ "path": "lib/b.rb", "native": true })), root());
        assert!(native["target"].get("definition").is_none());

        let outside = call(&base(json!({ "path": "/elsewhere/b.rb" })), root());
        assert!(outside["target"].get("definition").is_none());
    }

    #[test]
    fn a_receiver_inherits_only_the_nonproduction_role() {
        let event = |role: &str| {
            json!({
                "caller": {}, "callsite": {},
                "callee": { "name": "x", "source_role": role, "package_manager": "workspace" },
                "count": 1
            })
        };
        let test_double = call(&event("nonproduction"), root());
        assert_eq!(test_double["receiver_source_role"], json!("NON_PRODUCTION"));
        let production = call(&event(""), root());
        assert_eq!(production["target"]["source_role"], json!("PRODUCTION"));
        assert_eq!(
            production["receiver_source_role"],
            json!("UNKNOWN_SOURCE"),
            "the receiver's own values are not claimed to be production"
        );
    }

    #[test]
    fn a_three_element_range_is_expanded_to_four() {
        assert_eq!(normalized_range(Some(&json!([1, 2, 9]))), Some(json!([1, 2, 1, 9])));
        assert_eq!(normalized_range(Some(&json!([1, 2, 3, 4]))), Some(json!([1, 2, 3, 4])));
        assert_eq!(normalized_range(Some(&json!([1, 2]))), None);
        assert_eq!(normalized_range(None), None);
    }

    #[test]
    fn a_falsy_witness_is_reported_before_a_truthy_one() {
        let event = |truths: Value| {
            json!({ "caller": {}, "callsite": {}, "callee": { "name": "x" },
                    "result_truths": truths, "count": 1 })
        };
        assert_eq!(call(&event(json!([true, false])), root())["result_truths"], json!([false, true]));
        assert_eq!(call(&event(json!([true, true])), root())["result_truths"], json!([true]));
    }

    #[test]
    fn a_domain_is_sorted_deduplicated_and_stripped_of_blanks() {
        let d = domain(
            Some(&json!(["B", "A", "A", ""])),
            None, None, None, None, None,
        );
        assert_eq!(d["types"], json!(["A", "B"]));
        assert_eq!(d["singletons"], json!([]));
    }

    #[test]
    fn a_record_shape_replaces_the_untyped_marker_it_identifies() {
        let d = domain(
            Some(&json!(["T.untyped"])),
            None, None, None, None,
            Some(&json!([{ "kind": "record", "name": "Point" }])),
        );
        assert_eq!(d["types"], json!(["Point"]), "the exact identity wins");
    }

    #[test]
    fn an_untyped_marker_with_no_record_identity_is_left_alone() {
        let d = domain(
            Some(&json!(["T.untyped"])),
            None, None, None, None,
            Some(&json!([{ "kind": "array" }])),
        );
        assert_eq!(d["types"], json!(["T.untyped"]));
    }

    #[test]
    fn nested_record_identities_reconcile_their_own_slot() {
        let d = domain(
            None, None,
            Some(&json!(["T.untyped"])),
            None, None,
            Some(&json!([{
                "kind": "array",
                "elements": [{ "kind": "record", "name": "Row" }]
            }])),
        );
        assert_eq!(d["elements"], json!(["Row"]));
    }

    #[test]
    fn a_bare_string_shape_becomes_a_class_shape() {
        assert_eq!(
            normalize_shape(&json!("String")),
            Some(json!({ "kind": "class", "name": "String" }))
        );
        assert_eq!(normalize_shape(&json!({})), Some(json!({ "kind": "unknown" })));
        assert_eq!(normalize_shape(&json!(7)), None);
    }

    #[test]
    fn a_shape_keeps_only_the_children_it_actually_has() {
        let shape = normalize_shape(&json!({
            "kind": "hash", "name": "", "keys": ["Symbol"], "values": [], "members": {}
        }))
        .expect("shape");
        assert_eq!(shape["keys"], json!([{ "kind": "class", "name": "Symbol" }]));
        assert!(shape.get("values").is_none(), "empty children are omitted");
        assert!(shape.get("members").is_none());
        assert!(shape.get("name").is_none(), "an empty name is omitted");
    }

    #[test]
    fn observations_of_one_slot_fuse_their_domains_and_add_their_counts() {
        let row = |types: Value, count: i64| {
            json!({
                "kind": "parameter",
                "scope": { "language": "ruby", "path": "a.rb", "owner": "A",
                           "function": "run", "line": 1 },
                "slot": "x", "slot_kind": "",
                "domain": { "types": types, "singletons": [], "elements": [],
                            "keys": [], "values": [], "shapes": [] },
                "count": count
            })
        };
        let merged = merge_observations(vec![row(json!(["A"]), 2), row(json!(["B", "A"]), 3)]);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0]["domain"]["types"], json!(["A", "B"]));
        assert_eq!(merged[0]["count"], json!(5));
    }

    #[test]
    fn different_slots_stay_separate_and_come_out_in_a_stable_order() {
        let row = |path: &str, function: &str, slot: &str| {
            json!({
                "kind": "parameter",
                "scope": { "language": "ruby", "path": path, "owner": "A",
                           "function": function, "line": 1 },
                "slot": slot, "slot_kind": "",
                "domain": { "types": ["X"] }, "count": 1
            })
        };
        let merged = merge_observations(vec![
            row("b.rb", "z", "q"),
            row("a.rb", "y", "p"),
            row("a.rb", "y", "a"),
        ]);
        let order: Vec<String> = merged
            .iter()
            .map(|r| format!("{}:{}", r["scope"]["path"].as_str().unwrap(), r["slot"].as_str().unwrap()))
            .collect();
        assert_eq!(order, vec!["a.rb:a", "a.rb:p", "b.rb:q"]);
    }
}
