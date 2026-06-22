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

pub(crate) struct JavaScriptNormalizedBehavior;

impl NormalizedLanguageBehavior for JavaScriptNormalizedBehavior {
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
