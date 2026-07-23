use anyhow::{bail, Context, Result};
use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::syntax::{self, Language};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

fn examples_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("examples")
        .join("profile")
}

fn fixture(name: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

#[test]
fn python_profile_keeps_lexical_closures_out_of_owner_methods() -> Result<()> {
    let document = syntax::parse_file(fixture("python_state_projection.py"), Language::Python)?;
    let output = profile::extract(&document, Profile::Espalier);
    let methods = output
        .methods
        .iter()
        .filter(|method| method.owner == "Console")
        .map(|method| method.name.as_str())
        .collect::<Vec<_>>();
    assert_eq!(methods, vec!["export"]);
    Ok(())
}

#[test]
fn python_profile_canonicalizes_and_projects_state_reads() -> Result<()> {
    let document = syntax::parse_file(fixture("python_state_projection.py"), Language::Python)?;
    let reads = document
        .state_reads
        .iter()
        .map(|read| (read.receiver.as_str(), read.field.as_str()))
        .collect::<Vec<_>>();
    assert!(reads.contains(&("self", "@_record_buffer_lock")));
    assert!(reads.contains(&("self", "@_items")));
    assert!(reads.contains(&("theme", "ansi_colors")));
    assert!(reads.contains(&("theme", "guard")));
    assert!(reads.contains(&("element", "href")));
    Ok(())
}

#[test]
fn declared_method_types_are_normalized_from_language_owned_syntax() -> Result<()> {
    let python = syntax::parse_file(fixture("declared_types.py"), Language::Python)?;
    let python = profile::extract(&python, Profile::NilKill);
    let call = python
        .type_definitions
        .iter()
        .find(|definition| definition.kind == "method_signature" && definition.name == "call")
        .context("missing Python call signature")?;
    assert_eq!(
        call.return_type
            .as_ref()
            .map(ToString::to_string)
            .as_deref(),
        Some("str")
    );
    assert!(call.params.iter().any(|parameter| {
        parameter.get("name") == Some(&json!("reason"))
            && parameter.get("type").and_then(|value| value.get("data")) == Some(&json!("str"))
    }));

    let typescript = syntax::parse_file(fixture("typescript_interface.ts"), Language::TypeScript)?;
    let typescript = profile::extract(&typescript, Profile::NilKill);
    let interface_method = typescript
        .type_definitions
        .iter()
        .find(|definition| {
            definition.kind == "method_signature"
                && definition.owner == "Client"
                && definition.name == "fetch"
        })
        .context("missing TypeScript interface method signature")?;
    assert_eq!(
        interface_method
            .return_type
            .as_ref()
            .map(ToString::to_string)
            .as_deref(),
        Some("T.nilable(string)")
    );
    Ok(())
}

#[test]
fn nullable_refinements_are_a_stable_nil_kill_public_fact() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_refinements.c"), Language::C)?;
    let output = profile::extract(&document, Profile::NilKill);
    let actual = output
        .nullable_refinements
        .iter()
        .map(|row| {
            json!({
                "edge": row.edge,
                "proof_kind": row.proof_kind,
                "state_on_edge": row.state_on_edge,
            })
        })
        .collect::<Vec<_>>();
    let expected: Vec<Value> =
        serde_json::from_str(&fs::read_to_string(fixture("nullable_refinements.json"))?)?;

    assert_eq!(actual, expected);
    assert!(output.nullable_refinements.iter().all(|row| {
        row.place_id.starts_with("place:")
            && row.condition_node_id.starts_with("cfg:")
            && (!row.complete || !row.source_definition_ids.is_empty())
    }));
    Ok(())
}

#[test]
fn nullable_states_follow_exact_nil_writes_and_direct_aliases() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_states.c"), Language::C)?;
    let output = profile::extract(&document, Profile::NilKill);
    let mut actual = output
        .nullable_states
        .iter()
        .map(|row| json!({"complete": row.complete, "state": row.state}))
        .collect::<Vec<_>>();
    actual.sort_by_key(|row| row["state"].as_str().unwrap_or_default().to_string());
    let expected: Vec<Value> =
        serde_json::from_str(&fs::read_to_string(fixture("nullable_states.json"))?)?;

    assert_eq!(actual, expected);
    assert!(output
        .nullable_states
        .iter()
        .filter(|row| row.state == "definitely_null")
        .all(|row| row.source_definition_ids.len() == 1 && row.unknown_reasons.is_empty()));
    Ok(())
}

#[test]
fn nullable_return_summaries_follow_cfg_state_facts() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_states.c"), Language::C)?;
    let output = profile::extract(&document, Profile::NilKill);
    let mut actual = output
        .nullable_summaries
        .iter()
        .map(|summary| {
            serde_json::json!({
                "complete": summary.complete,
                "function": summary.function,
                "return_state": summary.return_state,
            })
        })
        .collect::<Vec<_>>();
    actual.sort_by_key(|row| row["function"].as_str().unwrap().to_string());
    let expected: Vec<serde_json::Value> =
        serde_json::from_str(&fs::read_to_string(fixture("nullable_summaries.json"))?)?;
    assert_eq!(actual, expected);
    Ok(())
}

#[test]
fn nullable_states_preserve_go_and_cpp_null_literals() -> Result<()> {
    for (name, language) in [
        ("nullable_states.go", Language::Go),
        ("nullable_states.cpp", Language::Cpp),
    ] {
        let document = syntax::parse_file(fixture(name), language)?;
        let output = profile::extract(&document, Profile::NilKill);
        assert!(output.nullable_states.iter().any(|state| {
            state.state == "definitely_null"
                && state.complete
                && !state.source_definition_ids.is_empty()
        }));
        assert!(output
            .nullable_summaries
            .iter()
            .any(|summary| { summary.return_state == "definitely_null" && summary.complete }));
    }
    Ok(())
}

#[test]
fn native_declared_non_null_contracts_reach_public_nullable_states() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_annotations.cpp"), Language::Cpp)?;
    let output = profile::extract(&document, Profile::NilKill);

    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("non_null_parameter")
            && state.place_id.ends_with(":value")
            && state.state == "definitely_non_null"
            && state.complete
    }));
    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("non_null_local")
            && state.place_id.ends_with(":value")
            && state.state == "definitely_non_null"
            && state.complete
    }));
    Ok(())
}

#[test]
fn c_native_nullability_annotations_survive_parser_preprocessing() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_annotations.c"), Language::C)?;
    let output = profile::extract(&document, Profile::NilKill);

    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("nullable_parameter")
            && state.place_id.ends_with(":value")
            && state.state == "maybe_null"
            && state.complete
    }));
    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("non_null_parameter")
            && state.place_id.ends_with(":value")
            && state.state == "definitely_non_null"
            && state.complete
    }));
    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("nullable_local")
            && state.place_id.ends_with(":value")
            && state.state == "maybe_null"
            && state.complete
    }));
    assert!(output.nullable_operations.iter().any(|operation| {
        operation.path.ends_with("nullable_annotations.c")
            && operation.operation_kind == "pointer_dereference"
            && operation.state_at_operation == "maybe_null"
            && operation.complete
    }));
    assert!(output.nullable_operations.iter().all(|operation| {
        operation
            .path
            .ends_with("nullable_annotations.c")
            .then_some(operation.operation_kind.as_str())
            != Some("function_pointer_call")
    }));
    Ok(())
}

#[test]
fn nullable_operations_join_native_dereferences_to_proven_null_states() -> Result<()> {
    for (name, language, behavior) in [
        ("nullable_operations.c", Language::C, "undefined_behavior"),
        (
            "nullable_operations.cpp",
            Language::Cpp,
            "undefined_behavior",
        ),
        ("nullable_operations.go", Language::Go, "panic"),
    ] {
        let document = syntax::parse_file(fixture(name), language)?;
        let output = profile::extract(&document, Profile::NilKill);
        assert_eq!(output.nullable_operations.len(), 1, "{name}");
        assert!(output.nullable_operations.iter().any(|operation| {
            operation.operation_kind == "pointer_dereference"
                && operation.nil_behavior == behavior
                && operation.state_at_operation == "definitely_null"
                && operation.complete
                && !operation.place_id.is_empty()
                && operation.path.ends_with(name)
                && operation.span[0] > 0
        }));
    }
    Ok(())
}

#[test]
fn native_unevaluated_pointer_operands_do_not_create_nullable_operations() -> Result<()> {
    for (name, language) in [
        ("nullable_unevaluated.c", Language::C),
        ("nullable_unevaluated.cpp", Language::Cpp),
    ] {
        let document = syntax::parse_file(fixture(name), language)?;
        let output = profile::extract(&document, Profile::NilKill);
        assert_eq!(output.nullable_operations.len(), 1, "{name}");
        assert!(output.nullable_operations.iter().all(|operation| {
            operation.operation_kind == "pointer_dereference"
                && operation
                    .place_id
                    .contains("evaluated_dereference_is_reported")
                && operation.span[0] > 0
        }));
    }
    Ok(())
}

