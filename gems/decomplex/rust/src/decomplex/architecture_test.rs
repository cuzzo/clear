use std::fs;
use std::path::{Path, PathBuf};

fn crate_src() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src/decomplex")
}

#[test]
fn every_supported_language_has_a_syntax_adapter_file() {
    let adapters = crate_src().join("syntax/adapters");
    let expected = [
        "c.rs",
        "cpp.rs",
        "csharp.rs",
        "go.rs",
        "java.rs",
        "javascript.rs",
        "kotlin.rs",
        "lua.rs",
        "php.rs",
        "python.rs",
        "ruby.rs",
        "rust.rs",
        "swift.rs",
        "typescript.rs",
        "zig.rs",
    ];

    for file in expected {
        assert!(
            adapters.join(file).is_file(),
            "missing syntax adapter file {}",
            adapters.join(file).display()
        );
    }
}

#[test]
fn every_supported_language_has_an_ast_adapter_file() {
    let adapters = crate_src().join("ast/adapters");
    let expected = [
        "c.rs",
        "cpp.rs",
        "csharp.rs",
        "go.rs",
        "java.rs",
        "javascript.rs",
        "kotlin.rs",
        "lua.rs",
        "php.rs",
        "python.rs",
        "ruby.rs",
        "rust.rs",
        "swift.rs",
        "typescript.rs",
        "zig.rs",
    ];

    for file in expected {
        assert!(
            adapters.join(file).is_file(),
            "missing AST adapter file {}",
            adapters.join(file).display()
        );
    }
}

#[test]
fn tree_sitter_adapter_does_not_define_concrete_language_profiles() {
    let path = crate_src().join("syntax/tree_sitter_adapter.rs");
    let source = fs::read_to_string(&path).expect("read tree_sitter_adapter.rs");
    let forbidden = [
        "default_profile!",
        "struct RubyProfile",
        "struct PythonProfile",
        "struct JavaScriptProfile",
        "struct JavaProfile",
        "struct TypeScriptProfile",
        "struct SwiftProfile",
        "struct KotlinProfile",
        "struct GoProfile",
        "struct RustProfile",
        "struct ZigProfile",
        "struct LuaProfile",
        "struct CProfile",
        "struct CppProfile",
        "struct CSharpProfile",
        "struct PhpProfile",
    ];

    for pattern in forbidden {
        assert!(
            !source.contains(pattern),
            "{} should live in syntax/adapters, not tree_sitter_adapter.rs",
            pattern
        );
    }
}

#[test]
fn ast_normalizer_does_not_define_a_language_adapter_enum() {
    let path = crate_src().join("ast.rs");
    let source = fs::read_to_string(&path).expect("read ast.rs");
    for pattern in [
        "enum TreeSitterNormalizationAdapter",
        "impl TreeSitterNormalizationAdapter",
        "TreeSitterNormalizationAdapter::",
    ] {
        assert!(
            !source.contains(pattern),
            "{} should live as polymorphic ast/adapters implementations",
            pattern
        );
    }
}

#[test]
fn ast_adapters_do_not_delegate_through_a_language_kind_selector() {
    let adapters = crate_src().join("ast/adapters");
    for entry in fs::read_dir(&adapters).expect("read ast adapters dir") {
        let path = entry.expect("ast adapter entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let source = fs::read_to_string(&path).expect("read ast adapter");
        for pattern in [
            "TreeSitterNormalizationAdapter",
            "fn kind(&self)",
            "self.kind()",
        ] {
            assert!(
                !source.contains(pattern),
                "{} delegates through {}; put behavior directly in the adapter",
                path.display(),
                pattern
            );
        }
    }
}

#[test]
fn detectors_do_not_import_tree_sitter_directly() {
    let detectors = crate_src().join("detectors");
    let entries = fs::read_dir(&detectors).expect("read detectors dir");

    for entry in entries {
        let path = entry.expect("detector entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        let source = production_source(&fs::read_to_string(&path).expect("read detector source"));
        assert!(
            !source.contains("tree_sitter"),
            "{} imports tree_sitter directly; detectors should consume normalized syntax/AST facts",
            path.display()
        );
    }
}

#[test]
fn detectors_do_not_cross_the_syntax_boundary() {
    let detectors = crate_src().join("detectors");
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

    for entry in fs::read_dir(&detectors).expect("read detectors dir") {
        let path = entry.expect("detector entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
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
            "{} belongs in syntax/adapters, not the false_simplicity detector",
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
            "{} belongs in syntax/adapters, not flay_similarity",
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

#[test]
fn ast_normalizer_does_not_branch_on_language_after_parser_setup() {
    let path = crate_src().join("ast.rs");
    let source = fs::read_to_string(&path).expect("read ast.rs");
    let normalizer_source = source
        .split_once("struct TreeSitterNormalizer")
        .map(|(_, rest)| rest)
        .unwrap_or(&source);
    let language_branch_count = [
        "Language::Ruby",
        "Language::Python",
        "Language::JavaScript",
        "Language::Java",
        "Language::TypeScript",
        "Language::Swift",
        "Language::Kotlin",
        "Language::Go",
        "Language::Rust",
        "Language::Zig",
        "Language::Lua",
        "Language::C",
        "Language::Cpp",
        "Language::CSharp",
        "Language::Php",
        "Self::Ruby",
        "Self::Python",
        "Self::Lua",
        "Self::TypeScript",
        "Self::Default",
        "TreeSitterNormalizationAdapter::Python",
        "TreeSitterNormalizationAdapter::Lua",
    ]
    .iter()
    .map(|pattern| normalizer_source.matches(pattern).count())
    .sum::<usize>();

    assert_eq!(
        language_branch_count, 0,
        "ast.rs normalizer branches on language; put behavior in ast/adapters instead"
    );
}
