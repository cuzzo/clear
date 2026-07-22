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
fn type_inference_language_grammars_live_in_language_modules() {
    let engine = fs::read_to_string(crate_src().join("type_inference.rs"))
        .expect("read type inference engine");
    for token in [
        "fn parse_ruby",
        "fn parse_python",
        "fn parse_typescript",
        "fn parse_go",
        "match language {",
    ] {
        assert!(
            !engine.contains(token),
            "shared type inference engine contains language selector {token}"
        );
    }

    let languages = crate_src().join("type_inference/languages");
    for file in ["ruby.rs", "python.rs", "typescript.rs", "go.rs"] {
        assert!(
            languages.join(file).is_file(),
            "missing type semantics module {file}"
        );
    }
}

#[test]
fn public_api_does_not_export_ast_or_parser_internals() {
    let lib_source = fs::read_to_string(crate_src().join("lib.rs")).expect("read lib.rs");
    let syntax_source = fs::read_to_string(crate_src().join("syntax.rs")).expect("read syntax.rs");
    let forbidden = [
        (&lib_source, "pub mod ast", "AST internals"),
        (
            &syntax_source,
            "pub mod tree_sitter_adapter",
            "tree-sitter adapter internals",
        ),
    ];

    for (source, pattern, label) in forbidden {
        assert!(
            !source.contains(pattern),
            "{} must not be public FactMine API",
            label
        );
    }
}

#[test]
fn document_public_api_does_not_expose_raw_syntax_internals() {
    let source = fs::read_to_string(crate_src().join("syntax.rs")).expect("read syntax.rs");
    let forbidden = [
        ("pub source: String", "raw source text"),
        ("pub lines: Vec<String>", "raw source lines"),
        ("pub root: RawNode", "raw syntax root"),
        ("pub normalized_root: NormalizedNode", "normalized IR root"),
        ("pub body: RawNode", "raw function body"),
    ];

    for (pattern, label) in forbidden {
        assert!(
            !source.contains(pattern),
            "{} must stay internal to FactMine passes",
            label
        );
    }
}

#[test]
fn syntax_adapters_directory_does_not_exist() {
    let adapters = crate_src().join("syntax/adapters");
    assert!(
        !adapters.exists(),
        "syntax/adapters was the old raw fact-profile boundary; use ast/adapters for normalization and syntax/<lang>.rs for language behavior"
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
            "{} should not live in tree_sitter_adapter.rs; parser setup is grammar-only and language behavior belongs in syntax/<lang>.rs",
            pattern
        );
    }
}

