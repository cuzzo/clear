// Type inference visitor and analysis engine.

#[allow(unused_macros)]
macro_rules! println {
    ($($arg:tt)*) => {
        if std::env::var("FACT_MINE_DEBUG").is_ok() {
            std::println!($($arg)*);
        }
    };
}

#[allow(unused_macros)]
macro_rules! eprintln {
    ($($arg:tt)*) => {
        if std::env::var("FACT_MINE_DEBUG").is_ok() {
            std::eprintln!($($arg)*);
        }
    };
}

use crate::syntax::{Document, Language};

use crate::profile::{
    MethodRecord, FieldRecord, StructDeclaration, StateTypeRecord, StateProtocolRecord,
    StateParamOriginRecord, TypeDefinition, HashShape, ArrayShape, StateTypeEdge,
    CallGraphEdge, receiver_state_field, state_key,
    child_nodes, call_arguments, child_symbol, owner_name, split_top_level_params,
};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use crate::ast::{Node, Span, Child};

#[derive(Clone, Debug, Eq, PartialEq)]
enum LiteralStaticValue {
    String(String),
    Symbol(String),
    Integer(i64),
    Float(String),
    Bool(bool),
    Nil,
    Unknown,
}

fn unquote(s: &str) -> String {
    let s = s.trim();
    if (s.starts_with('"') && s.ends_with('"')) || (s.starts_with('\'') && s.ends_with('\'')) {
        if s.len() >= 2 {
            s[1..s.len() - 1].to_string()
        } else {
            s.to_string()
        }
    } else {
        s.to_string()
    }
}

fn is_non_nil_type(t: &str) -> bool {
    !t.is_empty() && t != "T.untyped" && t != "NilClass" && !t.contains("T.nilable")
}

fn useful_type(t: &str) -> bool {
    !t.is_empty() && t != "T.untyped"
}

fn weak_type(t: &str) -> bool {
    t.contains("T.untyped") || t.contains("[T.untyped") || t.contains(", T.untyped")
}

fn strip_nilable_type(type_text: &str) -> String {
    let text = type_text.trim();
    if text.starts_with("T.nilable(") && text.ends_with(')') {
        extract_call_args(text, "T.nilable").unwrap_or_else(|| text.to_string())
    } else {
        text.to_string()
    }
}

fn extract_return_type(sig: &str) -> Option<String> {
    extract_call_args(sig, "returns").map(|t| t.trim().to_string())
}

fn extract_call_args(source: &str, name: &str) -> Option<String> {
    let marker = format!("{name}(");
    let idx = source.find(&marker)?;
    let start = idx + marker.len();
    let mut depth = 1i32;
    for (offset, ch) in source[start..].char_indices() {
        match ch {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth == 0 {
                    return Some(source[start..start + offset].to_string());
                }
            }
            _ => {}
        }
    }
    None
}

fn static_sorbet_type(types: &[String]) -> String {
    let mut has_nil = false;
    let mut others = BTreeSet::new();
    for ty in types.iter().filter(|ty| !ty.is_empty()) {
        if ty == "NilClass" {
            has_nil = true;
        } else if ty.starts_with("T.nilable(") && ty.ends_with(')') {
            has_nil = true;
            others.insert(strip_nilable_type(ty));
        } else {
            others.insert(normalize_static_sorbet_type(ty));
        }
    }
    if others.contains("T.noreturn") {
        if others.len() == 1 {
            return if has_nil {
                "NilClass".to_string()
            } else {
                "T.noreturn".to_string()
            };
        }
        others.remove("T.noreturn");
    }
    if others.is_empty() && has_nil {
        return "NilClass".to_string();
    }
    if others.is_empty() {
        return "T.untyped".to_string();
    }
    let base = if others
        .iter()
        .all(|ty| matches!(ty.as_str(), "TrueClass" | "FalseClass" | "T::Boolean"))
    {
        "T::Boolean".to_string()
    } else if others.len() == 1 {
        others.into_iter().next().unwrap()
    } else {
        "T.untyped".to_string()
    };
    if base == "T.untyped" {
        return base;
    }
    if has_nil {
        format!("T.nilable({base})")
    } else {
        base
    }
}

fn normalize_static_sorbet_type(type_text: &str) -> String {
    match type_text {
        "Array" => "T::Array[T.untyped]".to_string(),
        "Hash" => "T::Hash[T.untyped, T.untyped]".to_string(),
        "Set" => "T::Set[T.untyped]".to_string(),
        _ => type_text.to_string(),
    }
}

fn get_empty_node() -> &'static crate::ast::Node {
    static EMPTY_NODE: std::sync::OnceLock<crate::ast::Node> = std::sync::OnceLock::new();
    EMPTY_NODE.get_or_init(|| crate::ast::Node {
        r#type: "ZLIST".to_string(),
        children: Vec::new(),
        first_lineno: 0,
        first_column: 0,
        last_lineno: 0,
        last_column: 0,
        text: String::new(),
    })
}

fn match_call<'a>(
    node: &'a crate::ast::Node,
) -> Option<(&'a crate::ast::Node, String, &'a crate::ast::Node)> {
    if node.r#type == "CALL" || node.r#type == "QCALL" || node.r#type == "OPCALL" || node.r#type == "ATTRASGN" {
        let receiver = match node.children.get(0)? {
            crate::ast::Child::Node(n) => n.as_ref(),
            _ => return None,
        };
        let method = match node.children.get(1)? {
            crate::ast::Child::Symbol(s) | crate::ast::Child::String(s) => s.clone(),
            _ => return None,
        };
        let args = match node.children.get(2) {
            Some(crate::ast::Child::Node(n)) => n.as_ref(),
            _ => get_empty_node(),
        };
        Some((receiver, method, args))
    } else {
        None
    }
}

fn child_node(node: &crate::ast::Node, index: usize) -> Option<&crate::ast::Node> {
    node.children.get(index).and_then(crate::ast::node)
}

fn node_symbol(node: &crate::ast::Node) -> Option<String> {
    let sym = node.children.iter().find_map(|child| match child {
        crate::ast::Child::Symbol(value) | crate::ast::Child::String(value) => Some(value.clone()),
        _ => None,
    });
    if sym.is_none() && (node.r#type == "VCALL" || node.r#type == "FCALL") {
        let txt = node.text.trim().to_string();
        if !txt.is_empty() {
            if let Some(idx) = txt.find('(') {
                return Some(txt[..idx].trim().to_string());
            }
            return Some(txt);
        }
    }
    sym
}


fn implicit_return_expression(node: &crate::ast::Node) -> Option<&crate::ast::Node> {
    match node.r#type.as_str() {
        "BLOCK" | "STATEMENTS" | "BEGIN" | "ELSE" | "PAREN" | "SCOPE" | "ROOT" => {
            let ns = child_nodes(node);
            ns.last().and_then(|&n| implicit_return_expression(n))
        }
        _ => Some(node),
    }
}

fn collect_explicit_returns<'a>(
    node: &'a crate::ast::Node,
    results: &mut Vec<&'a crate::ast::Node>,
) {
    if matches!(
        node.r#type.as_str(),
        "CLASS"
            | "MODULE"
            | "INTERFACE_DECLARATION"
            | "DEFN"
            | "DEFS"
            | "LAMBDA"
            | "ITER"
            | "METHOD_SIGNATURE"
    ) {
        return;
    }
    if node.r#type == "RETURN" {
        if let Some(arg) = child_node(node, 0) {
            results.push(arg);
        } else {
            results.push(node);
        }
        return;
    }
    for child in child_nodes(node) {
        collect_explicit_returns(child, results);
    }
}

fn return_control_shape(
    explicit: &[&crate::ast::Node],
    implicit: Option<&crate::ast::Node>,
    implicit_present: bool,
) -> &'static str {
    if explicit.len() > 1 || (!explicit.is_empty() && implicit_present) {
        return "branching";
    }
    if explicit
        .iter()
        .any(|expr| branching_return_expression(*expr))
    {
        return "branching";
    }
    if implicit_present && implicit.is_some_and(|expr| branching_return_expression(expr)) {
        return "branching";
    }
    "branchless"
}

fn branching_return_expression(node: &crate::ast::Node) -> bool {
    if matches!(
        node.r#type.as_str(),
        "IF" | "UNLESS" | "CASE" | "CASE2" | "RESCUE"
    ) {
        return true;
    }
    child_nodes(node)
        .into_iter()
        .any(|child| branching_return_expression(child))
}

fn return_syntax(explicit_empty: bool, implicit_present: bool) -> &'static str {
    if !explicit_empty && implicit_present {
        "mixed"
    } else if !explicit_empty {
        "explicit"
    } else {
        "implicit"
    }
}

