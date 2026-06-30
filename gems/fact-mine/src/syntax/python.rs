use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect, NormalizedStateRead,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::Child;
use crate::ast::{Node, Span};

const PYTHON_CONTEXT_PAIRS: &[(&str, &[&str])] = &[
    ("time", &["time", "monotonic", "perf_counter"]),
    ("datetime", &["now", "today", "utcnow"]),
    ("random", &["random", "randint", "randrange", "choice"]),
];

const PYTHON_EFFECT_LEXICON: EffectLexicon = EffectLexicon {
    dispatch_mids: &[
        "getattr",
        "setattr",
        "hasattr",
        "__getattr__",
        "__setattr__",
        "import_module",
    ],
    meta_mids: &[
        "eval", "exec", "compile", "type", "globals", "locals", "vars", "setattr", "delattr",
    ],
    method_obj_mids: &["method"],
    io_consts: &[
        "Path",
        "pathlib",
        "os",
        "sys",
        "subprocess",
        "socket",
        "shutil",
    ],
    io_bare: &[
        "print", "println", "printf", "puts", "panic", "input", "open", "exec", "eval",
    ],
    context_pairs: PYTHON_CONTEXT_PAIRS,
    context_bare: &["random", "randint", "randrange"],
    callback_set: &[
        "transaction",
        "synchronize",
        "lock",
        "with_lock",
        "unlock",
        "mutex",
        "atomic",
        "subscribe",
        "callback",
        "hook",
    ],
    callback_requires_block: true,
    ..EffectLexicon::empty()
};

const PYTHON_NIL_PREDICATES: &[&str] = &["isNull", "is_null", "is_none"];
const PYTHON_NON_NIL_PREDICATES: &[&str] = &["isSome", "is_some", "present"];
const PYTHON_GUARD_MIDS: &[&str] = &["isNull", "is_null", "is_none", "is_some"];

pub(crate) struct PythonNormalizedBehavior;

impl NormalizedLanguageBehavior for PythonNormalizedBehavior {
    fn self_member_receiver(&self, message: &str) -> String {
        format!("self.{message}")
    }

    fn clean_identifier(&self, token: &str) -> String {
        token.strip_prefix("self.").unwrap_or(token).to_string()
    }

    fn clean_receiver(&self, receiver: &str) -> String {
        if receiver.starts_with("self.") {
            receiver["self.".len()..].to_string()
        } else {
            receiver.to_string()
        }
    }

    fn yield_semantic_effect(&self, _node: &Node) -> bool {
        false
    }

    fn boolean_decision_members(&self, mut members: Vec<String>, _node: &Node) -> Vec<String> {
        members.sort();
        members
    }

