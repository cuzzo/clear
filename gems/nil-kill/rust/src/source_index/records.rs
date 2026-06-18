impl<'a> FileIndexer<'a> {
    fn inspect_array_literal(&mut self, node: Node<'_>, frame: &mut Frame) {
        let elements = array_elements(node);
        if elements.len() < 2 || elements.iter().any(|elem| elem.kind() == "splat_argument") {
            return;
        }
        let types = elements
            .iter()
            .map(|elem| self.expression_type(*elem, frame))
            .collect::<Vec<_>>();
        if types.iter().any(Option::is_none) {
            return;
        }
        let values = types.into_iter().flatten().collect::<Vec<_>>();
        let unique = values.iter().collect::<BTreeSet<_>>();
        if unique.len() < 2 {
            return;
        }
        self.facts.tuple_arrays.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "size": values.len(),
            "types": values,
            "confidence": "high",
            "code": node_text(node, self.file),
        }));
    }

    fn inspect_hash_literal(&mut self, node: Node<'_>, frame: &mut Frame) {
        let pairs = hash_pairs(node);
        if pairs.is_empty() {
            return;
        }
        let mut keys = Vec::new();
        let mut values = Vec::new();
        let mut value_hash_shapes = Map::new();
        let mut value_array_shapes = Map::new();
        for pair in pairs {
            let Some(key_node) = pair_key(pair) else { continue };
            let Some(value_node) = pair_value(pair) else { continue };
            let Some(key) = hash_key_name(key_node, self.file) else { continue };
            keys.push(key.clone());
            values.push(self.expression_type(value_node, frame).map(Value::String).unwrap_or(Value::Null));
            if let Some(shape) = self.hash_shape_for_value(value_node, frame) {
                value_hash_shapes.insert(key.clone(), shape);
            }
            if let Some(shape) = self.array_element_shape_for_value(value_node, frame) {
                value_array_shapes.insert(key, shape);
            }
        }
        if keys.len() < 2 || keys.len() != hash_pairs(node).len() {
            return;
        }
        self.facts.hash_shapes.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "keys": keys,
            "value_types": values,
            "value_hash_shapes": value_hash_shapes,
            "value_array_element_shapes": value_array_shapes,
            "code": node_text(node, self.file),
        }));
    }

    fn inspect_local_container_origin(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        if let Some(value) = write_value(node) {
            if let Some(origin) = self.container_origin_for_value(value, &name, frame) {
                frame.local_container_origins.insert(name, origin);
            } else {
                frame.local_container_origins.remove(&name);
            }
        }
    }

    fn inspect_ivar_container_origin(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        if let Some(value) = write_value(node) {
            if let Some(origin) = self.container_origin_for_value(value, &name, frame) {
                frame.ivar_container_origins.insert(name, origin);
            }
        }
    }

    fn container_origin_for_value(&mut self, value: Node<'_>, name: &str, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(value, self.file) {
            NormKind::Array => {
                let types = array_elements(value)
                    .into_iter()
                    .filter_map(|elem| self.expression_type(elem, frame))
                    .collect::<BTreeSet<_>>()
                    .into_iter()
                    .collect::<Vec<_>>();
                Some(json!({"kind": "array literal", "name": name, "path": self.file.rel, "line": line(value), "code": node_text(value, self.file), "array_element_types": types}))
            }
            NormKind::Hash | NormKind::KeywordHash => {
                let mut key_types = BTreeSet::new();
                let mut value_types = BTreeSet::new();
                for pair in hash_pairs(value) {
                    if let Some(key) = pair_key(pair) {
                        if let Some(ty) = self.expression_type(key, frame) {
                            key_types.insert(ty);
                        }
                    }
                    if let Some(val) = pair_value(pair) {
                        if let Some(ty) = self.expression_type(val, frame) {
                            value_types.insert(ty);
                        }
                    }
                }
                Some(json!({"kind": "hash literal", "name": name, "path": self.file.rel, "line": line(value), "code": node_text(value, self.file), "hash_key_types": key_types.into_iter().collect::<Vec<_>>(), "hash_value_types": value_types.into_iter().collect::<Vec<_>>() }))
            }
            NormKind::LocalRead => frame
                .local_container_origins
                .get(&node_text(value, self.file))
                .map(|origin| merge_value(origin, &[("name", json!(name)), ("alias_of", json!(node_text(value, self.file)))])),
            NormKind::IvarRead | NormKind::ClassVarRead | NormKind::GlobalVarRead => frame
                .ivar_container_origins
                .get(&node_text(value, self.file))
                .map(|origin| merge_value(origin, &[("name", json!(name)), ("alias_of", json!(node_text(value, self.file)))])),
            NormKind::Call => Some(json!({
                "kind": "forwarded return",
                "name": name,
                "path": self.file.rel,
                "line": line(value),
                "code": node_text(value, self.file),
                "callee": call_name(value, self.file).unwrap_or_default(),
            })),
            _ => None,
        }
    }

    fn inspect_index_lookup(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let name = call_name(node, self.file).unwrap_or_default();
        if name != "[]" && name != "fetch" {
            return;
        }
        let Some(receiver) = call_receiver(node, self.file) else { return };
        if sorbet_type_index_syntax(&node_text(receiver, self.file)) {
            return;
        }
        let args = call_arguments(node, self.file);
        if args.is_empty() || (name == "fetch" && args.len() > 1) {
            return;
        }
        let receiver_type = self.expression_type(receiver, frame);
        let lookup_type = self.collection_index_return_type(node, receiver_type.as_deref(), frame);
        let index_type = self.expression_type(args[0], frame);
        let origin = self.receiver_collection_origin(receiver, frame);
        self.facts.collection_index_lookups.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "enclosing_scope": state.scope.join("::"),
            "code": node_text(node, self.file),
            "receiver": node_text(receiver, self.file),
            "index": node_text(args[0], self.file),
            "receiver_type": receiver_type,
            "index_type": index_type,
            "lookup_type": lookup_type,
            "status": collection_index_status(receiver_type.as_deref(), lookup_type.as_deref()),
            "origin": origin,
        }));
    }

    fn inspect_hash_record_blocker(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let name = call_name(node, self.file).unwrap_or_default();
        let args = call_arguments(node, self.file);
        if name == "[]" || name == "fetch" {
            if name == "fetch" && args.len() > 1 {
                return;
            }
            if args.is_empty() || hash_key_name(args[0], self.file).is_some() {
                return;
            }
            let origin = self.hash_record_blocker_origin_for_receiver(receiver, frame);
            if !hash_record_blocker_origin(&origin) {
                return;
            }
            self.facts.hash_record_blockers.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "enclosing_scope": state.scope.join("::"),
                "kind": "dynamic_key",
                "code": node_text(node, self.file),
                "receiver": node_text(receiver, self.file),
                "index": args.first().map(|arg| node_text(*arg, self.file)),
                "origin": origin,
                "message": "dynamic hash-record key prevents struct accessor rewrite",
            }));
        } else if matches!(name.as_str(), "[]=" | "merge!" | "update" | "delete" | "clear" | "shift") {
            let origin = self.hash_record_blocker_origin_for_receiver(receiver, frame);
            if !hash_record_blocker_origin(&origin) {
                return;
            }
            self.facts.hash_record_blockers.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "enclosing_scope": state.scope.join("::"),
                "kind": "mutation",
                "code": node_text(node, self.file),
                "receiver": node_text(receiver, self.file),
                "origin": origin,
                "message": "shape-changing hash-record mutation prevents broad struct rewrite",
            }));
        }
    }

    fn inspect_hash_record_member_call(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let receiver_name = call_name(receiver, self.file).unwrap_or_default();
        if receiver_name != "[]" && receiver_name != "fetch" {
            return;
        }
        let args = call_arguments(receiver, self.file);
        if receiver_name == "fetch" && args.len() > 1 {
            return;
        }
        let Some(key) = args.first().and_then(|arg| hash_key_name(*arg, self.file)) else {
            return;
        };
        let Some(inner_receiver) = call_receiver(receiver, self.file) else { return };
        let origin = self.receiver_collection_origin(inner_receiver, frame);
        if !hash_record_blocker_origin(&origin)
            && origin.get("kind").and_then(Value::as_str) != Some("local hash shape")
        {
            return;
        }
        self.facts.hash_record_member_calls.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "enclosing_scope": state.scope.join("::"),
            "field": key,
            "member": call_name(node, self.file).unwrap_or_default(),
            "code": node_text(node, self.file),
            "lookup_code": node_text(receiver, self.file),
            "receiver": node_text(inner_receiver, self.file),
            "origin": origin,
        }));
    }

    fn hash_record_blocker_origin_for_receiver(&mut self, receiver: Node<'_>, frame: &mut Frame) -> Value {
        let origin = self.receiver_collection_origin(receiver, frame);
        if hash_record_blocker_origin(&origin) {
            return origin;
        }
        if normalized_kind(receiver, self.file) == NormKind::LocalRead {
            let name = node_text(receiver, self.file);
            if let Some(shape) = frame.hash_shapes.get(&name) {
                return json!({"kind": "local hash shape", "name": name, "path": self.file.rel, "line": line(receiver), "shape": shape});
            }
        }
        origin
    }

    fn receiver_collection_origin(&mut self, node: Node<'_>, frame: &mut Frame) -> Value {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                if let Some(origin) = frame.local_container_origins.get(&name) {
                    if origin.get("kind").and_then(Value::as_str) == Some("method parameter") {
                        if let Some(shape) = frame.hash_shapes.get(&name) {
                            return merge_value(origin, &[("shape", shape.clone())]);
                        }
                    }
                    return origin.clone();
                }
                if let Some(source) = frame.hash_shape_sources.get(&name) {
                    let mut v = source.clone();
                    if let Some(obj) = v.as_object_mut() {
                        obj.insert("receiver".into(), Value::String(name.clone()));
                        if let Some(shape) = frame.hash_shapes.get(&name) {
                            obj.insert("shape".into(), shape.clone());
                        }
                    }
                    return v;
                }
                if let Some(shape) = frame.hash_shapes.get(&name) {
                    return json!({"kind": "local hash shape", "name": name, "path": self.file.rel, "line": line(node), "shape": shape});
                }
                json!({"kind": "local variable", "name": name})
            }
            NormKind::IvarRead | NormKind::ClassVarRead | NormKind::GlobalVarRead => {
                let name = node_text(node, self.file);
                frame.ivar_container_origins.get(&name).cloned().unwrap_or_else(|| {
                    json!({"kind": "instance variable", "name": name})
                })
            }
            NormKind::Array | NormKind::Hash | NormKind::KeywordHash => self
                .container_origin_for_value(node, "literal", frame)
                .unwrap_or_else(|| json!({"kind": debug_node_name(normalized_kind(node, self.file)), "code": node_text(node, self.file)})),
            NormKind::Call => {
                if let Some(shape) = self.hash_shape_for_receiver(node, frame) {
                    json!({"kind": "local hash shape", "name": node_text(node, self.file), "path": self.file.rel, "line": line(node), "shape": shape})
                } else {
                    json!({"kind": "forwarded return", "callee": call_name(node, self.file).unwrap_or_default(), "path": self.file.rel, "line": line(node), "code": node_text(node, self.file)})
                }
            }
            _ => json!({"kind": debug_node_name(normalized_kind(node, self.file)), "code": node_text(node, self.file)}),
        }
    }

    fn collection_index_return_type(
        &mut self,
        node: Node<'_>,
        receiver_type: Option<&str>,
        frame: &mut Frame,
    ) -> Option<String> {
        let args = call_arguments(node, self.file);
        if args.len() != 1 {
            return None;
        }
        if let Some(shape_type) = self.hash_shape_index_return_type(call_receiver(node, self.file), args[0], frame) {
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
                if normalized_kind(args[0], self.file) == NormKind::Range {
                    Some(format!("T::Array[{elem}]"))
                } else if self.expression_type(args[0], frame).as_deref() == Some("Integer") {
                    Some(nilable_type(&elem))
                } else {
                    None
                }
            }
            "hash" => {
                let value = info.value?;
                if value.is_empty() || value.contains("T.untyped") {
                    None
                } else {
                    Some(nilable_type(&value))
                }
            }
            _ => None,
        }
    }

    fn hash_shape_index_return_type(
        &mut self,
        receiver: Option<Node<'_>>,
        index: Node<'_>,
        frame: &mut Frame,
    ) -> Option<String> {
        let shape = self.hash_shape_for_receiver(receiver?, frame)?;
        if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
            return None;
        }
        let key = hash_key_name(index, self.file)?;
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
        useful_type(&value).then(|| nilable_type(&value))
    }

    fn inspect_struct_constructor(&mut self, node: Node<'_>, frame: &mut Frame) {
        if call_name(node, self.file).as_deref() != Some("new") {
            return;
        }
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let klass = const_name(Some(receiver), self.file);
        let fields = self
            .global
            .struct_fields_by_name
            .get(&klass)
            .or_else(|| self.global.struct_fields_by_name.get(klass.rsplit("::").next().unwrap_or("")))
            .cloned();
        let Some(fields) = fields else { return };
        let full_class = self
            .global
            .struct_full_by_name
            .get(&klass)
            .or_else(|| self.global.struct_full_by_name.get(klass.rsplit("::").next().unwrap_or("")))
            .cloned()
            .unwrap_or(klass);
        for (idx, arg) in call_arguments(node, self.file).iter().enumerate() {
            if idx >= fields.len()
                || matches!(normalized_kind(*arg, self.file), NormKind::KeywordHash | NormKind::Pair)
            {
                continue;
            }
            let ty = self.expression_type(*arg, frame);
            self.facts.struct_field_static.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "class": full_class,
                "field": fields[idx],
                "type": ty,
                "expression": node_text(*arg, self.file),
            }));
        }
    }

    fn inspect_struct_declaration(&mut self, node: Node<'_>, state: &ScopeState) {
        let Some(value) = write_value(node) else { return };
        if !(struct_new_call(value, self.file) || data_define_call(value, self.file)) {
            return;
        }
        let Some(name) = write_name(node, self.file) else { return };
        let class = if state.scope.is_empty() {
            name
        } else {
            format!("{}::{name}", state.scope.join("::"))
        };
        let fields = struct_fields(value, self.file);
        if fields.is_empty() {
            return;
        }
        self.facts.struct_declarations.push(json!({
            "path": self.file.rel,
            "line": line(node),
            "class": class,
            "fields": fields,
        }));
    }

    fn inspect_class_constructor_fields(&mut self, node: Node<'_>, frame: &mut Frame) {
        if call_name(node, self.file).as_deref() != Some("new") {
            return;
        }
        let Some(receiver) = call_receiver(node, self.file) else { return };
        let klass = const_name(Some(receiver), self.file);
        if klass.is_empty() || klass == "Struct" {
            return;
        }
        for arg in call_arguments(node, self.file) {
            if normalized_kind(arg, self.file) == NormKind::Pair {
                if let Some(value) = pair_value(arg) {
                    let _ = self.expression_type(value, frame);
                }
            }
        }
    }

    fn inspect_attribute_shape_write(&mut self, _node: Node<'_>, _frame: &mut Frame) {}

    fn inspect_dispatcher(&mut self, node: Node<'_>, record: &Value) {
        let params = value_array(record.get("params"));
        let Some(param) = params.first().and_then(|param| param.get("name")).and_then(Value::as_str) else {
            return;
        };
        let mut arms = Vec::new();
        if let Some(body) = method_body(node) {
            collect_dispatch_arms(body, param, self.file, &mut arms);
        }
        let mut grouped = BTreeMap::<String, BTreeSet<String>>::new();
        for (helper, classes) in arms {
            grouped.entry(helper).or_default().extend(classes);
        }
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
            self.facts.dispatcher_inferences.push(json!({
                "path": self.file.rel,
                "line": record["line"],
                "class": record["class"],
                "kind": record["kind"],
                "dispatcher": record["method"],
                "helper": helper,
                "type": ty,
                "classes": classes_vec,
            }));
        }
    }
}