#[test]
fn ast_normalizer_does_not_define_a_language_adapter_enum() {
    let checked = [
        crate_src().join("ast.rs"),
        crate_src().join("ast/normalizer.rs"),
    ];
    for pattern in [
        "enum TreeSitterNormalizationAdapter",
        "impl TreeSitterNormalizationAdapter",
        "TreeSitterNormalizationAdapter::",
    ] {
        for path in &checked {
            let source = fs::read_to_string(path).expect("read shared AST file");
            assert!(
                !source.contains(pattern),
                "{} should live as polymorphic ast/adapters implementations",
                pattern
            );
        }
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
fn ast_adapter_base_does_not_own_concrete_language_selectors_or_lexicons() {
    let path = crate_src().join("ast/adapters/base.rs");
    let source = production_source(&fs::read_to_string(&path).expect("read ast adapter base"));
    let forbidden = [
        "fn ruby",
        "ruby_",
        "RUBY_",
        "python_",
        "PYTHON_",
        "lua_",
        "LUA_",
        "typescript_",
        "TYPESCRIPT_",
    ];
    let offenders = forbidden
        .into_iter()
        .filter(|pattern| source.contains(pattern))
        .map(|pattern| pattern.to_string())
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Shared AST adapter base must not own concrete-language selectors or lexicons:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn shared_ast_normalizer_does_not_own_concrete_parser_tokens() {
    let checked = [
        crate_src().join("ast.rs"),
        crate_src().join("ast/normalizer.rs"),
        crate_src().join("ast/adapters/base.rs"),
    ];
    let forbidden = [
        "\"unless\"",
        "\"unless_modifier\"",
        "\"elsif\"",
        "\"rescue_modifier\"",
        "\"rescue\"",
        "\"ensure\"",
        "\"begin\"",
        "\"instance_variable\"",
        "\"global_variable\"",
        "\"def\"",
        "\"singleton_method\"",
        "\"impl_item\"",
        "\"singleton_class\"",
        "\"block_argument\"",
        "\"until_modifier\"",
        "\"heredoc_beginning\"",
        "\"heredoc_body\"",
        "\"heredoc_content\"",
        "\"chained_string\"",
        "\"concatenated_string\"",
    ];
    let mut offenders = Vec::new();

    for path in checked {
        let source = production_source(&fs::read_to_string(&path).expect("read shared AST file"));
        for pattern in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}", path.display(), pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Concrete parser tokens belong in ast/adapters/<language>.rs, not shared AST normalization:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn syntax_directory_does_not_gain_unreviewed_helper_files() {
    let syntax_dir = crate_src().join("syntax");
    let expected = [
        "complexity_facts.rs",
        "clone_similarity.rs",
        "complexity.rs",
        "cfg/branches.rs",
        "cfg/builder.rs",
        "cfg/callbacks.rs",
        "cfg/cases.rs",
        "cfg/cursor.rs",
        "cfg/dataflow.rs",
        "cfg/effects.rs",
        "cfg/exceptions.rs",
        "cfg/exits.rs",
        "cfg/facts.rs",
        "cfg/loops.rs",
        "cfg/metrics.rs",
        "cfg/mod.rs",
        "cfg/projection.rs",
        "cfg/short_circuit.rs",
        "cfg/statements.rs",
        "cfg/validation.rs",
        "cfg/worklist.rs",
        "effects.rs",
        "local_flow.rs",
        "normalized_behavior.rs",
        "c.rs",
        "cpp.rs",
        "csharp.rs",
        "normalized_extractor.rs",
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
        "hazards.rs",
        "imports.rs",
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
fn complexity_fact_extractor_has_no_language_iterator_lexicon() {
    let source = fs::read_to_string(crate_src().join("syntax/complexity_facts.rs"))
        .expect("read complexity facts");
    let production = source.split("#[cfg(test)]").next().unwrap_or(&source);
    let forbidden = [
        "RUBY_ITERATION_METHODS",
        "\"each\"",
        "\"each_with_object\"",
        "\"map\"",
        "\"range\"",
        "\"times\"",
        "\"ZLIST\"",
        "\"DSTR\"",
        "TypeExpr::Primitive(\"String\"",
        "NormalizedCallComplexity {",
    ];
    let offenders = forbidden
        .iter()
        .filter(|token| production.contains(**token))
        .copied()
        .collect::<Vec<_>>();
    assert!(
        offenders.is_empty(),
        "language iterator, literal, and call-cost identities belong in language adapters: {}",
        offenders.join(", ")
    );
}

#[test]
fn syntax_language_files_use_plain_language_names() {
    let syntax_dir = crate_src().join("syntax");
    let offenders = rust_files_recursive(&syntax_dir)
        .into_iter()
        .filter_map(|path| {
            let file_name = path.file_name()?.to_str()?;
            (file_name.starts_with("normalized_")
                && file_name != "normalized_behavior.rs"
                && file_name != "normalized_extractor.rs")
                .then(|| path.display().to_string())
        })
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Concrete language syntax files must be syntax/<lang>.rs; normalized_* is reserved for generic normalized passes:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn language_specific_ast_files_live_only_in_ast_adapters() {
    let ast_dir = crate_src().join("ast");
    let forbidden_names = [
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
        "ruby_normalization.rs",
        "python_normalization.rs",
        "lua_normalization.rs",
        "typescript_normalization.rs",
    ];
    let offenders = rust_files_recursive(&ast_dir)
        .into_iter()
        .filter_map(|path| {
            let relative = path
                .strip_prefix(&ast_dir)
                .expect("ast file under ast dir")
                .to_string_lossy()
                .replace('\\', "/");
            if relative.starts_with("adapters/") {
                return None;
            }
            let file_name = path.file_name()?.to_str()?;
            (forbidden_names.contains(&file_name) || file_name.ends_with("_normalization.rs"))
                .then(|| relative)
        })
        .collect::<Vec<_>>();

    assert!(
        offenders.is_empty(),
        "Language-specific AST normalization belongs in ast/adapters/<lang>.rs, not extra ast helper files:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn syntax_subfiles_do_not_declare_nested_modules() {
    let syntax_dir = crate_src().join("syntax");
    let allowed_module_loaders = [
        syntax_dir.join("adapters/mod.rs"),
        syntax_dir.join("cfg/mod.rs"),
    ];
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
        "Concrete guard/metadata spellings belong in syntax/<language>.rs, not generic syntax files:\n{}",
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
        crate_src().join("syntax/ruby.rs"),
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
fn generic_cfg_does_not_own_concrete_language_knowledge() {
    let cfg_dir = crate_src().join("syntax/cfg");
    let forbidden = [
        "Language::",
        "Ruby",
        "Python",
        "JavaScript",
        "TypeScript",
        "Kotlin",
        "Swift",
        "Lua",
        "Php",
        "CSharp",
        "ruby_",
        "python_",
        "javascript_",
        "do end",
        "\"each\"",
        "\"forEach\"",
        "\"iter_mut\"",
    ];
    let mut offenders = Vec::new();

    for path in rust_files_recursive(&cfg_dir) {
        let source = production_source(&fs::read_to_string(&path).expect("read CFG file"));
        for pattern in forbidden {
            if source.contains(pattern) {
                offenders.push(format!("{}: {}", path.display(), pattern));
            }
        }
    }

    assert!(
        offenders.is_empty(),
        "Generic CFG code must consume normalized facts and injected profiles, never concrete-language knowledge:\n{}",
        offenders.join("\n")
    );
}

#[test]
fn language_cfg_additions_are_explicitly_demarcated() {
    let syntax_dir = crate_src().join("syntax");
    let language_files = [
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
    let mut offenders = Vec::new();
    let mut report = Vec::new();
    let mut total_marked_lines = 0usize;
    let mut total_vocabulary_entries = 0usize;

    for file in language_files {
        let path = syntax_dir.join(file);
        let source = fs::read_to_string(&path).expect("read language syntax file");
        let mut inside = false;
        let mut marked_lines = 0usize;
        let mut vocabulary_entries = 0usize;
        let mut profile_lines = Vec::new();

        for (index, line) in production_source(&source).lines().enumerate() {
            if line.contains("CFG-SPECIFIC START:") {
                if inside {
                    offenders.push(format!("{file}:{} nested CFG marker", index + 1));
                }
                inside = true;
                continue;
            }
            if line.contains("CFG-SPECIFIC END") {
                if !inside {
                    offenders.push(format!("{file}:{} unmatched CFG end marker", index + 1));
                }
                inside = false;
                continue;
            }
            if inside {
                marked_lines += 1;
                vocabulary_entries += line.matches('"').count() / 2;
            }
            if line.contains("cfg_profile") || line.contains("_CFG_PROFILE") {
                profile_lines.push((index + 1, inside));
            }
        }

        if inside {
            offenders.push(format!("{file}: unclosed CFG marker"));
        }
        if marked_lines == 0 {
            offenders.push(format!("{file}: no marked CFG-specific lines"));
        }
        total_marked_lines += marked_lines;
        total_vocabulary_entries += vocabulary_entries;
        report.push(format!(
            "{file}: {marked_lines} marked lines, {vocabulary_entries} vocabulary entries"
        ));
        offenders.extend(
            profile_lines
                .into_iter()
                .filter(|(_, is_marked)| !is_marked)
                .map(|(line, _)| format!("{file}:{line} CFG profile outside marked section")),
        );
    }

    assert!(
        offenders.is_empty(),
        "Language-owned CFG additions must stay measurable inside CFG-SPECIFIC markers:\n{}",
        offenders.join("\n")
    );

    eprintln!(
        "CFG adapter audit:\n{}\nTOTAL: {} marked lines, {} vocabulary entries",
        report.join("\n"),
        total_marked_lines,
        total_vocabulary_entries
    );
}

#[test]
fn ast_normalizer_does_not_branch_on_language_after_parser_setup() {
    let path = crate_src().join("ast/normalizer.rs");
    let normalizer_source = fs::read_to_string(&path).expect("read ast/normalizer.rs");
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
        "ast/normalizer.rs branches on language; put behavior in ast/adapters instead"
    );
}
