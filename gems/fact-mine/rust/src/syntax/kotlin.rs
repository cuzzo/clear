use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::{Node, Span};
use crate::ast::Child;
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect,
};

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

struct KotlinNormalizedBehavior;

impl NormalizedLanguageBehavior for KotlinNormalizedBehavior {
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
    ) -> Option<StateDeclaration> {
        let text = node.text.trim();
        // Kotlin: `val name: Type` or `var name: Type`
        let text = text.strip_prefix("val ").or_else(|| text.strip_prefix("var ")).unwrap_or(text);
        if let Some((name, rest)) = text.split_once(':') {
            let name = name.trim();
            if !name.is_empty() && !name.contains(' ') && !name.contains('.')
                && name.chars().next().map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
            {
                let type_text = rest.split('=').next().unwrap_or(rest).trim().to_string();
                if !type_text.is_empty() {
                    return Some(StateDeclaration {
                        field: name.to_string(),
                        owner: String::new(),
                        r#type: Some(type_text),
                        file: String::new(),
                        line: node.first_lineno,
                        span: span(node),
                    });
                }
            }
        }
        None
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
        && name.chars().next().map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
        && name.chars().all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}
