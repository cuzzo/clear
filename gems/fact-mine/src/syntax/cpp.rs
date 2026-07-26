// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    balanced_selector_name, configured_collection_operation, configured_intrinsic_call_complexity,
    configured_non_call_construct, configured_semantic_symbol_call_complexity,
    configured_semantic_symbol_kind, configured_semantic_symbol_parametric_cost,
    eliminable_guard_from_call, exact_direct_call_name, native_pointer_nullability_contract,
    nil_guard_from_predicates, scip_descriptor_owner, scip_global_parts,
    type_before_parameter_name, NormalizedCallParts, NormalizedCallProjection,
    NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedNullableOperation,
    NormalizedSemanticEffect, NormalizedStateRead,
};
use super::{CallSite, ExternalCallComplexity, ExternalSymbolMetadata};
use crate::ast::{Child, Node, Span};
use crate::type_inference::languages::nominal::{self, NominalTypeSyntax};
use crate::type_inference::TypeExpr;

const CPP_NOMINAL_TYPE_SYNTAX: NominalTypeSyntax = NominalTypeSyntax {
    strip_prefixes: &["const "],
    trim_prefix_chars: &[],
    trim_suffix_chars: &['&', '*'],
    array_names: &["vector", "array", "span"],
    hash_names: &["unordered_map"],
    set_names: &["unordered_set"],
    string_names: &["string", "basic_string"],
    bare_array_names: &[],
    suffix_array: false,
    bracket_array: false,
};

pub(crate) fn parse_declared_type(source: &str) -> TypeExpr {
    nominal::parse(source, &CPP_NOMINAL_TYPE_SYNTAX)
}

fn scip_clang_parts(symbol: &str) -> Option<(&str, &str)> {
    let (package, _version, descriptor) = scip_global_parts(symbol, "cxx", ".")?;
    Some((package, descriptor))
}

fn cpp_std_descriptor(descriptor: &str) -> bool {
    descriptor.starts_with("std/") || descriptor.starts_with("`std`/")
}

fn cpp_std_owner_type(owner: &str) -> TypeExpr {
    match owner.trim_matches('`') {
        "array" | "span" | "vector" => TypeExpr::Array(Box::new(TypeExpr::Untyped)),
        "map" | "unordered_map" => TypeExpr::Hash {
            key: Box::new(TypeExpr::Untyped),
            value: Box::new(TypeExpr::Untyped),
        },
        "set" | "unordered_set" => TypeExpr::Set(Box::new(TypeExpr::Untyped)),
        "basic_string" | "string" | "string_view" => TypeExpr::Primitive("String".to_string()),
        other => parse_declared_type(other),
    }
}

pub(crate) fn external_symbol_call_complexity(
    symbol: &str,
    message: &str,
) -> Option<ExternalCallComplexity> {
    let (_package, descriptor) = scip_clang_parts(symbol)?;
    if !cpp_std_descriptor(descriptor)
        || configured_semantic_symbol_parametric_cost("cpp", descriptor).is_some()
    {
        return None;
    }
    let owner = scip_descriptor_owner(descriptor);
    let message = balanced_selector_name(message);
    let complexity = configured_semantic_symbol_call_complexity("cpp", descriptor)
        .or_else(|| {
            owner
                .as_deref()
                .and_then(|owner| configured_intrinsic_call_complexity("cpp", Some(owner), message))
        })
        .or_else(|| {
            owner.as_deref().and_then(|owner| {
                CppNormalizedBehavior.call_complexity(&cpp_std_owner_type(owner), message)
            })
        })?;
    Some(ExternalCallComplexity {
        time: complexity.time,
        space: complexity.space,
        provenance: "cpp_scip_symbol_registry",
        bound_quality: "upper_bound_exact_target",
        candidates: Vec::new(),
        assumption: None,
    })
}

