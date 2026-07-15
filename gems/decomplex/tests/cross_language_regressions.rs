use anyhow::Result;
use decomplex_rust::decomplex::detectors::{redundant_nil_guard, superfluous_state};
use decomplex_rust::decomplex::syntax::Language;
use std::path::{Path, PathBuf};

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests")
        .join("fixtures")
        .join(name)
}

#[test]
fn python_state_projections_prevent_false_dead_state_without_hiding_real_dead_state() -> Result<()>
{
    let findings = superfluous_state::scan_files(
        &[fixture("python_state_read_regressions.py")],
        Language::Python,
    )?;
    let dead = findings
        .iter()
        .filter(|finding| finding.classification == "dead_state")
        .map(|finding| finding.field.trim_start_matches('@'))
        .collect::<Vec<_>>();

    assert!(
        dead.contains(&"inherit"),
        "the unused inherit field is a real control finding"
    );
    assert!(
        !dead.contains(&"_items"),
        "indexed state reads must count as reads"
    );
    assert!(
        !dead.contains(&"_record_buffer_lock"),
        "context-manager state reads must count as reads"
    );
    assert!(
        !dead.contains(&"ansi_colors"),
        "cross-object state reads must retain the declared field identity"
    );
    assert!(
        !dead.contains(&"href"),
        "cross-object renderer reads must retain the declared field identity"
    );
    Ok(())
}

#[test]
fn python_lexical_closures_are_not_owner_methods() -> Result<()> {
    let document = decomplex_rust::decomplex::syntax::parse_file(
        fixture("python_state_read_regressions.py"),
        Language::Python,
    )?;
    let console_methods = document
        .function_defs
        .iter()
        .filter(|function| function.owner == "Console")
        .map(|function| function.name.as_str())
        .collect::<Vec<_>>();
    assert_eq!(console_methods, vec!["export"]);
    Ok(())
}

#[test]
fn go_shadowing_and_indexed_state_reads_survive_end_to_end() -> Result<()> {
    let path = fixture("go_shadow_and_index_regressions.go");
    let nil_findings = redundant_nil_guard::scan_files(&[path.clone()], Language::Go)?;
    assert!(
        nil_findings.is_empty(),
        "short-declared err is a new binding"
    );

    let state_findings = superfluous_state::scan_files(&[path], Language::Go)?;
    assert!(
        state_findings
            .iter()
            .all(|finding| finding.field.trim_start_matches('@') != "items"),
        "cache.items[key] must prevent a false dead-state finding"
    );
    Ok(())
}
