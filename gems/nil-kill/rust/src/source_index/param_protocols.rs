impl<'a> FileIndexer<'a> {
    fn inspect_param_origins(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let Some(callee) = call_name(node, self.file) else { return };
        let args = call_arguments(node, self.file);
        for (idx, arg) in args.iter().enumerate() {
            if normalized_kind(*arg, self.file) == NormKind::Pair {
                let Some(key) = pair_key(*arg).and_then(|key| hash_key_name(key, self.file)) else {
                    continue;
                };
                if let Some(value) = pair_value(*arg) {
                    let record = self.param_origin_record(node, value, &callee, "keyword", &key, state, frame);
                    self.facts.param_origins.push(record);
                }
            } else {
                let record = self.param_origin_record(
                    node,
                    *arg,
                    &callee,
                    "positional",
                    &idx.to_string(),
                    state,
                    frame,
                );
                self.facts.param_origins.push(record);
            }
        }
    }

    fn param_origin_record(
        &mut self,
        call_node: Node<'_>,
        arg: Node<'_>,
        callee: &str,
        kind: &str,
        slot: &str,
        state: &ScopeState,
        frame: &mut Frame,
    ) -> Value {
        let mut ty = self.expression_type(arg, frame);
        let mut origin_kind = if ty.is_some() { "static" } else { "unknown" }.to_string();
        let mut source_method = None::<String>;
        if normalized_kind(arg, self.file) == NormKind::Call {
            source_method = call_name(arg, self.file);
            if let Some(method) = source_method.as_deref() {
                if let Some(ret) = self.known_return_type(method, Some(arg), frame) {
                    ty = Some(ret);
                    origin_kind = "typed_return".to_string();
                } else if ty.as_deref().is_some_and(useful_type) {
                    origin_kind = "typed_return".to_string();
                } else {
                    origin_kind = "untyped_return".to_string();
                }
            }
        } else if normalized_kind(arg, self.file) == NormKind::LocalRead {
            origin_kind = "local".to_string();
        }
        json!({
            "path": self.file.rel,
            "line": line(call_node),
            "enclosing_scope": state.scope.join("::"),
            "callee": callee,
            "arg_kind": kind,
            "slot": slot,
            "origin_kind": origin_kind,
            "receiver": call_receiver(call_node, self.file).map(|receiver| const_name(Some(receiver), self.file)),
            "source_method": source_method,
            "type": ty,
            "code": node_text(arg, self.file),
            "hash_shape": self.hash_shape_for_value(arg, frame),
            "array_element_shape": self.array_element_shape_for_value(arg, frame),
            "unknown_reasons": if origin_kind == "unknown" { self.unknown_expression_reasons(arg, frame) } else { Vec::<String>::new() },
        })
    }

    fn param_protocols(&mut self, node: Node<'_>, source: &Value, frame: &mut Frame) -> Value {
        let params = value_array(source.get("params"));
        let names = params
            .iter()
            .filter_map(|param| param.get("name").and_then(Value::as_str).map(ToString::to_string))
            .collect::<BTreeSet<_>>();
        let mut protocols = names
            .iter()
            .map(|name| (name.clone(), Protocol::default()))
            .collect::<BTreeMap<_, _>>();
        if let Some(body) = method_body(node) {
            self.collect_protocols(body, &names, &mut protocols, frame);
        }
        let mut out = Map::new();
        for (name, protocol) in protocols {
            out.insert(
                name,
                json!({
                    "methods": protocol.methods.into_iter().collect::<Vec<_>>(),
                    "aliases": protocol.aliases.into_iter().collect::<Vec<_>>(),
                    "gaps": protocol.gaps.into_iter().collect::<Vec<_>>(),
                }),
            );
        }
        Value::Object(out)
    }

    fn collect_protocols(
        &mut self,
        node: Node<'_>,
        names: &BTreeSet<String>,
        protocols: &mut BTreeMap<String, Protocol>,
        frame: &mut Frame,
    ) {
        match normalized_kind(node, self.file) {
            NormKind::Call => {
                if let Some(receiver) = call_receiver(node, self.file) {
                    if normalized_kind(receiver, self.file) == NormKind::LocalRead {
                        let receiver_name = node_text(receiver, self.file);
                        if let Some(protocol) = protocols.get_mut(&receiver_name) {
                            if let Some(name) = call_name(node, self.file) {
                                protocol.methods.insert(name);
                            }
                        }
                    }
                    if normalized_kind(receiver, self.file) == NormKind::IvarRead {
                        if let (Some(class), Some(name)) = (frame.current_class.as_ref(), call_name(node, self.file)) {
                            let key = format!("{class}\0{}", node_text(receiver, self.file));
                            let entry = self.facts.ivar_protocols.entry(key).or_default();
                            if !entry.contains(&name) {
                                entry.push(name);
                                entry.sort();
                            }
                        }
                    }
                }
                for (slot, arg) in call_arguments(node, self.file).iter().enumerate() {
                    if normalized_kind(*arg, self.file) == NormKind::LocalRead {
                        let name = node_text(*arg, self.file);
                        if let Some(protocol) = protocols.get_mut(&name) {
                            let callee = call_name(node, self.file).unwrap_or_default();
                            protocol.gaps.insert(format!(
                                "forwarded to {callee} slot {slot} at {}:{}",
                                self.file.rel,
                                line(node)
                            ));
                        }
                    }
                }
            }
            NormKind::LocalWrite => {
                if let Some(source) = write_value(node).and_then(|value| unwrap_alias_source(value, self.file)) {
                    if names.contains(&source) {
                        if let Some(protocol) = protocols.get_mut(&source) {
                            protocol.aliases.insert(format!(
                                "{} at {}:{}",
                                write_name(node, self.file).unwrap_or_default(),
                                self.file.rel,
                                line(node)
                            ));
                        }
                    }
                }
            }
            NormKind::IvarWrite => {
                if let Some(source) = write_value(node).and_then(|value| unwrap_alias_source(value, self.file)) {
                    if names.contains(&source) {
                        let ivar = write_name(node, self.file).unwrap_or_default();
                        if let Some(protocol) = protocols.get_mut(&source) {
                            protocol.gaps.insert(format!("captured in {ivar} at {}:{}", self.file.rel, line(node)));
                        }
                        if let Some(class) = frame.current_class.as_ref() {
                            let key = format!("{class}\0{ivar}");
                            let entry = self.facts.ivar_param_origins.entry(key).or_default();
                            if !entry.contains(&source) {
                                entry.push(source);
                                entry.sort();
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        for child in named_children(node) {
            self.collect_protocols(child, names, protocols, frame);
        }
    }

    fn inspect_call(&mut self, node: Node<'_>, frame: &mut Frame) {
        let name = call_name(node, self.file).unwrap_or_default();
        let receiver = call_receiver(node, self.file);
        let receiver_text = receiver.map(|receiver| node_text(receiver, self.file));
        if name == "let" && receiver_text.as_deref() == Some("T") {
            let args = call_arguments(node, self.file);
            self.facts.tlet_sites.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "tlet": true,
                "type": args.get(1).map(|arg| node_text(*arg, self.file)),
            }));
        } else if safe_navigation(node) {
            if let Some(receiver) = receiver {
                if self.provably_non_nil(receiver, frame) {
                    self.facts.dead_nil_checks.push(json!({
                        "path": self.file.rel,
                        "line": line(node),
                        "kind": "safe_nav",
                        "code": node_text(node, self.file),
                        "reason": format!("{} is provably non-nil", node_text(receiver, self.file)),
                    }));
                }
            }
        } else if name == "nil?" {
            if let Some(receiver) = receiver {
                if self.provably_non_nil(receiver, frame) {
                    self.facts.dead_nil_checks.push(json!({
                        "path": self.file.rel,
                        "line": line(node),
                        "kind": "nil_check",
                        "code": node_text(node, self.file),
                        "reason": format!("{} is provably non-nil; .nil? is always false", node_text(receiver, self.file)),
                    }));
                }
            }
        }
    }

    fn unknown_expression_reasons(&mut self, node: Node<'_>, frame: &mut Frame) -> Vec<String> {
        let mut reasons = BTreeSet::new();
        self.collect_unknown_expression_reasons(node, frame, &mut reasons);
        reasons.into_iter().collect()
    }

    fn collect_unknown_expression_reasons(
        &mut self,
        node: Node<'_>,
        frame: &mut Frame,
        reasons: &mut BTreeSet<String>,
    ) {
        match normalized_kind(node, self.file) {
            NormKind::IvarRead | NormKind::IvarWrite => {
                reasons.insert(format!("instance variable {}", node_text(node, self.file)));
            }
            NormKind::ClassVarRead | NormKind::ClassVarWrite => {
                reasons.insert(format!("class variable {}", node_text(node, self.file)));
            }
            NormKind::GlobalVarRead | NormKind::GlobalVarWrite => {
                reasons.insert(format!("global variable {}", node_text(node, self.file)));
            }
            NormKind::LocalRead => {
                reasons.insert(format!("local variable {}", node_text(node, self.file)));
            }
            NormKind::ConstRead | NormKind::ConstPath => {
                if let Some(ty) = self.constant_expression_type(node) {
                    reasons.insert(format!("literal/static expression {}", static_expression_reason(&ty)));
                } else {
                    reasons.insert(format!("operation unresolved constant {}", node_text(node, self.file)));
                }
                return;
            }
            NormKind::Array => {
                reasons.insert("struct/array/collection value Array".to_string());
                return;
            }
            NormKind::Hash | NormKind::KeywordHash => {
                reasons.insert("struct/array/collection value Hash".to_string());
                return;
            }
            NormKind::Call => {
                if let Some(ty) = self.expression_type(node, frame) {
                    reasons.insert(format!("literal/static expression {}", static_expression_reason(&ty)));
                    return;
                }
                if let Some(name) = call_name(node, self.file) {
                    if self.known_return_type(&name, Some(node), frame).is_none() {
                        reasons.insert(format!("forwarded return {name}"));
                        if let Some(receiver) = call_receiver(node, self.file) {
                            self.collect_unknown_expression_reasons(receiver, frame, reasons);
                        }
                        return;
                    }
                }
            }
            _ => {
                if let Some(ty) = literal_type(node, self.file) {
                    reasons.insert(format!("literal/static expression {}", static_expression_reason(&ty)));
                    return;
                }
                reasons.insert(format!("operation {}", debug_node_name(normalized_kind(node, self.file))));
            }
        }
        for child in named_children(node) {
            self.collect_unknown_expression_reasons(child, frame, reasons);
        }
    }
}

#[derive(Default)]
struct Protocol {
    methods: BTreeSet<String>,
    aliases: BTreeSet<String>,
    gaps: BTreeSet<String>,
}

fn params(node: Node<'_>, sig: Option<&str>, file: &SourceFile) -> Vec<Value> {
    let sig_types = extract_param_entries(sig.unwrap_or(""))
        .into_iter()
        .collect::<BTreeMap<_, _>>();
    let Some(parameters) = node.child_by_field_name("parameters") else {
        return Vec::new();
    };
    named_children(parameters)
        .into_iter()
        .filter_map(|param| {
            if matches!(param.kind(), "splat_parameter" | "hash_splat_parameter" | "block_parameter") {
                return None;
            }
            let name = parameter_name(param, file)?;
            Some(json!({
                "name": name,
                "nil_default": parameter_value(param).is_some_and(|value| normalized_kind(value, file) == NormKind::Nil),
                "type": sig_types.get(&name).cloned(),
            }))
        })
        .collect()
}

fn untraceable_param_names(node: Node<'_>, file: &SourceFile) -> Vec<String> {
    let Some(parameters) = node.child_by_field_name("parameters") else {
        return Vec::new();
    };
    named_children(parameters)
        .into_iter()
        .filter(|param| matches!(param.kind(), "splat_parameter" | "hash_splat_parameter" | "block_parameter"))
        .filter_map(|param| parameter_name(param, file))
        .collect()
}

fn parameter_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    node.child_by_field_name("name")
        .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "identifier"))
        .or_else(|| (node.kind() == "identifier").then_some(node))
        .map(|child| node_text(child, file))
}

