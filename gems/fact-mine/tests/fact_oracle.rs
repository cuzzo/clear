use anyhow::{bail, Context, Result};
use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::syntax::{self, Language};
use fact_mine_rust::syntax_oracle;
use serde::Serialize;
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

#[test]
fn syntax_fact_examples_match_oracles() -> Result<()> {
    let examples_root = examples_root().join("syntax-facts");
    let oracle_dir = examples_root.join("oracles");
    let mut failures = Vec::new();

    for fixture in syntax_fact_fixture_paths(&examples_root)? {
        let language = language_for_fixture(&fixture)?;
        let name = file_stem(&fixture)?;
        let oracle_path = oracle_dir.join(format!("{}-{name}.json", language.as_str()));
        let expected: Value = if std::env::var("UPDATE_ORACLES").is_ok() && !oracle_path.exists() {
            if let Some(parent) = oracle_path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            json!({})
        } else {
            serde_json::from_str(&fs::read_to_string(&oracle_path)?)
                .with_context(|| format!("read {}", oracle_path.display()))?
        };
        let actual = syntax_oracle::project_files(&[fixture.clone()], language)
            .with_context(|| format!("project {}", fixture.display()))?;
        let actual = project_expected_shape(&actual, &expected)?;

        if std::env::var("UPDATE_ORACLES").is_ok() {
            fs::write(&oracle_path, serde_json::to_string_pretty(&actual)?)?;
        } else if actual != expected {
            failures.push(format!(
                "{}\nexpected: {}\nactual:   {}",
                fixture.display(),
                expected,
                actual
            ));
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!("syntax-facts oracle failures:\n{}", failures.join("\n\n"))
    }
}

#[test]
fn cfg_is_emitted_for_every_supported_language() -> Result<()> {
    let examples_root = examples_root().join("syntax-facts");
    let mut covered = BTreeSet::new();

    for fixture in syntax_fact_fixture_paths(&examples_root)? {
        if !file_stem(&fixture)?.starts_with("cfg_") {
            continue;
        }
        let language = language_for_fixture(&fixture)?;
        let document = syntax::parse_file(fixture.clone(), language)?;

        assert!(
            !document.control_flow_nodes.is_empty(),
            "{} emitted no CFG nodes",
            fixture.display()
        );
        assert!(
            !document.control_flow_edges.is_empty(),
            "{} emitted no CFG edges",
            fixture.display()
        );
        assert_eq!(
            document.control_flow_metrics.len(),
            document.local_methods.len(),
            "{} emitted incomplete CFG metrics",
            fixture.display()
        );
        assert_eq!(
            document.node_effects.len(),
            document.control_flow_nodes.len()
        );
        assert_eq!(
            document.reachability.len(),
            document.control_flow_nodes.len()
        );
        assert_eq!(document.dominators.len(), document.control_flow_nodes.len());
        assert_eq!(document.liveness.len(), document.control_flow_nodes.len());
        assert!(document.source_digest.starts_with("sha256:"));
        covered.insert(language.as_str());
    }

    assert_eq!(
        covered,
        BTreeSet::from([
            "c",
            "cpp",
            "csharp",
            "go",
            "java",
            "javascript",
            "kotlin",
            "lua",
            "php",
            "python",
            "ruby",
            "rust",
            "swift",
            "typescript",
            "zig",
        ])
    );
    Ok(())
}

#[test]
fn dataflow_respects_early_return_and_publishes_literal_type() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".rb").tempfile()?;
    write!(
        fixture,
        "def flow(x)\n  a = x\n  if a\n    b = \"yes\"\n  else\n    return 0\n  end\n  b\nend\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::Ruby)?;
    let read = document
        .control_flow_nodes
        .iter()
        .find(|node| node.source == "b")
        .expect("final b read");
    let assignment = document
        .control_flow_nodes
        .iter()
        .find(|node| node.source == "b = \"yes\"")
        .expect("b assignment");
    let place = document
        .places
        .iter()
        .find(|place| place.name == "b")
        .expect("b place");

    let reaching = document
        .reaching_definitions
        .iter()
        .find(|fact| fact.node_id == read.id && fact.place_id == place.id)
        .expect("reaching definition");
    assert_eq!(reaching.definitions, vec![assignment.id.clone()]);
    let flow_type = document
        .flow_types
        .iter()
        .find(|fact| fact.node_id == read.id && fact.place_id == place.id)
        .expect("flow type");
    assert_eq!(flow_type.types, vec!["string"]);
    assert!(flow_type.complete);
    assert!(
        document
            .def_use
            .iter()
            .any(|fact| fact.definition_node_id == assignment.id
                && fact.uses == vec![read.id.clone()])
    );
    let nil_kill = profile::extract(&document, Profile::NilKill);
    assert!(nil_kill.flow_local_types.iter().any(|fact| {
        fact["name"] == "b"
            && fact["node_id"] == read.id
            && fact["types"] == json!(["string"])
            && fact["complete"] == true
    }));
    let flow_return = nil_kill
        .return_origins
        .iter()
        .find(|origin| origin["method"] == "flow")
        .expect("flow return origin");
    let flow_source = flow_return["sources"]
        .as_array()
        .and_then(|sources| sources.iter().find(|source| source["code"] == "b"))
        .expect("DFG-derived return source");
    assert_eq!(
        flow_source["type"],
        json!({"kind": "Primitive", "data": "String"})
    );
    assert_eq!(flow_source["flow_complete"], true);
    Ok(())
}

