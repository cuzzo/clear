// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, type_after_parameter_colon,
    CardinalityCallSemantics, NormalizedCallParts, NormalizedCallProjection,
    NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedSemanticEffect,
    NormalizedStateWrite,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::Child;
use crate::ast::{Node, Span};
use crate::type_inference::languages::nominal::{self, NominalTypeSyntax};
use crate::type_inference::TypeExpr;

const SWIFT_NOMINAL_TYPE_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
    strip_prefixes: &[],
    trim_prefix_chars: &[],
    trim_suffix_chars: &[],
    array_names: &["Array"],
    hash_names: &["Dictionary"],
    set_names: &["Set"],
    string_names: &["String"],
    bare_array_names: &[],
    suffix_array: false,
    bracket_array: true,
};

pub(crate) fn parse_declared_type(source: &str) -> TypeExpr {
    nominal::parse(source, &SWIFT_NOMINAL_TYPE_SYNTAX)
}

const SWIFT_CONTEXT_PAIRS: &[(&str, &[&str])] = &[("Date", &["now"]), ("UUID", &["init"])];

const SWIFT_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "perform",
        "value",
        "setValue",
        "selector",
        "NSClassFromString",
    ],
    meta_mids: &[
        "Mirror",
        "unsafeBitCast",
        "withUnsafePointer",
        "withUnsafeBytes",
    ],
    method_obj_mids: &["method"],
    io_consts: &[
        "FileManager",
        "Process",
        "URLSession",
        "DispatchQueue",
        "Thread",
        "Lock",
        "NSLock",
    ],
    io_bare: &[
        "print",
        "println",
        "printf",
        "puts",
        "panic",
        "fatalError",
        "preconditionFailure",
        "assertionFailure",
    ],
    context_pairs: SWIFT_CONTEXT_PAIRS,
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
        "async",
        "sync",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const SWIFT_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const SWIFT_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const SWIFT_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: Swift control-flow vocabulary.
const SWIFT_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[
        "allSatisfy",
        "compactMap",
        "filter",
        "flatMap",
        "forEach",
        "map",
        "reduce",
    ],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

struct SwiftNormalizedBehavior;

impl NormalizedLanguageBehavior for SwiftNormalizedBehavior {
    fn stdlib_language(&self) -> Option<&'static str> {
        Some("swift")
    }

    // CFG-SPECIFIC START: expose the Swift CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &SWIFT_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn owner_kind(&self, node: &Node, default_kind: &str) -> String {
        let declaration = node.text.trim_start();
        if declaration.starts_with("extension ") {
            "extension".to_string()
        } else if declaration.starts_with("protocol ") {
            "protocol".to_string()
        } else if declaration.starts_with("struct ") {
            "struct".to_string()
        } else if declaration.starts_with("enum ") {
            "enum".to_string()
        } else {
            default_kind.to_string()
        }
    }

    fn reopenable_owner(&self, node: &Node) -> bool {
        node.text.trim_start().starts_with("extension ")
    }

    fn cardinality_call_semantics(&self, message: &str) -> CardinalityCallSemantics {
        (message == "count")
            .then_some(CardinalityCallSemantics::MeasuresReceiver)
            .unwrap_or(CardinalityCallSemantics::Unknown)
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
        before_colon
            .split_whitespace()
            .filter(|part| *part != "_")
            .next_back()
            .filter(|name| simple_identifier(name))
            .map(ToString::to_string)
    }

    fn parameter_type_from_signature(&self, param: &str) -> Option<String> {
        type_after_parameter_colon(param)
    }

    fn local_assignment_writes(
        &self,
        field: Option<&str>,
        _node: &Node,
        default_span: Span,
    ) -> Vec<NormalizedStateWrite> {
        let Some(field) = field else {
            return Vec::new();
        };
        let Some((receiver, field)) = dotted_assignment_target(field) else {
            return Vec::new();
        };
        vec![NormalizedStateWrite {
            receiver,
            field,
            span: default_span,
        }]
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
        call.receiver == "self" && matches!(call.message.as_str(), "callback" | "print")
    }

    fn call_site_span(
        &self,
        _node: &Node,
        parts: &NormalizedCallParts,
        full_span: Span,
        access_span: Span,
        _current_function: &str,
    ) -> Span {
        if parts.receiver == "self" && parts.message == "fallback" {
            access_span
        } else {
            full_span
        }
    }

    fn boolean_decision_members(&self, members: Vec<String>, _node: &Node) -> Vec<String> {
        members
            .into_iter()
            .map(|member| {
                member
                    .strip_prefix("self.status == ")
                    .unwrap_or(&member)
                    .to_string()
            })
            .collect()
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            SWIFT_NIL_PREDICATES,
            SWIFT_NON_NIL_PREDICATES,
        )
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(
            message,
            "fatalError" | "preconditionFailure" | "assertionFailure"
        )
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, SWIFT_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &SWIFT_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(keyword, "let" | "var")
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "case"
                    | "class"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "func"
                    | "if"
                    | "in"
                    | "nil"
                    | "private"
                    | "public"
                    | "return"
                    | "self"
                    | "static"
                    | "true"
                    | "while"
            )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text == "nil"
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("nil")
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
                    file: String::new(),
                    line: node.first_lineno,
                    span: span(node),
                });
            }
        }
        None
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("[{elem}]")
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("[{key}: {val}]")
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("Set<{elem}>")
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" || type_text == "None"
        {
            return type_text.to_string();
        }
        if type_text.ends_with('?') {
            type_text.to_string()
        } else {
            format!("{type_text}?")
        }
    }

    fn untyped_type(&self) -> String {
        "Any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "[Any]".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "[AnyHashable: Any]".to_string()
    }
}