fn parameter_value(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("value").or_else(|| {
        let name = node.child_by_field_name("name");
        named_children(node)
            .into_iter()
            .find(|child| Some(*child) != name && child.kind() != "identifier")
    })
}

fn sig_above(lines: &[String], line: usize) -> Option<String> {
    if line < 2 {
        return None;
    }
    let mut idx = line as isize - 2;
    while idx >= 0 && lines.get(idx as usize).map(|line| line.trim().is_empty()).unwrap_or(false) {
        idx -= 1;
    }
    if idx < 0 {
        return None;
    }
    let stripped = lines[idx as usize].trim();
    if contains_sig_brace(stripped) {
        return Some(stripped.to_string());
    }
    if stripped == "end" {
        let floor = (idx - 40).max(0);
        let mut start = idx;
        while start >= floor {
            let current = lines[start as usize].as_str();
            if current.contains("sig do") {
                return Some(lines[start as usize..=idx as usize].join("\n"));
            }
            if current.trim_start().starts_with("def ")
                || current.trim_start().starts_with("class ")
                || current.trim_start().starts_with("module ")
            {
                break;
            }
            start -= 1;
        }
    }
    None
}

fn contains_sig_brace(line: &str) -> bool {
    line.contains("sig") && line.contains('{')
}

fn extract_param_entries(sig: &str) -> Vec<(String, String)> {
    let Some(params) = extract_call_args(sig, "params") else {
        return Vec::new();
    };
    split_top_level(&params)
        .into_iter()
        .filter_map(|entry| {
            let (name, ty) = entry.split_once(':')?;
            Some((name.trim().to_string(), ty.trim().to_string()))
        })
        .collect()
}

