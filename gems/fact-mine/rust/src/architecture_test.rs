use std::fs;
use std::path::{Path, PathBuf};

fn crate_src() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
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
fn syntax_adapters_directory_does_not_exist() {
    let adapters = crate_src().join("syntax/adapters");
    assert!(
        !adapters.exists(),
        "syntax/adapters was the old raw fact-profile boundary; use ast/adapters for normalization and syntax/normalized_<lang>.rs for language behavior"
    );
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
            "{} should not live in tree_sitter_adapter.rs; parser setup is grammar-only and language behavior belongs in normalized_<lang>.rs",
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
        "clone_similarity.rs",
        "complexity.rs",
        "effects.rs",
        "local_flow.rs",
        "normalized_behavior.rs",
        "normalized_c.rs",
        "normalized_cpp.rs",
        "normalized_csharp.rs",
        "normalized_extractor.rs",
        "normalized_go.rs",
        "normalized_java.rs",
        "normalized_javascript.rs",
        "normalized_kotlin.rs",
        "normalized_lua.rs",
        "normalized_php.rs",
        "normalized_python.rs",
        "normalized_ruby.rs",
        "normalized_rust.rs",
        "normalized_swift.rs",
        "normalized_typescript.rs",
        "normalized_zig.rs",
        "parser_grammar.rs",
        "passes.rs",
        "path_condition.rs",
        "protocols.rs",
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
fn removed_raw_syntax_profile_architecture_stays_removed() {
    let syntax_dir = crate_src().join("syntax");
    let forbidden = [
        "LanguageProfile",
        "false_simplicity_lexicon",
        "syntax/adapters",
        "materialize_protocol_facts",
        "raw_tree",
    ];
    let mut offenders = Vec::new();
    for path in rust_files_recursive(&syntax_dir) {
        let source = production_source(&fs::read_to_string(&path).expect("read syntax file"));
        for pattern in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}", path.display(), pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Removed raw syntax profile/fallback architecture must not come back:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn generic_syntax_files_do_not_own_language_guard_or_metadata_lexicons() {
    let syntax_dir = crate_src().join("syntax");
    let language_files = [
        "normalized_c.rs",
        "normalized_cpp.rs",
        "normalized_csharp.rs",
        "normalized_go.rs",
        "normalized_java.rs",
        "normalized_javascript.rs",
        "normalized_kotlin.rs",
        "normalized_lua.rs",
        "normalized_php.rs",
        "normalized_python.rs",
        "normalized_ruby.rs",
        "normalized_rust.rs",
        "normalized_swift.rs",
        "normalized_typescript.rs",
        "normalized_zig.rs",
    ];
    let forbidden = [
        "\"nil?\"",
        "\"respond_to?\"",
        "\"is_a?\"",
        "\"kind_of?\"",
        "\"instance_of?\"",
        "\"isNull\"",
        "\"is_null\"",
        "\"is_none\"",
        "\"is_some\"",
        "T::Struct",
        "const :",
        "ruby_metadata",
    ];
    let mut offenders = Vec::new();

    for path in rust_files_recursive(&syntax_dir) {
        let relative = path
            .strip_prefix(&syntax_dir)
            .expect("syntax file under syntax dir")
            .to_string_lossy()
            .replace('\\', "/");
        if language_files.contains(&relative.as_str()) {
            continue;
        }
        let source = production_source(&fs::read_to_string(&path).expect("read syntax file"));
        for pattern in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}", path.display(), pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Concrete guard/metadata spellings belong in normalized_<language>.rs, not generic syntax files:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn clone_similarity_does_not_depend_on_parser_or_concrete_languages() {
    let path = crate_src().join("syntax/clone_similarity.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read clone similarity"));
    let forbidden = [
        "tree_sitter",
        "RawNode",
        "document.root",
        "LanguageProfile",
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
        "default_clone_candidate_node",
        "raw_clone",
        "T::Struct",
    ];
    let offenders = forbidden
        .into_iter()
        .filter(|pattern| source.contains(pattern))
        .map(|pattern| pattern.to_string())
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Clone similarity must consume only normalized syntax facts, not parser, profile-hook, or concrete-language APIs:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn parse_file_routes_all_languages_through_normalized_passes() {
    let path = crate_src().join("syntax/tree_sitter_adapter.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read tree_sitter_adapter"));
    let parse_file_source = source
        .split_once("fn parse_file_with_options")
        .and_then(|(_, rest)| {
            rest.split_once("fn parse_normalized_file")
                .map(|(body, _)| body)
        })
        .unwrap_or("");
    let forbidden = [
        "collect_facts(",
        "collect_dispatch_sites(",
        "collect_implicit_state_accesses(",
        "apply_visibility(",
        "RawNode::from_tree_sitter",
    ];
    let missing = [
        "parse_normalized_file(",
        "normalize_tree(",
        "StatelessSyntaxPass::normalized",
        "StatefulSyntaxPass::new",
    ];
    let mut offenders = forbidden
        .into_iter()
        .filter(|pattern| parse_file_source.contains(pattern))
        .map(|pattern| format!("forbidden raw collection path: {pattern}"))
        .collect::<Vec<_>>();
    offenders.extend(
        missing
            .into_iter()
            .filter(|pattern| !source.contains(pattern))
            .map(|pattern| format!("missing normalized pipeline call: {pattern}")),
    );

    assert!(
        offenders.is_empty(),
        "parse_file must normalize every language, then run stateless/stateful normalized passes:\n{}",
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
fn normalized_extractor_does_not_own_stateful_enrichment() {
    let path = crate_src().join("syntax/normalized_extractor.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read normalized extractor"));
    let forbidden = [
        "apply_visibility",
        "VisibilityEvent",
        "false_simplicity_lexicon",
        "semantic_effect_sites_from_calls",
        "ruby_immutable",
        "ruby_type_alias",
        "ruby_sig_param",
    ];
    let offenders = forbidden
        .into_iter()
        .filter(|pattern| source.contains(pattern))
        .map(|pattern| pattern.to_string())
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Normalized extraction must remain stateless; stateful enrichment belongs in syntax/passes.rs and role modules:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn tree_sitter_adapter_does_not_own_stateful_enrichment_engines() {
    let path = crate_src().join("syntax/tree_sitter_adapter.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read tree_sitter_adapter"));
    let forbidden = [
        "fn semantic_effect_sites_from_calls",
        "fn dedup_semantic_effect_sites",
        "fn ruby_immutable",
        "fn reader_sets_to_vecs",
        "fn ruby_type_alias",
        "fn ruby_method_param_types",
        "fn ruby_sig_param_types",
    ];
    let offenders = forbidden
        .into_iter()
        .filter(|pattern| source.contains(pattern))
        .map(|pattern| pattern.to_string())
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "tree_sitter_adapter.rs should parse and orchestrate passes, not own stateful fact engines:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn rust_syntax_passes_do_not_touch_parser_internals() {
    let checked = [
        crate_src().join("syntax/normalized_behavior.rs"),
        crate_src().join("syntax/normalized_ruby.rs"),
        crate_src().join("syntax/passes.rs"),
        crate_src().join("syntax/effects.rs"),
    ];
    let forbidden = ["tree_sitter", "RawNode", "document.root"];
    let mut offenders = Vec::new();

    for path in checked {
        let source = production_source(&fs::read_to_string(&path).expect("read pass file"));
        for pattern in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}", path.display(), pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Stateful pass modules must consume facts/source metadata, not parser internals:\n{}",
        offenders.join("\n")
    );
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