#[test]
fn java_nullable_receiver_operations_follow_direct_null_flow() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_java.java"), Language::Java)?;
    let output = profile::extract(&document, Profile::NilKill);

    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("NullableJava#unsafe:local:value")
            && state.state == "definitely_null"
            && state.complete
    }));
    assert!(output.nullable_operations.iter().any(|operation| {
        operation.operation_kind == "receiver_member_access"
            && operation.nil_behavior == "null_pointer_exception"
            && operation.state_at_operation == "definitely_null"
            && operation.complete
            && operation
                .place_id
                .contains("NullableJava#unsafe:local:value")
    }));
    assert!(output.nullable_refinements.iter().any(|refinement| {
        refinement
            .place_id
            .contains("NullableJava#guarded:local:value")
            && refinement.edge == "else"
            && refinement.state_on_edge == "definitely_non_null"
            && refinement.proof_kind == "nil_comparison"
            && refinement.complete
    }));
    assert!(output.nullable_operations.iter().any(|operation| {
        operation.operation_kind == "receiver_member_access"
            && operation.state_at_operation == "definitely_non_null"
            && operation.complete
            && operation
                .place_id
                .contains("NullableJava#guarded:local:value")
    }));
    Ok(())
}

#[test]
fn csharp_nullable_receiver_operations_follow_direct_null_flow() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_csharp.cs"), Language::CSharp)?;
    let output = profile::extract(&document, Profile::NilKill);

    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("NullableCSharp#Unsafe:local:value")
            && state.state == "definitely_null"
            && state.complete
    }));
    assert!(output.nullable_operations.iter().any(|operation| {
        operation.operation_kind == "receiver_member_access"
            && operation.nil_behavior == "null_reference_exception"
            && operation.state_at_operation == "definitely_null"
            && operation.complete
            && operation
                .place_id
                .contains("NullableCSharp#Unsafe:local:value")
    }));
    assert!(output.nullable_refinements.iter().any(|refinement| {
        refinement
            .place_id
            .contains("NullableCSharp#Guarded:local:value")
            && refinement.edge == "else"
            && refinement.state_on_edge == "definitely_non_null"
            && refinement.proof_kind == "nil_comparison"
            && refinement.complete
    }));
    assert!(output.nullable_operations.iter().any(|operation| {
        operation.operation_kind == "receiver_member_access"
            && operation.state_at_operation == "definitely_non_null"
            && operation.complete
            && operation
                .place_id
                .contains("NullableCSharp#Guarded:local:value")
    }));
    Ok(())
}

#[test]
fn typescript_null_and_undefined_receiver_operations_follow_direct_flow() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_typescript.ts"), Language::TypeScript)?;
    let output = profile::extract(&document, Profile::NilKill);

    for function in ["unsafeNull", "unsafeUndefined"] {
        assert!(output.nullable_states.iter().any(|state| {
            state
                .place_id
                .contains(&format!("NullableTypeScript#{function}:local:value"))
                && state.state == "definitely_null"
                && state.complete
        }));
        assert!(output.nullable_operations.iter().any(|operation| {
            operation.operation_kind == "receiver_member_access"
                && operation.nil_behavior == "type_error"
                && operation.state_at_operation == "definitely_null"
                && operation.complete
                && operation
                    .place_id
                    .contains(&format!("NullableTypeScript#{function}:local:value"))
        }));
    }
    assert!(output.nullable_refinements.iter().any(|refinement| {
        refinement
            .place_id
            .contains("NullableTypeScript#guarded:local:value")
            && refinement.edge == "else"
            && refinement.state_on_edge == "definitely_non_null"
            && refinement.proof_kind == "nil_comparison"
            && refinement.complete
    }));
    assert!(output.nullable_operations.iter().any(|operation| {
        operation.operation_kind == "receiver_member_access"
            && operation.state_at_operation == "definitely_non_null"
            && operation.complete
            && operation
                .place_id
                .contains("NullableTypeScript#guarded:local:value")
    }));
    assert!(output.nullable_operations.iter().all(|operation| {
        !operation
            .place_id
            .contains("NullableTypeScript#shadowedUndefined:local:undefined")
    }));
    Ok(())
}

#[test]
fn go_map_lookup_exports_presence_without_proving_payload_non_null() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_presence.go"), Language::Go)?;
    let output = profile::extract(&document, Profile::NilKill);
    assert!(output.presence_correlations.iter().any(|correlation| {
        correlation.semantics == "map_lookup"
            && correlation.branch_refinement == "presence_on_true"
            && correlation.complete
            && correlation.value_place_id.ends_with(":value")
            && correlation.presence_place_id.ends_with(":ok")
    }));
    assert!(output
        .nullable_states
        .iter()
        .all(|state| !state.place_id.ends_with(":value") || state.state != "definitely_non_null"));
    Ok(())
}

#[test]
fn go_type_assertions_and_channel_receives_export_presence_without_payload_proofs() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_go_presence_pairs.go"), Language::Go)?;
    let output = profile::extract(&document, Profile::NilKill);
    let semantics = output
        .presence_correlations
        .iter()
        .map(|correlation| correlation.semantics.as_str())
        .collect::<Vec<_>>();
    assert_eq!(semantics, vec!["channel_receive", "type_assertion"]);
    assert!(output
        .nullable_states
        .iter()
        .all(|state| !state.place_id.ends_with(":result") || state.state != "definitely_non_null"));
    Ok(())
}