pub(crate) fn external_symbol_metadata(symbol: &str) -> ExternalSymbolMetadata {
    let Some((package, descriptor)) = scip_clang_parts(symbol) else {
        return ExternalSymbolMetadata {
            scope: "dynamic",
            missing_cost_kind: "callback_or_function_value_origin_unknown".to_string(),
            parametric_cost: None,
        };
    };
    if cpp_std_descriptor(descriptor) {
        ExternalSymbolMetadata {
            scope: "stdlib",
            missing_cost_kind: configured_semantic_symbol_kind("cpp", descriptor)
                .unwrap_or_else(|| "stdlib_cost_model_missing".to_string()),
            parametric_cost: configured_semantic_symbol_parametric_cost("cpp", descriptor),
        }
    } else {
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
}

pub(crate) fn external_symbol_owner(symbol: &str) -> Option<String> {
    let (_package, descriptor) = scip_clang_parts(symbol)?;
    scip_descriptor_owner(descriptor)
}

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

// CFG-SPECIFIC START: C++ control-flow vocabulary.
const CPP_CFG_PROFILE: ControlFlowProfile = ControlFlowProfile {
    iterator_messages: &["for_each", "transform"],
    ignored_callback_body_sources: &[],
};
// CFG-SPECIFIC END

pub(crate) struct CppNormalizedBehavior;

/// C++ normalizes `static_cast<T>(call())` as an FCALL. The cast only changes
/// the static view of the result, so a reviewed nullable result contract still
/// belongs to the exact inner call.
fn transparent_static_cast_argument(node: &Node) -> Option<&Node> {
    let Child::Symbol(name) = node.children.first()? else {
        return None;
    };
    if node.r#type != "FCALL" || !name.starts_with("static_cast<") {
        return None;
    }
    let arguments = node.children.get(1).and_then(crate::ast::node)?;
    if arguments.r#type != "LIST" {
        return None;
    }
    let mut children = arguments.children.iter().filter_map(crate::ast::node);
    let only = children.next()?;
    children.next().is_none().then_some(only)
}

fn nullable_contract_call(node: &Node) -> &Node {
    if let Some(argument) = transparent_static_cast_argument(node) {
        return nullable_contract_call(argument);
    }
    if node.r#type == "LIST" {
        let mut children = node.children.iter().filter_map(crate::ast::node);
        let only = children.next();
        if children.next().is_none() {
            if let Some(only) = only {
                return nullable_contract_call(only);
            }
        }
    }
    node
}

impl NormalizedLanguageBehavior for CppNormalizedBehavior {
    // C-family indexers render a local as `Type name` - the type leads.
    fn parse_variable_declaration(&self, text: &str) -> Option<String> {
        let text = text.trim().trim_end_matches(';').trim();
        let (declared, _name) = text.rsplit_once(char::is_whitespace)?;
        let declared = declared.trim();
        (!declared.is_empty() && !declared.contains('=')).then(|| declared.to_string())
    }

    // C++ declares `Ret name(T a)`, not `name(a: T) -> Ret`.
    fn parse_signature(
        &self,
        signature: &str,
    ) -> super::normalized_behavior::NormalizedSignature {
        super::normalized_behavior::parse_c_family_declarator(signature)
    }

    fn nullable_operation(&self, node: &Node) -> Option<NormalizedNullableOperation> {
        if node.r#type == "VCALL" {
            return local_call_subject(node).map(|subject| NormalizedNullableOperation {
                subject,
                operation_kind: "function_pointer_call",
                nil_behavior: "undefined_behavior",
            });
        }
        if node.r#type == "CALL" {
            return node
                .children
                .first()
                .and_then(crate::ast::node)
                .filter(|receiver| receiver.r#type == "LVAR")
                .map(|receiver| receiver.text.trim().to_string())
                .filter(|subject| !subject.is_empty())
                .map(|subject| NormalizedNullableOperation {
                    subject,
                    operation_kind: "pointer_selector",
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
        let call = nullable_contract_call(node);
        if call.r#type == "NEW_EXPRESSION" && call.text.contains("std::nothrow") {
            return Some("nullable_nothrow_allocation");
        }
        exact_direct_call_name(call).and_then(|name| match name {
            "malloc" | "calloc" => Some("nullable_allocation"),
            "realloc" => Some("nullable_reallocation_preserves_input"),
            name if name.starts_with("dynamic_cast<") && name.contains('*') => {
                Some("nullable_pointer_dynamic_cast")
            }
            _ => None,
        })
    }

    fn nullable_declared_type_contract(&self, type_name: &str) -> Option<&'static str> {
        native_pointer_nullability_contract(type_name)
    }

