impl<'a> FileIndexer<'a> {
    fn method_source_record(&mut self, node: Node<'_>, state: &ScopeState) -> Value {
        let sig = sig_above(&self.file.lines, line(node));
        let method_params = params(node, sig.as_deref(), self.file);
        if let Some(ret) = sig.as_deref().and_then(extract_return_type) {
            self.global
                .method_return_types
                .entry(method_name(node, self.file))
                .or_default()
                .insert(ret);
        }
        let non_nil_params = non_nil_sig_params(sig.as_deref());
        let receiver = method_receiver(node);
        let kind = if receiver
            .map(|receiver| node_text(receiver, self.file) == "self")
            .unwrap_or(false)
        {
            "class"
        } else {
            "instance"
        };
        json!({
            "path": self.file.rel,
            "line": line(node),
            "end_line": end_line(node),
            "class": state.scope.join("::"),
            "method": method_name(node, self.file),
            "kind": kind,
            "has_sig": sig.is_some(),
            "sig": sig,
            "params": method_params,
            "scope": state.scope,
            "non_nil_params": non_nil_params,
            "uses_yield": method_body(node).map(|body| contains_kind(body, "yield")).unwrap_or(false),
            "untraceable_params": untraceable_param_names(node, self.file),
            "protocols": {},
            "noreturn_candidate": false,
        })
    }

    fn analyze_return_origin(
        &mut self,
        node: Node<'_>,
        record: &Value,
        frame: &mut Frame,
    ) -> Option<Value> {
        let body = method_body(node)?;
        let mut explicit = Vec::new();
        collect_explicit_returns(body, &mut explicit);
        let implicit = implicit_return_expression(body);
        let implicit_present = implicit.map(|expr| normalized_kind(expr, self.file) != NormKind::Return).unwrap_or(false);
        let mut expressions = explicit.clone();
        if implicit_present {
            if let Some(expr) = implicit {
                expressions.push(expr);
            }
        }
        let mut sources = Vec::new();
        let mut blockers = BTreeSet::new();
        for expr in &expressions {
            sources.extend(self.return_sources_for(*expr, frame, &mut blockers));
        }
        if expressions.is_empty() || sources.is_empty() {
            blockers.insert("no return expression found".to_string());
        }
        let source_types = sources
            .iter()
            .filter_map(|source| source.get("type").and_then(Value::as_str).map(ToString::to_string))
            .collect::<Vec<_>>();
        let mut candidate = static_sorbet_type(&source_types);
        if candidate == "NilClass"
            && sources.iter().any(|source| {
                matches!(
                    source.get("kind").and_then(Value::as_str),
                    Some("call_untyped" | "unknown")
                )
            })
        {
            candidate = "T.untyped".to_string();
        }
        let useful = useful_type(&candidate);
        let has_untyped_call = sources
            .iter()
            .any(|source| source.get("kind").and_then(Value::as_str) == Some("call_untyped"));
        let confidence = if useful && !weak_type(&candidate) && blockers.is_empty() && !has_untyped_call {
            "strong"
        } else if useful {
            "weak"
        } else {
            "blocked"
        };
        Some(json!({
            "path": record["path"],
            "line": record["line"],
            "end_line": record["end_line"],
            "class": record["class"],
            "method": record["method"],
            "kind": record["kind"],
            "implicit": explicit.is_empty(),
            "return_syntax": return_syntax(explicit.is_empty(), implicit_present),
            "control_shape": return_control_shape(&explicit, implicit, implicit_present, self.file),
            "candidate_type": if useful { candidate } else { "T.untyped".to_string() },
            "confidence": confidence,
            "sources": sources,
            "blockers": blockers.into_iter().collect::<Vec<_>>(),
            "hash_shape": self.hash_shape_for_return_expressions(&expressions, frame),
            "array_element_shape": self.array_element_shape_for_return_expressions(&expressions, frame),
        }))
    }

