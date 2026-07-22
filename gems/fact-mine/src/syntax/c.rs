// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    configured_intrinsic_call_complexity, eliminable_guard_from_call, exact_direct_call_name,
    native_pointer_nullability_contract, nil_guard_from_predicates, scip_descriptor_owner,
    scip_global_parts, type_before_parameter_name, NormalizedCallComplexity, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedNullableOperation, NormalizedOwner, NormalizedSemanticEffect,
};
use super::{CallSite, ExternalSymbolMetadata};
use crate::ast::{Child, Node, Span};
use std::collections::BTreeMap;

const C_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &["dlsym", "dlopen", "GetProcAddress"],
    meta_mids: &["setjmp", "longjmp", "va_start", "va_arg"],
    method_obj_mids: &["method"],
    io_consts: &["FILE", "DIR", "pthread", "mutex", "atomic"],
    io_bare: &[
        "print", "printf", "fprintf", "fopen", "open", "read", "write", "close", "system", "exec",
        "abort", "exit", "assert", "puts", "panic",
    ],
    context_bare: &["rand", "time", "clock"],
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
        "pthread_mutex_lock",
        "pthread_mutex_unlock",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const C_NIL_PREDICATES: &[&str] = &["isNull", "is_null"];
const C_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const C_GUARD_MIDS: &[&str] = &["isNull", "is_null"];

fn scip_clang_parts(symbol: &str) -> Option<(&str, &str)> {
    let (package, _version, descriptor) = scip_global_parts(symbol, "cxx", ".")?;
    Some((package, descriptor))
}

pub(crate) fn external_symbol_metadata(symbol: &str) -> ExternalSymbolMetadata {
    let Some((package, _descriptor)) = scip_clang_parts(symbol) else {
        return ExternalSymbolMetadata {
            scope: "dynamic",
            missing_cost_kind: "callback_or_function_value_origin_unknown".to_string(),
            parametric_cost: None,
        };
    };
    // Clang's SCIP symbols intentionally do not claim that an un-packaged C
    // global came from libc rather than a project header. Preserve that
    // uncertainty instead of turning a familiar spelling into fake proof.
    ExternalSymbolMetadata {
        scope: if package == "." {
            "external"
        } else {
            "dependency"
        },
        missing_cost_kind: "dependency_cost_model_missing".to_string(),
        parametric_cost: None,
    }
}

pub(crate) fn external_symbol_owner(symbol: &str) -> Option<String> {
    let (_package, descriptor) = scip_clang_parts(symbol)?;
    scip_descriptor_owner(descriptor)
}

// CFG-SPECIFIC START: C control-flow vocabulary.
const C_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &[],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

struct CNormalizedBehavior;

impl NormalizedLanguageBehavior for CNormalizedBehavior {
    fn nullable_operation(&self, node: &Node) -> Option<NormalizedNullableOperation> {
        if node.r#type == "VCALL" {
            return local_call_subject(node).map(|subject| NormalizedNullableOperation {
                subject,
                operation_kind: "function_pointer_call",
                nil_behavior: "undefined_behavior",
            });
        }
        let subject = (node.r#type == "POINTER_EXPRESSION"
            && node.text.trim_start().starts_with('*'))
        .then(|| node.children.first().and_then(crate::ast::node))
        .flatten()
        .filter(|subject| subject.r#type == "LVAR")?
        .text
        .trim()
        .to_string();
        (!subject.is_empty()).then_some(NormalizedNullableOperation {
            subject,
            operation_kind: "pointer_dereference",
            nil_behavior: "undefined_behavior",
        })
    }

    fn function_value_calls_are_local_reads(&self) -> bool {
        true
    }