#[test]
fn dataflow_propagates_direct_copies_but_not_call_results() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".rb").tempfile()?;
    write!(
        fixture,
        "def copied\n  source = \"yes\"\n  middle = source\n  result = (middle)\n  result\nend\n\ndef transformed\n  source = \"yes\"\n  result = transform(source)\n  result\nend\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::Ruby)?;

    let copied_read = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "copied" && node.source == "result")
        .expect("copied result read");
    let copied_place = document
        .places
        .iter()
        .find(|place| place.function == "copied" && place.name == "result")
        .expect("copied result place");
    let copied_flow = document
        .flow_types
        .iter()
        .find(|fact| fact.node_id == copied_read.id && fact.place_id == copied_place.id)
        .expect("copied result flow");
    assert_eq!(copied_flow.types, vec!["string"]);
    assert!(copied_flow.complete);
    assert!(document.node_effects.iter().any(|effect| {
        effect
            .write_sources
            .iter()
            .any(|(target, source)| target.ends_with(":result") && source.ends_with(":middle"))
    }));

    let transformed_read = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "transformed" && node.source == "result")
        .expect("transformed result read");
    let transformed_place = document
        .places
        .iter()
        .find(|place| place.function == "transformed" && place.name == "result")
        .expect("transformed result place");
    let transformed_flow = document
        .flow_types
        .iter()
        .find(|fact| fact.node_id == transformed_read.id && fact.place_id == transformed_place.id)
        .expect("transformed result flow");
    assert!(transformed_flow.types.is_empty());
    assert!(!transformed_flow.complete);
    Ok(())
}

#[test]
fn ruby_dataflow_seeds_declared_parameters_and_propagates_copies() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".rb").tempfile()?;
    write!(
        fixture,
        "class Copier\n  extend T::Sig\n  sig {{ params(input: String).returns(String) }}\n  def copy(input)\n    result = input\n    result\n  end\nend\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::Ruby)?;
    let method = document
        .local_methods
        .iter()
        .find(|method| method.owner == "Copier" && method.name == "copy")
        .expect("copy method summary");
    assert_eq!(
        method.param_types.get("input").map(String::as_str),
        Some("String")
    );

    let read = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "copy" && node.source == "result")
        .expect("result read");
    let place = document
        .places
        .iter()
        .find(|place| place.function == "copy" && place.name == "result")
        .expect("result place");
    let flow = document
        .flow_types
        .iter()
        .find(|fact| fact.node_id == read.id && fact.place_id == place.id)
        .expect("result flow");
    assert_eq!(flow.types, vec!["declared:String"]);
    assert!(flow.complete);

    let nil_kill = profile::extract(&document, Profile::NilKill);
    let origin = nil_kill
        .return_origins
        .iter()
        .find(|origin| origin["class"] == "Copier" && origin["method"] == "copy")
        .expect("copy return origin");
    assert_eq!(
        origin["candidate_type"],
        json!({"kind": "Primitive", "data": "String"})
    );
    assert_eq!(origin["sources"][0]["flow_complete"], true);
    Ok(())
}

