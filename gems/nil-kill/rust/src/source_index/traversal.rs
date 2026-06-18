impl<'a> FileIndexer<'a> {
    fn recompute_return_origins_with_inferred_shapes(&mut self) {
        self.recompute_return_origins();
    }

    fn recompute_return_origins(&mut self) {
        let nodes: Vec<_> = self.method_nodes.iter().map(|&(n, ref r)| (n, r.clone())).collect();
        for _ in 0..2 {
            for &(node, ref record) in &nodes {
                let mut frame = self.scoped_facts(record);
                if let Some(body) = method_body(node) {
                    self.collect_local_type_facts(body, &mut frame);
                }
                if let Some(origin) = self.analyze_return_origin(node, record, &mut frame) {
                    if origin.get("confidence").and_then(Value::as_str) == Some("strong") {
                        if let Some(t) = origin.get("candidate_type").and_then(Value::as_str) {
                            if useful_type(t) {
                                self.global.static_return_types.insert(
                                    record["method"].as_str().unwrap_or("").to_string(), t.to_string());
                            }
                        }
                    }
                    if let Some(h) = origin.get("hash_shape") {
                        if !h.is_null() && h.get("poisoned") != Some(&Value::Bool(true)) {
                            self.global.static_hash_return_shapes.insert(
                                record["method"].as_str().unwrap_or("").to_string(), h.clone());
                        }
                    }
                    if let Some(a) = origin.get("array_element_shape") {
                        if !a.is_null() && a.get("poisoned") != Some(&Value::Bool(true)) {
                            self.global.static_array_element_return_shapes.insert(
                                record["method"].as_str().unwrap_or("").to_string(), a.clone());
                        }
                    }
                }
            }
        }
    }

    fn recompute_collection_index_lookups_with_inferred_shapes(&mut self) {
        self.recompute_collection_lookups();
    }

    fn recompute_collection_lookups(&mut self) {
        self.facts.collection_index_lookups.clear();
        self.facts.hash_record_blockers.clear();
        let nodes: Vec<_> = self.method_nodes.iter().map(|&(n, ref r)| (n, r.clone())).collect();
        for (node, record) in &nodes {
            let mut frame = self.scoped_facts(record);
            if let Some(body) = method_body(*node) {
                let scope_vec: Vec<String> = record.get("scope")
                    .and_then(Value::as_array)
                    .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
                    .unwrap_or_default();
                let scope = ScopeState { scope: scope_vec.clone(), class_name: record.get("class").and_then(Value::as_str).map(String::from) };
                self.collect_collection_index_facts(body, &scope, &mut frame);
            }
        }
    }

    fn recompute_struct_field_static_with_inferred_locals(&mut self) {
        self.recompute_struct_field_static();
    }

    fn recompute_struct_field_static(&mut self) {
        if self.facts.struct_field_static.is_empty() { return; }
        let mut index: BTreeMap<(String, usize, String, String, String), Vec<Value>> = BTreeMap::new();
        for entry in &self.facts.struct_field_static {
            let key = (
                entry.get("path").and_then(Value::as_str).unwrap_or("").to_string(),
                entry.get("line").and_then(Value::as_i64).unwrap_or(0) as usize,
                entry.get("class").and_then(Value::as_str).unwrap_or("").to_string(),
                entry.get("field").and_then(Value::as_str).unwrap_or("").to_string(),
                entry.get("expression").and_then(Value::as_str).unwrap_or("").to_string(),
            );
            index.entry(key).or_default().push(entry.clone());
        }
        let nodes: Vec<_> = self.method_nodes.iter().map(|&(n, ref r)| (n, r.clone())).collect();
        for &(node, ref record) in &nodes {
            let mut frame = self.scoped_facts(record);
            if let Some(body) = method_body(node) {
                self.collect_local_type_facts(body, &mut frame);
                self.refill_struct_constructor_types(body, &mut index, &mut frame);
            }
        }
        self.facts.struct_field_static = index.into_values().flatten().collect();
    }

    fn child_walk(&mut self, node: Node<'a>, state: &mut ScopeState, frame: &mut Frame) {
        for child in named_children(node) {
            self.walk(child, state, frame);
        }
    }

    #[allow(dead_code)]
    fn collect_local_container_origins(&mut self, node: Node<'_>, frame: &mut Frame) {
        if nested_scope_node(node, self.file) {
            return;
        }
        if normalized_kind(node, self.file) == NormKind::LocalWrite {
            self.inspect_local_container_origin(node, frame);
        }
        for child in named_children(node) {
            self.collect_local_container_origins(child, frame);
        }
    }

    fn refill_struct_constructor_types(&mut self, node: Node<'_>,
        index: &mut BTreeMap<(String, usize, String, String, String), Vec<Value>>, frame: &mut Frame) {
        if nested_scope_node(node, self.file) { return; }
        if normalized_kind(node, self.file) == NormKind::Call && call_name(node, self.file).as_deref() == Some("new")
            && call_receiver(node, self.file).is_some()
        {
            let receiver = call_receiver(node, self.file).unwrap();
            let klass = const_name(Some(receiver), self.file);
            let klass_short = klass.rsplit("::").next().unwrap_or("");
            let fields = self.global.struct_fields_by_name.get(&klass)
                .or_else(|| self.global.struct_fields_by_name.get(klass_short))
                .cloned();
            if let Some(fields) = fields {
                let full_class = self.global.struct_full_by_name.get(&klass)
                    .or_else(|| self.global.struct_full_by_name.get(klass_short))
                    .cloned().unwrap_or(klass);
                let args = call_arguments(node, self.file);
                for (idx, arg) in args.iter().enumerate() {
                    if idx >= fields.len() { break; }
                    if arg.kind() == "pair" { continue; } // KeywordHashNode skip
                    let key = (
                        self.file.rel.clone(), line(node), full_class.clone(),
                        fields[idx].clone(), node_text(*arg, self.file),
                    );
                    if let Some(entries) = index.get(&key) {
                        if entries.iter().all(|e| !useful_type(e.get("type").and_then(Value::as_str).unwrap_or(""))) {
                            continue;
                        }
                        let resolved = self.expression_type(*arg, frame);
                        if let Some(ref resolved) = resolved {
                            if useful_type(resolved) {
                                if let Some(entries) = index.get_mut(&key) {
                                    for e in entries {
                                        if !useful_type(e.get("type").and_then(Value::as_str).unwrap_or("")) {
                                            object_insert(e, "type", json!(resolved));
                                        }
                                    }
                                }
                                let sk = (full_class.clone(), fields[idx].clone());
                                self.global.struct_field_static_types.entry(sk).or_default().push(resolved.clone());
                            }
                        }
                    }
                }
            }
        }
        for child in named_children(node) {
            self.refill_struct_constructor_types(child, index, frame);
        }
    }

    fn collect_collection_index_facts(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        if nested_scope_node(node, self.file) { return; }
        match normalized_kind(node, self.file) {
            NormKind::Call => {
                self.update_collection_builder_call(node, frame);
                self.inspect_index_lookup(node, state, frame);
                self.inspect_hash_record_blocker(node, state, frame);
                self.inspect_hash_record_member_call(node, state, frame);
                self.collect_call_collection_index_facts(node, state, frame);
            }
            NormKind::LocalWrite => {
                self.update_local_fact(node, frame);
                self.inspect_local_container_origin(node, frame);
                for child in named_children(node) {
                    self.collect_collection_index_facts(child, state, frame);
                }
            }
            _ => {
                for child in named_children(node) {
                    self.collect_collection_index_facts(child, state, frame);
                }
            }
        }
    }

    fn collect_call_collection_index_facts(&mut self, node: Node<'_>, state: &ScopeState, frame: &mut Frame) {
        let block = call_block(node);
        if block.is_none() || block.unwrap().child_by_field_name("body").is_none() {
            for child in named_children(node) {
                self.collect_collection_index_facts(child, state, frame);
            }
            return;
        }
        let block = block.unwrap();
        let old_hs = frame.hash_shapes.clone();
        frame.hash_shapes = clone_hash_shapes(&frame.hash_shapes);
        let names = block_param_names(block, self.file);
        let shapes = self.block_param_shapes_for_call(node, frame);
        for (i, name) in names.iter().enumerate() {
            if let Some(shape) = shapes.get(i) {
                frame.hash_shapes.insert(name.clone(), clone_hash_shape(shape));
            }
        }
        for child in named_children(node) {
            self.collect_collection_index_facts(child, state, frame);
        }
        frame.hash_shapes = old_hs;
    }

    fn walk(&mut self, node: Node<'a>, state: &mut ScopeState, frame: &mut Frame) {
        let walk_key = walk_key(node);
        if self.walk_stack.contains(&walk_key) {
            return;
        }
        self.walk_stack.insert(walk_key.clone());
        match normalized_kind(node, self.file) {
            NormKind::Class | NormKind::Module => {
                let name = const_name(class_name_node(node), self.file);
                let mut child_state = state.clone();
                if !name.is_empty() {
                    child_state.scope.push(name.clone());
                    child_state.class_name = Some(child_state.scope.join("::"));
                }
                for child in named_children(node) {
                    self.walk(child, &mut child_state, frame);
                }
            }
            NormKind::Def => {
                let method = self.method_record(node, state);
                let mut method_frame = self.scoped_facts(&method);
                if let Some(body) = method_body(node) {
                    self.collect_local_type_facts(body, &mut method_frame);
                }

                let mut source = method.clone();
                let return_origin = self.analyze_return_origin(node, &method, &mut method_frame);
                if let Some(origin) = return_origin {
                    if origin.get("confidence").and_then(Value::as_str) == Some("strong") {
                        if let Some(candidate) = origin.get("candidate_type").and_then(Value::as_str) {
                            if useful_type(candidate) {
                                self.global
                                    .static_return_types
                                    .insert(method["method"].as_str().unwrap_or("").to_string(), candidate.to_string());
                            }
                        }
                    }
                    if let Some(shape) = origin.get("hash_shape") {
                        if !shape.is_null() {
                            self.global.static_hash_return_shapes.insert(
                                method["method"].as_str().unwrap_or("").to_string(),
                                shape.clone(),
                            );
                        }
                    }
                    if let Some(shape) = origin.get("array_element_shape") {
                        if !shape.is_null() {
                            self.global.static_array_element_return_shapes.insert(
                                method["method"].as_str().unwrap_or("").to_string(),
                                shape.clone(),
                            );
                        }
                    }
                    object_insert(&mut source, "return_origin", origin.clone());
                    self.facts.return_origins.push(origin);
                }

                let protocols = self.param_protocols(node, &source, &mut method_frame);
                object_insert(&mut source, "protocols", protocols);
                self.inspect_dispatcher(node, &source);
                if let Some(body) = method_body(node) {
                    self.walk(body, state, &mut method_frame);
                    self.collect_type_normalizers(body, &source, &method_frame);
                    self.collect_hidden_enum_observations(body, &source);
                }
                self.facts.methods.push(source.clone());
                self.method_nodes.push((node, source));
            }
            NormKind::If => {
                self.inspect_branch_guard(node, false, frame);
                self.child_walk(node, state, frame);
            }
            NormKind::Unless => {
                self.inspect_branch_guard(node, true, frame);
                self.child_walk(node, state, frame);
            }
            NormKind::Call => {
                if lhs_element_reference_node(node) {
                    self.walk_stack.remove(&walk_key);
                    return;
                }
                self.inspect_param_origins(node, state, frame);
                self.update_collection_builder_call(node, frame);
                self.inspect_call(node, frame);
                self.inspect_index_lookup(node, state, frame);
                self.inspect_hash_record_blocker(node, state, frame);
                self.inspect_hash_record_member_call(node, state, frame);
                self.inspect_struct_constructor(node, frame);
                self.inspect_class_constructor_fields(node, frame);
                self.inspect_attribute_shape_write(node, frame);
                self.walk_call_children(node, state, frame);
            }
            NormKind::Array => {
                self.inspect_array_literal(node, frame);
                self.child_walk(node, state, frame);
            }
            NormKind::Hash => {
                self.inspect_hash_literal(node, frame);
                self.child_walk(node, state, frame);
            }
            NormKind::KeywordHash => {
                self.child_walk(node, state, frame);
            }
            NormKind::ConstWrite => {
                self.inspect_struct_declaration(node, state);
                self.child_walk(node, state, frame);
            }
            NormKind::LocalWrite => {
                self.update_local_fact(node, frame);
                self.inspect_local_container_origin(node, frame);
                self.child_walk(node, state, frame);
            }
            NormKind::IvarWrite | NormKind::ClassVarWrite | NormKind::GlobalVarWrite => {
                self.inspect_variable_write(node, frame);
                self.inspect_ivar_container_origin(node, frame);
                self.child_walk(node, state, frame);
            }
            _ => {
                self.child_walk(node, state, frame);
            }
        }
        self.walk_stack.remove(&walk_key);
    }

    fn walk_call_children(&mut self, node: Node<'a>, state: &mut ScopeState, frame: &mut Frame) {
        let block = call_block(node);
        let seed_shape = call_receiver(node, self.file).and_then(|receiver| {
            if normalized_kind(receiver, self.file) == NormKind::LocalRead
                && matches!(
                    call_name(node, self.file).as_deref(),
                    Some("each" | "map" | "filter_map" | "select" | "reject" | "find" | "detect" | "any?" | "all?" | "none?" | "one?")
                )
            {
                frame.array_element_shapes.get(&node_text(receiver, self.file)).cloned()
            } else {
                None
            }
        });
        for child in named_children(node) {
            if Some(child) == block {
                let mut block_frame = frame.clone();
                let block_names = block_param_names(child, self.file);
                if let Some(shape) = seed_shape.clone() {
                    for name in &block_names {
                        block_frame.hash_shapes.insert(name.clone(), shape.clone());
                    }
                }
                self.walk(child, state, &mut block_frame);
                for (name, shape) in block_frame.array_element_shapes {
                    if !block_names.contains(&name) {
                        frame.array_element_shapes.insert(name, shape);
                    }
                }
            } else {
                self.walk(child, state, frame);
            }
        }
    }
}

