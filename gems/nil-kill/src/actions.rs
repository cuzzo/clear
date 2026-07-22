pub fn replace_dead_nil_check(input: &InputState) -> Vec<Action> {
    let mut actions = Vec::new();
    if let Some(checks) = input
        .facts
        .get("dead_nil_checks")
        .and_then(|v| v.as_array())
    {
        for check in checks {
            if let Some(check_obj) = check.as_object() {
                let code = check_obj.get("code").and_then(|v| v.as_str()).unwrap_or("");
                let reason = check_obj
                    .get("reason")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let kind = check_obj.get("kind").and_then(|v| v.as_str()).unwrap_or("");

                let mut data = HashMap::new();
                data.insert(
                    "code".to_string(),
                    serde_json::Value::String(code.to_string()),
                );

                let action_kind = if kind == "nil_check" {
                    "replace_dead_nil_check"
                } else {
                    "remove_dead_safe_nav"
                };

                actions.push(Action {
                    kind: action_kind.to_string(),
                    confidence: "review".to_string(),
                    path: check_obj
                        .get("path")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    line: check_obj.get("line").and_then(|v| v.as_i64()).unwrap_or(0),
                    message: reason.to_string(),
                    data,
                });
            }
        }
    }
    actions
}

pub fn replace_deterministic_guard(input: &InputState) -> Vec<Action> {
    let mut actions = Vec::new();
    if let Some(guards) = input
        .facts
        .get("deterministic_guards")
        .and_then(|v| v.as_array())
    {
        for guard in guards {
            if let Some(guard_obj) = guard.as_object() {
                let proof_tier = guard_obj
                    .get("proof_tier")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if proof_tier != "static_proven" {
                    continue;
                }

                let predicate_kind = guard_obj
                    .get("predicate_kind")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                if predicate_kind == "nil_check" {
                    continue;
                }

                let mut data = HashMap::new();
                for (k, v) in guard_obj {
                    data.insert(k.clone(), v.clone());
                }

                let code = guard_obj.get("code").and_then(|v| v.as_str()).unwrap_or("");
                let truth = guard_obj
                    .get("truth_value")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false);
                let reason = guard_obj
                    .get("reason")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let message = format!("{} is always {}: {}", code, truth, reason);

                actions.push(Action {
                    kind: "replace_deterministic_guard".to_string(),
                    confidence: "review".to_string(),
                    path: guard_obj
                        .get("path")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    line: guard_obj.get("line").and_then(|v| v.as_i64()).unwrap_or(0),
                    message,
                    data,
                });
            }
        }
    }
    actions
}
use crate::schemas::{Action, InputState, MethodRecord, SourceRecord};
use std::collections::{BTreeMap, BTreeSet, HashMap};

pub fn propose_sig(input: &InputState) -> Vec<Action> {
    let mut actions = Vec::new();
    for m in &input.methods {
        let src = match &m.source {
            Some(s) => s,
            None => continue,
        };

        if m.has_sig {
            continue;
        }

        let mut params_str = Vec::new();
        for param in &src.params {
            let name = &param.name;
            let nil_default = param.nil_default;
            let mut typ = "T.untyped".to_string();

            if let Some(classes) = m.params_by_name.get(name) {
                for c_str in classes {
                    if !c_str.is_empty() && c_str != "T.untyped" {
                        typ = c_str.to_string();
                        break;
                    }
                }
            }
            if nil_default && !typ.starts_with("T.nilable(") && typ != "T.untyped" {
                typ = format!("T.nilable({})", typ);
            }
            params_str.push(format!("{}: {}", name, typ));
        }

        let mut ret = "T.untyped".to_string();
        for r_str in &m.returns {
            if !r_str.is_empty() && r_str != "T.untyped" {
                ret = r_str.to_string();
                break;
            }
        }

        let clause = format!("returns({})", ret);
        let sig = if params_str.is_empty() {
            format!("sig {{ {} }}", clause)
        } else {
            format!("sig {{ params({}).{} }}", params_str.join(", "), clause)
        };

        let calls = m.calls;
        let mut conf = if sig.contains("T.untyped") || calls == 0 {
            "review"
        } else {
            if calls >= 20 {
                "high"
            } else {
                "review"
            }
        };

        let uses_yield = src.uses_yield;
        if uses_yield && conf == "high" {
            conf = "review";
        }

        let message = if uses_yield {
            "add missing sig; method uses implicit yield, block typing needs review"
        } else {
            "add missing sig"
        };

        let mut data = HashMap::new();
        data.insert("sig".to_string(), serde_json::Value::String(sig.clone()));
        data.insert(
            "scope".to_string(),
            serde_json::to_value(&src.scope).unwrap(),
        );
        data.insert(
            "method".to_string(),
            serde_json::Value::String(src.method.clone()),
        );

        actions.push(Action {
            kind: "add_sig".to_string(),
            confidence: conf.to_string(),
            path: src.path.clone(),
            line: src.line,
            message: message.to_string(),
            data,
        });
    }
    actions
}

fn sorbet_type(classes: &[String], allow_nilable: bool) -> String {
    let mut others = Vec::new();
    let mut has_nil = false;
    for c in classes {
        if c == "NilClass" {
            has_nil = true;
        } else if !c.is_empty() && !c.contains('#') && !c.starts_with("Sorbet::Private::") {
            others.push(c.clone());
        }
    }

    if others.is_empty() && !has_nil {
        return "T.untyped".to_string();
    }

    let has_ast = others.iter().any(|c| {
        c.starts_with("AST::")
            && c != "AST::Type"
            && c != "AST::Scope"
            && c != "AST::SymbolEntry"
            && c != "AST::Param"
            && c != "AST::Diagnostic"
            && c != "AST::SourceError"
            && c != "AST::DiagnosticBucket"
    });
    let has_mir = others.iter().any(|c| c.starts_with("MIR::"));

    if has_ast || has_mir {
        let mut new_others = Vec::new();
        for c in &others {
            if c.starts_with("AST::")
                && c != "AST::Type"
                && c != "AST::Scope"
                && c != "AST::SymbolEntry"
                && c != "AST::Param"
                && c != "AST::Diagnostic"
                && c != "AST::SourceError"
                && c != "AST::DiagnosticBucket"
            {
                if !new_others.contains(&"AST::Node".to_string()) {
                    new_others.push("AST::Node".to_string());
                }
            } else if c.starts_with("MIR::") {
                if !new_others.contains(&"MIR::Node".to_string()) {
                    new_others.push("MIR::Node".to_string());
                }
            } else {
                if !new_others.contains(c) {
                    new_others.push(c.clone());
                }
            }
        }
        others = new_others;
    }

    others.sort();
    others.dedup();

    let base = if others.len() == 2
        && others.contains(&"TrueClass".to_string())
        && others.contains(&"FalseClass".to_string())
    {
        "T::Boolean".to_string()
    } else if others.len() == 1 {
        others[0].clone()
    } else if others.len() > 1 && others.len() <= 3 {
        format!("T.any({})", others.join(", "))
    } else {
        "T.untyped".to_string()
    };

    if base == "T.untyped" {
        return base;
    }

    if has_nil && allow_nilable {
        format!("T.nilable({})", base)
    } else {
        base
    }
}

fn conservative_element_type(classes: &[String]) -> Option<String> {
    let mut others = Vec::new();
    let mut has_nil = false;
    for c in classes {
        if c == "NilClass" {
            has_nil = true;
        } else if !c.is_empty() && !c.contains('#') && !c.starts_with("Sorbet::Private::") {
            others.push(c.clone());
        }
    }
    others.sort();
    others.dedup();
    if others.is_empty() {
        return None;
    }
    if others.len() == 2
        && others.contains(&"TrueClass".to_string())
        && others.contains(&"FalseClass".to_string())
    {
        return Some("T::Boolean".to_string());
    }
    let klass = if others.len() > 1 && others.iter().all(|c| c.starts_with("AST::")) {
        "AST::Node".to_string()
    } else if others.len() > 1 && others.iter().all(|c| c.starts_with("MIR::")) {
        "MIR::Node".to_string()
    } else if others.len() == 1 {
        let k = others[0].clone();
        if k.starts_with("AST::") || k.starts_with("MIR::") {
            return None;
        }
        k
    } else {
        return None;
    };
    if has_nil {
        Some(format!("T.nilable({})", klass))
    } else {
        Some(klass)
    }
}

fn conservative_element_type_json(classes: &Vec<serde_json::Value>) -> Option<String> {
    let mut str_classes = Vec::new();
    for c in classes {
        if let Some(s) = c.as_str() {
            str_classes.push(s.to_string());
        }
    }
    conservative_element_type(&str_classes)
}

fn shape_union_type(shapes: &[serde_json::Value]) -> Option<String> {
    if shapes.is_empty() {
        return None;
    }

    let mut kinds = Vec::new();
    for shape in shapes {
        if let Some(obj) = shape.as_object() {
            if let Some(kind) = obj.get("kind").and_then(|k| k.as_str()) {
                if !kinds.contains(&kind) {
                    kinds.push(kind);
                }
            }
        }
    }

    if kinds.len() == 1 {
        match kinds[0] {
            "array" => {
                let mut all_elems = Vec::new();
                for shape in shapes {
                    if let Some(elems) = shape.get("elements").and_then(|e| e.as_array()) {
                        all_elems.extend(elems.clone());
                    }
                }
                if !all_elems.is_empty() {
                    let elem =
                        shape_union_type(&all_elems).unwrap_or_else(|| "T.untyped".to_string());
                    return Some(format!("T::Array[{}]", elem));
                }
            }
            "set" => {
                let mut all_elems = Vec::new();
                for shape in shapes {
                    if let Some(elems) = shape.get("elements").and_then(|e| e.as_array()) {
                        all_elems.extend(elems.clone());
                    }
                }
                if !all_elems.is_empty() {
                    let elem =
                        shape_union_type(&all_elems).unwrap_or_else(|| "T.untyped".to_string());
                    return Some(format!("T::Set[{}]", elem));
                }
            }
            "hash" => {
                let mut all_keys = Vec::new();
                let mut all_values = Vec::new();
                for shape in shapes {
                    if let Some(keys) = shape.get("keys").and_then(|e| e.as_array()) {
                        all_keys.extend(keys.clone());
                    }
                    if let Some(values) = shape.get("values").and_then(|e| e.as_array()) {
                        all_values.extend(values.clone());
                    }
                }
                let key = shape_union_type(&all_keys);
                let mut value = shape_union_type(&all_values);
                if value.is_none() && !all_values.is_empty() {
                    value = Some("T.untyped".to_string());
                }
                if let Some(ref v) = value {
                    if v.contains("T.any(") {
                        value = Some("T.untyped".to_string());
                    }
                }
                if let (Some(k), Some(v)) = (key, value) {
                    return Some(format!("T::Hash[{}, {}]", k, v));
                }
            }
            "class" => {
                let mut names = Vec::new();
                for shape in shapes {
                    if let Some(name) = shape.get("name").and_then(|n| n.as_str()) {
                        if !names.contains(&name.to_string()) {
                            names.push(name.to_string());
                        }
                    }
                }
                if names.len() == 1 {
                    return Some(names[0].clone());
                }
            }
            _ => {}
        }
    }

    None
}

fn runtime_return_type_candidate(m: &MethodRecord) -> String {
    let observed = sorbet_type(&m.returns, true);
    if observed == "Array" {
        if let Some(elem) = shape_union_type(&m.return_elem_shapes)
            .or_else(|| conservative_element_type_json(&m.return_elem))
        {
            return format!("T::Array[{}]", elem);
        }
    } else if observed == "Hash" {
        let keys = m
            .return_kv
            .get(0)
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();
        let values = m
            .return_kv
            .get(1)
            .and_then(|v| v.as_array())
            .cloned()
            .unwrap_or_default();

        let mut key_shapes = Vec::new();
        let mut val_shapes = Vec::new();
        if let Some(kv_shapes_arr) = m.return_kv_shapes.get(0).and_then(|v| v.as_array()) {
            key_shapes = kv_shapes_arr.clone();
        }
        if let Some(kv_shapes_arr) = m.return_kv_shapes.get(1).and_then(|v| v.as_array()) {
            val_shapes = kv_shapes_arr.clone();
        }

        let key = shape_union_type(&key_shapes).or_else(|| conservative_element_type_json(&keys));
        let val = shape_union_type(&val_shapes).or_else(|| conservative_element_type_json(&values));

        if let (Some(k), Some(v)) = (key, val) {
            return format!("T::Hash[{}, {}]", k, v);
        }
    } else if observed == "Set" {
        if let Some(elem) = shape_union_type(&m.return_elem_shapes)
            .or_else(|| conservative_element_type_json(&m.return_elem))
        {
            return format!("T::Set[{}]", elem);
        }
    }
    observed
}

fn report_union_candidates(m: &MethodRecord, src: &SourceRecord, actions: &mut Vec<Action>) {
    let params_to_check = if m.params_ok.is_empty() {
        &m.params_by_name
    } else {
        &m.params_ok
    };
    for (name, classes) in params_to_check {
        let mut others: Vec<String> = classes
            .iter()
            .filter(|c| *c != "NilClass")
            .cloned()
            .collect();
        others.sort();
        others.dedup();
        if others.len() > 1 {
            let mut callsites = serde_json::Map::new();
            let sites = if m.param_sites_ok.is_empty() {
                &m.param_sites
            } else {
                &m.param_sites_ok
            };
            if let Some(sites_for_param) = sites.get(name) {
                for (site, count) in sites_for_param {
                    let class_name = site.split(':').last().unwrap_or("");
                    if others.iter().any(|c| c == class_name) {
                        callsites.insert(site.clone(), serde_json::Value::Number((*count).into()));
                    }
                }
            }

            let mut data = HashMap::new();
            data.insert("name".to_string(), serde_json::Value::String(name.clone()));
            data.insert(
                "classes".to_string(),
                serde_json::Value::Array(
                    others
                        .iter()
                        .map(|s| serde_json::Value::String(s.clone()))
                        .collect(),
                ),
            );
            data.insert(
                "callsites".to_string(),
                serde_json::Value::Object(callsites),
            );

            actions.push(Action {
                kind: "union_observed".to_string(),
                confidence: "review".to_string(),
                path: src.path.clone(),
                line: src.line,
                message: format!("param {} observed {}; leaving as T.untyped by default until more evidence or design intent is clear", name, others.join(", ")),
                data,
            });
        }
    }
}

fn generic_type(t: &str) -> bool {
    let raw = strip_nilable_type(t);
    (raw.starts_with("Array[")
        || raw.starts_with("Hash[")
        || raw.starts_with("Set[")
        || raw.starts_with("T::Array[")
        || raw.starts_with("T::Hash[")
        || raw.starts_with("T::Set["))
        && raw.contains("T.untyped")
}

fn strip_nilable_type(t: &str) -> &str {
    if t.starts_with("T.nilable(") && t.ends_with(")") {
        &t[10..t.len() - 1]
    } else {
        t
    }
}

fn preserve_nilable_wrapper(current_type: &str, candidate: &str) -> String {
    if current_type.starts_with("T.nilable(") {
        format!("T.nilable({})", candidate)
    } else {
        candidate.to_string()
    }
}

fn extract_return_type(sig: &str) -> Option<String> {
    if let Some(idx) = sig.find("returns(") {
        let rest = &sig[idx + 8..];
        let mut depth = 1;
        for (i, c) in rest.char_indices() {
            if c == '(' {
                depth += 1;
            } else if c == ')' {
                depth -= 1;
                if depth == 0 {
                    return Some(rest[..i].to_string());
                }
            }
        }
    }
    None
}

