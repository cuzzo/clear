use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedOwner,
    NormalizedSemanticEffect, NormalizedStateRead, NormalizedStateWrite,
};
use super::CallSite;
use crate::ast::{Node, Span};

const GO_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("time", &["Now", "Since", "Until"]),
    ("rand", &["Int", "Intn", "Float64", "Read"]),
];

const GO_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "Call",
        "CallSlice",
        "Method",
        "MethodByName",
        "ValueOf",
        "TypeOf",
    ],
    meta_mids: &["Call", "CallSlice", "MethodByName", "New", "MakeFunc"],
    method_obj_mids: &["method"],
    io_consts: &["os", "io", "ioutil", "fs", "net", "http", "exec", "syscall"],
    io_bare: &["panic", "print", "println"],
    context_pairs: GO_CONTEXT_PAIRS,
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
        "Unlock",
        "RLock",
        "RUnlock",
        "Do",
        "Go",
        "Add",
        "Done",
        "Wait",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const GO_NIL_PREDICATES: &[&str] = &["isNull", "is_null", "nil"];
const GO_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const GO_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

pub(crate) struct GoNormalizedBehavior;

impl NormalizedLanguageBehavior for GoNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        if node.r#type != "TYPE_DECLARATION" {
            return None;
        }
        type_name(&node.text).map(|name| NormalizedOwner {
            name,
            kind: "owner".to_string(),
        })
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
    ) -> Option<super::StateDeclaration> {
        if node.r#type != "FIELD_DECLARATION" {
            return None;
        }
        let name = first_lvar_child_name(node)?;
        let ty = node
            .text
            .trim_start()
            .strip_prefix(&name)
            .unwrap_or("")
            .trim()
            .to_string();
        (!ty.is_empty()).then(|| super::StateDeclaration {
            field: name,
            owner: String::new(),
            r#type: Some(ty),
            file: String::new(),
            line: node.first_lineno,
            span: span(node),
        })
    }

    fn embedded_member_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        if node.first_lineno != node.last_lineno {
            return Vec::new();
        }
        dotted_uppercase_reads(&node.text, node.first_lineno, node.first_column)
    }

    fn node_state_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        indexed_lookup_read(node).into_iter().collect()
    }

    fn owner_for_function(
        &self,
        _name: &str,
        node: &Node,
        current_owner: &str,
        file_owner: &str,
    ) -> String {
        if current_owner != file_owner {
            return current_owner.to_string();
        }
        node.text
            .trim_start()
            .strip_prefix("func")
            .and_then(receiver_owner_from_go_function)
            .unwrap_or_else(|| current_owner.to_string())
    }

    fn receiver_aliases_for_function(
        &self,
        node: &Node,
    ) -> std::collections::BTreeMap<String, String> {
        let mut aliases = std::collections::BTreeMap::new();
        if let Some(receiver) = node
            .text
            .trim_start()
            .strip_prefix("func")
            .and_then(receiver_name_from_go_function)
        {
            aliases.insert(receiver, "self".to_string());
        }
        aliases
    }

    fn function_visibility(&self, name: &str, _node: &Node, _lines: &[String]) -> String {
        if name
            .chars()
            .next()
            .is_some_and(|ch| ch.is_ascii_lowercase() || ch == '_')
        {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn function_name_from_text(&self, text: &str) -> Option<String> {
        let source = text.trim_start();
        let source = source.strip_prefix("func")?.trim_start();
        let source = if source.starts_with('(') {
            let close = matching_paren_index(source, 0)?;
            source[(close + 1)..].trim_start()
        } else {
            source
        };
        source
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .find(|part| !part.is_empty())
            .map(str::to_string)
    }

    fn parameter_list_source(&self, source: &str) -> String {
        let Some(mut open_index) = source.find('(') else {
            return String::new();
        };
        if source.trim_start().starts_with("func (") {
            let Some(receiver_close) = matching_paren_index(source, open_index) else {
                return String::new();
            };
            let Some(next_open) = source[(receiver_close + 1)..].find('(') else {
                return String::new();
            };
            open_index = receiver_close + 1 + next_open;
        }
        let Some(close_index) = matching_paren_index(source, open_index) else {
            return String::new();
        };
        source[(open_index + 1)..close_index].to_string()
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        param
            .split_whitespace()
            .next()
            .filter(|name| simple_identifier(name))
            .map(|name| name.trim_end_matches('?').to_string())
    }

    fn split_case_source(&self, source: &str) -> Vec<String> {
        vec![source.to_string()]
    }

    fn local_assignment_writes(
        &self,
        field: Option<&str>,
        _node: &Node,
        default_span: Span,
    ) -> Vec<NormalizedStateWrite> {
        let Some(field) = field.and_then(indexed_lookup_field) else {
            return Vec::new();
        };
        vec![NormalizedStateWrite {
            receiver: "self".to_string(),
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
        call.receiver == "self" && matches!(call.message.as_str(), "callback" | "println")
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn explicit_self_state_ref(&self, node: &Node, message: &str) -> String {
        node.text
            .trim()
            .split_once('.')
            .map(|(receiver, _)| format!("{receiver}.{message}"))
            .unwrap_or_else(|| message.to_string())
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, GO_NIL_PREDICATES, GO_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "panic" | "Fatal" | "Fatalf")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, GO_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &GO_EFFECT_LEXICON))
    }

    fn local_flow_assignment_operator(&self, operator: &str) -> bool {
        matches!(operator, "=" | ":=")
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "bool"
                | "byte"
                | "float32"
                | "float64"
                | "int"
                | "int32"
                | "int64"
                | "rune"
                | "string"
                | "uint"
                | "uint32"
                | "uint64"
                | "var"
        )
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "break"
                    | "case"
                    | "continue"
                    | "default"
                    | "defer"
                    | "else"
                    | "false"
                    | "for"
                    | "func"
                    | "if"
                    | "in"
                    | "nil"
                    | "return"
                    | "struct"
                    | "true"
            )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text == "nil"
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("nil")
    }
}

