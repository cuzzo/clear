// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect, NormalizedStateRead, NormalizedStateWrite,
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

// CFG-SPECIFIC START: Lua control-flow vocabulary.
const LUA_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct LuaNormalizedBehavior;

impl NormalizedLanguageBehavior for LuaNormalizedBehavior {
    fn stdlib_language(&self) -> Option<&'static str> {
        Some("lua")
    }

    // CFG-SPECIFIC START: expose the Lua CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &LUA_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

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

    fn local_assignment_writes(
        &self,
        field: Option<&str>,
        _node: &Node,
        default_span: Span,
    ) -> Vec<NormalizedStateWrite> {
        let Some(field) = field else {
            return Vec::new();
        };
        let field_truncated = if let Some(pos) = field.find('[') {
            field[..pos].trim()
        } else {
            field
        };
        if let Some(pos) = field_truncated.rfind(|c| c == '.' || c == ':') {
            let receiver = &field_truncated[..pos];
            let actual_field = &field_truncated[pos + 1..];
            if simple_dotted_part(receiver) && simple_identifier(actual_field) {
                return vec![NormalizedStateWrite {
                    receiver: receiver.to_string(),
                    field: actual_field.to_string(),
                    span: default_span,
                }];
            }
        }
        Vec::new()
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
        _in_method: bool,
    ) -> Option<StateDeclaration> {
        let text = node.text.trim();
        // Lua: table fields, pattern: name = value (no type annotation in Lua)
        // Lua doesn't have static types, so return None. State is detected via writes.
        let _ = text;
        None
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("{}[]", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("table<{}, {}>", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("table<{}, boolean>", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" {
            type_text.to_string()
        } else if type_text.ends_with("|nil") || type_text.starts_with("nil|") {
            type_text.to_string()
        } else {
            format!("{}|nil", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "any[]".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "table".to_string()
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
    let name_part = match rest.find('(') {
        Some(pos) => rest[..pos].trim(),
        None => rest.trim(),
    };
    let separator = name_part.rfind(|c| c == ':' || c == '.')?;
    let owner = &name_part[..separator];
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
            .char_indices()
            .rfind(|(_, ch)| !(*ch == '_' || ch.is_ascii_alphanumeric() || *ch == '.'))
            .map(|(offset, ch)| offset + ch.len_utf8())
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

#[cfg(test)]
mod tests {
    use super::*;

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: text.to_string(),
        }
    }

    #[test]
    fn test_lua_behavior_comprehensive() {
        let b = LuaNormalizedBehavior;

        // 1. self_member_receiver
        assert_eq!(b.self_member_receiver("foo"), "self.foo");

        // 2. project_call
        let call_p = NormalizedCallProjection {
            receiver: "self:method".to_string(),
            message: "call".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        };
        let res_p = b.project_call(&node("CALL", ""), call_p);
        assert_eq!(res_p.receiver, "self");
        assert_eq!(res_p.message, "method");

        // 3. state_read_uses_access_span
        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 4. node_call_projections & lua_expression_list_call
        // Case 1: LVAR with ipairs
        let mut lvar_node = node("LVAR", "ipairs");
        lvar_node.children = vec![Child::Symbol("ipairs".to_string())];
        let mut arg_node = node("ARGUMENTS", "(t)");
        arg_node.children = vec![Child::Node(Box::new(node("LVAR", "t")))];
        let mut exp_node = node("EXPRESSION_LIST", "ipairs(t)");
        exp_node.children = vec![
            Child::Node(Box::new(lvar_node)),
            Child::Node(Box::new(arg_node)),
        ];
        let calls = b.node_call_projections(&exp_node);
        assert_eq!(calls.len(), 1);
        assert_eq!(calls[0].message, "ipairs");

        // Case 2: CALL node (non LVAR) inside EXPRESSION_LIST
        let mut call_node = node("CALL", "self:method");
        call_node.children = vec![
            Child::Node(Box::new(node("IDENT", "self"))),
            Child::Symbol("method".to_string()),
        ];
        let mut exp_node_call = node("EXPRESSION_LIST", "self:method(1)");
        let mut args_node_call = node("ARGUMENTS", "(1)");
        let mut int_node = node("INT", "1");
        int_node.children = vec![Child::Symbol("1".to_string())];
        args_node_call.children = vec![Child::Node(Box::new(int_node))];
        exp_node_call.children = vec![
            Child::Node(Box::new(call_node)),
            Child::Node(Box::new(args_node_call)),
        ];
        let calls_call = b.node_call_projections(&exp_node_call);
        assert_eq!(calls_call.len(), 1);
        assert_eq!(calls_call[0].message, "method");

        // Cover fallback branches in lua_expression_list_call
        let mut non_lvar_node = node("EXPRESSION_LIST", "1");
        non_lvar_node.children = vec![Child::Node(Box::new(node("INT", "1")))];
        assert!(b.node_call_projections(&non_lvar_node).is_empty());

        let mut other_lvar_node = node("LVAR", "other");
        other_lvar_node.children = vec![Child::Symbol("other".to_string())];
        let mut exp_node_other = node("EXPRESSION_LIST", "other(t)");
        exp_node_other.children = vec![
            Child::Node(Box::new(other_lvar_node)),
            Child::Node(Box::new(node("ARGUMENTS", ""))),
        ];
        assert!(b.node_call_projections(&exp_node_other).is_empty());

        // 5. call_site_span
        assert_eq!(
            b.call_site_span(
                &node("CALL", "self:escalate()"),
                &NormalizedCallParts {
                    receiver: "self".to_string(),
                    message: "escalate".to_string(),
                    arguments: Vec::new()
                },
                [1, 2, 3, 4],
                [5, 6, 7, 8],
                "foo"
            ),
            [5, 6, 7, 8]
        );
        assert_eq!(
            b.call_site_span(
                &node("CALL", "other()"),
                &NormalizedCallParts {
                    receiver: "other".to_string(),
                    message: "other".to_string(),
                    arguments: Vec::new()
                },
                [1, 2, 3, 4],
                [5, 6, 7, 8],
                "foo"
            ),
            [1, 2, 3, 4]
        );

        // 6. suppress_state_read_for_call
        assert!(b.suppress_state_read_for_call(
            &NormalizedCallProjection {
                receiver: "self".to_string(),
                message: "callback".to_string(),
                arguments: Vec::new(),
                access_span: [1, 2, 3, 4],
                span: [1, 2, 3, 4],
            },
            ""
        ));

        // 7. property_read_call
        assert!(b.property_read_call(
            &node("CALL", "x.y"),
            &NormalizedCallParts {
                receiver: "x".to_string(),
                message: "y".to_string(),
                arguments: Vec::new(),
            }
        ));

        // 8. embedded_member_reads & node_state_reads
        let reads = b.node_state_reads(&node("DOT_INDEX_EXPRESSION", "self.x"));
        assert_eq!(reads.len(), 1);
        assert_eq!(reads[0].field, "x");
        assert!(b.node_state_reads(&node("other", "self.x")).is_empty());

        // 9. function_visibility
        assert_eq!(b.function_visibility("foo", &node("", ""), &[]), "public");

        // 10. owner_for_function & lua_function_owner
        assert_eq!(
            b.owner_for_function(
                "foo",
                &node("FN", "function MyTable:foo()"),
                "current",
                "file"
            ),
            "MyTable"
        );
        assert_eq!(
            b.owner_for_function("foo", &node("FN", "function foo()"), "current", "file"),
            "current"
        );
        assert_eq!(
            b.owner_for_function(
                "foo",
                &node("FN", "function MyTable:foo"),
                "current",
                "file"
            ),
            "MyTable"
        );

        // 11. owner_name_span
        assert!(b
            .owner_name_span("MyClass", &node("CLASS", ""), [1, 2, 3, 4])
            .is_some());

        // 12. suppress_branch_decision
        assert!(b.suppress_branch_decision(&node("", "elseif x then")));

        // 13. nil_guard_fact
        assert!(b.nil_guard_fact("isNull", "x").is_some());

        // 14. terminating_call_message
        assert!(b.terminating_call_message("error"));

        // 15. semantic_effect_for_call
        assert!(b
            .semantic_effect_for_call(&CallSite {
                receiver: "x".to_string(),
                message: "isNull".to_string(),
                file: "".to_string(),
                function: "".to_string(),
                owner: "".to_string(),
                line: 1,
                span: [1, 2, 3, 4],
                conditional: false,
                arguments: Vec::new(),
                control: None,
                safe_navigation: false,
                block: false,
            })
            .is_some());

        // 16. local_assignment_writes
        assert!(b
            .local_assignment_writes(None, &node("", ""), [1, 2, 3, 4])
            .is_empty());
        let writes = b.local_assignment_writes(Some("self.field[1]"), &node("", ""), [1, 2, 3, 4]);
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].receiver, "self");
        assert_eq!(writes[0].field, "field");

        assert!(b
            .local_assignment_writes(Some("invalid"), &node("", ""), [1, 2, 3, 4])
            .is_empty());

        // 17. local_flow_declaration_keyword & local_flow_keyword
        assert!(b.local_flow_declaration_keyword("local"));
        for kw in &[
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "if", "in",
            "nil", "return", "then", "true", "while",
        ] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 18. suppress_predicate_body_text
        assert!(b.suppress_predicate_body_text("nil"));

        // 19. predicate_body_language_signal
        assert!(b.predicate_body_language_signal("nil"));

        // 20. state_declaration_from_node
        assert!(b
            .state_declaration_from_node(&node("", ""), "", false)
            .is_none());

        // 21-25. formatting
        assert_eq!(b.format_array_type("Int"), "Int[]");
        assert_eq!(b.format_hash_type("String", "Int"), "table<String, Int>");
        assert_eq!(b.format_set_type("Int"), "table<Int, boolean>");
        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("Int|nil"), "Int|nil");
        assert_eq!(b.format_nilable_type("Int"), "Int|nil");
        assert_eq!(b.untyped_type(), "any");
        assert_eq!(b.untyped_array_type(), "any[]");
        assert_eq!(b.untyped_hash_type(), "table");

        // child_symbol None branch
        let empty_node = node("", "");
        assert_eq!(child_symbol(&empty_node, 0), None);
        // first_string_or_symbol None branch
        assert_eq!(first_string_or_symbol(&empty_node), None);
        // child_symbol and first_string_or_symbol match fallback arms
        let mut node_with_int = node("", "");
        node_with_int.children = vec![Child::Integer(1)];
        assert_eq!(child_symbol(&node_with_int, 0), None);
        assert_eq!(first_string_or_symbol(&node_with_int), None);
    }
}
