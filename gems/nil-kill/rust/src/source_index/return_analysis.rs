impl<'a> FileIndexer<'a> {
    fn scoped_facts(&self, method_record: &Value) -> Frame {
        let mut frame = Frame::default();
        scope_method_frame(method_record, &mut frame);
        frame.collection_builders = self.seed_param_collection_builders(method_record);
        frame.hash_shapes = self.seed_param_hash_shapes(method_record);
        frame.array_element_shapes = self.seed_param_array_element_shapes(method_record);
        frame
    }

    fn method_record(&mut self, node: Node<'_>, state: &ScopeState) -> Value {
        let sig = sig_above(&self.file.lines, line(node));
        let method_params = params(node, sig.as_deref(), self.file);
        if let Some(ret) = sig.as_deref().and_then(extract_return_type) {
            self
                .method_return_types
                .entry(method_name(node, self.file))
                .or_default()
                .insert(ret);
        }
        let body = method_body(node);
        let noreturn_candidate = !self.contains_explicit_return(body) && body.is_some_and(|body| self.noreturn_body(body));
        if noreturn_candidate
            || sig
                .as_deref()
                .is_some_and(|sig| sig.contains("returns(T.noreturn)") || sig.contains("returns( T.noreturn )"))
        {
            self.global.noreturn_methods.insert(method_name(node, self.file));
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
            "uses_yield": body.map(|body| uses_yield(body, self.file)).unwrap_or(false),
            "untraceable_params": untraceable_param_names(node, self.file),
            "protocols": {},
            "noreturn_candidate": noreturn_candidate,
        })
    }

    fn contains_explicit_return(&self, node: Option<Node<'_>>) -> bool {
        let Some(node) = node else { return false };
        if self.nested_scope_node(node) {
            return false;
        }
        if self.return_node(node) {
            return true;
        }
        named_children(node)
            .into_iter()
            .any(|child| self.contains_explicit_return(Some(child)))
    }

    fn noreturn_body(&mut self, node: Node<'_>) -> bool {
        match normalized_kind(node, self.file) {
            NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses => {
                implicit_return_expression(node).is_some_and(|inner| self.noreturn_body(inner))
            }
            NormKind::If | NormKind::Unless => {
                let left = consequent_node(node)
                    .and_then(implicit_return_expression)
                    .is_some_and(|inner| self.noreturn_body(inner));
                let right = alternative_node(node)
                    .and_then(implicit_return_expression)
                    .is_some_and(|inner| self.noreturn_body(inner));
                left && right
            }
            NormKind::Case => {
                let arms = named_children(node)
                    .into_iter()
                    .filter(|child| normalized_kind(*child, self.file) == NormKind::When)
                    .collect::<Vec<_>>();
                !arms.is_empty()
                    && arms
                        .into_iter()
                        .all(|arm| consequent_node(arm).is_some_and(|body| self.noreturn_body(body)))
                    && alternative_node(node).is_some_and(|body| self.noreturn_body(body))
            }
            NormKind::Rescue => {
                let children = named_children(node);
                children
                    .iter()
                    .copied()
                    .all(|child| self.noreturn_body(child))
            }
            NormKind::Call => self.noreturn_call(node),
            _ => false,
        }
    }

    fn noreturn_call(&mut self, node: Node<'_>) -> bool {
        let name = call_name(node, self.file).unwrap_or_default();
        if matches!(name.as_str(), "raise" | "fail" | "exit" | "abort") {
            return true;
        }
        if name == "absurd"
            && call_receiver(node, self.file).map(|receiver| node_text(receiver, self.file)) == Some("T".to_string())
        {
            return true;
        }
        if self.global.noreturn_methods.contains(&name) {
            return true;
        }
        self.known_return_type(&name, Some(node), &mut Frame::default()).as_deref() == Some("T.noreturn")
    }

    fn analyze_return_origin(
        &mut self,
        node: Node<'_>,
        record: &Value,
        frame: &mut Frame,
    ) -> Option<Value> {
        let body = method_body(node)?;
        let explicit = self.explicit_return_expressions(body);
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
                        let stdlib = self.statically_provable_call(node, frame);
                        return vec![json!({"kind": "safe_call", "callee": callee, "type": nilable_type(&ret), "line": node_line, "code": code, "stdlib": stdlib})];
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
                    let stdlib = self.statically_provable_call(node, frame);
                    return vec![json!({"kind": "typed_call", "callee": callee, "type": ret, "line": node_line, "code": code, "stdlib": stdlib})];
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
        if normalized_kind(node, self.file) == NormKind::If {
            self.collect_branch_local_type_facts(node, frame);
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

    fn collect_branch_local_type_facts(&mut self, node: Node<'_>, frame: &mut Frame) {
        let before = frame.clone();

        let mut then_frame = before.clone();
        if let Some(consequent) = consequent_node(node) {
            self.collect_local_type_facts(consequent, &mut then_frame);
        }

        let mut else_frame = before.clone();
        if let Some(alternative) = alternative_node(node) {
            self.collect_local_type_facts(alternative, &mut else_frame);
        }

        frame.local_types = self.merge_branch_local_types(
            &before.local_types,
            &then_frame.local_types,
            &else_frame.local_types,
        );
        frame.collection_builders = self.merge_branch_collection_builders(
            &before.collection_builders,
            &then_frame.collection_builders,
            &else_frame.collection_builders,
        );
        frame.hash_shapes = self.merge_branch_hash_shapes(
            &before.hash_shapes,
            &then_frame.hash_shapes,
            &else_frame.hash_shapes,
        );
        frame.array_element_shapes = self.merge_branch_hash_shapes(
            &before.array_element_shapes,
            &then_frame.array_element_shapes,
            &else_frame.array_element_shapes,
        );
    }

    fn merge_branch_local_types(
        &self,
        before: &BTreeMap<String, String>,
        then_types: &BTreeMap<String, String>,
        else_types: &BTreeMap<String, String>,
    ) -> BTreeMap<String, String> {
        let names = before
            .keys()
            .chain(then_types.keys())
            .chain(else_types.keys())
            .cloned()
            .collect::<BTreeSet<_>>();
        names
            .into_iter()
            .filter_map(|name| {
                if then_types.contains_key(&name) && else_types.contains_key(&name) {
                    let ty = static_sorbet_type(
                        &[then_types.get(&name).cloned(), else_types.get(&name).cloned()]
                            .into_iter()
                            .flatten()
                            .collect::<Vec<_>>(),
                    );
                    return Some((name, if useful_type(&ty) { ty } else { "T.untyped".to_string() }));
                }
                before.get(&name).cloned().map(|ty| (name, ty))
            })
            .collect()
    }

    fn explicit_return_expressions<'tree>(&self, node: Node<'tree>) -> Vec<Node<'tree>> {
        let mut results = Vec::new();
        collect_explicit_returns(node, &mut results);
        results
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
        if let Some(ty) = self.static_return_types.get(method_name) {
            if useful_type(ty) {
                return Some(ty.clone());
            }
        }
        let types = self
            .method_return_types
            .get(method_name)
            .map(|set| set.iter().cloned().collect::<Vec<_>>())
            .unwrap_or_default();
        if types.len() == 1 && useful_type(&types[0]) {
            return Some(types[0].clone());
        }
        if let Some(node) = node {
            if let Some(ret) = self.rbi_return_source(node, frame) {
                if useful_type(&ret) {
                    return Some(ret);
                }
            }
        }
        None
    }

    fn rbi_return_candidate(&self, node: Node<'_>) -> bool {
        if normalized_kind(node, self.file) != NormKind::Call {
            return false;
        }
        if call_receiver(node, self.file).is_some_and(|receiver| normalized_kind(receiver, self.file) == NormKind::GlobalVarRead) {
            return false;
        }
        call_receiver(node, self.file).is_some()
            || matches!(
                call_name(node, self.file).as_deref(),
                Some("!" | "==" | "puts" | "print" | "warn" | "raise")
            )
    }

    fn rbi_return_source(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        if !self.rbi_return_candidate(node) {
            return None;
        }
        let method = call_name(node, self.file)?;
        let receiver_type = self.receiver_type_for_call(node, frame);
        core_rbi_return_type(&method, receiver_type.as_deref())
    }

    fn statically_provable_call(&mut self, node: Node<'_>, frame: &mut Frame) -> Value {
        if let Some(ret) = self.rbi_return_source(node, frame) {
            return json!(ret);
        }
        json!(
            self.propagated_core_return_type(node, frame)
                .as_deref()
                .is_some_and(useful_type)
        )
    }

    fn receiver_type_for_call(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        if normalized_kind(node, self.file) != NormKind::Call {
            return None;
        }
        call_receiver(node, self.file).and_then(|receiver| self.expression_type(receiver, frame))
    }

    fn propagated_core_return_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        let receiver_type = self.receiver_type_for_call(node, frame);
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
            "map" => receiver_type
                .as_deref()
                .and_then(|ty| self.collection_map_return_type(node, ty, frame)),
            "filter_map" => receiver_type
                .as_deref()
                .and_then(|ty| self.collection_filter_map_return_type(node, ty, frame)),
            "compact" => receiver_type
                .as_deref()
                .and_then(collection_compact_return_type),
            "select" | "reject" => receiver_type.filter(|ty| collection_receiver_type(ty)),
            "to_a" => receiver_type.filter(|ty| collection_receiver_type(ty)),
            "to_h" => receiver_type
                .filter(|ty| ty.starts_with("T::Hash") || ty.starts_with("T::Array")),
            "to_s" => Some("String".to_string()),
            "to_i" => Some("Integer".to_string()),
            "to_f" => Some("Float".to_string()),
            "to_sym" => Some("Symbol".to_string()),
            "!" | "!=" | "==" | "<" | ">" | "<=" | ">=" | "eql?" | "equal?" | "===" | "frozen?" | "respond_to?" | "kind_of?" | "instance_of?" => {
                Some("T::Boolean".to_string())
            }
            "<=>" => {
                if call_receiver(node, self.file).is_some() {
                    Some("T.nilable(Integer)".to_string())
                } else {
                    None
                }
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

    fn return_node(&self, node: Node<'_>) -> bool {
        normalized_kind(node, self.file) == NormKind::Return
    }

    fn nested_scope_node(&self, node: Node<'_>) -> bool {
        nested_scope_node(node, self.file)
    }

    fn hash_shape_for_return_expressions(&mut self, expressions: &[Node<'_>], frame: &mut Frame) -> Value {
        let mut shapes = Vec::new();
        for expr in expressions {
            if self.nil_return_expression(*expr) {
                continue;
            }
            if let Some(shape) = self.hash_shape_for_expression(*expr, frame) {
                shapes.push(shape);
            } else {
                return Value::Null;
            }
        }
        if shapes.is_empty() {
            Value::Null
        } else {
            shapes.into_iter().reduce(merge_hash_record_shapes).unwrap_or(Value::Null)
        }
    }

    fn hash_shape_for_expression(&mut self, expr: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let kind = normalized_kind(expr, self.file);
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            return implicit_return_expression(expr).and_then(|inner| self.hash_shape_for_expression(inner, frame));
        }
        if kind == NormKind::Return {
            return call_arguments(expr, self.file)
                .first()
                .and_then(|arg| self.hash_shape_for_expression(*arg, frame));
        }
        if kind == NormKind::If {
            let left = consequent_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.hash_shape_for_expression(inner, frame));
            let right = alternative_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.hash_shape_for_expression(inner, frame));
            return match (left, right) {
                (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                _ => None,
            };
        }
        self.hash_shape_for_value(expr, frame)
    }

    fn array_element_shape_for_return_expressions(&mut self, expressions: &[Node<'_>], frame: &mut Frame) -> Value {
        let mut shapes = Vec::new();
        for expr in expressions {
            if self.nil_return_expression(*expr) {
                continue;
            }
            if let Some(shape) = self.array_element_shape_for_expression(*expr, frame) {
                shapes.push(shape);
            } else {
                return Value::Null;
            }
        }
        if shapes.is_empty() {
            Value::Null
        } else {
            shapes.into_iter().reduce(merge_hash_record_shapes).unwrap_or(Value::Null)
        }
    }

    fn array_element_shape_for_expression(&mut self, expr: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let kind = normalized_kind(expr, self.file);
        if matches!(kind, NormKind::Statements | NormKind::Begin | NormKind::Else | NormKind::Parentheses) {
            return implicit_return_expression(expr).and_then(|inner| self.array_element_shape_for_expression(inner, frame));
        }
        if kind == NormKind::Return {
            return call_arguments(expr, self.file)
                .first()
                .and_then(|arg| self.array_element_shape_for_expression(*arg, frame));
        }
        if kind == NormKind::If {
            let left = consequent_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.array_element_shape_for_expression(inner, frame));
            let right = alternative_node(expr)
                .and_then(implicit_return_expression)
                .and_then(|inner| self.array_element_shape_for_expression(inner, frame));
            return match (left, right) {
                (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                _ => None,
            };
        }
        self.array_element_shape_for_value(expr, frame)
    }

    fn update_collection_builder_call(&mut self, node: Node<'_>, frame: &mut Frame) {
        if let Some(receiver) = call_receiver(node, self.file) {
            if normalized_kind(receiver, self.file) == NormKind::LocalRead {
                let receiver_name = node_text(receiver, self.file);
                if frame.collection_builders.contains_key(&receiver_name) {
                    self.update_receiver_collection_builder(node, &receiver_name, frame);
                }
            }
        }
        self.poison_escaped_collection_builders(node, frame);
    }

    fn update_receiver_collection_builder(&mut self, node: Node<'_>, name: &str, frame: &mut Frame) {
        let Some(mut builder) = frame.collection_builders.remove(name) else {
            return;
        };
        let method_name = call_name(node, self.file).unwrap_or_default();
        let args = call_arguments(node, self.file);
        let mut handled = true;
        match method_name.as_str() {
            "<<" | "push" | "add" => {
                if let Some(arg) = args.first() {
                    self.add_collection_type(&mut builder, Some(*arg), frame);
                    if builder.kind == CollectionBuilderKind::Array {
                        self.add_array_element_shape(name, Some(*arg), frame);
                    }
                }
            }
            "concat" => {
                if let Some(arg) = args.first() {
                    self.add_array_collection_types(&mut builder, Some(*arg), frame);
                    if builder.kind == CollectionBuilderKind::Array {
                        self.add_array_element_shapes(name, Some(*arg), frame);
                    }
                }
            }
            "[]=" => {
                if args.len() >= 2 {
                    self.add_hash_collection_types(&mut builder, args.first().copied(), args.last().copied(), frame);
                    if builder.kind == CollectionBuilderKind::Hash {
                        self.add_hash_shape_key(name, args[0], *args.last().unwrap(), frame);
                    }
                } else {
                    handled = false;
                }
            }
            "merge!" => {
                self.add_hash_literal_collection_types(&mut builder, args.first().copied(), frame);
                if builder.kind == CollectionBuilderKind::Hash {
                    self.merge_hash_shape_literal(name, args.first().copied(), frame);
                }
            }
            _ => handled = false,
        }
        if handled {
            if let Some(ty) = self.synthesized_collection_builder_type(&builder) {
                frame.local_types.insert(name.to_string(), ty);
            } else {
                frame.local_types.remove(name);
            }
        }
        frame.collection_builders.insert(name.to_string(), builder);
    }

    fn add_array_element_shape(&mut self, name: &str, expr: Option<Node<'_>>, frame: &mut Frame) {
        let Some(expr) = expr else { return };
        let Some(shape) = self.hash_shape_for_value(expr, frame) else { return };
        if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let merged = frame
            .array_element_shapes
            .get(name)
            .cloned()
            .map(|current| merge_hash_record_shapes(current, shape.clone()))
            .unwrap_or_else(|| clone_hash_shape(&shape));
        frame.array_element_shapes.insert(name.to_string(), merged);
    }

    fn add_array_element_shapes(&mut self, name: &str, expr: Option<Node<'_>>, frame: &mut Frame) {
        let Some(expr) = expr else { return };
        let Some(shape) = self.array_element_shape_for_value(expr, frame) else { return };
        if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let merged = frame
            .array_element_shapes
            .get(name)
            .cloned()
            .map(|current| merge_hash_record_shapes(current, shape.clone()))
            .unwrap_or_else(|| clone_hash_shape(&shape));
        frame.array_element_shapes.insert(name.to_string(), merged);
    }

    fn add_hash_shape_key(&mut self, name: &str, key_expr: Node<'_>, value_expr: Node<'_>, frame: &mut Frame) {
        let Some(key) = hash_key_name(key_expr, self.file) else { return };
        let Some(ty) = self.expression_type(value_expr, frame) else { return };
        if !useful_type(&ty) && ty != "NilClass" {
            return;
        }
        let shape = frame
            .hash_shapes
            .entry(name.to_string())
            .or_insert_with(empty_hash_shape);
        let keys = shape
            .get_mut("keys")
            .and_then(Value::as_object_mut)
            .expect("hash shape keys");
        let entry = keys.entry(key).or_insert_with(|| json!([]));
        if let Some(types) = entry.as_array_mut() {
            if !types.iter().any(|entry| entry.as_str() == Some(&ty)) {
                types.push(json!(ty));
            }
        }
    }

    fn merge_hash_shape_literal(&mut self, name: &str, expr: Option<Node<'_>>, frame: &mut Frame) {
        let Some(expr) = expr else { return };
        let Some(shape) = self.hash_shape_for_value(expr, frame) else { return };
        if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
            return;
        }
        let merged = frame
            .hash_shapes
            .get(name)
            .cloned()
            .map(|current| merge_hash_record_shapes(current, shape.clone()))
            .unwrap_or_else(|| clone_hash_shape(&shape));
        frame.hash_shapes.insert(name.to_string(), merged);
    }

    fn poison_escaped_collection_builders(&mut self, node: Node<'_>, frame: &mut Frame) {
        if call_receiver(node, self.file).is_some() {
            return;
        }
        let name = call_name(node, self.file).unwrap_or_default();
        if frame.current_method.as_deref() == Some(name.as_str()) {
            return;
        }
        if self.known_return_type(&name, Some(node), frame).is_some() {
            return;
        }
        for arg in call_arguments(node, self.file) {
            if normalized_kind(arg, self.file) != NormKind::LocalRead {
                continue;
            }
            let arg_name = node_text(arg, self.file);
            if let Some(builder) = frame.collection_builders.get_mut(&arg_name) {
                builder.poisoned = true;
                frame.local_types.remove(&arg_name);
                frame.hash_shapes.remove(&arg_name);
                frame.array_element_shapes.remove(&arg_name);
            }
        }
        for arg in call_arguments(node, self.file) {
            if normalized_kind(arg, self.file) != NormKind::LocalRead {
                continue;
            }
            let arg_name = node_text(arg, self.file);
            if frame.hash_shapes.contains_key(&arg_name) || frame.array_element_shapes.contains_key(&arg_name) {
                frame.hash_shapes.remove(&arg_name);
                frame.array_element_shapes.remove(&arg_name);
            }
        }
    }

    fn add_collection_type(&mut self, builder: &mut CollectionBuilder, expr: Option<Node<'_>>, frame: &mut Frame) {
        let Some(expr) = expr else { return };
        match self.expression_type(expr, frame) {
            Some(ty) if useful_type(&ty) || ty == "NilClass" => {
                builder.types.insert(ty);
            }
            _ => builder.poisoned = true,
        }
    }

    fn add_array_collection_types(&mut self, builder: &mut CollectionBuilder, expr: Option<Node<'_>>, frame: &mut Frame) {
        let Some(expr) = expr else { return };
        if normalized_kind(expr, self.file) == NormKind::Array {
            for elem in array_elements(expr) {
                self.add_collection_type(builder, Some(elem), frame);
            }
            return;
        }
        let ty = self.expression_type(expr, frame);
        let info = ty.as_deref().and_then(collection_type_info);
        if info.as_ref().is_some_and(|info| info.kind == "array" && info.element.as_deref().is_some_and(useful_type)) {
            builder.types.insert(info.and_then(|info| info.element).unwrap());
        } else {
            builder.poisoned = true;
        }
    }

    fn add_hash_collection_types(
        &mut self,
        builder: &mut CollectionBuilder,
        key_expr: Option<Node<'_>>,
        value_expr: Option<Node<'_>>,
        frame: &mut Frame,
    ) {
        let (Some(key_expr), Some(value_expr)) = (key_expr, value_expr) else {
            builder.poisoned = true;
            return;
        };
        let key_type = self.expression_type(key_expr, frame);
        let value_type = self.expression_type(value_expr, frame);
        if key_type.as_deref().is_some_and(|ty| useful_type(ty) || ty == "NilClass")
            && value_type.as_deref().is_some_and(|ty| useful_type(ty) || ty == "NilClass")
        {
            builder.key_types.insert(key_type.unwrap());
            builder.value_types.insert(value_type.unwrap());
        } else {
            builder.poisoned = true;
        }
    }

    fn add_hash_literal_collection_types(
        &mut self,
        builder: &mut CollectionBuilder,
        expr: Option<Node<'_>>,
        frame: &mut Frame,
    ) {
        let Some(expr) = expr else {
            builder.poisoned = true;
            return;
        };
        if !matches!(normalized_kind(expr, self.file), NormKind::Hash | NormKind::KeywordHash) {
            builder.poisoned = true;
            return;
        }
        for pair in hash_pairs(expr) {
            self.add_hash_collection_types(builder, pair_key(pair), pair_value(pair), frame);
        }
    }

    fn builder_has_evidence(&self, builder: &CollectionBuilder) -> bool {
        !builder.types.is_empty()
            || !builder.key_types.is_empty()
            || !builder.value_types.is_empty()
            || builder.poisoned
    }

    fn synthesized_collection_builder_type(&self, builder: &CollectionBuilder) -> Option<String> {
        if builder.poisoned {
            return None;
        }
        match builder.kind {
            CollectionBuilderKind::Array => {
                let elem = static_sorbet_type(&builder.types.iter().cloned().collect::<Vec<_>>());
                Some(format!("T::Array[{}]", if useful_type(&elem) { elem } else { "T.untyped".to_string() }))
            }
            CollectionBuilderKind::Hash => {
                let key = static_sorbet_type(&builder.key_types.iter().cloned().collect::<Vec<_>>());
                let value = static_sorbet_type(&builder.value_types.iter().cloned().collect::<Vec<_>>());
                Some(format!(
                    "T::Hash[{}, {}]",
                    if useful_type(&key) { key } else { "T.untyped".to_string() },
                    if useful_type(&value) { value } else { "T.untyped".to_string() },
                ))
            }
            CollectionBuilderKind::Set => {
                let elem = static_sorbet_type(&builder.types.iter().cloned().collect::<Vec<_>>());
                Some(format!("T::Set[{}]", if useful_type(&elem) { elem } else { "T.untyped".to_string() }))
            }
            CollectionBuilderKind::Unknown => None,
        }
    }

    fn seed_param_collection_builders(&self, record: &Value) -> BTreeMap<String, CollectionBuilder> {
        value_array(record.get("params"))
            .into_iter()
            .filter_map(|param| {
                let name = param.get("name").and_then(Value::as_str)?;
                let ty = param.get("type").and_then(Value::as_str).unwrap_or("");
                let info = collection_type_info(ty)?;
                let has_untyped = info.element.as_deref().is_some_and(|part| part.contains("T.untyped"))
                    || info.value.as_deref().is_some_and(|part| part.contains("T.untyped"));
                if !has_untyped {
                    return None;
                }
                Some((name.to_string(), self.collection_builder(collection_builder_kind(&info.kind))))
            })
            .collect()
    }

    #[allow(dead_code)]
    fn dup_collection_builders(
        &self,
        builders: &BTreeMap<String, CollectionBuilder>,
    ) -> BTreeMap<String, CollectionBuilder> {
        builders.clone()
    }

    fn collection_builder(&self, kind: CollectionBuilderKind) -> CollectionBuilder {
        CollectionBuilder::new(kind)
    }

    fn merge_branch_collection_builders(
        &self,
        before: &BTreeMap<String, CollectionBuilder>,
        then_builders: &BTreeMap<String, CollectionBuilder>,
        else_builders: &BTreeMap<String, CollectionBuilder>,
    ) -> BTreeMap<String, CollectionBuilder> {
        let names = before
            .keys()
            .chain(then_builders.keys())
            .chain(else_builders.keys())
            .cloned()
            .collect::<BTreeSet<_>>();
        names
            .into_iter()
            .filter_map(|name| {
                if let (Some(left), Some(right)) = (then_builders.get(&name), else_builders.get(&name)) {
                    return Some((name, self.merge_collection_builders(left, right)));
                }
                before.get(&name).cloned().map(|builder| (name, builder))
            })
            .collect()
    }

    fn merge_collection_builders(
        &self,
        left: &CollectionBuilder,
        right: &CollectionBuilder,
    ) -> CollectionBuilder {
        if left.kind != right.kind {
            let mut builder = self.collection_builder(CollectionBuilderKind::Unknown);
            builder.poisoned = true;
            return builder;
        }
        let mut builder = self.collection_builder(left.kind.clone());
        builder.types = left.types.union(&right.types).cloned().collect();
        builder.key_types = left.key_types.union(&right.key_types).cloned().collect();
        builder.value_types = left.value_types.union(&right.value_types).cloned().collect();
        builder.poisoned = left.poisoned || right.poisoned;
        builder
    }

    #[allow(dead_code)]
    fn dup_hash_shapes(&self, shapes: &BTreeMap<String, Value>) -> BTreeMap<String, Value> {
        clone_hash_shapes(shapes)
    }

    #[allow(dead_code)]
    fn dup_hash_shape(&self, shape: &Value) -> Value {
        clone_hash_shape(shape)
    }

    fn merge_branch_hash_shapes(
        &self,
        before: &BTreeMap<String, Value>,
        then_shapes: &BTreeMap<String, Value>,
        else_shapes: &BTreeMap<String, Value>,
    ) -> BTreeMap<String, Value> {
        let names = before
            .keys()
            .chain(then_shapes.keys())
            .chain(else_shapes.keys())
            .cloned()
            .collect::<BTreeSet<_>>();
        names
            .into_iter()
            .filter_map(|name| {
                if let (Some(left), Some(right)) = (then_shapes.get(&name), else_shapes.get(&name)) {
                    return Some((name, merge_hash_record_shapes(left.clone(), right.clone())));
                }
                before.get(&name).cloned().map(|shape| (name, shape))
            })
            .collect()
    }

    #[allow(dead_code)]
    fn merge_nested_hash_shape_maps(&self, left: &Value, right: &Value) -> Value {
        merge_hash_record_shapes(left.clone(), right.clone())
    }

    fn seed_param_hash_shapes(&self, record: &Value) -> BTreeMap<String, Value> {
        value_array(record.get("params"))
            .into_iter()
            .enumerate()
            .filter_map(|(idx, param)| {
                let name = param.get("name").and_then(Value::as_str)?;
                let shape = self.inferred_param_hash_shape(
                    record.get("method").and_then(Value::as_str).unwrap_or(""),
                    name,
                    idx,
                )?;
                (shape.get("poisoned").and_then(Value::as_bool) != Some(true))
                    .then(|| (name.to_string(), shape))
            })
            .collect()
    }

    fn seed_param_array_element_shapes(&self, record: &Value) -> BTreeMap<String, Value> {
        value_array(record.get("params"))
            .into_iter()
            .enumerate()
            .filter_map(|(idx, param)| {
                let name = param.get("name").and_then(Value::as_str)?;
                let shape = self.inferred_param_array_element_shape(
                    record.get("method").and_then(Value::as_str).unwrap_or(""),
                    name,
                    idx,
                )?;
                (shape.get("poisoned").and_then(Value::as_bool) != Some(true))
                    .then(|| (name.to_string(), shape))
            })
            .collect()
    }

    fn inferred_param_hash_shape(&self, method_name: &str, param_name: &str, idx: usize) -> Option<Value> {
        self.merge_inferred_param_shapes(&self.global.inferred_param_hash_shapes, method_name, param_name, idx)
    }

    fn inferred_param_array_element_shape(&self, method_name: &str, param_name: &str, idx: usize) -> Option<Value> {
        self.merge_inferred_param_shapes(
            &self.global.inferred_param_array_element_shapes,
            method_name,
            param_name,
            idx,
        )
    }

    fn merge_inferred_param_shapes(
        &self,
        index: &BTreeMap<(String, String, String), Value>,
        method_name: &str,
        param_name: &str,
        idx: usize,
    ) -> Option<Value> {
        let shapes = [
            index.get(&(method_name.to_string(), "positional".to_string(), idx.to_string())),
            index.get(&(method_name.to_string(), "keyword".to_string(), param_name.to_string())),
        ]
        .into_iter()
        .flatten()
        .cloned()
        .collect::<Vec<_>>();
        shapes.into_iter().reduce(merge_hash_record_shapes)
    }
}

