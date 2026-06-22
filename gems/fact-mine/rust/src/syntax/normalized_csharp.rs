use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect,
};
use super::CallSite;
use crate::ast::{Node, Span};

const CSHARP_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("DateTime", &["Now", "UtcNow", "Today"]),
    ("Guid", &["NewGuid"]),
    ("Random", &["Next", "NextDouble"]),
];

const CSHARP_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "Invoke",
        "GetMethod",
        "GetProperty",
        "GetField",
        "Activator",
        "CreateInstance",
    ],
    meta_mids: &["Invoke", "GetType", "Reflection", "Emit", "DynamicMethod"],
    method_obj_mids: &["method"],
    io_consts: &[
        "Console",
        "File",
        "Directory",
        "Path",
        "Process",
        "Socket",
        "HttpClient",
        "Environment",
    ],
    io_bare: &["print", "println", "printf", "puts", "panic", "throw"],
    context_pairs: CSHARP_CONTEXT_PAIRS,
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
        "Lock",
        "Monitor",
        "Enter",
        "Exit",
        "Wait",
        "Pulse",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const CSHARP_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const CSHARP_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const CSHARP_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

pub(crate) struct CSharpNormalizedBehavior;

impl NormalizedLanguageBehavior for CSharpNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        message.to_string()
    }

    fn explicit_self_state_ref(&self, _node: &Node, message: &str) -> String {
        format!("this.{message}")
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let text = node.text.trim_start();
        if text.starts_with("public ") {
            "public".to_string()
        } else if text.starts_with("protected ") {
            "protected".to_string()
        } else {
            "private".to_string()
        }
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
        call.receiver == "self" && !call.arguments.is_empty()
    }

    fn implicit_owner_fields(&self) -> bool {
        true
    }

    fn field_name_from_declaration(&self, node: &Node) -> Option<String> {
        if node.r#type != "FIELD_DECLARATION" {
            return None;
        }
        node.text
            .trim_end_matches(';')
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .filter(|part| !part.is_empty())
            .next_back()
            .map(str::to_string)
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            CSHARP_NIL_PREDICATES,
            CSHARP_NON_NIL_PREDICATES,
        )
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "throw" | "Exit")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, CSHARP_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &CSHARP_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "bool"
                | "boolean"
                | "char"
                | "double"
                | "float"
                | "int"
                | "long"
                | "short"
                | "string"
                | "String"
                | "var"
                | "void"
        )
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "case"
                    | "class"
                    | "const"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "if"
                    | "in"
                    | "private"
                    | "protected"
                    | "public"
                    | "return"
                    | "static"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
    }
}

static BEHAVIOR: CSharpNormalizedBehavior = CSharpNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}
