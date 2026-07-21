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
use sha2::{Digest, Sha256};
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

// Was invisible: TypeScript's own version of the Kotlin bug, but reachable
// (unlike Kotlin's primary_constructor, the constructor here is already a
// normal class member) - just misclassified. A `constructor(private
// readonly foo: Foo)` parameter normalizes as REQUIRED_PARAMETER, which
// the field-declaration recognizer in syntax/typescript.rs's
// state_declaration_from_node never matched. Fixed by widening its type
// gate to also accept REQUIRED_PARAMETER/OPTIONAL_PARAMETER when the
// parameter actually carries an accessibility/readonly modifier (a plain
// parameter with none stays a parameter, not state).
#[test]
fn typescript_constructor_parameter_property_is_recognized_as_state() {
    let document = parse_source(
        ".ts",
        Language::TypeScript,
        "class Widget {\n\
         constructor(private count: number) {\n\
         }\n\
         increment() {\n\
         this.count += 1;\n\
         }\n\
         }\n",
    );

    assert!(
        document.state_declarations.iter().any(|s| s.field == "count" && s.owner == "Widget"),
        "expected a Widget.count state declaration from the constructor parameter, got {:?}",
        document.state_declarations
    );
}

// Was dropped as an owner entirely: `abstract class Foo` is a distinct
// grammar node (abstract_class_declaration), not `class_declaration` - the
// default class_node matcher never recognized it, so the base class every
// concrete subclass extends vanished from owner_defs, and its own methods
// fell back to whatever unrelated owner the extractor happened to be
// tracking. Fixed by widening TypeScriptAstAdapter::class_node.
#[test]
fn typescript_abstract_class_is_recognized_as_an_owner() {
    let document = parse_source(
        ".ts",
        Language::TypeScript,
        "abstract class Widget {\n\
         count: number = 0;\n\
         increment() {\n\
         this.count += 1;\n\
         }\n\
         }\n",
    );

    assert!(
        document.owner_defs.iter().any(|o| o.name == "Widget"),
        "expected an abstract class to be recognized as an owner, got {:?}",
        document.owner_defs
    );
    assert!(
        document.function_defs.iter().any(|f| f.name == "increment" && f.owner == "Widget"),
        "expected Widget.increment, got {:?}",
        document.function_defs
    );
}

// Was dropped from state extraction entirely: an embedded field
// (`type Embedded struct { Basic; Vunique string }`) has no separate name
// token at all - the type itself is the field's access name (`e.Basic`) -
// so neither state_declaration_from_node's LVAR-name lookup nor
// field_name_from_declaration (unset for Go) had anything to find. Fixed
// by deriving the field name from the embedded type reference itself when
// there is no separate name.
#[test]
fn go_embedded_struct_field_is_recognized_as_state() {
    let document = parse_source(
        ".go",
        Language::Go,
        "package demo\n\n\
         type Basic struct {\n\
         Vname string\n\
         }\n\n\
         type Embedded struct {\n\
         Basic\n\
         Vunique string\n\
         }\n",
    );

    assert!(
        document.state_declarations.iter().any(|s| s.field == "Basic" && s.owner == "Embedded"),
        "expected the embedded Basic field to be recognized as state, got {:?}",
        document.state_declarations
    );
    assert!(
        document.state_declarations.iter().any(|s| s.field == "Vunique" && s.owner == "Embedded"),
        "expected the ordinary Vunique field to still be recognized, got {:?}",
        document.state_declarations
    );
}

// Real bug, found auditing commons-cli/rtree: Java's state-declaration
// text heuristic had no node-type guard at all (every other language's
// version restricts to FIELD_DECLARATION-shaped nodes), so any node whose
// text loosely resembled "word word ... = ..." matched - including plain
// comments. `// TODO this seems wrong` parsed as a field literally named
// "wrong". A real field declaration must still work exactly as before.
#[test]
fn java_comment_is_not_parsed_as_a_field_declaration() {
    let document = parse_source(
        ".java",
        Language::Java,
        "class Options {\n\
         // TODO this seems wrong\n\
         private String realField = \"x\";\n\
         }\n",
    );

    assert!(
        !document.state_declarations.iter().any(|s| s.field == "wrong"),
        "a comment must never be parsed as a field declaration, got {:?}",
        document.state_declarations
    );
    assert!(
        document.state_declarations.iter().any(|s| s.field == "realField"),
        "a real field declaration must still be recognized, got {:?}",
        document.state_declarations
    );
}