pub(crate) fn collect_prepass_facts(
    node: &crate::ast::Node,
    language: Language,
    current_owners: &mut Vec<String>,
    ivar_tlet_types: &mut BTreeMap<(String, String), String>,
) {
    match node.r#type.as_str() {
        "LASGN" | "CASGN" => {
            let mut pushed = false;
            let current_owner = current_owners.last().cloned().unwrap_or_default();
            let behavior = crate::syntax::normalized_behavior::behavior(language);
            if let Some(owner) = behavior.declarative_owner(node, &current_owner) {
                current_owners.push(owner.name);
                pushed = true;
            }
            for child in child_nodes(node) {
                collect_prepass_facts(child, language, current_owners, ivar_tlet_types);
            }
            if pushed {
                current_owners.pop();
            }
        }
        "CLASS" | "MODULE" | "INTERFACE_DECLARATION" => {
            let name = owner_name(node).unwrap_or_else(|| "(anonymous)".to_string());
            let qualified = if current_owners.is_empty() {
                name
            } else {
                format!("{}::{name}", current_owners.join("::"))
            };
            current_owners.push(qualified);
            for child in child_nodes(node) {
                collect_prepass_facts(child, language, current_owners, ivar_tlet_types);
            }
            current_owners.pop();
        }
        "IASGN" => {
            if let Some(ivar_name) = node_symbol(node) {
                if let Some(val_node) = child_node(node, 1) {
                    if let Some((receiver, method, args_node)) = match_call(val_node) {
                        if method == "let" && receiver.text == "T" {
                            let arg_nodes = call_arguments(args_node);
                            if let Some(type_node) = arg_nodes.get(1) {
                                let type_text = type_node.text.trim().to_string();
                                if !type_text.is_empty() && type_text != "T.untyped" {
                                    if let Some(class_name) = current_owners.last() {
                                        println!("IASGN inserting {:?} for {:?}", type_text, (class_name.clone(), ivar_name.clone()));
                                        ivar_tlet_types
                                            .insert((class_name.clone(), ivar_name), type_text);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            for child in child_nodes(node) {
                collect_prepass_facts(child, language, current_owners, ivar_tlet_types);
            }
        }
        _ => {
            for child in child_nodes(node) {
                collect_prepass_facts(child, language, current_owners, ivar_tlet_types);
            }
        }
    }
}

pub(crate) struct TypeInferenceVisitor<'a> {
    pub(crate) behavior: &'static dyn crate::syntax::normalized_behavior::NormalizedLanguageBehavior,
    pub(crate) document: &'a Document,
    pub(crate) lines: &'a [String],
    pub(crate) path: &'a str,
    pub(crate) current_owners: Vec<String>,
    pub(crate) current_method: Option<String>,
    pub(crate) current_method_kind: String,
    pub(crate) current_method_line: usize,
    pub(crate) current_method_end_line: usize,
    pub(crate) current_params: Vec<String>,
    pub(crate) param_types: BTreeMap<String, String>,
    pub(crate) local_types: BTreeMap<String, String>,
    pub(crate) in_conditional: bool,
    pub(crate) ivar_tlet_types: BTreeMap<(String, String), String>,
    pub(crate) signatures: BTreeMap<String, String>,
    pub(crate) tlet_sites: &'a mut Vec<serde_json::Value>,
    pub(crate) dead_nil_checks: &'a mut Vec<serde_json::Value>,
    pub(crate) deterministic_guards: &'a mut Vec<serde_json::Value>,
    pub(crate) return_origins: &'a mut Vec<serde_json::Value>,
    pub(crate) noreturn_methods: &'a mut Vec<serde_json::Value>,
    pub(crate) collection_index_lookups: &'a mut Vec<serde_json::Value>,
    pub(crate) hash_record_blockers: &'a mut Vec<serde_json::Value>,
    pub(crate) type_normalizers: &'a mut Vec<serde_json::Value>,
    pub(crate) rescue_handlers: &'a mut Vec<serde_json::Value>,
    pub(crate) return_usage_sites: &'a mut Vec<serde_json::Value>,
    pub(crate) return_direct_usage_sites: &'a mut Vec<serde_json::Value>,
    pub(crate) hash_record_escape_sites: &'a mut Vec<serde_json::Value>,
    pub(crate) hidden_enum_observations: &'a mut Vec<serde_json::Value>,
    pub(crate) dispatcher_inferences: &'a mut Vec<serde_json::Value>,
    pub(crate) hash_record_member_calls: &'a mut Vec<serde_json::Value>,
    pub(crate) param_origins: &'a mut Vec<serde_json::Value>,
    pub(crate) struct_declarations: &'a mut Vec<StructDeclaration>,
    pub(crate) state_type_records: &'a mut Vec<StateTypeRecord>,
    pub(crate) hash_shapes: &'a mut Vec<HashShape>,
    pub(crate) tuple_arrays: &'a mut Vec<serde_json::Value>,
    pub(crate) local_hash_shapes: BTreeMap<String, serde_json::Value>,
    pub(crate) local_array_shapes: BTreeMap<String, serde_json::Value>,
    pub(crate) local_container_origins: BTreeMap<String, serde_json::Value>,
    pub(crate) ivar_container_origins: BTreeMap<String, serde_json::Value>,
    pub(crate) struct_field_hash_shapes: BTreeMap<(String, String), serde_json::Value>,
    pub(crate) struct_field_array_shapes: BTreeMap<(String, String), serde_json::Value>,
    pub(crate) pre_registered_noreturns: &'a std::collections::HashSet<String>,
    pub(crate) is_prepass: bool,
    pub(crate) method_param_hash_shapes: BTreeMap<(String, String, String), serde_json::Value>,
    pub(crate) method_param_array_shapes: BTreeMap<(String, String, String), serde_json::Value>,
    pub(crate) method_return_hash_shapes: BTreeMap<(String, String), serde_json::Value>,
    pub(crate) method_return_array_shapes: BTreeMap<(String, String), serde_json::Value>,
    pub(crate) inferred_return_types: BTreeMap<(String, String), String>,
    pub(crate) unconditional_vars: BTreeSet<String>,
}

const CORE_RUNTIME_GUARD_CLASSES: &[&str] = &[
    "Array",
    "Hash",
    "Set",
    "String",
    "Symbol",
    "Integer",
    "Float",
    "NilClass",
    "TrueClass",
    "FalseClass",
    "Numeric",
    "Range",
    "Regexp",
    "Time",
];

const CORE_CLASS_CONSTANTS: &[&str] = &[
    "Array",
    "BasicObject",
    "Class",
    "Complex",
    "Encoding",
    "Enumerator",
    "Exception",
    "FalseClass",
    "Fiber",
    "Float",
    "Hash",
    "Integer",
    "Module",
    "NilClass",
    "Numeric",
    "Object",
    "Proc",
    "Range",
    "Rational",
    "Regexp",
    "String",
    "Struct",
    "Symbol",
    "Thread",
    "Time",
    "TrueClass",
];

impl<'a> TypeInferenceVisitor<'a> {
    

    

    

    

    

    

    

    pub(crate) fn visit(&mut self, node: &crate::ast::Node) {
        match node.r#type.as_str() {
            "CLASS" | "MODULE" | "INTERFACE_DECLARATION" => {
                let name = owner_name(node).unwrap_or_else(|| "(anonymous)".to_string());
                let qualified = if self.current_owners.is_empty() {
                    name
                } else {
                    format!("{}::{name}", self.current_owners.join("::"))
                };
                self.current_owners.push(qualified);
                for child in child_nodes(node) {
                    self.visit(child);
                }
                self.current_owners.pop();
            }
            "DEFN" | "DEFS" | "METHOD_SIGNATURE" => {
                let name_symbol = if node.r#type == "DEFS" {
                    child_symbol(node, 1)
                } else {
                    child_symbol(node, 0)
                };
                if let Some(func_name) = name_symbol {
                    let owner = self.current_owners.last().cloned().unwrap_or_default();
                    let kind = if node.r#type == "DEFS" {
                        "class".to_string()
                    } else if !owner.is_empty() {
                        "instance".to_string()
                    } else {
                        "top".to_string()
                    };

                    if let Some(fn_def) = self.document.function_defs.iter().find(|fd| {
                        (fd.name == func_name || (node.r#type == "DEFS" && fd.name == format!("self.{}", func_name)))
                            && (fd.line == node.first_lineno || fd.owner == owner)
                    }) {
                        eprintln!(
                            "TypeInferenceVisitor matched: name={}, owner={}, line={}",
                            func_name, owner, node.first_lineno
                        );
                        let old_method = self.current_method.clone();
                        let old_method_kind = self.current_method_kind.clone();
                        let old_method_line = self.current_method_line;
                        let old_method_end_line = self.current_method_end_line;
                        let old_params = self.current_params.clone();
                        let old_param_types = std::mem::take(&mut self.param_types);
                        let old_local_types = std::mem::take(&mut self.local_types);
                        let old_local_hash_shapes = std::mem::take(&mut self.local_hash_shapes);
                        let old_local_array_shapes = std::mem::take(&mut self.local_array_shapes);
                        let old_local_container_origins = std::mem::take(&mut self.local_container_origins);
                        let old_unconditional_vars = std::mem::take(&mut self.unconditional_vars);
                        let old_in_conditional = self.in_conditional;
 
                        self.current_method = Some(func_name.clone());
                        self.in_conditional = false;
                        self.current_method_kind = kind.clone();
                        self.current_method_line = node.first_lineno;
                        self.current_method_end_line = node.last_lineno;
                        self.current_params = fn_def.params.clone();

                        let fn_key_null = format!("{}\u{0}{}", owner, func_name);
                        let fn_key_colon = if owner.is_empty() {
                            func_name.clone()
                        } else {
                            format!("{}::{}", owner, func_name)
                        };
                        let types_opt = self
                            .document
                            .method_param_types
                            .get(&fn_key_null)
                            .or_else(|| self.document.method_param_types.get(&fn_key_colon))
                            .or_else(|| self.document.method_param_types.get(&func_name));
                        if let Some(types) = types_opt {
                            for (pname, ptype) in types {
                                if useful_type(ptype) {
                                    self.param_types.insert(pname.clone(), ptype.clone());
                                }
                            }
                        }

                        // Populate local_container_origins with method parameters and parameter shapes
                        eprintln!("DEBUG: DEFN/DEFS matched method: {}, current_params: {:?}", func_name, self.current_params);
                        for (idx, param_name) in self.current_params.iter().enumerate() {
                            let origin = json!({
                                "kind": "method parameter",
                                "name": param_name,
                                "path": self.path,
                                "line": node.first_lineno
                            });
                            eprintln!("DEBUG: inserting method parameter origin for {}: {:?}", param_name, origin);
                            self.local_container_origins.insert(param_name.clone(), origin);

                            if let Some(shape) = self.get_method_param_hash_shape(&owner, &func_name, param_name)
                                .or_else(|| self.get_method_param_hash_shape(&owner, &func_name, &idx.to_string()))
                            {
                                self.local_hash_shapes.insert(param_name.clone(), shape);
                            }
                            if let Some(shape) = self.get_method_param_array_shape(&owner, &func_name, param_name)
                                .or_else(|| self.get_method_param_array_shape(&owner, &func_name, &idx.to_string()))
                            {
                                self.local_array_shapes.insert(param_name.clone(), shape);
                            }
                        }

                        let body = child_node(node, if node.r#type == "DEFS" { 2 } else { 1 });
                        if let Some(body_node) = body {
                            self.visit(body_node);

                            if !self.is_prepass {
                                let params_list = self.current_params_json(node);
                                let record = json!({
                                    "path": self.path,
                                    "line": node.first_lineno,
                                    "class": owner,
                                    "method": func_name,
                                    "kind": kind,
                                    "params": params_list,
                                });
                                self.collect_type_normalizers(body_node, &record);
                                self.collect_hidden_enum_observations(body_node, &record);
                                self.inspect_dispatcher(body_node, node.first_lineno);
                            }
                        }

                        let explicit = body
                            .map(|b| {
                                let mut exp = Vec::new();
                                collect_explicit_returns(b, &mut exp);
                                exp
                            })
                            .unwrap_or_default();

                        let implicit_expr = body.and_then(implicit_return_expression);
                        let implicit_present = implicit_expr
                            .map(|expr| expr.r#type != "RETURN")
                            .unwrap_or(false);

                        let mut expressions = explicit.clone();
                        if implicit_present {
                            if let Some(expr) = implicit_expr {
                                expressions.push(expr);
                            }
                        }

                        let mut sources = Vec::new();
                        let mut blockers = BTreeSet::new();
                        for expr in &expressions {
                            sources.extend(self.return_sources_for(expr, body, &mut blockers));
                        }
                        if expressions.is_empty() || sources.is_empty() {
                            blockers.insert("no return expression found".to_string());
                        }

                        let source_types = sources
                            .iter()
                            .filter_map(|s| {
                                s.get("type")
                                    .and_then(Value::as_str)
                                    .map(ToString::to_string)
                            })
                            .collect::<Vec<_>>();

                        let mut candidate = static_sorbet_type(&source_types);
                        if candidate == "NilClass"
                            && sources.iter().any(|s| {
                                matches!(
                                    s.get("kind").and_then(Value::as_str),
                                    Some("call_untyped" | "unknown")
                                )
                            })
                        {
                            candidate = "T.untyped".to_string();
                        }
                        let useful = useful_type(&candidate);
                        let has_untyped_call = sources
                            .iter()
                            .any(|s| s.get("kind").and_then(Value::as_str) == Some("call_untyped"));
                        let confidence = if useful
                            && !weak_type(&candidate)
                            && blockers.is_empty()
                            && !has_untyped_call
                        {
                            "strong"
                        } else if useful {
                            "weak"
                        } else {
                            "blocked"
                        };

                        eprintln!("DEBUG: method={:?}, expressions={:?}", func_name, expressions.iter().map(|e| (&e.r#type, &e.text)).collect::<Vec<_>>());
                        let mut ret_hash_shape = None;
                        for expr in &expressions {
                            if let Some(shape) = self.hash_shape_for_value(expr) {
                                if let Some(existing) = ret_hash_shape {
                                    ret_hash_shape = Some(merge_hash_record_shapes(existing, shape));
                                } else {
                                    ret_hash_shape = Some(shape);
                                }
                            }
                        }
                        if let Some(ref shape) = ret_hash_shape {
                            let key = (owner.clone(), func_name.clone());
                            self.method_return_hash_shapes.insert(key, shape.clone());
                        }

                        let mut ret_array_shape = None;
                        for expr in &expressions {
                            if let Some(shape) = self.array_element_shape_for_value(expr) {
                                if let Some(existing) = ret_array_shape {
                                    ret_array_shape = Some(merge_hash_record_shapes(existing, shape));
                                } else {
                                    ret_array_shape = Some(shape);
                                }
                            }
                        }
                        if let Some(ref shape) = ret_array_shape {
                            let key = (owner.clone(), func_name.clone());
                            self.method_return_array_shapes.insert(key, shape.clone());
                        }

                        if useful {
                            let key = (owner.clone(), func_name.clone());
                            self.inferred_return_types.insert(key, candidate.clone());
                        }

                        if !self.is_prepass {
                            self.return_origins.push(json!({
                                "path": self.path,
                                "line": node.first_lineno,
                                "end_line": node.last_lineno,
                                "class": owner,
                                "method": func_name,
                                "kind": kind,
                                "implicit": explicit.is_empty(),
                                "return_syntax": return_syntax(explicit.is_empty(), implicit_present),
                                "control_shape": return_control_shape(&explicit, implicit_expr, implicit_present),
                                "candidate_type": if useful { &candidate } else { "T.untyped" },
                                "confidence": confidence,
                                "sources": sources,
                                "blockers": blockers.into_iter().collect::<Vec<_>>(),
                                "hash_shape": ret_hash_shape.unwrap_or(Value::Null),
                                "array_element_shape": ret_array_shape.unwrap_or(Value::Null),
                            }));

                            let is_noreturn = !self.has_explicit_return(body)
                                && body.is_some_and(|b| self.noreturn_body(b));
                            if is_noreturn {
                                self.noreturn_methods.push(json!({
                                    "name": func_name,
                                    "path": self.path,
                                    "line": node.first_lineno,
                                    "class": owner,
                                    "kind": kind,
                                }));
                            }
                        }

                        self.current_method = old_method;
                        self.current_method_kind = old_method_kind;
                        self.current_method_line = old_method_line;
                        self.current_method_end_line = old_method_end_line;
                        self.current_params = old_params;
                        self.param_types = old_param_types;
                        self.local_types = old_local_types;
                        self.local_hash_shapes = old_local_hash_shapes;
                        self.local_array_shapes = old_local_array_shapes;
                        self.local_container_origins = old_local_container_origins;
                        self.unconditional_vars = old_unconditional_vars;
                        self.in_conditional = old_in_conditional;
                    }
                }
            }
            "IF" | "UNLESS" => {
                self.inspect_branch_guard(node, node.r#type == "UNLESS");
                let children = child_nodes(node);
                if !children.is_empty() {
                    self.visit(children[0]);
                    
                    let mut then_vars = BTreeSet::new();
                    if let Some(then_node) = children.get(1) {
                        collect_assigned_vars(then_node, &mut then_vars);
                    }
                    let mut else_vars = BTreeSet::new();
                    if let Some(else_node) = children.get(2) {
                        collect_assigned_vars(else_node, &mut else_vars);
                    }
                    let common_vars: BTreeSet<String> = then_vars.intersection(&else_vars).cloned().collect();
                    self.unconditional_vars.extend(common_vars);
                    
                    let before_local_types = self.local_types.clone();
                    let before_hash_shapes = self.local_hash_shapes.clone();
                    let before_array_shapes = self.local_array_shapes.clone();
                    
                    let mut then_local_types = before_local_types.clone();
                    let mut then_hash_shapes = before_hash_shapes.clone();
                    let mut then_array_shapes = before_array_shapes.clone();
                    
                    if let Some(then_node) = children.get(1) {
                        self.local_types = before_local_types.clone();
                        self.local_hash_shapes = before_hash_shapes.clone();
                        self.local_array_shapes = before_array_shapes.clone();
                        
                        let old_cond = self.in_conditional;
                        self.in_conditional = true;
                        self.visit(then_node);
                        self.in_conditional = old_cond;
                        
                        then_local_types = self.local_types.clone();
                        then_hash_shapes = self.local_hash_shapes.clone();
                        then_array_shapes = self.local_array_shapes.clone();
                    }
                    
                    let mut else_local_types = before_local_types.clone();
                    let mut else_hash_shapes = before_hash_shapes.clone();
                    let mut else_array_shapes = before_array_shapes.clone();
                    
                    if let Some(else_node) = children.get(2) {
                        self.local_types = before_local_types.clone();
                        self.local_hash_shapes = before_hash_shapes.clone();
                        self.local_array_shapes = before_array_shapes.clone();
                        
                        let old_cond = self.in_conditional;
                        self.in_conditional = true;
                        self.visit(else_node);
                        self.in_conditional = old_cond;
                        
                        else_local_types = self.local_types.clone();
                        else_hash_shapes = self.local_hash_shapes.clone();
                        else_array_shapes = self.local_array_shapes.clone();
                    }
                    
                    let all_keys: BTreeSet<String> = then_local_types.keys()
                        .chain(else_local_types.keys())
                        .cloned()
                        .collect();
                        
                    let mut merged_local_types = BTreeMap::new();
                    for key in &all_keys {
                        let t_val = then_local_types.get(key);
                        let e_val = else_local_types.get(key);
                        let b_val = before_local_types.get(key);
                        
                        let merged = match (t_val, e_val) {
                            (Some(t), Some(e)) => merge_types(t, e),
                            (Some(t), None) => {
                                if t.starts_with("T.nilable(") {
                                    t.clone()
                                } else {
                                    format!("T.nilable({})", t)
                                }
                            }
                            (None, Some(e)) => {
                                if e.starts_with("T.nilable(") {
                                    e.clone()
                                } else {
                                    format!("T.nilable({})", e)
                                }
                            }
                            _ => unreachable!(),
                        };
                        merged_local_types.insert(key.clone(), merged);
                    }
                    
                    let all_hash_keys: BTreeSet<String> = then_hash_shapes.keys()
                        .chain(else_hash_shapes.keys())
                        .cloned()
                        .collect();
                    let mut merged_hash_shapes = BTreeMap::new();
                    for key in &all_hash_keys {
                        let t_val = then_hash_shapes.get(key);
                        let e_val = else_hash_shapes.get(key);
                        if let (Some(t), Some(e)) = (t_val, e_val) {
                            merged_hash_shapes.insert(key.clone(), merge_hash_record_shapes(t.clone(), e.clone()));
                        }
                    }
                    
                    let all_array_keys: BTreeSet<String> = then_array_shapes.keys()
                        .chain(else_array_shapes.keys())
                        .cloned()
                        .collect();
                    let mut merged_array_shapes = BTreeMap::new();
                    for key in &all_array_keys {
                        let t_val = then_array_shapes.get(key);
                        let e_val = else_array_shapes.get(key);
                        if let (Some(t), Some(e)) = (t_val, e_val) {
                            merged_array_shapes.insert(key.clone(), merge_hash_record_shapes(t.clone(), e.clone()));
                        }
                    }
                    
                    self.local_types = merged_local_types;
                    self.local_hash_shapes = merged_hash_shapes;
                    self.local_array_shapes = merged_array_shapes;
                }
            }
            "AND" | "OR" | "WHILE" | "UNTIL" => {
                let children = child_nodes(node);
                if !children.is_empty() {
                    self.visit(children[0]);
                    let old_cond = self.in_conditional;
                    self.in_conditional = true;
                    for child in children.iter().skip(1) {
                        self.visit(child);
                    }
                    self.in_conditional = old_cond;
                }
            }
            "CASE" => {
                let children = child_nodes(node);
                if !children.is_empty() {
                    self.visit(children[0]);
                    let old_cond = self.in_conditional;
                    self.in_conditional = true;
                    for child in children.iter().skip(1) {
                        self.visit(child);
                    }
                    self.in_conditional = old_cond;
                }
            }
            "WHEN" | "IN" | "RESCUE" | "RESBODY" => {
                let old_cond = self.in_conditional;
                self.in_conditional = true;
                for child in child_nodes(node) {
                    self.visit(child);
                }
                self.in_conditional = old_cond;
            }
            "ITER" => {
                let call_node = child_node(node, 0);
                let block_node = child_node(node, 1);

                let old_local_types = self.local_types.clone();
                let old_local_hash_shapes = self.local_hash_shapes.clone();
                let old_local_array_shapes = self.local_array_shapes.clone();
                let old_local_container_origins = self.local_container_origins.clone();

                let mut args_node = None;
                if let Some(block) = block_node {
                    for child in child_nodes(block) {
                        if child.r#type == "ARGS" {
                            args_node = Some(child);
                            break;
                        }
                    }
                }

                let param_names = if let Some(args) = args_node {
                    collect_block_param_names(args)
                } else {
                    Vec::new()
                };

                if let Some(call) = call_node {
                    if let Some((rec, method, _)) = match_call(call) {
                        if matches!(
                            method.as_str(),
                            "each"
                                | "map"
                                | "collect"
                                | "filter_map"
                                | "select"
                                | "reject"
                                | "find"
                                | "detect"
                                | "any?"
                                | "all?"
                                | "none?"
                                | "one?"
                        ) {
                            if let Some(receiver_type) = self.expression_type(rec) {
                                if let Some(info) = collection_type_info(&receiver_type) {
                                    if info.kind == "hash" {
                                        if let Some(p0) = param_names.get(0) {
                                            if let Some(ref key_ty) = info.element {
                                                if useful_type(key_ty) {
                                                    self.local_types.insert(p0.clone(), key_ty.clone());
                                                }
                                            }
                                        }
                                        if let Some(p1) = param_names.get(1) {
                                            if let Some(ref val_ty) = info.value {
                                                if useful_type(val_ty) {
                                                    self.local_types.insert(p1.clone(), val_ty.clone());
                                                }
                                            }
                                        }
                                    } else {
                                        if let Some(p0) = param_names.get(0) {
                                            if let Some(ref elem_ty) = info.element {
                                                if useful_type(elem_ty) {
                                                    self.local_types.insert(p0.clone(), elem_ty.clone());
                                                }
                                            }
                                        }
                                    }
                                }
                            }

                            if let Some(p0) = param_names.get(0) {
                                if let Some(shape) = self.array_element_shape_for_receiver(Some(rec)) {
                                    self.local_hash_shapes.insert(p0.clone(), shape);
                                }
                                if let Some(origin) = self.container_origin_for_value(rec, p0) {
                                    let kind = origin.get("kind").and_then(serde_json::Value::as_str).unwrap_or("");
                                    if kind == "method parameter" || kind == "instance variable" {
                                        self.local_container_origins.insert(p0.clone(), origin);
                                    }
                                }
                            }
                        }
                    }
                }

                let old_cond = self.in_conditional;
                self.in_conditional = true;
                for child in child_nodes(node) {
                    self.visit(child);
                }
                self.in_conditional = old_cond;

                self.local_types = old_local_types;
                for p in &param_names {
                    if let Some(old_val) = old_local_hash_shapes.get(p) {
                        self.local_hash_shapes.insert(p.clone(), old_val.clone());
                    } else {
                        self.local_hash_shapes.remove(p);
                    }
                    if let Some(old_val) = old_local_array_shapes.get(p) {
                        self.local_array_shapes.insert(p.clone(), old_val.clone());
                    } else {
                        self.local_array_shapes.remove(p);
                    }
                    if let Some(old_val) = old_local_container_origins.get(p) {
                        self.local_container_origins.insert(p.clone(), old_val.clone());
                    } else {
                        self.local_container_origins.remove(p);
                    }
                }
            }
            "CALL" | "QCALL" | "FCALL" | "VCALL" | "OPCALL" | "ATTRASGN" => {
                self.inspect_call_node(node);
                self.inspect_index_lookup(node);
                self.inspect_hash_record_blocker(node);
                self.inspect_hash_record_member_call(node);
                self.inspect_struct_constructor(node);
                self.inspect_class_constructor_fields(node);
                self.inspect_param_origins(node);
                self.inspect_attribute_assignment(node);
                self.check_local_escapes_and_mutations(node);

                if let Some((rec, method, args_node)) = match_call(node) {
                    if rec.r#type == "LVAR" || rec.r#type == "DVAR" {
                        let name = node_symbol(rec).unwrap_or_else(|| rec.text.trim().to_string());
                        let args = call_arguments(args_node);
                        if collection_append_method(&method) {
                            if let Some(arg) = args.first() {
                                if let Some(shape) = self.hash_shape_for_value(arg) {
                                    self.local_array_shapes.insert(name.clone(), shape);
                                }
                                let existing_type = self.local_types.get(&name)
                                    .or_else(|| self.param_types.get(&name))
                                    .cloned();
                                if let Some(existing_type) = existing_type {
                                    if let Some(info) = collection_type_info(&existing_type) {
                                        if info.kind == "array" || info.kind == "set" {
                                            let arg_type = self.expression_type(arg).unwrap_or_else(|| self.behavior.untyped_type());
                                            let new_elem_type = if method == "concat" {
                                                collection_type_info(&arg_type).and_then(|i| i.element).unwrap_or_else(|| self.behavior.untyped_type())
                                            } else {
                                                arg_type
                                            };
                                            let existing_elem = info.element.unwrap_or_else(|| self.behavior.untyped_type());
                                            let merged_elem = merge_types(&existing_elem, &new_elem_type);
                                            let updated_type = if existing_type.starts_with("T::Set") || existing_type.starts_with("Set") {
                                                self.behavior.format_set_type(&merged_elem)
                                            } else {
                                                self.behavior.format_array_type(&merged_elem)
                                            };
                                            if self.param_types.contains_key(&name) {
                                                self.param_types.insert(name.clone(), updated_type);
                                            } else {
                                                self.local_types.insert(name.clone(), updated_type);
                                            }
                                        }
                                    }
                                }
                            }
                        } else if method == "[]=" {
                            if args.len() >= 2 {
                                let key_arg = args[0];
                                let val_arg = args[1];
                                let existing_type = self.local_types.get(&name)
                                    .or_else(|| self.param_types.get(&name))
                                    .cloned();
                                if let Some(existing_type) = existing_type {
                                    if let Some(info) = collection_type_info(&existing_type) {
                                        if info.kind == "hash" {
                                            let key_type = self.expression_type(key_arg).unwrap_or_else(|| self.behavior.untyped_type());
                                            let val_type = self.expression_type(val_arg).unwrap_or_else(|| self.behavior.untyped_type());
                                            let existing_key = info.element.unwrap_or_else(|| self.behavior.untyped_type());
                                            let existing_val = info.value.unwrap_or_else(|| self.behavior.untyped_type());
                                            let merged_key = merge_types(&existing_key, &key_type);
                                            let merged_val = merge_types(&existing_val, &val_type);
                                            let updated_type = self.behavior.format_hash_type(&merged_key, &merged_val);
                                            if self.param_types.contains_key(&name) {
                                                self.param_types.insert(name.clone(), updated_type);
                                            } else {
                                                self.local_types.insert(name.clone(), updated_type);
                                            }
                                        }
                                    }
                                }
                            }
                        } else if method == "merge!" || method == "update" {
                            if let Some(arg) = args.first() {
                                let arg_type = self.expression_type(arg).unwrap_or_else(|| self.behavior.untyped_type());
                                if let Some(arg_info) = collection_type_info(&arg_type) {
                                    if arg_info.kind == "hash" {
                                        let arg_key = arg_info.element.unwrap_or_else(|| self.behavior.untyped_type());
                                        let arg_val = arg_info.value.unwrap_or_else(|| self.behavior.untyped_type());
                                        let existing_type = self.local_types.get(&name)
                                            .or_else(|| self.param_types.get(&name))
                                            .cloned();
                                        if let Some(existing_type) = existing_type {
                                            if let Some(info) = collection_type_info(&existing_type) {
                                                if info.kind == "hash" {
                                                    let existing_key = info.element.unwrap_or_else(|| self.behavior.untyped_type());
                                                    let existing_val = info.value.unwrap_or_else(|| self.behavior.untyped_type());
                                                    let merged_key = merge_types(&existing_key, &arg_key);
                                                    let merged_val = merge_types(&existing_val, &arg_val);
                                                    let updated_type = self.behavior.format_hash_type(&merged_key, &merged_val);
                                                    if self.param_types.contains_key(&name) {
                                                        self.param_types.insert(name.clone(), updated_type);
                                                    } else {
                                                        self.local_types.insert(name.clone(), updated_type);
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

                for child in child_nodes(node) {
                    self.visit(child);
                }
            }
            "LASGN" | "DASGN" | "CASGN" => {
                let mut pushed = false;
                let current_owner = self.current_owners.last().cloned().unwrap_or_default();
                if let Some(owner) = self.behavior.declarative_owner(node, &current_owner) {
                    self.current_owners.push(owner.name);
                    pushed = true;
                }

                if node.r#type == "LASGN" || node.r#type == "DASGN" {
                    if let Some(var_name) = node_symbol(node) {
                        if let Some(val_node) = child_node(node, 1) {
                            let mut resolved_type = None;
                            if let Some((receiver, method, args_node)) = match_call(val_node) {
                                if method == "let" && receiver.text == "T" {
                                    let arg_nodes = call_arguments(args_node);
                                    if let Some(type_node) = arg_nodes.get(1) {
                                        resolved_type = Some(type_node.text.trim().to_string());
                                    }
                                }
                            }
                            if resolved_type.is_none() {
                                resolved_type = self.expression_type(val_node);
                            }
                            if let Some(ty) = resolved_type {
                                if useful_type(&ty) {
                                    let is_conditional = self.in_conditional && !self.unconditional_vars.contains(&var_name);
                                    let ty = if is_conditional {
                                        if ty.starts_with("T.nilable(") {
                                            ty
                                        } else {
                                            format!("T.nilable({})", ty)
                                        }
                                    } else {
                                        ty
                                    };
                                    let merged = if let Some(existing) = self.local_types.get(&var_name) {
                                        merge_types(existing, &ty)
                                    } else {
                                        ty
                                    };
                                    self.local_types.insert(var_name.clone(), merged);
                                }
                            }
                        }
                    }
                    self.update_local_fact(node);
                    self.inspect_local_container_origin(node);
                    self.inspect_ivar_container_origin(node);
                    self.inspect_struct_declaration(node);
                } else {
                    // CASGN
                    self.inspect_ivar_container_origin(node);
                    self.inspect_struct_declaration(node);
                }

                for child in child_nodes(node) {
                    self.visit(child);
                }

                if pushed {
                    self.current_owners.pop();
                }
            }
            "IASGN" | "CVASGN" | "GVASGN" => {
                self.inspect_ivar_container_origin(node);
                self.inspect_struct_declaration(node);
                for child in child_nodes(node) {
                    self.visit(child);
                }
            }
            "ARRAY" | "LIST" => {
                self.check_literal_escapes(node);
                self.inspect_array_literal(node);
                for child in child_nodes(node) {
                    self.visit(child);
                }
            }
            "HASH" => {
                self.check_literal_escapes(node);
                self.inspect_hash_literal(node);
                for child in child_nodes(node) {
                    self.visit(child);
                }
            }
            _ => {
                for child in child_nodes(node) {
                    self.visit(child);
                }
            }
        }
    }

    fn has_explicit_return(&self, body: Option<&crate::ast::Node>) -> bool {
        let Some(b) = body else { return false };
        let mut exp = Vec::new();
        collect_explicit_returns(b, &mut exp);
        !exp.is_empty()
    }

    fn inspect_call_node(&mut self, node: &crate::ast::Node) {
        if self.is_prepass {
            return;
        }
        if node.r#type == "CALL" || node.r#type == "QCALL" {
            if let Some((receiver, method, args_node)) = match_call(node) {
                if method == "let" && receiver.text == "T" {
                    let arg_nodes = call_arguments(args_node);
                    self.tlet_sites.push(json!({
                        "path": self.path,
                        "line": node.first_lineno,
                        "tlet": true,
                        "type": arg_nodes.get(1).map(|arg| arg.text.clone()),
                    }));
                } else if node.r#type == "QCALL" {
                    if self.provably_non_nil(receiver) {
                        self.dead_nil_checks.push(json!({
                            "path": self.path,
                            "line": node.first_lineno,
                            "kind": "safe_nav",
                            "code": node.text.clone(),
                            "reason": format!("{} is provably non-nil", receiver.text),
                        }));
                    }
                } else if self.behavior.is_nil_check(&method) {
                    if self.provably_non_nil(receiver) {
                        self.dead_nil_checks.push(json!({
                            "path": self.path,
                            "line": node.first_lineno,
                            "kind": "nil_check",
                            "code": node.text.clone(),
                            "reason": format!("{} is provably non-nil; .nil? is always false", receiver.text),
                        }));
                    }
                }
            }
        }
    }

    fn provably_non_nil(&self, node: &crate::ast::Node) -> bool {
        if node.r#type == "SELF" {
            return true;
        }
        eprintln!("provably_non_nil: node.type={}, node.text={}, node_symbol={:?}, self.param_types={:?}, self.local_types={:?}",
            node.r#type, node.text, node_symbol(node), self.param_types, self.local_types);
        match node.r#type.as_str() {
            "LVAR" | "DVAR" => {
                if let Some(name) = node_symbol(node) {
                    if let Some(t) = self
                        .param_types
                        .get(&name)
                        .or_else(|| self.local_types.get(&name))
                    {
                        return is_non_nil_type(t);
                    }
                }
            }
            _ => {
                if let Some(ty) = self.static_expression_type(node) {
                    return is_non_nil_type(&ty);
                }
            }
        }
        false
    }

    fn inspect_branch_guard(&mut self, node: &crate::ast::Node, inverted: bool) {
        let Some(predicate) = child_node(node, 0) else {
            return;
        };
        let Some(result) = self.deterministic_predicate_result(predicate) else {
            return;
        };

        let truth = result
            .get("truth_value")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let taken = if inverted { !truth } else { truth };
        let current_class = self.current_owners.last().cloned().unwrap_or_default();
        let current_method = self.current_method.clone().unwrap_or_default();

        self.deterministic_guards.push(json!({
            "path": self.path,
            "line": predicate.first_lineno,
            "class": current_class,
            "method": current_method,
            "code": predicate.text.chars().take(160).collect::<String>(),
            "branch_kind": if inverted { "unless" } else { "if" },
            "truth_value": truth,
            "taken_branch": if taken { "body" } else { "else" },
            "proof_tier": result.get("proof_tier").cloned().unwrap_or_else(|| json!("static_proven")),
            "predicate_kind": result.get("predicate_kind").cloned().unwrap_or(Value::Null),
            "reason": result.get("reason").cloned().unwrap_or(Value::Null),
            "origin_kind": result.get("origin_kind").cloned().unwrap_or(Value::Null),
            "origin_name": result.get("origin_name").cloned().unwrap_or(Value::Null),
        }));
    }

    fn deterministic_predicate_result(&self, node: &crate::ast::Node) -> Option<Value> {
        let node = if node.r#type == "PAREN" {
            child_node(node, 0).unwrap_or(node)
        } else {
            node
        };
        if let Some(literal) = self.literal_truth_value(node) {
            return Some(self.deterministic_guard_result(
                literal,
                "literal",
                format!("{} is a boolean literal", node.text),
                None,
                None,
            ));
        }
        if node.r#type == "CALL" || node.r#type == "QCALL" || node.r#type == "OPCALL" {
            if let Some(result) = self.deterministic_nil_predicate_result(node) {
                return Some(result);
            }
            if let Some(result) = self.deterministic_class_predicate_result(node) {
                return Some(result);
            }
            return self.deterministic_literal_comparison_result(node);
        }
        None
    }

    fn deterministic_guard_result(
        &self,
        truth_value: bool,
        predicate_kind: &str,
        reason: String,
        origin_kind: Option<String>,
        origin_name: Option<String>,
    ) -> Value {
        json!({
            "truth_value": truth_value,
            "proof_tier": "static_proven",
            "predicate_kind": predicate_kind,
            "reason": reason,
            "origin_kind": origin_kind,
            "origin_name": origin_name,
        })
    }

    fn literal_truth_value(&self, node: &crate::ast::Node) -> Option<bool> {
        match node.r#type.as_str() {
            "TRUE" => Some(true),
            "FALSE" => Some(false),
            _ => None,
        }
    }

    fn deterministic_nil_predicate_result(&self, node: &crate::ast::Node) -> Option<Value> {
        let (receiver, method, _) = match_call(node)?;
        if !self.behavior.is_nil_check(&method) {
            return None;
        }
        let (origin_kind, origin_name) = self.predicate_origin(receiver);
        let receiver_type = self.deterministic_guard_subject_type(receiver)?;
        if receiver_type != "NilClass" && !receiver_type.starts_with("T.nilable(") {
            return Some(self.deterministic_guard_result(
                false,
                "nil_check",
                format!(
                    "{} has static type {}; .nil? is always false",
                    receiver.text, receiver_type
                ),
                origin_kind,
                origin_name,
            ));
        }
        if receiver_type == "NilClass" {
            return Some(self.deterministic_guard_result(
                true,
                "nil_check",
                format!(
                    "{} has static type NilClass; .nil? is always true",
                    receiver.text
                ),
                origin_kind,
                origin_name,
            ));
        }
        None
    }

    fn deterministic_class_predicate_result(&self, node: &crate::ast::Node) -> Option<Value> {
        let (receiver, method, args_node) = match_call(node)?;
        if !self.behavior.is_type_guard(&method) {
            return None;
        }
        let arg_nodes = call_arguments(args_node);
        if arg_nodes.len() != 1 {
            return None;
        }
        let arg = arg_nodes[0];
        let class_name = arg.text.trim().to_string();
        if class_name.is_empty() {
            return None;
        }
        let receiver_type = self.deterministic_guard_subject_type(receiver)?;
        let truth =
            self.class_guard_truth(&receiver_type, &class_name, method == "instance_of?")?;
        let (origin_kind, origin_name) = self.predicate_origin(receiver);
        Some(self.deterministic_guard_result(
            truth,
            "class_guard",
            format!(
                "{} has static type {}; {}({}) is always {}",
                receiver.text, receiver_type, method, class_name, truth
            ),
            origin_kind,
            origin_name,
        ))
    }

    fn class_guard_truth(
        &self,
        receiver_type: &str,
        class_name: &str,
        exact: bool,
    ) -> Option<bool> {
        let raw = receiver_type.trim();
        if raw.is_empty()
            || raw == "T.untyped"
            || raw.contains("T.any(")
            || raw.starts_with("T.nilable(")
        {
            return None;
        }
        let normalized = strip_nilable_type(raw);
        let bare = self.bare_class_name(&normalized);
        let wanted = self.bare_class_name(class_name);
        if exact && self.known_disjoint_guard_classes(&bare, &wanted) {
            return Some(false);
        }
        if exact {
            return None;
        }
        if bare == wanted || self.known_guard_subclass(&bare, &wanted) {
            return Some(true);
        }
        if self.known_disjoint_guard_classes(&bare, &wanted) {
            return Some(false);
        }
        None
    }

    fn bare_class_name(&self, type_text: &str) -> String {
        let raw = type_text.trim();
        if raw.starts_with("T::Array") || raw.starts_with("Array") {
            "Array".to_string()
        } else if raw.starts_with("T::Hash") || raw.starts_with("Hash") {
            "Hash".to_string()
        } else if raw.starts_with("T::Set") || raw.starts_with("Set") {
            "Set".to_string()
        } else if raw == "T::Boolean" {
            "T::Boolean".to_string()
        } else {
            raw.trim_start_matches("::")
                .rsplit("::")
                .next()
                .unwrap_or(raw)
                .to_string()
        }
    }

    fn known_guard_subclass(&self, bare: &str, wanted: &str) -> bool {
        (wanted == "Numeric" && matches!(bare, "Integer" | "Float"))
            || (wanted == "T::Boolean" && matches!(bare, "TrueClass" | "FalseClass"))
    }

    fn known_disjoint_guard_classes(&self, bare: &str, wanted: &str) -> bool {
        if bare == wanted {
            return false;
        }
        if self.known_guard_subclass(bare, wanted) || self.known_guard_subclass(wanted, bare) {
            return false;
        }
        if bare == "T::Boolean" && CORE_RUNTIME_GUARD_CLASSES.contains(&wanted) {
            return true;
        }
        if wanted == "T::Boolean" && CORE_RUNTIME_GUARD_CLASSES.contains(&bare) {
            return true;
        }
        CORE_RUNTIME_GUARD_CLASSES.contains(&bare) && CORE_RUNTIME_GUARD_CLASSES.contains(&wanted)
    }

    fn deterministic_literal_comparison_result(&self, node: &crate::ast::Node) -> Option<Value> {
        let (receiver, method, args_node) = match_call(node)?;
        if !matches!(method.as_str(), "==" | "!=" | ">" | ">=" | "<" | "<=") {
            return None;
        }
        let arg_nodes = call_arguments(args_node);
        if arg_nodes.len() != 1 {
            return None;
        }
        let left = self.literal_static_value(receiver);
        let right = self.literal_static_value(arg_nodes[0]);
        if matches!(left, LiteralStaticValue::Unknown)
            || matches!(right, LiteralStaticValue::Unknown)
        {
            return None;
        }
        let truth = self.compare_literal_values(&left, &right, &method)?;
        Some(self.deterministic_guard_result(
            truth,
            "literal_comparison",
            format!(
                "{} {} {} is always {}",
                receiver.text, method, arg_nodes[0].text, truth
            ),
            None,
            None,
        ))
    }

    fn deterministic_guard_subject_type(&self, node: &crate::ast::Node) -> Option<String> {
        match node.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name = node_symbol(node)?;
                self.param_types
                    .get(&name)
                    .cloned()
                    .or_else(|| self.local_types.get(&name).cloned())
            }
            "IVAR" => {
                let name = node_symbol(node)?;
                self.ivar_expression_type(&name)
            }
            _ => self.static_expression_type(node),
        }
    }

    fn literal_static_value(&self, node: &crate::ast::Node) -> LiteralStaticValue {
        match node.r#type.as_str() {
            "STR" | "STRING" | "STRING_LITERAL" => LiteralStaticValue::String(unquote(&node.text)),
            "SYM" | "SYMBOL" => {
                LiteralStaticValue::Symbol(node.text.trim_start_matches(':').to_string())
            }
            "LIT" => {
                let text = node.text.trim();
                if text.starts_with(':') {
                    LiteralStaticValue::Symbol(text.trim_start_matches(':').to_string())
                } else if let Ok(i) = text.parse::<i64>() {
                    LiteralStaticValue::Integer(i)
                } else if text.parse::<f64>().is_ok() {
                    LiteralStaticValue::Float(text.to_string())
                } else {
                    LiteralStaticValue::Unknown
                }
            }
            "INT" | "INTEGER" | "NUM" | "NUMBER" => node
                .text
                .parse::<i64>()
                .map(LiteralStaticValue::Integer)
                .unwrap_or(LiteralStaticValue::Unknown),
            "FLOAT" => LiteralStaticValue::Float(node.text.clone()),
            "TRUE" => LiteralStaticValue::Bool(true),
            "FALSE" => LiteralStaticValue::Bool(false),
            "NIL" => LiteralStaticValue::Nil,
            _ => LiteralStaticValue::Unknown,
        }
    }

    fn compare_literal_values(
        &self,
        left: &LiteralStaticValue,
        right: &LiteralStaticValue,
        op: &str,
    ) -> Option<bool> {
        match op {
            "==" => Some(self.literal_values_equal(left, right)),
            "!=" => Some(!self.literal_values_equal(left, right)),
            ">" | ">=" | "<" | "<=" => {
                let left = self.literal_numeric_value(left)?;
                let right = self.literal_numeric_value(right)?;
                match op {
                    ">" => Some(left > right),
                    ">=" => Some(left >= right),
                    "<" => Some(left < right),
                    _ => Some(left <= right),
                }
            }
            _ => None,
        }
    }

    fn predicate_origin(&self, node: &crate::ast::Node) -> (Option<String>, Option<String>) {
        match node.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name = node_symbol(node).unwrap_or_default();
                if self.current_params.contains(&name) {
                    return (Some("param".to_string()), Some(name));
                }
                return (Some("local".to_string()), Some(name));
            }
            "IVAR" => {
                return (
                    Some("ivar".to_string()),
                    Some(node_symbol(node).unwrap_or_default()),
                )
            }
            "CALL" | "QCALL" => {
                let (_, method, args_node) =
                    match_call(node).unwrap_or((node, String::new(), node));
                let arg_nodes = call_arguments(args_node);
                if arg_nodes.is_empty() {
                    return (Some("attr".to_string()), Some(method));
                }
                return (Some("call".to_string()), Some(method));
            }
            "VCALL" => {
                let name = node_symbol(node).unwrap_or_default();
                return (Some("attr".to_string()), Some(name));
            }
            "FCALL" => {
                let name = node_symbol(node).unwrap_or_default();
                return (Some("call".to_string()), Some(name));
            }
            _ => {}
        }
        (None, None)
    }

    fn literal_values_equal(&self, left: &LiteralStaticValue, right: &LiteralStaticValue) -> bool {
        match (left, right) {
            (LiteralStaticValue::String(left), LiteralStaticValue::String(right)) => left == right,
            (LiteralStaticValue::Symbol(left), LiteralStaticValue::Symbol(right)) => left == right,
            (LiteralStaticValue::Integer(left), LiteralStaticValue::Integer(right)) => {
                left == right
            }
            (LiteralStaticValue::Float(left), LiteralStaticValue::Float(right)) => left == right,
            (LiteralStaticValue::Bool(left), LiteralStaticValue::Bool(right)) => left == right,
            (LiteralStaticValue::Nil, LiteralStaticValue::Nil) => true,
            _ => false,
        }
    }

    fn literal_numeric_value(&self, value: &LiteralStaticValue) -> Option<f64> {
        match value {
            LiteralStaticValue::Integer(value) => Some(*value as f64),
            LiteralStaticValue::Float(value) => value.parse::<f64>().ok(),
            _ => None,
        }
    }

    fn hash_shape_index_type_readonly_with_shapes(
        &self,
        receiver: &crate::ast::Node,
        index: &crate::ast::Node,
        extra_hash_shapes: &std::collections::BTreeMap<String, serde_json::Value>,
    ) -> Option<String> {
        let shape = match receiver.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name = node_symbol(receiver)?;
                extra_hash_shapes.get(&name).cloned()
                    .or_else(|| self.local_hash_shapes.get(&name).cloned())?
            }
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                let (class_name, method, _) = self.get_call_info(receiver)?;
                self.method_return_hash_shape_for_call(&class_name, &method)?
            }
            _ => return None,
        };
        if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
            return None;
        }
        let key = hash_key_name(index)?;
        let types = shape
            .get("keys")
            .and_then(|keys| keys.get(&key))
            .and_then(Value::as_array)?
            .iter()
            .filter_map(Value::as_str)
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        if types.is_empty() {
            return None;
        }
        let value = static_sorbet_type(&types);
        if useful_type(&value) {
            Some(self.behavior.format_nilable_type(&value))
        } else {
            None
        }
    }

    fn hash_shape_for_value_readonly(
        &self,
        value: &crate::ast::Node,
        extra_hash_shapes: &std::collections::BTreeMap<String, serde_json::Value>,
    ) -> Option<Value> {
        match value.r#type.as_str() {
            "LASGN" | "DASGN" | "IASGN" | "CASGN" | "CVASGN" | "GVASGN" | "ATTRASGN" => {
                let val_node = if value.r#type == "ATTRASGN" {
                    child_node(value, 2).and_then(|args| child_nodes(args).last().copied())
                } else {
                    child_node(value, 1)
                };
                val_node.and_then(|val| self.hash_shape_for_value_readonly(val, extra_hash_shapes))
            }
            "HASH" => {
                let mut keys = serde_json::Map::new();
                let mut value_hash_shapes = serde_json::Map::new();
                let mut value_array_shapes = serde_json::Map::new();
                let mut poisoned = false;
                for pair in child_nodes(value) {
                    if pair.r#type == "pair" || pair.r#type == "PAIR" || pair.r#type == "HASH" {
                        let Some(key_node) = child_node(pair, 0) else {
                            continue;
                        };
                        let Some(value_node) = child_node(pair, 1) else {
                            continue;
                        };
                        if let Some(key) = hash_key_name(key_node) {
                            let ty = self
                                .expression_type(value_node)
                                .unwrap_or_else(|| "T.untyped".to_string());
                            let typed_value = useful_type(&ty) || ty == "NilClass";
                            let shape_type = if typed_value {
                                ty.clone()
                            } else {
                                "T.untyped".to_string()
                            };
                            let entry = keys.entry(key.clone()).or_insert_with(|| json!([]));
                            let array = entry.as_array_mut().unwrap();
                            if !array
                                .iter()
                                .any(|entry| entry.as_str() == Some(&shape_type))
                            {
                                array.push(json!(shape_type));
                            }
                            if typed_value {
                                if let Some(nested) = self.hash_shape_for_value_readonly(value_node, extra_hash_shapes) {
                                    value_hash_shapes.insert(key.clone(), nested);
                                }
                                if let Some(nested) = self.array_element_shape_for_value_readonly(value_node, extra_hash_shapes)
                                {
                                    value_array_shapes.insert(key, nested);
                                }
                            }
                        } else {
                            poisoned = true;
                        }
                    }
                }
                Some(json!({
                    "keys": keys,
                    "value_hash_shapes": value_hash_shapes,
                    "value_array_element_shapes": value_array_shapes,
                    "poisoned": poisoned,
                }))
            }
            "LVAR" | "DVAR" => {
                let name = node_symbol(value).unwrap_or_else(|| value.text.trim().to_string());
                extra_hash_shapes.get(&name).cloned()
                    .or_else(|| self.local_hash_shapes.get(&name).cloned())
            }
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some((class_name, method, args_node)) = self.get_call_info(value) {
                    if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        if let Some((rec, _, _)) = match_call(value) {
                            if (self.behavior.is_type_normalizer(&rec.text, &method)
                                || self.behavior.is_type_cast(&rec.text, &method))
                            {
                                let arg_nodes = call_arguments(args_node);
                                return arg_nodes
                                    .first()
                                    .and_then(|arg| self.hash_shape_for_value_readonly(arg, extra_hash_shapes));
                            } else if matches!(method.as_str(), "first" | "last" | "shift" | "pop" | "sample" | "[]" | "at") {
                                return self.array_element_shape_for_receiver_readonly(Some(rec), extra_hash_shapes);
                            }
                        }
                    }
                    if let Some(shape) = self.method_return_hash_shape_for_call(&class_name, &method) {
                        Some(shape)
                    } else if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        self.struct_field_hash_shape_for_call(value)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn array_element_shape_for_value_readonly(
        &self,
        value: &crate::ast::Node,
        extra_hash_shapes: &std::collections::BTreeMap<String, serde_json::Value>,
    ) -> Option<Value> {
        match value.r#type.as_str() {
            "LASGN" | "DASGN" | "IASGN" | "CASGN" | "CVASGN" | "GVASGN" | "ATTRASGN" => {
                let val_node = if value.r#type == "ATTRASGN" {
                    child_node(value, 2).and_then(|args| child_nodes(args).last().copied())
                } else {
                    child_node(value, 1)
                };
                val_node.and_then(|val| self.array_element_shape_for_value_readonly(val, extra_hash_shapes))
            }
            "ARRAY" | "LIST" => {
                let shapes = child_nodes(value)
                    .into_iter()
                    .filter_map(|elem| self.hash_shape_for_value_readonly(elem, extra_hash_shapes))
                    .collect::<Vec<_>>();
                if shapes.is_empty() {
                    None
                } else {
                    shapes.into_iter().reduce(merge_hash_record_shapes)
                }
            }
            "LVAR" | "DVAR" => {
                let name = node_symbol(value).unwrap_or_else(|| value.text.trim().to_string());
                extra_hash_shapes.get(&name).cloned()
                    .or_else(|| self.local_array_shapes.get(&name).cloned())
            }
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some((class_name, method, args_node)) = self.get_call_info(value) {
                    if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        if let Some((rec, _, _)) = match_call(value) {
                            if (self.behavior.is_type_normalizer(&rec.text, &method)
                                || self.behavior.is_type_cast(&rec.text, &method))
                            {
                                let arg_nodes = call_arguments(args_node);
                                return arg_nodes
                                    .first()
                                    .and_then(|arg| self.array_element_shape_for_value_readonly(arg, extra_hash_shapes));
                            } else if matches!(method.as_str(), "first" | "last" | "shift" | "pop" | "sample" | "[]" | "at") {
                                return self.array_element_shape_for_receiver_readonly(Some(rec), extra_hash_shapes);
                            }
                        }
                    }
                    if let Some(shape) = self.method_return_array_shape_for_call(&class_name, &method) {
                        Some(shape)
                    } else if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        self.struct_field_array_shape_for_call(value)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            "ITER" => {
                if let Some(call_node) = child_node(value, 0) {
                    if let Some((_, method, _)) = match_call(call_node) {
                        if method == "map" || method == "collect" {
                            let mut p0_name = None;
                            if let Some(block) = child_node(value, 1) {
                                let mut args_node = None;
                                for child in child_nodes(&block) {
                                    if child.r#type == "ARGS" {
                                        args_node = Some(child);
                                        break;
                                    }
                                }
                                if let Some(args) = args_node {
                                    let param_names = collect_block_param_names(&args);
                                    if let Some(p0) = param_names.get(0) {
                                        p0_name = Some(p0.clone());
                                    }
                                }
                            }
                            let mut next_hash_shapes = extra_hash_shapes.clone();
                            if let Some(ref p0) = p0_name {
                                if let Some((rec, _, _)) = match_call(call_node) {
                                    if let Some(shape) = self.array_element_shape_for_receiver_readonly(Some(rec), extra_hash_shapes) {
                                        next_hash_shapes.insert(p0.clone(), shape);
                                    }
                                }
                            }

                            let mut res = None;
                            if let Some(body_node) = child_nodes(value).last() {
                                let body_expr = implicit_return_expression(body_node).unwrap_or(body_node);
                                res = self.hash_shape_for_value_readonly(body_expr, &next_hash_shapes);
                            }
                            res
                        } else {
                            None
                        }
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn array_element_shape_for_receiver_readonly(
        &self,
        receiver: Option<&crate::ast::Node>,
        extra_hash_shapes: &std::collections::BTreeMap<String, serde_json::Value>,
    ) -> Option<Value> {
        let receiver = receiver?;
        if receiver.r#type == "ITER" {
            if let Some(call) = child_node(receiver, 0) {
                if let Some((_, method, _)) = match_call(call) {
                    if method == "map" || method == "collect" || method == "filter_map" {
                        if let Some(body_node) = child_nodes(receiver).last() {
                            let body_expr = implicit_return_expression(body_node).unwrap_or(body_node);
                            return self.hash_shape_for_value_readonly(body_expr, extra_hash_shapes);
                        }
                    }
                }
            }
            return child_node(receiver, 0).and_then(|c| self.array_element_shape_for_receiver_readonly(Some(c), extra_hash_shapes));
        }
        match receiver.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name =
                    node_symbol(receiver).unwrap_or_else(|| receiver.text.trim().to_string());
                extra_hash_shapes.get(&name).cloned()
                    .or_else(|| self.local_array_shapes.get(&name).cloned())
            }
            "ARRAY" | "LIST" => self.array_element_shape_for_value_readonly(receiver, extra_hash_shapes),
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some((class_name, method, args_node)) = self.get_call_info(receiver) {
                    if receiver.r#type != "FCALL" && receiver.r#type != "VCALL" {
                        if let Some((rec, _, _)) = match_call(receiver) {
                            if (self.behavior.is_type_normalizer(&rec.text, &method)
                                || self.behavior.is_type_cast(&rec.text, &method))
                            {
                                let arg_nodes = call_arguments(args_node);
                                return arg_nodes
                                    .first()
                                    .and_then(|arg| self.array_element_shape_for_receiver_readonly(Some(arg), extra_hash_shapes));
                            } else if matches!(method.as_str(), "select" | "reject" | "compact") {
                                return self.array_element_shape_for_receiver_readonly(Some(rec), extra_hash_shapes);
                            }
                        }
                    }
                    if let Some(shape) = self.method_return_array_shape_for_call(&class_name, &method) {
                        Some(shape)
                    } else if receiver.r#type != "FCALL" && receiver.r#type != "VCALL" {
                        self.struct_field_array_shape_for_call(receiver)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn ivar_expression_type(&self, name: &str) -> Option<String> {
        let current_class = self.current_owners.last()?;
        let mut class_chain = current_class.split("::").collect::<Vec<_>>();
        while !class_chain.is_empty() {
            let candidate = class_chain.join("::");
            println!("Checking ivar {:?} for {:?}", name, candidate);
            if let Some(type_text) = self.ivar_tlet_types.get(&(candidate, name.to_string())) {
                println!("Found type_text {:?}", type_text);
                if useful_type(type_text) {
                    return Some(type_text.clone());
                }
            }
            class_chain.pop();
        }
        None
    }

    fn hash_shape_index_type_readonly(
        &self,
        receiver: &crate::ast::Node,
        index: &crate::ast::Node,
    ) -> Option<String> {
        self.hash_shape_index_type_readonly_with_shapes(receiver, index, &std::collections::BTreeMap::new())
    }

    fn expression_type(&self, node: &crate::ast::Node) -> Option<String> {
        self.expression_type_with_locals(node, &std::collections::BTreeMap::new())
    }

    fn expression_type_with_locals(
        &self,
        node: &crate::ast::Node,
        extra_locals: &std::collections::BTreeMap<String, String>,
    ) -> Option<String> {
        self.expression_type_with_locals_and_shapes(node, extra_locals, &std::collections::BTreeMap::new())
    }

    fn expression_type_with_locals_and_shapes(
        &self,
        node: &crate::ast::Node,
        extra_locals: &std::collections::BTreeMap<String, String>,
        extra_hash_shapes: &std::collections::BTreeMap<String, serde_json::Value>,
    ) -> Option<String> {
        match node.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name = node_symbol(node)?;
                extra_locals
                    .get(&name)
                    .or_else(|| self.param_types.get(&name))
                    .or_else(|| self.local_types.get(&name))
                    .cloned()
                    .or_else(|| {
                        if self.local_hash_shapes.contains_key(&name) {
                            Some(self.behavior.untyped_hash_type())
                        } else if self.local_array_shapes.contains_key(&name) {
                            Some(self.behavior.untyped_array_type())
                        } else {
                            None
                        }
                    })
            }
            "IVAR" => {
                let name = node_symbol(node)?;
                self.ivar_expression_type(&name)
            }
            "OR" | "AND" => {
                let left = child_node(node, 0).and_then(|c| self.expression_type_with_locals_and_shapes(c, extra_locals, extra_hash_shapes));
                let right = child_node(node, 1).and_then(|c| self.expression_type_with_locals_and_shapes(c, extra_locals, extra_hash_shapes));
                let mut non_nil = Vec::new();
                if let Some(ref l) = left {
                    if l != "NilClass" {
                        non_nil.push(l.clone());
                    }
                }
                if let Some(ref r) = right {
                    if r != "NilClass" {
                        non_nil.push(r.clone());
                    }
                }
                let mut normalized = non_nil
                    .iter()
                    .map(|ty| strip_nilable_type(ty))
                    .collect::<Vec<_>>();
                normalized.sort();
                normalized.dedup();
                if normalized.len() == 1 && useful_type(&normalized[0]) {
                    return Some(normalized[0].clone());
                }

                if left == right && left.as_ref().is_some_and(|l| useful_type(l)) {
                    return left;
                }
                None
            }
            _ => self.static_expression_type_with_locals_and_shapes(node, extra_locals, extra_hash_shapes),
        }
    }

    fn static_expression_type(&self, node: &crate::ast::Node) -> Option<String> {
        self.static_expression_type_with_locals(node, &std::collections::BTreeMap::new())
    }

    fn static_expression_type_with_locals(
        &self,
        node: &crate::ast::Node,
        extra_locals: &std::collections::BTreeMap<String, String>,
    ) -> Option<String> {
        self.static_expression_type_with_locals_and_shapes(node, extra_locals, &std::collections::BTreeMap::new())
    }

    fn static_expression_type_with_locals_and_shapes(
        &self,
        node: &crate::ast::Node,
        extra_locals: &std::collections::BTreeMap<String, String>,
        extra_hash_shapes: &std::collections::BTreeMap<String, serde_json::Value>,
    ) -> Option<String> {
        let is_iter = node.r#type == "ITER";
        let call_node = if is_iter {
            child_node(node, 0).unwrap_or(node)
        } else {
            node
        };
        if call_node.r#type == "CALL" || call_node.r#type == "QCALL" || call_node.r#type == "FCALL" || call_node.r#type == "VCALL" || call_node.r#type == "OPCALL" {
            let callee = match call_node.r#type.as_str() {
                "VCALL" | "FCALL" => node_symbol(call_node).unwrap_or_default(),
                "CALL" | "QCALL" | "OPCALL" => {
                    let (_, method, _) = match_call(call_node).unwrap_or((call_node, String::new(), call_node));
                    method
                }
                _ => String::new(),
            };
            let receiver = if call_node.r#type == "CALL" || call_node.r#type == "QCALL" || call_node.r#type == "OPCALL" {
                child_node(call_node, 0)
            } else {
                None
            };
            let receiver_type = receiver.and_then(|r| self.expression_type_with_locals_and_shapes(r, extra_locals, extra_hash_shapes));
            if is_iter {
                println!("DEBUG static_expression_type ITER: callee={}, receiver_type={:?}", callee, receiver_type);
                let block_node = child_node(node, 1);
                let mut args_node = None;
                if let Some(block) = block_node {
                    for child in child_nodes(block) {
                        if child.r#type == "ARGS" {
                            args_node = Some(child);
                            break;
                        }
                    }
                }
                let param_names = if let Some(args) = args_node {
                    collect_block_param_names(args)
                } else {
                    Vec::new()
                };
                let mut next_locals = extra_locals.clone();
                if let Some(ref receiver_type) = receiver_type {
                    if let Some(info) = collection_type_info(receiver_type) {
                        if info.kind == "hash" {
                            if let Some(p0) = param_names.get(0) {
                                if let Some(key_ty) = info.element.as_ref() {
                                    if useful_type(key_ty) {
                                        next_locals.insert(p0.clone(), key_ty.clone());
                                    }
                                }
                            }
                            if let Some(p1) = param_names.get(1) {
                                if let Some(val_ty) = info.value.as_ref() {
                                    if useful_type(val_ty) {
                                        next_locals.insert(p1.clone(), val_ty.clone());
                                    }
                                }
                            }
                        } else {
                            if let Some(p0) = param_names.get(0) {
                                if let Some(elem_ty) = info.element.as_ref() {
                                    if useful_type(elem_ty) {
                                        next_locals.insert(p0.clone(), elem_ty.clone());
                                    }
                                }
                            }
                        }
                    }
                }

                if callee == "map" || callee == "collect" || callee == "filter_map" {
                    if let Some(body_node) = child_nodes(node).last() {
                        let body_expr = implicit_return_expression(body_node).unwrap_or(body_node);
                        
                        let mut next_hash_shapes = extra_hash_shapes.clone();
                        if let Some(p0) = param_names.get(0) {
                            if let Some(rec) = receiver {
                                if let Some(shape) = self.array_element_shape_for_receiver_readonly(Some(rec), extra_hash_shapes) {
                                    next_hash_shapes.insert(p0.clone(), shape);
                                }
                            }
                        }

                        if let Some(block_return_type) = self.expression_type_with_locals_and_shapes(body_expr, &next_locals, &next_hash_shapes) {
                            println!("DEBUG static_expression_type ITER map/collect block_return_type={:?}", block_return_type);
                            if callee == "filter_map" {
                                let inner = block_return_type
                                    .trim_start_matches("T.nilable(")
                                    .trim_end_matches(')');
                                return Some(self.behavior.format_array_type(inner));
                            } else {
                                return Some(self.behavior.format_array_type(&block_return_type));
                            }
                        }
                    }
                }
                if callee == "select" || callee == "reject" || callee == "filter" || callee == "each" || callee == "each_pair" || callee == "each_key" || callee == "each_value" {
                    if let Some(ref r_ty) = receiver_type {
                        println!("DEBUG static_expression_type ITER returning receiver_type={:?}", r_ty);
                        return Some(r_ty.clone());
                    }
                }
            }
            if callee == "[]" || callee == "fetch" {
                if let Some(receiver) = receiver {
                    if let Some((_, _, args_node)) = match_call(call_node) {
                        let args = call_arguments(args_node);
                        if args.len() == 1 {
                            if let Some(shape_type) = self.hash_shape_index_type_readonly_with_shapes(receiver, args[0], extra_hash_shapes) {
                                return Some(shape_type);
                            }
                        }
                    }
                }
            }
            let class_name = if call_node.r#type == "CALL" || call_node.r#type == "QCALL" || call_node.r#type == "OPCALL" {
                receiver_type.clone().unwrap_or_default()
            } else {
                self.current_owners.last().cloned().unwrap_or_default()
            };
            let class_name = class_name.replace("T.nilable(", "").replace(")", "");
            let key = (class_name, callee.clone());
            if let Some(ty) = self.inferred_return_types.get(&key) {
                return Some(ty.clone());
            }

            if let Some(ty) = self.behavior.static_call_return_type(node, &callee, receiver_type.as_deref()) {
                return Some(ty);
            }
            if let Some(ty) = self.behavior.static_return_type(&callee, receiver_type.as_deref()) {
                return Some(ty);
            }
            if let Some(ty) = self.behavior.propagated_collection_return_type(&callee, receiver_type.as_deref()) {
                return Some(ty);
            }
        }
        self.constant_expression_type(node)
            .or_else(|| self.literal_type(node))
    }

    fn constant_expression_type(&self, node: &crate::ast::Node) -> Option<String> {
        if node.r#type == "CONST" || node.r#type == "COLON2" || node.r#type == "COLON3" {
            let name = node.text.trim().to_string();
            if !name.is_empty() {
                let bare = name.trim_start_matches("::").to_string();
                if CORE_CLASS_CONSTANTS.contains(&bare.as_str())
                    || self.document.type_aliases.contains_key(&bare)
                {
                    return Some(format!("T.class_of({name})"));
                }
            }
        }
        None
    }

    fn literal_array_element_type(&self, node: &crate::ast::Node) -> Option<String> {
        let mut merged: Option<String> = None;
        for child in child_nodes(node) {
            let child_ty = self.expression_type(child).unwrap_or_else(|| self.behavior.untyped_type());
            if let Some(ref m) = merged {
                merged = Some(merge_types(m, &child_ty));
            } else {
                merged = Some(child_ty);
            }
        }
        merged
    }

    fn literal_hash_element_types(&self, node: &crate::ast::Node) -> (Option<String>, Option<String>) {
        let children = child_nodes(node);
        let mut key_merged: Option<String> = None;
        let mut val_merged: Option<String> = None;
        let has_pair_nodes = children.first().map(|c| c.r#type == "pair" || c.r#type == "PAIR" || c.r#type == "HASH").unwrap_or(false);
        if has_pair_nodes {
            for pair in children {
                if pair.r#type == "pair" || pair.r#type == "PAIR" || pair.r#type == "HASH" {
                    let Some(key_node) = child_node(pair, 0) else { continue; };
                    let Some(value_node) = child_node(pair, 1) else { continue; };
                    let mut key_ty = self.expression_type(key_node).unwrap_or_else(|| self.behavior.untyped_type());
                    if key_ty == self.behavior.untyped_type() {
                        let text = key_node.text.trim();
                        if key_node.r#type == "label" 
                            || key_node.r#type == "hash_key_symbol" 
                            || key_node.r#type == "LIT" && !text.starts_with('"') && !text.starts_with('\'') && !text.parse::<f64>().is_ok()
                        {
                            key_ty = "Symbol".to_string();
                        }
                    }
                    let val_ty = self.expression_type(value_node).unwrap_or_else(|| self.behavior.untyped_type());
                    
                    if let Some(ref k) = key_merged {
                        key_merged = Some(merge_types(k, &key_ty));
                    } else {
                        key_merged = Some(key_ty);
                    }
                    
                    if let Some(ref v) = val_merged {
                        val_merged = Some(merge_types(v, &val_ty));
                    } else {
                        val_merged = Some(val_ty);
                    }
                }
            }
        } else {
            for chunk in children.chunks(2) {
                if chunk.len() == 2 {
                    let key_node = chunk[0];
                    let value_node = chunk[1];
                    let mut key_ty = self.expression_type(key_node).unwrap_or_else(|| self.behavior.untyped_type());
                    if key_ty == self.behavior.untyped_type() {
                        let text = key_node.text.trim();
                        if key_node.r#type == "label" 
                            || key_node.r#type == "hash_key_symbol" 
                            || key_node.r#type == "LIT" && !text.starts_with('"') && !text.starts_with('\'') && !text.parse::<f64>().is_ok()
                        {
                            key_ty = "Symbol".to_string();
                        }
                    }
                    let val_ty = self.expression_type(value_node).unwrap_or_else(|| self.behavior.untyped_type());
                    
                    if let Some(ref k) = key_merged {
                        key_merged = Some(merge_types(k, &key_ty));
                    } else {
                        key_merged = Some(key_ty);
                    }
                    
                    if let Some(ref v) = val_merged {
                        val_merged = Some(merge_types(v, &val_ty));
                    } else {
                        val_merged = Some(val_ty);
                    }
                }
            }
        }
        (key_merged, val_merged)
    }

    fn literal_type(&self, node: &crate::ast::Node) -> Option<String> {
        match node.r#type.as_str() {
            "STR" | "DSTR" | "STRING" | "STRING_LITERAL" => Some("String".to_string()),
            "SYM" | "SYMBOL" | "hash_key_symbol" | "label" => Some("Symbol".to_string()),
            "LIT" => {
                let text = node.text.trim();
                if text.starts_with(':') {
                    Some("Symbol".to_string())
                } else if text.starts_with('"') || text.starts_with('\'') {
                    Some("String".to_string())
                } else if text.parse::<i64>().is_ok() {
                    Some("Integer".to_string())
                } else if text.parse::<f64>().is_ok() {
                    Some("Float".to_string())
                } else {
                    None
                }
            }
            "INT" | "INTEGER" | "NUM" | "NUMBER" => Some("Integer".to_string()),
            "FLOAT" => Some("Float".to_string()),
            "TRUE" | "FALSE" => Some("T::Boolean".to_string()),
            "NIL" => Some("NilClass".to_string()),
            "RANGE" | "DOT2" | "DOT3" => Some("Range".to_string()),
            "ARRAY" | "LIST" => {
                if let Some(elem_ty) = self.literal_array_element_type(node) {
                    Some(self.behavior.format_array_type(&elem_ty))
                } else {
                    Some(self.behavior.untyped_array_type())
                }
            }
            "ZLIST" => Some(self.behavior.untyped_array_type()),
            "HASH" => {
                let (key_ty, val_ty) = self.literal_hash_element_types(node);
                let k = key_ty.unwrap_or_else(|| self.behavior.untyped_type());
                let v = val_ty.unwrap_or_else(|| self.behavior.untyped_type());
                Some(self.behavior.format_hash_type(&k, &v))
            }
            "CALL" | "QCALL" => {
                if let Some((receiver, method, _)) = match_call(node) {
                    if method == "new" {
                        return Some(receiver.text.clone());
                    }
                }
                None
            }
            _ => None,
        }
    }

    fn known_return_type(&self, name: &str) -> Option<String> {
        if let Some(ty) = self.behavior.known_return_type(name) {
            return Some(ty);
        }
        let suffix = format!("\u{0}{}", name);
        for (key, sig) in &self.signatures {
            if key.ends_with(&suffix) {
                if let Some(ret) = extract_return_type(sig) {
                    return Some(ret);
                }
            }
        }
        None
    }

    fn noreturn_body(&self, node: &crate::ast::Node) -> bool {
        match node.r#type.as_str() {
            "BLOCK" | "STATEMENTS" | "BEGIN" | "ELSE" | "PAREN" | "SCOPE" | "ROOT" => {
                implicit_return_expression(node)
                    .map(|inner| self.noreturn_body(inner))
                    .unwrap_or(false)
            }
            "IF" | "UNLESS" => {
                let then_br = child_node(node, 1).and_then(implicit_return_expression);
                let else_br = child_node(node, 2).and_then(implicit_return_expression);
                then_br
                    .map(|inner| self.noreturn_body(inner))
                    .unwrap_or(false)
                    && else_br
                        .map(|inner| self.noreturn_body(inner))
                        .unwrap_or(false)
            }
            "CASE" | "CASE2" => {
                let when_arms = node
                    .children
                    .iter()
                    .filter_map(crate::ast::node)
                    .filter(|child| child.r#type == "WHEN" || child.r#type == "IN");
                let mut all_noreturn = true;
                let mut has_when = false;
                for arm in when_arms {
                    has_when = true;
                    let arm_body = child_node(arm, 1).and_then(implicit_return_expression);
                    if !arm_body
                        .map(|inner| self.noreturn_body(inner))
                        .unwrap_or(false)
                    {
                        all_noreturn = false;
                        break;
                    }
                }
                let else_br = node
                    .children
                    .iter()
                    .filter_map(crate::ast::node)
                    .find(|child| {
                        child.r#type != "WHEN"
                            && child.r#type != "IN"
                            && child.r#type != "CASE_EXPR"
                    });
                let else_noreturn = else_br
                    .and_then(implicit_return_expression)
                    .map(|inner| self.noreturn_body(inner))
                    .unwrap_or(false);
                has_when && all_noreturn && else_noreturn
            }
            "RESCUE" => child_nodes(node)
                .iter()
                .all(|child| self.noreturn_body(child)),
            "CALL" | "QCALL" | "FCALL" | "VCALL" | "OPCALL" => self.noreturn_call(node),
            _ => false,
        }
    }

    fn noreturn_call(&self, node: &crate::ast::Node) -> bool {
        let name = match node.r#type.as_str() {
            "VCALL" => node_symbol(node).unwrap_or_default(),
            "FCALL" => node_symbol(node).unwrap_or_default(),
            "CALL" | "QCALL" | "OPCALL" => {
                let (_, method, _) = match_call(node).unwrap_or((node, String::new(), node));
                method
            }
            _ => return false,
        };
        if self.behavior.is_noreturn_method(&name) || self.pre_registered_noreturns.contains(&name) {
            return true;
        }
        if name == "absurd" {
            if let Some((receiver, _, _)) = match_call(node) {
                if receiver.text == "T" {
                    return true;
                }
            }
        }
        self.known_return_type(&name).as_deref() == Some("T.noreturn")
    }

    fn return_sources_for(
        &self,
        node: &crate::ast::Node,
        body: Option<&crate::ast::Node>,
        blockers: &mut BTreeSet<String>,
    ) -> Vec<Value> {
        let node_line = node.first_lineno;
        let code = node.text.clone();
        if node.r#type == "RETURN" {
            if let Some(arg) = child_node(node, 0) {
                return self.return_sources_for(arg, body, blockers);
            }
            return vec![
                json!({"kind": "nil", "type": "NilClass", "line": Value::Null, "code": "return"}),
            ];
        }
        if matches!(
            node.r#type.as_str(),
            "BLOCK" | "STATEMENTS" | "BEGIN" | "ELSE" | "PAREN" | "SCOPE" | "ROOT"
        ) {
            if let Some(expr) = implicit_return_expression(node) {
                return self.return_sources_for(expr, body, blockers);
            }
        }
        if matches!(node.r#type.as_str(), "IVAR" | "CVAR" | "GVAR") {
            if let Some(ty) = self.expression_type(node) {
                return vec![json!({"kind": "static", "type": ty, "line": node_line, "code": code})];
            }
            blockers.insert(format!(
                "untyped instance variable {code} at {}:{node_line}",
                self.path
            ));
            return vec![json!({"kind": "ivar_read", "line": node_line, "code": code})];
        }
        if matches!(node.r#type.as_str(), "IF" | "UNLESS") {
            let mut out = Vec::new();
            if let Some(then_branch) = child_node(node, 1) {
                if let Some(expr) = implicit_return_expression(then_branch) {
                    out.extend(self.return_sources_for(expr, body, blockers));
                }
            }
            if let Some(else_branch) = child_node(node, 2) {
                if let Some(expr) = implicit_return_expression(else_branch) {
                    out.extend(self.return_sources_for(expr, body, blockers));
                }
            } else {
                out.push(json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": "implicit else"}));
            }
            return out;
        }
        if matches!(node.r#type.as_str(), "CASE" | "CASE2") {
            let mut out = Vec::new();
            let when_arms = node
                .children
                .iter()
                .filter_map(crate::ast::node)
                .filter(|child| child.r#type == "WHEN" || child.r#type == "IN");
            for arm in when_arms {
                if let Some(body_arm) = child_node(arm, 1) {
                    if let Some(expr) = implicit_return_expression(body_arm) {
                        out.extend(self.return_sources_for(expr, body, blockers));
                    }
                }
            }
            let else_br = node
                .children
                .iter()
                .filter_map(crate::ast::node)
                .find(|child| {
                    child.r#type != "WHEN" && child.r#type != "IN" && child.r#type != "CASE_EXPR"
                });
            if let Some(alt) = else_br {
                if let Some(expr) = implicit_return_expression(alt) {
                    out.extend(self.return_sources_for(expr, body, blockers));
                }
            }
            if out.is_empty() {
                blockers.insert(format!(
                    "case return without exhaustive static branch type at {}:{node_line}",
                    self.path
                ));
            }
            return out;
        }
        if matches!(node.r#type.as_str(), "WHILE" | "UNTIL") {
            return vec![
                json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": code}),
            ];
        }
        let call_node = if node.r#type == "ITER" {
            child_node(node, 0).unwrap_or(node)
        } else {
            node
        };
        if call_node.r#type == "CALL"
            || call_node.r#type == "QCALL"
            || call_node.r#type == "FCALL"
            || call_node.r#type == "VCALL"
            || call_node.r#type == "OPCALL"
        {
            let callee = match call_node.r#type.as_str() {
                "VCALL" | "FCALL" => node_symbol(call_node).unwrap_or_default(),
                "CALL" | "QCALL" | "OPCALL" => {
                    let (_, method, _) = match_call(call_node).unwrap_or((call_node, String::new(), call_node));
                    method
                }
                _ => String::new(),
            };
            let receiver = if call_node.r#type == "CALL" || call_node.r#type == "QCALL" || call_node.r#type == "OPCALL" {
                child_node(call_node, 0)
            } else {
                None
            };
            let receiver_type = receiver.and_then(|r| self.expression_type(r));
            let is_global_receiver = receiver.map(|r| r.r#type == "GVAR").unwrap_or(false);

            println!("DEBUG extract_return_usage_sites: node.type={}, callee='{}', text='{}'", call_node.r#type, callee, call_node.text);
            if call_node.r#type == "QCALL" {
                if !is_global_receiver {
                    if let Some(ret) = self.known_return_type(&callee) {
                        if useful_type(&ret) {
                            return vec![
                                json!({"kind": "safe_call", "callee": callee, "type": format!("T.nilable({})", ret), "line": node_line, "code": code, "stdlib": Value::Null}),
                            ];
                        }
                    }
                }
                blockers.insert(format!(
                    "safe navigation return may be nil at {}:{node_line}",
                    self.path
                ));
                return vec![
                    json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": code}),
                    json!({"kind": "call_untyped", "callee": callee, "receiver_type": receiver_type, "line": node_line, "code": code}),
                ];
            }
            if !is_global_receiver {
                if let Some(ret) = self.known_return_type(&callee) {
                    if useful_type(&ret) {
                        return vec![
                            json!({"kind": "typed_call", "callee": callee, "type": ret, "line": node_line, "code": code, "stdlib": Value::Null}),
                        ];
                    }
                }
            }
            if let Some(expr_type) = self.expression_type(node) {
                if useful_type(&expr_type) {
                    let kind = if call_node.r#type == "QCALL" {
                        "safe_call"
                    } else {
                        "typed_call_inferred"
                    };
                    return vec![
                        json!({"kind": kind, "callee": callee, "type": expr_type, "line": node_line, "code": code}),
                    ];
                }
            }
            blockers.insert(format!(
                "untyped callee {callee} at {}:{node_line}",
                self.path
            ));
            return vec![
                json!({"kind": "call_untyped", "callee": callee, "receiver_type": receiver_type, "line": node_line, "code": code}),
            ];
        }
        if matches!(
            node.r#type.as_str(),
            "LASGN" | "DASGN" | "IASGN" | "CASGN" | "CVASGN" | "GVASGN"
        ) {
            if let Some(value) = child_node(node, 1) {
                return self.return_sources_for(value, body, blockers);
            }
        }
        if node.r#type == "ATTRASGN" {
            if let Some(args_node) = child_node(node, 2) {
                let arg_children = call_arguments(args_node);
                let val_node = arg_children
                    .last()
                    .map(|n| *n)
                    .unwrap_or(args_node);
                return self.return_sources_for(val_node, body, blockers);
            }
        }
        if node.r#type == "OP_ASGN1" {
            if let Some(val_node) = child_node(node, 3) {
                return self.return_sources_for(val_node, body, blockers);
            }
        }
        if node.r#type == "OP_ASGN2" {
            if let Some(val_node) = child_node(node, 4) {
                return self.return_sources_for(val_node, body, blockers);
            }
        }
        if matches!(node.r#type.as_str(), "LVAR" | "DVAR") {
            let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
            let is_escaped = body.is_some_and(|b| self.escape_uses_of_local(b, &name));
            if is_escaped {
                blockers.insert(format!(
                    "escaped local variable {code} at {}:{node_line}",
                    self.path
                ));
                return vec![json!({"kind": "unknown", "line": node_line, "code": code, "unknown_reasons": []})];
            }
            if let Some(ty) = self.expression_type(node) {
                if useful_type(&ty) {
                    return vec![
                        json!({"kind": if ty == "NilClass" { "nil" } else { "static" }, "type": ty, "line": node_line, "code": code}),
                    ];
                }
            }
            blockers.insert(format!(
                "untyped local variable {code} (LocalVariableReadNode) at {}:{node_line}",
                self.path
            ));
            return vec![json!({"kind": "unknown", "line": node_line, "code": code, "unknown_reasons": []})];
        }
        if let Some(ty) = self.expression_type(node) {
            return vec![
                json!({"kind": if ty == "NilClass" { "nil" } else { "static" }, "type": ty, "line": node_line, "code": code}),
            ];
        }
        blockers.insert(format!(
            "unknown return expression {} at {}:{node_line}",
            node.r#type, self.path
        ));
        vec![json!({"kind": "unknown", "line": node_line, "code": code, "unknown_reasons": []})]
    }

    fn current_params_json(&self, node: &crate::ast::Node) -> Vec<Value> {
        let mut list = Vec::new();
        let mut params_node = None;
        for child in child_nodes(node) {
            if child.r#type == "parameters"
                || child.r#type == "method_parameters"
                || child.r#type == "parameter_list"
            {
                params_node = Some(child);
                break;
            }
        }

        let mut nil_defaults = BTreeMap::new();
        if let Some(pn) = params_node {
            for param in child_nodes(pn) {
                if param.r#type == "optional_parameter" || param.r#type == "keyword_parameter" {
                    let children = child_nodes(param);
                    if children.len() >= 2 {
                        let name_node = children[0];
                        let val_node = children[1];
                        let name = name_node.text.trim().trim_end_matches(':').to_string();
                        let is_nil = val_node.r#type == "NIL";
                        nil_defaults.insert(name, is_nil);
                    }
                }
            }
        }

        for param in &self.current_params {
            let ptype = self.param_types.get(param).cloned();
            let is_nil_default = nil_defaults.get(param).cloned().unwrap_or(false);
            list.push(json!({
                "name": param,
                "nil_default": is_nil_default,
                "type": ptype,
            }));
        }
        list
    }

    fn collect_type_normalizers(&mut self, body: &crate::ast::Node, record: &Value) {
        let param_names = value_array(record.get("params"))
            .iter()
            .filter_map(|param| {
                param
                    .get("name")
                    .and_then(Value::as_str)
                    .map(ToString::to_string)
            })
            .collect::<BTreeSet<_>>();
        let mut assigns = BTreeMap::new();
        self.collect_assigns(body, &mut assigns);
        self.collect_type_normalizers_node(body, record, &param_names, &assigns);
    }

    fn collect_assigns<'tree>(
        &self,
        node: &'tree crate::ast::Node,
        assigns: &mut BTreeMap<String, &'tree crate::ast::Node>,
    ) {
        if node.r#type == "LASGN" || node.r#type == "DASGN" {
            if let (Some(name), Some(value)) = (node_symbol(node), child_node(node, 1)) {
                assigns.entry(name).or_insert(value);
            }
        }
        for child in child_nodes(node) {
            self.collect_assigns(child, assigns);
        }
    }

    fn collect_type_normalizers_node(
        &mut self,
        node: &crate::ast::Node,
        record: &Value,
        param_names: &BTreeSet<String>,
        assigns: &BTreeMap<String, &crate::ast::Node>,
    ) {
        if (node.r#type == "CALL" || node.r#type == "QCALL" || node.r#type == "OPCALL")
            && node_symbol(node)
                .as_deref()
                .map_or(false, |m| self.behavior.is_type_guard(m))
        {
            if let Some((receiver, _, args_node)) = match_call(node) {
                let arg_nodes = call_arguments(args_node);
                if arg_nodes.len() == 1 && arg_nodes[0].text == "Type" {
                    let (origin_kind, origin_name) =
                        self.classify_origin(receiver, param_names, assigns, 0);
                    self.type_normalizers.push(json!({
                        "path": self.path,
                        "line": node.first_lineno,
                        "class": record["class"],
                        "method": record["method"],
                        "code": node.text.lines().next().unwrap_or("").trim().chars().take(120).collect::<String>(),
                        "origin_kind": origin_kind,
                        "origin_name": origin_name,
                    }));
                }
            }
        }
        for child in child_nodes(node) {
            self.collect_type_normalizers_node(child, record, param_names, assigns);
        }
    }

    fn classify_origin(
        &self,
        node: &crate::ast::Node,
        param_names: &BTreeSet<String>,
        assigns: &BTreeMap<String, &crate::ast::Node>,
        depth: usize,
    ) -> (String, Value) {
        match node.r#type.as_str() {
            "IVAR" => ("ivar".to_string(), json!(node.text.trim())),
            "LVAR" | "DVAR" => {
                let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
                if param_names.contains(&name) {
                    return ("param".to_string(), json!(name));
                }
                if depth == 0 {
                    if let Some(rhs) = assigns.get(&name) {
                        return self.classify_origin(*rhs, param_names, assigns, depth + 1);
                    }
                }
                ("local".to_string(), Value::Null)
            }
            "CALL" | "QCALL" | "OPCALL" => {
                if let Some((_, method, args_node)) = match_call(node) {
                    if method == "[]" {
                        let arg_nodes = call_arguments(args_node);
                        let key = arg_nodes
                            .first()
                            .and_then(|key| hash_key_name(key).map(|k| format!(":{k}")));
                        (
                            "hashkey".to_string(),
                            key.map(Value::String).unwrap_or(Value::Null),
                        )
                    } else if !call_arguments(args_node).is_empty() {
                        ("call".to_string(), json!(method))
                    } else {
                        ("attr".to_string(), json!(method))
                    }
                } else {
                    ("call".to_string(), Value::Null)
                }
            }
            "FCALL" => {
                let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
                ("call".to_string(), json!(name))
            }
            "VCALL" => {
                let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
                ("attr".to_string(), json!(name))
            }
            _ => ("local".to_string(), Value::Null),
        }
    }

    fn collect_hidden_enum_observations(&mut self, body: &crate::ast::Node, record: &Value) {
        let params = value_array(record.get("params"))
            .into_iter()
            .filter_map(|param| {
                let name = param.get("name").and_then(Value::as_str)?.to_string();
                Some((name, param))
            })
            .collect::<BTreeMap<_, _>>();
        self.collect_hidden_enum_observations_node(body, record, &params);
    }

    fn collect_hidden_enum_observations_node(
        &mut self,
        node: &crate::ast::Node,
        record: &Value,
        params: &BTreeMap<String, Value>,
    ) {
        match node.r#type.as_str() {
            "CASE" | "CASE2" => {
                if let Some(condition) = child_node(node, 0) {
                    if let Some(slot) = self.hidden_enum_slot_for(condition, record, params) {
                        let values = case_literal_values(node);
                        self.record_hidden_enum_observation(slot, values, node, "case");
                    }
                }
            }
            "CALL" | "QCALL" | "OPCALL" => {
                let name = node_symbol(node).unwrap_or_default();
                if matches!(name.as_str(), "==" | "!=" | "===") {
                    if let Some((receiver, _, args_node)) = match_call(node) {
                        let arg_nodes = call_arguments(args_node);
                        if arg_nodes.len() == 1 {
                            let arg = arg_nodes[0];
                            if let Some(slot) = self.hidden_enum_slot_for(receiver, record, params)
                            {
                                self.record_hidden_enum_observation(
                                    slot,
                                    hidden_enum_literal_values(arg),
                                    node,
                                    &name,
                                );
                            }
                            if let Some(slot) = self.hidden_enum_slot_for(arg, record, params) {
                                self.record_hidden_enum_observation(
                                    slot,
                                    hidden_enum_literal_values(receiver),
                                    node,
                                    &name,
                                );
                            }
                        }
                    }
                } else if matches!(name.as_str(), "include?" | "member?" | "key?") {
                    if let Some((receiver, _, args_node)) = match_call(node) {
                        let arg_nodes = call_arguments(args_node);
                        if arg_nodes.len() == 1 {
                            let arg = arg_nodes[0];
                            if let Some(slot) = self.hidden_enum_slot_for(arg, record, params) {
                                self.record_hidden_enum_observation(
                                    slot,
                                    hidden_enum_literal_values(receiver),
                                    node,
                                    &name,
                                );
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        for child in child_nodes(node) {
            self.collect_hidden_enum_observations_node(child, record, params);
        }
    }

    fn hidden_enum_slot_for(
        &self,
        node: &crate::ast::Node,
        record: &Value,
        params: &BTreeMap<String, Value>,
    ) -> Option<Value> {
        match node.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
                let param = params.get(&name)?;
                let key = [
                    "param".to_string(),
                    record["path"].as_str().unwrap_or("").to_string(),
                    record["class"].as_str().unwrap_or("").to_string(),
                    record["kind"].as_str().unwrap_or("instance").to_string(),
                    record["method"].as_str().unwrap_or("").to_string(),
                    record["line"].as_i64().unwrap_or(0).to_string(),
                    name.clone(),
                ]
                .join("\0");
                Some(json!({
                    "key": key,
                    "kind": "param",
                    "path": record["path"],
                    "line": record["line"],
                    "owner": record["class"],
                    "method": record["method"],
                    "method_kind": record["kind"],
                    "slot": name,
                    "type": param.get("type").and_then(Value::as_str).unwrap_or(""),
                }))
            }
            "IVAR" | "CVAR" => {
                let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
                let key = [
                    "state".to_string(),
                    record["path"].as_str().unwrap_or("").to_string(),
                    record["class"].as_str().unwrap_or("").to_string(),
                    name.clone(),
                ]
                .join("\0");
                Some(json!({
                    "key": key,
                    "kind": "state",
                    "path": record["path"],
                    "line": node.first_lineno,
                    "owner": record["class"],
                    "method": Value::Null,
                    "method_kind": Value::Null,
                    "slot": name,
                    "type": "",
                }))
            }
            _ => None,
        }
    }

    fn record_hidden_enum_observation(
        &mut self,
        slot: Value,
        values: Vec<Value>,
        site: &crate::ast::Node,
        kind: &str,
    ) {
        let values = values
            .into_iter()
            .filter(|value| {
                let raw = value.get("value").and_then(Value::as_str).unwrap_or("");
                !raw.is_empty() && raw.len() <= 80
            })
            .collect::<Vec<_>>();
        if values.is_empty() {
            return;
        }
        let mut obs = slot;
        object_insert(&mut obs, "event", json!("decision"));
        object_insert(&mut obs, "values", json!(values));

        let first_line = site.text.lines().next().unwrap_or("").trim().to_string();
        object_insert(
            &mut obs,
            "site",
            json!({
                "path": self.path,
                "line": site.first_lineno,
                "kind": kind,
                "code": first_line,
            }),
        );
        self.hidden_enum_observations.push(obs);
    }

    pub(crate) fn collect_return_usage_site_context(
        &mut self,
        node: &crate::ast::Node,
        context: &str,
        current_method: Option<&str>,
        current_handler: Option<usize>,
        direct_usage: bool,
    ) {
        if node.r#type == "ARGUMENT_LIST" {
            let arg_context = if direct_usage { "return" } else { context };
            for child in child_nodes(node) {
                self.collect_return_usage_site_context(
                    child,
                    arg_context,
                    current_method,
                    current_handler,
                    direct_usage,
                );
            }
            return;
        }

        match node.r#type.as_str() {
            "DEFN" | "DEFS" => {
                let name = node_symbol(node).unwrap_or_default();
                let body_index = if node.r#type == "DEFS" { 2 } else { 1 };
                if let Some(body) = child_node(node, body_index) {
                    self.collect_return_usage_site_context(
                        body,
                        "return",
                        Some(&name),
                        None,
                        direct_usage,
                    );
                }
            }
            "ROOT" | "PROGRAM" => {
                let children = child_nodes(node);
                if !children.is_empty() {
                    let last = children.len() - 1;
                    for (idx, child) in children.into_iter().enumerate() {
                        let child_context = if idx == last { "value" } else { "statement" };
                        self.collect_return_usage_site_context(
                            child,
                            child_context,
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                }
            }
            "BLOCK" | "ITER" => {
                let children = child_nodes(node);
                if !children.is_empty() {
                    let body = children.last().unwrap();
                    for child in children.iter().take(children.len() - 1) {
                        self.collect_return_usage_site_context(
                            child,
                            "statement",
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                    self.collect_return_usage_site_context(
                        body,
                        context,
                        current_method,
                        current_handler,
                        direct_usage,
                    );
                }
            }
            "STATEMENTS" | "BEGIN" | "SCOPE" => {
                let children = child_nodes(node);
                let handler_line = children
                    .iter()
                    .find(|child| child.r#type == "rescue" || child.r#type == "RESCUE")
                    .map(|child| child.first_lineno);
                if let Some(hl) = handler_line {
                    self.rescue_handlers.push(json!({
                        "path": self.path,
                        "line": hl,
                        "kind": "rescue",
                        "method": current_method,
                    }));
                }
                let protected_handler = handler_line.or(current_handler);
                if !children.is_empty() {
                    let last = children.len() - 1;
                    for (idx, child) in children.iter().enumerate() {
                        let child_context = if idx == last { context } else { "statement" };
                        self.collect_return_usage_site_context(
                            child,
                            child_context,
                            current_method,
                            protected_handler,
                            direct_usage,
                        );
                    }
                }
            }
            "RETURN" => {
                for child in child_nodes(node) {
                    self.collect_return_usage_site_context(
                        child,
                        "return",
                        current_method,
                        current_handler,
                        direct_usage,
                    );
                }
            }
            "IF" | "UNLESS" => {
                if let Some(condition) = child_node(node, 0) {
                    self.collect_return_usage_site_context(
                        condition,
                        "value",
                        current_method,
                        current_handler,
                        direct_usage,
                    );
                }
                if let Some(then_branch) = child_node(node, 1) {
                    self.collect_return_usage_site_context(
                        then_branch,
                        context,
                        current_method,
                        current_handler,
                        direct_usage,
                    );
                }
                if let Some(else_branch) = child_node(node, 2) {
                    self.collect_return_usage_site_context(
                        else_branch,
                        context,
                        current_method,
                        current_handler,
                        direct_usage,
                    );
                }
            }
            "ELSE" => {
                let children = child_nodes(node);
                if !children.is_empty() {
                    let last = children.len() - 1;
                    for (idx, child) in children.iter().enumerate() {
                        let child_context = if idx == last { context } else { "statement" };
                        self.collect_return_usage_site_context(
                            child,
                            child_context,
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                }
            }
            "RESCUE" => {
                for child in child_nodes(node) {
                    if child.r#type == "then"
                        || child.r#type == "STATEMENTS"
                        || child.r#type == "BLOCK"
                    {
                        self.collect_return_usage_site_context(
                            child,
                            "statement",
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                }
            }
            "OPASGN" | "OPASGN2" | "LASGN" | "DASGN" | "IASGN" | "CASGN" | "CVASGN" | "GVASGN" => {
                let is_element_ref = child_node(node, 0)
                    .map(|lhs| lhs.r#type == "element_reference" || lhs.r#type == "AREF")
                    .unwrap_or(false);
                let contains_or_assign = node.text.contains("||=");

                if node.r#type == "OPASGN" && !(is_element_ref && contains_or_assign) {
                    if is_element_ref {
                        if let Some(name) = node_symbol(node).filter(|n| !n.is_empty()) {
                            let site_record = json!({
                                "path": self.path,
                                "line": node.first_lineno,
                                "name": name,
                                "context": context,
                                "current_method": current_method,
                                "handler_line": current_handler,
                                "code": node.text.lines().next().unwrap_or("").trim().to_string(),
                            });
                            if direct_usage {
                                self.return_direct_usage_sites.push(site_record);
                            } else {
                                self.return_usage_sites.push(site_record);
                            }
                        }
                        if let Some(receiver) =
                            child_node(node, 0).and_then(|lhs| child_node(lhs, 0))
                        {
                            self.collect_return_usage_site_context(
                                receiver,
                                "value",
                                current_method,
                                current_handler,
                                direct_usage,
                            );
                        }
                        let arg_context = if direct_usage { "return" } else { "value" };
                        if let Some(args) = child_node(node, 0).and_then(|lhs| child_node(lhs, 1)) {
                            for arg in child_nodes(args) {
                                self.collect_return_usage_site_context(
                                    arg,
                                    arg_context,
                                    current_method,
                                    current_handler,
                                    direct_usage,
                                );
                            }
                        }
                    } else if let Some(val_node) = child_node(node, 1) {
                        let value_context = if child_node(node, 0)
                            .map(|lhs| lhs.r#type == "identifier" || lhs.r#type == "LVAR")
                            .unwrap_or(false)
                        {
                            "value"
                        } else if node.text.contains("||=") || node.text.contains("&&=") {
                            context
                        } else {
                            "value"
                        };
                        self.collect_return_usage_site_context(
                            val_node,
                            value_context,
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                } else {
                    for child in child_nodes(node) {
                        self.collect_return_usage_site_context(
                            child,
                            "value",
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                }
            }
            "CALL" | "QCALL" | "FCALL" | "VCALL" => {
                if let Some(name) = node_symbol(node).filter(|n| !n.is_empty()) {
                    let site_record = json!({
                        "path": self.path,
                        "line": node.first_lineno,
                        "name": name,
                        "context": context,
                        "current_method": current_method,
                        "handler_line": current_handler,
                        "code": node.text.lines().next().unwrap_or("").trim().to_string(),
                    });
                    if direct_usage {
                        self.return_direct_usage_sites.push(site_record);
                    } else {
                        self.return_usage_sites.push(site_record);
                    }
                }
                if let Some((receiver, _, args_node)) = match_call(node) {
                    self.collect_return_usage_site_context(
                        receiver,
                        "value",
                        current_method,
                        current_handler,
                        direct_usage,
                    );
                    let arg_context = if direct_usage { "return" } else { "value" };
                    for arg in call_arguments(args_node) {
                        self.collect_return_usage_site_context(
                            arg,
                            arg_context,
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                } else {
                    let arg_context = if direct_usage { "return" } else { "value" };
                    for child in child_nodes(node) {
                        self.collect_return_usage_site_context(
                            child,
                            arg_context,
                            current_method,
                            current_handler,
                            direct_usage,
                        );
                    }
                }
            }
            _ => {
                for child in child_nodes(node) {
                    self.collect_return_usage_site_context(
                        child,
                        "value",
                        current_method,
                        current_handler,
                        direct_usage,
                    );
                }
            }
        }
    }

    pub(crate) fn collect_hash_record_escape_sites(&mut self, root: &crate::ast::Node) {
        self.collect_hash_record_escape_sites_node(root, root);
    }

    fn collect_hash_record_escape_sites_node(
        &mut self,
        root: &crate::ast::Node,
        node: &crate::ast::Node,
    ) {
        if node.r#type == "HASH" {
            if let Some(reason) = self.hash_record_escape_reason(root, node) {
                self.hash_record_escape_sites.push(json!({
                    "path": self.path,
                    "line": node.first_lineno,
                    "code": node.text.trim().to_string(),
                    "escapes_collection": true,
                    "reason": reason,
                }));
            }
        }
        for child in child_nodes(node) {
            self.collect_hash_record_escape_sites_node(root, child);
        }
    }

    fn hash_record_escape_reason(
        &self,
        root: &crate::ast::Node,
        hash_node: &crate::ast::Node,
    ) -> Option<&'static str> {
        if self.hash_literal_in_array_literal(root, hash_node) {
            return Some("array_literal");
        }
        if self.value_in_collection_append_or_index_write(root, hash_node) {
            return Some("collection_append_or_index_write");
        }
        let writer = self.enclosing_local_write_for(root, hash_node)?;
        let name = node_symbol(writer)?;
        if self.escape_uses_of_local(root, &name) {
            Some("local_alias_escape")
        } else {
            None
        }
    }

    fn hash_literal_in_array_literal(
        &self,
        root: &crate::ast::Node,
        target: &crate::ast::Node,
    ) -> bool {
        let mut node = target;
        while let Some(parent) = self.find_parent(root, node) {
            if parent.r#type == "ARRAY" || parent.r#type == "LIST" {
                return true;
            }
            node = parent;
        }
        false
    }

    fn find_parent<'b>(
        &self,
        current: &'b crate::ast::Node,
        target: &crate::ast::Node,
    ) -> Option<&'b crate::ast::Node> {
        for child in child_nodes(current) {
            if child == target {
                return Some(current);
            }
            if let Some(p) = self.find_parent(child, target) {
                return Some(p);
            }
        }
        None
    }

    fn value_in_collection_append_or_index_write(
        &self,
        root: &crate::ast::Node,
        target: &crate::ast::Node,
    ) -> bool {
        let mut found = false;
        self.walk_raw(root, &mut |node| {
            if found {
                return;
            }
            if (node.r#type == "CALL" || node.r#type == "QCALL")
                && node_symbol(node).is_some_and(|name| collection_append_method(&name))
            {
                if let Some((_, _, args_node)) = match_call(node) {
                    if call_arguments(args_node).into_iter().any(|arg| arg == target) {
                        found = true;
                        return;
                    }
                }
            }
            if (node.r#type == "OPASGN" || node.r#type == "LASGN" || node.r#type == "IASGN")
                && child_node(node, 0)
                    .map(|lhs| lhs.r#type == "element_reference" || lhs.r#type == "AREF")
                    .unwrap_or(false)
                && child_node(node, 1) == Some(target)
            {
                found = true;
                return;
            }
            if (node.r#type == "CALL" || node.r#type == "QCALL")
                && node_symbol(node).as_deref() == Some("[]=")
            {
                if let Some((_, _, args_node)) = match_call(node) {
                    if call_arguments(args_node).last().copied() == Some(target) {
                        found = true;
                    }
                }
            }
        });
        found
    }

    fn walk_raw(&self, node: &crate::ast::Node, f: &mut impl FnMut(&crate::ast::Node)) {
        f(node);
        for child in child_nodes(node) {
            self.walk_raw(child, f);
        }
    }

    fn enclosing_local_write_for<'b>(
        &self,
        root: &'b crate::ast::Node,
        hash_node: &crate::ast::Node,
    ) -> Option<&'b crate::ast::Node> {
        let parent = self.find_parent(root, hash_node)?;
        if (parent.r#type == "LASGN" || parent.r#type == "DASGN")
            && child_node(parent, 1) == Some(hash_node)
        {
            Some(parent)
        } else {
            None
        }
    }

    fn escape_uses_of_local(&self, root: &crate::ast::Node, name: &str) -> bool {
        let mut escapes = false;
        self.walk_raw(root, &mut |node| {
            if escapes {
                return;
            }
            if node.r#type == "CALL" || node.r#type == "QCALL" || node.r#type == "FCALL" || node.r#type == "VCALL" {
                let opt_method = match node.r#type.as_str() {
                    "VCALL" | "FCALL" => node_symbol(node),
                    "CALL" | "QCALL" => match_call(node).map(|(_, method, _)| method),
                    _ => None,
                };
                if let Some(method) = opt_method {
                    if self.current_method.as_ref() == Some(&method) {
                        return;
                    }
                    let args_node = match node.r#type.as_str() {
                        "VCALL" | "FCALL" => {
                            node.children.iter().find_map(|c| match c {
                                crate::ast::Child::Node(n) => Some(n.as_ref()),
                                _ => None,
                            }).unwrap_or(node)
                        }
                        "CALL" | "QCALL" => {
                            match_call(node).map(|(_, _, args)| args).unwrap_or(node)
                        }
                        _ => node,
                    };
                    if call_arguments(args_node).into_iter().any(|arg| {
                        (arg.r#type == "LVAR" || arg.r#type == "DVAR")
                            && node_symbol(arg).as_deref() == Some(name)
                    }) {
                        escapes = true;
                        return;
                    }
                }
            }
            if node.r#type == "ARRAY" || node.r#type == "LIST" {
                if child_nodes(node).into_iter().any(|child| {
                    (child.r#type == "LVAR" || child.r#type == "DVAR")
                        && node_symbol(child).as_deref() == Some(name)
                }) {
                    let mut is_recursive_arg_list = false;
                    if let Some(parent) = self.find_parent(root, node) {
                        if parent.r#type == "FCALL" || parent.r#type == "VCALL" {
                            if let Some(callee) = node_symbol(parent) {
                                if self.current_method.as_ref() == Some(&callee) {
                                    is_recursive_arg_list = true;
                                }
                            }
                        } else if parent.r#type == "CALL" || parent.r#type == "QCALL" {
                            if let Some((_, callee, _)) = match_call(parent) {
                                if self.current_method.as_ref() == Some(&callee) {
                                    is_recursive_arg_list = true;
                                }
                            }
                        }
                    }
                    if !is_recursive_arg_list {
                        escapes = true;
                    }
                }
            }
        });
        escapes
    }

    fn get_method_param_hash_shape(&self, class_name: &str, method_name: &str, param: &str) -> Option<Value> {
        let methods = if method_name == "initialize" {
            vec!["initialize".to_string(), "new".to_string()]
        } else if method_name == "new" {
            vec!["new".to_string(), "initialize".to_string()]
        } else {
            vec![method_name.to_string()]
        };
        for m in &methods {
            if let Some(shape) = self.method_param_hash_shapes.get(&(class_name.to_string(), m.clone(), param.to_string())) {
                return Some(shape.clone());
            }
            if class_name != "" {
                if let Some(shape) = self.method_param_hash_shapes.get(&("".to_string(), m.clone(), param.to_string())) {
                    return Some(shape.clone());
                }
            }
            let matching = self.method_param_hash_shapes.iter()
                .filter(|((_, m_name, p), _)| m_name == m && p == param)
                .map(|(_, shape)| shape)
                .collect::<Vec<_>>();
            if !matching.is_empty() {
                return Some(matching[0].clone());
            }
        }
        if method_name == "initialize" {
            if let Some(shape) = self.struct_field_hash_shapes.get(&(class_name.to_string(), param.to_string())) {
                return Some(shape.clone());
            }
        }
        None
    }

    fn get_method_param_array_shape(&self, class_name: &str, method_name: &str, param: &str) -> Option<Value> {
        let methods = if method_name == "initialize" {
            vec!["initialize".to_string(), "new".to_string()]
        } else if method_name == "new" {
            vec!["new".to_string(), "initialize".to_string()]
        } else {
            vec![method_name.to_string()]
        };
        for m in &methods {
            if let Some(shape) = self.method_param_array_shapes.get(&(class_name.to_string(), m.clone(), param.to_string())) {
                return Some(shape.clone());
            }
            if class_name != "" {
                if let Some(shape) = self.method_param_array_shapes.get(&("".to_string(), m.clone(), param.to_string())) {
                    return Some(shape.clone());
                }
            }
            let matching = self.method_param_array_shapes.iter()
                .filter(|((_, m_name, p), _)| m_name == m && p == param)
                .map(|(_, shape)| shape)
                .collect::<Vec<_>>();
            if !matching.is_empty() {
                return Some(matching[0].clone());
            }
        }
        if method_name == "initialize" {
            if let Some(shape) = self.struct_field_array_shapes.get(&(class_name.to_string(), param.to_string())) {
                return Some(shape.clone());
            }
        }
        None
    }

    fn method_return_hash_shape_for_call(&self, class_name: &str, method_name: &str) -> Option<Value> {
        if let Some(shape) = self.method_return_hash_shapes.get(&(class_name.to_string(), method_name.to_string())) {
            return Some(shape.clone());
        }
        if class_name != "" {
            if let Some(shape) = self.method_return_hash_shapes.get(&("".to_string(), method_name.to_string())) {
                return Some(shape.clone());
            }
        }
        let matching = self.method_return_hash_shapes.iter()
            .filter(|((_, m), _)| m == method_name)
            .map(|(_, shape)| shape)
            .collect::<Vec<_>>();
        if !matching.is_empty() {
            return Some(matching[0].clone());
        }
        if !method_name.ends_with('=') {
            let setter = format!("{}=", method_name);
            if let Some(shape) = self.get_method_param_hash_shape(class_name, &setter, "0") {
                return Some(shape);
            }
        }
        None
    }

    fn method_return_array_shape_for_call(&self, class_name: &str, method_name: &str) -> Option<Value> {
        if let Some(shape) = self.method_return_array_shapes.get(&(class_name.to_string(), method_name.to_string())) {
            return Some(shape.clone());
        }
        if class_name != "" {
            if let Some(shape) = self.method_return_array_shapes.get(&("".to_string(), method_name.to_string())) {
                return Some(shape.clone());
            }
        }
        let matching = self.method_return_array_shapes.iter()
            .filter(|((_, m), _)| m == method_name)
            .map(|(_, shape)| shape)
            .collect::<Vec<_>>();
        if !matching.is_empty() {
            return Some(matching[0].clone());
        }
        if !method_name.ends_with('=') {
            let setter = format!("{}=", method_name);
            if let Some(shape) = self.get_method_param_array_shape(class_name, &setter, "0") {
                return Some(shape);
            }
        }
        None
    }

    fn get_call_info<'tree>(&self, node: &'tree crate::ast::Node) -> Option<(String, String, &'tree crate::ast::Node)> {
        if let Some((rec, callee, args_node)) = match_call(node) {
            let mut class_name = "".to_string();
            if let Some(receiver_type) = self.expression_type(rec) {
                class_name = receiver_type.replace("T.nilable(", "").replace(")", "");
            }
            if class_name.is_empty() && rec.text.trim() == "self" {
                class_name = self.current_owners.last().cloned().unwrap_or_default();
            }
            Some((class_name, callee, args_node))
        } else if node.r#type == "FCALL" || node.r#type == "VCALL" || node.r#type == "SUPER" {
            let callee = node_symbol(node).unwrap_or_else(|| {
                if node.r#type == "SUPER" { "super".to_string() } else { "".to_string() }
            });
            let args_node = node.children.iter().find_map(|c| match c {
                crate::ast::Child::Node(n) => Some(n.as_ref()),
                _ => None,
            }).unwrap_or(node);
            let class_name = self.current_owners.last().cloned().unwrap_or_default();
            Some((class_name, callee, args_node))
        } else {
            None
        }
    }

    fn inspect_param_origins(&mut self, node: &crate::ast::Node) {
        let (callee, args_node, rec) = if let Some((rec, callee, args_node)) = match_call(node) {
            (callee, args_node, Some(rec))
        } else if node.r#type == "FCALL" || node.r#type == "VCALL" || node.r#type == "SUPER" {
            let callee = node_symbol(node).unwrap_or_else(|| {
                if node.r#type == "SUPER" { "super".to_string() } else { "".to_string() }
            });
            let args_node = node.children.iter().find_map(|c| match c {
                crate::ast::Child::Node(n) => Some(n.as_ref()),
                _ => None,
            }).unwrap_or(node);
            (callee, args_node, None)
        } else {
            return;
        };

        if callee == "defined?" || callee == "" {
            return;
        }

        let mut class_name = "".to_string();
        if let Some(r) = rec {
            if let Some(receiver_type) = self.expression_type(r) {
                class_name = receiver_type.replace("T.nilable(", "").replace(")", "");
            }
            if class_name.is_empty() && r.text.trim() == "self" {
                class_name = self.current_owners.last().cloned().unwrap_or_default();
            }
        } else {
            class_name = self.current_owners.last().cloned().unwrap_or_default();
        }

        let args = call_arguments(args_node);
        let mut positional_idx = 0usize;
        let mut counted_keyword_group = false;
        for arg in args.iter() {
            let is_keyword_pair = if arg.r#type == "pair" || arg.r#type == "PAIR" {
                true
            } else if arg.r#type == "HASH" {
                if let Some(key_node) = child_node(arg, 0) {
                    hash_key_name(key_node).is_some()
                } else {
                    false
                }
            } else {
                false
            };

            if is_keyword_pair {
                if let Some(key_node) = child_node(arg, 0) {
                    if let Some(key) = hash_key_name(key_node) {
                        if let Some(value) = child_node(arg, 1) {
                            let record =
                                self.param_origin_record(node, value, &callee, "keyword", &key);
                            if !self.is_prepass {
                                self.param_origins.push(record);
                            }
                            self.record_callsite_hash_shape(&class_name, &callee, "keyword", &key, value);
                            self.record_callsite_array_element_shape(
                                &class_name, &callee, "keyword", &key, value,
                            );
                        }
                    }
                }
                if !counted_keyword_group {
                    positional_idx += 1;
                    counted_keyword_group = true;
                }
            } else {
                let record = self.param_origin_record(
                    node,
                    *arg,
                    &callee,
                    "positional",
                    &positional_idx.to_string(),
                );
                if !self.is_prepass {
                    self.param_origins.push(record);
                }
                self.record_callsite_hash_shape(
                    &class_name,
                    &callee,
                    "positional",
                    &positional_idx.to_string(),
                    *arg,
                );
                self.record_callsite_array_element_shape(
                    &class_name,
                    &callee,
                    "positional",
                    &positional_idx.to_string(),
                    *arg,
                );
                positional_idx += 1;
            }
        }
    }

    fn record_callsite_hash_shape(
        &mut self,
        class_name: &str,
        callee: &str,
        _kind: &str,
        slot: &str,
        arg: &crate::ast::Node,
    ) {
        if let Some(shape) = self.hash_shape_for_value(arg) {
            let key = (class_name.to_string(), callee.to_string(), slot.to_string());
            self.method_param_hash_shapes.insert(key, shape);
        }
    }

    fn record_callsite_array_element_shape(
        &mut self,
        class_name: &str,
        callee: &str,
        _kind: &str,
        slot: &str,
        arg: &crate::ast::Node,
    ) {
        if let Some(shape) = self.array_element_shape_for_value(arg) {
            let key = (class_name.to_string(), callee.to_string(), slot.to_string());
            self.method_param_array_shapes.insert(key, shape);
        }
    }

    fn param_origin_record(
        &mut self,
        call_node: &crate::ast::Node,
        arg: &crate::ast::Node,
        callee: &str,
        kind: &str,
        slot: &str,
    ) -> Value {
        let mut ty = self.expression_type(arg);
        let mut origin_kind = if ty.is_some() { "static" } else { "unknown" }.to_string();
        let mut source_method = None::<String>;
        if arg.r#type == "CALL" || arg.r#type == "QCALL" || arg.r#type == "OPCALL" || arg.r#type == "VCALL" || arg.r#type == "FCALL" {
            source_method = node_symbol(arg);
            if let Some(ref method) = source_method {
                if let Some(ret) = self.known_return_type(method) {
                    ty = Some(ret);
                    origin_kind = "typed_return".to_string();
                } else if ty.as_deref().is_some_and(useful_type) {
                    origin_kind = "typed_return".to_string();
                } else {
                    origin_kind = "untyped_return".to_string();
                }
            }
        } else if arg.r#type == "LVAR" || arg.r#type == "DVAR" {
            origin_kind = "local".to_string();
        }
        let mut code = arg.text.clone();
        while code.starts_with('(') && code.ends_with(')') {
            code = code[1..code.len() - 1].to_string();
        }
        json!({
            "path": self.path,
            "line": call_node.first_lineno,
            "enclosing_scope": self.current_owners.join("::"),
            "callee": callee,
            "arg_kind": kind,
            "slot": slot,
            "origin_kind": origin_kind,
            "receiver": call_receiver_name(call_node),
            "source_method": source_method,
            "type": ty,
            "code": code,
            "hash_shape": self.hash_shape_for_value(arg),
            "array_element_shape": self.array_element_shape_for_value(arg),
            "unknown_reasons": if origin_kind == "unknown" { self.unknown_expression_reasons(arg) } else { Vec::<String>::new() },
        })
    }

    fn unknown_expression_reasons(&mut self, node: &crate::ast::Node) -> Vec<String> {
        let mut reasons = BTreeSet::new();
        self.collect_unknown_expression_reasons(node, &mut reasons);
        reasons.into_iter().collect()
    }

    fn collect_unknown_expression_reasons(
        &mut self,
        node: &crate::ast::Node,
        reasons: &mut BTreeSet<String>,
    ) {
        match node.r#type.as_str() {
            "IVAR" | "IVAR_WRITE" => {
                reasons.insert(format!("instance variable {}", node.text.trim()));
            }
            "CVAR" | "CVAR_WRITE" => {
                reasons.insert(format!("class variable {}", node.text.trim()));
            }
            "GVAR" | "GVAR_WRITE" => {
                reasons.insert(format!("global variable {}", node.text.trim()));
            }
            "LVAR" | "DVAR" => {
                reasons.insert(format!("local variable {}", node.text.trim()));
            }
            "CONST" | "COLON2" | "COLON3" => {
                if let Some(ty) = self.constant_expression_type(node) {
                    reasons.insert(format!(
                        "literal/static expression {}",
                        static_expression_reason(&ty)
                    ));
                } else {
                    reasons.insert(format!(
                        "operation unresolved constant {}",
                        node.text.trim()
                    ));
                }
                return;
            }
            "ARRAY" | "LIST" => {
                reasons.insert("struct/array/collection value Array".to_string());
                return;
            }
            "HASH" => {
                reasons.insert("struct/array/collection value Hash".to_string());
                return;
            }
            "CALL" | "QCALL" | "OPCALL" | "VCALL" | "FCALL" => {
                if let Some(ty) = self.expression_type(node) {
                    reasons.insert(format!(
                        "literal/static expression {}",
                        static_expression_reason(&ty)
                    ));
                    return;
                }
                if let Some(name) = node_symbol(node) {
                    if self.known_return_type(&name).is_none() {
                        reasons.insert(format!("forwarded return {name}"));
                        if let Some((receiver, _, _)) = match_call(node) {
                            self.collect_unknown_expression_reasons(receiver, reasons);
                        }
                        return;
                    }
                }
            }
            _ => {
                if let Some(ty) = self.literal_type(node) {
                    reasons.insert(format!(
                        "literal/static expression {}",
                        static_expression_reason(&ty)
                    ));
                    return;
                }
                reasons.insert(format!("operation {}", node.r#type));
            }
        }
        for child in child_nodes(node) {
            self.collect_unknown_expression_reasons(child, reasons);
        }
    }

    fn inspect_index_lookup(&mut self, node: &crate::ast::Node) {
        if self.is_prepass {
            return;
        }
        let name = node_symbol(node).unwrap_or_default();
        if name != "[]" && name != "fetch" {
            return;
        }
        let Some((receiver, _, args_node)) = match_call(node) else {
            return;
        };
        if sorbet_type_index_syntax(&receiver.text) {
            return;
        }
        let args = call_arguments(args_node);
        if args.is_empty() || (name == "fetch" && args.len() > 1) {
            return;
        }
        let receiver_type = self.expression_type(receiver);
        println!("DEBUG inspect_index_lookup: receiver={}, receiver_type={:?}, local_hash_shapes={:?}, local_array_shapes={:?}", receiver.text, receiver_type, self.local_hash_shapes, self.local_array_shapes);
        let lookup_type = self.collection_index_return_type(node, receiver_type.as_deref());
        let index_type = self.expression_type(args[0]);
        let origin = self.receiver_collection_origin(receiver);

        let code = node.text.clone();

        self.collection_index_lookups.push(json!({
            "path": self.path,
            "line": node.first_lineno,
            "enclosing_scope": self.current_owners.join("::"),
            "code": code,
            "receiver": receiver.text.clone(),
            "index": args[0].text.clone(),
            "receiver_type": receiver_type,
            "index_type": index_type,
            "lookup_type": lookup_type,
            "status": collection_index_status(receiver_type.as_deref(), lookup_type.as_deref()),
            "origin": origin,
        }));
    }

    fn collection_index_return_type(
        &mut self,
        node: &crate::ast::Node,
        receiver_type: Option<&str>,
    ) -> Option<String> {
        let Some((receiver, _, args_node)) = match_call(node) else {
            return None;
        };
        let args = call_arguments(args_node);
        if args.len() != 1 {
            return None;
        }
        if let Some(shape_type) = self.hash_shape_index_return_type(Some(receiver), args[0]) {
            if useful_type(&shape_type) {
                return Some(shape_type);
            }
        }
        let info = collection_type_info(receiver_type.unwrap_or(""))?;
        match info.kind.as_str() {
            "array" => {
                let elem = info.element?;
                if elem.is_empty() || elem.contains("T.untyped") {
                    return None;
                }
                if args[0].r#type == "RANGE" || args[0].r#type == "DOT2" || args[0].r#type == "DOT3"
                {
                    Some(self.behavior.format_array_type(&elem))
                } else if self.expression_type(args[0]).as_deref() == Some("Integer") {
                    Some(self.behavior.format_nilable_type(&elem))
                } else {
                    None
                }
            }
            "hash" => {
                let value = info.value?;
                if value.is_empty() || value.contains("T.untyped") {
                    None
                } else {
                    Some(self.behavior.format_nilable_type(&value))
                }
            }
            _ => None,
        }
    }

    fn hash_shape_index_return_type(
        &mut self,
        receiver: Option<&crate::ast::Node>,
        index: &crate::ast::Node,
    ) -> Option<String> {
        let shape = self.hash_shape_for_receiver(receiver?)?;
        if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
            return None;
        }
        let key = hash_key_name(index)?;
        let types = shape
            .get("keys")
            .and_then(|keys| keys.get(&key))
            .and_then(Value::as_array)?
            .iter()
            .filter_map(Value::as_str)
            .map(ToString::to_string)
            .collect::<Vec<_>>();
        if types.is_empty() {
            return None;
        }
        let value = static_sorbet_type(&types);
        if useful_type(&value) {
            Some(self.behavior.format_nilable_type(&value))
        } else {
            None
        }
    }

    fn hash_shape_for_receiver(&mut self, receiver: &crate::ast::Node) -> Option<Value> {
        if receiver.r#type == "ITER" {
            return child_node(receiver, 0).and_then(|c| self.hash_shape_for_receiver(c));
        }
        match receiver.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name =
                    node_symbol(receiver).unwrap_or_else(|| receiver.text.trim().to_string());
                self.local_hash_shapes.get(&name).cloned()
            }
            "HASH" | "OR" | "AND" => self.hash_shape_for_value(receiver),
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some((class_name, method, args_node)) = self.get_call_info(receiver) {
                    if receiver.r#type != "FCALL" && receiver.r#type != "VCALL" {
                        if let Some((rec, _, _)) = match_call(receiver) {
                            if (self.behavior.is_type_normalizer(&rec.text, &method)
                                || self.behavior.is_type_cast(&rec.text, &method))
                            {
                                let arg_nodes = call_arguments(args_node);
                                return arg_nodes
                                    .first()
                                    .and_then(|arg| self.hash_shape_for_receiver(arg));
                            } else if matches!(method.as_str(), "first" | "last" | "shift" | "pop" | "sample" | "[]" | "at") {
                                return self.array_element_shape_for_receiver(Some(rec));
                            }
                        }
                    }
                    if let Some(shape) = self.method_return_hash_shape_for_call(&class_name, &method) {
                        Some(shape)
                    } else if receiver.r#type != "FCALL" && receiver.r#type != "VCALL" {
                        self.struct_field_hash_shape_for_call(receiver)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn array_element_shape_for_receiver(
        &mut self,
        receiver: Option<&crate::ast::Node>,
    ) -> Option<Value> {
        let receiver = receiver?;
        if receiver.r#type == "ITER" {
            if let Some(call) = child_node(receiver, 0) {
                if let Some((_, method, _)) = match_call(call) {
                    if method == "map" || method == "collect" || method == "filter_map" {
                        if let Some(body_node) = child_nodes(receiver).last() {
                            let body_expr = implicit_return_expression(body_node).unwrap_or(body_node);
                            return self.hash_shape_for_value(body_expr);
                        }
                    }
                }
            }
            return child_node(receiver, 0).and_then(|c| self.array_element_shape_for_receiver(Some(c)));
        }
        match receiver.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name =
                    node_symbol(receiver).unwrap_or_else(|| receiver.text.trim().to_string());
                self.local_array_shapes.get(&name).cloned()
            }
            "ARRAY" | "LIST" | "OR" | "AND" => self.array_element_shape_for_value(receiver),
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some((class_name, method, args_node)) = self.get_call_info(receiver) {
                    if receiver.r#type != "FCALL" && receiver.r#type != "VCALL" {
                        if let Some((rec, _, _)) = match_call(receiver) {
                            if (self.behavior.is_type_normalizer(&rec.text, &method)
                                || self.behavior.is_type_cast(&rec.text, &method))
                            {
                                let arg_nodes = call_arguments(args_node);
                                return arg_nodes
                                    .first()
                                    .and_then(|arg| self.array_element_shape_for_receiver(Some(arg)));
                            } else if matches!(method.as_str(), "select" | "reject" | "compact") {
                                return self.array_element_shape_for_receiver(Some(rec));
                            }
                        }
                    }
                    if let Some(shape) = self.method_return_array_shape_for_call(&class_name, &method) {
                        Some(shape)
                    } else if receiver.r#type != "FCALL" && receiver.r#type != "VCALL" {
                        self.struct_field_array_shape_for_call(receiver)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn receiver_collection_origin(&mut self, node: &crate::ast::Node) -> Value {
        match node.r#type.as_str() {
            "LVAR" | "DVAR" => {
                let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
                if let Some(origin) = self.local_container_origins.get(&name) {
                    if origin.get("kind").and_then(Value::as_str) == Some("method parameter") {
                        if let Some(shape) = self.local_hash_shapes.get(&name) {
                            return merge_value(origin, &[("shape", shape.clone())]);
                        }
                    }
                    return origin.clone();
                }
                if let Some(shape) = self.local_hash_shapes.get(&name) {
                    return json!({"kind": "local hash shape", "name": name, "path": self.path, "line": node.first_lineno, "shape": shape});
                }
                json!({"kind": "local variable", "name": name})
            }
            "IVAR" | "CVAR" | "GVAR" => {
                let name = node_symbol(node).unwrap_or_else(|| node.text.trim().to_string());
                self.ivar_container_origins
                    .get(&name)
                    .cloned()
                    .unwrap_or_else(|| json!({"kind": "instance variable", "name": name}))
            }
            "ARRAY" | "LIST" | "HASH" => self
                .container_origin_for_value(node, "literal")
                .unwrap_or_else(|| json!({"kind": node.r#type.clone(), "code": node.text.clone()})),
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some(shape) = self.hash_shape_for_receiver(node) {
                    json!({"kind": "local hash shape", "name": node.text.clone(), "path": self.path, "line": node.first_lineno, "shape": shape})
                } else {
                    let callee = node_symbol(node).unwrap_or_default();
                    json!({"kind": "forwarded return", "callee": callee, "path": self.path, "line": node.first_lineno, "code": node.text.clone()})
                }
            }
            _ => json!({"kind": node.r#type.clone(), "code": node.text.clone()}),
        }
    }

    fn container_origin_for_value(
        &mut self,
        value: &crate::ast::Node,
        name: &str,
    ) -> Option<Value> {
        if value.r#type == "AND" {
            let callee = if let Some((_, m, _)) = match_call(value) {
                m
            } else {
                String::new()
            };
            return Some(json!({
                "kind": "forwarded return",
                "name": name,
                "path": self.path,
                "line": value.first_lineno,
                "code": value.text.clone(),
                "callee": callee,
            }));
        }
        match value.r#type.as_str() {
            "ARRAY" | "LIST" => {
                let types = child_nodes(value)
                    .into_iter()
                    .filter_map(|elem| self.expression_type(elem))
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect::<Vec<_>>();
                Some(json!({
                    "kind": "array literal",
                    "name": name,
                    "path": self.path,
                    "line": value.first_lineno,
                    "code": value.text.clone(),
                    "array_element_types": types,
                }))
            }
            "HASH" => {
                let mut key_types = BTreeSet::new();
                let mut value_types = BTreeSet::new();
                for pair in child_nodes(value) {
                    if pair.r#type == "pair" || pair.r#type == "PAIR" || pair.r#type == "HASH" {
                        if let Some(key) = child_node(pair, 0) {
                            if let Some(ty) = self.expression_type(key) {
                                key_types.insert(ty);
                            }
                        }
                        if let Some(val) = child_node(pair, 1) {
                            if let Some(ty) = self.expression_type(val) {
                                value_types.insert(ty);
                            }
                        }
                    }
                }
                Some(json!({
                    "kind": "hash literal",
                    "name": name,
                    "path": self.path,
                    "line": value.first_lineno,
                    "code": value.text.clone(),
                    "hash_key_types": key_types.into_iter().collect::<Vec<_>>(),
                    "hash_value_types": value_types.into_iter().collect::<Vec<_>>(),
                }))
            }
            "LVAR" | "DVAR" => {
                let text = node_symbol(value).unwrap_or_else(|| value.text.trim().to_string());
                self.local_container_origins.get(&text).map(|origin| {
                    merge_value(origin, &[("name", json!(name)), ("alias_of", json!(text))])
                })
            }
            "IVAR" | "CVAR" | "GVAR" => {
                let text = node_symbol(value).unwrap_or_else(|| value.text.trim().to_string());
                self.ivar_container_origins.get(&text).map(|origin| {
                    merge_value(origin, &[("name", json!(name)), ("alias_of", json!(text))])
                })
            }
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                let callee = node_symbol(value).unwrap_or_default();
                Some(json!({
                    "kind": "forwarded return",
                    "name": name,
                    "path": self.path,
                    "line": value.first_lineno,
                    "code": value.text.clone(),
                    "callee": callee,
                }))
            }
            _ => None,
        }
    }

    fn inspect_hash_record_blocker(&mut self, node: &crate::ast::Node) {
        if self.is_prepass {
            return;
        }
        let Some((receiver, name, args_node)) = match_call(node) else {
            return;
        };
        let args = call_arguments(args_node);
        if name == "[]" || name == "fetch" {
            if name == "fetch" && args.len() > 1 {
                return;
            }
            if args.is_empty() || hash_key_name(args[0]).is_some() {
                return;
            }
            let origin = self.hash_record_blocker_origin_for_receiver(receiver);
            if !hash_record_blocker_origin(&origin) {
                return;
            }
            let code = node.text.clone();
            self.hash_record_blockers.push(json!({
                "path": self.path,
                "line": node.first_lineno,
                "enclosing_scope": self.current_owners.join("::"),
                "kind": "dynamic_key",
                "code": code,
                "receiver": receiver.text.clone(),
                "index": args.first().map(|arg| arg.text.clone()),
                "origin": origin,
                "message": "dynamic hash-record key prevents struct accessor rewrite",
            }));
        } else if matches!(
            name.as_str(),
            "[]=" | "merge!" | "update" | "delete" | "clear" | "shift"
        ) {
            let origin = self.hash_record_blocker_origin_for_receiver(receiver);
            if !hash_record_blocker_origin(&origin) {
                return;
            }
            self.hash_record_blockers.push(json!({
                "path": self.path,
                "line": node.first_lineno,
                "enclosing_scope": self.current_owners.join("::"),
                "kind": "mutation",
                "code": node.text.clone(),
                "receiver": receiver.text.clone(),
                "origin": origin,
                "message": "shape-changing hash-record mutation prevents broad struct rewrite",
            }));
        }
    }

    fn hash_record_blocker_origin_for_receiver(&mut self, receiver: &crate::ast::Node) -> Value {
        let origin = self.receiver_collection_origin(receiver);
        if hash_record_blocker_origin(&origin) {
            return origin;
        }
        if receiver.r#type == "LVAR" || receiver.r#type == "DVAR" {
            let name = node_symbol(receiver).unwrap_or_else(|| receiver.text.trim().to_string());
            if let Some(shape) = self.local_hash_shapes.get(&name) {
                return json!({"kind": "local hash shape", "name": name, "path": self.path, "line": receiver.first_lineno, "shape": shape});
            }
        }
        origin
    }

    fn inspect_hash_record_member_call(&mut self, node: &crate::ast::Node) {
        if self.is_prepass {
            return;
        }
        let Some((receiver, name, _)) = match_call(node) else {
            return;
        };
        let receiver_name = node_symbol(receiver).unwrap_or_default();
        if receiver_name != "[]" && receiver_name != "fetch" {
            return;
        }
        let Some((inner_receiver, _, args_node)) = match_call(receiver) else {
            return;
        };
        let args = call_arguments(args_node);
        if receiver_name == "fetch" && args.len() > 1 {
            return;
        }
        let Some(key) = args.first().and_then(|arg| hash_key_name(*arg)) else {
            return;
        };

        let origin = self.receiver_collection_origin(inner_receiver);
        if !hash_record_blocker_origin(&origin)
            && origin.get("kind").and_then(Value::as_str) != Some("local hash shape")
        {
            return;
        }
        self.hash_record_member_calls.push(json!({
            "path": self.path,
            "line": node.first_lineno,
            "enclosing_scope": self.current_owners.join("::"),
            "field": key,
            "member": name,
            "code": node.text.clone(),
            "lookup_code": receiver.text.clone(),
            "receiver": inner_receiver.text.clone(),
            "origin": origin,
        }));
    }

    fn inspect_dispatcher(&mut self, node: &crate::ast::Node, line: usize) {
        if self.current_params.is_empty() {
            return;
        }
        let param = &self.current_params[0];
        let mut arms = Vec::new();
        collect_dispatch_arms(node, param, &mut arms);

        let mut grouped = BTreeMap::<String, BTreeSet<String>>::new();
        for (helper, classes) in arms {
            grouped.entry(helper).or_default().extend(classes);
        }
        let owner = self.current_owners.last().cloned().unwrap_or_default();
        let method = self.current_method.clone().unwrap_or_default();
        for (helper, classes) in grouped {
            if classes.is_empty() {
                continue;
            }
            let classes_vec = classes.into_iter().collect::<Vec<_>>();
            let ty = if classes_vec.len() == 1 {
                classes_vec[0].clone()
            } else {
                format!("T.any({})", classes_vec.join(", "))
            };
            self.dispatcher_inferences.push(json!({
                "path": self.path,
                "line": line,
                "class": owner,
                "kind": self.current_method_kind,
                "dispatcher": method,
                "helper": helper,
                "type": ty,
                "classes": classes_vec,
            }));
        }
    }

    fn inspect_struct_constructor(&mut self, node: &crate::ast::Node) {
        if let Some((receiver, method, args_node)) = match_call(node) {
            if method != "new" {
                return;
            }
            let klass = receiver.text.trim().to_string();
            if let Some(decl) = self.find_struct_declaration(&klass) {
                let full_class = decl.class.clone();
                let fields = decl.fields.clone();
                let args = call_arguments(args_node);
                for (idx, arg) in args.iter().enumerate() {
                    if idx >= fields.len() {
                        continue;
                    }
                    if arg.r#type == "pair" || arg.r#type == "PAIR" || arg.r#type == "HASH" {
                        continue;
                    }
                    let ty = self
                        .expression_type(arg)
                        .unwrap_or_else(|| self.behavior.untyped_type());
                    let key = state_key(&full_class, &fields[idx]);
                    if !self.is_prepass {
                        self.state_type_records.push(StateTypeRecord {
                            language: self.document.language.as_str().to_string(),
                            path: self.path.to_string(),
                            owner: full_class.clone(),
                            field: fields[idx].clone(),
                            declared_type: ty,
                            type_references: Vec::new(),
                            line: node.first_lineno,
                            span: Some([
                                node.first_lineno,
                                node.first_column,
                                node.last_lineno,
                                node.last_column,
                            ]),
                            key,
                        });
                    }
                    if let Some(shape) = self.hash_shape_for_value(arg) {
                        self.struct_field_hash_shapes.insert((full_class.clone(), fields[idx].clone()), shape);
                    }
                    if let Some(shape) = self.array_element_shape_for_value(arg) {
                        self.struct_field_array_shapes.insert((full_class.clone(), fields[idx].clone()), shape);
                    }
                }
            }
        }
    }

    fn inspect_class_constructor_fields(&mut self, node: &crate::ast::Node) {
        if let Some((receiver, method, args_node)) = match_call(node) {
            if method != "new" {
                return;
            }
            let klass = receiver.text.trim().to_string();
            if klass.is_empty() || klass == "Struct" {
                return;
            }
            let args = call_arguments(args_node);
            for arg in args {
                if arg.r#type == "pair" || arg.r#type == "PAIR" || arg.r#type == "HASH" {
                    if let Some(value_node) = child_node(arg, 1) {
                        if let Some(key_node) = child_node(arg, 0) {
                            if let Some(field) = hash_key_name(key_node) {
                                let ty = self
                                    .expression_type(value_node)
                                    .unwrap_or_else(|| self.behavior.untyped_type());
                                let key = state_key(&klass, &field);
                                if !self.is_prepass {
                                    self.state_type_records.push(StateTypeRecord {
                                        language: self.document.language.as_str().to_string(),
                                        path: self.path.to_string(),
                                        owner: klass.clone(),
                                        field: field.clone(),
                                        declared_type: ty,
                                        type_references: Vec::new(),
                                        line: node.first_lineno,
                                        span: Some([
                                            node.first_lineno,
                                            node.first_column,
                                            node.last_lineno,
                                            node.last_column,
                                        ]),
                                        key,
                                    });
                                }
                                if let Some(shape) = self.hash_shape_for_value(value_node) {
                                    println!("DEBUG inspect_class_constructor_fields: inserting hash shape class={}, field={}, shape={:?}", klass, field, shape);
                                    self.struct_field_hash_shapes.insert((klass.clone(), field.clone()), shape);
                                }
                                if let Some(shape) = self.array_element_shape_for_value(value_node) {
                                    println!("DEBUG inspect_class_constructor_fields: inserting array shape class={}, field={}, shape={:?}", klass, field, shape);
                                    self.struct_field_array_shapes.insert((klass.clone(), field.clone()), shape);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    fn inspect_struct_declaration(&mut self, _node: &crate::ast::Node) {}

    fn inspect_attribute_assignment(&mut self, node: &crate::ast::Node) {
        if let Some((rec, method, args_node)) = match_call(node) {
            if method.ends_with('=') {
                let field = method.trim_end_matches('=').to_string();
                let arg_children = call_arguments(args_node);
                let val_node = arg_children
                    .last()
                    .map(|n| *n)
                    .unwrap_or(args_node);
                let class_name = if let Some(receiver_type) = self.expression_type(rec) {
                    receiver_type.replace("T.nilable(", "").replace(")", "")
                } else {
                    self.behavior.untyped_type()
                };
                if let Some(shape) = self.hash_shape_for_value(val_node) {
                    self.struct_field_hash_shapes.insert((class_name.clone(), field.clone()), shape);
                }
                if let Some(shape) = self.array_element_shape_for_value(val_node) {
                    self.struct_field_array_shapes.insert((class_name, field), shape);
                }
            }
        }
    }

    fn inspect_array_literal(&mut self, node: &crate::ast::Node) {
        if self.is_prepass {
            return;
        }
        let elements = child_nodes(node);
        if elements.len() < 2
            || elements.iter().any(|elem| {
                elem.r#type == "splat_argument" || elem.r#type == "SPLAT" || elem.r#type == "splat"
            })
        {
            return;
        }
        let mut values = Vec::new();
        for elem in &elements {
            if let Some(ty) = self.expression_type(elem) {
                values.push(ty);
            } else {
                return;
            }
        }
        let unique = values.iter().collect::<BTreeSet<_>>();
        if unique.len() < 2 {
            return;
        }
        self.tuple_arrays.push(json!({
            "path": self.path,
            "line": node.first_lineno,
            "size": values.len(),
            "types": values,
            "confidence": tuple_confidence(&values),
            "code": node.text.clone(),
        }));
    }

    fn inspect_hash_literal(&mut self, node: &crate::ast::Node) {
        if self.is_prepass {
            return;
        }
        let pairs: Vec<&crate::ast::Node> = child_nodes(node)
            .into_iter()
            .filter(|child| {
                child.r#type == "pair" || child.r#type == "PAIR" || child.r#type == "HASH"
            })
            .collect();
        if pairs.is_empty() {
            return;
        }
        let mut keys = Vec::new();
        let mut values = Vec::new();
        let mut value_hash_shapes = serde_json::Map::new();
        let mut value_array_shapes = serde_json::Map::new();
        for pair in &pairs {
            let Some(key_node) = child_node(pair, 0) else {
                continue;
            };
            let Some(value_node) = child_node(pair, 1) else {
                continue;
            };
            let Some(key) = hash_key_name(key_node) else {
                continue;
            };
            keys.push(key.clone());
            let val_ty = self
                .expression_type(value_node)
                .unwrap_or_else(|| self.behavior.untyped_type());
            values.push(json!(val_ty));
            if let Some(shape) = self.hash_shape_for_value(value_node) {
                value_hash_shapes.insert(key.clone(), shape);
            }
            if let Some(shape) = self.array_element_shape_for_value(value_node) {
                value_array_shapes.insert(key, shape);
            }
        }
        if keys.len() < 2 || keys.len() != pairs.len() {
            return;
        }
        self.hash_shapes.push(HashShape {
            path: self.path.to_string(),
            line: node.first_lineno,
            keys: keys.clone(),
            value_types: values
                .iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .collect(),
            code: node.text.clone(),
            value_hash_shapes: if value_hash_shapes.is_empty() {
                None
            } else {
                Some(value_hash_shapes.into_iter().collect())
            },
            value_array_element_shapes: if value_array_shapes.is_empty() {
                None
            } else {
                Some(value_array_shapes.into_iter().collect())
            },
        });
    }

    fn find_struct_declaration(&self, class_name: &str) -> Option<StructDeclaration> {
        let clean_name = class_name.trim_start_matches("::");
        if let Some(decl) = self
            .struct_declarations
            .iter()
            .find(|d| d.class.trim_start_matches("::") == clean_name)
        {
            return Some(decl.clone());
        }
        let short_name = clean_name.rsplit("::").next().unwrap_or(clean_name);
        if let Some(decl) = self.struct_declarations.iter().find(|d| {
            let decl_clean = d.class.trim_start_matches("::");
            decl_clean == short_name || decl_clean.ends_with(&format!("::{short_name}"))
        }) {
            return Some(decl.clone());
        }
        None
    }

    fn inspect_local_container_origin(&mut self, node: &crate::ast::Node) {
        let Some(name) = node_symbol(node) else {
            return;
        };
        if let Some(value) = child_node(node, 1) {
            if let Some(origin) = self.container_origin_for_value(value, &name) {
                self.local_container_origins.insert(name, origin);
            } else {
                self.local_container_origins.remove(&name);
            }
        }
    }

    fn inspect_ivar_container_origin(&mut self, node: &crate::ast::Node) {
        let Some(name) = node_symbol(node) else {
            return;
        };
        if let Some(value) = child_node(node, 1) {
            if let Some(origin) = self.container_origin_for_value(value, &name) {
                self.ivar_container_origins.insert(name, origin);
            }
        }
    }

    fn update_local_fact(&mut self, node: &crate::ast::Node) {
        let Some(name) = node_symbol(node) else {
            return;
        };
        let Some(value) = child_node(node, 1) else {
            return;
        };

        if let Some(shape) = self.hash_shape_for_receiver(value) {
            self.local_hash_shapes.insert(name.clone(), shape);
        } else {
            self.local_hash_shapes.remove(&name);
        }

        if let Some(shape) = self.array_element_shape_for_receiver(Some(value)) {
            self.local_array_shapes.insert(name.clone(), shape);
        } else {
            self.local_array_shapes.remove(&name);
        }
    }

    fn check_local_escapes_and_mutations(&mut self, node: &crate::ast::Node) {
        if let Some((rec, method, args_node)) = match_call(node) {
            if rec.r#type == "LVAR" || rec.r#type == "DVAR" {
                if let Some(name) = node_symbol(rec) {
                    if matches!(method.as_str(), "[]=" | "merge!" | "update" | "delete" | "clear" | "shift") {
                        if self.local_hash_shapes.contains_key(&name) || self.local_array_shapes.contains_key(&name) {
                            self.local_hash_shapes.remove(&name);
                            self.local_array_shapes.remove(&name);
                        }
                    }
                }
            }
        }

        let (callee, args_node) = if let Some((_, callee, args_node)) = match_call(node) {
            (callee, args_node)
        } else if node.r#type == "FCALL" || node.r#type == "VCALL" || node.r#type == "SUPER" {
            let callee = node_symbol(node).unwrap_or_default();
            let args_node = node.children.iter().find_map(|c| match c {
                crate::ast::Child::Node(n) => Some(n.as_ref()),
                _ => None,
            }).unwrap_or(node);
            (callee, args_node)
        } else {
            return;
        };

        if matches!(
            callee.as_str(),
            "[]" | "fetch"
                | "each"
                | "each_pair"
                | "each_key"
                | "each_value"
                | "present?"
                | "nil?"
                | "blank?"
                | "<<"
                | "push"
                | "unshift"
                | "append"
                | "prepend"
                | "concat"
                | "add"
                | "[]="
                | "merge"
                | "merge!"
                | "update"
        ) {
            return;
        }

        for arg in call_arguments(args_node) {
            if arg.r#type == "LVAR" || arg.r#type == "DVAR" {
                if let Some(name) = node_symbol(arg) {
                    if self.local_hash_shapes.contains_key(&name) || self.local_array_shapes.contains_key(&name) {
                        self.local_hash_shapes.remove(&name);
                        self.local_array_shapes.remove(&name);
                        self.local_types.insert(name.clone(), self.behavior.untyped_type());
                    }
                }
            }
        }
    }

    fn check_literal_escapes(&mut self, node: &crate::ast::Node) {
        for child in child_nodes(node) {
            if child.r#type == "LVAR" || child.r#type == "DVAR" {
                if let Some(name) = node_symbol(child) {
                    if self.local_hash_shapes.contains_key(&name) || self.local_array_shapes.contains_key(&name) {
                        self.local_hash_shapes.remove(&name);
                        self.local_array_shapes.remove(&name);
                        self.local_types.insert(name.clone(), self.behavior.untyped_type());
                    }
                }
            } else if child.r#type == "pair" || child.r#type == "PAIR" || child.r#type == "HASH" {
                if let Some(val_node) = child_node(child, 1) {
                    if val_node.r#type == "LVAR" || val_node.r#type == "DVAR" {
                        if let Some(name) = node_symbol(val_node) {
                            if self.local_hash_shapes.contains_key(&name) || self.local_array_shapes.contains_key(&name) {
                                self.local_hash_shapes.remove(&name);
                                self.local_array_shapes.remove(&name);
                                self.local_types.insert(name.clone(), self.behavior.untyped_type());
                            }
                        }
                    }
                }
            }
        }
    }

    fn hash_shape_for_value(&mut self, value: &crate::ast::Node) -> Option<Value> {
        match value.r#type.as_str() {
            "LASGN" | "DASGN" | "IASGN" | "CASGN" | "CVASGN" | "GVASGN" | "ATTRASGN" => {
                let val_node = if value.r#type == "ATTRASGN" {
                    child_node(value, 2).and_then(|args| child_nodes(args).last().copied())
                } else {
                    child_node(value, 1)
                };
                eprintln!("DEBUG hash_shape_for_value: type={}, val_node={:?}", value.r#type, val_node.map(|n| &n.r#type));
                val_node.and_then(|val| self.hash_shape_for_value(val))
            }
            "HASH" => {
                eprintln!("DEBUG hash_shape_for_value HASH node: text={}, children={:?}", value.text, child_nodes(value).iter().map(|c| &c.r#type).collect::<Vec<_>>());
                let mut keys = serde_json::Map::new();
                let mut value_hash_shapes = serde_json::Map::new();
                let mut value_array_shapes = serde_json::Map::new();
                let mut poisoned = false;
                for pair in child_nodes(value) {
                    if pair.r#type == "pair" || pair.r#type == "PAIR" || pair.r#type == "HASH" {
                        let Some(key_node) = child_node(pair, 0) else {
                            continue;
                        };
                        let Some(value_node) = child_node(pair, 1) else {
                            continue;
                        };
                        if let Some(key) = hash_key_name(key_node) {
                            let ty = self
                                .expression_type(value_node)
                                .unwrap_or_else(|| self.behavior.untyped_type());
                            let typed_value = useful_type(&ty) || ty == "NilClass";
                            let shape_type = if typed_value {
                                ty.clone()
                            } else {
                                self.behavior.untyped_type()
                            };
                            let entry = keys.entry(key.clone()).or_insert_with(|| json!([]));
                            if let Some(array) = entry.as_array_mut() {
                                if !array
                                    .iter()
                                    .any(|entry| entry.as_str() == Some(&shape_type))
                                {
                                    array.push(json!(shape_type));
                                }
                            }
                            if typed_value {
                                if let Some(nested) = self.hash_shape_for_value(value_node) {
                                    value_hash_shapes.insert(key.clone(), nested);
                                }
                                if let Some(nested) = self.array_element_shape_for_value(value_node)
                                {
                                    value_array_shapes.insert(key, nested);
                                }
                            }
                        } else {
                            poisoned = true;
                        }
                    }
                }
                Some(json!({
                    "keys": keys,
                    "value_hash_shapes": value_hash_shapes,
                    "value_array_element_shapes": value_array_shapes,
                    "poisoned": poisoned,
                }))
            }
            "LVAR" | "DVAR" => {
                let name = node_symbol(value).unwrap_or_else(|| value.text.trim().to_string());
                self.local_hash_shapes.get(&name).cloned()
            }
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some((class_name, method, args_node)) = self.get_call_info(value) {
                    if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        if let Some((rec, _, _)) = match_call(value) {
                            if (self.behavior.is_type_normalizer(&rec.text, &method)
                                || self.behavior.is_type_cast(&rec.text, &method))
                            {
                                let arg_nodes = call_arguments(args_node);
                                return arg_nodes
                                    .first()
                                    .and_then(|arg| self.hash_shape_for_value(arg));
                            } else if matches!(method.as_str(), "first" | "last" | "shift" | "pop" | "sample" | "[]" | "at") {
                                return self.array_element_shape_for_receiver(Some(rec));
                            }
                        }
                    }
                    if let Some(shape) = self.method_return_hash_shape_for_call(&class_name, &method) {
                        Some(shape)
                    } else if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        self.struct_field_hash_shape_for_call(value)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            "OR" | "AND" => {
                let left = child_node(value, 0).and_then(|c| self.hash_shape_for_value(c));
                let right = child_node(value, 1).and_then(|c| self.hash_shape_for_value(c));
                match (left, right) {
                    (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                    (Some(l), None) => Some(l),
                    (None, Some(r)) => Some(r),
                    (None, None) => None,
                }
            }
            _ => None,
        }
    }

    fn array_element_shape_for_value(&mut self, value: &crate::ast::Node) -> Option<Value> {
        match value.r#type.as_str() {
            "LASGN" | "DASGN" | "IASGN" | "CASGN" | "CVASGN" | "GVASGN" | "ATTRASGN" => {
                let val_node = if value.r#type == "ATTRASGN" {
                    child_node(value, 2).and_then(|args| child_nodes(args).last().copied())
                } else {
                    child_node(value, 1)
                };
                val_node.and_then(|val| self.array_element_shape_for_value(val))
            }
            "ARRAY" | "LIST" => {
                let shapes = child_nodes(value)
                    .into_iter()
                    .filter_map(|elem| self.hash_shape_for_value(elem))
                    .collect::<Vec<_>>();
                if shapes.is_empty() {
                    None
                } else {
                    shapes.into_iter().reduce(merge_hash_record_shapes)
                }
            }
            "LVAR" | "DVAR" => {
                let name = node_symbol(value).unwrap_or_else(|| value.text.trim().to_string());
                self.local_array_shapes.get(&name).cloned()
            }
            "CALL" | "QCALL" | "OPCALL" | "FCALL" | "VCALL" => {
                if let Some((class_name, method, args_node)) = self.get_call_info(value) {
                    if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        if let Some((rec, _, _)) = match_call(value) {
                            if (self.behavior.is_type_normalizer(&rec.text, &method)
                                || self.behavior.is_type_cast(&rec.text, &method))
                            {
                                let arg_nodes = call_arguments(args_node);
                                return arg_nodes
                                    .first()
                                    .and_then(|arg| self.array_element_shape_for_value(arg));
                            } else if matches!(method.as_str(), "first" | "last" | "shift" | "pop" | "sample" | "[]" | "at") {
                                return self.array_element_shape_for_receiver(Some(rec));
                            }
                        }
                    }
                    if let Some(shape) = self.method_return_array_shape_for_call(&class_name, &method) {
                        Some(shape)
                    } else if value.r#type != "FCALL" && value.r#type != "VCALL" {
                        self.struct_field_array_shape_for_call(value)
                    } else {
                        None
                    }
                } else {
                    None
                }
            }
            "ITER" => {
                println!("DEBUG array_element_shape_for_value ITER: value.text={}", value.text);
                if let Some(call_node) = child_node(value, 0) {
                    println!("DEBUG array_element_shape_for_value ITER call_node: {}", call_node.text);
                    if let Some((_, method, _)) = match_call(call_node) {
                        println!("DEBUG array_element_shape_for_value ITER method: {}", method);
                        if method == "map" || method == "collect" {
                            let mut p0_name = None;
                            if let Some(block) = child_node(value, 1) {
                                let mut args_node = None;
                                for child in child_nodes(&block) {
                                    if child.r#type == "ARGS" {
                                        args_node = Some(child);
                                        break;
                                    }
                                }
                                if let Some(args) = args_node {
                                    let param_names = collect_block_param_names(&args);
                                    if let Some(p0) = param_names.get(0) {
                                        p0_name = Some(p0.clone());
                                    }
                                }
                            }
                            let old_shape = p0_name.as_ref().and_then(|p0| self.local_hash_shapes.get(p0).cloned());
                            if let Some(ref p0) = p0_name {
                                if let Some((rec, _, _)) = match_call(call_node) {
                                    if let Some(shape) = self.array_element_shape_for_receiver(Some(rec)) {
                                        self.local_hash_shapes.insert(p0.clone(), shape);
                                    }
                                }
                            }

                            let mut res = None;
                            if let Some(body_node) = child_nodes(value).last() {
                                println!("DEBUG array_element_shape_for_value ITER body_node: {}, type={}", body_node.text, body_node.r#type);
                                let body_expr = implicit_return_expression(body_node).unwrap_or(body_node);
                                println!("DEBUG array_element_shape_for_value ITER body_expr: {}, type={}", body_expr.text, body_expr.r#type);
                                res = self.hash_shape_for_value(body_expr);
                                println!("DEBUG array_element_shape_for_value ITER result: {:?}", res);
                            } else {
                                println!("DEBUG array_element_shape_for_value ITER body_node is None");
                            }

                            if let Some(ref p0) = p0_name {
                                if let Some(old) = old_shape {
                                    self.local_hash_shapes.insert(p0.clone(), old);
                                } else {
                                    self.local_hash_shapes.remove(p0);
                                }
                            }
                            res
                        } else {
                            println!("DEBUG array_element_shape_for_value ITER method is not map/collect");
                            None
                        }
                    } else {
                        println!("DEBUG array_element_shape_for_value ITER match_call failed");
                        None
                    }
                } else {
                    println!("DEBUG array_element_shape_for_value ITER call_node is None");
                    None
                }
            }
            "OR" | "AND" => {
                let left = child_node(value, 0).and_then(|c| self.array_element_shape_for_value(c));
                let right = child_node(value, 1).and_then(|c| self.array_element_shape_for_value(c));
                match (left, right) {
                    (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                    (Some(l), None) => Some(l),
                    (None, Some(r)) => Some(r),
                    (None, None) => None,
                }
            }
            _ => None,
        }
    }

    fn struct_field_hash_shape_for_call(&self, node: &crate::ast::Node) -> Option<Value> {
        let (rec, method, _) = match_call(node)?;
        let mut found_shape = None;
        if let Some(receiver_type) = self.expression_type(rec) {
            let class = receiver_type.replace("T.nilable(", "").replace(")", "");
            let key = (class, method.clone());
            found_shape = self.struct_field_hash_shapes.get(&key).cloned();
        }
        if found_shape.is_none() {
            let matching_shapes = self.struct_field_hash_shapes.iter()
                .filter(|((_, field), _)| field == &method)
                .map(|(_, shape)| shape)
                .collect::<Vec<_>>();
            if matching_shapes.len() == 1 {
                found_shape = Some(matching_shapes[0].clone());
            }
        }
        found_shape
    }

    fn struct_field_array_shape_for_call(&self, node: &crate::ast::Node) -> Option<Value> {
        let (rec, method, _) = match_call(node)?;
        let mut found_shape = None;
        if let Some(receiver_type) = self.expression_type(rec) {
            let class = receiver_type.replace("T.nilable(", "").replace(")", "");
            let key = (class, method.clone());
            found_shape = self.struct_field_array_shapes.get(&key).cloned();
        }
        if found_shape.is_none() {
            let matching_shapes = self.struct_field_array_shapes.iter()
                .filter(|((_, field), _)| field == &method)
                .map(|(_, shape)| shape)
                .collect::<Vec<_>>();
            if matching_shapes.len() == 1 {
                found_shape = Some(matching_shapes[0].clone());
            }
        }
        println!("DEBUG struct_field_array_shape_for_call: node={}, method={}, found={:?}", node.text, method, found_shape);
        found_shape
    }
}

