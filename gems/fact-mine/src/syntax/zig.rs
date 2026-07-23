// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, type_after_parameter_colon,
    NormalizedCallParts, NormalizedCallProjection, NormalizedLanguageBehavior,
    NormalizedNilGuardFact, NormalizedOwner, NormalizedSemanticEffect, NormalizedStateRead,
    NormalizedStateWrite,
};
use super::{CallSite, StateDeclaration};
use crate::ast::{Child, Node, Span};
use crate::type_inference::languages::nominal::{self, NominalTypeSyntax};
use crate::type_inference::TypeExpr;

const ZIG_NOMINAL_TYPE_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
    strip_prefixes: &[],
    trim_prefix_chars: &[],
    trim_suffix_chars: &[],
    array_names: &["ArrayList", "ArrayListUnmanaged"],
    hash_names: &["StringHashMap", "AutoHashMap", "AutoHashMapUnmanaged"],
    set_names: &[],
    string_names: &[],
    bare_array_names: &[],
    suffix_array: false,
    bracket_array: false,
};

pub(crate) fn parse_declared_type(source: &str) -> TypeExpr {
    // Zig generic type constructors use `Name(T)` rather than angle brackets.
    // Normalize only adapter-owned container constructors before handing the
    // structural split to the language-neutral helper.
    let source = source.trim();
    let normalized = source.find('(').and_then(|open| {
        let close = source.rfind(')')?;
        let base = source[..open].rsplit('.').next().unwrap_or(&source[..open]);
        let recognized = ZIG_NOMINAL_TYPE_SYNTAX.array_names.contains(&base)
            || ZIG_NOMINAL_TYPE_SYNTAX.hash_names.contains(&base);
        (recognized && close > open)
            .then(|| format!("{}<{}>", &source[..open], &source[(open + 1)..close]))
    });
    nominal::parse(
        normalized.as_deref().unwrap_or(source),
        &ZIG_NOMINAL_TYPE_SYNTAX,
    )
}

const ZIG_CONTEXT_PAIRS: &[(&str, &[&str])] =
    &[("time", &["timestamp", "nanoTimestamp", "milliTimestamp"])];

const ZIG_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &["field", "fieldParentPtr", "ptrCast", "alignCast", "call"],
    meta_mids: &[
        "typeInfo",
        "TypeOf",
        "ptrCast",
        "intFromPtr",
        "ptrFromInt",
        "eval",
    ],
    method_obj_mids: &["method"],
    io_consts: &[
        "std", "os", "fs", "process", "net", "Thread", "Mutex", "Atomic",
    ],
    io_bare: &["panic", "print", "println", "eprintln", "printf", "puts"],
    context_pairs: ZIG_CONTEXT_PAIRS,
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
        "spawn",
        "wait",
        "signal",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const ZIG_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const ZIG_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const ZIG_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

// CFG-SPECIFIC START: Zig control-flow vocabulary.
const ZIG_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct ZigNormalizedBehavior;

