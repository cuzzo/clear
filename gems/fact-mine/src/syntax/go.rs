// CFG-SPECIFIC START: shared CFG profile contract.
use super::cfg::ControlFlowProfile;
// CFG-SPECIFIC END

use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    configured_collection_operation, configured_external_latency_bound,
    configured_intrinsic_call_complexity, configured_semantic_symbol_call_complexity,
    configured_semantic_symbol_kind, configured_semantic_symbol_parametric_cost,
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact, NormalizedOwner,
    method_param_types_from_signatures, NormalizedSemanticEffect, NormalizedStateRead,
    NormalizedStateWrite, SyntaxMetadata,
};
use super::{CallSite, ExternalCallComplexity, FunctionDef};
use crate::ast::{Node, Span};
use crate::type_inference::TypeExpr;
use regex::Regex;
use std::collections::{BTreeMap, BTreeSet};
use std::sync::OnceLock;

fn scip_go_parts(symbol: &str) -> Option<(&str, &str)> {
    let rest = symbol.strip_prefix("scip-go gomod ")?;
    let mut fields = rest.splitn(3, ' ');
    let module = fields.next()?;
    fields.next()?; // module version
    Some((module, fields.next()?))
}

fn go_stdlib_module(module: &str) -> bool {
    module == "github.com/golang/go/src"
}

fn go_semantic_conversion(descriptor: &str, message: &str) -> bool {
    !message.is_empty() && descriptor.ends_with(&format!("/{message}#"))
}

fn go_descriptor_package(descriptor: &str) -> Option<&str> {
    descriptor
        .rsplit_once('/')
        .map(|(package, _)| package.trim_matches('`'))
        .map(|package| package.rsplit('/').next().unwrap_or(package))
}

fn go_descriptor_owner(descriptor: &str) -> Option<String> {
    let package = go_descriptor_package(descriptor)?;
    let callable = descriptor.rsplit('/').next()?;
    callable
        .split_once('#')
        .map(|(owner, _)| format!("{package}.{}", owner.trim_matches('`')))
        .or_else(|| Some(package.to_string()))
}

pub(crate) fn external_symbol_call_complexity(
    symbol: &str,
    message: &str,
) -> Option<ExternalCallComplexity> {
    let (module, descriptor) = scip_go_parts(symbol)?;
    // scip-go emits named type conversions as exact term symbols such as
    // `time/Duration#`. The occurrence plus normalized call syntax proves a
    // representation-preserving conversion; argument work is independent.
    if go_semantic_conversion(descriptor, message) {
        return Some(ExternalCallComplexity {
            time: "O(1)",
            space: "O(1)",
            provenance: "go_semantic_conversion",
            bound_quality: "upper_bound_exact_target",
            candidates: Vec::new(),
            assumption: None,
        });
    }
    if !go_stdlib_module(module)
        || configured_semantic_symbol_parametric_cost("go", descriptor).is_some()
    {
        return None;
    }
    let behavior = GoNormalizedBehavior;
    let package = go_descriptor_package(descriptor);
    let owner = go_descriptor_owner(descriptor);
    let complexity = configured_semantic_symbol_call_complexity("go", descriptor)
        .or_else(|| {
            owner.as_deref().and_then(|owner| {
                behavior.call_complexity(&TypeExpr::Primitive(owner.to_string()), message)
            })
        })
        .or_else(|| behavior.intrinsic_call_complexity(package, message));
    if let Some(complexity) = complexity {
        return Some(ExternalCallComplexity {
            time: complexity.time,
            space: complexity.space,
            provenance: "go_stdlib_registry",
            bound_quality: "upper_bound_exact_target",
            candidates: Vec::new(),
            assumption: None,
        });
    }
    let complexity = configured_external_latency_bound("go", owner.as_deref()?, message)?;
    Some(ExternalCallComplexity {
        time: complexity.time,
        space: complexity.space,
        provenance: "go_external_effect_registry",
        bound_quality: "upper_bound_external_latency_excluded",
        candidates: Vec::new(),
        assumption: Some(
            "computational Big-O only; filesystem, network, scheduler, or stream latency is excluded"
                .to_string(),
        ),
    })
}

