use anyhow::{Context, Result};
use fact_mine_rust::profile::{self, Profile};
use fact_mine_rust::syntax::{self, Language};
use std::path::PathBuf;

fn examples_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
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
    assert!(!add_method.signature.is_empty());

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

    let out_calc = profile::extract(&doc_calc, Profile::Espalier);
    let out_greeter = profile::extract(&doc_greeter, Profile::Espalier);

    assert!(!out_calc.methods.is_empty());
    assert!(!out_greeter.methods.is_empty());

    let merged = profile::merge(vec![out_calc, out_greeter], Profile::Espalier);
    assert!(merged.methods.len() > 1, "merge should combine methods");

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