fn hash_key_name(node: &crate::ast::Node) -> Option<String> {
    match node.r#type.as_str() {
        "SYM" | "SYMBOL" => {
            let text = node.text.trim();
            Some(
                text.trim_start_matches(':')
                    .trim_end_matches(':')
                    .to_string(),
            )
        }
        "LIT" => {
            if let Some(sym) = node_symbol(node) {
                let s = sym.trim_start_matches(':').trim_end_matches(':').to_string();
                Some(unquote(&s))
            } else {
                let text = node.text.trim();
                if text.starts_with(':') || text.ends_with(':') {
                    Some(text.trim_start_matches(':').trim_end_matches(':').to_string())
                } else {
                    None
                }
            }
        }
        "STR" | "STRING" | "STRING_LITERAL" => Some(unquote(&node.text)),
        "LVAR" | "DVAR" | "IVAR" | "CVAR" | "GVAR" | "CALL" | "QCALL" | "OPCALL" | "VCALL" | "FCALL" => None,
        _ => {
            if let Some(sym) = node_symbol(node) {
                let s = sym.trim_start_matches(':').trim_end_matches(':').to_string();
                Some(unquote(&s))
            } else {
                None
            }
        }
    }
}

fn case_literal_values(case_node: &crate::ast::Node) -> Vec<Value> {
    child_nodes(case_node)
        .into_iter()
        .filter(|child| child.r#type == "WHEN")
        .flat_map(|when_node| {
            let children = child_nodes(when_node);
            if children.is_empty() {
                Vec::new()
            } else {
                let count = children.len() - 1;
                children
                    .into_iter()
                    .take(count)
                    .flat_map(|condition| hidden_enum_literal_values(condition))
                    .collect::<Vec<_>>()
            }
        })
        .collect()
}

fn hidden_enum_literal_values(node: &crate::ast::Node) -> Vec<Value> {
    match node.r#type.as_str() {
        "SYM" | "SYMBOL" | "LIT" => hash_key_name(node)
            .map(|name| vec![json!({ "kind": "Symbol", "value": format!(":{name}") })])
            .unwrap_or_default(),
        "STR" | "STRING" | "STRING_LITERAL" => {
            if node.text.contains("#{") {
                Vec::new()
            } else {
                let val = unquote(&node.text);
                let value = serde_json::to_string(&val).unwrap_or_else(|_| "\"\"".to_string());
                vec![json!({ "kind": "String", "value": value })]
            }
        }
        "ARRAY" | "LIST" => child_nodes(node)
            .into_iter()
            .flat_map(|child| hidden_enum_literal_values(child))
            .collect(),
        "PAREN" => child_nodes(node)
            .into_iter()
            .flat_map(|child| hidden_enum_literal_values(child))
            .collect(),
        _ => Vec::new(),
    }
}

