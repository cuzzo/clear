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

use fact_mine_rust::profile::{self, Profile};
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

// Real bug, found auditing a real JS codebase: state mutated via
// increment/decrement (`this.lastId++`) or an in-place mutating method
// call (`this.items.push(x)`) produced zero state_writes - only a plain
// `this.field = value` assignment was ever recognized. Root causes were
// two separate gaps: (1) UPDATE_EXPRESSION (JS/C++/Java's dedicated
// increment/decrement grammar node) had no dispatch arm at all, so its
// operand was only ever scanned as an ordinary read; (2) state_receiver_field
// (shared across every "this."-spelling language) only recognized a
// "self." prefix, so even TypeScript - which already declared "push" a
// mutating_receiver_message - silently produced no write for `this.x.push()`.
#[test]
fn javascript_increment_and_mutating_method_call_are_recognized_as_state_writes() {
    let document = parse_source(
        ".js",
        Language::JavaScript,
        "class Store {\n\
         constructor() {\n\
         this.items = [];\n\
         this.lastId = 0;\n\
         }\n\
         add(x) {\n\
         this.items.push(x);\n\
         this.lastId++;\n\
         }\n\
         };\n",
    );

    assert!(
        document.state_writes.iter().any(|w| w.field == "items" && w.function == "add"),
        "expected this.items.push(x) to be recognized as a write to items, got {:?}",
        document.state_writes
    );
    assert!(
        document.state_writes.iter().any(|w| w.field == "lastId" && w.function == "add"),
        "expected this.lastId++ to be recognized as a write to lastId, got {:?}",
        document.state_writes
    );
}

// The same increment fix must not fire for C#'s generic
// PREFIX_UNARY_EXPRESSION/POSTFIX_UNARY_EXPRESSION node kind on any
// operator besides ++/--: `!this.flag` and `-this.count` are pure reads,
// and C# (unlike JS/Java) has no separate grammar rule distinguishing
// increment/decrement from every other unary operator - only the `++`/`--`
// spelling itself tells them apart.
#[test]
fn csharp_unary_negation_and_logical_not_are_not_recognized_as_state_writes() {
    let document = parse_source(
        ".cs",
        Language::CSharp,
        "class Store {\n\
         int lastId;\n\
         bool flag;\n\
         void Add() {\n\
         this.lastId++;\n\
         bool x = !this.flag;\n\
         int y = -this.lastId;\n\
         }\n\
         }\n",
    );

    assert!(
        document.state_writes.iter().any(|w| w.field == "lastId"),
        "expected this.lastId++ to still be recognized as a write, got {:?}",
        document.state_writes
    );
    assert!(
        !document.state_writes.iter().any(|w| w.field == "flag"),
        "!this.flag is a read, not a write - it must never appear in state_writes, got {:?}",
        document.state_writes
    );
}

// Go has no self/this keyword - method receivers are named freely
// (`func (s *Store) Add()`) and resolved to the canonical "self" receiver
// via receiver aliasing elsewhere. Go also spells increment/decrement as
// dedicated statements (INC_STATEMENT/DEC_STATEMENT), not an expression.
#[test]
fn go_receiver_increment_is_recognized_as_a_state_write() {
    let document = parse_source(
        ".go",
        Language::Go,
        "package demo\n\n\
         type Store struct {\n\
         LastId int\n\
         }\n\n\
         func (s *Store) Add() {\n\
         s.LastId++\n\
         }\n",
    );

    assert!(
        document.state_writes.iter().any(|w| w.field == "LastId" && w.owner == "Store"),
        "expected s.LastId++ to be recognized as a write to Store.LastId, got {:?}",
        document.state_writes
    );
}

// Real bug, third of the three reported JS object-literal state gaps: an
// object-literal key that is only ever initialized - never read or
// written again anywhere else - was invisible as state entirely, since
// every existing path to a state declaration only reacts to a later
// read/write. A module-level `const NAME = { key: value, ... }` binding
// (a plain-object "stateful module" idiom) now registers each key as
// state owned by NAME at declaration time, the same way a class field's
// initializer already does - the same fix applies to TypeScript, which
// has its own separate NormalizedLanguageBehavior for .ts files.
#[test]
fn javascript_object_literal_binding_registers_init_only_keys_as_state() {
    let document = parse_source(
        ".js",
        Language::JavaScript,
        "const config = {\n\
         timeout: 30,\n\
         retries: 3,\n\
         };\n\n\
         function connect() {\n\
         return config.timeout;\n\
         }\n",
    );

    assert!(
        document.state_declarations.iter().any(|d| d.field == "timeout" && d.owner == "config"),
        "expected config.timeout to be declared as state, got {:?}",
        document.state_declarations
    );
    assert!(
        document.state_declarations.iter().any(|d| d.field == "retries" && d.owner == "config"),
        "expected the init-only field retries (never read or written again) to still be \
         declared as state, got {:?}",
        document.state_declarations
    );
}