    fn function_visibility(&self, name: &str, _node: &Node, _lines: &[String]) -> String {
        if name.starts_with('_') && !name.starts_with("__") {
            "private".to_string()
        } else {
            "public".to_string()
        }
    }

    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param
            .split('=')
            .next()
            .unwrap_or(param)
            .split(':')
            .next()
            .unwrap_or(param)
            .trim();
        (!text.is_empty()).then(|| text.trim_start_matches('*').to_string())
    }

    fn state_read_uses_access_span(&self, _call: &NormalizedCallProjection) -> bool {
        true
    }

    fn suppress_state_read_for_call(
        &self,
        call: &NormalizedCallProjection,
        _span_source: &str,
    ) -> bool {
        call.receiver == "self" && matches!(call.message.as_str(), "callback" | "len" | "open")
    }

    fn property_read_call(&self, node: &Node, parts: &NormalizedCallParts) -> bool {
        node.r#type != "VCALL"
            && parts.arguments.is_empty()
            && (!node.text.contains('(') || parenthesized_property_read(&node.text))
    }

    fn embedded_member_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        dotted_member_reads(&node.text, node.first_lineno, node.first_column)
            .into_iter()
            .filter(|read| read.field != "_lock" && !read.field.ends_with("_lock"))
            .collect()
    }

    fn node_state_reads(&self, node: &Node) -> Vec<NormalizedStateRead> {
        if node.r#type != "EXPRESSION_STATEMENT" || !node.text.contains('=') {
            return Vec::new();
        }
        let rhs = node.text.split_once('=').map(|(_, rhs)| rhs).unwrap_or("");
        dotted_member_reads(
            rhs,
            node.first_lineno,
            node.first_column + node.text.len() - rhs.len(),
        )
    }

    fn ternary_children_conditional(&self, _node: &Node) -> bool {
        false
    }

    fn ternary_if_node(&self, node: &Node) -> bool {
        if node.r#type != "IF" || node.first_lineno != node.last_lineno {
            return false;
        }
        let source = format!(" {} ", node.text.as_str());
        source.contains(" if ") && source.contains(" else ")
    }

    fn wrap_branch_predicate(&self, _branch: &Node) -> bool {
        false
    }

    fn owner_name_span(&self, _name: &str, node: &Node, default_span: Span) -> Option<Span> {
        (node.r#type == "CLASS").then_some(default_span)
    }

    fn nil_guard_fact(&self, message: &str, subject: &str) -> Option<NormalizedNilGuardFact> {
        nil_guard_from_predicates(
            message,
            subject,
            PYTHON_NIL_PREDICATES,
            PYTHON_NON_NIL_PREDICATES,
        )
    }

    fn semantic_effect_for_call(&self, call: &CallSite) -> Option<NormalizedSemanticEffect> {
        eliminable_guard_from_call(call, PYTHON_GUARD_MIDS)
            .or_else(|| effect_from_call_with_lexicon(call, &PYTHON_EFFECT_LEXICON))
    }

    fn local_flow_declaration_keyword(&self, _keyword: &str) -> bool {
        false
    }

    fn local_flow_keyword(&self, name: &str) -> bool {
        matches!(
            name,
            "as" | "break"
                | "class"
                | "continue"
                | "else"
                | "False"
                | "false"
                | "for"
                | "if"
                | "in"
                | "None"
                | "return"
                | "self"
                | "True"
                | "true"
                | "while"
        )
    }

    fn state_declaration_from_node(
        &self,
        node: &Node,
        _owner: &str,
        in_method: bool,
    ) -> Option<StateDeclaration> {
        if !node.text.contains(':') {
            return None;
        }
        if !matches!(
            node.r#type.as_str(),
            "expression_statement"
                | "annotated_assignment"
                | "assignment"
                | "IASGN"
                | "ASSIGN"
                | "LASGN"
        ) {
            return None;
        }
        if in_method && !node.text.trim().starts_with("self.") {
            return None;
        }
        // Try structured children first: [name_node, type_node?, value_node?]
        let child_nodes: Vec<&Node> = node
            .children
            .iter()
            .filter_map(|c| match c {
                Child::Node(n) => Some(n.as_ref()),
                _ => None,
            })
            .collect();
        if child_nodes.len() >= 2 {
            let raw_name = child_nodes[0].text.trim();
            let name = raw_name.strip_prefix("self.").unwrap_or(raw_name);
            if is_simple_name(name) {
                let type_text = child_nodes[1].text.trim().to_string();
                if !type_text.is_empty() && type_text != ":" && !type_text.starts_with('=') {
                    return Some(StateDeclaration {
                        field: name.to_string(),
                        owner: String::new(),
                        r#type: Some(type_text),
                        file: String::new(),
                        line: node.first_lineno,
                        span: span(node),
                    });
                }
            }
        }
        // Fallback: text-based for nodes without structured children (`name: Type`)
        let text = node.text.trim();
        if let Some((raw_name, rest)) = text.split_once(':') {
            let raw_name = raw_name.trim();
            let name = raw_name.strip_prefix("self.").unwrap_or(raw_name);
            if is_simple_name(name) {
                let type_text = rest
                    .split('=')
                    .next()
                    .unwrap_or(rest)
                    .trim()
                    .trim_end_matches(',')
                    .to_string();
                if !type_text.is_empty() && type_text != ":" {
                    return Some(StateDeclaration {
                        field: name.to_string(),
                        owner: String::new(),
                        r#type: Some(type_text),
                        file: String::new(),
                        line: node.first_lineno,
                        span: span(node),
                    });
                }
            }
        }
        None
    }

    fn format_array_type(&self, elem: &str) -> String {
        format!("List[{elem}]")
    }

    fn format_hash_type(&self, key: &str, val: &str) -> String {
        format!("Dict[{key}, {val}]")
    }

    fn format_set_type(&self, elem: &str) -> String {
        format!("Set[{elem}]")
    }

    fn format_nilable_type(&self, type_text: &str) -> String {
        if type_text.is_empty() || type_text == "nil" || type_text == "null" || type_text == "None" {
            return type_text.to_string();
        }
        if type_text.starts_with("Optional[") {
            type_text.to_string()
        } else {
            format!("Optional[{type_text}]")
        }
    }

    fn untyped_type(&self) -> String {
        "Any".to_string()
    }

    fn untyped_array_type(&self) -> String {
        "List[Any]".to_string()
    }

    fn untyped_hash_type(&self) -> String {
        "Dict[Any, Any]".to_string()
    }
}