fn generic_candidate_type(
    current_type: &str,
    elem_classes: Option<&serde_json::Value>,
    kv_classes: Option<&serde_json::Value>,
    elem_shapes: Option<&serde_json::Value>,
    kv_shapes: Option<&serde_json::Value>,
) -> Option<String> {
    fn valid_candidate(candidate: String) -> Option<String> {
        // Sorbet requires type arguments for its generic collection classes.
        // Runtime element-class telemetry only reports `Hash`/`Array`/`Set`
        // for nested containers; emitting that bare class creates an invalid
        // signature and wastes an Auto-Type verification round. Shape evidence
        // may still produce the valid `T::Hash[...]`/`T::Array[...]` forms.
        let has_bare_collection = candidate
            .split(|c: char| !(c.is_ascii_alphanumeric() || c == '_' || c == ':'))
            .any(|token| matches!(token, "Array" | "Hash" | "Set"));
        (!has_bare_collection).then_some(candidate)
    }

    if current_type.starts_with("Array") || current_type.starts_with("T::Array") {
        let mut elem = None;
        if let Some(shapes) = elem_shapes.and_then(|v| v.as_array()) {
            elem = shape_union_type(shapes);
        }
        if elem.is_none() {
            if let Some(classes) = elem_classes.and_then(|v| v.as_array()) {
                elem = conservative_element_type_json(classes);
            }
        }
        if let Some(e) = elem {
            return valid_candidate(format!("T::Array[{}]", e));
        }
    } else if current_type.starts_with("Set") || current_type.starts_with("T::Set") {
        let mut elem = None;
        if let Some(shapes) = elem_shapes.and_then(|v| v.as_array()) {
            elem = shape_union_type(shapes);
        }
        if elem.is_none() {
            if let Some(classes) = elem_classes.and_then(|v| v.as_array()) {
                elem = conservative_element_type_json(classes);
            }
        }
        if let Some(e) = elem {
            return valid_candidate(format!("T::Set[{}]", e));
        }
    } else if current_type.starts_with("Hash") || current_type.starts_with("T::Hash") {
        let mut key = None;
        let mut val = None;
        if let Some(shapes_arr) = kv_shapes.and_then(|v| v.as_array()) {
            if let Some(k_shapes) = shapes_arr.get(0).and_then(|v| v.as_array()) {
                key = shape_union_type(k_shapes);
            }
            if let Some(v_shapes) = shapes_arr.get(1).and_then(|v| v.as_array()) {
                val = shape_union_type(v_shapes);
            }
        }
        if key.is_none() {
            if let Some(classes_arr) = kv_classes.and_then(|v| v.as_array()) {
                if let Some(k_classes) = classes_arr.get(0).and_then(|v| v.as_array()) {
                    key = conservative_element_type_json(k_classes);
                }
            }
        }
        if val.is_none() {
            if let Some(classes_arr) = kv_classes.and_then(|v| v.as_array()) {
                if let Some(v_classes) = classes_arr.get(1).and_then(|v| v.as_array()) {
                    val = conservative_element_type_json(v_classes);
                }
            }
        }
        if let (Some(k), Some(v)) = (key, val) {
            return valid_candidate(format!("T::Hash[{}, {}]", k, v));
        }
    }
    None
}

pub fn validate_sig(
    input: &InputState,
    m: &MethodRecord,
    src: &SourceRecord,
    unused_returns: &HashMap<String, serde_json::Value>,
) -> Vec<Action> {
    let mut actions = Vec::new();
    let sig = &src.sig;

    for param in &src.params {
        let name = &param.name;
        let current_type = match &param.r#type {
            Some(t) => t,
            None => continue,
        };

        if generic_type(current_type) {
            let inner_type = strip_nilable_type(current_type);
            let param_elem = m.param_elem.get(name);
            let param_kv = m.param_kv.get(name);
            let param_elem_shapes = m.param_elem_shapes.get(name);
            let param_kv_shapes = m.param_kv_shapes.get(name);

            let candidate = generic_candidate_type(
                inner_type,
                param_elem,
                param_kv,
                param_elem_shapes,
                param_kv_shapes,
            );

            if let Some(cand) = candidate {
                let final_cand = preserve_nilable_wrapper(current_type, &cand);
                let observed = m
                    .params_ok
                    .get(name)
                    .or_else(|| m.params_by_name.get(name))
                    .cloned()
                    .unwrap_or_default();
                if final_cand != *current_type && !runtime_contradicts(&observed, &final_cand) {
                    let mut data = HashMap::new();
                    data.insert(
                        "name".to_string(),
                        serde_json::Value::String(name.to_string()),
                    );
                    data.insert(
                        "from".to_string(),
                        serde_json::Value::String(current_type.to_string()),
                    );
                    data.insert(
                        "type".to_string(),
                        serde_json::Value::String(final_cand.clone()),
                    );
                    data.insert(
                        "source".to_string(),
                        serde_json::Value::String("collection_runtime".to_string()),
                    );

                    let action_conf = collection_narrowing_confidence(m.calls, &final_cand);

                    actions.push(Action {
                        kind: "narrow_generic_param".to_string(),
                        confidence: action_conf.to_string(),
                        path: src.path.clone(),
                        line: src.line,
                        message: format!(
                            "narrow generic param {} from {} to {}",
                            name, current_type, final_cand
                        ),
                        data,
                    });
                }
            }
        }
    }

    if let Some(current_return) = extract_return_type(sig) {
        if generic_type(&current_return) {
            let inner_return = strip_nilable_type(&current_return);
            let candidate = generic_candidate_type(
                inner_return,
                Some(&serde_json::Value::Array(m.return_elem.clone())),
                Some(&serde_json::Value::Array(m.return_kv.clone())),
                Some(&serde_json::Value::Array(m.return_elem_shapes.clone())),
                Some(&serde_json::Value::Array(m.return_kv_shapes.clone())),
            );
            if let Some(cand) = candidate {
                let final_cand = preserve_nilable_wrapper(&current_return, &cand);
                if final_cand != current_return && !runtime_contradicts(&m.returns, &final_cand) {
                    let mut data = HashMap::new();
                    data.insert(
                        "from".to_string(),
                        serde_json::Value::String(current_return.clone()),
                    );
                    data.insert(
                        "type".to_string(),
                        serde_json::Value::String(final_cand.clone()),
                    );
                    data.insert(
                        "source".to_string(),
                        serde_json::Value::String("collection_runtime".to_string()),
                    );

                    let action_conf = collection_narrowing_confidence(m.calls, &final_cand);

                    actions.push(Action {
                        kind: "narrow_generic_return".to_string(),
                        confidence: action_conf.to_string(),
                        path: src.path.clone(),
                        line: src.line,
                        message: format!(
                            "narrow generic return from {} to {}",
                            current_return, final_cand
                        ),
                        data,
                    });
                }
            }
        }
    }

    let params_to_check = if m.params_ok.is_empty() {
        &m.params_by_name
    } else {
        &m.params_ok
    };
    for (name, classes) in params_to_check {
        let observed = sorbet_type(classes, true);
        if observed != "T.untyped" && !observed.is_empty() {
            let pattern = format!("{}: T.untyped", name);
            if sig.contains(&pattern)
                || sig.contains(&format!("{}:T.untyped", name))
                || sig.contains(&format!("{}:  T.untyped", name))
            {
                let mut data = HashMap::new();
                data.insert("name".to_string(), serde_json::Value::String(name.clone()));
                data.insert(
                    "type".to_string(),
                    serde_json::Value::String(observed.clone()),
                );

                actions.push(Action {
                    kind: "fix_sig_param".to_string(),
                    confidence: "review".to_string(),
                    path: src.path.clone(),
                    line: src.line,
                    message: format!(
                        "existing sig param {} is T.untyped; observed {}",
                        name, observed
                    ),
                    data,
                });
            }
        }
    }

    if sig.contains("returns(T.untyped)") {
        let observed_return = runtime_return_type_candidate(m);
        if observed_return != "T.untyped" && !observed_return.is_empty() {
            let mut data = HashMap::new();
            data.insert(
                "type".to_string(),
                serde_json::Value::String(observed_return.clone()),
            );

            actions.push(Action {
                kind: "fix_sig_return".to_string(),
                confidence: "review".to_string(),
                path: src.path.clone(),
                line: src.line,
                message: format!(
                    "existing sig return is T.untyped; observed {}",
                    observed_return
                ),
                data,
            });
        }
    }

    if sig.contains("returns(T.untyped)") && !src.noreturn_candidate {
        let key =
            serde_json::json!([src.path, src.line, src.class, src.method, src.kind]).to_string();

        if unused_returns.contains_key(&key) {
            let mut contradicts_void = false;
            for c in &m.returns {
                if !c.is_empty()
                    && c != "NilClass"
                    && !c.contains("#")
                    && !c.starts_with("Sorbet::Private::")
                {
                    contradicts_void = true;
                    break;
                }
            }
            if !contradicts_void {
                let mut data = HashMap::new();
                data.insert(
                    "type".to_string(),
                    serde_json::Value::String("void".to_string()),
                );
                data.insert(
                    "source".to_string(),
                    serde_json::Value::String("unused_return".to_string()),
                );

                actions.push(Action {
                    kind: "fix_sig_return".to_string(),
                    confidence: "high".to_string(),
                    path: src.path.clone(),
                    line: src.line,
                    message:
                        "existing sig return is T.untyped; return value is never used, prefer .void"
                            .to_string(),
                    data,
                });
            }
        }
    }

    if sig.contains("returns(T.untyped)")
        && src.noreturn_candidate
        && !runtime_contradicts(&m.returns, "T.noreturn")
    {
        let mut data = HashMap::new();
        data.insert(
            "type".to_string(),
            serde_json::Value::String("T.noreturn".to_string()),
        );
        data.insert(
            "source".to_string(),
            serde_json::Value::String("noreturn_body".to_string()),
        );

        actions.push(Action {
            kind: "fix_sig_return".to_string(),
            confidence: "high".to_string(),
            path: src.path.clone(),
            line: src.line,
            message: "existing sig return is T.untyped; method body cannot return normally"
                .to_string(),
            data,
        });
    }

    if sig.contains("returns(T.untyped)") {
        if let Some(origins) = input.facts.get("return_origins").and_then(|v| v.as_array()) {
            let method_name = &src.method;
            let class_name = &src.class;
            let kind_name = &src.kind;
            let line_num = src.line;
            for origin in origins {
                let orig_obj = origin.as_object().unwrap();
                if orig_obj.get("method").and_then(|v| v.as_str()) == Some(method_name)
                    && orig_obj.get("class").and_then(|v| v.as_str()) == Some(class_name)
                    && orig_obj.get("kind").and_then(|v| v.as_str()) == Some(kind_name)
                    && orig_obj.get("line").and_then(|v| v.as_i64()) == Some(line_num)
                {
                    let conf = orig_obj
                        .get("confidence")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    let cand = orig_obj
                        .get("candidate_type")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");

                    if cand != "T.untyped" && !cand.is_empty() {
                        let blockers = orig_obj
                            .get("blockers")
                            .cloned()
                            .unwrap_or(serde_json::Value::Array(Vec::new()));

                        let has_blockers = blockers.as_array().map_or(false, |b| !b.is_empty());

                        let mut is_high = conf == "strong" && !has_blockers;
                        if is_high {
                            if let Some(sources) =
                                orig_obj.get("sources").and_then(|v| v.as_array())
                            {
                                let mut useful = Vec::new();
                                for source in sources {
                                    if let Some(s_obj) = source.as_object() {
                                        if s_obj.get("kind").and_then(|v| v.as_str()) != Some("nil")
                                        {
                                            useful.push(s_obj);
                                        }
                                    }
                                }
                                if useful.is_empty() {
                                    is_high = false;
                                } else {
                                    for s_obj in &useful {
                                        let kind = s_obj
                                            .get("kind")
                                            .and_then(|v| v.as_str())
                                            .unwrap_or("");
                                        if kind == "static" || kind == "typed_call_inferred" {
                                            continue;
                                        }
                                        if kind != "typed_call" && kind != "safe_call" {
                                            is_high = false;
                                            break;
                                        }
                                        if s_obj.get("stdlib").map_or(false, |v| {
                                            !v.is_null() && v.as_bool() != Some(false)
                                        }) {
                                            continue;
                                        }
                                        is_high = false;
                                        break;
                                    }

                                    if is_high {
                                        let mut has_bare = false;
                                        for s_obj in &useful {
                                            let kind = s_obj
                                                .get("kind")
                                                .and_then(|v| v.as_str())
                                                .unwrap_or("");
                                            if kind == "static" {
                                                let is_stdlib =
                                                    s_obj.get("stdlib").map_or(false, |v| {
                                                        !v.is_null() && v.as_bool() != Some(false)
                                                    });
                                                if !is_stdlib {
                                                    let code = s_obj
                                                        .get("code")
                                                        .and_then(|v| v.as_str())
                                                        .unwrap_or("");
                                                    let is_self_evident = code.starts_with('"')
                                                        || code.starts_with('[')
                                                        || code.starts_with('{')
                                                        || code.starts_with(':')
                                                        || code.starts_with('/')
                                                        || code == "true"
                                                        || code == "false"
                                                        || code == "nil"
                                                        || code.contains(".new(");
                                                    let starts_with_digit =
                                                        code.chars().next().map_or(false, |c| {
                                                            c.is_ascii_digit() || c == '-'
                                                        });
                                                    if !is_self_evident && !starts_with_digit {
                                                        has_bare = true;
                                                        break;
                                                    }
                                                }
                                            }
                                        }
                                        if has_bare && m.returns.is_empty() {
                                            is_high = false;
                                        }
                                    }
                                }
                            } else {
                                is_high = false;
                            }
                        }

                        let action_conf = if is_high { "high" } else { "review" };

                        let mut data = HashMap::new();
                        data.insert(
                            "type".to_string(),
                            serde_json::Value::String(cand.to_string()),
                        );
                        data.insert(
                            "source".to_string(),
                            serde_json::Value::String("static_return_origin".to_string()),
                        );
                        data.insert(
                            "origin_confidence".to_string(),
                            serde_json::Value::String(conf.to_string()),
                        );

                        let mut final_blockers = blockers
                            .as_array()
                            .map(|v| v.clone())
                            .unwrap_or_else(Vec::new);
                        final_blockers.truncate(8);
                        data.insert(
                            "blockers".to_string(),
                            serde_json::Value::Array(final_blockers),
                        );

                        // Check for contradicts_void
                        let mut contradicts_void = false;
                        for c in &m.returns {
                            if !c.is_empty()
                                && c != "NilClass"
                                && !c.contains("#")
                                && !c.starts_with("Sorbet::Private::")
                            {
                                if cand == "void" {
                                    contradicts_void = true;
                                    break;
                                }
                            }
                        }

                        if !contradicts_void && !runtime_contradicts(&m.returns, cand) {
                            actions.push(Action {
                                kind: "fix_sig_return".to_string(),
                                confidence: action_conf.to_string(),
                                path: src.path.clone(),
                                line: src.line,
                                message: format!("existing sig return is T.untyped; static return origins suggest {}", cand),
                                data,
                            });
                        }
                    }
                    break;
                }
            }
        }
    }

    actions
}

fn extract_param_entries(sig: &str) -> Vec<(String, String)> {
    let mut params = Vec::new();
    if let Some(start) = sig.find("params(") {
        let rest = &sig[start + 7..];
        let mut end = 0;
        let mut depth = 1;
        for (i, c) in rest.char_indices() {
            if c == '(' {
                depth += 1;
            } else if c == ')' {
                depth -= 1;
                if depth == 0 {
                    end = i;
                    break;
                }
            }
        }
        let params_str = &rest[..end];
        let mut current_name = String::new();
        let mut parsing_type = false;
        let mut nest = 0;
        let mut token = String::new();

        for c in params_str.chars() {
            if c == '(' || c == '[' || c == '{' {
                nest += 1;
                token.push(c);
            } else if c == ')' || c == ']' || c == '}' {
                nest -= 1;
                token.push(c);
            } else if c == ':' && nest == 0 && !parsing_type {
                current_name = token.trim().to_string();
                token.clear();
                parsing_type = true;
            } else if c == ',' && nest == 0 {
                if !current_name.is_empty() {
                    params.push((current_name.clone(), token.trim().to_string()));
                }
                token.clear();
                current_name.clear();
                parsing_type = false;
            } else {
                token.push(c);
            }
        }
        if parsing_type {
            if !current_name.is_empty() {
                params.push((current_name, token.trim().to_string()));
            }
        }
    }
    params
}

#[derive(Default)]
struct ProtocolRequirements {
    methods: std::collections::BTreeSet<String>,
    unresolved: bool,
}

fn signature_identity(signature: &serde_json::Value) -> String {
    format!(
        "{}#{}",
        signature
            .get("class")
            .and_then(|value| value.as_str())
            .unwrap_or(""),
        signature
            .get("method")
            .and_then(|value| value.as_str())
            .unwrap_or("")
    )
}

fn signature_param_name(signature: &serde_json::Value, slot: &str) -> Option<String> {
    let entries = extract_param_entries(
        signature
            .get("sig")
            .and_then(|value| value.as_str())
            .unwrap_or(""),
    );
    if let Ok(index) = slot.parse::<usize>() {
        return entries.get(index).map(|(name, _)| name.clone());
    }
    entries
        .iter()
        .find(|(name, _)| name == slot)
        .map(|(name, _)| name.clone())
}