fn collect_prescan(file: &SourceFile, global: &mut GlobalState) {
    let mut state = ScopeState::default();
    collect_prescan_node(file, file.root_node(), &mut state, global);
}

fn collect_prescan_node(
    file: &SourceFile,
    node: Node<'_>,
    state: &mut ScopeState,
    global: &mut GlobalState,
) {
    match normalized_kind(node, file) {
        NormKind::Class | NormKind::Module => {
            let name = const_name(class_name_node(node), file);
            let full = if state.scope.is_empty() {
                name.clone()
            } else {
                format!("{}::{name}", state.scope.join("::"))
            };
            if !name.is_empty() {
                global.class_like_constants.insert(full.clone());
                global.class_like_constants.insert(name.clone());
                state.scope.push(name);
                state.class_name = Some(full);
                for child in named_children(node) {
                    collect_prescan_node(file, child, state, global);
                }
                state.scope.pop();
                state.class_name = state.scope.last().cloned();
                return;
            }
        }
        NormKind::ConstWrite => {
            if let Some(value) = write_value(node) {
                if struct_new_call(value, file) || data_define_call(value, file) {
                    let name = write_name(node, file).unwrap_or_default();
                    let klass = if state.scope.is_empty() {
                        name.clone()
                    } else {
                        format!("{}::{name}", state.scope.join("::"))
                    };
                    let fields = struct_fields(value, file);
                    if !fields.is_empty() {
                        global.struct_fields_by_name.insert(klass.clone(), fields.clone());
                        global.struct_full_by_name.insert(klass.clone(), klass.clone());
                        if let Some(short) = klass.rsplit("::").next() {
                            global
                                .struct_fields_by_name
                                .entry(short.to_string())
                                .or_insert_with(|| fields.clone());
                            global
                                .struct_full_by_name
                                .entry(short.to_string())
                                .or_insert_with(|| klass.clone());
                        }
                    }
                    global.class_like_constants.insert(klass);
                    global.class_like_constants.insert(name);
                }
            }
        }
        NormKind::IvarWrite => {
            if let (Some(name), Some(value)) = (write_name(node, file), write_value(node)) {
                if normalized_kind(value, file) == NormKind::Call
                    && call_name(value, file).as_deref() == Some("let")
                    && call_receiver(value, file).map(|receiver| node_text(receiver, file)) == Some("T".to_string())
                {
                    global.ivar_tlet_names.insert(name.clone());
                    if let (Some(class_name), Some(type_node)) = (state.class_name.as_ref(), call_arguments(value, file).get(1)) {
                        let type_text = node_text(*type_node, file);
                        if useful_type(&type_text) {
                            global.ivar_tlet_types.insert((class_name.clone(), name), type_text);
                        }
                    }
                }
            }
        }
        NormKind::Def => {
            if let Some(sig) = sig_above(&file.lines, line(node)) {
                if let Some(ret) = extract_return_type(&sig) {
                    global
                        .method_return_types
                        .entry(method_name(node, file))
                        .or_default()
                        .insert(ret.clone());
                    if non_nil_return_sig(&sig) {
                        global.noreturn_methods.remove(&method_name(node, file));
                    }
                }
            }
        }
        _ => {}
    }
    for child in named_children(node) {
        collect_prescan_node(file, child, state, global);
    }
}