static BEHAVIOR: PythonNormalizedBehavior = PythonNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn span(node: &Node) -> Span {
    [
        node.first_lineno,
        node.first_column,
        node.last_lineno,
        node.last_column,
    ]
}

fn dotted_member_reads(text: &str, line: usize, column: usize) -> Vec<NormalizedStateRead> {
    if text.contains('=') && !text.contains('.') {
        return Vec::new();
    }
    let mut reads = Vec::new();
    for (receiver, field, start, end) in dotted_segments(text) {
        reads.push(NormalizedStateRead {
            receiver,
            field,
            line: Some(line),
            span: [line, column + start, line, column + end],
        });
    }
    reads
}

fn parenthesized_property_read(text: &str) -> bool {
    let source = text.trim();
    source.starts_with('(')
        && source.ends_with(')')
        && !source[1..source.len().saturating_sub(1)].contains('(')
}

fn dotted_segments(text: &str) -> Vec<(String, String, usize, usize)> {
    let bytes = text.as_bytes();
    let mut out = Vec::new();
    for index in 0..bytes.len() {
        if bytes[index] != b'.' || index == 0 || index + 1 >= bytes.len() {
            continue;
        }
        let receiver_start = text[..index]
            .char_indices()
            .rfind(|(_, ch)| !(*ch == '_' || ch.is_ascii_alphanumeric() || *ch == '.'))
            .map(|(offset, ch)| offset + ch.len_utf8())
            .unwrap_or(0);
        let field_end = text[(index + 1)..]
            .find(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric()))
            .map(|offset| index + 1 + offset)
            .unwrap_or(text.len());
        let receiver = &text[receiver_start..index];
        let field = &text[(index + 1)..field_end];
        if simple_dotted_part(receiver) && simple_identifier(field) {
            out.push((
                receiver.to_string(),
                field.to_string(),
                receiver_start,
                field_end,
            ));
        }
    }
    out
}

fn simple_dotted_part(value: &str) -> bool {
    !value.is_empty() && value.split('.').all(simple_identifier)
}