// A plain object literal built inside a function body is a local, throwaway
// value, not a module-level singleton - it must not be registered as state.
#[test]
fn javascript_function_local_object_literal_is_not_registered_as_state() {
    let document = parse_source(
        ".js",
        Language::JavaScript,
        "function build() {\n\
         const opts = { debug: true };\n\
         return opts;\n\
         }\n",
    );

    assert!(
        document.state_declarations.is_empty(),
        "a function-local object literal must not be registered as module state, got {:?}",
        document.state_declarations
    );
}

#[test]
fn javascript_calls_do_not_produce_phantom_state_reads() {
    let document = parse_source(
        ".js",
        Language::JavaScript,
        "class Widget {\n\
         escalate(user) {\n\
         return user;\n\
         }\n\
         process(fn, user) {\n\
         fn(5);\n\
         this.escalate(user);\n\
         }\n\
         };\n",
    );

    assert!(
        !document.state_reads.iter().any(|r| r.field == "fn"),
        "a bare call to a plain parameter must never read a field named after it, got {:?}",
        document.state_reads
    );
    assert!(
        !document.state_reads.iter().any(|r| r.field == "escalate"),
        "a real method call must never also read a field named after the method, got {:?}",
        document.state_reads
    );
    assert!(
        document.function_defs.iter().any(|f| f.name == "escalate" && f.owner == "Widget"),
        "escalate must still be recognized as a real method, got {:?}",
        document.function_defs
    );
}

#[test]
fn java_constructor_is_recognized_as_a_function_and_owns_its_field_writes() {
    let document = parse_source(
        ".java",
        Language::Java,
        "public class Widget {\n\
         private int count;\n\
         private String name;\n\
         public Widget(String name) {\n\
         this.count = 0;\n\
         this.name = name;\n\
         }\n\
         }\n",
    );

    assert!(
        document.function_defs.iter().any(|f| f.name == "Widget" && f.owner == "Widget"),
        "the constructor must be recognized as a function, got {:?}",
        document.function_defs
    );
    assert!(
        document
            .state_writes
            .iter()
            .any(|w| w.field == "count" && w.function == "Widget"),
        "the constructor's own field write must be attributed to it, not (top-level), got {:?}",
        document.state_writes
    );
    assert!(
        !document.state_writes.iter().any(|w| w.function == "(top-level)"),
        "no write should be left attributed to (top-level), got {:?}",
        document.state_writes
    );
}

fn parse_source_keep_file(
    suffix: &str,
    language: Language,
    source: &str,
) -> (syntax::Document, tempfile::NamedTempFile) {
    let mut file = tempfile::Builder::new().suffix(suffix).tempfile().unwrap();
    file.write_all(source.as_bytes()).unwrap();
    let documents = syntax::parse_files(&[file.path().to_path_buf()], language).unwrap();
    (documents.into_iter().next().unwrap(), file)
}

#[test]
fn java_and_csharp_leading_annotation_does_not_clobber_the_method_signature() {
    // profile::extract re-reads the source file from disk by path, so the
    // backing tempfile must outlive the call - unlike parse_source's other
    // callers, which only read the already-parsed Document.
    let (java_document, _java_file) = parse_source_keep_file(
        ".java",
        Language::Java,
        "public class Widget {\n\
         @Override\n\
         public String toString() {\n\
         return \"widget\";\n\
         }\n\
         }\n",
    );
    let java_output = profile::extract(&java_document, Profile::Espalier);
    let java_method = java_output
        .methods
        .iter()
        .find(|m| m.name == "toString")
        .unwrap_or_else(|| panic!("toString not found, got {:?}", java_output.methods));
    assert_eq!(java_method.signature, "public String toString()");

    let (csharp_document, _csharp_file) = parse_source_keep_file(
        ".cs",
        Language::CSharp,
        "public class Widget {\n\
         [Obsolete]\n\
         public int Run() {\n\
         return 1;\n\
         }\n\
         }\n",
    );
    let csharp_output = profile::extract(&csharp_document, Profile::Espalier);
    let csharp_method = csharp_output
        .methods
        .iter()
        .find(|m| m.name == "Run")
        .unwrap_or_else(|| panic!("Run not found, got {:?}", csharp_output.methods));
    assert_eq!(csharp_method.signature, "public int Run()");
}

#[test]
fn csharp_manual_property_accessor_bodies_are_recognized_as_state_reads_and_writes() {
    let document = parse_source(
        ".cs",
        Language::CSharp,
        "public class Widget {\n\
         private int _count;\n\
         public int Count {\n\
         get { return _count; }\n\
         set { _count = value; }\n\
         }\n\
         }\n",
    );

    assert!(
        document
            .state_reads
            .iter()
            .any(|r| r.field == "_count" && r.function == "Count"),
        "the getter's read of the backing field must be attributed to the property, got {:?}",
        document.state_reads
    );
    assert!(
        document
            .state_writes
            .iter()
            .any(|w| w.field == "_count" && w.function == "Count"),
        "the setter's write of the backing field must be attributed to the property, got {:?}",
        document.state_writes
    );
}

