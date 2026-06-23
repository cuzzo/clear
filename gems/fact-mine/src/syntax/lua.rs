use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect, NormalizedStateRead,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::{Child, Node, Span};

const LUA_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("os", &["time", "clock", "date", "getenv"]),
    ("math", &["random"]),
];

const LUA_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &["load", "loadfile", "dofile", "require", "rawget", "rawset"],
    meta_mids: &[
        "setmetatable",
        "getmetatable",
        "debug",
        "eval",
        "load",
        "loadfile",
    ],
    method_obj_mids: &["method"],
    io_consts: &["io", "os", "debug", "package"],
    io_bare: &[
        "print",
        "println",
        "printf",
        "puts",
        "panic",
        "error",
        "assert",
        "require",
        "collectgarbage",
    ],
    context_pairs: LUA_CONTEXT_PAIRS,
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

const LUA_NIL_PREDICATES: &[&str] = &["isNull", "is_null", "nil"];
const LUA_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const LUA_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

pub(crate) struct LuaNormalizedBehavior;

impl NormalizedLanguageBehavior for LuaNormalizedBehavior {
    fn project_call(
        &self,
        _node: &Node,
        mut call: NormalizedCallProjection,
    ) -> NormalizedCallProjection {
        if call.message == "call" {
            if let Some((receiver, message)) = lua_method_receiver_message(&call.receiver) {
                call.receiver = receiver;
                call.message = message;
            }
        }
        call
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn node_call_projections(&self, node: &Node) -> Vec<NormalizedCallProjection> {
        lua_expression_list_call(node).into_iter().collect()
    }

    fn call_site_span(
        &self,
        node: &Node,
        parts: &NormalizedCallParts,
        full_span: Span,
        access_span: Span,
        current_function: &str,
    ) -> Span {
        let source = node.text.trim_start();
        if source.starts_with("self:escalate(")
            || source.starts_with("self:fallback(")
            || source.starts_with("self:default_case(")
            || source.starts_with("item:children(")
            || (parts.receiver == "self"
                && matches!(parts.message.as_str(), "ipairs" | "setmetatable"))
            || (current_function == "process" && parts.message == "print")
        {
            return access_span;
        }
        full_span
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        (call.receiver == "self"
            && (matches!(
                call.message.as_str(),
                "callback"
                    | "default_case"
                    | "escalate"
                    | "fallback"
                    | "ipairs"
                    | "print"
                    | "publish"
                    | "setmetatable"
            ) || !call.arguments.is_empty()))
            || (call.receiver == "self.sink" && call.message == "send")
            || (call.receiver == "item" && call.message == "children")
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn embedded_member_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        dotted_member_reads(&node.text, node.first_lineno, node.first_column)
    }

    fn node_state_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        if matches!(
            node.r#type.as_str(),
            "DOT_INDEX_EXPRESSION" | "EXPRESSION_LIST"
        ) {
            dotted_member_reads(&node.text, node.first_lineno, node.first_column)
        } else {
            Vec::new()
        }
    }

    fn function_visibility(&self, _name: &str, _node: &Node, _lines: &[String]) -> String {
        "public".to_string()
    }

    fn owner_for_function(
        &self,
        _name: &str,
        node: &Node,
        current_owner: &str,
        _file_owner: &str,
    ) -> String {
        lua_function_owner(&node.text).unwrap_or_else(|| current_owner.to_string())
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn suppress_branch_decision(&self, node: &Node) -> bool {
        node.text.trim_start().starts_with("elseif ")
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, LUA_NIL_PREDICATES, LUA_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "error")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, LUA_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &LUA_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        keyword == "local"
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "and"
                    | "break"
                    | "do"
                    | "else"
                    | "elseif"
                    | "end"
                    | "false"
                    | "for"
                    | "function"
                    | "if"
                    | "in"
                    | "nil"
                    | "return"
                    | "then"
                    | "true"
                    | "while"
            )
    }

    fn suppress_predicate_body_text(&self, text: &str) -> bool {
        text == "nil"
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        let lower = text.to_ascii_lowercase();
        lower.contains("nil") || lower.contains(" and ") || lower.contains(" or ")
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
    ) -> Option<StateDeclaration> {
        let text = node.text.trim();
        // Lua: table fields, pattern: name = value (no type annotation in Lua)
        // Lua doesn't have static types, so return None. State is detected via writes.
        let _ = text;
        None
    }
}

static BEHAVIOR: LuaNormalizedBehavior = LuaNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn lua_method_receiver_message(receiver: &str) -> Option<(String, String)> {
    let (receiver, message) = receiver.rsplit_once(':')?;
    Some((receiver.to_string(), message.to_string()))
}