#[test]
fn go_nullable_operations_distinguish_pointer_selectors_and_function_values() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_go_operations.go"), Language::Go)?;
    let output = profile::extract(&document, Profile::NilKill);
    let operations = output
        .nullable_operations
        .iter()
        .filter(|operation| operation.state_at_operation == "definitely_null" && operation.complete)
        .map(|operation| {
            (
                operation.operation_kind.as_str(),
                operation.nil_behavior.as_str(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        operations,
        vec![
            ("function_value_call", "panic"),
            ("pointer_selector", "panic")
        ]
    );
    Ok(())
}

#[test]
fn go_nullable_operations_cover_index_writes_and_channels() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_go_collections.go"), Language::Go)?;
    let output = profile::extract(&document, Profile::NilKill);
    let operations = output
        .nullable_operations
        .iter()
        .filter(|operation| operation.state_at_operation == "definitely_null" && operation.complete)
        .map(|operation| {
            (
                operation.operation_kind.as_str(),
                operation.nil_behavior.as_str(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        operations,
        vec![
            ("channel_close", "panic"),
            ("channel_send", "blocks"),
            ("indexed_write", "panic"),
        ]
    );
    Ok(())
}

#[test]
fn go_safe_nil_collection_operations_do_not_create_nullable_operations() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_go_safe_collections.go"), Language::Go)?;
    let output = profile::extract(&document, Profile::NilKill);
    assert!(output.nullable_operations.is_empty());
    Ok(())
}

#[test]
fn native_function_pointer_calls_are_nullable_operations() -> Result<()> {
    for (fixture_name, language) in [
        ("nullable_function_pointer.c", Language::C),
        ("nullable_function_pointer.cpp", Language::Cpp),
    ] {
        let document = syntax::parse_file(fixture(fixture_name), language)?;
        let output = profile::extract(&document, Profile::NilKill);
        let calls = output
            .nullable_operations
            .iter()
            .filter(|operation| operation.operation_kind == "function_pointer_call")
            .map(|operation| {
                (
                    operation.nil_behavior.as_str(),
                    operation.state_at_operation.as_str(),
                    operation.complete,
                )
            })
            .collect::<Vec<_>>();
        assert_eq!(
            calls,
            vec![
                ("undefined_behavior", "definitely_null", true),
                ("undefined_behavior", "unknown", false),
            ],
            "{fixture_name}"
        );
    }
    Ok(())
}

#[test]
fn hidden_enum_observations_use_the_primary_normalized_walk() -> Result<()> {
    let document = syntax::parse_file(fixture("hidden_enum_state.rb"), Language::Ruby)?;
    let output = profile::extract(&document, Profile::NilKill);
    let observations = output
        .hidden_enum_observations
        .iter()
        .filter(|observation| observation["kind"] == "state")
        .collect::<Vec<_>>();
    assert_eq!(observations.len(), 5);
    assert!(observations
        .iter()
        .filter(|observation| observation["event"] == "decision")
        .all(|observation| {
            observation["key"]
                .as_str()
                .is_some_and(|key| key.starts_with("state\0") && key.contains("\0Workflow\0"))
        }));
    assert_eq!(
        observations
            .iter()
            .filter(|observation| observation["event"] == "producer")
            .count(),
        2
    );
    assert_eq!(
        observations
            .iter()
            .flat_map(|observation| observation["values"].as_array().into_iter().flatten())
            .filter_map(|value| value["value"].as_str())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from(["\"complete\"", "\"draft\""])
    );
    assert_eq!(
        output
            .hidden_enum_observations
            .iter()
            .filter(|observation| observation["kind"] == "param")
            .count(),
        3
    );
    Ok(())
}

#[test]
fn hidden_enum_observations_preserve_closed_symbol_and_integer_domains() -> Result<()> {
    let document = syntax::parse_file(fixture("hidden_enum_symbol_integer.rb"), Language::Ruby)?;
    let output = profile::extract(&document, Profile::NilKill);
    let values = output
        .hidden_enum_observations
        .iter()
        .filter(|observation| observation["kind"] == "state")
        .flat_map(|observation| observation["values"].as_array().into_iter().flatten())
        .filter_map(|value| {
            Some((
                value["kind"].as_str()?.to_string(),
                value["value"].as_str()?.to_string(),
            ))
        })
        .collect::<BTreeSet<_>>();

    assert_eq!(
        values,
        BTreeSet::from([
            ("Integer".to_string(), "1".to_string()),
            ("Integer".to_string(), "2".to_string()),
            ("Symbol".to_string(), ":done".to_string()),
            ("Symbol".to_string(), ":queued".to_string()),
        ])
    );
    Ok(())
}

#[test]
fn hidden_enum_observations_mark_nonliteral_state_writes_open_world() -> Result<()> {
    let document = syntax::parse_file(fixture("hidden_enum_open_world.rb"), Language::Ruby)?;
    let output = profile::extract(&document, Profile::NilKill);
    let events = output
        .hidden_enum_observations
        .iter()
        .filter(|observation| observation["kind"] == "state")
        .map(|observation| {
            (
                observation["event"].as_str().unwrap_or_default(),
                observation["reason"].as_str(),
            )
        })
        .collect::<BTreeSet<_>>();
    assert!(events.contains(&("producer", None)));
    assert!(events.contains(&("blocker", Some("nonliteral_assignment"))));
    assert!(events.contains(&("decision", None)));
    assert_eq!(
        output
            .hidden_enum_observations
            .iter()
            .filter(|observation| observation["event"] == "producer")
            .count(),
        1,
        "a collection assignment is an open-world blocker, not a scalar producer"
    );
    Ok(())
}

#[test]
fn hidden_enum_observations_keep_same_spelled_locals_in_distinct_callables() -> Result<()> {
    let document = syntax::parse_file(fixture("hidden_enum_unrelated_locals.rb"), Language::Ruby)?;
    let output = profile::extract(&document, Profile::NilKill);
    let locals = output
        .hidden_enum_observations
        .iter()
        .filter(|observation| observation["kind"] == "local")
        .collect::<Vec<_>>();

    assert_eq!(locals.len(), 4);
    assert_eq!(
        locals
            .iter()
            .filter_map(|observation| observation["method"].as_str())
            .collect::<BTreeSet<_>>(),
        BTreeSet::from(["draft?", "sent?"])
    );
    assert!(locals.iter().all(|observation| {
        observation["key"]
            .as_str()
            .is_some_and(|key| key.starts_with("local\0") && key.ends_with("\0state"))
    }));
    Ok(())
}

#[test]
fn hidden_enum_observations_scale_with_geometric_file_and_callable_growth() -> Result<()> {
    use std::io::Write;

    let dir = tempfile::tempdir()?;
    for size in [1_usize, 4, 16] {
        let mut outputs = Vec::new();
        for file_index in 0..size {
            let path = dir.path().join(format!("workflow_{size}_{file_index}.rb"));
            let mut source = std::fs::File::create(&path)?;
            source.write_all(format!("class Workflow{file_index}\n").as_bytes())?;
            for callable_index in 0..size {
                source.write_all(
                    format!(
                        "  def transition_{callable_index}\n    state = \"draft\"\n    state == \"draft\"\n  end\n"
                    )
                    .as_bytes(),
                )?;
            }
            source.write_all(b"end\n")?;
            let document = syntax::parse_file(path, Language::Ruby)?;
            outputs.push(profile::extract(&document, Profile::NilKill));
        }

        let output = profile::merge(outputs, Profile::NilKill);
        let locals = output
            .hidden_enum_observations
            .iter()
            .filter(|observation| observation["kind"] == "local")
            .collect::<Vec<_>>();
        let callable_count = size * size;
        assert_eq!(locals.len(), callable_count * 2, "size={size}");
        assert_eq!(
            locals
                .iter()
                .filter_map(|observation| observation["key"].as_str())
                .collect::<BTreeSet<_>>()
                .len(),
            callable_count,
            "size={size}"
        );
    }
    Ok(())
}

#[test]
fn native_deliberate_domains_do_not_emit_hidden_enum_observations() -> Result<()> {
    for (fixture_name, language) in [
        ("go/core.go", Language::Go),
        ("c/core.c", Language::C),
        ("cpp/core.cpp", Language::Cpp),
    ] {
        let document = syntax::parse_file(
            PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("examples")
                .join("syntax-facts")
                .join(fixture_name),
            language,
        )?;
        let output = profile::extract(&document, Profile::NilKill);
        assert!(
            output.hidden_enum_observations.is_empty(),
            "{fixture_name} must not turn native named constants or enums into primitive-domain candidates"
        );
    }
    Ok(())
}

#[test]
fn native_pointer_slot_mutation_invalidates_the_original_null_proof() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_alias_mutation.cpp"), Language::Cpp)?;
    let output = profile::extract(&document, Profile::NilKill);

    assert!(output.nullable_states.iter().any(|state| {
        state.place_id.contains("use_after_slot_update")
            && state.place_id.ends_with(":value")
            && state.state == "unknown"
            && !state.complete
    }));
    assert!(output.nullable_operations.iter().all(|operation| {
        operation.span[0] != 5 || operation.operation_kind != "pointer_dereference"
    }));
    Ok(())
}

#[test]
fn c_allocator_contracts_seed_maybe_null_operation_states() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_allocators.c"), Language::C)?;
    let output = profile::extract(&document, Profile::NilKill);
    let operations = output
        .nullable_operations
        .iter()
        .filter(|operation| operation.operation_kind == "pointer_dereference")
        .collect::<Vec<_>>();
    assert_eq!(operations.len(), 2);
    assert!(operations.iter().all(|operation| {
        operation.nil_behavior == "undefined_behavior"
            && operation.state_at_operation == "maybe_null"
            && operation.complete
    }));
    assert_eq!(
        output
            .nullable_states
            .iter()
            .filter(|state| state.state == "maybe_null" && state.complete)
            .count(),
        2
    );
    Ok(())
}

#[test]
fn cpp_allocator_contracts_seed_maybe_null_operation_states() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_allocators.cpp"), Language::Cpp)?;
    let output = profile::extract(&document, Profile::NilKill);
    let operations = output
        .nullable_operations
        .iter()
        .filter(|operation| operation.operation_kind == "pointer_dereference")
        .collect::<Vec<_>>();
    assert_eq!(operations.len(), 2);
    assert!(operations.iter().all(|operation| {
        operation.nil_behavior == "undefined_behavior"
            && operation.state_at_operation == "maybe_null"
            && operation.complete
    }));
    Ok(())
}