fn collect_dispatch_arms(
    node: Node<'_>,
    param_name: &str,
    file: &SourceFile,
    arms: &mut Vec<(String, Vec<String>)>,
) {
    if normalized_kind(node, file) == NormKind::Case {
        for child in named_children(node) {
            if normalized_kind(child, file) != NormKind::When {
                continue;
            }
            let helper = dispatch_helper_call(child, param_name, file);
            if let Some(helper) = helper {
                let classes = named_children(child)
                    .into_iter()
                    .filter(|candidate| normalized_kind(*candidate, file) != NormKind::Statements)
                    .filter_map(|candidate| {
                        let name = const_name(Some(candidate), file);
                        (!name.is_empty()).then_some(name)
                    })
                    .collect::<Vec<_>>();
                if !classes.is_empty() {
                    arms.push((helper, classes));
                }
            }
        }
    }
    for child in named_children(node) {
        collect_dispatch_arms(child, param_name, file, arms);
    }
}

fn dispatch_helper_call(when_node: Node<'_>, param_name: &str, file: &SourceFile) -> Option<String> {
    let body = consequent_node(when_node)?;
    let body_exprs = statement_expressions(body);
    if body_exprs.len() != 1 {
        return None;
    }
    let call = body_exprs[0];
    if normalized_kind(call, file) != NormKind::Call || call_receiver(call, file).is_some() {
        return None;
    }
    let args = call_arguments(call, file);
    if args.len() != 1 || normalized_kind(args[0], file) != NormKind::LocalRead || node_text(args[0], file) != param_name {
        return None;
    }
    call_name(call, file)
}

