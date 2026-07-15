// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect,
};
use super::CallSite;
use crate::ast::{Node, Span};

const JAVASCRIPT_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("Date", &["now"]),
    ("Math", &["random"]),
    ("performance", &["now"]),
];

pub(crate) const JAVASCRIPT_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &["eval", "Function", "call", "apply", "bind"],
    meta_mids: &[
        "eval",
        "Function",
        "defineProperty",
        "defineProperties",
        "setPrototypeOf",
    ],
    method_obj_mids: &["method"],
    io_consts: &["console", "Console", "fs", "process", "Deno", "Bun"],
    io_bare: &[
        "setTimeout",
        "setInterval",
        "fetch",
        "require",
        "import",
        "print",
        "println",
        "printf",
        "puts",
        "panic",
    ],
    context_pairs: JAVASCRIPT_CONTEXT_PAIRS,
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
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const JAVASCRIPT_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const JAVASCRIPT_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const JAVASCRIPT_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: JavaScript control-flow vocabulary.
const JAVASCRIPT_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[
        "every", "filter", "find", "flatMap", "forEach", "map", "reduce", "some",
    ],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct JavaScriptNormalizedBehavior;

impl NormalizedLanguageBehavior for JavaScriptNormalizedBehavior {
    fn stdlib_language(&self) -> Option<&'static str> {
        Some("javascript")
    }

    // CFG-SPECIFIC START: expose the JavaScript CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &JAVASCRIPT_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn self_member_receiver(&self, message: &str) -> String {
        format!("this.{message}")
    }

    fn function_visibility(&self, name: &str, _node: &Node, _lines: &[String]) -> String {
        if name.starts_with('#') {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        true
    }

    fn explicit_self_state_ref(&self, _node: &Node, message: &str) -> String {
        format!("this.{message}")
    }

    fn state_read_uses_access_span(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "console" || call.receiver == "this.sink" || call.receiver == "self"
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && call.message == "callback"
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        property_read_call(node, parts)
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            JAVASCRIPT_NIL_PREDICATES,
            JAVASCRIPT_NON_NIL_PREDICATES,
        )
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, JAVASCRIPT_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &JAVASCRIPT_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(keyword, "const" | "let" | "var")
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
                    | "function"
                    | "if"
                    | "in"
                    | "null"
                    | "return"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text.contains("undefined")
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null") || text.contains("??")
    }

    fn suppress_state_write(&self, receiver: &str, _field: &str, node: &Node) -> bool {
        receiver == "self" && node.text.contains(".bind(this)") && node.text.contains('=')
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("{elem}[]")
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("Record<{key}, {val}>")
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("Set<{elem}>")
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" || type_text == "None"
        {
            return type_text.to_string();
        }
        if type_text.contains(" | null") {
            type_text.to_string()
        } else {
            format!("{type_text} | null")
        }
    }

    fn untyped_type(&self) -> String {
        "any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "any[]".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "Record<any, any>".to_string()
    }
}

static BEHAVIOR: JavaScriptNormalizedBehavior = JavaScriptNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

pub(crate) fn property_read_call(node: &Node, parts: &NormalizedCallParts) -> bool {
    if node.r#type == "VCALL" || !parts.arguments.is_empty() {
        return false;
    }
    let text = node.text.as_str();
    !text.contains('(') || (text.starts_with('(') && text.ends_with(')'))
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
    fn test_javascript_behavior_comprehensive() {
        let b = JavaScriptNormalizedBehavior;
        assert_eq!(b.self_member_receiver("Foo"), "this.Foo");
        assert_eq!(
            b.function_visibility("#foo", &node("DEFN", ""), &[]),
            "private"
        );
        assert_eq!(
            b.function_visibility("foo", &node("DEFN", ""), &[]),
            "public"
        );
        assert!(b.wrap_branch_predicate(&node("IF", "")));
        assert_eq!(
            b.explicit_self_state_ref(&node("LVAR", ""), "Foo"),
            "this.Foo"
        );

        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "console".to_string(),
            message: "log".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

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

        assert!(b.property_read_call(
            &node("CALL", "x.y"),
            &NormalizedCallParts {
                receiver: "x".to_string(),
                message: "y".to_string(),
                arguments: Vec::new(),
            }
        ));

        assert!(b
            .owner_name_span("A", &node("CLASS", "class A {}"), [1, 2, 3, 4])
            .is_some());

        assert!(b.nil_guard_fact("isNull", "x").is_some());

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

        assert!(b.local_flow_declaration_keyword("let"));
        assert!(b.local_flow_keyword("let"));
        assert!(b.local_flow_keyword("if"));
        assert!(!b.local_flow_keyword("foo"));

        assert!(b.suppress_predicate_body_text("undefined"));
        assert!(!b.suppress_predicate_body_text("foo"));

        assert!(b.predicate_body_language_signal("null"));
        assert!(!b.predicate_body_language_signal("foo"));

        assert_eq!(b.format_array_type("number"), "number[]");
        assert_eq!(
            b.format_hash_type("string", "number"),
            "Record<string, number>"
        );
        assert_eq!(b.format_set_type("number"), "Set<number>");

        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("nil"), "nil");
        assert_eq!(b.format_nilable_type("number | null"), "number | null");
        assert_eq!(b.format_nilable_type("number"), "number | null");

        assert_eq!(b.untyped_type(), "any");
        assert_eq!(b.untyped_array_type(), "any[]");
        assert_eq!(b.untyped_hash_type(), "Record<any, any>");
    }
}