#[test]
fn cpp_special_nullable_sources_preserve_throwing_new_as_unknown() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_cpp_special_sources.cpp"), Language::Cpp)?;
    let output = profile::extract(&document, Profile::NilKill);
    let complete = output
        .nullable_operations
        .iter()
        .filter(|operation| operation.complete)
        .map(|operation| {
            (
                operation.operation_kind.as_str(),
                operation.state_at_operation.as_str(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        complete,
        vec![
            ("pointer_selector", "maybe_null"),
            ("pointer_dereference", "maybe_null"),
        ]
    );
    assert!(output.nullable_operations.iter().any(|operation| {
        operation.operation_kind == "pointer_dereference"
            && operation.state_at_operation == "unknown"
            && !operation.complete
    }));
    Ok(())
}

#[test]
fn cpp_macro_alias_template_and_overload_boundaries_stay_unknown() -> Result<()> {
    let document = syntax::parse_file(fixture("nullable_cpp_boundaries.cpp"), Language::Cpp)?;
    let output = profile::extract(&document, Profile::NilKill);

    for function in ["macro_and_alias_boundary", "overload_boundary"] {
        assert!(
            output.nullable_operations.iter().any(|operation| {
                operation.path.ends_with("nullable_cpp_boundaries.cpp")
                    && operation.state_at_operation == "unknown"
                    && !operation.complete
                    && operation.operation_kind == "pointer_dereference"
                    && operation.node_id.contains(function)
            }),
            "{function}"
        );
    }
    Ok(())
}

#[test]
fn typescript_variable_bound_callables_are_emitted_as_project_methods() -> Result<()> {
    let document = syntax::parse_file(fixture("typescript_callable.ts"), Language::TypeScript)?;
    let output = profile::extract(&document, Profile::Espalier);
    let methods = output
        .methods
        .iter()
        .map(|method| method.name.as_str())
        .collect::<Vec<_>>();

    assert!(methods.contains(&"double"), "methods={methods:?}");
    assert!(methods.contains(&"increment"), "methods={methods:?}");
    assert!(methods.contains(&"useCallable"), "methods={methods:?}");
    let double = output
        .methods
        .iter()
        .find(|method| method.name == "double")
        .context("missing double method")?;
    let binding_column = fs::read_to_string(fixture("typescript_callable.ts"))?
        .lines()
        .next()
        .and_then(|line| line.find("double"))
        .context("missing double binding")?;
    assert!(
        double.span.is_some_and(|span| span[1] <= binding_column),
        "span={:?}, binding_column={binding_column}",
        double.span
    );
    assert!(output.calls.iter().any(|call| call.message == "double"));
    assert!(output.calls.iter().any(|call| call.message == "increment"));
    let nested_fact = output
        .complexity_facts
        .iter()
        .find(|fact| fact.function == "nested")
        .context("missing complexity facts for nested bound callable")?;
    assert!(
        nested_fact
            .call_contexts
            .iter()
            .any(|context| context.message == "increment"),
        "contexts={:?}",
        nested_fact.call_contexts
    );
    Ok(())
}

#[test]
fn source_facing_fields_preserve_native_declared_type_spelling() -> Result<()> {
    for (fixture_name, language, field, expected) in [
        (
            "native_field_types.rs",
            Language::Rust,
            "items",
            "Vec<String>",
        ),
        (
            "native_field_types.hpp",
            Language::Cpp,
            "name",
            "std::string",
        ),
        ("native_field_types.cs", Language::CSharp, "Name", "string"),
    ] {
        let document = syntax::parse_file(fixture(fixture_name), language)?;
        let output = profile::extract(&document, Profile::NilKill);
        let record = output
            .fields
            .iter()
            .find(|record| record.name == field)
            .with_context(|| format!("missing {fixture_name} field {field}"))?;
        assert_eq!(
            record.declared_type.as_deref(),
            Some(expected),
            "{fixture_name}"
        );
        let definition = output
            .type_definitions
            .iter()
            .find(|definition| definition.kind == "state_field" && definition.name == field)
            .with_context(|| format!("missing {fixture_name} state-field definition {field}"))?;
        assert_eq!(
            definition.declared_type.as_deref(),
            Some(expected),
            "{fixture_name}"
        );
    }
    Ok(())
}

#[test]
fn cpp_field_projections_and_named_casts_are_not_calls() -> Result<()> {
    let tmp = tempfile::Builder::new().suffix(".cpp").tempfile()?;
    fs::write(
        tmp.path(),
        r#"struct Data { int value; };
struct Holder { Data data; int read() { return data.value; } };
int helper(int value) { return value; }
int analyze(Data* data, int input) {
    int projected = data->value;
    long widened = static_cast<long>(input);
    return helper(static_cast<int>(projected + widened));
}
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Cpp)?;
    assert!(
        document
            .state_reads
            .iter()
            .any(|read| read.receiver == "data" && read.field == "value"),
        "field projection should remain a state read: {:?}",
        document.state_reads
    );
    let output = profile::extract(&document, Profile::Espalier);
    let messages = output
        .calls
        .iter()
        .map(|call| call.message.as_str())
        .collect::<Vec<_>>();
    assert!(messages.contains(&"helper"), "calls={messages:?}");
    assert!(!messages.contains(&"value"), "calls={messages:?}");
    assert!(!messages.contains(&"data"), "calls={messages:?}");
    assert!(
        messages
            .iter()
            .all(|message| !message.starts_with("static_cast<")),
        "calls={messages:?}"
    );
    Ok(())
}

#[test]
fn go_short_declaration_does_not_reuse_outer_non_nil_proof() -> Result<()> {
    let document = syntax::parse_file(fixture("go_shadowing.go"), Language::Go)?;
    assert!(document.redundant_nil_guards.is_empty());
    Ok(())
}

#[test]
fn exact_native_stdlib_calls_emit_normalized_complexity_facts() -> Result<()> {
    for (name, language, message, time, space) in [
        ("stdlib_registry.c", Language::C, "strcmp", "O(N)", "O(1)"),
        (
            "stdlib_registry.go",
            Language::Go,
            "BinarySearch",
            "O(log N)",
            "O(1)",
        ),
        (
            "stdlib_registry.java",
            Language::Java,
            "copyOf",
            "O(N)",
            "O(N)",
        ),
        (
            "stdlib_registry.cs",
            Language::CSharp,
            "BinarySearch",
            "O(log N)",
            "O(1)",
        ),
        (
            "stdlib_registry.py",
            Language::Python,
            "casefold",
            "O(N)",
            "O(N)",
        ),
    ] {
        let document = syntax::parse_file(fixture(name), language)?;
        let output = profile::extract(&document, Profile::Espalier);
        let call = output
            .complexity_facts
            .iter()
            .flat_map(|facts| facts.call_contexts.iter())
            .find(|call| call.message == message)
            .with_context(|| format!("missing {name} {message} complexity fact"))?;
        assert_eq!(call.known_time_complexity.as_deref(), Some(time), "{name}");
        assert_eq!(
            call.known_space_complexity.as_deref(),
            Some(space),
            "{name}"
        );
    }
    Ok(())
}

#[test]
fn go_builtins_are_modeled_as_language_intrinsics_without_scip_targets() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".go").tempfile()?;
    tmp.write_all(
        br#"package sample

func builtins(xs []int, values map[string]int, done chan int) int {
    result := make([]int, len(xs))
    result = append(result, xs...)
    copy(result, xs)
    delete(values, "missing")
    close(done)
    return int(int32(len(result)))
}

func fail() {
    panic("failed")
}

type holder struct { values []int }

// Go has no implicit method dispatch: the bare len below remains the
// predeclared function even though its enclosing type has a method named len.
func (h *holder) len() int {
    return len(h.values)
}
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Go)?;
    let output = profile::extract(&document, Profile::Espalier);
    let expected = [
        ("len", "O(1)", "O(1)"),
        ("make", "O(N)", "O(N)"),
        ("append", "O(N)", "O(N)"),
        ("copy", "O(N)", "O(1)"),
        ("delete", "O(1)", "O(1)"),
        ("close", "O(1)", "O(1)"),
        ("int", "O(1)", "O(1)"),
        ("int32", "O(1)", "O(1)"),
        ("panic", "O(N)", "O(1)"),
    ];

    for (message, time, space) in expected {
        let matching = output
            .calls
            .iter()
            .filter(|call| call.message == message)
            .collect::<Vec<_>>();
        assert!(!matching.is_empty(), "missing Go builtin {message}");
        assert!(matching.iter().all(|call| call.target.is_none()));
        assert!(matching
            .iter()
            .all(|call| call.known_time_complexity.as_deref() == Some(time)));
        assert!(matching
            .iter()
            .all(|call| call.known_space_complexity.as_deref() == Some(space)));
    }
    let holder_len = output
        .complexity_facts
        .iter()
        .find(|fact| fact.owner == "holder" && fact.function == "len")
        .context("missing holder.len complexity facts")?;
    assert_eq!(holder_len.recursion.calls, 0);
    Ok(())
}

#[test]
fn go_top_level_calls_retain_declared_parameter_receiver_types() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".go").tempfile()?;
    tmp.write_all(
        br#"package sample

type worker interface { Work() }

func run(value worker) {
    value.Work()
}
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Go)?;
    let output = profile::extract(&document, Profile::Espalier);
    assert!(
        output
            .owners
            .iter()
            .any(|owner| owner.name == "worker" && owner.kind == "interface"),
        "{:#?}",
        output.owners
    );
    let call = output
        .calls
        .iter()
        .find(|call| call.message == "Work")
        .context("missing Work call")?;

    assert_eq!(call.receiver_type.as_deref(), Some("worker"));
    assert_eq!(
        call.receiver_type_origin.as_deref(),
        Some("declared_parameter")
    );
    Ok(())
}

#[test]
fn go_zero_argument_receiver_calls_are_not_degraded_to_property_reads() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".go").tempfile()?;
    tmp.write_all(
        br#"package sample

type pool struct{}

func (p *pool) IsClosed() bool { return false }
func (p *pool) Running() int { return 0 }

func (p *pool) ready() bool {
    return !p.IsClosed() && p.Running() > 0
}
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Go)?;
    let output = profile::extract(&document, Profile::Espalier);
    let calls = output
        .calls
        .iter()
        .filter(|call| call.message == "IsClosed" || call.message == "Running")
        .collect::<Vec<_>>();

    assert_eq!(calls.len(), 2, "{calls:#?}");
    assert!(calls.iter().any(|call| {
        call.receiver == "self" && call.message == "IsClosed" && call.argument_count == 0
    }));
    assert!(calls.iter().any(|call| {
        call.receiver == "self" && call.message == "Running" && call.argument_count == 0
    }));
    Ok(())
}

#[test]
fn go_if_initializer_calls_remain_in_the_normalized_condition_sequence() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".go").tempfile()?;
    tmp.write_all(
        br#"package sample

type pool struct{}

func (p *pool) Next() *int { return nil }

func (p *pool) ready() bool {
    if next := p.Next(); next != nil {
        return true
    }
    return false
}
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Go)?;
    let output = profile::extract(&document, Profile::Espalier);
    let calls = output
        .calls
        .iter()
        .filter(|call| call.message == "Next")
        .collect::<Vec<_>>();

    assert_eq!(calls.len(), 1, "{calls:#?}");
    assert_eq!(calls[0].receiver, "self");
    assert_eq!(calls[0].function, "ready");
    assert_eq!(calls[0].argument_count, 0);
    Ok(())
}