fn resolve_protocol_requirements(
    signature: &serde_json::Value,
    param_name: &str,
    existing_sigs: &[serde_json::Value],
    ivar_protocols: Option<&serde_json::Map<String, serde_json::Value>>,
    visiting: &mut std::collections::BTreeSet<String>,
) -> ProtocolRequirements {
    let visit_key = format!("{}:{param_name}", signature_identity(signature));
    if !visiting.insert(visit_key.clone()) {
        return ProtocolRequirements::default();
    }

    let mut result = ProtocolRequirements::default();
    let protocol = signature
        .get("protocols")
        .and_then(|value| value.as_object())
        .and_then(|protocols| protocols.get(param_name))
        .and_then(|value| value.as_object());
    let Some(protocol) = protocol else {
        visiting.remove(&visit_key);
        return result;
    };

    for method in protocol
        .get("methods")
        .and_then(|value| value.as_array())
        .into_iter()
        .flatten()
        .filter_map(|value| value.as_str())
    {
        result.methods.insert(method.to_string());
    }

    for gap in protocol
        .get("gaps")
        .and_then(|value| value.as_array())
        .into_iter()
        .flatten()
        .filter_map(|value| value.as_str())
    {
        if let Some(rest) = gap.strip_prefix("forwarded to ") {
            let Some((method_name, slot_tail)) = rest.split_once(" slot ") else {
                result.unresolved = true;
                continue;
            };
            let slot = slot_tail.split_whitespace().next().unwrap_or("");
            let candidates: Vec<&serde_json::Value> = existing_sigs
                .iter()
                .filter(|candidate| {
                    candidate.get("method").and_then(|value| value.as_str()) == Some(method_name)
                })
                .collect();
            if candidates.len() != 1 {
                result.unresolved = true;
                continue;
            }
            let Some(target_param) = signature_param_name(candidates[0], slot) else {
                result.unresolved = true;
                continue;
            };
            let nested = resolve_protocol_requirements(
                candidates[0],
                &target_param,
                existing_sigs,
                ivar_protocols,
                visiting,
            );
            result.methods.extend(nested.methods);
            result.unresolved |= nested.unresolved;
        } else if let Some(rest) = gap.strip_prefix("captured in ") {
            let ivar = rest.split_whitespace().next().unwrap_or("");
            let owner = signature
                .get("class")
                .and_then(|value| value.as_str())
                .unwrap_or("");
            let key = format!("{owner}\0{ivar}");
            let methods = ivar_protocols
                .and_then(|protocols| protocols.get(&key))
                .and_then(|value| value.as_array());
            let Some(methods) = methods else {
                result.unresolved = true;
                continue;
            };
            result.methods.extend(
                methods
                    .iter()
                    .filter_map(|value| value.as_str())
                    .map(str::to_string),
            );
        } else {
            result.unresolved = true;
        }
    }

    visiting.remove(&visit_key);
    result
}

fn candidate_satisfies_protocol(
    candidate: &str,
    signature: &serde_json::Value,
    param_name: &str,
    existing_sigs: &[serde_json::Value],
    ivar_protocols: Option<&serde_json::Map<String, serde_json::Value>>,
) -> bool {
    let requirements = resolve_protocol_requirements(
        signature,
        param_name,
        existing_sigs,
        ivar_protocols,
        &mut std::collections::BTreeSet::new(),
    );
    if requirements.unresolved {
        return false;
    }
    requirements.methods.iter().all(|required| {
        existing_sigs.iter().any(|candidate_method| {
            candidate_method
                .get("class")
                .and_then(|value| value.as_str())
                == Some(candidate)
                && candidate_method
                    .get("method")
                    .and_then(|value| value.as_str())
                    == Some(required.as_str())
        })
    })
}

