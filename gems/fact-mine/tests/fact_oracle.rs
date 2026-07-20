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
        assert!(
            document.node_effects.iter().all(|effect| effect.complete),
            "{} emitted an incomplete executable-node effect",
            fixture.display()
        );
        assert_eq!(
            document.reachability.len(),
            document.control_flow_nodes.len()
        );
        assert_eq!(document.dominators.len(), document.control_flow_nodes.len());
        assert_eq!(document.liveness.len(), document.control_flow_nodes.len());
        for method in &document.local_methods {
            let entry = document
                .control_flow_nodes
                .iter()
                .find(|node| {
                    node.owner == method.owner
                        && node.function == method.name
                        && node.kind == "entry"
                })
                .with_context(|| {
                    format!("missing CFG entry for {}#{}", method.owner, method.name)
                })?;
            let effect = document
                .node_effects
                .iter()
                .find(|effect| effect.node_id == entry.id)
                .context("missing entry effect")?;
            for parameter in &method.params {
                assert!(
                    effect
                        .writes
                        .iter()
                        .any(|place| place.rsplit(':').next() == Some(parameter.as_str())),
                    "{}#{} parameter {parameter} has no entry definition",
                    method.owner,
                    method.name
                );
            }
        }
        let local_places = document
            .places
            .iter()
            .filter(|place| place.kind == "local")
            .map(|place| place.id.as_str())
            .collect::<BTreeSet<_>>();
        let reachable = document
            .reachability
            .iter()
            .filter(|fact| fact.reachable)
            .map(|fact| fact.node_id.as_str())
            .collect::<BTreeSet<_>>();
        for effect in document
            .node_effects
            .iter()
            .filter(|effect| reachable.contains(effect.node_id.as_str()))
        {
            for place in effect
                .reads
                .iter()
                .filter(|place| local_places.contains(place.as_str()))
            {
                let reaching = document
                    .reaching_definitions
                    .iter()
                    .find(|fact| fact.node_id == effect.node_id && fact.place_id == *place)
                    .context("reachable local read has no reaching-definition fact")?;
                assert!(
                    !reaching.definitions.is_empty(),
                    "{} has a disconnected local read {} at {}#{}",
                    fixture.display(),
                    place,
                    effect.owner,
                    effect.function
                );
            }
        }
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
fn dataflow_uses_the_innermost_equal_span_and_unwraps_literal_groups() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".rb").tempfile()?;
    write!(
        fixture,
        "def flow(items)\n  items.each do |item|\n    publish(item)\n  end\n  transaction do |token|\n    consume(token)\n  end\n  mapped = items.map {{ |mapped_item| mapped_item.to_s }}\n  items.ownership_bearing?(->(lambda_name) {{ ownership(lambda_name) }})\n  ownership = \"local\"\n  dims = {{ ownership: nil }}\n  called = ownership(items)\n  wrapped = (\"yes\")\n  wrapped\nend\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::Ruby)?;

    let body = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.source == "publish(item)")
        .expect("iterator body node");
    let body_effect = document
        .node_effects
        .iter()
        .find(|effect| effect.node_id == body.id)
        .expect("iterator body effect");
    assert!(body_effect.writes.is_empty());
    assert!(body_effect
        .reads
        .iter()
        .any(|place| place.ends_with(":item")));
    let loop_node = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.role == "iterator_loop")
        .expect("iterator node");
    let entry = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.kind == "entry")
        .expect("flow entry");
    let items = document
        .places
        .iter()
        .find(|place| place.function == "flow" && place.name == "items")
        .expect("items parameter");
    let items_reaching = document
        .reaching_definitions
        .iter()
        .find(|fact| fact.node_id == loop_node.id && fact.place_id == items.id)
        .expect("parameter reaching definition");
    assert_eq!(items_reaching.definitions, vec![entry.id.clone()]);
    let item = document
        .places
        .iter()
        .find(|place| place.function == "flow" && place.name == "item")
        .expect("iterator binding");
    let item_reaching = document
        .reaching_definitions
        .iter()
        .find(|fact| fact.node_id == body.id && fact.place_id == item.id)
        .expect("iterator binding reaching definition");
    assert_eq!(item_reaching.definitions, vec![loop_node.id.clone()]);

    let callback = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.role == "callback_region")
        .expect("callback node");
    let callback_effect = document
        .node_effects
        .iter()
        .find(|effect| effect.node_id == callback.id)
        .expect("callback effect");
    assert!(callback_effect
        .writes
        .iter()
        .any(|place| place.ends_with(":token")));
    assert!(!callback_effect
        .reads
        .iter()
        .any(|place| place.ends_with(":token")));
    let callback_body = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.source == "consume(token)")
        .expect("callback body node");
    let token = document
        .places
        .iter()
        .find(|place| place.function == "flow" && place.name == "token")
        .expect("callback binding");
    let token_reaching = document
        .reaching_definitions
        .iter()
        .find(|fact| fact.node_id == callback_body.id && fact.place_id == token.id)
        .expect("callback binding reaching definition");
    assert_eq!(token_reaching.definitions, vec![callback.id.clone()]);

    let nested_callback = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.source.starts_with("mapped = items.map"))
        .expect("nested callback expression");
    let nested_effect = document
        .node_effects
        .iter()
        .find(|effect| effect.node_id == nested_callback.id)
        .expect("nested callback effect");
    let mapped_item = document
        .places
        .iter()
        .find(|place| place.function == "flow" && place.name == "mapped_item")
        .expect("nested callback binding");
    assert!(nested_effect.reads.contains(&mapped_item.id));
    assert!(nested_effect.writes.contains(&mapped_item.id));
    assert!(document
        .reaching_definitions
        .iter()
        .find(|fact| fact.node_id == nested_callback.id && fact.place_id == mapped_item.id)
        .is_some_and(|fact| fact.definitions.is_empty()));
    let lambda_node = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.source.starts_with("items.ownership_bearing?"))
        .expect("lambda argument expression");
    let lambda_effect = document
        .node_effects
        .iter()
        .find(|effect| effect.node_id == lambda_node.id)
        .expect("lambda argument effect");
    let lambda_name = document
        .places
        .iter()
        .find(|place| place.function == "flow" && place.name == "lambda_name")
        .expect("lambda argument binding");
    assert!(lambda_effect.writes.contains(&lambda_name.id));
    let lambda_body = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.source == "ownership(lambda_name)")
        .expect("lambda body node");
    let lambda_reaching = document
        .reaching_definitions
        .iter()
        .find(|fact| fact.node_id == lambda_body.id && fact.place_id == lambda_name.id)
        .expect("lambda parameter reaching definition");
    assert_eq!(lambda_reaching.definitions, vec![lambda_node.id.clone()]);
    for source in ["dims = { ownership: nil }", "called = ownership(items)"] {
        let node = document
            .control_flow_nodes
            .iter()
            .find(|node| node.function == "flow" && node.source == source)
            .expect("label/call regression node");
        let effect = document
            .node_effects
            .iter()
            .find(|effect| effect.node_id == node.id)
            .expect("label/call regression effect");
        assert!(
            !effect
                .reads
                .iter()
                .any(|place| place.ends_with(":ownership")),
            "{source} must not treat a label or method name as a local read"
        );
    }

    let read = document
        .control_flow_nodes
        .iter()
        .find(|node| node.function == "flow" && node.source == "wrapped")
        .expect("wrapped read");
    let place = document
        .places
        .iter()
        .find(|place| place.function == "flow" && place.name == "wrapped")
        .expect("wrapped place");
    let flow = document
        .flow_types
        .iter()
        .find(|fact| fact.node_id == read.id && fact.place_id == place.id)
        .expect("wrapped flow type");
    assert_eq!(flow.types, vec!["string"]);
    assert!(flow.complete);
    Ok(())
}

