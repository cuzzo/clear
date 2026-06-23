use super::effects::{effect_from_call_with_lexicon, EffectLexicon};
use super::normalized_behavior::{
    eliminable_guard_from_call, nil_guard_from_predicates, NormalizedCallParts,
    NormalizedCallProjection, NormalizedLanguageBehavior, NormalizedNilGuardFact,
    NormalizedSemanticEffect, NormalizedStateRead,
};
use super::CallSite;
use super::StateDeclaration;
use crate::ast::{Node, Span};
use crate::ast::Child;

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
    ) -> Option<StateDeclaration> {
        // Try structured children first: [name_node, type_node?, value_node?]
        let child_nodes: Vec<&Node> = node.children.iter().filter_map(|c| match c {
            Child::Node(n) => Some(n.as_ref()),
            _ => None,
        }).collect();
        if child_nodes.len() >= 2 {
            let name = child_nodes[0].text.trim();
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
        if let Some((name, rest)) = text.split_once(':') {
            let name = name.trim();
            if is_simple_name(name) {
                let type_text = rest.split('=').next().unwrap_or(rest).trim()
                    .trim_end_matches(',').to_string();
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
            .rfind(|ch: char| !(ch == '_' || ch.is_ascii_alphanumeric() || ch == '.'))
            .map(|offset| offset + 1)
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
        && name.chars().next().map_or(false, |c| c == '_' || c.is_ascii_alphabetic())
        && name.chars().all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    matches!(chars.next(), Some(first) if first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch == '?' || ch == '!' || ch.is_ascii_alphanumeric())
}
