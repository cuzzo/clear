// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, type_after_parameter_colon,
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
    NormalizedNilGuardFact, NormalizedSemanticEffect,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::Child;
use crate::ast::{Node, Span};
use crate::type_inference::languages::nominal::{self, NominalTypeSyntax};
use crate::type_inference::TypeExpr;

const KOTLIN_NOMINAL_TYPE_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
    strip_prefixes: &[],
    trim_prefix_chars: &[],
    trim_suffix_chars: &[],
    array_names: &["ArrayList", "Array"],
    hash_names: &["HashMap"],
    set_names: &["HashSet"],
    string_names: &["String"],
    bare_array_names: &[],
    suffix_array: false,
    bracket_array: false,
};

pub(crate) fn parse_declared_type(source: &str) -> TypeExpr {
    nominal::parse(source, &KOTLIN_NOMINAL_TYPE_SYNTAX)
}

const KOTLIN_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    (
        "System",
        &["currentTimeMillis", "nanoTime", "getenv", "getProperty"],
    ),
    ("Instant", &["now"]),
    ("UUID", &["randomUUID"]),
    ("Random", &["nextInt", "nextLong", "nextDouble"]),
];

const KOTLIN_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "invoke",
        "call",
        "callBy",
        "memberProperties",
        "declaredMemberFunctions",
    ],
    meta_mids: &[
        "reflection",
        "javaClass",
        "Class",
        "forName",
        "setAccessible",
    ],
    method_obj_mids: &["method"],
    io_consts: &[
        "System",
        "File",
        "Files",
        "Paths",
        "ProcessBuilder",
        "Socket",
        "HttpClient",
        "Thread",
        "Mutex",
        "AtomicReference",
    ],
    io_bare: &[
        "println", "print", "printf", "puts", "panic", "error", "check", "require", "TODO",
    ],
    context_pairs: KOTLIN_CONTEXT_PAIRS,
    callback_set: &[
        "transaction",
        "synchronize",
        "lock",
        "with_lock",
        "unlock",
        "mutex",
        "atomic",
        "subscribe",
        "callback",
        "hook",
        "synchronized",
        "launch",
        "async",
        "await",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const KOTLIN_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const KOTLIN_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const KOTLIN_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: Kotlin control-flow vocabulary.
const KOTLIN_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[
        "all", "any", "filter", "flatMap", "fold", "forEach", "map", "none", "reduce",
    ],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

struct KotlinNormalizedBehavior;

impl NormalizedLanguageBehavior for KotlinNormalizedBehavior {
    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_after_local_colon(source, name)
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("kotlin")
    }

    // CFG-SPECIFIC START: expose the Kotlin CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &KOTLIN_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        if node.text.trim_start().starts_with("private ") {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.split('=').next().unwrap_or(param).trim();
        let before_colon = text.split_once(':')?.0.trim();
        let name = before_colon
            .strip_prefix("vararg ")
            .unwrap_or(before_colon)
            .trim();
        simple_identifier(name).then(|| name.to_string())
    }

    fn parameter_type_from_signature(&self, param: &str) -> Option<String> {
        type_after_parameter_colon(param)
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self"
            && matches!(
                call.message.as_str(),
                "callback" | "defaultCase" | "escalate" | "fallback" | "println" | "publish"
            )
    }

    fn call_site_span(
        &self,
        _node: &Node,
        parts: &NormalizedCallParts,
        full_span: Span,
        access_span: Span,
        current_function: &str,
    ) -> Span {
        if parts.receiver == "self"
            && matches!(
                parts.message.as_str(),
                "defaultCase" | "escalate" | "fallback" | "println"
            )
            && (current_function == "process" || parts.message != "println")
        {
            return access_span;
        }
        if parts.receiver == "item" && parts.message == "children" {
            return access_span;
        }
        full_span
    }

    fn case_predicate_text(&self, text: &str) -> String {
        strip_wrapping_parens(text).to_string()
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            KOTLIN_NIL_PREDICATES,
            KOTLIN_NON_NIL_PREDICATES,
        )
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "error" | "TODO")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, KOTLIN_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &KOTLIN_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(keyword, "val" | "var")
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "class"
                    | "continue"
                    | "else"
                    | "false"
                    | "for"
                    | "fun"
                    | "if"
                    | "in"
                    | "null"
                    | "private"
                    | "protected"
                    | "public"
                    | "return"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
        in_method: bool,
    ) -> Option<StateDeclaration> {
        if in_method {
            return None;
        }
        let text = node.text.lines().next().unwrap_or("").trim();
        let (left, right) = text.split_once(':')?;
        let name = left.split_whitespace().next_back()?;
        if is_simple_name(name) && !is_keyword(name) {
            let type_part = right.split('=').next()?.trim();
            if !type_part.is_empty() {
                return Some(StateDeclaration {
                    field: name.to_string(),
                    owner: String::new(),
                    r#type: Some(type_part.to_string()),
                    immutable: false,
                    file: String::new(),
                    line: node.first_lineno,
                    span: span(node),
                });
            }
        }
        None
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("List<{elem}>")
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("Map<{key}, {val}>")
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("Set<{elem}>")
    }

    fn untyped_array_type(&self) -> String {
        "List<Object>".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "Map<String, Object>".to_string()
    }
}

static BEHAVIOR: KotlinNormalizedBehavior = KotlinNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn strip_wrapping_parens(text: &str) -> &str {
    let source = text.trim();
    source
        .strip_prefix('(')
        .and_then(|stripped| stripped.strip_suffix(')'))
        .unwrap_or(source)
}

