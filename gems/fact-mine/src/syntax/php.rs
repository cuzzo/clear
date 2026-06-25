use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect, NormalizedStateRead,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::Child;
use crate::ast::{Node, Span};

const PHP_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("DateTime", &["createFromFormat"]),
    ("DateTimeImmutable", &["createFromFormat"]),
    ("random_int", &["call"]),
];

const PHP_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "call_user_func",
        "call_user_func_array",
        "__call",
        "__callStatic",
    ],
    meta_mids: &[
        "eval",
        "ReflectionClass",
        "ReflectionMethod",
        "ReflectionFunction",
        "class_alias",
    ],
    method_obj_mids: &["Closure", "fromCallable"],
    io_consts: &["FilesystemIterator", "DirectoryIterator", "PDO", "mysqli"],
    io_bare: &[
        "print",
        "println",
        "printf",
        "puts",
        "panic",
        "fopen",
        "file_get_contents",
        "file_put_contents",
        "exec",
        "shell_exec",
        "system",
        "passthru",
        "die",
        "exit",
        "trigger_error",
    ],
    context_pairs: PHP_CONTEXT_PAIRS,
    context_bare: &["time", "microtime", "random_int", "rand", "mt_rand"],
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

const PHP_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const PHP_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const PHP_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

pub(crate) struct PhpNormalizedBehavior;

impl NormalizedLanguageBehavior for PhpNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        format!("this.{message}")
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

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && matches!(call.message.as_str(), "callback" | "print")
    }

    fn node_state_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        if !matches!(
            node.r#type.as_str(),
            "MEMBER_ACCESS_EXPRESSION" | "NULLSAFE_MEMBER_ACCESS_EXPRESSION"
        ) {
            return Vec::new();
        }
        member_reads(&node.text, node.first_lineno, node.first_column)
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        true
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, PHP_NIL_PREDICATES, PHP_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "die" | "exit")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, PHP_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &PHP_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "bool" | "boolean" | "float" | "int" | "string" | "String" | "var" | "void"
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
                    | "function"
                    | "if"
                    | "in"
                    | "null"
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
        text.to_ascii_lowercase().contains("null") || text.contains("??")
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
        // Try structured children first: [name, type?, value?]
        let child_nodes: Vec<&Node> = node
            .children
            .iter()
            .filter_map(|c| match c {
                Child::Node(n) => Some(n.as_ref()),
                _ => None,
            })
            .collect();
        if child_nodes.len() >= 2 {
            let name = child_nodes[0].text.trim();
            if is_simple_name(name) {
                let type_text = child_nodes[1].text.trim().to_string();
                if !type_text.is_empty() && type_text != ":" && !type_text.starts_with('=') {
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
        let text = node.text.trim();
        // PHP: `public Type $name`, `private Type $name`, `Type $name`
        let text = text
            .strip_prefix("public ")
            .or_else(|| text.strip_prefix("private "))
            .or_else(|| text.strip_prefix("protected "))
            .unwrap_or(text);
        // After visibility modifier, pattern is `Type $name` or `Type $name = value`
        if let Some((name, _)) = text.split_once('=') {
            let parts: Vec<&str> = text.split_whitespace().collect();
            if parts.len() >= 2 {
                let name = name
                    .trim()
                    .split_whitespace()
                    .last()
                    .unwrap_or("")
                    .trim_start_matches('$');
                if !name.is_empty()
                    && name
                        .chars()
                        .next()
                        .map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
                {
                    let type_text = parts[..parts.len() - 1].join(" ");
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
        }
        let parts: Vec<&str> = text.split_whitespace().collect();
        if parts.len() >= 2 {
            let name = parts
                .last()
                .unwrap()
                .trim_start_matches('$')
                .trim_end_matches(';');
            if !name.is_empty()
                && name
                    .chars()
                    .next()
                    .map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
            {
                let type_text = parts[..parts.len() - 1].join(" ");
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

    fn format_array_type(&self, elem: &str) -> String {
        format!("array<{}>", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("array<{}, {}>", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("array<{}, bool>", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" {
            type_text.to_string()
        } else if type_text.starts_with('?') {
            type_text.to_string()
        } else {
            format!("?{}", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "mixed".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "array".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "array".to_string()
    }
}

static BEHAVIOR: PhpNormalizedBehavior = PhpNormalizedBehavior;

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

fn member_reads(text: &str, line: usize, column: usize) -> Vec<NormalizedStateRead> {
    let mut reads = Vec::new();
    for (receiver, field, start, end) in member_segments(text) {
        let receiver = if receiver == "this" {
            "self".to_string()
        } else {
            receiver
        };
        reads.push(NormalizedStateRead {
            receiver,
            field,
            line: Some(line),
            span: [
                line,
                column + start,
                line,
                column + php_source_column(end, text),
            ],
        });
    }
    reads
}

fn member_segments(text: &str) -> Vec<(String, String, usize, usize)> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    let mut index = 0usize;
    while index < bytes.len() {
        let separator_len = if bytes[index] == b'.' {
            1
        } else if index + 1 < bytes.len() && bytes[index] == b'?' && bytes[index + 1] == b'.' {
            2
        } else {
            index += 1;
            continue;
        };
        if index == 0 || index + separator_len >= bytes.len() {
            index += separator_len;
            continue;
        }
        let receiver_start = text[..index]
            .rfind(|ch: char| !(ch == '_' || ch == '?' || ch == '.' || ch.is_ascii_alphanumeric()))
            .map(|offset| offset + 1)
            .unwrap_or(0);
        let field_start = index + separator_len;
        let field_end = text[field_start..]
            .find(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .map(|offset| field_start + offset)
            .unwrap_or(text.len());
        let receiver = &text[receiver_start..index];
        let field = &text[field_start..field_end];
        if simple_member_receiver(receiver) && simple_identifier(field) {
            out.push((
                receiver.to_string(),
                field.to_string(),
                receiver_start,
                field_end,
            ));
        }
        index += separator_len;
    }
    out
}

fn php_source_column(normalized_index: usize, text: &str) -> usize {
    let mut offset = 1usize;
    for (index, ch) in text.char_indices() {
        if index >= normalized_index {
            break;
        }
        if ch == '.' {
            offset += 1;
        }
    }
    normalized_index + offset
}

fn simple_member_receiver(value: &str) -> bool {
    let normalized = value.replace("?.", ".");
    !normalized.is_empty() && normalized.split('.').all(simple_identifier)
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
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