fn collect_explicit_returns<'tree>(node: Node<'tree>, results: &mut Vec<Node<'tree>>) {
    if nested_scope_kind(node.kind()) {
        return;
    }
    if node.kind() == "return" || normalized_kind_by_raw(node) == NormKind::Return {
        let args = raw_return_args(node);
        results.push(args.first().copied().unwrap_or(node));
        return;
    }
    for child in named_children(node) {
        collect_explicit_returns(child, results);
    }
}

fn collection_builder_kind(kind: &str) -> CollectionBuilderKind {
    match kind {
        "array" => CollectionBuilderKind::Array,
        "hash" => CollectionBuilderKind::Hash,
        "set" => CollectionBuilderKind::Set,
        _ => CollectionBuilderKind::Unknown,
    }
}

fn core_rbi_return_type(method: &str, receiver_type: Option<&str>) -> Option<String> {
    let receiver_type = receiver_type.unwrap_or("");
    match (method, receiver_type) {
        (
            "empty?"
                | "any?"
                | "all?"
                | "none?"
                | "one?"
                | "include?"
                | "key?"
                | "has_key?"
                | "value?"
                | "has_value?"
                | "positive?"
                | "end_with?"
                | "start_with?"
                | "match?"
                | "!"
                | "!="
                | "equal?"
                | "==="
                | "frozen?"
                | "respond_to?"
                | "kind_of?"
                | "instance_of?",
            _,
        ) => Some("T::Boolean".to_string()),
        ("==" | "eql?", ty) if !ty.is_empty() => Some("T::Boolean".to_string()),
        ("each_with_object", _) => Some("T::Enumerator[[T.untyped, T.untyped]]".to_string()),
        ("each_index", _) => Some("T::Array[T.untyped]".to_string()),
        ("file?", _) => Some("T::Boolean".to_string()),
        ("line", _) => Some("Integer".to_string()),
        ("mktmpdir" | "realpath" | "message" | "strip" | "lstrip" | "rstrip" | "delete_prefix" | "delete_suffix" | "tr", _) => {
            Some("String".to_string())
        }
        ("pretty_generate", _) => Some("::String".to_string()),
        ("sort" | "uniq" | "sort_by", _) => Some("T::Array[T.untyped]".to_string()),
        ("[]", "String") => Some("T.nilable(String)".to_string()),
        ("split", "String") => Some("T::Array[String]".to_string()),
        ("join", ty) if array_receiver_type(ty) => Some("String".to_string()),
        ("+", ty) if array_receiver_type(ty) => Some("T::Array[T.any(T.untyped, T.untyped)]".to_string()),
        ("merge", _) => Some("T::Hash[T.any(T.untyped, T.untyped), T.any(T.untyped, T.untyped)]".to_string()),
        ("map" | "filter_map" | "select" | "reject", ty) if collection_receiver_type(ty) => {
            Some("T::Array[T.untyped]".to_string())
        }
        ("flat_map", ty) if collection_receiver_type(ty) => Some("T::Enumerator[T.untyped]".to_string()),
        ("compact", ty) if array_receiver_type(ty) => Some("T::Array[T.untyped]".to_string()),
        ("values", ty) if hash_receiver_type(ty) => Some("T::Array[T.untyped]".to_string()),
        ("fetch", ty) if array_receiver_type(ty) || hash_receiver_type(ty) => {
            Some("T.any(T.untyped, T.untyped)".to_string())
        }
        ("to_a", ty) if collection_receiver_type(ty) => Some("T::Array[T.untyped]".to_string()),
        ("to_h", ty) if collection_receiver_type(ty) => Some("T::Hash[T.untyped, T.untyped]".to_string()),
        ("to_s", _) => Some("String".to_string()),
        ("to_i", _) => Some("Integer".to_string()),
        ("to_f", _) => Some("Float".to_string()),
        ("to_sym", _) => Some("Symbol".to_string()),
        ("upcase" | "downcase" | "capitalize" | "swapcase", "String") => {
            Some("String".to_string())
        }
        ("lines" | "readlines", _) => Some("T::Array[String]".to_string()),
        ("to_set", _) => Some("T::Set[T.untyped]".to_string()),
        ("new", "Struct") => Some("Struct".to_string()),
        ("raise", _) => Some("T.noreturn".to_string()),
        ("run", _) => Some("Thread".to_string()),
        ("sub", "String") => Some("String".to_string()),
        ("nil?", _) => Some("T::Boolean".to_string()),
        ("bytes", "String") => Some("T::Array[Integer]".to_string()),
        ("*", "String") => Some("String".to_string()),
        ("expand_path", _) => Some("String".to_string()),
        ("ruby", _) => Some("String".to_string()),
        ("spawn", _) => Some("Integer".to_string()),
        ("sum", "String") => Some("Integer".to_string()),
        ("sum", ty) if collection_receiver_type(ty) => Some("T.all(T.untyped, Numeric)".to_string()),
        _ => None,
    }
}

fn merge_hash_record_shapes(left: Value, right: Value) -> Value {
    let mut out = json!({"keys": {}, "value_hash_shapes": {}, "value_array_element_shapes": {}, "poisoned": false});
    let poisoned = left.get("poisoned").and_then(Value::as_bool).unwrap_or(false)
        || right.get("poisoned").and_then(Value::as_bool).unwrap_or(false);
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

fn nilable_type(type_text: &str) -> String {
    if type_text == "NilClass" || type_text.starts_with("T.nilable(") {
        type_text.to_string()
    } else {
        format!("T.nilable({type_text})")
    }
}

fn empty_hash_shape() -> Value {
    json!({
        "keys": {},
        "value_hash_shapes": {},
        "value_array_element_shapes": {},
        "poisoned": false,
    })
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
        .filter(|child| !matches!(child.kind(), "comment" | "rescue" | "ensure"))
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