fn collection_append_method(name: &str) -> bool {
    matches!(
        name,
        "<<" | "push" | "unshift" | "append" | "prepend" | "concat" | "add"
    )
}

fn merge_hash_record_shapes(left: Value, right: Value) -> Value {
    let mut out = json!({"keys": {}, "value_hash_shapes": {}, "value_array_element_shapes": {}, "poisoned": false});
    let poisoned = left
        .get("poisoned")
        .and_then(Value::as_bool)
        .unwrap_or(false)
        || right
            .get("poisoned")
            .and_then(Value::as_bool)
            .unwrap_or(false);
    object_insert(&mut out, "poisoned", json!(poisoned));
    for shape in [&left, &right] {
        if let Some(keys) = shape.get("keys").and_then(Value::as_object) {
            for (key, values) in keys {
                let existing = out
                    .get_mut("keys")
                    .and_then(Value::as_object_mut)
                    .unwrap()
                    .entry(key.clone())
                    .or_insert_with(|| json!([]));
                if let Some(array) = existing.as_array_mut() {
                    for value in values.as_array().into_iter().flatten() {
                        if !array.contains(value) {
                            array.push(value.clone());
                        }
                    }
                }
            }
        }
        for map_name in ["value_hash_shapes", "value_array_element_shapes"] {
            if let Some(map) = shape.get(map_name).and_then(Value::as_object) {
                for (key, nested) in map {
                    out.get_mut(map_name)
                        .and_then(Value::as_object_mut)
                        .unwrap()
                        .insert(key.clone(), nested.clone());
                }
            }
        }
    }
    out
}

