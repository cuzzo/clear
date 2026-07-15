// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    configured_collection_operation, configured_intrinsic_call_complexity, eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
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

// CFG-SPECIFIC START: Go control-flow vocabulary.
const GO_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct GoNormalizedBehavior;

impl NormalizedLanguageBehavior for GoNormalizedBehavior {
    fn stdlib_language(&self) -> Option<&'static str> {
        Some("go")
    }

    // CFG-SPECIFIC START: expose the Go CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &GO_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn conditional_local_bindings(&self, conditional: &Node) -> Vec<String> {
        let header = conditional
            .text
            .lines()
            .next()
            .unwrap_or_default()
            .trim()
            .strip_prefix("if ")
            .unwrap_or_default();
        let Some((initializer, _)) = header.split_once(';') else {
            return Vec::new();
        };
        let Some((lhs, _)) = initializer.split_once(":=") else {
            return Vec::new();
        };
        lhs.split(',')
            .map(str::trim)
            .filter(|name| simple_identifier(name))
            .map(str::to_string)
            .collect()
    }

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
        in_method: bool,
    ) -> Option<super::StateDeclaration> {
        if in_method {
            return None;
        }
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

    fn parameter_type_from_signature(&self, param: &str) -> Option<String> {
        let mut parts = param.split_whitespace();
        let _name = parts.next()?;
        let type_name = parts.collect::<Vec<_>>().join(" ");
        (!type_name.is_empty()).then_some(type_name)
    }

    fn collection_operation(
        &self,
        receiver_type: &crate::type_inference::TypeExpr,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCollectionOperation> {
        configured_collection_operation("go", receiver_type, message)
    }

    fn intrinsic_call_complexity(
        &self,
        receiver: Option<&str>,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCallComplexity> {
        configured_intrinsic_call_complexity("go", receiver, message)
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

    fn initializer_writes(&self, node: &Node, _source_text: &str, span: Span) -> Vec<crate::syntax::normalized_behavior::NormalizedStateWrite> {
        let mut writes = Vec::new();
        if node.r#type == "COMPOSITE_LITERAL" {
            let mut type_name = ".literal".to_string();
            let mut is_collection = false;
            
            for child in &node.children {
                if let crate::ast::Child::Node(child) = child {
                    if child.r#type == "TYPE_IDENTIFIER" || child.r#type == "IDENTIFIER" || child.r#type == "CONST" {
                        type_name = child.text.clone();
                    } else if child.r#type == "MAP_TYPE" || child.r#type == "SLICE_TYPE" || child.r#type == "ARRAY_TYPE" {
                        is_collection = true;
                    }
                }
            }
            
            if !is_collection {
                for child in &node.children {
                    if let crate::ast::Child::Node(child) = child {
                        if child.r#type == "LITERAL_VALUE" {
                            for field in &child.children {
                                if let crate::ast::Child::Node(field) = field {
                                    if field.r#type == "KEYED_ELEMENT" {
                                        for key in &field.children {
                                            if let crate::ast::Child::Node(key) = key {
                                                writes.push(crate::syntax::normalized_behavior::NormalizedStateWrite {
                                                    receiver: type_name.clone(),
                                                    field: key.text.clone(),
                                                    span,
                                                });
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        writes
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

    fn format_array_type(&self, elem: &str) -> String {
        format!("[]{elem}")
    }

    fn format_hash_type(&self, key: &str, _val: &str) -> String {
        format!("map[{key}]value_type")
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("map[{elem}]struct{{}}")
    }

    fn untyped_array_type(&self) -> String {
        "[]any".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "map[string]any".to_string()
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" {
            type_text.to_string()
        } else if type_text.starts_with('*') {
            type_text.to_string()
        } else {
            format!("*{}", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "any".to_string()
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
            .char_indices()
            .rfind(|(_, ch)| !(*ch == '_' || ch.is_ascii_alphanumeric()))
            .map(|(offset, ch)| offset + ch.len_utf8())
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::Child;

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10 + text.lines().count().saturating_sub(1),
            last_column: text.lines().last().map(str::len).unwrap_or_default(),
            text: text.to_string(),
        }
    }

    #[test]
    fn test_go_behavior_uncovered_methods() {
        let behavior = GoNormalizedBehavior;

        // format_array_type etc
        assert_eq!(behavior.format_array_type("int"), "[]int");
        assert_eq!(behavior.format_hash_type("string", "int"), "map[string]value_type");
        assert_eq!(behavior.format_set_type("string"), "map[string]struct{}");
        assert_eq!(behavior.untyped_array_type(), "[]any");
        assert_eq!(behavior.untyped_hash_type(), "map[string]any");
        assert_eq!(behavior.untyped_type(), "any");
        assert_eq!(behavior.format_nilable_type(""), "");
        assert_eq!(behavior.format_nilable_type("nil"), "nil");
        assert_eq!(behavior.format_nilable_type("*int"), "*int");
        assert_eq!(behavior.format_nilable_type("int"), "*int");

        // state_declaration_from_node
        let field_decl = node("FIELD_DECLARATION", "Value int");
        assert!(behavior.state_declaration_from_node(&field_decl, "Widget", true).is_none());
        assert!(behavior.state_declaration_from_node(&node("OTHER", "Value int"), "Widget", false).is_none());

        // embedded_member_reads
        let multiline_node = Node {
            r#type: "READ".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 12,
            last_column: 5,
            text: "first\nsecond".to_string(),
        };
        assert!(behavior.embedded_member_reads(&multiline_node).is_empty());

        assert_eq!(
            behavior.conditional_local_bindings(&node(
                "IF",
                "if value, err := load(); err != nil { return err }"
            )),
            vec!["value", "err"]
        );
        assert!(behavior
            .conditional_local_bindings(&node("IF", "if err != nil { return err }"))
            .is_empty());
        assert!(behavior
            .conditional_local_bindings(&node("IF", "if err = load(); err != nil {}"))
            .is_empty());

        // owner_for_function
        let fn_node = node("FUNCTION", "func (r *Receiver) MyMethod() {}");
        assert_eq!(behavior.owner_for_function("MyMethod", &fn_node, "Receiver", "File"), "Receiver");
        assert_eq!(behavior.owner_for_function("MyMethod", &fn_node, "File", "File"), "Receiver");

        // function_name_from_text
        assert_eq!(behavior.function_name_from_text("func (r *Receiver) MyMethod()"), Some("MyMethod".to_string()));
        assert_eq!(behavior.function_name_from_text("func MyFunction()"), Some("MyFunction".to_string()));
        assert_eq!(behavior.function_name_from_text("invalid"), None);

        // parameter_list_source
        assert_eq!(behavior.parameter_list_source("func (r *Receiver) MyMethod(a int, b string)"), "a int, b string");
        assert_eq!(behavior.parameter_list_source("func MyMethod(a int)"), "a int");
        assert_eq!(behavior.parameter_list_source("func (r *Receiver) MyMethod("), "");
        assert_eq!(behavior.parameter_list_source("func MyMethod("), "");
        assert_eq!(behavior.parameter_list_source("func MyMethod"), "");
        assert_eq!(behavior.parameter_list_source("func (r *Receiver MyMethod()"), "");
        assert_eq!(behavior.parameter_list_source("func (r *Receiver) MyMethod"), "");

        // keywords
        assert!(behavior.local_flow_declaration_keyword("int"));
        assert!(!behavior.local_flow_declaration_keyword("invalid"));
        assert!(behavior.local_flow_keyword("break"));
        assert!(!behavior.local_flow_keyword("invalid"));

        // receiver_aliases_for_function
        let aliases = behavior.receiver_aliases_for_function(&fn_node);
        assert_eq!(aliases.get("r"), Some(&"self".to_string()));

        // initializer_writes
        let mut key_node = node("IDENTIFIER", "x");
        key_node.children = vec![Child::Integer(123)];
        
        let mut keyed_node = node("KEYED_ELEMENT", "x: 1");
        keyed_node.children = vec![Child::Integer(123), Child::Node(Box::new(key_node))];

        let keyed_node_no_key = node("KEYED_ELEMENT", "y: 2");
        let not_keyed_node = node("IDENTIFIER", "z");

        let mut lit_val_node = node("LITERAL_VALUE", "{x: 1}");
        lit_val_node.children = vec![
            Child::Integer(123),
            Child::Node(Box::new(not_keyed_node)),
            Child::Node(Box::new(keyed_node_no_key)),
            Child::Node(Box::new(keyed_node)),
        ];

        let mut comp_lit_node = node("COMPOSITE_LITERAL", "Point{x: 1}");
        comp_lit_node.children = vec![
            Child::Integer(123),
            Child::Node(Box::new(node("TYPE_IDENTIFIER", "Point"))),
            Child::Node(Box::new(lit_val_node)),
        ];

        let writes = behavior.initializer_writes(&comp_lit_node, "dummy", [10, 0, 10, 15]);
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].receiver, "Point");
        assert_eq!(writes[0].field, "x");

        // state_declaration_from_node error paths
        let mut invalid_lvar = node("LVAR", "x");
        invalid_lvar.children = vec![Child::Integer(123)];
        let mut invalid_field_decl = node("FIELD_DECLARATION", "Value int");
        invalid_field_decl.children = vec![Child::Node(Box::new(invalid_lvar)), Child::Integer(123)];
        assert!(behavior.state_declaration_from_node(&invalid_field_decl, "Widget", false).is_none());
    }
}
