// Minimal, in-repo fixtures for Espalier-consumed architecture extraction
// (owner/function/state facts) across languages, replacing the need to
// clone large external OSS repos to validate this specific concern. See
// gems/lineage/docs/agents/lang-support-quality.md for the original
// large-repo validation pass this narrows down to reproducible unit-level
// fixtures.
//
// Two currently-working languages (C#, Lua) get passing regression
// baselines. Two documented gaps (Kotlin, Swift) get `#[ignore]`d tests
// encoding the CORRECT expected behavior - proving the bug exists and
// pinning down its exact shape, without leaving the suite red for
// unrelated contributors. `cargo test -- --ignored` runs them directly.

use fact_mine_rust::syntax::{self, Language};
use std::io::Write;

fn parse_source(suffix: &str, language: Language, source: &str) -> syntax::Document {
    let mut file = tempfile::Builder::new().suffix(suffix).tempfile().unwrap();
    file.write_all(source.as_bytes()).unwrap();
    let documents = syntax::parse_files(&[file.path().to_path_buf()], language).unwrap();
    documents.into_iter().next().unwrap()
}

#[test]
fn csharp_class_extraction_finds_owner_functions_and_state() {
    let document = parse_source(
        ".cs",
        Language::CSharp,
        "public class Widget {\n\
         private int count;\n\
         public Widget(int start) {\n\
         count = start;\n\
         }\n\
         public void Increment() {\n\
         count += 1;\n\
         }\n\
         }\n",
    );

    assert!(
        document.owner_defs.iter().any(|o| o.name == "Widget"),
        "expected a Widget owner, got {:?}",
        document.owner_defs
    );
    assert!(
        document.function_defs.iter().any(|f| f.name == "Increment" && f.owner == "Widget"),
        "expected Widget.Increment, got {:?}",
        document.function_defs
    );
    assert!(
        document.state_declarations.iter().any(|s| s.field == "count" && s.owner == "Widget"),
        "expected a Widget.count state declaration, got {:?}",
        document.state_declarations
    );
}

#[test]
fn lua_metatable_class_extraction_finds_owner_functions_and_state() {
    let document = parse_source(
        ".lua",
        Language::Lua,
        "local Widget = {}\n\
         Widget.__index = Widget\n\n\
         function Widget.new(start)\n\
         local self = setmetatable({}, Widget)\n\
         self.count = start\n\
         return self\n\
         end\n\n\
         function Widget:increment()\n\
         self.count = self.count + 1\n\
         end\n",
    );

    // Lua has no formal `class` construct, so - unlike C# - ownership here
    // is inferred per-function from the `Widget:method`/`Widget.method`
    // receiver prefix, not a separate owner_defs entry.
    assert!(
        document.function_defs.iter().any(|f| f.name == "increment" && f.owner == "Widget"),
        "expected Widget:increment, got {:?}",
        document.function_defs
    );
    assert!(
        document.function_defs.iter().any(|f| f.name == "new" && f.owner == "Widget"),
        "expected Widget.new, got {:?}",
        document.function_defs
    );
}

// Was invisible entirely: `count` is a `class_parameter` of a
// `primary_constructor` that is a *sibling* of `class_body`, not a child of
// it, so the default class-body scan never reached it. Fixed via a new
// opt-in AstNormalizationAdapter hook (supplementary_class_body_nodes,
// gems/fact-mine/src/ast/adapters/base.rs + normalizer.rs's normalize_class)
// that folds extra raw nodes into the scanned body - a no-op for every
// language except Kotlin's override
// (gems/fact-mine/src/ast/adapters/kotlin.rs), which surfaces `var`/`val`
// primary-constructor parameters. Kotlin's existing
// state_declaration_from_node text heuristic (gems/fact-mine/src/syntax/
// kotlin.rs) picks the resulting node up unchanged.
#[test]
fn kotlin_primary_constructor_property_is_recognized_as_state() {
    let document = parse_source(
        ".kt",
        Language::Kotlin,
        "class Widget(private var count: Int) {\n\
         fun increment() {\n\
         count += 1\n\
         }\n\
         }\n",
    );

    assert!(
        document.state_declarations.iter().any(|s| s.field == "count" && s.owner == "Widget"),
        "expected a Widget.count state declaration from the primary constructor, got {:?}",
        document.state_declarations
    );
}

// Was dropped from `functions` entirely: Swift's `init` has no separate
// "function" keyword (raw tree-sitter kind `init_declaration`, distinct
// from `function_declaration`), so the extractor's function-kind
// recognition never matched it. Fixed in
// gems/fact-mine/src/ast/adapters/swift.rs (SwiftAstAdapter::function_kind).
#[test]
fn swift_init_is_recognized_as_a_function() {
    let document = parse_source(
        ".swift",
        Language::Swift,
        "struct Widget {\n\
         var count: Int\n\
         init(start: Int) {\n\
         count = start\n\
         }\n\
         mutating func increment() {\n\
         count += 1\n\
         }\n\
         }\n",
    );

    assert!(
        document.function_defs.iter().any(|f| f.name == "init" && f.owner == "Widget"),
        "expected Widget.init to be recognized as a function, got {:?}",
        document.function_defs
    );
}