static BEHAVIOR: GoNormalizedBehavior = GoNormalizedBehavior;

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

fn first_lvar_child_name(node: &Node) -> Option<String> {
    node.children.iter().find_map(|child| match child {
        crate::ast::Child::Node(child) if child.r#type == "LVAR" => {
            child.children.first().and_then(|item| match item {
                crate::ast::Child::String(value) | crate::ast::Child::Symbol(value) => {
                    Some(value.clone())
                }
                _ => None,
            })
        }
        _ => None,
    })
}

fn type_name(text: &str) -> Option<String> {
    text.trim_start()
        .strip_prefix("type ")?
        .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
        .find(|part| !part.is_empty())
        .map(str::to_string)
}

fn receiver_owner_from_go_function(source: &str) -> Option<String> {
    let source = source.trim_start();
    let receiver = source.strip_prefix('(')?.split_once(')')?.0;
    receiver
        .split_whitespace()
        .next_back()
        .map(|value| value.trim_start_matches('*').to_string())
        .filter(|value| !value.is_empty())
}

fn receiver_name_from_go_function(source: &str) -> Option<String> {
    let source = source.trim_start();
    let receiver = source.strip_prefix('(')?.split_once(')')?.0;
    receiver
        .split_whitespace()
        .next()
        .filter(|value| simple_identifier(value))
        .map(str::to_string)
}

fn dotted_uppercase_reads(text: &str, line: usize, column: usize) -> Vec<NormalizedStateRead> {
    let bytes = text.as_bytes();
    let mut reads = Vec::new();
    for index in 0..bytes.len() {
        if bytes[index] != b'.' || index == 0 || index + 1 >= bytes.len() {
            continue;
        }
        let receiver_start = text[..index]
            .rfind(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .map(|offset| offset + 1)
            .unwrap_or(0);
        let receiver = &text[receiver_start..index];
        let field_end = text[(index + 1)..]
            .find(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .map(|offset| index + 1 + offset)
            .unwrap_or(text.len());
        let field = &text[(index + 1)..field_end];
        if receiver
            .chars()
            .next()
            .is_some_and(|ch| ch.is_ascii_lowercase())
            && field
                .chars()
                .next()
                .is_some_and(|ch| ch.is_ascii_uppercase())
        {
            reads.push(NormalizedStateRead {
                receiver: receiver.to_string(),
                field: field.to_string(),
                line: Some(line),
                span: [line, column + receiver_start, line, column + field_end],
            });
        }
    }
    reads
}

fn indexed_lookup_read(node: &Node) -> Option<NormalizedStateRead> {
    if node.r#type != "LASGN" || !node.text.contains('=') {
        return None;
    }
    let lhs = node.text.split_once('=')?.0.trim_end();
    let field = indexed_lookup_field(lhs)?;
    let start = node.text.find(lhs)?;
    let end = start + lhs.find('[').unwrap_or(lhs.len());
    Some(NormalizedStateRead {
        receiver: "self".to_string(),
        field,
        line: Some(node.first_lineno),
        span: [
            node.first_lineno,
            node.first_column + start,
            node.first_lineno,
            node.first_column + end,
        ],
    })
}

fn indexed_lookup_field(lhs: &str) -> Option<String> {
    let before_bracket = lhs.split_once('[')?.0;
    let field = before_bracket.rsplit_once('.')?.1;
    (field == "lookup").then(|| field.to_string())
}

fn matching_paren_index(source: &str, open_index: usize) -> Option<usize> {
    let mut depth = 0usize;
    for (index, ch) in source
        .char_indices()
        .filter(|(index, _)| *index >= open_index)
    {
        if ch == '(' {
            depth += 1;
        } else if ch == ')' {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return Some(index);
            }
        }
    }
    None
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}
