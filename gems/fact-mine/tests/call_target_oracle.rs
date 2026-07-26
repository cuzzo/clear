use anyhow::{Context, Result};
use fact_mine_rust::profile::{self, MethodRecord, Profile, ProfileOutput};
use fact_mine_rust::syntax::{self, Language};
use std::fs;
use std::io::Write;

fn extract_source(source: &str, suffix: &str, language: Language) -> Result<ProfileOutput> {
    let mut file = tempfile::Builder::new().suffix(suffix).tempfile()?;
    file.write_all(source.as_bytes())?;
    let document = syntax::parse_file(file.path().to_path_buf(), language)?;
    Ok(profile::extract(&document, Profile::Espalier))
}

fn method<'a>(output: &'a ProfileOutput, owner: &str, name: &str) -> Result<&'a MethodRecord> {
    output
        .methods
        .iter()
        .find(|method| method.owner == owner && method.name == name)
        .with_context(|| format!("missing method {owner}#{name}"))
}

fn extract_project(files: &[(&str, &str)], language: Language) -> Result<ProfileOutput> {
    let directory = tempfile::tempdir()?;
    let mut paths = Vec::new();
    for (name, source) in files {
        let path = directory.path().join(name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&path, source)?;
        paths.push(path);
    }
    let outputs = syntax::parse_files(&paths, language)?
        .iter()
        .map(|document| profile::extract(document, Profile::Espalier))
        .collect();
    Ok(profile::merge(outputs, Profile::Espalier))
}

fn extract_java_project(files: &[(&str, &str)]) -> Result<ProfileOutput> {
    extract_project(files, Language::Java)
}

