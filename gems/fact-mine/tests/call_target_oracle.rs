use anyhow::{Context, Result};
use fact_mine_rust::profile::{self, MethodRecord, Profile, ProfileOutput};
use fact_mine_rust::syntax::{self, Language};
use std::io::Write;
use std::fs;

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

fn extract_java_project(files: &[(&str, &str)]) -> Result<ProfileOutput> {
    let directory = tempfile::tempdir()?;
    let mut paths = Vec::new();
    for (name, source) in files {
        let path = directory.path().join(name);
        fs::write(&path, source)?;
        paths.push(path);
    }
    let outputs = syntax::parse_files(&paths, Language::Java)?
        .iter()
        .map(|document| profile::extract(document, Profile::Espalier))
        .collect();
    Ok(profile::merge(outputs, Profile::Espalier))
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
    assert!(output.call_graph_edges.is_empty(), "static calls are not internal-owner edges");
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
fn field_and_call_result_projections_remain_unknown_without_type_facts() -> Result<()> {
    let output = extract_source(
        "class Service {\n  int work() { return 1; }\n}\nclass Caller {\n  Service service;\n  Service factory() { return service; }\n  int run() {\n    service.work();\n    return factory().work();\n  }\n}\n",
        ".java",
        Language::Java,
    )?;
    let projected = output
        .calls
        .iter()
        .filter(|call| call.function == "run" && call.message == "work")
        .collect::<Vec<_>>();
    assert_eq!(projected.len(), 2);
    for call in projected {
        assert_eq!(call.target, None, "projection receiver {}", call.receiver);
    }
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