fn extract_return_type(sig: &str) -> Option<String> {
    extract_call_args(sig, "returns")
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

fn split_top_level(source: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut start = 0usize;
    let mut depth = 0i32;
    for (idx, ch) in source.char_indices() {
        match ch {
            '(' | '[' | '{' => depth += 1,
            ')' | ']' | '}' => depth -= 1,
            ',' if depth == 0 => {
                let part = source[start..idx].trim();
                if !part.is_empty() {
                    parts.push(part.to_string());
                }
                start = idx + 1;
            }
            _ => {}
        }
    }
    let tail = source[start..].trim();
    if !tail.is_empty() {
        parts.push(tail.to_string());
    }
    parts
}

fn non_nil_sig_params(sig: Option<&str>) -> Vec<String> {
    let Some(sig) = sig else { return Vec::new() };
    let Some(params) = extract_call_args(sig, "params") else {
        return Vec::new();
    };
    split_top_level(&params)
        .into_iter()
        .filter_map(|entry| {
            let (name, ty) = entry.split_once(':')?;
            let ty = ty.trim();
            (!ty.contains("T.nilable") && ty != "T.untyped" && ty != "NilClass").then(|| name.trim().to_string())
        })
        .collect()
}

fn non_nil_return_sig(sig: &str) -> bool {
    extract_return_type(sig).is_some_and(|ty| {
        !ty.contains("T.nilable") && ty != "T.untyped" && ty != "NilClass"
    })
}

fn unwrap_alias_source(node: Node<'_>, file: &SourceFile) -> Option<String> {
    if normalized_kind(node, file) == NormKind::LocalRead {
        return Some(node_text(node, file));
    }
    if normalized_kind(node, file) == NormKind::Call
        && call_receiver(node, file).map(|receiver| node_text(receiver, file)) == Some("T".to_string())
        && matches!(call_name(node, file).as_deref(), Some("must" | "cast" | "let"))
    {
        return call_arguments(node, file)
            .first()
            .and_then(|arg| unwrap_alias_source(*arg, file));
    }
    None
}