fn pair_key(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("key").or_else(|| named_children(node).first().copied())
}

fn pair_value(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("value")
        .or_else(|| named_children(node).get(1).copied())
}

fn hash_pairs(node: Node<'_>) -> Vec<Node<'_>> {
    named_children(node)
        .into_iter()
        .filter(|child| child.kind() == "pair")
        .collect()
}

fn array_elements(node: Node<'_>) -> Vec<Node<'_>> {
    named_children(node)
}

fn hash_key_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    match normalized_kind(node, file) {
        NormKind::Symbol => {
            let text = node_text(node, file);
            Some(
                text.trim()
                    .trim_start_matches(':')
                    .trim_end_matches(':')
                    .to_string(),
            )
        }
        NormKind::String => Some(unquote(&node_text(node, file))),
        _ => None,
    }
}

fn struct_new_call(node: Node<'_>, file: &SourceFile) -> bool {
    normalized_kind(node, file) == NormKind::Call
        && call_name(node, file).as_deref() == Some("new")
        && call_receiver(node, file).map(|receiver| node_text(receiver, file)) == Some("Struct".to_string())
}

fn data_define_call(node: Node<'_>, file: &SourceFile) -> bool {
    normalized_kind(node, file) == NormKind::Call
        && call_name(node, file).as_deref() == Some("define")
        && call_receiver(node, file).map(|receiver| node_text(receiver, file)) == Some("Data".to_string())
}

fn struct_fields(node: Node<'_>, file: &SourceFile) -> Vec<String> {
    call_arguments(node, file)
        .into_iter()
        .filter(|arg| normalized_kind(*arg, file) == NormKind::Symbol)
        .filter_map(|arg| hash_key_name(arg, file))
        .collect()
}

fn class_name_node(node: Node<'_>) -> Option<Node<'_>> {
    named_children(node)
        .into_iter()
        .find(|child| matches!(child.kind(), "constant" | "scope_resolution"))
        .or_else(|| node.child_by_field_name("name"))
}

fn const_name(node: Option<Node<'_>>, file: &SourceFile) -> String {
    node.map(|node| node_text(node, file)).unwrap_or_default()
}

fn literal_type(node: Node<'_>, file: &SourceFile) -> Option<String> {
    match normalized_kind(node, file) {
        NormKind::String => Some("String".to_string()),
        NormKind::Symbol => Some("Symbol".to_string()),
        NormKind::Integer => Some("Integer".to_string()),
        NormKind::Float => Some("Float".to_string()),
        NormKind::True | NormKind::False => Some("T::Boolean".to_string()),
        NormKind::Nil => Some("NilClass".to_string()),
        NormKind::Range => Some("Range".to_string()),
        NormKind::InterpolatedString => Some("String".to_string()),
        NormKind::Array => Some("T::Array[T.untyped]".to_string()),
        NormKind::Hash | NormKind::KeywordHash => Some("T::Hash[T.untyped, T.untyped]".to_string()),
        NormKind::Call if call_name(node, file).as_deref() == Some("new") => {
            call_receiver(node, file).map(|receiver| node_text(receiver, file))
        }
        _ => None,
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
    if text.starts_with("Array") || text.starts_with("Hash") || text.starts_with("T::Array") || text.starts_with("T::Hash") {
        return "typed collection receiver";
    }
    "non-collection or unresolved receiver"
}

fn sorbet_type_index_syntax(text: &str) -> bool {
    matches!(text, "Array" | "Hash" | "Set" | "Enumerable" | "T::Array" | "T::Hash" | "T::Set" | "T::Enumerable")
        || text.starts_with("T::")
}

fn hash_record_blocker_origin(origin: &Value) -> bool {
    matches!(
        origin.get("kind").and_then(Value::as_str),
        Some("hash literal" | "method parameter" | "forwarded return" | "instance variable" | "local hash shape")
    )
}
