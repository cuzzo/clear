impl<'a> FileIndexer<'a> {
    fn expression_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        let key = scope_key(node);
        if frame.expression_type_stack.contains(&key) {
            return None;
        }
        frame.expression_type_stack.insert(key);
        let result = self.expression_type_uncached(node, frame);
        frame.expression_type_stack.remove(&key);
        result
    }

    fn expression_type_uncached(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
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
            if let Some(field_type) = self.struct_field_static_type_for_call(node, frame) {
                if useful_type(&field_type) {
                    return Some(field_type);
                }
            }
            if let Some(ret) = self.known_return_type(&name, Some(node), frame) {
                if useful_type(&ret) {
                    return Some(ret);
                }
            }
        }
        if kind == NormKind::LocalRead {
            let name = node_text(node, self.file);
            if let Some(builder) = frame.collection_builders.get(&name) {
                let builder_type = self.synthesized_collection_builder_type(builder);
                if self.builder_has_evidence(builder) && builder_type.as_deref().is_some_and(useful_type) {
                    return builder_type;
                }
            }
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
        if kind == NormKind::IvarRead {
            return self.ivar_expression_type(&node_text(node, self.file), frame);
        }
        if kind == NormKind::Parentheses || kind == NormKind::Statements || kind == NormKind::Else {
            return implicit_return_expression(node).and_then(|expr| self.expression_type(expr, frame));
        }
        if kind == NormKind::If || kind == NormKind::Unless {
            let left = consequent_node(node)
                .and_then(implicit_return_expression)
                .and_then(|expr| self.expression_type(expr, frame));
            let right = if let Some(alternative) = alternative_node(node) {
                implicit_return_expression(alternative).and_then(|expr| self.expression_type(expr, frame))
            } else {
                Some("NilClass".to_string())
            };
            return Some(static_sorbet_type(&[left, right].into_iter().flatten().collect::<Vec<_>>()));
        }
        if kind == NormKind::While || kind == NormKind::Until {
            return Some("NilClass".to_string());
        }
        if kind == NormKind::HiddenOr {
            if let Some(or_child) = named_children(node)
                .into_iter()
                .find(|child| normalized_kind(*child, self.file) == NormKind::Or)
            {
                return self.expression_type(or_child, frame);
            }
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
        let builder = self.collection_builder_for_assignment(value, frame);
        if let Some(builder) = builder.clone() {
            frame.collection_builders.insert(name.clone(), builder);
        } else if !self.preserve_collection_builder_assignment(value, frame) {
            frame.collection_builders.remove(&name);
        } else if normalized_kind(value, self.file) == NormKind::LocalRead {
            let src = node_text(value, self.file);
            if let Some(builder) = frame.collection_builders.get(&src).cloned() {
                frame.collection_builders.insert(name.clone(), builder);
            }
        }
        if let Some(shape) = self.hash_shape_for_value(value, frame) {
            frame.hash_shapes.insert(name.clone(), shape.clone());
            frame.hash_shape_sources.insert(name.clone(), self.hash_record_source_for_assignment(node, &shape));
        } else if self.preserve_hash_shape_assignment(value, frame) {
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
        } else if self.preserve_array_element_shape_assignment(value, frame) {
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
        } else if let Some(builder) = builder.as_ref() {
            if let Some(ty) = self.synthesized_collection_builder_type(builder) {
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

    fn collection_builder_for_assignment(
        &mut self,
        value: Node<'_>,
        frame: &mut Frame,
    ) -> Option<CollectionBuilder> {
        match normalized_kind(value, self.file) {
            NormKind::Array => {
                let mut builder = self.collection_builder(CollectionBuilderKind::Array);
                for elem in array_elements(value) {
                    self.add_collection_type(&mut builder, Some(elem), frame);
                }
                Some(builder)
            }
            NormKind::Hash | NormKind::KeywordHash => {
                let mut builder = self.collection_builder(CollectionBuilderKind::Hash);
                for pair in hash_pairs(value) {
                    self.add_hash_collection_types(&mut builder, pair_key(pair), pair_value(pair), frame);
                }
                Some(builder)
            }
            NormKind::Call => {
                if call_name(value, self.file).as_deref() == Some("new")
                    && call_receiver(value, self.file).map(|receiver| node_text(receiver, self.file)) == Some("Set".to_string())
                {
                    Some(self.collection_builder(CollectionBuilderKind::Set))
                } else {
                    None
                }
            }
            _ => None,
        }
    }

    fn preserve_collection_builder_assignment(&self, value: Node<'_>, frame: &Frame) -> bool {
        normalized_kind(value, self.file) == NormKind::LocalRead
            && frame.collection_builders.contains_key(&node_text(value, self.file))
    }

    fn preserve_hash_shape_assignment(&self, value: Node<'_>, frame: &Frame) -> bool {
        normalized_kind(value, self.file) == NormKind::LocalRead
            && frame.hash_shapes.contains_key(&node_text(value, self.file))
    }

    fn hash_record_source_for_assignment(&self, node: Node<'_>, shape: &Value) -> Value {
        let name = write_name(node, self.file).unwrap_or_default();
        let value = write_value(node);
        if value.is_some_and(|value| matches!(normalized_kind(value, self.file), NormKind::Hash | NormKind::KeywordHash)) {
            json!({
                "kind": "hash literal",
                "name": name,
                "path": self.file.rel,
                "line": line(node),
                "code": value.map(|value| node_text(value, self.file)),
                "shape": shape,
            })
        } else {
            json!({
                "kind": "local hash shape",
                "name": name,
                "path": self.file.rel,
                "line": line(node),
                "code": value.map(|value| node_text(value, self.file)),
                "shape": shape,
            })
        }
    }

    fn preserve_array_element_shape_assignment(&self, value: Node<'_>, frame: &Frame) -> bool {
        normalized_kind(value, self.file) == NormKind::LocalRead
            && frame.array_element_shapes.contains_key(&node_text(value, self.file))
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
        if self.global.ivar_tlet_names.contains(&name) {
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
        let _ = frame;
        self.constant_expression_type(node).or_else(|| literal_type(node, self.file))
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
        if CORE_CLASS_CONSTANTS.contains(&bare.as_str()) || self.file.class_like_constants.contains(&bare) {
            Some(format!("T.class_of({name})"))
        } else {
            None
        }
    }

    fn non_nil_literal(&mut self, node: Node<'_>, frame: &mut Frame) -> bool {
        self.static_expression_type(node, frame)
            .is_some_and(|ty| ty != "NilClass")
    }

    fn ivar_expression_type(&self, name: &str, frame: &Frame) -> Option<String> {
        let current_class = frame.current_class.as_ref()?;
        let mut class_chain = current_class.split("::").collect::<Vec<_>>();
        while !class_chain.is_empty() {
            let candidate = class_chain.join("::");
            if let Some(type_text) = self
                .global
                .ivar_tlet_types
                .get(&(candidate, name.to_string()))
                .filter(|type_text| useful_type(type_text))
            {
                return Some(type_text.clone());
            }
            class_chain.pop();
        }
        None
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
                    call_name(value, self.file).and_then(|name| self.static_hash_return_shapes.get(&name).cloned())
                } else {
                    self.attribute_hash_shape_for_call(value, frame)
                }
            }
            NormKind::HiddenOr => named_children(value)
                .into_iter()
                .find(|child| normalized_kind(*child, self.file) == NormKind::Or)
                .and_then(|child| self.hash_shape_for_value(child, frame)),
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
                } else if matches!(call_name(value, self.file).as_deref(), Some("map" | "filter_map")) {
                    self.hash_shape_for_block_return(value, frame)
                } else if matches!(call_name(value, self.file).as_deref(), Some("select" | "reject" | "compact" | "first" | "last")) {
                    self.array_element_shape_for_receiver(call_receiver(value, self.file), frame)
                } else if call_receiver(value, self.file).is_none() {
                    call_name(value, self.file).and_then(|name| self.static_array_element_return_shapes.get(&name).cloned())
                } else {
                    self.attribute_array_element_shape_for_call(value, frame)
                }
            }
            NormKind::HiddenOr => named_children(value)
                .into_iter()
                .find(|child| normalized_kind(*child, self.file) == NormKind::Or)
                .and_then(|child| self.array_element_shape_for_value(child, frame)),
            NormKind::Or => {
                let children = named_children(value);
                match (children.first(), children.get(1)) {
                    (Some(left), Some(right)) => {
                        let left = self.array_element_shape_for_value(*left, frame);
                        let right = self.array_element_shape_for_value(*right, frame);
                        self.merge_optional_hash_shape(left, right)
                    }
                    _ => None,
                }
            }
            _ => None,
        }
    }

    fn merge_optional_hash_shape(&self, left: Option<Value>, right: Option<Value>) -> Option<Value> {
        match (left, right) {
            (Some(left), Some(right)) => Some(merge_hash_record_shapes(left, right)),
            (Some(left), None) => Some(clone_hash_shape(&left)),
            (None, Some(right)) => Some(clone_hash_shape(&right)),
            (None, None) => None,
        }
    }

    fn hash_shape_for_block_return(&mut self, call_node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let block = call_block(call_node)?;
        let body = block.child_by_field_name("body").or_else(|| named_children(block).last().copied())?;
        let old_hash_shapes = frame.hash_shapes.clone();
        let param_shapes = self.block_param_shapes_for_call(call_node, frame);
        for (idx, name) in self.block_param_names(block).into_iter().enumerate() {
            if let Some(shape) = param_shapes.get(idx) {
                frame.hash_shapes.insert(name, clone_hash_shape(shape));
            }
        }
        let expr = implicit_return_expression(body);
        let mut shape = expr.and_then(|expr| self.hash_shape_for_expression(expr, frame));
        if shape
            .as_ref()
            .and_then(|shape| shape.get("keys"))
            .and_then(Value::as_object)
            .map_or(true, Map::is_empty)
        {
            if let Some(literal_shape) = expr.and_then(|expr| self.hash_shape_for_literal_keys(expr, frame)) {
                shape = Some(literal_shape);
            }
        }
        frame.hash_shapes = old_hash_shapes;
        shape
    }

    fn hash_shape_for_literal_keys(&mut self, value: Node<'_>, frame: &mut Frame) -> Option<Value> {
        if !matches!(normalized_kind(value, self.file), NormKind::Hash | NormKind::KeywordHash) {
            return None;
        }
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
                let ty = self
                    .expression_type(value_node, frame)
                    .filter(|ty| useful_type(ty) || ty == "NilClass")
                    .unwrap_or_else(|| "T.untyped".to_string());
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
        if keys.is_empty() {
            None
        } else {
            Some(json!({
                "keys": keys,
                "value_hash_shapes": value_hash_shapes,
                "value_array_element_shapes": value_array_shapes,
                "poisoned": poisoned,
            }))
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
                    self.attribute_hash_shape_for_call(receiver, frame)
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
                    self.attribute_array_element_shape_for_call(receiver, frame)
                }
            }
            _ => None,
        }
    }

    fn attribute_hash_shape_for_call(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        if normalized_kind(node, self.file) != NormKind::Call {
            return None;
        }
        let name = call_name(node, self.file)?;
        if name.ends_with('=') {
            return None;
        }
        self.struct_field_hash_shape_for_call(node, frame)
            .or_else(|| self.global.attribute_hash_shapes.get(&name).map(clone_hash_shape))
    }

    fn attribute_array_element_shape_for_call(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        if normalized_kind(node, self.file) != NormKind::Call {
            return None;
        }
        let name = call_name(node, self.file)?;
        if name.ends_with('=') {
            return None;
        }
        self.struct_field_array_element_shape_for_call(node, frame)
            .or_else(|| self.global.attribute_array_element_shapes.get(&name).map(clone_hash_shape))
    }

    fn struct_field_hash_shape_for_call(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let index = self.global.struct_field_hash_shapes.clone();
        self.struct_field_shape_for_call(node, &index, frame)
    }

    fn struct_field_array_element_shape_for_call(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let index = self.global.struct_field_array_element_shapes.clone();
        self.struct_field_shape_for_call(node, &index, frame)
    }

    fn sym_to_s(&mut self, symbol: &str) -> String {
        symbol.to_string()
    }

    fn struct_field_shape_for_call(
        &mut self,
        node: Node<'_>,
        index: &BTreeMap<(String, String), Value>,
        frame: &mut Frame,
    ) -> Option<Value> {
        let receiver = call_receiver(node, self.file)?;
        let receiver_type = self.expression_type(receiver, frame);
        let name = self.sym_to_s(&call_name(node, self.file)?);
        let classes = self.receiver_classes_for_field_shape(receiver_type.as_deref().unwrap_or(""));
        for klass in &classes {
            if let Some(shape) = index.get(&(klass.clone(), name.clone())) {
                return Some(clone_hash_shape(shape));
            }
        }
        if classes.is_empty() {
            let matching = index
                .iter()
                .filter(|((_, field), _)| field == &name)
                .map(|(_, shape)| shape)
                .collect::<Vec<_>>();
            if matching.len() == 1 {
                return Some(clone_hash_shape(matching[0]));
            }
        }
        None
    }

    fn struct_field_static_type_for_call(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        let receiver = call_receiver(node, self.file)?;
        let receiver_type = self.expression_type(receiver, frame);
        let name = self.sym_to_s(&call_name(node, self.file)?);
        let types = self
            .receiver_classes_for_field_shape(receiver_type.as_deref().unwrap_or(""))
            .into_iter()
            .flat_map(|klass| {
                self.global
                    .struct_field_static_types
                    .get(&(klass, name.clone()))
                    .cloned()
                    .unwrap_or_default()
            })
            .collect::<BTreeSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        let ty = static_sorbet_type(&types);
        useful_type(&ty).then_some(ty)
    }

    fn receiver_classes_for_field_shape(&self, type_text: &str) -> Vec<String> {
        self.receiver_classes_for_field_shape_uncached(type_text)
    }

    fn receiver_classes_for_field_shape_uncached(&self, type_text: &str) -> Vec<String> {
        let raw = strip_nilable_type(type_text);
        if raw.is_empty() || raw == "T.untyped" {
            return Vec::new();
        }
        if raw.starts_with("T.any(") {
            return extract_call_args(&raw, "T.any")
                .map(|args| {
                    split_top_level(&args)
                        .into_iter()
                        .flat_map(|inner| self.receiver_classes_for_field_shape(&inner))
                        .collect::<BTreeSet<_>>()
                        .into_iter()
                        .collect()
                })
                .unwrap_or_default();
        }
        let short = raw.rsplit("::").next().unwrap_or(&raw).to_string();
        if raw == short { vec![raw] } else { vec![raw, short] }
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

    fn collection_map_return_type(
        &mut self,
        node: Node<'_>,
        receiver_type: &str,
        frame: &mut Frame,
    ) -> Option<String> {
        let info = collection_type_info(receiver_type)?;
        if !array_receiver_type(receiver_type) {
            return None;
        }
        let param_types = self.block_param_types_for_collection(&info);
        let param_shapes = self.block_param_shapes_for_collection(node, &info, frame);
        let block_type = self.block_return_type(node, param_types, param_shapes, frame)?;
        if !useful_type(&block_type) || block_type.contains("T.untyped") {
            return None;
        }
        Some(format!("T::Array[{block_type}]"))
    }

    fn collection_filter_map_return_type(
        &mut self,
        node: Node<'_>,
        receiver_type: &str,
        frame: &mut Frame,
    ) -> Option<String> {
        let info = collection_type_info(receiver_type)?;
        if !array_receiver_type(receiver_type) {
            return None;
        }
        let param_types = self.block_param_types_for_collection(&info);
        let param_shapes = self.block_param_shapes_for_collection(node, &info, frame);
        let block_type = self.block_return_type(node, param_types, param_shapes, frame)?;
        let elem = non_nil_type(&block_type)?;
        if elem.is_empty() || elem.contains("T.untyped") || elem == "NilClass" {
            return None;
        }
        Some(format!("T::Array[{elem}]"))
    }

    fn block_return_type(
        &mut self,
        call_node: Node<'_>,
        param_types: Vec<Option<String>>,
        param_shapes: Vec<Value>,
        frame: &mut Frame,
    ) -> Option<String> {
        let block = call_block(call_node)?;
        let body = block.child_by_field_name("body").or_else(|| named_children(block).last().copied())?;
        let old_local_types = frame.local_types.clone();
        let old_hash_shapes = frame.hash_shapes.clone();
        for (idx, name) in self.block_param_names(block).into_iter().enumerate() {
            if let Some(Some(ty)) = param_types.get(idx) {
                if useful_type(ty) {
                    frame.local_types.insert(name.clone(), ty.clone());
                }
            }
            if let Some(shape) = param_shapes.get(idx) {
                frame.hash_shapes.insert(name, clone_hash_shape(shape));
            }
        }
        let result = implicit_return_expression(body).and_then(|expr| self.expression_type(expr, frame));
        frame.local_types = old_local_types;
        frame.hash_shapes = old_hash_shapes;
        result
    }

    fn block_param_names(&self, block: Node<'_>) -> Vec<String> {
        block_param_names(block, self.file)
    }

    fn block_param_types_for_collection(&self, info: &CollectionInfo) -> Vec<Option<String>> {
        match info.kind.as_str() {
            "array" | "set" => vec![info.element.clone()],
            "hash" => vec![info.element.clone(), info.value.clone()],
            _ => Vec::new(),
        }
    }

    fn block_param_shapes_for_collection(
        &mut self,
        call_node: Node<'_>,
        info: &CollectionInfo,
        frame: &mut Frame,
    ) -> Vec<Value> {
        if info.kind != "array" {
            return Vec::new();
        }
        self.array_element_shape_for_receiver(call_receiver(call_node, self.file), frame)
            .map(|shape| vec![shape])
            .unwrap_or_default()
    }

    fn block_param_shapes_for_call(&mut self, call_node: Node<'_>, frame: &mut Frame) -> Vec<Value> {
        if !matches!(
            call_name(call_node, self.file).as_deref(),
            Some("each" | "map" | "filter_map" | "select" | "reject" | "find" | "detect" | "any?" | "all?" | "none?" | "one?")
        ) {
            return Vec::new();
        }
        self.array_element_shape_for_receiver(call_receiver(call_node, self.file), frame)
            .map(|shape| vec![shape])
            .unwrap_or_default()
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

fn array_receiver_type(type_text: &str) -> bool {
    type_text.starts_with("Array") || type_text.starts_with("T::Array")
}

fn hash_receiver_type(type_text: &str) -> bool {
    type_text.starts_with("Hash") || type_text.starts_with("T::Hash")
}

fn collection_receiver_type(type_text: &str) -> bool {
    array_receiver_type(type_text)
        || hash_receiver_type(type_text)
        || type_text.starts_with("Set")
        || type_text.starts_with("T::Set")
}

fn non_nil_type(type_text: &str) -> Option<String> {
    let raw = type_text.trim();
    if raw.is_empty() {
        return None;
    }
    if raw.starts_with("T.nilable(") {
        return Some(strip_nilable_type(raw));
    }
    if raw.starts_with("T.any(") {
        let parts = split_top_level(&extract_call_args(raw, "T.any").unwrap_or_default())
            .into_iter()
            .filter(|part| part != "NilClass")
            .collect::<Vec<_>>();
        return Some(static_sorbet_type(&parts));
    }
    Some(raw.to_string())
}

fn collection_compact_return_type(receiver_type: &str) -> Option<String> {
    let info = collection_type_info(receiver_type)?;
    if info.kind != "array" {
        return None;
    }
    let elem = non_nil_type(info.element.as_deref().unwrap_or(""))?;
    if elem.is_empty() || elem.contains("T.untyped") || elem == "NilClass" {
        return None;
    }
    Some(format!("T::Array[{elem}]"))
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
    frame.current_method = record.get("method").and_then(Value::as_str).map(ToString::to_string);
    frame.current_class = record.get("class").and_then(Value::as_str).map(ToString::to_string);
    frame.current_scope = record.get("scope").and_then(Value::as_array)
        .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect()).unwrap_or_default();
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
    frame.collection_builders = BTreeMap::new();
    frame.hash_shapes = BTreeMap::new();
    frame.array_element_shapes = BTreeMap::new();
    frame.hash_shape_sources = BTreeMap::new();
    frame.local_container_origins = record.get("params").and_then(Value::as_array).map(|a| {
        a.iter().filter_map(|p| {
            let nm = p.get("name")?.as_str()?;
            let mut origin = json!({"kind":"method parameter","name":nm,"path":record.get("path"),"line":record.get("line")});
            if let Some(ty) = p.get("type").and_then(Value::as_str) {
                object_insert(&mut origin, "type", json!(ty));
            }
            Some((nm.to_string(), origin))
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
