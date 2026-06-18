impl<'a> FileIndexer<'a> {
    fn expression_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        let kind = normalized_kind(node, self.file);
        if kind == NormKind::Return {
            let args = call_arguments(node, self.file);
            return args.first().and_then(|arg| self.expression_type(*arg, frame)).or_else(|| Some("NilClass".to_string()));
        }
        if kind == NormKind::Call {
            let name = call_name(node, self.file).unwrap_or_default();
            let receiver_text = call_receiver(node, self.file).map(|receiver| node_text(receiver, self.file));
            let args = call_arguments(node, self.file);
            if receiver_text.as_deref() == Some("T") && name == "let" {
                return args.get(1).map(|arg| node_text(*arg, self.file));
            }
            if receiver_text.as_deref() == Some("T") && name == "must" {
                return args.first().and_then(|arg| self.expression_type(*arg, frame));
            }
            if assignment_call(node, self.file) {
                return assignment_value_expression(node, self.file).and_then(|value| self.expression_type(value, frame));
            }
            if self.hash_shape_for_receiver(node, frame).is_some() {
                return Some("T::Hash[T.untyped, T.untyped]".to_string());
            }
            if self.array_element_shape_for_receiver(Some(node), frame).is_some() {
                return Some("T::Array[T::Hash[T.untyped, T.untyped]]".to_string());
            }
            if let Some(ret) = self.known_return_type(&name, Some(node), frame) {
                if useful_type(&ret) {
                    return Some(ret);
                }
            }
        }
        if kind == NormKind::LocalRead {
            let name = node_text(node, self.file);
            if frame.hash_shapes.contains_key(&name) {
                return Some("T::Hash[T.untyped, T.untyped]".to_string());
            }
            if frame.array_element_shapes.contains_key(&name) {
                return Some("T::Array[T::Hash[T.untyped, T.untyped]]".to_string());
            }
            if let Some(ty) = frame.local_types.get(&name) {
                if useful_type(ty) {
                    return Some(ty.clone());
                }
            }
            return frame.param_types.get(&name).and_then(Clone::clone);
        }
        if kind == NormKind::Parentheses || kind == NormKind::Statements || kind == NormKind::Else {
            return implicit_return_expression(node).and_then(|expr| self.expression_type(expr, frame));
        }
        if kind == NormKind::If || kind == NormKind::Unless {
            let left = consequent_node(node)
                .and_then(implicit_return_expression)
                .and_then(|expr| self.expression_type(expr, frame));
            let right = alternative_node(node)
                .and_then(implicit_return_expression)
                .and_then(|expr| self.expression_type(expr, frame))
                .or_else(|| Some("NilClass".to_string()));
            return Some(static_sorbet_type(&[left, right].into_iter().flatten().collect::<Vec<_>>()));
        }
        if kind == NormKind::While || kind == NormKind::Until {
            return Some("NilClass".to_string());
        }
        if kind == NormKind::Or {
            let children = named_children(node);
            if children.len() >= 2 {
                let left = self.expression_type(children[0], frame);
                let right = self.expression_type(children[1], frame);
                let non_nil = [left, right]
                    .into_iter()
                    .flatten()
                    .filter(|ty| ty != "NilClass")
                    .collect::<Vec<_>>();
                let normalized = non_nil
                    .iter()
                    .map(|ty| strip_nilable_type(ty))
                    .collect::<BTreeSet<_>>();
                if normalized.len() == 1 {
                    let ty = normalized.iter().next().unwrap().clone();
                    if useful_type(&ty) {
                        return Some(ty);
                    }
                }
                if non_nil.len() == 1 && useful_type(&non_nil[0]) {
                    return Some(non_nil[0].clone());
                }
            }
        }
        if self.array_element_shape_for_value(node, frame).is_some() {
            return Some("T::Array[T::Hash[T.untyped, T.untyped]]".to_string());
        }
        self.constant_expression_type(node).or_else(|| literal_type(node, self.file))
    }

    fn update_local_fact(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        let Some(value) = write_value(node) else { return };
        if let Some(shape) = self.hash_shape_for_value(value, frame) {
            frame.hash_shapes.insert(name.clone(), shape.clone());
            frame.hash_shape_sources.insert(name.clone(), json!({
                "kind": "hash literal", "name": name, "path": self.file.rel,
                "line": line(node), "code": node_text(value, self.file), "shape": shape
            }));
        } else if normalized_kind(value, self.file) == NormKind::LocalRead {
            let src = node_text(value, self.file);
            if let Some(shape) = frame.hash_shapes.get(&src).cloned() {
                frame.hash_shapes.insert(name.clone(), shape.clone());
                if let Some(source) = frame.hash_shape_sources.get(&src).cloned() {
                    let mut s = source.clone();
                    if let Some(obj) = s.as_object_mut() { obj.insert("alias".into(), Value::String(name.clone())); }
                    frame.hash_shape_sources.insert(name.clone(), s);
                } else {
                    frame.hash_shape_sources.insert(name.clone(), json!({"kind":"local hash shape","name":name,"path":self.file.rel,"line":line(node),"code":node_text(value,self.file),"shape":shape}));
                }
            } else {
                frame.hash_shapes.remove(&name);
                frame.hash_shape_sources.remove(&name);
            }
        } else {
            frame.hash_shapes.remove(&name);
            frame.hash_shape_sources.remove(&name);
        }
        if let Some(shape) = self.array_element_shape_for_value(value, frame) {
            frame.array_element_shapes.insert(name.clone(), shape);
        } else if normalized_kind(value, self.file) == NormKind::LocalRead {
            let src = node_text(value, self.file);
            if let Some(shape) = frame.array_element_shapes.get(&src).cloned() {
                frame.array_element_shapes.insert(name.clone(), shape);
            } else {
                frame.array_element_shapes.remove(&name);
            }
        } else {
            frame.array_element_shapes.remove(&name);
        }
        if let Some(ty) = self.expression_type(value, frame) {
            if useful_type(&ty) {
                frame.local_types.insert(name.clone(), ty);
            } else {
                frame.local_types.remove(&name);
            }
        } else {
            frame.local_types.remove(&name);
        }
        if self.non_nil_literal(value, frame) && !frame.maybe_nil_locals.contains(&name) {
            frame.non_nil_locals.insert(name);
        } else {
            frame.non_nil_locals.remove(&name);
            frame.maybe_nil_locals.insert(name);
        }
    }

    fn update_collection_builder_call(&mut self, _node: Node<'_>, _frame: &mut Frame) {
        let node = _node;
        let frame = _frame;
        let Some(receiver) = call_receiver(node, self.file) else { return };
        if normalized_kind(receiver, self.file) != NormKind::LocalRead {
            return;
        }
        let receiver_name = node_text(receiver, self.file);
        let name = call_name(node, self.file).unwrap_or_default();
        let args = call_arguments(node, self.file);
        match name.as_str() {
            "<<" | "push" | "add" => {
                if let Some(arg) = args.first() {
                    if let Some(shape) = self.hash_shape_for_value(*arg, frame) {
                        merge_frame_array_shape(frame, &receiver_name, shape);
                    }
                }
            }
            "concat" => {
                if let Some(arg) = args.first() {
                    if let Some(shape) = self.array_element_shape_for_value(*arg, frame) {
                        merge_frame_array_shape(frame, &receiver_name, shape);
                    }
                }
            }
            _ => {}
        }
    }

    fn inspect_variable_write(&mut self, node: Node<'_>, frame: &mut Frame) {
        let Some(name) = write_name(node, self.file) else { return };
        let Some(value) = write_value(node) else { return };
        if normalized_kind(value, self.file) == NormKind::Call
            && call_name(value, self.file).as_deref() == Some("let")
            && call_receiver(value, self.file).map(|receiver| node_text(receiver, self.file)) == Some("T".to_string())
        {
            return;
        }
        let ty = self.static_expression_type(value, frame);
        if ty.as_deref() == Some("NilClass") {
            return;
        }
        if let Some(ty) = ty {
            self.facts.tlet_sites.push(json!({
                "path": self.file.rel,
                "line": line(node),
                "tlet": false,
                "name": name,
                "candidate_type": ty,
            }));
        }
    }

    fn static_expression_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        self.constant_expression_type(node).or_else(|| literal_type(node, self.file)).or_else(|| {
            if normalized_kind(node, self.file) == NormKind::Call {
                self.expression_type(node, frame)
            } else {
                None
            }
        })
    }

    fn constant_expression_type(&self, node: Node<'_>) -> Option<String> {
        if !matches!(normalized_kind(node, self.file), NormKind::ConstRead | NormKind::ConstPath) {
            return None;
        }
        let name = node_text(node, self.file);
        if name.is_empty() {
            return None;
        }
        let bare = name.trim_start_matches("::").to_string();
        if CORE_CLASS_CONSTANTS.contains(&bare.as_str()) || self.global.class_like_constants.contains(&bare) {
            Some(format!("T.class_of({name})"))
        } else {
            None
        }
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

    fn hash_shape_for_value(&mut self, value: Node<'_>, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(value, self.file) {
            NormKind::Hash | NormKind::KeywordHash => {
                let mut keys = Map::new();
                let mut value_hash_shapes = Map::new();
                let mut value_array_shapes = Map::new();
                let mut poisoned = false;
                for pair in hash_pairs(value) {
                    let Some(key_node) = pair_key(pair) else {
                        continue;
                    };
                    let Some(value_node) = pair_value(pair) else {
                        continue;
                    };
                    if let Some(key) = hash_key_name(key_node, self.file) {
                        let ty = self.expression_type(value_node, frame).unwrap_or_else(|| "T.untyped".to_string());
                        let entry = keys.entry(key.clone()).or_insert_with(|| json!([]));
                        if let Some(array) = entry.as_array_mut() {
                            if !array.iter().any(|entry| entry.as_str() == Some(&ty)) {
                                array.push(json!(ty));
                            }
                        }
                        if let Some(nested) = self.hash_shape_for_value(value_node, frame) {
                            value_hash_shapes.insert(key.clone(), nested);
                        }
                        if let Some(nested) = self.array_element_shape_for_value(value_node, frame) {
                            value_array_shapes.insert(key, nested);
                        }
                    } else {
                        poisoned = true;
                    }
                }
                Some(json!({
                    "keys": keys,
                    "value_hash_shapes": value_hash_shapes,
                    "value_array_element_shapes": value_array_shapes,
                    "poisoned": poisoned,
                }))
            }
            NormKind::LocalRead => frame.hash_shapes.get(&node_text(value, self.file)).cloned(),
            NormKind::Call => {
                if assignment_call(value, self.file) {
                    assignment_value_expression(value, self.file).and_then(|arg| self.hash_shape_for_value(arg, frame))
                } else if call_receiver(value, self.file).map(|receiver| node_text(receiver, self.file)) == Some("T".to_string())
                    && matches!(call_name(value, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(value, self.file)
                        .first()
                        .and_then(|arg| self.hash_shape_for_value(*arg, frame))
                } else if call_receiver(value, self.file).is_none() {
                    call_name(value, self.file).and_then(|name| self.global.static_hash_return_shapes.get(&name).cloned())
                } else {
                    None
                }
            }
            NormKind::Or => {
                let children = named_children(value);
                match (children.first(), children.get(1)) {
                    (Some(left), Some(right)) => match (
                        self.hash_shape_for_value(*left, frame),
                        self.hash_shape_for_value(*right, frame),
                    ) {
                        (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                        (Some(l), None) => Some(l),
                        (None, Some(r)) => Some(r),
                        _ => None,
                    },
                    _ => None,
                }
            }
            _ => None,
        }
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

    fn array_element_shape_for_value(&mut self, value: Node<'_>, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(value, self.file) {
            NormKind::Array => {
                let shapes = array_elements(value)
                    .into_iter()
                    .filter_map(|elem| self.hash_shape_for_value(elem, frame))
                    .collect::<Vec<_>>();
                if shapes.is_empty() {
                    None
                } else {
                    shapes.into_iter().reduce(merge_hash_record_shapes)
                }
            }
            NormKind::LocalRead => frame.array_element_shapes.get(&node_text(value, self.file)).cloned(),
            NormKind::Call => {
                if assignment_call(value, self.file) {
                    assignment_value_expression(value, self.file).and_then(|arg| self.array_element_shape_for_value(arg, frame))
                } else if call_receiver(value, self.file).map(|receiver| node_text(receiver, self.file)) == Some("T".to_string())
                    && matches!(call_name(value, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(value, self.file)
                        .first()
                        .and_then(|arg| self.array_element_shape_for_value(*arg, frame))
                } else if matches!(call_name(value, self.file).as_deref(), Some("select" | "reject" | "compact" | "first" | "last")) {
                    self.array_element_shape_for_receiver(call_receiver(value, self.file), frame)
                } else if call_receiver(value, self.file).is_none() {
                    call_name(value, self.file).and_then(|name| self.global.static_array_element_return_shapes.get(&name).cloned())
                } else {
                    None
                }
            }
            NormKind::Or => {
                let children = named_children(value);
                match (children.first(), children.get(1)) {
                    (Some(left), Some(right)) => match (
                        self.array_element_shape_for_value(*left, frame),
                        self.array_element_shape_for_value(*right, frame),
                    ) {
                        (Some(l), Some(r)) => Some(merge_hash_record_shapes(l, r)),
                        (Some(l), None) => Some(l),
                        (None, Some(r)) => Some(r),
                        _ => None,
                    },
                    _ => None,
                }
            }
            _ => None,
        }
    }

    fn hash_shape_for_receiver(&mut self, receiver: Node<'_>, frame: &mut Frame) -> Option<Value> {
        match normalized_kind(receiver, self.file) {
            NormKind::LocalRead => frame.hash_shapes.get(&node_text(receiver, self.file)).cloned(),
            NormKind::Hash | NormKind::KeywordHash => self.hash_shape_for_value(receiver, frame),
            NormKind::Call => {
                if call_receiver(receiver, self.file).map(|r| node_text(r, self.file)) == Some("T".to_string())
                    && matches!(call_name(receiver, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(receiver, self.file)
                        .first()
                        .and_then(|arg| self.hash_shape_for_receiver(*arg, frame))
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn array_element_shape_for_receiver(&mut self, receiver: Option<Node<'_>>, frame: &mut Frame) -> Option<Value> {
        let receiver = receiver?;
        match normalized_kind(receiver, self.file) {
            NormKind::LocalRead => frame.array_element_shapes.get(&node_text(receiver, self.file)).cloned(),
            NormKind::Array => self.array_element_shape_for_value(receiver, frame),
            NormKind::Call => {
                if call_receiver(receiver, self.file).map(|r| node_text(r, self.file)) == Some("T".to_string())
                    && matches!(call_name(receiver, self.file).as_deref(), Some("must" | "cast" | "let"))
                {
                    call_arguments(receiver, self.file)
                        .first()
                        .and_then(|arg| self.array_element_shape_for_receiver(Some(*arg), frame))
                } else if matches!(call_name(receiver, self.file).as_deref(), Some("select" | "reject" | "compact")) {
                    self.array_element_shape_for_receiver(call_receiver(receiver, self.file), frame)
                } else {
                    None
                }
            }
            _ => None,
        }
    }
}

fn collection_type_info(type_text: &str) -> Option<CollectionInfo> {
    let raw = strip_nilable_type(type_text.trim());
    if raw.is_empty() {
        return None;
    }
    parse_collection_type(&raw)
}

struct CollectionInfo {
    kind: String,
    element: Option<String>,
    value: Option<String>,
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
            let parts = split_top_level(inner);
            return Some(CollectionInfo {
                kind: kind.to_string(),
                element: parts.first().cloned(),
                value: parts.get(1).cloned(),
            });
        }
    }
    None
}

fn array_receiver_type(type_text: &str) -> bool {
    type_text.starts_with("Array") || type_text.starts_with("T::Array")
}

fn collection_receiver_type(type_text: &str) -> bool {
    array_receiver_type(type_text)
        || type_text.starts_with("Hash")
        || type_text.starts_with("T::Hash")
        || type_text.starts_with("Set")
        || type_text.starts_with("T::Set")
}

fn nilable_type(type_text: &str) -> String {
    if type_text == "NilClass" || type_text.starts_with("T.nilable(") {
        type_text.to_string()
    } else {
        format!("T.nilable({type_text})")
    }
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
            return if has_nil { "NilClass".to_string() } else { "T.noreturn".to_string() };
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

fn useful_type(type_text: &str) -> bool {
    !type_text.is_empty() && type_text != "T.untyped"
}

fn weak_type(type_text: &str) -> bool {
    type_text.contains("T.untyped")
        || type_text.contains("[T.untyped")
        || type_text.contains(", T.untyped")
}

fn strip_nilable_type(type_text: &str) -> String {
    let text = type_text.trim();
    if text.starts_with("T.nilable(") && text.ends_with(')') {
        extract_call_args(text, "T.nilable").unwrap_or_else(|| text.to_string())
    } else {
        text.to_string()
    }
}

fn static_expression_reason(type_text: &str) -> String {
    if type_text.starts_with("T.class_of(") && type_text.ends_with(')') {
        format!(
            "class constant {}",
            type_text.trim_start_matches("T.class_of(").trim_end_matches(')')
        )
    } else {
        type_text.to_string()
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

fn merge_frame_array_shape(frame: &mut Frame, name: &str, shape: Value) {
    if shape.get("poisoned").and_then(Value::as_bool) == Some(true) {
        return;
    }
    let merged = frame
        .array_element_shapes
        .get(name)
        .cloned()
        .map(|current| merge_hash_record_shapes(current, shape.clone()))
        .unwrap_or(shape);
    frame.array_element_shapes.insert(name.to_string(), merged);
}

fn merge_value(base: &Value, entries: &[(&str, Value)]) -> Value {
    let mut out = base.clone();
    for (key, value) in entries {
        object_insert(&mut out, key, value.clone());
    }
    out
}

fn object_insert(value: &mut Value, key: &str, entry: Value) {
    if let Some(obj) = value.as_object_mut() {
        obj.insert(key.to_string(), entry);
    }
}

fn scope_method_frame(record: &Value, frame: &mut Frame) {
    frame.non_nil_locals = record.get("non_nil_params").and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
    frame.maybe_nil_locals = BTreeSet::new();
    frame.param_types = record.get("params").and_then(Value::as_array).map(|a| {
        a.iter().filter_map(|p| {
            let nm = p.get("name")?.as_str()?;
            let ty = p.get("type")?.as_str();
            if useful_type(ty.unwrap_or("")) { Some((nm.to_string(), ty.map(String::from))) } else { Some((nm.to_string(), None)) }
        }).collect()
    }).unwrap_or_default();
    frame.local_types = BTreeMap::new();
    frame.hash_shapes = BTreeMap::new();
    frame.array_element_shapes = BTreeMap::new();
    frame.hash_shape_sources = BTreeMap::new();
    frame.local_container_origins = record.get("params").and_then(Value::as_array).map(|a| {
        a.iter().filter_map(|p| {
            let nm = p.get("name")?.as_str()?;
            Some((nm.to_string(), json!({"kind":"method parameter","name":nm,"type":p.get("type"),"path":record.get("path"),"line":record.get("line")})))
        }).collect()
    }).unwrap_or_default();
}

fn clone_hash_shapes(shapes: &BTreeMap<String, Value>) -> BTreeMap<String, Value> {
    shapes.iter().map(|(k,v)| (k.clone(), clone_hash_shape(v))).collect()
}

fn clone_hash_shape(shape: &Value) -> Value {
    if let Some(obj) = shape.as_object() {
        let mut out = serde_json::Map::new();
        for (k, v) in obj {
            out.insert(k.clone(), clone_hash_shape(v));
        }
        Value::Object(out)
    } else {
        shape.clone()
    }
}

fn value_array(value: Option<&Value>) -> Vec<Value> {
    value.and_then(Value::as_array).cloned().unwrap_or_default()
}

fn value_string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|array| {
            array
                .iter()
                .filter_map(Value::as_str)
                .map(ToString::to_string)
                .collect()
        })
        .unwrap_or_default()
}

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