#[test]
fn go_local_bindings_retain_provable_interface_types() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".go").tempfile()?;
    tmp.write_all(
        br#"package sample

type bundle struct { errs []error }

func run(value error, values bundle, ch chan error) {
    var local error
    local.Error()
    for _, ranged := range values.errs { ranged.Error() }
    if received := <-ch; received != nil { received.Error() }
    switch narrowed := value.(type) {
    default:
        narrowed.Error()
    }
}
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Go)?;
    let output = profile::extract(&document, Profile::Espalier);
    let calls = output
        .calls
        .iter()
        .filter(|call| call.message == "Error")
        .collect::<Vec<_>>();

    assert_eq!(calls.len(), 4, "{calls:#?}");
    assert!(
        calls
            .iter()
            .all(|call| call.receiver_type.as_deref() == Some("error")),
        "{calls:#?}"
    );
    assert!(
        calls.iter().all(|call| {
            call.known_time_complexity.as_deref() == Some("O(C)")
                && call.complexity_bound_quality.as_deref()
                    == Some("upper_bound_parametric_callback_once")
        }),
        "{calls:#?}"
    );
    Ok(())
}

#[test]
fn go_declared_function_fields_are_parametric_callbacks() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".go").tempfile()?;
    tmp.write_all(
        br#"package sample

type worker struct { fn func(int) }
type wrapper struct { worker *worker }

func (w *worker) direct() { w.fn(1) }
func (w *wrapper) projected() { w.worker.fn(1) }
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Go)?;
    let output = profile::extract(&document, Profile::Espalier);
    let calls = output
        .calls
        .iter()
        .filter(|call| call.message == "fn")
        .collect::<Vec<_>>();

    assert_eq!(calls.len(), 2, "{calls:#?}");
    assert!(
        calls.iter().all(|call| {
            call.callback_receiver
                && call.known_time_complexity.as_deref() == Some("O(C)")
                && call.complexity_bound_quality.as_deref()
                    == Some("upper_bound_parametric_callback_once")
        }),
        "{calls:#?}"
    );
    Ok(())
}

#[test]
fn ruby_calculator_extracts_methods() -> Result<()> {
    let file = examples_dir().join("ruby_calculator.rb");
    let document = syntax::parse_file(file.clone(), Language::Ruby)
        .with_context(|| format!("parse {}", file.display()))?;

    let output = profile::extract(&document, Profile::Espalier);

    // Methods - the normalized extractor detects the two functions
    assert!(
        !output.methods.is_empty(),
        "should have at least one method"
    );
    let add_method = output
        .methods
        .iter()
        .find(|m| m.name == "add")
        .with_context(|| "missing 'add' method")?;
    assert_eq!(add_method.owner, "Calculator");
    assert_eq!(add_method.kind, "instance");
    assert_eq!(add_method.dispatch_name, "add");
    assert!(add_method.raw_source.contains("def add"));
    assert_eq!(
        add_method.normalized_source,
        add_method
            .raw_source
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
    );

    let result_method = output
        .methods
        .iter()
        .find(|m| m.name == "result")
        .with_context(|| "missing 'result' method")?;
    assert_eq!(result_method.owner, "Calculator");

    Ok(())
}

#[test]
fn espalier_profile_carries_dispatch_and_resolved_flow_types() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".rb").tempfile()?;
    tmp.write_all(
        br#"Record = Struct.new(:value)

class Target
  def initialize(value); end
  def self.build(value = nil); end
  def work; end
end

class Source
  extend T::Sig
  sig { params(target: Target).void }
  def run(target)
    T.let(target, Target)
    Target.new(target)
    Record.new(target)
    Target.build(target)
    target.work
  end
end
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Ruby)?;
    let output = profile::extract(&document, Profile::Espalier);

    let build = output
        .methods
        .iter()
        .find(|method| method.name == "self.build")
        .unwrap();
    assert_eq!(build.kind, "class");
    assert_eq!(build.dispatch_name, "build");

    let target_flow = output
        .flow_local_types
        .iter()
        .find(|fact| {
            fact.get("function").and_then(Value::as_str) == Some("run")
                && fact.get("name").and_then(Value::as_str) == Some("target")
                && fact.get("complete").and_then(Value::as_bool) == Some(true)
        })
        .context("missing complete target flow type")?;
    let resolved = target_flow
        .get("resolved_types")
        .and_then(Value::as_array)
        .context("missing normalized resolved flow types")?;
    assert_eq!(resolved.len(), 1);
    assert_eq!(
        resolved[0].get("kind").and_then(Value::as_str),
        Some("Primitive")
    );
    assert_eq!(
        resolved[0].get("data").and_then(Value::as_str),
        Some("Target")
    );
    let static_call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.receiver == "Target" && call.message == "build")
        .with_context(|| format!("missing static Target.build call in {:?}", output.calls))?;
    assert_eq!(static_call.receiver_kind, "type");
    let constructor = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.receiver == "Target" && call.message == "new")
        .context("missing Target.new call")?;
    assert_eq!(
        constructor.constructor_target.as_deref(),
        Some("initialize")
    );
    let type_operation = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.receiver == "T" && call.message == "let")
        .context("missing T.let call")?;
    assert_eq!(
        type_operation.known_time_complexity.as_deref(),
        Some("O(1)")
    );
    assert_eq!(
        type_operation.known_space_complexity.as_deref(),
        Some("O(1)")
    );
    let record = output
        .struct_declarations
        .iter()
        .find(|declaration| declaration.class == "Record")
        .context("missing Record declaration")?;
    assert_eq!(record.constant_operations, ["new", "[]", "[]="]);

    Ok(())
}

#[test]
fn nil_kill_profile_exports_replayable_type_dependencies() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".rb").tempfile()?;
    tmp.write_all(
        br#"class Pipeline
  def initialize
    @state = load
    @typed = T.let(load, String)
  end

  def state
    @state
  end

  def fanout(source)
    first = source
    second = first
    typed_copy = @typed
    typed_local = T.let(load, String)
    fixed = "ok"
    mystery = load
    mapped = [source].map { |mapped_item| mapped_item.to_s }
    [first, second, fixed, mystery]
  end

  def passthrough(source)
    copy = source
    copy
  end

  def choose(flag, left, right)
    if flag
      chosen = left
    else
      chosen = right
    end
    chosen
  end
end
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Ruby)?;
    let output = profile::extract(&document, Profile::NilKill);

    let source_root = output
        .type_dependencies
        .iter()
        .find(|fact| {
            fact["name"] == "source"
                && fact["kind"] == "definition"
                && fact["candidate"] == true
                && fact["candidate_kind"] == "parameter"
        })
        .context("missing untyped parameter dependency root")?;
    let source_id = source_root["id"]
        .as_str()
        .context("parameter root has no stable id")?;

    let first_definition = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "first" && fact["kind"] == "definition")
        .context("missing direct-copy definition")?;
    assert_eq!(first_definition["candidate"], false);
    assert!(first_definition["requirements"]
        .as_array()
        .context("definition requirements")?
        .iter()
        .any(|requirement| requirement == source_id));

    let second_read = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "second" && fact["kind"] == "flow_read")
        .context("missing downstream flow read")?;
    assert_eq!(second_read["resolved"], false);
    assert!(!second_read["requirements"]
        .as_array()
        .context("read requirements")?
        .is_empty());

    let fixed_definition = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "fixed" && fact["kind"] == "definition")
        .context("missing literal definition")?;
    assert_eq!(fixed_definition["resolved"], true);
    assert_eq!(fixed_definition["candidate"], false);

    let mystery_definition = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "mystery" && fact["kind"] == "definition")
        .context("missing opaque definition")?;
    assert_eq!(mystery_definition["candidate"], true);
    assert_eq!(mystery_definition["candidate_kind"], "local");

    let merged = profile::merge(vec![output.clone()], Profile::NilKill);
    assert_eq!(merged.type_dependencies, output.type_dependencies);
    assert!(output
        .type_dependencies
        .iter()
        .filter(|fact| fact["candidate_kind"] == "local" || fact["candidate_kind"] == "parameter")
        .all(|fact| fact["id"]
            .as_str()
            .is_some_and(|id| id.contains(tmp.path().to_string_lossy().as_ref()))));
    let espalier = profile::extract(&document, Profile::Espalier);
    assert!(espalier.type_dependencies.is_empty());

    let passthrough = output
        .return_origins
        .iter()
        .find(|origin| origin["method"] == "passthrough")
        .context("missing passthrough return origin")?;
    let source = passthrough["sources"]
        .as_array()
        .and_then(|sources| sources.first())
        .context("missing passthrough return source")?;
    assert_eq!(source["kind"], "unknown");
    assert!(source["type_dependency_id"]
        .as_str()
        .is_some_and(|id| id.starts_with("type-read:")));
    let state_roots = output
        .type_dependencies
        .iter()
        .filter(|fact| fact["name"] == "@state" && fact["candidate"] == true)
        .collect::<Vec<_>>();
    assert_eq!(state_roots.len(), 1);
    assert_eq!(state_roots[0]["candidate_kind"], "instance_field");
    let state_read = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "@state" && fact["kind"] == "flow_read")
        .context("missing state read")?;
    assert_eq!(
        state_read["requirements"],
        json!([state_roots[0]["id"].clone()])
    );
    let typed_root = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "@typed" && fact["kind"] == "definition")
        .context("missing typed state root")?;
    assert_eq!(typed_root["resolved"], true);
    assert_eq!(typed_root["candidate"], false);
    let typed_copy = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "typed_copy" && fact["kind"] == "definition")
        .context("missing copy from typed state")?;
    assert_eq!(
        typed_copy["requirements"],
        json!([typed_root["id"].clone()])
    );
    let typed_local = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "typed_local" && fact["kind"] == "definition")
        .context("missing T.let local definition")?;
    assert_eq!(typed_local["resolved"], true);
    assert_eq!(typed_local["candidate"], false);
    let mapped_definition = output
        .type_dependencies
        .iter()
        .find(|fact| {
            fact["function"] == "fanout"
                && fact["name"] == "mapped_item"
                && fact["kind"] == "definition"
        })
        .context("missing nested callback definition")?;
    let mapped_read = output
        .type_dependencies
        .iter()
        .find(|fact| {
            fact["function"] == "fanout"
                && fact["name"] == "mapped_item"
                && fact["kind"] == "flow_read"
        })
        .context("missing nested callback read")?;
    assert_eq!(
        mapped_read["requirements"],
        json!([mapped_definition["id"].clone()])
    );
    let chosen_read = output
        .type_dependencies
        .iter()
        .find(|fact| {
            fact["function"] == "choose" && fact["name"] == "chosen" && fact["kind"] == "flow_read"
        })
        .context("missing diamond-join read")?;
    assert_eq!(
        chosen_read["requirements"]
            .as_array()
            .context("diamond requirements")?
            .len(),
        2
    );
    Ok(())
}