fn propose_static_param_backflow_actions(
    input: &InputState,
    existing_actions: &[Action],
) -> Vec<Action> {
    let mut actions = Vec::new();

    let param_origins = match input.facts.get("param_origins").and_then(|v| v.as_array()) {
        Some(arr) => arr,
        None => return actions,
    };

    let existing_sigs = match input.facts.get("existing_sigs").and_then(|v| v.as_array()) {
        Some(arr) => arr,
        None => return actions,
    };
    let ivar_protocols = input
        .facts
        .get("ivar_protocols")
        .and_then(|value| value.as_object());

    let mut origins_by_callee = std::collections::HashMap::new();
    for origin in param_origins {
        if let Some(callee) = origin.get("callee").and_then(|v| v.as_str()) {
            origins_by_callee
                .entry(callee)
                .or_insert_with(Vec::new)
                .push(origin.clone());
        }
    }

    for method in existing_sigs {
        let name = match method.get("method").and_then(|v| v.as_str()) {
            Some(n) => n,
            None => continue,
        };
        let path = match method.get("path").and_then(|v| v.as_str()) {
            Some(p) => p,
            None => continue,
        };
        let line = match method.get("line").and_then(|v| v.as_i64()) {
            Some(l) => l,
            None => continue,
        };
        let sig = match method.get("sig").and_then(|v| v.as_str()) {
            Some(s) => s,
            None => continue,
        };

        let m_params = extract_param_entries(sig);

        for (idx, (param_name, current_type)) in m_params.iter().enumerate() {
            if current_type != "T.untyped" {
                continue;
            }

            let mut origins = Vec::new();
            if let Some(callee_origins) = origins_by_callee.get(name) {
                for origin in callee_origins {
                    if let Some(slot) = origin.get("slot") {
                        let matches = if let Some(s) = slot.as_str() {
                            s == idx.to_string() || s == param_name
                        } else if let Some(i) = slot.as_i64() {
                            i == idx as i64
                        } else {
                            false
                        };
                        if matches {
                            origins.push(origin.clone());
                        }
                    }
                }
            }

            if origins.is_empty() {
                continue;
            }

            let mut has_unknown = false;
            let mut types = Vec::new();
            for origin in &origins {
                let kind = origin
                    .get("origin_kind")
                    .and_then(|v| v.as_str())
                    .unwrap_or("");
                let t = origin.get("type").and_then(|v| v.as_str()).unwrap_or("");
                if kind == "unknown" || t.is_empty() {
                    has_unknown = true;
                    break;
                }
                if kind == "local" && !useful_type(t) {
                    has_unknown = true;
                    break;
                }
                if !t.is_empty() {
                    types.push(t.to_string());
                }
            }

            if has_unknown {
                continue;
            }

            if let Some(candidate) = static_sorbet_type(&types) {
                if !useful_type(&candidate)
                    || weak_type(&candidate)
                    || strip_nilable_type(&candidate) == "Object"
                {
                    continue;
                }
                if !candidate_satisfies_protocol(
                    &candidate,
                    method,
                    param_name,
                    existing_sigs,
                    ivar_protocols,
                ) {
                    continue;
                }
                if let Some(runtime) = runtime_record_for_signature(input, method) {
                    let observed = runtime
                        .params_ok
                        .get(param_name)
                        .or_else(|| runtime.params_by_name.get(param_name))
                        .cloned()
                        .unwrap_or_default();
                    if runtime_contradicts(&observed, &candidate) {
                        continue;
                    }
                }

                // Skip if an existing action already covers this param with the same candidate
                let mut exists = false;
                for act in existing_actions {
                    if act.kind == "fix_sig_param" && act.path == path && act.line == line {
                        if let Some(n) = act.data.get("name").and_then(|v| v.as_str()) {
                            if n == param_name {
                                if let Some(t) = act.data.get("type").and_then(|v| v.as_str()) {
                                    if t == candidate {
                                        exists = true;
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
                if exists {
                    continue;
                }

                let mut data = std::collections::HashMap::new();
                data.insert(
                    "name".to_string(),
                    serde_json::Value::String(param_name.clone()),
                );
                data.insert(
                    "type".to_string(),
                    serde_json::Value::String(candidate.clone()),
                );
                data.insert(
                    "source".to_string(),
                    serde_json::Value::String("static_param_backflow".to_string()),
                );

                let mut callsites_map = serde_json::Map::new();
                for origin in &origins {
                    let p = origin.get("path").and_then(|v| v.as_str()).unwrap_or("");
                    let l = origin.get("line").and_then(|v| v.as_i64()).unwrap_or(0);
                    let c = origin.get("code").and_then(|v| v.as_str()).unwrap_or("");
                    let key = format!("{}:{}:{}", p, l, c);
                    if let Some(val) = callsites_map.get_mut(&key) {
                        *val = serde_json::Value::Number(serde_json::Number::from(
                            val.as_i64().unwrap_or(0) + 1,
                        ));
                    } else {
                        callsites_map
                            .insert(key, serde_json::Value::Number(serde_json::Number::from(1)));
                    }
                }
                data.insert(
                    "callsites".to_string(),
                    serde_json::Value::Object(callsites_map),
                );
                data.insert(
                    "callsite_count".to_string(),
                    serde_json::Value::Number(serde_json::Number::from(origins.len())),
                );

                actions.push(Action {
                    kind: "fix_sig_param".to_string(),
                    confidence: "review".to_string(),
                    path: path.to_string(),
                    line: line,
                    message: format!(
                        "static callsites prove param {} is {}; {} static callsite(s) agree",
                        param_name,
                        candidate,
                        origins.len()
                    ),
                    data,
                });
            }
        }
    }

    actions
}

fn useful_type(t: &str) -> bool {
    !t.is_empty()
        && t != "T.untyped"
        && t != "Object"
        && t != "BasicObject"
        && t != "T.anything"
        && !t.starts_with("T.class_of(")
}

fn weak_type(t: &str) -> bool {
    t.starts_with("T.any(")
        && (t.contains("T.untyped") || t.contains("Object") || t.contains("BasicObject"))
}

fn proposed_type_accepts(proposed_type: &str, observed_class: &str) -> bool {
    let proposed = proposed_type.trim();
    if proposed.is_empty() || observed_class.is_empty() {
        return false;
    }
    if proposed == "T.untyped"
        || observed_class.contains('#')
        || observed_class.starts_with("Sorbet::Private::")
    {
        return true;
    }
    if proposed == "void" {
        return observed_class == "NilClass";
    }
    if proposed == "T.noreturn" {
        return false;
    }
    if let Some(inner) = proposed
        .strip_prefix("T.nilable(")
        .and_then(|value| value.strip_suffix(')'))
    {
        return observed_class == "NilClass" || proposed_type_accepts(inner, observed_class);
    }
    if let Some(inner) = proposed
        .strip_prefix("T.any(")
        .and_then(|value| value.strip_suffix(')'))
    {
        return split_top_level_types(inner)
            .iter()
            .any(|alternative| proposed_type_accepts(alternative, observed_class));
    }
    if proposed == "T::Boolean" {
        return matches!(observed_class, "TrueClass" | "FalseClass" | "T::Boolean");
    }
    if proposed.starts_with("T::Array[") {
        return observed_class == "Array";
    }
    if proposed.starts_with("T::Hash[") {
        return observed_class == "Hash";
    }
    if proposed.starts_with("T::Set[") {
        return observed_class == "Set";
    }
    if proposed.starts_with("T::Enumerable[") {
        return matches!(observed_class, "Array" | "Hash" | "Set");
    }
    proposed == observed_class
}

fn split_top_level_types(types: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut token = String::new();
    let mut depth = 0_i64;
    for character in types.chars() {
        match character {
            '(' | '[' | '{' => {
                depth += 1;
                token.push(character);
            }
            ')' | ']' | '}' => {
                depth -= 1;
                token.push(character);
            }
            ',' if depth == 0 => {
                result.push(token.trim().to_string());
                token.clear();
            }
            _ => token.push(character),
        }
    }
    if !token.trim().is_empty() {
        result.push(token.trim().to_string());
    }
    result
}

fn runtime_contradicts(observed_classes: &[String], proposed_type: &str) -> bool {
    observed_classes
        .iter()
        .filter(|observed| !observed.is_empty())
        .any(|observed| !proposed_type_accepts(proposed_type, observed))
}

fn runtime_record_for_signature<'a>(
    input: &'a InputState,
    signature: &serde_json::Value,
) -> Option<&'a MethodRecord> {
    let path = signature
        .get("path")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let line = signature
        .get("line")
        .and_then(|value| value.as_i64())
        .unwrap_or(0);
    let owner = signature
        .get("class")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let method = signature
        .get("method")
        .and_then(|value| value.as_str())
        .unwrap_or("");
    let kind = signature
        .get("kind")
        .and_then(|value| value.as_str())
        .unwrap_or("");

    input.methods.iter().find(|record| {
        if let Some(source) = &record.source {
            return source.line == line
                && source.class == owner
                && source.method == method
                && source.kind == kind
                && (source.path == path
                    || source.path.ends_with(path)
                    || path.ends_with(&source.path));
        }
        let key_strings: Vec<String> = record
            .key
            .iter()
            .map(|value| value.as_str().unwrap_or("").to_string())
            .collect();
        key_strings.get(0).map(String::as_str) == Some(owner)
            && key_strings.get(1).map(String::as_str) == Some(method)
            && key_strings.get(2).map(String::as_str) == Some(kind)
            && record.key.get(4).and_then(|value| value.as_i64()) == Some(line)
            && key_strings
                .get(3)
                .is_some_and(|runtime_path| runtime_path == path || runtime_path.ends_with(path))
    })
}

fn static_sorbet_type(types: &[String]) -> Option<String> {
    if types.is_empty() {
        return None;
    }
    let mut has_nil = false;
    let mut uniq = Vec::new();
    for t in types {
        let normalized = match t.as_str() {
            "NilClass" => {
                has_nil = true;
                continue;
            }
            "Array" => "T::Array[T.untyped]".to_string(),
            "Hash" => "T::Hash[T.untyped, T.untyped]".to_string(),
            "Set" => "T::Set[T.untyped]".to_string(),
            value if value.starts_with("T.nilable(") && value.ends_with(')') => {
                has_nil = true;
                value[10..value.len() - 1].to_string()
            }
            value => value.to_string(),
        };
        if !uniq.contains(&normalized) {
            uniq.push(normalized);
        }
    }
    if uniq.is_empty() {
        return has_nil.then(|| "NilClass".to_string());
    }
    uniq.sort();
    let base = if uniq
        .iter()
        .all(|value| matches!(value.as_str(), "TrueClass" | "FalseClass" | "T::Boolean"))
    {
        "T::Boolean".to_string()
    } else if uniq.len() == 1 {
        uniq[0].clone()
    } else {
        return None;
    };
    Some(if has_nil {
        format!("T.nilable({base})")
    } else {
        base
    })
}

fn weak_collection_type(t: &str) -> bool {
    t == "Array"
        || t == "Hash"
        || t == "Set"
        || t == "T::Array[T.untyped]"
        || t == "T::Set[T.untyped]"
        || t == "T::Hash[T.untyped, T.untyped]"
}

fn runtime_field_candidate(classes: &[String], elem_classes: &[String]) -> Option<String> {
    let concrete: Vec<String> = classes.iter().filter(|c| useful_type(c)).cloned().collect();
    if concrete.is_empty() {
        return None;
    }

    if concrete.len() == 1 && concrete[0] == "Array" && !elem_classes.is_empty() {
        if let Some(elem) = runtime_field_candidate(elem_classes, &[]) {
            return Some(format!("T::Array[{}]", elem));
        }
    }

    let bool_classes = concrete
        .iter()
        .all(|c| c == "TrueClass" || c == "FalseClass" || c == "T::Boolean");
    if bool_classes {
        return Some("T::Boolean".to_string());
    }

    // Field telemetry must never erase a nil observation. A field contract is
    // persistent state, not a transient parameter sample; narrowing
    // `T.nilable(MIR::Node)` to `MIR::Node` from the non-nil observations is
    // unsound. Nilable candidates remain review-only until callers are proven
    // ready for the stronger contract.
    let observed = persistent_field_type(&concrete);
    if useful_type(&observed) && !weak_type(&observed) && !observed.contains("T.nilable") {
        Some(observed)
    } else {
        None
    }
}

fn persistent_field_type(classes: &[String]) -> String {
    let mut concrete = Vec::new();
    let mut has_nil = false;
    for class in classes {
        if class == "NilClass" {
            has_nil = true;
        } else if useful_type(class)
            && !class.contains('#')
            && !class.starts_with("Sorbet::Private::")
        {
            concrete.push(class.clone());
        }
    }
    concrete.sort();
    concrete.dedup();

    let base = if concrete.len() == 2
        && concrete.contains(&"TrueClass".to_string())
        && concrete.contains(&"FalseClass".to_string())
    {
        "T::Boolean".to_string()
    } else if concrete.len() == 1 {
        concrete[0].clone()
    } else if concrete.len() > 1 && concrete.len() <= 3 {
        format!("T.any({})", concrete.join(", "))
    } else {
        return "T.untyped".to_string();
    };

    if has_nil {
        format!("T.nilable({base})")
    } else {
        base
    }
}

fn static_field_candidate(types: &[String]) -> Option<String> {
    let concrete: Vec<String> = types.iter().filter(|t| useful_type(t)).cloned().collect();
    if concrete.is_empty() {
        return None;
    }
    if concrete
        .iter()
        .all(|t| t == "TrueClass" || t == "FalseClass" || t == "T::Boolean")
    {
        return Some("T::Boolean".to_string());
    }
    static_sorbet_type(&concrete).and_then(|candidate| {
        if useful_type(&candidate) && !weak_type(&candidate) && !candidate.contains("T.nilable") {
            Some(candidate)
        } else {
            None
        }
    })
}

fn collapsible_node_union(current_type: &str, candidate: &str) -> bool {
    if !current_type.starts_with("T.any(") {
        return false;
    }
    if candidate == "AST::Node" {
        return current_type.contains("AST::");
    }
    if candidate == "MIR::Node" {
        return current_type.contains("MIR::");
    }
    false
}

fn collapsible_boolean_union(current_type: &str, candidate: &str) -> bool {
    candidate == "T::Boolean"
        && current_type.starts_with("T.any(")
        && current_type.contains("TrueClass")
        && current_type.contains("FalseClass")
}

fn rewriteable_field_type(current_type: &str, candidate: &str) -> bool {
    let current = current_type.trim();
    if current.is_empty() {
        return false;
    }
    if current == candidate {
        return false;
    }
    current == "T.untyped"
        || weak_collection_type(current)
        || weak_type(current)
        || collapsible_node_union(current, candidate)
        || collapsible_boolean_union(current, candidate)
}

fn propose_false_nilable_return_actions(input: &InputState) -> Vec<Action> {
    let Some(existing_sigs) = input.facts.get("existing_sigs").and_then(|value| value.as_array())
    else {
        return Vec::new();
    };
    let Some(return_origins) = input.facts.get("return_origins").and_then(|value| value.as_array())
    else {
        return Vec::new();
    };

    let origins_by_location = return_origins
        .iter()
        .map(|origin| (fact_location(origin), origin))
        .collect::<std::collections::HashMap<_, _>>();
    let mut actions = Vec::new();

    for method in existing_sigs {
        let Some(non_nil_type) = method.get("non_nil_return_type") else {
            continue;
        };
        if non_nil_type.is_null() {
            continue;
        }
        let Some(origin) = origins_by_location.get(&fact_location(method)) else {
            continue;
        };
        let blockers_empty = origin
            .get("blockers")
            .and_then(|value| value.as_array())
            .is_some_and(Vec::is_empty);
        if origin.get("confidence").and_then(|value| value.as_str()) != Some("strong")
            || !blockers_empty
            || origin.get("candidate_type") != Some(non_nil_type)
        {
            continue;
        }

        let Some(candidate_text) = method
            .get("non_nil_return_type_text")
            .and_then(|value| value.as_str())
            .filter(|value| !value.is_empty())
        else {
            continue;
        };
        let current_text = method
            .get("return_type_text")
            .and_then(|value| value.as_str())
            .unwrap_or_default();
        let path = method
            .get("path")
            .and_then(|value| value.as_str())
            .unwrap_or_default();
        let line = method
            .get("line")
            .and_then(|value| value.as_i64())
            .unwrap_or_default();
        let mut data = HashMap::new();
        data.insert(
            "type".to_string(),
            serde_json::Value::String(candidate_text.to_string()),
        );
        data.insert(
            "from".to_string(),
            serde_json::Value::String(current_text.to_string()),
        );
        data.insert(
            "source".to_string(),
            serde_json::Value::String("static_return_origin".to_string()),
        );

        actions.push(Action {
            kind: "fix_sig_return".to_string(),
            confidence: "high".to_string(),
            path: path.to_string(),
            line,
            message: format!(
                "declared return {} is always {}",
                current_text, candidate_text
            ),
            data,
        });
    }

    actions
}

fn fact_location(value: &serde_json::Value) -> String {
    let text = |key| value.get(key).and_then(|item| item.as_str()).unwrap_or_default();
    let line = value
        .get("line")
        .and_then(|item| item.as_i64())
        .unwrap_or_default();
    format!(
        "{}:{}:{}:{}:{}",
        text("path"),
        line,
        text("class"),
        text("method"),
        text("kind")
    )
}

fn propose_forwarded_return_chain_actions(input: &InputState) -> Vec<Action> {
    let mut actions = Vec::new();

    let existing_sigs = match input.facts.get("existing_sigs").and_then(|v| v.as_array()) {
        Some(arr) => arr,
        None => return actions,
    };

    let return_origins = match input.facts.get("return_origins").and_then(|v| v.as_array()) {
        Some(arr) => arr,
        None => return actions,
    };

    let mut untyped_methods = Vec::new();
    for method in existing_sigs {
        if let Some(sig) = method.get("sig").and_then(|v| v.as_str()) {
            if extract_return_type(sig).as_deref() == Some("T.untyped") {
                untyped_methods.push(method);
            }
        }
    }

    if untyped_methods.is_empty() {
        return actions;
    }

    let mut origin_by_location = std::collections::HashMap::new();
    for origin in return_origins {
        let path = origin.get("path").and_then(|v| v.as_str()).unwrap_or("");
        let line = origin.get("line").and_then(|v| v.as_i64()).unwrap_or(0);
        let class = origin.get("class").and_then(|v| v.as_str()).unwrap_or("");
        let method = origin.get("method").and_then(|v| v.as_str()).unwrap_or("");
        let kind = origin.get("kind").and_then(|v| v.as_str()).unwrap_or("");
        origin_by_location.insert(
            format!("{}:{}:{}:{}:{}", path, line, class, method, kind),
            origin.clone(),
        );
    }

    for method in untyped_methods {
        let path = method.get("path").and_then(|v| v.as_str()).unwrap_or("");
        let line = method.get("line").and_then(|v| v.as_i64()).unwrap_or(0);
        let class = method.get("class").and_then(|v| v.as_str()).unwrap_or("");
        let m_name = method.get("method").and_then(|v| v.as_str()).unwrap_or("");
        let kind = method.get("kind").and_then(|v| v.as_str()).unwrap_or("");

        let mut origin = None;
        if let Some(ro) = method.get("return_origin") {
            origin = Some(ro.clone());
        } else if let Some(ro) =
            origin_by_location.get(&format!("{}:{}:{}:{}:{}", path, line, class, m_name, kind))
        {
            origin = Some(ro.clone());
        }

        if let Some(o) = origin {
            let sources = match o.get("sources").and_then(|v| v.as_array()) {
                Some(arr) => arr,
                None => continue,
            };

            if sources.is_empty() {
                continue;
            }

            let mut types = Vec::new();
            let mut chain = vec![format!("{}:{} {}#{}", path, line, class, m_name)];
            let mut forwarded = false;
            let mut failed = false;

            for source in sources {
                let skind = source.get("kind").and_then(|v| v.as_str()).unwrap_or("");
                match skind {
                    "static" | "assignment" | "typed_call" | "safe_call" => {
                        let t = source.get("type").and_then(|v| v.as_str()).unwrap_or("");
                        if !useful_type(t) {
                            failed = true;
                            break;
                        }
                        types.push(t.to_string());
                        if skind == "typed_call" || skind == "safe_call" {
                            forwarded = true;
                        }

                        let sl = source.get("line").and_then(|v| v.as_i64()).unwrap_or(0);
                        chain.push(format!(
                            "{} {} at line {}",
                            skind,
                            source.get("callee").and_then(|v| v.as_str()).unwrap_or(""),
                            sl
                        ));
                    }
                    "nil" => {
                        types.push("NilClass".to_string());
                    }
                    _ => {
                        failed = true;
                        break;
                    }
                }
            }

            if failed || !forwarded {
                continue;
            }

            if let Some(candidate) = static_sorbet_type(&types) {
                if !useful_type(&candidate) || weak_type(&candidate) {
                    continue;
                }
                if let Some(runtime) = runtime_record_for_signature(input, method) {
                    if runtime_contradicts(&runtime.returns, &candidate) {
                        continue;
                    }
                }

                let confidence = if ["String", "Integer", "Float", "Symbol", "T::Boolean"]
                    .contains(&candidate.as_str())
                {
                    "high"
                } else {
                    "review"
                };

                let mut data = std::collections::HashMap::new();
                data.insert(
                    "type".to_string(),
                    serde_json::Value::String(candidate.clone()),
                );
                data.insert(
                    "source".to_string(),
                    serde_json::Value::String("forwarded_return_chain".to_string()),
                );
                let chain_vals: Vec<serde_json::Value> =
                    chain.into_iter().map(serde_json::Value::String).collect();
                data.insert("chain".to_string(), serde_json::Value::Array(chain_vals));

                actions.push(Action {
                    kind: "fix_sig_return".to_string(),
                    confidence: confidence.to_string(),
                    path: path.to_string(),
                    line: line,
                    message: format!(
                        "existing sig return is T.untyped; forwarded-return chain resolves to {}",
                        candidate
                    ),
                    data,
                });
            }
        }
    }

    actions
}

fn propose_struct_field_sig_actions(input: &InputState) -> Vec<Action> {
    let mut actions = Vec::new();

    let struct_runtime = input
        .facts
        .get("struct_field_runtime")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let ivar_runtime = input
        .facts
        .get("ivar_runtime")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let static_fields = input
        .facts
        .get("struct_field_static")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let type_definitions = input
        .facts
        .get("type_definitions")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();
    let effective_field_types = input
        .facts
        .get("effective_struct_field_types")
        .and_then(|v| v.as_array())
        .cloned()
        .unwrap_or_default();

    if struct_runtime.is_empty()
        && ivar_runtime.is_empty()
        && static_fields.is_empty()
        && type_definitions.is_empty()
    {
        return actions;
    }

    // A Struct's raw storage declaration is not necessarily its public field
    // contract. Ruby code commonly replaces the generated accessor with a
    // typed method, or includes a module that does so. Do not propose a second
    // RBI signature when FactMine already found a strong effective accessor:
    // it is redundant at best and can unsafely narrow a deliberately broader
    // source contract from the runtime classes observed in one test run.
    let mut accessor_contracts = std::collections::BTreeSet::new();
    let mut included_modules: std::collections::HashMap<
        String,
        std::collections::BTreeSet<String>,
    > = std::collections::HashMap::new();
    for rec in &type_definitions {
        match rec.get("kind").and_then(|v| v.as_str()) {
            Some("method_signature") => {
                let owner = rec.get("owner").and_then(|v| v.as_str()).unwrap_or("");
                let name = rec.get("name").and_then(|v| v.as_str()).unwrap_or("");
                let signature = rec.get("signature").and_then(|v| v.as_str()).unwrap_or("");
                let Some(return_type) = extract_return_type(signature) else {
                    continue;
                };
                if !owner.is_empty()
                    && !name.is_empty()
                    && useful_type(&return_type)
                    && !return_type.contains("T.untyped")
                    && !weak_type(&return_type)
                    && !weak_collection_type(&return_type)
                {
                    accessor_contracts.insert((owner.to_string(), name.to_string()));
                }
            }
            Some("included_module") => {
                let owner = rec.get("owner").and_then(|v| v.as_str()).unwrap_or("");
                let name = rec.get("name").and_then(|v| v.as_str()).unwrap_or("");
                if !owner.is_empty() && !name.is_empty() {
                    included_modules
                        .entry(owner.to_string())
                        .or_default()
                        .insert(name.to_string());
                }
            }
            _ => {}
        }
    }
    for rec in effective_field_types {
        let owner = rec.get("owner").and_then(|v| v.as_str()).unwrap_or("");
        let field = rec.get("field").and_then(|v| v.as_str()).unwrap_or("");
        let field_type = rec.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if !owner.is_empty()
            && !field.is_empty()
            && useful_type(field_type)
            && !field_type.contains("T.untyped")
            && !weak_type(field_type)
            && !weak_collection_type(field_type)
        {
            accessor_contracts.insert((owner.to_string(), field.to_string()));
        }
    }
    loop {
        let snapshot = included_modules.clone();
        let mut changed = false;
        for modules in included_modules.values_mut() {
            let inherited: Vec<String> = modules
                .iter()
                .flat_map(|module| snapshot.get(module).into_iter().flatten().cloned())
                .collect();
            for module in inherited {
                changed |= modules.insert(module);
            }
        }
        if !changed {
            break;
        }
    }
    let inherited_contracts: Vec<(String, String)> = included_modules
        .iter()
        .flat_map(|(owner, modules)| {
            accessor_contracts
                .iter()
                .filter(move |(contract_owner, _)| modules.contains(contract_owner))
                .map(move |(_, field)| (owner.clone(), field.clone()))
        })
        .collect();
    accessor_contracts.extend(inherited_contracts);

    #[derive(Clone)]
    struct Declaration {
        path: String,
        line: i64,
        raw_field: String,
        current_type: String,
        type_system: String,
    }

    struct Slot {
        class: String,
        field: String,
        runtime_classes: Vec<String>,
        elem_classes: Vec<String>,
        static_types: Vec<String>,
        declarations: Vec<Declaration>,
        runtime_calls: i64,
        static_count: i64,
        has_unknown_static: bool,
        has_struct_runtime: bool,
        has_ivar_runtime: bool,
    }

    let mut by_slot: std::collections::HashMap<(String, String), Slot> =
        std::collections::HashMap::new();

    for rec in struct_runtime {
        let class = rec
            .get("class")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let field = rec
            .get("field")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if class.is_empty() || field.is_empty() {
            continue;
        }
        let key = (class.clone(), field.clone());

        let slot = by_slot.entry(key).or_insert(Slot {
            class,
            field,
            runtime_classes: Vec::new(),
            elem_classes: Vec::new(),
            static_types: Vec::new(),
            declarations: Vec::new(),
            runtime_calls: 0,
            static_count: 0,
            has_unknown_static: false,
            has_struct_runtime: false,
            has_ivar_runtime: false,
        });

        if let Some(arr) = rec.get("classes").and_then(|v| v.as_array()) {
            for c in arr {
                if let Some(c_str) = c.as_str() {
                    if !slot.runtime_classes.contains(&c_str.to_string()) {
                        slot.runtime_classes.push(c_str.to_string());
                    }
                }
            }
        }

        if let Some(arr) = rec.get("elem_classes").and_then(|v| v.as_array()) {
            for c in arr {
                if let Some(c_str) = c.as_str() {
                    if !slot.elem_classes.contains(&c_str.to_string()) {
                        slot.elem_classes.push(c_str.to_string());
                    }
                }
            }
        }

        slot.runtime_calls += rec.get("calls").and_then(|v| v.as_i64()).unwrap_or(0);
        slot.has_struct_runtime = true;
    }

    for rec in ivar_runtime {
        let class = rec
            .get("class")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let raw_name = rec.get("name").and_then(|v| v.as_str()).unwrap_or("");
        let field = raw_name
            .trim_start_matches('@')
            .trim_start_matches('@')
            .to_string();
        if class.is_empty() || field.is_empty() {
            continue;
        }
        let key = (class.clone(), field.clone());

        let slot = by_slot.entry(key).or_insert(Slot {
            class,
            field,
            runtime_classes: Vec::new(),
            elem_classes: Vec::new(),
            static_types: Vec::new(),
            declarations: Vec::new(),
            runtime_calls: 0,
            static_count: 0,
            has_unknown_static: false,
            has_struct_runtime: false,
            has_ivar_runtime: false,
        });

        if let Some(arr) = rec.get("classes").and_then(|v| v.as_array()) {
            for c in arr {
                if let Some(c_str) = c.as_str() {
                    if !slot.runtime_classes.contains(&c_str.to_string()) {
                        slot.runtime_classes.push(c_str.to_string());
                    }
                }
            }
        }

        slot.runtime_calls += rec.get("calls").and_then(|v| v.as_i64()).unwrap_or(0);
        slot.has_ivar_runtime = true;
    }

    for rec in static_fields {
        let class = rec
            .get("class")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let field = rec
            .get("field")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        if class.is_empty() || field.is_empty() {
            continue;
        }
        let key = (class.clone(), field.clone());

        let slot = by_slot.entry(key).or_insert(Slot {
            class,
            field,
            runtime_classes: Vec::new(),
            elem_classes: Vec::new(),
            static_types: Vec::new(),
            declarations: Vec::new(),
            runtime_calls: 0,
            static_count: 0,
            has_unknown_static: false,
            has_struct_runtime: false,
            has_ivar_runtime: false,
        });

        let type_str = rec.get("type").and_then(|v| v.as_str()).unwrap_or("");
        if type_str.is_empty() {
            slot.has_unknown_static = true;
        } else {
            if !slot.static_types.contains(&type_str.to_string()) {
                slot.static_types.push(type_str.to_string());
            }
        }
        slot.static_count += 1;
    }

    for rec in type_definitions {
        if rec.get("kind").and_then(|v| v.as_str()) != Some("state_field") {
            continue;
        }
        let class = rec
            .get("owner")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let raw_field = rec
            .get("name")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string();
        let field = raw_field
            .trim_start_matches('@')
            .trim_start_matches('@')
            .to_string();
        if class.is_empty() || field.is_empty() {
            continue;
        }
        let key = (class.clone(), field.clone());
        let slot = by_slot.entry(key).or_insert(Slot {
            class,
            field,
            runtime_classes: Vec::new(),
            elem_classes: Vec::new(),
            static_types: Vec::new(),
            declarations: Vec::new(),
            runtime_calls: 0,
            static_count: 0,
            has_unknown_static: false,
            has_struct_runtime: false,
            has_ivar_runtime: false,
        });
        slot.declarations.push(Declaration {
            path: rec
                .get("path")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            line: rec.get("line").and_then(|v| v.as_i64()).unwrap_or(0),
            raw_field,
            current_type: rec
                .get("declared_type")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
            type_system: rec
                .get("type_system")
                .and_then(|v| v.as_str())
                .unwrap_or("")
                .to_string(),
        });
    }

    let mut slots: Vec<Slot> = by_slot.into_values().collect();
    // Sort by: -runtime_calls, -static_count, class, field
    slots.sort_by(|a, b| {
        b.runtime_calls
            .cmp(&a.runtime_calls)
            .then_with(|| b.static_count.cmp(&a.static_count))
            .then_with(|| a.class.cmp(&b.class))
            .then_with(|| a.field.cmp(&b.field))
    });

    for slot in slots {
        if accessor_contracts.contains(&(slot.class.clone(), slot.field.clone())) {
            continue;
        }
        if slot.has_unknown_static && slot.runtime_calls == 0 {
            continue;
        }

        let type_opt = if slot.runtime_calls > 0 {
            runtime_field_candidate(&slot.runtime_classes, &slot.elem_classes)
        } else {
            static_field_candidate(&slot.static_types)
        };

        let type_str = match type_opt {
            Some(t) => t,
            None => continue,
        };

        if !useful_type(&type_str)
            || weak_type(&type_str)
            || weak_collection_type(&type_str)
            || type_str.contains("T.nilable")
        {
            continue;
        }

        let source_decl = slot.declarations.iter().find(|decl| {
            !decl.path.is_empty()
                && decl.line > 0
                && rewriteable_field_type(&decl.current_type, &type_str)
        });

        if let Some(decl) = source_decl {
            let mut data = std::collections::HashMap::new();
            data.insert(
                "class".to_string(),
                serde_json::Value::String(slot.class.clone()),
            );
            data.insert(
                "field".to_string(),
                serde_json::Value::String(slot.field.clone()),
            );
            data.insert(
                "raw_field".to_string(),
                serde_json::Value::String(decl.raw_field.clone()),
            );
            data.insert(
                "type".to_string(),
                serde_json::Value::String(type_str.clone()),
            );
            data.insert(
                "current_type".to_string(),
                serde_json::Value::String(decl.current_type.clone()),
            );
            data.insert(
                "target".to_string(),
                serde_json::Value::String("source_field".to_string()),
            );
            data.insert(
                "type_system".to_string(),
                serde_json::Value::String(decl.type_system.clone()),
            );
            data.insert(
                "runtime_calls".to_string(),
                serde_json::Value::Number(serde_json::Number::from(slot.runtime_calls)),
            );

            actions.push(Action {
                kind: "add_struct_field_sig".to_string(),
                confidence: "review".to_string(),
                path: decl.path.clone(),
                line: decl.line,
                message: format!(
                    "type {}#{} as {} in source",
                    slot.class, slot.field, type_str
                ),
                data,
            });
        } else if slot.has_struct_runtime {
            let mut data = std::collections::HashMap::new();
            data.insert(
                "class".to_string(),
                serde_json::Value::String(slot.class.clone()),
            );
            data.insert(
                "field".to_string(),
                serde_json::Value::String(slot.field.clone()),
            );
            data.insert(
                "type".to_string(),
                serde_json::Value::String(type_str.clone()),
            );
            data.insert(
                "target".to_string(),
                serde_json::Value::String("rbi".to_string()),
            );
            data.insert(
                "runtime_calls".to_string(),
                serde_json::Value::Number(serde_json::Number::from(slot.runtime_calls)),
            );

            actions.push(Action {
                kind: "add_struct_field_sig".to_string(),
                confidence: "review".to_string(),
                path: "sorbet/rbi/ast-struct-fields.rbi".to_string(),
                line: 1,
                message: format!(
                    "type {}#{} as {} (struct field RBI)",
                    slot.class, slot.field, type_str
                ),
                data,
            });
        }
    }
    actions
}

pub fn build_actions(input: &InputState) -> Vec<Action> {
    let mut actions = Vec::new();
    actions.extend(replace_dead_nil_check(input));
    actions.extend(replace_deterministic_guard(input));
    actions.extend(propose_sig(input));

    for m in &input.methods {
        if m.has_sig {
            if let Some(src) = &m.source {
                report_union_candidates(m, src, &mut actions);
                actions.extend(validate_sig(
                    input,
                    m,
                    src,
                    &input.unused_return_methods_by_location,
                ));
            }
        }
    }

    let existing = actions.clone();
    actions.extend(propose_static_param_backflow_actions(input, &existing));
    actions.extend(propose_false_nilable_return_actions(input));
    actions.extend(propose_forwarded_return_chain_actions(input));
    actions.extend(propose_struct_field_sig_actions(input));
    actions.extend(report_static_nil_pressure(input));
    actions.extend(report_static_primitive_domains(input));

    actions
}

/// Reports closed-looking primitive state domains from FactMine's normalized
/// hidden-enum observations. Parameters are deliberately excluded: without a
/// proven caller contract they are open-world inputs rather than candidates.
fn report_static_primitive_domains(input: &InputState) -> Vec<Action> {
    #[derive(Default)]
    struct Domain {
        values: BTreeSet<String>,
        sites: BTreeSet<String>,
        path: String,
        line: i64,
        slot: String,
    }

    let mut domains = BTreeMap::<String, Domain>::new();
    for observation in fact_objects(input, "hidden_enum_observations") {
        if fact_string(observation, "event") != Some("decision")
            || fact_string(observation, "kind") != Some("state")
        {
            continue;
        }
        let Some(key) = fact_string(observation, "key") else { continue; };
        let domain = domains.entry(key.to_string()).or_default();
        domain.path = fact_string(observation, "path").unwrap_or("").to_string();
        domain.line = fact_i64(observation, "line").unwrap_or(0);
        domain.slot = fact_string(observation, "slot").unwrap_or("").to_string();
        if let Some(site) = observation.get("site").and_then(serde_json::Value::as_object) {
            let line = fact_i64(site, "line").unwrap_or(0);
            domain.sites.insert(format!("{}:{line}", fact_string(site, "path").unwrap_or("")));
        }
        for value in observation.get("values").and_then(serde_json::Value::as_array).into_iter().flatten() {
            if value.get("kind").and_then(serde_json::Value::as_str) == Some("String") {
                if let Some(value) = value.get("value").and_then(serde_json::Value::as_str) {
                    domain.values.insert(value.to_string());
                }
            }
        }
    }
    domains
        .into_values()
        .filter(|domain| (2..=10).contains(&domain.values.len()) && domain.sites.len() >= 2)
        .map(|domain| Action {
            kind: "report_static_primitive_domain".to_string(),
            confidence: "review".to_string(),
            path: domain.path,
            line: domain.line,
            message: format!(
                "state {} has a closed-looking string domain across {} decision sites",
                domain.slot,
                domain.sites.len()
            ),
            data: HashMap::from([
                ("slot".to_string(), serde_json::Value::String(domain.slot)),
                ("values".to_string(), json_strings(domain.values)),
                ("decision_sites".to_string(), json_strings(domain.sites)),
            ]),
        })
        .collect()
}

/// Produces a review-only causal report from FactMine's public nullable
/// facts. NilKill deliberately receives no source text, normalized AST, or
/// CFG here: it groups only the already-proven origins and obligations.
fn report_static_nil_pressure(input: &InputState) -> Vec<Action> {
    let mut roots = nullable_roots(&fact_objects(input, "nullable_states"));
    attach_guard_obligations(&mut roots, &fact_objects(input, "nullable_refinements"));
    attach_return_obligations(&mut roots, &fact_objects(input, "nullable_summaries"));
    attach_operation_obligations(&mut roots, &fact_objects(input, "nullable_operations"));
    pressure_actions(roots)
}

fn nullable_roots(
    states: &[&serde_json::Map<String, serde_json::Value>],
) -> BTreeMap<String, PressureEvidence> {
    let mut roots = BTreeMap::<String, PressureEvidence>::new();
    for state in states {
        if !is_pressure_nullable_state(fact_string(state, "state")) || !fact_bool(state, "complete") {
            continue;
        }
        let Some(place_id) = fact_string(state, "place_id") else {
            continue;
        };
        for root in fact_strings(state, "source_definition_ids") {
            let evidence = roots.entry(root.to_string()).or_default();
            evidence.places.insert(place_id.to_string());
        }
    }
    roots
}

fn attach_guard_obligations(
    roots: &mut BTreeMap<String, PressureEvidence>,
    refinements: &[&serde_json::Map<String, serde_json::Value>],
) {
    for (_, evidence) in roots {
        for refinement in refinements {
            let Some(place_id) = fact_string(refinement, "place_id") else {
                continue;
            };
            if !evidence.places.contains(place_id) {
                continue;
            }
            let condition = fact_string(refinement, "condition_node_id").unwrap_or("");
            evidence.guards.insert(format!("{place_id}:{condition}"));
        }
    }
}

fn attach_return_obligations(
    roots: &mut BTreeMap<String, PressureEvidence>,
    summaries: &[&serde_json::Map<String, serde_json::Value>],
) {
    for (root, evidence) in roots {
        for summary in summaries {
            if is_pressure_nullable_state(fact_string(summary, "return_state"))
                && fact_bool(summary, "complete")
                && fact_strings(summary, "source_definition_ids").contains(&root.as_str())
            {
                let owner = fact_string(summary, "owner").unwrap_or("");
                let function = fact_string(summary, "function").unwrap_or("");
                evidence.returns.insert(format!("{owner}#{function}"));
            }
        }
    }
}

fn is_pressure_nullable_state(state: Option<&str>) -> bool {
    matches!(state, Some("definitely_null" | "maybe_null"))
}

fn attach_operation_obligations(
    roots: &mut BTreeMap<String, PressureEvidence>,
    operations: &[&serde_json::Map<String, serde_json::Value>],
) {
    for evidence in roots.values_mut() {
        for operation in operations {
            let Some(place_id) = fact_string(operation, "place_id") else {
                continue;
            };
            let behavior = fact_string(operation, "nil_behavior").unwrap_or("unknown");
            if evidence.places.contains(place_id)
                && behavior != "safe"
                && behavior != "unknown"
                && fact_bool(operation, "complete")
            {
                let node = fact_string(operation, "node_id").unwrap_or("");
                let kind = fact_string(operation, "operation_kind").unwrap_or("");
                evidence.operations.insert(
                    format!("{kind}:{node}"),
                    OperationLocation {
                        path: fact_string(operation, "path").unwrap_or("").to_string(),
                        line: fact_span_line(operation),
                    },
                );
            }
        }
    }
}

fn pressure_actions(roots: BTreeMap<String, PressureEvidence>) -> Vec<Action> {
    roots
        .into_iter()
        .filter_map(|(root, evidence)| {
            let pressure = evidence.guards.len() + evidence.returns.len() + evidence.operations.len();
            (pressure > 0).then(|| {
                let location = evidence
                    .operations
                    .values()
                    .find(|location| !location.path.is_empty())
                    .cloned()
                    .unwrap_or_default();
                let mut data = HashMap::new();
                data.insert("root_definition_id".to_string(), serde_json::Value::String(root.clone()));
                data.insert(
                    "pressure".to_string(),
                    serde_json::Value::Number(serde_json::Number::from(pressure)),
                );
                data.insert("guard_clusters".to_string(), json_strings(evidence.guards));
                data.insert("nullable_returns".to_string(), json_strings(evidence.returns));
                data.insert(
                    "unsafe_operations".to_string(),
                    json_strings(evidence.operations.into_keys().collect()),
                );
                Action {
                    kind: "report_static_nil_pressure".to_string(),
                    confidence: "review".to_string(),
                    path: location.path,
                    line: location.line,
                    message: format!(
                        "nullable root {root} creates {pressure} independently necessary obligations"
                    ),
                    data,
                }
            })
        })
        .collect()
}

#[derive(Default)]
struct PressureEvidence {
    places: BTreeSet<String>,
    guards: BTreeSet<String>,
    returns: BTreeSet<String>,
    operations: BTreeMap<String, OperationLocation>,
}

#[derive(Clone, Default)]
struct OperationLocation {
    path: String,
    line: i64,
}

fn fact_objects<'a>(input: &'a InputState, key: &str) -> Vec<&'a serde_json::Map<String, serde_json::Value>> {
    input
        .facts
        .get(key)
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_object)
        .collect()
}

fn fact_string<'a>(fact: &'a serde_json::Map<String, serde_json::Value>, key: &str) -> Option<&'a str> {
    fact.get(key).and_then(serde_json::Value::as_str)
}

