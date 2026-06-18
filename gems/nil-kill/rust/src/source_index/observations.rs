impl<'a> FileIndexer<'a> {
    fn collect_type_normalizers(&mut self, body: Node<'_>, record: &Value, frame: &Frame) {
        let param_names = value_array(record.get("params"))
            .iter()
            .filter_map(|param| param.get("name").and_then(Value::as_str).map(ToString::to_string))
            .collect::<BTreeSet<_>>();
        let mut assigns = BTreeMap::<String, Node<'_>>::new();
        collect_assigns(body, self.file, &mut assigns);
        let mut visitor_frame = frame.clone();
        self.collect_type_normalizers_node(body, record, &param_names, &assigns, &mut visitor_frame);
    }

    fn collect_type_normalizers_node(
        &mut self,
        node: Node<'_>,
        record: &Value,
        param_names: &BTreeSet<String>,
        assigns: &BTreeMap<String, Node<'_>>,
        frame: &mut Frame,
    ) {
        if normalized_kind(node, self.file) == NormKind::Call
            && matches!(call_name(node, self.file).as_deref(), Some("is_a?" | "kind_of?"))
            && call_receiver(node, self.file).is_some()
        {
            let args = call_arguments(node, self.file);
            if args.len() == 1 && node_text(args[0], self.file) == "Type" {
                let (origin_kind, origin_name) =
                    self.classify_origin(call_receiver(node, self.file).unwrap(), param_names, assigns, 0, frame);
                self.facts.type_normalizers.push(json!({
                    "path": self.file.rel,
                    "line": line(node),
                    "class": record["class"],
                    "method": record["method"],
                    "code": node_text(node, self.file).lines().next().unwrap_or("").trim().chars().take(120).collect::<String>(),
                    "origin_kind": origin_kind,
                    "origin_name": origin_name,
                }));
            }
        }
        for child in named_children(node) {
            self.collect_type_normalizers_node(child, record, param_names, assigns, frame);
        }
    }

    fn collect_hidden_enum_observations(&mut self, body: Node<'_>, record: &Value) {
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
        node: Node<'_>,
        record: &Value,
        params: &BTreeMap<String, Value>,
    ) {
        match normalized_kind(node, self.file) {
            NormKind::Case => {
                if let Some(slot) = condition_node(node).and_then(|condition| self.hidden_enum_slot_for(condition, record, params)) {
                    let values = case_literal_values(node, self.file);
                    self.record_hidden_enum_observation(slot, values, node, "case");
                }
            }
            NormKind::Call => {
                let name = call_name(node, self.file).unwrap_or_default();
                if matches!(name.as_str(), "==" | "!=" | "===") {
                    let args = call_arguments(node, self.file);
                    if args.len() == 1 {
                        if let Some(slot) = call_receiver(node, self.file).and_then(|receiver| self.hidden_enum_slot_for(receiver, record, params)) {
                            self.record_hidden_enum_observation(slot, hidden_enum_literal_values(args[0], self.file), node, &name);
                        }
                        if let Some(slot) = self.hidden_enum_slot_for(args[0], record, params) {
                            if let Some(receiver) = call_receiver(node, self.file) {
                                self.record_hidden_enum_observation(slot, hidden_enum_literal_values(receiver, self.file), node, &name);
                            }
                        }
                    }
                } else if matches!(name.as_str(), "include?" | "member?" | "key?") {
                    let args = call_arguments(node, self.file);
                    if args.len() == 1 {
                        if let Some(slot) = self.hidden_enum_slot_for(args[0], record, params) {
                            if let Some(receiver) = call_receiver(node, self.file) {
                                self.record_hidden_enum_observation(slot, hidden_enum_literal_values(receiver, self.file), node, &name);
                            }
                        }
                    }
                }
            }
            _ => {}
        }
        for child in named_children(node) {
            self.collect_hidden_enum_observations_node(child, record, params);
        }
    }

    fn hidden_enum_slot_for(
        &self,
        node: Node<'_>,
        record: &Value,
        params: &BTreeMap<String, Value>,
    ) -> Option<Value> {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                let param = params.get(&name)?;
                let key = [
                    "param".to_string(),
                    record["path"].as_str().unwrap_or("").to_string(),
                    record["class"].as_str().unwrap_or("").to_string(),
                    record["kind"].as_str().unwrap_or("instance").to_string(),
                    record["method"].as_str().unwrap_or("").to_string(),
                    record["line"].as_i64().unwrap_or(0).to_string(),
                    name.clone(),
                ].join("\0");
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
            NormKind::IvarRead | NormKind::ClassVarRead => {
                let name = node_text(node, self.file);
                let key = [
                    "state".to_string(),
                    record["path"].as_str().unwrap_or("").to_string(),
                    record["class"].as_str().unwrap_or("").to_string(),
                    name.clone(),
                ].join("\0");
                Some(json!({
                    "key": key,
                    "kind": "state",
                    "path": record["path"],
                    "line": line(node),
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

    fn record_hidden_enum_observation(&mut self, slot: Value, values: Vec<Value>, site: Node<'_>, kind: &str) {
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
        object_insert(
            &mut obs,
            "site",
            json!({
                "path": self.file.rel,
                "line": line(site),
                "kind": kind,
                "code": first_line(&node_text(site, self.file)),
            }),
        );
        self.facts.hidden_enum_observations.push(obs);
    }

    fn classify_origin(
        &mut self,
        node: Node<'_>,
        param_names: &BTreeSet<String>,
        assigns: &BTreeMap<String, Node<'_>>,
        depth: usize,
        frame: &mut Frame,
    ) -> (String, Value) {
        match normalized_kind(node, self.file) {
            NormKind::IvarRead => ("ivar".to_string(), json!(node_text(node, self.file))),
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                if param_names.contains(&name) {
                    return ("param".to_string(), json!(name));
                }
                if depth == 0 {
                    if let Some(rhs) = assigns.get(&name) {
                        return self.classify_origin(*rhs, param_names, assigns, depth + 1, frame);
                    }
                }
                ("local".to_string(), Value::Null)
            }
            NormKind::Call => {
                let name = call_name(node, self.file).unwrap_or_default();
                if name == "[]" {
                    let key = call_arguments(node, self.file)
                        .first()
                        .and_then(|key| hash_key_name(*key, self.file))
                        .map(|key| format!(":{key}"));
                    ("hashkey".to_string(), key.map(Value::String).unwrap_or(Value::Null))
                } else if !call_arguments(node, self.file).is_empty() {
                    ("call".to_string(), json!(name))
                } else if call_receiver(node, self.file).is_some() {
                    ("attr".to_string(), json!(name))
                } else {
                    ("call".to_string(), json!(name))
                }
            }
            _ => ("local".to_string(), Value::Null),
        }
    }
}

fn each_ast(node: Node<'_>, f: &mut impl FnMut(Node<'_>)) {
    f(node);
    for child in named_children(node) {
        each_ast(child, f);
    }
}

fn collect_return_usage_sites(file: &SourceFile, facts: &mut FileFacts) {
    collect_return_usage_site_context(
        file.root_node(), file, "statement", None, None,
        &mut facts.return_usage_sites, &mut facts.rescue_handlers, false,
    );
    collect_return_usage_site_context(
        file.root_node(), file, "statement", None, None,
        &mut facts.return_direct_usage_sites, &mut facts.rescue_handlers, true,
    );
}

fn collect_return_usage_site_context(
    node: Node<'_>,
    file: &SourceFile,
    context: &str,
    current_method: Option<&str>,
    current_handler: Option<usize>,
    sites: &mut Vec<Value>,
    handlers: &mut Vec<Value>,
    direct_usage: bool,
) {
    if node.kind() == "argument_list" {
        let arg_context = if direct_usage { "return" } else { context };
        for child in named_children(node) {
            collect_return_usage_site_context(child, file, arg_context, current_method, current_handler, sites, handlers, direct_usage);
        }
        return;
    }

    match normalized_kind(node, file) {
        NormKind::Def => {
            let name = method_name(node, file);
            if let Some(body) = method_body(node) {
                collect_return_usage_site_context(body, file, "return", Some(name.as_str()), None, sites, handlers, direct_usage);
            }
        }
        NormKind::Program => {
            let body = statement_expressions(node);
            let last = body.len().saturating_sub(1);
            for (idx, child) in body.into_iter().enumerate() {
                let child_context = if idx == last { "value" } else { "statement" };
                collect_return_usage_site_context(child, file, child_context, current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        NormKind::Block => {
            if let Some(body) = node
                .child_by_field_name("body")
                .or_else(|| named_children(node).into_iter().find(|child| matches!(child.kind(), "body_statement" | "block_body")))
                .or_else(|| named_children(node).last().copied())
            {
                collect_return_usage_site_context(body, file, context, current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        NormKind::Statements => {
            let body = statement_expressions(node);
            let children = named_children(node);
            let handler_line = children
                .iter()
                .find(|child| child.kind() == "rescue")
                .map(|child| line(*child));
            if let Some(handler_line) = handler_line {
                handlers.push(json!({
                    "path": file.rel,
                    "line": handler_line,
                    "kind": "rescue",
                    "method": current_method,
                }));
            }
            let protected_handler = handler_line.or(current_handler);
            let last = body.len().saturating_sub(1);
            for (idx, child) in body.into_iter().enumerate() {
                let child_context = if idx == last { context } else { "statement" };
                collect_return_usage_site_context(child, file, child_context, current_method, protected_handler, sites, handlers, direct_usage);
            }
            for child in children {
                match child.kind() {
                    "rescue" => {
                        collect_return_usage_site_context(child, file, "statement", current_method, None, sites, handlers, direct_usage);
                    }
                    "else" => {
                        collect_return_usage_site_context(child, file, context, current_method, protected_handler, sites, handlers, direct_usage);
                    }
                    "ensure" => {
                        collect_return_usage_site_context(child, file, context, current_method, protected_handler, sites, handlers, direct_usage);
                    }
                    _ => {}
                }
            }
        }
        NormKind::Return => {
            for child in named_children(node) {
                collect_return_usage_site_context(child, file, "return", current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        NormKind::If | NormKind::Unless => {
            if let Some(condition) = condition_node(node) {
                collect_return_usage_site_context(condition, file, "value", current_method, current_handler, sites, handlers, direct_usage);
            }
            if let Some(consequent) = consequent_node(node) {
                collect_return_usage_site_context(consequent, file, context, current_method, current_handler, sites, handlers, direct_usage);
            }
            if let Some(alternative) = alternative_node(node) {
                collect_return_usage_site_context(alternative, file, context, current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        NormKind::Else => {
            let body = statement_expressions(node);
            let last = body.len().saturating_sub(1);
            for (idx, child) in body.into_iter().enumerate() {
                let child_context = if idx == last { context } else { "statement" };
                collect_return_usage_site_context(child, file, child_context, current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        NormKind::Begin => {
            let children = named_children(node);
            let handler_line = children
                .iter()
                .find(|child| child.kind() == "rescue")
                .map(|child| line(*child));
            if let Some(handler_line) = handler_line {
                handlers.push(json!({
                    "path": file.rel,
                    "line": handler_line,
                    "kind": "rescue",
                    "method": current_method,
                }));
            }
            let protected_handler = handler_line.or(current_handler);
            let body = statement_expressions(node);
            let last = body.len().saturating_sub(1);
            for (idx, child) in body.into_iter().enumerate() {
                let child_context = if idx == last { context } else { "statement" };
                collect_return_usage_site_context(child, file, child_context, current_method, protected_handler, sites, handlers, direct_usage);
            }
            for child in children {
                match child.kind() {
                    "rescue" => {
                        collect_return_usage_site_context(child, file, "statement", current_method, None, sites, handlers, direct_usage);
                    }
                    "else" => {
                        collect_return_usage_site_context(child, file, context, current_method, protected_handler, sites, handlers, direct_usage);
                    }
                    "ensure" => {
                        collect_return_usage_site_context(child, file, context, current_method, protected_handler, sites, handlers, direct_usage);
                    }
                    _ => {}
                }
            }
        }
        NormKind::Rescue => {
            for child in named_children(node) {
                if matches!(child.kind(), "body_statement" | "block_body" | "then") {
                    collect_return_usage_site_context(child, file, "statement", current_method, current_handler, sites, handlers, direct_usage);
                }
            }
        }
        _ if node.kind() == "operator_assignment"
            && !(assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference")
                && node_text(node, file).contains("||=")) =>
        {
            if node.kind() == "operator_assignment"
                && assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference")
            {
                if let Some(lhs) = assignment_lhs(node) {
                    collect_return_usage_site_context(lhs, file, context, current_method, current_handler, sites, handlers, direct_usage);
                }
            } else if let Some(value) = write_value(node) {
                collect_return_usage_site_context(value, file, context, current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        _ if unary_bang_condition_and_operand(node, file) => {
            sites.push(json!({
                "path": file.rel, "line": line(node), "name": "!",
                "context": context, "current_method": current_method,
                "handler_line": current_handler,
                "code": first_line(&node_text(node, file)),
            }));
        }
        _ if logical_and_condition_node(node, file) => {
            if let Some(name) = call_name(node, file).filter(|name| !name.is_empty()) {
                sites.push(json!({
                    "path": file.rel, "line": line(node), "name": name,
                    "context": context, "current_method": current_method,
                    "handler_line": current_handler,
                    "code": first_line(&node_text(node, file)),
                }));
            }
            if let Some(receiver) = call_receiver(node, file) {
                collect_return_usage_site_context(receiver, file, "value", current_method, current_handler, sites, handlers, direct_usage);
            }
            let arg_context = if direct_usage { "return" } else { "value" };
            for arg in call_arguments(node, file) {
                collect_return_usage_site_context(arg, file, arg_context, current_method, current_handler, sites, handlers, direct_usage);
            }
            if let Some(block) = call_block(node) {
                collect_return_usage_site_context(block, file, "value", current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        NormKind::Call => {
            if let Some(name) = call_name(node, file).filter(|name| !name.is_empty()) {
                sites.push(json!({
                    "path": file.rel, "line": line(node), "name": name,
                    "context": context, "current_method": current_method,
                    "handler_line": current_handler,
                    "code": first_line(&node_text(node, file)),
                }));
            }
            if let Some(receiver) = call_receiver(node, file) {
                collect_return_usage_site_context(receiver, file, "value", current_method, current_handler, sites, handlers, direct_usage);
            }
            let arg_context = if direct_usage { "return" } else { "value" };
            for arg in call_arguments(node, file) {
                collect_return_usage_site_context(arg, file, arg_context, current_method, current_handler, sites, handlers, direct_usage);
            }
            if let Some(block) = call_block(node) {
                collect_return_usage_site_context(block, file, "value", current_method, current_handler, sites, handlers, direct_usage);
            }
        }
        _ => {
            for child in named_children(node) {
                collect_return_usage_site_context(child, file, "value", current_method, current_handler, sites, handlers, direct_usage);
            }
        }
    }
}

fn collect_hash_record_escape_sites(file: &SourceFile, facts: &mut FileFacts) {
    each_ast(file.root_node(), &mut |node| {
        if normalized_kind(node, file) != NormKind::Hash {
            return;
        }
        let Some(reason) = hash_record_escape_reason(file.root_node(), node, file) else {
            return;
        };
        facts.hash_record_escape_sites.push(json!({
            "path": file.rel,
            "line": line(node),
            "code": node_text(node, file).trim().to_string(),
            "escapes_collection": true,
            "reason": reason,
        }));
    });
}

fn hash_record_escape_reason(root: Node<'_>, hash_node: Node<'_>, file: &SourceFile) -> Option<&'static str> {
    if hash_literal_in_array_literal(hash_node, file) {
        return Some("array_literal");
    }
    if value_in_collection_append_or_index_write(root, hash_node, file) {
        return Some("collection_append_or_index_write");
    }
    let writer = enclosing_local_write_for(hash_node, file)?;
    let name = write_name(writer, file)?;
    escape_uses_of_local(root, &name, file).then_some("local_alias_escape")
}

fn hash_literal_in_array_literal(mut node: Node<'_>, file: &SourceFile) -> bool {
    while let Some(parent) = node.parent() {
        if normalized_kind(parent, file) == NormKind::Array {
            return true;
        }
        node = parent;
    }
    false
}

fn value_in_collection_append_or_index_write(root: Node<'_>, target: Node<'_>, file: &SourceFile) -> bool {
    let mut found = false;
    walk_raw(root, &mut |node| {
        if found {
            return;
        }
        if normalized_kind(node, file) == NormKind::Call
            && call_name(node, file).is_some_and(|name| collection_append_method(&name))
            && call_arguments(node, file).into_iter().any(|arg| arg == target)
        {
            found = true;
            return;
        }
        if matches!(node.kind(), "assignment" | "operator_assignment")
            && assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference")
            && write_value(node) == Some(target)
        {
            found = true;
            return;
        }
        if normalized_kind(node, file) == NormKind::Call
            && call_name(node, file).as_deref() == Some("[]=")
            && call_arguments(node, file).last().copied() == Some(target)
        {
            found = true;
        }
    });
    found
}

fn enclosing_local_write_for<'tree>(hash_node: Node<'tree>, file: &SourceFile) -> Option<Node<'tree>> {
    let parent = hash_node.parent()?;
    if normalized_kind(parent, file) == NormKind::LocalWrite && write_value(parent) == Some(hash_node) {
        Some(parent)
    } else {
        None
    }
}

fn escape_uses_of_local(root: Node<'_>, name: &str, file: &SourceFile) -> bool {
    let mut escapes = false;
    walk_raw(root, &mut |node| {
        if escapes {
            return;
        }
        if normalized_kind(node, file) == NormKind::Call
            && call_arguments(node, file).into_iter().any(|arg| {
                normalized_kind(arg, file) == NormKind::LocalRead && node_text(arg, file) == name
            })
        {
            escapes = true;
            return;
        }
        if normalized_kind(node, file) == NormKind::Array
            && named_children(node).into_iter().any(|child| {
                normalized_kind(child, file) == NormKind::LocalRead && node_text(child, file) == name
            })
        {
            escapes = true;
        }
    });
    escapes
}

fn collection_append_method(name: &str) -> bool {
    matches!(name, "<<" | "push" | "unshift" | "append" | "prepend" | "concat")
}

#[allow(dead_code)]
fn each_node(node: Node<'_>, f: &mut impl FnMut(Node<'_>)) {
    each_ast(node, f);
}

#[allow(dead_code)]
fn node_contains(root: Node<'_>, target: Node<'_>) -> bool {
    let mut found = false;
    each_node(root, &mut |node| {
        if node == target {
            found = true;
        }
    });
    found
}

fn case_literal_values(case_node: Node<'_>, file: &SourceFile) -> Vec<Value> {
    named_children(case_node)
        .into_iter()
        .filter(|child| normalized_kind(*child, file) == NormKind::When)
        .flat_map(|when_node| {
            named_children(when_node)
                .into_iter()
                .take_while(|child| !matches!(child.kind(), "then" | "body_statement" | "block_body"))
                .flat_map(|condition| hidden_enum_literal_values(condition, file))
                .collect::<Vec<_>>()
        })
        .collect()
}

fn hidden_enum_literal_values(node: Node<'_>, file: &SourceFile) -> Vec<Value> {
    match normalized_kind(node, file) {
        NormKind::Symbol => hash_key_name(node, file)
            .map(|name| vec![json!({ "kind": "Symbol", "value": format!(":{name}") })])
            .unwrap_or_default(),
        NormKind::String => {
            if named_children(node).iter().any(|child| child.kind() == "interpolation") {
                Vec::new()
            } else {
                let value = serde_json::to_string(&unquote(&node_text(node, file))).unwrap_or_else(|_| "\"\"".to_string());
                vec![json!({ "kind": "String", "value": value })]
            }
        }
        NormKind::Array => named_children(node)
            .into_iter()
            .flat_map(|child| hidden_enum_literal_values(child, file))
            .collect(),
        NormKind::Parentheses => named_children(node)
            .into_iter()
            .flat_map(|child| hidden_enum_literal_values(child, file))
            .collect(),
        _ => Vec::new(),
    }
}

fn collect_assigns<'tree>(
    node: Node<'tree>,
    file: &SourceFile,
    assigns: &mut BTreeMap<String, Node<'tree>>,
) {
    if normalized_kind(node, file) == NormKind::LocalWrite {
        if let (Some(name), Some(value)) = (write_name(node, file), write_value(node)) {
            assigns.entry(name).or_insert(value);
        }
    }
    for child in named_children(node) {
        collect_assigns(child, file, assigns);
    }
}