pub(crate) fn external_symbol_metadata(symbol: &str) -> super::ExternalSymbolMetadata {
    let Some((module, descriptor)) = scip_go_parts(symbol) else {
        return super::ExternalSymbolMetadata {
            scope: "dynamic",
            missing_cost_kind: "callback_or_function_value_origin_unknown".to_string(),
            parametric_cost: None,
        };
    };
    if go_stdlib_module(module) {
        super::ExternalSymbolMetadata {
            scope: "stdlib",
            missing_cost_kind: configured_semantic_symbol_kind("go", descriptor)
                .unwrap_or_else(|| "stdlib_cost_model_missing".to_string()),
            parametric_cost: configured_semantic_symbol_parametric_cost("go", descriptor),
        }
    } else {
        super::ExternalSymbolMetadata {
            scope: "dependency",
            missing_cost_kind: "dependency_cost_model_missing".to_string(),
            parametric_cost: None,
        }
    }
}

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
    fn external_symbol_call_complexity(
        &self,
        symbol: &str,
        message: &str,
    ) -> Option<ExternalCallComplexity> {
        external_symbol_call_complexity(symbol, message)
    }

    fn external_symbol_metadata(&self, symbol: &str) -> super::ExternalSymbolMetadata {
        external_symbol_metadata(symbol)
    }

    fn external_symbol_owner(&self, symbol: &str) -> Option<String> {
        let (_module, descriptor) = scip_go_parts(symbol)?;
        go_descriptor_owner(descriptor)
    }

    fn owner_supertypes(&self, node: &Node) -> Vec<String> {
        let Some((_, body)) = node.text.split_once('{') else {
            return Vec::new();
        };
        let body = body.rsplit_once('}').map(|(body, _)| body).unwrap_or(body);
        body.lines()
            .flat_map(|line| line.split(';'))
            .filter_map(|declaration| {
                let declaration = declaration
                    .split("//")
                    .next()
                    .unwrap_or(declaration)
                    .trim()
                    .trim_start_matches('*');
                if declaration.is_empty()
                    || declaration.contains(char::is_whitespace)
                    || declaration.contains(['(', ')', '|', '~', '`'])
                {
                    return None;
                }
                declaration
                    .chars()
                    .all(|character| {
                        character.is_alphanumeric()
                            || matches!(character, '_' | '.' | '[' | ']' | ',' | '*')
                    })
                    .then(|| declaration.to_string())
            })
            .collect()
    }

    fn declared_local_type(&self, source: &str, name: &str) -> Option<String> {
        super::normalized_behavior::type_after_go_local_name(source, name)
    }

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

    fn suppress_call_site(&self, node: &Node, call: &NormalizedCallProjection) -> bool {
        let receiver = call.receiver.trim_start();
        if call.message == "call"
            && (receiver.starts_with("func(") || receiver.starts_with('*'))
        {
            // Immediately-invoked function bodies and conversion arguments are
            // visited independently. The synthetic wrapper is not another
            // dynamically dispatched call.
            return true;
        }

        // A selector is not a call unless its selected member is followed by
        // an argument list. A nested receiver call can otherwise make
        // `x.make().field` look callable to the shared projection.
        let source = node.text.trim_end();
        let selector = format!(".{}", call.message);
        source
            .rfind(&selector)
            .map(|offset| {
                !source[(offset + selector.len())..]
                    .trim_start()
                    .starts_with('(')
            })
            .unwrap_or(false)
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
            kind: if is_interface_declaration(&node.text) {
                "interface".to_string()
            } else {
                "owner".to_string()
            },
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
        if let Some(name) = first_lvar_child_name(node) {
            let ty = node
                .text
                .trim_start()
                .strip_prefix(&name)
                .unwrap_or("")
                .trim()
                .to_string();
            return (!ty.is_empty()).then(|| super::StateDeclaration {
                field: name,
                owner: String::new(),
                r#type: Some(ty),
                immutable: false,
                file: String::new(),
                line: node.first_lineno,
                span: span(node),
            });
        }
        // Embedded field (`type Embedded struct { Basic }`, possibly
        // `*Basic` or `pkg.Basic`): there is no separate name token at
        // all - the type itself IS the field's access name (`e.Basic`).
        // Without this, an anonymous embed vanished from state extraction
        // entirely, not just under the wrong name, since neither this
        // function nor field_name_from_declaration (unset for Go) had
        // anything to find.
        let embedded_type = node.text.trim();
        let name = embedded_type.trim_start_matches('*').rsplit('.').next()?.to_string();
        (simple_identifier(&name)).then(|| super::StateDeclaration {
            field: name,
            owner: String::new(),
            r#type: Some(embedded_type.to_string()),
            immutable: false,
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

    fn syntax_metadata(&self, source: &str, functions: &[FunctionDef]) -> SyntaxMetadata {
        let method_param_types = method_param_types_from_signatures(self, source, functions);
        let method_local_types = go_method_local_types(source, functions, &method_param_types);
        let (type_aliases, type_alias_lines) = go_callable_type_aliases(source);
        SyntaxMetadata {
            type_aliases,
            type_alias_lines,
            method_param_types,
            method_local_types,
            ..SyntaxMetadata::default()
        }
    }

    fn declared_callable_cost(&self, declared_type: &str) -> Option<String> {
        declared_type
            .trim()
            .starts_with("func(")
            .then(|| "callback_once".to_string())
            .or_else(|| {
                super::normalized_behavior::configured_callable_type_cost("go", declared_type)
            })
    }

    fn owner_kind(&self, node: &Node, default_kind: &str) -> String {
        if is_interface_declaration(&node.text) {
            "interface".to_string()
        } else {
            default_kind.to_string()
        }
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

    fn supports_implicit_owner_dispatch(&self) -> bool {
        false
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

    fn initializer_writes(
        &self,
        node: &Node,
        _source_text: &str,
        span: Span,
    ) -> Vec<crate::syntax::normalized_behavior::NormalizedStateWrite> {
        let mut writes = Vec::new();
        if node.r#type == "COMPOSITE_LITERAL" {
            let mut type_name = ".literal".to_string();
            let mut is_collection = false;

            for child in &node.children {
                if let crate::ast::Child::Node(child) = child {
                    if child.r#type == "TYPE_IDENTIFIER"
                        || child.r#type == "IDENTIFIER"
                        || child.r#type == "CONST"
                    {
                        type_name = child.text.clone();
                    } else if child.r#type == "MAP_TYPE"
                        || child.r#type == "SLICE_TYPE"
                        || child.r#type == "ARRAY_TYPE"
                    {
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

fn go_callable_type_aliases(source: &str) -> (BTreeMap<String, String>, BTreeMap<String, usize>) {
    let mut aliases = BTreeMap::new();
    let mut lines = BTreeMap::new();
    for (line_index, line) in source.lines().enumerate() {
        let Some(declaration) = line.trim().strip_prefix("type ") else {
            continue;
        };
        let name_end = declaration
            .find(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .unwrap_or(declaration.len());
        let name = &declaration[..name_end];
        if name.is_empty() {
            continue;
        }
        let mut target = declaration[name_end..].trim_start();
        if target.starts_with('[') {
            let mut depth = 0usize;
            let mut close = None;
            for (index, character) in target.char_indices() {
                match character {
                    '[' => depth += 1,
                    ']' => {
                        depth = depth.saturating_sub(1);
                        if depth == 0 {
                            close = Some(index);
                            break;
                        }
                    }
                    _ => {}
                }
            }
            let Some(close) = close else { continue };
            target = target[(close + 1)..].trim_start();
        }
        target = target.strip_prefix('=').unwrap_or(target).trim_start();
        if !target.starts_with("func(") {
            continue;
        }
        aliases.insert(name.to_string(), target.to_string());
        lines.insert(name.to_string(), line_index + 1);
    }
    (aliases, lines)
}

fn go_method_local_types(
    source: &str,
    functions: &[FunctionDef],
    param_types: &BTreeMap<String, BTreeMap<String, String>>,
) -> BTreeMap<String, BTreeMap<String, String>> {
    static VAR: OnceLock<Regex> = OnceLock::new();
    static MAKE_CHAN: OnceLock<Regex> = OnceLock::new();
    static RECEIVE: OnceLock<Regex> = OnceLock::new();
    static TYPE_SWITCH: OnceLock<Regex> = OnceLock::new();
    static RANGE: OnceLock<Regex> = OnceLock::new();
    static STRUCT: OnceLock<Regex> = OnceLock::new();
    static FIELD: OnceLock<Regex> = OnceLock::new();
    let var = VAR.get_or_init(|| {
        Regex::new(r"\bvar\s+([A-Za-z_][A-Za-z0-9_]*)\s+([^\s=;,){}]+)")
            .expect("valid Go var declaration regex")
    });
    let make_chan = MAKE_CHAN.get_or_init(|| {
        Regex::new(r"([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*make\s*\(\s*chan\s+([^\s,)]+)")
            .expect("valid Go channel construction regex")
    });
    let receive = RECEIVE.get_or_init(|| {
        Regex::new(r"([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*<-\s*([A-Za-z_][A-Za-z0-9_]*)")
            .expect("valid Go channel receive regex")
    });
    let type_switch = TYPE_SWITCH.get_or_init(|| {
        Regex::new(r"switch\s+([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*([A-Za-z_][A-Za-z0-9_]*)\.\(type\)")
            .expect("valid Go type switch regex")
    });
    let range = RANGE.get_or_init(|| {
        Regex::new(r"for\s+(?:_|[A-Za-z_][A-Za-z0-9_]*)\s*,\s*([A-Za-z_][A-Za-z0-9_]*)\s*:=\s*range\s+([A-Za-z_][A-Za-z0-9_]*)(?:\.([A-Za-z_][A-Za-z0-9_]*))?")
            .expect("valid Go range declaration regex")
    });
    let struct_body = STRUCT.get_or_init(|| {
        Regex::new(r"(?s)type\s+[A-Za-z_][A-Za-z0-9_]*\s+struct\s*\{(.*?)\}")
            .expect("valid Go struct regex")
    });
    let field = FIELD.get_or_init(|| {
        Regex::new(r"(?m)^\s*([A-Za-z_][A-Za-z0-9_]*)\s+([^\s`]+)")
            .expect("valid Go field regex")
    });

    let mut field_types = BTreeMap::<String, BTreeSet<String>>::new();
    for body in struct_body.captures_iter(source).filter_map(|row| row.get(1)) {
        for capture in field.captures_iter(body.as_str()) {
            field_types
                .entry(capture[1].to_string())
                .or_default()
                .insert(capture[2].to_string());
        }
    }
    let stable_fields = field_types
        .into_iter()
        .filter_map(|(name, types)| {
            (types.len() == 1).then(|| (name, types.into_iter().next().unwrap()))
        })
        .collect::<BTreeMap<_, _>>();
    let lines = source.lines().collect::<Vec<_>>();

    functions
        .iter()
        .filter_map(|function| {
            let key = super::normalized_behavior::method_parameter_type_key(
                &function.owner,
                &function.name,
                function.line,
            );
            let parameters = param_types.get(&key).cloned().unwrap_or_default();
            let start = function.span[0].saturating_sub(1).min(lines.len());
            let end = function.span[2].min(lines.len());
            let body = lines.get(start..end)?.join("\n");
            let mut candidates = BTreeMap::<String, BTreeSet<String>>::new();
            let mut known = parameters.clone();

            for capture in var.captures_iter(&body) {
                candidates
                    .entry(capture[1].to_string())
                    .or_default()
                    .insert(capture[2].to_string());
                known.insert(capture[1].to_string(), capture[2].to_string());
            }
            let mut channel_elements = BTreeMap::new();
            for capture in make_chan.captures_iter(&body) {
                let name = capture[1].to_string();
                let element = capture[2].to_string();
                channel_elements.insert(name.clone(), element.clone());
                known.insert(name, format!("chan {element}"));
            }
            for capture in receive.captures_iter(&body) {
                let element = channel_elements
                    .get(&capture[2])
                    .map(String::as_str)
                    .or_else(|| known.get(&capture[2]).and_then(|value| value.strip_prefix("chan ")));
                if let Some(element) = element {
                    candidates
                        .entry(capture[1].to_string())
                        .or_default()
                        .insert(element.to_string());
                }
            }
            for capture in type_switch.captures_iter(&body) {
                if let Some(type_name) = known.get(&capture[2]) {
                    candidates
                        .entry(capture[1].to_string())
                        .or_default()
                        .insert(type_name.clone());
                }
            }
            for capture in range.captures_iter(&body) {
                let collection_type = capture
                    .get(3)
                    .and_then(|field| stable_fields.get(field.as_str()))
                    .or_else(|| known.get(&capture[2]));
                if let Some(element) = collection_type.and_then(|type_name| {
                    type_name
                        .strip_prefix("[]")
                        .or_else(|| type_name.strip_prefix("..."))
                }) {
                    candidates
                        .entry(capture[1].to_string())
                        .or_default()
                        .insert(element.to_string());
                }
            }

            let stable = candidates
                .into_iter()
                .filter_map(|(name, types)| {
                    (types.len() == 1).then(|| (name, types.into_iter().next().unwrap()))
                })
                .collect::<BTreeMap<_, _>>();
            (!stable.is_empty()).then_some((key, stable))
        })
        .collect()
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

// A struct with any `interface{}`-typed field anywhere in its body (a
// common idiom - mapstructure's own DecoderConfig has one) was
// misclassified as an interface itself, because callers searched the
// declaration's *entire* text for the substring "interface" rather than
// just its own `type Name struct|interface {` header. Truncating to the
// header before the first `{` excludes the body, where a field's type
// happens to contain the same word.
fn is_interface_declaration(text: &str) -> bool {
    let header = text.split('{').next().unwrap_or(text);
    header.contains(" interface") || header.trim_end().ends_with("interface")
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
    let receiver = receiver.trim();
    let mut parts = receiver.splitn(2, char::is_whitespace);
    let first = parts.next()?;
    let value = parts.next().unwrap_or(first).trim();
    Some(
        value
            .trim_start_matches('*')
            .split('[')
            .next()
            .unwrap_or(value)
            .to_string(),
    )
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
        assert_eq!(
            behavior.format_hash_type("string", "int"),
            "map[string]value_type"
        );
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
        assert!(behavior
            .state_declaration_from_node(&field_decl, "Widget", true)
            .is_none());
        assert!(behavior
            .state_declaration_from_node(&node("OTHER", "Value int"), "Widget", false)
            .is_none());

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
        assert_eq!(
            behavior.owner_for_function("MyMethod", &fn_node, "Receiver", "File"),
            "Receiver"
        );
        assert_eq!(
            behavior.owner_for_function("MyMethod", &fn_node, "File", "File"),
            "Receiver"
        );
        let generic_fn = node("FUNCTION", "func (c *LRU[K, V]) Add(key K, value V) {}");
        assert_eq!(
            behavior.owner_for_function("Add", &generic_fn, "File", "File"),
            "LRU"
        );

        // function_name_from_text
        assert_eq!(
            behavior.function_name_from_text("func (r *Receiver) MyMethod()"),
            Some("MyMethod".to_string())
        );
        assert_eq!(
            behavior.function_name_from_text("func MyFunction()"),
            Some("MyFunction".to_string())
        );
        assert_eq!(behavior.function_name_from_text("invalid"), None);

        // parameter_list_source
        assert_eq!(
            behavior.parameter_list_source("func (r *Receiver) MyMethod(a int, b string)"),
            "a int, b string"
        );
        assert_eq!(
            behavior.parameter_list_source("func MyMethod(a int)"),
            "a int"
        );
        assert_eq!(
            behavior.parameter_list_source("func (r *Receiver) MyMethod("),
            ""
        );
        assert_eq!(behavior.parameter_list_source("func MyMethod("), "");
        assert_eq!(behavior.parameter_list_source("func MyMethod"), "");
        assert_eq!(
            behavior.parameter_list_source("func (r *Receiver MyMethod()"),
            ""
        );
        assert_eq!(
            behavior.parameter_list_source("func (r *Receiver) MyMethod"),
            ""
        );

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
        invalid_field_decl.children =
            vec![Child::Node(Box::new(invalid_lvar)), Child::Integer(123)];
        assert!(behavior
            .state_declaration_from_node(&invalid_field_decl, "Widget", false)
            .is_none());
    }

    #[test]
    fn scip_go_symbols_use_proven_stdlib_identity() {
        let value_type = "scip-go gomod github.com/golang/go/src go1.22 reflect/Value#Type().";
        let atomic = "scip-go gomod github.com/golang/go/src go1.22 `sync/atomic`/LoadInt32().";
        let dependency = "scip-go gomod golang.org/x/sync v0.10.0 singleflight/Group#Do().";

        assert_eq!(
            external_symbol_call_complexity(value_type, "Type").map(|complexity| complexity.time),
            Some("O(1)")
        );
        assert_eq!(
            external_symbol_call_complexity(atomic, "LoadInt32").map(|complexity| complexity.time),
            Some("O(1)")
        );
        assert_eq!(external_symbol_metadata(value_type).scope, "stdlib");
        assert_eq!(external_symbol_metadata(dependency).scope, "dependency");
        assert!(external_symbol_call_complexity(dependency, "Do").is_none());
    }

    #[test]
    fn go_callback_contracts_remain_parametric() {
        let once = "scip-go gomod github.com/golang/go/src go1.22 sync/Once#Do().";
        let metadata = external_symbol_metadata(once);

        assert_eq!(metadata.parametric_cost.as_deref(), Some("callback_once"));
        assert!(external_symbol_call_complexity(once, "Do").is_none());

        let sort = "scip-go gomod github.com/golang/go/src go1.22 sort/Sort().";
        assert_eq!(
            external_symbol_metadata(sort).parametric_cost.as_deref(),
            Some("callback_sort")
        );

        for symbol in [
            "scip-go gomod github.com/golang/go/src go1.22 `crypto/elliptic`/Curve#Params().",
            "scip-go gomod github.com/golang/go/src go1.22 crypto/Signer#Sign().",
            "scip-go gomod github.com/golang/go/src go1.22 flag/Usage.",
        ] {
            assert_eq!(
                external_symbol_metadata(symbol).parametric_cost.as_deref(),
                Some("callback_once"),
                "{symbol}"
            );
        }

        for symbol in [
            "scip-go gomod github.com/golang/go/src go1.22 `crypto/rsa`/VerifyPKCS1v15().",
            "scip-go gomod github.com/golang/go/src go1.22 `crypto/rsa`/VerifyPSS().",
        ] {
            assert_eq!(
                external_symbol_call_complexity(symbol, "verify")
                    .map(|complexity| complexity.time),
                Some("O(N^3)"),
                "{symbol}"
            );
        }
    }

    #[test]
    fn go_suppresses_synthetic_wrappers_and_selector_projections() {
        let behavior = GoNormalizedBehavior;
        let projection = |receiver: &str, message: &str| NormalizedCallProjection {
            receiver: receiver.to_string(),
            message: message.to_string(),
            arguments: Vec::new(),
            access_span: [10, 2, 10, 6],
            span: [10, 2, 10, 8],
        };

        assert!(behavior.suppress_call_site(
            &node("CALL", "func() { work() }()"),
            &projection("func() { work() }", "call")
        ));
        assert!(behavior.suppress_call_site(
            &node("CALL", "(*uint32)(value)"),
            &projection("*uint32", "call")
        ));
        assert!(!behavior.suppress_call_site(
            &node("CALL", "fn()"),
            &projection("fn", "call")
        ));
        assert!(behavior.suppress_call_site(
            &node("CALL", "ecdsaKey.Curve.Params().BitSize"),
            &projection("ecdsaKey.Curve.Params()", "BitSize")
        ));
        assert!(!behavior.suppress_call_site(
            &node("CALL", "err.Error()"),
            &projection("err", "Error")
        ));
    }

    #[test]
    fn scip_go_term_symbols_prove_constant_named_type_conversions() {
        let stdlib = "scip-go gomod github.com/golang/go/src go1.22 time/Duration#";
        let dependency = "scip-go gomod example.com/demo v1.0.0 demo/ClaimStrings#";

        for (symbol, message) in [(stdlib, "Duration"), (dependency, "ClaimStrings")] {
            let complexity = external_symbol_call_complexity(symbol, message).unwrap();
            assert_eq!(complexity.time, "O(1)");
            assert_eq!(complexity.space, "O(1)");
            assert_eq!(complexity.provenance, "go_semantic_conversion");
            assert_eq!(complexity.bound_quality, "upper_bound_exact_target");
        }
    }

    #[test]
    fn named_generic_function_types_normalize_to_callable_aliases() {
        let source = "type EvictCallback[K comparable, V any] func(key K, value V)\n";
        let (aliases, lines) = go_callable_type_aliases(source);
        assert_eq!(
            aliases.get("EvictCallback").map(String::as_str),
            Some("func(key K, value V)")
        );
        assert_eq!(lines.get("EvictCallback"), Some(&1));
        assert_eq!(
            GoNormalizedBehavior.declared_callable_cost(
                aliases.get("EvictCallback").unwrap()
            ),
            Some("callback_once".to_string())
        );
    }

    // Real bug, found auditing mapstructure's DecoderConfig: a plain
    // struct with an `interface{}`-typed field anywhere in its body was
    // classified as an interface itself, because the check searched the
    // whole declaration text for the substring "interface" rather than
    // just its own `type Name struct|interface {` header.
    #[test]
    fn struct_with_interface_typed_field_is_not_classified_as_interface() {
        let text = "type DecoderConfig struct {\n\tResult interface{}\n\tName string\n}\n";
        assert!(!is_interface_declaration(text), "a struct field's own type must not leak into the declaration kind");

        let real_interface = "type DecodeHookFunc interface {\n\tDecode(from, to reflect.Value) error\n}\n";
        assert!(is_interface_declaration(real_interface));
    }
}