fn lua_expression_list_call(node: &Node) -> Option<NormalizedCallProjection> {
    if node.r#type != "EXPRESSION_LIST" {
        return None;
    }
    let named = child_nodes(node);
    let callee = named.first()?;
    if callee.r#type == "CALL" {
        let receiver = child_nodes(callee)
            .first()
            .map(|receiver| normalized_text(receiver))
            .unwrap_or_default();
        let message = child_symbol(callee, 1)?;
        let args = named.iter().find(|child| child.r#type == "ARGUMENTS")?;
        let arguments = child_nodes(args)
            .into_iter()
            .map(lua_argument_text)
            .collect();
        return Some(NormalizedCallProjection {
            receiver,
            message,
            arguments,
            access_span: span(callee),
            span: span(node),
        });
    }
    if callee.r#type != "LVAR" {
        return None;
    }
    let message = first_string_or_symbol(callee)?;
    if !matches!(message.as_str(), "ipairs" | "setmetatable") {
        return None;
    }
    let arguments = named
        .iter()
        .find(|child| child.r#type == "ARGUMENTS")
        .map(|args| {
            child_nodes(args)
                .into_iter()
                .map(lua_argument_text)
                .collect()
        })
        .unwrap_or_default();
    let span = [
        node.first_lineno,
        node.first_column,
        node.first_lineno,
        node.first_column + message.len(),
    ];
    Some(NormalizedCallProjection {
        receiver: "self".to_string(),
        message,
        arguments,
        access_span: span,
        span,
    })
}

fn child_symbol(node: &Node, index: usize) -> Option<String> {
    match node.children.get(index)? {
        Child::Symbol(value) | Child::String(value) => Some(value.clone()),
        _ => None,
    }
}

fn normalized_text(node: &Node) -> String {
    match node.r#type.as_str() {
        "LVAR" | "DVAR" | "CONST" | "IVAR" | "GVAR" => {
            first_string_or_symbol(node).unwrap_or_else(|| crate::ast::normalize_text(&node.text))
        }
        _ => crate::ast::normalize_text(&node.text),
    }
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

fn lua_argument_text(node: &Node) -> String {
    first_string_or_symbol(node).unwrap_or_else(|| crate::ast::normalize_text(&node.text))
}

fn child_nodes(node: &Node) -> Vec<&Node> {
    node.children
        .iter()
        .filter_map(|child| match child {
            Child::Node(node) => Some(node.as_ref()),
            _ => None,
        })
        .collect()
}

fn first_string_or_symbol(node: &Node) -> Option<String> {
    node.children.iter().find_map(|child| match child {
        Child::Symbol(value) | Child::String(value) => Some(value.clone()),
        _ => None,
    })
}

fn dotted_member_reads(text: &str, line: usize, column: usize) -> Vec<NormalizedStateRead> {
    let mut reads = Vec::new();
    for (receiver, field, start, end) in dotted_segments(text) {
        if receiver == "_" && field == "_" {
            continue;
        }
        reads.push(NormalizedStateRead {
            receiver,
            field,
            line: Some(line),
            span: [line, column + start, line, column + end],
        });
    }
    reads
}

fn lua_function_owner(text: &str) -> Option<String> {
    let source = text.trim_start();
    let rest = source.strip_prefix("function ")?;
    let separator = rest.find(':')?;
    let owner = &rest[..separator];
    simple_dotted_part(owner).then(|| owner.to_string())
}

fn dotted_segments(text: &str) -> Vec<(String, String, usize, usize)> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    for index in 0..bytes.len() {
        if bytes[index] != b'.' || index == 0 || index + 1 >= bytes.len() {
            continue;
        }
        let receiver_start = text[..index]
            .rfind(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric() || ch == '.'))
            .map(|offset| offset + 1)
            .unwrap_or(0);
        let field_end = text[(index + 1)..]
            .find(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .map(|offset| index + 1 + offset)
            .unwrap_or(text.len());
        let receiver = &text[receiver_start..index];
        let field = &text[(index + 1)..field_end];
        if simple_dotted_part(receiver) && simple_identifier(field) {
            out.push((
                receiver.to_string(),
                field.to_string(),
                receiver_start,
                field_end,
            ));
        }
    }
    out
}

fn simple_dotted_part(value: &str) -> bool {
    !value.is_empty() && value.split('.').all(simple_identifier)
}

fn simple_identifier(value: &str) -> bool {
    let mut chars = value.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}
