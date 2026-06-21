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

fn rust_files_recursive(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    collect_rust_files(dir, &mut files);
    files.sort();
    files
}

fn collect_rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in fs::read_dir(dir).unwrap_or_else(|err| panic!("read {}: {err}", dir.display())) {
        let path = entry.expect("rust file entry").path();
        if path.is_dir() {
            collect_rust_files(&path, out);
        } else if path.extension().and_then(|ext| ext.to_str()) == Some("rs") {
            out.push(path);
        }
    }
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
fn syntax_directory_does_not_gain_unreviewed_helper_files() {
    let syntax_dir = crate_src().join("syntax");
    let expected = [
        "adapters/base.rs",
        "adapters/c.rs",
        "adapters/cpp.rs",
        "adapters/csharp.rs",
        "adapters/false_simplicity_lexicon.rs",
        "adapters/go.rs",
        "adapters/java.rs",
        "adapters/javascript.rs",
        "adapters/kotlin.rs",
        "adapters/lua.rs",
        "adapters/mod.rs",
        "adapters/php.rs",
        "adapters/python.rs",
        "adapters/ruby.rs",
        "adapters/rust.rs",
        "adapters/swift.rs",
        "adapters/typescript.rs",
        "adapters/zig.rs",
        "complexity.rs",
        "local_flow.rs",
        "normalized_extractor.rs",
        "path_condition.rs",
        "protocols.rs",
        "raw_tree.rs",
        "redundant_nil_guard.rs",
        "tree_sitter_adapter.rs",
        "visibility.rs",
    ];
    let mut files = rust_files_recursive(&syntax_dir)
        .into_iter()
        .map(|path| {
            path.strip_prefix(&syntax_dir)
                .expect("syntax file under syntax dir")
                .to_string_lossy()
                .replace('\\', "/")
        })
        .collect::<Vec<_>>();
    files.sort();
    let expected = expected.into_iter().map(str::to_string).collect::<Vec<_>>();
    let unexpected = files
        .iter()
        .filter(|file| !expected.contains(file))
        .map(|file| format!("{file}: unexpected syntax helper file"));
    let missing = expected
        .iter()
        .filter(|file| !files.contains(file))
        .map(|file| format!("{file}: missing syntax file"));
    let offenders = unexpected.chain(missing).collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Syntax helper files are an architecture boundary; update this invariant deliberately:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn syntax_subfiles_do_not_declare_nested_modules() {
    let syntax_dir = crate_src().join("syntax");
    let allowed_module_loaders = [syntax_dir.join("adapters/mod.rs")];
    let mut offenders = Vec::new();

    for path in rust_files_recursive(&syntax_dir) {
        if allowed_module_loaders.contains(&path) {
            continue;
        }
        let source = production_source(&fs::read_to_string(&path).expect("read syntax file"));
        for (index, line) in source.lines().enumerate() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("mod ")
                || trimmed.starts_with("pub mod ")
                || trimmed.starts_with("pub(crate) mod ")
            {
                offenders.push(format!("{}:{}: {}", path.display(), index + 1, trimmed));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Syntax subfiles must not hide behavior behind nested modules:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn syntax_adapter_module_loader_only_declares_known_modules() {
    let path = crate_src().join("syntax/adapters/mod.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read syntax adapters mod"));
    let expected = [
        "pub(crate) mod base;",
        "mod c;",
        "mod cpp;",
        "mod csharp;",
        "pub(crate) mod false_simplicity_lexicon;",
        "mod go;",
        "mod java;",
        "mod javascript;",
        "mod kotlin;",
        "mod lua;",
        "mod php;",
        "mod python;",
        "mod ruby;",
        "mod rust;",
        "mod swift;",
        "mod typescript;",
        "mod zig;",
    ];
    let modules = source
        .lines()
        .map(str::trim)
        .filter(|line| {
            line.starts_with("mod ")
                || line.starts_with("pub mod ")
                || line.starts_with("pub(crate) mod ")
        })
        .map(str::to_string)
        .collect::<Vec<_>>();
    let expected = expected.into_iter().map(str::to_string).collect::<Vec<_>>();
    let unexpected = modules
        .iter()
        .filter(|module| !expected.contains(module))
        .map(|module| format!("{module}: unexpected adapter module declaration"));
    let missing = expected
        .iter()
        .filter(|module| !modules.contains(module))
        .map(|module| format!("{module}: missing adapter module declaration"));
    let offenders = unexpected.chain(missing).collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "syntax/adapters/mod.rs must only load the approved adapter modules:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn concrete_syntax_profiles_only_live_in_their_own_files() {
    let syntax_dir = crate_src().join("syntax");
    let adapters_dir = syntax_dir.join("adapters");
    let owners = [
        ("CProfile", "c.rs"),
        ("CppProfile", "cpp.rs"),
        ("CSharpProfile", "csharp.rs"),
        ("GoProfile", "go.rs"),
        ("JavaProfile", "java.rs"),
        ("JavaScriptProfile", "javascript.rs"),
        ("KotlinProfile", "kotlin.rs"),
        ("LuaProfile", "lua.rs"),
        ("PhpProfile", "php.rs"),
        ("PythonProfile", "python.rs"),
        ("RubyProfile", "ruby.rs"),
        ("RustProfile", "rust.rs"),
        ("SwiftProfile", "swift.rs"),
        ("TypeScriptProfile", "typescript.rs"),
        ("ZigProfile", "zig.rs"),
    ];
    let mut offenders = Vec::new();

    for path in rust_files_recursive(&syntax_dir) {
        let source = production_source(&fs::read_to_string(&path).expect("read syntax file"));
        for (index, line) in source.lines().enumerate() {
            let trimmed = line.trim_start();
            for (profile, owner_file) in owners {
                if !(trimmed.starts_with(&format!("pub(crate) struct {profile}"))
                    || trimmed.starts_with(&format!("struct {profile}"))
                    || trimmed.starts_with(&format!("impl {profile}"))
                    || trimmed.contains(&format!(" for {profile}")))
                {
                    continue;
                }
                let owner = adapters_dir.join(owner_file);
                if path != owner {
                    offenders.push(format!(
                        "{}:{}: {} belongs in {}: {}",
                        path.display(),
                        index + 1,
                        profile,
                        owner.display(),
                        trimmed
                    ));
                }
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Concrete syntax profiles must not be split across helper files:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn syntax_language_profile_trait_does_not_expose_detector_fact_engines() {
    let path = crate_src().join("syntax/adapters/base.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read syntax adapter base"));
    let trait_source = source
        .split_once("pub(crate) trait LanguageProfile")
        .map(|(_, rest)| rest)
        .unwrap_or(&source);
    let forbidden = [
        (
            "semantic-effect fact generation",
            "structural_semantic_effect_sites(",
        ),
        (
            "ordered-protocol effect generation",
            "protocol_method_effects(",
        ),
        ("ordered-protocol path generation", "protocol_call_paths("),
        ("clone candidate generation", "clone_candidates("),
        ("post-collection fact mutation", "after_collect_facts("),
    ];
    let offenders = forbidden
        .into_iter()
        .filter_map(|(reason, pattern)| {
            trait_source
                .contains(pattern)
                .then(|| format!("{}: {}", reason, pattern))
        })
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "LanguageProfile must be grammar facts and small hooks only; detector fact engines belong in shared syntax modules:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn concrete_syntax_adapters_do_not_define_detector_fact_engines() {
    let adapters = crate_src().join("syntax/adapters");
    let skipped = ["base.rs", "mod.rs", "false_simplicity_lexicon.rs"];
    let forbidden_lines = [
        "fn structural_semantic_effect_sites",
        "fn ruby_structural_semantic_effect_sites",
        "fn protocol_method_effects",
        "fn protocol_call_paths",
        "fn clone_candidates",
        "fn after_collect_facts",
        "RawProtocolAdapter",
        "RawProtocolShape",
        "RawCallShape",
        "semantic_effects::",
        "protocols::method_effects",
        "protocols::call_paths",
    ];
    let mut offenders = Vec::new();

    for entry in fs::read_dir(&adapters).expect("read syntax adapters dir") {
        let path = entry.expect("syntax adapter entry").path();
        if path.extension().and_then(|ext| ext.to_str()) != Some("rs") {
            continue;
        }
        if path
            .file_name()
            .and_then(|name| name.to_str())
            .map(|name| skipped.contains(&name))
            .unwrap_or(false)
        {
            continue;
        }

        let source = production_source(&fs::read_to_string(&path).expect("read syntax adapter"));
        for (index, line) in source.lines().enumerate() {
            let trimmed = line.trim_start();
            for pattern in forbidden_lines {
                if trimmed.contains(pattern) {
                    offenders.push(format!("{}:{}: {}", path.display(), index + 1, trimmed));
                }
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Concrete syntax adapters may classify grammar shapes, but must not own detector fact engines:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn ruby_syntax_profile_is_parser_only() {
    let path = crate_src().join("syntax/adapters/ruby.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read ruby syntax adapter"));
    let forbidden = [
        "tree_sitter::Node",
        "RawNode",
        "CallSite",
        "CallTarget",
        "Target",
        "FunctionDef",
        "StateRead",
        "StateWrite",
        "SemanticEffectSite",
        "ProtocolMethod",
        "fn call_target",
        "fn state_target",
        "fn state_read_target",
        "fn assignment_target",
        "fn function_name",
        "fn function_visibility",
        "fn owner_name_from_declaration",
        "fn clone_candidate_node",
        "fn clone_fingerprint_children",
        "ruby_",
    ];
    let offenders = forbidden
        .into_iter()
        .filter(|pattern| source.contains(pattern))
        .map(|pattern| pattern.to_string())
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Ruby syntax facts must come from normalized extraction; syntax/adapters/ruby.rs is parser-only:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn syntax_adapter_loader_does_not_forward_detector_fact_engines() {
    let path = crate_src().join("syntax/adapters/mod.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read syntax adapters mod"));
    let forbidden = [
        "protocols",
        "ProtocolMethod",
        "SemanticEffect",
        "structural_semantic",
        "method_effects",
        "call_paths",
    ];
    let offenders = forbidden
        .into_iter()
        .filter(|pattern| source.contains(pattern))
        .map(|pattern| pattern.to_string())
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "syntax/adapters/mod.rs must only select profiles and apply syntax-level helpers; detector fact derivation belongs outside adapters:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn normalized_extractor_does_not_depend_on_concrete_languages_or_tree_sitter() {
    let path = crate_src().join("syntax/normalized_extractor.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read normalized extractor"));
    let forbidden = [
        "tree_sitter",
        "Language::",
        "Ruby",
        "Python",
        "JavaScript",
        "TypeScript",
        "Swift",
        "Kotlin",
        "Lua",
        "Php",
        "CSharp",
        "ruby_",
        "python_",
        "javascript_",
        "Protocol",
        "puts",
        "print",
        "warn",
        "send",
        "public_send",
        "ENV",
        "File",
        "Dir",
    ];
    let offenders = forbidden
        .into_iter()
        .filter(|pattern| source.contains(pattern))
        .map(|pattern| pattern.to_string())
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Normalized extraction must consume only the normalized schema, not concrete language/parser APIs:\n{}",
        offenders.join("\n")
    );
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