#[test]
fn nil_kill_profile_preserves_weak_declared_shapes_without_marking_them_resolved() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".rb").tempfile()?;
    tmp.write_all(
        br#"class TypedInputs
  extend T::Sig
  sig { params(strong: String, weak: T::Array[T.untyped]).void }
  def run(strong, weak)
    strong.to_s
    weak.length
  end
end
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Ruby)?;
    let declared = document
        .method_param_types
        .get(&format!("TypedInputs\0run\0{}", 4))
        .context("missing declared parameter shapes")?;
    assert_eq!(
        declared.get("weak").map(String::as_str),
        Some("T::Array[T.untyped]")
    );

    let output = profile::extract(&document, Profile::NilKill);
    let parameter = |name: &str| {
        output.type_dependencies.iter().find(|fact| {
            fact["function"] == "run"
                && fact["name"] == name
                && fact["kind"] == "definition"
                && fact["candidate_kind"] == "parameter"
        })
    };
    let strong = parameter("strong").context("missing strong parameter dependency")?;
    let weak = parameter("weak").context("missing weak parameter dependency")?;
    assert_eq!(strong["resolved"], true);
    assert_eq!(strong["candidate"], false);
    assert_eq!(weak["resolved"], false);
    assert_eq!(weak["candidate"], true);
    Ok(())
}

#[test]
fn nil_kill_profile_connects_program_globals_across_owners_and_files() -> Result<()> {
    use std::io::Write;

    let mut writer = tempfile::Builder::new().suffix(".rb").tempfile()?;
    writer.write_all(b"class Writer\n  def write\n    $shared = \"ready\"\n  end\nend\n")?;
    let mut reader = tempfile::Builder::new().suffix(".rb").tempfile()?;
    reader.write_all(b"class Reader\n  def read\n    $shared\n  end\nend\n")?;

    let output = profile::merge(
        vec![
            profile::extract(
                &syntax::parse_file(writer.path().to_path_buf(), Language::Ruby)?,
                Profile::NilKill,
            ),
            profile::extract(
                &syntax::parse_file(reader.path().to_path_buf(), Language::Ruby)?,
                Profile::NilKill,
            ),
        ],
        Profile::NilKill,
    );
    let roots = output
        .type_dependencies
        .iter()
        .filter(|fact| fact["name"] == "$shared" && fact["kind"] == "definition")
        .collect::<Vec<_>>();
    assert_eq!(roots.len(), 1, "a program global must have one DFG root");
    assert_eq!(roots[0]["id"], "type-root:state:global:$shared");
    let read = output
        .type_dependencies
        .iter()
        .find(|fact| fact["name"] == "$shared" && fact["kind"] == "flow_read")
        .context("missing cross-file global read")?;
    assert_eq!(read["requirements"], json!([roots[0]["id"].clone()]));
    Ok(())
}

#[test]
fn profile_merge_combines_two_files() -> Result<()> {
    let calc = examples_dir().join("ruby_calculator.rb");
    let greeter = examples_dir().join("ruby_greeter.rb");

    let doc_calc = syntax::parse_file(calc, Language::Ruby)?;
    let doc_greeter = syntax::parse_file(greeter, Language::Ruby)?;

    let mut out_calc = profile::extract(&doc_calc, Profile::Espalier);
    let mut out_greeter = profile::extract(&doc_greeter, Profile::Espalier);

    assert!(!out_calc.methods.is_empty());
    assert!(!out_greeter.methods.is_empty());

    // Inject state_protocols and state_param_origins to test merge logic
    out_calc
        .state_protocols
        .insert("Service\u{0}client".to_string(), vec!["read".to_string()]);
    out_greeter
        .state_protocols
        .insert("Service\u{0}client".to_string(), vec!["write".to_string()]);

    out_calc.state_param_origins.insert(
        "Worker\u{0}run\u{0}param".to_string(),
        vec!["total".to_string()],
    );
    out_greeter.state_param_origins.insert(
        "Worker\u{0}run\u{0}param".to_string(),
        vec!["other".to_string()],
    );

    // Inject NilKill fields to test nil_kill merge logic
    out_calc
        .collection_index_lookups
        .push(serde_json::json!("lookup1"));
    out_greeter
        .collection_index_lookups
        .push(serde_json::json!("lookup2"));
    out_calc
        .hash_record_blockers
        .push(serde_json::json!("blocker"));
    out_calc.tlet_sites.push(serde_json::json!("tlet"));
    out_calc.dead_nil_checks.push(serde_json::json!("dead"));
    out_calc
        .deterministic_guards
        .push(serde_json::json!("guard"));
    out_calc.return_origins.push(serde_json::json!("origin"));
    out_calc
        .noreturn_methods
        .push(serde_json::json!("noreturn"));

    let merged = profile::merge(vec![out_calc, out_greeter], Profile::NilKill);
    assert!(merged.methods.len() > 1, "merge should combine methods");

    // Assert on merged state_protocols and state_param_origins
    let proto = merged.state_protocols.get("Service\u{0}client").unwrap();
    assert!(proto.contains(&"read".to_string()));
    assert!(proto.contains(&"write".to_string()));

    let origins = merged
        .state_param_origins
        .get("Worker\u{0}run\u{0}param")
        .unwrap();
    assert!(origins.contains(&"total".to_string()));
    assert!(origins.contains(&"other".to_string()));

    // Assert on merged NilKill fields
    assert_eq!(merged.collection_index_lookups.len(), 2);
    assert_eq!(merged.hash_record_blockers.len(), 1);
    assert_eq!(merged.tlet_sites.len(), 1);
    assert_eq!(merged.dead_nil_checks.len(), 1);
    assert_eq!(merged.deterministic_guards.len(), 1);
    assert_eq!(merged.return_origins.len(), 1);
    assert_eq!(merged.noreturn_methods.len(), 1);

    Ok(())
}

#[test]
fn nil_kill_profile_produces_same_core_structure() -> Result<()> {
    let file = examples_dir().join("ruby_calculator.rb");
    let document = syntax::parse_file(file.clone(), Language::Ruby)?;

    let output = profile::extract(&document, Profile::NilKill);

    // Core facts are the same; nil-kill specific arrays exist but are empty
    assert!(!output.methods.is_empty());
    assert!(output.collection_index_lookups.is_empty());
    assert!(output.tlet_sites.is_empty());
    assert!(output.dead_nil_checks.is_empty());

    Ok(())
}

#[test]
fn declaration_pressure_is_normalized_for_sorbet_and_typed_python() -> Result<()> {
    use std::io::Write;

    let mut ruby = tempfile::Builder::new().suffix(".rb").tempfile()?;
    write!(ruby, "extend T::Sig\nPayload = T.type_alias {{ T.nilable(T.any(String, Integer, Float, Symbol)) }}\n")?;
    let ruby_doc = syntax::parse_file(ruby.path().to_path_buf(), Language::Ruby)?;
    let ruby_rows = profile::extract_declaration_type_pressures(&ruby_doc);
    let ruby_alias = ruby_rows
        .iter()
        .find(|row| row.declaration_name == "Payload")
        .context("missing Sorbet alias pressure")?;
    assert_eq!(ruby_alias.union_width, 4);
    assert!(ruby_alias.nilable);

    let mut python = tempfile::Builder::new().suffix(".py").tempfile()?;
    write!(
        python,
        "def parse(value: str | int | float | bool | None) -> object:\n    return value\n"
    )?;
    let python_doc = syntax::parse_file(python.path().to_path_buf(), Language::Python)?;
    let python_rows = profile::extract_declaration_type_pressures(&python_doc);
    let python_param = python_rows
        .iter()
        .find(|row| row.declaration_name == "parse" && row.slot == "param:value")
        .context("missing Python parameter pressure")?;
    assert_eq!(python_param.union_width, 4);
    assert!(python_param.nilable);
    Ok(())
}