#[test]
fn overloaded_methods_keep_independent_cfg_and_dfg_identity() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".java").tempfile()?;
    write!(
        fixture,
        "class Overloaded {{\n  int convert(int number) {{ return number; }}\n  String convert(String text) {{ return text; }}\n}}\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::Java)?;

    assert_eq!(
        document
            .control_flow_nodes
            .iter()
            .filter(|node| node.function == "convert" && node.kind == "entry")
            .count(),
        2
    );
    assert!(document.reachability.iter().all(|fact| fact.reachable));

    for (line, parameter) in [(2, "number"), (3, "text")] {
        let entry = document
            .control_flow_nodes
            .iter()
            .find(|node| node.function == "convert" && node.kind == "entry" && node.line == line)
            .expect("overload entry");
        let effect = document
            .node_effects
            .iter()
            .find(|effect| effect.node_id == entry.id)
            .expect("overload entry effect");
        let place = document
            .places
            .iter()
            .find(|place| place.function == "convert" && place.name == parameter)
            .expect("overload parameter place");
        assert_eq!(effect.writes, vec![place.id.clone()]);

        let read = document
            .reaching_definitions
            .iter()
            .find(|fact| fact.place_id == place.id && fact.node_id != entry.id)
            .expect("overload parameter read");
        assert_eq!(read.definitions, vec![entry.id.clone()]);
    }
    let ids = document
        .places
        .iter()
        .filter(|place| place.function == "convert")
        .map(|place| place.id.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(ids.len(), 2, "overload-local place IDs must not collide");
    Ok(())
}

#[test]
fn cfg_publishes_exact_boolean_assignment_values_for_ruby_and_python() -> Result<()> {
    use std::io::Write;

    for (suffix, language, source, expected_name) in [
        (".rb", Language::Ruby, "def toggle\n  @mode = true\n  @mode = false\nend\n", "@mode"),
        (".py", Language::Python, "class Demo:\n    def toggle(self):\n        self.mode = True\n        self.mode = False\n", "@mode"),
    ] {
        let mut fixture = tempfile::Builder::new().suffix(suffix).tempfile()?;
        write!(fixture, "{source}")?;
        let document = syntax::parse_file(fixture.path().to_path_buf(), language)?;
        let place = document.places.iter()
            .find(|place| place.name == expected_name || place.name.ends_with("mode"))
            .context("missing state place")?;
        let values = document.node_effects.iter()
            .filter_map(|effect| effect.write_value_hints.get(&place.id))
            .cloned().collect::<Vec<_>>();
        assert_eq!(values, vec!["boolean:true", "boolean:false"], "{}", language.as_str());
    }
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

#[test]
fn regression_fixtures_preserve_utf8_state_scope_and_product_domains() -> Result<()> {
    let root = examples_root().join("regressions");

    let php = syntax::parse_file(root.join("php/utf8_and_instance_state.php"), Language::Php)?;
    // Scanning the fixture exercises the formerly panicking path-condition
    // excerpt and establishes that identical `$this->options` spellings stay
    // owner-relative rather than becoming one global flow root.
    let path_conditions = syntax::path_condition::scan_documents(&[php.clone()]);
    // The fixture reaches the normalized path-condition pass; successful
    // completion is the regression for the former UTF-8 boundary panic.
    assert_eq!(path_conditions.neglected.len(), 0);
    assert!(php.state_reads.iter().all(|read| read.field == "options"));
    assert_eq!(
        php.state_reads
            .iter()
            .map(|read| read.owner.as_str())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from(["First", "Second"])
    );

    let cpp = syntax::parse_file(root.join("cpp/preprocessor_recovery.cpp"), Language::Cpp)?;
    assert!(cpp
        .function_defs
        .iter()
        .all(|function| function.name != "namespace"));
    assert!(cpp
        .function_defs
        .iter()
        .any(|function| function.name == "real_function"));

    let swift = syntax::parse_file(
        root.join("general/nested_independent_domains.swift"),
        Language::Swift,
    )?;
    let profile = profile::extract(&swift, Profile::Espalier);
    let facts = profile
        .complexity_facts
        .iter()
        .find(|fact| fact.function == "fill")
        .context("missing fill complexity facts")?;
    let iterations = &facts.iterations;
    assert_eq!(iterations.len(), 2);
    assert_eq!(iterations[1].cardinality_relation, "independent_of");
    assert_eq!(iterations[1].power, 2);
    let symbolic = iterations[1]
        .symbolic_time
        .as_ref()
        .context("missing symbolic time")?;
    assert!(symbolic.complete);
    assert_eq!(symbolic.factors.len(), 2);

    let swift_scope = syntax::parse_file(
        root.join("swift/extension_and_closure.swift"),
        Language::Swift,
    )?;
    let swift_profile = profile::extract(&swift_scope, Profile::NilKill);
    assert!(swift_profile
        .flow_local_types
        .iter()
        .any(|fact| fact["name"] == "$0"));
    assert!(swift_scope
        .places
        .iter()
        .any(|place| place.name == "$0" && place.kind == "local"));
    assert!(swift_scope
        .places
        .iter()
        .all(|place| place.name != "$0" || place.kind != "global"));
    let owners = profile::extract(&swift_scope, Profile::Espalier).owners;
    assert!(owners.iter().any(|owner| owner.kind == "struct"));
    assert!(owners.iter().any(|owner| owner.kind == "extension"));
    Ok(())
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
                "semantic_effects"
                    if object[key]
                        .as_array()
                        .and_then(|items| items.first())
                        .and_then(Value::as_object)
                        .is_some_and(|item| item.contains_key("receiver_scope")) =>
                {
                    &["kind", "detail", "receiver_scope", "function", "line"][..]
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
                "control_flow_nodes" => &["id", "kind", "line", "label"][..],
                "control_flow_edges" => &["source", "target", "kind"][..],
                "control_flow_metrics" => &["id", "cyclomatic", "npath"][..],
                "places" => &["id", "kind", "name"][..],
                "node_effects" => &["id", "reads", "writes"][..],
                "reachability" => &["source", "target"][..],
                "dominators" => &["node", "dominator"][..],
                "reaching_definitions" => &["line", "var", "def_line"][..],
                "def_use" => &["def_line", "var", "use_line"][..],
                "liveness" => &["line", "live_vars"][..],
                "flow_types" => &["id", "type_text"][..],
                "hazard_sites" => &["path", "line", "source", "hazard_type", "required_evidence", "start_column", "end_line", "end_column"][..],
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

#[test]
fn csharp_properties_and_while_drains_are_first_class_facts() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".cs").tempfile()?;
    write!(
        fixture,
        "class Queue {{\n  object _current;\n  readonly System.Collections.Generic.Queue<int> _queue;\n  public object Current => _current;\n  public object Value {{ get; set; }}\n  void Drain(bool stop) {{ int _queue = 1; while (this._queue.TryDequeue(out _) && !stop) {{ Consume(); }} }}\n}}\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::CSharp)?;
    assert!(document
        .function_defs
        .iter()
        .any(|method| method.name == "Current"));
    assert!(document
        .state_reads
        .iter()
        .any(|read| read.function == "Current" && read.field == "_current"));
    assert!(document.state_declarations.iter().any(|declaration| {
        declaration.owner == "Queue"
            && declaration.field == "Value"
            && declaration.r#type.as_deref() == Some("object")
    }));

    let output = profile::extract(&document, Profile::NilKill);
    let drain = output
        .complexity_facts
        .iter()
        .find(|fact| fact.function == "Drain")
        .context("Drain complexity fact")?;
    assert!(drain.iterations.iter().any(|iteration| {
        iteration.kind == "WHILE"
            && iteration.state_domains == ["@_queue"]
            && iteration.parameter_domains.is_empty()
    }));
    Ok(())
}

#[test]
fn javascript_bound_method_setup_is_not_mutable_instance_state() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".ts").tempfile()?;
    write!(
        fixture,
        "class Handler {{ run() {{}} constructor() {{ this.run = this.run.bind(this); }} }}\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::TypeScript)?;
    assert!(!document
        .state_writes
        .iter()
        .any(|write| write.field == "run"));
    Ok(())
}

#[test]
fn owner_reopenability_is_normalized_in_the_language_adapter() -> Result<()> {
    use std::io::Write;

    let mut ruby = tempfile::Builder::new().suffix(".rb").tempfile()?;
    ruby.write_all(b"class Extension; end\n")?;
    let ruby_document = syntax::parse_file(ruby.path().to_path_buf(), Language::Ruby)?;
    assert!(ruby_document
        .owner_defs
        .iter()
        .any(|owner| owner.reopenable));

    let mut typescript = tempfile::Builder::new().suffix(".ts").tempfile()?;
    typescript.write_all(b"class Extension {}\n")?;
    let typescript_document =
        syntax::parse_file(typescript.path().to_path_buf(), Language::TypeScript)?;
    assert!(typescript_document
        .owner_defs
        .iter()
        .all(|owner| !owner.reopenable));
    Ok(())
}

#[test]
fn c_aggregate_state_identity_is_owner_qualified() -> Result<()> {
    use std::io::Write;

    let mut fixture = tempfile::Builder::new().suffix(".c").tempfile()?;
    write!(
        fixture,
        "struct Alpha {{ int flag; }};\nstruct Beta {{ int flag; }};\nvoid alpha(struct Alpha* self) {{ self->flag = 1; }}\nvoid beta(struct Beta* self) {{ self->flag = 2; }}\n"
    )?;
    let document = syntax::parse_file(fixture.path().to_path_buf(), Language::C)?;
    let identities = document
        .state_writes
        .iter()
        .map(|write| write.identity.as_str())
        .collect::<BTreeSet<_>>();
    assert_eq!(identities, BTreeSet::from(["Alpha::flag", "Beta::flag"]));
    Ok(())
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