// Real bug, found auditing SmartEnum.cs: a field whose initializer
// contains no literal `{` at all (`static readonly Lazy<T> _x = new
// Lazy<T>(GetAllOptions, LazyThreadSafetyMode.ExecutionAndPublication);`)
// was never truncated by the old brace-based split, so the "last
// identifier in the text" grab reached past the field's own name and into
// the initializer expression, returning "ExecutionAndPublication" as if
// it were the field's name.
#[test]
fn csharp_field_with_braceless_initializer_keeps_its_own_name() {
    let document = parse_source(
        ".cs",
        Language::CSharp,
        "class Widget {\n\
         static readonly Lazy<int> _enumOptions =\n\
         new Lazy<int>(GetAllOptions, LazyThreadSafetyMode.ExecutionAndPublication);\n\
         }\n",
    );

    assert!(
        document.state_declarations.iter().any(|s| s.field == "_enumOptions"),
        "expected _enumOptions to keep its own name, got {:?}",
        document.state_declarations
    );
    assert!(
        !document.state_declarations.iter().any(|s| s.field == "ExecutionAndPublication"),
        "the initializer's trailing identifier must not leak in as the field name, got {:?}",
        document.state_declarations
    );
}

// Real bug, found auditing rich/rich/color.py: Python's state-declaration
// heuristic required a `:` type annotation unconditionally, so a plain,
// unannotated class-body assignment produced zero state declarations -
// exactly how Enum/IntEnum members are declared (`STANDARD = 1`), so every
// enum's members were invisible to state extraction entirely.
#[test]
fn python_enum_members_are_recognized_as_state() {
    let document = parse_source(
        ".py",
        Language::Python,
        "from enum import IntEnum\n\n\
         class ColorSystem(IntEnum):\n\
         \x20   STANDARD = 1\n\
         \x20   EIGHT_BIT = 2\n",
    );

    assert!(
        document.state_declarations.iter().any(|s| s.field == "STANDARD" && s.owner == "ColorSystem"),
        "expected STANDARD to be recognized as state, got {:?}",
        document.state_declarations
    );
    assert!(
        document.state_declarations.iter().any(|s| s.field == "EIGHT_BIT" && s.owner == "ColorSystem"),
        "expected EIGHT_BIT to be recognized as state, got {:?}",
        document.state_declarations
    );
}

// Real bug, found auditing plog: an operator overload's declarator is
// `operator_name` (`operator+=`) or `operator_cast` (`operator bool`), not
// `identifier`/`field_identifier` like an ordinary method - custom_function_name's
// BFS walk had no case for either, so it fell through into the parameter
// list and returned the first parameter's name as if it were the function's
// own name (`operator+=(const Record& record)` extracted as "record").
#[test]
fn cpp_operator_overloads_keep_their_own_name() {
    let document = parse_source(
        ".cpp",
        Language::Cpp,
        "struct Widget {\n\
         float x;\n\
         Widget& operator+=(const Widget& other) {\n\
         x += other.x;\n\
         return *this;\n\
         }\n\
         operator bool() const {\n\
         return x != 0;\n\
         }\n\
         };\n",
    );

    assert!(
        document.function_defs.iter().any(|f| f.name == "operator+="),
        "expected operator+= to keep its own name, not a parameter name, got {:?}",
        document.function_defs
    );
    assert!(
        document.function_defs.iter().any(|f| f.name == "operator bool"),
        "expected the cast operator to be named 'operator bool', got {:?}",
        document.function_defs
    );
}

