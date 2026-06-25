use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect, NormalizedStateWrite,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::Child;
use crate::ast::{Node, Span};

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

struct SwiftNormalizedBehavior;

impl NormalizedLanguageBehavior for SwiftNormalizedBehavior {
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
        before_colon
            .split_whitespace()
            .filter(|part| *part != "_")
            .next_back()
            .filter(|name| simple_identifier(name))
            .map(ToString::to_string)
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