fn object_insert(value: &mut Value, key: &str, entry: Value) {
    if let Some(obj) = value.as_object_mut() {
        obj.insert(key.to_string(), entry);
    }
}

fn merge_value(base: &Value, entries: &[(&str, Value)]) -> Value {
    let mut out = base.clone();
    for (key, value) in entries {
        object_insert(&mut out, key, value.clone());
    }
    out
}

fn nilable_type(type_text: &str) -> String {
    if type_text == "NilClass" || type_text.starts_with("T.nilable(") {
        type_text.to_string()
    } else {
        format!("T.nilable({type_text})")
    }
}

fn collection_index_status(receiver_type: Option<&str>, lookup_type: Option<&str>) -> &'static str {
    if lookup_type.is_some_and(|ty| useful_type(ty) && !weak_type(ty)) {
        return "typed lookup";
    }
    let text = receiver_type.unwrap_or("");
    if text.is_empty() {
        return "unknown receiver type";
    }
    if text.contains("T.untyped") {
        return "weak collection receiver";
    }
    if text.starts_with("Array")
        || text.starts_with("Hash")
        || text.starts_with("T::Array")
        || text.starts_with("T::Hash")
    {
        return "typed collection receiver";
    }
    "non-collection or unresolved receiver"
}

fn sorbet_type_index_syntax(text: &str) -> bool {
    matches!(
        text,
        "Array"
            | "Hash"
            | "Set"
            | "Enumerable"
            | "T::Array"
            | "T::Hash"
            | "T::Set"
            | "T::Enumerable"
    ) || text.starts_with("T::")
}

struct CollectionInfo {
    kind: String,
    element: Option<String>,
    value: Option<String>,
}

fn collection_type_info(type_text: &str) -> Option<CollectionInfo> {
    let raw = strip_nilable_type(type_text.trim());
    if raw.is_empty() {
        return None;
    }
    parse_collection_type(&raw)
}

fn parse_collection_type(raw: &str) -> Option<CollectionInfo> {
    for (prefix, kind) in [
        ("T::Array", "array"),
        ("Array", "array"),
        ("T::Hash", "hash"),
        ("Hash", "hash"),
        ("T::Set", "set"),
        ("Set", "set"),
    ] {
        if raw == prefix {
            return Some(CollectionInfo {
                kind: kind.to_string(),
                element: None,
                value: None,
            });
        }
        let bracket = format!("{prefix}[");
        if raw.starts_with(&bracket) && raw.ends_with(']') {
            let inner = &raw[bracket.len()..raw.len() - 1];
            let parts = split_top_level_params(inner);
            return Some(CollectionInfo {
                kind: kind.to_string(),
                element: parts.first().cloned(),
                value: parts.get(1).cloned(),
            });
        }
    }
    None
}

fn collect_block_param_names(args_node: &crate::ast::Node) -> Vec<String> {
    let mut names = Vec::new();
    for child in child_nodes(args_node) {
        if child.r#type == "LASGN" || child.r#type == "DASGN" || child.r#type == "LVAR" || child.r#type == "DVAR" {
            if let Some(name) = node_symbol(child) {
                names.push(name);
            } else {
                names.push(child.text.trim().to_string());
            }
        }
    }
    names
}

fn extract_param_entries(sig: &str) -> Vec<(String, String)> {
    let Some(params) = extract_call_args(sig, "params") else {
        return Vec::new();
    };
    split_top_level_params(&params)
        .into_iter()
        .filter_map(|entry| {
            let (name, ty) = entry.split_once(':')?;
            Some((name.trim().to_string(), ty.trim().to_string()))
        })
        .collect()
}

fn static_expression_reason(type_text: &str) -> String {
    if type_text.starts_with("T.class_of(") && type_text.ends_with(')') {
        format!(
            "class constant {}",
            type_text
                .trim_start_matches("T.class_of(")
                .trim_end_matches(')')
        )
    } else {
        type_text.to_string()
    }
}

fn hash_record_blocker_origin(origin: &Value) -> bool {
    matches!(
        origin.get("kind").and_then(Value::as_str),
        Some(
            "hash literal"
                | "method parameter"
                | "forwarded return"
                | "instance variable"
                | "local hash shape"
        )
    )
}

fn value_array(value: Option<&Value>) -> Vec<Value> {
    value.and_then(Value::as_array).cloned().unwrap_or_default()
}

fn call_receiver_name(call_node: &crate::ast::Node) -> Option<String> {
    if let Some((receiver, _, _)) = match_call(call_node) {
        if receiver.r#type == "CONST" || receiver.r#type == "COLON2" || receiver.r#type == "COLON3"
        {
            Some(receiver.text.trim().to_string())
        } else {
            Some(receiver.text.clone())
        }
    } else {
        None
    }
}

fn single_statement_expression(node: &crate::ast::Node) -> Option<&crate::ast::Node> {
    match node.r#type.as_str() {
        "BLOCK" | "STATEMENTS" | "BEGIN" | "SCOPE" => {
            let children = child_nodes(node);
            if children.len() == 1 {
                single_statement_expression(children[0])
            } else {
                None
            }
        }
        _ => Some(node),
    }
}

fn dispatch_helper_call(when_node: &crate::ast::Node, param_name: &str) -> Option<String> {
    let children = child_nodes(when_node);
    if children.is_empty() {
        return None;
    }
    let body = children.last()?;
    let expr = single_statement_expression(body)?;
    if expr.r#type == "FCALL" {
        let name = node_symbol(expr)?;
        if let Some(args_node) = child_node(expr, 1) {
            let args = call_arguments(args_node);
            if args.len() == 1 {
                let arg = args[0];
                if (arg.r#type == "LVAR" || arg.r#type == "DVAR") && arg.text.trim() == param_name {
                    return Some(name);
                }
            }
        }
    } else if expr.r#type == "CALL" || expr.r#type == "QCALL" {
        let (receiver, method, args_node) = match_call(expr)?;
        if receiver.r#type == "self" || receiver.text.trim() == "self" {
            let args = call_arguments(args_node);
            if args.len() == 1 {
                let arg = args[0];
                if (arg.r#type == "LVAR" || arg.r#type == "DVAR") && arg.text.trim() == param_name {
                    return Some(method);
                }
            }
        }
    }
    None
}

fn collect_classes(node: &crate::ast::Node, classes: &mut Vec<String>) {
    if node.r#type == "CONST" || node.r#type == "COLON2" || node.r#type == "COLON3" {
        classes.push(node.text.trim().to_string());
    } else if node.r#type == "LIST" {
        for child in child_nodes(node) {
            collect_classes(child, classes);
        }
    }
}

fn collect_dispatch_arms(
    node: &crate::ast::Node,
    param_name: &str,
    arms: &mut Vec<(String, Vec<String>)>,
) {
    if node.r#type == "CASE" || node.r#type == "CASE2" {
        for child in child_nodes(node) {
            if child.r#type != "WHEN" && child.r#type != "IN" {
                continue;
            }
            let helper = dispatch_helper_call(child, param_name);
            if let Some(helper) = helper {
                let children = child_nodes(child);
                if children.len() >= 2 {
                    let count = children.len() - 1;
                    let mut classes = Vec::new();
                    for candidate in children.iter().take(count) {
                        collect_classes(candidate, &mut classes);
                    }
                    if !classes.is_empty() {
                        arms.push((helper, classes));
                    }
                }
            }
        }
    }
    for child in child_nodes(node) {
        collect_dispatch_arms(child, param_name, arms);
    }
}

fn tuple_confidence(types: &[String]) -> &'static str {
    let constants = types
        .iter()
        .filter(|ty| leading_constant_path(ty).is_some())
        .collect::<Vec<_>>();
    let namespaces = constants
        .iter()
        .filter_map(|ty| {
            ty.contains("::")
                .then(|| ty.split("::").next().unwrap_or(""))
        })
        .collect::<BTreeSet<_>>();
    if namespaces.len() == 1 && constants.len() == types.len() {
        return "review";
    }
    let unique = types.iter().collect::<BTreeSet<_>>();
    if unique.len() == types.len() {
        "high"
    } else {
        "review"
    }
}

fn leading_constant_path(type_text: &str) -> Option<&str> {
    let end = type_text
        .char_indices()
        .take_while(|(_, ch)| ch.is_ascii_alphanumeric() || *ch == '_' || *ch == ':')
        .map(|(idx, ch)| idx + ch.len_utf8())
        .last()
        .unwrap_or(0);
    let prefix = &type_text[..end];
    if prefix.is_empty() {
        return None;
    }
    let valid = prefix.split("::").all(|part| {
        part.chars()
            .next()
            .is_some_and(|ch| ch.is_ascii_uppercase())
    });
    valid.then_some(prefix)
}

fn collect_assigned_vars(node: &crate::ast::Node, vars: &mut BTreeSet<String>) {
    if node.r#type == "LASGN" || node.r#type == "DASGN" {
        if let Some(name) = node_symbol(node) {
            vars.insert(name);
        }
    }
    for child in child_nodes(node) {
        collect_assigned_vars(child, vars);
    }
}

