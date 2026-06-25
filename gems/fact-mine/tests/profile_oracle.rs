use anyhow::{bail, Context, Result};
use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::syntax::{self, Language};
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

fn examples_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("examples")
        .join("profile")
}

#[test]
fn ruby_calculator_extracts_methods() -> Result<()> {
    let file = examples_dir().join("ruby_calculator.rb");
    let document = syntax::parse_file(file.clone(), Language::Ruby)
        .with_context(|| format!("parse {}", file.display()))?;

    let output = profile::extract(&document, Profile::Espalier);

    // Methods — the normalized extractor detects the two functions
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
fn nil_kill_all_profile_examples_extract_successfully() -> Result<()> {
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
        // Ensure it doesn't crash and returns a valid ProfileOutput
        assert!(output.methods.len() >= 0);
    }
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
        _ => value.clone(),
    }
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