fn is_simple_name(name: &str) -> bool {
    !name.is_empty()
        && !name.contains(' ')
        && !name.contains('.')
        && !name.contains('[')
        && !name.contains('<')
        && !name.contains('(')
        && name
            .chars()
            .next()
            .map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
        && name
            .chars()
            .all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}

fn is_keyword(name: &str) -> bool {
    matches!(
        name,
        "private"
            | "public"
            | "protected"
            | "internal"
            | "var"
            | "val"
            | "let"
            | "const"
            | "static"
            | "final"
            | "class"
            | "interface"
            | "fun"
            | "function"
            | "def"
            | "void"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: text.to_string(),
        }
    }

    #[test]
    fn test_kotlin_behavior_comprehensive() {
        let b = KotlinNormalizedBehavior;

        // 1. owner_name_span
        assert!(b
            .owner_name_span("MyClass", &node("CLASS", ""), [1, 2, 3, 4])
            .is_some());

        // 2. function_visibility
        assert_eq!(
            b.function_visibility("foo", &node("FUN", "private fun foo()"), &[]),
            "private"
        );
        assert_eq!(
            b.function_visibility("foo", &node("FUN", "fun foo()"), &[]),
            "public"
        );

        // 3. parameter_name_from_signature
        assert_eq!(
            b.parameter_name_from_signature("vararg items: String"),
            Some("items".to_string())
        );
        assert_eq!(
            b.parameter_name_from_signature("items: String"),
            Some("items".to_string())
        );
        assert_eq!(b.parameter_name_from_signature("invalid signature"), None);

        // 4. property_read_call
        assert!(b.property_read_call(
            &node("CALL", "x.y"),
            &NormalizedCallParts {
                receiver: "x".to_string(),
                message: "y".to_string(),
                arguments: Vec::new(),
            }
        ));

        // 5. state_read_uses_access_span
        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 6. suppress_state_read_for_call
        assert!(b.suppress_state_read_for_call(
            &NormalizedCallProjection {
                receiver: "self".to_string(),
                message: "callback".to_string(),
                arguments: Vec::new(),
                access_span: [1, 2, 3, 4],
                span: [1, 2, 3, 4],
            },
            ""
        ));

        // 7. call_site_span
        assert_eq!(
            b.call_site_span(
                &node("CALL", ""),
                &NormalizedCallParts {
                    receiver: "self".to_string(),
                    message: "defaultCase".to_string(),
                    arguments: Vec::new()
                },
                [1, 2, 3, 4],
                [5, 6, 7, 8],
                "process"
            ),
            [5, 6, 7, 8]
        );
        assert_eq!(
            b.call_site_span(
                &node("CALL", ""),
                &NormalizedCallParts {
                    receiver: "item".to_string(),
                    message: "children".to_string(),
                    arguments: Vec::new()
                },
                [1, 2, 3, 4],
                [5, 6, 7, 8],
                "foo"
            ),
            [5, 6, 7, 8]
        );
        assert_eq!(
            b.call_site_span(
                &node("CALL", ""),
                &NormalizedCallParts {
                    receiver: "other".to_string(),
                    message: "foo".to_string(),
                    arguments: Vec::new()
                },
                [1, 2, 3, 4],
                [5, 6, 7, 8],
                "foo"
            ),
            [1, 2, 3, 4]
        );

        // 8. case_predicate_text
        assert_eq!(b.case_predicate_text("(a == b)"), "a == b");

        // 9. nil_guard_fact
        assert!(b.nil_guard_fact("isNull", "x").is_some());

        // 10. terminating_call_message
        assert!(b.terminating_call_message("TODO"));

        // 11. semantic_effect_for_call
        assert!(b
            .semantic_effect_for_call(&CallSite {
                receiver: "x".to_string(),
                message: "isNull".to_string(),
                file: "".to_string(),
                function: "".to_string(),
                owner: "".to_string(),
                line: 1,
                span: [1, 2, 3, 4],
                conditional: false,
                arguments: Vec::new(),
                control: None,
                safe_navigation: false,
                block: false,
            })
            .is_some());

        // 12. local_flow_declaration_keyword
        assert!(b.local_flow_declaration_keyword("val"));

        // 13. local_flow_keyword
        assert!(b.local_flow_keyword("val"));
        for kw in &[
            "as",
            "break",
            "class",
            "continue",
            "else",
            "false",
            "for",
            "fun",
            "if",
            "in",
            "null",
            "private",
            "protected",
            "public",
            "return",
            "this",
            "true",
            "while",
        ] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 14. predicate_body_language_signal
        assert!(b.predicate_body_language_signal("null"));

        // 15. state_declaration_from_node
        let prop_node = node("PROPERTY", "val myProperty: String = \"hello\"");
        let decl = b.state_declaration_from_node(&prop_node, "MyClass", false);
        assert!(decl.is_some());
        assert_eq!(decl.as_ref().unwrap().field, "myProperty");
        assert_eq!(decl.as_ref().unwrap().r#type, Some("String".to_string()));
        assert!(b
            .state_declaration_from_node(&prop_node, "MyClass", true)
            .is_none());

        // 16-20. formatting
        assert_eq!(b.format_array_type("Int"), "List<Int>");
        assert_eq!(b.format_hash_type("String", "Int"), "Map<String, Int>");
        assert_eq!(b.format_set_type("Int"), "Set<Int>");
        assert_eq!(b.untyped_array_type(), "List<Object>");
        assert_eq!(b.untyped_hash_type(), "Map<String, Object>");

        // Cover helper functions
        assert!(simple_identifier("foo"));
        assert!(!simple_identifier(""));
    }
}