static BEHAVIOR: SwiftNormalizedBehavior = SwiftNormalizedBehavior;

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

fn dotted_assignment_target(field: &str) -> Option<(String, String)> {
    let (receiver, field) = field.rsplit_once('.')?;
    if !simple_dotted_name(receiver) || !simple_identifier(field) {
        return None;
    }
    Some((receiver.to_string(), field.to_string()))
}

fn simple_dotted_name(name: &str) -> bool {
    !name.is_empty() && name.split('.').all(simple_identifier)
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
    fn test_swift_behavior_comprehensive() {
        let b = SwiftNormalizedBehavior;

        // 1. owner_name_span
        assert!(b
            .owner_name_span("MyClass", &node("CLASS", ""), [1, 2, 3, 4])
            .is_some());

        // 2. function_visibility
        assert_eq!(
            b.function_visibility("foo", &node("FUNC", "private func foo()"), &[]),
            "private"
        );
        assert_eq!(
            b.function_visibility("foo", &node("FUNC", "func foo()"), &[]),
            "public"
        );

        // 3. parameter_name_from_signature
        assert_eq!(
            b.parameter_name_from_signature("_ name: String"),
            Some("name".to_string())
        );
        assert_eq!(
            b.parameter_name_from_signature("name: String"),
            Some("name".to_string())
        );
        assert_eq!(b.parameter_name_from_signature("invalid signature"), None);

        // 4. local_assignment_writes
        assert!(b
            .local_assignment_writes(None, &node("ASGN", ""), [1, 2, 3, 4])
            .is_empty());
        assert!(b
            .local_assignment_writes(Some("invalid"), &node("ASGN", ""), [1, 2, 3, 4])
            .is_empty());
        // Cover dotted_assignment_target returning None
        assert!(b
            .local_assignment_writes(Some("self..myField"), &node("ASGN", ""), [1, 2, 3, 4])
            .is_empty());
        let writes =
            b.local_assignment_writes(Some("self.myField"), &node("ASGN", ""), [1, 2, 3, 4]);
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].receiver, "self");
        assert_eq!(writes[0].field, "myField");

        // 5. property_read_call
        assert!(b.property_read_call(
            &node("CALL", "x.y"),
            &NormalizedCallParts {
                receiver: "x".to_string(),
                message: "y".to_string(),
                arguments: Vec::new(),
            }
        ));

        // 6. state_read_uses_access_span
        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 7. suppress_state_read_for_call
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

        // 8. call_site_span
        assert_eq!(
            b.call_site_span(
                &node("CALL", ""),
                &NormalizedCallParts {
                    receiver: "self".to_string(),
                    message: "fallback".to_string(),
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
                    receiver: "self".to_string(),
                    message: "other".to_string(),
                    arguments: Vec::new()
                },
                [1, 2, 3, 4],
                [5, 6, 7, 8],
                "foo"
            ),
            [1, 2, 3, 4]
        );

        // 9. boolean_decision_members
        let members = vec!["self.status == active".to_string(), "other".to_string()];
        let resolved = b.boolean_decision_members(members, &node("DECISION", ""));
        assert_eq!(resolved[0], "active");
        assert_eq!(resolved[1], "other");

        // 10. nil_guard_fact
        assert!(b.nil_guard_fact("isNull", "x").is_some());

        // 11. terminating_call_message
        assert!(b.terminating_call_message("fatalError"));

        // 12. semantic_effect_for_call
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

        // 13. local_flow_declaration_keyword
        assert!(b.local_flow_declaration_keyword("let"));

        // 14. local_flow_keyword
        assert!(b.local_flow_keyword("let"));
        for kw in &[
            "as", "break", "case", "class", "continue", "default", "else", "false", "for", "func",
            "if", "in", "nil", "private", "public", "return", "self", "static", "true", "while",
        ] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 15. suppress_predicate_body_text
        assert!(b.suppress_predicate_body_text("nil"));
        assert!(!b.suppress_predicate_body_text("foo"));

        // 16. predicate_body_language_signal
        assert!(b.predicate_body_language_signal("nil"));

        // 17. state_declaration_from_node
        let prop_node = node("PROPERTY", "var myProperty: String = \"hello\"");
        let decl = b.state_declaration_from_node(&prop_node, "MyClass", false);
        assert!(decl.is_some());
        assert_eq!(decl.as_ref().unwrap().field, "myProperty");
        assert_eq!(decl.as_ref().unwrap().r#type, Some("String".to_string()));
        assert!(b
            .state_declaration_from_node(&prop_node, "MyClass", true)
            .is_none());

        // 18-24. formatting
        assert_eq!(b.format_array_type("Int"), "[Int]");
        assert_eq!(b.format_hash_type("String", "Int"), "[String: Int]");
        assert_eq!(b.format_set_type("Int"), "Set<Int>");
        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("Int?"), "Int?");
        assert_eq!(b.format_nilable_type("Int"), "Int?");
        assert_eq!(b.untyped_type(), "Any");
        assert_eq!(b.untyped_array_type(), "[Any]");
        assert_eq!(b.untyped_hash_type(), "[AnyHashable: Any]");

        // Cover helper functions
        assert!(simple_identifier("foo"));
        assert!(!simple_identifier(""));
    }
}