fn fact_i64(fact: &serde_json::Map<String, serde_json::Value>, key: &str) -> Option<i64> {
    fact.get(key).and_then(serde_json::Value::as_i64)
}

fn fact_strings<'a>(fact: &'a serde_json::Map<String, serde_json::Value>, key: &str) -> Vec<&'a str> {
    fact.get(key)
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .collect()
}

fn fact_bool(fact: &serde_json::Map<String, serde_json::Value>, key: &str) -> bool {
    fact.get(key).and_then(serde_json::Value::as_bool).unwrap_or(false)
}

fn fact_span_line(fact: &serde_json::Map<String, serde_json::Value>) -> i64 {
    fact.get("span")
        .and_then(serde_json::Value::as_array)
        .and_then(|span| span.first())
        .and_then(serde_json::Value::as_u64)
        .and_then(|line| i64::try_from(line).ok())
        .unwrap_or(0)
}

fn json_strings(values: BTreeSet<String>) -> serde_json::Value {
    serde_json::Value::Array(values.into_iter().map(serde_json::Value::String).collect())
}

fn simple_high_confidence_collection_candidate(candidate: &str) -> bool {
    let raw = strip_nilable_type(candidate);
    let scalar_pattern = |s: &str| -> bool {
        s == "String" || s == "Symbol" || s == "Integer" || s == "Float" || s == "T::Boolean"
    };

    if let Some(inner) = raw
        .strip_prefix("T::Array[")
        .and_then(|s| s.strip_suffix("]"))
    {
        return scalar_pattern(inner);
    }
    if let Some(inner) = raw
        .strip_prefix("T::Set[")
        .and_then(|s| s.strip_suffix("]"))
    {
        return scalar_pattern(inner);
    }
    if let Some(inner) = raw
        .strip_prefix("T::Hash[")
        .and_then(|s| s.strip_suffix("]"))
    {
        if let Some((k, v)) = inner.split_once(", ") {
            if (k == "String" || k == "Symbol" || k == "Integer") && scalar_pattern(v) {
                return true;
            }
        }
    }
    false
}