impl NormalizedLanguageBehavior for ZigNormalizedBehavior {
    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_after_local_colon(source, name)
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("zig")
    }

    // CFG-SPECIFIC START: expose the Zig CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &ZIG_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn state_write_span(
        &self,
        receiver: &str,
        field: &str,
        node: &Node,
        default_span: Span,
    ) -> Span {
        target_span_from_text(node, &format!("{receiver}.{field}")).unwrap_or(default_span)
    }

    fn suppress_call_site(&self, _node: &Node, call: &NormalizedCallProjection) -> bool {
        call.receiver == "std.debug" && call.message == "print"
    }

    fn local_assignment_writes(
        &self,
        field: Option<&str>,
        _node: &Node,
        default_span: Span,
    ) -> Vec<NormalizedStateWrite> {
        let Some(field) = field.and_then(|field| field.strip_prefix('.')) else {
            return Vec::new();
        };
        vec![NormalizedStateWrite {
            receiver: ".literal".to_string(),
            field: field.to_string(),
            span: default_span,
        }]
    }

    fn literal_state_reads(
        &self,
        node: &Node,
        normalized_text: &str,
        span: Span,
        source_text: &str,
    ) -> Vec<NormalizedStateRead> {
        let Some(field) = normalized_text.strip_prefix('.') else {
            return Vec::new();
        };
        if !simple_identifier(field) {
            return Vec::new();
        }
        vec![NormalizedStateRead {
            receiver: ".literal".to_string(),
            field: field.to_string(),
            line: Some(node.first_lineno),
            span: literal_span(node, normalized_text, span, source_text),
        }]
    }

    fn literal_state_refs(&self, _node: &Node, normalized_text: &str) -> Vec<String> {
        normalized_text
            .strip_prefix('.')
            .map(|field| vec![format!(".literal.{field}")])
            .unwrap_or_default()
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        (call.receiver == "std" && call.message == "debug")
            || (call.receiver == "self" && call.message == "callback")
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        keyword_block_span(node, "struct").or(Some(default_span))
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        if node.r#type != "VARIABLE_DECLARATION" {
            return None;
        }
        let text = node.text.as_str();
        if !text.contains("const ") || !text.contains("= struct") {
            return None;
        }
        let name = text
            .split_once("const ")?
            .1
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .find(|part| !part.is_empty())?;
        Some(NormalizedOwner {
            name: name.to_string(),
            kind: "struct".to_string(),
        })
    }

    fn body_owner_for_function(
        &self,
        name: &str,
        node: &Node,
        current_owner: &str,
        file_owner: &str,
    ) -> Option<NormalizedOwner> {
        if current_owner != file_owner || !node.text.contains("return struct") {
            return None;
        }
        let source = node.text.trim_start();
        if source.starts_with(&format!("fn {name}"))
            || source.starts_with(&format!("pub fn {name}"))
        {
            Some(NormalizedOwner {
                name: name.to_string(),
                kind: "struct".to_string(),
            })
        } else {
            None
        }
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
        if node.r#type != "CONTAINER_FIELD" {
            return None;
        }
        let field = node.children.iter().find_map(|child| match child {
            Child::Node(child) if child.r#type == "LVAR" => {
                child.children.first().and_then(|item| match item {
                    Child::String(value) | Child::Symbol(value) => Some(value.clone()),
                    _ => None,
                })
            }
            _ => None,
        })?;
        let ty = node
            .text
            .trim_start()
            .strip_prefix(&field)?
            .trim_start()
            .strip_prefix(':')?
            .split(['=', ',', '\n'])
            .next()
            .unwrap_or("")
            .trim()
            .to_string();
        (!ty.is_empty()).then(|| StateDeclaration {
            field,
            owner: String::new(),
            r#type: Some(ty),
            immutable: false,
            file: String::new(),
            line: node.first_lineno,
            span: span(node),
        })
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
        self_owner_from_zig_fn(&node.text).unwrap_or_else(|| current_owner.to_string())
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        if node.text.trim_start().starts_with("pub ") {
            "public".to_string()
        } else {
            "private".to_string()
        }
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let before_colon = param.split_once(':')?.0.trim();
        simple_identifier(before_colon).then(|| before_colon.to_string())
    }

    fn parameter_type_from_signature(&self, param: &str) -> Option<String> {
        type_after_parameter_colon(param)
    }

    fn case_pattern_values(&self, pattern_values: Vec<String>) -> Vec<String> {
        pattern_values.into_iter().take(1).collect()
    }

    fn initializer_writes(
        &self,
        node: &Node,
        _source_text: &str,
        span: Span,
    ) -> Vec<crate::syntax::normalized_behavior::NormalizedStateWrite> {
        let mut writes = Vec::new();
        if node.r#type == "STRUCT_INITIALIZER" {
            let mut type_name = ".literal".to_string();
            // Look for the type identifier
            for child in &node.children {
                if let crate::ast::Child::Node(child) = child {
                    if child.r#type == "TYPE_IDENTIFIER"
                        || child.r#type == "IDENTIFIER"
                        || child.r#type == "CONST"
                        || child.r#type == "LVAR"
                    {
                        type_name = child.text.clone();
                    }
                }
            }

            // Look for the initializer list
            for child in &node.children {
                if let crate::ast::Child::Node(child) = child {
                    if child.r#type == "INITIALIZER_LIST" {
                        for field in &child.children {
                            if let crate::ast::Child::Node(field) = field {
                                if field.r#type == "ASSIGNMENT_EXPRESSION"
                                    || field.r#type == "FIELD_INITIALIZER"
                                    || field.r#type == "LASGN"
                                {
                                    let text = field
                                        .text
                                        .split('=')
                                        .next()
                                        .unwrap_or("")
                                        .trim()
                                        .trim_start_matches('.');
                                    if !text.is_empty() {
                                        writes.push(crate::syntax::normalized_behavior::NormalizedStateWrite {
                                            receiver: type_name.clone(),
                                            field: text.to_string(),
                                            span,
                                        });
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

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, ZIG_NIL_PREDICATES, ZIG_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "panic" | "unreachable")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, ZIG_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &ZIG_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(keyword, "const" | "var")
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "break"
                    | "continue"
                    | "else"
                    | "false"
                    | "fn"
                    | "for"
                    | "if"
                    | "null"
                    | "pub"
                    | "return"
                    | "struct"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("[]{}", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("std.AutoHashMap({}, {})", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("std.AutoHashMap({}, void)", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty()
            || type_text == "nil"
            || type_text == "null"
            || type_text.starts_with('?')
        {
            type_text.to_string()
        } else {
            format!("?{}", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "anytype".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "[]anytype".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "std.AutoHashMap(anytype, anytype)".to_string()
    }
}

static BEHAVIOR: ZigNormalizedBehavior = ZigNormalizedBehavior;

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

fn target_span_from_text(node: &Node, target: &str) -> Option<Span> {
    if node.first_lineno != node.last_lineno {
        return None;
    }
    let index = node.text.find(target)?;
    Some([
        node.first_lineno,
        node.first_column + index,
        node.first_lineno,
        node.first_column + index + target.len(),
    ])
}

fn literal_span(node: &Node, text: &str, node_span: Span, source_text: &str) -> Span {
    if node.first_lineno != node.last_lineno {
        return node_span;
    }
    let source = if source_text.is_empty() {
        node.text.as_str()
    } else {
        source_text
    };
    let Some(index) = source.find(text) else {
        return node_span;
    };
    [
        node.first_lineno,
        node.first_column + index,
        node.first_lineno,
        node.first_column + index + text.len(),
    ]
}

fn self_owner_from_zig_fn(text: &str) -> Option<String> {
    let params = text.split_once('(')?.1.split_once(')')?.0;
    let first = params.split(',').next()?.trim();
    let after_colon = first.split_once(':')?.1.trim();
    let owner = after_colon.trim_start_matches('*').trim();
    simple_identifier(owner).then(|| owner.to_string())
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

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
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
            last_lineno: 10 + text.lines().count().saturating_sub(1),
            last_column: text.lines().last().map(str::len).unwrap_or_default(),
            text: text.to_string(),
        }
    }

    #[test]
    fn test_zig_behavior_uncovered_paths() {
        let behavior = ZigNormalizedBehavior;

        let reads_no_dot =
            behavior.literal_state_reads(&node("READ", "val"), "val", [1, 2, 3, 4], "");
        assert!(reads_no_dot.is_empty());

        let reads_invalid_ident =
            behavior.literal_state_reads(&node("READ", ".1val"), ".1val", [1, 2, 3, 4], "");
        assert!(reads_invalid_ident.is_empty());

        let fn_node = node("FN", "pub fn my_fun(self: *Self) { return struct {}; }");
        let owner = behavior
            .body_owner_for_function("my_fun", &fn_node, "File", "File")
            .unwrap();
        assert_eq!(owner.name, "my_fun");

        let fn_node_invalid = node("FN", "invalid_start fn my_fun() {}");
        assert!(behavior
            .body_owner_for_function("my_fun", &fn_node_invalid, "File", "File")
            .is_none());

        let fn_node_not_struct = node("FN", "fn my_fun() { return struct; }");
        assert!(behavior
            .body_owner_for_function("other_fun", &fn_node_not_struct, "File", "File")
            .is_none());

        let mut child_node = node("LVAR", "");
        child_node.children = vec![Child::Integer(42)];
        let mut container_node = node("CONTAINER_FIELD", "");
        container_node.children = vec![Child::Node(Box::new(child_node))];
        assert!(behavior
            .state_declaration_from_node(&container_node, "Widget", false)
            .is_none());

        let mut container_node_no_lvar = node("CONTAINER_FIELD", "");
        container_node_no_lvar.children = vec![Child::Node(Box::new(node("NOT_LVAR", "")))];
        assert!(behavior
            .state_declaration_from_node(&container_node_no_lvar, "Widget", false)
            .is_none());

        assert!(behavior.local_flow_declaration_keyword("const"));
        assert!(behavior.local_flow_declaration_keyword("var"));
        assert!(!behavior.local_flow_declaration_keyword("let"));
        assert!(behavior.local_flow_keyword("break"));
        assert!(behavior.local_flow_keyword("while"));
        assert!(!behavior.local_flow_keyword("domain_value"));

        let multiline_node = Node {
            r#type: "READ".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 12,
            last_column: 5,
            text: "first\nsecond".to_string(),
        };
        assert!(behavior
            .owner_name_span("Widget", &multiline_node, [10, 0, 12, 5])
            .is_some());

        let multiline_write_node = Node {
            r#type: "ASSIGN".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 12,
            last_column: 5,
            text: "self.field\nvalue".to_string(),
        };
        let write_span =
            behavior.state_write_span("self", "field", &multiline_write_node, [10, 0, 12, 5]);
        assert_eq!(write_span, [10, 0, 12, 5]);

        let multiline_read_node = Node {
            r#type: "READ".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 12,
            last_column: 5,
            text: ".my_field\nother".to_string(),
        };
        let reads_multiline =
            behavior.literal_state_reads(&multiline_read_node, ".my_field", [10, 0, 12, 5], "");
        assert_eq!(reads_multiline.len(), 1);
        assert_eq!(reads_multiline[0].span, [10, 0, 12, 5]);

        let single_line_read = Node {
            r#type: "READ".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 15,
            text: "    .my_field  ".to_string(),
        };
        let reads_source_empty =
            behavior.literal_state_reads(&single_line_read, ".my_field", [10, 0, 10, 15], "");
        assert_eq!(reads_source_empty.len(), 1);
        assert_eq!(reads_source_empty[0].span, [10, 4, 10, 13]);

        let reads_not_found = behavior.literal_state_reads(
            &single_line_read,
            ".other_field",
            [10, 0, 10, 15],
            "    .my_field  ",
        );
        assert_eq!(reads_not_found.len(), 1);
        assert_eq!(reads_not_found[0].span, [10, 0, 10, 15]);

        let fn_with_ptr = "fn init(self: *Self, value: usize)";
        assert_eq!(
            behavior.owner_for_function("init", &node("FN", fn_with_ptr), "File", "File"),
            "Self"
        );

        let multiline_struct_node = Node {
            r#type: "CLASS".to_string(),
            children: Vec::new(),
            first_lineno: 20,
            first_column: 0,
            last_lineno: 22,
            last_column: 1,
            text: "\n    struct Widget {\n}".to_string(),
        };
        let span = behavior
            .owner_name_span("Widget", &multiline_struct_node, [20, 0, 22, 1])
            .unwrap();
        assert_eq!(span[0], 21);
        assert_eq!(span[2], 22);

        let end_offset_zero_node_zig = Node {
            r#type: "CLASS".to_string(),
            children: Vec::new(),
            first_lineno: 30,
            first_column: 5,
            last_lineno: 31,
            last_column: 17,
            text: "}\n    struct Widget".to_string(),
        };
        let span_zig = behavior
            .owner_name_span("Widget", &end_offset_zero_node_zig, [30, 5, 31, 17])
            .unwrap();
        assert_eq!(span_zig[0], 31);
        assert_eq!(span_zig[2], 30);
    }

    #[test]
    fn test_zig_behavior_uncovered_methods() {
        let behavior = ZigNormalizedBehavior;
        assert_eq!(behavior.format_array_type("i32"), "[]i32");
        assert_eq!(
            behavior.format_hash_type("String", "i32"),
            "std.AutoHashMap(String, i32)"
        );
        assert_eq!(
            behavior.format_set_type("i32"),
            "std.AutoHashMap(i32, void)"
        );
        assert_eq!(behavior.format_nilable_type(""), "");
        assert_eq!(behavior.format_nilable_type("?i32"), "?i32");
        assert_eq!(behavior.format_nilable_type("i32"), "?i32");
        assert_eq!(behavior.untyped_type(), "anytype");
        assert_eq!(behavior.untyped_array_type(), "[]anytype");
        assert_eq!(
            behavior.untyped_hash_type(),
            "std.AutoHashMap(anytype, anytype)"
        );

        // Test literal_state_writes with STRUCT_INITIALIZER
        let init_list = Node {
            r#type: "INITIALIZER_LIST".to_string(),
            children: vec![
                Child::Node(Box::new(Node {
                    r#type: "FIELD_INITIALIZER".to_string(),
                    children: Vec::new(),
                    first_lineno: 10,
                    first_column: 0,
                    last_lineno: 10,
                    last_column: 15,
                    text: ".x = 42".to_string(),
                })),
                Child::Integer(123),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 15,
            text: "{ .x = 42 }".to_string(),
        };
        let type_id = Node {
            r#type: "TYPE_IDENTIFIER".to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 5,
            text: "Point".to_string(),
        };
        let struct_init = Node {
            r#type: "STRUCT_INITIALIZER".to_string(),
            children: vec![
                Child::Node(Box::new(type_id)),
                Child::Node(Box::new(init_list)),
                Child::Integer(123),
            ],
            first_lineno: 10,
            first_column: 0,
            last_lineno: 10,
            last_column: 15,
            text: "Point{ .x = 42 }".to_string(),
        };
        let writes = behavior.initializer_writes(&struct_init, "dummy", [10, 0, 10, 15]);
        assert_eq!(writes.len(), 1);
        assert_eq!(writes[0].receiver, "Point");
        assert_eq!(writes[0].field, "x");
    }
}