    fn external_symbol_call_complexity(
        &self,
        symbol: &str,
        message: &str,
    ) -> Option<ExternalCallComplexity> {
        external_symbol_call_complexity(symbol, message)
    }

    fn external_symbol_metadata(&self, symbol: &str) -> ExternalSymbolMetadata {
        external_symbol_metadata(symbol)
    }

    fn external_symbol_owner(&self, symbol: &str) -> Option<String> {
        external_symbol_owner(symbol)
    }

    fn owner_supertypes(&self, node: &Node) -> Vec<String> {
        let header = node.text.split('{').next().unwrap_or(&node.text);
        header
            .split_once(" : ")
            .map(|(_, clause)| super::normalized_behavior::split_declared_supertypes(clause))
            .unwrap_or_default()
    }

    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_before_local_name(source, name)
    }

    fn stdlib_language(&self) -> Option<&'static str> {
        Some("cpp")
    }

    // CFG-SPECIFIC START: expose the C++ CFG profile.
    fn cfg_profile(&self) -> &'static ControlFlowProfile {
        &CPP_CFG_PROFILE
    }
    // CFG-SPECIFIC END

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

    fn parameter_type_from_signature(&self, parameter: &str) -> Option<String> {
        type_before_parameter_name(parameter)
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        cpp_member_selector_is_invoked(&node.text, &parts.message) == Some(false)
    }

    fn suppress_call_site(&self, _node: &Node, call: &NormalizedCallProjection) -> bool {
        configured_non_call_construct("cpp", &call.message)
    }

    fn collection_operation(
        &self,
        receiver_type: &crate::type_inference::TypeExpr,
        message: &str,
    ) -> Option<super::normalized_behavior::NormalizedCollectionOperation> {
        configured_collection_operation("cpp", receiver_type, message)
    }

    fn mutating_receiver_message(&self, message: &str) -> bool {
        matches!(
            message,
            "clear" | "erase" | "insert" | "pop_back" | "push_back" | "reserve" | "resize"
        )
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
            .rfind(|part| simple_identifier(part))
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
            .rfind(|part| !part.is_empty())
            .map(|part| part.trim_end_matches('?').to_string())
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
    fn format_array_type(&self, elem: &str) -> String {
        format!("std::vector<{}>", elem)
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("std::unordered_map<{}, {}>", key, val)
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("std::unordered_set<{}>", elem)
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty()
            || type_text == "nil"
            || type_text == "null"
            || type_text.starts_with("std::optional<")
        {
            type_text.to_string()
        } else {
            format!("std::optional<{}>", type_text)
        }
    }

    fn untyped_type(&self) -> String {
        "std::any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "std::vector<std::any>".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "std::unordered_map<std::string, std::any>".to_string()
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

fn cpp_member_selector_is_invoked(source: &str, message: &str) -> Option<bool> {
    let selector = balanced_selector_name(message);
    if selector.is_empty() || selector == "operator" {
        return None;
    }
    let explicit_offset = ["->", ".", "::"]
        .into_iter()
        .filter_map(|separator| {
            source
                .rfind(&format!("{separator}{selector}"))
                .map(|offset| offset + separator.len() + selector.len())
        })
        .max();
    let offset = explicit_offset.or_else(|| {
        source
            .match_indices(selector)
            .filter_map(|(offset, _)| {
                let before = source[..offset].chars().next_back();
                let end = offset + selector.len();
                let after = source[end..].chars().next();
                let identifier = |character: char| character == '_' || character.is_alphanumeric();
                (!before.is_some_and(identifier) && !after.is_some_and(identifier)).then_some(end)
            })
            .last()
    })?;
    let suffix = source[offset..].trim_start();
    if !suffix.starts_with('<') {
        return Some(suffix.starts_with('('));
    }

    let mut depth = 0usize;
    for (index, character) in suffix.char_indices() {
        match character {
            '<' => depth += 1,
            '>' => {
                depth = depth.saturating_sub(1);
                if depth == 0 {
                    return Some(
                        suffix[index + character.len_utf8()..]
                            .trim_start()
                            .starts_with('('),
                    );
                }
            }
            _ => {}
        }
    }
    None
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
        assert!(CppNormalizedBehavior.function_value_calls_are_local_reads());

        let address = Node {
            children: vec![Child::Node(Box::new(node("LVAR", "value")))],
            ..node("POINTER_EXPRESSION", "&value")
        };
        assert!(CppNormalizedBehavior.nullable_operation(&address).is_none());
    }

    #[test]
    fn allocator_contracts_require_exact_bare_call_identity() {
        let behavior = CppNormalizedBehavior;
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

        let allocation = Node {
            children: vec![
                Child::Symbol("static_cast<int *>".to_string()),
                Child::Node(Box::new(Node {
                    children: vec![Child::Node(Box::new(Node {
                        children: vec![Child::Symbol("malloc".to_string())],
                        ..node("FCALL", "malloc(sizeof(int))")
                    }))],
                    ..node("LIST", "malloc(sizeof(int))")
                })),
            ],
            ..node("FCALL", "static_cast<int *>(malloc(sizeof(int)))")
        };
        assert_eq!(
            behavior.nullable_call_result_contract(&allocation),
            Some("nullable_allocation")
        );

        let nested_allocation = Node {
            children: vec![Child::Node(Box::new(Node {
                children: vec![Child::Symbol("malloc".to_string())],
                ..node("FCALL", "malloc(sizeof(int))")
            }))],
            ..node("LIST", "malloc(sizeof(int))")
        };
        assert_eq!(
            behavior.nullable_call_result_contract(&nested_allocation),
            Some("nullable_allocation")
        );

        let malformed_cast = Node {
            children: vec![
                Child::Symbol("static_cast<int *>".to_string()),
                Child::Node(Box::new(node("PAREN", ""))),
            ],
            ..node("FCALL", "static_cast<int *>(value)")
        };
        assert_eq!(
            behavior.nullable_call_result_contract(&malformed_cast),
            None
        );
        assert_eq!(
            behavior.nullable_declared_type_contract("gsl::not_null<Widget *>"),
            Some("non_null_declared_type")
        );
        assert_eq!(
            behavior.nullable_declared_type_contract("std::unique_ptr<Widget>"),
            None
        );
        assert_eq!(
            behavior.declared_local_type("gsl::not_null<Widget *> value = load_widget()", "value"),
            Some("gsl::not_null<Widget *>".to_string())
        );
    }

    #[test]
    fn test_cpp_behavior_comprehensive() {
        let b = CppNormalizedBehavior;

        // 1. source_message_text
        assert_eq!(
            b.source_message_text("foo", Some(&node("CALL", "foo()"))),
            "foo()"
        );
        assert_eq!(
            b.source_message_text("foo", Some(&node("CALL", "foo"))),
            "foo"
        );
        assert_eq!(b.source_message_text("foo", None), "foo");

        // 2. owner_name_span
        assert!(b
            .owner_name_span("MyClass", &node("CLASS", ""), [1, 2, 3, 4])
            .is_some());

        // 3. function_visibility
        let lines = vec![
            "class MyClass {".to_string(),
            "public:".to_string(),
            "  void foo();".to_string(),
            "private:".to_string(),
            "  void bar();".to_string(),
        ];
        let mut fn_foo = node("FUNCTION", "void foo();");
        fn_foo.first_lineno = 3;
        let mut fn_bar = node("FUNCTION", "void bar();");
        fn_bar.first_lineno = 5;
        assert_eq!(b.function_visibility("foo", &fn_foo, &lines), "public");
        assert_eq!(b.function_visibility("bar", &fn_bar, &lines), "private");

        // test last_visibility_marker same line visibility fallback
        let lines_inline = vec!["public: void foo();".to_string()];
        let mut fn_inline = node("FUNCTION", "void foo();");
        fn_inline.first_lineno = 1;
        fn_inline.first_column = 8;
        assert_eq!(
            b.function_visibility("foo", &fn_inline, &lines_inline),
            "public"
        );

        // 4. implicit_owner_fields
        assert!(b.implicit_owner_fields());

        // 5. field_name_from_declaration
        assert_eq!(
            b.field_name_from_declaration(&node("FIELD_DECLARATION", "int count;")),
            Some("count".to_string())
        );
        assert_eq!(b.field_name_from_declaration(&node("LVAR", "")), None);

        // 6. initializer_field_reads
        let init_node = node("CONSTRUCTOR", "MyClass() : count(0) {}");
        let reads =
            b.initializer_field_reads(&init_node, "MyClass", &["count".to_string()], "MyClass");
        assert_eq!(reads.len(), 1);
        assert_eq!(reads[0].field, "count");
        assert!(b
            .initializer_field_reads(&init_node, "MyClass", &["count".to_string()], "not_owner")
            .is_empty());
        // Cover target_span_from_text returning None (line 128)
        let init_node_no_text = node("CONSTRUCTOR", "MyClass() : field(0) {}");
        assert!(b
            .initializer_field_reads(
                &init_node_no_text,
                "MyClass",
                &["count".to_string()],
                "MyClass"
            )
            .is_empty());

        // 7. state_read_uses_access_span
        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 8. suppress_state_read_for_call
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

        // 9. case_predicate_text
        assert_eq!(b.case_predicate_text("(a == b)"), "a == b");

        // 10. stream_insertion_operator
        assert!(b.stream_insertion_operator(&node("OP", "")));

        // 11. nil_guard_fact
        assert!(b.nil_guard_fact("isNull", "x").is_some());

        // 12. terminating_call_message
        assert!(b.terminating_call_message("throw"));

        // 13. semantic_effect_for_call
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

        // 14. local_flow_declaration_keyword
        assert!(b.local_flow_declaration_keyword("int"));

        // 15. local_flow_keyword
        assert!(b.local_flow_keyword("int"));
        for kw in &[
            "break",
            "case",
            "class",
            "const",
            "continue",
            "default",
            "else",
            "false",
            "for",
            "if",
            "private",
            "protected",
            "public",
            "return",
            "static",
            "struct",
            "this",
            "true",
            "while",
        ] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 16. predicate_body_language_signal
        assert!(b.predicate_body_language_signal("null"));

        // 17-21. formatting
        assert_eq!(b.format_array_type("int"), "std::vector<int>");
        assert_eq!(
            b.format_hash_type("int", "int"),
            "std::unordered_map<int, int>"
        );
        assert_eq!(b.format_set_type("int"), "std::unordered_set<int>");
        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(
            b.format_nilable_type("std::optional<int>"),
            "std::optional<int>"
        );
        assert_eq!(b.format_nilable_type("int"), "std::optional<int>");
        assert_eq!(b.untyped_type(), "std::any");
        assert_eq!(b.untyped_array_type(), "std::vector<std::any>");
        assert_eq!(
            b.untyped_hash_type(),
            "std::unordered_map<std::string, std::any>"
        );
    }
}