fn is_simple_name(name: &str) -> bool {
    !name.is_empty()
        && !name.contains(' ')
        && !name.contains('.')
        && !name.contains('[')
        && !name.contains('<')
        && !name.contains('(')
        && name
            .chars()
            .next()
            .map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
        && name
            .chars()
            .all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn node(kind: &str, text: &str) -> Node {
        Node {
            r#type: kind.to_string(),
            children: Vec::new(),
            first_lineno: 10,
            first_column: 2,
            last_lineno: 10,
            last_column: 20,
            text: text.to_string(),
        }
    }

    #[test]
    fn test_python_behavior_comprehensive() {
        let b = PythonNormalizedBehavior;

        // 1. self_member_receiver
        assert_eq!(b.self_member_receiver("foo"), "self.foo");

        // 2. clean_identifier & clean_receiver
        assert_eq!(b.clean_identifier("self.foo"), "foo");
        assert_eq!(b.clean_identifier("foo"), "foo");
        assert_eq!(b.clean_receiver("self.foo"), "foo");
        assert_eq!(b.clean_receiver("foo"), "foo");

        // 3. yield_semantic_effect
        assert!(!b.yield_semantic_effect(&node("", "")));

        // 4. boolean_decision_members
        let members = vec!["b".to_string(), "a".to_string()];
        let sorted = b.boolean_decision_members(members, &node("", ""));
        assert_eq!(sorted, vec!["a".to_string(), "b".to_string()]);

        // 5. function_visibility
        assert_eq!(b.function_visibility("_foo", &node("", ""), &[]), "private");
        assert_eq!(b.function_visibility("__foo__", &node("", ""), &[]), "public");
        assert_eq!(b.function_visibility("foo", &node("", ""), &[]), "public");

        // 6. parameter_name_from_signature
        assert_eq!(b.parameter_name_from_signature("*args"), Some("args".to_string()));
        assert_eq!(b.parameter_name_from_signature("x: int = 1"), Some("x".to_string()));

        // 7. state_read_uses_access_span
        assert!(b.state_read_uses_access_span(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "foo".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }));

        // 8. suppress_state_read_for_call
        assert!(b.suppress_state_read_for_call(&NormalizedCallProjection {
            receiver: "self".to_string(),
            message: "callback".to_string(),
            arguments: Vec::new(),
            access_span: [1, 2, 3, 4],
            span: [1, 2, 3, 4],
        }, ""));

        // 9. property_read_call
        assert!(b.property_read_call(&node("CALL", "(x.y)"), &NormalizedCallParts {
            receiver: "x".to_string(),
            message: "y".to_string(),
            arguments: Vec::new(),
        }));

        // 10. embedded_member_reads
        let reads = b.embedded_member_reads(&node("", "self.field_lock"));
        assert!(reads.is_empty());
        let reads_eq = b.embedded_member_reads(&node("", "x = y"));
        assert!(reads_eq.is_empty());

        // 11. node_state_reads
        let reads_node = b.node_state_reads(&node("EXPRESSION_STATEMENT", "self.x = self.y"));
        assert_eq!(reads_node.len(), 1);
        assert_eq!(reads_node[0].field, "y");
        assert!(b.node_state_reads(&node("EXPRESSION_STATEMENT", "self.x = y")).is_empty());
        // Cover line 339 (contains = but not .)
        let reads_no_dots = b.node_state_reads(&node("EXPRESSION_STATEMENT", "x = y"));
        assert!(reads_no_dots.is_empty());

        // 12. ternary_children_conditional & ternary_if_node
        assert!(!b.ternary_children_conditional(&node("", "")));
        assert!(b.ternary_if_node(&node("IF", "x if cond else y")));
        assert!(!b.ternary_if_node(&node("IF", "if cond:\n  pass")));

        // 13. wrap_branch_predicate
        assert!(!b.wrap_branch_predicate(&node("", "")));

        // 14. owner_name_span
        assert!(b.owner_name_span("MyClass", &node("CLASS", ""), [1, 2, 3, 4]).is_some());

        // 15. nil_guard_fact
        assert!(b.nil_guard_fact("is_none", "x").is_some());

        // 16. semantic_effect_for_call
        assert!(b.semantic_effect_for_call(&CallSite {
            receiver: "x".to_string(),
            message: "is_none".to_string(),
            file: "".to_string(),
            function: "".to_string(),
            owner: "".to_string(),
            line: 1,
            span: [1, 2, 3, 4],
            conditional: false,
            arguments: Vec::new(),
            control: None,
            safe_navigation: false,
            block: false,
        }).is_some());

        // 17. local_flow_declaration_keyword
        assert!(!b.local_flow_declaration_keyword("int"));

        // 18. local_flow_keyword
        for kw in &["as", "break", "class", "continue", "else", "False", "false", "for", "if", "in", "None", "return", "self", "True", "true", "while"] {
            assert!(b.local_flow_keyword(kw));
        }
        assert!(!b.local_flow_keyword("not_a_keyword"));

        // 19. state_declaration_from_node
        // Structured children branch
        let child1 = node("identifier", "self.myField");
        let child2 = node("type", "int");
        let mut decl_node = node("annotated_assignment", "self.myField: int");
        decl_node.children = vec![
            Child::Node(Box::new(child1)),
            Child::Node(Box::new(child2)),
        ];
        let decl = b.state_declaration_from_node(&decl_node, "MyClass", false).unwrap();
        assert_eq!(decl.field, "myField");
        assert_eq!(decl.r#type, Some("int".to_string()));

        // Text-based fallback branch
        let field_node = node("annotated_assignment", "self.myField: int = 123");
        let decl_fallback = b.state_declaration_from_node(&field_node, "MyClass", false).unwrap();
        assert_eq!(decl_fallback.field, "myField");
        assert_eq!(decl_fallback.r#type, Some("int".to_string()));

        // None branches
        assert!(b.state_declaration_from_node(&node("annotated_assignment", "no_colon"), "MyClass", false).is_none());
        assert!(b.state_declaration_from_node(&node("other", "self.x: int"), "MyClass", false).is_none());
        let field_node_no_self = node("annotated_assignment", "myField: int = 123");
        assert!(b.state_declaration_from_node(&field_node_no_self, "MyClass", true).is_none());
        // Cover line 283 (empty type_text after colon)
        assert!(b.state_declaration_from_node(&node("annotated_assignment", "self.myField:"), "MyClass", false).is_none());

        // 20-26. formatting
        assert_eq!(b.format_array_type("Int"), "List[Int]");
        assert_eq!(b.format_hash_type("String", "Int"), "Dict[String, Int]");
        assert_eq!(b.format_set_type("Int"), "Set[Int]");
        assert_eq!(b.format_nilable_type(""), "");
        assert_eq!(b.format_nilable_type("Optional[Int]"), "Optional[Int]");
        assert_eq!(b.format_nilable_type("Int"), "Optional[Int]");
        assert_eq!(b.untyped_type(), "Any");
        assert_eq!(b.untyped_array_type(), "List[Any]");
        assert_eq!(b.untyped_hash_type(), "Dict[Any, Any]");

        // Helper functions
        assert!(is_simple_name("var_name"));
        assert!(!is_simple_name(""));
    }
}
