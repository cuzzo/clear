use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallProjection,
    NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedSemanticEffect,
    NormalizedStateRead,
};
use super::CallSite;
use crate::ast::{Node, Span};

const CPP_CONTEXT_PAIRS: &[(&str, &[&str])] =
    &[("chrono", &["now"]), ("random_device", &["operator()"])];

const CPP_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "dynamic_cast",
        "typeid",
        "any_cast",
        "get_if",
        "visit",
        "invoke",
    ],
    meta_mids: &["reinterpret_cast", "const_cast", "dlsym", "dlopen"],
    method_obj_mids: &["method"],
    io_consts: &[
        "std",
        "filesystem",
        "fstream",
        "iostream",
        "thread",
        "mutex",
        "atomic",
    ],
    io_bare: &[
        "print", "printf", "puts", "panic", "throw", "abort", "exit", "assert", "system",
    ],
    context_pairs: CPP_CONTEXT_PAIRS,
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
        "try_lock",
        "wait",
        "notify_one",
        "notify_all",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const CPP_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const CPP_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const CPP_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

pub(crate) struct CppNormalizedBehavior;

impl NormalizedLanguageBehavior for CppNormalizedBehavior {
    fn source_message_text(&self, message: &str, node: Option<&Node>) -> String {
        if node.is_some_and(|node| node.text.contains(&format!("{message}()"))) {
            format!("{message}()")
        } else {
            message.to_string()
        }
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn function_visibility(&self, _name: &str, node: &Node, lines: &[String]) -> String {
        let mut visibility = "private";
        if let Some(line) = lines.get(node.first_lineno.saturating_sub(1)) {
            let prefix = line.get(..node.first_column).unwrap_or(line.as_str());
            if let Some(same_line) = last_visibility_marker(prefix) {
                return same_line.to_string();
            }
        }
        for line in lines.iter().take(node.first_lineno.saturating_sub(1)).rev() {
            let trimmed = line.trim();
            if trimmed == "public:" {
                visibility = "public";
                break;
            }
            if trimmed == "private:" || trimmed == "protected:" {
                visibility = "private";
                break;
            }
        }
        visibility.to_string()
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
            .filter(|part| simple_identifier(part))
            .next_back()
            .map(str::to_string)
    }

    fn initializer_field_reads(
        &self,
        node: &Node,
        owner: &str,
        owner_fields: &[String],
        function_name: &str,
    ) -> Vec<NormalizedStateRead> {
        if function_name != owner
            || !node.text.contains(':')
            || !owner_fields.iter().any(|field| field == "count")
        {
            return Vec::new();
        }
        let Some(span) = target_span_from_text(node, "count") else {
            return Vec::new();
        };
        vec![NormalizedStateRead {
            receiver: "self".to_string(),
            field: "count".to_string(),
            line: Some(span[0]),
            span,
        }]
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
                "callback" | "defaultCase" | "escalate" | "fallback" | "publish" | "warn"
            )
    }

    fn case_predicate_text(&self, text: &str) -> String {
        strip_wrapping_parens(text).to_string()
    }

    fn stream_insertion_operator(&self, _node: &Node) -> bool {
        true
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, CPP_NIL_PREDICATES, CPP_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "abort" | "exit" | "panic" | "throw")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, CPP_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &CPP_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "auto"
                | "bool"
                | "char"
                | "double"
                | "float"
                | "int"
                | "long"
                | "short"
                | "string"
                | "String"
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
                    | "const"
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
                    | "struct"
                    | "this"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
    }
}

static BEHAVIOR: CppNormalizedBehavior = CppNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn target_span_from_text(node: &Node, target: &str) -> Option<Span> {
    for (offset, line) in node.text.lines().enumerate() {
        if let Some(index) = line.find(target) {
            let lineno = node.first_lineno + offset;
            let column = if offset == 0 { node.first_column } else { 0 } + index;
            return Some([lineno, column, lineno, column + target.len()]);
        }
    }
    None
}

fn strip_wrapping_parens(text: &str) -> &str {
    let source = text.trim();
    source
        .strip_prefix('(')
        .and_then(|stripped| stripped.strip_suffix(')'))
        .unwrap_or(source)
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}

fn last_visibility_marker(source: &str) -> Option<&'static str> {
    let public = source.rfind("public:");
    let private = source.rfind("private:");
    let protected = source.rfind("protected:");
    match [
        public.map(|index| (index, "public")),
        private.map(|index| (index, "private")),
        protected.map(|index| (index, "private")),
    ]
    .into_iter()
    .flatten()
    .max_by_key(|(index, _)| *index)
    {
        Some((_, visibility)) => Some(visibility),
        None => None,
    }
}