    fn return_sources_for(
        &mut self,
        node: Node<'_>,
        frame: &mut Frame,
        blockers: &mut BTreeSet<String>,
    ) -> Vec<Value> {
        let kind = normalized_kind(node, self.file);
        let code = node_text(node, self.file);
        let node_line = line(node);
        if kind == NormKind::Return {
            let args = call_arguments(node, self.file);
            if let Some(first) = args.first() {
                return self.return_sources_for(*first, frame, blockers);
            }
            return vec![json!({"kind": "nil", "type": "NilClass", "line": Value::Null, "code": "return"})];
        }
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            if let Some(expr) = implicit_return_expression(node) {
                return self.return_sources_for(expr, frame, blockers);
            }
        }
        if kind == NormKind::IvarRead || kind == NormKind::ClassVarRead || kind == NormKind::GlobalVarRead {
            blockers.insert(format!("untyped instance variable {code} at {}:{node_line}", self.file.rel));
            return vec![json!({"kind": "ivar_read", "line": node_line, "code": code})];
        }
        if kind == NormKind::If || kind == NormKind::Unless {
            let mut out = Vec::new();
            if let Some(cons) = consequent_node(node) {
                if let Some(expr) = implicit_return_expression(cons) {
                    out.extend(self.return_sources_for(expr, frame, blockers));
                }
            }
            if let Some(alt) = alternative_node(node) {
                if let Some(expr) = implicit_return_expression(alt) {
                    out.extend(self.return_sources_for(expr, frame, blockers));
                }
            } else {
                out.push(json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": "implicit else"}));
            }
            return out;
        }
        if kind == NormKind::Case {
            let mut out = Vec::new();
            for child in named_children(node) {
                if normalized_kind(child, self.file) == NormKind::When {
                    if let Some(body) = consequent_node(child) {
                        if let Some(expr) = implicit_return_expression(body) {
                            out.extend(self.return_sources_for(expr, frame, blockers));
                        }
                    }
                }
            }
            if let Some(alt) = alternative_node(node) {
                if let Some(expr) = implicit_return_expression(alt) {
                    out.extend(self.return_sources_for(expr, frame, blockers));
                }
            }
            if out.is_empty() {
                blockers.insert(format!("case return without exhaustive static branch type at {}:{node_line}", self.file.rel));
            }
            return out;
        }
        if kind == NormKind::While || kind == NormKind::Until {
            return vec![json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": code})];
        }
        if kind == NormKind::Call {
            let callee = call_name(node, self.file).unwrap_or_default();
            if assignment_call(node, self.file) {
                if let Some(arg) = assignment_value_expression(node, self.file) {
                    if let Some(arg_type) = self.expression_type(arg, frame) {
                        if useful_type(&arg_type) {
                            return vec![json!({"kind": "assignment", "callee": callee, "type": arg_type, "line": node_line, "code": code})];
                        }
                    }
                    blockers.insert(format!("assignment {callee} has unknown RHS at {}:{node_line}", self.file.rel));
                    return vec![json!({"kind": "unknown", "line": node_line, "code": code, "unknown_reasons": self.unknown_expression_reasons(arg, frame)})];
                }
            }
            if safe_navigation(node) {
                if let Some(ret) = self.known_return_type(&callee, Some(node), frame) {
                    if useful_type(&ret) {
                        return vec![json!({"kind": "safe_call", "callee": callee, "type": nilable_type(&ret), "line": node_line, "code": code, "stdlib": false})];
                    }
                }
                blockers.insert(format!("safe navigation return may be nil at {}:{node_line}", self.file.rel));
                return vec![
                    json!({"kind": "nil", "type": "NilClass", "line": node_line, "code": code}),
                    json!({"kind": "call_untyped", "callee": callee, "line": node_line, "code": code}),
                ];
            }
            if let Some(ret) = self.known_return_type(&callee, Some(node), frame) {
                if useful_type(&ret) {
                    return vec![json!({"kind": "typed_call", "callee": callee, "type": ret, "line": node_line, "code": code, "stdlib": false})];
                }
            }
            if let Some(expr_type) = self.expression_type(node, frame) {
                if useful_type(&expr_type) {
                    return vec![json!({"kind": "static", "callee": callee, "type": expr_type, "line": node_line, "code": code})];
                }
            }
            blockers.insert(format!("untyped callee {callee} at {}:{node_line}", self.file.rel));
            return vec![json!({"kind": "call_untyped", "callee": callee, "line": node_line, "code": code})];
        }
        if matches!(
            kind,
            NormKind::LocalWrite
                | NormKind::IvarWrite
                | NormKind::ClassVarWrite
                | NormKind::GlobalVarWrite
                | NormKind::ConstWrite
        ) {
            if let Some(value) = write_value(node) {
                return self.return_sources_for(value, frame, blockers);
            }
        }
        if let Some(ty) = self.expression_type(node, frame) {
            return vec![json!({"kind": if ty == "NilClass" { "nil" } else { "static" }, "type": ty, "line": node_line, "code": code})];
        }
        blockers.insert(format!(
            "unknown return expression {} at {}:{node_line}",
            debug_node_name(kind),
            self.file.rel
        ));
        vec![json!({"kind": "unknown", "line": node_line, "code": code, "unknown_reasons": self.unknown_expression_reasons(node, frame)})]
    }

    fn collect_local_type_facts(&mut self, node: Node<'_>, frame: &mut Frame) {
        if nested_scope_node(node, self.file) {
            return;
        }
        if normalized_kind(node, self.file) == NormKind::LocalWrite {
            self.update_local_fact(node, frame);
        }
        if normalized_kind(node, self.file) == NormKind::Call {
            self.update_collection_builder_call(node, frame);
        }
        for child in named_children(node) {
            self.collect_local_type_facts(child, frame);
        }
    }

    fn known_return_type(
        &mut self,
        method_name: &str,
        node: Option<Node<'_>>,
        frame: &mut Frame,
    ) -> Option<String> {
        if let Some(node) = node {
            if let Some(propagated) = self.propagated_core_return_type(node, frame) {
                if useful_type(&propagated) {
                    return Some(propagated);
                }
            }
        }
        if let Some(ty) = self.global.static_return_types.get(method_name) {
            if useful_type(ty) {
                return Some(ty.clone());
            }
        }
        let types = self
            .global
            .method_return_types
            .get(method_name)
            .map(|set| set.iter().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        if types.len() == 1 && useful_type(&types[0]) {
            return Some(types[0].clone());
        }
        None
    }

    fn propagated_core_return_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        let receiver = call_receiver(node, self.file)?;
        let receiver_type = self.expression_type(receiver, frame);
        let name = call_name(node, self.file)?;
        match name.as_str() {
            "[]" => self.collection_index_return_type(node, receiver_type.as_deref(), frame),
            "each" | "each_pair" | "each_value" | "each_key" => {
                receiver_type.filter(|ty| collection_receiver_type(ty))
            }
            "<<" | "push" | "concat" | "merge!" | "add" => {
                receiver_type.filter(|ty| collection_receiver_type(ty))
            }
            "length" | "size" => {
                if receiver_type.as_deref().is_some_and(|ty| collection_receiver_type(ty) || ty == "String") {
                    Some("Integer".to_string())
                } else {
                    None
                }
            }
            "empty?" | "any?" | "all?" | "none?" | "one?" | "include?" | "key?" | "has_key?" | "value?" | "has_value?" => {
                if receiver_type.as_deref().is_some_and(|ty| collection_receiver_type(ty) || ty == "String") {
                    Some("T::Boolean".to_string())
                } else {
                    None
                }
            }
            "join" => {
                if receiver_type.as_deref().is_some_and(array_receiver_type) {
                    Some("String".to_string())
                } else {
                    None
                }
            }
            "to_s" => Some("String".to_string()),
            "to_i" => Some("Integer".to_string()),
            "to_sym" => Some("Symbol".to_string()),
            "!" | "!=" | "==" | "<" | ">" | "<=" | ">=" | "eql?" | "equal?" | "===" | "frozen?" | "respond_to?" | "kind_of?" | "instance_of?" => {
                Some("T::Boolean".to_string())
            }
            "hash" => Some("Integer".to_string()),
            "inspect" => Some("String".to_string()),
            "freeze" | "dup" | "clone" | "itself" | "tap" => receiver_type.filter(|ty| useful_type(ty)),
            "+" | "-" | "*" | "/" | "%" => match receiver_type.as_deref() {
                Some("Integer" | "Float" | "Rational" | "Complex" | "String") => receiver_type,
                Some(ty) if array_receiver_type(ty) => receiver_type,
                _ => None,
            },
            _ => None,
        }
    }

    fn nil_return_expression(&mut self, expr: Node<'_>) -> bool {
        let kind = normalized_kind(expr, self.file);
        if kind == NormKind::Return {
            let args = call_arguments(expr, self.file);
            return args.first().map(|arg| self.nil_return_expression(*arg)).unwrap_or(true);
        }
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            return implicit_return_expression(expr)
                .map(|inner| self.nil_return_expression(inner))
                .unwrap_or(false);
        }
        kind == NormKind::Nil
    }
}

