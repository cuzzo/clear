use std::fs;
use std::path::{Path, PathBuf};

fn crate_src() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/decomplex")
}

fn detector_files() -> Vec<PathBuf> {
    rust_files(crate_src().join("detectors"))
}

fn post_syntax_consumer_files() -> Vec<PathBuf> {
    let mut files = detector_files();
    files.extend(
        [
            "convergence.rs",
            "delta.rs",
            "report.rs",
            "report_facts.rs",
            "report_value.rs",
            "root_cause.rs",
            "sarif.rs",
        ]
        .iter()
        .map(|name| crate_src().join(name)),
    );
    files
}

fn rust_files(dir: PathBuf) -> Vec<PathBuf> {
    let mut files = fs::read_dir(&dir)
        .unwrap_or_else(|err| panic!("read {}: {err}", dir.display()))
        .map(|entry| entry.expect("rust file entry").path())
        .filter(|path| path.extension().and_then(|ext| ext.to_str()) == Some("rs"))
        .collect::<Vec<_>>();
    files.sort();
    files
}

#[test]
fn decomplex_crate_does_not_depend_on_tree_sitter() {
    let manifest = fs::read_to_string(Path::new(env!("CARGO_MANIFEST_DIR")).join("Cargo.toml"))
        .expect("read Cargo.toml");
    assert!(
        !manifest.contains("tree-sitter"),
        "Decomplex must not depend on parser crates; parser access belongs behind FactMine"
    );
}

#[test]
fn decomplex_does_not_reexport_fact_mine_internals() {
    let path = crate_src().join("mod.rs");
    let source = fs::read_to_string(&path).expect("read decomplex/mod.rs");
    for pattern in [
        "fact_mine_rust::{ast",
        "fact_mine_rust::ast",
        "tree_sitter_adapter",
        "syntax::tree_sitter_adapter",
    ] {
        assert!(
            !source.contains(pattern),
            "{} would let Decomplex bypass computed FactMine facts",
            pattern
        );
    }
}

#[test]
fn detectors_do_not_import_tree_sitter_directly() {
    for path in detector_files() {
        let source = production_source(&fs::read_to_string(&path).expect("read detector source"));
        assert!(
            !source.contains("tree_sitter"),
            "{} imports tree_sitter directly; detectors should consume normalized syntax/AST facts",
            path.display()
        );
    }
}

#[test]
fn detectors_do_not_read_raw_document_text() {
    let forbidden = [
        ("raw document lines", "document.lines"),
        ("raw document source", "document.source"),
        ("local source slicing helper", "source_text("),
    ];
    let mut offenders = Vec::new();

    for path in detector_files() {
        let source = production_source(&fs::read_to_string(&path).expect("read detector source"));
        for (reason, pattern) in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}: {}", path.display(), reason, pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Detectors must consume computed facts, not raw document text:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn detectors_do_not_cross_the_syntax_boundary() {
    let forbidden = [
        ("syntax adapter access", "syntax::adapters"),
        ("language profile access", "language_profile("),
        ("raw syntax node type", "RawNode"),
        ("raw document root access", "document.root"),
        (
            "normalized document root access",
            "document.normalized_root",
        ),
        ("document language inspection", "document.language"),
        ("Ruby language branch", "Language::Ruby"),
        ("Python language branch", "Language::Python"),
        ("JavaScript language branch", "Language::JavaScript"),
        ("Java language branch", "Language::Java"),
        ("TypeScript language branch", "Language::TypeScript"),
        ("Swift language branch", "Language::Swift"),
        ("Kotlin language branch", "Language::Kotlin"),
        ("Go language branch", "Language::Go"),
        ("Rust language branch", "Language::Rust"),
        ("Zig language branch", "Language::Zig"),
        ("Lua language branch", "Language::Lua"),
        ("C language branch", "Language::C"),
        ("Cpp language branch", "Language::Cpp"),
        ("CSharp language branch", "Language::CSharp"),
        ("Php language branch", "Language::Php"),
    ];
    let mut offenders = Vec::new();

    for path in detector_files() {
        let source = production_source(&fs::read_to_string(&path).expect("read detector source"));
        for (reason, pattern) in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}: {}", path.display(), reason, pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Detectors must consume syntax facts, not language/parser internals:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn post_syntax_consumers_do_not_access_parser_or_adapter_internals() {
    let forbidden = [
        ("syntax adapter access", "syntax::adapters"),
        ("language profile access", "language_profile("),
        ("raw syntax node type", "RawNode"),
        ("tree-sitter access", "tree_sitter"),
        ("raw document root access", "document.root"),
        (
            "normalized document root access",
            "document.normalized_root",
        ),
    ];
    let mut offenders = Vec::new();

    for path in post_syntax_consumer_files() {
        let source = production_source(&fs::read_to_string(&path).expect("read consumer source"));
        for (reason, pattern) in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}: {}", path.display(), reason, pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Post-syntax consumers must consume generated facts, not parser/adaptor internals:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn post_syntax_consumers_do_not_branch_on_concrete_languages() {
    let forbidden = [
        ("Ruby language branch", "Language::Ruby"),
        ("Python language branch", "Language::Python"),
        ("JavaScript language branch", "Language::JavaScript"),
        ("Java language branch", "Language::Java"),
        ("TypeScript language branch", "Language::TypeScript"),
        ("Swift language branch", "Language::Swift"),
        ("Kotlin language branch", "Language::Kotlin"),
        ("Go language branch", "Language::Go"),
        ("Rust language branch", "Language::Rust"),
        ("Zig language branch", "Language::Zig"),
        ("Lua language branch", "Language::Lua"),
        ("C language branch", "Language::C"),
        ("Cpp language branch", "Language::Cpp"),
        ("CSharp language branch", "Language::CSharp"),
        ("Php language branch", "Language::Php"),
    ];
    let mut offenders = Vec::new();

    for path in post_syntax_consumer_files() {
        let source = production_source(&fs::read_to_string(&path).expect("read consumer source"));
        for (reason, pattern) in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}: {}", path.display(), reason, pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Post-syntax consumers must not encode language-specific branches:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn report_facts_uses_document_detector_apis() {
    let path = crate_src().join("report_facts.rs");
    let source = fs::read_to_string(&path).expect("read report_facts.rs");
    assert!(
        !source.contains("::scan_files("),
        "report_facts.rs must build shared documents once and call detector scan_documents APIs"
    );
}