fn merge_types(existing: &str, new_ty: &str) -> String {
    if existing == new_ty {
        return existing.to_string();
    }
    if existing == "T.untyped" {
        return new_ty.to_string();
    }
    if new_ty == "T.untyped" {
        return existing.to_string();
    }
    if existing == "NilClass" {
        if new_ty.starts_with("T.nilable(") {
            return new_ty.to_string();
        } else {
            return format!("T.nilable({})", new_ty);
        }
    }
    if new_ty == "NilClass" {
        if existing.starts_with("T.nilable(") {
            return existing.to_string();
        } else {
            return format!("T.nilable({})", existing);
        }
    }
    let clean_exist = existing.replace("T.nilable(", "").replace(")", "");
    let clean_new = new_ty.replace("T.nilable(", "").replace(")", "");
    if clean_exist == clean_new {
        return format!("T.nilable({})", clean_exist);
    }
    "T.untyped".to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::syntax::{Document, Language};
    use serde_json::json;

    fn dummy_doc() -> Document {
        serde_json::from_str(r#"{"file":"test.rb","language":"ruby"}"#).unwrap()
    }

    #[test]
    fn test_unquote_edge_cases() {
        assert_eq!(unquote("\"a\""), "a");
        assert_eq!(unquote("'b'"), "b");
        assert_eq!(unquote("\""), "\"");
        assert_eq!(unquote("'"), "'");
        assert_eq!(unquote(""), "");
    }

    #[test]
    fn test_extract_call_args_edge_cases() {
        assert_eq!(extract_call_args("foo((bar))", "foo"), Some("(bar)".to_string()));
        assert_eq!(extract_call_args("foo(bar", "foo"), None);
    }

    #[test]
    fn test_static_sorbet_type_noreturn() {
        assert_eq!(static_sorbet_type(&["T.noreturn".to_string()]), "T.noreturn");
        assert_eq!(static_sorbet_type(&["T.noreturn".to_string(), "NilClass".to_string()]), "NilClass");
        assert_eq!(static_sorbet_type(&["T.noreturn".to_string(), "Integer".to_string()]), "Integer");
        assert_eq!(extract_return_type("sig { returns(Integer) }"), Some("Integer".to_string()));
        assert_eq!(static_sorbet_type(&["T.nilable(Integer)".to_string()]), "T.nilable(Integer)");
    }

    #[test]
    fn test_merge_types_full() {
        assert_eq!(merge_types("Int", "Int"), "Int");
        assert_eq!(merge_types("T.untyped", "Int"), "Int");
        assert_eq!(merge_types("Int", "T.untyped"), "Int");
        assert_eq!(merge_types("NilClass", "T.nilable(Int)"), "T.nilable(Int)");
        assert_eq!(merge_types("NilClass", "Int"), "T.nilable(Int)");
        assert_eq!(merge_types("T.nilable(Int)", "NilClass"), "T.nilable(Int)");
        assert_eq!(merge_types("Int", "NilClass"), "T.nilable(Int)");
        assert_eq!(merge_types("T.nilable(Int)", "Int"), "T.nilable(Int)");
        assert_eq!(merge_types("Int", "T.nilable(Int)"), "T.nilable(Int)");
        assert_eq!(merge_types("Int", "String"), "T.untyped");
    }

    #[test]
    fn test_node_symbol_vcall_fcall() {
        let node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "VCALL",
            "children": [],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "my_vcall_method(args)"
        }"#).unwrap();
        assert_eq!(node_symbol(&node), Some("my_vcall_method".to_string()));

        let node2: crate::ast::Node = serde_json::from_str(r#"{
            "type": "FCALL",
            "children": [],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "my_fcall_method"
        }"#).unwrap();
        assert_eq!(node_symbol(&node2), Some("my_fcall_method".to_string()));
    }

    #[test]
    fn test_match_call_fallbacks() {
        let node1: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": ["Nil"],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "foo.bar"
        }"#).unwrap();
        assert!(match_call(&node1).is_none());

        let node2: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "SELF",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "self"
                }},
                "Nil"
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "self.nil"
        }"#).unwrap();
        assert!(match_call(&node2).is_none());
    }

    #[test]
    fn test_compare_literal_values() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let l_int = LiteralStaticValue::Integer(10);
        let r_int = LiteralStaticValue::Integer(5);
        let r_int_same = LiteralStaticValue::Integer(10);

        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "!="), Some(true));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int_same, "!="), Some(false));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, ">"), Some(true));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, ">="), Some(true));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "<"), Some(false));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "<="), Some(false));
        assert_eq!(visitor.compare_literal_values(&l_int, &r_int, "invalid_op"), None);

        // literal_values_equal other branches
        assert!(visitor.literal_values_equal(&LiteralStaticValue::String("a".to_string()), &LiteralStaticValue::String("a".to_string())));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::String("a".to_string()), &LiteralStaticValue::String("b".to_string())));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Symbol("a".to_string()), &LiteralStaticValue::Symbol("a".to_string())));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Symbol("a".to_string()), &LiteralStaticValue::Symbol("b".to_string())));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Float("1.5".to_string()), &LiteralStaticValue::Float("1.5".to_string())));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Float("1.5".to_string()), &LiteralStaticValue::Float("2.5".to_string())));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Bool(true), &LiteralStaticValue::Bool(true)));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Bool(true), &LiteralStaticValue::Bool(false)));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Nil));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Bool(false)));
    }

    #[test]
    fn test_visitor_edge_cases() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();

        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec!["MyClass".to_string()],
            current_method: Some("foo".to_string()),
            current_method_kind: "instance".to_string(),
            current_method_line: 1,
            current_method_end_line: 10,
            current_params: vec!["param1".to_string()],
            param_types: [("param1".to_string(), "Integer".to_string())].into_iter().collect(),
            local_types: [("local1".to_string(), "String".to_string())].into_iter().collect(),
            in_conditional: false,
            ivar_tlet_types: [
                (("MyClass".to_string(), "ivar1".to_string()), "Float".to_string()),
                (("MyClass".to_string(), "ivar_empty".to_string()), "".to_string()),
            ].into_iter().collect(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        assert!(visitor.known_disjoint_guard_classes("Integer", "String"));
        assert!(!visitor.known_disjoint_guard_classes("TrueClass", "T::Boolean"));
        assert!(!visitor.known_disjoint_guard_classes("T::Boolean", "TrueClass"));
        assert!(visitor.known_disjoint_guard_classes("T::Boolean", "Integer"));
        assert!(visitor.known_disjoint_guard_classes("Integer", "T::Boolean"));

        assert_eq!(visitor.ivar_expression_type("ivar1"), Some("Float".to_string()));
        assert_eq!(visitor.ivar_expression_type("ivar_empty"), None);
        assert_eq!(visitor.ivar_expression_type("ivar_missing"), None);

        assert_eq!(visitor.literal_numeric_value(&LiteralStaticValue::Integer(42)), Some(42.0));
        assert_eq!(visitor.literal_numeric_value(&LiteralStaticValue::Float("3.14".to_string())), Some(3.14));
        assert_eq!(visitor.literal_numeric_value(&LiteralStaticValue::Nil), None);

        assert!(visitor.literal_values_equal(&LiteralStaticValue::Integer(1), &LiteralStaticValue::Integer(1)));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Integer(1), &LiteralStaticValue::Integer(2)));
        assert!(visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Nil));
        assert!(!visitor.literal_values_equal(&LiteralStaticValue::Nil, &LiteralStaticValue::Integer(1)));

        let self_node = crate::ast::Node {
            r#type: "SELF".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 4,
            text: "self".to_string(),
        };
        assert!(visitor.provably_non_nil(&self_node));
    }

    #[test]
    fn test_literal_static_value() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let sym_node = crate::ast::Node {
            r#type: "SYMBOL".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: ":my_sym".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&sym_node), LiteralStaticValue::Symbol("my_sym".to_string()));

        let lit_sym = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: ":lit_sym".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_sym), LiteralStaticValue::Symbol("lit_sym".to_string()));

        let lit_int = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "123".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_int), LiteralStaticValue::Integer(123));

        let lit_float = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "12.34".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_float), LiteralStaticValue::Float("12.34".to_string()));

        let lit_unknown = crate::ast::Node {
            r#type: "LIT".to_string(),
            children: vec![],
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "unknown_lit".to_string(),
        };
        assert_eq!(visitor.literal_static_value(&lit_unknown), LiteralStaticValue::Unknown);
    }

    #[test]
    fn test_predicate_origins() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec!["param_x".to_string()],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let node_param = crate::ast::Node {
            r#type: "LVAR".to_string(),
            children: [Child::Symbol("param_x".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "param_x".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_param), (Some("param".to_string()), Some("param_x".to_string())));

        let node_local = crate::ast::Node {
            r#type: "LVAR".to_string(),
            children: [Child::Symbol("local_x".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "local_x".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_local), (Some("local".to_string()), Some("local_x".to_string())));

        let node_ivar = crate::ast::Node {
            r#type: "IVAR".to_string(),
            children: [Child::Symbol("@ivar".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "@ivar".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_ivar), (Some("ivar".to_string()), Some("@ivar".to_string())));

        let node_vcall = crate::ast::Node {
            r#type: "VCALL".to_string(),
            children: [Child::Symbol("vcall_m".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "vcall_m".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_vcall), (Some("attr".to_string()), Some("vcall_m".to_string())));

        let node_fcall = crate::ast::Node {
            r#type: "FCALL".to_string(),
            children: [Child::Symbol("fcall_m".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "fcall_m".to_string(),
        };
        assert_eq!(visitor.predicate_origin(&node_fcall), (Some("call".to_string()), Some("fcall_m".to_string())));

        let node_call_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "SELF",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "self"
                }},
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {
                            "type": "LIT",
                            "children": [],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 2,
                            "text": "1"
                        }}
                    ],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "1"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "self.my_method(1)"
        }"#).unwrap();
        assert_eq!(visitor.predicate_origin(&node_call_args), (Some("call".to_string()), Some("my_method".to_string())));
    }

    #[test]
    fn test_deterministic_nil_predicate() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec!["x".to_string()],
            param_types: [("x".to_string(), "String".to_string())].into_iter().collect(),
            local_types: [
                ("y".to_string(), "NilClass".to_string()),
                ("z".to_string(), "T.nilable(Integer)".to_string())
            ].into_iter().collect(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let call_nil_check: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "x"}],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "x"
                }},
                {"Symbol": "nil?"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "x.nil?"
        }"#).unwrap();

        let res = visitor.deterministic_nil_predicate_result(&call_nil_check);
        assert!(res.is_some());
        let res_val = res.unwrap();
        assert_eq!(res_val.get("truth_value").and_then(Value::as_bool), Some(false));

        let call_nil_check_y: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "y"}],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "y"
                }},
                {"Symbol": "nil?"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "y.nil?"
        }"#).unwrap();

        let res = visitor.deterministic_nil_predicate_result(&call_nil_check_y);
        assert!(res.is_some());
        let res_val = res.unwrap();
        assert_eq!(res_val.get("truth_value").and_then(Value::as_bool), Some(true));

        let call_nil_check_z: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "z"}],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "z"
                }},
                {"Symbol": "nil?"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "z.nil?"
        }"#).unwrap();

        let res_z = visitor.deterministic_nil_predicate_result(&call_nil_check_z);
        assert!(res_z.is_none());

        // class_guard_truth tests
        assert_eq!(visitor.class_guard_truth("Integer", "String", true), Some(false));

        // known_disjoint_guard_classes tests
        assert!(!visitor.known_disjoint_guard_classes("T::Boolean", "TrueClass"));
        assert!(!visitor.known_disjoint_guard_classes("FalseClass", "T::Boolean"));
    }

    #[test]
    fn test_hash_shape_for_value_readonly() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let hash_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {
                            "type": "SYMBOL",
                            "children": [],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 5,
                            "text": ":a"
                        }},
                        {"Node": {
                            "type": "INTEGER",
                            "children": [],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 5,
                            "text": "1"
                        }}
                    ],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": ":a => 1"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "{:a => 1}"
        }"#).unwrap();

        let extra_hash_shapes = BTreeMap::new();
        let shape = visitor.hash_shape_for_value_readonly(&hash_node, &extra_hash_shapes);
        assert!(shape.is_some());
        let val = shape.unwrap();
        assert_eq!(val.get("keys").unwrap().get("a").unwrap().as_array().unwrap().get(0).unwrap().as_str().unwrap(), "Integer");

        let array_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ARRAY",
            "children": [
                {"Node": {
                    "type": "HASH",
                    "children": [
                        {"Node": {
                            "type": "pair",
                            "children": [
                                {"Node": {
                                    "type": "SYMBOL",
                                    "children": [],
                                    "first_lineno": 1,
                                    "first_column": 1,
                                    "last_lineno": 1,
                                    "last_column": 5,
                                    "text": ":x"
                                }},
                                {"Node": {
                                    "type": "STRING",
                                    "children": [],
                                    "first_lineno": 1,
                                    "first_column": 1,
                                    "last_lineno": 1,
                                    "last_column": 5,
                                    "text": "\"hello\""
                                }}
                            ],
                            "first_lineno": 1,
                            "first_column": 1,
                            "last_lineno": 1,
                            "last_column": 10,
                            "text": ":x => \"hello\""
                        }}
                    ],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 10,
                    "text": "{:x => \"hello\"}"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "[{:x => \"hello\"}]"
        }"#).unwrap();

        let shape_arr = visitor.array_element_shape_for_value_readonly(&array_node, &extra_hash_shapes);
        assert!(shape_arr.is_some());
    }

    #[test]
    fn test_expression_type_with_locals_and_shapes() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);

        let visitor = TypeInferenceVisitor {
            behavior,
            document: &doc,
            lines: &lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites: &mut tlet_sites,
            dead_nil_checks: &mut dead_nil_checks,
            deterministic_guards: &mut deterministic_guards,
            return_origins: &mut return_origins,
            noreturn_methods: &mut noreturn_methods,
            collection_index_lookups: &mut collection_index_lookups,
            hash_record_blockers: &mut hash_record_blockers,
            type_normalizers: &mut type_normalizers,
            rescue_handlers: &mut rescue_handlers,
            return_usage_sites: &mut return_usage_sites,
            return_direct_usage_sites: &mut return_direct_usage_sites,
            hash_record_escape_sites: &mut hash_record_escape_sites,
            hidden_enum_observations: &mut hidden_enum_observations,
            dispatcher_inferences: &mut dispatcher_inferences,
            hash_record_member_calls: &mut hash_record_member_calls,
            param_origins: &mut param_origins,
            struct_declarations: &mut struct_declarations,
            state_type_records: &mut state_type_records,
            hash_shapes: &mut hash_shapes,
            tuple_arrays: &mut tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns: &pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        };

        let lvar_node = crate::ast::Node {
            r#type: "LVAR".to_string(),
            children: [Child::Symbol("v".to_string())].to_vec(),
            first_lineno: 1,
            first_column: 1,
            last_lineno: 1,
            last_column: 5,
            text: "v".to_string(),
        };

        let mut extra_locals = BTreeMap::new();
        extra_locals.insert("v".to_string(), "String".to_string());

        assert_eq!(
            visitor.expression_type_with_locals(&lvar_node, &extra_locals),
            Some("String".to_string())
        );

        let or_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OR",
            "children": [
                {"Node": {
                    "type": "INTEGER",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "1"
                }},
                {"Node": {
                    "type": "INTEGER",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "2"
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "1 || 2"
        }"#).unwrap();

        assert_eq!(
            visitor.expression_type(&or_node),
            Some("Integer".to_string())
        );
    }

    fn create_visitor<'a>(
        doc: &'a Document,
        lines: &'a [String],
        tlet_sites: &'a mut Vec<serde_json::Value>,
        dead_nil_checks: &'a mut Vec<serde_json::Value>,
        deterministic_guards: &'a mut Vec<serde_json::Value>,
        return_origins: &'a mut Vec<serde_json::Value>,
        noreturn_methods: &'a mut Vec<serde_json::Value>,
        collection_index_lookups: &'a mut Vec<serde_json::Value>,
        hash_record_blockers: &'a mut Vec<serde_json::Value>,
        type_normalizers: &'a mut Vec<serde_json::Value>,
        rescue_handlers: &'a mut Vec<serde_json::Value>,
        return_usage_sites: &'a mut Vec<serde_json::Value>,
        return_direct_usage_sites: &'a mut Vec<serde_json::Value>,
        hash_record_escape_sites: &'a mut Vec<serde_json::Value>,
        hidden_enum_observations: &'a mut Vec<serde_json::Value>,
        dispatcher_inferences: &'a mut Vec<serde_json::Value>,
        hash_record_member_calls: &'a mut Vec<serde_json::Value>,
        param_origins: &'a mut Vec<serde_json::Value>,
        struct_declarations: &'a mut Vec<StructDeclaration>,
        state_type_records: &'a mut Vec<StateTypeRecord>,
        hash_shapes: &'a mut Vec<HashShape>,
        tuple_arrays: &'a mut Vec<serde_json::Value>,
        pre_registered_noreturns: &'a std::collections::HashSet<String>,
    ) -> TypeInferenceVisitor<'a> {
        let behavior = crate::syntax::normalized_behavior::behavior(Language::Ruby);
        TypeInferenceVisitor {
            behavior,
            document: doc,
            lines,
            path: "test.rb",
            current_owners: vec![],
            current_method: None,
            current_method_kind: String::new(),
            current_method_line: 0,
            current_method_end_line: 0,
            current_params: vec![],
            param_types: BTreeMap::new(),
            local_types: BTreeMap::new(),
            in_conditional: false,
            ivar_tlet_types: BTreeMap::new(),
            signatures: BTreeMap::new(),
            tlet_sites,
            dead_nil_checks,
            deterministic_guards,
            return_origins,
            noreturn_methods,
            collection_index_lookups,
            hash_record_blockers,
            type_normalizers,
            rescue_handlers,
            return_usage_sites,
            return_direct_usage_sites,
            hash_record_escape_sites,
            hidden_enum_observations,
            dispatcher_inferences,
            hash_record_member_calls,
            param_origins,
            struct_declarations,
            state_type_records,
            hash_shapes,
            tuple_arrays,
            local_hash_shapes: BTreeMap::new(),
            local_array_shapes: BTreeMap::new(),
            local_container_origins: BTreeMap::new(),
            ivar_container_origins: BTreeMap::new(),
            struct_field_hash_shapes: BTreeMap::new(),
            struct_field_array_shapes: BTreeMap::new(),
            pre_registered_noreturns,
            is_prepass: false,
            method_param_hash_shapes: BTreeMap::new(),
            method_param_array_shapes: BTreeMap::new(),
            method_return_hash_shapes: BTreeMap::new(),
            method_return_array_shapes: BTreeMap::new(),
            inferred_return_types: BTreeMap::new(),
            unconditional_vars: BTreeSet::new(),
        }
    }

    #[test]
    fn test_noreturn_detection() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        let call_absurd: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "CONST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": "T"
                }},
                {"Symbol": "absurd"},
                {"Node": {
                    "type": "LIST",
                    "children": [],
                    "first_lineno": 1,
                    "first_column": 1,
                    "last_lineno": 1,
                    "last_column": 5,
                    "text": ""
                }}
            ],
            "first_lineno": 1,
            "first_column": 1,
            "last_lineno": 1,
            "last_column": 10,
            "text": "T.absurd(x)"
        }"#).unwrap();

        assert!(visitor.noreturn_body(&call_absurd));
    }

    #[test]
    fn test_inference_expansion() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        // 1. collect_prepass_facts
        // LASGN / CASGN with Struct.new
        let struct_new_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASGN",
            "children": [
                {"Symbol": "MyStruct"},
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"Struct"}},
                        {"Symbol": "new"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "Struct.new"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "MyStruct = Struct.new"
        }"#).unwrap();
        let mut owners = vec![];
        let mut ivar_tlet = BTreeMap::new();
        collect_prepass_facts(&struct_new_node, Language::Ruby, &mut owners, &mut ivar_tlet);

        // CLASS / MODULE
        let class_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CLASS",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"Klass"}},
                "Nil",
                {"Node": {
                    "type": "IASGN",
                    "children": [
                        {"Symbol": "@ivar"},
                        {"Node": {
                            "type": "CALL",
                            "children": [
                                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"T"}},
                                {"Symbol": "let"},
                                {"Node": {
                                    "type": "LIST",
                                    "children": [
                                        {"Node": {"type": "IVAR", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"@ivar"}},
                                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"String"}}
                                    ],
                                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ""
                                }}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "T.let(@ivar, String)"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "@ivar = T.let(@ivar, String)"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "class Klass; @ivar = T.let(@ivar, String); end"
        }"#).unwrap();
        collect_prepass_facts(&class_node, Language::Ruby, &mut owners, &mut ivar_tlet);
        assert_eq!(ivar_tlet.get(&("Klass".to_string(), "@ivar".to_string())), Some(&"String".to_string()));

        // 2. return_control_shape / branching_return_expression
        let explicit_ret: crate::ast::Node = serde_json::from_str(r#"{
            "type": "RETURN",
            "children": [
                {"Node": {
                    "type": "IF",
                    "children": [
                        {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                        "Nil"
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "1 if true"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "return 1 if true"
        }"#).unwrap();
        let explicit_nodes = vec![&explicit_ret];
        assert_eq!(return_control_shape(&explicit_nodes, None, false), "branching");

        // 3. IF/UNLESS local type merging with None (branching merges)
        visitor.local_types.insert("my_var".to_string(), "Integer".to_string());
        // We will visit an IF statement manually
        let if_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                {"Node": {
                    "type": "LASGN",
                    "children": [
                        {"Symbol": "my_var"},
                        {"Node": {"type": "STRING", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"\"hi\""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "my_var = \"hi\""
                }},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; my_var = \"hi\"; end"
        }"#).unwrap();
        visitor.visit(&if_node);
        assert_eq!(visitor.local_types.get("my_var").cloned(), Some("Integer".to_string()));

        // Also test IF where the else branch assigns and then doesn't
        visitor.local_types.insert("my_var2".to_string(), "Integer".to_string());
        let if_node2: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                "Nil",
                {"Node": {
                    "type": "LASGN",
                    "children": [
                        {"Symbol": "my_var2"},
                        {"Node": {"type": "STRING", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"\"hi\""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "my_var2 = \"hi\""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; else my_var2 = \"hi\"; end"
        }"#).unwrap();
        visitor.visit(&if_node2);
        assert_eq!(visitor.local_types.get("my_var2").cloned(), Some("Integer".to_string()));

        // Test uninitialized variable assigned in then branch (merges to T.nilable)
        let if_node3: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"true"}},
                {"Node": {
                    "type": "LASGN",
                    "children": [
                        {"Symbol": "my_var3"},
                        {"Node": {"type": "STRING", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"\"hi\""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "my_var3 = \"hi\""
                }},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; my_var3 = \"hi\"; end"
        }"#).unwrap();
        visitor.visit(&if_node3);
        assert_eq!(visitor.local_types.get("my_var3").cloned(), Some("T.nilable(String)".to_string()));

        // 4. AND / OR / WHILE / UNTIL / CASE
        let case_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASE",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                {"Node": {
                    "type": "WHEN",
                    "children": [
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"Integer"}},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "when Integer; x; end"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "case x; when Integer; x; end"
        }"#).unwrap();
        visitor.visit(&case_node);

        // 5. ITER on a Hash and Array
        visitor.local_types.insert("my_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let iter_hash_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_hash"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"my_hash"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 12, "text": "my_hash.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k, v"
                        }},
                        {"Node": {
                            "type": "STATEMENTS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k; v"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_hash.each { |k, v| k; v }"
        }"#).unwrap();
        visitor.visit(&iter_hash_node);

        // ITER on Array
        visitor.local_types.insert("my_array".to_string(), "T::Array[String]".to_string());
        let iter_array_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_array"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"my_array"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 13, "text": "my_array.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 6, "text": "item"
                        }},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_array.each { |item| item }"
        }"#).unwrap();
        visitor.visit(&iter_array_node);

        // 6. Mutation type tracking
        // array append: arr << val
        visitor.local_types.insert("my_array2".to_string(), "T::Array[String]".to_string());
        let append_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_array2"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":9, "text":"my_array2"}},
                {"Symbol": "<<"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "1"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_array2 << 1"
        }"#).unwrap();
        visitor.visit(&append_node);
        assert_eq!(visitor.local_types.get("my_array2").cloned(), Some("T::Array[T.untyped]".to_string()));
 
        // hash assignment: hash[key] = val
        visitor.local_types.insert("my_hash2".to_string(), "T::Hash[Symbol, String]".to_string());
        let hash_set_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_hash2"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"my_hash2"}},
                {"Symbol": "[]="},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a, 1"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_hash2[:a] = 1"
        }"#).unwrap();
        visitor.visit(&hash_set_node);
        assert_eq!(visitor.local_types.get("my_hash2").cloned(), Some("T::Hash[Symbol, T.untyped]".to_string()));
 
        // hash merge!: hash.merge!(other)
        visitor.local_types.insert("my_hash3".to_string(), "T::Hash[Symbol, String]".to_string());
        visitor.local_types.insert("other_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let merge_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_hash3"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"my_hash3"}},
                {"Symbol": "merge!"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "other_hash"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":10, "text":"other_hash"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 12, "text": "other_hash"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_hash3.merge!(other_hash)"
        }"#).unwrap();
        visitor.visit(&merge_node);
        assert_eq!(visitor.local_types.get("my_hash3").cloned(), Some("T::Hash[Symbol, T.untyped]".to_string()));

        // 7. provably_non_nil and guards
        visitor.local_types.insert("non_nil_v".to_string(), "String".to_string());
        let non_nil_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR",
            "children": [{"Symbol": "non_nil_v"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 9, "text": "non_nil_v"
        }"#).unwrap();
        assert!(visitor.provably_non_nil(&non_nil_node));

        // nil check guard
        let unless_nil_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "UNLESS",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "non_nil_v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":9, "text":"non_nil_v"}},
                        {"Symbol": "nil?"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":9, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "non_nil_v.nil?"
                }},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "unless non_nil_v.nil?; 1; end"
        }"#).unwrap();
        visitor.visit(&unless_nil_node);
        assert!(!visitor.dead_nil_checks.is_empty());

        // Class guards and subclass/disjointness
        visitor.local_types.insert("my_int".to_string(), "Integer".to_string());
        let class_guard_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_int"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"my_int"}},
                        {"Symbol": "is_a?"},
                        {"Node": {
                            "type": "LIST",
                            "children": [
                                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"String"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 8, "text": "String"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_int.is_a?(String)"
                }},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if my_int.is_a?(String); 1; end"
        }"#).unwrap();
        visitor.visit(&class_guard_node);
        assert!(!visitor.deterministic_guards.is_empty());

        // Subclass guard Numeric
        let class_guard_sub_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_int"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"my_int"}},
                        {"Symbol": "is_a?"},
                        {"Node": {
                            "type": "LIST",
                            "children": [
                                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"Numeric"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 9, "text": "Numeric"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_int.is_a?(Numeric)"
                }},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if my_int.is_a?(Numeric); 1; end"
        }"#).unwrap();
        visitor.visit(&class_guard_sub_node);
    }

    #[test]
    fn test_readonly_shapes() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        let extra_hash_shapes = BTreeMap::new();

        // 1. ATTRASGN / IASGN / CASGN etc.
        let iasgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [
                {"Symbol": "@x"},
                {"Node": {
                    "type": "HASH",
                    "children": [],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "@x = {}"
        }"#).unwrap();
        let shape = visitor.hash_shape_for_value_readonly(&iasgn_node, &extra_hash_shapes);
        assert!(shape.is_some());

        let attr_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ATTRASGN",
            "children": [
                {"Node": {"type": "SELF", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"self"}},
                {"Symbol": "x="},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "{}"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "self.x = {}"
        }"#).unwrap();
        let shape_attr = visitor.hash_shape_for_value_readonly(&attr_node, &extra_hash_shapes);
        assert!(shape_attr.is_some());

        // 2. HASH with keys, values, and poisoned case
        let hash_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                        {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => {}"
                }},
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                        {"Node": {
                            "type": "ARRAY",
                            "children": [
                                {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "[{}]"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => [{}]"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "{:a => {}, :b => [{}]}"
        }"#).unwrap();
        let shape_hash = visitor.hash_shape_for_value_readonly(&hash_node, &extra_hash_shapes);
        assert!(shape_hash.is_some());
        let sh_val = shape_hash.unwrap();
        assert!(!sh_val.get("value_hash_shapes").unwrap().get("a").is_none());
        assert!(!sh_val.get("value_array_element_shapes").unwrap().get("b").is_none());

        // Poisoned HASH
        let poisoned_hash: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {
                    "type": "pair",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "x => 1"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "{x => 1}"
        }"#).unwrap();
        let shape_poisoned = visitor.hash_shape_for_value_readonly(&poisoned_hash, &extra_hash_shapes).unwrap();
        assert_eq!(shape_poisoned.get("poisoned").and_then(Value::as_bool), Some(true));

        // 3. LVAR / DVAR extra / local shapes
        let lvar_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR",
            "children": [{"Symbol": "var_a"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "var_a"
        }"#).unwrap();
        let mut extra_locals_shapes = BTreeMap::new();
        extra_locals_shapes.insert("var_a".to_string(), json!({"keys": {}}));
        let shape_lvar = visitor.hash_shape_for_value_readonly(&lvar_node, &extra_locals_shapes);
        assert!(shape_lvar.is_some());

        // 4. CALL / QCALL / OPCALL
        // Type normalizer cast case: T.cast(x, Type)
        let cast_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"T"}},
                {"Symbol": "cast"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "HASH", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"{}"}},
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"Hash"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "{}, Hash"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "T.cast({}, Hash)"
        }"#).unwrap();
        let shape_cast = visitor.hash_shape_for_value_readonly(&cast_node, &extra_hash_shapes);
        assert!(shape_cast.is_some());

        // Array index/first/last cases: arr.first
        let first_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {
                    "type": "LVAR",
                    "children": [{"Symbol": "my_arr"}],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 7, "text": "my_arr"
                }},
                {"Symbol": "first"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_arr.first"
        }"#).unwrap();
        visitor.local_array_shapes.insert("my_arr".to_string(), json!({"keys": {}}));
        let shape_first = visitor.hash_shape_for_value_readonly(&first_node, &extra_hash_shapes);
        assert!(shape_first.is_some());

        // Method return shapes
        visitor.method_return_hash_shapes.insert(("MyClass".to_string(), "my_method".to_string()), json!({"keys": {}}));
        let method_call_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":8, "text":"MyClass"}},
                {"Symbol": "my_method"},
                {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "MyClass.my_method"
        }"#).unwrap();
        let shape_method = visitor.hash_shape_for_value_readonly(&method_call_node, &extra_hash_shapes);
        assert!(shape_method.is_some());

        // Struct field shapes
        visitor.struct_field_hash_shapes.insert(("MyStructClass".to_string(), "field_a".to_string()), json!({"keys": {}}));
        visitor.local_types.insert("my_struct_inst".to_string(), "MyStructClass".to_string());
        let struct_field_call_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "my_struct_inst"}], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_struct_inst"}},
                {"Symbol": "field_a"},
                {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 25, "text": "my_struct_inst.field_a"
        }"#).unwrap();
        let shape_struct_field = visitor.hash_shape_for_value_readonly(&struct_field_call_node, &extra_hash_shapes);
        assert!(shape_struct_field.is_some());

        // 5. ARRAY / LIST of hash element shapes
        let array_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ARRAY",
            "children": [
                {"Node": {"type": "HASH", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "[{}]"
        }"#).unwrap();
        let shape_arr = visitor.array_element_shape_for_value_readonly(&array_node, &extra_hash_shapes);
        assert!(shape_arr.is_some());

        // 6. ITER map/collect element shapes
        let map_iter_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "my_arr2"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"my_arr2"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "my_arr2.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 6, "text": "item"
                        }},
                        {"Node": {"type": "HASH", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "my_arr2.map { |item| {} }"
        }"#).unwrap();
        visitor.local_array_shapes.insert("my_arr2".to_string(), json!({"keys": {}}));
        let shape_map = visitor.array_element_shape_for_value_readonly(&map_iter_node, &extra_hash_shapes);
        assert!(shape_map.is_some());
    }

    #[test]
    fn test_additional_uncovered_paths() {
        let doc = dummy_doc();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        let extra_hash_shapes = BTreeMap::new();

        // 1. empty text VCALL node for node_symbol
        let node_empty_vcall: crate::ast::Node = serde_json::from_str(r#"{
            "type": "VCALL",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": ""
        }"#).unwrap();
        assert_eq!(node_symbol(&node_empty_vcall), None);

        // 2. collect_prepass_facts CLASS module qualified formatting with empty current_owners
        let mut current_owners = vec![];
        let mut ivar_tlet_types = BTreeMap::new();
        let class_node_simple: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CLASS",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"Foo"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "class Foo; end"
        }"#).unwrap();
        collect_prepass_facts(&class_node_simple, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // 3. IASGN prepass cases:
        // - ivar_name is None
        let iasgn_no_sym: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": ""
        }"#).unwrap();
        collect_prepass_facts(&iasgn_no_sym, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // - val_node is None
        let iasgn_no_val: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [{"Symbol": "@foo"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": "@foo"
        }"#).unwrap();
        collect_prepass_facts(&iasgn_no_val, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // - not "let" or receiver not "T"
        let iasgn_not_t_let: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IASGN",
            "children": [
                {"Symbol": "@foo"},
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"X"}},
                        {"Symbol": "let"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "X.let"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "@foo = X.let"
        }"#).unwrap();
        collect_prepass_facts(&iasgn_not_t_let, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);

        // 4. hash_shape_for_value HASH with empty pair elements to hit continue branches
        let hash_empty_pair: crate::ast::Node = serde_json::from_str(r#"{
            "type": "HASH",
            "children": [
                {"Node": {"type": "pair", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 1, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "{}"
        }"#).unwrap();
        let shape_empty_pair = visitor.hash_shape_for_value_readonly(&hash_empty_pair, &extra_hash_shapes);
        assert!(shape_empty_pair.is_some());

        // 5. array_element_shape_for_value_readonly LVAR/DVAR, and QCALL/OPCALL methods
        let dvar_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DVAR",
            "children": [{"Symbol": "var_d"}],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "var_d"
        }"#).unwrap();
        visitor.local_array_shapes.insert("var_d".to_string(), json!({"keys": {}}));
        let shape_dvar = visitor.array_element_shape_for_value_readonly(&dvar_node, &extra_hash_shapes);
        assert!(shape_dvar.is_some());

        let qcall_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "QCALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "var_d"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"var_d"}},
                {"Symbol": "first"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "var_d?.first"
        }"#).unwrap();
        let shape_qcall = visitor.array_element_shape_for_value_readonly(&qcall_node, &extra_hash_shapes);
        assert!(shape_qcall.is_some());

        // 6. array_element_shape_for_receiver_readonly select/reject/compact/filter_map methods
        let select_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "var_d"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"var_d"}},
                {"Symbol": "select"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "var_d.select"
        }"#).unwrap();
        let shape_select = visitor.array_element_shape_for_receiver_readonly(Some(&select_node), &extra_hash_shapes);
        assert!(shape_select.is_some());

        // 7. provably_non_nil with literal node & SELF
        let self_node = crate::ast::Node {
            r#type: "SELF".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 4, text: "self".to_string(),
        };
        assert!(visitor.provably_non_nil(&self_node));

        let true_node = crate::ast::Node {
            r#type: "TRUE".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 4, text: "true".to_string(),
        };
        assert!(visitor.provably_non_nil(&true_node));

        // 8. inspect_branch_guard with no children
        let guard_no_child = crate::ast::Node {
            r#type: "IF".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 1, text: "if".to_string(),
        };
        visitor.inspect_branch_guard(&guard_no_child, false);

        // 9. deterministic_predicate_result PAREN node with no children
        let paren_no_child = crate::ast::Node {
            r#type: "PAREN".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 1, text: "()".to_string(),
        };
        assert!(visitor.deterministic_predicate_result(&paren_no_child).is_none());

        // 10. deterministic_class_predicate_result checks:
        // - class predicate has not 1 argument
        let class_guard_0_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                {"Symbol": "is_a?"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "x.is_a?"
        }"#).unwrap();
        assert!(visitor.deterministic_class_predicate_result(&class_guard_0_args).is_none());

        // - empty class name
        let class_guard_empty_arg: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}},
                {"Symbol": "is_a?"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "STR", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "x.is_a?('')"
        }"#).unwrap();
        assert!(visitor.deterministic_class_predicate_result(&class_guard_empty_arg).is_none());

        // 11. class_guard_truth edge cases:
        assert_eq!(visitor.class_guard_truth("T.untyped", "String", false), None);
        assert_eq!(visitor.class_guard_truth("T.nilable(String)", "String", false), None);
        assert_eq!(visitor.class_guard_truth("", "String", false), None);
        // normalized empty case:
        assert_eq!(visitor.class_guard_truth("T.nilable()", "String", false), None);

        // 12. bare_class_name
        assert_eq!(visitor.bare_class_name("T::Array[String]"), "Array");
        assert_eq!(visitor.bare_class_name("Array"), "Array");
        assert_eq!(visitor.bare_class_name("T::Hash[Symbol, Integer]"), "Hash");
        assert_eq!(visitor.bare_class_name("T::Set[Integer]"), "Set");
        assert_eq!(visitor.bare_class_name("T::Boolean"), "T::Boolean");
        assert_eq!(visitor.bare_class_name("::A::B"), "B");

        // 13. known_disjoint_guard_classes with T::Boolean
        assert!(!visitor.known_disjoint_guard_classes("T::Boolean", "TrueClass"));
        assert!(!visitor.known_disjoint_guard_classes("TrueClass", "T::Boolean"));

        // 14. deterministic_literal_comparison_result with comparison method not 1 argument
        let compare_0_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                {"Symbol": "=="},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "1.=="
        }"#).unwrap();
        assert!(visitor.deterministic_literal_comparison_result(&compare_0_args).is_none());

        // 15. predicate_origin with CALL node having 0 arguments
        let call_0_args: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "SELF", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":4, "text":"self"}},
                {"Symbol": "foo"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "self.foo"
        }"#).unwrap();
        let origin = visitor.predicate_origin(&call_0_args);
        assert_eq!(origin, (Some("attr".to_string()), Some("foo".to_string())));

        let origin_fallback = visitor.predicate_origin(&true_node);
        assert_eq!(origin_fallback, (None, None));

        // 16. hash_shape_index_type_readonly_with_shapes poisoned shape or empty types
        let idx_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":":a"
        }"#).unwrap();
        let mut poisoned_shapes = BTreeMap::new();
        poisoned_shapes.insert("x".to_string(), json!({"poisoned": true}));
        let receiver_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"
        }"#).unwrap();
        assert_eq!(visitor.hash_shape_index_type_readonly_with_shapes(&receiver_node, &idx_node, &poisoned_shapes), None);

        let mut empty_key_shapes = BTreeMap::new();
        empty_key_shapes.insert("x".to_string(), json!({"keys": {"a": []}}));
        assert_eq!(visitor.hash_shape_index_type_readonly_with_shapes(&receiver_node, &idx_node, &empty_key_shapes), None);

        // 17. static_expression_type_with_locals_and_shapes with OPCALL callee, collection type details, and []/fetch
        let opcall_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OPCALL",
            "children": [
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}},
                {"Symbol": "+"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "2"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "1 + 2"
        }"#).unwrap();
        assert_eq!(visitor.static_expression_type(&opcall_node), Some("Integer".to_string()));

        // Collection iteration types (each/map details)
        let iter_untyped_rec: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "c"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"c"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "c.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k, v"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "c.each { |k, v| }"
        }"#).unwrap();
        let mut extra_locals = BTreeMap::new();
        extra_locals.insert("c".to_string(), "T::Hash[Symbol, String]".to_string());
        assert!(visitor.static_expression_type_with_locals(&iter_untyped_rec, &extra_locals).is_some());

        // Array element type iteration details
        let iter_arr: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.each { |elem| }"
        }"#).unwrap();
        let mut extra_locals_arr = BTreeMap::new();
        extra_locals_arr.insert("a".to_string(), "T::Array[String]".to_string());
        assert!(visitor.static_expression_type_with_locals(&iter_arr, &extra_locals_arr).is_some());

        // 18. expression_type on empty array / empty hash
        let empty_arr: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ARRAY",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "[]"
        }"#).unwrap();
        assert_eq!(visitor.expression_type(&empty_arr), Some("T::Array[T.untyped]".to_string()));

        // 19. literal_type on LIT float value
        let float_lit: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LIT",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "3.14"
        }"#).unwrap();
        assert_eq!(visitor.expression_type(&float_lit), Some("Float".to_string()));

        // 20. noreturn_body with empty branches (IF/UNLESS)
        let noreturn_if_empty: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "true"}},
                "Nil",
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "if true; end"
        }"#).unwrap();
        assert!(!visitor.noreturn_body(&noreturn_if_empty));

        // 21. noreturn_call with non-call node or absurd call
        let absurd_call: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "CONST", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"T"}},
                {"Symbol": "absurd"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "T.absurd"
        }"#).unwrap();
        assert!(visitor.noreturn_call(&absurd_call));
        assert!(!visitor.noreturn_call(&true_node));

        // 22. return_sources_for with empty BLOCK, implicit else, empty CASE
        let return_empty_block: crate::ast::Node = serde_json::from_str(r#"{
            "type": "BLOCK",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": ""
        }"#).unwrap();
        let mut blockers = BTreeSet::new();
        let res_sources = visitor.return_sources_for(&return_empty_block, None, &mut blockers);
        assert_eq!(res_sources.len(), 1);

        let if_implicit_else: crate::ast::Node = serde_json::from_str(r#"{
            "type": "IF",
            "children": [
                {"Node": {"type": "TRUE", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "true"}},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}},
                "Nil"
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "1 if true"
        }"#).unwrap();
        let res_sources_if = visitor.return_sources_for(&if_implicit_else, None, &mut blockers);
        assert!(!res_sources_if.is_empty());

        let case_empty: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASE",
            "children": [],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "case; end"
        }"#).unwrap();
        let res_sources_case = visitor.return_sources_for(&case_empty, None, &mut blockers);
        assert!(res_sources_case.is_empty());

        // 23. classify_origin with GVAR, VCALL, etc.
        let gvar_node = crate::ast::Node {
            r#type: "GVAR".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 5, text: "$g".to_string(),
        };
        let param_names_set = BTreeSet::new();
        let assigns_map = BTreeMap::new();
        let origin_gvar = visitor.classify_origin(&gvar_node, &param_names_set, &assigns_map, 0);
        assert_eq!(origin_gvar, ("local".to_string(), Value::Null));

        let vcall_node = crate::ast::Node {
            r#type: "VCALL".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 5, text: "v".to_string(),
        };
        let origin_vcall = visitor.classify_origin(&vcall_node, &param_names_set, &assigns_map, 0);
        assert_eq!(origin_vcall, ("attr".to_string(), json!("v")));

        // 24. current_params_json optional/keyword params default values
        let defn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFN",
            "children": [
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "parameters",
                    "children": [
                        {"Node": {
                            "type": "optional_parameter",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "opt"}},
                                {"Node": {"type": "NIL", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 3, "text": "nil"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "opt = nil"
                        }},
                        {"Node": {
                            "type": "keyword_parameter",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 4, "text": "key"}},
                                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "key: 1"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "(opt = nil, key: 1)"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def my_method(opt = nil, key: 1); end"
        }"#).unwrap();
        visitor.current_params = vec!["opt".to_string(), "key".to_string()];
        let params_json = visitor.current_params_json(&defn_node);
        assert_eq!(params_json.len(), 2);

        // 25. collect_hidden_enum_observations_node: include?/member?/key? method calls, and IVAR/CVAR receiver
        let record = json!({
            "path": "test.rb",
            "class": "MyClass",
            "kind": "instance",
            "method": "foo",
            "line": 1,
            "params": []
        });
        let include_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "IVAR", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"@arr"}},
                {"Symbol": "include?"},
                {"Node": {
                    "type": "LIST",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "x"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"x"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "x"
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "@arr.include?(x)"
        }"#).unwrap();
        let params_map = BTreeMap::new();
        visitor.collect_hidden_enum_observations_node(&include_node, &record, &params_map);

        // 26. inspect_dead_nil_check nil check and safe_nav on a non-nil receiver
        visitor.local_types.insert("nn".to_string(), "String".to_string());
        let nil_check_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "nn"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":"nn"}},
                {"Symbol": "nil?"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "nn.nil?"
        }"#).unwrap();
        visitor.inspect_call_node(&nil_check_node);
        assert!(!visitor.dead_nil_checks.is_empty());

        let safe_nav_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "QCALL",
            "children": [
                {"Node": {"type": "LVAR", "children": [{"Symbol": "nn"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":"nn"}},
                {"Symbol": "upcase"},
                {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "nn?.upcase"
        }"#).unwrap();
        visitor.inspect_call_node(&safe_nav_node);

        // 27. update_local_fact / inspect_local_container_origin / inspect_ivar_container_origin / inspect_struct_declaration
        let lasgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LASGN",
            "children": [
                {"Symbol": "var_lasgn"},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "var_lasgn = 1"
        }"#).unwrap();
        visitor.update_local_fact(&lasgn_node);
        visitor.inspect_local_container_origin(&lasgn_node);
        visitor.inspect_ivar_container_origin(&lasgn_node);
        visitor.inspect_struct_declaration(&lasgn_node);

        // CASGN to run inspect_ivar_container_origin / inspect_struct_declaration
        let casgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "CASGN",
            "children": [
                {"Symbol": "MyConst"},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "MyConst = 1"
        }"#).unwrap();
        visitor.visit(&casgn_node);

        // OP_ASGN1 and OP_ASGN2 return sources
        let op_asgn1_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OP_ASGN1",
            "children": [
                "Nil", "Nil", "Nil",
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "5"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "x[0] += 5"
        }"#).unwrap();
        let res_op1 = visitor.return_sources_for(&op_asgn1_node, None, &mut blockers);
        assert!(!res_op1.is_empty());

        let op_asgn2_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "OP_ASGN2",
            "children": [
                "Nil", "Nil", "Nil", "Nil",
                {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "6"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "x.y += 6"
        }"#).unwrap();
        let res_op2 = visitor.return_sources_for(&op_asgn2_node, None, &mut blockers);
        assert!(!res_op2.is_empty());

        // 28. hash_shape_index_type_readonly
        let hash_idx_recv: crate::ast::Node = serde_json::from_str(r#"{
            "type": "LVAR", "children": [{"Symbol": "h_idx"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":6, "text":"h_idx"
        }"#).unwrap();
        let hash_idx_key: crate::ast::Node = serde_json::from_str(r#"{
            "type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":":a"
        }"#).unwrap();
        visitor.local_hash_shapes.insert("h_idx".to_string(), json!({"keys": {"a": ["String"]}}));
        assert_eq!(visitor.hash_shape_index_type_readonly(&hash_idx_recv, &hash_idx_key), Some("T.nilable(String)".to_string()));

        // 29. GVASGN inspect_ivar_container_origin / inspect_struct_declaration
        let gvasgn_node: crate::ast::Node = serde_json::from_str(r#"{
            "type": "GVASGN",
            "children": [
                {"Symbol": "$gvar"},
                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "$gvar = 1"
        }"#).unwrap();
        visitor.visit(&gvasgn_node);

        // 30. shadow existing array shape variable in ITER block param to cover line 1013
        visitor.local_array_shapes.insert("elem".to_string(), json!({"keys": {}}));
        visitor.visit(&iter_arr);
    }

    #[test]
    fn test_uncovered_method_visitation() {
        let doc_json = r#"{
            "file": "test.rb",
            "language": "ruby",
            "function_defs": [
                {
                    "file": "test.rb",
                    "name": "my_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "self.my_class_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                }
            ]
        }"#;
        let doc: Document = serde_json::from_str(doc_json).unwrap();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        // 31. DEFN node with multiple returns to hit lines 672 and 687
        let defn_multi_returns: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFN",
            "children": [
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => 1"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:a => 1}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:a => 1}"
                        }},
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => 2"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:b => 2}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:b => 2}"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def my_method; return {:a=>1}; return {:b=>2}; end"
        }"#).unwrap();

        visitor.current_owners = vec!["MyClass".to_string()];
        visitor.visit(&defn_multi_returns);

        let defn_array_multi_returns: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFN",
            "children": [
                {"Symbol": "my_method"},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "ARRAY", "children": [
                                    {"Node": {"type": "HASH", "children": [
                                        {"Node": {
                                            "type": "pair",
                                            "children": [
                                                {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                                                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                                            ],
                                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => 1"
                                        }}
                                    ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:a => 1}"}}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "[{:a => 1}]"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return [{:a => 1}]"
                        }},
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "ARRAY", "children": [
                                    {"Node": {"type": "HASH", "children": [
                                        {"Node": {
                                            "type": "pair",
                                            "children": [
                                                {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                                                {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                                            ],
                                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => 2"
                                        }}
                                    ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:b => 2}"}}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": "[{:b => 2}]"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return [{:b => 2}]"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def my_method; return [{:a=>1}]; return [{:b=>2}]; end"
        }"#).unwrap();

        visitor.visit(&defn_array_multi_returns);

        // 32. DEFS node with multiple returns to hit lines 672 and 687
        let defs_multi_returns: crate::ast::Node = serde_json::from_str(r#"{
            "type": "DEFS",
            "children": [
                {"Symbol": "self"},
                {"Symbol": "my_class_method"},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":a"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"1"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":a => 1"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:a => 1}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:a => 1}"
                        }},
                        {"Node": {
                            "type": "RETURN",
                            "children": [
                                {"Node": {"type": "HASH", "children": [
                                    {"Node": {
                                        "type": "pair",
                                        "children": [
                                            {"Node": {"type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":3, "text":":b"}},
                                            {"Node": {"type": "INTEGER", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"2"}}
                                        ],
                                        "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": ":b => 2"
                                    }}
                                ], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{:b => 2}"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "return {:b => 2}"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 30, "text": "def self.my_class_method; return {:a=>1}; return {:b=>2}; end"
        }"#).unwrap();

        visitor.visit(&defs_multi_returns);
    }

    #[test]
    fn test_uncovered_type_inference_helpers() {
        fn make_node(r#type: &str, children: Vec<crate::ast::Child>, text: &str) -> crate::ast::Node {
            crate::ast::Node {
                r#type: r#type.to_string(),
                children,
                first_lineno: 1,
                first_column: 1,
                last_lineno: 1,
                last_column: 1,
                text: text.to_string(),
            }
        }
        
        fn make_symbol(symbol: &str) -> crate::ast::Child {
            crate::ast::Child::Symbol(symbol.to_string())
        }
        
        fn make_child_node(node: crate::ast::Node) -> crate::ast::Child {
            crate::ast::Child::Node(Box::new(node))
        }

        let doc = dummy_doc();
        let extra_hash_shapes = std::collections::BTreeMap::new();
        let true_node = crate::ast::Node {
            r#type: "TRUE".to_string(),
            children: vec![],
            first_lineno: 1, first_column: 1, last_lineno: 1, last_column: 4, text: "true".to_string(),
        };
        let hash_idx_key: crate::ast::Node = serde_json::from_str(r#"{
            "type": "SYMBOL", "children": [], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":":a"
        }"#).unwrap();
        let iter_arr: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.each { |elem| }"
        }"#).unwrap();
        let lines = vec![];
        let pre_registered_noreturns = std::collections::HashSet::new();
        let mut tlet_sites = Vec::new();
        let mut dead_nil_checks = Vec::new();
        let mut deterministic_guards = Vec::new();
        let mut return_origins = Vec::new();
        let mut noreturn_methods = Vec::new();
        let mut collection_index_lookups = Vec::new();
        let mut hash_record_blockers = Vec::new();
        let mut type_normalizers = Vec::new();
        let mut rescue_handlers = Vec::new();
        let mut return_usage_sites = Vec::new();
        let mut return_direct_usage_sites = Vec::new();
        let mut hash_record_escape_sites = Vec::new();
        let mut hidden_enum_observations = Vec::new();
        let mut dispatcher_inferences = Vec::new();
        let mut hash_record_member_calls = Vec::new();
        let mut param_origins = Vec::new();
        let mut struct_declarations = Vec::new();
        let mut state_type_records = Vec::new();
        let mut hash_shapes = Vec::new();
        let mut tuple_arrays = Vec::new();

        let mut visitor = create_visitor(
            &doc,
            &lines,
            &mut tlet_sites,
            &mut dead_nil_checks,
            &mut deterministic_guards,
            &mut return_origins,
            &mut noreturn_methods,
            &mut collection_index_lookups,
            &mut hash_record_blockers,
            &mut type_normalizers,
            &mut rescue_handlers,
            &mut return_usage_sites,
            &mut return_direct_usage_sites,
            &mut hash_record_escape_sites,
            &mut hidden_enum_observations,
            &mut dispatcher_inferences,
            &mut hash_record_member_calls,
            &mut param_origins,
            &mut struct_declarations,
            &mut state_type_records,
            &mut hash_shapes,
            &mut tuple_arrays,
            &pre_registered_noreturns,
        );

        // 1. nilable_type
        assert_eq!(nilable_type("NilClass"), "NilClass");
        assert_eq!(nilable_type("T.nilable(Integer)"), "T.nilable(Integer)");
        assert_eq!(nilable_type("Integer"), "T.nilable(Integer)");

        // 2. extract_param_entries
        let entries = extract_param_entries("params(a: Integer, b: String)");
        assert_eq!(entries.len(), 2);
        assert_eq!(entries[0], ("a".to_string(), "Integer".to_string()));
        assert_eq!(entries[1], ("b".to_string(), "String".to_string()));

        // 3. collection_index_status
        assert_eq!(collection_index_status(Some("T.untyped"), None), "weak collection receiver");
        assert_eq!(collection_index_status(Some("Array<Integer>"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("Hash<Symbol, String>"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("T::Array[Integer]"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("T::Hash[Symbol, String]"), None), "typed collection receiver");
        assert_eq!(collection_index_status(Some("String"), None), "non-collection or unresolved receiver");

        // 4. dispatch_helper_call
        let node_fcall = make_node(
            "WHEN",
            vec![make_child_node(make_node(
                "FCALL",
                vec![
                    make_symbol("is_a?"),
                    make_child_node(make_node(
                        "ARGUMENT_LIST",
                        vec![make_child_node(make_node("LVAR", vec![], "my_param"))],
                        "my_param"
                    ))
                ],
                "is_a?(my_param)"
            ))],
            ""
        );
        assert_eq!(dispatch_helper_call(&node_fcall, "my_param"), Some("is_a?".to_string()));

        let node_call = make_node(
            "WHEN",
            vec![make_child_node(make_node(
                "CALL",
                vec![
                    make_child_node(make_node("self", vec![], "self")),
                    make_symbol("is_a?"),
                    make_child_node(make_node(
                        "ARGUMENT_LIST",
                        vec![make_child_node(make_node("DVAR", vec![], "my_param"))],
                        "my_param"
                    ))
                ],
                "self.is_a?(my_param)"
            ))],
            ""
        );
        assert_eq!(dispatch_helper_call(&node_call, "my_param"), Some("is_a?".to_string()));

        // 5. collect_prepass_facts CLASS owner
        let class_node = make_node(
            "CLASS",
            vec![
                make_symbol("MyClass"),
                crate::ast::Child::Nil,
                make_child_node(make_node(
                    "IASGN",
                    vec![
                        make_symbol("@my_ivar"),
                        make_child_node(make_node(
                            "CALL",
                            vec![
                                make_child_node(make_node("CONST", vec![], "T")),
                                make_symbol("let"),
                                make_child_node(make_node(
                                    "ARGUMENT_LIST",
                                    vec![
                                        make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                        make_child_node(make_node("CONST", vec![], "Integer"))
                                    ],
                                    "val, Integer"
                                ))
                            ],
                            "T.let(val, Integer)"
                        ))
                    ],
                    "@my_ivar = T.let(val, Integer)"
                ))
            ],
            ""
        );
        let mut current_owners = vec![];
        let mut ivar_tlet_types = std::collections::BTreeMap::new();
        collect_prepass_facts(&class_node, Language::Ruby, &mut current_owners, &mut ivar_tlet_types);
        assert_eq!(ivar_tlet_types.get(&("MyClass".to_string(), "@my_ivar".to_string())), Some(&"Integer".to_string()));

        // 6. collect_return_usage_site_context direct_usage variants
        let node_arg_list = make_node(
            "ARGUMENT_LIST",
            vec![make_child_node(make_node("IDENTIFIER", vec![], "x"))],
            "x"
        );
        visitor.collect_return_usage_site_context(&node_arg_list, "value", None, None, false);

        let node_opasgn_el = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node(
                    "element_reference",
                    vec![
                        make_child_node(make_node("IDENTIFIER", vec![], "arr")),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![make_child_node(make_node("INTEGER", vec![], "0"))],
                            "0"
                        ))
                    ],
                    "arr[0]"
                )),
                make_symbol("arr"),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "arr[0] += 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_el, "value", None, None, false);
        visitor.collect_return_usage_site_context(&node_opasgn_el, "value", None, None, true);

        // OPASGN LHS Const cases for ||= and other
        let node_opasgn_const_or = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node("CONST", vec![], "ConstName")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "ConstName ||= 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_const_or, "special_context", None, None, false);

        let node_opasgn_const_other = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node("CONST", vec![], "ConstName")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "ConstName += 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_const_other, "value", None, None, false);

        let node_opasgn_id = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node("identifier", vec![], "x")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "x += 1"
        );
        visitor.collect_return_usage_site_context(&node_opasgn_id, "value", None, None, false);

        let node_else = make_node(
            "ELSE",
            vec![make_child_node(make_node("IDENTIFIER", vec![], "x"))],
            "else x"
        );
        visitor.collect_return_usage_site_context(&node_else, "value", None, None, false);

        // 7. classify_origin variants
        let param_names = std::collections::BTreeSet::from(["my_param".to_string()]);
        let mut assigns = std::collections::BTreeMap::new();
        
        let node_rhs = make_node("INTEGER", vec![], "42");
        assigns.insert("x".to_string(), &node_rhs);
        let node_lvar = make_node("LVAR", vec![], "x");
        let res1 = visitor.classify_origin(&node_lvar, &param_names, &assigns, 0);
        assert_eq!(res1.0, "local");
        
        let node_call_index = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "my_hash")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("SYMBOL", vec![], ":key"))],
                    ":key"
                ))
            ],
            "my_hash[:key]"
        );
        let res2 = visitor.classify_origin(&node_call_index, &param_names, &assigns, 0);
        assert_eq!(res2.0, "hashkey");

        let node_call_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "obj")),
                make_symbol("foo"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "obj.foo(1)"
        );
        let res3 = visitor.classify_origin(&node_call_args, &param_names, &assigns, 0);
        assert_eq!(res3.0, "call");

        let node_call_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "obj")),
                make_symbol("bar"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "obj.bar"
        );
        let res4 = visitor.classify_origin(&node_call_no_args, &param_names, &assigns, 0);
        assert_eq!(res4.0, "attr");

        let node_call_fail = make_node("CALL", vec![], "bad_call");
        let res5 = visitor.classify_origin(&node_call_fail, &param_names, &assigns, 0);
        assert_eq!(res5.0, "call");

        // 8. hidden_enum_slot_for
        let record = json!({
            "path": "test.rb",
            "class": "MyClass",
            "kind": "instance",
            "method": "my_method",
            "line": 10
        });
        let params_map = std::collections::BTreeMap::new();
        let node_ivar = make_node("IVAR", vec![], "@x");
        let slot = visitor.hidden_enum_slot_for(&node_ivar, &record, &params_map);
        assert!(slot.is_some());

        // 9. value_in_collection_append_or_index_write
        let col_push = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "col")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("IDENTIFIER", vec![], "target_val"))],
                    "target_val"
                ))
            ],
            "col.push(target_val)"
        );
        let actual_target = child_node(child_node(&col_push, 2).unwrap(), 0).unwrap();
        assert!(visitor.value_in_collection_append_or_index_write(&col_push, actual_target));

        let col_assign = make_node(
            "CALL",
            vec![
                make_child_node(make_node("IDENTIFIER", vec![], "col")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "0")),
                        make_child_node(make_node("IDENTIFIER", vec![], "target_val"))
                    ],
                    "0, target_val"
                ))
            ],
            "col[0] = target_val"
        );
        let actual_target_2 = child_nodes(child_node(&col_assign, 2).unwrap())[1];
        assert!(visitor.value_in_collection_append_or_index_write(&col_assign, actual_target_2));

        let col_opasgn = make_node(
            "OPASGN",
            vec![
                make_child_node(make_node(
                    "element_reference",
                    vec![
                        make_child_node(make_node("IDENTIFIER", vec![], "col")),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![make_child_node(make_node("INTEGER", vec![], "0"))],
                            "0"
                        ))
                    ],
                    "col[0]"
                )),
                make_child_node(make_node("IDENTIFIER", vec![], "target_val"))
            ],
            "col[0] += target_val"
        );
        let actual_target_3 = child_node(&col_opasgn, 1).unwrap();
        assert!(visitor.value_in_collection_append_or_index_write(&col_opasgn, actual_target_3));

        // 10. hash_record_escapes recursive check
        visitor.current_method = Some("my_method".to_string());
        let root_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("self", vec![], "self")),
                make_symbol("my_method"),
                make_child_node(make_node(
                    "ARRAY",
                    vec![make_child_node(make_node("LVAR", vec![], "my_var"))],
                    "my_var"
                ))
            ],
            "self.my_method([my_var])"
        );
        assert!(!visitor.escape_uses_of_local(&root_node, "my_var"));

        // 11. array_element_shape_for_value ITER mapping
        let mock_shape = json!({"a": "Integer"});
        visitor.local_array_shapes.insert("my_array".to_string(), mock_shape.clone());
        let iter_node = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "my_array")),
                        make_symbol("map"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array.map"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![make_child_node(make_node("LVAR", vec![], "x"))],
                        "x"
                    ))],
                    "|x|"
                )),
                make_child_node(make_node(
                    "HASH",
                    vec![make_child_node(make_node(
                        "pair",
                        vec![
                            make_child_node(make_node("SYMBOL", vec![], ":b")),
                            make_child_node(make_node("INTEGER", vec![], "2"))
                        ],
                        ":b => 2"
                    ))],
                    "{:b => 2}"
                ))
            ],
            "my_array.map { |x| {:b => 2} }"
        );
        let res_iter = visitor.array_element_shape_for_value(&iter_node);
        assert!(res_iter.is_some());

        // 12. IF merge (None, Some(e)) branches
        let node_if = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node("NilClass", vec![], "nil")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("else_var"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "else_var = 1"
                ))
            ],
            "if true; nil; else; else_var = 1; end"
        );
        visitor.visit(&node_if);
        assert_eq!(visitor.local_types.get("else_var").unwrap(), "T.nilable(Integer)");

        visitor.unconditional_vars.insert("else_var_uncond".to_string());
        let node_if_uncond = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node("NilClass", vec![], "nil")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("else_var_uncond"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "else_var_uncond = 1"
                ))
            ],
            "if true; nil; else; else_var_uncond = 1; end"
        );
        visitor.visit(&node_if_uncond);
        assert_eq!(visitor.local_types.get("else_var_uncond").unwrap(), "T.nilable(Integer)");

        // 13. collect_prepass_facts empty owners IASGN
        let mut empty_owners = vec![];
        let mut ivar_tlet_types_empty = std::collections::BTreeMap::new();
        let iasgn_node = make_node(
            "IASGN",
            vec![
                make_symbol("@my_ivar"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![
                                make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                make_child_node(make_node("CONST", vec![], "Integer"))
                            ],
                            "val, Integer"
                        ))
                    ],
                    "T.let(val, Integer)"
                ))
            ],
            "@my_ivar = T.let(val, Integer)"
        );
        collect_prepass_facts(&iasgn_node, Language::Ruby, &mut empty_owners, &mut ivar_tlet_types_empty);
        assert!(ivar_tlet_types_empty.is_empty());

        // 14. DEFN with no body
        let defn_no_body = make_node(
            "DEFN",
            vec![make_symbol("my_empty_method")],
            "def my_empty_method; end"
        );
        visitor.visit(&defn_no_body);

        // 15. Empty children for AND, CASE
        let node_and_empty = make_node("AND", vec![], "");
        visitor.visit(&node_and_empty);

        let node_case_empty = make_node("CASE", vec![], "");
        visitor.visit(&node_case_empty);

        // 16. ITER block with no ARGS
        let node_iter_no_args = make_node(
            "ITER",
            vec![
                make_child_node(make_node("CALL", vec![], "foo")),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "foo {}"
        );
        visitor.visit(&node_iter_no_args);

        // 17. Collection iteration zero params or invalid collection types
        visitor.local_types.insert("my_hash_zero".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.local_types.insert("my_array_zero".to_string(), "T::Array[String]".to_string());
        visitor.local_types.insert("my_string_each".to_string(), "String".to_string());

        let iter_hash_zero = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_hash_zero")], "my_hash_zero")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_hash_zero.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node("ARGS", vec![], ""))],
                    ""
                ))
            ],
            "my_hash_zero.each {}"
        );
        visitor.visit(&iter_hash_zero);

        let iter_array_zero = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_array_zero")], "my_array_zero")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array_zero.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node("ARGS", vec![], ""))],
                    ""
                ))
            ],
            "my_array_zero.each {}"
        );
        visitor.visit(&iter_array_zero);

        let iter_string = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_string_each")], "my_string_each")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_string_each.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![make_child_node(make_node("LVAR", vec![make_symbol("x")], "x"))],
                        "x"
                    ))],
                    "|x|"
                ))
            ],
            "my_string_each.each { |x| }"
        );
        visitor.visit(&iter_string);

        // 17.5 iteration with untyped collection elements (none type)
        visitor.local_types.insert("my_hash_none".to_string(), "T::Hash".to_string());
        let iter_hash_none = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_hash_none")], "my_hash_none")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_hash_none.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![
                            make_child_node(make_node("LVAR", vec![make_symbol("k")], "k")),
                            make_child_node(make_node("LVAR", vec![make_symbol("v")], "v"))
                        ],
                        "k, v"
                    ))],
                    "|k, v|"
                ))
            ],
            "my_hash_none.each { |k, v| }"
        );
        visitor.visit(&iter_hash_none);

        visitor.local_types.insert("my_array_none".to_string(), "T::Array".to_string());
        let iter_array_none = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_array_none")], "my_array_none")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array_none.each"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node(
                        "ARGS",
                        vec![make_child_node(make_node("LVAR", vec![make_symbol("x")], "x"))],
                        "x"
                    ))],
                    "|x|"
                ))
            ],
            "my_array_none.each { |x| }"
        );
        visitor.visit(&iter_array_none);

        // 18. CALL parameter type update (merge!)
        visitor.param_types.insert("my_param_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.local_types.insert("other_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_merge_param = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_param_hash")], "my_param_hash")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "my_param_hash.merge!(other_hash)"
        );
        visitor.visit(&node_merge_param);
        assert_eq!(visitor.param_types.get("my_param_hash").unwrap(), "T::Hash[Symbol, Integer]");

        // 19. CALL push edge cases
        visitor.local_types.insert("push_no_args".to_string(), "T::Array[String]".to_string());
        let node_push_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_no_args")], "push_no_args")),
                make_symbol("push"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "push_no_args.push"
        );
        visitor.visit(&node_push_no_args);

        let node_push_no_type = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_no_type")], "push_no_type")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "push_no_type.push(1)"
        );
        visitor.visit(&node_push_no_type);

        visitor.local_types.insert("push_non_col".to_string(), "String".to_string());
        let node_push_non_col = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_non_col")], "push_non_col")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "push_non_col.push(1)"
        );
        visitor.visit(&node_push_non_col);

        visitor.local_types.insert("push_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_push_hash = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("push_hash")], "push_hash")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "push_hash.push(1)"
        );
        visitor.visit(&node_push_hash);

        // 20. CALL []= edge cases
        visitor.local_types.insert("bracket_few_args".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_bracket_few_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("bracket_few_args")], "bracket_few_args")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "bracket_few_args[1]"
        );
        visitor.visit(&node_bracket_few_args);

        visitor.local_types.insert("bracket_non_col".to_string(), "String".to_string());
        let node_bracket_non_col = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("bracket_non_col")], "bracket_non_col")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "1")),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    "1, 2"
                ))
            ],
            "bracket_non_col[1] = 2"
        );
        visitor.visit(&node_bracket_non_col);

        // 21. CALL merge! edge cases
        visitor.local_types.insert("merge_no_args".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_merge_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_no_args")], "merge_no_args")),
                make_symbol("merge!"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "merge_no_args.merge!"
        );
        visitor.visit(&node_merge_no_args);

        visitor.local_types.insert("merge_arg_non_hash".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.local_types.insert("non_hash_arg".to_string(), "String".to_string());
        let node_merge_arg_non_hash = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_arg_non_hash")], "merge_arg_non_hash")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("non_hash_arg")], "non_hash_arg"))],
                    "non_hash_arg"
                ))
            ],
            "merge_arg_non_hash.merge!(non_hash_arg)"
        );
        visitor.visit(&node_merge_arg_non_hash);

        let node_merge_no_type = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_no_type")], "merge_no_type")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "merge_no_type.merge!(other_hash)"
        );
        visitor.visit(&node_merge_no_type);

        visitor.local_types.insert("merge_non_col".to_string(), "String".to_string());
        let node_merge_non_col = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_non_col")], "merge_non_col")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "merge_non_col.merge!(other_hash)"
        );
        visitor.visit(&node_merge_non_col);

        // 22. merge! where receiver is Array (not Hash)
        visitor.local_types.insert("merge_rec_array".to_string(), "T::Array[Integer]".to_string());
        let node_merge_rec_array = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_rec_array")], "merge_rec_array")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_hash")], "other_hash"))],
                    "other_hash"
                ))
            ],
            "merge_rec_array.merge!(other_hash)"
        );
        visitor.visit(&node_merge_rec_array);

        // 23. merge! where argument is Array (not Hash)
        visitor.local_types.insert("some_array".to_string(), "T::Array[Integer]".to_string());
        let node_merge_arg_array = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("merge_no_args")], "merge_no_args")),
                make_symbol("merge!"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("some_array")], "some_array"))],
                    "some_array"
                ))
            ],
            "merge_no_args.merge!(some_array)"
        );
        visitor.visit(&node_merge_arg_array);

        // 24. LASGN with no RHS value
        let lasgn_no_val = make_node(
            "LASGN",
            vec![make_symbol("x")],
            "x ="
        );
        visitor.visit(&lasgn_no_val);

        // 25. nil? call with no type
        let node_nil_check = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("x")], "x")),
                make_symbol("nil?"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "x.nil?"
        );
        visitor.visit(&node_nil_check);

        // 26. nil? call with non-nil type (dead check)
        visitor.local_types.insert("y".to_string(), "Integer".to_string());
        let node_nil_check_dead = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("y")], "y")),
                make_symbol("nil?"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "y.nil?"
        );
        visitor.visit(&node_nil_check_dead);

        // 27. qualified prepass nested owner when current_owners is not empty
        let mut nested_owners = vec!["Outer".to_string()];
        let mut nested_ivar_types = std::collections::BTreeMap::new();
        collect_prepass_facts(&class_node, Language::Ruby, &mut nested_owners, &mut nested_ivar_types);

        // 28. prepass IASGN where T.let has no second argument
        let iasgn_no_type_arg = make_node(
            "IASGN",
            vec![
                make_symbol("@my_ivar"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![make_child_node(make_node("IDENTIFIER", vec![], "val"))], "val"))
                    ],
                    "T.let(val)"
                ))
            ],
            "@my_ivar = T.let(val)"
        );
        let mut owners_tmp = vec!["MyClass".to_string()];
        collect_prepass_facts(&iasgn_no_type_arg, Language::Ruby, &mut owners_tmp, &mut nested_ivar_types);

        // 29. prepass IASGN where type is empty or T.untyped
        let iasgn_untyped = make_node(
            "IASGN",
            vec![
                make_symbol("@my_ivar"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![
                                make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                make_child_node(make_node("CONST", vec![], "T.untyped"))
                            ],
                            "val, T.untyped"
                        ))
                    ],
                    "T.let(val, T.untyped)"
                ))
            ],
            "@my_ivar = T.let(val, T.untyped)"
        );
        collect_prepass_facts(&iasgn_untyped, Language::Ruby, &mut owners_tmp, &mut nested_ivar_types);

        // 30. collect_explicit_returns with bare RETURN node
        let bare_return_node = make_node("RETURN", vec![], "return");
        let mut returns_vec = Vec::new();
        collect_explicit_returns(&bare_return_node, &mut returns_vec);
        assert_eq!(returns_vec.len(), 1);

        // 31. return_syntax direct test
        assert_eq!(return_syntax(false, true), "mixed");

        // 32. static_sorbet_type edge cases
        // - starts_with T.nilable( but ends with unmatched paren to hit line 72 in strip_nilable_type
        assert_eq!(strip_nilable_type("T.nilable(foo(bar)"), "T.nilable(foo(bar)");
        assert_eq!(strip_nilable_type("T.nilable(Int)"), "Int");
        // - static_sorbet_type has_nil but no others to hit line 126
        assert_eq!(static_sorbet_type(&["NilClass".to_string()]), "NilClass");
        // - static_sorbet_type others.len() > 1 to hit line 139 and 142
        assert_eq!(static_sorbet_type(&["Integer".to_string(), "String".to_string()]), "T.untyped");

        // 33. visit CLASS/MODULE qualified name when current_owners is not empty to hit line 486
        visitor.current_owners = vec!["Outer".to_string()];
        let module_node = make_node(
            "MODULE",
            vec![make_symbol("Inner")],
            "module Inner; end"
        );
        visitor.visit(&module_node);
        visitor.current_owners.clear();

        // 34. declarative owner casing to hit line 1131, 1132, 1187
        let casgn_struct = make_node(
            "CASGN",
            vec![
                make_symbol("MyStruct"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "Struct")),
                        make_symbol("new"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "Struct.new"
                ))
            ],
            "MyStruct = Struct.new"
        );
        visitor.visit(&casgn_struct);

        // 35. local / param type updates on Set receiver, param types check, concat call
        // Set receiver, is param, update_type format_set_type (line 1051, 1056)
        visitor.param_types.insert("my_set_param".to_string(), "T::Set[Integer]".to_string());
        let node_set_push = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_set_param")], "my_set_param")),
                make_symbol("<<"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "my_set_param << 1"
        );
        visitor.visit(&node_set_push);

        // concat method call (line 1044)
        visitor.local_types.insert("my_arr_local".to_string(), "T::Array[Integer]".to_string());
        visitor.local_types.insert("other_arr_local".to_string(), "T::Array[String]".to_string());
        let node_concat = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_local")], "my_arr_local")),
                make_symbol("concat"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_arr_local")], "other_arr_local"))],
                    "other_arr_local"
                ))
            ],
            "my_arr_local.concat(other_arr_local)"
        );
        visitor.visit(&node_concat);

        // append method where argument is a hash literal to hit line 1034
        visitor.local_types.insert("my_arr_for_hash".to_string(), "T::Array[T.untyped]".to_string());
        let node_push_hash_lit = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_for_hash")], "my_arr_for_hash")),
                make_symbol("push"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node(
                        "HASH",
                        vec![make_child_node(make_node(
                            "pair",
                            vec![
                                make_child_node(make_node("SYMBOL", vec![], ":a")),
                                make_child_node(make_node("INTEGER", vec![], "1"))
                            ],
                            ":a => 1"
                        ))],
                        "{:a => 1}"
                    ))],
                    "{:a => 1}"
                ))
            ],
            "my_arr_for_hash.push({:a => 1})"
        );
        visitor.visit(&node_push_hash_lit);

        // 36. []= method where receiver is in param_types to hit line 1082, 1086, 1088
        visitor.param_types.insert("my_hash_param".to_string(), "T::Hash[Symbol, Integer]".to_string());
        let node_hash_assign = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_hash_param")], "my_hash_param")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("SYMBOL", vec![], ":b")),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    ":b, 2"
                ))
            ],
            "my_hash_param[:b] = 2"
        );
        visitor.visit(&node_hash_assign);

        // 37. conditional assignment with existing T.nilable( to hit line 1155
        visitor.local_types.insert("cond_var".to_string(), "T.nilable(Integer)".to_string());
        let node_cond_assign = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("cond_var"),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    "cond_var = 2"
                )),
                crate::ast::Child::Nil
            ],
            "if true; cond_var = 2; end"
        );
        visitor.visit(&node_cond_assign);

        // 38. conditional assignment where a variable has a hash/array shape in both branches (merging) to hit line 847-851 and 859-865
        let node_cond_shapes = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("shape_var"),
                        make_child_node(make_node(
                            "HASH",
                            vec![make_child_node(make_node(
                                "pair",
                                vec![
                                    make_child_node(make_node("SYMBOL", vec![], ":a")),
                                    make_child_node(make_node("INTEGER", vec![], "1"))
                                ],
                                ":a => 1"
                            ))],
                            "{:a => 1}"
                        ))
                    ],
                    "shape_var = {:a => 1}"
                )),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("shape_var"),
                        make_child_node(make_node(
                            "HASH",
                            vec![make_child_node(make_node(
                                "pair",
                                vec![
                                    make_child_node(make_node("SYMBOL", vec![], ":b")),
                                    make_child_node(make_node("INTEGER", vec![], "2"))
                                ],
                                ":b => 2"
                            ))],
                            "{:b => 2}"
                        ))
                    ],
                    "shape_var = {:b => 2}"
                ))
            ],
            "if true; shape_var = {:a => 1}; else; shape_var = {:b => 2}; end"
        );
        visitor.visit(&node_cond_shapes);

        // 39. (Some(t), None) path of conditional merge to hit line 826
        let node_cond_some_none = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("some_none_var"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "some_none_var = 1"
                )),
                crate::ast::Child::Nil
            ],
            "if true; some_none_var = 1; end"
        );
        visitor.visit(&node_cond_some_none);

        // 40. shadow hash / array / container origin parameter restore to hit line 1000 and 1010
        // We set receiver origin and shape for "a"
        visitor.local_container_origins.insert("a".to_string(), json!({
            "kind": "method parameter",
            "name": "a",
            "path": "test.rb",
            "line": 1
        }));
        visitor.local_hash_shapes.insert("elem".to_string(), json!({"keys": {}}));
        visitor.local_container_origins.insert("elem".to_string(), json!({"kind": "method parameter"}));
        // visiting iter_arr (receiver "a", param "elem") will shadow elem, and then restore it.
        // It also checks receiver shape lookup to hit line 977 and container origin to hit line 982.
        visitor.visit(&iter_arr);

        // 41. ITER block with no block_node to hit line 921
        let iter_no_block = make_node(
            "ITER",
            vec![make_child_node(make_node("CALL", vec![], "foo"))],
            "foo"
        );
        visitor.visit(&iter_no_block);

        // 42. hash_shape_index_type_readonly keys only untyped to hit line 1719
        let hash_idx_recv_untyped = make_node("LVAR", vec![make_symbol("h_idx_untyped")], "h_idx_untyped");
        visitor.local_hash_shapes.insert("h_idx_untyped".to_string(), json!({"keys": {"a": ["T.untyped"]}}));
        assert_eq!(visitor.hash_shape_index_type_readonly(&hash_idx_recv_untyped, &hash_idx_key), None);

        // 43. hash_shape_for_value_readonly pair with exactly 1 child to hit line 1748
        let hash_pair_1_child = make_node(
            "HASH",
            vec![make_child_node(make_node(
                "pair",
                vec![make_child_node(make_node("SYMBOL", vec![], ":a"))],
                ":a =>"
            ))],
            "{:a =>}"
        );
        let _ = visitor.hash_shape_for_value(&hash_pair_1_child);

        // 44. hash_shape_for_value_readonly untyped value to hit line 1758 and 1777
        let hash_untyped_val = make_node(
            "HASH",
            vec![make_child_node(make_node(
                "pair",
                vec![
                    make_child_node(make_node("SYMBOL", vec![], ":a")),
                    make_child_node(make_node("LVAR", vec![make_symbol("untyped_val")], "untyped_val"))
                ],
                ":a => untyped_val"
            ))],
            "{:a => untyped_val}"
        );
        let _ = visitor.hash_shape_for_value(&hash_untyped_val);

        // 45. hash_shape_for_value_readonly non-static key to hit line 1781
        let hash_non_static_key = make_node(
            "HASH",
            vec![make_child_node(make_node(
                "pair",
                vec![
                    make_child_node(make_node("LVAR", vec![make_symbol("x")], "x")),
                    make_child_node(make_node("INTEGER", vec![], "1"))
                ],
                "x => 1"
            ))],
            "{x => 1}"
        );
        let _ = visitor.hash_shape_for_value(&hash_non_static_key);

        // 46. hash_shape_for_value_readonly call fallbacks for VCALL to hit line 1816
        let fcall_node = make_node("FCALL", vec![make_symbol("foo")], "foo()");
        assert_eq!(visitor.hash_shape_for_value(&fcall_node), None);

        // 47. hash_shape_for_value_readonly get_call_info None to hit line 1819
        let call_node_invalid = make_node("CALL", vec![], "invalid");
        assert_eq!(visitor.hash_shape_for_value(&call_node_invalid), None);

        // 48. array_element_shape_for_value_readonly cast / normalizer to hit lines 1863-1866
        let cast_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("CONST", vec![], "T")),
                make_symbol("cast"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                        make_child_node(make_node("CONST", vec![], "Array"))
                    ],
                    "my_arr, Array"
                ))
            ],
            "T.cast(my_arr, Array)"
        );
        let _ = visitor.array_element_shape_for_value(&cast_node);

        // 49. array_element_shape_for_value_readonly method return shape / fallback to hit 1872, 1877
        visitor.method_return_array_shapes.insert(("".to_string(), "my_arr_method".to_string()), json!({"keys": {}}));
        let call_arr_shape = make_node(
            "CALL",
            vec![
                make_child_node(make_node("self", vec![], "self")),
                make_symbol("my_arr_method"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "my_arr_method"
        );
        let _ = visitor.array_element_shape_for_value(&call_arr_shape);

        // 50. array_element_shape_for_value_readonly ITER None path to hit 1909, 1910
        let map_iter_node_no_shape: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "no_shape"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":7, "text":"no_shape"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "no_shape.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "item"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"item"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 6, "text": "item"
                        }},
                        {"Node": {"type": "HASH", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "{}"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "no_shape.map { |item| {} }"
        }"#).unwrap();
        let _ = visitor.array_element_shape_for_value(&map_iter_node_no_shape);

        // 51. array_element_shape_for_value_readonly ITER else branches to hit 1919, 1922, 1925
        let iter_each_node = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_arr.each"
                )),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "my_arr.each {}"
        );
        let _ = visitor.array_element_shape_for_value(&iter_each_node);

        let iter_bad_call = make_node(
            "ITER",
            vec![
                make_child_node(make_node("CALL", vec![], "bad_call")),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "bad_call {}"
        );
        let _ = visitor.array_element_shape_for_value(&iter_bad_call);

        let iter_no_call = make_node(
            "ITER",
            vec![],
            "{}"
        );
        let _ = visitor.array_element_shape_for_value(&iter_no_call);

        // 52. array_element_shape_for_receiver_readonly ITER cases to hit 1941-1945 and 1949
        let iter_map_rec = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                        make_symbol("map"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_arr.map"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node("ARGS", vec![], "")),
                        make_child_node(make_node("HASH", vec![], "{}"))
                    ],
                    ""
                ))
            ],
            "my_arr.map {}"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_map_rec), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_each_node), &extra_hash_shapes);

        // 53. array_element_shape_for_receiver_readonly CALL cases to hit 1966-1969, 1972-1973, 1975-1976, 1980, 1983, 1986
        let select_call = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr")),
                make_symbol("select"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "my_arr.select"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&select_call), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&cast_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_arr_shape), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&fcall_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_node_invalid), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&true_node), &extra_hash_shapes);

        // 54. array_element_shape_for_value_readonly empty array to hit 1846
        let arr_empty_node = make_node("ARRAY", vec![], "[]");
        let _ = visitor.array_element_shape_for_value(&arr_empty_node);

        // 55. deterministic_class_predicate_result / class_guard_truth edge cases to hit 1346, 1347, 1415, 1466, 1473, 1474
        // valid class guard returning Some
        visitor.local_types.insert("guard_x".to_string(), "Integer".to_string());
        let class_guard_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("guard_x")], "guard_x")),
                make_symbol("is_a?"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("CONST", vec![], "Integer"))],
                    "Integer"
                ))
            ],
            "guard_x.is_a?(Integer)"
        );
        assert!(visitor.deterministic_predicate_result(&class_guard_node).is_some());

        // comparison node returning Some
        let comp_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("INTEGER", vec![], "1")),
                make_symbol("=="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "2"))],
                    "2"
                ))
            ],
            "1 == 2"
        );
        assert!(visitor.deterministic_predicate_result(&comp_node).is_some());

        // not type guard to hit 1415
        let non_type_guard_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("guard_x")], "guard_x")),
                make_symbol("foo"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("CONST", vec![], "Integer"))],
                    "Integer"
                ))
            ],
            "guard_x.foo(Integer)"
        );
        assert!(visitor.deterministic_class_predicate_result(&non_type_guard_node).is_none());

        // class_guard_truth edge cases
        assert_eq!(visitor.class_guard_truth("Integer", "Integer", true), None); // exact true disjoint false -> 1466
        assert_eq!(visitor.class_guard_truth("Integer", "String", false), Some(false)); // disjoint true -> 1473
        assert_eq!(visitor.class_guard_truth("MyClass", "OtherClass", false), None); // disjoint false -> 1474

        // 56. deterministic_literal_comparison_result edge cases to hit 1526, 1531, 1534-1538
        let comp_bad_method = make_node(
            "CALL",
            vec![
                make_child_node(make_node("INTEGER", vec![], "1")),
                make_symbol("foo"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "2"))],
                    "2"
                ))
            ],
            "1.foo(2)"
        );
        assert!(visitor.deterministic_literal_comparison_result(&comp_bad_method).is_none());

        let comp_bad_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("INTEGER", vec![], "1")),
                make_symbol("=="),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "1 =="
        );
        assert!(visitor.deterministic_literal_comparison_result(&comp_bad_args).is_none());

        let comp_unknown = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("unknown_var")], "unknown_var")),
                make_symbol("=="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "2"))],
                    "2"
                ))
            ],
            "unknown_var == 2"
        );
        assert!(visitor.deterministic_literal_comparison_result(&comp_unknown).is_none());

        // 57. deterministic_guard_subject_type IVAR, fallback to static_expression_type to hit 1561-1563, 1565
        visitor.current_owners = vec!["MyClass".to_string()];
        visitor.ivar_tlet_types.insert(("MyClass".to_string(), "@my_ivar".to_string()), "String".to_string());
        let ivar_node = make_node("IVAR", vec![make_symbol("@my_ivar")], "@my_ivar");
        assert_eq!(visitor.deterministic_guard_subject_type(&ivar_node), Some("String".to_string()));
        assert_eq!(visitor.deterministic_guard_subject_type(&true_node), Some("T::Boolean".to_string()));

        // 58. literal_static_value for fallback nodes to hit 1587-1596
        let node_int = make_node("INTEGER", vec![], "123");
        assert!(matches!(visitor.literal_static_value(&node_int), LiteralStaticValue::Integer(123)));
        let node_float = make_node("FLOAT", vec![], "1.23");
        assert!(matches!(visitor.literal_static_value(&node_float), LiteralStaticValue::Float(_)));
        let node_true = make_node("TRUE", vec![], "true");
        assert!(matches!(visitor.literal_static_value(&node_true), LiteralStaticValue::Bool(true)));
        let node_false = make_node("FALSE", vec![], "false");
        assert!(matches!(visitor.literal_static_value(&node_false), LiteralStaticValue::Bool(false)));
        let node_nil = make_node("NIL", vec![], "nil");
        assert!(matches!(visitor.literal_static_value(&node_nil), LiteralStaticValue::Nil));
        let node_other_val = make_node("OTHER", vec![], "other");
        assert!(matches!(visitor.literal_static_value(&node_other_val), LiteralStaticValue::Unknown));

        // 59. method matched but has no body / return type confidence is weak to hit 662
        // We define a FunctionDef and its corresponding method in method_param_types,
        // and visit a DEFN node whose body is empty or returns something that triggers weak confidence
        let doc_json_weak = r#"{
            "file": "test.rb",
            "language": "ruby",
            "function_defs": [
                {
                    "file": "test.rb",
                    "name": "my_empty_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "my_weak_method",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": ["x"],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "my_top_method",
                    "owner": "",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                },
                {
                    "file": "test.rb",
                    "name": "my_qcall_untyped",
                    "owner": "MyClass",
                    "line": 1,
                    "span": [1, 1, 5, 5],
                    "body": {
                        "kind": "body",
                        "text": "",
                        "span": [1, 1, 5, 5],
                        "named": true,
                        "field_name": null,
                        "children": []
                    },
                    "visibility": "public",
                    "params": [],
                    "signature": ""
                }
            ]
        }"#;
        let doc_weak: Document = serde_json::from_str(doc_json_weak).unwrap();
        let mut tlet_sites_weak = Vec::new();
        let mut dead_nil_checks_weak = Vec::new();
        let mut deterministic_guards_weak = Vec::new();
        let mut return_origins_weak = Vec::new();
        let mut noreturn_methods_weak = Vec::new();
        let mut collection_index_lookups_weak = Vec::new();
        let mut hash_record_blockers_weak = Vec::new();
        let mut type_normalizers_weak = Vec::new();
        let mut rescue_handlers_weak = Vec::new();
        let mut return_usage_sites_weak = Vec::new();
        let mut return_direct_usage_sites_weak = Vec::new();
        let mut hash_record_escape_sites_weak = Vec::new();
        let mut hidden_enum_observations_weak = Vec::new();
        let mut dispatcher_inferences_weak = Vec::new();
        let mut hash_record_member_calls_weak = Vec::new();
        let mut param_origins_weak = Vec::new();
        let mut struct_declarations_weak = Vec::new();
        let mut state_type_records_weak = Vec::new();
        let mut hash_shapes_weak = Vec::new();
        let mut tuple_arrays_weak = Vec::new();
        let mut visitor_weak = create_visitor(
            &doc_weak,
            &lines,
            &mut tlet_sites_weak,
            &mut dead_nil_checks_weak,
            &mut deterministic_guards_weak,
            &mut return_origins_weak,
            &mut noreturn_methods_weak,
            &mut collection_index_lookups_weak,
            &mut hash_record_blockers_weak,
            &mut type_normalizers_weak,
            &mut rescue_handlers_weak,
            &mut return_usage_sites_weak,
            &mut return_direct_usage_sites_weak,
            &mut hash_record_escape_sites_weak,
            &mut hidden_enum_observations_weak,
            &mut dispatcher_inferences_weak,
            &mut hash_record_member_calls_weak,
            &mut param_origins_weak,
            &mut struct_declarations_weak,
            &mut state_type_records_weak,
            &mut hash_shapes_weak,
            &mut tuple_arrays_weak,
            &pre_registered_noreturns,
        );
        visitor_weak.method_param_hash_shapes.insert(
            ("MyClass".to_string(), "my_weak_method".to_string(), "x".to_string()),
            json!({"keys": {}})
        );
        visitor_weak.method_param_array_shapes.insert(
            ("MyClass".to_string(), "my_weak_method".to_string(), "x".to_string()),
            json!({"keys": {}})
        );
        visitor_weak.current_owners = vec!["MyClass".to_string()];

        // empty body -> expressions empty -> blockers has "no return expression found" -> line 628
        let defn_empty_matched = make_node(
            "DEFN",
            vec![make_symbol("my_empty_method")],
            "def my_empty_method; end"
        );
        visitor_weak.visit(&defn_empty_matched);

        // weak method: returns untyped ivar + 1 -> candidate is "Integer" (useful), blockers is not empty -> confidence is "weak" -> line 662
        let defn_weak_matched = make_node(
            "DEFN",
            vec![
                make_symbol("my_weak_method"),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node(
                            "RETURN",
                            vec![make_child_node(make_node("IVAR", vec![], "@untyped_ivar"))],
                            "return @untyped_ivar"
                        )),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "return @untyped_ivar; 1"
                ))
            ],
            "def my_weak_method; return @untyped_ivar; 1; end"
        );
        visitor_weak.visit(&defn_weak_matched);

        // top method: owner is empty -> line 540
        let defn_top_method = make_node(
            "DEFN",
            vec![make_symbol("my_top_method")],
            "def my_top_method; end"
        );
        visitor_weak.current_owners.clear();
        visitor_weak.visit(&defn_top_method);
        visitor_weak.current_owners = vec!["MyClass".to_string()];

        // DEFN with no children -> line 748
        let defn_no_name = make_node("DEFN", vec![], "");
        visitor_weak.visit(&defn_no_name);

        // qcall untyped: returns x?.foo -> sources has "call_untyped" -> candidate becomes "T.untyped" -> line 642, 649
        let defn_qcall_untyped = make_node(
            "DEFN",
            vec![
                make_symbol("my_qcall_untyped"),
                make_child_node(make_node(
                    "QCALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![make_symbol("x")], "x")),
                        make_symbol("foo"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "x?.foo"
                ))
            ],
            "def my_qcall_untyped; x?.foo; end"
        );
        visitor_weak.visit(&defn_qcall_untyped);

        // --- Extra coverage additions ---

        // 60. []= on a receiver variable with no type to hit line 1088
        let node_bracket_no_type_rec = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_var")], "no_type_var")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("SYMBOL", vec![], ":b")),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    ":b, 2"
                ))
            ],
            "no_type_var[:b] = 2"
        );
        visitor.visit(&node_bracket_no_type_rec);

        // 61. x = T.let(val) with no type argument to hit line 1145
        let node_tlet_no_type = make_node(
            "LASGN",
            vec![
                make_symbol("tlet_no_type_var"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![make_child_node(make_node("IDENTIFIER", vec![], "val"))], "val"))
                    ],
                    "T.let(val)"
                ))
            ],
            "tlet_no_type_var = T.let(val)"
        );
        visitor.visit(&node_tlet_no_type);
        assert_eq!(visitor.local_types.get("tlet_no_type_var"), None);

        // x = obj.foo assignment (not T.let) to cover the false path of method == "let" && receiver.text == "T"
        let node_call_assign = make_node(
            "LASGN",
            vec![
                make_symbol("call_assign_var"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "obj")),
                        make_symbol("foo"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "obj.foo"
                ))
            ],
            "call_assign_var = obj.foo"
        );
        visitor.visit(&node_call_assign);

        // 62. conditional assignment with nilable resolved type to hit line 1155
        let node_cond_assign_nilable = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("cond_var_nilable"),
                        make_child_node(make_node(
                            "CALL",
                            vec![
                                make_child_node(make_node("CONST", vec![], "T")),
                                make_symbol("let"),
                                make_child_node(make_node(
                                    "ARGUMENT_LIST",
                                    vec![
                                        make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                        make_child_node(make_node("CONST", vec![], "T.nilable(Integer)"))
                                    ],
                                    "val, T.nilable(Integer)"
                                ))
                            ],
                            "T.let(val, T.nilable(Integer))"
                        ))
                    ],
                    "cond_var_nilable = T.let(val, T.nilable(Integer))"
                )),
                crate::ast::Child::Nil
            ],
            "if true; cond_var_nilable = T.let(val, T.nilable(Integer)); end"
        );
        visitor.visit(&node_cond_assign_nilable);

        // 63. conditional assignment with untyped resolved type to hit line 1168
        let node_untyped_assign = make_node(
            "LASGN",
            vec![
                make_symbol("untyped_assign_var"),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("let"),
                        make_child_node(make_node(
                            "ARGUMENT_LIST",
                            vec![
                                make_child_node(make_node("IDENTIFIER", vec![], "val")),
                                make_child_node(make_node("CONST", vec![], "T.untyped"))
                            ],
                            "val, T.untyped"
                        ))
                    ],
                    "T.let(val, T.untyped)"
                ))
            ],
            "untyped_assign_var = T.let(val, T.untyped)"
        );
        visitor.visit(&node_untyped_assign);

        // 64. LASGN/DASGN nodes with empty symbol names to hit line 1171
        let lasgn_no_symbol = make_node("LASGN", vec![], "");
        visitor.visit(&lasgn_no_symbol);

        // 65. provably_non_nil on an LVAR node with no symbol child to hit line 1281
        let lvar_no_sym = make_node("LVAR", vec![], "");
        assert!(!visitor.provably_non_nil(&lvar_no_sym));

        // 66. provably_non_nil on a fallback node to hit line 1286
        let fallback_node = make_node("FOO", vec![], "");
        assert!(!visitor.provably_non_nil(&fallback_node));

        // 67. Insert "some_none_var" into visitor.unconditional_vars before visiting node_cond_some_none to hit line 826
        visitor.local_types.remove("some_none_var");
        visitor.unconditional_vars.insert("some_none_var".to_string());
        visitor.visit(&node_cond_some_none);

        // 68. Visit an UNLESS node to hit line 870
        let node_unless = make_node(
            "UNLESS",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("unless_var"),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "unless_var = 1"
                )),
                make_child_node(make_node(
                    "LASGN",
                    vec![
                        make_symbol("unless_var"),
                        make_child_node(make_node("INTEGER", vec![], "2"))
                    ],
                    "unless_var = 2"
                ))
            ],
            "unless true; unless_var = 1; else; unless_var = 2; end"
        );
        visitor.visit(&node_unless);

        let node_if_empty = make_node("IF", vec![], "");
        visitor.visit(&node_if_empty);

        // []= on a receiver variable with an Array type to hit line 1086
        visitor.local_types.insert("bracket_arr_rec".to_string(), "T::Array[Integer]".to_string());
        let node_bracket_arr_rec = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("bracket_arr_rec")], "bracket_arr_rec")),
                make_symbol("[]="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "0")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    "0, 1"
                ))
            ],
            "bracket_arr_rec[0] = 1"
        );
        visitor.visit(&node_bracket_arr_rec);

        // 69. Insert "a" into visitor.local_array_shapes before visitor.visit(&iter_arr) to hit line 977
        visitor.local_array_shapes.insert("a".to_string(), json!({"keys": {}}));
        visitor.visit(&iter_arr);

        // 70. Visit iter_no_call using the main visitor to hit line 988
        let iter_no_call = make_node("ITER", vec![], "{}");
        visitor.visit(&iter_no_call);

        // 71. Call read-only shape functions to cover lines 1745, 1755, 1773, 1777, etc.
        let _ = visitor.hash_shape_for_value_readonly(&hash_pair_1_child, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&hash_untyped_val, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&hash_non_static_key, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&fcall_node, &extra_hash_shapes);
        let _ = visitor.hash_shape_for_value_readonly(&call_node_invalid, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&cast_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&call_arr_shape, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&map_iter_node_no_shape, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&iter_each_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&iter_bad_call, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&iter_no_call, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&arr_empty_node, &extra_hash_shapes);

        let _ = visitor.array_element_shape_for_receiver(Some(&iter_map_rec));
        let _ = visitor.array_element_shape_for_receiver(Some(&iter_each_node));
        let _ = visitor.array_element_shape_for_receiver(Some(&select_call));
        let _ = visitor.array_element_shape_for_receiver(Some(&cast_node));
        let _ = visitor.array_element_shape_for_receiver(Some(&call_arr_shape));
        let _ = visitor.array_element_shape_for_receiver(Some(&fcall_node));
        let _ = visitor.array_element_shape_for_receiver(Some(&call_node_invalid));
        let _ = visitor.array_element_shape_for_receiver(Some(&true_node));

        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_map_rec), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_each_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&select_call), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&cast_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_arr_shape), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&fcall_node), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_node_invalid), &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&true_node), &extra_hash_shapes);

        // 72. LVAR has local hash shape but no type in expression_type_with_locals_and_shapes to hit line 2039
        visitor.local_hash_shapes.insert("no_type_hash".to_string(), json!({"keys": {}}));
        let no_type_hash_node = make_node("LVAR", vec![make_symbol("no_type_hash")], "no_type_hash");
        assert_eq!(
            visitor.expression_type_with_locals_and_shapes(&no_type_hash_node, &BTreeMap::new(), &BTreeMap::new()),
            Some(visitor.behavior.untyped_hash_type())
        );

        // 73. OR / AND left == right == Some("NilClass") in expression_type_with_locals_and_shapes to hit line 2078
        let node_or_nil = make_node(
            "OR",
            vec![
                make_child_node(make_node("NIL", vec![], "nil")),
                make_child_node(make_node("NIL", vec![], "nil"))
            ],
            "nil || nil"
        );
        assert_eq!(
            visitor.expression_type_with_locals_and_shapes(&node_or_nil, &BTreeMap::new(), &BTreeMap::new()),
            Some("NilClass".to_string())
        );

        // 74. ITER node read-only expression_type lookup to hit lines 2125-2204
        visitor.local_types.insert("a".to_string(), "T::Array[Integer]".to_string());
        visitor.static_expression_type(&iter_arr);

        // 75. ITER map node read-only expression_type lookup to hit lines 2172-2197
        let iter_map: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }},
                        {"Node": {"type": "INTEGER", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 2, "text": "1"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.map { |elem| 1 }"
        }"#).unwrap();
        visitor.static_expression_type(&iter_map);

        // 76. ITER filter_map node with nilable return to hit lines 2187-2191
        let iter_filter_map_nilable: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "filter_map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.filter_map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.filter_map { |elem| elem }"
        }"#).unwrap();
        visitor.local_types.insert("a".to_string(), "T::Array[T.nilable(Integer)]".to_string());
        assert_eq!(
            visitor.static_expression_type(&iter_filter_map_nilable),
            Some("T::Array[Integer]".to_string())
        );

        // 77. ITER each node with a hash receiver to hit lines 2146-2159
        let iter_hash: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "h"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"h"}},
                        {"Symbol": "each"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "h.each"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "k"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"k"}},
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "v"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"v"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "k, v"
                        }}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "h.each { |k, v| }"
        }"#).unwrap();
        visitor.local_types.insert("h".to_string(), "T::Hash[Symbol, Integer]".to_string());
        visitor.static_expression_type(&iter_hash);

        // 78. CALL [] with shapes lookup to hit line 2211
        let node_bracket_lookup = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_hash")], "no_type_hash")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("SYMBOL", vec![], ":a"))],
                    ":a"
                ))
            ],
            "no_type_hash[:a]"
        );
        visitor.static_expression_type(&node_bracket_lookup);

        // 79. inferred_return_types lookup in static_expression_type to hit line 2225
        visitor.inferred_return_types.insert(("MyClass".to_string(), "my_inferred_method".to_string()), "String".to_string());
        visitor.current_owners = vec!["MyClass".to_string()];
        let call_inferred = make_node(
            "VCALL",
            vec![make_symbol("my_inferred_method")],
            "my_inferred_method"
        );
        assert_eq!(visitor.static_expression_type(&call_inferred), Some("String".to_string()));

        // 80. static_call_return_type lookup to hit line 2229
        let call_array_index = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_local")], "my_arr_local")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("INTEGER", vec![], "0"))],
                    "0"
                ))
            ],
            "my_arr_local[0]"
        );
        visitor.local_types.insert("my_arr_local".to_string(), "T::Array[Integer]".to_string());
        assert_eq!(visitor.static_expression_type(&call_array_index), Some("T.nilable(Integer)".to_string()));

        // 81. propagated_collection_return_type lookup to hit line 2235
        let call_concat = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr_local")], "my_arr_local")),
                make_symbol("concat"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("other_arr_local")], "other_arr_local"))],
                    "other_arr_local"
                ))
            ],
            "my_arr_local.concat(other_arr_local)"
        );
        assert_eq!(visitor.static_expression_type(&call_concat), Some("T::Array[Integer]".to_string()));

        // 82. Flat hash elements lookup to hit lines 2307-2333 and HASH literal type case (line 2371)
        let flat_hash_node = make_node(
            "HASH",
            vec![
                make_child_node(make_node("label", vec![], "my_key:")),
                make_child_node(make_node("INTEGER", vec![], "1"))
            ],
            "{my_key: 1}"
        );
        let _ = visitor.static_expression_type(&flat_hash_node);

        // 83. Foo.new literal type to hit lines 2379 and 2381
        let call_new_node = make_node(
            "CALL",
            vec![
                make_child_node(make_node("CONST", vec![], "Foo")),
                make_symbol("new"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "Foo.new"
        );
        assert_eq!(visitor.literal_type(&call_new_node), Some("Foo".to_string()));

        // 84. signatures return type extraction in known_return_type to hit lines 2395-2397
        visitor.signatures.insert("MyClass\u{0}my_sig_method".to_string(), "sig { returns(Integer) }".to_string());
        assert_eq!(visitor.known_return_type("my_sig_method"), Some("Integer".to_string()));

        // 85. IF node where both then and else are noreturn to hit lines 2416-2418
        let node_noreturn_if = make_node(
            "IF",
            vec![
                make_child_node(make_node("TRUE", vec![], "true")),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("absurd"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "T.absurd"
                )),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("absurd"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "T.absurd"
                ))
            ],
            "if true; T.absurd; else; T.absurd; end"
        );
        assert!(visitor.noreturn_body(&node_noreturn_if));

        // 86. CASE node where all arms are noreturn to hit lines 2421-2452
        let node_noreturn_case = make_node(
            "CASE",
            vec![
                make_child_node(make_node(
                    "WHEN",
                    vec![
                        make_child_node(make_node("INTEGER", vec![], "1")),
                        make_child_node(make_node(
                            "CALL",
                            vec![
                                make_child_node(make_node("CONST", vec![], "T")),
                                make_symbol("absurd"),
                                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                            ],
                            "T.absurd"
                        ))
                    ],
                    ""
                )),
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("CONST", vec![], "T")),
                        make_symbol("absurd"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "T.absurd"
                ))
            ],
            ""
        );
        assert!(visitor.noreturn_body(&node_noreturn_case));

        // 87. call absurd on non-T receiver to hit lines 2479-2480
        let call_absurd_not_t = make_node(
            "CALL",
            vec![
                make_child_node(make_node("CONST", vec![], "Foo")),
                make_symbol("absurd"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "Foo.absurd"
        );
        assert!(!visitor.noreturn_call(&call_absurd_not_t));

        // 88. HASH with other child node type to hit line 1771
        let hash_with_other_child = make_node(
            "HASH",
            vec![
                make_child_node(make_node(
                    "pair",
                    vec![
                        make_child_node(make_node("SYMBOL", vec![], ":a")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    ":a => 1"
                )),
                make_child_node(make_node("COMMENT", vec![], "# comment"))
            ],
            "{:a => 1, # comment}"
        );
        let _ = visitor.hash_shape_for_value_readonly(&hash_with_other_child, &extra_hash_shapes);

        // 89. CALL with no receiver node (match_call returns None) to cover lines 1799, 1860, 1963
        let call_no_rec_node = make_node(
            "CALL",
            vec![
                crate::ast::Child::Nil,
                make_symbol("foo"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "foo"
        );
        let _ = visitor.hash_shape_for_value_readonly(&call_no_rec_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_value_readonly(&call_no_rec_node, &extra_hash_shapes);
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&call_no_rec_node), &extra_hash_shapes);

        // 90. array_element_shape_for_value_readonly with ATTRASGN / LASGN to cover lines 1823-1828
        let attr_asgn_node = make_node(
            "ATTRASGN",
            vec![
                make_child_node(make_node("LVAR", vec![], "obj")),
                make_symbol("x="),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr"))],
                    "my_arr"
                ))
            ],
            "obj.x = my_arr"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&attr_asgn_node, &extra_hash_shapes);

        let lasgn_arr_node = make_node(
            "LASGN",
            vec![
                make_symbol("x"),
                make_child_node(make_node("LVAR", vec![make_symbol("my_arr")], "my_arr"))
            ],
            "x = my_arr"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&lasgn_arr_node, &extra_hash_shapes);

        // 91. array_element_shape_for_value_readonly call_node_invalid to cover line 1870
        let _ = visitor.array_element_shape_for_value_readonly(&call_node_invalid, &extra_hash_shapes);

        // 92. array_element_shape_for_value_readonly obj_foo_call and fcall_foo to cover lines 1864, 1865, 1867
        let obj_foo_call = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![], "obj")),
                make_symbol("foo"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "obj.foo"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&obj_foo_call, &extra_hash_shapes);

        let fcall_foo = make_node("FCALL", vec![make_symbol("foo")], "foo()");
        let _ = visitor.array_element_shape_for_value_readonly(&fcall_foo, &extra_hash_shapes);

        // 93. ITER map with no ARGS to cover line 1884 & 1891
        let iter_map_no_args = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "my_array")),
                        make_symbol("map"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_array.map"
                )),
                make_child_node(make_node(
                    "BLOCK",
                    vec![make_child_node(make_node("INTEGER", vec![], "1"))],
                    "1"
                ))
            ],
            "my_array.map { 1 }"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&iter_map_no_args, &extra_hash_shapes);

        // 94. ITER map with no block to cover line 1892 & 1899
        let iter_map_no_block = make_node(
            "ITER",
            vec![make_child_node(make_node(
                "CALL",
                vec![
                    make_child_node(make_node("LVAR", vec![], "my_array")),
                    make_symbol("map"),
                    make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                ],
                "my_array.map"
            ))],
            "my_array.map"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&iter_map_no_block, &extra_hash_shapes);
        visitor.static_expression_type(&iter_map_no_block);

        // 95. ITER map as FCALL (no receiver) to cover line 1899 & 2174
        let iter_fcall_map = make_node(
            "ITER",
            vec![
                make_child_node(make_node("FCALL", vec![make_symbol("map")], "map()")),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node("ARGS", vec![make_child_node(make_node("LVAR", vec![], "x"))], "x")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    ""
                ))
            ],
            "map { |x| 1 }"
        );
        let _ = visitor.array_element_shape_for_value_readonly(&iter_fcall_map, &extra_hash_shapes);
        visitor.static_expression_type(&iter_fcall_map);

        // 96. ITER with no receiver node for match_call to cover lines 1937, 1938
        let iter_fcall = make_node(
            "ITER",
            vec![
                make_child_node(make_node("FCALL", vec![make_symbol("foo")], "foo")),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "foo {}"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_fcall), &extra_hash_shapes);

        let iter_each = make_node(
            "ITER",
            vec![
                make_child_node(make_node(
                    "CALL",
                    vec![
                        make_child_node(make_node("LVAR", vec![], "my_arr")),
                        make_symbol("each"),
                        make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
                    ],
                    "my_arr.each"
                )),
                make_child_node(make_node("BLOCK", vec![], ""))
            ],
            "my_arr.each {}"
        );
        let _ = visitor.array_element_shape_for_receiver_readonly(Some(&iter_each), &extra_hash_shapes);

        // 97. static_expression_type for iter_no_block to cover line 2128
        visitor.static_expression_type(&iter_no_block);

        // 98. static_expression_type for iter_hash_none and iter_array_none to cover lines 2143, 2144, 2150, 2151, 2158, 2159, 2161
        visitor.static_expression_type(&iter_hash_none);
        visitor.static_expression_type(&iter_array_none);

        // 99. ITER map return no type to cover line 2187
        let iter_map_no_type_return: crate::ast::Node = serde_json::from_str(r#"{
            "type": "ITER",
            "children": [
                {"Node": {
                    "type": "CALL",
                    "children": [
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "a"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":2, "text":"a"}},
                        {"Symbol": "map"},
                        {"Node": {"type": "LIST", "children": [], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 5, "text": ""}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "a.map"
                }},
                {"Node": {
                    "type": "BLOCK",
                    "children": [
                        {"Node": {
                            "type": "ARGS",
                            "children": [
                                {"Node": {"type": "LVAR", "children": [{"Symbol": "elem"}], "first_lineno":1, "first_column":1, "last_lineno":1, "last_column":5, "text":"elem"}}
                            ],
                            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 10, "text": "elem"
                        }},
                        {"Node": {"type": "LVAR", "children": [{"Symbol": "no_type_var_ret"}], "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": "no_type_var_ret"}}
                    ],
                    "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 15, "text": ""
                }}
            ],
            "first_lineno": 1, "first_column": 1, "last_lineno": 1, "last_column": 20, "text": "a.map { |elem| no_type_var_ret }"
        }"#).unwrap();
        visitor.static_expression_type(&iter_map_no_type_return);

        // 100. ITER fcall select to cover line 2194
        let iter_fcall_select = make_node(
            "ITER",
            vec![
                make_child_node(make_node("FCALL", vec![make_symbol("select")], "select")),
                make_child_node(make_node(
                    "BLOCK",
                    vec![
                        make_child_node(make_node("ARGS", vec![make_child_node(make_node("LVAR", vec![], "x"))], "x")),
                        make_child_node(make_node("INTEGER", vec![], "1"))
                    ],
                    ""
                ))
            ],
            "select { |x| 1 }"
        );
        visitor.static_expression_type(&iter_fcall_select);

        // 101. static_expression_type with bracket lookups to cover lines 2203 and 2206
        visitor.local_hash_shapes.insert("no_type_hash_with_key".to_string(), json!({"keys": {"a": ["Integer"]}}));
        let node_bracket_lookup_with_key = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_hash_with_key")], "no_type_hash_with_key")),
                make_symbol("[]"),
                make_child_node(make_node(
                    "ARGUMENT_LIST",
                    vec![make_child_node(make_node("SYMBOL", vec![], ":a"))],
                    ":a"
                ))
            ],
            "no_type_hash_with_key[:a]"
        );
        assert_eq!(visitor.static_expression_type(&node_bracket_lookup_with_key), Some("T.nilable(Integer)".to_string()));

        let fcall_bracket = make_node(
            "FCALL",
            vec![
                make_symbol("[]"),
                make_child_node(make_node("ARGUMENT_LIST", vec![make_child_node(make_node("INTEGER", vec![], "1"))], "1"))
            ],
            "[](1)"
        );
        visitor.static_expression_type(&fcall_bracket);

        let node_bracket_no_args = make_node(
            "CALL",
            vec![
                make_child_node(make_node("LVAR", vec![make_symbol("no_type_hash")], "no_type_hash")),
                make_symbol("[]"),
                make_child_node(make_node("ARGUMENT_LIST", vec![], ""))
            ],
            "no_type_hash[]"
        );
        visitor.static_expression_type(&node_bracket_no_args);
    }
}
