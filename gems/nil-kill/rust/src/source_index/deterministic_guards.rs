#[derive(Clone, Debug)]
enum LiteralStaticValue {
    String(String),
    Symbol(String),
    Integer(i64),
    Float(f64),
    Bool(bool),
    Nil,
    Unknown,
}

impl<'a> FileIndexer<'a> {
    fn inspect_branch_guard(&mut self, node: Node<'_>, inverted: bool, frame: &mut Frame) {
        let Some(predicate) = condition_node(node) else { return };
        let Some(result) = self.deterministic_predicate_result(predicate, frame) else { return };

        let truth = result.get("truth_value").and_then(Value::as_bool).unwrap_or(false);
        let taken = if inverted { !truth } else { truth };
        self.facts.deterministic_guards.push(json!({
            "path": self.file.rel,
            "line": line(predicate),
            "class": frame.current_class,
            "method": frame.current_method,
            "code": first_line(&node_text(predicate, self.file)).chars().take(160).collect::<String>(),
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

    fn deterministic_predicate_result(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let node = if normalized_kind(node, self.file) == NormKind::Parentheses {
            implicit_return_expression(node).unwrap_or(node)
        } else {
            node
        };
        if let Some(literal) = self.literal_truth_value(node) {
            return Some(self.deterministic_guard_result(
                literal,
                "literal",
                format!("{} is a boolean literal", node_text(node, self.file)),
                None,
                None,
            ));
        }
        if normalized_kind(node, self.file) == NormKind::Call {
            if let Some(result) = self.deterministic_nil_predicate_result(node, frame) {
                return Some(result);
            }
            if let Some(result) = self.deterministic_class_predicate_result(node, frame) {
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

    fn literal_truth_value(&self, node: Node<'_>) -> Option<bool> {
        match normalized_kind(node, self.file) {
            NormKind::True => Some(true),
            NormKind::False => Some(false),
            _ => None,
        }
    }

    fn deterministic_nil_predicate_result(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        if call_name(node, self.file).as_deref() != Some("nil?") {
            return None;
        }
        let receiver = call_receiver(node, self.file)?;
        let (origin_kind, origin_name) = self.predicate_origin(receiver, frame);
        let receiver_type = self.deterministic_guard_subject_type(receiver, frame)?;
        if receiver_type != "NilClass" && !receiver_type.starts_with("T.nilable(") {
            return Some(self.deterministic_guard_result(
                false,
                "nil_check",
                format!(
                    "{} has static type {}; .nil? is always false",
                    node_text(receiver, self.file),
                    receiver_type
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
                    node_text(receiver, self.file)
                ),
                origin_kind,
                origin_name,
            ));
        }
        None
    }

    fn deterministic_class_predicate_result(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<Value> {
        let name = call_name(node, self.file)?;
        if !matches!(name.as_str(), "is_a?" | "kind_of?" | "instance_of?") {
            return None;
        }
        let receiver = call_receiver(node, self.file)?;
        let args = call_arguments(node, self.file);
        if args.len() != 1 {
            return None;
        }
        let class_name = const_name(args.first().copied(), self.file);
        if class_name.is_empty() {
            return None;
        }
        let receiver_type = self.deterministic_guard_subject_type(receiver, frame)?;
        let truth = self.class_guard_truth(&receiver_type, &class_name, name == "instance_of?")?;
        let (origin_kind, origin_name) = self.predicate_origin(receiver, frame);
        Some(self.deterministic_guard_result(
            truth,
            "class_guard",
            format!(
                "{} has static type {}; {}({}) is always {}",
                node_text(receiver, self.file),
                receiver_type,
                name,
                class_name,
                truth
            ),
            origin_kind,
            origin_name,
        ))
    }

    fn class_guard_truth(&self, receiver_type: &str, class_name: &str, exact: bool) -> Option<bool> {
        let raw = receiver_type.trim();
        if raw.is_empty() || raw == "T.untyped" || raw.contains("T.any(") || raw.starts_with("T.nilable(") {
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
            raw.trim_start_matches("::").rsplit("::").next().unwrap_or(raw).to_string()
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

    fn deterministic_literal_comparison_result(&self, node: Node<'_>) -> Option<Value> {
        let op = call_name(node, self.file)?;
        if !matches!(op.as_str(), "==" | "!=" | ">" | ">=" | "<" | "<=") {
            return None;
        }
        let receiver = call_receiver(node, self.file)?;
        let args = call_arguments(node, self.file);
        if args.len() != 1 {
            return None;
        }
        let left = self.literal_static_value(receiver);
        let right = self.literal_static_value(args[0]);
        if matches!(left, LiteralStaticValue::Unknown) || matches!(right, LiteralStaticValue::Unknown) {
            return None;
        }
        let truth = self.compare_literal_values(&left, &right, &op)?;
        Some(self.deterministic_guard_result(
            truth,
            "literal_comparison",
            format!(
                "{} {} {} is always {}",
                node_text(receiver, self.file),
                op,
                node_text(args[0], self.file),
                truth
            ),
            None,
            None,
        ))
    }

    fn deterministic_guard_subject_type(&mut self, node: Node<'_>, frame: &mut Frame) -> Option<String> {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                frame
                    .param_types
                    .get(&name)
                    .and_then(Clone::clone)
                    .or_else(|| frame.local_types.get(&name).cloned())
            }
            NormKind::IvarRead => self.expression_type(node, frame),
            _ => self.static_expression_type(node, frame),
        }
    }

    fn literal_static_value(&self, node: Node<'_>) -> LiteralStaticValue {
        match normalized_kind(node, self.file) {
            NormKind::String => LiteralStaticValue::String(unquote(&node_text(node, self.file))),
            NormKind::Symbol => LiteralStaticValue::Symbol(node_text(node, self.file).trim_start_matches(':').to_string()),
            NormKind::Integer => node_text(node, self.file)
                .parse::<i64>()
                .map(LiteralStaticValue::Integer)
                .unwrap_or(LiteralStaticValue::Unknown),
            NormKind::Float => node_text(node, self.file)
                .parse::<f64>()
                .map(LiteralStaticValue::Float)
                .unwrap_or(LiteralStaticValue::Unknown),
            NormKind::True => LiteralStaticValue::Bool(true),
            NormKind::False => LiteralStaticValue::Bool(false),
            NormKind::Nil => LiteralStaticValue::Nil,
            _ => LiteralStaticValue::Unknown,
        }
    }

    fn compare_literal_values(&self, left: &LiteralStaticValue, right: &LiteralStaticValue, op: &str) -> Option<bool> {
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

    fn predicate_origin(&self, node: Node<'_>, frame: &Frame) -> (Option<String>, Option<String>) {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                if frame.param_types.contains_key(&name) {
                    return (Some("param".to_string()), Some(name));
                }
                if frame.local_types.contains_key(&name) {
                    return (Some("local".to_string()), Some(name));
                }
            }
            NormKind::IvarRead => return (Some("ivar".to_string()), Some(node_text(node, self.file))),
            NormKind::Call => {
                let name = call_name(node, self.file).unwrap_or_default();
                if call_receiver(node, self.file).is_some() && call_arguments(node, self.file).is_empty() {
                    return (Some("attr".to_string()), Some(name));
                }
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
            (LiteralStaticValue::Integer(left), LiteralStaticValue::Integer(right)) => left == right,
            (LiteralStaticValue::Float(left), LiteralStaticValue::Float(right)) => left == right,
            (LiteralStaticValue::Integer(left), LiteralStaticValue::Float(right)) => (*left as f64) == *right,
            (LiteralStaticValue::Float(left), LiteralStaticValue::Integer(right)) => *left == (*right as f64),
            (LiteralStaticValue::Bool(left), LiteralStaticValue::Bool(right)) => left == right,
            (LiteralStaticValue::Nil, LiteralStaticValue::Nil) => true,
            _ => false,
        }
    }

    fn literal_numeric_value(&self, value: &LiteralStaticValue) -> Option<f64> {
        match value {
            LiteralStaticValue::Integer(value) => Some(*value as f64),
            LiteralStaticValue::Float(value) => Some(*value),
            _ => None,
        }
    }

    fn provably_non_nil(&mut self, node: Node<'_>, frame: &mut Frame) -> bool {
        match normalized_kind(node, self.file) {
            NormKind::LocalRead => {
                let name = node_text(node, self.file);
                frame.non_nil_locals.contains(&name) && !frame.maybe_nil_locals.contains(&name)
            }
            NormKind::Call => !safe_navigation(node)
                && call_name(node, self.file)
                    .is_some_and(|name| self.file.non_nil_method_returns.contains(&name)),
            NormKind::SelfNode => true,
            _ => self.non_nil_literal(node, frame),
        }
    }

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