#[test]
fn local_shards_do_not_retain_cross_file_resolution() -> Result<()> {
    let directory = tempfile::tempdir()?;
    let callee_path = directory.path().join("Callee.java");
    let caller_path = directory.path().join("Caller.java");
    fs::write(
        &callee_path,
        "package demo; class Callee { void work() {} }\n",
    )?;
    fs::write(
        &caller_path,
        "package demo; class Caller { void run(Callee callee) { callee.work(); } }\n",
    )?;

    let callee = syntax::parse_file(callee_path, Language::Java)?;
    let caller = syntax::parse_file(caller_path, Language::Java)?;
    let caller_shard = profile::extract_local(&caller, Profile::Espalier);
    assert_eq!(caller_shard.profile(), Profile::Espalier);
    let local_call = caller_shard
        .local_output()
        .calls
        .iter()
        .find(|call| call.message == "work")
        .context("missing local call")?;
    assert!(local_call.target.is_none());
    assert!(local_call.candidate_targets.is_empty());
    assert!(caller_shard.local_output().call_graph_edges.is_empty());

    let output = profile::ProjectFactFinalizer::new(Profile::Espalier).finalize(vec![
        profile::extract_local(&callee, Profile::Espalier),
        caller_shard,
    ]);
    let target = output
        .methods
        .iter()
        .find(|method| method.name == "work")
        .context("missing project callee")?;
    let finalized_call = output
        .calls
        .iter()
        .find(|call| call.message == "work")
        .context("missing finalized call")?;
    assert_eq!(finalized_call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn c_free_call_resolves_to_exact_declaration_id_and_span() -> Result<()> {
    let output = extract_source(
        "int helper(void) {\n  return 1;\n}\n\nint run(void) {\n  return helper();\n}\n",
        ".c",
        Language::C,
    )?;
    let target = output
        .methods
        .iter()
        .find(|method| method.name == "helper")
        .context("missing C helper")?;
    assert_eq!(target.kind, "top");
    assert_eq!(target.span, Some([1, 0, 3, 1]));
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "helper")
        .context("missing helper call")?;
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn cpp_scoped_free_call_resolves_by_exact_namespace_identity() -> Result<()> {
    let output = extract_source(
        "namespace demo { int helper(int value) { return value; } }\nint run() { return demo::helper(1); }\n",
        ".cpp",
        Language::Cpp,
    )?;
    let target = output
        .methods
        .iter()
        .find(|method| method.name.contains("helper"))
        .context("missing C++ scoped helper")?;
    assert_eq!(target.span, Some([1, 17, 1, 56]));
    assert_eq!(target.lexical_symbol.as_deref(), Some("demo::helper"));
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run")
        .context("missing C++ scoped helper call")?;
    assert_eq!(call.message, "demo::helper");
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn cpp_scoped_free_call_never_joins_a_same_name_wrong_namespace() -> Result<()> {
    let output = extract_source(
        "namespace other { int helper(int value) { return value; } }\nint run() { return demo::helper(1); }\n",
        ".cpp",
        Language::Cpp,
    )?;
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run")
        .context("missing C++ scoped helper call")?;
    assert_eq!(call.lexical_symbol.as_deref(), Some("demo::helper"));
    assert_eq!(call.target, None);
    Ok(())
}

#[test]
fn python_explicit_import_resolves_an_exact_project_lexical_target() -> Result<()> {
    let output = extract_project(
        &[
            ("helper.py", "def work():\n    return 1\n"),
            (
                "caller.py",
                "from helper import work\n\ndef run():\n    return work()\n",
            ),
        ],
        Language::Python,
    )?;
    let target = output
        .methods
        .iter()
        .find(|method| method.path.ends_with("helper.py") && method.name == "work")
        .context("missing imported Python target")?;
    let call = output
        .calls
        .iter()
        .find(|call| call.path.ends_with("caller.py") && call.message == "work")
        .context("missing imported Python call")?;
    assert_eq!(target.lexical_symbol.as_deref(), Some("helper::work"));
    assert_eq!(call.lexical_symbol.as_deref(), Some("helper::work"));
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn python_explicit_import_does_not_short_name_join_the_wrong_module() -> Result<()> {
    let output = extract_project(
        &[
            ("helper.py", "def work():\n    return 1\n"),
            (
                "caller.py",
                "from other import work\n\ndef run():\n    return work()\n",
            ),
        ],
        Language::Python,
    )?;
    let call = output
        .calls
        .iter()
        .find(|call| call.path.ends_with("caller.py") && call.message == "work")
        .context("missing imported Python call")?;
    assert_eq!(call.lexical_symbol.as_deref(), Some("other::work"));
    assert_eq!(call.target, None);
    Ok(())
}

#[test]
fn empty_candidate_domains_separate_external_normalization_and_dynamic_causes() -> Result<()> {
    let external = extract_project(
        &[(
            "caller.py",
            "from external_pkg import absent\n\ndef run():\n    return absent()\n",
        )],
        Language::Python,
    )?;
    let external_call = external
        .calls
        .iter()
        .find(|call| call.message == "absent")
        .context("missing external call")?;
    assert_eq!(
        external_call.empty_domain_cause.as_deref(),
        Some("imported_declaration_outside_analyzed_set")
    );

    let project_surface = extract_project(
        &[
            ("helper.py", "def present():\n    return 1\n"),
            (
                "caller.py",
                "from helper import absent\n\ndef run():\n    return absent()\n",
            ),
        ],
        Language::Python,
    )?;
    let project_call = project_surface
        .calls
        .iter()
        .find(|call| call.message == "absent")
        .context("missing project-surface call")?;
    assert_eq!(
        project_call.empty_domain_cause.as_deref(),
        Some("normalization_project_declaration_surface_missing")
    );

    let missing_receiver = extract_project(
        &[(
            "caller.py",
            "def run(value):\n    return value.unknown_member()\n",
        )],
        Language::Python,
    )?;
    let receiver_call = missing_receiver
        .calls
        .iter()
        .find(|call| call.message == "unknown_member")
        .context("missing receiver call")?;
    assert_eq!(
        receiver_call.empty_domain_cause.as_deref(),
        Some("normalization_receiver_or_module_identity_missing")
    );

    let dynamic = extract_project(
        &[("caller.js", "function run() { return runtimeHook(); }\n")],
        Language::JavaScript,
    )?;
    let dynamic_call = dynamic
        .calls
        .iter()
        .find(|call| call.message == "runtimeHook")
        .context("missing dynamic call")?;
    assert_eq!(
        dynamic_call.empty_domain_cause.as_deref(),
        Some("dynamic_or_unbound_global_callable")
    );
    Ok(())
}

#[test]
fn call_resolution_coverage_has_an_honest_executable_denominator() -> Result<()> {
    let mut output = extract_source(
        "int helper(void) { return 1; }\nint run(void) { return helper(); }\n",
        ".c",
        Language::C,
    )?;
    let exact = output
        .calls
        .iter()
        .find(|call| call.message == "helper")
        .context("missing exact helper call")?
        .clone();

    let mut modeled = exact.clone();
    modeled.id = "edge:modeled".to_string();
    modeled.target = None;
    modeled.message = "strlen".to_string();
    modeled.known_time_complexity = Some("O(N)".to_string());
    modeled.unresolved_reason = Some("target_not_defined_in_document".to_string());

    let mut unresolved = exact.clone();
    unresolved.id = "edge:unresolved".to_string();
    unresolved.target = None;
    unresolved.message = "missing".to_string();
    unresolved.unresolved_reason = Some("receiver_requires_corpus_resolution".to_string());

    let mut dangling = unresolved.clone();
    dangling.id = "edge:dangling".to_string();
    dangling.target = Some("fn:not-in-method-index".to_string());

    let mut outside = unresolved.clone();
    outside.id = "edge:outside".to_string();
    outside.source = "fn:owner-body".to_string();

    output.calls = vec![exact, modeled, unresolved, dangling, outside];
    let merged = profile::merge(vec![output], Profile::Espalier);
    let coverage = &merged.call_resolution_coverage;
    assert_eq!(coverage.total_call_sites, 5);
    assert_eq!(coverage.eligible_call_sites, 4);
    assert_eq!(coverage.outside_executable_function, 1);
    assert_eq!(coverage.exact_project_targets, 1);
    assert_eq!(coverage.modeled_without_project_target, 1);
    assert_eq!(coverage.unresolved_call_sites, 2);
    assert_eq!(coverage.functions_with_unresolved_calls, 1);
    assert_eq!(coverage.exact_project_target_percent, 25.0);
    assert_eq!(coverage.accounted_call_percent, 50.0);
    assert_eq!(coverage.semantically_accounted_call_sites, 2);
    assert_eq!(coverage.semantically_accounted_call_percent, 50.0);
    assert_eq!(coverage.unresolved_call_percent, 50.0);
    assert_eq!(
        coverage
            .unresolved_by_reason
            .get("receiver_requires_corpus_resolution"),
        Some(&1)
    );

    let mut candidate = merged
        .calls
        .iter()
        .find(|call| call.id == "edge:unresolved")
        .unwrap()
        .clone();
    candidate.candidate_targets = vec![merged.methods[0].id.clone()];
    candidate.candidate_reason = Some("compiler_closed_implementation_set".to_string());
    let candidate_coverage =
        profile::summarize_call_resolution(&merged.owners, &merged.methods, &[candidate]);
    assert_eq!(candidate_coverage.accounted_call_percent, 0.0);
    assert_eq!(candidate_coverage.semantically_accounted_call_sites, 1);
    assert_eq!(
        candidate_coverage.semantically_accounted_call_percent,
        100.0
    );
    assert_eq!(
        coverage
            .unresolved_by_reason
            .get("target_id_not_in_method_index"),
        Some(&1)
    );
    assert_eq!(
        coverage
            .by_language
            .get("c")
            .map(|counts| counts.eligible_call_sites),
        Some(4)
    );
    Ok(())
}

#[test]
fn normalization_coverage_compares_parser_and_emitted_call_spans() -> Result<()> {
    let output = extract_source(
        "int helper(void) { return 1; }\nint run(void) { return helper(); }\n",
        ".c",
        Language::C,
    )?;
    assert_eq!(output.call_resolution_coverage.raw_parser_call_sites, 1);
    assert_eq!(output.call_resolution_coverage.raw_calls_not_normalized, 0);
    assert_eq!(
        output
            .call_resolution_coverage
            .normalized_calls_without_raw_span,
        0
    );
    Ok(())
}

#[test]
fn lexical_free_calls_share_the_exact_top_level_contract() -> Result<()> {
    for (source, suffix, language) in [
        (
            "def target; end\ndef run\n  target\nend\n",
            ".rb",
            Language::Ruby,
        ),
        (
            "def target():\n    pass\ndef run():\n    target()\n",
            ".py",
            Language::Python,
        ),
        (
            "package contract\nfunc target() {}\nfunc run() { target() }\n",
            ".go",
            Language::Go,
        ),
        (
            "function target(): void {}\nfunction run(): void { target(); }\n",
            ".ts",
            Language::TypeScript,
        ),
        (
            "void target() {}\nvoid run() { target(); }\n",
            ".c",
            Language::C,
        ),
        (
            "void target() {}\nvoid run() { target(); }\n",
            ".cpp",
            Language::Cpp,
        ),
        (
            "fn target() {}\nfn run() { target(); }\n",
            ".rs",
            Language::Rust,
        ),
        (
            "fun target() {}\nfun run() { target() }\n",
            ".kt",
            Language::Kotlin,
        ),
        (
            "func target() {}\nfunc run() { target() }\n",
            ".swift",
            Language::Swift,
        ),
        (
            "fn target() void {}\nfn run() void { target(); }\n",
            ".zig",
            Language::Zig,
        ),
        (
            "<?php\nfunction target(): void {}\nfunction run(): void { target(); }\n",
            ".php",
            Language::Php,
        ),
        (
            "function target() end\nfunction run() target() end\n",
            ".lua",
            Language::Lua,
        ),
    ] {
        let output = extract_source(source, suffix, language)?;
        let target = output
            .methods
            .iter()
            .find(|method| method.name == "target")
            .with_context(|| format!("{suffix}: missing lexical target"))?;
        assert_eq!(target.kind, "top", "{suffix}: {target:?}");
        let call = output
            .calls
            .iter()
            .find(|call| call.function == "run" && call.message == "target")
            .with_context(|| format!("{suffix}: missing lexical target call"))?;
        assert_eq!(
            call.target.as_deref(),
            Some(target.id.as_str()),
            "{suffix}: {call:?}"
        );
    }
    Ok(())
}

#[test]
fn java_instance_call_resolves_to_exact_declaration_id_and_span() -> Result<()> {
    let output = extract_source(
        "class Worker {\n  int helper() {\n    return 1;\n  }\n  int run() {\n    return helper();\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&output, "Worker", "helper")?;
    assert_eq!(target.kind, "instance");
    assert_eq!(target.span, Some([2, 2, 4, 3]));
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "helper")
        .context("missing helper call")?;
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn java_static_call_resolves_only_to_static_declaration() -> Result<()> {
    let output = extract_source(
        "class StaticTarget {\n  static int work() {\n    return 1;\n  }\n}\nclass Caller {\n  static int run() {\n    return StaticTarget.work();\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&output, "StaticTarget", "work")?;
    assert_eq!(target.kind, "class");
    assert_eq!(target.span, Some([2, 2, 4, 3]));
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing static work call")?;
    assert_eq!(call.receiver, "StaticTarget");
    assert_eq!(call.receiver_kind, "type");
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    assert_eq!(call.kind, "resolved_call");
    assert!(
        output.call_graph_edges.is_empty(),
        "static calls are not internal-owner edges"
    );
    Ok(())
}

#[test]
fn java_import_resolves_cross_file_to_exact_qualified_owner() -> Result<()> {
    let output = extract_java_project(&[
        (
            "AlphaHelper.java",
            "package alpha;\npublic class Helper {\n  public static int work() { return 1; }\n}\n",
        ),
        (
            "BetaHelper.java",
            "package beta;\npublic class Helper {\n  public static int work() { return 2; }\n}\n",
        ),
        (
            "Caller.java",
            "package client;\nimport alpha.Helper;\npublic class Caller {\n  public static int run() { return Helper.work(); }\n}\n",
        ),
    ])?;
    let target = output
        .methods
        .iter()
        .find(|method| {
            method.symbol_owner.as_deref() == Some("alpha.Helper") && method.name == "work"
        })
        .context("missing alpha.Helper.work")?;
    assert_eq!(target.span, Some([3, 2, 3, 40]));
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing imported Helper.work call")?;
    assert_eq!(call.receiver_symbol.as_deref(), Some("alpha.Helper"));
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    assert_eq!(call.kind, "resolved_call");
    assert!(
        call.candidate_targets.is_empty() && call.candidate_reason.is_none(),
        "an exact merged target must clear stale per-file ambiguity"
    );
    Ok(())
}

#[test]
fn go_package_lexical_call_resolves_only_with_canonical_directory_scope() -> Result<()> {
    let output = extract_project(
        &[
            (
                "helper.go",
                "package demo\nfunc helper() int { return 1 }\n",
            ),
            (
                "caller.go",
                "package demo\nfunc run() int { return helper() }\n",
            ),
            (
                "nested/helper.go",
                "package demo\nfunc helper() int { return 2 }\n",
            ),
        ],
        Language::Go,
    )?;
    let target = output
        .methods
        .iter()
        .find(|method| {
            method.name == "helper"
                && method.path.ends_with("/helper.go")
                && !method.path.contains("/nested/")
        })
        .context("missing root package helper")?;
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "helper")
        .context("missing Go package call")?;
    assert!(call.lexical_symbol.is_some());
    assert_eq!(call.lexical_symbol, target.lexical_symbol);
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn java_same_package_declared_type_resolves_cross_file() -> Result<()> {
    let output = extract_java_project(&[
        (
            "Service.java",
            "package contract;\npublic class Service {\n  public int work() { return 1; }\n}\n",
        ),
        (
            "Caller.java",
            "package contract;\npublic class Caller {\n  private Service service;\n  public int run(Service local) { service.work(); return local.work(); }\n}\n",
        ),
    ])?;
    let target = output
        .methods
        .iter()
        .find(|method| {
            method.symbol_owner.as_deref() == Some("contract.Service") && method.name == "work"
        })
        .context("missing contract.Service.work")?;
    let calls = output
        .calls
        .iter()
        .filter(|call| call.function == "run" && call.message == "work")
        .collect::<Vec<_>>();
    assert_eq!(calls.len(), 2);
    for call in calls {
        assert_eq!(call.receiver_symbol.as_deref(), Some("contract.Service"));
        assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    }
    Ok(())
}

#[test]
fn java_same_package_static_type_binding_requires_an_unshadowed_name() -> Result<()> {
    let output = extract_java_project(&[
        (
            "Util.java",
            "package demo;\nclass Util { static int work() { return 1; } }\n",
        ),
        (
            "Other.java",
            "package demo;\nclass Other { int work() { return 2; } }\n",
        ),
        (
            "Caller.java",
            "package demo;\nclass Caller { int staticCall() { return Util.work(); } int shadowed(Other Util) { return Util.work(); } }\n",
        ),
    ])?;
    let static_target = method(&output, "Util", "work")?;
    let static_call = output
        .calls
        .iter()
        .find(|call| call.function == "staticCall" && call.message == "work")
        .context("missing static Util.work call")?;
    assert_eq!(static_call.receiver_binding_kind, "unbound");
    assert_eq!(
        static_call.target.as_deref(),
        Some(static_target.id.as_str())
    );
    let shadowed = output
        .calls
        .iter()
        .find(|call| call.function == "shadowed" && call.message == "work")
        .context("missing shadowed Util.work call")?;
    assert_eq!(shadowed.receiver_binding_kind, "parameter");
    assert_ne!(shadowed.target.as_deref(), Some(static_target.id.as_str()));
    Ok(())
}

#[test]
fn java_declared_call_result_resolves_cross_file() -> Result<()> {
    let output = extract_java_project(&[
        (
            "Service.java",
            "package contract;\npublic class Service {\n  public int work() { return 1; }\n}\n",
        ),
        (
            "Factory.java",
            "package contract;\npublic class Factory {\n  public static Service create() { return new Service(); }\n}\n",
        ),
        (
            "Caller.java",
            "package client;\nimport contract.Factory;\npublic class Caller {\n  public int run() {\n    var service = Factory.create();\n    service.work();\n    return Factory.create().work();\n  }\n  public int uncertain(boolean flag) {\n    var service = Factory.create();\n    if (flag) service = null;\n    return service.work();\n  }\n}\n",
        ),
    ])?;
    let target = output
        .methods
        .iter()
        .find(|method| {
            method.symbol_owner.as_deref() == Some("contract.Service") && method.name == "work"
        })
        .context("missing contract.Service.work")?;
    let calls = output
        .calls
        .iter()
        .filter(|call| call.function == "run" && call.message == "work")
        .collect::<Vec<_>>();
    assert_eq!(calls.len(), 2, "work calls: {:?}", output.calls);
    let direct = calls
        .iter()
        .find(|call| call.receiver_call_span.is_some())
        .context("missing direct Factory.create().work projection")?;
    let assigned = calls
        .iter()
        .find(|call| !call.receiver_definition_call_spans.is_empty())
        .context("missing reaching-definition call-result projection")?;
    for call in [direct, assigned] {
        assert_eq!(call.receiver_symbol.as_deref(), Some("contract.Service"));
        assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    }
    let uncertain = output
        .calls
        .iter()
        .find(|call| call.function == "uncertain" && call.message == "work")
        .context("missing uncertain reaching-definition call")?;
    assert!(uncertain.receiver_definition_call_spans.is_empty());
    assert_eq!(uncertain.target, None);
    Ok(())
}

#[test]
fn java_complete_typed_local_resolves_through_canonical_import() -> Result<()> {
    let output = extract_java_project(&[
        (
            "Helper.java",
            "package alpha;\npublic class Helper {\n  public int work() { return 1; }\n}\n",
        ),
        (
            "Caller.java",
            "package client;\nimport alpha.Helper;\npublic class Caller {\n  public int run(Helper helper) { return helper.work(); }\n}\n",
        ),
    ])?;
    let target = output
        .methods
        .iter()
        .find(|method| {
            method.symbol_owner.as_deref() == Some("alpha.Helper") && method.name == "work"
        })
        .context("missing alpha.Helper instance work")?;
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing typed helper.work call")?;
    assert_eq!(call.receiver_kind, "value");
    assert_eq!(call.receiver_symbol.as_deref(), Some("alpha.Helper"));
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    assert_eq!(call.kind, "resolved_call");
    Ok(())
}

#[test]
fn declared_parameter_instance_calls_share_the_exact_same_document_contract() -> Result<()> {
    for (source, suffix, language, message) in [
        (
            "class Target\n  def work; end\nend\nclass Runner\n  extend T::Sig\n  sig { params(value: Target).void }\n  def run(value)\n    value.work\n  end\nend\n",
            ".rb",
            Language::Ruby,
            "work",
        ),
        (
            "package contract\ntype Target struct{}\nfunc (Target) Work() {}\nfunc Run(value Target) { value.Work() }\n",
            ".go",
            Language::Go,
            "Work",
        ),
        (
            "class Target { void work() {} }\nclass Runner { void run(Target value) { value.work(); } }\n",
            ".java",
            Language::Java,
            "work",
        ),
        (
            "class Target { work(): void {} }\nfunction run(value: Target): void { value.work(); }\n",
            ".ts",
            Language::TypeScript,
            "work",
        ),
        (
            "class Target { public void Work() {} }\nclass Runner { void Run(Target value) { value.Work(); } }\n",
            ".cs",
            Language::CSharp,
            "Work",
        ),
        (
            "class Target:\n    def work(self) -> None:\n        pass\n\ndef run(value: Target) -> None:\n    value.work()\n",
            ".py",
            Language::Python,
            "work",
        ),
        (
            "class Target { public: void work() {} };\nvoid run(Target value) { value.work(); }\n",
            ".cpp",
            Language::Cpp,
            "work",
        ),
        (
            "class Target { fun work() {} }\nfun run(value: Target) { value.work() }\n",
            ".kt",
            Language::Kotlin,
            "work",
        ),
        (
            "class Target { func work() {} }\nfunc run(value: Target) { value.work() }\n",
            ".swift",
            Language::Swift,
            "work",
        ),
        (
            "struct Target;\nimpl Target { fn work(&self) {} }\nfn run(value: Target) { value.work(); }\n",
            ".rs",
            Language::Rust,
            "work",
        ),
        (
            "const Target = struct { fn work(_: Target) void {} };\nfn run(value: Target) void { value.work(); }\n",
            ".zig",
            Language::Zig,
            "work",
        ),
        (
            "<?php\nclass Target { public function work(): void {} }\nfunction run(Target $value): void { $value->work(); }\n",
            ".php",
            Language::Php,
            "work",
        ),
    ] {
        let output = extract_source(source, suffix, language)?;
        let target = output
            .methods
            .iter()
            .find(|method| method.name == message && method.owner.contains("Target"))
            .with_context(|| format!("{suffix}: missing Target.{message}"))?;
        let call = output
            .calls
            .iter()
            .find(|call| {
                call.receiver.trim_start_matches('$') == "value" && call.message == message
            })
            .with_context(|| format!("{suffix}: missing value.{message}"))?;
        assert_eq!(
            call.target.as_deref(),
            Some(target.id.as_str()),
            "{suffix}: {call:?}"
        );
        assert_eq!(call.kind, "resolved_call", "{suffix}: {call:?}");
    }
    Ok(())
}

#[test]
fn annotated_multiline_parameter_type_reaches_the_exact_call_target() -> Result<()> {
    let output = extract_source(
        "class Target { void work() {} }\nclass Runner {\n  @Override\n  protected void run(\n      final Target value) {\n    value.work();\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&output, "Target", "work")?;
    assert_eq!(target.span, Some([1, 15, 1, 29]));
    let call = output
        .calls
        .iter()
        .find(|call| call.message == "work" && call.receiver == "value")
        .context("missing multiline parameter call")?;
    assert_eq!(call.receiver_type.as_deref(), Some("Target"));
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn declared_local_instance_calls_share_the_exact_same_document_contract() -> Result<()> {
    for (source, suffix, language, message) in [
        (
            "class Target { void work() {} }\nclass Runner { void run() { Target value = new Target(); value.work(); } }\n",
            ".java",
            Language::Java,
            "work",
        ),
        (
            "class Target { work(): void {} }\nfunction run(): void { let value: Target = new Target(); value.work(); }\n",
            ".ts",
            Language::TypeScript,
            "work",
        ),
        (
            "class Target { public void Work() {} }\nclass Runner { void Run() { Target value = new Target(); value.Work(); } }\n",
            ".cs",
            Language::CSharp,
            "Work",
        ),
        (
            "class Target:\n    def work(self) -> None:\n        pass\n\ndef run() -> None:\n    value: Target = Target()\n    value.work()\n",
            ".py",
            Language::Python,
            "work",
        ),
        (
            "class Target { public: void work() {} };\nvoid run() { Target value = Target(); value.work(); }\n",
            ".cpp",
            Language::Cpp,
            "work",
        ),
        (
            "package contract\ntype Target struct{}\nfunc (Target) Work() {}\nfunc Run() { var value Target; value.Work() }\n",
            ".go",
            Language::Go,
            "Work",
        ),
    ] {
        let output = extract_source(source, suffix, language)?;
        let target = output
            .methods
            .iter()
            .find(|method| method.name == message && method.owner.contains("Target"))
            .with_context(|| format!("{suffix}: missing Target.{message}"))?;
        let call = output
            .calls
            .iter()
            .find(|call| call.receiver == "value" && call.message == message)
            .with_context(|| format!("{suffix}: missing value.{message}"))?;
        assert_eq!(
            call.target.as_deref(),
            Some(target.id.as_str()),
            "{suffix}: {call:?}"
        );
    }
    Ok(())
}

#[test]
fn java_declared_local_type_survives_cfg_branching() -> Result<()> {
    let output = extract_source(
        "class Target { void work() {} }\nclass Runner {\n  void run(boolean enabled) {\n    final Target value = new Target();\n    if (enabled) {\n      value.work();\n    }\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&output, "Target", "work")?;
    assert_eq!(target.span, Some([1, 15, 1, 29]));
    let call = output
        .calls
        .iter()
        .find(|call| call.receiver == "value" && call.message == "work")
        .context("missing loop-local work call")?;
    assert_eq!(call.receiver_type.as_deref(), Some("Target"));
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn java_loop_header_declarations_reach_exact_receiver_targets() -> Result<()> {
    let output = extract_source(
        "class Target { void work() {} }\nclass Runner {\n  void run(Target[] values, boolean enabled) {\n    for (Target value = new Target(); enabled; ) { value.work(); break; }\n    for (Target item : values) { item.work(); }\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&output, "Target", "work")?;
    let calls = output
        .calls
        .iter()
        .filter(|call| call.function == "run" && call.message == "work")
        .collect::<Vec<_>>();
    assert_eq!(calls.len(), 2);
    for call in calls {
        assert_eq!(call.receiver_type.as_deref(), Some("Target"));
        assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    }
    Ok(())
}

#[test]
fn generic_and_alias_types_resolve_only_their_single_nominal_owner() -> Result<()> {
    let java = extract_source(
        "class Box<T> { void work() {} }\nclass Runner { void run(Box<String> value) { value.work(); } }\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&java, "Box", "work")?;
    let call = java
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing generic Box.work call")?;
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));

    let ruby = extract_source(
        "class Target\n  def work; end\nend\nAliasTarget = T.type_alias { Target }\nclass Runner\n  extend T::Sig\n  sig { params(value: AliasTarget).void }\n  def run(value)\n    value.work\n  end\nend\n",
        ".rb",
        Language::Ruby,
    )?;
    let target = method(&ruby, "Target", "work")?;
    let call = ruby
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing aliased Target.work call")?;
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn java_short_name_without_scope_proof_never_chooses_a_corpus_match() -> Result<()> {
    let output = extract_java_project(&[
        (
            "Helper.java",
            "package alpha;\npublic class Helper {\n  public static int work() { return 1; }\n}\n",
        ),
        (
            "Caller.java",
            "package client;\npublic class Caller {\n  public static int run() { return Helper.work(); }\n}\n",
        ),
    ])?;
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing unscoped Helper.work call")?;
    assert_eq!(call.receiver_symbol, None);
    assert_eq!(call.target, None);
    Ok(())
}

#[test]
fn wrong_owner_overloads_and_value_receivers_remain_unknown() -> Result<()> {
    let output = extract_source(
        "class Alpha {\n  static int work() { return 1; }\n}\nclass Beta {\n  static int work() { return 2; }\n}\nclass Caller {\n  int work(int value) { return value; }\n  int work(String value) { return value.length(); }\n  int run(Service service) {\n    Alpha.missing();\n    service.work();\n    return work(1);\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    for call in output.calls.iter().filter(|call| {
        call.function == "run" && matches!(call.message.as_str(), "missing" | "work")
    }) {
        assert_eq!(
            call.target, None,
            "unexpected target for {}.{}",
            call.receiver, call.message
        );
    }
    let overload = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.receiver == "self" && call.message == "work")
        .context("missing ambiguous local overload")?;
    assert_eq!(overload.candidate_targets.len(), 2);
    assert_eq!(
        overload.candidate_reason.as_deref(),
        Some("overload_or_override")
    );
    Ok(())
}

#[test]
fn java_unique_overload_arity_resolves_exact_declaration() -> Result<()> {
    let output = extract_source(
        "class Target {\n  int work() { return 1; }\n  int work(int value) { return value; }\n}\nclass Runner { int run(Target value) { return value.work(); } }\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&output, "Target", "work")?;
    assert_eq!(target.span, Some([2, 2, 2, 26]));
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing zero-arity overload call")?;
    assert_eq!(call.argument_count, 0);
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    Ok(())
}

#[test]
fn java_override_precedence_stays_with_the_lexical_owner() -> Result<()> {
    let output = extract_source(
        "class Parent {\n  int work() { return 1; }\n}\nclass Child extends Parent {\n  int work() { return 2; }\n  int run() { return work(); }\n}\n",
        ".java",
        Language::Java,
    )?;
    let child_target = method(&output, "Child", "work")?;
    assert_eq!(child_target.span, Some([5, 2, 5, 26]));
    let parent_target = method(&output, "Parent", "work")?;
    let call = output
        .calls
        .iter()
        .find(|call| call.function == "run" && call.message == "work")
        .context("missing overridden work call")?;
    assert_eq!(call.target.as_deref(), Some(child_target.id.as_str()));
    assert_ne!(call.target.as_deref(), Some(parent_target.id.as_str()));
    Ok(())
}

#[test]
fn declared_field_and_direct_call_result_projections_resolve_exactly() -> Result<()> {
    let output = extract_source(
        "class Service {\n  int work() { return 1; }\n}\nclass Caller {\n  Service service;\n  Service factory() { return service; }\n  int run() {\n    service.work();\n    return factory().work();\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let target = method(&output, "Service", "work")?;
    let projected = output
        .calls
        .iter()
        .filter(|call| call.function == "run" && call.message == "work")
        .collect::<Vec<_>>();
    assert_eq!(projected.len(), 2);
    let field_call = projected
        .iter()
        .find(|call| call.receiver == "service")
        .context("missing declared field call")?;
    assert_eq!(field_call.target.as_deref(), Some(target.id.as_str()));
    assert_eq!(target.span, Some([2, 2, 2, 26]));
    let result_call = projected
        .iter()
        .find(|call| call.receiver != "service")
        .context("missing call-result projection")?;
    assert_eq!(
        result_call.target.as_deref(),
        Some(target.id.as_str()),
        "{result_call:?}; definitions={:?}",
        output.type_definitions
    );
    assert!(result_call.receiver_call_span.is_some());
    Ok(())
}

#[test]
fn undeclared_ffi_call_remains_unknown() -> Result<()> {
    let output = extract_source(
        "int run(void) {\n  return foreign_api();\n}\n",
        ".c",
        Language::C,
    )?;
    let call = output
        .calls
        .iter()
        .find(|call| call.message == "foreign_api")
        .context("missing FFI call")?;
    assert_eq!(call.target, None);
    assert_eq!(
        call.unresolved_reason.as_deref(),
        Some("target_not_defined_in_document")
    );
    Ok(())
}

#[test]
fn c_function_like_macros_are_not_reported_as_missing_declarations() -> Result<()> {
    let output = extract_project(
        &[(
            "macro.c",
            "#define project_value(x) ((x) + 1)\nint run(void) { return project_value(1); }\n",
        )],
        Language::C,
    )?;
    let call = output
        .calls
        .iter()
        .find(|call| call.message == "project_value")
        .context("missing macro invocation")?;
    assert!(call.preprocessor_callable);
    assert_eq!(
        call.empty_domain_cause.as_deref(),
        Some("macro_or_preprocessor_surface")
    );
    Ok(())
}

#[test]
fn language_proven_reflection_is_classified_before_receiver_guessing() -> Result<()> {
    let output = extract_java_project(&[(
        "Reflective.java",
        "package demo;\nclass Reflective { Object run(java.lang.reflect.Method method, Object target) throws Exception { return method.invoke(target); } }\n",
    )])?;
    let call = output
        .calls
        .iter()
        .find(|call| call.message == "invoke")
        .context("missing reflective invoke call")?;
    assert_eq!(call.target, None);
    assert_eq!(call.dispatch_boundary.as_deref(), Some("metaprogramming"));
    assert_eq!(
        call.resolution_missing_proof.as_deref(),
        Some("reflection_or_dynamic_dispatch")
    );
    Ok(())
}

#[test]
fn external_api_models_require_a_proven_native_receiver_type() -> Result<()> {
    let java = extract_source(
        "class Caller {\n  int run(ArrayList<String> values, ProjectList project) {\n    values.add(\"x\");\n    project.add(\"x\");\n    return values.size();\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let native = java
        .calls
        .iter()
        .find(|call| call.receiver == "values" && call.message == "add")
        .context("missing ArrayList.add call")?;
    assert_eq!(native.target, None);
    assert_eq!(native.known_time_complexity.as_deref(), Some("O(1)"));
    let lookalike = java
        .calls
        .iter()
        .find(|call| call.receiver == "project" && call.message == "add")
        .context("missing project add call")?;
    assert_eq!(lookalike.target, None);
    assert_eq!(lookalike.known_time_complexity, None);

    let python = extract_source(
        "def run(values: list[int]):\n    values.append(1)\n",
        ".py",
        Language::Python,
    )?;
    let append = python
        .calls
        .iter()
        .find(|call| call.message == "append")
        .context("missing list.append call")?;
    assert_eq!(append.target, None);
    assert_eq!(append.known_time_complexity.as_deref(), Some("O(1)"));
    Ok(())
}

#[test]
fn commons_cli_rtree_and_javapoet_anonymous_methods_keep_exact_spans() -> Result<()> {
    let output = extract_source(
        "class CorpusRegressions {\n  Object commonsCli() {\n    return new TableDefinition() {\n      public String caption() { return \"caption\"; }\n      public String[] headers() { return new String[0]; }\n      public Iterable<?> rows() { return null; }\n    };\n  }\n\n  Object rTree() {\n    return new Func2<Integer, Integer, Integer>() {\n      public Integer call(Integer left, Integer right) { return left + right; }\n    };\n  }\n\n  Object javaPoet() {\n    return new Appendable() {\n      public Appendable append(char value) { return this; }\n    };\n  }\n}\n",
        ".java",
        Language::Java,
    )?;

    let actual = ["caption", "headers", "rows", "call", "append"]
        .into_iter()
        .map(|name| {
            let methods = output
                .methods
                .iter()
                .filter(|method| method.name == name)
                .collect::<Vec<_>>();
            assert_eq!(methods.len(), 1, "anonymous-class method {name}");
            (name, methods[0].span)
        })
        .collect::<Vec<_>>();
    assert_eq!(
        actual,
        vec![
            ("caption", Some([4, 6, 4, 51])),
            ("headers", Some([5, 6, 5, 57])),
            ("rows", Some([6, 6, 6, 48])),
            ("call", Some([12, 6, 12, 79])),
            ("append", Some([18, 6, 18, 59])),
        ]
    );
    Ok(())
}

#[test]
fn java_inherited_call_resolves_to_exact_declaration_id_and_span() -> Result<()> {
    let output = extract_java_project(&[
        (
            "Base.java",
            "package demo;\nclass Base { int work() { return 1; } }\n",
        ),
        (
            "Child.java",
            "package demo;\nclass Child extends Base { int run() { return work(); } }\n",
        ),
    ])?;
    let child = output
        .owners
        .iter()
        .find(|owner| owner.name == "Child")
        .context("missing Child owner")?;
    assert_eq!(child.symbol.as_deref(), Some("demo.Child"));
    assert_eq!(child.supertypes, ["demo.Base"]);
    let call = output
        .calls
        .iter()
        .find(|call| call.message == "work")
        .context("missing inherited work call")?;
    let target = method(&output, "Base", "work")?;
    assert_eq!(target.span, Some([2, 13, 2, 37]));
    assert_eq!(call.target.as_deref(), Some(target.id.as_str()));
    assert_eq!(
        output
            .call_resolution_coverage
            .unresolved_with_unique_inherited_target,
        0
    );
    Ok(())
}

#[test]
fn conservative_inherited_dispatch_resolves_exact_native_declarations() -> Result<()> {
    for (source, suffix, language, owner, message, expected_span) in [
        (
            "class Base { public void Work() {} }\nclass Child : Base {}\nclass Runner { public void Run(Child value) { value.Work(); } }\n",
            ".cs",
            Language::CSharp,
            "Base",
            "Work",
            [1, 13, 1, 34],
        ),
        (
            "class Base:\n    def work(self):\n        return 1\nclass Child(Base):\n    def run(self):\n        return self.work()\n",
            ".py",
            Language::Python,
            "Base",
            "work",
            [2, 4, 3, 16],
        ),
        (
            "package demo\ntype Base struct{}\nfunc (Base) Work() {}\ntype Child struct { Base }\nfunc Run(value Child) { value.Work() }\n",
            ".go",
            Language::Go,
            "Base",
            "Work",
            [3, 0, 3, 21],
        ),
    ] {
        let output = extract_source(source, suffix, language)?;
        let target = method(&output, owner, message)?;
        assert_eq!(
            target.span,
            Some(expected_span),
            "{language:?} target declaration span"
        );
        let call = output
            .calls
            .iter()
            .find(|call| call.message == message && call.source != target.id)
            .with_context(|| format!("missing {language:?} inherited {message} call"))?;
        assert_eq!(
            call.target.as_deref(),
            Some(target.id.as_str()),
            "{language:?} exact inherited target"
        );
    }
    Ok(())
}

#[test]
fn language_adapters_extract_only_native_direct_supertype_clauses() -> Result<()> {
    for (source, suffix, language, owner_name, expected) in [
        (
            "class Base {}\nclass Child : Base, IFace {}\n",
            ".cs",
            Language::CSharp,
            "Child",
            vec!["Base", "IFace"],
        ),
        (
            "class Base: pass\nclass Child(Base, Protocol): pass\n",
            ".py",
            Language::Python,
            "Child",
            vec!["Base", "Protocol"],
        ),
        (
            "interface Face {}\nclass Child extends Base implements Face {}\n",
            ".ts",
            Language::TypeScript,
            "Child",
            vec!["Base", "Face"],
        ),
        (
            "class Base {};\nclass Child : public Base, private Face {};\n",
            ".cpp",
            Language::Cpp,
            "Child",
            vec!["Base", "Face"],
        ),
        (
            "class Base {}\nclass Child extends Base {}\n",
            ".js",
            Language::JavaScript,
            "Child",
            vec!["Base"],
        ),
        (
            "package demo\ntype Base struct{}\ntype Child struct {\n Base\n}\n",
            ".go",
            Language::Go,
            "Child",
            vec!["Base"],
        ),
    ] {
        let output = extract_source(source, suffix, language)?;
        let owner = output
            .owners
            .iter()
            .find(|owner| owner.name == owner_name)
            .with_context(|| format!("missing {language:?} owner {owner_name}"))?;
        let actual = owner
            .supertypes
            .iter()
            .map(|supertype| {
                supertype
                    .rsplit([':', '.'])
                    .find(|part| !part.is_empty())
                    .unwrap_or(supertype)
            })
            .collect::<Vec<_>>();
        assert_eq!(actual, expected, "{language:?}");
    }
    Ok(())
}

#[test]
fn csharp_namespace_is_retained_as_canonical_owner_identity() -> Result<()> {
    let output = extract_source(
        "namespace Demo.Core { class Target { public void Work() {} } }\n",
        ".cs",
        Language::CSharp,
    )?;
    let target = method(&output, "Target", "Work")?;
    assert_eq!(target.symbol_owner.as_deref(), Some("Demo.Core.Target"));
    Ok(())
}

/// A `base.field` receiver whose base type resolves must inherit the declared
/// field type, so `b.f.work()` resolves to the field type's method. This is a
/// language-neutral path (reads the declared field table), verified across the
/// statically-typed adapters that populate it.
#[test]
fn field_access_receiver_inherits_declared_field_type() -> Result<()> {
    let cases: &[(&str, &str, Language)] = &[
        (
            "go",
            "package demo\ntype Foo struct{}\nfunc (f Foo) Work() int { return 1 }\ntype Box struct { f Foo }\nfunc Field(b Box) int { return b.f.Work() }\n",
            Language::Go,
        ),
        (
            "rust",
            "struct Foo;\nimpl Foo { fn work(&self) -> i32 { 1 } }\nstruct Box { f: Foo }\nfn field(b: &Box) -> i32 { b.f.work() }\n",
            Language::Rust,
        ),
        (
            "java",
            "class Foo { int work() { return 1; } }\nclass Box { Foo f; }\nclass M { int field(Box b) { return b.f.work(); } }\n",
            Language::Java,
        ),
        (
            "swift",
            "struct Foo { func work() -> Int { return 1 } }\nstruct Box {\n    let f: Foo\n}\nfunc field(_ b: Box) -> Int { return b.f.work() }\n",
            Language::Swift,
        ),
    ];
    for (label, source, language) in cases {
        let suffix = format!(".{label}");
        let output = extract_source(source, &suffix, *language)?;
        let call = output
            .calls
            .iter()
            .find(|call| call.message.eq_ignore_ascii_case("work"))
            .with_context(|| format!("{label}: missing work call"))?;
        assert!(
            call.target.is_some(),
            "{label}: b.f.work() must resolve a target (got receiver_type {:?})",
            call.receiver_type
        );
        assert_eq!(
            call.receiver_type_origin.as_deref(),
            Some("field_access"),
            "{label}: receiver type must come from the field-access resolver",
        );
    }
    Ok(())
}

#[test]
fn explicit_type_arguments_do_not_replace_the_call_message() -> Result<()> {
    let cases: &[(&str, &str, Language, &str, &str)] = &[
        (
            "rust-method",
            "fn parse_num(text: &str) -> i64 { text.parse::<i64>().unwrap_or(0) }\n",
            Language::Rust,
            "text",
            "parse",
        ),
        (
            "rust-chained",
            "fn names(rows: &[String]) -> Vec<String> { rows.iter().cloned().collect::<Vec<_>>() }\n",
            Language::Rust,
            "rows.iter().cloned()",
            "collect",
        ),
        (
            "rust-free-function",
            "fn ident<T>(x: T) -> T { x }\nfn run() -> i32 { ident::<i32>(1) }\n",
            Language::Rust,
            "self",
            "ident",
        ),
    ];
    for (label, source, language, receiver, message) in cases {
        let output = extract_source(source, ".rs", *language)?;
        assert!(
            output
                .calls
                .iter()
                .any(|call| call.message == *message && call.receiver == *receiver),
            "{label}: expected `{receiver}.{message}` call, got {:?}",
            output
                .calls
                .iter()
                .map(|call| (call.receiver.clone(), call.message.clone()))
                .collect::<Vec<_>>()
        );
        assert!(
            !output
                .calls
                .iter()
                .any(|call| call.message.starts_with('<')),
            "{label}: type arguments must not be extracted as a call message, got {:?}",
            output
                .calls
                .iter()
                .map(|call| (call.receiver.clone(), call.message.clone()))
                .collect::<Vec<_>>()
        );
    }
    Ok(())
}

#[test]
fn synthetic_lambda_names_survive_qualified_name_handling() -> Result<()> {
    // `<lambda@2:24>` carries a row:column span, not a namespace. The shared
    // qualified-name split reported such a method as `24>`.
    let source = "package demo\nfunc helper(v int) int { return v }\nfunc run() { _ = func(x int) int { return helper(x) } }\n";
    let mut file = tempfile::Builder::new().suffix(".go").tempfile()?;
    file.write_all(source.as_bytes())?;
    let document = syntax::parse_file(file.path().to_path_buf(), Language::Go)?;
    let names = document
        .protocol_call_paths
        .iter()
        .map(|path| path.name.clone())
        .chain(
            document
                .protocol_method_effects
                .iter()
                .map(|effect| effect.name.clone()),
        )
        .collect::<Vec<_>>();
    assert!(
        names.iter().any(|name| name.starts_with("<lambda@") && name.ends_with('>')),
        "expected an intact synthetic lambda name, got {names:?}"
    );
    assert!(
        !names.iter().any(|name| name.ends_with('>') && !name.starts_with('<')),
        "a lambda name was split on its span separator, got {names:?}"
    );
    Ok(())
}