fn collection_narrowing_confidence(calls: i64, candidate: &str) -> &'static str {
    if !simple_high_confidence_collection_candidate(candidate) {
        return "review";
    }
    if calls >= 20 {
        "high"
    } else {
        "review"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    fn input_from_json(value: serde_json::Value) -> crate::schemas::InputState {
        serde_json::from_value(value).unwrap()
    }

    #[test]
    fn reports_closed_string_domains_for_state_observations_only() {
        let input = input_from_json(serde_json::json!({
            "methods": [],
            "facts": {
                "hidden_enum_observations": [
                    {
                        "event": "decision", "kind": "state", "key": "state:status",
                        "path": "post.rb", "line": 2, "slot": "@status",
                        "site": {"path": "post.rb", "line": 4},
                        "values": [{"kind": "String", "value": "\"draft\""}]
                    },
                    {
                        "event": "decision", "kind": "state", "key": "state:status",
                        "path": "post.rb", "line": 2, "slot": "@status",
                        "site": {"path": "post.rb", "line": 8},
                        "values": [{"kind": "String", "value": "\"published\""}]
                    },
                    {
                        "event": "decision", "kind": "param", "key": "param:status",
                        "path": "post.rb", "line": 12, "slot": "status",
                        "site": {"path": "post.rb", "line": 13},
                        "values": [{"kind": "String", "value": "\"draft\""}]
                    },
                    {
                        "event": "decision", "kind": "state", "key": "state:ignored",
                        "path": "post.rb", "line": 16, "slot": "@ignored",
                        "values": [{"kind": "Integer", "value": "1"}, {"kind": "String"}]
                    }
                ]
            }
        }));
        let actions = report_static_primitive_domains(&input);
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0].kind, "report_static_primitive_domain");
        assert_eq!(actions[0].data["values"], serde_json::json!(["\"draft\"", "\"published\""]));
        assert_eq!(actions[0].data["decision_sites"], serde_json::json!(["post.rb:4", "post.rb:8"]));
    }

    #[test]
    fn static_nil_pressure_uses_nullable_public_facts_not_hazard_sites() {
        let input = input_from_json(serde_json::json!({
            "methods": [],
            "facts": {
                "hazard_sites": [{
                    "hazard_type": "c_null_pointer_dereference",
                    "path": "cache.c",
                    "line": 12,
                    "evidence": "nil-kill"
                }]
            }
        }));

        assert!(report_static_nil_pressure(&input).is_empty());
    }

    #[test]
    fn static_nil_pressure_has_no_source_analysis_dependency() {
        let manifest = include_str!("../Cargo.toml");

        assert!(!manifest.contains("tree-sitter"));
        assert!(!manifest.contains("fact-mine"));
    }

    #[test]
    fn strong_static_return_can_remove_false_nilability() {
        let input = input_from_json(serde_json::json!({
            "methods": [],
            "facts": {
                "existing_sigs": [{
                    "path": "parser.rb",
                    "line": 10,
                    "class": "Parser",
                    "method": "required_token",
                    "kind": "instance",
                    "sig": "sig { returns(T.nilable(Token)) }",
                    "return_type": {
                        "kind": "Nilable",
                        "data": { "kind": "Primitive", "data": "Token" }
                    },
                    "return_type_text": "T.nilable(Token)",
                    "non_nil_return_type": { "kind": "Primitive", "data": "Token" },
                    "non_nil_return_type_text": "Token"
                }],
                "return_origins": [{
                    "path": "parser.rb",
                    "line": 10,
                    "class": "Parser",
                    "method": "required_token",
                    "kind": "instance",
                    "candidate_type": { "kind": "Primitive", "data": "Token" },
                    "confidence": "strong",
                    "sources": [{ "kind": "static", "type": "Token", "code": "Token.new(:ID)" }],
                    "blockers": []
                }]
            }
        }));

        let actions = build_actions(&input);
        assert!(actions.iter().any(|action| {
            action.kind == "fix_sig_return"
                && action.path == "parser.rb"
                && action.line == 10
                && action.confidence == "high"
                && action.data.get("type").and_then(|value| value.as_str()) == Some("Token")
                && action.data.get("from").and_then(|value| value.as_str())
                    == Some("T.nilable(Token)")
        }));
    }

    #[test]
    fn static_nil_pressure_groups_only_proven_obligations_by_root() {
        let input = input_from_json(serde_json::json!({
            "facts": {
                "nullable_states": [
                    {
                        "state": "definitely_null",
                        "complete": true,
                        "place_id": "place:cache:value",
                        "source_definition_ids": ["definition:cache_lookup"]
                    },
                    {
                        "state": "unknown",
                        "complete": false,
                        "place_id": "place:cache:unknown",
                        "source_definition_ids": ["definition:unknown"]
                    },
                    {
                        "state": "definitely_null",
                        "complete": true,
                        "source_definition_ids": ["definition:missing_place"]
                    }
                ],
                "nullable_refinements": [
                    {
                        "place_id": "place:cache:value",
                        "condition_node_id": "guard:1"
                    },
                    {
                        "condition_node_id": "missing-place"
                    },
                    {
                        "place_id": "place:other:value",
                        "condition_node_id": "other-place"
                    },
                    {
                        "place_id": "place:cache:value",
                        "condition_node_id": "guard:1"
                    }
                ],
                "nullable_summaries": [
                    {
                        "owner": "Cache",
                        "function": "lookup",
                        "return_state": "definitely_null",
                        "complete": true,
                        "source_definition_ids": ["definition:cache_lookup"]
                    },
                    {
                        "owner": "Cache",
                        "function": "unknown_lookup",
                        "return_state": "unknown",
                        "complete": false,
                        "source_definition_ids": ["definition:unknown"]
                    }
                ],
                "nullable_operations": [
                    {
                        "place_id": "place:cache:value",
                        "node_id": "deref:1",
                        "path": "cache.c",
                        "span": [14, 2, 14, 8],
                        "operation_kind": "pointer_dereference",
                        "nil_behavior": "undefined_behavior",
                        "complete": true
                    },
                    {
                        "node_id": "missing-place",
                        "operation_kind": "pointer_dereference",
                        "nil_behavior": "undefined_behavior",
                        "complete": true
                    },
                    {
                        "place_id": "place:cache:value",
                        "node_id": "safe:1",
                        "operation_kind": "map_read",
                        "nil_behavior": "safe",
                        "complete": true
                    }
                ]
            }
        }));

        let actions = super::report_static_nil_pressure(&input);

        assert_eq!(actions.len(), 1);
        let action = &actions[0];
        assert_eq!(action.kind, "report_static_nil_pressure");
        assert_eq!(action.path, "cache.c");
        assert_eq!(action.line, 14);
        assert_eq!(action.data["pressure"], 3);
        assert_eq!(action.data["guard_clusters"], serde_json::json!(["place:cache:value:guard:1"]));
        assert_eq!(action.data["nullable_returns"], serde_json::json!(["Cache#lookup"]));
        assert_eq!(
            action.data["unsafe_operations"],
            serde_json::json!(["pointer_dereference:deref:1"])
        );
    }

    #[test]
    fn test_actions_oracle_fixtures() {
        let mut d = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
        d.push("spec/fixtures/oracle");

        let mut tested = 0;
        for entry in fs::read_dir(d).unwrap() {
            let entry = entry.unwrap();
            let path = entry.path();
            if path.is_dir() {
                let input_path = path.join("input.json");
                let output_path = path.join("output.json");

                if input_path.exists() && output_path.exists() {
                    let input_data = fs::read_to_string(&input_path).unwrap();
                    let expected_data = fs::read_to_string(&output_path).unwrap();
                    eprintln!("Testing {:?}", path);

                    let input_state: crate::schemas::InputState = serde_json::from_str(&input_data)
                        .unwrap_or_else(|e| {
                            panic!("Failed to parse input JSON for {:?}: {}", path, e)
                        });
                    let expected_actions: crate::schemas::OutputState =
                        serde_json::from_str(&expected_data).unwrap_or_else(|e| {
                            panic!("Failed to parse expected JSON for {:?}: {}", path, e)
                        });

                    let actual_actions = crate::schemas::OutputState {
                        actions: build_actions(&input_state),
                        diagnostics: std::collections::HashMap::new(),
                    };

                    let mut actual_val = serde_json::to_value(&actual_actions.actions).unwrap();
                    let mut expected_val = serde_json::to_value(&expected_actions.actions).unwrap();

                    if let (Some(actual_arr), Some(expected_arr)) =
                        (actual_val.as_array_mut(), expected_val.as_array_mut())
                    {
                        actual_arr.sort_by_key(|v| serde_json::to_string(v).unwrap());
                        expected_arr.sort_by_key(|v| serde_json::to_string(v).unwrap());
                    }

                    assert_eq!(
                        actual_val,
                        expected_val,
                        "Failed oracle test for fixture {:?}",
                        path.file_name().unwrap()
                    );
                    tested += 1;
                }
            }
        }
        assert!(tested > 0, "No oracle fixtures found!");
    }

    #[test]
    fn test_generic_candidate_type() {
        use serde_json::json;
        // Test Set
        let set_class = json!(["Integer"]);
        let res = super::generic_candidate_type("Set", Some(&set_class), None, None, None);
        assert_eq!(res, Some("T::Set[Integer]".to_string()));

        let set_class2 = json!(["String"]);
        let res2 =
            super::generic_candidate_type("T::Set[T.untyped]", Some(&set_class2), None, None, None);
        assert_eq!(res2, Some("T::Set[String]".to_string()));

        // Test Hash
        let hash_class = json!([["String"], ["Integer"]]);
        let res3 = super::generic_candidate_type("Hash", None, Some(&hash_class), None, None);
        assert_eq!(res3, Some("T::Hash[String, Integer]".to_string()));

        let hash_class2 = json!([["Symbol"], ["Float"]]);
        let res4 = super::generic_candidate_type(
            "T::Hash[T.untyped, T.untyped]",
            None,
            Some(&hash_class2),
            None,
            None,
        );
        assert_eq!(res4, Some("T::Hash[Symbol, Float]".to_string()));

        let broad_classes = json!([
            {"kind": "class", "name": "Float"},
            {"kind": "class", "name": "Hash"},
            {"kind": "class", "name": "Integer"},
            {"kind": "class", "name": "String"}
        ]);
        let nested_array = json!([{"kind": "array", "elements": broad_classes}]);
        assert_eq!(
            super::generic_candidate_type(
                "T::Array[T.untyped]",
                None,
                None,
                Some(&nested_array),
                None,
            ),
            Some("T::Array[T::Array[T.untyped]]".to_string()),
        );

        let hash_shapes = json!([
            {
                "kind": "hash",
                "keys": [{"kind": "class", "name": "Symbol"}],
                "values": [
                    {"kind": "class", "name": "String"},
                    {"kind": "class", "name": "Symbol"}
                ]
            },
            {
                "kind": "hash",
                "keys": [{"kind": "class", "name": "Symbol"}],
                "values": [{"kind": "class", "name": "Integer"}]
            }
        ]);
        assert_eq!(
            super::generic_candidate_type(
                "T::Array[T.untyped]",
                None,
                None,
                Some(&hash_shapes),
                None,
            ),
            Some("T::Array[T::Hash[Symbol, T.untyped]]".to_string()),
        );
    }

    #[test]
    fn generic_candidate_refuses_bare_nested_collection_classes() {
        use serde_json::json;

        let array_classes = json!(["Hash"]);
        assert_eq!(
            super::generic_candidate_type(
                "T::Array[T::Hash[Symbol, T.untyped]]",
                Some(&array_classes),
                None,
                None,
                None,
            ),
            None,
        );

        let hash_classes = json!([["String"], ["Hash"]]);
        assert_eq!(
            super::generic_candidate_type(
                "T::Hash[String, T::Hash[Symbol, T.untyped]]",
                None,
                Some(&hash_classes),
                None,
                None,
            ),
            None,
        );
    }

    #[test]
    fn test_runtime_field_candidate_ignores_static_untyped_and_normalizes_boolean() {
        assert_eq!(
            super::runtime_field_candidate(&vec!["String".to_string()], &[]),
            Some("String".to_string())
        );
        assert_eq!(
            super::runtime_field_candidate(&vec!["FalseClass".to_string()], &[]),
            Some("T::Boolean".to_string())
        );
        assert_eq!(
            super::runtime_field_candidate(
                &vec!["AST::Identifier".to_string(), "AST::Literal".to_string()],
                &[]
            ),
            Some("T.any(AST::Identifier, AST::Literal)".to_string())
        );
    }

    #[test]
    fn test_field_candidate_helper_edges() {
        assert_eq!(super::runtime_field_candidate(&[], &[]), None);
        assert_eq!(
            super::runtime_field_candidate(&vec!["Array".to_string()], &vec!["String".to_string()]),
            Some("T::Array[String]".to_string())
        );
        assert_eq!(
            super::runtime_field_candidate(
                &vec![
                    "String".to_string(),
                    "Integer".to_string(),
                    "Symbol".to_string(),
                    "Float".to_string(),
                ],
                &[]
            ),
            None
        );
        assert_eq!(
            super::runtime_field_candidate(&vec!["MIR::CallableContract".to_string()], &[]),
            Some("MIR::CallableContract".to_string())
        );
        assert_eq!(
            super::runtime_field_candidate(
                &vec!["AST::Identifier".to_string(), "AST::Literal".to_string()],
                &[]
            ),
            Some("T.any(AST::Identifier, AST::Literal)".to_string())
        );
        assert_eq!(
            super::runtime_field_candidate(
                &vec![
                    "AST::Identifier".to_string(),
                    "AST::Literal".to_string(),
                    "AST::FuncCall".to_string(),
                    "AST::MethodCall".to_string(),
                ],
                &[]
            ),
            None
        );
        assert_eq!(
            super::runtime_field_candidate(
                &vec!["MIR::Ident".to_string(), "NilClass".to_string()],
                &[]
            ),
            None
        );

        assert_eq!(super::static_field_candidate(&[]), None);
        assert_eq!(
            super::static_field_candidate(&vec!["FalseClass".to_string(), "TrueClass".to_string()]),
            Some("T::Boolean".to_string())
        );
        assert_eq!(
            super::static_field_candidate(&vec!["String".to_string()]),
            Some("String".to_string())
        );
        assert_eq!(
            super::static_field_candidate(&vec!["T.untyped".to_string()]),
            None
        );

        assert!(!super::collapsible_node_union("String", "AST::Node"));
        assert!(super::collapsible_node_union(
            "T.any(AST::FuncCall, AST::MethodCall)",
            "AST::Node"
        ));
        assert!(super::collapsible_node_union(
            "T.any(MIR::Literal, MIR::FuncCall)",
            "MIR::Node"
        ));
        assert!(!super::collapsible_node_union(
            "T.any(String, Symbol)",
            "TypeShape"
        ));
        assert!(super::collapsible_boolean_union(
            "T.any(FalseClass, TrueClass)",
            "T::Boolean"
        ));

        assert!(!super::rewriteable_field_type("", "String"));
        assert!(!super::rewriteable_field_type("String", "String"));
        assert!(super::rewriteable_field_type(
            "T::Array[T.untyped]",
            "T::Array[String]"
        ));
        assert!(super::rewriteable_field_type(
            "T.any(AST::FuncCall, AST::MethodCall)",
            "AST::Node"
        ));
    }

    #[test]
    fn test_build_actions_emits_source_field_action_for_weak_declaration() {
        use serde_json::json;

        let input: crate::schemas::InputState = serde_json::from_value(json!({
            "methods": [],
            "tlets": [],
            "unused_return_methods_by_location": {},
            "facts": {
                "struct_field_runtime": [
                    {
                        "class": "Example",
                        "field": "name",
                        "classes": ["String"],
                        "elem_classes": [],
                        "calls": 25
                    }
                ],
                "ivar_runtime": [
                    {
                        "class": "Example",
                        "name": "@shape",
                        "classes": ["TypeShape"],
                        "calls": 10
                    }
                ],
                "struct_field_static": [
                    {
                        "class": "Example",
                        "field": "name",
                        "type": "T.untyped",
                        "path": "src/example.rb",
                        "line": 3
                    }
                ],
                "type_definitions": [
                    {
                        "kind": "state_field",
                        "owner": "Example",
                        "name": "name",
                        "declared_type": "T.untyped",
                        "path": "src/example.rb",
                        "line": 3,
                        "type_system": "sorbet"
                    },
                    {
                        "kind": "state_field",
                        "owner": "Example",
                        "name": "@shape",
                        "declared_type": "T.untyped",
                        "path": "src/example.rb",
                        "line": 8,
                        "type_system": "sorbet"
                    }
                ]
            }
        }))
        .unwrap();

        let actions = super::build_actions(&input);
        assert!(actions.iter().any(|action| {
            action.kind == "add_struct_field_sig"
                && action.path == "src/example.rb"
                && action.line == 3
                && action.data.get("target").and_then(|v| v.as_str()) == Some("source_field")
                && action.data.get("field").and_then(|v| v.as_str()) == Some("name")
                && action.data.get("type").and_then(|v| v.as_str()) == Some("String")
        }));
        assert!(actions.iter().any(|action| {
            action.kind == "add_struct_field_sig"
                && action.path == "src/example.rb"
                && action.line == 8
                && action.data.get("target").and_then(|v| v.as_str()) == Some("source_field")
                && action.data.get("raw_field").and_then(|v| v.as_str()) == Some("@shape")
                && action.data.get("type").and_then(|v| v.as_str()) == Some("TypeShape")
        }));
    }

    #[test]
    fn test_struct_field_actions_respect_direct_and_inherited_accessor_contracts() {
        use serde_json::json;

        let input: crate::schemas::InputState = serde_json::from_value(json!({
            "methods": [],
            "tlets": [],
            "unused_return_methods_by_location": {},
            "facts": {
                "struct_field_runtime": [
                    { "class": "Direct", "field": "value", "classes": ["String"], "calls": 10 },
                    { "class": "Inherited", "field": "value", "classes": ["String"], "calls": 10 },
                    { "class": "NeedsType", "field": "value", "classes": ["String"], "calls": 10 }
                ],
                "type_definitions": [
                    {
                        "kind": "method_signature", "owner": "Direct", "name": "value",
                        "signature": "sig { returns(ValueProtocol) }"
                    },
                    {
                        "kind": "method_signature", "owner": "AccessorModule", "name": "value",
                        "signature": "sig { returns(T.nilable(ValueProtocol)) }"
                    },
                    { "kind": "included_module", "owner": "Intermediate", "name": "AccessorModule" },
                    { "kind": "included_module", "owner": "Inherited", "name": "Intermediate" }
                ]
            }
        }))
        .unwrap();

        let actions = super::build_actions(&input);
        let fields: Vec<&str> = actions
            .iter()
            .filter(|action| action.kind == "add_struct_field_sig")
            .filter_map(|action| action.data.get("class").and_then(|v| v.as_str()))
            .collect();

        assert_eq!(fields, vec!["NeedsType"]);
    }

    #[test]
    fn test_struct_field_actions_respect_effective_rbi_contracts() {
        use serde_json::json;

        let input: crate::schemas::InputState = serde_json::from_value(json!({
            "methods": [],
            "tlets": [],
            "unused_return_methods_by_location": {},
            "facts": {
                "struct_field_runtime": [
                    { "class": "AlreadyTyped", "field": "value", "classes": ["String"], "calls": 10 },
                    { "class": "NeedsType", "field": "value", "classes": ["String"], "calls": 10 }
                ],
                "effective_struct_field_types": [
                    { "owner": "AlreadyTyped", "field": "value", "type": "String" },
                    { "owner": "NeedsType", "field": "value", "type": "T.untyped" }
                ]
            }
        }))
        .unwrap();

        let actions = super::build_actions(&input);
        let fields: Vec<&str> = actions
            .iter()
            .filter(|action| action.kind == "add_struct_field_sig")
            .filter_map(|action| action.data.get("class").and_then(|v| v.as_str()))
            .collect();

        assert_eq!(fields, vec!["NeedsType"]);
    }

    #[test]
    fn test_struct_field_actions_skip_malformed_or_static_only_rows() {
        use serde_json::json;

        let input: crate::schemas::InputState = serde_json::from_value(json!({
            "methods": [],
            "tlets": [],
            "unused_return_methods_by_location": {},
            "facts": {
                "struct_field_runtime": [
                    { "class": "", "field": "name", "classes": ["String"], "calls": 1 }
                ],
                "ivar_runtime": [
                    { "class": "Example", "name": "", "classes": ["String"], "calls": 1 }
                ],
                "struct_field_static": [
                    { "class": "Example", "field": "", "type": "String" },
                    { "class": "Example", "field": "static_only", "type": "String" }
                ],
                "type_definitions": [
                    { "kind": "method_signature", "owner": "Example", "name": "call" },
                    { "kind": "state_field", "owner": "Example", "name": "", "declared_type": "T.untyped" }
                ]
            }
        }))
        .unwrap();

        let actions = super::build_actions(&input);
        assert!(actions
            .iter()
            .all(|action| action.kind != "add_struct_field_sig"));
    }

    #[test]
    fn test_build_actions_missing_sig() {
        let input_json = r#"{
            "methods": [
                {
                    "has_sig": false,
                    "key": [],
                    "calls": 1,
                    "ok_calls": 1,
                    "raised_calls": 0,
                    "params_by_name": {
                        "x": ["Integer"]
                    },
                    "params_ok": {},
                    "params_raised": {},
                    "param_elem": {},
                    "param_kv": {},
                    "param_elem_shapes": {},
                    "param_kv_shapes": {},
                    "param_sites": {},
                    "param_sites_ok": {},
                    "param_sites_raised": {},
                    "param_traces": {},
                    "param_traces_ok": {},
                    "param_traces_raised": {},
                    "returns": ["String"],
                    "return_elem": [],
                    "return_elem_shapes": [],
                    "return_kv": [],
                    "return_kv_shapes": [],
                    "raised": [],
                    "source": {
                        "path": "/foo.rb",
                        "line": 1,
                        "end_line": null,
                        "class": "SomeClass",
                        "method": "foo",
                        "kind": "def",
                        "language": "ruby",
                        "has_sig": false,
                        "sig": "",
                        "params": [
                            { "name": "x", "nil_default": false, "type": null }
                        ],
                        "scope": [],
                        "non_nil_params": [],
                        "uses_yield": false,
                        "untraceable_params": [],
                        "protocols": {},
                        "noreturn_candidate": false
                    }
                }
            ],
            "tlets": [],
            "facts": {},
            "unused_return_methods_by_location": {}
        }"#;
        let input: crate::schemas::InputState = serde_json::from_str(input_json).unwrap();
        let actions = super::build_actions(&input);
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0].kind, "add_sig");
        assert_eq!(
            actions[0].data["sig"],
            "sig { params(x: Integer).returns(String) }"
        );
    }

    #[test]
    fn test_inferred_return_type_hash_and_set() {
        use serde_json::json;
        // Test Hash
        let json_hash = json!({
            "returns": ["Hash"],
            "return_elem": [],
            "return_elem_shapes": [],
            "return_kv": [["String"], ["Integer"]],
            "return_kv_shapes": [
                [ { "kind": "class", "name": "String" } ],
                [ { "kind": "class", "name": "Integer" } ]
            ],
            "key": ["x"],
            "calls": 1,
            "ok_calls": 1,
            "raised_calls": 0,
            "params_by_name": {},
            "params_ok": {},
            "params_raised": {},
            "param_elem": {},
            "param_kv": {},
            "param_elem_shapes": {},
            "param_kv_shapes": {},
            "param_sites": {},
            "param_sites_ok": {},
            "param_sites_raised": {},
            "param_traces": {},
            "param_traces_ok": {},
            "param_traces_raised": {},
            "raised": [],
            "source": null,
            "has_sig": false
        });
        let mut m: crate::schemas::MethodRecord = serde_json::from_value(json_hash).unwrap();
        assert_eq!(
            super::runtime_return_type_candidate(&m),
            "T::Hash[String, Integer]"
        );

        // Test Set
        m.returns = vec!["Set".to_string()];
        m.return_elem_shapes = vec![json!({ "kind": "class", "name": "Float" })];
        assert_eq!(super::runtime_return_type_candidate(&m), "T::Set[Float]");
    }

    #[test]
    fn test_simple_high_confidence_collection_candidate() {
        assert!(super::simple_high_confidence_collection_candidate(
            "T::Set[Integer]"
        ));
        assert!(!super::simple_high_confidence_collection_candidate(
            "T::Set[Object]"
        ));
        assert!(super::simple_high_confidence_collection_candidate(
            "T::Hash[String, Float]"
        ));
        assert!(!super::simple_high_confidence_collection_candidate(
            "T::Hash[Object, Float]"
        ));
    }
    #[test]
    fn test_narrow_generic_return() {
        use crate::schemas::*;
        let input_json = r#"{
            "methods": [{
                "key": [],
                "calls": 2,
                "ok_calls": 2,
                "raised_calls": 0,
                "params_by_name": {},
                "params_ok": {},
                "params_raised": {},
                "param_elem": {},
                "param_kv": {},
                "param_elem_shapes": {},
                "param_kv_shapes": {},
                "param_sites": {},
                "param_sites_ok": {},
                "param_sites_raised": {},
                "param_traces": {},
                "param_traces_ok": {},
                "param_traces_raised": {},
                "returns": [],
                "return_elem": ["Integer"],
                "return_kv": [],
                "return_elem_shapes": [],
                "return_kv_shapes": [],
                "raised": [],
                "source": {
                    "path": "test.rb",
                    "line": 1,
                    "end_line": null,
                    "class": "Test",
                    "method": "test",
                    "kind": "def",
                    "language": "ruby",
                    "has_sig": true,
                    "sig": "sig { returns(T::Array[T.untyped]) }",
                    "params": [],
                    "scope": [],
                    "non_nil_params": [],
                    "uses_yield": false,
                    "untraceable_params": [],
                    "protocols": {},
                    "noreturn_candidate": false,
                    "static_return_types": ["T::Array[T.untyped]"]
                },
                "has_sig": true
            }],
            "tlets": [],
            "facts": {},
            "unused_return_methods_by_location": {}
        }"#;
        let input: InputState = serde_json::from_str(input_json).unwrap();
        let actions = super::build_actions(&input);
        assert!(actions
            .iter()
            .any(|a| a.kind == "narrow_generic_return" && a.data["type"] == "T::Array[Integer]"));
    }
    #[test]
    fn test_shape_union_type_hash() {
        use serde_json::json;
        // Test shape_union_type with hash
        let hash_shapes = json!([
            {
                "kind": "hash",
                "keys": [
                    { "kind": "class", "name": "String" }
                ],
                "values": [
                    { "kind": "class", "name": "Integer" }
                ]
            }
        ]);
        let shapes = hash_shapes.as_array().unwrap();
        let res = super::shape_union_type(&shapes);
        assert_eq!(res, Some("T::Hash[String, Integer]".to_string()));

        let kv_shapes = json!([
            [ { "kind": "class", "name": "String" } ],
            [ { "kind": "class", "name": "Integer" } ]
        ]);
        let res2 = super::generic_candidate_type("Hash", None, None, None, Some(&kv_shapes));
        assert_eq!(res2, Some("T::Hash[String, Integer]".to_string()));
    }

    #[test]
    fn test_sorbet_type_ast() {
        let classes = vec![
            "AST::Node".to_string(),
            "AST::SomethingElse".to_string(),
            "MIR::Node".to_string(),
            "String".to_string(),
            "NilClass".to_string(),
        ];
        let res = super::sorbet_type(&classes, true);
        assert_eq!(res, "T.nilable(T.any(AST::Node, MIR::Node, String))");
    }
    #[test]
    fn test_shape_union_type_set_array() {
        use serde_json::json;
        // Test shape_union_type with set and array
        let set_shapes = json!([
            {
                "kind": "set",
                "elements": [
                    { "kind": "class", "name": "Float" }
                ]
            }
        ]);
        let res = super::shape_union_type(&set_shapes.as_array().unwrap());
        assert_eq!(res, Some("T::Set[Float]".to_string()));

        let arr_shapes = json!([
            {
                "kind": "array",
                "elements": [
                    { "kind": "class", "name": "Float" }
                ]
            }
        ]);
        let res2 = super::shape_union_type(&arr_shapes.as_array().unwrap());
        assert_eq!(res2, Some("T::Array[Float]".to_string()));
    }

    #[test]
    fn test_type_helper_conservative_edges() {
        use serde_json::json;

        assert_eq!(
            super::sorbet_type(&["TrueClass".to_string(), "FalseClass".to_string()], true),
            "T::Boolean"
        );
        assert_eq!(
            super::conservative_element_type(&["NilClass".to_string(), "String".to_string()]),
            Some("T.nilable(String)".to_string())
        );
        assert_eq!(
            super::conservative_element_type(&["TrueClass".to_string(), "FalseClass".to_string()]),
            Some("T::Boolean".to_string())
        );
        assert_eq!(
            super::conservative_element_type(&["AST::Send".to_string()]),
            None
        );
        assert_eq!(
            super::conservative_element_type(&["String".to_string(), "Integer".to_string()]),
            None
        );

        let mixed_hash = json!([
            {
                "kind": "hash",
                "keys": [{ "kind": "class", "name": "String" }],
                "values": [
                    { "kind": "class", "name": "String" },
                    { "kind": "class", "name": "Integer" }
                ]
            }
        ]);
        assert_eq!(
            super::shape_union_type(mixed_hash.as_array().unwrap()),
            Some("T::Hash[String, T.untyped]".to_string())
        );
        assert_eq!(
            super::shape_union_type(&[json!({ "kind": "unknown" })]),
            None
        );
        assert_eq!(super::shape_union_type(&[json!({})]), None);

        let array_classes = json!(["Symbol"]);
        assert_eq!(
            super::generic_candidate_type("Array", Some(&array_classes), None, None, None),
            Some("T::Array[Symbol]".to_string())
        );
        let set_classes = json!(["String"]);
        assert_eq!(
            super::generic_candidate_type("Set", Some(&set_classes), None, None, None),
            Some("T::Set[String]".to_string())
        );
        let hash_classes = json!([["Symbol"], ["Float"]]);
        assert_eq!(
            super::generic_candidate_type("Hash", None, Some(&hash_classes), None, None),
            Some("T::Hash[Symbol, Float]".to_string())
        );
        assert_eq!(
            super::preserve_nilable_wrapper("T.nilable(T.untyped)", "String"),
            "T.nilable(String)"
        );
        assert_eq!(
            super::extract_return_type("sig { returns(T.nilable(String)) }"),
            Some("T.nilable(String)".to_string())
        );
        assert_eq!(
            super::collection_narrowing_confidence(1, "T::Array[User]"),
            "review"
        );
    }

    #[test]
    fn test_dead_checks_deterministic_guards_and_missing_sig_confidence() {
        use serde_json::json;

        let input = input_from_json(json!({
            "methods": [
                { "has_sig": false, "source": null },
                {
                    "has_sig": false,
                    "calls": 25,
                    "params_by_name": { "name": ["String"] },
                    "returns": ["Integer"],
                    "source": {
                        "path": "src/signup.rb",
                        "line": 10,
                        "class": "Signup",
                        "method": "create",
                        "kind": "instance",
                        "params": [{ "name": "name", "nil_default": true, "type": null }],
                        "uses_yield": false
                    }
                },
                {
                    "has_sig": false,
                    "calls": 25,
                    "params_by_name": { "block_arg": ["String"] },
                    "returns": ["String"],
                    "source": {
                        "path": "src/signup.rb",
                        "line": 20,
                        "class": "Signup",
                        "method": "around",
                        "kind": "instance",
                        "params": [{ "name": "block_arg", "nil_default": false, "type": null }],
                        "uses_yield": true
                    }
                },
                {
                    "has_sig": true,
                    "source": {
                        "path": "src/signup.rb",
                        "line": 30,
                        "class": "Signup",
                        "method": "already_typed",
                        "kind": "instance",
                        "sig": "sig { void }"
                    }
                }
            ],
            "facts": {
                "dead_nil_checks": [
                    { "kind": "nil_check", "path": "src/signup.rb", "line": 3, "code": "user.nil?", "reason": "user is non-nil" },
                    { "kind": "safe_nav", "path": "src/signup.rb", "line": 4, "code": "user&.name", "reason": "receiver is non-nil" }
                ],
                "deterministic_guards": [
                    { "proof_tier": "runtime_observed", "predicate_kind": "type_check", "path": "src/signup.rb", "line": 5, "code": "name.is_a?(String)", "truth_value": true, "reason": "runtime only" },
                    { "proof_tier": "static_proven", "predicate_kind": "nil_check", "path": "src/signup.rb", "line": 6, "code": "name.nil?", "truth_value": false, "reason": "handled elsewhere" },
                    { "proof_tier": "static_proven", "predicate_kind": "type_check", "path": "src/signup.rb", "line": 7, "code": "name.is_a?(String)", "truth_value": true, "reason": "signature proves String" }
                ]
            }
        }));

        let actions = super::build_actions(&input);
        assert!(actions.iter().any(|a| a.kind == "replace_dead_nil_check"));
        assert!(actions.iter().any(|a| a.kind == "remove_dead_safe_nav"));
        let guard = actions
            .iter()
            .find(|a| a.kind == "replace_deterministic_guard")
            .unwrap();
        assert_eq!(guard.line, 7);
        assert!(guard.message.contains("always true"));

        let create_sig = actions
            .iter()
            .find(|a| a.kind == "add_sig" && a.line == 10)
            .unwrap();
        assert_eq!(create_sig.confidence, "high");
        assert_eq!(
            create_sig.data["sig"],
            "sig { params(name: T.nilable(String)).returns(Integer) }"
        );

        let around_sig = actions
            .iter()
            .find(|a| a.kind == "add_sig" && a.line == 20)
            .unwrap();
        assert_eq!(around_sig.confidence, "review");
        assert!(around_sig.message.contains("block typing needs review"));
    }

    #[test]
    fn test_signature_validation_handles_collections_voids_and_static_return_origins() {
        use serde_json::json;

        let unused_key =
            serde_json::json!(["src/service.rb", 40, "Service", "unused", "instance"]).to_string();
        let contradicted_key = serde_json::json!([
            "src/service.rb",
            50,
            "Service",
            "contradicted_unused",
            "instance"
        ])
        .to_string();

        let input = input_from_json(json!({
            "methods": [
                {
                    "has_sig": true,
                    "calls": 25,
                    "params_ok": { "value": ["String"], "items": ["Array"] },
                    "param_elem": { "items": ["Integer"] },
                    "returns": ["Hash"],
                    "return_kv": [["String"], ["Integer"]],
                    "source": {
                        "path": "src/service.rb",
                        "line": 10,
                        "class": "Service",
                        "method": "process",
                        "kind": "instance",
                        "sig": "sig { params(value:T.untyped, items: T::Array[T.untyped]).returns(T.untyped) }",
                        "params": [
                            { "name": "value", "type": "T.untyped" },
                            { "name": "items", "type": "T::Array[T.untyped]" }
                        ]
                    }
                },
                {
                    "has_sig": true,
                    "calls": 1,
                    "returns": [],
                    "source": {
                        "path": "src/service.rb",
                        "line": 30,
                        "class": "Service",
                        "method": "always_raises",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "params": [],
                        "noreturn_candidate": true
                    }
                },
                {
                    "has_sig": true,
                    "calls": 5,
                    "returns": [],
                    "source": {
                        "path": "src/service.rb",
                        "line": 40,
                        "class": "Service",
                        "method": "unused",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "params": []
                    }
                },
                {
                    "has_sig": true,
                    "calls": 5,
                    "returns": ["String"],
                    "source": {
                        "path": "src/service.rb",
                        "line": 50,
                        "class": "Service",
                        "method": "contradicted_unused",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "params": []
                    }
                },
                {
                    "has_sig": true,
                    "calls": 5,
                    "returns": [],
                    "source": {
                        "path": "src/service.rb",
                        "line": 60,
                        "class": "Service",
                        "method": "literal_return",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "params": []
                    }
                },
                {
                    "has_sig": true,
                    "calls": 5,
                    "returns": [],
                    "source": {
                        "path": "src/service.rb",
                        "line": 70,
                        "class": "Service",
                        "method": "bare_static_return",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "params": []
                    }
                },
                {
                    "has_sig": true,
                    "calls": 5,
                    "returns": ["String"],
                    "source": {
                        "path": "src/service.rb",
                        "line": 80,
                        "class": "Service",
                        "method": "void_contradiction",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "params": []
                    }
                }
            ],
            "unused_return_methods_by_location": {
                (unused_key): true,
                (contradicted_key): true
            },
            "facts": {
                "return_origins": [
                    {
                        "path": "src/service.rb",
                        "line": 60,
                        "class": "Service",
                        "method": "literal_return",
                        "kind": "instance",
                        "confidence": "strong",
                        "candidate_type": "String",
                        "sources": [{ "kind": "static", "type": "String", "code": "\"ok\"" }],
                        "blockers": []
                    },
                    {
                        "path": "src/service.rb",
                        "line": 70,
                        "class": "Service",
                        "method": "bare_static_return",
                        "kind": "instance",
                        "confidence": "strong",
                        "candidate_type": "String",
                        "sources": [{ "kind": "static", "type": "String", "code": "value" }],
                        "blockers": []
                    },
                    {
                        "path": "src/service.rb",
                        "line": 80,
                        "class": "Service",
                        "method": "void_contradiction",
                        "kind": "instance",
                        "confidence": "strong",
                        "candidate_type": "void",
                        "sources": [{ "kind": "static", "type": "void", "code": "nil" }],
                        "blockers": []
                    }
                ]
            }
        }));

        let actions = super::build_actions(&input);
        assert!(actions.iter().any(|a| {
            a.kind == "narrow_generic_param"
                && a.line == 10
                && a.data["type"] == "T::Array[Integer]"
                && a.confidence == "high"
        }));
        assert!(actions
            .iter()
            .any(|a| { a.kind == "fix_sig_param" && a.line == 10 && a.data["name"] == "value" }));
        assert!(actions.iter().any(|a| {
            a.kind == "fix_sig_return"
                && a.line == 10
                && a.data["type"] == "T::Hash[String, Integer]"
        }));
        assert!(actions.iter().any(|a| {
            a.kind == "fix_sig_return" && a.line == 30 && a.data["type"] == "T.noreturn"
        }));
        assert!(actions
            .iter()
            .any(|a| { a.kind == "fix_sig_return" && a.line == 40 && a.data["type"] == "void" }));
        assert!(actions
            .iter()
            .any(|a| { a.kind == "fix_sig_return" && a.line == 50 && a.data["type"] == "String" }));
        assert!(!actions.iter().any(|a| {
            a.kind == "fix_sig_return"
                && a.line == 50
                && a.data.get("source").and_then(|v| v.as_str()) == Some("unused_return")
        }));

        let literal = actions
            .iter()
            .find(|a| a.kind == "fix_sig_return" && a.line == 60)
            .unwrap();
        assert_eq!(literal.confidence, "high");

        let bare = actions
            .iter()
            .find(|a| a.kind == "fix_sig_return" && a.line == 70)
            .unwrap();
        assert_eq!(bare.confidence, "review");
        assert!(actions
            .iter()
            .any(|a| { a.kind == "fix_sig_return" && a.line == 80 && a.data["type"] == "String" }));
        assert!(!actions.iter().any(|a| {
            a.kind == "fix_sig_return"
                && a.line == 80
                && a.data.get("source").and_then(|v| v.as_str()) == Some("static_return_origin")
                && a.data.get("type").and_then(|v| v.as_str()) == Some("void")
        }));
    }

    #[test]
    fn test_static_backflow_forwarded_returns_and_struct_field_rbi_paths() {
        use serde_json::json;

        let input = input_from_json(json!({
            "methods": [],
            "facts": {
                "existing_sigs": [
                    {
                        "path": "src/service.rb",
                        "line": 10,
                        "class": "Service",
                        "method": "accept",
                        "kind": "instance",
                        "sig": "sig { params(user: T.untyped, ignored: T.untyped).void }"
                    },
                    {
                        "path": "src/service.rb",
                        "line": 20,
                        "class": "Service",
                        "method": "forwarded",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }"
                    },
                    {
                        "path": "src/service.rb",
                        "line": 30,
                        "class": "Service",
                        "method": "not_forwarded",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "return_origin": { "sources": [{ "kind": "static", "type": "String", "code": "\"ok\"" }] }
                    },
                    {
                        "path": "src/service.rb",
                        "line": 40,
                        "class": "Service",
                        "method": "bad_forward",
                        "kind": "instance",
                        "sig": "sig { returns(T.untyped) }",
                        "return_origin": { "sources": [{ "kind": "typed_call", "type": "Object", "callee": "load_any", "line": 41 }] }
                    }
                ],
                "param_origins": [
                    { "callee": "accept", "slot": "user", "origin_kind": "static", "type": "User", "path": "src/caller.rb", "line": 3, "code": "accept(user)" },
                    { "callee": "accept", "slot": "user", "origin_kind": "static", "type": "User", "path": "src/caller.rb", "line": 3, "code": "accept(user)" },
                    { "callee": "accept", "slot": "ignored", "origin_kind": "unknown", "path": "src/caller.rb", "line": 4, "code": "accept(dynamic)" }
                ],
                "return_origins": [
                    {
                        "path": "src/service.rb",
                        "line": 20,
                        "class": "Service",
                        "method": "forwarded",
                        "kind": "instance",
                        "sources": [
                            { "kind": "typed_call", "type": "String", "callee": "load_name", "line": 21 },
                            { "kind": "nil" }
                        ]
                    }
                ],
                "struct_field_runtime": [
                    { "class": "User", "field": "name", "classes": ["String"], "elem_classes": [], "calls": 5 },
                    { "class": "User", "field": "empty", "classes": [], "elem_classes": [], "calls": 5 }
                ],
                "struct_field_static": [
                    { "class": "User", "field": "missing_runtime", "type": "" }
                ]
            }
        }));

        let actions = super::build_actions(&input);
        let backflow = actions
            .iter()
            .find(|a| a.kind == "fix_sig_param" && a.line == 10)
            .unwrap();
        assert_eq!(backflow.data["name"], "user");
        assert_eq!(backflow.data["type"], "User");
        assert_eq!(backflow.data["callsite_count"], 2);
        assert_eq!(
            backflow
                .data
                .get("callsites")
                .and_then(|v| v.as_object())
                .and_then(|m| m.get("src/caller.rb:3:accept(user)"))
                .and_then(|v| v.as_i64()),
            Some(2)
        );

        let forwarded = actions
            .iter()
            .find(|a| a.kind == "fix_sig_return" && a.line == 20)
            .unwrap();
        assert_eq!(forwarded.confidence, "review");
        assert_eq!(forwarded.data["type"], "T.nilable(String)");
        assert!(!actions
            .iter()
            .any(|a| a.kind == "fix_sig_return" && a.line == 30));
        assert!(!actions
            .iter()
            .any(|a| a.kind == "fix_sig_return" && a.line == 40));

        let rbi = actions
            .iter()
            .find(|a| a.kind == "add_struct_field_sig" && a.data["target"] == "rbi")
            .unwrap();
        assert_eq!(rbi.path, "sorbet/rbi/ast-struct-fields.rbi");
        assert_eq!(rbi.data["field"], "name");
        assert!(!actions
            .iter()
            .any(|a| a.kind == "add_struct_field_sig" && a.data["field"] == "empty"));
    }

    #[test]
    fn legacy_runtime_contradiction_and_static_type_invariants() {
        assert!(super::runtime_contradicts(
            &["Hash".to_string(), "NilClass".to_string()],
            "T.nilable(T::Array[T.untyped])",
        ));
        assert!(!super::runtime_contradicts(
            &["Array".to_string(), "NilClass".to_string()],
            "T.nilable(T::Array[T.untyped])",
        ));
        assert!(super::runtime_contradicts(
            &["Array".to_string()],
            "T::Hash[T.untyped, T.untyped]",
        ));
        assert!(super::runtime_contradicts(
            &["NilClass".to_string()],
            "T.noreturn",
        ));
        assert!(!super::runtime_contradicts(
            &["NilClass".to_string()],
            "void",
        ));
        assert_eq!(
            super::static_sorbet_type(&["String".to_string(), "NilClass".to_string()]),
            Some("T.nilable(String)".to_string()),
        );
        assert_eq!(
            super::static_sorbet_type(&["String".to_string(), "Symbol".to_string()]),
            None,
        );
    }

    #[test]
    fn static_backflow_requires_protocol_and_runtime_compatibility() {
        use serde_json::json;

        let input = input_from_json(json!({
            "methods": [
                {
                    "key": ["Service", "accept_runtime", "instance", "/repo/src/service.rb", 40],
                    "params_by_name": {"node": ["AST::Foo", "Symbol"]}
                }
            ],
            "facts": {
                "existing_sigs": [
                    {
                        "path": "src/service.rb", "line": 10, "class": "Service",
                        "method": "accept", "kind": "instance",
                        "sig": "sig { params(node: T.untyped).void }",
                        "protocols": {"node": {"methods": ["token"], "gaps": []}}
                    },
                    {
                        "path": "src/service.rb", "line": 20, "class": "Service",
                        "method": "missing_protocol", "kind": "instance",
                        "sig": "sig { params(node: T.untyped).void }",
                        "protocols": {"node": {"methods": ["missing"], "gaps": []}}
                    },
                    {
                        "path": "src/service.rb", "line": 30, "class": "Service",
                        "method": "missing_forward", "kind": "instance",
                        "sig": "sig { params(node: T.untyped).void }",
                        "protocols": {"node": {"methods": [], "gaps": ["forwarded to absent slot 0 at src/service.rb:31"]}}
                    },
                    {
                        "path": "src/service.rb", "line": 40, "class": "Service",
                        "method": "accept_runtime", "kind": "instance",
                        "sig": "sig { params(node: T.untyped).void }",
                        "protocols": {"node": {"methods": [], "gaps": []}}
                    },
                    {
                        "path": "src/ast.rb", "line": 1, "class": "AST::Foo",
                        "method": "token", "kind": "instance",
                        "sig": "sig { returns(Token) }", "protocols": {}
                    }
                ],
                "param_origins": [
                    {"callee": "accept", "slot": "node", "origin_kind": "static", "type": "AST::Foo", "path": "src/caller.rb", "line": 1, "code": "accept(foo)"},
                    {"callee": "missing_protocol", "slot": "node", "origin_kind": "static", "type": "AST::Foo", "path": "src/caller.rb", "line": 2, "code": "missing_protocol(foo)"},
                    {"callee": "missing_forward", "slot": "node", "origin_kind": "static", "type": "AST::Foo", "path": "src/caller.rb", "line": 3, "code": "missing_forward(foo)"},
                    {"callee": "accept_runtime", "slot": "node", "origin_kind": "static", "type": "AST::Foo", "path": "src/caller.rb", "line": 4, "code": "accept_runtime(foo)"}
                ]
            }
        }));

        let actions = super::build_actions(&input);
        assert!(actions.iter().any(|action| {
            action.kind == "fix_sig_param" && action.line == 10 && action.data["type"] == "AST::Foo"
        }));
        assert!(!actions
            .iter()
            .any(|action| action.kind == "fix_sig_param" && action.line == 20));
        assert!(!actions
            .iter()
            .any(|action| action.kind == "fix_sig_param" && action.line == 30));
        assert!(!actions
            .iter()
            .any(|action| action.kind == "fix_sig_param" && action.line == 40));
    }

    #[test]
    fn forwarded_returns_and_noreturn_actions_reject_runtime_conflicts() {
        use serde_json::json;

        let input = input_from_json(json!({
            "methods": [
                {
                    "has_sig": true,
                    "returns": ["Symbol"],
                    "source": {
                        "path": "src/service.rb", "line": 10, "class": "Service",
                        "method": "forwarded", "kind": "instance", "has_sig": true,
                        "sig": "sig { returns(T.untyped) }", "params": []
                    }
                },
                {
                    "has_sig": true,
                    "returns": ["NilClass"],
                    "source": {
                        "path": "src/service.rb", "line": 20, "class": "Service",
                        "method": "boom", "kind": "instance", "has_sig": true,
                        "sig": "sig { returns(T.untyped) }", "params": [],
                        "noreturn_candidate": true
                    }
                },
                {
                    "has_sig": true,
                    "returns": [],
                    "source": {
                        "path": "src/service.rb", "line": 30, "class": "Service",
                        "method": "maybe_name", "kind": "instance", "has_sig": true,
                        "sig": "sig { returns(T.untyped) }", "params": []
                    }
                }
            ],
            "facts": {
                "existing_sigs": [
                    {"path": "src/service.rb", "line": 10, "class": "Service", "method": "forwarded", "kind": "instance", "sig": "sig { returns(T.untyped) }"},
                    {"path": "src/service.rb", "line": 30, "class": "Service", "method": "maybe_name", "kind": "instance", "sig": "sig { returns(T.untyped) }"}
                ],
                "return_origins": [
                    {
                        "path": "src/service.rb", "line": 10, "class": "Service",
                        "method": "forwarded", "kind": "instance",
                        "sources": [{"kind": "typed_call", "type": "String", "callee": "name", "line": 11}]
                    },
                    {
                        "path": "src/service.rb", "line": 30, "class": "Service",
                        "method": "maybe_name", "kind": "instance",
                        "sources": [
                            {"kind": "typed_call", "type": "String", "callee": "name", "line": 31},
                            {"kind": "nil"}
                        ]
                    }
                ]
            }
        }));

        let actions = super::build_actions(&input);
        assert!(!actions.iter().any(|action| {
            action.kind == "fix_sig_return"
                && action.line == 10
                && action.data.get("source").and_then(|value| value.as_str())
                    == Some("forwarded_return_chain")
        }));
        assert!(!actions.iter().any(|action| {
            action.kind == "fix_sig_return"
                && action.line == 20
                && action.data.get("type").and_then(|value| value.as_str()) == Some("T.noreturn")
        }));
        let maybe = actions
            .iter()
            .find(|action| {
                action.kind == "fix_sig_return"
                    && action.line == 30
                    && action.data.get("source").and_then(|value| value.as_str())
                        == Some("forwarded_return_chain")
            })
            .expect("nilable forwarded return action");
        assert_eq!(maybe.data["type"], "T.nilable(String)");
        assert_eq!(maybe.confidence, "review");
    }
}