#[test]
fn trace_plan_profile_keeps_elision_facts_and_skips_heavy_analysis() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".rb").tempfile()?;
    tmp.write_all(
        br#"class Worker
  class MutableState < T::Struct
    const :name, String
    prop :items, T::Array[String], factory: -> { [] }
  end

  Payload = Data.define(:name, :metadata)
  sig { params(value: T.untyped).returns(T.untyped) }
  def call(value)
    @items = T.let([], T::Array[String])
    value
  end
end
"#,
    )?;
    let path = tmp.path().to_path_buf();
    let document = syntax::parse_file(path.clone(), Language::Ruby)?;

    let output = profile::extract(&document, Profile::TracePlan);

    assert_eq!(output.methods.len(), 1);
    assert!(output
        .tlet_sites
        .iter()
        .any(|site| { site.get("type").and_then(Value::as_str) == Some("T::Array[String]") }));
    assert!(output.state_type_records.iter().any(|record| {
        record.owner == "Worker"
            && record.field == "items"
            && record.declared_type.to_sorbet_string() == "T::Array[String]"
    }));
    assert!(output.struct_declarations.iter().any(|declaration| {
        declaration.class == "Worker::Payload"
            && declaration.fields == vec!["name".to_string(), "metadata".to_string()]
    }));
    assert!(output.struct_declarations.iter().any(|declaration| {
        declaration.class == "MutableState"
            && declaration.fields == vec!["items".to_string(), "name".to_string()]
            && declaration.field_types.get("items").map(String::as_str) == Some("T::Array[String]")
            && declaration.field_types.get("name").map(String::as_str) == Some("String")
    }));
    assert!(output.flow_local_types.is_empty());
    assert!(output.collection_index_lookups.is_empty());
    assert!(output.call_graph_edges.is_empty());
    assert!(output.complexity_facts.is_empty());

    let merged = profile::merge(vec![output], Profile::TracePlan);
    assert_eq!(merged.tlet_sites.len(), 1);
    assert_eq!(merged.methods.len(), 1);
    Ok(())
}

#[test]
fn espalier_profile_projects_tlet_state_types_and_aliases() -> Result<()> {
    use std::io::Write;

    let mut tmp = tempfile::Builder::new().suffix(".rb").tempfile()?;
    tmp.write_all(
        br#"class OwnershipDataflow
  OwnershipState = T.type_alias { T::Hash[String, Integer] }

  def initialize
    @block_out = T.let({}, T::Hash[Integer, T.nilable(OwnershipState)])
  end
end
"#,
    )?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Ruby)?;
    let output = profile::extract(&document, Profile::Espalier);

    assert_eq!(
        output
            .state_types
            .get("OwnershipDataflow\0block_out")
            .map(|value| value.to_sorbet_string()),
        Some("T::Hash[Integer, T.nilable(OwnershipState)]".to_string())
    );
    assert!(output.type_definitions.iter().any(|definition| {
        definition.kind == "type_alias"
            && definition.name == "OwnershipState"
            && definition.target.as_deref() == Some("T::Hash[String, Integer]")
    }));
    Ok(())
}

#[test]
fn nil_kill_return_flow_ignores_escape_into_noreturn_branch() -> Result<()> {
    use std::io::Write;

    let mut source = tempfile::Builder::new().suffix(".rb").tempfile()?;
    source.write_all(
        br#"
class Parser
  extend T::Sig

  MaybeToken = T.type_alias { T.nilable(Token) }
  MaybeName = T.type_alias { T.any(String, NilClass) }

  sig { returns(Token) }
  def current
    T.must(@tokens[0])
  end

  sig { params(token: Token).returns(T.noreturn) }
  def fail!(token)
    raise token.to_s
  end

  sig { params(ok: T::Boolean).returns(T.nilable(Token)) }
  def consume(ok)
    token = current
    if ok
      if token.to_s.empty?
        fail!(token)
      end
      token.to_s
      token
    else
      fail!(token)
    end
  end

  sig { params(value: String).returns(String) }
  def validated(value)
    if value.is_a?(String)
      value
    else
      raise "invalid"
    end
  end

  sig { params(token: MaybeToken).returns(T::Boolean) }
  def optional?(token)
    token.nil?
  end

  sig { params(name: MaybeName).returns(T::Boolean) }
  def optional_name?(name)
    name.nil?
  end

  def parser_class?
    self.class.name&.include?("Parser")
  end
end

module Outer
  module Inner
    module Deep
      extend T::Sig

      sig { params(branch: T.nilable(Symbol)).returns(T::Boolean) }
      def nested_scope(branch: nil)
        case branch
        when :then
          1
        when :else
          2
        end
        branch.nil?
      end
    end
  end
end
"#,
    )?;
    let document = syntax::parse_file(source.path().to_path_buf(), Language::Ruby)?;
    let output = profile::extract(&document, Profile::NilKill);
    let origin = output
        .return_origins
        .iter()
        .find(|record| record["method"] == "consume")
        .context("missing consume return origin")?;
    let nested_origin = output
        .return_origins
        .iter()
        .find(|record| record["method"] == "nested_scope")
        .context("missing nested_scope return origin")?;

    assert_eq!(
        origin["candidate_type"],
        serde_json::json!({
            "kind": "Primitive",
            "data": "Token",
        }),
        "{origin:#}"
    );
    assert_eq!(origin["confidence"], "strong");
    assert_eq!(origin["blockers"], serde_json::json!([]));
    assert_eq!(
        nested_origin["class"], "Outer::Inner::Deep",
        "nested owners must be qualified exactly once"
    );
    assert_eq!(
        output
            .deterministic_guards
            .iter()
            .filter(|record| record["method"] == "validated")
            .count(),
        1,
        "prepasses must not duplicate emitted facts"
    );
    assert!(
        output
            .dead_nil_checks
            .iter()
            .all(|record| record["code"] != "token.nil?"),
        "a nilable type alias must not prove a nil check dead"
    );
    assert!(
        output
            .dead_nil_checks
            .iter()
            .all(|record| record["code"] != "name.nil?"),
        "a union containing NilClass must not prove a nil check dead"
    );
    assert!(
        output
            .deterministic_guards
            .iter()
            .all(|record| record["method"] != "nested_scope"),
        "a nil default must not replace the declared nilable parameter type"
    );
    assert!(
        output.dead_nil_checks.iter().all(|record| !record["code"]
            .as_str()
            .is_some_and(|code| code.contains("class.name"))),
        "Module#name may be nil for anonymous classes"
    );

    Ok(())
}

#[test]
fn nil_kill_all_profile_examples_extract_successfully() -> Result<()> {
    let mut method_count = 0;
    for entry in fs::read_dir(examples_dir())? {
        let entry = entry?;
        let fixture = entry.path();
        if !fixture.is_file() {
            continue;
        }
        let ext = fixture.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext == "json" {
            continue;
        }
        let lang = fixture
            .extension()
            .and_then(|e| e.to_str())
            .and_then(|e| Language::for_extension(&e.to_ascii_lowercase()))
            .with_context(|| format!("cannot detect language for {}", fixture.display()))?;

        let document = syntax::parse_file(fixture.clone(), lang)
            .with_context(|| format!("parse {}", fixture.display()))?;
        let output = profile::extract(&document, Profile::NilKill);
        method_count += output.methods.len();
        for method in output.methods {
            assert!(
                !method.raw_source.is_empty(),
                "empty source for {}",
                method.name
            );
            assert_eq!(
                method.normalized_source,
                method
                    .raw_source
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
            );
        }
    }
    assert!(
        method_count > 0,
        "profile examples should contain functions"
    );
    Ok(())
}

#[test]
fn state_writes_without_declarations_extract_as_fields() -> Result<()> {
    use std::io::Write;
    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(b"class Worker\n  def run\n    @total = 0\n    @total += 1\n  end\nend\n")?;
    let path = tmp.path().to_path_buf();

    let document = syntax::parse_file(path, Language::Ruby)?;
    let output = profile::extract(&document, Profile::Espalier);

    assert!(
        !output.fields.is_empty(),
        "state_writes should produce fields"
    );
    let total = output
        .fields
        .iter()
        .find(|f| f.name == "total")
        .with_context(|| "missing total field")?;
    assert_eq!(total.owner, "Worker");
    assert_eq!(total.static_origin, "state_write");

    Ok(())
}