#[test]
fn typescript_field_with_initializer_is_recognized_as_state_with_correct_type() {
    let document = parse_source(
        ".ts",
        Language::TypeScript,
        "class Widget {\n\
         untyped = 10;\n\
         typed: number = 20;\n\
         }\n",
    );

    assert!(
        document.state_declarations.iter().any(|d| d.field == "untyped" && d.r#type.is_none()),
        "an untyped field with an initializer must still be declared as state, got {:?}",
        document.state_declarations
    );
    let typed = document
        .state_declarations
        .iter()
        .find(|d| d.field == "typed")
        .unwrap_or_else(|| panic!("typed field not found, got {:?}", document.state_declarations));
    assert_eq!(
        typed.r#type,
        Some("number".to_string()),
        "a typed field's initializer must not leak into its declared type"
    );
}

#[test]
fn csharp_interlocked_increment_is_recognized_as_a_state_write() {
    let document = parse_source(
        ".cs",
        Language::CSharp,
        "public class Widget {\n\
         private int _count;\n\
         public void Bump() {\n\
         Interlocked.Increment(ref _count);\n\
         }\n\
         }\n",
    );

    assert!(
        document.state_writes.iter().any(|w| w.field == "_count" && w.function == "Bump"),
        "Interlocked.Increment(ref _count) must be recognized as a write to _count, got {:?}",
        document.state_writes
    );
}

#[test]
fn lua_require_is_recognized_as_an_import() {
    let document = parse_source(
        ".lua",
        Language::Lua,
        "local Widget = require(\"widget\")\n\
         local Other = require('other.thing')\n",
    );

    assert!(
        document.imports.iter().any(|i| i.target == "widget" && i.kind == "file"),
        "require(\"widget\") must be recognized as a file import, got {:?}",
        document.imports
    );
    assert!(
        document.imports.iter().any(|i| i.target == "other.thing" && i.kind == "file"),
        "require('other.thing') must be recognized as a file import, got {:?}",
        document.imports
    );
}

#[test]
fn go_struct_tag_does_not_hide_an_embedded_field_or_leak_into_a_named_fields_type() {
    let document = parse_source(
        ".go",
        Language::Go,
        "package widget\n\n\
         type Widget struct {\n\
         Base  `mapstructure:\",squash\"`\n\
         Name string `mapstructure:\"name\"`\n\
         }\n",
    );

    assert!(
        document.state_declarations.iter().any(|d| d.field == "Base" && d.owner == "Widget"),
        "an embedded field with a struct tag must still be declared as state, got {:?}",
        document.state_declarations
    );
    let name_field = document
        .state_declarations
        .iter()
        .find(|d| d.field == "Name")
        .unwrap_or_else(|| panic!("Name field not found, got {:?}", document.state_declarations));
    assert_eq!(
        name_field.r#type,
        Some("string".to_string()),
        "a struct tag must not leak into the field's declared type"
    );
}

#[test]
fn javascript_static_method_is_tagged_class_not_instance() {
    let document = parse_source(
        ".js",
        Language::JavaScript,
        "class Widget {\n\
         static create() {\n\
         return new Widget();\n\
         }\n\
         instanceMethod() {\n\
         return 1;\n\
         }\n\
         }\n",
    );

    let create = document
        .function_defs
        .iter()
        .find(|f| f.name == "create")
        .unwrap_or_else(|| panic!("create not found, got {:?}", document.function_defs));
    assert_eq!(create.dispatch_kind, "class");
    let instance_method = document
        .function_defs
        .iter()
        .find(|f| f.name == "instanceMethod")
        .unwrap_or_else(|| panic!("instanceMethod not found, got {:?}", document.function_defs));
    assert_eq!(instance_method.dispatch_kind, "instance");
}

#[test]
fn python_chained_self_attribute_read_is_captured_separately_from_state_reads() {
    let document = parse_source(
        ".py",
        Language::Python,
        "class HookImpl:\n\
         def __init__(self, spec):\n\
         self.spec = spec\n\n\
         def describe(self):\n\
         return self.spec.namespace\n",
    );

    assert!(
        !document.state_reads.iter().any(|r| r.field == "namespace"),
        "an unproven cross-instance read must not be attributed as a direct state read, got {:?}",
        document.state_reads
    );
    assert!(
        document
            .chained_self_reads
            .iter()
            .any(|r| r.field == "namespace" && r.receiver == "spec"),
        "self.spec.namespace must be captured as a chained self-attribute read, got {:?}",
        document.chained_self_reads
    );
}