// Real bug, found auditing plog: unlike C (where a bare `struct` is plain
// data with its own separate textual owner heuristic), C++ structs and
// classes are the same construct modulo default visibility - methods are
// routinely defined directly inside a `struct` body. The shared, cross-language
// default class_node matcher only recognized `class_specifier`, so every
// struct-with-methods was invisible as an owner and its methods fell back to
// a bogus file-stem pseudo-owner.
#[test]
fn cpp_struct_with_methods_is_recognized_as_an_owner() {
    let document = parse_source(
        ".cpp",
        Language::Cpp,
        "struct Vec3 {\n\
         float x;\n\
         void increment() {\n\
         x += 1;\n\
         }\n\
         };\n",
    );

    assert!(
        document.owner_defs.iter().any(|o| o.name == "Vec3"),
        "expected struct Vec3 to be recognized as an owner, got {:?}",
        document.owner_defs
    );
    assert!(
        document.function_defs.iter().any(|f| f.name == "increment" && f.owner == "Vec3"),
        "expected Vec3.increment, got {:?}",
        document.function_defs
    );
}

// Real bug, found auditing plog's Logger.h: a linkage/visibility macro
// between `class`/`struct` and the real type name (`class PLOG_LINKAGE
// Logger : ...`) is invisible to tree-sitter (macros are never expanded),
// so the grammar greedily consumes the macro token as the type's own name.
// The real name that follows then derails parsing into an ERROR-node
// recovery that swallows the entire class body - every real method vanishes
// (not misattributed, just gone), while a phantom, empty owner named after
// the macro itself appears in their place. Fixed by blanking the macro
// token (equal-length whitespace, preserving every later byte offset)
// before tree-sitter ever sees the source.
#[test]
fn cpp_linkage_macro_before_class_name_does_not_swallow_the_class_body() {
    let document = parse_source(
        ".cpp",
        Language::Cpp,
        "template<int instanceId>\n\
         class PLOG_LINKAGE Logger : public IAppender\n\
         {\n\
         public:\n\
         Logger(int maxSeverity) : m_maxSeverity(maxSeverity)\n\
         {\n\
         }\n\
         void addAppender(IAppender* appender)\n\
         {\n\
         m_appenders.push_back(appender);\n\
         }\n\
         private:\n\
         int m_maxSeverity;\n\
         };\n",
    );

    assert!(
        !document.owner_defs.iter().any(|o| o.name == "PLOG_LINKAGE"),
        "the linkage macro must never itself become a phantom owner, got {:?}",
        document.owner_defs
    );
    assert!(
        document.owner_defs.iter().any(|o| o.name == "Logger"),
        "expected the real class name Logger to be recovered, got {:?}",
        document.owner_defs
    );
    assert!(
        document.function_defs.iter().any(|f| f.name == "addAppender" && f.owner == "Logger"),
        "expected Logger.addAppender to survive the macro-corrupted parse, got {:?}",
        document.function_defs
    );
}

// Real bug: the linkage-macro fix above rewrites the buffer fed to
// tree-sitter's parser, but source_digest must always reflect the real,
// on-disk file - not the rewritten parse-only buffer - or freshness and
// staleness checks (which compare this digest against the file's own
// content) silently start comparing against the wrong thing.
#[test]
fn source_digest_matches_the_real_file_even_when_the_parse_buffer_is_rewritten() {
    let source = "class PLOG_LINKAGE Logger : public IAppender {\npublic:\n    void write() {}\n};\n";
    let mut file = tempfile::Builder::new().suffix(".cpp").tempfile().unwrap();
    file.write_all(source.as_bytes()).unwrap();
    let documents = syntax::parse_files(&[file.path().to_path_buf()], Language::Cpp).unwrap();
    let document = documents.into_iter().next().unwrap();

    let expected = format!("sha256:{:x}", Sha256::digest(source.as_bytes()));
    assert_eq!(
        document.source_digest, expected,
        "source_digest must hash the real file content, not the macro-stripped parse buffer"
    );
}