fn collect_explicit_returns<'tree>(node: Node<'tree>, results: &mut Vec<Node<'tree>>) {
    if nested_scope_kind(node.kind()) {
        return;
    }
    if node.kind() == "return" || normalized_kind_by_raw(node) == NormKind::Return {
        let args = raw_return_args(node);
        if let Some(first) = args.first() {
            results.push(*first);
        }
        return;
    }
    for child in named_children(node) {
        collect_explicit_returns(child, results);
    }
}

fn method_body(node: Node<'_>) -> Option<Node<'_>> {
    named_children(node)
        .into_iter()
        .find(|child| matches!(child.kind(), "body_statement" | "block_body"))
        .or_else(|| node.child_by_field_name("body"))
        .or_else(|| {
        named_children(node)
            .into_iter()
            .rev()
            .find(|child| !matches!(child.kind(), "method_parameters" | "identifier" | "self"))
    })
}

fn method_receiver(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("object").or_else(|| {
        let children = all_children(node);
        let dot = children.iter().position(|child| !child.is_named() && node_text_raw(*child) == ".");
        dot.and_then(|idx| idx.checked_sub(1)).map(|idx| children[idx])
    })
}

fn method_name(node: Node<'_>, file: &SourceFile) -> String {
    node.child_by_field_name("name")
        .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "identifier"))
        .map(|child| node_text(child, file))
        .unwrap_or_default()
}