#[test]
fn false_simplicity_detector_does_not_own_language_lexicons() {
    let path = crate_src().join("detectors/false_simplicity.rs");
    let source = fs::read_to_string(&path).expect("read false_simplicity.rs");
    for pattern in [
        "fn lexicon_for",
        "struct Lexicon",
        "RUBY_CONTEXT_PAIRS",
        "RUBY_CALLBACK_SET",
        "RUBY_CORE_CONSTS",
        "PYTHON_CONTEXT_PAIRS",
        "JS_CONTEXT_PAIRS",
        "COMMON_CALLBACK_SET",
    ] {
        assert!(
            !source.contains(pattern),
            "{} belongs in FactMine normalized language behavior, not the false_simplicity detector",
            pattern
        );
    }
}

#[test]
fn state_branch_density_detector_does_not_own_ruby_source_mining() {
    let path = crate_src().join("detectors/state_branch_density.rs");
    let source = fs::read_to_string(&path).expect("read state_branch_density.rs");
    for pattern in [
        "T::Struct",
        "T\\.type_alias",
        "const\\s+:",
        "fn immutable_struct_readers",
        "fn immutable_struct_reader_types",
        "fn type_aliases",
        "fn extract_method_param_types",
        "fn sig_param_types",
    ] {
        assert!(
            !source.contains(pattern),
            "{} belongs in the Ruby syntax adapter, not state_branch_density",
            pattern
        );
    }
}

#[test]
fn decision_pressure_detector_uses_semantic_effect_facts_for_eliminable_guards() {
    let path = crate_src().join("detectors/decision_pressure.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read decision_pressure.rs"));
    for pattern in [
        "rescue nil",
        "statement.source",
        "fn rescue_nil_hits",
        "fn inside_span",
        "GUARD_MIDS",
        "\"nil?\"",
        "\"respond_to?\"",
        "\"is_a?\"",
        "\"kind_of?\"",
        "\"instance_of?\"",
        "\"isNull\"",
        "\"is_null\"",
        "\"is_none\"",
        "\"is_some\"",
        "call.safe_navigation",
    ] {
        assert!(
            !source.contains(pattern),
            "{} belongs in normalized semantic effects, not decision_pressure",
            pattern
        );
    }
}

#[test]
fn state_branch_density_detector_does_not_classify_raw_branch_keywords() {
    let path = crate_src().join("detectors/state_branch_density.rs");
    let source =
        production_source(&fs::read_to_string(&path).expect("read state_branch_density.rs"));
    for pattern in [
        "\"unless\"",
        "\"until\"",
        "strip_prefix(prefix)",
        "starts_with(char::is_whitespace)",
    ] {
        assert!(
            !source.contains(pattern),
            "{} belongs in normalized branch facts, not state_branch_density",
            pattern
        );
    }
}

#[test]
fn flay_similarity_detector_does_not_own_clone_fingerprint_grammar() {
    let path = crate_src().join("detectors/flay_similarity.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read flay_similarity.rs"));
    for pattern in [
        "RawNode",
        "CLONE_CANDIDATE_KINDS",
        "IDENTIFIER_KINDS",
        "LITERAL_KINDS",
        "fn candidate_node",
        "fn fingerprint",
        "fn typed_struct_schema_text",
    ] {
        assert!(
            !source.contains(pattern),
            "{} belongs in FactMine normalized clone facts, not flay_similarity",
            pattern
        );
    }
}

fn production_source(source: &str) -> String {
    source
        .lines()
        .take_while(|line| line.trim() != "#[cfg(test)]")
        .collect::<Vec<_>>()
        .join("\n")
}