#[test]
fn ruby_cfg_control_bodies_preserve_executable_statement_spans() -> Result<()> {
    let examples = examples_root().join("syntax-facts/ruby");
    let loops = syntax::parse_file(examples.join("cfg_loops.rb"), Language::Ruby)?;
    let loop_body = loops
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "while_loop" && node.source == "publish(user)")
        .expect("while-loop body statement");
    assert_eq!(loop_body.span, [4, 6, 4, 19]);

    let exceptions = syntax::parse_file(examples.join("cfg_exceptions.rb"), Language::Ruby)?;
    let cleanup_nodes = exceptions
        .control_flow_nodes
        .iter()
        .filter(|node| node.function == "rescue_ensure" && node.source == "close(user)")
        .collect::<Vec<_>>();
    assert_eq!(
        cleanup_nodes.len(),
        2,
        "cleanup is expanded once per incoming path"
    );
    assert!(
        cleanup_nodes
            .iter()
            .all(|node| node.span == [26, 6, 26, 17]),
        "cleanup spans must exclude the trailing end keyword"
    );
    Ok(())
}

fn full_syntax_expected() -> Value {
    json!({
        "functions": [],
        "owners": [],
        "calls": [],
        "state_declarations": [],
        "state_param_origins": [],
        "state_reads": [],
        "state_writes": [],
        "decisions": [],
        "branch_decisions": [],
        "branch_arms": [],
        "dispatch_sites": [],
        "semantic_effects": [],
        "predicate_bodies": [],
        "comparisons": [],
        "path_conditions": [],
        "control_flow_nodes": [],
        "control_flow_edges": [],
        "control_flow_metrics": [],
        "places": [],
        "node_effects": [],
        "reachability": [],
        "dominators": [],
        "reaching_definitions": [],
        "def_use": [],
        "liveness": [],
        "flow_types": [],
        "protocol_method_effects": [],
        "protocol_call_paths": [],
        "clone_candidates": [],
        "redundant_nil_guards": [],
        "local_methods": [],
        "local_complexity_scores": []
    })
}

#[test]
fn source_fact_examples_match_oracles() -> Result<()> {
    let examples_root = examples_root().join("source-facts");
    let mut failures = Vec::new();

    for fixture in source_fact_fixture_paths(&examples_root)? {
        let language = source_fixture_language(&fixture)?;
        let oracle_path = source_oracle_path(&examples_root, &fixture)?;
        let expected: Value = if std::env::var("UPDATE_ORACLES").is_ok() && !oracle_path.exists() {
            if let Some(parent) = oracle_path.parent() {
                let _ = fs::create_dir_all(parent);
            }
            json!({
                "syntax": {},
                "local_flow": [],
                "path_condition": {}
            })
        } else {
            serde_json::from_str(&fs::read_to_string(&oracle_path)?)
                .with_context(|| format!("read {}", oracle_path.display()))?
        };
        let mut actual = Map::new();

        let is_update = std::env::var("UPDATE_ORACLES").is_ok();
        let syntax_expected = if is_update {
            Some(full_syntax_expected())
        } else {
            expected.get("syntax").cloned()
        };

        if let Some(syntax_expected) = &syntax_expected {
            actual.insert(
                "syntax".to_string(),
                project_source_syntax(&fixture, language, syntax_expected)?,
            );
        }
        if is_update || expected.get("local_flow").is_some() {
            actual.insert(
                "local_flow".to_string(),
                project_local_flow(&value(syntax::local_flow::scan_files(
                    &[fixture.clone()],
                    language,
                )?)?),
            );
        }
        if is_update || expected.get("path_condition").is_some() {
            actual.insert(
                "path_condition".to_string(),
                project_path_condition(&value(syntax::path_condition::scan_files(
                    &[fixture.clone()],
                    language,
                )?)?),
            );
        }

        let actual = Value::Object(actual);
        if is_update {
            fs::write(&oracle_path, serde_json::to_string_pretty(&actual)?)?;
        } else if actual != expected {
            failures.push(format!(
                "{}\nexpected: {}\nactual:   {}",
                fixture.display(),
                expected,
                actual
            ));
        }
    }

    if failures.is_empty() {
        Ok(())
    } else {
        bail!("source-facts oracle failures:\n{}", failures.join("\n\n"))
    }
}

