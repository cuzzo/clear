use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedOwner,
    NormalizedSemanticEffect,
};
use super::CallSite;
use crate::ast::{Node, Span};

const RUST_CONTEXT_PAIRS: &[(&str, &[&str])] = &[("SystemTime", &["now"]), ("Instant", &["now"])];

const RUST_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "downcast",
        "downcast_ref",
        "downcast_mut",
        "call",
        "call_mut",
        "call_once",
    ],
    meta_mids: &["transmute", "from_raw_parts", "from_raw_parts_mut"],
    method_obj_mids: &["method"],
    io_consts: &["std", "tokio", "fs", "env", "process", "net", "io"],
    io_bare: &[
        "panic",
        "todo",
        "unimplemented",
        "unreachable",
        "print",
        "println",
        "eprintln",
        "printf",
        "puts",
    ],
    context_pairs: RUST_CONTEXT_PAIRS,
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
        "read",
        "write",
        "spawn",
        "await",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const RUST_NIL_PREDICATES: &[&str] = &["isNull", "is_null", "is_none"];
const RUST_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const RUST_GUARD_MIDS: &[&str] = &["isNull", "is_null", "is_none", "is_some"];

pub(crate) struct RustNormalizedBehavior;

impl NormalizedLanguageBehavior for RustNormalizedBehavior {
    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn project_call(
        &self,
        _node: &Node,
        mut call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        if call.message == "call" {
            let receiver_text = call.receiver.clone();
            if let Some((receiver, message)) = receiver_text.rsplit_once("::") {
                call.receiver = receiver.to_string();
                call.message = message.to_string();
            }
        }
        call
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
        call.receiver == "self" && call.message == "callback"
    }

    fn owner_kind(&self, node: &Node, default_kind: &str) -> String {
        if node.text.trim_start().starts_with("impl ") {
            "impl".to_string()
        } else {
            default_kind.to_string()
        }
    }

    fn owner_name_from_text(&self, node: &Node) -> Option<String> {
        owner_after_keyword(&node.text, "impl")
            .or_else(|| owner_after_keyword(&node.text, "struct"))
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        (node.r#type == "STRUCT_ITEM")
            .then(|| owner_after_keyword(&node.text, "struct"))
            .flatten()
            .map(|name| NormalizedOwner {
                name,
                kind: "struct".to_string(),
            })
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        if node.r#type == "STRUCT_ITEM" {
            Some(default_span)
        } else {
            keyword_block_span(node, "struct").or(Some(default_span))
        }
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        if node.text.trim_start().starts_with("pub ") {
            "public".to_string()
        } else {
            "private".to_string()
        }
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.trim();
        if text == "&self" || text == "&mut self" {
            return Some(text.to_string());
        }
        let before_colon = text.split_once(':')?.0.trim();
        let name = before_colon.strip_prefix("mut ").unwrap_or(before_colon);
        simple_identifier(name).then(|| name.to_string())
    }

    fn function_name_from_text(&self, text: &str) -> Option<String> {
        function_name_after_fn(text)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            RUST_NIL_PREDICATES,
            RUST_NON_NIL_PREDICATES,
        )
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "panic" | "todo" | "unimplemented" | "unreachable")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, RUST_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &RUST_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        keyword == "let"
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "as" | "break"
                    | "const"
                    | "continue"
                    | "else"
                    | "false"
                    | "fn"
                    | "for"
                    | "if"
                    | "in"
                    | "match"
                    | "mut"
                    | "pub"
                    | "return"
                    | "self"
                    | "static"
                    | "struct"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("none")
    }
}

static BEHAVIOR: RustNormalizedBehavior = RustNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

pub(crate) fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

pub(crate) fn function_name_after_fn(text: &str) -> Option<String> {
    let source = text.trim_start();
    let source = source.strip_prefix("pub ").unwrap_or(source).trim_start();
    let rest = source.strip_prefix("fn ")?;
    rest.split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .find(|part| !part.is_empty())
        .map(str::to_string)
}

fn owner_after_keyword(text: &str, keyword: &str) -> Option<String> {
    let rest = text.split_once(keyword)?.1.trim_start();
    rest.split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .find(|part| !part.is_empty())
        .map(str::to_string)
}

fn keyword_block_span(node: &Node, keyword: &str) -> Option<Span> {
    let lines = node.text.lines().collect::<Vec<_>>();
    let start_offset = lines.iter().position(|line| line.contains(keyword))?;
    let end_offset = lines
        .iter()
        .rposition(|line| line.contains('}'))
        .unwrap_or(lines.len() - 1);
    let start_line = node.first_lineno + start_offset;
    let end_line = node.first_lineno + end_offset;
    let start_column = if start_offset == 0 {
        node.first_column
    } else {
        0
    } + lines[start_offset].find(keyword).unwrap_or(0);
    let end_column = if end_offset == 0 {
        node.first_column
    } else {
        0
    } + lines[end_offset]
        .find('}')
        .unwrap_or(lines[end_offset].len())
        + 1;
    Some([start_line, start_column, end_line, end_column])
}
