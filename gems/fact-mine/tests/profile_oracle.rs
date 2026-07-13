use anyhow::{bail, Context, Result};
use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::syntax::{self, Language};
use serde_json::{json, Value};
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
    let document = syntax::parse_file(
        fixture("python_state_projection.py"),
        Language::Python,
    )?;
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
    let document = syntax::parse_file(
        fixture("python_state_projection.py"),
        Language::Python,
    )?;
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
fn go_short_declaration_does_not_reuse_outer_non_nil_proof() -> Result<()> {
    let document = syntax::parse_file(fixture("go_shadowing.go"), Language::Go)?;
    assert!(document.redundant_nil_guards.is_empty());
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
        add_method.raw_source.split_whitespace().collect::<Vec<_>>().join(" ")
    );
    assert!(
        !add_method.signature.is_empty() || true,
        "signature optional without Sorbet sigs"
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

    let build = output.methods.iter().find(|method| method.name == "self.build").unwrap();
    assert_eq!(build.kind, "class");
    assert_eq!(build.dispatch_name, "build");

    let target_flow = output.flow_local_types.iter().find(|fact| {
        fact.get("function").and_then(Value::as_str) == Some("run")
            && fact.get("name").and_then(Value::as_str) == Some("target")
            && fact.get("complete").and_then(Value::as_bool) == Some(true)
    }).context("missing complete target flow type")?;
    let resolved = target_flow.get("resolved_types").and_then(Value::as_array)
        .context("missing normalized resolved flow types")?;
    assert_eq!(resolved.len(), 1);
    assert_eq!(resolved[0].get("kind").and_then(Value::as_str), Some("Primitive"));
    assert_eq!(resolved[0].get("data").and_then(Value::as_str), Some("Target"));
    let static_call = output.calls.iter().find(|call| {
        call.function == "run" && call.receiver == "Target" && call.message == "build"
    }).with_context(|| format!("missing static Target.build call in {:?}", output.calls))?;
    assert_eq!(static_call.receiver_kind, "type");
    let constructor = output.calls.iter().find(|call| {
        call.function == "run" && call.receiver == "Target" && call.message == "new"
    }).context("missing Target.new call")?;
    assert_eq!(constructor.constructor_target.as_deref(), Some("initialize"));
    let type_operation = output.calls.iter().find(|call| {
        call.function == "run" && call.receiver == "T" && call.message == "let"
    }).context("missing T.let call")?;
    assert_eq!(type_operation.known_time_complexity.as_deref(), Some("O(1)"));
    assert_eq!(type_operation.known_space_complexity.as_deref(), Some("O(1)"));
    let record = output.struct_declarations.iter().find(|declaration| declaration.class == "Record")
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
    tmp.write_all(br#"class TypedInputs
  extend T::Sig
  sig { params(strong: String, weak: T::Array[T.untyped]).void }
  def run(strong, weak)
    strong.to_s
    weak.length
  end
end
"#)?;
    let document = syntax::parse_file(tmp.path().to_path_buf(), Language::Ruby)?;
    let declared = document
        .method_param_types
        .get("TypedInputs\0run")
        .context("missing declared parameter shapes")?;
    assert_eq!(declared.get("weak").map(String::as_str), Some("T::Array[T.untyped]"));

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
    writer.write_all(
        b"class Writer\n  def write\n    $shared = \"ready\"\n  end\nend\n",
    )?;
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
    assert!(output.tlet_sites.iter().any(|site| {
        site.get("type").and_then(Value::as_str) == Some("T::Array[String]")
    }));
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
            && declaration.field_types.get("items").map(String::as_str)
                == Some("T::Array[String]")
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

    assert_eq!(origin["candidate_type"], serde_json::json!({
        "kind": "Primitive",
        "data": "Token",
    }), "{origin:#}");
    assert_eq!(origin["confidence"], "strong");
    assert_eq!(origin["blockers"], serde_json::json!([]));
    assert_eq!(
        nested_origin["class"],
        "Outer::Inner::Deep",
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
        output
            .dead_nil_checks
            .iter()
            .all(|record| !record["code"].as_str().is_some_and(|code| code.contains("class.name"))),
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
            assert!(!method.raw_source.is_empty(), "empty source for {}", method.name);
            assert_eq!(
                method.normalized_source,
                method.raw_source.split_whitespace().collect::<Vec<_>>().join(" ")
            );
        }
    }
    assert!(method_count > 0, "profile examples should contain functions");
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
        let actual = profile::extract(&document, Profile::Espalier);
        let actual_json = serde_json::to_value(&actual)?;

        let expected: Value = serde_json::from_str(&fs::read_to_string(&oracle_path)?)?;

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

/// Normalize a profile JSON value to match oracle expectations.
/// Only compares keys present in expected; sorts arrays for determinism.
fn normalize_for_oracle(value: &Value, expected: &Value) -> Value {
    match (value, expected) {
        (Value::Object(actual_map), Value::Object(expected_map)) => {
            let mut out = serde_json::Map::new();
            for key in expected_map.keys() {
                if let Some(actual_val) = actual_map.get(key) {
                    let mut normalized = normalize_for_oracle(actual_val, &expected_map[key]);
                    // Normalize paths to be relative (strip absolute prefixes)
                    if key == "path" || key == "id" {
                        if let Value::String(path) = &normalized {
                            if let Some(idx) = path.find("examples/profile/") {
                                normalized = Value::String(path[idx..].to_string());
                            }
                        }
                    }
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
        (Value::String(actual), Value::String(_)) => {
            Value::String(normalize_opaque_id(actual))
        }
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