fn examples_root() -> PathBuf {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("examples");
    fs::canonicalize(&root).unwrap_or(root)
}

fn syntax_fact_fixture_paths(examples_root: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();
    for language_dir in fs::read_dir(examples_root)? {
        let language_dir = language_dir?.path();
        if !language_dir.is_dir()
            || language_dir.file_name().and_then(|name| name.to_str()) == Some("oracles")
        {
            continue;
        }
        for entry in fs::read_dir(&language_dir)? {
            let path = entry?.path();
            if path.is_file() && language_for_fixture(&path).is_ok() {
                paths.push(path);
            }
        }
    }
    paths.sort();
    Ok(paths)
}

fn source_fact_fixture_paths(examples_root: &Path) -> Result<Vec<PathBuf>> {
    let mut paths = Vec::new();

    let general_root = examples_root.join("general");
    if general_root.is_dir() {
        for fixture_dir in fs::read_dir(&general_root)? {
            let fixture_dir = fixture_dir?.path();
            if !fixture_dir.is_dir() {
                continue;
            }
            for entry in fs::read_dir(&fixture_dir)? {
                let path = entry?.path();
                if path.is_file() && source_fixture_language(&path).is_ok() {
                    paths.push(path);
                }
            }
        }
    }

    let ruby_root = examples_root.join("ruby");
    if ruby_root.is_dir() {
        for entry in fs::read_dir(&ruby_root)? {
            let path = entry?.path();
            if path.is_file() && source_fixture_language(&path).is_ok() {
                paths.push(path);
            }
        }
    }

    paths.sort();
    Ok(paths)
}

fn file_stem(path: &Path) -> Result<String> {
    path.file_stem()
        .and_then(|stem| stem.to_str())
        .map(str::to_string)
        .with_context(|| format!("missing file stem for {}", path.display()))
}

fn language_for_fixture(path: &Path) -> Result<Language> {
    let extension = path
        .extension()
        .and_then(|extension| extension.to_str())
        .with_context(|| format!("missing extension for {}", path.display()))?;
    Language::for_extension(extension)
        .with_context(|| format!("unsupported fixture extension: {}", path.display()))
}

fn source_fixture_language(path: &Path) -> Result<Language> {
    if is_general_source_fixture(path) {
        return Language::parse(&file_stem(path)?);
    }

    let language = path
        .parent()
        .and_then(|parent| parent.file_name())
        .and_then(|name| name.to_str())
        .with_context(|| format!("missing source fixture language for {}", path.display()))?;
    Language::parse(language)
}

fn source_fixture_name(path: &Path) -> Result<String> {
    if is_general_source_fixture(path) {
        return path
            .parent()
            .and_then(|parent| parent.file_name())
            .and_then(|name| name.to_str())
            .map(str::to_string)
            .with_context(|| {
                format!("missing general source fixture name for {}", path.display())
            });
    }

    file_stem(path)
}

fn is_general_source_fixture(path: &Path) -> bool {
    path.components()
        .any(|component| component.as_os_str() == "general")
}

fn source_oracle_path(examples_root: &Path, path: &Path) -> Result<PathBuf> {
    let language = source_fixture_language(path)?.as_str();
    let name = source_fixture_name(path)?;
    if is_general_source_fixture(path) {
        return Ok(examples_root
            .join("oracles")
            .join("general")
            .join(name)
            .join(format!("{language}.json")));
    }

    Ok(examples_root
        .join("oracles")
        .join(format!("{language}-{name}.json")))
}

