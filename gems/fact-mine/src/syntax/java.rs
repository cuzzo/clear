use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::Child;
use crate::ast::{Node, Span};

const JAVA_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    (
        "System",
        &["currentTimeMillis", "nanoTime", "getenv", "getProperty"],
    ),
    ("Instant", &["now"]),
    ("UUID", &["randomUUID"]),
    ("Math", &["random"]),
];

const JAVA_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "invoke",
        "getMethod",
        "getDeclaredMethod",
        "getField",
        "getDeclaredField",
        "forName",
    ],
    meta_mids: &["invoke", "setAccessible", "newInstance", "Proxy"],
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
        "Lock",
        "AtomicReference",
    ],
    io_bare: &["print", "println", "printf", "puts", "panic", "throw"],
    context_pairs: JAVA_CONTEXT_PAIRS,
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
        "wait",
        "notify",
        "notifyAll",
        "submit",
        "execute",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const JAVA_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const JAVA_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const JAVA_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

pub(crate) struct JavaNormalizedBehavior;

impl NormalizedLanguageBehavior for JavaNormalizedBehavior {
    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("this.{message}")
    }

    fn project_call(
        &self,
        node: &Node,
        mut call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        if call.receiver == "self" && !call.arguments.is_empty() && node.text.contains("this.") {
            call.message = "this".to_string();
            return call;
        }
        if let Some(rest) = call.receiver.strip_prefix("System.").map(str::to_string) {
            if !call.arguments.is_empty() {
                call.receiver = "System".to_string();
                call.message = rest.split('.').next().map(str::to_string).unwrap_or(rest);
                return call;
            }
        }
        if let Some((base, message)) = java_receiver_method_message(&call.receiver) {
            call.receiver = base;
            call.message = message;
            return call;
        }
        if let Some(field) = call.receiver.strip_prefix("this.").map(str::to_string) {
            if call.arguments.is_empty() && node.text.contains('(') {
                call.receiver = "self".to_string();
                call.message = field.split('.').next().map(str::to_string).unwrap_or(field);
            }
        }
        call
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        let text = node.text.trim_start();
        if text.starts_with("private ") {
            "private".to_string()
        } else if text.starts_with("protected ") {
            "protected".to_string()
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
        !call.arguments.is_empty()
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.span != call.access_span || call.span[3] > call.access_span[3]
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn suppress_call_site(&self, node: &Node, call: &NormalizedCallProjection) -> bool {
        if node.text.contains("this.status.name()")
            && call.receiver == "self"
            && call.message == "status"
        {
            return false;
        }
        false
    }

    fn structural_semantic_effects(
        &self,
        _node: &Node,
        _function_name: &str,
    ) -> Vec<NormalizedSemanticEffect> {
        Vec::new()
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn case_pattern_display(&self, pattern: &str) -> String {
        if pattern.starts_with("case ") {
            pattern.to_string()
        } else {
            format!("case {pattern}")
        }
    }

    fn branch_state_ref(
        &self,
        node: &Node,
        parts: &NormalizedCallParts,
        default_ref: String,
    ) -> Option<String> {
        if node.text.contains('(') {
            return None;
        }
        if parts
            .receiver
            .chars()
            .next()
            .is_some_and(|ch| ch.is_ascii_uppercase())
        {
            return None;
        }
        Some(default_ref)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            JAVA_NIL_PREDICATES,
            JAVA_NON_NIL_PREDICATES,
        )
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "throw" | "exit")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, JAVA_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &JAVA_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "boolean"
                | "bool"
                | "char"
                | "double"
                | "float"
                | "int"
                | "long"
                | "short"
                | "String"
                | "string"
                | "var"
                | "void"
        )
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "break"
                    | "case"
                    | "class"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "if"
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

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
        in_method: bool,
    ) -> Option<StateDeclaration> {
        if in_method {
            return None;
        }
        let text = node
            .text
            .lines()
            .next()
            .unwrap_or("")
            .trim()
            .trim_end_matches(';')
            .trim();
        let left = text.split('=').next()?.trim();
        let parts = left.split_whitespace().collect::<Vec<_>>();
        if parts.len() >= 2 {
            let name = parts.last()?.trim();
            if is_simple_name(name) && !is_keyword(name) {
                let type_text = parts[..parts.len() - 1].join(" ");
                let mut type_parts = type_text.split_whitespace().collect::<Vec<_>>();
                while !type_parts.is_empty() && is_modifier(type_parts[0]) {
                    type_parts.remove(0);
                }
                let type_name = type_parts.join(" ");
                if !type_name.is_empty() {
                    return Some(StateDeclaration {
                        field: name.to_string(),
                        owner: String::new(),
                        r#type: Some(type_name),
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

static BEHAVIOR: JavaNormalizedBehavior = JavaNormalizedBehavior;

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

fn java_receiver_method_message(receiver: &str) -> Option<(String, String)> {
    if !receiver.ends_with("()") {
        return None;
    }
    let (base, method) = receiver.split_once('.')?;
    Some((base.to_string(), method.to_string()))
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

fn is_modifier(word: &str) -> bool {
    matches!(
        word,
        "public"
            | "private"
            | "protected"
            | "internal"
            | "static"
            | "final"
            | "transient"
            | "volatile"
            | "synchronized"
            | "abstract"
            | "const"
    )
}
