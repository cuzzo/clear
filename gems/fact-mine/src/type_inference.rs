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
                                if let Some(b) = b_val {
                                    merge_types(t, b)
                                } else {
                                    if t.starts_with("T.nilable(") {
                                        t.clone()
                                    } else {
                                        format!("T.nilable({})", t)
                                    }
                                }
                            }
                            (None, Some(e)) => {
                                if let Some(b) = b_val {
                                    merge_types(b, e)
                                } else {
                                    if e.starts_with("T.nilable(") {
                                        e.clone()
                                    } else {
                                        format!("T.nilable({})", e)
                                    }
                                }
                            }
                            (None, None) => unreachable!(),
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
        if normalized.is_empty() {
            return None;
        }
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
        if bare == "T::Boolean" && matches!(wanted, "TrueClass" | "FalseClass") {
            return false;
        }
        if wanted == "T::Boolean" && matches!(bare, "TrueClass" | "FalseClass") {
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
                    "<=" => Some(left <= right),
                    _ => None,
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
                            if let Some(array) = entry.as_array_mut() {
                                if !array
                                    .iter()
                                    .any(|entry| entry.as_str() == Some(&shape_type))
                                {
                                    array.push(json!(shape_type));
                                }
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
                if non_nil.len() == 1 && useful_type(&non_nil[0]) {
                    return Some(non_nil[0].clone());
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