fn project_expected_shape(actual: &Value, expected: &Value) -> Result<Value> {
    match expected {
        Value::Object(expected_object) => {
            let actual_object = actual
                .as_object()
                .with_context(|| format!("expected object shape, got {actual}"))?;
            let mut out = Map::new();
            for (key, expected_value) in expected_object {
                let actual_value = actual_object
                    .get(key)
                    .with_context(|| format!("missing key {key} in {actual}"))?;
                out.insert(
                    key.clone(),
                    project_expected_shape(actual_value, expected_value)?,
                );
            }
            Ok(Value::Object(out))
        }
        Value::Array(expected_items) => {
            if !expected_items.iter().any(Value::is_object) {
                return Ok(actual.clone());
            }

            let actual_items = actual
                .as_array()
                .with_context(|| format!("expected array shape, got {actual}"))?;
            let mut keys = BTreeSet::new();
            for expected_item in expected_items {
                if let Some(object) = expected_item.as_object() {
                    keys.extend(object.keys().cloned());
                }
            }

            let mut projected = actual_items
                .iter()
                .map(|actual_item| {
                    let Some(actual_object) = actual_item.as_object() else {
                        return Ok(actual_item.clone());
                    };
                    let mut out = Map::new();
                    for key in &keys {
                        let expected_value = expected_items
                            .iter()
                            .filter_map(Value::as_object)
                            .find_map(|object| object.get(key));
                        let Some(actual_value) = actual_object.get(key) else {
                            continue;
                        };
                        out.insert(
                            key.clone(),
                            project_expected_shape(
                                actual_value,
                                expected_value.unwrap_or(actual_value),
                            )?,
                        );
                    }
                    Ok(Value::Object(out))
                })
                .collect::<Result<Vec<_>>>()?;
            projected.sort_by_key(|item| item.to_string());
            Ok(Value::Array(projected))
        }
        _ => Ok(actual.clone()),
    }
}

fn project_source_syntax(fixture: &Path, language: Language, expected: &Value) -> Result<Value> {
    let projection = syntax_oracle::project_files(&[fixture.to_path_buf()], language)?;
    let document = array(field(&projection, "documents"))
        .first()
        .cloned()
        .unwrap_or(Value::Null);
    let mut out = Map::new();
    if let Some(object) = expected.as_object() {
        for key in object.keys() {
            let keys = match key.as_str() {
                "functions" => &["name", "owner", "line", "visibility", "params"][..],
                "owners" => &["name", "kind", "line"][..],
                "calls" => &[
                    "receiver",
                    "message",
                    "function",
                    "line",
                    "conditional",
                    "control",
                    "safe_navigation",
                    "block",
                    "arguments",
                ][..],
                "state_declarations" => &["field", "owner", "type", "line"][..],
                "state_param_origins" => {
                    &["field", "receiver", "owner", "param", "function", "line"][..]
                }
                "state_reads" => &["receiver", "field", "function", "line"][..],
                "state_writes" => &["receiver", "field", "function", "line"][..],
                "decisions" => &[
                    "kind",
                    "members",
                    "function",
                    "line",
                    "predicate",
                    "enclosing_span",
                ][..],
                "branch_decisions" => &["function", "line", "predicate", "state_refs"][..],
                "branch_arms" => &[
                    "function",
                    "kind",
                    "line",
                    "decision_line",
                    "predicate",
                    "member",
                    "body",
                ][..],
                "dispatch_sites" => {
                    &["variant_set", "arm_members", "outside", "function", "line"][..]
                }
                "semantic_effects" => &["kind", "detail", "function", "line"][..],
                "predicate_bodies" => &["name", "owner", "body", "line"][..],
                "comparisons" => &[
                    "source",
                    "raw",
                    "canon_source",
                    "operator",
                    "function",
                    "line",
                ][..],
                "path_conditions" => &["guards", "action", "function", "line"][..],
                "protocol_method_effects" => &["owner", "name", "line", "reads", "writes"][..],
                "protocol_call_paths" => &["owner", "name", "line", "calls"][..],
                "clone_candidates" => &[
                    "method_name",
                    "node_name",
                    "line",
                    "mass",
                    "fingerprint",
                    "child_fingerprints",
                    "child_masses",
                ][..],
                "redundant_nil_guards" => &["defn", "line", "local", "guard", "proof"][..],
                "local_methods" => &[
                    "id",
                    "owner",
                    "name",
                    "line",
                    "statements",
                    "boundaries",
                    "local_contract_assignments",
                ][..],
                "local_complexity_scores" => &["id", "score", "signals"][..],
                _ => bail!("unsupported source syntax section: {key}"),
            };
            out.insert(key.clone(), rows(field(&document, key), keys));
        }
    }
    Ok(Value::Object(out))
}