    fn nullable_call_result_contract(&self, node: &Node) -> Option<&'static str> {
        exact_direct_call_name(node).and_then(|name| match name {
            "malloc" | "calloc" => Some("nullable_allocation"),
            "realloc" => Some("nullable_reallocation_preserves_input"),
            _ => None,
        })
    }

    fn nullable_declared_type_contract(&self, type_name: &str) -> Option<&'static str> {
        native_pointer_nullability_contract(type_name)
    }

    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_before_local_name(source, name)
    }

    fn parameter_type_from_signature(&self, parameter: &str) -> Option<String> {
        type_before_parameter_name(parameter)
    }

    fn external_symbol_metadata(&self, symbol: &str) -> ExternalSymbolMetadata {
        external_symbol_metadata(symbol)
    }

    fn external_symbol_owner(&self, symbol: &str) -> Option<String> {
        external_symbol_owner(symbol)
    }

    fn function_dispatch_kind_from_node(&self, _name: &str, _node: &Node, _owner: &str) -> String {
        // C functions are lexical/file-scope symbols. Some existing state
        // projections assign a synthetic struct owner to receiver-style APIs;
        // that owner is not an instance-dispatch fact.
        "top".to_string()
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("c")
    }

    // CFG-SPECIFIC START: expose the C CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &C_CFG_PROFILE
    }
    // CFG-SPECIFIC END

    fn intrinsic_call_complexity(
        &self,
        receiver: Option<&str>,
        message: &str,
    ) -> Option<NormalizedCallComplexity> {
        // The generic call extractor represents a bare C function as a
        // synthetic `self` receiver. C has no instance dispatch here, so
        // translate only that parser sentinel back to a free intrinsic.
        let receiver = receiver.filter(|receiver| *receiver != "self");
        configured_intrinsic_call_complexity("c", receiver, message)
    }

    fn call_receiver(&self, parts: &NormalizedCallParts) -> String {
        if parts.receiver != "self" {
            return parts.receiver.clone();
        }
        let first_arg = parts.arguments.first().map(String::as_str).unwrap_or("");
        first_arg
            .strip_prefix("self->")
            .filter(|field| simple_identifier(field))
            .map(|field| format!("self.{field}"))
            .unwrap_or_else(|| parts.receiver.clone())
    }

    fn self_member_receiver(&self, message: &str) -> String {
        format!("self->{message}")
    }

    fn state_identity(&self, owner: &str, field: &str) -> String {
        (!owner.is_empty())
            .then(|| format!("{owner}::{field}"))
            .unwrap_or_default()
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver.starts_with("self.") && !call.arguments.is_empty()
    }

    fn suppress_self_call_state_read(&self, call: &NormalizedCallProjection) -> bool {
        call.receiver == "self" && !call.arguments.is_empty()
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL" && parts.arguments.is_empty() && !node.text.contains('(')
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        keyword_block_span(node, "struct").or(Some(default_span))
    }

    fn declarative_owner(&self, node: &Node, _current_owner: &str) -> Option<NormalizedOwner> {
        if node.r#type != "TYPE_DEFINITION" || !node.text.contains("struct") {
            return None;
        }
        let name = node
            .text
            .split_once('}')?
            .1
            .split(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .find(|part| !part.is_empty())?;
        Some(NormalizedOwner {
            name: name.to_string(),
            kind: "struct".to_string(),
        })
    }

    fn owner_for_function(
        &self,
        name: &str,
        node: &Node,
        current_owner: &str,
        file_owner: &str,
    ) -> String {
        if current_owner != file_owner {
            return current_owner.to_string();
        }

        let params = self.parameter_list_source(&node.text);
        let first = params.split(',').next().unwrap_or_default().trim();
        if let Some(owner) = typed_pointer_owner(first) {
            return owner;
        }

        name.split_once('_')
            .and_then(|(prefix, _)| {
                prefix
                    .chars()
                    .next()
                    .filter(|ch| ch.is_ascii_uppercase())
                    .map(|_| prefix.to_string())
            })
            .unwrap_or_else(|| current_owner.to_string())
    }

    fn receiver_aliases_for_function(&self, node: &Node) -> BTreeMap<String, String> {
        let params = self.parameter_list_source(&node.text);
        let first = params.split(',').next().unwrap_or_default().trim();
        let name = first
            .split_whitespace()
            .next_back()
            .map(|value| value.trim_start_matches('*').trim())
            .filter(|value| simple_identifier(value));
        let mut aliases = BTreeMap::new();
        if first.contains('*') {
            if let Some(name) = name {
                aliases.insert(name.to_string(), "self".to_string());
            }
        }
        aliases
    }

    fn function_visibility(&self, _name: &str, node: &Node, _lines: &[String]) -> String {
        if node.text.trim_start().starts_with("static ") {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        true
    }

    fn case_pattern_display(&self, pattern: &str) -> String {
        pattern
            .strip_prefix("AST_")
            .map(|tail| format!("AST.{tail}"))
            .unwrap_or_else(|| pattern.to_string())
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        if let Some(start) = param.find("(*") {
            if let Some(end) = param[start..].find(')') {
                let inner = &param[start + 2..start + end];
                let name = inner.trim_start_matches('*').trim();
                if !name.is_empty()
                    && name
                        .chars()
                        .all(|ch| ch.is_ascii_alphanumeric() || ch == '_')
                {
                    return Some(name.to_string());
                }
            }
        }
        let text = param.trim();
        if text.is_empty() {
            return None;
        }
        let text = text.split('=').next().unwrap_or(text).trim();
        text.split(|ch: char| !(ch == '_' || ch == '?' || ch.is_ascii_alphanumeric()))
            .filter(|part| !part.is_empty())
            .next_back()
            .map(|part| part.trim_end_matches('?').to_string())
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(message, subject, C_NIL_PREDICATES, C_NON_NIL_PREDICATES)
    }

    fn terminating_call_message(&self, message: &str) -> bool {
        matches!(message, "abort" | "exit" | "panic")
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, C_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &C_EFFECT_LEXICON))
    }

    fn opaque_receiver_escape_call(&self, call: &CallSite) -> bool {
        call.receiver == "self"
    }

    fn local_flow_declaration_keyword(&self, keyword: &str) -> bool {
        matches!(
            keyword,
            "auto" | "bool" | "char" | "double" | "float" | "int" | "long" | "short" | "void"
        )
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        self.local_flow_declaration_keyword(name)
            || matches!(
                name,
                "break"
                    | "case"
                    | "const"
                    | "continue"
                    | "default"
                    | "else"
                    | "false"
                    | "for"
                    | "if"
                    | "return"
                    | "static"
                    | "struct"
                    | "true"
                    | "while"
            )
    }

    fn predicate_body_language_signal(&self, text: &str) -> bool {
        text.to_ascii_lowercase().contains("null")
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
    fn format_array_type(&self, elem: &str) -> String {
        format!("{}*", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("Map<{}, {}>", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("Set<{}>", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" {
            type_text.to_string()
        } else if type_text.ends_with('*') {
            type_text.to_string()
        } else {
            format!("{}*", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "void*".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "void**".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "void*".to_string()
    }
}

fn local_call_subject(node: &Node) -> Option<String> {
    match node.children.first()? {
        Child::Symbol(subject) | Child::String(subject) => {
            (!subject.trim().is_empty()).then(|| subject.trim().to_string())
        }
        _ => None,
    }
}

static BEHAVIOR: CNormalizedBehavior = CNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

#[cfg(test)]
fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

fn typed_pointer_owner(parameter: &str) -> Option<String> {
    if !parameter.contains('*') {
        return None;
    }
    let normalized = parameter.replace(['*', '&'], " ");
    let tokens = normalized
        .split_whitespace()
        .filter(|token| {
            !matches!(
                *token,
                "const"
                    | "volatile"
                    | "struct"
                    | "_Nullable"
                    | "_Nonnull"
                    | "__nullable"
                    | "__nonnull"
            )
        })
        .collect::<Vec<_>>();
    if tokens.len() < 2 {
        return None;
    }
    tokens
        .get(tokens.len() - 2)
        .filter(|owner| {
            **owner != "void"
                && owner
                    .chars()
                    .all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
        })
        .map(|owner| (*owner).to_string())
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
            .is_some_and(|c| c == '_' || c.is_ascii_alphabetic())
        && name
            .chars()
            .all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
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
    fn function_pointer_operations_require_a_symbol_callee() {
        let callback = Node {
            children: vec![Child::Symbol("callback".to_string())],
            ..node("VCALL", "callback()")
        };
        assert_eq!(local_call_subject(&callback), Some("callback".to_string()));
        let malformed = Node {
            children: vec![Child::Nil],
            ..node("VCALL", "callback()")
        };
        assert_eq!(local_call_subject(&malformed), None);
        assert_eq!(
            CNormalizedBehavior.function_value_calls_are_local_reads(),
            true
        );

        let address = Node {
            children: vec![Child::Node(Box::new(node("LVAR", "value")))],
            ..node("POINTER_EXPRESSION", "&value")
        };
        assert!(CNormalizedBehavior.nullable_operation(&address).is_none());
    }

    #[test]
    fn allocator_contracts_require_exact_bare_call_identity() {
        let behavior = CNormalizedBehavior;
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "malloc(sizeof(int))")),
            Some("nullable_allocation")
        );
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "realloc(value, 8)")),
            Some("nullable_reallocation_preserves_input")
        );
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "custom_malloc(value)")),
            None
        );
        assert_eq!(
            behavior.nullable_call_result_contract(&node("CALL", "object.malloc()")),
            None
        );
        assert_eq!(
            behavior.nullable_declared_type_contract("Widget * _Nullable"),
            Some("nullable_declared_type")
        );
        assert_eq!(behavior.nullable_declared_type_contract("Widget *"), None);
        assert_eq!(
            behavior.declared_local_type("Widget * _Nullable value = load_widget()", "value"),
            Some("Widget * _Nullable".to_string())
        );
    }

    #[test]
    fn typed_pointer_owner_ignores_nullability_annotations() {
        assert_eq!(
            typed_pointer_owner("Widget * _Nullable value"),
            Some("Widget".to_string())
        );
        assert_eq!(
            typed_pointer_owner("Widget * _Nonnull value"),
            Some("Widget".to_string())
        );
        assert_eq!(typed_pointer_owner("* value"), None);
    }

    #[test]
    fn c_parameter_type_preserves_nullability_annotation() {
        assert_eq!(
            CNormalizedBehavior.parameter_type_from_signature("Widget * _Nullable value"),
            Some("Widget * _Nullable".to_string())
        );
    }

    #[test]
    fn test_c_behavior_comprehensive() {
        let b = CNormalizedBehavior;

        // 1. call_receiver
        assert_eq!(
            b.call_receiver(&NormalizedCallParts {
                receiver: "self".to_string(),
                message: "foo".to_string(),
                arguments: vec!["self->field".to_string()],
            }),
            "self.field"
        );
        assert_eq!(
            b.call_receiver(&NormalizedCallParts {
                receiver: "self".to_string(),
                message: "foo".to_string(),
                arguments: vec!["not_self".to_string()],
            }),
            "self"
        );
        assert_eq!(
            b.call_receiver(&NormalizedCallParts {
                receiver: "obj".to_string(),
                message: "foo".to_string(),
                arguments: Vec::new(),
            }),
            "obj"
        );

        // 2. self_member_receiver
        assert_eq!(b.self_member_receiver("foo"), "self->foo");

        // 3. suppress_state_read_for_call
        assert!(b.suppress_state_read_for_call(
            &NormalizedCallProjection {
                receiver: "self.field".to_string(),
                message: "foo".to_string(),
                arguments: vec!["a".to_string()],
                access_span: [1, 2, 3, 4],
                span: [1, 2, 3, 4],
            },
            ""
        ));
        assert!(!b.suppress_state_read_for_call(
            &NormalizedCallProjection {
                receiver: "self.field".to_string(),
                message: "foo".to_string(),
                arguments: Vec::new(),
                access_span: [1, 2, 3, 4],
                span: [1, 2, 3, 4],
            },
            ""
        ));

        // 4. suppress_self_call_state_read
        assert!(b.suppress_self_call_state_read(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: vec!["a".to_string()],
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));
        assert!(!b.suppress_self_call_state_read(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 5. property_read_call
        assert!(b.property_read_call(
            &node("CALL", "x.y"),
            &NormalizedCallParts {
                receiver: "x".to_string(),
                message: "y".to_string(),
                arguments: Vec::new(),
            }
        ));

        // 6. owner_name_span
        let struct_node = node("STRUCT", "struct MyStruct {\n    int x;\n}");
        assert!(b
            .owner_name_span("MyStruct", &struct_node, [1, 2, 3, 4])
            .is_some());
        // Cover start_offset != 0 in keyword_block_span
        let struct_node_offset = node("STRUCT", "\nstruct MyStruct {\n    int x;\n}");
        assert!(b
            .owner_name_span("MyStruct", &struct_node_offset, [1, 2, 3, 4])
            .is_some());
        // Cover end_offset == 0 in keyword_block_span
        let struct_node_inline = node("STRUCT", "struct MyStruct {}");
        assert!(b
            .owner_name_span("MyStruct", &struct_node_inline, [1, 2, 3, 4])
            .is_some());

        // 7. declarative_owner
        let typedef_node = node(
            "TYPE_DEFINITION",
            "typedef struct MyStruct { int x; } MyStruct;",
        );
        assert_eq!(
            b.declarative_owner(&typedef_node, "").unwrap().name,
            "MyStruct"
        );
        assert!(b.declarative_owner(&node("LVAR", ""), "").is_none());

        // 8. owner_for_function
        let fn_node = node("FUNCTION", "void foo(struct MyStruct* self)");
        assert_eq!(
            b.owner_for_function("foo", &fn_node, "file", "file"),
            "MyStruct"
        );
        assert_eq!(
            b.owner_for_function(
                "MyStruct_foo",
                &node("FUNCTION", "void MyStruct_foo()"),
                "file",
                "file"
            ),
            "MyStruct"
        );
        assert_eq!(
            b.owner_for_function("foo", &node("FUNCTION", "void foo()"), "current", "file"),
            "current"
        );

        // 9. receiver_aliases_for_function
        let aliases = b.receiver_aliases_for_function(&fn_node);
        assert_eq!(aliases.get("self").map(String::as_str), Some("self"));
        let ptr_fn_node = node("FUNCTION", "void foo(MyStruct *ptr)");
        let aliases_ptr = b.receiver_aliases_for_function(&ptr_fn_node);
        assert_eq!(aliases_ptr.get("ptr").map(String::as_str), Some("self"));

        // 10. function_visibility
        assert_eq!(
            b.function_visibility("foo", &node("FN", "static void foo()"), &[]),
            "private"
        );
        assert_eq!(
            b.function_visibility("foo", &node("FN", "void foo()"), &[]),
            "public"
        );

        // 11. wrap_branch_predicate
        assert!(b.wrap_branch_predicate(&node("IF", "")));

        // 12. case_pattern_display
        assert_eq!(b.case_pattern_display("AST_NODE"), "AST.NODE");
        assert_eq!(b.case_pattern_display("OTHER"), "OTHER");

        // 13. nil_guard_fact
        assert!(b.nil_guard_fact("isNull", "x").is_some());

        // 14. terminating_call_message
        assert!(b.terminating_call_message("abort"));

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

        // 16. local_flow_declaration_keyword
        assert!(b.local_flow_declaration_keyword("int"));

        // 17. local_flow_keyword
        assert!(b.local_flow_keyword("int"));
        for kw in &[
            "break", "case", "const", "continue", "default", "else", "false", "for", "if",
            "return", "static", "struct", "true", "while",
        ] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 18. predicate_body_language_signal
        assert!(b.predicate_body_language_signal("null"));

        // 19. implicit_owner_fields
        assert!(b.implicit_owner_fields());

        // 20. field_name_from_declaration
        let field_node = node("FIELD_DECLARATION", "int my_field;");
        assert_eq!(
            b.field_name_from_declaration(&field_node),
            Some("my_field".to_string())
        );
        assert_eq!(b.field_name_from_declaration(&node("LVAR", "")), None);

        // 21-25. formatting
        assert_eq!(b.format_array_type("int"), "int*");
        assert_eq!(b.format_hash_type("int", "int"), "Map<int, int>");
        assert_eq!(b.format_set_type("int"), "Set<int>");
        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("null"), "null");
        assert_eq!(b.format_nilable_type("int*"), "int*");
        assert_eq!(b.format_nilable_type("int"), "int*");
        assert_eq!(b.untyped_type(), "void*");
        assert_eq!(b.untyped_array_type(), "void**");
        assert_eq!(b.untyped_hash_type(), "void*");

        // Cover static functions
        assert!(is_simple_name("var_name"));
        assert!(span(&node("LVAR", "")).len() == 4);
    }
}