#[test]
fn writes_through_local_receivers_do_not_become_owner_state() -> Result<()> {
    use std::io::Write;
    let mut tmp = tempfile::Builder::new().suffix(".rb").tempfile()?;
    tmp.write_all(
        b"class Parser\n  def populate(block)\n    block.after_all = parse_body\n    value = block.before_all\n    @position = 1\n    value\n  end\nend\n",
    )?;

    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Ruby)?;

    assert!(document
        .state_writes
        .iter()
        .any(|write| write.receiver == "block" && write.field == "after_all"));
    assert!(document
        .state_reads
        .iter()
        .any(|read| read.receiver == "block" && read.field == "before_all"));

    let output = profile::extract(&document, Profile::Espalier);
    assert!(output
        .fields
        .iter()
        .any(|field| { field.owner == "Parser" && field.name == "position" }));
    assert!(!output
        .fields
        .iter()
        .any(|field| { field.owner == "Parser" && field.name == "after_all" }));
    assert!(!output.state_accesses.iter().any(|access| {
        access.owner == "Parser"
            && access.receiver == "block"
            && matches!(access.field.as_str(), "after_all" | "before_all")
    }));

    Ok(())
}

#[test]
fn call_sites_on_fields_emit_state_protocols() -> Result<()> {
    use std::io::Write;
    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(
        b"class Service\n  def call\n    @client.fetch\n    @client.store(1)\n  end\nend\n",
    )?;
    let path = tmp.path().to_path_buf();

    let document = syntax::parse_file(path, Language::Ruby)?;
    let output = profile::extract(&document, Profile::Espalier);

    let key = "Service\u{0}client";
    let protocols = output
        .state_protocols
        .get(key)
        .with_context(|| format!("missing state_protocols key {}", key))?;
    assert!(protocols.contains(&"fetch".to_string()));
    assert!(protocols.contains(&"store".to_string()));

    Ok(())
}

#[test]
fn bare_owner_calls_do_not_emit_state_protocols_for_the_first_field() -> Result<()> {
    use std::io::Write;
    let mut tmp = tempfile::NamedTempFile::new()?;
    tmp.write_all(
        b"class Service\n  def initialize(client)\n    @client = T.let(client, Client)\n  end\n\n  def call\n    @client.fetch\n    self.helper\n  end\n\n  def helper\n  end\nend\n",
    )?;
    let path = tmp.path().to_path_buf();

    let document = syntax::parse_file(path, Language::Ruby)?;
    let output = profile::extract(&document, Profile::Espalier);

    let key = "Service\u{0}client";
    let protocols = output
        .state_protocols
        .get(key)
        .with_context(|| format!("missing state_protocols key {}", key))?;
    assert!(protocols.contains(&"fetch".to_string()));
    assert!(
        !protocols.contains(&"helper".to_string()),
        "a bare owner-method call must not be attributed to a state field"
    );
    assert!(
        !output.state_protocol_records.iter().any(|record| {
            record.owner == "Service" && record.field == "client" && record.protocol == "helper"
        }),
        "a bare owner-method call must not emit a state-protocol record"
    );

    Ok(())
}

// ---------------------------------------------------------------------------
// Oracle-based cross-language tests
// ---------------------------------------------------------------------------

#[test]
fn profile_oracle_matches_ruby_output() -> Result<()> {
    let examples = examples_dir();
    let oracle_dir = examples.join("oracles");

    for entry in fs::read_dir(&examples)? {
        let entry = entry?;
        let fixture = entry.path();
        if !fixture.is_file() {
            continue;
        }
        let ext = fixture.extension().and_then(|e| e.to_str()).unwrap_or("");
        if ext == "json" {
            continue;
        }

        let stem = fixture.file_stem().unwrap().to_str().unwrap();
        let oracle_path = oracle_dir.join(format!("{stem}.json"));
        if !oracle_path.is_file() {
            continue;
        }

        let lang = fixture
            .extension()
            .and_then(|e| e.to_str())
            .and_then(|e| Language::for_extension(&e.to_ascii_lowercase()))
            .with_context(|| format!("cannot detect language for {}", fixture.display()))?;

        let document = syntax::parse_file(fixture.clone(), lang)
            .with_context(|| format!("parse {}", fixture.display()))?;
        let selected_profile = if stem.ends_with("_nil_kill") {
            Profile::NilKill
        } else {
            Profile::Espalier
        };
        let actual = profile::extract(&document, selected_profile);
        let mut actual_json = serde_json::to_value(&actual)?;
        let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        profile::normalize_paths(&mut actual_json, &manifest_dir);

        let mut expected: Value = serde_json::from_str(&fs::read_to_string(&oracle_path)?)?;
        profile::normalize_paths(&mut expected, &manifest_dir);

        let normalized = normalize_for_oracle(&actual_json, &expected);
        let expected_normalized = normalize_for_oracle(&expected, &expected);

        if std::env::var("UPDATE_ORACLES").is_ok() {
            fs::write(&oracle_path, serde_json::to_string_pretty(&actual_json)?)?;
        } else if normalized != expected_normalized {
            bail!(
                "{}: oracle mismatch\nexpected: {}\nactual:   {}",
                fixture.display(),
                expected_normalized,
                normalized
            );
        }
    }

    Ok(())
}

fn normalize_for_oracle(value: &Value, expected: &Value) -> Value {
    match (value, expected) {
        (Value::Object(actual_map), Value::Object(expected_map)) => {
            let mut out = serde_json::Map::new();
            for key in expected_map.keys() {
                if let Some(actual_val) = actual_map.get(key) {
                    let normalized = normalize_for_oracle(actual_val, &expected_map[key]);
                    out.insert(key.clone(), normalized);
                }
            }
            Value::Object(out)
        }
        (Value::Array(actual_arr), Value::Array(expected_arr)) => {
            if expected_arr.is_empty() {
                return Value::Array(Vec::new());
            }
            let mut normalized: Vec<Value> = actual_arr
                .iter()
                .map(|item| normalize_for_oracle(item, expected_arr.first().unwrap_or(item)))
                .collect();
            // Sort for determinism
            normalized.sort_by(|a, b| {
                serde_json::to_string(a)
                    .unwrap_or_default()
                    .cmp(&serde_json::to_string(b).unwrap_or_default())
            });
            Value::Array(normalized)
        }
        (Value::String(actual), Value::String(_)) => Value::String(normalize_opaque_id(actual)),
        _ => value.clone(),
    }
}

/// Profile IDs deliberately hash the source path and therefore differ across
/// checkouts. The oracle verifies the semantic record and the ID namespace;
/// exact hash stability belongs in a unit test with a fixed synthetic path.
fn normalize_opaque_id(value: &str) -> String {
    for prefix in ["owner:", "fn:", "state:", "edge:"] {
        if value.starts_with(prefix) {
            return format!("{prefix}<opaque>");
        }
    }
    value.to_string()
}

#[test]
fn test_comprehensive_profile_extraction_integration() -> Result<()> {
    use std::io::Write;

    // 1. Create a comprehensive Ruby file
    let mut ruby_tmp = tempfile::Builder::new().suffix(".rb").tempfile()?;
    let ruby_content = r#"
class Database
end

class Greeter
  MY_CONST = {
    :sym => :symbol,
    "str" => "string",
  }

  def initialize(db: Database)
    @db = db
    @name = "world"
  end

  def hello(name)
    user[:name]
    user.fetch(:id)
    self.typed_method(name)
    @client.nested.fetch
    self.db.query
  end

  sig { params(x: Integer).returns(String) }
  def typed_method(x)
    "result"
  end
end

[true, false, nil, 4.5, Object, untyped_var]
"#;
    ruby_tmp.write_all(ruby_content.as_bytes())?;
    let doc_rb = syntax::parse_file(ruby_tmp.path().to_path_buf(), Language::Ruby)?;

    // 2. Create a Python file
    let mut py_tmp = tempfile::Builder::new().suffix(".py").tempfile()?;
    let py_content = r#"
class PyClass:
    def py_fn(self, a: int) -> str:
        return "hello"
"#;
    py_tmp.write_all(py_content.as_bytes())?;
    let doc_py = syntax::parse_file(py_tmp.path().to_path_buf(), Language::Python)?;

    // 3. Create a TypeScript file
    let mut ts_tmp = tempfile::Builder::new().suffix(".ts").tempfile()?;
    let ts_content = r#"
class Greeter {
    hello(name: string): string {
        return "hello";
    }
}
"#;
    ts_tmp.write_all(ts_content.as_bytes())?;
    let doc_ts = syntax::parse_file(ts_tmp.path().to_path_buf(), Language::TypeScript)?;

    // 4. Extract profiles
    let output_rb = profile::extract(&doc_rb, Profile::NilKill);
    let output_py = profile::extract(&doc_py, Profile::Espalier);
    let output_ts = profile::extract(&doc_ts, Profile::Espalier);

    // Assertions to verify we extracted expected facts
    assert!(!output_rb.methods.is_empty());
    assert!(!output_py.methods.is_empty());
    assert!(!output_ts.methods.is_empty());

    // 5. Merge profiles
    let merged = profile::merge(vec![output_rb, output_py, output_ts], Profile::NilKill);
    assert!(merged.methods.len() > 1);

    Ok(())
}