fn project_local_flow(output: &Value) -> Value {
    Value::Array(
        array(output)
            .iter()
            .map(|method| {
                json!({
                    "method": field(method, "name").clone(),
                    "statements": array(field(method, "statements")).iter().map(|statement| {
                        json!({
                            "reads": sorted_array(field(statement, "reads")),
                            "writes": sorted_array(field(statement, "writes")),
                            "dependencies": field(statement, "dependencies").clone(),
                            "co_uses": canonical_co_uses(field(statement, "co_uses")),
                        })
                    }).collect::<Vec<_>>(),
                    "boundaries": array(field(method, "boundaries")).iter().map(|boundary| {
                        pick(boundary, &["before_index", "after_index", "kind"])
                    }).collect::<Vec<_>>(),
                })
            })
            .collect(),
    )
}

fn project_path_condition(output: &Value) -> Value {
    json!({
        "neglected": array(field(output, "neglected")).iter().map(|row| {
            json!({
                "pattern": field(row, "pattern"),
                "support": field(row, "support"),
                "missing": field(row, "missing"),
                "at": canonical_location(field(row, "at")),
                "action": field(row, "action"),
            })
        }).collect::<Vec<_>>(),
        "scattered": array(field(output, "scattered")).iter().map(|row| {
            json!({
                "guards": field(row, "guards"),
                "support": field(row, "support"),
                "scatter": field(row, "scatter"),
                "rank": field(row, "rank"),
                "sites": canonical_locations(field(row, "sites")),
            })
        }).collect::<Vec<_>>(),
    })
}

fn canonical_location(value: &Value) -> Value {
    value
        .as_str()
        .map(canonical_location_text)
        .map(Value::String)
        .unwrap_or(Value::Null)
}

fn canonical_locations(value: &Value) -> Value {
    Value::Array(
        array(value)
            .iter()
            .map(canonical_location)
            .collect::<Vec<_>>(),
    )
}

fn canonical_location_text(text: &str) -> String {
    text.split_once("/examples/")
        .map(|(_, suffix)| format!("examples/{suffix}"))
        .unwrap_or_else(|| text.to_string())
}

fn canonical_co_uses(value: &Value) -> Value {
    let mut pairs = array(value)
        .iter()
        .map(|pair| {
            let mut items = array(pair)
                .iter()
                .map(|item| item.as_str().unwrap_or_default().to_string())
                .collect::<Vec<_>>();
            items.sort();
            json!(items)
        })
        .collect::<Vec<_>>();
    pairs.sort_by_key(|item| item.to_string());
    Value::Array(pairs)
}

fn rows(value: &Value, keys: &[&str]) -> Value {
    Value::Array(array(value).iter().map(|row| pick(row, keys)).collect())
}

fn pick(row: &Value, keys: &[&str]) -> Value {
    let mut out = Map::new();
    if let Some(object) = row.as_object() {
        for key in keys {
            if let Some(value) = object.get(*key) {
                out.insert((*key).to_string(), canonical_value(value));
            }
        }
    }
    Value::Object(out)
}

fn canonical_value(value: &Value) -> Value {
    match value {
        Value::Object(object) => {
            let mut out = Map::new();
            let mut keys = object.keys().collect::<Vec<_>>();
            keys.sort();
            for key in keys {
                out.insert(key.clone(), canonical_value(&object[key]));
            }
            Value::Object(out)
        }
        Value::Array(values) => Value::Array(values.iter().map(canonical_value).collect()),
        _ => value.clone(),
    }
}

fn sorted_array(value: &Value) -> Value {
    let mut values = array(value);
    values.sort_by_key(|item| item.to_string());
    Value::Array(values)
}

fn field<'a>(value: &'a Value, key: &str) -> &'a Value {
    value.get(key).unwrap_or(&Value::Null)
}

fn array(value: &Value) -> Vec<Value> {
    value.as_array().cloned().unwrap_or_default()
}

fn value<T: Serialize>(value: T) -> Result<Value> {
    Ok(serde_json::to_value(value)?)
}