fn assignment_call(node: Node<'_>, file: &SourceFile) -> bool {
    setter_call(node, file) || index_assignment_call(node, file)
}

fn setter_call(node: Node<'_>, file: &SourceFile) -> bool {
    if normalized_kind(node, file) != NormKind::Call {
        return false;
    }
    let Some(name) = call_name(node, file) else { return false };
    name.ends_with('=') && !matches!(name.as_str(), "==" | "!=" | "<=" | ">=" | "===") && call_arguments(node, file).len() == 1
}

fn index_assignment_call(node: Node<'_>, file: &SourceFile) -> bool {
    normalized_kind(node, file) == NormKind::Call
        && call_name(node, file).as_deref() == Some("[]=")
        && call_arguments(node, file).len() >= 2
}

fn assignment_value_expression<'tree>(node: Node<'tree>, file: &SourceFile) -> Option<Node<'tree>> {
    call_arguments(node, file).last().copied()
}

fn implicit_return_expression(node: Node<'_>) -> Option<Node<'_>> {
    match node.kind() {
        "body_statement" | "block_body" | "then" if hidden_or_body_statement(node) => Some(node),
        "program" | "body_statement" | "block_body" | "then" => statement_expressions(node).last().copied(),
        "begin" | "else" | "parenthesized_statements" | "parenthesized_expression" => {
            statement_expressions(node).last().copied()
        }
        _ => Some(node),
    }
}

fn statement_expressions(node: Node<'_>) -> Vec<Node<'_>> {
    named_children(node)
        .into_iter()
        .filter(|child| !matches!(child.kind(), "rescue" | "ensure"))
        .collect()
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

fn return_control_shape(
    explicit: &[Node<'_>],
    implicit: Option<Node<'_>>,
    implicit_present: bool,
    file: &SourceFile,
) -> &'static str {
    if explicit.len() > 1 || (!explicit.is_empty() && implicit_present) {
        return "branching";
    }
    if explicit.iter().any(|expr| branching_return_expression(*expr, file)) {
        return "branching";
    }
    if implicit_present && implicit.is_some_and(|expr| branching_return_expression(expr, file)) {
        return "branching";
    }
    "branchless"
}

fn branching_return_expression(node: Node<'_>, file: &SourceFile) -> bool {
    if matches!(
        normalized_kind(node, file),
        NormKind::If | NormKind::Case | NormKind::Rescue
    ) {
        return true;
    }
    named_children(node)
        .into_iter()
        .any(|child| branching_return_expression(child, file))
}
